import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  compareRepeatedSnapshots,
  parseSnapshot,
  runChecks,
  serializeSnapshot,
  validateToolchain,
} from "../../scripts/check-gas-scenarios.mjs";

function fixture() {
  const config = {
    budgets: { OPERATION: 100 },
    bounds: { MAX_BATCH: 10 },
    recommendedTxGasCeiling: 12_000_000,
    requiredScenarioFamilies: ["cold", "warm"],
    toolchain: {
      foundryVersion: "1.8.3",
      solcVersion: "0.8.28",
      foundryEvmVersion: "prague",
      optimizerRuns: 200,
      viaIR: true,
    },
    scenarios: [
      {
        id: "registry.cold",
        families: ["cold"],
        function: "GasBudgetRegistry.getBudget",
        snapshotKey: "ScenarioGasSnapshotsTest:test_gas_registryReadCold()",
        maxGas: 100,
        setup: "First read",
      },
      {
        id: "registry.warm",
        families: ["warm"],
        function: "GasBudgetRegistry.getBudget",
        snapshotKey: "ScenarioGasSnapshotsTest:test_gas_registryReadWarm()",
        maxGas: 100,
        setup: "Repeated read",
      },
    ],
  };
  const snapshotText = [
    "ScenarioGasSnapshotsTest:test_gas_registryReadCold() (gas: 50)",
    "ScenarioGasSnapshotsTest:test_gas_registryReadWarm() (gas: 60)",
    "",
  ].join("\n");
  const actualToolchain = { ...config.toolchain };
  return { config, snapshotText, actualToolchain };
}

describe("SC-064 gas scenario gate", () => {
  it("accepts complete scenario data and deterministic snapshot regeneration", () => {
    const input = fixture();
    const first = parseSnapshot(input.snapshotText);
    const regenerated = parseSnapshot(input.snapshotText);
    assert.deepEqual(compareRepeatedSnapshots(first, regenerated), []);
    assert.equal(serializeSnapshot(first), serializeSnapshot(regenerated));
    assert.deepEqual(
      runChecks({
        configText: JSON.stringify(input.config),
        snapshotText: input.snapshotText,
        actualToolchain: input.actualToolchain,
      }),
      [],
    );
  });

  it("rejects compiler or Foundry toolchain changes", () => {
    const input = fixture();
    const changed = { ...input.actualToolchain, solcVersion: "0.8.29" };
    assert.match(validateToolchain(input.config, changed).join("\n"), /toolchain drift: solcVersion/);
  });

  it("rejects noisy measurements across repeated runs", () => {
    const first = parseSnapshot("Suite:test_case() (gas: 50)\n");
    const noisy = parseSnapshot("Suite:test_case() (gas: 51)\n");
    assert.match(compareRepeatedSnapshots(first, noisy).join("\n"), /unstable/);
  });

  it("reports a deliberate regression with scenario and function", () => {
    const input = fixture();
    input.snapshotText = input.snapshotText.replace("(gas: 50)", "(gas: 101)");
    const errors = runChecks({
      configText: JSON.stringify(input.config),
      snapshotText: input.snapshotText,
      actualToolchain: input.actualToolchain,
    });
    assert.match(errors.join("\n"), /registry\.cold \(GasBudgetRegistry\.getBudget\): 101 gas exceeds budget 100/);
  });

  it("rejects missing required families and missing snapshot keys", () => {
    const input = fixture();
    input.config.scenarios = input.config.scenarios.slice(0, 1);
    input.snapshotText = input.snapshotText.split("\n")[0];
    const errors = runChecks({
      configText: JSON.stringify(input.config),
      snapshotText: input.snapshotText,
      actualToolchain: input.actualToolchain,
    });
    assert.ok(errors.some((error) => error.includes("missing required scenario family: warm")));
  });

  it("fails when a configured scenario has no snapshot measurement", () => {
    const input = fixture();
    input.snapshotText = input.snapshotText.split("\n")[0];
    const errors = runChecks({
      configText: JSON.stringify(input.config),
      snapshotText: input.snapshotText,
      actualToolchain: input.actualToolchain,
    });
    assert.ok(errors.some((error) => error.includes("missing snapshot key")));
  });

  it("rejects duplicate snapshot keys and malformed snapshot entries", () => {
    const input = fixture();
    input.config.scenarios[1].snapshotKey = input.config.scenarios[0].snapshotKey;
    const errors = runChecks({
      configText: JSON.stringify(input.config),
      snapshotText: input.snapshotText,
      actualToolchain: input.actualToolchain,
    });
    assert.ok(errors.some((error) => error.includes("duplicate snapshotKey")));
    assert.throws(() => parseSnapshot("not a forge snapshot"), /invalid snapshot entry/);
  });
});
