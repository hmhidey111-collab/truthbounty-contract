# V2 Cross-Module Authorization Model (V2-SC-093)

Every module-to-module caller edge in the canonical V2 surface, and why user, guardian, governance, settlement, treasury and registry authority cannot be confused with one another or escalated.

Enforced by `contracts/v2/StakeVault.sol` and `contracts/v2/FinalRewardAllocator.sol`. Proved by `test/v2/invariant/CrossModuleAuthorizationInvariant.t.sol`.

## Three independent axes

Authority in V2 comes from three sources that must never imply one another.

**Axis 1 — registry identity.** A caller is "the SETTLEMENT module" only if the module registry currently maps `keccak256("SETTLEMENT")` to its address. Identity is a live lookup, never a stored grant, so rotation takes effect in the same block.

**Axis 2 — governance roles.** `ADMIN_ROLE` on the vault configures supported assets and appoints explicit lock mutators. It confers no custody authority of its own.

**Axis 3 — account ownership.** A user may move their own claimable balance and nothing else.

## The two authorization tiers

| Tier | Guard | Satisfied by | Grants |
| --- | --- | --- | --- |
| 1 — lock mutation | `StakeVault._onlyAuthorizedMutator` | an explicit `lockMutators` entry, **or** the registered `SLASHING`, `SETTLEMENT`, or `VERIFICATION` module | `lock`, `unlock`, `allocateLocked`, `releaseStake`, `slashStake` |
| 2 — settlement execution | `_onlySettlementModule` | **only** the registered `SETTLEMENT` module | `settleConclusive`, `refundInconclusive`, `carryForwardAppeal`, `rolloverRound`, `finalUnlock`; on the allocator, `fund` and `finalizeRewards` |

**Tier 1 does not imply tier 2.** This is the central confusion this harness rules out. `SLASHING` and `VERIFICATION` both hold tier 1, and an explicit governance mutator does too — none of them may execute a settlement hook. If any could, a slashing module would be able to declare a settlement outcome for a claim-round and redirect or release principal. `StakeVault.isAuthorizedMutator` documents this in prose ("a true result is necessary but not sufficient for settlement hooks"); `test_tier1AuthorityDoesNotGrantSettlementHooks` enforces it.

## Caller-edge matrix

Rows are callers; columns are the guarded surfaces. `Y` means permitted.

| Caller | Tier 1 (locks) | Tier 2 (settlement) | `ADMIN_ROLE` config | Own balance |
| --- | --- | --- | --- | --- |
| registered `SETTLEMENT` | Y | Y | — | — |
| registered `SLASHING` | Y | — | — | — |
| registered `VERIFICATION` | Y | — | — | — |
| explicit `lockMutators` entry | Y | — | — | — |
| `ADMIN_ROLE` holder (governance) | — | — | Y | — |
| user / verifier | — | — | — | Y |
| guardian | — | — | — | — |
| rotated-out module | — | — | — | — |
| unregistered address | — | — | — | — |

Governance's blank in the tier-1 column is deliberate: holding `ADMIN_ROLE` does not make you a mutator. Governance may appoint *itself* via `setLockMutator`, which is an explicit, auditable act rather than an implicit consequence of the role — and even then tier 2 stays closed.

## Revocation

- **Rotation revokes immediately.** Re-pointing a module id to a new address removes the previous holder's authority in the same block. There is no grandfathering, so a rotated-out settlement module cannot finish work in flight.
- **Removal revokes immediately.** `removeModule` drops tier-1 authority for that id.
- **Explicit mutators are registry-independent by design.** A `lockMutators` entry is a governance override, so it survives registry changes and is revoked the same way it was granted. `setLockMutator` emits no event; the public mapping and the governance transaction trace are the audit record.

## Deployment isolation

Module identity is per-registry, not global. A settlement module registered in one deployment's registry has no authority over a vault wired to a different registry, in either direction. Two deployments sharing an asset therefore cannot settle each other's claims.

## Fail-closed on unknown ids

`StakeVault._isRegisteredModule` checks `isRegistered(moduleId)` **before** comparing the implementation address. An id that is absent authorizes nobody, including `address(0)`.

### Known divergence: the allocator trusts the address alone

`FinalRewardAllocator._onlySettlementModule` compares `module(MODULE_SETTLEMENT)` to `msg.sender` and never consults `isRegistered`. Against a registry that retains a stale implementation address after deregistration, the vault denies the call and the allocator accepts it.

This is recorded as a hardening item, not a live exploit: `IModuleRegistry` requires an implementation to revert or return zero for unknown ids, so a conforming registry never reaches that state, and a zero address can never equal a caller. It is worth fixing anyway, because the two canonical modules disagree about how much they trust the registry and the weaker of the two guards treasury funding. The fix is one `isRegistered` check, matching the vault.

`test_stakeVaultDeniesDeregisteredModuleWithStaleAddress` and `test_finalRewardAllocatorTrustsTheAddressAloneKnownDivergence` pin both behaviours, so hardening the guard shows up as a deliberate, reviewed change rather than a silent one.

## Escalation paths that are closed

- A module cannot grant itself a role (`grantRole` requires `DEFAULT_ADMIN_ROLE`).
- An appointed lock mutator cannot promote itself to `ADMIN_ROLE`.
- A module cannot appoint another mutator or reconfigure supported assets.
- No caller can withdraw another account's claimable balance.
- No unauthorized caller can record a settlement outcome, which would otherwise permanently freeze a claim-round via `_assertSettlementNotFinalized`.

## Invariants asserted

`CrossModuleAuthorizationInvariantTest` drives four unauthorized principals at every privileged entry point on both modules and requires that, after any sequence:

| Invariant | Statement |
| --- | --- |
| `invariant_unauthorizedCallersCannotMoveLockedPrincipal` | the victim's lock is byte-identical |
| `invariant_unauthorizedCallersCannotSlash` | protocol allocation never grew |
| `invariant_unauthorizedCallersCannotRecordSettlement` | no settlement outcome was recorded |
| `invariant_unauthorizedCallersCannotFundTheAllocator` | no treasury funding was accepted |
| `invariant_custodyUnchangedAndReconciled` | custody is unchanged and still reconciles |
| `invariant_noRoleWasEscalated` | no attacker holds a role or a mutator entry |

The handler holds no authority of its own: the vault is deployed with a separate governance address specifically so the handler cannot legitimately appoint itself and invalidate its own invariants.

## Source of truth

The module registry is authoritative for module identity, and `AccessControl` for roles. No API, indexer, frontend, guardian, deployer, or test harness holds settlement or treasury authority at any point in this model.
