// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EmergencyPauseOrdering
 * @notice Authoritative pause dependency matrix for TruthBounty V2 (V2-SC-117 / #503).
 * @dev Pure library: no storage, no external calls, no zero-address dependencies.
 *
 * \## Pause levels (must match EmergencyController)
 * | Level | Name      | Effect |
 * |-------|-----------|--------|
 * | 0     | NORMAL    | Full protocol operation |
 * | 1     | HIGH_RISK | Pause risk-increasing commitments (claims, staking, verification) |
 * | 2     | FINANCIAL | Also pause reward/treasury/withdrawal egress |
 * | 3     | SHUTDOWN  | Only governance recovery mutations remain |
 *
 * \## Recovery order after lift to NORMAL
 * 1. inventory_risk_surfaces
 * 2. inventory_financial_surfaces
 * 3. finalise_recovery
 *
 * Operation id hashes match the prior inline keccak256 strings in EmergencyController
 * so existing EmergencyProtected callers keep identical gates.
 */
library EmergencyPauseOrdering {
    uint8 internal constant LEVEL_NORMAL = 0;
    uint8 internal constant LEVEL_HIGH_RISK = 1;
    uint8 internal constant LEVEL_FINANCIAL = 2;
    uint8 internal constant LEVEL_SHUTDOWN = 3;
    uint8 internal constant MAX_PAUSE_LEVEL = 3;
    uint8 internal constant MAX_RECOVERY_STEP = 3;

    bytes32 internal constant OP_CLAIM_CREATION = keccak256("claim_creation");
    bytes32 internal constant OP_STAKING = keccak256("staking");
    bytes32 internal constant OP_VERIFICATION_SUBMISSION = keccak256("verification_submission");
    bytes32 internal constant OP_REWARD_DISTRIBUTION = keccak256("reward_distribution");
    bytes32 internal constant OP_TREASURY_TRANSFER = keccak256("treasury_transfer");
    bytes32 internal constant OP_WITHDRAWAL = keccak256("withdrawal");
    bytes32 internal constant OP_GOVERNANCE_RECOVERY = keccak256("governance_recovery");
    /// @dev Opt-in pull of already-settled user value; allowed at L1/L2, blocked at L3.
    bytes32 internal constant OP_PULL_SETTLED_CLAIM = keccak256("pull_settled_claim");

    error InvalidPauseLevel(uint8 level);
    error InvalidRecoveryStep(uint8 step);

    /**
     * @notice Whether `operationType` is allowed at pause `level`.
     * @dev Fail-closed at SHUTDOWN except GOVERNANCE_RECOVERY.
     *      Unknown ops are allowed below SHUTDOWN (compatibility with prior controller).
     */
    function isOperationAllowed(uint8 level, bytes32 operationType)
        internal
        pure
        returns (bool)
    {
        if (level > MAX_PAUSE_LEVEL) revert InvalidPauseLevel(level);
        if (level == LEVEL_NORMAL) return true;

        if (level == LEVEL_SHUTDOWN) {
            return operationType == OP_GOVERNANCE_RECOVERY;
        }

        if (level >= LEVEL_FINANCIAL) {
            if (
                operationType == OP_REWARD_DISTRIBUTION ||
                operationType == OP_TREASURY_TRANSFER ||
                operationType == OP_WITHDRAWAL
            ) {
                return false;
            }
        }

        if (level >= LEVEL_HIGH_RISK) {
            if (
                operationType == OP_CLAIM_CREATION ||
                operationType == OP_STAKING ||
                operationType == OP_VERIFICATION_SUBMISSION
            ) {
                return false;
            }
        }

        return true;
    }

    /// @notice Operations that pause together at HIGH_RISK (L1+).
    function highRiskCohort() internal pure returns (bytes32[3] memory ops) {
        ops[0] = OP_CLAIM_CREATION;
        ops[1] = OP_STAKING;
        ops[2] = OP_VERIFICATION_SUBMISSION;
    }

    /// @notice Additional operations that pause together at FINANCIAL (L2+).
    function financialCohort() internal pure returns (bytes32[3] memory ops) {
        ops[0] = OP_REWARD_DISTRIBUTION;
        ops[1] = OP_TREASURY_TRANSFER;
        ops[2] = OP_WITHDRAWAL;
    }

    function requireValidRecoveryStep(uint8 nextStep) internal pure {
        if (nextStep == 0 || nextStep > MAX_RECOVERY_STEP) {
            revert InvalidRecoveryStep(nextStep);
        }
    }

    function recoveryStepLabel(uint8 step) internal pure returns (string memory) {
        if (step == 1) return "inventory_risk_surfaces";
        if (step == 2) return "inventory_financial_surfaces";
        if (step == 3) return "finalise_recovery";
        revert InvalidRecoveryStep(step);
    }
}
