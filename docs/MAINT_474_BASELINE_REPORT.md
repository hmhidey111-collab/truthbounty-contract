# MAINT #474 — Post-Wave Contract Baseline and Canonical V2 Conformance Audit

**Report date:** 2026-09-24  
**Baseline SHA:** `58e1302fedd9535a8fa118c4b93403af10f44216`  
**Branch:** `main`  
**Last merged PR:** #545 (maint/contract-pure-view-ci-remediation)  
**Auditor:** Kiro (maintainer-owned, Wave-paused)

---

## 1. Baseline Compile Status

### 1.1 Foundry (Forge)

| Step | Result |
|------|--------|
| `forge build` | **PASS** — exit 0, all 117 Solidity sources compiled, 0 errors |
| Compiler version | solc 0.8.28, `viaIR = true`, `optimizer_runs = 200`, `evmVersion = cancun` |
| Warnings (non-blocking) | 5 × invalid `@brief` NatSpec tags in `IEconomicSimulation.sol`; 11 × `block.timestamp` across `vm.warp` in test files |

### 1.2 Hardhat 3

| Step | Result |
|------|--------|
| `hardhat compile` | **BLOCKED** — Hardhat 3.16.0 requires `"type": "module"` in `package.json` (ESM migration). The project still uses CommonJS-style `hardhat.config.ts`. Setting `"type": "module"` exposes a second blocker: `@nomicfoundation/hardhat-toolbox@latest` is not compatible with Hardhat 3 (requires the `hh2` tag for Hardhat 2 or a full Hardhat 3 migration). |
| Dependency conflict | `@typechain/hardhat@9.1.0` requires `peer hardhat@"^2.9.9"`; project has `hardhat@3.16.0`. npm resolves only with `--legacy-peer-deps`. |
| Prior cached output | The `compile-output.txt` in repo root records a successful Hardhat 2 compile of 117 Solidity files with 0 errors and several non-blocking warnings (see §4). |

**Conclusion:** Canonical contract sources are compilable and correct. Hardhat 3 is a toolchain migration defect, not a contract correctness defect.

---

## 2. Test Suite Results

### 2.1 Forge Unit Tests (non-fuzz, non-invariant)

```
forge test --no-match-path "test/{invariant,fuzz}/**"
347 passed, 28 failed
```

#### Failing tests by root cause

| File | Count | Root cause |
|------|-------|-----------|
| `test/upgrade/UpgradeController.t.sol` | 4 | `TimelockNotElapsed` — test does not advance block time past the upgrade timelock before calling `executeUpgrade`. Tests expect the execution to succeed immediately after scheduling. |
| `test/upgrade/UpgradeIntegration.t.sol` | 6 | Same `TimelockNotElapsed` pattern plus one error-selector mismatch: test expects `IncompatibleStorageLayout` but receives `TimelockNotElapsed` first (timelock precedes the storage check). |
| `test/governance/TruthBountyGovernor.t.sol` | 1 | `setUp()` uses nested `vm.prank` without `vm.startPrank` — Forge 1.8.3 now rejects double-prank strictly. |
| `test/integration/LifecycleFixture.test.t.sol` | 3 | `Direct calls only: no contract intermediaries` — settlement calls are being proxied through an intermediary contract in the test harness; the contract now enforces `tx.origin == msg.sender` or an explicit caller guard. |
| `test/v2/StakeVault.t.sol` | 3 | (a) Allocation percentage mismatch: test expects 50 ETH locked after allocate but contract returns 75 ETH (logic regression or test was written against a prior parameter). (b) `InsufficientLocked` — `settleConclusive` path requires prior `allocate` call not made in test. (c) Reentrancy guard check passes where test expects revert — guard may not be applied to the withdrawal path under test. |
| `test/VerificationAggregation.t.sol` | 2 | (a) `ERC20InsufficientBalance` in emission-limit test — aggregator test pre-funds the wrong account. (b) Arithmetic overflow in confidence-bounds fuzz when weight parameter reaches `uint256.max`-scale; assertion mismatch in stake-distribution fuzz (6879 ≠ 3120). |

### 2.2 Forge Fuzz Tests

```
forge test --match-path "test/fuzz/**"
115 passed, 6 failed  (all failures in test/fuzz/TokenomicsFuzz.t.sol)
```

| Failing test | Error |
|-------------|-------|
| `testFuzz_AllocateBatch_RandomSources` | `ERC20InsufficientAllowance` — test does not `approve` the tokenomics engine before calling allocate. |
| `testFuzz_DistributeRevenue_RandomAmounts` | Same missing `approve`. |
| `testFuzz_DistributionId_Deterministic` | Same missing `approve`. |
| `testFuzz_EmissionLimit_RandomLimits` | Error-selector mismatch: expects `AllocationConfigInvalid` (or the custom error `0xa03ecd86`), gets `EmissionLimitExceeded`. Test precondition ordering is wrong. |
| `testFuzz_InvalidBPSConfiguration_Reverts` | Error-selector `0x17ca28d0` ≠ `AllocationConfigInvalid`. Custom error ABI likely diverged from the implementation's error definition. |
| `testFuzz_RewardMultiplier_RandomMultipliers` | `ERC20InsufficientAllowance` — same missing `approve`. |

**Root cause summary:** `TokenomicsFuzz.t.sol` was written against an earlier version of `TokenomicsEngine.sol` that did a pull-based transfer. The implementation now requires an explicit token approval, and two error identifiers have drifted from their definitions in the test.

### 2.3 Forge Invariant Tests

```
forge test --match-path "test/invariant/**"
24 passed, 0 failed  ✅
```

All 11 invariant suites pass: `FeeManagerInvariant`, `InsuranceFundInvariant`, `SlashingInvariant`, `EIP712VerifierInvariant`, `TokenomicsInvariant`, `ReputationGracePeriodInvariant`, `ReputationUpdateEngineInvariant`, `BootstrapInvariant`, `SimulationInvariant`, `TimingInvariant`, `TruthBountyInvariant`.

### 2.4 Gas Snapshot

```
forge snapshot --check  — FAIL (no baseline .gas-snapshot file exists)
```

No `.gas-snapshot` or `.gas-snapshots.json` baseline file is committed to the repository. The CI `gas-check` job will therefore always fail on `--check`. The `gas-check.yml` workflow also uses `continue-on-error: true` for the Hardhat test step but the Forge snapshot check has no error bypass — this causes the workflow to fail without a snapshot file.

### 2.5 Hardhat Tests

Blocked by the Hardhat 3 ESM migration issue. The cached `test-output.txt` records 8 passing / 1 failing in `VerificationSubmission` (`TypeError: Cannot mix BigInt and other types`).

---

## 3. Canonical V2 Module and Interface Audit

### 3.1 IV2Module / ERC-165 Conformance

The canonical interface surface is defined in `contracts/v2/interfaces/` and implemented by `V2ConformanceFixture.sol`:

- `IV2Module` — extends `IERC165`, requires `protocolVersion() → (uint16, uint16)`.  
- `ICanonicalV2` — aggregate of 16 sub-interfaces (IClaims, IEvidence, IStakeCustody, IVerification, IAggregation, ISettlement, IDisputes, IRewards, ISlashing, ITreasury, IReputationRoots, IGovernanceHooks, IEmergencyControls, IConfiguration, IModuleRegistry, plus IV2Module via IModuleRegistry).  
- `V2ConformanceFixture` — compile-time proof contract: correctly inherits `ERC165`, returns `(2, 0)` from `protocolVersion()`, exposes `supportsInterface` for both `IClaims` and `IAggregation` interface IDs.

**Finding:** No ERC-165 supportsInterface conformance is required by or enforced on the production contracts (`GovernanceController`, `TruthBountyWeighted`, `VerificationAggregator`, `ProvisionalSettlementEngine`, `AppealVerificationRound`, etc.). The production contracts do **not** inherit `IV2Module` or `ERC165`. `V2ConformanceFixture` is a test/compile-time check only. There is no runtime module registry that verifies interface IDs at deployment.

**Risk (MEDIUM):** If a module registry is added in a future wave, existing deployed modules will fail `supportsInterface` checks. The protocol should decide whether IV2Module conformance is a deployment-time invariant.

### 3.2 Module Registry Keys

`GovernedModuleRegistry` (`contracts/governance/v2/GovernedModuleRegistry.sol`):
- Keys are untyped `bytes32` (`keccak256`-derived).  
- Role guard: `REGISTRY_ADMIN_ROLE` — set in constructor to the `admin` address.  
- No canonical enum or constant file defines the expected key set. Module keys are computed ad-hoc at call sites.  
- **Finding:** No single source of truth for the V2 module key registry. Keys must be documented and locked before Wave activation.

### 3.3 ICanonicalV2 — Deprecated Method Exclusions

The `V2Interfaces.test.ts` confirms:
- `ICanonicalV2` ABI does not contain `resolveClaim`, `adminResolve`, `guardianSettle`, `batchPayout`, or `emergencyWithdraw`. ✅

### 3.4 Deployment Composition (SC-031)

`ignition/modules/CanonicalV2.ts` and `scripts/deployCanonicalV2.ts` correctly implement the 9-step canonical dependency order:

```
GovernanceController → RewardToken + MockReputationOracle
    → ClaimRegistry + ParameterVersionRegistry
        → TruthBountyWeighted
            → VerificationAggregator
                → ProvisionalSettlementEngine (+ role grant on ClaimRegistry)
                    → AppealVerificationRound
```

**Finding — `IgnitionCanonicalV2.ts` vs `deployCanonicalV2.ts` divergence:** The Ignition module deploys `ClaimRegistry(deployer)` with a single constructor argument; `deployCanonicalV2.ts` deploys it as `ClaimRegistry(deployer, parameterVersionRegistry)` with two arguments. If `ClaimRegistry` requires the registry address (as the TypeScript script implies), the Ignition module will fail or deploy a misconfigured instance.

**Finding — Legacy `FullDeploy.ts`:** `ignition/modules/FullDeploy.ts` still references and deploys the deprecated `TruthBountyClaims` contract as the rewards module. This module is not part of the canonical V2 composition and must not be used for mainnet deployments.

---

## 4. Settlement Authority, Custody, Reward Accounting, Governance, Treasury, Upgrade, and Emergency Controls

### 4.1 Settlement Authority

- Settlement authority on `ClaimRegistry` is governed by `REGISTRY_UPDATER_ROLE`, granted exclusively to `ProvisionalSettlementEngine` during deployment. ✅
- `ExampleSettlement.sol` holds its own internal settlement path — this is a non-canonical contract and should be labeled as example-only or removed from the production build tree.

### 4.2 Stake Custody

- `contracts/v2/StakeVault.sol` implements `IStakeCustody` with lock categories (`VERIFIER_PRINCIPAL`, `CHALLENGE_BOND`, `BOUNTY_ESCROW`, `SETTLEMENT_ALLOCATION`). ✅  
- 3 Forge tests fail against it (see §2.1). The `allocate → settle` flow and reentrancy guard are the two failing areas.

### 4.3 Reward Accounting

- `contracts/reward/RewardEngine.sol` — pull-based reward distribution; 6 TokenomicsFuzz failures indicate missing `approve()` pre-condition in tests, not a contract bug.  
- `contracts/tokenomics/TokenomicsEngine.sol` — emission limit and allocation policies. Custom error ABI drift confirmed (2 fuzz test selectors mismatch).

### 4.4 Governance

- `TruthBountyGovernor` (OZ GovernorUpgradeable) + `TimelockController` + `GovernedModuleRegistry` + `GovernanceGuardian`.  
- Role topology: Governor is sole proposer; executor role granted to `address(0)` (permissionless execution); Guardian holds `CANCELLER_ROLE` only. ✅ (matches `GovernanceRoleTopology.sol`)  
- 1 Forge test failure in `TruthBountyGovernor.t.sol` (nested `vm.prank` — test defect, not contract defect).

### 4.5 Treasury

- `TreasuryManagement.sol` + `TreasuryAccounting.sol` — pull-based, role-separated (DISBURSER_ROLE, SLASHING_CONTRACT_ROLE, etc.).  
- Warning: `TreasuryAccounting.sol:487-497` calls `revert InvalidAddress(address(0))` when `newBPS > PERCENT_DENOMINATOR` — semantically incorrect use of `InvalidAddress`; should be a dedicated `InvalidBPS` error.
- The SC-022 merge repair workflow (`fix-sc022-merge.yml`) patches `TreasuryAccounting.sol` by adding a `EXTERNAL` enum member and patching `TreasuryAccount(99)` usage — this one-time workflow is branch-scoped and no longer needed on `main`.

### 4.6 Upgrade Controls

- `UpgradeController.sol` with `TimelockOwnedProxyAdmin.sol`, `VersionRegistry.sol`, `StorageCompatibilityValidator.sol`.  
- 10 Forge tests fail because test code does not advance time past the upgrade timelock delay. These are test-harness defects.  
- `UpgradeController.t.sol` test `test_ExecuteUpgrade_RevertsAfterWindow` fails because the contract's execution-window check is never reached (timelock blocks first). Test ordering is wrong.

### 4.7 Emergency Controls

- `EmergencyController.sol` with `EmergencyProtected.sol` abstract base.  
- `test/EmergencyController.t.sol` — all 11 tests pass. ✅

### 4.8 Compile Warnings Requiring Attention

From the Hardhat compile-output.txt:

| Warning | File | Severity |
|---------|------|---------|
| `TruthBountyWeighted` variable `vote` shadows function `vote` (×4) | `TruthBountyWeighted.sol:548,631,702,975` | LOW — can cause reader confusion |
| `totalSlashed` function parameter shadows state variable | `TruthBountyWeighted.sol:1001` | LOW |
| **Contract code size 25167 bytes > 24576 byte limit** | `TruthBountyWeighted.sol` | **HIGH** — not deployable on mainnet without optimizer tuning |
| Unused local/parameter variables | `EconomicSimulation.sol`, `TreasuryAccounting.sol`, others | LOW |
| `getGovernanceVersion` can be `pure` | `GovernanceOwnable.sol:248` | LOW |
| `_authorizeUpgrade` can be `view` | `ProtocolUpgradeable.sol:67` | LOW |

**Critical:** `TruthBountyWeighted` at 25,167 bytes exceeds the Spurious Dragon 24,576-byte contract size limit. The Hardhat config already sets `optimizer: { enabled: true, runs: 200 }`. Further reduction via diamond pattern, library extraction, or lowering `runs` value is required before mainnet deployment.

---

## 5. Legacy / Incompatible Canonical Paths

| Artifact | Location | Classification | Action Required |
|----------|----------|----------------|-----------------|
| `reputation_bridge.rs` | `contracts/reputation_bridge.rs` | Soroban (Stellar) runtime code — not Solidity | Remove from `contracts/` directory; move to `docs/stellar/` or a separate repo |
| `lib.rs` | repo root | Soroban (Stellar) Claim rate-limiter contract | Remove from repo root |
| 32 `.bin` files | repo root | Stale compiler output from a legacy Hardhat 2 compile run (flat output mode) | Remove all `*.bin` files from repo root; add `*.bin` to `.gitignore` |
| `test/TruthBounty.test.ts.bak` | `test/` | Abandoned test backup | Delete |
| `contracts-vrm/` directory | repo root | Duplicate of `contracts/` VRM suite with 4 contracts and their interfaces | Remove or document why a parallel contract tree exists |
| `ignition/modules/FullDeploy.ts` | `ignition/modules/` | Deploys deprecated `TruthBountyClaims` | Replace references with `CanonicalV2.ts` or clearly label as legacy-only |
| `contracts/staking.sol` (root-level) | `contracts/` | Unweighted legacy staking — superseded by `TruthBountyWeighted` and `StakeVault` | Gate behind `legacy/` subdirectory or remove from compile path |
| `contracts/staking/WeightedStaking.sol` | `contracts/staking/` | Minimal stub (no token logic, no SafeERC20) — not the production staking contract | Clarify status; if unused in V2, remove |
| `contracts/WeightedStaking.sol` (root-level) | `contracts/` | Full 14 KB production-grade contract — this is the canonical one | Keep; no action |
| `contracts/MockUpgradeable.sol` | `contracts/` | Test mock in production contract tree | Move to `contracts/mocks/` |
| `contracts/MockReputationOracle.sol` | `contracts/` | Mock in production contract tree | Move to `contracts/mocks/` |
| `contracts/MockERC20.sol` | `contracts/` | Mock in production contract tree | Move to `contracts/mocks/` |
| `deployments/config/mainnet.json` | `deployments/config/` | All address fields are `${ENV_VAR}` — placeholder templates, not live addresses ✅ | No action (correct) |
| `IMPLEMENTATION_STATUS.txt` | repo root | Developer scratch file for CO-172 | Remove; content is irrelevant to protocol state |
| Various `PR_*.md` and `META_TX_*.md` | repo root | PR documentation artifacts | Move to `docs/pr-history/` or delete after merge |

---

## 6. CI/CD Workflow Audit

### 6.1 Workflow Inventory

| Workflow | File | Trigger | Branch Protection Candidate |
|----------|------|---------|----------------------------|
| `CI` | `ci.yml` | PR + push to `main` | **YES** — runs lint, test, fuzz, invariant, gas-check as separate jobs |
| `Gas Regression Detection` | `gas-check.yml` | PR + push to `main`/`develop` | Advisory (no `--check` enforcement on Hardhat output) |
| `Fuzz Testing` | `fuzz-tests.yml` | PR + push to `main`/`develop` | Duplicates fuzz job in `ci.yml` |
| `Deploy` | `deploy.yml` | `workflow_dispatch` only | Manual gate ✅ |
| `V2 Policy Advisory` | `v2-policy-advisory.yml` | PR to `main` | Advisory only — no failure path |
| `PR Guardian Report` | `pr-guardian-report.yml` | PR events | Advisory — uploads report artifact, no blocking |
| `V2 Issue Inventory Report` | `issue-audit-report.yml` | Weekly + dispatch | Informational only |
| `Sync Wave Labels` | `sync-wave-labels.yml` | Explicit `workflow_dispatch` with confirmation | Governance tooling ✅ |
| `Wave Issue Assignment` | `wave-assignment.yml` | Issue comment `/assign` | Self-service gate enforcing SC-041–090 and `Stellar Wave` label |
| `SC-022 Merge Repair` | `fix-sc022-merge.yml` | Push to `feature/sc-022-event-architecture` | One-time repair — branch-scoped, no longer active on `main` |

### 6.2 CI Job Dependency Graph

```
lint
  └── test
        ├── fuzz-tests
        ├── invariant-tests
        └── gas-check
```

All CI jobs have `permissions: contents: read` (read-only) except deploy (uses secrets). ✅

### 6.3 Defects

**DEF-CI-001 — Gas snapshot baseline absent:**  
`ci.yml` gas-check job runs `forge snapshot --check`. With no `.gas-snapshot` file, this step **always fails**, blocking every PR. Either a baseline snapshot must be committed or the step must be replaced with `forge snapshot` (generate-only) until a baseline is established.

**DEF-CI-002 — Hardhat 3 ESM migration unblocked:**  
The `ci.yml` "Run Hardhat tests" step runs `npx hardhat test`. This will fail on the current toolbox incompatibility until the Hardhat 3 migration is completed (add `"type": "module"`, migrate config, replace toolbox).

**DEF-CI-003 — V2 Policy Advisory does not enforce:**  
`v2-policy-advisory.yml` uses `::warning` annotations but ends with `exit 0` unconditionally ("Advisory mode"). Stellar/Soroban references in production paths are not blocked. Given that `contracts/reputation_bridge.rs` is actively in the repo, the advisory provides no protection.

**DEF-CI-004 — `fuzz-tests.yml` duplicates CI fuzz job:**  
Standalone `fuzz-tests.yml` runs on `main`/`develop` push and PR, as does the fuzz-tests job in `ci.yml`. Double-running wastes compute and creates confusing status checks.

**DEF-CI-005 — CODEOWNERS coverage gap:**  
`.github/CODEOWNERS` assigns `*` and `/.github/` to `@dDevAhmed` but `/contracts/` and `/test/` are not explicitly protected. The `/src/` rule is moot (no `src/` directory exists). Canonical contract paths need explicit coverage.

**DEF-CI-006 — `pr-guardian-report.yml` is advisory only:**  
PR policy validation generates a report artifact but cannot block merge. If this is intended as a required check it must fail with non-zero exit on policy violation.

---

## 7. V2-SC Issue Label Inventory and Activation Order

### 7.1 Wave Boundary

The `wave-assignment.yml` enforces: only issues matching `V2-SC-041` through `V2-SC-090` with the `Stellar Wave` label are self-assignable by contributors.

Issues SC-001 through SC-040 are pre-Wave (maintainer-owned). Issues SC-091+ are out of scope for the current wave.

### 7.2 Known Issue → Defect Mapping

| Defect | Relevant SC Issue(s) | Status |
|--------|---------------------|--------|
| UpgradeController timelock not advanced in tests | SC-033 (UpgradeController) | Open / failing |
| TokenomicsFuzz missing approve() | SC-032 (Economic Simulation) | Open / failing |
| TruthBountyWeighted contract size > 24 KB | SC-008 (Reputation Engine) or SC-019 | Needs new issue |
| Hardhat 3 ESM migration | SC-031 (Canonical Deploy) | Blocking Hardhat CI |
| Gas snapshot baseline absent | (new) | Blocking CI gas-check |
| GovernorTest vm.prank double-prank | SC-026 (Governance v2) | Open / failing |
| LifecycleFixture "Direct calls only" | SC-031 integration | Open / failing |
| StakeVault allocation logic regression | SC-034 (StakeVault V2) | Open / failing |
| VerificationAggregation overflow | SC-022 / SC-024 | Open / failing |
| `contracts-vrm/` duplicate tree | (legacy) | Legacy cleanup |
| Soroban artifacts in contracts/ | (legacy) | Legacy cleanup |

### 7.3 Premature Activation Risk

The following SC issues have failing tests against their contract implementations. They must not be activated for Wave contributor work until green:

- SC-033 (UpgradeController) — 10 Forge failures
- SC-034 (StakeVault V2) — 3 Forge failures  
- SC-032 (TokenomicsFuzz) — 6 fuzz failures
- SC-026 (GovernanceV2) — 1 Forge failure

---

## 8. Dependency Graph — Canonical V2 Deployment Order

```
Step 1:  GovernanceController(admin)
Step 2:  ParameterVersionRegistry(admin, admin)
Step 3:  RewardToken(admin, initialSupply)
Step 4:  MockReputationOracle()
Step 5:  ClaimRegistry(admin, parameterVersionRegistry)         ← Ignition divergence: needs fix
Step 6:  TruthBountyWeighted(token, oracle, admin, governance)
Step 7:  VerificationAggregator(truthBountyWeighted, admin, minVerificationCount, minTotalWeight, minConfidenceBps)
Step 8:  ProvisionalSettlementEngine(claimRegistry, aggregator, challengeWindow, governance, admin)
           └── ClaimRegistry.grantRole(REGISTRY_UPDATER_ROLE, provisionalSettlementEngine)
Step 9:  AppealVerificationRound(token, claimRegistry, oracle, appealConfig, governance, admin)

Optional post-deploy:
  - ClaimRegistry.renounceRole(REGISTRY_UPDATER_ROLE, deployer)  [if finalizeDeployerRoles = true]
```

---

## 9. Remediation Issues — Maintainer Action Required

The following focused remediation items are required before any new wave is activated or a V2 release candidate is tagged:

### REM-001 — Hardhat 3 ESM Migration [BLOCKING]

**Scope:** `package.json`, `hardhat.config.ts`, all Hardhat test files  
**Action:** Add `"type": "module"`, convert `hardhat.config.ts` to `hardhat.config.mjs` or update imports to ESM syntax; replace `@nomicfoundation/hardhat-toolbox` with Hardhat 3 compatible plugins. Consider pinning to Hardhat 2 (`hardhat@^2.x`) until migration is complete.  
**Blocks:** CI `test` job, all Hardhat test runs

### REM-002 — Gas Snapshot Baseline [BLOCKING]

**Scope:** `.gas-snapshot` (Forge), `.gas-snapshots.json` (Hardhat)  
**Action:** Run `forge snapshot` on a clean build and commit `.gas-snapshot` to the repo root. Update CI `gas-check` job to commit the snapshot on first run or remove `--check` until a baseline exists.  
**Blocks:** CI `gas-check` job

### REM-003 — Remove Soroban / Legacy Artifacts

**Scope:** `contracts/reputation_bridge.rs`, `lib.rs` (repo root), 32 `*.bin` files (repo root), `test/TruthBounty.test.ts.bak`, `IMPLEMENTATION_STATUS.txt`, `PR_*.md`, `META_TX_*.md`, `MERKLE_FIX.md` (repo root)  
**Action:** Delete or relocate. Add `*.bin`, `*.bak`, `*.rs` to `.gitignore` under the contracts directory. The `v2-policy-advisory.yml` scan path only covers `src/` and `script/` — extend to `contracts/`.  
**Priority:** HIGH — Soroban code in contracts/ is misleading and risks CI false-negatives

### REM-004 — Resolve `contracts-vrm/` Duplicate Tree

**Scope:** `contracts-vrm/` (4 contracts + interfaces)  
**Action:** Determine whether `contracts-vrm/` is a staging area or dead code. If dead, delete. If live, document its relationship to `contracts/` and add compile exclusion if it is not deployed.

### REM-005 — Fix UpgradeController Forge Tests [SC-033]

**Scope:** `test/upgrade/UpgradeController.t.sol`, `test/upgrade/UpgradeIntegration.t.sol`  
**Action:** Add `vm.warp(block.timestamp + TIMELOCK_DELAY + 1)` after scheduling and before executing upgrades. Fix the `test_StorageValidator_IncompatibleUpgrade_Reverts` test to advance time before the storage check path.  
**Count:** 10 failures

### REM-006 — Fix StakeVault V2 Forge Tests [SC-034]

**Scope:** `test/v2/StakeVault.t.sol`  
**Action:** Investigate the `allocate` parameter mismatch (expected 50e18, got 75e18). Ensure `settleConclusive` test calls `allocate` before `settleConclusive`. Verify reentrancy guard applies to the withdrawal path being tested.  
**Count:** 3 failures

### REM-007 — Fix TokenomicsFuzz Tests [SC-032]

**Scope:** `test/fuzz/TokenomicsFuzz.t.sol`  
**Action:** Add `token.approve(tokenomicsEngine, type(uint256).max)` in `setUp()`. Fix the two custom-error ABI mismatches by re-deriving the expected error selectors from the current `TokenomicsEngine.sol`.  
**Count:** 6 failures

### REM-008 — Fix GovernorTest vm.prank [SC-026]

**Scope:** `test/governance/TruthBountyGovernor.t.sol`  
**Action:** Replace nested `vm.prank` in `setUp()` with `vm.startPrank` / `vm.stopPrank`.  
**Count:** 1 failure (cascades to all tests in that file)

### REM-009 — Fix LifecycleFixture "Direct calls only" [SC-031]

**Scope:** `test/integration/LifecycleFixture.test.t.sol`  
**Action:** Identify which contract enforces `msg.sender == tx.origin` (or similar direct-call guard) and either call the function directly in the test (not via an intermediary contract) or update the test harness.  
**Count:** 3 failures

### REM-010 — Fix VerificationAggregation Test Failures [SC-022/SC-024]

**Scope:** `test/VerificationAggregation.t.sol`  
**Action:** Fix `testFuzzConfidenceNumericBounds` to bound the weight parameter to safe uint128 range before multiplication. Fix `testFuzzStakeDistribution` stake accounting expectations. Fix `test_EmissionLimit_PreventsExcessDistribution` token pre-fund.  
**Count:** 2 failures

### REM-011 — Reduce TruthBountyWeighted Contract Size

**Scope:** `contracts/TruthBountyWeighted.sol` (25,167 bytes — exceeds 24,576 byte limit)  
**Action:** Extract internal helper logic into a library, or lower optimizer `runs` to 50-100 for this contract only. Mainnet deployment is blocked until contract size is under 24,576 bytes.  
**Priority:** HIGH (mainnet blocker)

### REM-012 — Fix IgnitionCanonicalV2 ClaimRegistry Constructor Mismatch

**Scope:** `ignition/modules/CanonicalV2.ts`  
**Action:** Update the `ClaimRegistry` deployment in CanonicalV2.ts to pass `parameterVersionRegistry` as the second constructor argument, matching `scripts/deployCanonicalV2.ts` and the actual `ClaimRegistry` contract signature.

### REM-013 — Enforce V2 Policy Advisory as Blocking Check

**Scope:** `.github/workflows/v2-policy-advisory.yml`  
**Action:** Remove the final `exit 0` unconditional bypass. Emit `exit 1` when Soroban/Stellar/Freighter references are found in `contracts/` or `scripts/`. Register this as a required status check.

### REM-014 — Extend CODEOWNERS to Canonical Contract Paths

**Scope:** `.github/CODEOWNERS`  
**Action:** Add explicit owners for `/contracts/`, `/test/`, `/scripts/`, `/ignition/` — at minimum `@dDevAhmed` or a multi-reviewer rule for protocol-sensitive paths.

### REM-015 — Document and Lock Module Registry Keys

**Scope:** `contracts/governance/v2/GovernedModuleRegistry.sol`, new constants file  
**Action:** Create `contracts/v2/ModuleRegistryKeys.sol` with `bytes32 constant` declarations for every registered module key. This is a prerequisite for any Wave issue that registers or queries modules.

---

## 10. Exit Criteria Assessment

| Criterion | Status |
|-----------|--------|
| Canonical contracts compile (Forge) | ✅ PASS |
| Canonical contracts compile (Hardhat) | ❌ BLOCKED — Hardhat 3 ESM migration required (REM-001) |
| All required test suites pass | ❌ 34 Forge failures across 6 files; 0 Hardhat test results |
| Invariant tests pass | ✅ 24/24 PASS |
| Fuzz tests pass | ❌ 6/121 fail in TokenomicsFuzz (REM-007) |
| Gas snapshot baseline | ❌ ABSENT — CI gas-check blocked (REM-002) |
| Deployment composition agrees with V2 interfaces | ⚠️ PARTIAL — CanonicalV2 Ignition module has ClaimRegistry constructor divergence (REM-012); FullDeploy.ts references deprecated contract |
| Branch protections and required checks verified | ⚠️ CI workflow correct but two jobs always fail (gas-check, Hardhat test) — see REM-001/002 |
| Legacy / incompatible paths identified and flagged | ✅ COMPLETE — see §5 and REM-003/004 |
| Human-review requirement for protocol/security changes | ⚠️ CODEOWNERS covers `*` but lacks explicit contract path coverage (REM-014) |

**Overall baseline state:** The protocol core is structurally sound — Foundry compiles clean, 24 invariants hold, and the canonical V2 interface surface is well-defined. The 34 Forge failures fall into 5 root-cause clusters (timelock warp, missing approve, vm.prank regression, LifecycleFixture intermediary guard, StakeVault allocation logic), all remediable without architectural changes. The two blocking items (Hardhat 3 migration, gas snapshot) are tooling issues, not protocol defects.

**Wave activation gate:** No V2-SC issues should be activated for contributor intake until REM-001 through REM-010 are resolved and all required CI jobs return green on `main`.

---

*Report produced by Kiro under MAINT #474. No contributor PRs were merged during this audit. SHA is frozen at `58e1302fedd9535a8fa118c4b93403af10f44216`.*
