# Protocol Upgrade & Version Management Framework

## Overview

The Upgrade & Version Management Framework governs how the TruthBounty protocol evolves
after deployment. It ensures that every upgrade is **versioned**, **authorised**,
**storage-compatible**, **migration-validated**, **timelocked**, **auditable**, and
**recoverable** — so the protocol can adopt new features and security fixes without
disruptive redeployments or risking user assets.

The framework is implemented by
[`contracts/upgrade/ProtocolUpgradeManager.sol`](../contracts/upgrade/ProtocolUpgradeManager.sol)
(interface: [`IProtocolUpgradeManager.sol`](../contracts/upgrade/IProtocolUpgradeManager.sol)).

It is an **on-chain authorisation & versioning registry**. It does not hold proxy-admin
rights and never calls `upgradeToAndCall` itself. Instead, each upgradeable module gates its
own upgrade hook against the registry (see [Proxy integration](#proxy-integration)). This
mirrors the sibling `BootstrapController` and `MigrationManager` frameworks and avoids
converting the whole protocol to a single monolithic proxy admin.

## Concepts

| Concept | Meaning |
|---------|---------|
| **Module** | An upgradeable protocol component, keyed by `bytes32` id (e.g. `keccak256("TRUTH_BOUNTY")`). |
| **Version** | Semantic `major.minor.patch`. Strictly monotonic per module (no accidental downgrade). |
| **Storage layout hash** | A fingerprint of an implementation's storage layout, recorded for audit and compatibility gating. |
| **Migration hash** | A commitment to the off-chain migration steps required by a layout-breaking upgrade. |
| **Upgrade proposal** | A pending transition from the current version/implementation to a target, moving through a fixed lifecycle. |
| **Authorised implementation** | The single implementation a module's proxy is currently permitted to adopt (`latestAuthorized`). |

## Lifecycle

```
registerModule
     │
     ▼
proposeUpgrade ──► attestStorageCompatibility ──► validateMigration ──► approveUpgrade
     │                                              (only if migration       │
     │                                               hash is set)      (starts timelock)
     ▼                                                                        ▼
cancelUpgrade  ◄──────────────── (proposer / admin / guardian) ─────►  executeUpgrade
                                                                              │
                                                                              ▼
                                                                    rollbackUpgrade (recovery)
```

1. **registerModule** — an `ADMIN` establishes a module's baseline: current implementation
   (must have code), version, and storage-layout hash. The baseline implementation is
   immediately marked authorised.
2. **proposeUpgrade** — a `PROPOSER` proposes a transition to a strictly newer version with a
   new implementation (must have code, differ from current) and its storage-layout hash. A
   `migrationHash` of `0` means no migration is required.
3. **attestStorageCompatibility** — a `VALIDATOR` attests whether the new implementation
   preserves storage compatibility. Layout cannot be introspected on-chain, so this is backed
   by tooling (e.g. OpenZeppelin upgrade-safety checks) in CI.
4. **validateMigration** — when a `migrationHash` is set, a `VALIDATOR` must supply the exact
   committed hash, binding off-chain migration review to on-chain approval.
5. **approveUpgrade** — an `UPGRADER` (governance-gated) approves, enforcing the
   [storage-compatibility policy](#storage-compatibility-policy) and starting the timelock.
6. **executeUpgrade** — an `EXECUTOR` finalises the upgrade after the timelock elapses. The
   module advances to the new version/implementation, the outgoing implementation is retained
   for rollback, and `latestAuthorized` is re-pointed.
7. **cancelUpgrade** — the proposer, an `ADMIN`, or a `GUARDIAN` may veto any non-executed
   proposal.
8. **rollbackUpgrade** — a `GUARDIAN`/`ADMIN` recovery path that restores the previously
   active implementation. It is intentionally executable even while the contract is paused.

## Storage compatibility policy

Enforced at `approveUpgrade`:

- Storage compatibility **must be attested** before approval.
- A **same-major** upgrade (minor/patch) must be attested **compatible** — layouts may only
  grow append-only within a major version.
- A **storage-incompatible** upgrade **must** carry a validated **migration** (`migrationHash`
  ≠ 0 and validated). This makes layout-breaking changes explicit and reviewed.

Since V2-SC-121 there is an additional **pre-approval gate**: the compiled storage layout of
every upgradeable contract is frozen in `storage-layouts/manifest.json` and CI fails on
unapproved drift (see [storage-layout manifests](./storage-layout-manifests.md). Layout drift
is therefore reviewed at the pull request that introduces it, long before any upgrade
proposal references the implementation.

## Roles

| Role | Capability |
|------|------------|
| `DEFAULT_ADMIN_ROLE` / `ADMIN_ROLE` | Register modules, set timelock, manage roles, cancel, rollback. |
| `PROPOSER_ROLE` | Create upgrade proposals. |
| `VALIDATOR_ROLE` | Attest storage compatibility; validate migrations. |
| `UPGRADER_ROLE` | Approve proposals (governance-gated authorisation step). |
| `EXECUTOR_ROLE` | Execute approved proposals after the timelock. |
| `GUARDIAN_ROLE` | Veto pending proposals; perform emergency rollback. |
| `PAUSER_ROLE` | Pause/unpause the manager. |

Separating `PROPOSER`, `VALIDATOR`, `UPGRADER`, and `EXECUTOR` enforces multi-party control:
no single actor can propose, validate, approve, and execute an upgrade alone.

### Proxy upgrade authority boundary

For modules inheriting `ProtocolUpgradeable`, the configured upgrade controller must also
hold `GOVERNANCE_ROLE` to authorize a UUPS upgrade. `DEFAULT_ADMIN_ROLE` alone cannot
authorize an implementation, change the configured controller, or grant either governance
or upgrade-controller authority. Governance is the admin of both authority roles; initialize
the module with the governance-controlled executor as its upgrade controller, and ensure
that executor holds `GOVERNANCE_ROLE`. Direct implementation initialization remains disabled
by the implementation constructor.

## Timelock

Approvals start a configurable `upgradeTimelock` (default **2 days**, bounded to
`[1 hour, 30 days]`, settable by `ADMIN` via `setUpgradeTimelock`). Execution reverts with
`TimelockNotPassed` until it elapses, giving the community a window to review or veto.

## Proxy integration

An upgradeable (e.g. UUPS) module consults the registry from its authorisation hook:

```solidity
import "../upgrade/IProtocolUpgradeManager.sol";

contract MyModule is UUPSUpgradeable {
    IProtocolUpgradeManager public upgradeManager;
    bytes32 public constant MODULE_ID = keccak256("MY_MODULE");

    function _authorizeUpgrade(address newImplementation) internal view override {
        require(
            upgradeManager.isUpgradeAuthorized(MODULE_ID, newImplementation),
            "upgrade not authorised"
        );
    }
}
```

Only an implementation that has completed the full lifecycle (or the current/rolled-back
implementation) is authorised at any time.

## Auditability

Every transition emits an event (`ModuleRegistered`, `UpgradeProposed`,
`StorageCompatibilityAttested`, `MigrationValidated`, `UpgradeApproved`, `UpgradeExecuted`,
`UpgradeCancelled`, `UpgradeRolledBack`, `UpgradeTimelockUpdated`). On-chain history is
queryable via `getUpgradeProposal`, `getModuleUpgradeHistory`, `getModuleState`, and the
module enumeration getters — a complete, deterministic upgrade trail.

## Testing

```bash
npm install
npm run compile
npx hardhat test test/ProtocolUpgradeManager.test.ts
```
