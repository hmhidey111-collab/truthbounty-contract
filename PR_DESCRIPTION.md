# V2-SC-046 — Automate Upgradeable Storage Layout Compatibility

Closes #428

## Objective

Automate upgradeable storage layout compatibility as a focused, independently
reviewable V2 contract work item: compare storage layouts on every upgradeable
contract change and block slot deletion, type mutation, inheritance reordering,
or unsafe gap consumption.

## What this PR does

### 1. Real storage-layout comparator (replaces stub)

`scripts/validateStorageLayouts.ts` previously "validated" four hardcoded
slot counts (50/20/15/30) — it was a placeholder that could never detect an
actual layout regression. It now:

- Extracts each tracked contract's storage layout from Hardhat build-info
  (`storageLayout` compiler output).
- Compares it against a committed baseline manifest using
  `@openzeppelin/upgrades-core` — the same engine behind the OZ upgrades
  plugins — so verdicts match `@openzeppelin/hardhat-upgrades` behaviour.
- Blocks slot deletion, variable reordering, type mutation, inheritance-order
  layout changes, and unsafe gap consumption; allows append-only growth.
- Is **fail-closed for new modules**: any concrete contract under `contracts/`
  declaring `uint256[N] private __gap` that is absent from `TRACKED_CONTRACTS`
  fails validation, so new upgradeable contracts cannot silently bypass the gate.
- Detects manifest drift (missing/stale entries) and fails on it.
- Supports `--update` to regenerate the baseline after an *intentional*,
  reviewed layout change.

### 2. Committed baseline manifest

`config/storage-layouts.json` records the current layouts of all **23 tracked
upgradeable contracts** (proxy targets, gap declarers, and bases that declare
gaps, e.g. everything inheriting `GovernanceOwnable`). Compiler-internal
`astId`/`src` fields are stripped so diffs only show semantic layout changes.

### 3. Regression test suite

`test/StorageLayoutCompatibility.test.ts` (12 tests) proves:

- the gate passes on a clean tree (all 23 layouts compatible, end-to-end);
- **type mutation** of an existing slot is rejected;
- **slot deletion** is rejected;
- **variable reordering** (slot swap) is rejected;
- **storage gap consumption** is rejected;
- append-only growth within the same major version is allowed;
- enum members are stabilized as strings (guards a serializer edge case);
- manifest integrity (no stale entries, file drift, untracked gap contracts).

### 4. CI gate

`.github/workflows/storage-layout-check.yml` runs on every PR/push to
`main`/`develop`: compile → validate against baseline → run the test suite, and
labels any PR that touches `config/storage-layouts.json` for reviewer attention.

### 5. Toolchain repair (prerequisite)

The repo was in a state where `hardhat compile` **exited 1 with no error** and
`hardhat test` could not run at all:

- The pinned `@nomicfoundation/hardhat-toolbox@7.0.0` is a placeholder package
  that prints a warning and calls `process.exit(1)` — it works with neither
  Hardhat 2 nor 3. Replaced with `hardhat-toolbox-mocha-ethers` (this project
  is a mocha/ethers project), matching the installed Hardhat 3.16.
- `hardhat-gas-reporter` has peer `hardhat@^2.16.0` and crashes on import under
  Hardhat 3; removed.
- Migrated `hardhat.config.ts` / `hardhat.vrm.config.ts` to Hardhat 3's
  declarative format: explicit `plugins` array, `type` discriminators on all
  networks, `verify.etherscan` (replaces removed top-level `etherscan`).
- Added `"type": "module"` + ESM `tsconfig` (Hardhat 3 is ESM-first) and fixed
  `typechain-types` output path references.
- De-CJS'd the scripts loaded by tests (`require.main` → `import.meta` URL
  check; `__dirname` → `fileURLToPath`), unblocking
  `ReleaseReadiness` and `EventSchemaConsistency` tests.
- Enabled `storageLayout` compiler output (required by the validator; the OZ
  upgrades plugin requests it too).

### 6. Documentation

`docs/storage-layout-compatibility.md` documents the framework, tracked-contract
policy, safe-change workflow (`--update` + PR justification), manifest format,
and how this gate maps to the on-chain `ProtocolUpgradeManager` policy.
`README.md` links it and bumps Node to v22+ (Hardhat 3 requirement).

## Evidence mapped to acceptance criteria

- [x] **Scoped behaviour, no unrelated refactoring** — contract sources under
      `contracts/` are untouched (0 Solidity changes); only tooling, the
      validator, the manifest, tests, CI, and docs changed.
- [x] **New public surface has NatSpec/events/errors** — n/a (TypeScript tool;
      fully JSDoc'd public functions and types).
- [x] **Tests demonstrate the security property and fail against prior unsafe
      behaviour** — `test/StorageLayoutCompatibility.test.ts` detector tests
      fail against the previous stub (the stub could not detect any of the four
      unsafe-mutation classes; it hard-coded equal slot counts and always
      passed).
- [x] **Build / unit / static-analysis checks pass** —
      - `npx hardhat compile --force`: ✅ 190 files, solc 0.8.28
      - `npx tsx scripts/validateStorageLayouts.ts`: ✅ all 23 layouts verified
      - `npx hardhat test test/StorageLayoutCompatibility.test.ts
        test/ReleaseReadiness.test.ts test/EventSchemaConsistency.test.ts`:
        ✅ 21 passing
- [x] **PR maps evidence to every acceptance criterion** — this section.
- [ ] **Explicit approving human maintainer review** — pending review.

### Test evidence

```
Compiled 190 Solidity files with solc 0.8.28 (evm target: cancun)

Storage Layout Compatibility (V2-SC-046)
  ✔ manifest integrity (4 tests)
  ✔ compatibility gate (2 tests)
  ✔ detector regression coverage (6 tests)
21 passing (3s)   # incl. ReleaseReadiness + EventSchemaConsistency

All 23 tracked upgradeable layouts verified successfully.
```

## Security & integrity requirements

- Preserves Optimism/EVM on-chain authority and canonical V2 state transitions —
  no contract behaviour is modified.
- No Stellar, Soroban, or Freighter runtime dependencies introduced.
- No legacy contracts restored as canonical modules; no secrets or placeholder
  production values embedded (manifest contains compiler layout data only).
- Fails closed: missing build-info, missing manifest, manifest drift, untracked
  gap contracts, and any incompatible layout all abort with a non-zero exit.

## Dependencies

- V2-SC-041 ✅ (merged), V2-SC-029 ✅ (merged)

## Non-goals respected

- No production mainnet deployment.
- No backend-authoritative protocol mutation.
- No reintroduction or extension of the legacy V1 canonical path.

## Known limitations

The pre-existing 52 Hardhat-2-style test files use `import { ethers } from
"hardhat"` and need the per-file `network.create()` migration to run under
Hardhat 3. That mechanical sweep is a separate work item — bundling it here
would violate this issue's "no unrelated refactoring" criterion. The new
SC-046 test suite plus the previously-blocking release-readiness suites
(21 tests) run and pass.

🤖 Generated with Codebuff
Co-Authored-By: Codebuff <noreply@codebuff.com>
