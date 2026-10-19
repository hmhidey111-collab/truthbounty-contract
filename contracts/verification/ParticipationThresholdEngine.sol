// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ParticipationThresholdTypes} from "./ParticipationThresholdTypes.sol";
import {ParticipationConfidenceRules} from "./ParticipationConfidenceRules.sol";
import {FrozenRoundConfigStore} from "./FrozenRoundConfigStore.sol";
import {RoundFinalization} from "./RoundFinalization.sol";

/**
 * @title ParticipationThresholdEngine
 * @notice V2-SC-014 engine applying frozen round thresholds to aggregated weights.
 *
 * @dev Extended by PREWAVE-SC-046 (#722):
 *
 *      FINALITY BINDING
 *      finalizeRound() reads challengeDeadline from FrozenRoundConfigStore --
 *      it is never accepted from the caller. The EVALUATOR_ROLE cannot shorten
 *      or replace it. Passing a deadline of 0 is the legacy path where no
 *      deadline was set; finalization is permitted immediately in that case only.
 *
 *      AGGREGATION BINDING
 *      finalizeRound() requires evaluateRound() to have been called first
 *      (_evaluated[id] must be true). It reads the stored ThresholdEvaluation
 *      and does not accept fresh WeightTotals -- the same round cannot be
 *      evaluated with one result and finalized with another.
 */
contract ParticipationThresholdEngine is AccessControl {
    bytes32 public constant EVALUATOR_ROLE = keccak256("EVALUATOR_ROLE");

    FrozenRoundConfigStore public immutable configStore;

    mapping(bytes32 => ParticipationThresholdTypes.ThresholdEvaluation) private _evaluations;
    mapping(bytes32 => bool) private _evaluated;

    mapping(bytes32 => RoundFinalization.FinalizationRecord) private _finalizations;
    mapping(bytes32 => bool) private _finalized;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ThresholdEvaluated(
        bytes32 indexed roundId,
        uint256 indexed claimId,
        ParticipationThresholdTypes.RoundKind roundKind,
        ParticipationThresholdTypes.ClaimOutcome outcome,
        ParticipationThresholdTypes.InconclusiveReason reason,
        uint256 confidenceBps
    );

    /**
     * @notice Canonical machine-readable finalization event (PREWAVE-SC-046).
     * @dev Settlement and reward modules MUST consume this event as the
     *      authoritative signal. isProvisional is always false because
     *      finalizeRound() enforces the stored challenge deadline.
     *      trueWeight/falseWeight come from the stored ThresholdEvaluation,
     *      not from a caller-supplied argument.
     */
    event RoundFinalized(
        bytes32 indexed roundId,
        uint256 indexed claimId,
        ParticipationThresholdTypes.RoundKind roundKind,
        RoundFinalization.TerminalState terminalState,
        RoundFinalization.EconomicOutcome economicOutcome,
        uint256 trueWeight,
        uint256 falseWeight,
        uint256 confidenceBps
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error AlreadyEvaluated(bytes32 roundId);
    error RoundNotFrozen(bytes32 roundId);
    error AlreadyFinalized(bytes32 roundId);
    /// @notice finalizeRound() called before evaluateRound().
    error NotEvaluated(bytes32 roundId);
    /// @notice block.timestamp is before the frozen challenge deadline.
    error ChallengeWindowStillOpen(bytes32 roundId, uint64 challengeDeadline);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address admin, FrozenRoundConfigStore store) {
        configStore = store;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EVALUATOR_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Evaluation path (SC-014, unchanged)
    // -------------------------------------------------------------------------

    /**
     * @notice Evaluate aggregated weights against frozen thresholds and store result.
     * @dev Must be called before finalizeRound(). Idempotent -- reverts on second call.
     */
    function evaluateRound(
        uint256 claimId,
        ParticipationThresholdTypes.RoundKind roundKind,
        ParticipationThresholdTypes.WeightTotals calldata weights
    ) external onlyRole(EVALUATOR_ROLE) returns (ParticipationThresholdTypes.ThresholdEvaluation memory evaluation) {
        bytes32 id = configStore.roundId(claimId, roundKind);
        if (!configStore.isRoundFrozen(id)) revert RoundNotFrozen(id);
        if (_evaluated[id]) revert AlreadyEvaluated(id);

        ParticipationThresholdTypes.FrozenRoundConfig memory config = configStore.getFrozenConfig(id);
        evaluation = ParticipationConfidenceRules.evaluate(weights, config, roundKind);

        _evaluations[id] = evaluation;
        _evaluated[id] = true;

        emit ThresholdEvaluated(
            id, claimId, roundKind,
            evaluation.outcome,
            evaluation.reason,
            evaluation.confidenceBps
        );
    }

    // -------------------------------------------------------------------------
    // PREWAVE-SC-046: authoritative finalization path
    // -------------------------------------------------------------------------

    /**
     * @notice Finalize a round using its stored ThresholdEvaluation.
     *
     * @dev Requirements (all enforced on-chain, not caller-disciplined):
     *      1. The round config must be frozen in configStore.
     *      2. evaluateRound() must have been called (_evaluated[id] == true).
     *      3. The frozen challenge deadline (from configStore) must have elapsed.
     *         The caller does NOT supply the deadline.
     *      4. Can only be called once per round (idempotent).
     *
     *      Outcome comes from _evaluations[id] -- the same stored record that
     *      evaluateRound() wrote. Fresh WeightTotals are not accepted.
     *
     * @param claimId   The claim being finalized.
     * @param roundKind FIRST or APPEAL.
     */
    function finalizeRound(
        uint256 claimId,
        ParticipationThresholdTypes.RoundKind roundKind
    ) external onlyRole(EVALUATOR_ROLE) returns (RoundFinalization.FinalizationRecord memory record) {
        bytes32 id = configStore.roundId(claimId, roundKind);
        if (!configStore.isRoundFrozen(id)) revert RoundNotFrozen(id);
        // Require prior evaluation -- cannot finalize before evaluate
        if (!_evaluated[id]) revert NotEvaluated(id);
        if (_finalized[id])  revert AlreadyFinalized(id);

        // Read the frozen deadline from the store -- caller cannot supply or override it
        uint64 deadline = configStore.getChallengeDeadline(id);
        // deadline == 0 means the legacy freezeRoundConfig() path was used (no deadline set).
        // In that case finalization is permitted immediately.
        if (deadline > 0 && block.timestamp < uint256(deadline)) {
            revert ChallengeWindowStillOpen(id, deadline);
        }

        // Build FinalizationRecord from the stored ThresholdEvaluation
        ParticipationThresholdTypes.ThresholdEvaluation memory eval = _evaluations[id];
        ParticipationThresholdTypes.FrozenRoundConfig memory config = configStore.getFrozenConfig(id);

        // Reconstruct WeightTotals from stored evaluation (source of truth)
        ParticipationThresholdTypes.WeightTotals memory storedWeights = ParticipationThresholdTypes.WeightTotals({
            trueWeight:    eval.trueWeight,
            falseWeight:   eval.falseWeight,
            verifierCount: 0 // verifierCount is not stored in ThresholdEvaluation;
                             // it was used only as a threshold gate during evaluation.
                             // The terminal state and economic outcome are already determined.
        });

        record = RoundFinalization.finalize(storedWeights, config, roundKind, true);

        _finalizations[id] = record;
        _finalized[id] = true;

        emit RoundFinalized(
            id,
            claimId,
            roundKind,
            record.state,
            record.economic,
            eval.trueWeight,
            eval.falseWeight,
            record.confidenceBps
        );
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    function previewEvaluation(
        ParticipationThresholdTypes.WeightTotals calldata weights,
        ParticipationThresholdTypes.FrozenRoundConfig calldata config,
        ParticipationThresholdTypes.RoundKind roundKind
    ) external pure returns (ParticipationThresholdTypes.ThresholdEvaluation memory) {
        return ParticipationConfidenceRules.evaluate(weights, config, roundKind);
    }

    function getEvaluation(bytes32 roundId)
        external
        view
        returns (ParticipationThresholdTypes.ThresholdEvaluation memory)
    {
        return _evaluations[roundId];
    }

    function isEvaluated(bytes32 roundId) external view returns (bool) {
        return _evaluated[roundId];
    }

    function getFinalization(bytes32 roundId)
        external
        view
        returns (RoundFinalization.FinalizationRecord memory)
    {
        return _finalizations[roundId];
    }

    function isFinalized(bytes32 roundId) external view returns (bool) {
        return _finalized[roundId];
    }
}
