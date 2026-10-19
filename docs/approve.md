# TruthBounty On-Chain Event Architecture

## Status
- **Schema version**: `1`
- **Protocol version**: `2.0.0`
- **Specification Reference**: Protocol Specification §20
- **Canonical Interface**: `contracts/interfaces/ITruthBountyEvents.sol`
- **Event Catalogue**: [`docs/event-catalogue-v1.md`](./event-catalogue-v1.md)
- **Machine-Readable Schema**: [`schemas/event-schema-v1.json`](../schemas/event-schema-v1.json)

This document defines the canonical event contract between TruthBounty smart contracts and off-chain consumers such as indexers, explorers, APIs, analytics services, notification systems, and frontends.

---

## Design Principles & Security Invariants

1. **Emission on Success**: Events are emitted only after the corresponding state transition succeeds. Reverted transactions produce no logs.
2. **Naming Convention**: Event names use past-tense domain actions suffixed with schema version (e.g., `ClaimCreatedV1`, `OutcomeAggregatedV1`, `RewardClaimedV1`).
3. **Strict Indexing Budget**: Entity identifiers, primary actors, and stable reason hashes are indexed, strictly adhering to the EVM limit of at most 3 indexed fields per event.
4. **Privacy & Integrity**: Evidence content, raw signatures, and sensitive user data are never emitted directly; deterministic `bytes32` hashes (e.g. `metadataHash`, `evidenceHash`, `reasonHash`) are emitted instead.
5. **Deterministic Timestamp & Versioning**: Every canonical event carries trailing `uint64 timestamp` (block context timestamp) and `uint16 version` (literal `1`).
6. **Financial Reconciliation Invariant**: All financial events (`StakeDepositedV1`, `StakeLockedV1`, `StakeUnlockedV1`, `StakeWithdrawnV1`, `SlashExecutedV1`, `RewardEscrowedV1`, `RewardClaimedV1`, `TreasuryDepositV1`, `TreasuryTransferV1`) reconcile with on-chain storage accounting balances without divergence.

---

## Event Families (Specification §20)

TruthBounty V2 canonical events are grouped into 16 authoritative families:

1. **Claims**: `ClaimCreatedV1`, `ClaimUpdatedV1`, `ClaimStatusTransitionedV1`, `ClaimResolvedV1`, `ClaimFinalizedV1`
2. **Evidence**: `EvidenceSubmittedV1`, `EvidenceRevokedV1`, `ClaimClosedForEvidenceV1`
3. **Staking & Collateral**: `StakeDepositedV1`, `StakeLockedV1`, `StakeUnlockedV1`, `StakeWithdrawnV1`
4. **Verification & Voting**: `VerificationSubmittedV1`, `VerificationChallengedV1`
5. **Rounds**: `RoundStartedV1`, `RoundEndedV1`
6. **Outcomes & Aggregation**: `OutcomeAggregatedV1`
7. **Disputes**: `DisputeRaisedV1`, `DisputeResolvedV1`
8. **Rewards**: `RewardCalculatedV1`, `RewardEscrowedV1`, `RewardClaimedV1`, `BatchRewardClaimedV1`
9. **Slashing**: `SlashExecutedV1`, `BatchSlashExecutedV1`
10. **Withdrawals**: `WithdrawalQueuedV1`, `WithdrawalExecutedV1`, `WithdrawalCancelledV1`
11. **Treasury & Accounting**: `TreasuryDepositV1`, `TreasuryTransferV1`, `TreasuryWithdrawalV1`, `TreasurySnapshotRecordedV1`
12. **Parameters & Schedules**: `ParameterUpdatedV1`, `AddressParameterUpdatedV1`, `FeeScheduleUpdatedV1`
13. **Reputation Roots & Snapshots**: `ReputationRootPublishedV1`, `ReputationScoreUpdatedV1`, `ReputationDecayedV1`
14. **Access Control & Roles**: `RoleGrantedV1`, `RoleRevokedV1`, `RoleAdminChangedV1`
15. **Emergency & Pauses**: `EmergencyPauseActivatedV1`, `EmergencyPauseRecoveredV1`
16. **Upgrades & Governance**: `GovernanceProposalCreatedV1`, `GovernanceProposalExecutedV1`, `ModuleRegisteredV1`, `UpgradeProposedV1`, `UpgradeApprovedV1`, `UpgradeExecutedV1`, `UpgradeRolledBackV1`

---

## Event Ordering & Indexing Guidance

### Total Log Ordering
Consumers must order logs deterministically by:
1. `blockNumber` (monotonically increasing)
2. `transactionIndex` (position within block)
3. `logIndex` (position within transaction receipt)

### Idempotency & Reorg Handling
- Persistent unique event key: `keccak256(chainId, contractAddress, transactionHash, logIndex)`.
- When a chain reorganization occurs, all events associated with orphaned block hashes must be unapplied before new canonical blocks are processed.

### Versioning & Breaking-Change Policy
- **Additive Evolution**: New features must introduce new event definitions or versioned schemas (e.g. `V2`).
- **Signature Immutability**: Existing event signatures are immutable once published to mainnet.
- **Consumer Quarantine**: Indexers must quarantine unsupported versions without halting the ingestion of valid canonical events.
