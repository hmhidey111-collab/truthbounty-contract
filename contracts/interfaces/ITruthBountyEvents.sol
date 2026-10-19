
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ITruthBountyEvents
/// @notice Canonical, versioned event surface for TruthBounty protocol indexers (Specification §20).
/// @dev Events are public protocol APIs. Implementations should emit events only
///      after the corresponding state transition succeeds. Schema version 1 is
///      represented by the literal value `1` in each event's `version` field.
///      Every event includes a block timestamp and schema version identifier.
interface ITruthBountyEvents {
    // -------------------------------------------------------------------------
    // 0. Stress-Test Amplification Metrics
    // -------------------------------------------------------------------------
    /// @notice Emitted when a stress-test run completes.
    /// @dev `maxAmplificationRatioBps` is expressed in basis points (1 bps = 0.01%),
    ///      bounded by `MAX_AMPLIFICATION_RATIO_BPS`. Values above the bound MUST
    ///      revert before emission. Zero is a valid, non-amplifying result.
    event StressTestCompleted(
        uint256 indexed runId,
        uint256 maxAmplificationRatioBps,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Upper bound for `StressTestCompleted.maxAmplificationRatioBps`.
    /// @dev 100_000 bps == 1000x amplification. Chosen to fit uint256 with no overflow.
    uint256 constant MAX_AMPLIFICATION_RATIO_BPS = 100_000;

    // -------------------------------------------------------------------------
    // 1. Claims
    // -------------------------------------------------------------------------
    /// @notice Emitted when a new claim is created and registered on-chain.
    event ClaimCreatedV1(
        uint256 indexed claimId,
        address indexed actor,
        bytes32 indexed metadataHash,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when claim metadata is updated before verification starts.
    event ClaimUpdatedV1(
        uint256 indexed claimId,
        address indexed actor,
        bytes32 indexed metadataHash,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a claim transitions to a new lifecycle status.
    event ClaimStatusTransitionedV1(
        uint256 indexed claimId,
        address indexed actor,
        uint8 oldStatus,
        uint8 newStatus,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when the consensus outcome of a claim is resolved.
    event ClaimResolvedV1(
        uint256 indexed claimId,
        address indexed actor,
        bool outcome,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when settlement and all financial distribution for a claim are finalized.
    event ClaimFinalizedV1(
        uint256 indexed claimId,
        address indexed actor,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 2. Evidence
    // -------------------------------------------------------------------------
    /// @notice Emitted when content-addressed evidence reference is attached to a claim.
    event EvidenceSubmittedV1(
        uint256 indexed claimId,
        uint256 indexed evidenceId,
        address indexed submitter,
        bytes32 evidenceHash,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when evidence submission is revoked or invalidated.
    event EvidenceRevokedV1(
        uint256 indexed claimId,
        uint256 indexed evidenceId,
        address indexed actor,
        bytes32 reasonHash,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a claim is closed to new evidence submissions.
    event ClaimClosedForEvidenceV1(
        uint256 indexed claimId,
        address indexed actor,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 3. Staking & Collateral
    // -------------------------------------------------------------------------
    /// @notice Emitted when verifier collateral is deposited into the protocol.
    event StakeDepositedV1(
        address indexed verifier,
        uint256 amount,
        uint256 newBalance,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when verifier stake is locked for a claim verification round.
    event StakeLockedV1(
        uint256 indexed claimId,
        address indexed verifier,
        uint256 round,
        uint256 amount,
        uint256 resultingActiveStake,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when verifier stake is unlocked after round settlement.
    event StakeUnlockedV1(
        uint256 indexed claimId,
        address indexed verifier,
        uint256 round,
        uint256 amount,
        uint256 resultingActiveStake,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when verifier collateral is withdrawn from the protocol.
    event StakeWithdrawnV1(
        address indexed verifier,
        uint256 amount,
        uint256 newBalance,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 4. Verification & Voting
    // -------------------------------------------------------------------------
    /// @notice Emitted when a verifier records a position and commits stake.
    event VerificationSubmittedV1(
        uint256 indexed claimId,
        address indexed verifier,
        bool support,
        uint256 stakeAmount,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a verification or claim is challenged.
    event VerificationChallengedV1(
        uint256 indexed claimId,
        address indexed challenger,
        bytes32 indexed reasonHash,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 5. Rounds
    // -------------------------------------------------------------------------
    /// @notice Emitted when a verification round starts for a claim.
    event RoundStartedV1(
        uint256 indexed claimId,
        uint256 indexed round,
        uint64 windowStart,
        uint64 windowEnd,
        uint256 minStake,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a verification round ends.
    event RoundEndedV1(
        uint256 indexed claimId,
        uint256 indexed round,
        uint256 totalWeightedFor,
        uint256 totalWeightedAgainst,
        uint256 participantCount,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 6. Outcomes & Aggregation
    // -------------------------------------------------------------------------
    /// @notice Emitted when weighted verification votes are aggregated into a consensus outcome.
    event OutcomeAggregatedV1(
        uint256 indexed claimId,
        uint256 indexed round,
        uint8 outcome,
        uint256 trueWeight,
        uint256 falseWeight,
        uint256 confidenceBps,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 7. Disputes
    // -------------------------------------------------------------------------
    /// @notice Emitted when a dispute is raised against a verification outcome.
    event DisputeRaisedV1(
        uint256 indexed claimId,
        uint256 indexed disputeId,
        address indexed challenger,
        uint256 bondAmount,
        bytes32 reasonHash,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a dispute is resolved by an authorized resolver.
    event DisputeResolvedV1(
        uint256 indexed claimId,
        uint256 indexed disputeId,
        address indexed resolver,
        uint8 ruling,
        uint8 resultingOutcome,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 8. Rewards
    // -------------------------------------------------------------------------
    /// @notice Emitted when a deterministic reward amount is calculated.
    event RewardCalculatedV1(
        bytes32 indexed calculationId,
        address indexed recipient,
        uint256 amount,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when reward funds are escrowed/reserved for a recipient.
    event RewardEscrowedV1(
        uint256 indexed claimId,
        address indexed recipient,
        uint256 amount,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when reserved reward funds are claimed by the recipient.
    event RewardClaimedV1(
        uint256 indexed claimId,
        address indexed recipient,
        uint256 amount,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when multiple reward allocations are claimed in batch.
    event BatchRewardClaimedV1(
        address indexed recipient,
        uint256 count,
        uint256 totalAmount,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 9. Slashing
    // -------------------------------------------------------------------------
    /// @notice Emitted when locked collateral is confiscated for an incorrect verdict or offence.
    event SlashExecutedV1(
        uint256 indexed claimId,
        address indexed verifier,
        bytes32 indexed reason,
        uint256 amount,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when losing verifiers are slashed in batch at claim settlement.
    event BatchSlashExecutedV1(
        uint256 indexed claimId,
        uint256 round,
        uint256 count,
        uint256 totalAmount,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 10. Withdrawals
    // -------------------------------------------------------------------------
    /// @notice Emitted when a large withdrawal is queued for timelocked verification.
    event WithdrawalQueuedV1(
        bytes32 indexed withdrawalId,
        address indexed actor,
        address indexed asset,
        uint256 amount,
        uint64 unlockTimestamp,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a queued withdrawal is executed after cooldown elapses.
    event WithdrawalExecutedV1(
        bytes32 indexed withdrawalId,
        address indexed actor,
        address indexed asset,
        uint256 amount,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a queued withdrawal request is cancelled.
    event WithdrawalCancelledV1(
        bytes32 indexed withdrawalId,
        address indexed actor,
        bytes32 indexed reasonHash,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 11. Treasury & Accounting
    // -------------------------------------------------------------------------
    /// @notice Emitted when external funds are deposited into a specific treasury account.
    event TreasuryDepositV1(
        bytes32 indexed operationId,
        uint8 indexed account,
        address indexed asset,
        uint256 amount,
        address sender,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when treasury-controlled value moves for a uniquely identified operation.
    event TreasuryTransferV1(
        bytes32 indexed operationId,
        address indexed token,
        address indexed recipient,
        uint256 amount,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when external funds are withdrawn from a treasury account.
    event TreasuryWithdrawalV1(
        bytes32 indexed operationId,
        uint8 indexed account,
        address indexed asset,
        address recipient,
        uint256 amount,
        address operator,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a periodic treasury account snapshot is recorded.
    event TreasurySnapshotRecordedV1(
        uint256 indexed snapshotId,
        uint256 totalAssets,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 12. Parameters & Configuration
    // -------------------------------------------------------------------------
    /// @notice Emitted when a protocol parameter value is updated by governance.
    event ParameterUpdatedV1(
        bytes32 indexed paramName,
        uint256 indexed parameterVersion,
        uint256 oldValue,
        uint256 newValue,
        uint64 effectiveAt,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a protocol address configuration is updated by governance.
    event AddressParameterUpdatedV1(
        bytes32 indexed paramName,
        uint256 indexed parameterVersion,
        address oldAddress,
        address newAddress,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a protocol fee schedule is updated.
    event FeeScheduleUpdatedV1(
        bytes32 indexed feeType,
        uint256 indexed parameterVersion,
        uint256 fixedAmount,
        uint256 basisPoints,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 13. Reputation Roots & Snapshots
    // -------------------------------------------------------------------------
    /// @notice Emitted when a Merkle root of reputation scores is published on-chain.
    event ReputationRootPublishedV1(
        uint256 indexed snapshotId,
        bytes32 indexed root,
        uint256 userCount,
        uint64 expiresAt,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when an individual verifier's reputation score is updated.
    event ReputationScoreUpdatedV1(
        address indexed verifier,
        uint256 oldScore,
        uint256 newScore,
        bytes32 indexed reasonHash,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when reputation decay is applied to a verifier.
    event ReputationDecayedV1(
        address indexed verifier,
        uint256 previousScore,
        uint256 newScore,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 14. Roles & Access Control
    // -------------------------------------------------------------------------
    /// @notice Emitted when a protocol role is granted to an account.
    event RoleGrantedV1(
        bytes32 indexed role,
        address indexed account,
        address indexed sender,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a protocol role is revoked from an account.
    event RoleRevokedV1(
        bytes32 indexed role,
        address indexed account,
        address indexed sender,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when the admin role controlling a role is updated.
    event RoleAdminChangedV1(
        bytes32 indexed role,
        bytes32 indexed previousAdminRole,
        bytes32 indexed newAdminRole,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 15. Emergency & Pauses
    // -------------------------------------------------------------------------
    /// @notice Emitted when emergency pause controls are activated.
    event EmergencyPauseActivatedV1(
        address indexed actor,
        bytes32 indexed reason,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when normal protocol operation is restored from emergency pause.
    event EmergencyPauseRecoveredV1(
        address indexed actor,
        uint64 timestamp,
        uint16 version
    );

    // -------------------------------------------------------------------------
    // 16. Upgrades & Governance
    // -------------------------------------------------------------------------
    /// @notice Emitted when a governance proposal is registered.
    event GovernanceProposalCreatedV1(
        bytes32 indexed proposalId,
        address indexed proposer,
        bytes32 indexed metadataHash,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when an approved governance proposal is executed.
    event GovernanceProposalExecutedV1(
        bytes32 indexed proposalId,
        address indexed executor,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when an upgradeable module is registered in the upgrade manager.
    event ModuleRegisteredV1(
        bytes32 indexed moduleId,
        address indexed implementation,
        uint64 major,
        uint64 minor,
        uint64 patch,
        bytes32 storageLayoutHash,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a contract upgrade proposal is submitted.
    event UpgradeProposedV1(
        uint256 indexed proposalId,
        bytes32 indexed moduleId,
        address indexed newImplementation,
        uint64 toMajor,
        uint64 toMinor,
        uint64 toPatch,
        bytes32 migrationHash,
        address proposer,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when a proposed contract upgrade is approved by governance.
    event UpgradeApprovedV1(
        uint256 indexed proposalId,
        bytes32 indexed moduleId,
        uint64 executeAfter,
        address indexed approver,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when an approved contract upgrade is executed.
    event UpgradeExecutedV1(
        uint256 indexed proposalId,
        bytes32 indexed moduleId,
        address oldImplementation,
        address newImplementation,
        address indexed executor,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when an emergency rollback to a known-good implementation is performed.
    event UpgradeRolledBackV1(
        bytes32 indexed moduleId,
        address oldImplementation,
        address restoredImplementation,
        bytes32 indexed reasonHash,
        address indexed guardian,
        uint64 timestamp,
        uint16 version
    );

    // Disputes
    /**
     * @notice Emitted when a dispute is opened against a provisional outcome.
     * @param claimId            Claim under dispute.
     * @param disputeId          Monotonic dispute identifier.
     * @param challenger         Address that opened the dispute.
     * @param challengedOutcome  Provisional outcome contended (encoded: 0 = TRUE, 1 = FALSE).
     * @param challengedStatus   Registry status that was contested (VerifiedTrue/VerifiedFalse).
     * @param bondToken          Bond token locked through the vault.
     * @param bondAmount         Bond amount locked.
     * @param appealDeadline     Frozen deadline before which the appeal round must close.
     * @param appealRationaleHash Hash of the challenger's rationale/evidence.
     * @param timestamp          Opening block timestamp.
     * @param version            Event schema version (1).
     */
    event DisputeOpenedV1(
        uint256 indexed claimId,
        uint256 indexed disputeId,
        address indexed challenger,
        uint8 challengedOutcome,
        uint8 challengedStatus,
        address bondToken,
        uint256 bondAmount,
        uint64 appealDeadline,
        bytes32 appealRationaleHash,
        uint64 timestamp,
        uint16 version
    );
}
