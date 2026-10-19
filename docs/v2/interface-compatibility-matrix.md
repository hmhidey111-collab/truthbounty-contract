# Protocol Interface Compatibility Matrix (`V2-SC-135`)

Generated from `contracts/v2/interfaces` by `scripts/checkInterfaceCompatibility.ts`. Protocol version 2.0. Do not edit by hand — run the script with `--write`.

## Module matrix

| Module | Kind | Interface ID | Inherits | Functions | Errors | Events | Structs | Enums | protocolVersion |
|---|---|---|---|---|---|---|---|---|---|
| `IAggregation` | module | `0xf06520f1` | `IV2Module` | 2 | 0 | 1 | 0 | 0 | inherited |
| `ICanonicalV2` | aggregate | `not advertised (no declared members)` | `IConfiguration`, `IModuleRegistry`, `IClaims`, `IEvidence`, `IStakeCustody`, `IVerification`, `IAggregation`, `ISettlement`, `IDisputes`, `IRewards`, `ISlashing`, `ITreasury`, `IReputationRoots`, `IGovernanceHooks`, `IEmergencyControls` | 0 | 0 | 0 | 0 | 0 | inherited |
| `IClaims` | module | `0x38a3ec24` | `IV2Module` | 4 | 0 | 2 | 0 | 0 | inherited |
| `IConfiguration` | module | `0x6b73d71f` | `IV2Module` | 4 | 1 | 1 | 1 | 0 | inherited |
| `IDisputes` | module | `0x98581ac8` | `IV2Module` | 3 | 0 | 2 | 0 | 0 | inherited |
| `IEmergencyControls` | module | `0x5c85bbe3` | `IV2Module` | 3 | 0 | 2 | 0 | 0 | inherited |
| `IEvidence` | module | `0x549aab2c` | `IV2Module` | 4 | 0 | 2 | 0 | 0 | inherited |
| `IFinalRewardAllocator` | module | `0xa3c19fb5` | `IV2Module` | 8 | 0 | 4 | 1 | 2 | inherited |
| `IGovernanceHooks` | module | `0x76228b23` | `IV2Module` | 3 | 0 | 2 | 0 | 0 | inherited |
| `IModuleRegistry` | module | `0x2970b48f` | `IV2Module` | 4 | 0 | 2 | 0 | 0 | inherited |
| `IReputationRoots` | module | `0x7b699d8e` | `IV2Module` | 4 | 0 | 2 | 0 | 0 | inherited |
| `IRewards` | module | `0xe0e8be78` | `IV2Module` | 3 | 0 | 2 | 0 | 0 | inherited |
| `ISettlement` | module | `0xd7d9d5f0` | `IV2Module` | 3 | 0 | 2 | 0 | 0 | inherited |
| `ISlashing` | module | `0x2bf473dd` | `IV2Module` | 3 | 0 | 2 | 0 | 0 | inherited |
| `IStakeCustody` | module | `0x3e53b374` | `IV2Module` | 11 | 0 | 8 | 0 | 0 | inherited |
| `ITreasury` | module | `0xd766ec85` | `IV2Module` | 3 | 0 | 2 | 0 | 0 | inherited |
| `IV2Module` | base | `0x2ae9c600` | `IERC165` | 1 | 0 | 0 | 0 | 0 | declared |
| `IV2Types` | types | `not advertised (no declared members)` | — | 0 | 0 | 0 | 5 | 7 | inherited |
| `IVerification` | module | `0x3833e81d` | `IV2Module` | 3 | 0 | 1 | 0 | 0 | inherited |

## Shared function surface

| Signature | Selector | Modules | Intentional | Note |
|---|---|---|---|---|
| `protocolVersion()` | `0x2ae9c600` | `IAggregation`, `IClaims`, `IConfiguration`, `IDisputes`, `IEmergencyControls`, `IEvidence`, `IFinalRewardAllocator`, `IGovernanceHooks`, `IModuleRegistry`, `IReputationRoots`, `IRewards`, `ISettlement`, `ISlashing`, `IStakeCustody`, `ITreasury`, `IVerification` | yes | IV2Module base discovery surface; identical meaning in every module |

## Event name collisions

| Name | Signatures | Modules |
|---|---|---|
| `RewardClaimed` | `RewardClaimed(address,address,uint256)`<br>`RewardClaimed(address,uint256,uint64,uint16)` | `IFinalRewardAllocator`, `IRewards` |

## Published artifact alignment

- `schemas/event-schema-v1.json`: 51 published topics.
- Canonical event topics: 37.
- Topic overlap: 0.
- Published-only topics (legacy V1 catalogue): 51; canonical-only topics: 37.
- Version fixture declaration: `2.0`.

## Documented divergences

- schemas/event-schema-v1.json publishes the legacy V1 event catalogue (51 topics) and shares 0 topic0 with the 37 canonical V2 events; consumers must treat the two catalogues as disjoint and read canonical V2 events from the V2-SC-131 export.
- IFinalRewardAllocator is a canonical module interface that is not named by ICanonicalV2: Published extension surface for the reward allocator; ICanonicalV2 names the 15 ownership modules from docs/v2/interface-ownership.md.
- RewardClaimed is emitted by IFinalRewardAllocator, IRewards with distinct signatures; decode by topic0, not by name.

## Aggregate manifest coverage

`ICanonicalV2` declares 0 members and inherits 15 interfaces. Not named: `IFinalRewardAllocator`.

## Invariants

| Invariant | Status | Detail |
|---|---|---|
| `unique-interface-ids` | pass | Every module advertises a distinct ERC-165 interface id. |
| `module-declares-migration-base` | pass | Every module inherits IV2Module and therefore exposes protocolVersion(). |
| `unique-function-selectors` | pass | No selector collision inside any module. |
| `declared-shared-functions` | pass | Every cross-module selector is documented in INTENTIONAL_SHARED_FUNCTIONS. |
| `unique-error-selectors` | pass | Error selectors are unique across modules. |
| `documented-event-name-collisions` | pass | Every duplicated event name is documented as topic0-distinguished. |
| `aggregate-is-pure-manifest` | pass | ICanonicalV2 declares no members and names every canonical module (documented extensions excepted). |
| `resolved-user-types` | pass | Every referenced struct and enum is declared by a canonical module. |
| `protocol-version-declaration` | pass | Version fixture declares protocolVersion 2.0. |
