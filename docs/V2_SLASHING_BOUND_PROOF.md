# V2 Slashing Bound: Cumulative Slashing Cannot Exceed Locked Principal (V2-SC-097)

Slashing must never take more from an actor than that actor actually locked, no matter how many separate calls arrive, which module makes them, or how principal moves between rounds during appeals and retries.

Enforced by `contracts/v2/StakeVault.sol`. Proved by `test/v2/invariant/StakeVaultSlashingInvariant.t.sol`.

## The unit of account is a lock cell

All custody accounting is keyed by a five-part tuple, hashed by `StakeVault._lockKey`:

```
cell = (asset, account, claimId, round, category)
```

The bound is a per-cell statement. "The principal locked for an actor and a round" is exactly `_locks[cell]` and its history -- not a per-account total, and not a per-claim total. Getting this wrong in either direction produces a bound that is either unprovable or trivially true.

## The claim

For every cell, across the whole lifetime of the protocol:

```
totalSlashedOut(cell) <= totalLockedIn(cell) + totalMovedIn(cell)
```

and, more strongly, flows balance exactly:

```
_locks[cell] == (totalLockedIn + totalMovedIn) - (totalSlashedOut + totalUnlockedOut + totalMovedOut)
```

The second statement implies the first and rules out the cheap way to satisfy a bound: losing principal somewhere else so that less appears to have been slashed.

## Why `movedIn` has to be in the bound

Appeals and retries move principal between rounds without touching custody totals:

- `carryForwardAppeal(asset, account, claimId, fromRound, toRound, amount)`
- `rolloverRound(asset, account, claimId, fromRound, toRound, amount)`

Both call `_moveLock`, which decrements the source cell and increments the destination. The destination round therefore holds slashable principal that was **never deposited into it directly**.

A bound written only against direct deposits would report a false violation the first time an appealed stake is slashed at the destination round. A bound that ignored the *source* side would let the same principal be slashed twice -- once at each round. Tracking both sides is what makes the statement both true and non-vacuous. `test_handlerReachesLockSlashAppealAndSettlement` exercises exactly this path and asserts `lockedIn(round 1) == 0` while principal is slashed there.

## Every surface that can reduce a lock

| Entry point | Authorization | Effect on the cell |
| --- | --- | --- |
| `slashStake` | tier 1 (mutator) | slash, round 0 just |
| `allocateLocked` | tier 1 (mutator) | slash, any round |
| `releaseStake` | tier 1 (mutator) | unlock to claimable, round 0 |
| `unlock` | tier 1 (mutator) | unlock to claimable |
| `settleConclusive` | tier 2 (settlement) | unlock principal, credit reward |
| `refundInconclusive` | tier 2 (settlement) | unlock to claimable |
| `finalUnlock` | tier 2 (settlement) | unlock to claimable |
| `carryForwardAppeal` | tier 2 (settlement) | move to a later round |
| `rolloverRound` | tier 2 (settlement) | move to a later round |

Both slashing surfaces and every non-slashing outflow are modelled in the handler. Omitting a non-slashing outflow would make the bound easier to satisfy and the proof worthless.

## How the bound is enforced in code

Nothing in the bound relies on the caller being well-behaved:

1. `_slash` reads `_locks[key]` and reverts with `InsufficientLocked(amount, locked)` when `locked < amount`. A slash can therefore never exceed what the cell holds at that moment.
2. Because every slash is bounded by the live lock, and the live lock only ever grows through `_lock` or `_moveLock`, cumulative slashing is bounded by cumulative inflow. Solidity 0.8 checked arithmetic makes the underflow route unavailable as well.
3. `_assertReconciliation` runs at the end of every mutation and reverts unless `custody == obligations == actualBalance`. A slash that reduced a lock without adding the same amount to protocol allocation would fail here.
4. `_assertSettlementNotFinalized` makes every settlement hook single-shot per `(claimId, round)`, which is the replay bound on the transitions that move principal between rounds.

## Slashed value is reclassified, never minted

Slashing moves value from `_assetTotalLocked` to `_protocolAllocation`. It is not a transfer, and custody totals do not change. Rewards are then funded *from* that allocation by `_creditReward`, which reverts with `InsufficientProtocolAllocation` if the allocation is short. Hence:

```
protocolAllocation(asset) == totalSlashed - totalRewardCredited
totalRewardCredited       <= totalSlashed
```

The protocol can never pay out a reward it did not first take.

## Invariants asserted

From `StakeVaultSlashingInvariantTest`:

| Invariant | Statement |
| --- | --- |
| `invariant_cumulativeSlashingNeverExceedsPrincipalIn` | the V2-SC-097 claim, per cell |
| `invariant_cellFlowsBalanceExactly` | exact per-cell flow conservation |
| `invariant_liveLockNeverExceedsPrincipalIn` | a lock never exceeds its inflow |
| `invariant_protocolAllocationIsSlashedMinusRewarded` | slashed value is reclassified, not minted |
| `invariant_rewardsNeverExceedSlashed` | rewards are funded from slashing |
| `invariant_custodyObligationsAndBalanceAgree` | custody conservation |
| `invariant_totalSlashedBoundedByCustody` | allocation never exceeds custody |

Ghost counters are updated **only** on the success branch of each `try`, so a reverted call leaves the ledger untouched and the invariants are never checked against a history that did not happen.

## Note on harness design

Two properties of the harness matter as much as the invariants:

- **The fuzz target is the handler, not the vault.** Targeting the vault has the fuzzer call it directly from random senders with random arguments; every authorized path then fails `_onlyAuthorizedMutator`, the handler never runs, and the invariants hold vacuously against an empty vault. `test/v2/StakeVaultInvariant.t.sol` had this defect and is corrected in this change.
- **The cell space is small on purpose** -- 3 accounts, 2 claims, 3 rounds. A slashing bound is only interesting when many operations land on the *same* cell. A wide key space means the fuzzer almost never collides and the run proves nothing, however many calls it makes.

`test_handlerReachesLockSlashAppealAndSettlement` is a deterministic coverage guard: it drives the handler directly and asserts that the lock, both slash surfaces, the appeal path, and settlement are all reachable. Without a guard of that kind, a handler that silently reverted on every call would leave every invariant above trivially satisfied.

## Source of truth

`_locks`, `_protocolAllocation` and `_totalCustody` in the canonical vault are authoritative. Slashing events are a projection and carry no authority.
