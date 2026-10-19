#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

import { readToolchainPins } from "./check-release-reproducibility.mjs";

export function parseSnapshot(text) {
  const values = new Map();
  for (const [index, rawLine] of text.split(/\r?\n/).entries()) {
    const line = rawLine.trim();
    if (!line) continue;
    const match = line.match(/^(.+?) \(gas: ([0-9]+)\)$/);
    if (!match) throw new Error(`invalid snapshot entry at line ${index + 1}: ${line}`);
    if (values.has(match[1])) throw new Error(`duplicate snapshot key: ${match[1]}`);
    values.set(match[1], Number(match[2]));
  }
  if (values.size === 0) throw new Error("snapshot contains no measurements");
  return values;
}

export function serializeSnapshot(snapshot) {
  return [...snapshot.entries()]
    .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
    .map(([key, gas]) => `${key} (gas: ${gas})`)
    .join("\n") + "\n";
}

export function validateScenarios(config, snapshot) {
  const errors = [];
  const requiredFamilies = config.requiredScenarioFamilies;
  const scenarios = config.scenarios;
  if (!config.budgets || typeof config.budgets !== "object" || Array.isArray(config.budgets)) {
    errors.push("budgets must be an object");
  }
  if (!config.bounds || typeof config.bounds !== "object" || Array.isArray(config.bounds)) {
    errors.push("bounds must be an object");
  }
  if (!Number.isSafeInteger(config.recommendedTxGasCeiling) || config.recommendedTxGasCeiling <= 0) {
    errors.push("recommendedTxGasCeiling must be a positive safe integer");
  }
  if (!Array.isArray(requiredFamilies) || requiredFamilies.length === 0) {
    errors.push("requiredScenarioFamilies must be a non-empty array");
  }
  if (!Array.isArray(scenarios) || scenarios.length === 0) {
    errors.push("scenarios must be a non-empty array");
    return errors;
  }
  if (!config.toolchain || typeof config.toolchain !== "object") errors.push("toolchain pins are required");

  const ids = new Set();
  const keys = new Set();
  const families = new Set();
  const ceiling = config.recommendedTxGasCeiling;
  for (const scenario of scenarios) {
    const label = scenario?.id || "<missing-id>";
    if (typeof scenario?.id !== "string" || !scenario.id.trim()) errors.push(`${label}: id is required`);
    else if (ids.has(scenario.id)) errors.push(`${label}: duplicate scenario id`);
    else ids.add(scenario.id);

    if (typeof scenario?.function !== "string" || !/^[A-Za-z0-9_.]+\.[A-Za-z0-9_]+$/.test(scenario.function)) {
      errors.push(`${label}: function must identify Contract.function`);
    }
    if (typeof scenario?.snapshotKey !== "string" || !scenario.snapshotKey.trim()) {
      errors.push(`${label}: snapshotKey is required`);
    } else if (keys.has(scenario.snapshotKey)) {
      errors.push(`${label}: duplicate snapshotKey ${scenario.snapshotKey}`);
    } else {
      keys.add(scenario.snapshotKey);
    }
    if (!Number.isSafeInteger(scenario?.maxGas) || scenario.maxGas <= 0 || scenario.maxGas > ceiling) {
      errors.push(`${label}: maxGas must be a positive safe integer no greater than ${ceiling}`);
    }
    if (typeof scenario?.setup !== "string" || !scenario.setup.trim()) errors.push(`${label}: setup is required`);
    if (!Array.isArray(scenario?.families) || scenario.families.length === 0) {
      errors.push(`${label}: at least one scenario family is required`);
    } else {
      for (const family of scenario.families) families.add(family);
    }

    if (scenario?.snapshotKey && snapshot instanceof Map && snapshot.has(scenario.snapshotKey)) {
      const gas = snapshot.get(scenario.snapshotKey);
      if (gas > scenario.maxGas) {
        errors.push(`${label} (${scenario.function}): ${gas} gas exceeds budget ${scenario.maxGas} by ${gas - scenario.maxGas}`);
      }
    } else if (scenario?.snapshotKey && snapshot instanceof Map) {
      errors.push(`${label} (${scenario.function}): missing snapshot key ${scenario.snapshotKey}`);
    }
  }

  for (const family of requiredFamilies ?? []) {
    if (!families.has(family)) errors.push(`missing required scenario family: ${family}`);
  }
  if (snapshot instanceof Map) {
    for (const key of snapshot.keys()) {
      if (!keys.has(key)) errors.push(`unexpected snapshot key: ${key}`);
    }
  }
  return errors;
}

export function compareRepeatedSnapshots(first, second) {
  const compareKeys = ([left], [right]) => (left < right ? -1 : left > right ? 1 : 0);
  const firstEntries = [...first.entries()].sort(compareKeys);
  const secondEntries = [...second.entries()].sort(compareKeys);
  if (JSON.stringify(firstEntries) !== JSON.stringify(secondEntries)) {
    return ["snapshot measurements are unstable across repeated runs"];
  }
  return [];
}

export function validateToolchain(config, actual) {
  const expected = config.toolchain;
  const errors = [];
  for (const field of ["foundryVersion", "solcVersion", "foundryEvmVersion", "optimizerRuns", "viaIR"]) {
    if (actual[field] !== expected?.[field]) {
      errors.push(`toolchain drift: ${field} is ${JSON.stringify(actual[field])}, expected ${JSON.stringify(expected?.[field])}`);
    }
  }
  return errors;
}

function currentToolchain(root) {
  const forge = spawnSync("forge", ["--version"], { cwd: root, encoding: "utf8" });
  if (forge.status !== 0) throw new Error(`forge --version failed: ${forge.stderr || forge.error?.message || "unknown error"}`);
  const foundryVersion = (forge.stdout.match(/Version:\s*(\S+)/) ?? [])[1];
  if (!foundryVersion) throw new Error("could not read Foundry version from forge --version");

  const pins = readToolchainPins(root);
  const foundryToml = readFileSync(resolve(root, "foundry.toml"), "utf8");
  const foundryEvmVersion = (foundryToml.match(/^\s*evm_version\s*=\s*["']([^"']+)["']/m) ?? [])[1];
  if (!foundryEvmVersion) throw new Error("foundry.toml must explicitly pin evm_version");
  return {
    foundryVersion,
    solcVersion: pins.foundry.solc,
    foundryEvmVersion,
    optimizerRuns: pins.foundry.optimizerRuns,
    viaIR: pins.foundry.viaIR,
  };
}

export function runChecks({ configText, snapshotText, actualToolchain }) {
  let config;
  let snapshot;
  try {
    config = JSON.parse(configText);
  } catch (error) {
    return [`invalid gas budget JSON: ${error.message}`];
  }
  try {
    snapshot = parseSnapshot(snapshotText);
  } catch (error) {
    return [error.message];
  }
  const errors = validateScenarios(config, snapshot);
  if (actualToolchain) errors.push(...validateToolchain(config, actualToolchain));
  return errors;
}

function main() {
  const root = resolve(process.cwd());
  try {
    const errors = runChecks({
      configText: readFileSync(resolve(root, "config/gas-budgets.json"), "utf8"),
      snapshotText: readFileSync(resolve(root, ".gas-snapshot.sc064"), "utf8"),
      actualToolchain: currentToolchain(root),
    });
    if (errors.length > 0) {
      for (const error of errors) console.error(`SC-064 gas gate: ${error}`);
      process.exitCode = 1;
      return;
    }
    console.log("SC-064 gas scenarios, budgets, snapshot, and toolchain are valid.");
  } catch (error) {
    console.error(`SC-064 gas gate: ${error.message}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main();
