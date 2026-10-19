// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IVerifierAssignment.sol";

/**
 * @title VerifierAssignmentGuard
 * @notice PREWAVE-SC-083: unique per-round assignment, snapshot eligibility, fail-closed conflicts.
 * @dev Does not custody stake or alter VerificationRoundManager / VerificationSubmission gates.
 */
contract VerifierAssignmentGuard is AccessControl, Pausable, ReentrancyGuard, IVerifierAssignment {
    bytes32 public constant ASSIGNER_ROLE = keccak256("ASSIGNER_ROLE");

    struct EligibilitySnapshot {
        uint256 expiresAt;
        bool exists;
    }

    struct AssignmentRecord {
        address verifier;
        uint256 stake;
        uint256 eligibilitySnapshotId;
        uint256 reputationScore;
        uint64 assignedAt;
    }

    struct RoundAssignmentState {
        uint256 claimId;
        address claimAuthor;
        uint256 capacity;
        bool closed;
        uint256 count;
    }

    mapping(uint256 => RoundAssignmentState) private _rounds;
    mapping(uint256 => mapping(address => bool)) private _assigned;
    mapping(uint256 => AssignmentRecord[]) private _records;
    mapping(uint256 => EligibilitySnapshot) private _snapshots;
    mapping(uint256 => mapping(address => uint256)) private _snapshotScore;

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ASSIGNER_ROLE, admin);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function registerEligibilitySnapshot(
        uint256 snapshotId,
        uint256 expiresAt,
        address[] calldata verifiers,
        uint256[] calldata scores
    ) external onlyRole(ASSIGNER_ROLE) whenNotPaused {
        if (snapshotId == 0 || expiresAt <= block.timestamp) {
            revert StaleEligibilitySnapshot(snapshotId, expiresAt, block.timestamp);
        }
        if (verifiers.length != scores.length) revert InvalidCapacity();

        _snapshots[snapshotId] = EligibilitySnapshot({expiresAt: expiresAt, exists: true});
        for (uint256 i = 0; i < verifiers.length; ) {
            _snapshotScore[snapshotId][verifiers[i]] = scores[i];
            unchecked {
                ++i;
            }
        }
    }

    function openAssignmentRound(
        uint256 roundId,
        uint256 claimId,
        address claimAuthor,
        uint256 capacity
    ) external onlyRole(ASSIGNER_ROLE) whenNotPaused {
        if (claimId == 0) revert ZeroClaimId();
        if (capacity == 0) revert InvalidCapacity();
        if (_rounds[roundId].claimId != 0) revert RoundAlreadyOpened(roundId);

        _rounds[roundId] = RoundAssignmentState({
            claimId: claimId,
            claimAuthor: claimAuthor,
            capacity: capacity,
            closed: false,
            count: 0
        });
    }

    function closeAssignmentRound(uint256 roundId) external onlyRole(ASSIGNER_ROLE) whenNotPaused {
        _rounds[roundId].closed = true;
    }

    function assignVerifier(
        uint256 roundId,
        address verifier,
        uint256 stake,
        uint256 eligibilitySnapshotId,
        uint256 minReputationScore
    ) external onlyRole(ASSIGNER_ROLE) whenNotPaused nonReentrant returns (uint256 assignmentIndex) {
        if (verifier == address(0)) revert ZeroVerifier();

        RoundAssignmentState storage st = _rounds[roundId];
        if (st.claimId == 0) revert ZeroClaimId();
        if (st.closed) revert AssignmentRoundClosed(roundId);
        if (_assigned[roundId][verifier]) revert DuplicateAssignment(roundId, verifier);
        if (st.count >= st.capacity) revert CapacityExceeded(roundId, st.capacity);
        if (verifier == st.claimAuthor) revert SelfClaimConflict(st.claimId, verifier);

        EligibilitySnapshot memory snap = _snapshots[eligibilitySnapshotId];
        if (!snap.exists || block.timestamp > snap.expiresAt) {
            revert StaleEligibilitySnapshot(eligibilitySnapshotId, snap.expiresAt, block.timestamp);
        }

        uint256 score = _snapshotScore[eligibilitySnapshotId][verifier];
        if (score < minReputationScore) {
            revert IneligibleReputation(verifier, score, minReputationScore);
        }

        // Effects only after all checks (fail closed — no partial assignment).
        _assigned[roundId][verifier] = true;
        assignmentIndex = st.count;
        unchecked {
            st.count = assignmentIndex + 1;
        }

        _records[roundId].push(
            AssignmentRecord({
                verifier: verifier,
                stake: stake,
                eligibilitySnapshotId: eligibilitySnapshotId,
                reputationScore: score,
                assignedAt: uint64(block.timestamp)
            })
        );

        emit VerifierAssigned(
            roundId,
            st.claimId,
            verifier,
            stake,
            eligibilitySnapshotId,
            score,
            uint64(block.timestamp),
            assignmentIndex
        );
    }

    function isAssigned(uint256 roundId, address verifier) external view returns (bool) {
        return _assigned[roundId][verifier];
    }

    function assignmentCount(uint256 roundId) external view returns (uint256) {
        return _rounds[roundId].count;
    }

    function getAssignment(uint256 roundId, uint256 index) external view returns (AssignmentRecord memory) {
        return _records[roundId][index];
    }
}
