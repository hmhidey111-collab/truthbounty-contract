# TruthBounty V2 Event-Based Read Model Reconstruction

## Purpose
This document specifies how the API and indexers reconstruct all approved read models from events plus declared view functions. It serves as the authoritative guide for building event-sourced projections that power the TruthBounty frontend and analytics.

---

## Architecture Overview

### Event Sourcing Principles
1. **Events as Source of Truth**: All state transitions are recorded as immutable events
2. **Deterministic Replay**: Same event sequence always produces same read model state
3. **View Functions for Snapshots**: On-chain view functions provide current state snapshots
4. **Event Validation**: Events + views must reconcile (events reconstruct to match views)

### Read Model Categories
- **Entity Models**: Claims, Rounds, Verifications, Disputes
- **Balance Models**: Verifier stakes, Reward pools, Treasury buckets
- **History Models**: Status transitions, Slash records, Reward distributions
- **Aggregate Models**: Claim statistics, Verifier performance, System metrics

---

## Core Entity Reconstruction

### Read Model 1: Claim Entity

#### Source Events
- `ClaimCreated(claimId, creator, evidenceCID)`
- `ClaimStatusUpdated(claimId, oldStatus, newStatus)`
- `RoundOpened(claimId, roundId, ...)`
- `RoundClosed(claimId, roundId, ...)`
- `ProvisionalOutcomeCreated(claimId, outcome, challengeDeadline, ...)`
- `DisputeOpenedV1(claimId, disputeId, ...)`
- `DisputeResolvedV1(claimId, disputeId, ...)`

#### View Functions
- `ClaimRegistry.getClaim(claimId) returns (Claim)`
- `ClaimRegistry.getClaimStatus(claimId) returns (ClaimStatus)`
- `ClaimRegistry.getClaimCreator(claimId) returns (address)`

#### Reconstruction Algorithm

```typescript
interface ClaimReadModel {
  claimId: bigint;
  creator: string;  // address
  evidenceCID: string;
  createdAt: bigint;  // timestamp
  verificationDeadline: bigint;
  
  // Status tracking
  status: ClaimStatus;
  statusHistory: StatusTransition[];
  
  // Lifecycle
  rounds: bigint[];  // roundIds
  currentRound: bigint | null;
  provisionalOutcome: Outcome | null;
  challengeDeadline: bigint | null;
  
  // Dispute
  disputeId: bigint | null;
  disputed: boolean;
  finalOutcome: Outcome | null;
}

function rebuildClaim(claimId: bigint, events: Event[]): ClaimReadModel {
  // 1. Find ClaimCreated
  const created = events.find(e => 
    e.name === 'ClaimCreated' && e.args.claimId === claimId
  );
  
  if (!created) {
    throw new Error(`Claim ${claimId} not found`);
  }
  
  const model: ClaimReadModel = {
    claimId,
    creator: created.args.creator,
    evidenceCID: created.args.evidenceCID,
    createdAt: created.blockTimestamp,
    verificationDeadline: 0n, // Extracted from getClaim view
    status: ClaimStatus.Pending,
    statusHistory: [],
    rounds: [],
    currentRound: null,
    provisionalOutcome: null,
    challengeDeadline: null,
    disputeId: null,
    disputed: false,
    finalOutcome: null,
  };
  
  // 2. Apply status updates
  const statusUpdates = events.filter(e => 
    e.name === 'ClaimStatusUpdated' && e.args.claimId === claimId
  ).sort((a, b) => compareLogPosition(a, b));
  
  for (const update of statusUpdates) {
    model.statusHistory.push({
      from: update.args.oldStatus,
      to: update.args.newStatus,
      timestamp: update.blockTimestamp,
      blockNumber: update.blockNumber,
    });
    model.status = update.args.newStatus;
  }
  
  // 3. Apply rounds
  const roundOpened = events.filter(e => 
    e.name === 'RoundOpened' && e.args.claimId === claimId
  );
  
  model.rounds = roundOpened.map(e => e.args.roundId);
  
  const lastRound = roundOpened[roundOpened.length - 1];
  if (lastRound) {
    const roundClosed = events.find(e => 
      e.name === 'RoundClosed' && e.args.roundId === lastRound.args.roundId
    );
    model.currentRound = roundClosed ? null : lastRound.args.roundId;
  }
  
  // 4. Apply provisional outcome
  const provisional = events.find(e => 
    e.name === 'ProvisionalOutcomeCreated' && e.args.claimId === claimId
  );
  
  if (provisional) {
    model.provisionalOutcome = provisional.args.outcome;
    model.challengeDeadline = provisional.args.challengeDeadline;
  }
  
  // 5. Apply dispute
  const dispute = events.find(e => 
    e.name === 'DisputeOpenedV1' && e.args.claimId === claimId
  );
  
  if (dispute) {
    model.disputeId = dispute.args.disputeId;
    model.disputed = true;
  }
  
  const resolution = events.find(e => 
    e.name === 'DisputeResolvedV1' && e.args.claimId === claimId
  );
  
  if (resolution) {
    model.finalOutcome = resolution.args.resultingOutcome;
  } else if (model.provisionalOutcome !== null) {
    // If challenge window passed, provisional becomes final
    const now = BigInt(Date.now()) / 1000n;
    if (model.challengeDeadline && now > model.challengeDeadline) {
      model.finalOutcome = model.provisionalOutcome;
    }
  }
  
  return model;
}
```

#### Validation Against View
```typescript
async function validateClaimModel(
  model: ClaimReadModel,
  registry: ClaimRegistry
): Promise<boolean> {
  const onChain = await registry.getClaim(model.claimId);
  
  return (
    model.creator === onChain.creator &&
    model.evidenceCID === onChain.evidenceCID &&
    model.status === onChain.status &&
    model.createdAt === onChain.createdAt
  );
}
```

---

### Read Model 2: Round Entity

#### Source Events
- `RoundOpened(claimId, roundId, roundType, startedAt, deadline, ...)`
- `VerificationSubmitted(claimId, verificationId, verifier, verdict, stake)`
- `RoundClosed(claimId, roundId, closedAt, totalVotes)`
- `RoundAggregated(claimId, outcome, confidence, trueWeight, falseWeight, ...)`

#### View Functions
- `VerificationRoundManager.getRound(roundId) returns (RoundParams)`
- `VerificationRoundManager.getParticipants(roundId, offset, limit) returns (ParticipantRecord[])`
- `VerificationRoundManager.getRoundState(roundId) returns (RoundState)`

#### Reconstruction Algorithm

```typescript
interface RoundReadModel {
  roundId: bigint;
  claimId: bigint;
  roundType: 'FIRST' | 'APPEAL';
  state: 'OPEN' | 'CLOSED';
  
  // Timing
  startedAt: bigint;
  deadline: bigint;
  closedAt: bigint | null;
  
  // Parameters
  minStake: bigint;
  maxStake: bigint;
  weightCap: bigint;
  passingThreshold: number;  // basis points
  paramVersion: number;
  
  // Participation
  participants: Participant[];
  totalVotes: number;
  
  // Outcome
  aggregated: boolean;
  outcome: Outcome | null;
  trueWeight: bigint;
  falseWeight: bigint;
  confidence: bigint;
}

interface Participant {
  verifier: string;
  verificationId: bigint;
  verdict: 'TRUE' | 'FALSE';
  stake: bigint;
  submittedAt: bigint;
}

function rebuildRound(roundId: bigint, events: Event[]): RoundReadModel {
  // 1. Find RoundOpened
  const opened = events.find(e => 
    e.name === 'RoundOpened' && e.args.roundId === roundId
  );
  
  if (!opened) {
    throw new Error(`Round ${roundId} not found`);
  }
  
  const model: RoundReadModel = {
    roundId,
    claimId: opened.args.claimId,
    roundType: opened.args.roundType === 0 ? 'FIRST' : 'APPEAL',
    state: 'OPEN',
    startedAt: opened.args.startedAt,
    deadline: opened.args.deadline,
    closedAt: null,
    minStake: opened.args.minStake,
    maxStake: opened.args.maxStake,
    weightCap: opened.args.weightCap,
    passingThreshold: opened.args.passingThreshold,
    paramVersion: opened.args.paramVersion,
    participants: [],
    totalVotes: 0,
    aggregated: false,
    outcome: null,
    trueWeight: 0n,
    falseWeight: 0n,
    confidence: 0n,
  };
  
  // 2. Collect participants
  const verifications = events.filter(e => 
    e.name === 'VerificationSubmitted' && 
    e.args.claimId === model.claimId &&
    e.blockTimestamp >= model.startedAt &&
    e.blockTimestamp <= model.deadline
  ).sort((a, b) => compareLogPosition(a, b));
  
  model.participants = verifications.map(e => ({
    verifier: e.args.verifier,
    verificationId: e.args.verificationId,
    verdict: e.args.verdict === 0 ? 'TRUE' : 'FALSE',
    stake: e.args.stake,
    submittedAt: e.blockTimestamp,
  }));
  
  // 3. Check if closed
  const closed = events.find(e => 
    e.name === 'RoundClosed' && e.args.roundId === roundId
  );
  
  if (closed) {
    model.state = 'CLOSED';
    model.closedAt = closed.args.closedAt;
    model.totalVotes = Number(closed.args.totalVotes);
  }
  
  // 4. Apply aggregation
  const aggregated = events.find(e => 
    e.name === 'RoundAggregated' && e.args.claimId === model.claimId
  );
  
  if (aggregated) {
    model.aggregated = true;
    model.outcome = aggregated.args.outcome;
    model.trueWeight = aggregated.args.trueWeight;
    model.falseWeight = aggregated.args.falseWeight;
    model.confidence = aggregated.args.confidence;
  }
  
  return model;
}
```

---

### Read Model 3: Verifier Balance

#### Source Events
- `StakeDeposited(account, claimId, amount, timestamp, version)`
- `StakeReleased(account, claimId, amount, timestamp, version)`
- `StakeSlashed(account, claimId, amount, reason, timestamp, version)`
- `StakeWithdrawn(verifier, amount, timestamp, version)`  // From legacy events

#### View Functions
- `StakeCustody.getBalance(account) returns (uint256)`
- `StakeCustody.getLockedBalance(account) returns (uint256)`

#### Reconstruction Algorithm

```typescript
interface VerifierBalanceReadModel {
  verifier: string;
  
  // Balances
  totalDeposited: bigint;
  totalWithdrawn: bigint;
  totalSlashed: bigint;
  availableBalance: bigint;
  lockedBalance: bigint;
  
  // History
  deposits: DepositRecord[];
  withdrawals: WithdrawalRecord[];
  slashes: SlashRecord[];
  locks: LockRecord[];
  releases: ReleaseRecord[];
}

function rebuildVerifierBalance(
  verifier: string,
  events: Event[]
): VerifierBalanceReadModel {
  const model: VerifierBalanceReadModel = {
    verifier,
    totalDeposited: 0n,
    totalWithdrawn: 0n,
    totalSlashed: 0n,
    availableBalance: 0n,
    lockedBalance: 0n,
    deposits: [],
    withdrawals: [],
    slashes: [],
    locks: [],
    releases: [],
  };
  
  // Process deposits
  const deposits = events.filter(e => 
    e.name === 'StakeDeposited' && e.args.account === verifier
  ).sort((a, b) => compareLogPosition(a, b));
  
  for (const deposit of deposits) {
    model.totalDeposited += deposit.args.amount;
    model.deposits.push({
      amount: deposit.args.amount,
      claimId: deposit.args.claimId,
      timestamp: deposit.args.timestamp,
      txHash: deposit.transactionHash,
    });
  }
  
  // Process withdrawals
  const withdrawals = events.filter(e => 
    e.name === 'StakeWithdrawn' && e.args.verifier === verifier
  );
  
  for (const withdrawal of withdrawals) {
    model.totalWithdrawn += withdrawal.args.amount;
    model.withdrawals.push({
      amount: withdrawal.args.amount,
      timestamp: withdrawal.blockTimestamp,
      txHash: withdrawal.transactionHash,
    });
  }
  
  // Process slashes
  const slashes = events.filter(e => 
    e.name === 'StakeSlashed' && e.args.account === verifier
  );
  
  for (const slash of slashes) {
    model.totalSlashed += slash.args.amount;
    model.slashes.push({
      amount: slash.args.amount,
      claimId: slash.args.claimId,
      reason: slash.args.reason,
      timestamp: slash.args.timestamp,
      txHash: slash.transactionHash,
    });
  }
  
  // Process releases (locked → available)
  const releases = events.filter(e => 
    e.name === 'StakeReleased' && e.args.account === verifier
  );
  
  for (const release of releases) {
    model.releases.push({
      amount: release.args.amount,
      claimId: release.args.claimId,
      timestamp: release.args.timestamp,
      txHash: release.transactionHash,
    });
  }
  
  // Calculate available balance
  model.availableBalance = 
    model.totalDeposited - 
    model.totalWithdrawn - 
    model.totalSlashed;
  
  // Note: Locked balance requires tracking active verifications
  // This would sum stakes in open rounds where verifier participated
  
  return model;
}
```

#### Financial Reconciliation
```typescript
async function validateVerifierBalance(
  model: VerifierBalanceReadModel,
  custody: StakeCustody
): Promise<boolean> {
  const onChainBalance = await custody.getBalance(model.verifier);
  const onChainLocked = await custody.getLockedBalance(model.verifier);
  
  const totalFromEvents = 
    model.availableBalance + model.lockedBalance;
  const totalOnChain = onChainBalance + onChainLocked;
  
  // Allow 1 wei tolerance for rounding
  const diff = totalFromEvents > totalOnChain 
    ? totalFromEvents - totalOnChain 
    : totalOnChain - totalFromEvents;
  
  return diff <= 1n;
}
```

---

## Aggregate Projections

### Read Model 4: Claim Statistics (System-Wide)

```typescript
interface ClaimStatsReadModel {
  // Counts
  totalClaims: number;
  claimsByStatus: Record<ClaimStatus, number>;
  claimsDisputed: number;
  
  // Outcomes
  verifiedTrue: number;
  verifiedFalse: number;
  inconclusive: number;
  
  // Participation
  totalVerifications: number;
  uniqueVerifiers: Set<string>;
  averageVerificationsPerClaim: number;
}

function rebuildClaimStats(events: Event[]): ClaimStatsReadModel {
  const model: ClaimStatsReadModel = {
    totalClaims: 0,
    claimsByStatus: {},
    claimsDisputed: 0,
    verifiedTrue: 0,
    verifiedFalse: 0,
    inconclusive: 0,
    totalVerifications: 0,
    uniqueVerifiers: new Set(),
    averageVerificationsPerClaim: 0,
  };
  
  // Count ClaimCreated
  model.totalClaims = events.filter(e => 
    e.name === 'ClaimCreated'
  ).length;
  
  // Track current status per claim
  const claimStatus = new Map<bigint, ClaimStatus>();
  
  events.filter(e => e.name === 'ClaimStatusUpdated')
    .sort((a, b) => compareLogPosition(a, b))
    .forEach(e => {
      claimStatus.set(e.args.claimId, e.args.newStatus);
    });
  
  // Aggregate by status
  for (const status of claimStatus.values()) {
    model.claimsByStatus[status] = 
      (model.claimsByStatus[status] || 0) + 1;
  }
  
  // Count disputes
  model.claimsDisputed = events.filter(e => 
    e.name === 'DisputeOpenedV1'
  ).length;
  
  // Count outcomes
  events.filter(e => e.name === 'ProvisionalOutcomeCreated')
    .forEach(e => {
      switch (e.args.outcome) {
        case Outcome.VERIFIED_TRUE:
          model.verifiedTrue++;
          break;
        case Outcome.VERIFIED_FALSE:
          model.verifiedFalse++;
          break;
        case Outcome.INCONCLUSIVE:
          model.inconclusive++;
          break;
      }
    });
  
  // Count verifications
  const verifications = events.filter(e => 
    e.name === 'VerificationSubmitted'
  );
  
  model.totalVerifications = verifications.length;
  
  verifications.forEach(e => {
    model.uniqueVerifiers.add(e.args.verifier);
  });
  
  model.averageVerificationsPerClaim = 
    model.totalClaims > 0 
      ? model.totalVerifications / model.totalClaims 
      : 0;
  
  return model;
}
```

---

## Read Model Update Strategies

### Strategy 1: Full Replay (Cold Start)
```typescript
async function fullReplay(fromBlock: bigint, toBlock: bigint) {
  console.log('Starting full event replay...');
  
  // 1. Fetch all events
  const allEvents = await fetchEventsInRange(fromBlock, toBlock);
  console.log(`Fetched ${allEvents.length} events`);
  
  // 2. Sort deterministically
  allEvents.sort(compareLogPosition);
  
  // 3. Rebuild all models
  const claims = new Map<bigint, ClaimReadModel>();
  const rounds = new Map<bigint, RoundReadModel>();
  const balances = new Map<string, VerifierBalanceReadModel>();
  
  for (const event of allEvents) {
    switch (event.name) {
      case 'ClaimCreated':
        const claimId = event.args.claimId;
        claims.set(claimId, rebuildClaim(claimId, allEvents));
        break;
        
      case 'RoundOpened':
        const roundId = event.args.roundId;
        rounds.set(roundId, rebuildRound(roundId, allEvents));
        break;
        
      case 'StakeDeposited':
      case 'StakeSlashed':
      case 'StakeReleased':
        const verifier = event.args.account || event.args.verifier;
        if (!balances.has(verifier)) {
          balances.set(verifier, rebuildVerifierBalance(verifier, allEvents));
        }
        break;
    }
  }
  
  // 4. Validate against on-chain views
  for (const [claimId, model] of claims) {
    const valid = await validateClaimModel(model, registry);
    if (!valid) {
      throw new Error(`Claim ${claimId} failed validation`);
    }
  }
  
  console.log('Full replay complete');
  return { claims, rounds, balances };
}
```

### Strategy 2: Incremental Update (Real-Time)
```typescript
async function incrementalUpdate(
  lastProcessedBlock: bigint,
  currentModels: ReadModels
) {
  // 1. Fetch new events since last block
  const newEvents = await fetchEventsSince(lastProcessedBlock);
  
  if (newEvents.length === 0) {
    return currentModels;
  }
  
  // 2. Group by entity
  const affectedClaims = new Set<bigint>();
  const affectedRounds = new Set<bigint>();
  const affectedVerifiers = new Set<string>();
  
  for (const event of newEvents) {
    if ('claimId' in event.args) {
      affectedClaims.add(event.args.claimId);
    }
    if ('roundId' in event.args) {
      affectedRounds.add(event.args.roundId);
    }
    if ('verifier' in event.args || 'account' in event.args) {
      affectedVerifiers.add(event.args.verifier || event.args.account);
    }
  }
  
  // 3. Rebuild only affected entities
  for (const claimId of affectedClaims) {
    const claimEvents = getAllEventsForClaim(claimId);
    currentModels.claims.set(claimId, rebuildClaim(claimId, claimEvents));
  }
  
  for (const roundId of affectedRounds) {
    const roundEvents = getAllEventsForRound(roundId);
    currentModels.rounds.set(roundId, rebuildRound(roundId, roundEvents));
  }
  
  for (const verifier of affectedVerifiers) {
    const balanceEvents = getAllEventsForVerifier(verifier);
    currentModels.balances.set(verifier, rebuildVerifierBalance(verifier, balanceEvents));
  }
  
  return currentModels;
}
```

### Strategy 3: Snapshot + Delta
```typescript
interface Snapshot {
  blockNumber: bigint;
  models: ReadModels;
  checksum: string;
}

async function snapshotWithDelta() {
  // 1. Load latest snapshot
  const snapshot = await loadLatestSnapshot();
  
  // 2. Apply events since snapshot
  const models = await incrementalUpdate(
    snapshot.blockNumber,
    snapshot.models
  );
  
  // 3. Periodically create new snapshot
  const currentBlock = await getCurrentBlock();
  const blocksSinceSnapshot = currentBlock - snapshot.blockNumber;
  
  if (blocksSinceSnapshot > SNAPSHOT_INTERVAL) {
    await saveSnapshot({
      blockNumber: currentBlock,
      models,
      checksum: computeChecksum(models),
    });
  }
  
  return models;
}
```

---

## Reorg Handling

```typescript
async function handleReorg(
  safeBlock: bigint,
  newCanonicalChain: Event[]
) {
  console.log(`Reorg detected, reverting to block ${safeBlock}`);
  
  // 1. Load snapshot at or before safe block
  const snapshot = await loadSnapshotAt(safeBlock);
  
  // 2. Identify orphaned events
  const orphanedEvents = await getEventsInOrphanedBlocks();
  console.log(`Reverting ${orphanedEvents.length} orphaned events`);
  
  // 3. Rebuild from snapshot with new canonical chain
  const canonicalEvents = newCanonicalChain.filter(e => 
    e.blockNumber > safeBlock
  );
  
  const models = await incrementalUpdate(
    snapshot.blockNumber,
    snapshot.models,
    canonicalEvents
  );
  
  // 4. Validate correlation keys still consistent
  await validateCorrelationIntegrity(models);
  
  console.log('Reorg handled successfully');
  return models;
}
```

---

## Testing Read Model Reconstruction

```typescript
describe('Read Model Reconstruction', () => {
  it('should rebuild claim from events matching on-chain view', async () => {
    // Emit events
    await registry.createClaim(statement, evidenceCID, deadline);
    
    // Capture events
    const events = await captureAllEvents();
    
    // Rebuild
    const model = rebuildClaim(1n, events);
    
    // Validate
    const onChain = await registry.getClaim(1n);
    expect(model.creator).to.equal(onChain.creator);
    expect(model.status).to.equal(onChain.status);
  });
  
  it('should handle event replay in different order', async () => {
    // Get events
    const events = await captureAllEvents();
    
    // Shuffle (but maintain block/tx/log order within each block)
    const shuffled = shuffleWithinBlocks(events);
    
    // Rebuild from both
    const model1 = rebuildClaim(1n, events);
    const model2 = rebuildClaim(1n, shuffled);
    
    // Should be identical
    expect(model1).to.deep.equal(model2);
  });
  
  it('should reconcile financial events to storage balance', async () => {
    // Execute stake operations
    await custody.deposit(verifier, 1000e18);
    await custody.slash(verifier, claimId, 100e18);
    await custody.release(verifier, claimId, 500e18);
    
    // Rebuild balance from events
    const events = await captureAllEvents();
    const model = rebuildVerifierBalance(verifier, events);
    
    // Validate against on-chain
    const onChainBalance = await custody.getBalance(verifier);
    expect(model.availableBalance).to.equal(onChainBalance);
  });
});
```

---

## API Integration Example

```typescript
// Express.js endpoint using event-sourced read models
app.get('/api/claims/:claimId', async (req, res) => {
  const claimId = BigInt(req.params.claimId);
  
  // Option 1: Use cached read model
  let model = readModelCache.get(claimId);
  
  if (!model) {
    // Option 2: Rebuild from events
    const events = await eventStore.getEventsForClaim(claimId);
    model = rebuildClaim(claimId, events);
    readModelCache.set(claimId, model);
  }
  
  // Option 3: Validate against on-chain view
  const onChain = await registry.getClaim(claimId);
  if (model.status !== onChain.status) {
    console.warn('Read model out of sync, rebuilding...');
    const events = await eventStore.getEventsForClaim(claimId);
    model = rebuildClaim(claimId, events);
    readModelCache.set(claimId, model);
  }
  
  res.json(model);
});
```

---

## Summary

This specification enables:
- ✅ Complete state reconstruction from events alone
- ✅ Validation against on-chain view functions
- ✅ Financial reconciliation within 1 wei tolerance
- ✅ Reorg handling with deterministic replay
- ✅ Incremental updates for real-time systems
- ✅ API integration with cached projections

All read models must pass the validation test:
```
Events → Rebuild → Model ≈ On-Chain View (within tolerance)
```
