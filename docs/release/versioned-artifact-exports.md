# Versioned ABI and Event Artifact Exports (`V2-SC-131`)

## Overview

`scripts/exportVersionedAbiArtifacts.ts` produces deterministic, versioned ABI,
selector, error, event, and address-manifest exports for API and frontend
consumers of the canonical V2 protocol, and fails closed when the committed
freeze drifts from the interface sources.

The freeze is derived directly from the canonical interface sources under
`contracts/v2/interfaces`, so it can be verified at any commit without a
compiler and without trusting a previously generated artifact set.

## Frozen artifacts

The committed export lives at:

```
exports/abi/v2/<releaseVersion>-<protocolMajor>.<protocolMinor>/manifest.json
```

and contains, for every canonical module interface:

| Field | Meaning |
|---|---|
| `interfaceId` | ERC-165 interface id — XOR of the selectors declared directly in that interface |
| `functions[]` | canonical signature plus 4-byte selector, sorted by signature |
| `errors[]` | canonical error signature plus 4-byte selector |
| `events[]` | canonical event signature plus `topic0` |
| `structs[]`, `enums[]` | value types declared by the interface |
| `digest` | keccak-256 of the module export, so a single changed member is visible |

plus:

- `canonicalAbi[]` — the deduplicated union of every module's function, error,
  and event fragments, including parameter names, indexed flags, output types,
  and state mutability. This is the ABI surface consumers consume directly.
- `addressManifest` — module identity (`moduleId = keccak256(name)`,
  `interfaceId`, concrete implementation contract where one exists in
  `contracts/v2`) and the deployment environments the addresses are injected
  from. **No concrete or placeholder addresses are committed**; addresses are
  supplied at deployment time from `deployments/config`.
- `checksum` — keccak-256 over the canonicalized export, the release pin.

## Deterministic derivation

The exporter does not require `solc`. It parses the canonical interfaces and
canonicalizes user-defined types exactly as the ABI encoder does:

- `enum` → `uint8`
- `struct` → `(componentTypes...)` tuple
- `uint`/`int` aliases → `uint256`/`int256`

Selectors and event topics are then derived with `keccak-256` over the
canonical signature, and the ERC-165 interface id is the XOR of the selectors
declared directly in the interface (inherited functions excluded, per EIP-165).

## Versioning policy

- The export path is versioned by protocol release and protocol version, so a
  breaking interface change lands in a new directory instead of mutating the
  published one.
- `releaseVersion` and `protocolVersion` are pinned in the exporter and repeated
  in the manifest; a mismatch is a drift failure.
- Any change to a signature, selector, topic0, parameter name, indexed flag,
  state mutability, struct, or enum changes the module `digest` and the export
  `checksum`.

## Drift gate

```bash
# fail closed if the sources no longer match the committed freeze
npx ts-node scripts/exportVersionedAbiArtifacts.ts

# re-freeze after an intentional, reviewed interface change
npx ts-node scripts/exportVersionedAbiArtifacts.ts --write
```

`test/VersionedAbiArtifactExport.test.ts` runs the same check in the Hardhat
test suite and asserts
the frozen bundle is deterministic, that interface ids and selectors are
collision-free, that events respect the three-indexed-parameter limit, and that
drift is actually detected.

## Consumer usage

```ts
import manifest from "../exports/abi/v2/2.0.0-2.0/manifest.json";

const claims = manifest.modules.find((m) => m.name === "IClaims");
// claims.interfaceId, claims.functions, claims.events are the published surface.
```

## Relationship to the event schema export

`schemas/event-schema-v1.json` (V2-SC-088) publishes the legacy V1 event
catalogue with families, topics, and a checksum. The event topic0s frozen here
are the canonical V2 surface; where an event appears in both, the topic0 values
must agree. `V2-SC-135` builds the cross-module compatibility matrix that
reconciles both published artifacts.

## Non-goals and residual risk

- No API, indexer, frontend, guardian, deployer, or test harness gains
  settlement or treasury authority; these are read-only exports.
- No Stellar, Soroban, Freighter, production secret, or placeholder address is
  added.
- The exporter is source-derived: it validates intended interface drift, and the
  compiled solc ABI remains the deployment source of truth. CI compiles before
  running the Hardhat suite, so a source-only change that fails compilation is
  still caught by the existing build.
