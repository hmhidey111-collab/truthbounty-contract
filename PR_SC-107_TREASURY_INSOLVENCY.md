# V2-SC-107 — Model Treasury Insolvency and Recovery Scenarios

Closes #493

## Summary

Adds an **advisory, isolated** treasury insolvency and recovery model that deterministically
simulates insufficient liquidity, delayed allocation, partial obligations, emergency pause,
governance recovery, and post-recovery reconciliation — with an explicit haircut policy and a
documented rounding rule, so no haircut ambiguity remains.

The model holds no tokens, exposes no transfer path, and cannot mutate any canonical protocol
module. It stores an append-only report ledger keyed by content-addressed ids and a one-way
reconciliation marker that blocks recovery replay.

## Dependencies

- **V2-SC-091** — verified compatible: the model consumes only view-style snapshot inputs and
  introduces no new storage, role, or event into existing modules.
- **V2-SC-100** — verified compatible: the model never settles, disburses, or finalizes; it
  makes no claim on active-claim lifecycle state.

## Files

| Path | Change |
|------|--------|
| `contracts/treasury/ITreasuryInsolvencyModel.sol` | New — types, events, errors, API |
| `contracts/treasury/TreasuryInsolvencyModel.sol` | New — deterministic engine, report ledger |
| `test/treasury/TreasuryInsolvencyModel.t.sol` | New — 31 unit/fuzz tests |
| `test/invariant/TreasuryInsolvencyHandler.sol` | New — stateful handler + ghost accounting |
| `test/invariant/TreasuryInsolvencyInvariant.t.sol` | New — 6 stateful invariants |
| `docs/treasury-insolvency-recovery.md` | New — behavior, invariants, boundaries, migration |

No existing file is modified.

## Behavior

- **Obligation classes** (senior → junior): `SETTLEMENT`, `STAKING_PRINCIPAL`, `INSURANCE`,
  `REWARDS`, `OPERATIONAL`, `DISCRETIONARY`.
- **Policies**: `PRO_RATA`, `PRIORITY_WATERFALL`, `DEFER`, `PAUSE_THEN_DEFER`.
- **Scenarios**: `SOLVENT_BASELINE`, `INSUFFICIENT_LIQUIDITY`, `DELAYED_ALLOCATION`,
  `PARTIAL_OBLIGATION`, `EMERGENCY_PAUSE`, `GOVERNANCE_RECOVERY`,
  `POST_RECOVERY_RECONCILIATION`.
- **Rounding**: protocol-favouring floors; residual retained; `paid + deferred == owed` always.

## Trust Boundaries and Authority

- Settlement and treasury authority remain exclusively with the Optimism/EVM protocol
  contracts. The model cannot move value and cannot mutate protocol state.
- `MODELER_ROLE` persists reports and reconciles a base report once; `ADMIN_ROLE` manages
  thresholds/roles; `PAUSER_ROLE` pauses only the model surface.
- No API, indexer, frontend, guardian, deployer, or test harness gains settlement or treasury
  authority.

## Acceptance Criteria → Evidence

| Acceptance Criterion | Evidence |
|----------------------|----------|
| Objective implemented without unrelated scope | New isolated module + docs; zero edits to existing files; non-goals section in docs |
| Every affected invariant and trust boundary documented and tested | `docs/treasury-insolvency-recovery.md`; 6 stateful invariants in `TreasuryInsolvencyInvariant.t.sol`; trust-boundary table |
| Events/storage sufficient for deterministic projection and reconciliation | `ReportGenerated`/`RecoveryReconciled`/`InsolvencyDetected`/`ModelThresholdExceeded`; per-class `owed/paid/deferred/haircutBps` in each report; report-id + pagination tests |
| No backend-authoritative mutation or privileged shortcut | Model has no token/transfer surface; `invariant_ModelHoldsNoValue`; role tests prove unauthorized callers cannot run/reconcile/configure |
| No ignored security findings | Zero-address rejection; fail-closed `validateInput`; bounded loops (`MAX_OBLIGATIONS`); write-once reconciliation; unique report ids |
| PR maps evidence to every acceptance criterion and identifies residual risk | This document + "Residual Risk" in `docs/treasury-insolvency-recovery.md` |
| Independent exact-head human maintainer approval | Required — automatic merge prohibited |

## Required Tests

- **Positive**: solvent baseline, pro-rata, waterfall, delayed allocation, partial obligation,
  emergency pause, governance recovery, reconciliation.
- **Negative / boundary**: empty ledger, zero id/amount, pause/policy mismatches, injection and
  cap scoping, `MAX_OBLIGATIONS` boundary, unknown report.
- **Authorization**: non-modeler cannot run/reconcile; non-admin cannot set thresholds.
- **Replay**: reconcile-once guard blocks a second reconciliation of the same base report;
  distinct report ids for identical inputs.
- **Failure-path**: nothing-to-reconcile, zero injection, invalid recovery policy.
- **Fuzz**: pro-rata never exceeds liquidity; waterfall never funds junior before senior.
- **Invariant**: conservation (global + per class), liquidity bound, metric bounds, append-only
  ledger, write-once reconciliation, pause fidelity, no custody.

## Checks Run (exact head)

```
forge build                                              # success
forge fmt --check <new files>                            # clean
forge lint <new files>                                   # 0 warnings / 0 findings
forge test --match-contract TreasuryInsolvency           # 33 passed, 0 failed
forge test --match-path "test/invariant/**"              # 26 passed, 0 failed (12 suites)
```

| Job | Result |
|-----|--------|
| `forge build` | success |
| Solidity lint (new files) | 0 warnings |
| Unit + fuzz — SC-107 scope | **33 passed / 0 failed** (incl. 2 fuzz, 6 stateful invariants; 500 runs, 10,000 calls, 0 reverts) |
| Invariant job (`test/invariant/**`) | **26 passed / 0 failed** |
| Fuzz job (`test/fuzz/**`) | 114 passed / 7 failed — **all 7 pre-existing, unrelated** |
| Unit job (`--no-match-path invariant/fuzz`) | 239 passed / 28 failed — **all 28 pre-existing, unrelated** |

### Baseline note (important for reviewers)

This branch is based on `DigiNodes/truthbounty-contract@main` (0 commits behind/ahead). The
28 unit failures and 7 fuzz failures above are **present on `main` without this change** and are
in suites that do not touch this work (`DisputeResolution`, `EmergencyController`, `StakeVault`,
`TokenomicsEngine`, `VerificationAggregation`, `TruthBountyGovernor`, `LifecycleFixture`,
`UpgradeController`, `UpgradeIntegration`, `v2/StakeVault`, `fuzz/ReputationEngine`,
`fuzz/TokenomicsFuzz`).

Verified by re-running the unit job with all SC-107 files removed:

```
SC-107 files removed : 28 failing, 208 succeeded
SC-107 files present : 28 failing, 239 succeeded   # +31 passing, +0 regressions
```

Fixing the pre-existing baseline is deliberately **out of scope** for V2-SC-107 (the issue
requires it not absorb unrelated work) and is recommended as a separate, independently
reviewable change. This PR introduces **zero new failures**.

## Residual Risk

- Advisory only: a production path must re-validate policy and conservation on-chain before
  any allocation is executed.
- Obligation ids are caller-supplied metadata; duplicate rows are not rejected (replay
  protection is enforced at report and reconciliation boundaries).
- Advisory thresholds require governance tuning before reliance.

## Non-Goals

- No API/frontend/off-chain settlement.
- No production secrets, addresses, or launch-value selection.
- No legacy V1 compatibility work.
- No change to `TreasuryManagement`, `InsuranceFund`, `FeeManager`, governance, or settlement
  contracts.
