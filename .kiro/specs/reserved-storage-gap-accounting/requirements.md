# Requirements Document

## Introduction

PREWAVE-SC-078 addresses a distinct security, correctness, and release-readiness boundary identified by the post-Wave-9 TruthBounty protocol audit: storage gap accounting across all upgradeable modules is not yet tracked as a first-class, testable invariant.

The TruthBounty protocol deploys a set of UUPS-upgradeable contracts. Each such contract reserves a `uint256[N] private __gap` array that downstream upgrades consume one slot at a time as new state variables are appended. This gap is the sole mechanism that prevents a new state variable from colliding with a slot already written by a deployed proxy. Three related hazards are not yet tested or enforced in CI:

1. **Gap decrement verification** — consuming a slot by adding a new variable must reduce the gap by exactly one and must not shift any already-written slot.
2. **Overrun detection** — adding more variables than the gap allows (or adding variables where no gap exists) must be detected and rejected before any on-chain operation.
3. **Inheritance order changes** — reordering base contracts in the C3 linearization causes every affected slot to shift, silently corrupting all existing storage; such changes must fail the review gate.
4. **Namespace relocation tracking** — moving an ERC-7201 namespace to a different abstract definer, or changing its `id`, orphans the already-written namespace root and must be caught.
5. **Slot packing and type-change detection** — changing a variable's type or packing can silently reinterpret existing storage; such changes must surface as layout drift.
6. **Manifest-vs-artifact alignment** — the committed `storage-layouts/manifest.json` and `storage-layouts/namespace-manifest.json` are the ground-truth for every upgrade review; they must remain byte-identical to the artifacts produced from the current source and toolchain at all times.

This feature introduces the gap-accounting layer that makes all six hazards machine-verifiable, closes the corresponding CI gate, and adds a deterministic Foundry test suite covering each hazard class. The V2 Optimism/EVM topology, exact arithmetic, timelock/role authority, scoped emergency controls, deterministic artifacts, and pinned consumer interfaces are all preserved without modification.

---

## Glossary

- **Gap_Array**: The `uint256[N] private __gap` declaration in an upgradeable contract that reserves `N` future storage slots. Its sole purpose is to allow safe append-only upgrades.
- **Gap_Slot_Count**: The current value of `N` in a given module's `Gap_Array`. Consuming a slot decrements `N` by one.
- **Consumed_Slot**: A previously reserved gap slot that has been replaced by a named state variable in an upgrade. The layout is safe when and only when the new variable occupies exactly the first available gap slot and every preceding variable remains at its original slot.
- **Storage_Manifest**: The committed JSON artifact at `storage-layouts/manifest.json`, generated deterministically by `scripts/validateStorageLayouts.ts` from the compiler `storageLayout` output at solc 0.8.28, optimizer runs 200, `via_ir = true`. It is the on-file freeze of every tracked upgradeable module's linear slot layout.
- **Namespace_Manifest**: The committed JSON artifact at `storage-layouts/namespace-manifest.json`, generated deterministically by `scripts/check-storage-namespaces.mjs`. It records ERC-7201 namespace ids, computed slots, definers, module composition, and inheritance linearization for every module in the V2-SC-121 frozen set.
- **Inheritance_Order**: The C3 linearization of an upgradeable module's base contracts as reported by solc and recorded in the Namespace_Manifest under `linearization`. Any change to this sequence is a storage-breaking mutation.
- **ERC_7201_Namespace**: A storage region whose root slot is derived as `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))`. Defined by exactly one abstract definer contract; every implementation version inherits that definer rather than redeclaring the namespace.
- **Namespace_Definer**: The single abstract contract that declares an ERC-7201 namespace struct and its `bytes32 internal constant` slot. Multiple versions of a module must share one definer, not redeclare the namespace in each version.
- **Append_Boundary**: The slot index immediately after the last frozen variable in a module's linear layout. New variables added after this boundary are safe appends; variables inserted before this boundary are layout-breaking mutations.
- **Slot_Packing**: The solc rule that multiple variables sharing one 32-byte slot when their combined `numberOfBytes` ≤ 32. Changing a variable's type or adding a variable into a packed slot can silently reinterpret existing data for all previously-packed neighbours.
- **Approved_Drift**: A layout change that has been reviewed and explicitly recorded in `storage-layouts/APPROVED_DRIFT.md` with the new canonical hash and PR link. Only approved drift passes the CI gate without failing the `slot-drift` rule.
- **Gap_Inventory**: A machine-readable record (produced by a new script or extended manifest section) that records, per tracked module: the module name, gap array slot index, declared gap size, consumed slot count, and the expected gap size after any pending upgrade.
- **Layout_Gate**: The combined CI enforcement layer consisting of `npm run test:layouts` (V2-SC-046), `scripts/check-storage-namespaces.mjs` (V2-SC-159), and the new gap-accounting tests introduced by this feature. A failing Layout_Gate blocks merge and deployment.
- **Overrun**: The condition where the number of new state variables appended to a module during an upgrade exceeds the remaining Gap_Slot_Count. An overrun silently corrupts every slot at and above the overrun point.
- **Canonical_Module_Set**: The 14 upgradeable modules frozen by V2-SC-121 and tracked in both manifests. This set is the scope of PREWAVE-SC-078.
- **Storage_Compatibility_Attestation**: The on-chain proof carried by `ProtocolUpgradeManager` (a `migrationHash` validated by a `VALIDATOR`) that a storage-incompatible upgrade has been reviewed. PREWAVE-SC-078 adds a pre-attestation requirement: the gap inventory must be regenerated and reviewed before `approveUpgrade` can proceed.

---

## Requirements

### Requirement 1: Gap Inventory and Slot Consumption Tracking

**User Story:** As a protocol maintainer, I want a deterministic, per-module gap inventory that records the current gap size and consumed slot count for every upgradeable module, so that I can verify at a glance whether a proposed upgrade will exhaust the reserved gap before it is merged.

#### Acceptance Criteria

1. THE `Gap_Inventory` SHALL record, for every module in the `Canonical_Module_Set`, the module name, the storage slot index of the `Gap_Array`, the declared `Gap_Slot_Count`, and the number of slots consumed relative to the V2-SC-121 freeze.
2. WHEN a state variable is added to a module that consumes one gap slot, THE `Gap_Inventory` SHALL reflect a `Gap_Slot_Count` decremented by exactly one and the `Consumed_Slot` count incremented by exactly one.
3. THE `Gap_Inventory` SHALL be derived deterministically from the compiler `storageLayout` output under solc 0.8.28, optimizer runs 200, `via_ir = true`, and SHALL produce byte-identical output for the same source tree regardless of the order in which modules are processed.
4. WHEN the `Gap_Inventory` is regenerated from the current source tree, THE resulting per-module gap counts SHALL match the counts recorded in the committed `Storage_Manifest` for every module in the `Canonical_Module_Set`.
5. IF the `Gap_Slot_Count` of any module reaches zero and an upgrade to that module is proposed, THEN THE `Layout_Gate` SHALL fail with an explicit gap-exhaustion diagnostic identifying the module and slot index.

---

### Requirement 2: Overrun Detection and Enforcement

**User Story:** As a security reviewer, I want the CI gate to detect and reject any proposed upgrade that would append more state variables than the remaining gap allows, so that slot overlaps are caught before any proxy upgrade transaction is authorized.

#### Acceptance Criteria

1. WHEN a module in the `Canonical_Module_Set` is modified to declare more new state variables than its current `Gap_Slot_Count` permits, THE `Layout_Gate` SHALL fail with an `overrun` diagnostic that names the module, the append count, and the remaining gap.
2. THE overrun check SHALL be enforced in the `npm run test:layouts` job before any layout-change approval workflow is offered, so that an overrun cannot be silently accepted as `Approved_Drift`.
3. WHEN a module has a `Gap_Slot_Count` of zero and a new variable is appended after the last frozen slot without a reviewed migration commitment, THE `Layout_Gate` SHALL treat this as an `overrun` and fail.
4. THE `Layout_Gate` SHALL confirm overrun-free status for all 14 modules in the `Canonical_Module_Set` on every PR and push to `main` or `develop`.
5. IF a layout-breaking upgrade requires a `ProtocolUpgradeManager.migrationHash` commitment, THEN THE `Layout_Gate` SHALL block the `approveUpgrade` timelock window from opening unless the `Gap_Inventory` for that module has been both regenerated from the current source tree AND explicitly approved in `storage-layouts/APPROVED_DRIFT.md`; the presence of an approval record alone without a matching regenerated inventory SHALL be treated as a gap-inventory-drift violation and SHALL block the timelock.

---

### Requirement 3: Inheritance Order Change Detection

**User Story:** As a contract auditor, I want any change to the C3 linearization of a tracked module's base contracts to fail the CI gate immediately, so that the silent slot-shift corruption that inheritance reordering causes is caught before a proxy upgrade is proposed.

#### Acceptance Criteria

1. WHEN the `Inheritance_Order` of any module in the `Canonical_Module_Set` changes between the committed `Namespace_Manifest` and the regenerated manifest, THE `Layout_Gate` SHALL report an `inheritance-reorder` violation for that module and fail.
2. THE `Layout_Gate` SHALL detect all forms of inheritance order change, including: reordering existing base contracts, inserting a new storage-bearing base contract between two existing bases, and removing a base contract from the linearization.
3. WHEN a new storage-bearing base contract is appended after all existing bases in the linearization, THE `Layout_Gate` SHALL report this as a new-contributor append and require explicit `Approved_Drift` before the manifests may be updated.
4. IF a module's `storageOrder` in the `Namespace_Manifest` disagrees with the compiler-derived C3 order and no `acknowledgedLayoutDiscrepancies` entry covers it, THEN THE `Layout_Gate` SHALL fail with a `layout-discrepancy` diagnostic.
5. THE Foundry test suite SHALL include a fuzz test that writes sentinel values to every linear slot of a representative upgradeable module, performs a simulated inheritance reorder, and asserts that at least one previously-written value is now read back from the wrong slot, demonstrating that the corruption is observable when the static check is bypassed.

---

### Requirement 4: Namespace Relocation Tracking

**User Story:** As a protocol developer, I want any attempt to move an ERC-7201 namespace to a different definer contract or rename its id to be caught by the CI gate, so that already-written namespaced storage is never orphaned by a source-level refactor.

#### Acceptance Criteria

1. WHEN an `ERC_7201_Namespace` id that exists in the committed `Namespace_Manifest` is absent from the regenerated manifest, THE `Layout_Gate` SHALL report a `namespace-removed` violation for that module and fail.
2. WHEN a namespace id exists in both the committed and regenerated manifests but the `Namespace_Definer` contract changes, THE `Layout_Gate` SHALL report a `namespace-moved` violation, because the storage-location constant must match the formula for the original id.
3. WHEN a namespace's `@custom:storage-location erc7201:<id>` annotation is present in source but the accompanying `bytes32 internal constant` does not equal `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))`, THE `Layout_Gate` SHALL report a `namespace-slot-mismatch` violation.
4. THE `Layout_Gate` SHALL verify that every ERC-7201 namespace slot is 256-bit aligned (`slot & 0xff == 0`) and does not equal any ERC-1967 reserved slot (`IMPLEMENTATION_SLOT`, `ADMIN_SLOT`, `BEACON_SLOT`).
5. WHEN a new namespace is added to a module by appending a new abstract definer to its inheritance chain, THE `Layout_Gate` SHALL accept this as a safe append and record the new namespace in the `Namespace_Manifest` without reporting a violation.

---

### Requirement 5: Slot Packing and Type-Change Detection

**User Story:** As a security analyst, I want the CI gate to detect variable type mutations and packing-order changes that could silently reinterpret stored data across an upgrade, so that EVM-level storage aliasing is prevented.

#### Acceptance Criteria

1. WHEN the `type` or `numberOfBytes` of any frozen variable in a tracked module changes between the committed `Storage_Manifest` and the regenerated manifest, THE `Layout_Gate` SHALL report a `slot-drift` violation for that variable and fail.
2. WHEN a new variable is inserted into an occupied packed slot — that is, it shares a `slot` index with an existing frozen variable — THE `Layout_Gate` SHALL report a `slot-drift` violation, because inserting into a packed slot reinterprets the existing neighbour's offset.
3. WHEN a variable's byte `offset` within its slot changes between the committed manifest and the regenerated manifest, THE `Layout_Gate` SHALL treat this as a `slot-drift` violation regardless of whether the slot index itself changed.
4. THE `Layout_Gate` SHALL detect the case where a `uint256` gap slot is replaced by two `uint128` variables that together occupy the same 32 bytes; this is a safe consumption only when no existing frozen variable shares that slot and the gap count decrements by exactly one.
5. WHEN a frozen mapping or dynamic array variable changes its base type between upgrades such that the slot derivation formula (`keccak256(key . slot)`) still maps to the same slot index, THE `Layout_Gate` SHALL still report the type mutation as `slot-drift`, because the on-chain ABI interpretation changes.

---

### Requirement 6: Manifest-vs-Artifact Alignment Gate

**User Story:** As a release engineer, I want the CI gate to fail whenever the committed storage manifests are not byte-identical to the manifests regenerated from the current source and toolchain, so that stale or manually edited manifests never reach a deployment review.

#### Acceptance Criteria

1. WHEN `npm run test:layouts` is executed in CI and the regenerated `Storage_Manifest` is not byte-identical to `storage-layouts/manifest.json`, THE `Layout_Gate` SHALL report a `manifest-drift` violation and fail.
2. WHEN `node scripts/check-storage-namespaces.mjs` is executed in CI and the regenerated `Namespace_Manifest` is not byte-identical to `storage-layouts/namespace-manifest.json`, THE `Layout_Gate` SHALL report a `manifest-drift` violation and fail.
3. THE `Storage_Manifest` and `Namespace_Manifest` SHALL be generated exclusively from the compiler `storageLayout` output and the checked-in source, respectively, with no manual edits. Any manual edit SHALL be detected as `manifest-drift` by the next CI run.
4. WHEN the `Gap_Inventory` introduced by this feature is regenerated and does not match the committed inventory file, THE `Layout_Gate` SHALL report a `gap-inventory-drift` violation and fail.
5. THE combined manifest alignment gate SHALL run in the `storage-layouts` CI job immediately after the standard compile step and before any deployment script or release-package workflow executes, so that a drifted manifest blocks every downstream gate.

---

### Requirement 7: Deterministic Foundry Test Suite for Hazard Coverage

**User Story:** As a maintainer reviewing a gap-accounting PR, I want a Foundry test suite that provides machine-verifiable evidence for each hazard class, so that the absence of the six gap-accounting bugs can be confirmed by running `forge test` on a clean tree.

#### Acceptance Criteria

1. THE Foundry test suite SHALL include a test that deploys a UUPS proxy with a representative upgradeable module, writes sentinel values into the gap-adjacent slots, upgrades to a V2 implementation that consumes exactly one gap slot, and asserts that the gap count decremented by one and all sentinel values in previously-frozen slots read back unchanged.
2. THE Foundry test suite SHALL include a test that attempts to upgrade a module whose `Gap_Slot_Count` is zero by adding a new variable, and asserts that the Layout_Gate rejects this before any proxy upgrade is authorized. WHERE the Foundry environment cannot invoke the off-chain gate directly, THE test SHALL assert that the post-upgrade slot at the overrun position contains the sentinel value written by the previous implementation, demonstrating that the position was already occupied before the overrun.
3. THE Foundry test suite SHALL include a fuzz test (per Requirement 3, AC 5) that writes sentinel values to the slots belonging to a representative upgradeable module, deploys a reordered implementation, and asserts that at least one sentinel value is misread, confirming that the inheritance-reorder corruption is observable.
4. THE Foundry test suite SHALL include a test that constructs a module whose ERC-7201 namespace constant does not match the formula slot for its annotated id, deploys it behind a proxy, and asserts that the namespace slot and the annotated constant address different storage regions, confirming that the `namespace-slot-mismatch` rule catches a real storage divergence.
5. THE Foundry test suite SHALL include a test that changes the type of a frozen variable from `uint256` to two packed `uint128` fields, writes a sentinel `uint256` value via the original implementation, upgrades, and asserts that reading back the two `uint128` fields produces the expected high/low decomposition, confirming that packing changes are observable and detectable.
6. THE Foundry test suite SHALL include a test that reads the committed `Storage_Manifest` via `vm.readFile`, regenerates the layout in-memory from the compiled artifacts, and asserts byte-identity, providing CI-level evidence that the manifest has not drifted from the current build.
7. FOR ALL six hazard tests, THE test suite SHALL compile without errors under `forge build` with the project's existing `foundry.toml` settings (solc 0.8.28, optimizer runs 200, `via_ir = true`) and SHALL pass with zero failures under `forge test --match-path "test/upgrade/StorageGapAccounting*"`.

---

### Requirement 8: CI Integration and Release Gate Compliance

**User Story:** As a maintainer approving a release candidate, I want the gap-accounting checks to be wired into the existing CI and release-readiness workflows so that no upgrade proposal can advance past the review gate while any gap-accounting violation is unresolved.

#### Acceptance Criteria

1. THE `npm run test:layouts` command SHALL incorporate the `Gap_Inventory` regeneration and comparison as a mandatory step, so that `gap-inventory-drift` is caught in the same CI job that already catches `slot-drift` and `manifest-drift`.
2. THE `scripts/auditReleaseReadiness.ts` script SHALL fail when any gap-accounting violation is present, ensuring that `test/ReleaseReadiness.test.ts` does not pass for a release candidate with unresolved gap overruns, inheritance reorders, namespace moves, or manifest drift.
3. THE `.github/workflows/storage-layout-check.yml` workflow SHALL be extended to run the gap-inventory check alongside the existing `validateStorageLayouts.ts` step, without weakening or making advisory any existing gate.
4. WHEN a PR modifies any of `storage-layouts/manifest.json`, `storage-layouts/namespace-manifest.json`, or the new gap-inventory artifact, THE CI workflow SHALL emit a reviewer-attention label consistent with the existing label emitted for `config/storage-layouts.json` changes.
5. THE implementation SHALL not introduce new compiler warnings, SHALL not increase any function's gas cost by more than 5 % relative to the pre-feature baseline (verified by the gas-check CI workflow), and SHALL compile to deterministic artifacts under the pinned solc 0.8.28 toolchain.
6. THE implementation SHALL not weaken any existing security gate, SHALL not make any failing check advisory, SHALL not skip any missing artifact, and SHALL not accept a new baseline without the explicit review workflow described in `docs/storage-layout-manifests.md`.

