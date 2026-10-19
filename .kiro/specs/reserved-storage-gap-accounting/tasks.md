# Implementation Plan: PREWAVE-SC-078 — Reserved Storage Gap Accounting

## Overview

18 tasks across 4 dependency waves. Waves 1 and 2 produce fixture contracts and the core new script + Foundry test suite. Wave 3 extends the three existing scripts. Wave 4 wires everything into CI. All tasks within the same wave are independent and can be executed in parallel.

## Tasks

- [ ] 1. Create `test/upgrade/fixtures/BaseA.sol` — minimal abstract storage-bearing base contract with `uint256 public valueA` (no constructor logic). Required by: Task 6, Task 7, Task 13.
  - Declare `pragma solidity ^0.8.28`
  - Declare `abstract contract BaseA` with a single `uint256 public valueA` state variable
  - No constructor — fixtures are initializer-based

- [ ] 2. Create `test/upgrade/fixtures/BaseB.sol` — minimal abstract storage-bearing base contract with `uint256 public valueB`. Required by: Task 6, Task 7, Task 13.
  - Declare `pragma solidity ^0.8.28`
  - Declare `abstract contract BaseB` with a single `uint256 public valueB` state variable
  - No constructor

- [ ] 3. Create `test/upgrade/fixtures/GapV1.sol` — UUPS-upgradeable module with `uint256[50] __gap` at slot 1, used by the gap-decrement test.
  - Declare `uint256 public frozenVar` at slot 0 and `uint256[50] private __gap` at slot 1
  - Import and inherit `UUPSUpgradeable` and `Initializable` from OpenZeppelin upgradeable contracts
  - Add `/// @custom:oz-upgrades-unsafe-allow constructor` and `constructor() { _disableInitializers(); }`
  - Add `initialize(uint256 v)` with `initializer` modifier
  - Add `function gapSize() external pure returns (uint256) { return 50; }`
  - Implement empty `_authorizeUpgrade(address) internal override {}`

- [ ] 4. Create `test/upgrade/fixtures/GapV2.sol` — same as GapV1 but consumes one gap slot by adding `uint256 public newVar` at slot 1; gap becomes `uint256[49]` at slot 2.
  - Keep `uint256 public frozenVar` at slot 0 (unchanged)
  - Add `uint256 public newVar` at slot 1 (consumed first gap slot)
  - Shrink gap to `uint256[49] private __gap` at slot 2
  - Return `49` from `gapSize()`

- [ ] 5. Create `test/upgrade/fixtures/GapV2Overrun.sol` — module with `uint256[0] __gap` (exhausted) plus an extra variable at the overrun slot to demonstrate the collision hazard.
  - Declare `uint256 public frozenVar` at slot 0
  - Declare `uint256[0] private __gap` at slot 1 (exhausted gap)
  - Declare `uint256 public overrunVar` at slot 1 — collides with the gap slot
  - Expose `function overrunSlot() external pure returns (uint256) { return 1; }`

- [ ] 6. Create `test/upgrade/fixtures/InheritanceReorderV1.sol` — upgradeable contract with base order `BaseA, BaseB` (depends on Tasks 1, 2).
  - Import `BaseA` and `BaseB` from the same fixtures directory
  - Declare `contract InheritanceReorderV1 is Initializable, UUPSUpgradeable, BaseA, BaseB`
  - Add `initialize()` with `initializer` modifier and disabled constructor
  - Implement empty `_authorizeUpgrade`

- [ ] 7. Create `test/upgrade/fixtures/InheritanceReorderV2.sol` — same bases but swapped order `BaseB, BaseA` (depends on Tasks 1, 2).
  - Declare `contract InheritanceReorderV2 is Initializable, UUPSUpgradeable, BaseB, BaseA`
  - Add `function getValueA() external view returns (uint256) { return valueA; }` for the fuzz test
  - Add `initialize()`, disabled constructor, empty `_authorizeUpgrade`

- [ ] 8. Create `test/upgrade/fixtures/NamespaceMismatch.sol` — contract whose ERC-7201 constant does not match the formula for its annotated id.
  - Add `/// @custom:storage-location erc7201:truthbounty.test.namespace` annotation
  - Declare `struct Layout { uint256 x; }`
  - Declare `bytes32 public constant STORAGE_LOCATION` using id `"truthbounty.test.namespace.wrong"` (intentionally wrong)
  - The constant must be computable at compile time using the ERC-7201 formula applied to the wrong id

- [ ] 9. Create `test/upgrade/fixtures/PackedV1.sol` — UUPS module with `uint256 public value` at slot 0.
  - Declare `uint256 public value` at slot 0
  - Add UUPS boilerplate (disabled constructor, `initialize`, empty `_authorizeUpgrade`)

- [ ] 10. Create `test/upgrade/fixtures/PackedV2.sol` — same module but `uint256 value` replaced by packed `uint128 public lo; uint128 public hi` (both at slot 0).
  - Declare `uint128 public lo` then `uint128 public hi` so solc packs them into slot 0 (lo at offset 0, hi at offset 16)
  - Add comment documenting the packing order
  - Add UUPS boilerplate

- [ ] 11. Create `scripts/generateGapInventory.ts` — new script that reads Hardhat build artifacts and produces `storage-layouts/gap-inventory.json` with per-module gap sizes, consumed-slot counts, and remaining-gap counts.
  - Import `node:fs`, `node:path`, `pathToFileURL`; mirror the import style of `validateStorageLayouts.ts`
  - Define `GAP_INVENTORY_PATH = "storage-layouts/gap-inventory.json"` and reference `MANIFEST_PATH` from `validateStorageLayouts.ts` (or `storage-layouts/manifest.json`)
  - Implement `parseGapSize(typeString: string): number` — extracts `N` from `"t_array(t_uint256)N_storage"` via regex
  - Implement `findGapEntry(slots)` — finds the slot entry whose key matches `/__gap@\d+/`
  - Implement `generateGapInventory(opts?: { check?: boolean })`: load baseline manifest for `baselineGapSize`; load current build artifacts; per module compute `currentGapSize`, `consumedSlots`, `remainingGap`; sort modules alphabetically; serialize with `JSON.stringify(manifest, null, 2) + "\n"`
  - In `--check` mode: compare regenerated vs committed file byte-for-byte; emit `[gap-inventory-drift]` and exit 1 on mismatch
  - Emit `[gap-inventory]`-prefixed errors and exit non-zero on missing build-info or missing `__gap` variable
  - Export `generateGapInventory` for use by `auditReleaseReadiness.ts`
  - Add CLI entry point with `--check` flag support

- [ ] 12. Generate and commit `storage-layouts/gap-inventory.json` — run `generateGapInventory.ts` against the current source tree to produce the initial baseline inventory artifact (depends on Task 11).
  - Run `npx hardhat compile --force` to ensure fresh build-info
  - Run `npx tsx scripts/generateGapInventory.ts` to generate the file
  - Verify the output contains an entry for every module in `TRACKED_CONTRACTS` with non-negative `consumedSlots` and correct `remainingGap`
  - Verify `npx tsx scripts/generateGapInventory.ts --check` exits 0 immediately after generation
  - Commit the file as the new baseline

- [ ] 13. Create `test/upgrade/StorageGapAccounting.t.sol` — six-function Foundry test suite covering all hazard classes (depends on Tasks 3–10).
  - Add SPDX header, `pragma solidity ^0.8.28`, import `forge-std/Test.sol`, `forge-std/StdStorage.sol`, `ERC1967Proxy`, and all nine fixture contracts
  - Declare `contract StorageGapAccountingTest is Test` with `using stdStorage for StdStorage`
  - **test_gapDecrementOnSlotConsumption**: deploy GapV1 proxy → write sentinel to frozen-var slot → upgrade to GapV2 → assert `frozenVar` unchanged, `newVar == 0`, `gapSize() == 49`
  - **test_overrunIsObservable**: deploy GapV2Overrun → write sentinel to `overrunSlot()` → upgrade to second GapV2Overrun instance → assert sentinel still present at overrun slot (slot was already occupied)
  - **testFuzz_inheritanceReorderCorruptsStorage(uint256 sentinel)**: `vm.assume(sentinel != 0)` → deploy InheritanceReorderV1 proxy → write sentinel to slot 0 → upgrade to InheritanceReorderV2 → assert `getValueA() != sentinel`
  - **test_namespaceMismatchIsObservable**: compute correct ERC-7201 slot for `"truthbounty.test.namespace"` → deploy NamespaceMismatch → assert `STORAGE_LOCATION() != correctSlot`
  - **test_packingChangeIsObservable**: deploy PackedV1 proxy → write `(uint256(0xAAAA) << 128) | 0xBBBB` to slot 0 → upgrade to PackedV2 → assert `lo() == 0xBBBB` and `hi() == 0xAAAA`
  - **test_manifestAlignmentWithBuild**: `vm.readFile("storage-layouts/manifest.json")` → parse `canonicalHash` for `ClaimLifecycle` via `stdJson` → read `out/ClaimLifecycle.sol/ClaimLifecycle.json` → recompute hash of storage slot keys → assert hashes match
  - All six tests must pass under `forge test --match-path "test/upgrade/StorageGapAccounting*"` with solc 0.8.28, optimizer 200, `via_ir = true`

- [ ] 14. Extend `scripts/validateStorageLayouts.ts` — add gap-overrun check that runs before the drift-approval workflow (depends on Task 12).
  - Add `parseGapSize(typeString: string): number` helper using the same regex as Task 11
  - Add `findGapEntry(layout: StorageLayoutEntry)` helper
  - Add `checkGapOverruns(current, baseline): string[]` — for each tracked module, compare new variable count against baseline gap; emit `[overrun] ModuleName: appended N slot(s) but only M gap slot(s) remain.` when overrun; emit `[gap-exhaustion] ModuleName: ...` when gap reaches zero
  - Insert `checkGapOverruns` call in `validateStorageLayouts()` **before** the manifest drift comparison
  - Append returned issues to the main `issues` array; they cannot be cleared by `APPROVED_DRIFT.md` (they surface first)
  - Verify the existing `test/scripts/validateStorageLayouts.test.mjs` still passes

- [ ] 15. Extend `scripts/check-storage-namespaces.mjs` — ensure every violation code is emitted as `[code] message` on stderr and the script exits non-zero (depends on Task 12).
  - Audit the existing problem-reporting section; locate where problems are printed and where `process.exit(1)` is called
  - Update the final reporting block to emit each problem as `process.stderr.write(\`[${p.code}] ${p.message}\n\`)`
  - Confirm all 12 violation codes in the design invariant table are reachable: `inheritance-reorder`, `namespace-slot-mismatch`, `namespace-removed`, `namespace-moved`, `namespace-alignment-violation`, `namespace-reserved-slot-collision`, `duplicate-namespace`, `slot-overlap`, `reserved-slot-reuse`, `manifest-drift`, `layout-discrepancy`, `coverage`
  - Ensure `--write` mode exits 1 when problems exist and refuses to write
  - Run `node --test test/scripts/check-storage-namespaces.test.mjs` and confirm zero failures

- [ ] 16. Extend `scripts/auditReleaseReadiness.ts` — add gap-inventory verification as a mandatory release check (depends on Tasks 11, 12).
  - After the existing `namespaceCheck` block, add a new block that runs `generateGapInventory.ts --check` via `spawnSync`
  - On non-zero exit, push `"Gap inventory drift or overrun detected (PREWAVE-SC-078): <detail>"` to `issues`
  - On success, log `"✅ Storage gap inventory verified — no overruns, no drift (PREWAVE-SC-078)."`
  - Verify `test/ReleaseReadiness.test.ts` still passes (gap-inventory.json must already be committed)

- [ ] 17. Create `test/scripts/generateGapInventory.test.mjs` — unit tests for the gap inventory script mirroring the pattern of existing `test/scripts/*.test.mjs` files (depends on Tasks 11, 12).
  - Import `node:test` and `node:assert`
  - Test that `--check` mode exits 0 on a clean tree (gap-inventory.json matches build)
  - Test `parseGapSize("t_array(t_uint256)50_storage") === 50`
  - Test `parseGapSize("t_array(t_uint256)0_storage") === 0`
  - Test that output modules are sorted alphabetically (use a synthetic two-module scenario if direct invocation is impractical; otherwise assert via the committed file)
  - Test that a module name not in `TRACKED_CONTRACTS` does not silently produce an incomplete inventory (verify error/exit behavior)

- [ ] 18. Extend `.github/workflows/storage-layout-check.yml` — add the gap-inventory and Foundry test CI steps and extend the manifest-flag step (depends on Tasks 11–17).
  - After the `Compile contracts` step, insert: `name: Generate and verify storage gap inventory (PREWAVE-SC-078)`, `run: npx tsx scripts/generateGapInventory.ts --check` (no `continue-on-error`)
  - After `Detect storage namespace and reserved-slot collisions`, insert: `name: Run storage gap accounting Foundry tests (PREWAVE-SC-078)`, `run: forge test --match-path "test/upgrade/StorageGapAccounting*" --ffi -vvv` (no `continue-on-error`)
  - Extend the existing `Flag baseline manifest changes` step to also check `storage-layouts/gap-inventory.json` and emit `⚠️  storage-layouts/gap-inventory.json changed in this PR — storage layout reviewer attention required.`
  - Confirm no existing step is removed or changed to `continue-on-error: true`

## Task Dependency Graph

```json
{
  "waves": [
    {
      "wave": 1,
      "tasks": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
      "description": "Fixture contracts and new gap-inventory script — no dependencies"
    },
    {
      "wave": 2,
      "tasks": [12, 13],
      "description": "Generate initial gap-inventory.json (needs Task 11) and Foundry test suite (needs Tasks 3-10)",
      "dependsOn": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    },
    {
      "wave": 3,
      "tasks": [14, 15, 16, 17],
      "description": "Script extensions — all need committed gap-inventory.json from Task 12",
      "dependsOn": [11, 12]
    },
    {
      "wave": 4,
      "tasks": [18],
      "description": "CI workflow extension — needs all scripts and tests complete",
      "dependsOn": [11, 12, 13, 14, 15, 16, 17]
    }
  ]
}
```

## Notes

- Fixture contracts must compile under the existing `foundry.toml` (`solc 0.8.28`, optimizer 200, `via_ir = true`) without modifying that file.
- `storage-layouts/gap-inventory.json` must be committed before the CI workflow step (Task 18) can pass in `--check` mode.
- The overrun check in `validateStorageLayouts.ts` (Task 14) must run before the drift-approval workflow so overruns cannot be silenced by an `APPROVED_DRIFT.md` entry.
- The `test_manifestAlignmentWithBuild` test (Task 13) requires `vm.readFile` access and therefore needs `--ffi` in the forge test invocation. The CI step in Task 18 already includes `--ffi`.
- No production Solidity state variables are added or modified by any task. No gas budgets are affected.
