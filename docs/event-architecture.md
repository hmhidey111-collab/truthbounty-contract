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

### Canonical Intra-Transaction Ordering

When a single call emits several canonical events, emission order is fixed by the following rules so that indexers can replay state transitions without reading contract storage:

1. **Causal order**: Events are emitted in the order the corresponding state transitions are applied within the call. A dependent event (e.g. `ClaimResolvedV1`) is always emitted after the event that establishes its precondition (e.g. `ClaimStatusTransitionedV1`).
2. **Family precedence**: For independent transitions applied in the same call, emission follows the family precedence below (lower number first):
   1. Access Control & Roles (`RoleGrantedV1`, `RoleRevokedV1`, `RoleAdminChangedV1`)
   2. Parameters & Schedules (`ParameterUpdatedV1`, `AddressParameterUpdatedV1`, `FeeScheduleUpdatedV1`)
   3. Emergency & Pauses (`EmergencyPauseActivatedV1`, `EmergencyPauseRecoveredV1`)
   4. Upgrades & Governance (`GovernanceProposalCreatedV1`, `GovernanceProposalExecutedV1`, `ModuleRegisteredV1`, `UpgradeProposedV1`, `UpgradeApprovedV1`, `UpgradeExecutedV1`, `UpgradeRolledBackV1`)
   5. Claims (`ClaimCreatedV1`, `ClaimUpdatedV1`, `ClaimStatusTransitionedV1`, `ClaimResolvedV1`, `ClaimFinalizedV1`)
   6. Evidence (`EvidenceSubmittedV1`, `EvidenceRevokedV1`, `ClaimClosedForEvidenceV1`)
   7. Rounds (`RoundStartedV1`, `RoundEndedV1`)
   8. Verification & Voting (`VerificationSubmittedV1`, `VerificationChallengedV1`)
   9. Outcomes & Aggregation (`OutcomeAggregatedV1`)
   10. Disputes (`DisputeRaisedV1`, `DisputeResolvedV1`)
   11. Staking & Collateral (`StakeDepositedV1`, `StakeLockedV1`, `StakeUnlockedV1`, `StakeWithdrawnV1`)
   12. Slashing (`SlashExecutedV1`, `BatchSlashExecutedV1`)
   13. Rewards (`RewardCalculatedV1`, `RewardEscrowedV1`, `RewardClaimedV1`, `BatchRewardClaimedV1`)
   14. Withdrawals (`WithdrawalQueuedV1`, `WithdrawalExecutedV1`, `WithdrawalCancelledV1`)
   15. Treasury & Accounting (`TreasuryDepositV1`, `TreasuryTransferV1`, `TreasuryWithdrawalV1`, `TreasurySnapshotRecordedV1`)
   16. Reputation Roots & Snapshots (`ReputationRootPublishedV1`, `ReputationScoreUpdatedV1`, `ReputationDecayedV1`)
3. **Within-family order**: Events of the same family are emitted in the order their transitions are applied (e.g. `StakeDepositedV1` before `StakeLockedV1` when both occur in one deposit-and-lock call).
4. **Batch order**: Batch events (`BatchRewardClaimedV1`, `BatchSlashExecutedV1`) are emitted once per batch, after the per-item events they summarize, and never interleaved with them.
5. **Nested calls**: Events emitted by a nested call (external call, hook, or callback) appear in the receipt at the position of the nested call's execution, i.e. between the events of the caller that precede and follow the nested call. Nested events retain their own intra-transaction ordering per the rules above.
6. **Proxy upgrades**: For upgrade flows, `UpgradeProposedV1` and `UpgradeApprovedV1` precede `UpgradeExecutedV1`; `UpgradeRolledBackV1` is emitted only on rollback and never alongside `UpgradeExecutedV1` in the same call. Upgrade events are emitted by the proxy-facing module and are not duplicated by implementation contracts.
7. **Revert semantics**: If any transition in the call reverts, the entire transaction reverts and no canonical events from that call are durable. Partial emission is never observable.
8. **No duplicate semantic events**: A single semantic state change emits exactly one canonical event. Emitting the same semantic event from both a proxy and its implementation, or from both a batch wrapper and its items, is prohibited.

### Regression Coverage

The ordering rules above are regression-tested by the following suites:

- Success and revert paths for multi-event calls (revert asserts zero durable logs).
- Nested call ordering (caller → nested → caller).
- Batch ordering (`BatchRewardClaimedV1`, `BatchSlashExecutedV1` after per-item events).
- Repeated action ordering (idempotent re-emission prohibited; distinct actions ordered per family precedence).
- Proxy upgrade ordering (`UpgradeProposedV1` → `UpgradeApprovedV1` → `UpgradeExecutedV1`; rollback path).
- Fuzz tests asserting the emitted log sequence matches the canonical ordering for arbitrary multi-event inputs.

### Idempotency & Reorg Handling
- Persistent unique event key: `keccak256(chainId, contractAddress, transactionHash, logIndex)`.
- When a chain reorganization occurs, all events associated with orphaned block hashes must be unapplied before new canonical blocks are processed.

### Versioning & Breaking-Change Policy
- **Additive Evolution**: New features must introduce new event definitions or versioned schemas (e.g. `V2`).
- **Signature Immutability**: Existing event signatures are immutable once published to mainnet.
- **Consumer Quarantine**: Indexers must quarantine unsupported versions without halting the ingestion of valid canonical events.
