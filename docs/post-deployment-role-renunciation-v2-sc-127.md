# Post-Deployment Role Renunciation Checks (V2-SC-127)

## Overview

V2-SC-127 closes the assurance gap between deployment and operational handoff. After
every V2 deployment, the deployer EOA and any bootstrap script must hold **zero**
protocol roles. This module provides:

1. **On-chain library** — `PostDeploymentRoleCheck.sol` — deterministic role sweep
2. **Forge verification script** — `VerifyRoleRenunciation.s.sol` — live/dry-run audit
3. **Foundry unit tests** — positive, negative, boundary, authorization, replay, failure-path
4. **Foundry fuzz tests** — arbitrary addresses and target arrays
5. **Foundry invariant tests** — stateful verification that roles cannot be re-acquired
6. **Hardhat tests** — canonical V2 suite integration with `deployCanonicalV2`

## Trust Boundaries

```
┌─────────────────────────────────────────────────────────────┐
│                    POST-HANDOFF STATE                        │
│                                                             │
│  Deployer EOA ──── holds ZERO roles on ALL contracts        │
│                                                             │
│  TimelockController ─┬── DEFAULT_ADMIN_ROLE (self)          │
│                      ├── PROPOSER_ROLE → Governor           │
│                      ├── CANCELLER_ROLE → Governor, Guardian│
│                      └── EXECUTOR_ROLE → address(0) [open]  │
│                                                             │
│  GovernedModuleRegistry ── REGISTRY_ADMIN_ROLE → Timelock   │
│                                                             │
│  GovernanceGuardian ── GUARDIAN_ROLE → Guardian EOA          │
│                        DEFAULT_ADMIN_ROLE → renounced       │
│                                                             │
│  Governor ── no AccessControl roles (uses onlyGovernance)   │
│                                                             │
│  All other modules ── DEFAULT_ADMIN_ROLE → Timelock/Gov     │
└─────────────────────────────────────────────────────────────┘
```

## Role Catalog

The library checks **27 distinct roles** covering every known V2 role hash:

| Role | Hash | Contracts |
|------|------|-----------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | All AccessControl contracts, including the `TimelockController` (OZ `>= 5.0` self-administration role) |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | WeightedStaking, VerifierSlashing, VerificationAggregator, StakeVault, TruthBountyClaims, MigrationManager, ProtocolUpgradeManager |
| `PROPOSER_ROLE` | `keccak256("PROPOSER_ROLE")` | TimelockController, ProtocolUpgradeManager |
| `EXECUTOR_ROLE` | `keccak256("EXECUTOR_ROLE")` | TimelockController, ProtocolUpgradeManager |
| `CANCELLER_ROLE` | `keccak256("CANCELLER_ROLE")` | TimelockController |
| `TIMELOCK_ADMIN_ROLE` | `keccak256("TIMELOCK_ADMIN_ROLE")` | Retired (OZ `< 5.0`). Kept in the catalog so a stale legacy grant is flagged as residual authority. |
| `GUARDIAN_ROLE` | `keccak256("GUARDIAN_ROLE")` | GovernanceGuardian, ProtocolUpgradeManager |
| `GOVERNANCE_ROLE` | `keccak256("GOVERNANCE_ROLE")` | UpgradeController, TreasuryManagement |
| `REGISTRY_ADMIN_ROLE` | `keccak256("REGISTRY_ADMIN_ROLE")` | GovernedModuleRegistry |
| `REGISTRY_UPDATER_ROLE` | `keccak256("REGISTRY_UPDATER_ROLE")` | ClaimRegistry |
| `UPGRADE_ROLE` | `keccak256("UPGRADE_ROLE")` | UpgradeController |
| `EMERGENCY_UPGRADE_ROLE` | `keccak256("EMERGENCY_UPGRADE_ROLE")` | UpgradeController |
| `UPGRADER_ROLE` | `keccak256("UPGRADER_ROLE")` | MigrationManager |
| `UPGRADE_CONTROLLER_ROLE` | `keccak256("UPGRADE_CONTROLLER_ROLE")` | ProtocolUpgradeable |
| `PAUSER_ROLE` | `keccak256("PAUSER_ROLE")` | VerifierSlashing, EvidenceRegistry, MigrationManager, ProtocolUpgradeManager |
| `RESOLVER_ROLE` | `keccak256("RESOLVER_ROLE")` | VerifierSlashing |
| `ROUND_MANAGER_ROLE` | `keccak256("ROUND_MANAGER_ROLE")` | VerificationRoundManager |
| `CRITICAL_SLASHER_ROLE` | `keccak256("CRITICAL_SLASHER_ROLE")` | VerifierSlashing |
| `TREASURY_ROLE` | `keccak256("TREASURY_ROLE")` | TruthBountyClaims, TruthBountyWeighted |
| `TREASURY_MANAGER_ROLE` | `keccak256("TREASURY_MANAGER_ROLE")` | TreasuryManagement |
| `EVIDENCE_ADMIN_ROLE` | `keccak256("EVIDENCE_ADMIN_ROLE")` | EvidenceRegistry |
| `EVALUATOR_ROLE` | `keccak256("EVALUATOR_ROLE")` | ParticipationThresholdEngine |
| `CONFIG_ADMIN_ROLE` | `keccak256("CONFIG_ADMIN_ROLE")` | FrozenRoundConfigStore |
| `VALIDATOR_ROLE` | `keccak256("VALIDATOR_ROLE")` | ProtocolUpgradeManager |
| `MIGRATOR_ROLE` | `keccak256("MIGRATOR_ROLE")` | MigrationManager |
| `MINTER_ROLE` | `keccak256("MINTER_ROLE")` | Token extensions |
| `REGISTRY_ROLE` | `keccak256("REGISTRY_ROLE")` | VersionRegistry |

## Handoff Sequence

The correct post-deployment handoff must execute these steps in order:

```solidity
// 1. Wire governance topology
GovernanceRoleTopology.configure(timelock, governor, guardian, minDelay);

// 2. Transfer timelock administration to the timelock itself.
//    OZ TimelockController >= 5.0 administers its role graph with DEFAULT_ADMIN_ROLE and no
//    longer defines TIMELOCK_ADMIN_ROLE. finalizeTimelockAdmin revokes DEFAULT_ADMIN_ROLE from
//    the bootstrap admin (and retires any stale legacy TIMELOCK_ADMIN_ROLE grant), leaving the
//    timelock as the sole role-graph authority.
GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);

// 3. Transfer module registry admin to timelock — the grant targets the registry contract.
registry.grantRole(REGISTRY_ADMIN_ROLE, address(timelock));

// 4. Renounce all deployer roles
registry.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
registry.renounceRole(REGISTRY_ADMIN_ROLE, deployer);
guardianContract.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
// ... repeat for every contract where deployer holds roles

// 5. Machine-check the deployed role graph against the canonical policy
PostDeploymentRoleCheck.assertRoleGraphMatchesPolicy(timelock, governor, guardian);
```

> [!WARNING]
> Skipping any step leaves the deployer with unauthorized power. The
> `PostDeploymentRoleCheck.assertNoRolesRetained()` function will revert
> and emit `RoleRenunciationViolation` events for every retained role.

## Gate B Reconciliation (#690): Timelock Administration Role

### Root cause

`GovernanceRoleTopology.configure`/`finalizeTimelockAdmin` moved the retired
`TIMELOCK_ADMIN_ROLE` hash, but OpenZeppelin `TimelockController >= 5.0` does not define that
role. It grafts the timelock role graph onto `DEFAULT_ADMIN_ROLE` (0x00): the constructor grants
`DEFAULT_ADMIN_ROLE` to `address(this)` and, when the `admin` argument is non-zero, to that
bootstrap administrator (OZ 5.6.1 `TimelockController.sol` lines 115–121).

The handoff therefore granted and revoked a role nobody held, while the bootstrap deployer kept
`DEFAULT_ADMIN_ROLE` on the timelock — the admin of `PROPOSER_ROLE`, `CANCELLER_ROLE` and
`EXECUTOR_ROLE`. That residual authority is the single role that
`testFuzz_ArbitraryAddress_NoRolesAfterHandoff` reported:

```
[FAIL: arbitrary account should have no roles after handoff: 1 != 0;
 counterexample: args=[0x00000000000000000000000000000000000000D1]]
```

A second latent defect existed in the same path: `DeployGovernanceV2` and several fixtures called
`timelock.grantRole(REGISTRY_ADMIN_ROLE, address(timelock))`. That minted an unused
timelock-side role and left the registry itself without a `REGISTRY_ADMIN_ROLE` holder, so the
governance graph never matched the documented topology.

### Fix

| Change | Rationale |
|--------|-----------|
| `finalizeTimelockAdmin` revokes `DEFAULT_ADMIN_ROLE` from the bootstrap admin | `DEFAULT_ADMIN_ROLE` is the only authority over the timelock role graph in OZ `>= 5.0` |
| `finalizeTimelockAdmin` skips the timelock address | A caller can never strip the timelock's own self-administration and brick the role graph |
| `LEGACY_TIMELOCK_ADMIN_ROLE` retained (revoke-only) | A stale grant from a pre-v5 deployment is retired during handoff and stays in the catalog so enumeration flags it |
| `TimelockAdminFinalized` event | Records the retired admin and whether a legacy grant was retired |
| `registry.grantRole(REGISTRY_ADMIN_ROLE, timelock)` | The grant belongs on the registry, not on the timelock |
| `PostDeploymentRoleCheck.roleGraph` / `checkExpectations` | Machine-verifiable before/after role-graph snapshots and expected-edge assertions |

### Role graph (account → target → role)

| Account | Target | Role | Before handoff | After handoff |
|---------|--------|------|----------------|---------------|
| deployer | timelock | `DEFAULT_ADMIN_ROLE` | ✅ | ❌ |
| deployer | timelock | `TIMELOCK_ADMIN_ROLE` (legacy) | ❌ (never granted) | ❌ |
| timelock | timelock | `DEFAULT_ADMIN_ROLE` | ✅ | ✅ |
| governor | timelock | `PROPOSER_ROLE` | ❌ | ✅ |
| governor | timelock | `CANCELLER_ROLE` | ❌ | ✅ |
| guardian | timelock | `CANCELLER_ROLE` | ❌ | ✅ |
| address(0) | timelock | `EXECUTOR_ROLE` | ❌ | ✅ |
| deployer | registry | `DEFAULT_ADMIN_ROLE`, `REGISTRY_ADMIN_ROLE` | ✅ | ❌ |
| timelock | registry | `REGISTRY_ADMIN_ROLE` | ❌ | ✅ |
| deployer | guardian | `DEFAULT_ADMIN_ROLE` | ✅ | ❌ |
| guardian | guardian | `GUARDIAN_ROLE` | ✅ | ✅ |

The post-handoff graph contains exactly seven edges. `test_RoleGraph_AfterHandoff_ExactlyApprovedGraph`
asserts the count and every edge; `test_ExpectedGovernanceGraph_MachineVerifiable` asserts the same
graph, plus the prohibited deployer edges, through `PostDeploymentRoleCheck.checkExpectations`.

### Deterministic reproduction

Toolchain used for these results:

| Component | Version |
|-----------|---------|
| Foundry (`forge`) | 1.8.5, commit `51a52c59cffd940f76eddd0b4bb1791aa4b5ac7f` |
| solc | 0.8.28 (pinned in `foundry.toml` and `hardhat.config.ts`) |
| EVM version | `cancun` |
| OpenZeppelin Contracts | 5.6.1 (`lib/openzeppelin-contracts/package.json`) |
| Fuzz runs | 1000 (`[profile.default.fuzz]`) |

```bash
# 1. Failing gate on the pre-fix tree (deterministic counterexample: 0xD1)
forge test --match-test testFuzz_ArbitraryAddress_NoRolesAfterHandoff -vv

# 2. Post-fix gates
forge test --match-test testFuzz_ArbitraryAddress_NoRolesAfterHandoff -vv
forge test --match-path 'test/governance/TimelockAdminHandoffReconciliation.t.sol'
forge test --match-path 'test/fuzz/RoleRenunciationFuzz.t.sol'
forge test --match-path 'test/invariant/DeployerRoleRenunciationInvariant.t.sol'
forge test --match-path 'test/deployment/PostDeploymentRoleRenunciation.t.sol'
forge test --match-path 'test/governance/GovernanceRoleTopologyConformance.t.sol'
```

Every fuzz test above is seed-deterministic and runs the pinned 1000 runs; the pre-fix failure in
step 1 reproduces on the first runs because the deployer address is a fixed fixture value (`0xD1`).

Failures in `Create2AddressPlanner`, `DeploymentAttestationRegistry`, `EmergencyRecoveryDrills`,
`TruthBountyGovernor` (guardian-module double-set) and `GovernanceSnapshot` voting-power tests are
pre-existing on `main` and are unrelated to this reconciliation; they are not masked or skipped.

## Running Verification

### Forge (local/CI)

```bash
# Unit tests
forge test --match-contract PostDeploymentRoleRenunciationTest -vvv

# Fuzz tests
forge test --match-contract RoleRenunciationFuzz -vvv

# Invariant tests
forge test --match-contract DeployerRoleRenunciationInvariantTest -vvv

# Live deployment verification
forge script script/deploy/VerifyRoleRenunciation.s.sol \
  --rpc-url $RPC_URL \
  --sig "runFromManifest(string)" \
  "deployments/mainnet/manifest.json"
```

### Hardhat

```bash
npx hardhat test test/deployment/PostDeploymentRoleRenunciation.test.ts
```

## Test Coverage Matrix

| Category | Foundry | Hardhat | Count |
|----------|---------|---------|-------|
| Positive (handoff passes) | ✅ | ✅ | 7 |
| Negative (pre-handoff detected) | ✅ | ✅ | 6 |
| Boundary (partial, zero-addr, EOA) | ✅ | ✅ | 6 |
| Authorization (re-acquisition blocked) | ✅ | ✅ | 7 |
| Replay (idempotent checks) | ✅ | ✅ | 4 |
| Failure-path (missing steps detected) | ✅ | — | 3 |
| Fuzz (arbitrary inputs) | ✅ | — | 6 |
| Invariant (stateful) | ✅ | — | 3 |
| Catalog integrity | ✅ | — | 4 |
| Gate B handoff reconciliation (#690) | ✅ | — | 13 |
| **Total** | | | **59** |

## Migration Impact

- **No storage changes** — library is stateless, uses only `staticcall`.
- **No ABI changes** — no new public functions on existing contracts.
- **No active-claim impact** — read-only verification, no state mutation.
- **Backward compatible** — existing deployment scripts are unmodified; the check
  library is additive.

## Residual Risk

| Risk | Mitigation |
|------|------------|
| New role added to a contract but not in catalog | Role catalog must be updated when new roles are defined. CI should flag new `bytes32 public constant` role declarations. |
| Contract does not implement `IAccessControl` | `_safeHasRole` uses `staticcall` with error handling — returns `false` for non-conforming targets. |
| Deployer is a multisig that retains signing power | This check verifies on-chain role state only. Off-chain key custody is out of scope. |
| Timelock self-admin could be exploited | Invariant test verifies the timelock retains `DEFAULT_ADMIN_ROLE` (and holds no retired `TIMELOCK_ADMIN_ROLE`) after handoff. Governance proposals are the only path to role changes. |

## File Map

| File | Purpose |
|------|---------|
| [`PostDeploymentRoleCheck.sol`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/contracts/deployment/PostDeploymentRoleCheck.sol) | Core library — role catalog + check logic |
| [`VerifyRoleRenunciation.s.sol`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/script/deploy/VerifyRoleRenunciation.s.sol) | Forge script for live verification |
| [`PostDeploymentRoleRenunciation.t.sol`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/test/deployment/PostDeploymentRoleRenunciation.t.sol) | Foundry unit tests (30+ cases) |
| [`RoleRenunciationFuzz.t.sol`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/test/fuzz/RoleRenunciationFuzz.t.sol) | Foundry fuzz tests |
| [`TimelockAdminHandoffReconciliation.t.sol`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/test/governance/TimelockAdminHandoffReconciliation.t.sol) | Gate B (#690) handoff regression + role-graph conformance |
| [`DeployerRoleRenunciationInvariant.t.sol`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/test/invariant/DeployerRoleRenunciationInvariant.t.sol) | Foundry invariant tests |
| [`PostDeploymentRoleRenunciation.test.ts`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/test/deployment/PostDeploymentRoleRenunciation.test.ts) | Hardhat integration tests |
| [`post-deployment-role-renunciation-v2-sc-127.md`](file:///c:/Users/HomePC/.antigravity-ide/truthbounty-contract/docs/post-deployment-role-renunciation-v2-sc-127.md) | This document |

## Dependencies

- **V2-SC-111** — prerequisite (role topology definitions)
- **V2-SC-121** — prerequisite (deployment script finalization hooks)
- **V2-SC-026** — `GovernanceRoleTopology` library (consumed, not modified)
- **V2-SC-027** — V2 governance contracts (consumed, not modified)
