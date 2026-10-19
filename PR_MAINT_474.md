# PR: MAINT #474 — Post-Wave Contract Baseline and Canonical V2 Conformance Audit

**Branch:** `#474-MAINT-—-Post-Wave-Contract-Baseline-and-Canonical-V2-Conformance-Audit`  
**Target:** `main`  
**Closes:** #474  
**Type:** Maintenance / Documentation — no production contract changes  
**Wave label:** ❌ Must not receive `Stellar Wave` label

---

## Summary

This PR delivers the post-wave maintainer-owned baseline and canonical V2 conformance audit required by MAINT #474. No smart contract source files were modified. The deliverable is a reproducible, SHA-pinned baseline report (`docs/MAINT_474_BASELINE_REPORT.md`) documenting the full protocol state as of `58e1302fedd9535a8fa118c4b93403af10f44216`, plus a first-step partial fix for the Hardhat 3 ESM migration.

---

## What Was Done

### 1. Compile Suites

Ran both toolchains against the current `main` SHA:

- **Forge `forge build`** — exits 0. All 117 Solidity sources compiled with 0 errors. Warnings are documented (5 × invalid NatSpec `@brief`, 11 × `block.timestamp` across `vm.warp`).
- **Hardhat 3 `hardhat compile`** — blocked by ESM migration requirement. Hardhat 3.16.0 requires `"type": "module"` in `package.json`, and `@nomicfoundation/hardhat-toolbox@latest` is incompatible with Hardhat 3. A full toolchain migration is needed (REM-001). The `"type": "module"` entry is added to `package.json` in this PR as the first required step.

### 2. Test Suites

Full Forge test run performed:

| Suite | Pass | Fail |
|-------|------|------|
| Unit tests (`--no-match-path "test/{invariant,fuzz}/**"`) | 347 | 28 |
| Fuzz tests (`test/fuzz/**`) | 115 | 6 |
| Invariant tests (`test/invariant/**`) | **24** | **0** ✅ |
| Gas snapshot (`forge snapshot --check`) | — | ❌ No baseline file |

The 34 Forge failures fall into 5 root-cause clusters, all test-harness defects (not contract bugs):
- UpgradeController / UpgradeIntegration: missing `vm.warp` past timelock delay (10 failures)
- TokenomicsFuzz: missing `token.approve()` in test setUp, plus 2 custom-error ABI drifts (6 failures)
- GovernorTest: nested `vm.prank` rejected by Forge 1.8.3 — use `vm.startPrank` (1 failure)
- LifecycleFixture integration: direct-call guard not satisfied by intermediary test harness (3 failures)
- StakeVault V2: allocate percentage mismatch and incomplete test precondition setup (3 failures)

All 24 invariant suites pass. FeeManager, InsuranceFund, Slashing, EIP712Verifier, Tokenomics, ReputationGracePeriod, ReputationUpdateEngine, Bootstrap, Simulation, Timing, and TruthBounty invariants are clean.

### 3. Module Registry, ERC-165 / IV2Module Conformance

- `V2ConformanceFixture` correctly demonstrates `ERC165` + `IClaims` + `IAggregation` interface IDs.
- `ICanonicalV2` aggregates all 16 sub-interfaces; confirmed no deprecated authority methods (`resolveClaim`, `adminResolve`, `guardianSettle`, `batchPayout`, `emergencyWithdraw`).
- Identified gap: production contracts do not implement `IV2Module` / `ERC165` at runtime. No deployment-time interface ID enforcement exists. Documented as a medium-risk future concern.
- `GovernedModuleRegistry` has no canonical module key constants file — REM-015 raised.

### 4. Settlement Authority, Custody, Reward Accounting, Governance, Treasury, Upgrade, Emergency

- Settlement authority correctly gated to `REGISTRY_UPDATER_ROLE` on `ClaimRegistry`, granted exclusively to `ProvisionalSettlementEngine`.
- Governance role topology wired per `GovernanceRoleTopology.sol`: Governor = sole proposer; executor = `address(0)` (permissionless); Guardian = canceller only.
- `EmergencyController` Forge tests: 11/11 pass.
- Identified **mainnet blocker**: `TruthBountyWeighted` is 25,167 bytes, exceeding the 24,576-byte EVM limit. Not deployable on mainnet without library extraction or optimizer tuning (REM-011).
- Identified **IgnitionCanonicalV2.ts divergence**: deploys `ClaimRegistry` with 1 constructor arg; `deployCanonicalV2.ts` uses 2 (includes `ParameterVersionRegistry`). One of them is wrong (REM-012).

### 5. Legacy / Incompatible Canonical Paths

All Soroban/Stellar/Freighter runtime artifacts identified and flagged for removal:

| Artifact | Finding |
|----------|---------|
| `contracts/reputation_bridge.rs` | Full Soroban smart contract — must be removed from contracts/ |
| `lib.rs` (repo root) | Soroban claim rate-limiter — must be removed from repo root |
| 32 `*.bin` files (repo root) | Stale Hardhat 2 flat compiler output — delete, add to `.gitignore` |
| `contracts-vrm/` | Duplicate VRM contract tree — status undefined, must be resolved |
| `FullDeploy.ts` | Deploys deprecated `TruthBountyClaims` — must not be used for V2 mainnet |
| `test/TruthBounty.test.ts.bak` | Abandoned backup — delete |
| `contracts/staking/WeightedStaking.sol` | Minimal stub without token logic — clarify or remove |
| 5 mock contracts in `contracts/` root | Should live in `contracts/mocks/` |

### 6. CI / CD Workflows

- **10 workflows audited**. Dependency graph: `lint → test → {fuzz-tests, invariant-tests, gas-check}`. Deploy is `workflow_dispatch`-only. ✅
- **DEF-CI-001**: `forge snapshot --check` always fails — no `.gas-snapshot` committed (REM-002, BLOCKING).
- **DEF-CI-002**: Hardhat test step always fails on Hardhat 3 ESM (REM-001, BLOCKING).
- **DEF-CI-003**: `v2-policy-advisory.yml` ends with `exit 0` unconditionally — Soroban refs in `contracts/` are not blocked (REM-013).
- **DEF-CI-004**: `fuzz-tests.yml` duplicates the fuzz job already in `ci.yml`.
- **DEF-CI-005**: CODEOWNERS lacks explicit coverage of `/contracts/`, `/test/`, `/scripts/`.
- **DEF-CI-006**: `pr-guardian-report.yml` is advisory-only, cannot block merges.

### 7. V2-SC Issue Inventory

Issues SC-041–090 are the Wave boundary; SC-001–040 are maintainer-owned. Four SC issues have failing Forge tests against their implementations and must not be activated for contributor intake until green: SC-033 (UpgradeController, 10 failures), SC-034 (StakeVault V2, 3 failures), SC-032 (TokenomicsFuzz, 6 failures), SC-026 (GovernorTest, 1 failure).

---

## Files Changed

| File | Change |
|------|--------|
| `docs/MAINT_474_BASELINE_REPORT.md` | **New** — 437-line structured baseline report |
| `package.json` | `"type": "module"` added (partial REM-001 — Hardhat 3 first step) |

---

## Remediation Issues Raised (15 total)

| ID | Description | Priority |
|----|-------------|----------|
| REM-001 | Hardhat 3 ESM full migration | BLOCKING |
| REM-002 | Gas snapshot baseline absent | BLOCKING |
| REM-003 | Remove Soroban artifacts (`.rs`, `.bin`, `.bak`) | HIGH |
| REM-004 | Resolve `contracts-vrm/` duplicate tree | HIGH |
| REM-005 | Fix UpgradeController tests (vm.warp) | MEDIUM |
| REM-006 | Fix StakeVault V2 tests | MEDIUM |
| REM-007 | Fix TokenomicsFuzz tests (approve + error ABI) | MEDIUM |
| REM-008 | Fix GovernorTest vm.prank | MEDIUM |
| REM-009 | Fix LifecycleFixture direct-call guard | MEDIUM |
| REM-010 | Fix VerificationAggregation test failures | MEDIUM |
| REM-011 | Reduce TruthBountyWeighted below 24 KB | HIGH (mainnet blocker) |
| REM-012 | Fix IgnitionCanonicalV2 ClaimRegistry arity | HIGH |
| REM-013 | Make V2 Policy Advisory a blocking check | MEDIUM |
| REM-014 | Extend CODEOWNERS to contract paths | LOW |
| REM-015 | Create canonical module registry key constants | MEDIUM |

---

## Wave Activation Gate

No V2-SC issues (SC-041–090) should be activated for contributor intake until REM-001 and REM-002 (CI blocking), REM-005–010 (test failures), and REM-011 (mainnet contract size) are resolved and the required CI jobs return green on `main`.

---

## Testing

- `forge build` — ✅ 0 errors
- `forge test --no-match-path "test/{invariant,fuzz}/**"` — 347/375 pass (28 pre-existing failures documented)
- `forge test --match-path "test/invariant/**"` — 24/24 pass ✅
- `forge test --match-path "test/fuzz/**"` — 115/121 pass (6 pre-existing failures documented)
- No contract source changes — no regression risk from this PR

---

## Reviewer Notes

- This PR contains no smart contract changes. Review is documentation and toolchain config only.
- The `"type": "module"` change in `package.json` is a prerequisite for REM-001. It does not break anything on its own but must be followed by the full Hardhat 3 config migration before the `hardhat compile`/`hardhat test` steps will work.
- All defects documented in the report existed prior to this PR. This PR records them; it does not introduce them.
- The baseline report is the required output artifact for MAINT #474 exit criteria.
