# Gas Snapshot Workflow

SC-064 adds a focused Foundry snapshot for representative protocol scenarios while preserving the full-suite `.gas-snapshot` gate and the existing operation budgets.

## Pinned Measurement Toolchain

- Foundry: `1.8.3`
- Solidity: `0.8.28`
- Foundry EVM: `prague` (explicitly pinned in `foundry.toml`)
- Optimizer: enabled, 200 runs
- `via_ir`: enabled

The gas scenario checker verifies the installed Foundry version and the Solidity/build pins before accepting the focused baseline. These settings identify the gas measurement toolchain; they do not authorize changing release/compiler behavior.

## Commands

Run the SC-064 scenario suite:

```sh
npm run test:gas:sc064
```

Run the scenario validator's self-tests:

```sh
npm run test:gas:sc064:gate
```

Regenerate the focused baseline after reviewing the measured change:

```sh
npm run snapshot:gas:sc064
```

Check the focused scenario budgets and snapshot:

```sh
npm run check:gas:sc064
```

The main CI and standalone gas workflows also check the existing full-suite `.gas-snapshot`.

## Scenario and Budget Review

`config/gas-budgets.json` retains the existing operation `budgets` and protocol `bounds`, and adds the SC-064 scenario catalog, required families, toolchain identity, and per-scenario maximums. Every snapshot key must map to exactly one configured scenario. Missing, malformed, extra, unstable, over-budget, or toolchain-mismatched measurements fail closed and identify the scenario/function where applicable.

A functional change that affects measured gas must include the regenerated `.gas-snapshot.sc064` and an explicit reviewed budget change when needed. Snapshot regeneration never updates budgets. Do not raise unrelated limits, accept noisy results, or weaken another security/release gate to make the gas workflow pass.
