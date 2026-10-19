# Design Document — PREWAVE-SC-078: Reserved Storage Gap Accounting

## Overview

This design introduces a gap-accounting layer that makes the six storage-safety hazards identified in the post-Wave-9 audit machine-verifiable without touching any production contract state. The implementation adds one new script (`scripts/generateGapInventory.ts`), one new committed artifact (`storage-layouts/gap-inventory.json`), targeted extensions to three existing scripts (`validateStorageLayouts.ts`, `check-storage-namespaces.mjs`, `auditReleaseReadiness.ts`), an extension to the CI workflow (`.github/workflows/storage-layout-check.yml`), and a Foundry test suite (`test/upgrade/StorageGapAccounting.t.sol`) with six fixture contracts under `test/upgrade/fixtures/`. No production Solidity state variables are added or modified; no gas budgets are affected.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  CI: .github/workflows/storage-layout-check.yml                          │
│                                                                          │
│  1. Compile (hardhat compile --force)                                    │
│  2. validateStorageLayouts.ts  ──►  gap-overrun check  ─► [overrun]     │
│  3. generateGapInventory.ts    ──►  gap-inventory.json                   │
│       └─ compare vs committed  ──►  [gap-inventory-drift]                │
│  4. check-storage-namespaces.mjs                                         │
│       ├─ namespace-slot-mismatch / namespace-removed / namespace-moved   │
│       ├─ namespace-alignment-violation / namespace-reserved-slot-coll.   │
│       └─ inheritance-reorder / layout-discrepancy                        │
│  5. forge test --match-path "test/upgrade/StorageGapAccounting*"         │
│  6. StorageLayoutCompatibility.test.ts (existing)                        │
│  7. Flag label if manifest files changed                                 │
└──────────────────────────────────────────────────────────────────────────┘

             Off-chain scripts                    Foundry test suite
     ┌────────────────────────────┐        ┌──────────────────────────────┐
     │ generateGapInventory.ts    │        │ StorageGapAccounting.t.sol   │
     │  reads: out/<Module>.json  │        │  test_gapDecrementOnSlotCon… │
     │  produces: gap-inventory   │        │  test_overrunIsObservable     │
     │            .json           │        │  testFuzz_inheritanceReorder… │
     └────────────────────────────┘        │  test_namespaceMismatchIsObs… │
     ┌────────────────────────────┐        │  test_packingChangeIsObserv…  │
     │ validateStorageLayouts.ts  │        │  test_manifestAlignmentWith…  │
     │  (existing, extended)      │        └──────────────────────────────┘
     │  + gap-overrun check       │
     └────────────────────────────┘        ┌──────────────────────────────┐
     ┌────────────────────────────┐        │ test/upgrade/fixtures/        │
     │ check-storage-namespaces   │        │  GapV1.sol / GapV2.sol        │
     │  .mjs (existing, extended) │        │  GapV2Overrun.sol             │
     │  + inheritance-reorder     │        │  InheritReorderV1/V2.sol      │
     │  + namespace-moved check   │        │  NamespaceMismatch.sol        │
     └────────────────────────────┘        │  PackedV1.sol / PackedV2.sol  │
                                           └──────────────────────────────┘
```

---

## Data Models

### `storage-layouts/gap-inventory.json`

Generated deterministically by `scripts/generateGapInventory.ts`. Modules are sorted alphabetically by name before serialization to ensure byte-identity across independent runs.

```json
{
  "schemaVersion": 1,
  "issue": "PREWAVE-SC-078",
  "generator": "scripts/generateGapInventory.ts",
  "solc": "0.8.28+pinned",
  "generatedAt": "<ISO-8601>",
  "modules": [
    {
      "name": "ClaimLifecycle",
      "sourcePath": "contracts/ClaimLifecycle.sol",
      "gapSlotIndex": 3,
      "gapLabel": "__gap@3",
      "baselineGapSize": 50,
      "currentGapSize": 50,
      "consumedSlots": 0,
      "remainingGap": 50
    }
  ]
}
```

Field definitions:

| Field | Type | Description |
|---|---|---|
| `name` | string | Contract name as it appears in `TRACKED_CONTRACTS` |
| `sourcePath` | string | Repo-relative source path |
| `gapSlotIndex` | uint | Storage slot index where `__gap` begins |
| `gapLabel` | string | Key from `manifest.json` (e.g. `"__gap@3"`) |
| `baselineGapSize` | uint | Slot count at the V2-SC-121 freeze (read from committed manifest) |
| `currentGapSize` | uint | Slot count in current build (from `storageLayout` output) |
| `consumedSlots` | uint | `baselineGapSize - currentGapSize` |
| `remainingGap` | uint | Same as `currentGapSize` |

Manifests `manifest.json` and `namespace-manifest.json` are not modified — they remain owned by their existing generators.

---

## Component Designs

### 4.1 `scripts/generateGapInventory.ts` (new)

**Purpose:** Produce `storage-layouts/gap-inventory.json` deterministically from the Hardhat build artifacts.

**Algorithm:**

1. Load `storage-layouts/manifest.json` (the committed baseline) to read `baselineGapSize` per module. The key format is `"__gap@<slot>"`.
2. For each module in `TRACKED_CONTRACTS` (same list used by `validateStorageLayouts.ts`), read its current `storageLayout` from the most recent Hardhat build-info JSON.
3. Locate the `__gap` entry: any variable whose label matches `/__gap@\d+/` in the layout.
4. Extract `currentGapSize` from the type string (e.g. `"t_array(t_uint256)50_storage"` → `50`).
5. Compute `consumedSlots = baselineGapSize - currentGapSize`.
6. Sort modules alphabetically by name before building the output object.
7. Serialize with `JSON.stringify(manifest, null, 2) + "\n"` for byte-identical output.

**Error exits (non-zero):**

- Build-info directory not found → print `[gap-inventory] Build info missing; run \`npx hardhat compile --force\` first.`
- A module in `TRACKED_CONTRACTS` has no `__gap` variable → print `[gap-inventory] ModuleName: no __gap variable found in storageLayout.`
- `currentGapSize < 0` (impossible but guarded) → print `[gap-inventory] ModuleName: gap underflow detected.`

**CLI flags:**

```
npx tsx scripts/generateGapInventory.ts           # generate (write file)
npx tsx scripts/generateGapInventory.ts --check   # compare vs committed; exit 1 on drift
```

The `--check` mode reads the committed `storage-layouts/gap-inventory.json`, regenerates in memory, and diffs byte-for-byte. Any difference emits `[gap-inventory-drift] gap-inventory.json has drifted; regenerate and commit.` and exits non-zero.

---

### 4.2 Gap-overrun check in `validateStorageLayouts.ts` (extension)

This check is inserted after `loadCurrentLayouts()` succeeds and **before** the drift-approval workflow is offered.

```typescript
// After existing layout loading, before manifest comparison:
function checkGapOverruns(
  current: Record<string, StorageLayoutEntry>,
  baseline: LayoutManifest,
): string[] {
  const issues: string[] = [];
  for (const tracked of TRACKED_CONTRACTS) {
    const currentLayout = current[tracked.name];
    const baselineLayout = baseline.contracts[tracked.name];
    if (!currentLayout || !baselineLayout) continue;

    const currentGap = findGapEntry(currentLayout);
    const baselineGap = findGapEntry(baselineLayout);
    if (!baselineGap) continue; // module has no gap — caught elsewhere

    const currentGapSize = parseGapSize(currentGap?.type ?? "t_array(t_uint256)0_storage");
    const baselineGapSize = parseGapSize(baselineGap.type as string);
    const newVars = (currentLayout.storage.length - baselineLayout.storage.length);

    if (newVars > baselineGapSize) {
      issues.push(
        `[overrun] ${tracked.name}: appended ${newVars} slot(s) but only ${baselineGapSize} gap slot(s) remain.`,
      );
    }
    if (currentGapSize === 0 && newVars > 0) {
      issues.push(
        `[gap-exhaustion] ${tracked.name}: gap is fully consumed; no further slots may be appended ` +
          `without a reviewed migration commitment in storage-layouts/APPROVED_DRIFT.md.`,
      );
    }
  }
  return issues;
}
```

`parseGapSize` extracts `N` from `"t_array(t_uint256)N_storage"` using a regex.

The overrun issues are added to the main `issues` array before the manifest drift comparison, so they surface first and cannot be silenced by an `APPROVED_DRIFT.md` entry.

---

### 4.3 Inheritance-reorder and namespace-relocation checks in `check-storage-namespaces.mjs` (extension)

The existing script already detects `inheritance-reorder`, `namespace-slot-mismatch`, `namespace-removed`, `namespace-moved`, `namespace-alignment-violation`, and `namespace-reserved-slot-collision` at the source level. These checks are already present in the codebase. The extension verifies that:

1. The **committed** `namespace-manifest.json` `linearization` array is compared against the regenerated one per module — the script already does this under the `inheritance-reorder` check.
2. The `namespace-moved` check compares the `definedBy` field between committed and regenerated manifest entries.
3. The byte-identity comparison of regenerated vs committed manifest (the `manifest-drift` exit) is already implemented.

The extension adds explicit exit codes and emits each violation code as a machine-parseable prefix (`[code]`) on its own line for downstream tooling:

```javascript
// Extension to the existing problem-reporting section:
if (problems.length > 0) {
  for (const p of problems) {
    process.stderr.write(`[${p.code}] ${p.message}\n`);
  }
  process.exit(1);
}
```

The violation code `manifest-drift` is emitted when the committed manifest is not byte-identical to the regenerated one.

---

### 4.4 `scripts/auditReleaseReadiness.ts` (extension)

Add a new check block after the existing namespace check:

```typescript
// PREWAVE-SC-078: gap-inventory-drift must not be present at release time.
const gapInventoryCheck = spawnSync(
  process.execPath,
  ["--import", "tsx/esm", path.join(__dirname, "generateGapInventory.ts"), "--check"],
  { cwd: path.join(__dirname, ".."), encoding: "utf-8" }
);
if (gapInventoryCheck.status !== 0) {
  const detail = `${gapInventoryCheck.stdout ?? ""}${gapInventoryCheck.stderr ?? ""}`.trim();
  issues.push(
    `Gap inventory drift or overrun detected (PREWAVE-SC-078): ${detail || gapInventoryCheck.error?.message || "unknown error"}`,
  );
} else {
  console.log("✅ Storage gap inventory verified — no overruns, no drift (PREWAVE-SC-078).");
}
```

The `passed` computation already uses `issues.length === 0`, so any gap violation propagates to a non-zero exit from `auditReleaseReadiness.ts`.

---

### 4.5 `.github/workflows/storage-layout-check.yml` (extension)

Three new steps are inserted after the existing `Compile contracts` step and before `Flag baseline manifest changes`. All new steps use `continue-on-error: false`.

```yaml
      - name: Generate and verify storage gap inventory (PREWAVE-SC-078)
        run: npx tsx scripts/generateGapInventory.ts --check

      - name: Check gap overruns in storage layout validation
        run: npx tsx scripts/validateStorageLayouts.ts

      - name: Run storage gap accounting Foundry tests
        run: |
          forge test --match-path "test/upgrade/StorageGapAccounting*" \
            --ffi -vvv

      - name: Flag gap-inventory and manifest changes
        if: github.event_name == 'pull_request'
        run: |
          CHANGED=$(git diff --name-only origin/"${{ github.base_ref }}"...HEAD)
          for f in \
            storage-layouts/manifest.json \
            storage-layouts/namespace-manifest.json \
            storage-layouts/gap-inventory.json; do
            if echo "$CHANGED" | grep -q "^${f}$"; then
              echo "⚠️  ${f} changed in this PR — storage layout reviewer attention required."
              echo "Review the diff and ensure APPROVED_DRIFT.md is updated if applicable."
            fi
          done
```

The existing `Validate upgradeable storage layouts against baseline` and `Detect storage namespace and reserved-slot collisions` steps are preserved unchanged.

---

### 4.6 `test/upgrade/StorageGapAccounting.t.sol` (new)

Six test functions, one per hazard class. All run under `forge test --match-path "test/upgrade/StorageGapAccounting*"`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "./fixtures/GapV1.sol";
import "./fixtures/GapV2.sol";
import "./fixtures/GapV2Overrun.sol";
import "./fixtures/InheritanceReorderV1.sol";
import "./fixtures/InheritanceReorderV2.sol";
import "./fixtures/NamespaceMismatch.sol";
import "./fixtures/PackedV1.sol";
import "./fixtures/PackedV2.sol";

contract StorageGapAccountingTest is Test {
    using stdStorage for StdStorage;

    // ── Hazard 1: Gap decrement on slot consumption ──────────────────────
    function test_gapDecrementOnSlotConsumption() public { ... }

    // ── Hazard 2: Overrun is observable ──────────────────────────────────
    function test_overrunIsObservable() public { ... }

    // ── Hazard 3: Inheritance reorder corrupts storage (fuzz) ─────────────
    function testFuzz_inheritanceReorderCorruptsStorage(uint256 sentinel) public { ... }

    // ── Hazard 4: Namespace-slot mismatch is observable ───────────────────
    function test_namespaceMismatchIsObservable() public { ... }

    // ── Hazard 5: Packing change is observable ─────────────────────────────
    function test_packingChangeIsObservable() public { ... }

    // ── Hazard 6: Manifest alignment with build ─────────────────────────────
    function test_manifestAlignmentWithBuild() public { ... }
}
```

Full test logic is specified per function below.

#### `test_gapDecrementOnSlotConsumption`

1. Deploy `GapV1` behind an `ERC1967Proxy`.
2. Write a sentinel value (`0xDEADBEEF...`) to the slot immediately before the gap (`slot = gapSlotIndex - 1`) via `vm.store`.
3. Upgrade the proxy to `GapV2` (which adds one `uint256 newVar` consuming the first gap slot).
4. Assert: `GapV2(proxy).newVar() == 0` (new variable is zero-initialized).
5. Assert: `vm.load(proxy, bytes32(gapSlotIndex - 1)) == sentinelValue` (frozen slot unchanged).
6. Assert: `GapV2(proxy).gapSize() == GapV1(proxy).gapSize() - 1` (gap decremented by one).

#### `test_overrunIsObservable`

1. Deploy `GapV2Overrun` (a module with `uint256[0] __gap` and an extra variable at the overrun position).
2. Write a sentinel value to the overrun slot via `vm.store` before the upgrade.
3. Deploy `GapV2Overrun` as an upgrade implementation.
4. Call `upgradeToAndCall` on the proxy.
5. Assert that `vm.load(proxy, bytes32(overrunSlot)) == sentinelValue` — the slot was already occupied, demonstrating that the overrun would have clobbered existing data.

#### `testFuzz_inheritanceReorderCorruptsStorage(uint256 sentinel)`

1. Deploy `InheritanceReorderV1` (two storage-bearing bases `BaseA`, `BaseB` in that order) behind a proxy.
2. Write `sentinel` to the slot belonging to `BaseA.value` via `stdstore`.
3. Deploy `InheritanceReorderV2` (same bases but `BaseB`, `BaseA` order) as the new implementation.
4. Upgrade the proxy.
5. Assert that reading `InheritanceReorderV2(proxy).valueA()` returns a value ≠ `sentinel` (the storage corruption is observable). Use `vm.assume(sentinel != 0)` to avoid the trivial zero case.

#### `test_namespaceMismatchIsObservable`

1. Compute the correct ERC-7201 slot for the test id `"truthbounty.test.namespace"`:
   `correctSlot = keccak256(abi.encode(uint256(keccak256("truthbounty.test.namespace")) - 1)) & ~bytes32(uint256(0xff))`
2. Deploy `NamespaceMismatch` (a contract that declares a constant `STORAGE_LOCATION` equal to a different value, e.g. `keccak256("wrong.id")`).
3. Assert `NamespaceMismatch.STORAGE_LOCATION() != correctSlot` — the mismatch between the annotation and the constant is directly observable.

#### `test_packingChangeIsObservable`

1. Deploy `PackedV1` (declares `uint256 value`) behind a proxy.
2. Write sentinel `uint256 s = (uint256(0xAAAA) << 128) | uint256(0xBBBB)` via `vm.store` at the variable's slot.
3. Upgrade to `PackedV2` (same slot, but declares `uint128 hi; uint128 lo` packed together).
4. Assert: `PackedV2(proxy).lo() == 0xBBBB` and `PackedV2(proxy).hi() == 0xAAAA` — the high/low decomposition matches the expected packing.

#### `test_manifestAlignmentWithBuild`

1. Read `storage-layouts/manifest.json` via `vm.readFile("storage-layouts/manifest.json")`.
2. Parse the JSON using Foundry's `stdJson` to extract the `canonicalHash` for `ClaimLifecycle`.
3. Read the compiled artifact `out/ClaimLifecycle.sol/ClaimLifecycle.json` via `vm.readFile`.
4. Parse `storageLayout.storage` and recompute a hash of the slot keys in declaration order.
5. Assert the two hashes match — manifests that have drifted from the build produce a mismatch.

> Note: step 4 implements a lightweight hash rather than byte-identical JSON comparison because Foundry's `vm.readFile` gives the exact committed bytes. The canonical hash algorithm must match whatever `generateStorageLayouts.ts` uses (SHA-256 or keccak256 of the sorted slot-key string). The test documents this in a comment.

---

### 4.7 Fixture contracts (`test/upgrade/fixtures/`)

All fixtures compile under solc 0.8.28, optimizer runs 200, `via_ir = true`. They are minimal — no constructor logic beyond `_disableInitializers()` for UUPS-compatible fixtures.

#### `GapV1.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract GapV1 is Initializable, UUPSUpgradeable {
    uint256 public frozenVar;           // slot 0
    uint256[50] private __gap;          // slots 1–50

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(uint256 v) external initializer {
        __UUPSUpgradeable_init();
        frozenVar = v;
    }

    function gapSize() external pure returns (uint256) { return 50; }

    function _authorizeUpgrade(address) internal override {}
}
```

#### `GapV2.sol`

Identical to `GapV1` but adds `uint256 public newVar` at the position of the first gap slot and shrinks the gap to `uint256[49]`.

```solidity
uint256 public frozenVar;   // slot 0
uint256 public newVar;      // slot 1  (consumed first gap slot)
uint256[49] private __gap;  // slots 2–50

function gapSize() external pure returns (uint256) { return 49; }
```

#### `GapV2Overrun.sol`

A module that has exhausted its gap and adds a variable that collides with an already-used slot. The gap is declared as `uint256[0]` to signal exhaustion, and one extra `uint256 overrunVar` sits at the overrun position.

#### `InheritanceReorderV1.sol` / `InheritanceReorderV2.sol`

```solidity
// BaseA: declares uint256 public valueA (slot 0)
// BaseB: declares uint256 public valueB (slot 0 relative to BaseB)

// V1: contract InheritanceReorderV1 is BaseA, BaseB  → A at slot 0, B at slot 1
// V2: contract InheritanceReorderV2 is BaseB, BaseA  → B at slot 0, A at slot 1
```

The fuzz test writes `sentinel` to the `BaseA.valueA` slot in V1, upgrades to V2, then reads `valueA` — the C3 reorder shifts the slot and returns a different value.

#### `NamespaceMismatch.sol`

```solidity
contract NamespaceMismatch {
    // Annotation says "truthbounty.test.namespace" but the constant uses a different id.
    /// @custom:storage-location erc7201:truthbounty.test.namespace
    struct Layout { uint256 x; }

    // WRONG: uses a different id than the annotation
    bytes32 internal constant STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("truthbounty.test.namespace.wrong")) - 1))
        & ~bytes32(uint256(0xff));

    function getLayout() internal pure returns (Layout storage l) {
        assembly { l.slot := STORAGE_LOCATION }
    }
}
```

#### `PackedV1.sol` / `PackedV2.sol`

```solidity
// PackedV1: uint256 public value (slot 0)
// PackedV2: uint128 public hi; uint128 public lo (both at slot 0, packed)
```

---

## CI Workflow Extension — Full Step Sequence

After the change the `storage-layout` job runs in this order:

1. `actions/checkout` (existing)
2. `Setup Node.js` (existing)
3. `Install dependencies` (existing)
4. `Compile contracts` — `npx hardhat compile --force` (existing)
5. **`Generate and verify storage gap inventory`** — `npx tsx scripts/generateGapInventory.ts --check` (`continue-on-error: false`)
6. `Validate upgradeable storage layouts against baseline` — `npx tsx scripts/validateStorageLayouts.ts` (existing, now includes overrun check)
7. `Detect storage namespace and reserved-slot collisions` (existing)
8. **`Run storage gap accounting Foundry tests`** — `forge test --match-path "test/upgrade/StorageGapAccounting*" --ffi -vvv` (`continue-on-error: false`)
9. `Flag baseline manifest changes` — extended to cover `gap-inventory.json` (modified from existing)
10. `Run storage layout test suite` — existing Hardhat suite (existing)

---

## Invariants and Error Codes

| Code | Trigger | Exit | Message format |
|---|---|---|---|
| `overrun` | new variables > remaining gap | 1 | `[overrun] ModuleName: appended N slot(s) but only M gap slot(s) remain.` |
| `gap-exhaustion` | remainingGap == 0 and new vars added | 1 | `[gap-exhaustion] ModuleName: gap is fully consumed.` |
| `gap-inventory-drift` | committed inventory ≠ regenerated | 1 | `[gap-inventory-drift] gap-inventory.json has drifted; regenerate and commit.` |
| `slot-drift` | type/offset/numberOfBytes changed | 1 | `[slot-drift] ModuleName.varName: <field> changed from X to Y.` |
| `inheritance-reorder` | linearization order changed | 1 | `[inheritance-reorder] ModuleName: linearization changed.` |
| `layout-discrepancy` | storageOrder disagrees with C3, no ack | 1 | `[layout-discrepancy] ModuleName: storageOrder disagrees with compiler C3 order.` |
| `namespace-removed` | namespace id absent from regenerated manifest | 1 | `[namespace-removed] ModuleName: erc7201:<id> missing from regenerated manifest.` |
| `namespace-moved` | definer contract changed | 1 | `[namespace-moved] ModuleName: erc7201:<id> definer changed from A to B.` |
| `namespace-slot-mismatch` | constant ≠ formula slot for annotated id | 1 | `[namespace-slot-mismatch] Contract: erc7201:<id> constant <NAME> does not match formula slot.` |
| `namespace-alignment-violation` | slot & 0xff ≠ 0 | 1 | `[namespace-alignment-violation] ModuleName: erc7201:<id> slot <slot> is not 256-bit aligned.` |
| `namespace-reserved-slot-collision` | slot equals ERC-1967 reserved slot | 1 | `[namespace-reserved-slot-collision] ModuleName: erc7201:<id> collides with ERC-1967 <SLOT_NAME>.` |
| `manifest-drift` | committed manifest ≠ regenerated | 1 | `[manifest-drift] storage-layouts/manifest.json has drifted; regenerate and commit.` |
| `duplicate-namespace` | same namespace id declared in >1 contract | 1 | `[duplicate-namespace] erc7201:<id> defined by multiple contracts.` |

All codes are emitted as `[code] message` on stderr, followed by a non-zero exit.

---

## Constraints

- **Compiler:** solc 0.8.28, optimizer runs 200, `via_ir = true`. All new Solidity fixtures must declare `pragma solidity ^0.8.28` and compile under the existing `foundry.toml` settings without modification.
- **No production state changes.** No new state variables, no inheritance changes, and no storage layout modifications to any production contract.
- **No gas impact.** All new code is off-chain (TypeScript/JavaScript) or in test fixtures. Zero on-chain gas impact.
- **No gate weakening.** Every new step in the CI workflow uses `continue-on-error: false`. No existing step is made advisory or removed.
- **Deterministic artifacts.** `gap-inventory.json` is byte-identical for the same source tree regardless of processing order (enforced by alphabetical module sorting and fixed `JSON.stringify` indentation).
- **Byte-identical manifests.** `manifest.json` and `namespace-manifest.json` are not modified by this feature. They remain owned by their existing generators.
- **`APPROVED_DRIFT.md` gate.** An `APPROVED_DRIFT.md` entry alone is never sufficient to clear a gap overrun. Both regeneration and approval must be present (Requirement 2, AC 5).

---

## Components and Interfaces

### New components

| Component | Type | Location | Exports |
|---|---|---|---|
| `generateGapInventory.ts` | TypeScript script | `scripts/generateGapInventory.ts` | `generateGapInventory(opts)`, `parseGapSize(typeString)`, `findGapEntry(slots)` |
| `gap-inventory.json` | JSON artifact | `storage-layouts/gap-inventory.json` | Committed file; schema version 1 |
| `StorageGapAccountingTest` | Foundry test contract | `test/upgrade/StorageGapAccounting.t.sol` | Six test functions |
| `GapV1` / `GapV2` | Solidity fixture | `test/upgrade/fixtures/` | UUPS upgradeable modules |
| `GapV2Overrun` | Solidity fixture | `test/upgrade/fixtures/` | Demonstrates overrun hazard |
| `InheritanceReorderV1/V2` | Solidity fixture | `test/upgrade/fixtures/` | Demonstrates C3-reorder corruption |
| `NamespaceMismatch` | Solidity fixture | `test/upgrade/fixtures/` | Demonstrates namespace-slot-mismatch |
| `PackedV1` / `PackedV2` | Solidity fixture | `test/upgrade/fixtures/` | Demonstrates type/packing change |
| `BaseA` / `BaseB` | Solidity fixture | `test/upgrade/fixtures/` | Storage-bearing abstract bases |

### Modified components

| Component | Change | Interface impact |
|---|---|---|
| `scripts/validateStorageLayouts.ts` | Add `checkGapOverruns()`, `parseGapSize()`, `findGapEntry()` | None — internal additions only |
| `scripts/check-storage-namespaces.mjs` | Add `[code]` prefix to all problem outputs on stderr | Stdout/stderr format change; exit codes unchanged |
| `scripts/auditReleaseReadiness.ts` | Add `gapInventoryCheck` block after namespace check | `AuditResult.issues` may include new gap-accounting message |
| `.github/workflows/storage-layout-check.yml` | Two new steps; extended flag step | CI job adds two new required-pass steps |

### Interface contracts

**`generateGapInventory.ts` exported API:**

```typescript
interface GapInventoryEntry {
  name: string;
  sourcePath: string;
  gapSlotIndex: number;
  gapLabel: string;
  baselineGapSize: number;
  currentGapSize: number;
  consumedSlots: number;
  remainingGap: number;
}

interface GapInventoryManifest {
  schemaVersion: 1;
  issue: "PREWAVE-SC-078";
  generator: "scripts/generateGapInventory.ts";
  solc: string;
  generatedAt: string;        // ISO-8601
  modules: GapInventoryEntry[];
}

interface GapInventoryResult {
  passed: boolean;
  issues: string[];
  inventory: GapInventoryManifest;
}

export function parseGapSize(typeString: string): number;
export function generateGapInventory(opts?: { check?: boolean; manifestPath?: string; buildInfoDir?: string }): Promise<GapInventoryResult>;
```

**`checkGapOverruns` addition to `validateStorageLayouts.ts`:**

```typescript
export function checkGapOverruns(
  current: Record<string, StorageLayoutEntry>,
  baseline: LayoutManifest,
): string[];   // returns violation strings in "[overrun] ..." format
```

---

## Correctness Properties

Property 1: Determinism — `generateGapInventory.ts` produces byte-identical output for the same source tree on any two independent runs, regardless of module processing order (enforced by alphabetical sort before `JSON.stringify`).
**Validates: Requirements 1.3, 6.4**

Property 2: Monotonic gap consumption — `consumedSlots = baselineGapSize - currentGapSize` is always ≥ 0 on a valid source tree. If it is negative the script exits with a `[gap-inventory]` error (gap size grew, which is also a layout violation caught by `validateStorageLayouts.ts`).
**Validates: Requirements 1.2, 1.5**

Property 3: Overrun detection ordering — Gap-overrun issues are appended to `validateStorageLayouts.ts`'s `issues` array before the drift-approval branch, making it impossible for an `APPROVED_DRIFT.md` entry to clear an overrun.
**Validates: Requirements 2.2, 2.5**

Property 4: Namespace formula integrity — The ERC-7201 slot formula `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))` is computed in TypeScript by `check-storage-namespaces.mjs` and independently in Solidity by `test_namespaceMismatchIsObservable`, providing a cross-layer consistency check.
**Validates: Requirements 4.3, 7.4**

Property 5: Fixture correctness — The `test_packingChangeIsObservable` test verifies that Solidity's packing order (`lo` at offset 0, `hi` at offset 16) matches the test's expected decomposition `(sentinel >> 128) == hi`. If solc changes packing for any reason the test will fail rather than silently pass.
**Validates: Requirements 5.4, 7.5**

Property 6: Sentinel non-aliasing — All sentinel values in the Foundry tests use distinct non-zero constants (`0xDEADBEEF...`, `0xAAAA/0xBBBB`) chosen to differ from zero-initialization, and the fuzz test uses `vm.assume(sentinel != 0)` to exclude the trivial case.
**Validates: Requirements 7.1, 7.3**

---

## Error Handling

| Failure mode | Location | Behaviour | Recovery |
|---|---|---|---|
| Build-info directory missing | `generateGapInventory.ts` | Print `[gap-inventory] Build info missing; run \`npx hardhat compile --force\` first.` and exit 1 | Run `npx hardhat compile --force` |
| Module has no `__gap` variable | `generateGapInventory.ts` | Print `[gap-inventory] ModuleName: no __gap variable found in storageLayout.` and exit 1 | Add `__gap` or remove module from `TRACKED_CONTRACTS` |
| `gap-inventory.json` missing at check time | `generateGapInventory.ts --check` | Treat as drift: print `[gap-inventory-drift] gap-inventory.json not found; run without --check to generate it.` and exit 1 | Run `generateGapInventory.ts` and commit the file |
| Gap overrun detected | `validateStorageLayouts.ts` | Print `[overrun] ModuleName: appended N slot(s) but only M gap slot(s) remain.` and exit 1 | Reduce the number of new variables, or follow the migration process and update `APPROVED_DRIFT.md` + regenerate manifests |
| Gap exhaustion | `validateStorageLayouts.ts` | Print `[gap-exhaustion] ModuleName: ...` and exit 1 | Same as overrun |
| Namespace slot mismatch | `check-storage-namespaces.mjs` | Print `[namespace-slot-mismatch] ...` and exit 1 | Fix the constant to match the ERC-7201 formula for the annotated id |
| Inheritance reorder | `check-storage-namespaces.mjs` | Print `[inheritance-reorder] ModuleName: linearization changed.` and exit 1 | Restore original inheritance order or follow the layout-breaking migration process |
| Manifest drift | both scripts in `--check`/validate mode | Print `[manifest-drift] ...` and exit 1 | Regenerate the relevant manifest and commit |
| Foundry test failure | CI / `forge test` | Non-zero exit code; forge prints assertion failure details | Fix the root cause identified in the test output |

All error paths emit a machine-parseable `[code]` prefix so CI logs can be grep-filtered per violation type.

---

## Testing Strategy

### Unit tests (off-chain scripts)

- `test/scripts/generateGapInventory.test.mjs` — tests `parseGapSize`, alphabetical sort, `--check` pass/fail, unknown module error. Runs via `node --test`.
- `test/scripts/validateStorageLayouts.test.mjs` (existing) — extended implicitly: if overrun check introduces a regression, the existing tests will catch it because the function signature is unchanged.
- `test/scripts/check-storage-namespaces.test.mjs` (existing) — must continue to pass after the `[code]` prefix addition.

### Foundry tests (on-chain hazard demonstration)

Six tests in `test/upgrade/StorageGapAccounting.t.sol`:

| Test | Hazard class | Type |
|---|---|---|
| `test_gapDecrementOnSlotConsumption` | Gap decrement | Unit |
| `test_overrunIsObservable` | Overrun | Unit |
| `testFuzz_inheritanceReorderCorruptsStorage` | Inheritance reorder | Fuzz |
| `test_namespaceMismatchIsObservable` | Namespace mismatch | Unit |
| `test_packingChangeIsObservable` | Packing/type change | Unit |
| `test_manifestAlignmentWithBuild` | Manifest drift | Unit (file I/O) |

Run with `forge test --match-path "test/upgrade/StorageGapAccounting*" --ffi -vvv`. The `--ffi` flag is required only for `test_manifestAlignmentWithBuild` (uses `vm.readFile`).

### Integration gate

The full CI workflow (`storage-layout-check.yml`) is the integration test: it runs all components in dependency order on every PR to `main` or `develop`. A green workflow run is the end-to-end acceptance test for PREWAVE-SC-078.
