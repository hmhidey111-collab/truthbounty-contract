// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title IVerificationSource
 * @notice Minimal read interface used to pull frozen vote data from the
 *         verification contract (TruthBountyWeighted).
 * @dev Keeping the interface slim avoids coupling the aggregator to the full
 *      settlement contract and leaves room for alternate sources in the future.
 */
interface IVerificationSource {
    function getClaimVoterCount(uint256 claimId) external view returns (uint256);
    function getClaimVoterAt(uint256 claimId, uint256 index) external view returns (address);
    function getVoteData(uint256 claimId, address verifier)
        external
        view
        returns (bool voted, bool support, uint256 effectiveStake);
}

/**
 * @title VerificationAggregator
 * @notice Deterministic weighted consensus engine for TruthBounty V2 (SC-005).
 *
 * Aggregates the frozen effectiveStake values recorded at vote time and folds
 * them into trueWeight / falseWeight totals. The canonical result is stored
 * on-chain so every downstream module (settlement, reputation, slashing,
 * disputes) reads the same outcome.
 *
 * Design principles
 * -----------------
 * - Pure integer arithmetic. No floats, no division before multiplication.
 * - Order-independent iteration: outcome is identical no matter how
 *   verifiers appear in the source's voter list.
 * - Extensible weighting. The current formula is weight = effectiveStake
 *   (already reputation-weighted by the source). Future versions can layer
 *   quadratic / committee / zk multipliers without changing storage.
 * - Separation of concerns. This contract only computes consensus; it never
 *   transfers funds, slashes stakes, or modifies claim state.
 */
contract VerificationAggregator is AccessControl {
    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ============ Constants ============

    /// @notice Basis-point denominator for confidence (0–10 000).
    uint256 public constant BPS = 10_000;

    // ============ Types ============

    enum ClaimOutcome {
        VERIFIED_TRUE,
        VERIFIED_FALSE,
        INCONCLUSIVE
    }

    struct AggregationResult {
        ClaimOutcome outcome;
        uint256 trueWeight;
        uint256 falseWeight;
        uint256 totalWeight;
        uint256 confidence; // basis points, 0–10 000
    }

    // ============ Protocol thresholds (governance-adjustable) ============

    /// @notice Minimum number of distinct verifications required.
    uint256 public minVerificationCount;

    /// @notice Minimum total weighted stake required.
    uint256 public minTotalWeight;

    /// @notice Minimum winning confidence required (basis points).
    uint256 public minConfidenceBps;

    // ============ Storage ============

    /// @notice Source contract that holds vote data (TruthBountyWeighted).
    IVerificationSource public verificationSource;

    /// @notice Cached aggregation results, keyed by claimId.
    mapping(uint256 => AggregationResult) private _results;

    /// @notice Whether aggregateClaim() has been called for a claimId.
    mapping(uint256 => bool) private _aggregated;

    // ============ Events ============

    event ClaimAggregated(
        uint256 indexed claimId,
        ClaimOutcome outcome,
        uint256 confidence
    );

    event VerificationSourceUpdated(address indexed oldSource, address indexed newSource);
    event ThresholdsUpdated(uint256 minCount, uint256 minWeight, uint256 minConfidenceBps);

    // ============ Errors ============

    error ZeroAddress();
    error AlreadyAggregated(uint256 claimId);
    error ThresholdNotMet(string reason);
    error NotAggregated(uint256 claimId);
    error WinningWeightExceedsTotal(uint256 winningWeight, uint256 total);

    // ============ Constructor ============

    constructor(
        address _verificationSource,
        address _admin,
        uint256 _minVerificationCount,
        uint256 _minTotalWeight,
        uint256 _minConfidenceBps
    ) {
        if (_verificationSource == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        require(_minConfidenceBps <= BPS, "Confidence threshold exceeds 100%");

        verificationSource = IVerificationSource(_verificationSource);

        minVerificationCount = _minVerificationCount;
        minTotalWeight = _minTotalWeight;
        minConfidenceBps = _minConfidenceBps;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
    }

    // ============ Core aggregation ============

    /**
     * @notice Aggregate all verifications for a claim and store the result.
     * @dev Can only be called once per claimId. Reverts if minimum participation
     *      thresholds are not met. The caller is responsible for ensuring the
     *      verification window is closed before calling.
     * @param claimId The claim to aggregate.
     */
    function aggregateClaim(uint256 claimId) external {
        if (_aggregated[claimId]) revert AlreadyAggregated(claimId);

        (uint256 trueWeight, uint256 falseWeight, uint256 count) = calculateWeights(claimId);
        uint256 totalWeight = trueWeight + falseWeight;

        // Enforce minimum participation thresholds
        if (count < minVerificationCount) {
            revert ThresholdNotMet("Insufficient verification count");
        }
        if (totalWeight < minTotalWeight) {
            revert ThresholdNotMet("Insufficient total weight");
        }

        (ClaimOutcome outcome, uint256 confidence) = _resolveOutcome(trueWeight, falseWeight, totalWeight);

        if (outcome != ClaimOutcome.INCONCLUSIVE && confidence < minConfidenceBps) {
            revert ThresholdNotMet("Insufficient confidence");
        }

        _results[claimId] = AggregationResult({
            outcome: outcome,
            trueWeight: trueWeight,
            falseWeight: falseWeight,
            totalWeight: totalWeight,
            confidence: confidence
        });
        _aggregated[claimId] = true;

        emit ClaimAggregated(claimId, outcome, confidence);
    }

    /**
     * @notice Return the stored aggregation result for a claim.
     * @param claimId The claim to query.
     */
    function getAggregation(uint256 claimId) external view returns (AggregationResult memory) {
        if (!_aggregated[claimId]) revert NotAggregated(claimId);
        return _results[claimId];
    }

    /**
     * @notice Calculate confidence for a hypothetical weight distribution.
     * @dev Returns 0 when total is 0 (avoids division by zero).
     * @param winningWeight The winning side's total weight.
     * @param total The combined weight of both sides.
     * @return Confidence in basis points (0–10 000).
     */
    function calculateConfidence(uint256 winningWeight, uint256 total) public pure returns (uint256) {
        if (winningWeight > total) revert WinningWeightExceedsTotal(winningWeight, total);
        if (total == 0) return 0;
        return Math.mulDiv(winningWeight, BPS, total);
    }

    /**
     * @notice Iterate all verifications for a claim and compute weight totals.
     * @dev Reads effectiveStake directly from the source, which already
     *      incorporates the reputation multiplier. The loop is order-independent:
     *      trueWeight and falseWeight are simple accumulators.
     * @param claimId The claim to inspect.
     * @return trueWeight  Aggregate weight of TRUE verifications.
     * @return falseWeight Aggregate weight of FALSE verifications.
     * @return count       Total number of verifications found.
     */
    function calculateWeights(uint256 claimId)
        public
        view
        returns (uint256 trueWeight, uint256 falseWeight, uint256 count)
    {
        uint256 voterCount = verificationSource.getClaimVoterCount(claimId);

        for (uint256 i = 0; i < voterCount; i++) {
            address verifier = verificationSource.getClaimVoterAt(claimId, i);
            (bool voted, bool support, uint256 effectiveStake) =
                verificationSource.getVoteData(claimId, verifier);

            if (!voted) continue;

            // weight = effectiveStake (= raw stake * reputation multiplier, already capped).
            // Future versions can layer additional multipliers here before accumulating.
            if (support) {
                trueWeight += effectiveStake;
            } else {
                falseWeight += effectiveStake;
            }
            count++;
        }
    }

    // ============ Internal helpers ============

    /**
     * @notice Resolve a canonical outcome from weight totals.
     * @dev Ties and zero-weight scenarios always return INCONCLUSIVE — no randomness.
     */
    function _resolveOutcome(uint256 trueWeight, uint256 falseWeight, uint256 totalWeight)
        internal
        pure
        returns (ClaimOutcome outcome, uint256 confidence)
    {
        if (totalWeight == 0 || trueWeight == falseWeight) {
            return (ClaimOutcome.INCONCLUSIVE, 0);
        }

        if (trueWeight > falseWeight) {
            confidence = calculateConfidence(trueWeight, totalWeight);
            return (ClaimOutcome.VERIFIED_TRUE, confidence);
        } else {
            confidence = calculateConfidence(falseWeight, totalWeight);
            return (ClaimOutcome.VERIFIED_FALSE, confidence);
        }
    }

    // ============ Admin ============

    /**
     * @notice Update the verification source contract.
     * @param _newSource New IVerificationSource address.
     */
    function setVerificationSource(address _newSource) external onlyRole(ADMIN_ROLE) {
        if (_newSource == address(0)) revert ZeroAddress();
        address old = address(verificationSource);
        verificationSource = IVerificationSource(_newSource);
        emit VerificationSourceUpdated(old, _newSource);
    }

    /**
     * @notice Update minimum participation thresholds.
     * @param _minCount     Minimum verification count (0 = no minimum).
     * @param _minWeight    Minimum total weight (0 = no minimum).
     * @param _minConfBps   Minimum winning confidence in basis points (0 = no minimum).
     */
    function setThresholds(
        uint256 _minCount,
        uint256 _minWeight,
        uint256 _minConfBps
    ) external onlyRole(ADMIN_ROLE) {
        require(_minConfBps <= BPS, "Confidence threshold exceeds 100%");
        minVerificationCount = _minCount;
        minTotalWeight = _minWeight;
        minConfidenceBps = _minConfBps;
        emit ThresholdsUpdated(_minCount, _minWeight, _minConfBps);
    }

    // ============ View helpers ============

    /**
     * @notice Whether aggregateClaim() has been called for a claimId.
     */
    function isAggregated(uint256 claimId) external view returns (bool) {
        return _aggregated[claimId];
    }
}
