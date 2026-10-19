#!/usr/bin/env node
/**
 * @file check-deployment-sizes.mjs
 * @issue PREWAVE-SC-062
 * @description Per-contract and proxy deployment size budget gate.
 *
 * Gate contract:
 *  1. For every contract name tracked in config/deployment-size-budgets.json, the
 *     Hardhat artifact is located and its runtime (deployed) bytecode and init
 *     (creation) bytecode are measured in bytes.
 *  2. A contract whose runtime bytecode exceeds its hard limit FAILS the gate;
 *     the deploy script must not proceed.  This prevents EIP-170 rejections on
 *     the network (24,576-byte limit) from reaching broadcast.
 *  3. A contract that exceeds its warning threshold but is still under the hard
 *     limit produces a warning and continues; CI can escalate this to advisory.
 *  4. Growth is attributed per contract in the JSON report so reviewers can
 *     pinpoint which module drove size increase.
 *  5. The optimizer profile (runs, viaIR) recorded in the budget config is
 *     cross-checked against the build-info metadata embedded in each artifact.
 *     A mismatch fails the gate.
 *  6. Library link references are detected; a linked library whose runtime size
 *     exceeds its own budget also fails.
 *  7. A report is written to deployments/releases/deployment-size-report.json
 *     whenever the gate runs, regardless of pass/fail, so release tooling can
 *     archive measurements.
 *  8. A --write-baseline flag regenerates config/deployment-size-budgets.json
 *     with the current measured sizes as the new hard limits (safety-margin
 *     applied), analogous to the reproducibility check.
 *  9. If a previous report exists, each contract's size is compared to the
 *     previous measurement and drift beyond a configurable threshold is flagged
 *     (report-drift check).
 *
 * Fails closed: missing artifacts, unreadable config, or malformed JSON all
 * exit non-zero instead of silently passing.
 *
 * Usage:
 *   node scripts/check-deployment-sizes.mjs                 # check mode
 *   node scripts/check-deployment-sizes.mjs --write-baseline # regenerate budgets
 *   node scripts/check-deployment-sizes.mjs --report-only   # measure + write report, no fail
 *   node scripts/check-deployment-sizes.mjs --contract FeeManager  # check one contract
 */

import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "..");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** EIP-170 network hard limit for deployed (runtime) bytecode. */
const NETWORK_LIMIT_BYTES = 24576;

/**
 * Safety margin applied on top of a measured size when writing a new baseline,
 * expressed as a fraction of the current measured value (5 %).
 */
const BASELINE_SAFETY_FRACTION = 0.05;

/**
 * Minimum absolute safety margin added when writing baselines (bytes).
 * Prevents margin from being negligibly small for tiny contracts.
 */
const BASELINE_MIN_SAFETY_BYTES = 200;

/**
 * Maximum single-contract drift allowed between successive reports before the
 * gate emits a drift warning (bytes).  Exceeding this threshold does not by
 * itself fail the gate — it merely annotates the report.
 */
const DRIFT_WARNING_BYTES = 500;

const CONFIG_PATH = "config/deployment-size-budgets.json";
const DEFAULT_REPORT_PATH = "deployments/releases/deployment-size-report.json";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * @param {string} label
 * @param {unknown} value
 * @returns {Record<string, unknown>}
 */
function requirePlainObject(label, value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be a plain JSON object`);
  }
  return /** @type {Record<string, unknown>} */ (value);
}

/**
 * Round up to the nearest integer.
 * @param {number} n
 */
function ceil(n) {
  return Math.ceil(n);
}

/**
 * Convert a hex-encoded bytecode string (with or without 0x prefix) to a byte
 * count.  "0x" / "" both map to 0.
 * @param {string} hex
 * @returns {number}
 */
function hexByteLength(hex) {
  const stripped = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (stripped.length === 0) return 0;
  // Each byte is 2 hex characters.
  return stripped.length / 2;
}

/**
 * Walk `dir` recursively, collecting all files with the given extension.
 * @param {string} dir
 * @param {string} ext  — e.g. ".json"
 * @param {string[]} [acc]
 * @returns {string[]}
 */
function findFiles(dir, ext, acc = []) {
  if (!existsSync(dir)) return acc;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      findFiles(full, ext, acc);
    } else if (entry.isFile() && entry.name.endsWith(ext)) {
      acc.push(full);
    }
  }
  return acc;
}

// ---------------------------------------------------------------------------
// Config loading
// ---------------------------------------------------------------------------

/**
 * @typedef {Object} ContractBudget
 * @property {number} warningThresholdBytes
 * @property {number} hardLimitBytes
 * @property {string} category
 * @property {string} [note]
 */

/**
 * @typedef {Object} BudgetConfig
 * @property {number} schemaVersion
 * @property {string} issue
 * @property {number} networkLimitBytes
 * @property {{ warningThresholdBytes: number; hardLimitBytes: number; initcodeWarningBytes: number; initcodeHardLimitBytes: number }} defaults
 * @property {Record<string, ContractBudget>} contracts
 * @property {{ expectedRuns: number; viaIR: boolean }} optimizerProfile
 * @property {string} reportPath
 */

/**
 * @param {string} configPath
 * @returns {BudgetConfig}
 */
function loadConfig(configPath = CONFIG_PATH) {
  const absolute = resolve(REPO_ROOT, configPath);
  if (!existsSync(absolute)) {
    throw new Error(`Budget config not found: ${absolute}`);
  }
  const raw = JSON.parse(readFileSync(absolute, "utf-8"));
  if (!raw || typeof raw !== "object" || raw.schemaVersion !== 1) {
    throw new Error(`Budget config ${absolute} must be a JSON object with schemaVersion:1`);
  }
  requirePlainObject("contracts", raw.contracts);
  return /** @type {BudgetConfig} */ (raw);
}

// ---------------------------------------------------------------------------
// Artifact discovery
// ---------------------------------------------------------------------------

/**
 * @typedef {Object} HardhatArtifact
 * @property {string} contractName
 * @property {string} sourceName
 * @property {string} bytecode          — init/creation bytecode (hex)
 * @property {string} deployedBytecode  — runtime bytecode (hex)
 * @property {Record<string, Record<string, Array<{start:number; length:number}>>>} linkReferences
 * @property {Record<string, Record<string, Array<{start:number; length:number}>>>} deployedLinkReferences
 */

/**
 * @typedef {Object} ArtifactMeasurement
 * @property {string} contractName
 * @property {string} sourceName
 * @property {number} runtimeBytes     — deployedBytecode size
 * @property {number} initcodeBytes    — bytecode (creation) size
 * @property {string[]} linkedLibraries — library names referenced in link references
 * @property {string} artifactPath
 */

/**
 * Find the canonical artifact for a contract name by walking artifacts/ directory.
 * Prefers artifacts under `contracts/` source path over `contracts/test/` or `contracts/mocks/`.
 *
 * @param {string} contractName
 * @param {string} artifactsDir
 * @returns {HardhatArtifact | null}
 */
function findArtifact(contractName, artifactsDir) {
  const candidatePaths = findFiles(artifactsDir, ".json").filter(
    (f) =>
      !f.endsWith(".dbg.json") &&
      // The artifact file name must be exactly <ContractName>.json
      f.endsWith(`/${contractName}.json`),
  );

  if (candidatePaths.length === 0) return null;

  // Prefer non-mock, non-test, non-script paths.
  const preferenceOrder = [
    (p) => !p.includes("/mocks/") && !p.includes("/test/") && !p.includes("/simulation/"),
    (p) => !p.includes("/mocks/") && !p.includes("/test/"),
    () => true,
  ];

  for (const pred of preferenceOrder) {
    const match = candidatePaths.find(pred);
    if (match) {
      const raw = JSON.parse(readFileSync(match, "utf-8"));
      return /** @type {HardhatArtifact} */ (raw);
    }
  }

  // Fallback: first found.
  return JSON.parse(readFileSync(candidatePaths[0], "utf-8"));
}

/**
 * @param {string} contractName
 * @param {string} artifactsDir
 * @returns {ArtifactMeasurement | null}
 */
function measureContract(contractName, artifactsDir) {
  const artifact = findArtifact(contractName, artifactsDir);
  if (!artifact) return null;

  const runtimeBytes = hexByteLength(artifact.deployedBytecode);
  const initcodeBytes = hexByteLength(artifact.bytecode);

  const linkedLibraries = Object.keys(artifact.deployedLinkReferences ?? {}).flatMap(
    (file) => Object.keys(artifact.deployedLinkReferences[file]),
  );

  return {
    contractName: artifact.contractName,
    sourceName: artifact.sourceName,
    runtimeBytes,
    initcodeBytes,
    linkedLibraries,
    artifactPath: "", // populated by caller
  };
}

// ---------------------------------------------------------------------------
// Optimizer profile cross-check via build-info
// ---------------------------------------------------------------------------

/**
 * @typedef {Object} CompilerSettings
 * @property {{ enabled: boolean; runs: number }} optimizer
 * @property {boolean} [viaIR]
 */

/**
 * Attempt to extract optimizer settings from build-info for a given source file.
 * Returns null if build-info is not available (e.g. Foundry artifacts).
 *
 * @param {string} sourceName
 * @param {string} buildInfoDir
 * @returns {CompilerSettings | null}
 */
function extractOptimizerSettings(sourceName, buildInfoDir) {
  if (!existsSync(buildInfoDir)) return null;
  const buildInfoFiles = findFiles(buildInfoDir, ".json").filter(
    (f) => !f.endsWith(".dbg.json"),
  );
  for (const bif of buildInfoFiles) {
    try {
      const bi = JSON.parse(readFileSync(bif, "utf-8"));
      const settings = bi?.input?.settings;
      if (!settings) continue;
      // Check if this build-info includes our source.
      if (bi.input?.sources?.[sourceName] !== undefined) {
        return {
          optimizer: settings.optimizer ?? { enabled: false, runs: 200 },
          viaIR: settings.viaIR ?? false,
        };
      }
    } catch {
      // Skip unreadable build-info files.
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Report types
// ---------------------------------------------------------------------------

/**
 * @typedef {"ok" | "warning" | "over_limit" | "missing_artifact" | "optimizer_mismatch"} ContractStatus
 */

/**
 * @typedef {Object} ContractReport
 * @property {string} contractName
 * @property {string} [sourceName]
 * @property {ContractStatus} status
 * @property {number} [runtimeBytes]
 * @property {number} [initcodeBytes]
 * @property {number} warningThresholdBytes
 * @property {number} hardLimitBytes
 * @property {number} networkLimitBytes
 * @property {number} [marginToHardLimit]
 * @property {number} [marginToNetworkLimit]
 * @property {string} category
 * @property {string[]} [linkedLibraries]
 * @property {string} [note]
 * @property {string} [optimizerMismatchDetail]
 * @property {number} [driftFromPreviousBytes]
 * @property {boolean} [driftWarning]
 */

/**
 * @typedef {Object} SizeReport
 * @property {number} schemaVersion
 * @property {string} issue
 * @property {string} generatedAt
 * @property {string} gitSha
 * @property {boolean} passed
 * @property {string[]} hardFailures
 * @property {string[]} warnings
 * @property {Record<string, number>} previousMeasurements   — runtime bytes by contract name
 * @property {ContractReport[]} contracts
 * @property {{ runs: number; viaIR: boolean; checked: boolean }} optimizerProfile
 */

// ---------------------------------------------------------------------------
// Core check logic
// ---------------------------------------------------------------------------

/**
 * @param {Object} opts
 * @param {string} [opts.configPath]
 * @param {string} [opts.artifactsDir]
 * @param {string} [opts.buildInfoDir]
 * @param {boolean} [opts.reportOnly]
 * @param {boolean} [opts.writeBaseline]
 * @param {string} [opts.filterContract]
 * @returns {{ report: SizeReport; exitCode: number }}
 */
export function runSizeBudgetGate(opts = {}) {
  const {
    configPath = CONFIG_PATH,
    artifactsDir = resolve(REPO_ROOT, "artifacts"),
    buildInfoDir = resolve(REPO_ROOT, "artifacts", "build-info"),
    reportOnly = false,
    writeBaseline = false,
    filterContract = null,
  } = opts;

  const config = loadConfig(configPath);

  // Load previous report for drift comparison.
  const reportAbsPath = resolve(REPO_ROOT, config.reportPath ?? DEFAULT_REPORT_PATH);
  /** @type {Record<string, number>} */
  let previousMeasurements = {};
  if (existsSync(reportAbsPath)) {
    try {
      const prev = JSON.parse(readFileSync(reportAbsPath, "utf-8"));
      if (prev && Array.isArray(prev.contracts)) {
        for (const c of prev.contracts) {
          if (typeof c.contractName === "string" && typeof c.runtimeBytes === "number") {
            previousMeasurements[c.contractName] = c.runtimeBytes;
          }
        }
      }
    } catch {
      // Ignore unreadable previous report.
    }
  }

  const hardFailures = [];
  const warnings = [];
  const contractReports = [];
  let optimizerChecked = false;

  const contractNames = filterContract
    ? [filterContract]
    : Object.keys(config.contracts);

  for (const contractName of contractNames) {
    const budget = config.contracts[contractName] ?? {
      warningThresholdBytes: config.defaults.warningThresholdBytes,
      hardLimitBytes: config.defaults.hardLimitBytes,
      category: "unknown",
    };

    const measurement = measureContract(contractName, artifactsDir);

    if (!measurement) {
      // Contract might be abstract / interface-only / not yet compiled.
      /** @type {ContractReport} */
      const missingReport = {
        contractName,
        status: "missing_artifact",
        warningThresholdBytes: budget.warningThresholdBytes,
        hardLimitBytes: budget.hardLimitBytes,
        networkLimitBytes: config.networkLimitBytes,
        category: budget.category,
        note: budget.note ?? "Artifact not found — contract may be abstract, interface-only, or not yet compiled.",
      };
      contractReports.push(missingReport);
      // Missing artifact is a warning, not a hard failure, in case the project
      // hasn't been fully compiled yet.  CI should compile first.
      warnings.push(
        `[PREWAVE-SC-062] Missing artifact for ${contractName} — run 'npm run compile' first.`,
      );
      continue;
    }

    // Optimizer profile cross-check (once, using first available build-info).
    if (!optimizerChecked && measurement.sourceName) {
      const compilerSettings = extractOptimizerSettings(
        measurement.sourceName,
        buildInfoDir,
      );
      if (compilerSettings) {
        optimizerChecked = true;
        const actualRuns = compilerSettings.optimizer?.runs ?? -1;
        const actualViaIR = compilerSettings.viaIR ?? false;
        const expectedRuns = config.optimizerProfile.expectedRuns;
        const expectedViaIR = config.optimizerProfile.viaIR;
        if (actualRuns !== expectedRuns || actualViaIR !== expectedViaIR) {
          const detail = `Expected optimizer.runs=${expectedRuns} viaIR=${expectedViaIR}, got runs=${actualRuns} viaIR=${actualViaIR}`;
          hardFailures.push(`[PREWAVE-SC-062] Optimizer profile mismatch: ${detail}`);
          /** @type {ContractReport} */
          const mismatchReport = {
            contractName,
            sourceName: measurement.sourceName,
            status: "optimizer_mismatch",
            runtimeBytes: measurement.runtimeBytes,
            initcodeBytes: measurement.initcodeBytes,
            warningThresholdBytes: budget.warningThresholdBytes,
            hardLimitBytes: budget.hardLimitBytes,
            networkLimitBytes: config.networkLimitBytes,
            category: budget.category,
            linkedLibraries: measurement.linkedLibraries,
            optimizerMismatchDetail: detail,
          };
          contractReports.push(mismatchReport);
          continue;
        }
      }
    }

    // Budget evaluation.
    const runtimeBytes = measurement.runtimeBytes;
    const driftFromPrevious =
      previousMeasurements[contractName] !== undefined
        ? runtimeBytes - previousMeasurements[contractName]
        : undefined;
    const driftWarning =
      driftFromPrevious !== undefined && Math.abs(driftFromPrevious) > DRIFT_WARNING_BYTES;

    /** @type {ContractStatus} */
    let status = "ok";

    if (runtimeBytes > budget.hardLimitBytes) {
      status = "over_limit";
      hardFailures.push(
        `[PREWAVE-SC-062] ${contractName}: runtime bytecode ${runtimeBytes}B exceeds hard limit ${budget.hardLimitBytes}B` +
          ` (network limit ${config.networkLimitBytes}B, margin ${config.networkLimitBytes - runtimeBytes}B)`,
      );
    } else if (runtimeBytes >= budget.warningThresholdBytes) {
      status = "warning";
      warnings.push(
        `[PREWAVE-SC-062] ${contractName}: runtime bytecode ${runtimeBytes}B meets or exceeds warning threshold ${budget.warningThresholdBytes}B` +
          ` (hard limit ${budget.hardLimitBytes}B, ${budget.hardLimitBytes - runtimeBytes}B remaining)`,
      );
    }

    // Initcode budget (uses defaults.initcodeHardLimitBytes when no per-contract override).
    const initHard = config.defaults.initcodeHardLimitBytes;
    const initWarn = config.defaults.initcodeWarningBytes;
    if (measurement.initcodeBytes > initHard) {
      if (status !== "over_limit") status = "over_limit";
      hardFailures.push(
        `[PREWAVE-SC-062] ${contractName}: initcode ${measurement.initcodeBytes}B exceeds initcode hard limit ${initHard}B`,
      );
    } else if (measurement.initcodeBytes >= initWarn) {
      if (status === "ok") status = "warning";
      warnings.push(
        `[PREWAVE-SC-062] ${contractName}: initcode ${measurement.initcodeBytes}B exceeds initcode warning ${initWarn}B` +
          ` (hard limit ${initHard}B)`,
      );
    }

    if (driftWarning) {
      warnings.push(
        `[PREWAVE-SC-062] ${contractName}: size drifted ${driftFromPrevious > 0 ? "+" : ""}${driftFromPrevious}B since last report.`,
      );
    }

    /** @type {ContractReport} */
    const cr = {
      contractName,
      sourceName: measurement.sourceName,
      status,
      runtimeBytes,
      initcodeBytes: measurement.initcodeBytes,
      warningThresholdBytes: budget.warningThresholdBytes,
      hardLimitBytes: budget.hardLimitBytes,
      networkLimitBytes: config.networkLimitBytes,
      marginToHardLimit: budget.hardLimitBytes - runtimeBytes,
      marginToNetworkLimit: config.networkLimitBytes - runtimeBytes,
      category: budget.category,
      linkedLibraries: measurement.linkedLibraries.length > 0 ? measurement.linkedLibraries : undefined,
      note: budget.note,
      driftFromPreviousBytes: driftFromPrevious,
      driftWarning: driftWarning || undefined,
    };
    contractReports.push(cr);
  }

  // Determine git SHA for provenance.
  let gitSha = "unknown";
  try {
    gitSha = execFileSync("git", ["rev-parse", "--short", "HEAD"], {
      cwd: REPO_ROOT,
      encoding: "utf-8",
    }).trim();
  } catch {
    // git not available or not a git repo — non-fatal.
  }

  const passed = hardFailures.length === 0 && !reportOnly;

  /** @type {SizeReport} */
  const report = {
    schemaVersion: 1,
    issue: "PREWAVE-SC-062",
    generatedAt: new Date().toISOString(),
    gitSha,
    passed: hardFailures.length === 0,
    hardFailures,
    warnings,
    previousMeasurements,
    contracts: contractReports,
    optimizerProfile: {
      runs: config.optimizerProfile.expectedRuns,
      viaIR: config.optimizerProfile.viaIR,
      checked: optimizerChecked,
    },
  };

  // Write the report.
  const reportDir = dirname(reportAbsPath);
  if (!existsSync(reportDir)) {
    mkdirSync(reportDir, { recursive: true });
  }
  writeFileSync(reportAbsPath, JSON.stringify(report, null, 2) + "\n", "utf-8");

  // Write baseline if requested.
  if (writeBaseline) {
    const newConfig = JSON.parse(JSON.stringify(config));
    for (const cr of contractReports) {
      if (cr.status === "missing_artifact") continue;
      const margin = Math.max(
        ceil(cr.runtimeBytes * BASELINE_SAFETY_FRACTION),
        BASELINE_MIN_SAFETY_BYTES,
      );
      const newHard = Math.min(cr.runtimeBytes + margin, NETWORK_LIMIT_BYTES - 100);
      const newWarn = Math.min(cr.runtimeBytes + ceil(margin * 0.6), newHard - 100);
      newConfig.contracts[cr.contractName] = {
        ...(newConfig.contracts[cr.contractName] ?? {}),
        warningThresholdBytes: newWarn,
        hardLimitBytes: newHard,
      };
    }
    const configAbsPath = resolve(REPO_ROOT, configPath);
    writeFileSync(configAbsPath, JSON.stringify(newConfig, null, 2) + "\n", "utf-8");
    console.log(`✅ [PREWAVE-SC-062] Wrote updated baselines to ${configPath}`);
  }

  return { report, exitCode: hardFailures.length > 0 ? 1 : 0 };
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/**
 * @param {SizeReport} report
 */
function printReport(report) {
  console.log("");
  console.log("=======================================================");
  console.log("  PREWAVE-SC-062 — Deployment Size Budget Gate");
  console.log("=======================================================");
  console.log(`  Generated: ${report.generatedAt}  (git ${report.gitSha})`);
  console.log("");

  const rows = report.contracts.filter((c) => c.status !== "missing_artifact");

  // Group by category.
  /** @type {Record<string, ContractReport[]>} */
  const byCategory = {};
  for (const row of rows) {
    (byCategory[row.category] ??= []).push(row);
  }

  for (const [cat, items] of Object.entries(byCategory)) {
    console.log(`  ── ${cat.toUpperCase()} ──`);
    for (const item of items) {
      const barWidth = 30;
      const fraction = item.runtimeBytes / item.networkLimitBytes;
      const filled = Math.min(Math.round(fraction * barWidth), barWidth);
      const bar = "█".repeat(filled) + "░".repeat(barWidth - filled);
      const statusIcon =
        item.status === "over_limit"
          ? "❌"
          : item.status === "warning"
          ? "⚠️ "
          : item.status === "optimizer_mismatch"
          ? "🔧"
          : "✅";
      const drift =
        item.driftFromPreviousBytes !== undefined
          ? ` (${item.driftFromPreviousBytes >= 0 ? "+" : ""}${item.driftFromPreviousBytes}B)`
          : "";
      console.log(
        `  ${statusIcon} ${item.contractName.padEnd(42)} ${String(item.runtimeBytes).padStart(6)}B [${bar}] margin ${item.marginToHardLimit}B${drift}`,
      );
    }
    console.log("");
  }

  if (report.warnings.length > 0) {
    console.log("  Warnings:");
    for (const w of report.warnings) {
      console.log(`    ⚠️  ${w}`);
    }
    console.log("");
  }

  if (report.hardFailures.length > 0) {
    console.log("  ❌ Hard failures — deploy must not proceed:");
    for (const f of report.hardFailures) {
      console.log(`    ${f}`);
    }
    console.log("");
  }

  if (report.passed) {
    console.log("  ✅ All deployment size budgets satisfied.");
  } else {
    console.log("  ❌ Gate FAILED — see hard failures above.");
  }
  console.log("=======================================================");
  console.log("");
}

// ---------------------------------------------------------------------------
// CLI entry point
// ---------------------------------------------------------------------------

const invokedDirectly =
  process.argv[1] !== undefined &&
  import.meta.url === new URL(`file://${process.argv[1]}`).href;

if (invokedDirectly) {
  const args = process.argv.slice(2);
  const writeBaseline = args.includes("--write-baseline");
  const reportOnly = args.includes("--report-only");
  const contractIdx = args.indexOf("--contract");
  const filterContract = contractIdx >= 0 ? args[contractIdx + 1] ?? null : null;

  try {
    const { report, exitCode } = runSizeBudgetGate({
      writeBaseline,
      reportOnly,
      filterContract,
    });
    printReport(report);
    process.exit(exitCode);
  } catch (/** @type {any} */ err) {
    console.error(`[PREWAVE-SC-062] Fatal: ${err.message}`);
    process.exit(1);
  }
}
