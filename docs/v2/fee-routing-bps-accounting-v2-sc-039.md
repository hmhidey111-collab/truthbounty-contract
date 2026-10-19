# V2 Fee Routing and Basis-Point Accounting Inventory (V2-SC-039)

This document is the canonical inventory of **every fee source and destination** in the
approved Optimism/EVM V2 topology, together with the bound, rounding, routing, and
event-attribution rule that applies to each one. It is enforced by
`test/v2/V2SC039FeeRoutingAccounting.t.sol`.

## The five rules

1. **Bounded BPS totals.** Every basis-point parameter is in `[0, 10000]`. Every routing
   table's *active* shares sum to **exactly** 10000 before it can take effect. There is no
   configuration in which a fee is split into less than all of itself or more than all of it.
2. **One fee, one route.** A fee moves from its source to its destination exactly once per
   economic event. Duplicate categories per settlement, duplicate routing-table names, and
   duplicate fee records are rejected, and finalization/single-shot guards make replaying a
   routing impossible.
3. **No fee-on-fee.** Fees are computed once from a gross base and are never re-applied to
   amounts that already had a fee deducted or routed. Submission fees are charged *on top
   of* (never from) escrowed value, and distribution transfers shares of the reserved gross
   with no deduction.
4. **Explicit dust ownership.** Integer division rounds down, and every truncation
   remainder is credited to an explicitly named owner — the settlement module's
   `remainderRecipient` per category, or the canonical `TREASURY_RESERVE` allocation in the
   FeeManager. Dust is never stranded and never silently absorbed.
5. **Exact integer event attribution.** Every routing emits the exact integer amount that
   moved, attributed to the fee type / category / allocation name and the recipient. Events
   are a projection of the ledger; the ledgers below are authoritative.

## Fee inventory

| # | Source (who charges) | Fee | Basis | Destination(s) | Rounding / dust | Events (exact integers) |
|---|---|---|---|---|---|---|
| 1 | `contracts/v2/Claims.sol` — `createClaim` | `claimSubmissionFee` | flat, governance-set (`setAntiGriefParams`) | `feeRecipient` (single pull destination) | none — a flat integer amount is routed whole; charged *on top of* the escrowed `reward` | `ClaimFeeCharged(claimId, payer, feeRecipient, amount)` (exactly one per paid claim), `AntiGriefParamsUpdated` |
| 2 | `contracts/v2/FinalRewardAllocator.sol` — `finalizeRewards` (`PROTOCOL_FEE` category) | protocol share of a funded settlement pool | pro-rata by `effectiveWeights`, category `amount` supplied once by the registered `SETTLEMENT` module | category `accounts[]` plus an explicit `remainderRecipient` per category | shares round down (`V2Precision.mulDivDown`, 512-bit); shortfall to `remainderRecipient`; `sum(credited) == amount` exactly | `RewardAllocated(settlementId, category, asset, account, amount)`, `RewardsFinalized(settlementId, asset, outcome, totalAmount)` |
| 3 | `contracts/fees/FeeManager.sol` — `collectFee` + `distributeReservedFees` | versioned schedules: `fixedAmount + base * basisPoints / 10000`, clamped to `[minValue, maxValue]` | BPS: `basisPoints <= 10000`; routing table: active targets sum to **exactly** 10000 | allocation targets (`TREASURY_RESERVE` 40%, `SECURITY_FUND` 20%, `ECOSYSTEM_FUND` 20%, `CONTRIBUTOR_INCENTIVES` 10%, `EMERGENCY_RESERVE` 10% by default) | shares round down; `TREASURY_RESERVE` receives the remainder (deterministic, name-canonical, order-independent) | `FeeCollected(feeType, payer, amount)`, `FeeDistributed(allocation, amount)`, `ReservedFeesAdded`, `FeesDistributedDeterministically`, `FeeScheduleConfigUpdated(feeType, fixed, bps, min, max, govVersion)` |

### Declared but not yet implemented

- `contracts/v2/interfaces/ISettlement.sol` declares `fee` (protocol fee in asset base
  units) with `SettlementQueued(claimId, recipient, grossAmount, fee, executableAt)` and the
  net-is-gross-minus-fee rule. **No settlement implementation exists yet.** Whoever lands it
  must keep `fee <= grossAmount`, emit the exact integers, and route the fee exactly once;
  the allocator (row 2) is the canonical destination for protocol-fee value.
- `contracts/TruthBountyWeighted.sol` and other V1-era modules contain legacy, in-module fee
  arithmetic (`protocolFeePercent`). They are outside the approved V2 topology and are
  frozen as legacy surface; no V2 module may call into them for fee logic.

## Conservation equations

For every fee path the following hold exactly, with no tolerated drift:

```
FeeManager:  totalCollected == totalDistributed + reserved
             contract balance == reserved                (nothing is stranded)
             sum(FeeDistributed amounts per batch) == reserved at batch start

Allocator:   sum(credited per category) == category.amount
             funded[settlementId] - allocated[settlementId] == unallocated pool
             sum(claimed) + sum(claimable) == allocated

Claims:      escrow balance == sum(rewards of OPEN claims)
             feeRecipient received == sum(ClaimFeeCharged amounts)   (each fee once)
             cancelClaim refunds `reward` only — the fee is never refunded twice
```

## Anti-patterns this inventory forbids

- **Fee-on-fee**: computing a percentage fee on an amount that already had a fee taken
  (e.g. applying a BPS schedule to a net payout instead of the gross base, or re-routing
  `PROTOCOL_FEE` value through a second schedule). The submission fee is charged on top of
  the bounty, and every BPS fee names its gross base exactly once.
- **Duplicate routing**: two active allocation targets sharing one name (merged, then
  unauditable attribution), two allocations sharing one `RewardCategory` in a settlement
  (`DuplicateCategory`), re-finalizing a settlement (`SettlementAlreadyFinalized`), or
  replaying a fee record (`DuplicateFeeRecord`).
- **Silent dust**: any split whose truncation remainder has no named owner.
- **Retargeted reservations**: swapping the FeeManager's fee token while fees are reserved
  (`ReservedFeesOutstanding`) would pay out one asset for amounts collected in another.

## Configuration-change semantics

- Fee-schedule updates are versioned (`getFeeScheduleAtVersion`, `globalGovVersion`) and
  emit the full new schedule with exact integers (`FeeScheduleConfigUpdated`). Only
  *subsequent* collections use the new schedule; existing records are immutable.
- Replacing the FeeManager routing table affects *subsequent* distributions, including
  fees already reserved but not yet distributed — this is explicit: distribution always
  uses the current, governance-approved table, and `AllocationTargetsUpdated` records the
  change.
- Changing `Claims.claimSubmissionFee` / `feeRecipient` affects only subsequent claims.

## Authority and pause model (unchanged)

- `Claims`: fee parameters are `ADMIN_ROLE`-gated and fail closed under `SCOPE_GOVERNANCE`;
  `createClaim` fails closed under `SCOPE_CLAIMS`.
- `FinalRewardAllocator`: only the registry-resolved `SETTLEMENT` module funds/finalizes;
  fails closed under `SCOPE_SETTLEMENT`; claims are RISK_REDUCING exits (SHUTDOWN only).
- `FeeManager`: collection is `COLLECTOR_ROLE`-gated and pausable; schedule/routing changes
  are `onlyGovernanceOrAdmin` (deprecated in V2 in favour of `ParameterVersionRegistry`).

No authority, interface, or storage-layout change is introduced by SC-039; the added events
and errors are purely additive.

## Source of truth

The on-chain ledgers (`FeeManager` accounting, `FinalRewardAllocator.claimable`, `Claims`
escrow) are authoritative. Events, indexers, and backends are projections and carry no
authority. This document and `test/v2/V2SC039FeeRoutingAccounting.t.sol` are the release
gate for this boundary.
