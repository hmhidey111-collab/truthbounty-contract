// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Shared value types used by the canonical V2 module interfaces.
/// @dev Amounts are expressed in the smallest unit of the relevant asset unless a field explicitly says basis points or seconds.
interface IV2Types {
    /// @notice Lifecycle state used by the claim state machine.
    enum ClaimState { None, VerificationOpen, ChallengeWindow, AwaitingSettlement, Disputed, Finalized }

    /// @notice Persisted claim status exposed by claim storage implementations.
    enum ClaimStatus { NONE, OPEN, VERIFIED, SETTLED, DISPUTED, REJECTED, CANCELLED }

    /// @notice Evidence acceptance state.
    enum EvidenceStatus { NONE, SUBMITTED, ACCEPTED, REJECTED, REVOKED }

    /// @notice Dispute state.
    enum DisputeStatus { NONE, OPEN, RESOLVED, ESCALATED, CANCELLED }

    /// @notice Settlement queue and execution state.
    enum SettlementStatus { NONE, PENDING, EXECUTED, BLOCKED, REFUNDED }

    /// @notice Named accounting buckets for stake vault locks.
    enum LockCategory { NONE, VERIFIER_PRINCIPAL, CHALLENGE_BOND, BOUNTY_ESCROW, SETTLEMENT_ALLOCATION }

    /// @notice Outcome of a claim-round settlement, used to enforce idempotent lock transitions.
    enum SettlementOutcome { NONE, CONCLUDED, REFUNDED, CARRIED_FORWARD, ROLLED_OVER, UNLOCKED }

    /// @notice Canonical claim record returned by claim modules.
    struct Claim {
        /// @dev Monotonic claim identifier.
        uint256 id;
        /// @dev Account that created the claim.
        address claimant;
        /// @dev Protocol-defined subject identifier, normally a commitment.
        bytes32 subject;
        /// @dev Reward amount in the claim asset's smallest unit.
        uint256 reward;
        /// @dev Unix timestamp in seconds.
        uint64 createdAt;
        /// @dev Persisted lifecycle status.
        ClaimStatus status;
    }

    /// @notice Evidence record exposed to consumers.
    struct Evidence {
        /// @dev Deterministic evidence identifier.
        uint256 id;
        /// @dev Claim to which the evidence belongs.
        uint256 claimId;
        /// @dev Account that submitted the commitment.
        address submitter;
        /// @dev Digest of off-chain evidence content.
        bytes32 contentHash;
        /// @dev Unix timestamp in seconds.
        uint64 submittedAt;
        /// @dev Current acceptance state.
        EvidenceStatus status;
    }

    /// @notice Verification record exposed to consumers.
    struct Verification {
        /// @dev Verification identifier.
        uint256 id;
        /// @dev Claim being verified.
        uint256 claimId;
        /// @dev Verifier account.
        address verifier;
        /// @dev True for support, false for opposition.
        bool supportsClaim;
        /// @dev Stake weight committed for this verification, in asset base units.
        uint256 stake;
        /// @dev Unix timestamp in seconds.
        uint64 submittedAt;
    }

    /// @notice Dispute record exposed to consumers.
    struct Dispute {
        /// @dev Dispute identifier.
        uint256 id;
        /// @dev Claim under dispute.
        uint256 claimId;
        /// @dev Account that opened the dispute.
        address opener;
        /// @dev Digest of the dispute reason.
        bytes32 reasonHash;
        /// @dev Unix timestamp in seconds.
        uint64 openedAt;
        /// @dev Current dispute state.
        DisputeStatus status;
    }

    /// @notice Settlement record exposed to consumers.
    struct Settlement {
        /// @dev Claim whose settlement is represented.
        uint256 claimId;
        /// @dev Account entitled to the net settlement.
        address recipient;
        /// @dev Gross amount before fees, in asset base units.
        uint256 grossAmount;
        /// @dev Protocol fee in asset base units; net is gross minus fee.
        uint256 fee;
        /// @dev Earliest Unix timestamp at which execution may occur.
        uint64 executableAt;
        /// @dev Current settlement state.
        SettlementStatus status;
    }
}
