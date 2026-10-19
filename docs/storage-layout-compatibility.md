# Automated Upgradeable Storage Layout Compatibility (V2-SC-046)

## Overview

Every upgradeable TruthBounty module is validated against a committed storage-layout
baseline on every pull request and push. The gate blocks unsafe storage layout
changes — slot deletion, variable reordering, type mutation, inheritance
reordering, or unsafe gap consumption — before they can be merged or deployed.

The check uses the same compatibility engine that backs the OpenZeppelin upgrades
plugins (`@openzeppelin/upgrades-core`), so its verdicts match
`@openzeppelin/hardhat-upgrades` behaviour used by `test/upgrade.test.ts`.

## Components

| Component | Path | Purpose |
|-----------|------|---------|
| Validator CLI | `scripts/validateStorageLayouts.ts` | Extracts layouts from build-info and compares them against the baseline manifest. |
| Baseline manifest | `config/storage-layouts.json` | Committed storage layouts of all tracked upgradeable contracts. |
| Test suite | `test/StorageLayoutCompatibility.test.ts` | Proves the gate passes on a clean tree and fails on slot deletion, type mutation, reordering, and gap consumption. |
| CI workflow | `.github/workflows/storage-layout-check.yml` | Runs compile + validation + tests on every PR and push to `main`/`develop`. |

## Tracked contracts

A contract is tracked when it is deployed behind (or is a base class of) a proxy:
it declares a `__gap`, inherits a gap-declaring base (e.g. `GovernanceOwnable`),
or inherits `UUPSUpgradeable`. The tracked list lives in
`TRACKED_CONTRACTS` inside `scripts/validateStorageLayouts.ts`.

The check is **fail-closed**: any concrete contract under `contracts/` that
declares a `uint256[N] private __gap` but is absent from `TRACKED_CONTRACTS`
makes validation fail, so new upgradeable modules cannot silently bypass the gate.

## Usage

```bash
# Compile (the validator reads build-info, including the storageLayout output)
npx hardhat compile --force

# Validate the working tree against the committed baseline (fails on unsafe change)
npx tsx scripts/validateStorageLayouts.ts

# After an INTENTIONAL layout change: regenerate the baseline
npx tsx scripts/validateStorageLayouts.ts --update
```

## Changing a layout safely

1. Make the contract change and compile: `npx hardhat compile --force`.
2. Run the validator to see the exact incompatibility report.
3. If the change is intentional:
   - Same-major (minor/patch): the layout must stay append-only — new state goes
     after existing state or consumes `__gap` slots the comparator approves
     (gap consumption is only safe when it ends on the same slot).
   - Layout-breaking (major): prepare a validated migration. Per
     [the upgrade framework](upgrade-framework.md), a storage-incompatible
     upgrade must carry a `migrationHash` validated by a `VALIDATOR` before
     `approveUpgrade` can start the timelock.
4. Regenerate the baseline with `--update` and commit the manifest diff.
5. The PR must justify every manifest change; CI labels any PR that touches
   `config/storage-layouts.json` for reviewer attention.

## Manifest format

```jsonc
{
  "schemaVersion": 1,
  "generator": "scripts/validateStorageLayouts.ts (V2-SC-046, @openzeppelin/upgrades-core)",
  "solcVersion": "0.8.28",
  "contracts": {
    "<ContractName>": {
      "file": "contracts/<path>.sol",
      "solcVersion": "0.8.28",
      "storage": [ { "label": "...", "slot": "0", "offset": 0, "type": "t_...", "contract": "..." } ],
      "types": { "t_...": { "label": "...", "numberOfBytes": "32", "members": [...] } }
    }
  }
}
```

Compiler-internal fields (`astId`, `src`) are stripped before the manifest is
written so diffs only contain semantic layout changes.

## Relationship to on-chain gating

Layout compatibility cannot be introspected on-chain. The layered defence is:

1. **This automated gate** (V2-SC-046) — deterministic, runs on every change,
   compares full layouts off-chain.
2. **`ProtocolUpgradeManager`** — a `VALIDATOR` attests storage compatibility
   per proposal; `approveUpgrade` rejects incompatible same-major upgrades and
   demands a validated migration for layout-breaking ones.
3. **`StorageCompatibilityValidator`** — on-chain slot-count check invoked by
   `UpgradeController` at execution time.

The baseline manifest is the evidence a `VALIDATOR` attests against: the CI run
on the upgrade PR proves the attested compatibility claim.
