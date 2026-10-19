// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ProtocolExecutionBounds
 * @notice Canonical V2 participant, page, and loop bounds (V2-SC-038).
 * @dev Single source of truth for maximum configuration used in gas benchmarking
 *      and denial-of-service analysis. Module-local constants should match these
 *      values or document intentional divergence.
 */
library ProtocolExecutionBounds {
    /// @notice Maximum verifications aggregated per claim (VerificationAggregation).
    uint256 internal constant MAX_VERIFIERS_PER_CLAIM = 200;

    /// @notice Maximum evidence attachments per claim (EvidenceManager).
    uint256 internal constant MAX_EVIDENCE_PER_CLAIM = 100;

    /// @notice Maximum assets allowed in one published parameter version.
    uint256 internal constant MAX_SUPPORTED_ASSETS = 16;

    /// @notice Maximum treasury batch payout rows (TruthBountyClaims).
    uint256 internal constant MAX_SETTLEMENT_BATCH_SIZE = 200;

    /// @notice Maximum reward distribution batch size (RewardEngine).
    uint256 internal constant MAX_REWARD_BATCH_SIZE = 100;

    /// @notice Maximum tokenomics distribution batch size.
    uint256 internal constant MAX_TOKENOMICS_BATCH_SIZE = 50;

    /// @notice Maximum insurance payout page size.
    uint256 internal constant MAX_INSURANCE_PAGE_SIZE = 200;

    /// @notice Maximum claim statement length in bytes (ClaimRegistry).
    uint256 internal constant MAX_CLAIM_STATEMENT_BYTES = 2000;

    /// @notice Maximum evidence CID length in bytes (ClaimRegistry / EvidenceManager).
    uint256 internal constant MAX_EVIDENCE_CID_BYTES = 512;

    /// @notice Block gas limit reference used for budget sanity checks (30M post-merge mainnet).
    uint256 internal constant REFERENCE_BLOCK_GAS_LIMIT = 30_000_000;

    /// @notice Recommended maximum gas for a single critical-path transaction at max config.
    uint256 internal constant RECOMMENDED_TX_GAS_CEILING = 12_000_000;

    /// @notice Maximum claim creations per account inside one spam window (V2-SC-105).
    uint256 internal constant MAX_CLAIMS_PER_ACCOUNT_WINDOW = 10;

    /// @notice Sliding window length for claim-creation rate limiting (V2-SC-105).
    uint256 internal constant CLAIM_SPAM_WINDOW_SECONDS = 1 hours;

    /// @notice Maximum concurrently open (non-terminal) claims per creator (V2-SC-105).
    uint256 internal constant MAX_OPEN_CLAIMS_PER_CREATOR = 25;

    /// @notice Default minimum verifier stake to reject dust griefing (V2-SC-105).
    uint256 internal constant DEFAULT_MIN_STKE_AMOUNT = 1 ether;

    /// @notice Default minimum claim bounty / reward (V2-SC-105).
    uint256 internal constant DEFAULT_MIN_BOUNTY_AMOUNT = 1 ether;

    // -------------------------------------------------------------------------
    // Stress-test amplification metric bounds (PREWAVE-SC-024)
    // -------------------------------------------------------------------------
    /// @notice Authoritative unit for amplification ratios emitted in events.
    ///         Amplification ratios are expressed in basis points (1 BPS = 0.01%).
    ///         10000 BPS = 1.00x (100%). The canonical event field is
    ///         `uint64 maxAmplificationRatioBps`.
    /// @notice Maximum amplification ratio in BPS that may be emitted.
    ///          Chosen so that `totalOperationsExecuted * MAX_AMP' fits in uint64
    ///          without overflow for any realistic stress run.
    uint64 internal constant MAX_AMP' = 10000000; // 100000.00x ceiling

    /// @notice Numerator denominator for the amplification ratio in BPS.
    ///          ratio_bps = (observed * 10000) / baseline
    uint64 internal constant AMP_BPS_DENOMINATOR = 10000;

    /// @notice Maximum number of operations that may be counted in a stress run.
    ///          Bounds the numerator of the amplification ratio: observed <= MAX_OPS.
    uint64 internal constant MAX_STRESS_OPS = 1_000_000_000;

    /// @notice Maximum value of the `uint64` x-axis of the amplification metric.
    ///          This is the largest value that may be emitted as `maxAmplificationRatioBps`.
    uint64 internal constant MAX_AMP'_BPS = MAX_AMP';

    /// @notice Returns true if `value` is a valid amplification ratio in BPS.
    function isValidAmpBps(uint64 value) internal pure returns (bool) {
        return value <= MAX_AMP'_BPS;
    }

    /// @notice Computes the amplification ratio in BPS from observed and baseline counts.
    ///          Reverts if the result would exceed `MAX_AMP'_BPS` or if `baseline` is zero.
    function computeAmpBps(uint64 observed, uint64 baseline) internal pure returns (uint64) {
        require(baseline > 0, "PROTOCOL: baseline zero");
        require(observed <= MAX_STRESS_OPS, "PROTOCOL: observed out of bounds");
        // uint256 intermediate avoids overflow on `observed * AMP_BPS_DENOMINATOR`.
        uint256 raw = (uint256(observed) * uint256(AMP_BPS_DENOMINATOR)) / uint256(baseline);
        require(raw <= uint256(MAX_AMP'_BPS), "PROTOCOL: amp exceeds max");
        return uint64(raw);
    }
}
