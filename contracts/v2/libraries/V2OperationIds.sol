// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title V2OperationIds
/// @notice Stub for canonical operation identifiers used by V2Scopes.
/// @dev This is a minimal placeholder to allow compilation. The full operation
///      identifier matrix is maintained in the protocol's governance documentation.
library V2OperationIds {
    bytes32 public constant CLAIM_CREATION = keccak256("claim_creation");
    bytes32 public constant STAKING = keccak256("staking");
    bytes32 public constant WITHDRAWAL = keccak256("withdrawal");
    bytes32 public constant VERIFICATION_SUBMISSION = keccak256("verification_submission");
    bytes32 public constant REWARD_DISTRIBUTION = keccak256("reward_distribution");
    bytes32 public constant TREASURY_TRANSFER = keccak256("treasury_transfer");
    bytes32 public constant GOVERNANCE_RECOVERY = keccak256("governance_recovery");
}
