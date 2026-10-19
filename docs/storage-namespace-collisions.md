# Storage Namespace and Reserved-Slot Collisions (V2-SC-159)

Status: enforced in CI · Owner: contracts maintainers · Depends on V2-SC-039, V2-SC-046, V2-SC-121, V2-SC-122, V2-SC-124

## 1. Why linear diffs are not enough

The V2-SC-121 manifest (`storage-layouts/manifest.json`) and the V2-SC-046 baseline
(`config/storage-layouts.json`) freeze the **linear** layout of each upgradeable module, meaning
slots `0..n` in declaration order. Some storage never appears in that region:

| Storage class | Where it lives | Example in the canonical modules |
|---|---|---|
| Direct (linear) slots | `0..n` in C3-linearized declaration order | `GovernanceOwnable.governanceController` |
| Inherited layouts | the same region, ordered by the C3 linearization | `AccessControl._roles`, `Pausable._paused` |
| ERC-7201 namespaces | `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))` | `openzeppelin.storage.Initializable`, `openzeppelin.storage.ReentrancyGuard` |
| Unstructured slots | `bytes32(uint256(keccak256(id)) - 1)` or a literal used with `sload`/`sstore`/`.slot :=`/`StorageSlot` | none in the canonical modules today |
| Proxy reserved slots | ERC-1967 implementation, admin, beacon | written only by the proxy and `ERC1967Utils` |

Two contracts can define the same namespace id, a base can be reordered, or an implementation
can write an ERC-1967 slot, and the linear diff still reports "unchanged". This check covers
those cases.

## 2. Artifacts

| File | Role |
|---|---|
| `storage-layouts/namespace-manifest.json` | Committed, deterministic slot/namespace manifest for every module frozen by V2-SC-121 |
| `scripts/check-storage-namespaces.mjs` | Recomputes the manifest from source, with no compiler and no network, and runs all collision rules |
| `scripts/lib/keccak256.mjs` | Keccak-256 with no dependencies (Node's `crypto` only has NIST SHA3), cross-checked against published vectors, ethers and Solidity |
| `scripts/storage-namespace-policy.json` | ERC-1967 reserved slots, the OpenZeppelin bases resolved by declaration, and acknowledged V2-SC-121 discrepancies |
| `test/scripts/check-storage-namespaces.test.mjs` | `node:test` self-tests on synthetic fixtures, plus a check against the live repository |
| `test/fixtures/storage-namespaces/fixtures.mjs` | Synthetic module-composition and upgrade-transition fixtures |
| `test/upgrade/StorageNamespaceCollision.t.sol` | Foundry evidence: slot derivations, proxy slot protection, sentinel-state upgrade fuzzing |
| `contracts/mocks/NamespacedSentinelModule.sol` | UUPS V1 and V2 fixture with linear and ERC-7201 state, where V2 is a safe append |

### Manifest shape (schema version 1)

```jsonc
{
  "schemaVersion": 1,
  "derivations": { "erc7201": "...", "eip1967": "..." },
  "reservedSlots": [{ "name": "IMPLEMENTATION_SLOT", "id": "eip1967.proxy.implementation", "slot": "0x3608…" }, …],
  "namespaces":   [{ "id": "openzeppelin.storage.ReentrancyGuard", "slot": "0x9b77…", "definedBy": "ReentrancyGuard", "modules": [...] }],
  "modules": {
    "<Module>": {
      "sourcePath": "contracts/…",
      "linearization": ["<Module>", "...", "<most base>"],        // solc C3 order, most-derived first
      "storageOrder": [{ "contract": "AccessControl", "variables": ["_roles"] }, …], // slot order
      "namespaces": [{ "id", "slot", "definedBy" }],
      "unstructuredSlots": [{ "name", "slot", "derivation", "definedBy" }],
      "reservedSlots": ["IMPLEMENTATION_SLOT", "ADMIN_SLOT", "BEACON_SLOT"],
      "digest": "keccak256(\"TB-STORAGE-NAMESPACE-V1\" || canonicalJson(entry without digest))"
    }
  }
}
```

The manifest is deterministic. Modules are sorted by name, namespaces by id, and unstructured
slots by slot. It carries no timestamps, and serializing it twice gives the same bytes.

## 3. Rules (each one fails CI)

| Code | Rule |
|---|---|
| `duplicate-namespace` | An ERC-7201 id is defined by more than one contract, anywhere under `contracts/`, `contracts-vrm/`, the vendored upgradeable library, or the declared OpenZeppelin bases. Shared namespaces must come from one abstract definer that every version inherits (see `SentinelModuleNamespace`). |
| `namespace-slot-mismatch` | An `@custom:storage-location erc7201:<id>` annotation has no `bytes32 constant` equal to the formula slot for `<id>`. |
| `slot-overlap` | Two computed slots of one composed module are equal, or an unstructured slot falls inside a namespace's 256-slot aligned window. |
| `reserved-slot-reuse` | A namespace or unstructured slot equals an ERC-1967 implementation, admin or beacon slot; a reserved slot falls inside a namespace's window; or any 32-byte literal in a module's composed sources equals a reserved slot. |
| `inheritance-reorder` | The committed storage-contributor order is not a prefix of the regenerated one. This catches reordered bases, a storage base inserted between existing contributors, and a removed contributor. |
| `layout-reorder` | Variables inside a contributor were reordered, removed or renamed (`__gap` excluded). |
| `namespace-removed` / `namespace-moved` / `unstructured-slot-removed` / `unstructured-slot-moved` | Existing out-of-line state would be orphaned or relocated. |
| `module-removed` / `coverage` | The module set differs from the V2-SC-121 frozen manifest. |
| `layout-discrepancy` | The source-derived linear order disagrees with the compiler-derived V2-SC-121 layout and no acknowledged policy entry covers it. A stale acknowledgement also fails. |
| `external-drift` | When `node_modules/@openzeppelin/contracts` is installed, a policy declaration for an OpenZeppelin base disagrees with the real source. |
| `manifest-drift` | The committed manifest is not byte-identical to the regenerated one. |

Two kinds of change are safe appends and are reported as `+` lines when you regenerate: new
variables after the frozen ones (shrink `__gap` by the appended size, as in V2-SC-121 §5) and
new namespaces or storage contributors appended after the existing ones.

## 4. Workflow

```bash
node scripts/check-storage-namespaces.mjs            # verify (CI)
node scripts/check-storage-namespaces.mjs --report   # print the per-module inventory
node scripts/check-storage-namespaces.mjs --write    # regenerate after review
node --test test/scripts/check-storage-namespaces.test.mjs
forge test --match-path test/upgrade/StorageNamespaceCollision.t.sol
```

`--write` refuses while any collision rule fails, and it also refuses an unsafe transition. A
layout-breaking migration that a maintainer has reviewed needs
`--write --allow-unsafe-transition`, a manifest diff reviewed like a V2-SC-121 approved drift,
and the `ProtocolUpgradeManager.migrationHash` commitment.

### CI and release gates

- `.github/workflows/ci.yml`, lint job: the checker plus its self-tests run on every PR.
- `.github/workflows/ci.yml`, storage-layouts job: the checker runs next to `npm run test:layouts`.
- `.github/workflows/storage-layout-check.yml`: the checker and self-tests run after `validateStorageLayouts.ts`.
- `scripts/auditReleaseReadiness.ts`: the release-readiness audit, and so
  `test/ReleaseReadiness.test.ts`, fails when the checker fails. A release candidate with a
  namespace collision or a stale manifest cannot pass the release gate.

## 5. Findings recorded by this change

The static inventory agrees with the compiler-derived V2-SC-121 layout for 11 of the 14 frozen
modules. That includes the C3 order of `Pausable` versus `AccessControl` in `StakeVault` and
`DisputeResolution`. For three modules the frozen layout is **stale** relative to the source,
because branches were developed in parallel and merged after the freeze. These are listed under
`acknowledgedLayoutDiscrepancies` so they stay visible instead of passing silently:

| Module | Discrepancy | Impact |
|---|---|---|
| `FeeManager` | `_reservedFees` inserted between `_feesByType` and `_totalByAllocation`; `_isDistributing` added after `globalGovVersion` | later FeeManager slots shift relative to the frozen layout |
| `TruthBountyToken` | inherited `ResolverRoleTimelock` declares `pendingRoleChanges`, `_resolverRoleChangeId`, `_operationNonce` in addition to the frozen `resolverRoleChangeReadyAt` | every TruthBountyToken-owned slot shifts; this is an inherited-layout change |
| `TimelockOwnedProxyAdmin` | `_operationNonce` declared before `__gap` | `__gap` moves by one slot |

Before any proxy upgrade of these modules, the V2-SC-121 re-freeze (`npm run test:layouts:update`)
must be reviewed as a layout change. After the re-freeze, the corresponding entries must be
removed, and the checker enforces this through the stale-acknowledgement rule.

## 6. Acceptance criteria → evidence

| Acceptance criterion | Reproducible evidence |
|---|---|
| Every upgradeable canonical module has a deterministic slot/namespace manifest | `storage-layouts/namespace-manifest.json` (14 modules = the V2-SC-121 set). Self-tests `every module frozen by V2-SC-121 has a slot/namespace manifest entry`, `the committed manifest is byte-identical to the regenerated one`, `manifests are deterministic and independent of module input order`. Foundry `test_EveryModuleComposesDistinctNonReservedSlots` checks the module count against `storage-layouts/manifest.json`. |
| Unsafe overlap or namespace reuse fails before deployment | Self-tests `synthetic namespace collision`, `an annotation whose constant does not match the formula fails`, `identical unstructured slots in one composed module fail`, `an unstructured slot inside a namespace window fails`, `reserved-slot overwrite …`, `inherited-layout reorder fails`, `a storage base inserted between existing contributors fails`, `variables reordered inside a contributor fail`, `dropping a composed namespace fails`. The checker is gated in the CI lint job, the storage-layout workflows and `auditReleaseReadiness.ts`, so the failure happens before any deployment script runs. |
| Sentinel-state upgrade tests preserve all existing values | Foundry `testFuzz_UupsUpgradePreservesSentinels` (UUPS through `ERC1967Proxy`) and `testFuzz_TransparentUpgradePreservesSentinelsAndAdminSlot` (through `TransparentUpgradeableProxy` and `ProxyAdmin`). Both write fuzzed linear, mapping and ERC-7201 sentinels, upgrade to the safe-append V2, and read every value back unchanged, including the raw linear slots `0..3`. The counter-example `testFuzz_ReorderedLayoutCorruptsSentinels` shows that a reorder is observable. |
| Proxy implementation/admin slot protections | Foundry `test_ReservedSlotsMatchErc1967AndManifest` and `testFuzz_ImplementationWritesNeverTouchReservedSlots`, which records every storage write with `vm.accesses` using adversarial payloads. The fuzz upgrade tests assert that the implementation slot tracks the upgrade and that the admin and beacon slots are unchanged. `test_ReservedSlotOverwriteBricksProxy` shows the hazard the `reserved-slot-reuse` rule prevents. |
| ERC-7201 derivations match the manifest | Foundry `test_Erc7201NamespaceSlotsMatchManifest`, `test_SentinelFixtureNamespacesFollowFormula`, and `test_InitializableNamespaceIsTheLiveSlot`, which reads the initialized version from the manifest slot on a live proxy. Self-tests `derives the OpenZeppelin v5 ERC-7201 namespace roots` and `the vendored OpenZeppelin upgradeable constants match the formula`, plus an ethers cross-check when ethers is installed. |
| Integrates with storage-layout and release artifact gates | The module set and linear order are cross-checked against `storage-layouts/manifest.json` (V2-SC-121). The checker runs in `storage-layout-check.yml` (V2-SC-046) and the ci.yml storage-layouts job. `auditReleaseReadiness.ts` fails on any checker failure. |

## 7. Non-goals

This change makes no protocol redesign, adds no on-chain enforcement, and does not touch V1
layouts, dependency upgrades, or API, frontend or indexer surfaces. It does not re-freeze the
V2-SC-121 manifest. That remains a separate, maintainer-reviewed step (see §5).
