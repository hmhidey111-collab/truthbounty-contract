# TruthBounty V2 Event Catalog - Testnet Readiness Audit

## Status
- **Catalog Version**: `2.0`
- **Protocol Release**: `v2.0.0-testnet`
- **Audit Phase**: Post-Wave-9 Testnet Readiness
- **Last Updated**: 2026-10-17
- **Compiler**: Solidity 0.8.28 (foundry.toml pinned)
- **Optimizer**: 200 runs, `via_ir = true`

## Purpose

This catalog provides independently reviewable proof of the contract boundary consumed by:
- The TruthBounty API for event-based state reconstruction
- Frontend indexers for real-time UI updates
- Analytics and reporting systems
- Cross-chain relays and bridges

**Security Guarantee**: Every state transition that affects approved read models emits a deterministic, versioned event with stable correlation identifiers.

---

## Design Principles

1. **Total State Reconstructibility**: API can reconstruct every approved read model from events plus declared view functions
2. **Stable Correlation Keys**: Every lifecycle has deterministic identifiers for cross-event correlation (claimId, roundId, disputeId, settlementId)
3. **Versioned Schemas**: Breaking changes require explicit version increments; additive changes permitted within version
4. **Indexed Budget**: Maximum 3 indexed parameters per event (EVM limit) - prioritize entity IDs and primary actors
5. **Deterministic Artifacts**: Generated from pinned compiler, optimizer settings, and exact commit
6. **Fail-Closed Authority**: No legacy V1 events or ambiguous authority patterns in V2 contracts

---

## Event Lifecycle Correlation Map

### Claim Lifecycle
```
ClaimCreated (claimId)
  ├─> ClaimStatusUpdated (claimId, oldStatus, newStatus)
  ├─> RoundOpened (claimId, roundId)
  │    ├─> VerificationSubmitted (claimId, verificationId, verifier)
  │    └─> RoundClosed (claimId, roundId)
  ├─> RoundAggregated (claimId, outcome, confidence)
  ├─> ProvisionalOutcomeCreated (claimId, outcome, challengeDeadline)
  └─> ClaimFinalizedV1 (claimId) [if no dispute]
```

### Dispute & Appeal Path
```
DisputeOpenedV1 (claimId, disputeId, challenger)
  ├─> ClaimStatusUpdated (claimId, status=Disputed)
  ├─> RoundOpened (claimId, roundId, roundType=APPEAL)
  │    ├─> VerificationSubmitted (claimId, verificationId)
  │    └─> RoundClosed (claimId, roundId)
  └─> DisputeResolvedV1 (claimId, disputeId, ruling)
```

### Settlement & Rewards Path
```
ProvisionalOutcomeCreated (claimId)
  ├─> ClaimSettled (beneficiary, amount, settlementId) [batch possible]
  ├─> RewardAllocated (recipient, claimId, amount, settlementId)
  ├─> RewardDistributed (recipient, claimId, amount)
  └─> RewardClaimed (recipient, distributionId, amount)
```

### Slashing Path
```
VerificationSubmitted (claimId, verifier, verdict=wrong)
  └─> [after settlement]
       ├─> Slashed (verifier, amount, claimId)
       ├─> VerifierSlashed (verifier, claimId, amount)
       └─> StakeSlashed (verifier, amount, claimId)
```

---

## Core Protocol Events

### 1. Claim Registry Events

#### ClaimCreated
Emitted when a new claim is registered in the protocol.

**Contract**: `ClaimRegistry.sol`
**Signature**: `ClaimCreated(uint256 indexed claimId, address indexed creator, string evidenceCID)`

**Indexed Fields**:
- `claimId` (uint256) — Unique, monotonically increasing claim identifier
- `creator` (address) — Account that created the claim

**Unindexed Fields**:
- `evidenceCID` (string) — IPFS CID or evidence reference

**Correlation Keys**: 
- Primary: `claimId`
- Secondary: `creator`

**Read Model Impact**: Initializes claim entity in all read models
**State Reconstruction**: Required to rebuild claim registry
**Ordering Requirement**: Must be first event for any claimId

---

#### ClaimStatusUpdated
Emitted when a claim transitions between lifecycle states.

**Contract**: `ClaimRegistry.sol`
**Signature**: `ClaimStatusUpdated(uint256 indexed claimId, ClaimStatus indexed oldStatus, ClaimStatus indexed newStatus)`

**Indexed Fields**:
- `claimId` (uint256) — The claim being updated
- `oldStatus` (ClaimStatus enum/uint8) — Previous state
- `newStatus` (ClaimStatus enum/uint8) — New state

**Unindexed Fields**: None

**Correlation Keys**:
- Primary: `claimId`

**State Transitions**:
```
Pending → UnderVerification → VerifiedTrue | VerifiedFalse | Disputed
```

**Read Model Impact**: Updates claim status in all views
**Multi-Event Requirement**: Often follows RoundClosed or DisputeResolved

---

### 2. Verification Round Events

#### RoundOpened
Emitted when a new verification round begins for a claim.

**Contract**: `VerificationRoundManager.sol`
**Signature**: 
```solidity
RoundOpened(
    uint256 indexed claimId,
    uint256 indexed roundId,
    uint8 roundType,
    uint64 startedAt,
    uint64 deadline,
    uint256 minStake,
    uint256 maxStake,
    uint256 weightCap,
    uint16 passingThreshold,
    uint32 paramVersion
)
```

**Indexed Fields**:
- `claimId` (uint256) — Claim this round belongs to
- `roundId` (uint256) — Unique, monotonically increasing round ID

**Unindexed Fields**:
- `roundType` (uint8) — 0=FIRST, 1=APPEAL
- `startedAt` (uint64) — Block timestamp when round opened
- `deadline` (uint64) — Timestamp after which no more submissions accepted
- `minStake` (uint256) — Minimum stake required to participate
- `maxStake` (uint256) — Maximum stake allowed per participant
- `weightCap` (uint256) — Maximum weight any single participant contributes
- `passingThreshold` (uint16) — Basis points (0-10000) required for TRUE outcome
- `paramVersion` (uint32) — Configuration registry version snapshot

**Correlation Keys**:
- Primary: `roundId`
- Foreign: `claimId`

**Read Model Impact**: Creates round entity, opens participation window
**Ordering Requirement**: Must precede VerificationSubmitted for this roundId

---

#### RoundClosed
Emitted when a verification round ends (permissionlessly after deadline).

**Contract**: `VerificationRoundManager.sol`
**Signature**: `RoundClosed(uint256 indexed claimId, uint256 indexed roundId, uint64 closedAt, uint256 totalVotes)`

**Indexed Fields**:
- `claimId` (uint256) — Claim this round belongs to
- `roundId` (uint256) — Round being closed

**Unindexed Fields**:
- `closedAt` (uint64) — Block timestamp of closure
- `totalVotes` (uint256) — Total participant count

**Correlation Keys**:
- Primary: `roundId`
- Foreign: `claimId`

**Read Model Impact**: Seals round, enables aggregation
**Multi-Event Requirement**: Triggers downstream aggregation and potential status change

---

#### VerificationSubmitted
Emitted when a verifier submits their vote/verification.

**Contract**: `VerificationSubmission.sol`
**Signature**: `VerificationSubmitted(uint256 indexed claimId, uint256 indexed verificationId, address indexed verifier, VerificationVerdict verdict, uint256 stake)`

**Indexed Fields**:
- `claimId` (uint256) — Claim being verified
- `verificationId` (uint256) — Unique verification record ID
- `verifier` (address) — Account submitting verification

**Unindexed Fields**:
- `verdict` (VerificationVerdict enum) — TRUE or FALSE
- `stake` (uint256) — Amount of stake committed

**Correlation Keys**:
- Primary: `verificationId`
- Foreign: `claimId`, `roundId` (implicitly from claim state)
- Actor: `verifier`

**Read Model Impact**: Records vote, updates aggregation weights
**Ordering Requirement**: Must occur after RoundOpened, before RoundClosed

---

### 3. Aggregation & Settlement Events

#### RoundAggregated
Emitted when verification results are aggregated.

**Contract**: `ProvisionalSettlementEngine.sol`
**Signature**: `RoundAggregated(uint256 indexed claimId, Outcome indexed outcome, uint256 confidence, uint256 trueWeight, uint256 falseWeight, uint256 totalWeight, uint256 verifierCount)`

**Indexed Fields**:
- `claimId` (uint256) — Claim being aggregated
- `outcome` (Outcome enum) — VERIFIED_TRUE | VERIFIED_FALSE | INCONCLUSIVE

**Unindexed Fields**:
- `confidence` (uint256) — Confidence score
- `trueWeight` (uint256) — Total weight for TRUE
- `falseWeight` (uint256) — Total weight for FALSE
- `totalWeight` (uint256) — Total weight participated
- `verifierCount` (uint256) — Number of verifiers

**Correlation Keys**:
- Primary: `claimId`

**Read Model Impact**: Establishes provisional outcome
**Multi-Event Requirement**: Always paired with ProvisionalOutcomeCreated

---

#### ProvisionalOutcomeCreated
Emitted when a claim enters challengeable provisional state.

**Contract**: `ProvisionalSettlementEngine.sol`
**Signature**: `ProvisionalOutcomeCreated(uint256 indexed claimId, Outcome indexed outcome, uint256 challengeDeadline, uint256 confidence, address indexed caller)`

**Indexed Fields**:
- `claimId` (uint256) — Claim being settled provisionally
- `outcome` (Outcome enum) — Provisional verdict
- `caller` (address) — Account triggering settlement

**Unindexed Fields**:
- `challengeDeadline` (uint256) — Timestamp after which outcome is final
- `confidence` (uint256) — Aggregation confidence score

**Correlation Keys**:
- Primary: `claimId`

**Read Model Impact**: Opens challenge window, sets outcome deadline
**Multi-Event Requirement**: Follows RoundAggregated

---

#### ClaimSettled
Emitted when settlement rewards are distributed.

**Contract**: `TruthBountyClaims.sol`
**Signature**: `ClaimSettled(address indexed beneficiary, uint256 amount, bytes32 indexed settlementId)`

**Indexed Fields**:
- `beneficiary` (address) — Recipient of settlement
- `settlementId` (bytes32) — Unique settlement operation ID (replay prevention)

**Unindexed Fields**:
- `amount` (uint256) — Token amount transferred

**Correlation Keys**:
- Primary: `settlementId`
- Actor: `beneficiary`
- Foreign: `claimId` (must be correlated from settlementId or batch context)

**Read Model Impact**: Records payout, updates treasury
**Replay Prevention**: settlementId consumed exactly once

---

#### BatchSettlementCompleted
Emitted when batch settlement finishes.

**Contract**: `TruthBountyClaims.sol`
**Signature**: `BatchSettlementCompleted(uint256 count, bytes32 indexed settlementId)`

**Indexed Fields**:
- `settlementId` (bytes32) — Batch operation ID

**Unindexed Fields**:
- `count` (uint256) — Number of successful settlements in batch

**Correlation Keys**:
- Primary: `settlementId`

**Read Model Impact**: Marks batch completion
**Multi-Event Requirement**: Preceded by multiple ClaimSettled events with same settlementId

---

### 4. Dispute & Appeal Events

#### DisputeOpenedV1
Emitted when a provisional outcome is challenged.

**Contract**: `DisputeResolution.sol`
**Signature**: 
```solidity
DisputeOpenedV1(
    uint256 indexed claimId,
    uint256 indexed disputeId,
    address indexed challenger,
    ChallengedOutcome challengedOutcome,
    ClaimStatus challengedStatus,
    address bondToken,
    uint256 bondAmount,
    uint64 appealDeadline,
    bytes32 appealRationaleHash,
    uint64 timestamp,
    uint16 version
)
```

**Indexed Fields**:
- `claimId` (uint256) — Claim being disputed
- `disputeId` (uint256) — Unique dispute ID
- `challenger` (address) — Account opening dispute

**Unindexed Fields**:
- `challengedOutcome` (ChallengedOutcome enum)
- `challengedStatus` (ClaimStatus enum)
- `bondToken` (address) — Token used for bond
- `bondAmount` (uint256) — Bond amount locked
- `appealDeadline` (uint64) — Deadline for appeal resolution
- `appealRationaleHash` (bytes32) — Hash of dispute reasoning
- `timestamp` (uint64) — Block timestamp
- `version` (uint16) — Event schema version (1)

**Correlation Keys**:
- Primary: `disputeId`
- Foreign: `claimId`
- Actor: `challenger`

**Read Model Impact**: Opens dispute, locks bond, triggers appeal round
**Multi-Event Requirement**: Triggers ClaimStatusUpdated (status=Disputed) and RoundOpened (roundType=APPEAL)

---

### 5. Reward Events

#### RewardAllocated
Emitted when rewards are calculated and allocated.

**Contract**: `RewardEngine.sol`
**Signature**: `RewardAllocated(address indexed recipient, uint256 indexed claimId, uint256 amount, bytes32 indexed settlementId)`

**Indexed Fields**:
- `recipient` (address) — Account receiving reward
- `claimId` (uint256) — Claim the reward is for
- `settlementId` (bytes32) — Settlement operation ID

**Unindexed Fields**:
- `amount` (uint256) — Reward amount

**Correlation Keys**:
- Primary: `settlementId`
- Foreign: `claimId`
- Actor: `recipient`

**Read Model Impact**: Records pending reward claim
**Ordering Requirement**: Precedes RewardClaimed

---

#### RewardClaimed
Emitted when a recipient claims their rewards.

**Contract**: `RewardEngine.sol`
**Signature**: `RewardClaimed(address indexed recipient, bytes32 indexed distributionId, uint256 amount)`

**Indexed Fields**:
- `recipient` (address) — Claimer
- `distributionId` (bytes32) — Distribution operation ID

**Unindexed Fields**:
- `amount` (uint256) — Amount claimed

**Correlation Keys**:
- Primary: `distributionId`
- Actor: `recipient`

**Read Model Impact**: Updates claimable balance, records payout
**Multi-Event Requirement**: Follows RewardAllocated

---

### 6. Slashing Events

#### VerifierSlashed
Emitted when a verifier's stake is slashed for incorrect verification.

**Contract**: `VerifierSlashing.sol`
**Signature**: `VerifierSlashed(address indexed verifier, uint256 indexed claimId, uint256 slashedAmount, uint256 remainingStake, bytes32 reason, address executor)`

**Indexed Fields**:
- `verifier` (address) — Account being slashed
- `claimId` (uint256) — Claim the slash relates to

**Unindexed Fields**:
- `slashedAmount` (uint256) — Amount removed
- `remainingStake` (uint256) — Remaining stake after slash
- `reason` (bytes32) — Slash reason code
- `executor` (address) — Account executing slash

**Correlation Keys**:
- Primary: `claimId`
- Actor: `verifier`
- Foreign: `verificationId` (must correlate from claim/verifier pair)

**Read Model Impact**: Reduces verifier stake, updates treasury
**Multi-Event Requirement**: May pair with StakeSlashed event

---

#### StakeSlashed
Emitted when stake is slashed from custody.

**Contract**: `StakeCustody.sol` (V2 interface)
**Signature**: `StakeSlashed(address indexed account, uint256 indexed claimId, uint256 amount, bytes32 indexed reason, uint64 timestamp, uint16 version)`

**Indexed Fields**:
- `account` (address) — Account losing stake
- `claimId` (uint256) — Related claim
- `reason` (bytes32) — Slash reason hash

**Unindexed Fields**:
- `amount` (uint256) — Slashed amount
- `timestamp` (uint64) — Block timestamp
- `version` (uint16) — Schema version

**Correlation Keys**:
- Primary: `claimId`, `account`
- Reason: `reason`

**Read Model Impact**: Updates custody balances
**Multi-Event Requirement**: Often paired with VerifierSlashed

---

### 7. Staking & Custody Events

#### StakeDeposited
Emitted when a verifier deposits collateral.

**Contract**: `StakeCustody.sol` (V2), various staking contracts
**Signature**: `StakeDeposited(address indexed account, uint256 indexed claimId, uint256 amount, uint64 timestamp, uint16 version)`

**Indexed Fields**:
- `account` (address) — Depositor
- `claimId` (uint256) — Claim context (0 for general deposit)

**Unindexed Fields**:
- `amount` (uint256) — Deposit amount
- `timestamp` (uint64) — Block timestamp
- `version` (uint16) — Schema version

**Correlation Keys**:
- Actor: `account`
- Foreign: `claimId`

**Read Model Impact**: Increases available stake balance
**Financial Reconciliation**: Must match custody storage

---

#### StakeReleased
Emitted when locked stake is returned to claimable balance.

**Contract**: `StakeCustody.sol`
**Signature**: `StakeReleased(address indexed account, uint256 indexed claimId, uint256 amount, uint64 timestamp, uint16 version)`

**Indexed Fields**:
- `account` (address) — Account receiving release
- `claimId` (uint256) — Claim the stake was locked for

**Unindexed Fields**:
- `amount` (uint256) — Released amount
- `timestamp` (uint64) — Block timestamp
- `version` (uint16) — Schema version

**Correlation Keys**:
- Actor: `account`
- Foreign: `claimId`

**Read Model Impact**: Moves stake from locked to available
**Multi-Event Requirement**: Follows claim settlement

---

### 8. Governance & Access Control Events

#### RoleGrantedV1
Emitted when a protocol role is assigned.

**Contract**: `ITruthBountyEvents.sol`, OpenZeppelin AccessControl
**Signature**: `RoleGrantedV1(bytes32 indexed role, address indexed account, address indexed sender, uint64 timestamp, uint16 version)`

**Indexed Fields**:
- `role` (bytes32) — Role identifier (e.g., ADMIN_ROLE, PAUSER_ROLE)
- `account` (address) — Account receiving role
- `sender` (address) — Account granting role

**Unindexed Fields**:
- `timestamp` (uint64) — Block timestamp
- `version` (uint16) — Schema version

**Correlation Keys**:
- Primary: `role`, `account`
- Actor: `sender`

**Read Model Impact**: Updates access control lists
**Security Requirement**: Must be included in authority audit trail

---

#### RoleRevokedV1
Emitted when a protocol role is removed.

**Contract**: `ITruthBountyEvents.sol`, OpenZeppelin AccessControl
**Signature**: `RoleRevokedV1(bytes32 indexed role, address indexed account, address indexed sender, uint64 timestamp, uint16 version)`

**Indexed Fields**:
- `role` (bytes32) — Role being revoked
- `account` (address) — Account losing role
- `sender` (address) — Account revoking

**Unindexed Fields**:
- `timestamp` (uint64) — Block timestamp
- `version` (uint16) — Schema version

**Correlation Keys**:
- Primary: `role`, `account`
- Actor: `sender`

**Read Model Impact**: Updates access control lists
**Security Requirement**: Must be included in authority audit trail

---

### 9. Emergency & Pause Events

#### EmergencyPauseActivatedV1
Emitted when protocol operations are paused.

**Contract**: `ITruthBountyEvents.sol`, Pausable contracts
**Signature**: `EmergencyPauseActivatedV1(address indexed actor, bytes32 indexed reason, uint64 timestamp, uint16 version)`

**Indexed Fields**:
- `actor` (address) — Account activating pause
- `reason` (bytes32) — Pause reason hash

**Unindexed Fields**:
- `timestamp` (uint64) — Block timestamp
- `version` (uint16) — Schema version

**Correlation Keys**:
- Actor: `actor`
- Reason: `reason`

**Read Model Impact**: Disables state-changing operations
**Security Requirement**: High-priority alert to frontend

---

#### EmergencyPauseRecoveredV1
Emitted when protocol operations resume.

**Contract**: `ITruthBountyEvents.sol`, Pausable contracts
**Signature**: `EmergencyPauseRecoveredV1(address indexed actor, uint64 timestamp, uint16 version)`

**Indexed Fields**:
- `actor` (address) — Account unpausing

**Unindexed Fields**:
- `timestamp` (uint64) — Block timestamp
- `version` (uint16) — Schema version

**Correlation Keys**:
- Actor: `actor`

**Read Model Impact**: Re-enables operations
**Multi-Event Requirement**: Must follow EmergencyPauseActivatedV1

---

### 10. Upgrade Events

#### Upgraded (UUPS)
Emitted when a contract is upgraded via UUPS proxy.

**Contract**: `UUPSUpgradeable` (OpenZeppelin)
**Signature**: `Upgraded(address indexed implementation)`

**Indexed Fields**:
- `implementation` (address) — New implementation address

**Unindexed Fields**: None

**Correlation Keys**:
- Target: `address(this)` (contract being upgraded, available from log address)
- New implementation: `implementation`

**Read Model Impact**: Updates implementation registry
**Security Requirement**: Must be approved via governance before execution

---

## Multi-Event State Transitions

### 1. Claim Creation Flow
**Required Events (in order)**:
1. `ClaimCreated` — Registers claim
2. `ClaimStatusUpdated` (Pending → UnderVerification) — Opens for voting

**Stable Identifiers**:
- `claimId` correlates both events

---

### 2. Verification Round Flow
**Required Events (in order)**:
1. `RoundOpened` — Opens round window
2. `VerificationSubmitted` (0..N times) — Verifiers submit
3. `RoundClosed` — Seals round
4. `RoundAggregated` — Computes outcome
5. `ProvisionalOutcomeCreated` — Enters challenge window

**Stable Identifiers**:
- `claimId` correlates entire flow
- `roundId` correlates round-specific events
- `verificationId` correlates individual submissions

---

### 3. Dispute & Appeal Flow
**Required Events (in order)**:
1. `DisputeOpenedV1` — Challenge initiated
2. `ClaimStatusUpdated` (VerifiedTrue/False → Disputed)
3. `RoundOpened` (roundType=APPEAL) — Appeal round starts
4. `VerificationSubmitted` (appeal votes)
5. `RoundClosed` (appeal round)
6. `RoundAggregated` (appeal outcome)
7. `DisputeResolvedV1` — Final ruling

**Stable Identifiers**:
- `claimId` correlates entire flow
- `disputeId` correlates dispute events
- `roundId` correlates appeal round events

---

### 4. Settlement & Reward Flow
**Required Events (in order)**:
1. `ProvisionalOutcomeCreated` — Outcome established
2. `RewardAllocated` (per winner) — Rewards calculated
3. `ClaimSettled` (per beneficiary) — Tokens transferred
4. `BatchSettlementCompleted` — Batch marker
5. `RewardClaimed` (on-demand) — User claims reward

**Stable Identifiers**:
- `claimId` correlates to provisional outcome
- `settlementId` correlates settlement batch
- `distributionId` correlates individual reward claims

---

### 5. Slashing Flow
**Required Events (in order)**:
1. `VerificationSubmitted` (losing side)
2. [Settlement determines outcome]
3. `VerifierSlashed` — Slash executed
4. `StakeSlashed` — Custody updated

**Stable Identifiers**:
- `claimId` correlates claim context
- `verifier` correlates target account
- `verificationId` (implicit from claim+verifier lookup)

---

## Event Versioning Policy

### Current Version: 1

**Schema Stability Guarantee**: 
- Event signatures are immutable once deployed to mainnet
- Parameter order never changes
- Indexed field positions never change

**Additive Changes (same version)**:
✅ Adding new events
✅ Adding new fields to existing events (at end)
✅ Emitting events from new contracts

**Breaking Changes (requires version increment)**:
❌ Changing event name
❌ Changing parameter types
❌ Changing parameter order
❌ Changing indexed/unindexed status
❌ Removing fields

**Version Increments**:
- V1 → V2 example: `ClaimCreatedV2` alongside `ClaimCreatedV1`
- Old events continue emitting until contract deprecated
- Indexers must support multi-version ingestion

---

## Financial Reconciliation Invariants

### Balance Equations

**Verifier Stake Balance**:
```
balance(verifier) = 
  Σ StakeDeposited.amount 
  - Σ StakeWithdrawn.amount 
  - Σ StakeSlashed.amount
  + Σ StakeReleased.amount
```

**Claim Settlement Balance**:
```
totalSettled(claim) = 
  Σ ClaimSettled[claimId].amount
```

**Reward Pool Balance**:
```
rewardPool = 
  Σ RewardPoolFunded.amount 
  - Σ RewardDistributed.amount
  - Σ RewardClaimed.amount
```

**Reconciliation Test**: Every financial event total must equal on-chain storage query within dust threshold (1 wei)

---

## Indexer Ordering Requirements

### Log Ordering
Events must be processed in deterministic order:
1. `blockNumber` (ascending)
2. `transactionIndex` (ascending)
3. `logIndex` (ascending)

### Reorg Handling
On chain reorganization:
1. Identify highest safe block before reorg
2. Revert all events from orphaned blocks
3. Re-apply events from new canonical chain
4. Verify correlation key consistency

### Event Key for Deduplication
```
eventKey = keccak256(
  chainId,
  contractAddress,
  transactionHash,
  logIndex
)
```

---

## Read Model Reconstruction Examples

### Example 1: Claim Status Read Model
**Source Events**:
- `ClaimCreated`
- `ClaimStatusUpdated`

**Reconstruction Algorithm**:
```typescript
function rebuildClaimStatus(claimId: uint256): ClaimStatus {
  const created = findEvent('ClaimCreated', {claimId})
  const updates = findEvents('ClaimStatusUpdated', {claimId})
    .sort((a,b) => compareLogPosition(a, b))
  
  return updates.length > 0 
    ? updates[updates.length - 1].newStatus 
    : created.initialStatus
}
```

---

### Example 2: Round Participants Read Model
**Source Events**:
- `RoundOpened`
- `VerificationSubmitted`
- `RoundClosed`

**Reconstruction Algorithm**:
```typescript
function rebuildRoundParticipants(roundId: uint256) {
  const round = findEvent('RoundOpened', {roundId})
  const verifications = findEvents('VerificationSubmitted', {claimId: round.claimId})
    .filter(v => v.timestamp >= round.startedAt && v.timestamp <= round.deadline)
  
  return {
    roundId,
    participants: verifications.map(v => ({
      verifier: v.verifier,
      verdict: v.verdict,
      stake: v.stake,
      verificationId: v.verificationId
    })),
    totalVotes: verifications.length
  }
}
```

---

### Example 3: Verifier Balance Read Model
**Source Events**:
- `StakeDeposited`
- `StakeReleased`
- `StakeSlashed`
- `StakeWithdrawn`

**Reconstruction Algorithm**:
```typescript
function rebuildVerifierBalance(verifier: address): Balance {
  const deposits = sumAmounts(findEvents('StakeDeposited', {account: verifier}))
  const releases = sumAmounts(findEvents('StakeReleased', {account: verifier}))
  const slashes = sumAmounts(findEvents('StakeSlashed', {account: verifier}))
  const withdrawals = sumAmounts(findEvents('StakeWithdrawn', {verifier}))
  
  return {
    available: deposits + releases - withdrawals - slashes,
    locked: /* requires additional StakeLocked/Unlocked events */,
    total: deposits - withdrawals - slashes
  }
}
```

---

## Test Coverage Requirements

### 1. Event Emission Tests
✅ Every state-changing function emits expected event(s)
✅ Event parameters match function inputs/outputs
✅ Indexed fields are correctly marked

### 2. Event Ordering Tests
✅ Multi-event transactions emit in documented order
✅ Lifecycle flows emit required sequence
✅ Revert prevents emission

### 3. Correlation Key Tests
✅ claimId consistent across claim lifecycle
✅ roundId consistent across round lifecycle
✅ settlementId unique and non-replayable
✅ verificationId unique and monotonic

### 4. Financial Reconciliation Tests
✅ Event totals match storage after N transactions
✅ Slashing reduces balance correctly
✅ Reward distribution matches allocation

### 5. Snapshot Drift Tests
✅ ABI extraction matches source events
✅ Event signature hashes stable across commits
✅ No unauthorized event additions/removals

---

## Deployment Artifacts

### Required Snapshot Files
1. `event-abi-snapshot.json` — All event ABIs extracted from compiled artifacts
2. `event-signature-snapshot.json` — Event signature hashes (topic0)
3. `event-correlation-map.json` — Lifecycle correlation requirements
4. `event-version-manifest.json` — Schema version registry

### Generation Command
```bash
forge build --force
node scripts/generate-event-snapshots.js
```

### Snapshot Validation
```bash
npm run test:event-snapshots
```

---

## Legacy Event Exclusions

### Excluded V1 Events (Not in V2)
These events exist in legacy contracts but are NOT part of the V2 API boundary:

❌ Any event without `V1` suffix in `ITruthBountyEvents.sol`
❌ Events from contracts in `contracts/test/` directory
❌ Events from mock contracts
❌ Events from deprecated `TruthBounty.sol` (non-modular)

### Authority Validation
All events must be emitted by:
✅ Contracts with `REGISTRY_UPDATER_ROLE` or equivalent
✅ Contracts with explicit governance authorization
✅ Contracts in approved V2 deployment topology

❌ No events from EOA transactions (except claim creation)
❌ No events from unauthorized module addresses

---

## Audit Checklist

- [ ] All events documented with indexed/unindexed fields
- [ ] Correlation keys defined for every lifecycle
- [ ] Multi-event transitions documented
- [ ] Read model reconstruction algorithms provided
- [ ] Financial reconciliation equations verified
- [ ] Event ordering requirements specified
- [ ] Reorg handling procedures defined
- [ ] Test coverage requirements met
- [ ] Snapshot generation scripts working
- [ ] Legacy event exclusions validated
- [ ] No ambiguous authority patterns
- [ ] Schema version policy documented

---

## Next Steps

1. Generate ABI snapshots from compiled artifacts (Task #6)
2. Implement event ordering tests (Task #7)
3. Implement snapshot drift tests (Task #8)
4. Implement negative tests for legacy events (Task #9)
5. Create detailed read model reconstruction spec (Task #10)

---

## References

- **Event Architecture**: `docs/event-architecture.md`
- **Legacy Catalog**: `docs/event-catalogue-v1.md`
- **Interface Contract**: `contracts/interfaces/ITruthBountyEvents.sol`
- **V2 Contracts**: `contracts/` (excluding `test/` and `mocks/`)
- **Compiler Config**: `foundry.toml`
- **V2 Policy**: `.github/workflows/v2-policy-advisory.yml`
