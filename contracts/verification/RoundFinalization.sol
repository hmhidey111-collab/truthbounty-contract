// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// =============================================================================
//  PREWAVE-SC-046 -- Quorum, Tie, and Insufficient-Evidence Finalization
//  Issue #722
//  Dependencies: PREWAVE-SC-004 (#679), PREWAVE-SC-005 (#680)
//
//  Design invariants
//  -----------------
//  - BPS_DENOMINATOR is NOT redefined here; the single frozen authority is
//    ParticipationThresholdTypes.BPS_DENOMINATOR = 10_000. This library
//    re-exports it as an alias so callers have one import point.
//  - Finality is bound to block.timestamp >= challengeDeadline inside the
//    authoritative engine path (ParticipationThresholdEngine.finalizeRound).
//    The pure helper finalize() accepts a pre-evaluated bool only for
//    off-chain preview/testing; the on-chain path always computes it.
//  - Aggregation is order-independent: weight totals are simple uint256
//    accumulators; outcome depends only on final totals.
//  - No token transfers, no state writes in this library.
// =============================================================================

import {ParticipationThresholdTypes} from "./ParticipationThresholdTypes.sol";
import {ParticipationConfidenceRules} from "./ParticipationConfidenceRules.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title RoundFinalization
 * @notice Pure library that converts aggregated weight totals and a frozen
 *         round config into a canonical, machine-readable FinalizationRecord.
 *
 * @dev The authoritative on-chain path is
 *      ParticipationThresholdEngine.finalizeRound(), which computes
 *      challengeWindowElapsed from block.timestamp and the frozen deadline.
 *      The pure finalize() helper is for off-chain preview and unit tests only.
 *
 *      Quorum denominator: uses ParticipationThresholdTypes.BPS_DENOMINATOR
 *      (= 10_000) as the single frozen authority. Never redefined here.
 */
library RoundFinalization {
    // =========================================================================
    // Re-export the canonical frozen denominator (single authority)
    // =========================================================================

    /// @notice Convenience alias for the frozen BPS denominator.
    ///         The actual constant lives in ParticipationThresholdTypes.
    ///         Value: 10_000 == ParticipationThresholdTypes.BPS_DENOMINATOR.
    uint256 internal constant BPS_DENOMINATOR =
        ParticipationThresholdTypes.BPS_DENOMINATOR;

    // =========================================================================
    // Terminal state enum  (machine-readable finalization output)
    // =========================================================================

    /**
     * @notice Every possible terminal outcome of a verification round.
     *
     * VERIFIED_TRUE              Quorum met, confidence >= threshold, TRUE wins.
     * VERIFIED_FALSE             Quorum met, confidence >= threshold, FALSE wins.
     * INCONCLUSIVE_TIE           Both sides have exactly equal weight.
     * INCONCLUSIVE_ZERO          No verifier participated (zero weight + zero count).
     * INCONCLUSIVE_INSUFFICIENT  Quorum not met (count < min OR weight < min).
     * INCONCLUSIVE_LOW_CONFIDENCE Quorum met but confidence < threshold.
     */
    enum TerminalState {
        VERIFIED_TRUE,
        VERIFIED_FALSE,
        INCONCLUSIVE_TIE,
        INCONCLUSIVE_ZERO,
        INCONCLUSIVE_INSUFFICIENT,
        INCONCLUSIVE_LOW_CONFIDENCE
    }

    // =========================================================================
    // Economic consequence enum
    // =========================================================================

    /**
     * @notice Maps each terminal state to a stake-custody consequence.
     *
     * REWARD_WINNERS_SLASH_LOSERS  Winning verifiers receive rewards;
     *                               losing verifiers are slashed.
     * FULL_REFUND                  All verifiers receive their principal back
     *                               unchanged (all inconclusive paths).
     * PARTIAL_SLASH_NO_REWARD      Reserved for future governance use.
     */
    enum EconomicOutcome {
        REWARD_WINNERS_SLASH_LOSERS,
        FULL_REFUND,
        PARTIAL_SLASH_NO_REWARD
    }

    // =========================================================================
    // Finalization record
    // =========================================================================

    /**
     * @notice The canonical, machine-readable finalization record produced at
     *         the end of a verification round.
     *
     * @param state              Terminal state (see TerminalState).
     * @param economic           Economic consequence (see EconomicOutcome).
     * @param trueWeight         Total weight of TRUE verifications.
     * @param falseWeight        Total weight of FALSE verifications.
     * @param totalWeight        trueWeight + falseWeight.
     * @param verifierCount      Number of distinct verifiers that participated.
     * @param confidenceBps      Winning confidence in bps (0 for inconclusive).
     * @param quorumDenominator  Snapshot of ParticipationThresholdTypes.BPS_DENOMINATOR
     *                           embedded for off-chain verifiability.
     * @param effectiveMinCount  Minimum verifier count that was required.
     * @param effectiveMinWeight Minimum total weight that was required.
     * @param effectiveMinConf   Minimum confidence (bps) that was required.
     * @param isProvisional      True when block.timestamp < challengeDeadline.
     *                           Settlement and reward modules MUST reject
     *                           provisional records -- use assertFinal().
     */
    struct FinalizationRecord {
        TerminalState state;
        EconomicOutcome economic;
        uint256 trueWeight;
        uint256 falseWeight;
        uint256 totalWeight;
        uint256 verifierCount;
        uint256 confidenceBps;
        uint256 quorumDenominator;
        uint256 effectiveMinCount;
        uint256 effectiveMinWeight;
        uint256 effectiveMinConf;
        bool isProvisional;
    }

    // =========================================================================
    // Custom errors
    // =========================================================================

    /// @notice Reverts when a caller attempts to treat a provisional record as
    ///         final before the challenge window has elapsed.
    error ProvisionalNotFinal();

    // =========================================================================
    // Core pure helper
    // =========================================================================

    /**
     * @notice Convert aggregated weight totals + a frozen round config into a
     *         FinalizationRecord.
     *
     * @dev PURE HELPER -- for off-chain preview and unit tests only.
     *      The authoritative on-chain path is
     *      ParticipationThresholdEngine.finalizeRound(), which derives
     *      challengeWindowElapsed from block.timestamp rather than accepting
     *      a caller-supplied value.
     *
     *      Order independence: weights must be produced by a simple
     *      accumulation loop (trueWeight += w_i, falseWeight += w_j).
     *      Because addition is commutative, the result is identical for any
     *      permutation of verifier submission order.
     *
     * @param weights               Aggregated weight totals.
     * @param config                Frozen threshold config for this round.
     * @param roundKind             FIRST or APPEAL.
     * @param challengeWindowElapsed True when block.timestamp >= challengeDeadline.
     * @return record               The canonical finalization record.
     */
    function finalize(
        ParticipationThresholdTypes.WeightTotals memory weights,
        ParticipationThresholdTypes.FrozenRoundConfig memory config,
        ParticipationThresholdTypes.RoundKind roundKind,
        bool challengeWindowElapsed
    ) internal pure returns (FinalizationRecord memory record) {
        // Delegate threshold evaluation to the canonical confidence rules
        ParticipationThresholdTypes.ThresholdEvaluation memory eval =
            ParticipationConfidenceRules.evaluate(weights, config, roundKind);

        record.trueWeight    = eval.trueWeight;
        record.falseWeight   = eval.falseWeight;
        record.totalWeight   = eval.totalWeight;
        record.verifierCount = weights.verifierCount;
        record.confidenceBps = eval.confidenceBps;

        // Embed the canonical frozen denominator as an auditable snapshot
        record.quorumDenominator = ParticipationThresholdTypes.BPS_DENOMINATOR;

        record.effectiveMinCount  = eval.effectiveMinVerifierCount;
        record.effectiveMinWeight = eval.effectiveMinTotalWeight;
        record.effectiveMinConf   = eval.effectiveMinConfidenceBps;

        // Map ParticipationThresholdTypes outcome to named TerminalState
        if (eval.outcome == ParticipationThresholdTypes.ClaimOutcome.VERIFIED_TRUE) {
            record.state    = TerminalState.VERIFIED_TRUE;
            record.economic = EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS;

        } else if (eval.outcome == ParticipationThresholdTypes.ClaimOutcome.VERIFIED_FALSE) {
            record.state    = TerminalState.VERIFIED_FALSE;
            record.economic = EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS;

        } else {
            // INCONCLUSIVE -- distinguish specific reason for downstream routing
            record.economic = EconomicOutcome.FULL_REFUND;

            if (eval.reason == ParticipationThresholdTypes.InconclusiveReason.ZERO_PARTICIPATION) {
                record.state = TerminalState.INCONCLUSIVE_ZERO;
            } else if (eval.reason == ParticipationThresholdTypes.InconclusiveReason.TIE) {
                record.state = TerminalState.INCONCLUSIVE_TIE;
            } else if (eval.reason == ParticipationThresholdTypes.InconclusiveReason.INSUFFICIENT_CONFIDENCE) {
                record.state = TerminalState.INCONCLUSIVE_LOW_CONFIDENCE;
            } else {
                // INSUFFICIENT_VERIFIER_COUNT or INSUFFICIENT_TOTAL_WEIGHT
                record.state = TerminalState.INCONCLUSIVE_INSUFFICIENT;
            }
        }

        record.isProvisional = !challengeWindowElapsed;
    }

    // =========================================================================
    // Guard
    // =========================================================================

    /**
     * @notice Revert if the record is still provisional (challenge window open).
     * @dev Settlement and reward modules MUST call this before disbursing funds.
     */
    function assertFinal(FinalizationRecord memory record) internal pure {
        if (record.isProvisional) revert ProvisionalNotFinal();
    }

    // =========================================================================
    // View helpers
    // =========================================================================

    /// @notice True iff the terminal state is conclusive (VERIFIED_TRUE or VERIFIED_FALSE).
    function isConclusive(TerminalState state) internal pure returns (bool) {
        return state == TerminalState.VERIFIED_TRUE ||
               state == TerminalState.VERIFIED_FALSE;
    }

    /// @notice True iff the economic outcome is FULL_REFUND.
    function isFullRefund(EconomicOutcome economic) internal pure returns (bool) {
        return economic == EconomicOutcome.FULL_REFUND;
    }

    /**
     * @notice Compute confidence bps using the canonical frozen denominator.
     * @param winningWeight Weight of the winning side.
     * @param totalWeight   Sum of both sides.
     * @return bps Confidence in basis points (floor division, 0 when total == 0).
     */
    function computeConfidenceBps(
        uint256 winningWeight,
        uint256 totalWeight
    ) internal pure returns (uint256 bps) {
        if (totalWeight == 0) return 0;
        if (winningWeight > totalWeight) {
            revert ParticipationConfidenceRules.WinningWeightExceedsTotal(winningWeight, totalWeight);
        }
        return Math.mulDiv(winningWeight, ParticipationThresholdTypes.BPS_DENOMINATOR, totalWeight);
    }
}
