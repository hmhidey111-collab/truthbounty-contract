# TruthBounty V2 Canonical Event Catalogue

## Status
- **Schema Version**: `1`
- **Protocol Release**: `v2.0.0`
- **Solidity Interface**: [`contracts/interfaces/ITruthBountyEvents.sol`](../contracts/interfaces/ITruthBountyEvents.sol)
- **Machine-Readable Schema**: [`schemas/event-schema-v1.json`](../schemas/event-schema-v1.json)
- **Specification Reference**: Protocol Specification §20

---

## Architecture and Replay Guarantees

The TruthBounty V2 event architecture provides a deterministic projection surface for off-chain indexers, analytics engines, user frontends, and cross-chain relays. Every state-mutating lifecycle, financial, governance, emergency, and upgrade transition emits a versioned canonical event.

### Key Invariants
1. **Total State Reconstructibility**: An indexer starting from block 0 can reconstruct the complete protocol state (claims, evidence, votes, balances, rounds, outcomes, disputes, rewards, and treasury buckets) solely from canonical logs without querying contract storage.
2. **Deterministic Financial Reconciliation**: Every financial event (`StakeDepositedV1`, `StakeLockedV1`, `StakeUnlockedV1`, `StakeWithdrawnV1`, `RewardCalculatedV1`, `RewardEscrowedV1`, `RewardClaimedV1`, `SlashExecutedV1`, `TreasuryDepositV1`, `TreasuryTransferV1`, `TreasuryWithdrawalV1`) maps 1-to-1 with contract storage balances.
3. **Strict EVM Indexing**: Every event has at most 3 `indexed` parameters (EVM topic limit), prioritizing entity identifiers (e.g. `claimId`, `disputeId`, `operationId`), primary actors (e.g. `verifier`, `recipient`, `creator`), and domain reason hashes.
4. **Uniform Suffix**: Every canonical event carries trailing `(uint64 timestamp, uint16 version)` fields.

---

## Event Families Catalogue

### 1. Claims Lifecycle
Reconstructs claim registration, updates, status transitions, resolution outcomes, and finalization.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `ClaimCreatedV1` | `uint256 claimId`, `address actor`, `bytes32 metadataHash` | `uint64 timestamp`, `uint16 version` | Emitted when a new claim is created. |
| `ClaimUpdatedV1` | `uint256 claimId`, `address actor`, `bytes32 metadataHash` | `uint64 timestamp`, `uint16 version` | Emitted when claim metadata is updated. |
| `ClaimStatusTransitionedV1` | `uint256 claimId`, `address actor` | `uint8 oldStatus`, `uint8 newStatus`, `uint64 timestamp`, `uint16 version` | Emitted on claim lifecycle status change. |
| `ClaimResolvedV1` | `uint256 claimId`, `address actor` | `bool outcome`, `uint64 timestamp`, `uint16 version` | Emitted when consensus verdict is finalized. |
| `ClaimFinalizedV1` | `uint256 claimId`, `address actor` | `uint64 timestamp`, `uint16 version` | Emitted when all settlement accounting completes. |

### 2. Evidence Management
Tracks content-addressed evidence commitments, revocations, and claim evidence window closures.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `EvidenceSubmittedV1` | `uint256 claimId`, `uint256 evidenceId`, `address submitter` | `bytes32 evidenceHash`, `uint64 timestamp`, `uint16 version` | Emitted when IPFS/Arweave CID hash is attached. |
| `EvidenceRevokedV1` | `uint256 claimId`, `uint256 evidenceId`, `address actor` | `bytes32 reasonHash`, `uint64 timestamp`, `uint16 version` | Emitted when evidence is invalidated. |
| `ClaimClosedForEvidenceV1` | `uint256 claimId`, `address actor` | `uint64 timestamp`, `uint16 version` | Emitted when evidence submission window closes. |

### 3. Staking & Collateral Accounting
Reconciles verifier collateral deposits, round locking, unlocking, and withdrawals.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `StakeDepositedV1` | `address verifier` | `uint256 amount`, `uint256 newBalance`, `uint64 timestamp`, `uint16 version` | Emitted on collateral deposit. |
| `StakeLockedV1` | `uint256 claimId`, `address verifier` | `uint256 round`, `uint256 amount`, `uint256 resultingActiveStake`, `uint64 timestamp`, `uint16 version` | Emitted when stake is locked for voting. |
| `StakeUnlockedV1` | `uint256 claimId`, `address verifier` | `uint256 round`, `uint256 amount`, `uint256 resultingActiveStake`, `uint64 timestamp`, `uint16 version` | Emitted when locked stake is freed. |
| `StakeWithdrawnV1` | `address verifier` | `uint256 amount`, `uint256 newBalance`, `uint64 timestamp`, `uint16 version` | Emitted on collateral withdrawal. |

### 4. Verification & Voting
Records individual verifier submissions, support verdicts, committed stakes, and challenges.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `VerificationSubmittedV1` | `uint256 claimId`, `address verifier` | `bool support`, `uint256 stakeAmount`, `uint64 timestamp`, `uint16 version` | Emitted on verifier vote submission. |
| `VerificationChallengedV1` | `uint256 claimId`, `address challenger`, `bytes32 reasonHash` | `uint64 timestamp`, `uint16 version` | Emitted when a vote/verdict is challenged. |

### 5. Rounds Management
Defines round lifecycle windows, participant counts, and weighted vote totals.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `RoundStartedV1` | `uint256 claimId`, `uint256 round` | `uint64 windowStart`, `uint64 windowEnd`, `uint256 minStake`, `uint64 timestamp`, `uint16 version` | Emitted when a verification round opens. |
| `RoundEndedV1` | `uint256 claimId`, `uint256 round` | `uint256 totalWeightedFor`, `uint256 totalWeightedAgainst`, `uint256 participantCount`, `uint64 timestamp`, `uint16 version` | Emitted when voting round closes. |

### 6. Outcomes & Consensus Aggregation
Tracks deterministic aggregation of weighted verifications, consensus verdict, and confidence scores.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `OutcomeAggregatedV1` | `uint256 claimId`, `uint256 round` | `uint8 outcome`, `uint256 trueWeight`, `uint256 falseWeight`, `uint256 confidenceBps`, `uint64 timestamp`, `uint16 version` | Emitted on deterministic consensus calculation. |

### 7. Dispute Resolution
Reconstructs dispute challenges, escalation bonds, rulings, and resulting outcome overrides.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `DisputeRaisedV1` | `uint256 claimId`, `uint256 disputeId`, `address challenger` | `uint256 bondAmount`, `bytes32 reasonHash`, `uint64 timestamp`, `uint16 version` | Emitted when dispute is escalated. |
| `DisputeResolvedV1` | `uint256 claimId`, `uint256 disputeId`, `address resolver` | `uint8 ruling`, `uint8 resultingOutcome`, `uint64 timestamp`, `uint16 version` | Emitted when authoritative ruling is issued. |

### 8. Reward Calculation & Distribution
Reconciles deterministic reward calculations, escrow reservations, claims, and batch payouts.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `RewardCalculatedV1` | `bytes32 calculationId`, `address recipient` | `uint256 amount`, `uint64 timestamp`, `uint16 version` | Emitted on reward calculation execution. |
| `RewardEscrowedV1` | `uint256 claimId`, `address recipient` | `uint256 amount`, `uint64 timestamp`, `uint16 version` | Emitted when reward funds are reserved. |
| `RewardClaimedV1` | `uint256 claimId`, `address recipient` | `uint256 amount`, `uint64 timestamp`, `uint16 version` | Emitted when recipient claims rewards. |
| `BatchRewardClaimedV1` | `address recipient` | `uint256 count`, `uint256 totalAmount`, `uint64 timestamp`, `uint16 version` | Emitted on batch reward payout. |

### 9. Slashing Penalties
Reconciles collateral slashing for losing votes or Byzantine behaviour across individual and batch flows.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `SlashExecutedV1` | `uint256 claimId`, `address verifier`, `bytes32 reason` | `uint256 amount`, `uint64 timestamp`, `uint16 version` | Emitted when verifier collateral is confiscated. |
| `BatchSlashExecutedV1` | `uint256 claimId` | `uint256 round`, `uint256 count`, `uint256 totalAmount`, `uint64 timestamp`, `uint16 version` | Emitted on batch settlement slashing. |

### 10. Withdrawal Queue & Timelocks
Tracks queueing, cooldown expiry, cancellations, and execution of large verifier withdrawals.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `WithdrawalQueuedV1` | `bytes32 withdrawalId`, `address actor`, `address asset` | `uint256 amount`, `uint64 unlockTimestamp`, `uint64 timestamp`, `uint16 version` | Emitted when large withdrawal is queued. |
| `WithdrawalExecutedV1` | `bytes32 withdrawalId`, `address actor`, `address asset` | `uint256 amount`, `uint64 timestamp`, `uint16 version` | Emitted when queued withdrawal is executed. |
| `WithdrawalCancelledV1` | `bytes32 withdrawalId`, `address actor`, `bytes32 reasonHash` | `uint64 timestamp`, `uint16 version` | Emitted when queued withdrawal is cancelled. |

### 11. Treasury Accounting & Solvency
Maintains full double-entry reconciliation of deposits, internal bucket transfers, withdrawals, and snapshots.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `TreasuryDepositV1` | `bytes32 operationId`, `uint8 account`, `address asset` | `uint256 amount`, `address sender`, `uint64 timestamp`, `uint16 version` | Emitted when external funds enter treasury. |
| `TreasuryTransferV1` | `bytes32 operationId`, `address token`, `address recipient` | `uint256 amount`, `uint64 timestamp`, `uint16 version` | Emitted on internal treasury transfer. |
| `TreasuryWithdrawalV1` | `bytes32 operationId`, `uint8 account`, `address asset` | `address recipient`, `uint256 amount`, `address operator`, `uint64 timestamp`, `uint16 version` | Emitted on external treasury disbursement. |
| `TreasurySnapshotRecordedV1` | `uint256 snapshotId` | `uint256 totalAssets`, `uint64 timestamp`, `uint16 version` | Emitted when treasury solvency snapshot is logged. |

### 12. Protocol Parameters & Schedules
Tracks versioned governance parameter updates, address reconfigurations, and fee schedule updates.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `ParameterUpdatedV1` | `bytes32 paramName`, `uint256 parameterVersion` | `uint256 oldValue`, `uint256 newValue`, `uint64 effectiveAt`, `uint64 timestamp`, `uint16 version` | Emitted when governance parameter changes. |
| `AddressParameterUpdatedV1` | `bytes32 paramName`, `uint256 parameterVersion` | `address oldAddress`, `address newAddress`, `uint64 timestamp`, `uint16 version` | Emitted when module address changes. |
| `FeeScheduleUpdatedV1` | `bytes32 feeType`, `uint256 parameterVersion` | `uint256 fixedAmount`, `uint256 basisPoints`, `uint64 timestamp`, `uint16 version` | Emitted when fee schedule is modified. |

### 13. Reputation Roots & Snapshots
Publishes cross-chain Merkle roots, individual score adjustments, and decay updates.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `ReputationRootPublishedV1` | `uint256 snapshotId`, `bytes32 root` | `uint256 userCount`, `uint64 expiresAt`, `uint64 timestamp`, `uint16 version` | Emitted on cross-chain reputation Merkle root publication. |
| `ReputationScoreUpdatedV1` | `address verifier`, `bytes32 reasonHash` | `uint256 oldScore`, `uint256 newScore`, `uint64 timestamp`, `uint16 version` | Emitted on verifier score adjustment. |
| `ReputationDecayedV1` | `address verifier` | `uint256 previousScore`, `uint256 newScore`, `uint64 timestamp`, `uint16 version` | Emitted when inactivity decay is calculated. |

### 14. Access Control & Roles
Tracks role granting, revocation, and admin role hierarchy changes across protocol modules.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `RoleGrantedV1` | `bytes32 role`, `address account`, `address sender` | `uint64 timestamp`, `uint16 version` | Emitted when role is granted. |
| `RoleRevokedV1` | `bytes32 role`, `address account`, `address sender` | `uint64 timestamp`, `uint16 version` | Emitted when role is revoked. |
| `RoleAdminChangedV1` | `bytes32 role`, `bytes32 previousAdminRole`, `bytes32 newAdminRole` | `uint64 timestamp`, `uint16 version` | Emitted when role admin changes. |

### 15. Emergency Controls & Pauses
Reconstructs protocol emergency pause activation and recovery events.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `EmergencyPauseActivatedV1` | `address actor`, `bytes32 reason` | `uint64 timestamp`, `uint16 version` | Emitted when emergency pause is enabled. |
| `EmergencyPauseRecoveredV1` | `address actor` | `uint64 timestamp`, `uint16 version` | Emitted when normal operation is restored. |

### 16. Upgrades & Governance
Reconstructs module registrations, upgrade proposals, approvals, executions, and rollbacks.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `GovernanceProposalCreatedV1` | `bytes32 proposalId`, `address proposer`, `bytes32 metadataHash` | `uint64 timestamp`, `uint16 version` | Emitted when governance proposal is created. |
| `GovernanceProposalExecutedV1` | `bytes32 proposalId`, `address executor` | `uint64 timestamp`, `uint16 version` | Emitted when proposal is executed. |
| `ModuleRegisteredV1` | `bytes32 moduleId`, `address implementation` | `uint64 major`, `uint64 minor`, `uint64 patch`, `bytes32 storageLayoutHash`, `uint64 timestamp`, `uint16 version` | Emitted on module registration. |
| `UpgradeProposedV1` | `uint256 proposalId`, `bytes32 moduleId`, `address newImplementation` | `uint64 toMajor`, `uint64 toMinor`, `uint64 toPatch`, `bytes32 migrationHash`, `address proposer`, `uint64 timestamp`, `uint16 version` | Emitted on upgrade proposal. |
| `UpgradeApprovedV1` | `uint256 proposalId`, `bytes32 moduleId` | `uint64 executeAfter`, `address approver`, `uint64 timestamp`, `uint16 version` | Emitted when upgrade is approved. |
| `UpgradeExecutedV1` | `uint256 proposalId`, `bytes32 moduleId` | `address oldImplementation`, `address newImplementation`, `address executor`, `uint64 timestamp`, `uint16 version` | Emitted when upgrade is executed. |
| `UpgradeRolledBackV1` | `bytes32 moduleId`, `bytes32 reasonHash`, `address guardian` | `address oldImplementation`, `address restoredImplementation`, `uint64 timestamp`, `uint16 version` | Emitted on emergency rollback. |

### 17. Appeal Domain (SC-017) Events
Emitted by `AppealVerificationRound` (a V2 module emitting its own non-`V1`-canonical events). These are the **modular** appeal events — the `V1` canonical families above (`ITruthBountyEvents`) are unaffected by their evolution.

| Event | Indexed Fields | Unindexed Fields | Description |
|---|---|---|---|
| `AppealRoundOpened` | `uint256 claimId`, `address openedBy` | `uint256 deadline`, `uint256 minStake`, `uint256 multiplierBps`, `uint256 roundIndex`, `uint256 maxRounds`, `uint256 requiredBond`, `uint256 bondLockId` | Emitted when a bond-gated appeal round opens. `requiredBond`/`bondLockId` and the ladder bounds (`roundIndex`, `maxRounds`) were added by V2-SC-059. |
| `AppealVoteSubmitted` | `uint256 claimId`, `address verifier` | `bool support`, `uint256 stakeAmount`, `uint256 effectiveWeight` | Emitted on appeal vote submission. |
| `AppealRoundClosed` | `uint256 claimId`, `address closedBy` | `uint256 totalTrueWeight`, `uint256 totalFalseWeight`, `uint256 verifierCount`, `uint256 roundIndex` | Emitted when an appeal round closes (`roundIndex` added by V2-SC-059). |
| `AppealPathFinalized` | `uint256 claimId` | `uint256 roundIndex`, `uint256 totalTrueWeight`, `uint256 totalFalseWeight`, `uint256 verifierCount` | Emitted (new in V2-SC-059) when a claim's appeal path becomes irreversibly terminal. |
| `DefaultAppealConfigUpdated` | — | `uint256 duration`, `uint256 minStake`, `uint256 multiplierBps`, `uint256 maxWeightCap`, `uint256 maxAppealRounds`, `uint256 appealBond`, `uint256 appealBondEscalationBps`, `uint256 maxAppealBond`, `uint256 maxVotersPerRound` | Emitted on governance config update (ladder/bond/voter fields added by V2-SC-059). |
| `VaultUpdated` | `address oldVault`, `address newVault` | — | Emitted when the bond-custody vault is re-pointed. |

---

## Versioning & Breaking-Change Policy

1. **Immutability of Released Signatures**: Once an event signature (e.g. `ClaimCreatedV1(...)`) is adopted on mainnet, its signature, topic hash, and parameter ordering are permanently immutable.
2. **Additive Modifications**: New fields or optional metadata must be added via new event signatures (e.g. `ClaimCreatedV2(...)`) or separate ancillary events.
3. **Quarantine & Fallback**: Indexers must quarantine unrecognized versions (`version != 1`) and emit alerts without halting projection of valid canonical events.
