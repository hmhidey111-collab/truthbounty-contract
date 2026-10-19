# Treasury Insolvency & Recovery Model (V2-SC-107)

## Overview

V2-SC-107 adds an **advisory, isolated model** of treasury insolvency and recovery so that
insufficient liquidity, delayed allocation, partial obligations, emergency pause, governance
recovery, and post-recovery reconciliation can be projected deterministically and reconciled
against the canonical `TreasuryManagement` pool ledger — **without haircut ambiguity**.

The model holds no tokens, exposes no transfer path, and can never mutate
`TreasuryManagement`, `InsuranceFund`, `FeeManager`, or any other canonical module. It only
stores append-only projection reports. Production settlement remains pull-based and
authoritative in the Optimism/EVM protocol contracts.

## Components

| Path | Role |
|------|------|
| `contracts/treasury/ITreasuryInsolvencyModel.sol` | Types, events, errors, and public API |
| `contracts/treasury/TreasuryInsolvencyModel.sol` | Deterministic scenario engine + append-only report ledger |
| `test/treasury/TreasuryInsolvencyModel.t.sol` | Unit, boundary, authorization, replay, and fuzz tests |
| `test/invariant/TreasuryInsolvencyHandler.sol` | Stateful handler (ghost accounting) |
| `test/invariant/TreasuryInsolvencyInvariant.t.sol` | Stateful invariant suite |

## Module Boundaries and Authority

- **No value custody.** The model has no token, no payable function, and no transfer surface.
  Its ETH balance is asserted to remain zero by an invariant.
- **No protocol mutation.** All engine computation is pure memory; the only writes are to the
  model's own report ledger and its one-way reconciliation marker.
- **No privileged shortcut.** Roles (`ADMIN_ROLE`, `MODELER_ROLE`, `PAUSER_ROLE`) gate *model
  bookkeeping only*. They cannot settle, disburse, slash, or pause any protocol module.
- **Reconciliation is projection, not settlement.** A report is a proposed allocation. Actual
  value movement must go through the canonical treasury/settlement paths.

### Trust boundaries

| Actor | Can do | Cannot do |
|-------|--------|-----------|
| `MODELER_ROLE` | Persist runs, reconcile a base report once | Move protocol funds, change live treasury state |
| `ADMIN_ROLE` | Set warning thresholds, manage roles | Grant any settlement/treasury authority |
| `PAUSER_ROLE` | Pause the *model surface* | Pause or unpause protocol contracts |
| Any external caller | Call `previewModel` / `validateInput` / views | Persist runs or reconcile |

## Obligation Priority (canonical waterfall order)

Lower index = more senior. Senior classes are funded first.

| Index | Class | Nature |
|-------|-------|--------|
| 0 | `SETTLEMENT` | Claim settlement payouts (highest priority) |
| 1 | `STAKING_PRINCIPAL` | Staker principal withdrawals |
| 2 | `INSURANCE` | Insurance fund claim payouts |
| 3 | `REWARDS` | Verifier reward distributions |
| 4 | `OPERATIONAL` | Ecosystem / operational spend |
| 5 | `DISCRETIONARY` | Governance discretionary spend (lowest priority) |

## Haircut Disambiguation

Every run applies exactly one explicit policy. There is no implicit or emergent haircut.

| Policy | Rule |
|--------|------|
| `PRO_RATA` | Each **due** obligation receives `floor(liquidity * amount_i / dueTotal)`, capped at `amount_i`. |
| `PRIORITY_WATERFALL` | Senior due classes are funded in full; the first underfunded class is paid pro-rata; every junior class is deferred with zero allocation. |
| `DEFER` | Nothing is allocated; every obligation is deferred. |
| `PAUSE_THEN_DEFER` | Emergency freeze; identical to `DEFER` and records `paused = true`. |

### Rounding rule (deterministic, no residual ambiguity)

All divisions floor (protocol-favouring rounding) and the **residual is retained**, never
distributed. Therefore:

- no obligation is ever over-paid (`paid_i <= amount_i`);
- `totalPaid <= effectiveLiquidity` always holds;
- `totalPaid + totalDeferred == totalObligations` always holds.

The engine never reads ambient randomness and never sorts caller input, so identical
`(input, block.timestamp, block.number)` always yields byte-identical metrics.

## Scenarios

| Scenario | Inputs | Meaning |
|----------|--------|---------|
| `SOLVENT_BASELINE` | no cap, no injection, not paused | Control: full coverage, zero haircut |
| `INSUFFICIENT_LIQUIDITY` | no cap, no injection, not paused | Assets < obligations; one deterministic haircut |
| `DELAYED_ALLOCATION` | `allocationCap > 0`; obligations may be future-dated | Per-epoch release budget and/or not-yet-due ledger |
| `PARTIAL_OBLIGATION` | no cap/injection; waterfall marginal class underfunded | Partial class funding, remainder deferred |
| `EMERGENCY_PAUSE` | `paused = true`, `PAUSE_THEN_DEFER` | Allocations frozen; everything deferred |
| `GOVERNANCE_RECOVERY` | `recoveryInjection > 0` | Injected capital restores coverage |
| `POST_RECOVERY_RECONCILIATION` | produced by `reconcile` | Deferred buckets settled from injected capital, once |

### Delayed allocation semantics

An obligation is **eligible** this run only when `dueAt <= block.timestamp`. Future-dated
obligations are deferred. Independently, when `allocationCap > 0`, effective liquidity is
`min(snapshot + injection, allocationCap)`; the remainder of the ledger is deferred. Coverage
and solvency are always computed against the **whole** ledger, so a solvent-but-delayed ledger
is reported as `solvent = true` yet `fullyCovered = false`.

## Reconciliation (governance recovery)

`reconcile(baseReportId, recoveryInjection, recoveryPolicy)`:

1. Requires the base report to exist, to carry deferred obligations, and to be unreconciled.
2. Requires an allocating policy (`PRO_RATA` or `PRIORITY_WATERFALL`); `DEFER`/`PAUSE_THEN_DEFER`
   are rejected — recovery may not silently re-defer.
3. Rebuilds the deferred ledger as one obligation per class bucket from the base report.
4. Runs the engine, persists a `POST_RECOVERY_RECONCILIATION` report, and records the mapping
   `baseReportId -> recoveryReportId` **exactly once**.

The one-way `_reconciledBy` marker is the replay guard: a base report can never be reconciled
twice. Reports themselves are immutable.

## Storage, Events, and Projection

### Storage

| Slot group | Contents |
|-----------|----------|
| `_reports` | `reportId => InsolvencyReport` (immutable append-only records) |
| `_reportIds` | insertion-ordered id list for pagination |
| `_reportCounter` | monotonic run counter (part of every report id) |
| `_reconciledBy` | `baseReportId => recoveryReportId` (write-once) |
| `thresholds` | `metricId => warning threshold` |

### Events

| Event | When | Key fields |
|-------|------|-----------|
| `ReportGenerated` | every persisted run | reportId, scenario, policy, liquidity, obligations, paid, deferred, haircutBps, solvent |
| `InsolvencyDetected` | shortfall above threshold | reportId, shortfall |
| `RecoveryReconciled` | successful recovery | baseReportId, recoveryReportId, injectedCapital, paid, deferred |
| `ModelThresholdExceeded` | coverage/haircut threshold breached | metricId, value |
| `ThresholdUpdated` | admin threshold change | metricId, old, new |

Reports plus events are sufficient to deterministically project and reconcile the modelled
ledger: every report carries the full per-class `owed/paid/deferred/haircutBps` breakdown and
the total conservation envelope.

### Report id

`keccak256(abi.encode(scenario, policy, availableByPool, obligations, allocationCap,
recoveryInjection, paused, _reportCounter))` — content-addressed and monotonic, so no two runs
can collide or overwrite. Uniqueness comes from the monotonic `_reportCounter`; the id is an
equality/dedup key, never a randomness source. Block context is stored in the report itself.

## Invariants

1. **Conservation** — `totalPaid + totalDeferred == totalObligations`, and per class
   `paid + deferred == owed`; class sums equal the totals.
2. **Liquidity bound** — `totalPaid <= totalLiquidity`; the residual is retained.
3. **Bounded metrics** — `haircutBps <= 10000`, `coverageBps <= 10000`.
4. **Coverage consistency** — `fullyCovered <=> totalDeferred == 0`.
5. **Append-only ledger** — report ids are monotonic and never rewritten.
6. **Write-once reconciliation** — each base report reconciles at most once.
7. **Pause fidelity** — a paused report allocates zero.
8. **Single-source rounding** — protocol-favouring floors; no value creation.

## Bounded Execution

- `MAX_OBLIGATIONS = 500` (rejected above), matching the canonical treasury page bound.
- Waterfall is `O(6 * n)`; pro-rata is `O(n)`; no sorts, no nested scans.
- Pagination is capped at `MAX_REPORTS_PER_QUERY = 500`.
- `reconcile` rebuilds at most 6 class obligations.

## Gas (measured in the unit suite)

| Operation | Gas (approx.) |
|-----------|---------------|
| `previewModel` (2 obligations) | ~18,000 (view) |
| `runModel` (2 obligations, persist + events) | ~770,000 |
| `runModel` at `MAX_OBLIGATIONS = 500` (pro-rata) | ~3,200,000 |
| `reconcile` (≤ 6 class buckets) | ~700,000 |

All paths stay far below the 12M recommended transaction ceiling even at maximum configured
obligation count.

## Compatibility and Migration

- **Additive only.** No existing contract, interface, storage slot, or event is modified.
- **No released-artifact drift.** The model is a new deployment; `TreasuryManagement`,
  `InsuranceFund`, `FeeManager`, settlement, and governance artifacts are untouched.
- **Active claims unaffected.** The model never settles, disburses, or finalizes; immutable
  active-claim parameters and single-settlement guarantees are untouched.
- **Version alignment.** The seven-slot liquidity snapshot is asserted in the constructor to
  match `ITreasuryManagement.TreasuryPool` ordering
  (`EMERGENCY_RESERVE + 1 == POOL_COUNT`), so future pool changes fail loudly at deploy time.
- **Adoption path.** A future production module may adopt the same obligation classes, policy
  formulas, and rounding rule; doing so is a separate, independently reviewable change.

## Non-Goals

- No API, indexer, frontend, guardian, or off-chain settlement implementation.
- No production secrets, addresses, or launch-value selection.
- No legacy V1 compatibility work.
- No mutation or privileged shortcut in any canonical protocol module.

## Residual Risk

- The model is advisory: it cannot enforce that an on-chain allocation follows its report. Any
  production use must re-validate the policy and conservation on-chain.
- Obligation ids are caller-supplied projection metadata; duplicate ids are not rejected at the
  entry level. Replay protection applies to *reports* (unique ids) and *reconciliations*
  (write-once), which are the security-relevant boundaries, not to duplicate ledger rows.
- Threshold values are advisory defaults and must be tuned by governance before reliance.
