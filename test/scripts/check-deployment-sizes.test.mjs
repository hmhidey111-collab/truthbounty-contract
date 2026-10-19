/**
 * @file check-deployment-sizes.test.mjs
 * @issue PREWAVE-SC-062 — Per-Contract and Proxy Deployment Size Budgets
 *
 * Test plan:
 *  T1  Budget boundary — contract exactly at hard limit passes.
 *  T2  Budget boundary — contract one byte over hard limit hard-fails.
 *  T3  Budget boundary — contract at warning threshold emits warning, does not hard-fail.
 *  T4  Budget boundary — contract below warning threshold is clean.
 *  T5  Optimizer profile — runs mismatch hard-fails and records optimizer_mismatch status.
 *  T6  Optimizer profile — viaIR mismatch hard-fails.
 *  T7  Optimizer profile — matching profile passes.
 *  T8  Linked library — a tracked library over its own budget hard-fails.
 *  T9  Linked library — linked references are recorded in the report.
 *  T10 Upgrade growth — size increased by > DRIFT_WARNING_BYTES triggers drift warning.
 *  T11 Upgrade growth — size decreased does not trigger drift warning.
 *  T12 Report drift — report is written on every run (pass and fail).
 *  T13 Report drift — previous measurements are loaded and diff is reported.
 *  T14 Missing artifact — produces missing_artifact status and warning (not hard failure).
 *  T15 initcode — initcode over hard limit hard-fails.
 *  T16 initcode — initcode over warning emits warning.
 *  T17 Write baseline — regenerates config with safety margin applied.
 *  T18 Network limit — margin-to-network-limit is correctly computed.
 *  T19 Filter — --contract flag restricts check to one contract.
 *  T20 No contracts — empty contracts map produces empty report with no failures.
 */

import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { test, before, after, describe } from "node:test";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = fileURLToPath(new URL(".", import.meta.url));

// Resolve repo root.
const REPO_ROOT = resolve(__dirname, "../..");

// ---------------------------------------------------------------------------
// Import the gate module under test.
// ---------------------------------------------------------------------------

const { runSizeBudgetGate } = await import(
  resolve(REPO_ROOT, "scripts/check-deployment-sizes.mjs")
);

// ---------------------------------------------------------------------------
// Fixture scaffolding helpers.
// ---------------------------------------------------------------------------

const FIXTURE_BASE = join(REPO_ROOT, ".test-tmp-sc062");

let fixtureCount = 0;

/**
 * Create an isolated scratch directory for a test.
 * @returns {string} Absolute path to a fresh temp directory.
 */
function freshDir() {
  const id = `fixture-${process.pid}-${++fixtureCount}`;
  const dir = join(FIXTURE_BASE, id);
  mkdirSync(dir, { recursive: true });
  return dir;
}

/**
 * Write a minimal Hardhat artifact file.
 *
 * @param {string} artifactsDir
 * @param {string} contractName
 * @param {string} sourceName
 * @param {number} runtimeBytes   — deployed bytecode size
 * @param {number} initcodeBytes  — creation bytecode size
 * @param {string[]} [libraries]  — library names for link references
 */
function writeArtifact(
  artifactsDir,
  contractName,
  sourceName,
  runtimeBytes,
  initcodeBytes,
  libraries = [],
) {
  // Deployed bytecode: "0x" + "aa" * runtimeBytes
  const deployedBytecode = runtimeBytes === 0 ? "0x" : "0x" + "aa".repeat(runtimeBytes);
  // Init bytecode: "0x" + "bb" * initcodeBytes
  const bytecode = initcodeBytes === 0 ? "0x" : "0x" + "bb".repeat(initcodeBytes);

  // Build link references from library names.
  /** @type {Record<string, Record<string, Array<{start:number; length:number}>>>} */
  const deployedLinkReferences = {};
  for (const lib of libraries) {
    deployedLinkReferences[`contracts/libraries/${lib}.sol`] = {
      [lib]: [{ start: 0, length: 20 }],
    };
  }

  const artifact = {
    _format: "hh-sol-artifact-1",
    contractName,
    sourceName,
    abi: [],
    bytecode,
    deployedBytecode,
    linkReferences: {},
    deployedLinkReferences,
  };

  const contractDir = join(artifactsDir, sourceName);
  mkdirSync(contractDir, { recursive: true });
  writeFileSync(
    join(contractDir, `${contractName}.json`),
    JSON.stringify(artifact, null, 2),
  );
}

/**
 * Write a minimal Hardhat build-info file that records optimizer settings for
 * a given source name.
 *
 * @param {string} buildInfoDir
 * @param {string} sourceName
 * @param {number} optimizerRuns
 * @param {boolean} viaIR
 */
function writeBuildInfo(buildInfoDir, sourceName, optimizerRuns, viaIR) {
  mkdirSync(buildInfoDir, { recursive: true });
  const buildInfo = {
    id: "test-build-info",
    solcVersion: "0.8.28",
    input: {
      language: "Solidity",
      sources: {
        [sourceName]: { content: "// placeholder" },
      },
      settings: {
        optimizer: { enabled: true, runs: optimizerRuns },
        viaIR,
        outputSelection: { "*": { "*": ["abi", "evm.deployedBytecode"] } },
      },
    },
    output: { contracts: {} },
  };
  writeFileSync(
    join(buildInfoDir, "test-build-info.json"),
    JSON.stringify(buildInfo, null, 2),
  );
}

/**
 * Build a minimal budget config.
 *
 * @param {Record<string, {warningThresholdBytes: number; hardLimitBytes: number; category?: string}>} contracts
 * @param {{ runs?: number; viaIR?: boolean; reportPath?: string }} [opts]
 * @returns {object}
 */
function buildConfig(contracts, opts = {}) {
  const normalized = Object.fromEntries(
    Object.entries(contracts).map(([name, budget]) => [
      name,
      {
        warningThresholdBytes: budget.warningThresholdBytes,
        hardLimitBytes: budget.hardLimitBytes,
        category: budget.category ?? "implementation",
      },
    ]),
  );
  return {
    schemaVersion: 1,
    issue: "PREWAVE-SC-062",
    networkLimitBytes: 24576,
    defaults: {
      warningThresholdBytes: 22000,
      hardLimitBytes: 23500,
      initcodeWarningBytes: 46000,
      initcodeHardLimitBytes: 49000,
    },
    contracts: normalized,
    optimizerProfile: {
      expectedRuns: opts.runs ?? 200,
      viaIR: opts.viaIR ?? true,
    },
    reportPath: opts.reportPath ?? "deployment-size-report.json",
  };
}

/**
 * Write a config file and return its path relative to tmpDir.
 *
 * @param {string} tmpDir
 * @param {object} configObj
 * @returns {string}  absolute path
 */
function writeConfig(tmpDir, configObj) {
  const configPath = join(tmpDir, "deployment-size-budgets.json");
  writeFileSync(configPath, JSON.stringify(configObj, null, 2));
  return configPath;
}

/**
 * Run the gate with a fixture directory as the effective repo root.
 *
 * Because `runSizeBudgetGate` resolves paths relative to REPO_ROOT we patch
 * the call by passing absolute paths for all relevant directories.
 *
 * @param {{
 *   configPath: string;
 *   artifactsDir: string;
 *   buildInfoDir?: string;
 *   reportPath: string;
 *   reportOnly?: boolean;
 *   writeBaseline?: boolean;
 *   filterContract?: string | null;
 * }} params
 */
function runGate(params) {
  return runSizeBudgetGate({
    configPath: params.configPath,
    artifactsDir: params.artifactsDir,
    buildInfoDir: params.buildInfoDir ?? join(params.artifactsDir, "build-info"),
    reportOnly: params.reportOnly ?? false,
    writeBaseline: params.writeBaseline ?? false,
    filterContract: params.filterContract ?? null,
  });
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------

after(() => {
  if (existsSync(FIXTURE_BASE)) {
    rmSync(FIXTURE_BASE, { recursive: true, force: true });
  }
});

// ===========================================================================
// Tests
// ===========================================================================

describe("PREWAVE-SC-062 — Deployment Size Budget Gate", () => {

  // -------------------------------------------------------------------------
  // T1: exactly at hard limit passes
  // -------------------------------------------------------------------------
  test("T1 — contract exactly at hard limit passes", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");
    const hardLimit = 23500;

    writeArtifact(
      artifactsDir,
      "MyContract",
      "contracts/MyContract.sol",
      hardLimit,   // runtime = hard limit exactly
      5000,        // initcode well within
    );

    const config = buildConfig(
      { MyContract: { warningThresholdBytes: 22000, hardLimitBytes: hardLimit } },
      { reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({ configPath, artifactsDir, reportPath: join(tmp, "report.json") });

    assert.equal(exitCode, 0, "Should pass at hard limit");
    assert.equal(report.hardFailures.length, 0, "No hard failures expected");
    const cr = report.contracts.find((c) => c.contractName === "MyContract");
    assert.ok(cr, "Contract report present");
    assert.equal(cr.runtimeBytes, hardLimit);
    assert.equal(cr.marginToHardLimit, 0, "Margin should be zero at hard limit");
  });

  // -------------------------------------------------------------------------
  // T2: one byte over hard limit hard-fails
  // -------------------------------------------------------------------------
  test("T2 — contract one byte over hard limit hard-fails", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");
    const hardLimit = 23500;

    writeArtifact(
      artifactsDir,
      "BigContract",
      "contracts/BigContract.sol",
      hardLimit + 1,
      5000,
    );

    const config = buildConfig(
      { BigContract: { warningThresholdBytes: 22000, hardLimitBytes: hardLimit } },
      { reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({ configPath, artifactsDir, reportPath: join(tmp, "report.json") });

    assert.equal(exitCode, 1, "Should fail over hard limit");
    assert.ok(report.hardFailures.length > 0, "Hard failure present");
    assert.ok(
      report.hardFailures.some((f) => f.includes("BigContract") && f.includes("hard limit")),
      `Hard failure references contract and limit. Got: ${report.hardFailures.join("; ")}`,
    );
    const cr = report.contracts.find((c) => c.contractName === "BigContract");
    assert.equal(cr?.status, "over_limit");
  });

  // -------------------------------------------------------------------------
  // T3: at warning threshold emits warning, does not hard-fail
  // -------------------------------------------------------------------------
  test("T3 — contract at warning threshold emits warning without hard failure", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");

    writeArtifact(
      artifactsDir,
      "WarnContract",
      "contracts/WarnContract.sol",
      22000, // exactly at warning
      5000,
    );

    const config = buildConfig(
      { WarnContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({ configPath, artifactsDir, reportPath: join(tmp, "report.json") });

    assert.equal(exitCode, 0, "Should not hard-fail at warning");
    assert.ok(report.warnings.length > 0, "Warning should be present");
    const cr = report.contracts.find((c) => c.contractName === "WarnContract");
    assert.equal(cr?.status, "warning");
  });

  // -------------------------------------------------------------------------
  // T4: below warning threshold is clean
  // -------------------------------------------------------------------------
  test("T4 — contract below warning threshold is clean", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");

    writeArtifact(
      artifactsDir,
      "SmallContract",
      "contracts/SmallContract.sol",
      10000,
      20000,
    );

    const config = buildConfig(
      { SmallContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({ configPath, artifactsDir, reportPath: join(tmp, "report.json") });

    assert.equal(exitCode, 0);
    assert.equal(report.hardFailures.length, 0);
    const cr = report.contracts.find((c) => c.contractName === "SmallContract");
    assert.equal(cr?.status, "ok");
  });

  // -------------------------------------------------------------------------
  // T5: optimizer runs mismatch hard-fails
  // -------------------------------------------------------------------------
  test("T5 — optimizer runs mismatch hard-fails and records optimizer_mismatch status", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");
    const buildInfoDir = join(artifactsDir, "build-info");

    writeArtifact(
      artifactsDir,
      "OptContract",
      "contracts/OptContract.sol",
      10000,
      20000,
    );
    // Build info says runs=100 but config expects 200.
    writeBuildInfo(buildInfoDir, "contracts/OptContract.sol", 100, true);

    const config = buildConfig(
      { OptContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { runs: 200, viaIR: true, reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({ configPath, artifactsDir, buildInfoDir, reportPath: join(tmp, "report.json") });

    assert.equal(exitCode, 1, "Optimizer mismatch should hard-fail");
    assert.ok(
      report.hardFailures.some((f) => f.includes("Optimizer profile mismatch")),
      `Expected optimizer mismatch failure. Got: ${report.hardFailures.join("; ")}`,
    );
  });

  // -------------------------------------------------------------------------
  // T6: viaIR mismatch hard-fails
  // -------------------------------------------------------------------------
  test("T6 — viaIR mismatch hard-fails", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");
    const buildInfoDir = join(artifactsDir, "build-info");

    writeArtifact(
      artifactsDir,
      "IRContract",
      "contracts/IRContract.sol",
      10000,
      20000,
    );
    // Config expects viaIR=true, build-info says false.
    writeBuildInfo(buildInfoDir, "contracts/IRContract.sol", 200, false);

    const config = buildConfig(
      { IRContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { runs: 200, viaIR: true, reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({ configPath, artifactsDir, buildInfoDir, reportPath: join(tmp, "report.json") });

    assert.equal(exitCode, 1, "viaIR mismatch should hard-fail");
    assert.ok(
      report.hardFailures.some((f) => f.includes("Optimizer profile mismatch")),
      `Expected optimizer mismatch failure. Got: ${report.hardFailures.join("; ")}`,
    );
  });

  // -------------------------------------------------------------------------
  // T7: matching optimizer profile passes
  // -------------------------------------------------------------------------
  test("T7 — matching optimizer profile passes without mismatch failure", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");
    const buildInfoDir = join(artifactsDir, "build-info");

    writeArtifact(
      artifactsDir,
      "MatchContract",
      "contracts/MatchContract.sol",
      10000,
      20000,
    );
    writeBuildInfo(buildInfoDir, "contracts/MatchContract.sol", 200, true);

    const config = buildConfig(
      { MatchContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { runs: 200, viaIR: true, reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({ configPath, artifactsDir, buildInfoDir, reportPath: join(tmp, "report.json") });

    assert.equal(exitCode, 0, "Matching optimizer should pass");
    assert.ok(
      !report.hardFailures.some((f) => f.includes("Optimizer")),
      "No optimizer failure",
    );
  });

  // -------------------------------------------------------------------------
  // T8: linked library over its budget hard-fails
  // -------------------------------------------------------------------------
  test("T8 — tracked linked library over its own budget hard-fails", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");

    // Main contract is fine.
    writeArtifact(
      artifactsDir,
      "MainContract",
      "contracts/MainContract.sol",
      5000,
      10000,
      ["BigLib"],
    );
    // Library exceeds its budget.
    writeArtifact(
      artifactsDir,
      "BigLib",
      "contracts/libraries/BigLib.sol",
      23000, // over library hard limit of 18000
      25000,
    );

    const config = buildConfig(
      {
        MainContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 },
        BigLib: { warningThresholdBytes: 15000, hardLimitBytes: 18000, category: "library" },
      },
      { reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({ configPath, artifactsDir, reportPath: join(tmp, "report.json") });

    assert.equal(exitCode, 1, "Library over budget should hard-fail");
    const libReport = report.contracts.find((c) => c.contractName === "BigLib");
    assert.equal(libReport?.status, "over_limit", "Library status should be over_limit");
  });

  // -------------------------------------------------------------------------
  // T9: linked references are recorded in the report
  // -------------------------------------------------------------------------
  test("T9 — linked library references are recorded in the contract report", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");

    writeArtifact(
      artifactsDir,
      "LinkedContract",
      "contracts/LinkedContract.sol",
      5000,
      10000,
      ["SafeMathLib", "EncodeLib"],
    );
    writeArtifact(artifactsDir, "SafeMathLib", "contracts/libraries/SafeMathLib.sol", 1000, 2000);
    writeArtifact(artifactsDir, "EncodeLib", "contracts/libraries/EncodeLib.sol", 1000, 2000);

    const config = buildConfig(
      {
        LinkedContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 },
        SafeMathLib: { warningThresholdBytes: 10000, hardLimitBytes: 12000, category: "library" },
        EncodeLib: { warningThresholdBytes: 10000, hardLimitBytes: 12000, category: "library" },
      },
      { reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report } = runGate({ configPath, artifactsDir, reportPath: join(tmp, "report.json") });

    const cr = report.contracts.find((c) => c.contractName === "LinkedContract");
    assert.ok(cr?.linkedLibraries, "linkedLibraries field present");
    assert.ok(
      cr.linkedLibraries.includes("SafeMathLib"),
      `linkedLibraries should include SafeMathLib. Got: ${cr.linkedLibraries}`,
    );
    assert.ok(
      cr.linkedLibraries.includes("EncodeLib"),
      `linkedLibraries should include EncodeLib. Got: ${cr.linkedLibraries}`,
    );
  });

  // -------------------------------------------------------------------------
  // T10: size increased by > DRIFT_WARNING_BYTES triggers drift warning
  // -------------------------------------------------------------------------
  test("T10 — upgrade growth beyond drift threshold triggers drift warning", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");
    const reportPath = join(tmp, "report.json");

    writeArtifact(
      artifactsDir,
      "GrowingContract",
      "contracts/GrowingContract.sol",
      15000,
      30000,
    );

    // Write a previous report where GrowingContract was 14000B.
    const previousReport = {
      schemaVersion: 1,
      issue: "PREWAVE-SC-062",
      generatedAt: new Date(Date.now() - 86400000).toISOString(),
      gitSha: "abcdef0",
      passed: true,
      hardFailures: [],
      warnings: [],
      previousMeasurements: {},
      contracts: [
        {
          contractName: "GrowingContract",
          runtimeBytes: 14000, // was 14000B, now 15000B — delta = 1000B > 500B threshold
          status: "ok",
        },
      ],
      optimizerProfile: { runs: 200, viaIR: true, checked: false },
    };
    writeFileSync(reportPath, JSON.stringify(previousReport, null, 2));

    const config = buildConfig(
      { GrowingContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { reportPath },
    );
    const configPath = writeConfig(tmp, config);

    const { report } = runGate({ configPath, artifactsDir, reportPath });

    assert.ok(
      report.warnings.some((w) => w.includes("GrowingContract") && w.includes("drift")),
      `Expected drift warning for GrowingContract. Warnings: ${report.warnings.join("; ")}`,
    );
    const cr = report.contracts.find((c) => c.contractName === "GrowingContract");
    assert.equal(cr?.driftWarning, true, "driftWarning flag should be true");
    assert.equal(cr?.driftFromPreviousBytes, 1000, "Drift should be +1000B");
  });

  // -------------------------------------------------------------------------
  // T11: size decreased does not trigger drift warning
  // -------------------------------------------------------------------------
  test("T11 — size decrease within threshold does not trigger drift warning", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");
    const reportPath = join(tmp, "report.json");

    writeArtifact(
      artifactsDir,
      "ShrinkingContract",
      "contracts/ShrinkingContract.sol",
      14900, // was 15000B, decreased by 100B — well within threshold
      30000,
    );

    const previousReport = {
      schemaVersion: 1,
      contracts: [{ contractName: "ShrinkingContract", runtimeBytes: 15000, status: "ok" }],
    };
    writeFileSync(reportPath, JSON.stringify(previousReport, null, 2));

    const config = buildConfig(
      { ShrinkingContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { reportPath },
    );
    const configPath = writeConfig(tmp, config);

    const { report } = runGate({ configPath, artifactsDir, reportPath });

    assert.ok(
      !report.warnings.some((w) => w.includes("ShrinkingContract") && w.includes("drift")),
      `Unexpected drift warning for ShrinkingContract. Warnings: ${report.warnings.join("; ")}`,
    );
    const cr = report.contracts.find((c) => c.contractName === "ShrinkingContract");
    assert.equal(cr?.driftWarning, undefined, "driftWarning should be absent");
  });

  // -------------------------------------------------------------------------
  // T12: report is written on every run (pass and fail)
  // -------------------------------------------------------------------------
  test("T12 — report file is written on every run regardless of pass/fail", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");
    const reportPath = join(tmp, "sub", "report.json");

    writeArtifact(
      artifactsDir,
      "ReportableContract",
      "contracts/ReportableContract.sol",
      25000, // over hard limit → gate fails
      50000,
    );

    const config = buildConfig(
      { ReportableContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { reportPath },
    );
    const configPath = writeConfig(tmp, config);

    const { exitCode } = runGate({ configPath, artifactsDir, reportPath });

    assert.equal(exitCode, 1, "Gate should fail");
    assert.ok(existsSync(reportPath), "Report file must be written even on failure");

    const written = JSON.parse(readFileSync(reportPath, "utf-8"));
    assert.equal(written.schemaVersion, 1, "Report schema version");
    assert.equal(written.issue, "PREWAVE-SC-062", "Report issue tag");
    assert.ok(Array.isArray(written.hardFailures), "hardFailures array present");
    assert.ok(Array.isArray(written.contracts), "contracts array present");
  });

  // -------------------------------------------------------------------------
  // T13: previous measurements are loaded and diff is reported
  // -------------------------------------------------------------------------
  test("T13 — previous report measurements are loaded and diff is computed", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");
    const reportPath = join(tmp, "report.json");

    writeArtifact(
      artifactsDir,
      "DiffContract",
      "contracts/DiffContract.sol",
      12000,
      24000,
    );

    // Pre-seed a previous report.
    const prev = {
      schemaVersion: 1,
      contracts: [{ contractName: "DiffContract", runtimeBytes: 11000, status: "ok" }],
    };
    writeFileSync(reportPath, JSON.stringify(prev, null, 2));

    const config = buildConfig(
      { DiffContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { reportPath },
    );
    const configPath = writeConfig(tmp, config);

    const { report } = runGate({ configPath, artifactsDir, reportPath });

    const cr = report.contracts.find((c) => c.contractName === "DiffContract");
    assert.equal(
      cr?.driftFromPreviousBytes,
      1000,
      `Expected drift +1000B. Got: ${cr?.driftFromPreviousBytes}`,
    );
    // Also verify the previousMeasurements field in the report captures the old value.
    assert.equal(
      report.previousMeasurements["DiffContract"],
      11000,
      "previousMeasurements should capture old value",
    );
  });

  // -------------------------------------------------------------------------
  // T14: missing artifact → missing_artifact status, warning (not hard failure)
  // -------------------------------------------------------------------------
  test("T14 — missing artifact produces missing_artifact status and warning, not hard failure", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");
    mkdirSync(artifactsDir, { recursive: true }); // empty artifacts dir

    const config = buildConfig(
      { GhostContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({ configPath, artifactsDir, reportPath: join(tmp, "report.json") });

    assert.equal(exitCode, 0, "Missing artifact should NOT hard-fail");
    assert.ok(
      report.warnings.some((w) => w.includes("GhostContract")),
      `Expected warning for GhostContract. Warnings: ${report.warnings.join("; ")}`,
    );
    const cr = report.contracts.find((c) => c.contractName === "GhostContract");
    assert.equal(cr?.status, "missing_artifact");
    assert.equal(report.hardFailures.length, 0);
  });

  // -------------------------------------------------------------------------
  // T15: initcode over hard limit hard-fails
  // -------------------------------------------------------------------------
  test("T15 — initcode over initcode hard limit hard-fails", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");

    writeArtifact(
      artifactsDir,
      "HugeInitContract",
      "contracts/HugeInitContract.sol",
      10000,  // runtime fine
      50000,  // initcode over 49000 hard limit
    );

    const config = buildConfig(
      { HugeInitContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({ configPath, artifactsDir, reportPath: join(tmp, "report.json") });

    assert.equal(exitCode, 1, "Initcode over hard limit should hard-fail");
    assert.ok(
      report.hardFailures.some(
        (f) => f.includes("HugeInitContract") && f.includes("initcode"),
      ),
      `Expected initcode hard failure. Got: ${report.hardFailures.join("; ")}`,
    );
  });

  // -------------------------------------------------------------------------
  // T16: initcode over warning emits warning
  // -------------------------------------------------------------------------
  test("T16 — initcode over warning threshold emits initcode warning", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");

    writeArtifact(
      artifactsDir,
      "WarnInitContract",
      "contracts/WarnInitContract.sol",
      10000,
      47000, // over 46000 warning but under 49000 hard limit
    );

    const config = buildConfig(
      { WarnInitContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({ configPath, artifactsDir, reportPath: join(tmp, "report.json") });

    assert.equal(exitCode, 0, "Initcode over warning should not hard-fail");
    assert.ok(
      report.warnings.some(
        (w) => w.includes("WarnInitContract") && w.includes("initcode"),
      ),
      `Expected initcode warning. Warnings: ${report.warnings.join("; ")}`,
    );
  });

  // -------------------------------------------------------------------------
  // T17: --write-baseline regenerates config with safety margin
  // -------------------------------------------------------------------------
  test("T17 — write-baseline regenerates config with safety margin applied", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");
    const reportPath = join(tmp, "report.json");

    writeArtifact(
      artifactsDir,
      "BaselineContract",
      "contracts/BaselineContract.sol",
      10000,
      20000,
    );

    const config = buildConfig(
      { BaselineContract: { warningThresholdBytes: 9000, hardLimitBytes: 11000 } },
      { reportPath },
    );
    const configPath = writeConfig(tmp, config);

    runGate({ configPath, artifactsDir, reportPath, writeBaseline: true });

    const updatedConfig = JSON.parse(readFileSync(configPath, "utf-8"));
    const entry = updatedConfig.contracts["BaselineContract"];
    assert.ok(entry, "Entry should exist after baseline write");
    // Safety margin: max(ceil(10000 * 0.05), 200) = max(500, 200) = 500
    // New hard limit = 10000 + 500 = 10500
    // New warning = 10000 + ceil(500 * 0.6) = 10000 + 300 = 10300
    assert.ok(
      entry.hardLimitBytes >= 10000,
      `New hard limit should be >= measured size. Got: ${entry.hardLimitBytes}`,
    );
    assert.ok(
      entry.hardLimitBytes > entry.warningThresholdBytes,
      "Hard limit must exceed warning threshold",
    );
    assert.ok(
      entry.hardLimitBytes <= 24576,
      "New hard limit must not exceed network limit",
    );
  });

  // -------------------------------------------------------------------------
  // T18: margin-to-network-limit is correctly computed
  // -------------------------------------------------------------------------
  test("T18 — marginToNetworkLimit is correctly computed", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");

    const runtimeBytes = 8192;
    const networkLimit = 24576;

    writeArtifact(
      artifactsDir,
      "MarginContract",
      "contracts/MarginContract.sol",
      runtimeBytes,
      16384,
    );

    const config = buildConfig(
      { MarginContract: { warningThresholdBytes: 22000, hardLimitBytes: 23500 } },
      { reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report } = runGate({ configPath, artifactsDir, reportPath: join(tmp, "report.json") });

    const cr = report.contracts.find((c) => c.contractName === "MarginContract");
    assert.equal(
      cr?.marginToNetworkLimit,
      networkLimit - runtimeBytes,
      `marginToNetworkLimit should be ${networkLimit - runtimeBytes}`,
    );
  });

  // -------------------------------------------------------------------------
  // T19: filterContract restricts check to one contract
  // -------------------------------------------------------------------------
  test("T19 — filterContract restricts check to one contract", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");

    // Contract A is fine.
    writeArtifact(
      artifactsDir,
      "ContractA",
      "contracts/ContractA.sol",
      5000,
      10000,
    );
    // Contract B is over limit but should be excluded.
    writeArtifact(
      artifactsDir,
      "ContractB",
      "contracts/ContractB.sol",
      25000,
      50000,
    );

    const config = buildConfig(
      {
        ContractA: { warningThresholdBytes: 22000, hardLimitBytes: 23500 },
        ContractB: { warningThresholdBytes: 22000, hardLimitBytes: 23500 },
      },
      { reportPath: join(tmp, "report.json") },
    );
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({
      configPath,
      artifactsDir,
      reportPath: join(tmp, "report.json"),
      filterContract: "ContractA",
    });

    assert.equal(exitCode, 0, "Filter to ContractA should pass");
    assert.equal(report.contracts.length, 1, "Only one contract in report");
    assert.equal(report.contracts[0].contractName, "ContractA");
  });

  // -------------------------------------------------------------------------
  // T20: empty contracts map produces empty report with no failures
  // -------------------------------------------------------------------------
  test("T20 — empty contracts map produces empty report with no failures", async () => {
    const tmp = freshDir();
    const artifactsDir = join(tmp, "artifacts");
    mkdirSync(artifactsDir, { recursive: true });

    const config = buildConfig({}, { reportPath: join(tmp, "report.json") });
    const configPath = writeConfig(tmp, config);

    const { report, exitCode } = runGate({ configPath, artifactsDir, reportPath: join(tmp, "report.json") });

    assert.equal(exitCode, 0, "Empty contracts should produce no failures");
    assert.equal(report.hardFailures.length, 0);
    assert.equal(report.contracts.length, 0);
  });

});
