// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ICriticalPathGasBudgets
 * @notice Critical-path operations benchmarked under V2-SC-038 and V2-SC-072.
 * @dev Amplification metrics are expressed in basis points (bps), where 10_000 bps == 1.0x.
 */
interface ICriticalPathGasBudgets {
    enum Operation {
        CLAIM_CREATION,
        EVIDENCE_ATTACHMENT,
        VERIFICATION_VOTE,
        AGGREGATION,
        PROVISIONAL_SETTLEMENT,
        CHALLENGE_OPEN,
        APPEAL_SETTLEMENT,
        FINALIZATION,
        WITHDRAWAL,
        REWARD_CLAIM,
        GOVERNANCE_CONFIGURATION,
        EMERGENCY_PAUSE
    }

    /**
     * @notice Canonical amplification metric units and bounds.
     * @dev maxAmplificationRatioBps is expressed in basis points (bps).
     *      - 0 bps denotes "no amplification observed" (zero case).
     *      - 10_000 bps denotes nominal 1.0x amplification.
     *      - MAX_AMPLIFICATION_RATIO_BPS is the inclusive upper bound.
     *      Values strictly greater than MAX_AMPLIFICATION_RATIO_BPS are
     *      considered impossible and MUST revert before event emission.
     */
    uint256 constant BPS_DENOMINATOR = 10_000;
    uint256 constant MAX_AMPLIFICATION_RATIO_BPS = 1_000_000;

    /**
     * @notice Emitted when a stress-test run completes.
     * @param maxAmplificationRatioBps Maximum observed amplification ratio, in bps.
     */
    event StressTestCompleted(uint256 indexed maxAmplificationRatioBps);

    struct GasBudget {
        Operation operation;
        uint256 maxGasAtMaxConfig;
        string boundDescription;
    }

    function getBudget(Operation operation) external view returns (uint256 maxGasAtMaxConfig, string memory boundDescription);

    function budgetCount() external pure returns (uint256);

    /**
     * @notice Validates an amplification ratio against documented units and bounds.
     * @dev MUST revert if `ratioBps` exceeds MAX_AMPLIFICATION_RATIO_BPS.
     * @param ratioBps Amplification ratio in basis points.
     * @return normalizedBps The validated ratio in basis points.
     */
    function validateAmplificationRatioBps(uint256 ratioBps) external pure returns (uint256 normalizedBps);
}
