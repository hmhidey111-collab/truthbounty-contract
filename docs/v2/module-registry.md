# V2 Canonical Module Registry (V2-SC-005)

**Specification:** [TruthBounty V2], §26 canonical module registry & dependency validation
**Audit scope:** `contracts/v2/interfaces/IModuleRegistry.sol`, `contracts/v2/ModuleRegistry.sol`,
`contracts/v2/libraries/ModuleRegistryLib.sol`, `contracts/mocks/MockModuleRegistry.sol`,
`contracts/mocks/MockV2Module.sol`

## Purpose

Every TruthBounty V2 canonical module is resolvable by a **stable `keccak256` key** and records a
**versioned registration** (interface ID, proxy/implementation metadata, status). Replacements only
take effect through a **timelocked governance path** so a compromised or stale authority cannot swap
a module immediately. The registry also provides **preflight views** and **reusable dependency
validation** for the deployment tooling and consumer manifests.

This supersedes the legacy permissive stub that accepted any address with zero validation. It is the
**sole** canonical module registry for V2; `StakeVault` discovers its settlement/slashing/verification
modules through `module(bytes32)` / `isRegistered(bytes32)` exactly as before.

## Canonical manifest

Fourteen canonical keys (the registry itself is **not** registrable — self-registration is rejected):

| Key (keccak256 text) | Canonical interface | Frozen ID (V2-SC-001) |
|---|---|---|
| `CONFIGURATION` | `IConfiguration` | `0x6b73d71f` |
| `CLAIMS` | `IClaims` | `0x38a3ec24` |
| `EVIDENCE` | `IEvidence` | `0x549aab2c` |
| `STAKE_CUSTODY` | `IStakeCustody` | `0x3e53b374` |
| `VERIFICATION` | `IVerification` | `0x3833e81d` |
| `AGGREGATION` | `IAggregation` | `0xf06520f1` |
| `SETTLEMENT` | `ISettlement` | `0xd7d9d5f0` |
| `DISPUTES` | `IDisputes` | `0x98581ac8` |
| `REWARDS` | `IRewards` | `0xe0e8be78` |
| `SLASHING` | `ISlashing` | `0x2bf473dd` |
| `TREASURY` | `ITreasury` | `0xd766ec85` |
| `REPUTATION_ROOTS` | `IReputationRoots` | `0x7b699d8e` |
| `GOVERNANCE_HOOKS` | `IGovernanceHooks` | `0x76228b23` |
| `EMERGENCY_CONTROLS` | `IEmergencyControls` | `0x5c85bbe3` |

Each registered module must additionally support `type(IV2Module).interfaceId`.

### Dependency edgeset (11 edges)

`EVIDENCE→CLAIMS` · `VERIFICATION→{CLAIMS, EVIDENCE, STAKE_CUSTODY}` ·
`AGGREGATION→VERIFICATION` · `SETTLEMENT→{AGGREGATION, STAKE_CUSTODY}` ·
`DISPUTES→{CLAIMS, VERIFICATION}` · `REWARDS→{SETTLEMENT, TREASURY}`

The edgeset is exposed as `canonicalDependencies()`, satisfied live by `checkDependencies(bytes32[])`,
and enforced by `ModuleRegistry._dependenciesSatisfied()` (intra-batch aware) during activation.

## Authority model

| Role | Permissions |
|---|---|
| `DEPLOYMENT_ROLE` | `registerModule(s)`, `activateModule(s)` |
| `GOVERNANCE_ROLE` | `proposeModuleReplacement`, `cancelModuleReplacement`, `deprecateModule`, `removeModule`, `forbidModule`, `unforbidModule` |
| `GUARDIAN_ROLE` | **explicitly rejected** from every registry mutation (`GuardianCannotReplaceModule`) |
| anyone | `activateModuleReplacement` after the timelock (cannot be censored) |

## Registration validation (reverts on first failure)

1. key must be canonical; interface ID must be non-zero
2. key not deprecated; proxy non-zero, not the registry itself, and not an EOA
3. proxy/implementation not on the **forbidden** (legacy quarantine) list
4. proxy not already bound to another key (`DuplicateProxy` → prevents circular authority)
5. `ERC165Checker`: proxy supports `IV2Module` **and** its claimed interface, and the claimed
   interface equals the frozen canonical ID for the key
6. `protocolVersion()` probe: major must be 2 (release-compatible) and must equal the declared
   `major`/`minor` (`DeclaredVersionMismatch` enforced)

`preflightRegistration` / `preflightActivation` / `validateCanonicalSuite` mirror the same checks as
**non-reverting** views returning `{ok, versionId, canonicalInterfaceId, errorCode, reason}` for
deployment and manifest tooling.

## Versioning and replacement

- `versionIdOf(reg) = keccak256(moduleId, interfaceId, proxy, implementation, major, minor)`.
- REPLACEMENT_DELAY is **2 days**. Propose (governance) → `ModuleReplacementProposed` → wait → anyone
  activates. `activateModuleReplacement` re-runs full validation so the new proxy must be valid *and*
  satisfy its canonical dependencies; identical registrations revert `ReplacementNoop`.
- `deprecateModule` renders a key permanently non-activatable (status `DEPRECATED`, immediately
  untracked by `isRegistered()`); `removeModule` deletes the record; `forbidModule` quarantines an
  address from ever being used as a proxy/implementation again.

## Atomic batches

`registerModules` and `activateModules` are all-or-nothing: every element is validated (including
intra-batch dependency resolution) before any storage write, so a failed batch cannot partially
change the suite.

## Backwards compatibility

- `module(bytes32) → (proxy, major, minor)` and `isRegistered(bytes32) → status == ACTIVE` keep the
  `StakeVault._isRegisteredModule` / `_onlySettlementModule` consumer shape and semantics.
- `MockModuleRegistry` remains a permissive test double (auto-activates, `permitModule(key, addr)`
  one-line helper) used by the StakeVault suites; it performs no validation by design.

## Test evidence

- Foundry: `test/v2/ModuleRegistry.t.sol` — 42 tests (registration events/auth, atomic batches,
  intra-batch dependency resolution, EOA/self/duplicate-proxy/forbidden/unknown-key fuzz, interface &
  version mismatch, deprecation, guardian exclusion, timelocked replacement, preflight views,
  full-suite bootstrap, legacy-stub regression).
- Hardhat (approved v3 style, `network.create()`): `test/ModuleRegistry.test.ts` — 15 tests covering
  registration/activation, unsafe-input rejection, governance redress/timelock, manifest and
  preflight views.
- Full CI suite: `forge test --no-match-path "test/{invariant,fuzz}/**"` reports the same **28**
  pre-existing failures as at HEAD (baseline in `<repo>/docs` change log / PR description); the
  remaining suite passes with the new registry work.