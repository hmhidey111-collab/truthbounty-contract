// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IVerifierAssignment
/// @notice PREWAVE-SC-083 assignment uniqueness + eligibility surface.
interface IVerifierAssignment {
    event VerifierAssigned(
        uint256 indexed roundId,
        uint256 indexed claimId,
        address indexed verifier,
        uint256 stake,
        uint256 eligibilitySnapshotId,
        uint256 reputationScore,
        uint64 assignedAt,
        uint256 assignmentIndex
    );

    error ZeroVerifier();
    error ZeroClaimId();
    error DuplicateAssignment(uint256 roundId, address verifier);
    error IneligibleReputation(address verifier, uint256 score, uint256 minimum);
    error StaleEligibilitySnapshot(uint256 snapshotId, uint256 expiresAt, uint256 nowTs);
    error SelfClaimConflict(uint256 claimId, address account);
    error CapacityExceeded(uint256 roundId, uint256 capacity);
    error AssignmentRoundClosed(uint256 roundId);
    error InvalidCapacity();
    error RoundAlreadyOpened(uint256 roundId);
}
