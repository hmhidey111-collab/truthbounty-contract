#!/usr/bin/env node
/**
 * STAB-SC-006: Toolchain drift gate.
 *
 * Ensures that Solidity and Node versions agree across:
 *   - package.json (dependencies.solc, engines.node)
 *   - foundry.toml (solc)
 *   - hardhat.config.ts (solidity.version)
 *   - scripts/canonicalV2Manifest.ts (solidVersion)
 *   - deployments/releases/v2-sc-129-release-manifest.json (solidityVersion)
 *   - .node-version (if present)
 *
 * Exits non-zero on any drift. Importable for unit tests via exports.
 */

import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..");

/** The single Solidity version this repo ships. */
export const PINNED_SOLIDITY_VERSION = "0.8.28";

/** The single Node major version this repo ships (Hardhat 3 requires Node 22+). */
export const PINNED_NODE_MAJOR = 22;

/**
 * Read and parse a JSON file. Returns null when the file is missing or
 * invalid. This is intentionally forgiving for optional files (e.g. release
 * manifest) so the gate can run in repos that have not yet generated one.
 */
export function readJsonIfExists(path) {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

/** Read a text file if it exists, otherwise null. */
export function readTextIfExists(path) {
  if (!existsSync(path)) return null;
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

/**
 * Extract the solidity version from a Hardhat config source text.
 * Supports both the string and object forms of the `solidity` field.
 */
export function extractHardhatSolidityVersion(source) {
  if (typeof source !== "string") return null;
  // Object form: solidity: { version: "0.8.28" }
  const objectMatch = source.match(/solidity\s*:\s*{[\s\S]*?version\s*:\s*"\+?([0-9.]+)"/);
  if (objectMatch) return objectMatch[1];
  // String form: solidity: "0.8.28"
  const stringMatch = source.match(/solidity\s*:\s*"\+?([0-9.]+)"/);
  return stringMatch ? stringMatch[1] : null;
}

/** Extract the solc version from foundry.toml text. */
export function extractFoundrySolcVersion(source) {
  if (typeof source !== "string") return null;
  const m = source.match(/^\s*solc\s*=\s*"\+?([0-9.]+)"/m);
  return m ? m[1] : null;
}

/** Extract the solidVersion field from a TS source text. */
export function extractSolidVersionField(source) {
  if (typeof source !== "string") return null;
  const m = source.match(/solidVersion\s*:\s*"\+?([0-9.]+)"/);
  return m ? m[1] : null;
}

/**
 * Parse the major version from a Node engines range string.
 * Handles forms like ">=22.0.0 <23.0.0", ">=22", "22.x", "^22.0.0".
 */
export function parseNodeEnginesMajor(range) {
  if (typeof range !== "string") return null;
  // Prefer the lower bound of a range.
  const lower = range.match(/>=?\s*v?(\d+)/);
  if (lower) return Number(lower[1]);
  const caret = range.match(/^\s*\?\s*v?(\d+)/);
  if (caret) return Number(caret[1]);
  return null;
}

/**
 * Validate toolchain pins across the repo. Returns a structured report.
 */
export function validateToolchainDrift(opts = {}) {
  const repoRoot = opts.repoRoot ?? REPO_ROOT;
  const errors = [];
  const warnings = [];
  const observed = { solidity: {}, node: {} };

  // ----- Solidity -----
  const packageJson = readJsonIfExists(resolve(repoRoot, "package.json"));
  if (!packageJson) {
    errors.push("Could not read package.json.");
  } else {
    const solc = packageJson.dependencies?.solc ?? packageJson.devDependencies?.solc;
    if (!solc) {
      errors.push("package.json does not pin solc.");
    } else {
      observed.solidity["package.json"] = solc;
    }
  }

  const foundryToml = readTextIfExists(resolve(repoRoot, "foundry.toml"));
  if (foundryToml === null) {
    errors.push("Could not read foundry.toml.");
  } else {
    const v = extractFoundrySolcVersion(foundryToml);
    if (!v) errors.push("foundry.toml does not pin solc.");
    else observed.solidity["foundry.toml"] = v;
  }

  const hardhatConfig = readTextIfExists(resolve(repoRoot, "hardhat.config.ts"));
  if (hardhatConfig === null) {
    errors.push("Could not read hardhat.config.ts.");
  } else {
    const v = extractHardhatSolidityVersion(hardhatConfig);
    if (!v) errors.push("hardhat.config.ts does not pin a solidity version.");
    else observed.solidity["hardhat.config.ts"] = v;
  }

  const canonicalManifestSrc = readTextIfExists(resolve(repoRoot, "scripts/canonicalV2Manifest.ts"));
  if (canonicalManifestSrc !== null) {
    const v = extractSolidVersionField(canonicalManifestSrc);
    if (!v) warnings.push("scripts/canonicalV2Manifest.ts does not declare solidVersion.");
    else observed.solidity["scripts/canonicalV2Manifest.ts"] = v;
  }

  const releaseManifest = readJsonIfExists(
    resolve(repoRoot, "deployments/releases/v2-sc-129-release-manifest.json"),
  );
  if (releaseManifest) {
    const v = releaseManifest.solidityVersion ?? releaseManifest.compiler?.version;
    if (!v) warnings.push("release manifest does not declare solidityVersion.");
    else observed.solidity["deployments/releases/v2-sc-129-release-manifest.json"] = String(v);
  }

  // Compare all observed Solidity versions against the pin.
  for (const [source, version] of Object.entries(observed.solidity)) {
    if (version !== PINNED_SOLIDITY_VERSION) {
      errors.push(
        `Solidity version drift in ${source}: found "${version}", expected "${PINNED_SOLIDITY_VERSION}".`,
      );
    }
  }

  // ----- Node -----
  if (packageJson) {
    const nodeRange = packageJson.engines?.node;
    if (!nodeRange) {
      errors.push("package.json does not declare engines.node.");
    } else {
      const major = parseNodeEnginesMajor(nodeRange);
      if (major === null) {
        errors.push(`Could not parse engines.node range "${nodeRange}".`);
      } else {
        observed.node["package.json"] = major;
      }
    }
  }

  const nodeVersionFile = readTextIfExists(resolve(repoRoot, ".node-version"));
  if (nodeVersionFile !== null) {
    const trimmed = nodeVersionFile.trim().replace(/^v/, "");
    const major = Number(trimmed.split(".")[0]);
    if (!Number.isFinite(major)) {
      errors.push(`.node-version contains an invalid version "${trimmed}".`);
    } else {
      observed.node[".node-version"] = major;
    }
  }

  for (const [source, major] of Object.entries(observed.node)) {
    if (major !== PINNED_NODE_MAJOR) {
      errors.push(
        `Node version drift in ${source}: found major ${major}, expected major ${PINNED_NODE_MAJOR}.`,
      );
    }
  }

  return { ok: errors.length === 0, errors, warnings, observed };
}

/** CLI entrypoint. */
function main() {
  const jsonOut = process.argv.includes("--json");
  const report = validateToolchainDrift();

  if (jsonOut) {
    process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  } else {
    if (report.ok) {
      console.log(
        `[check-toolchain-drift] Toolchain pins OK. Solidity ${PINNED_SOLIDITY_VERSION}, Node major ${PINNED_NODE_MAJOR}.`,
      );
    } else {
      console.error(`[check-toolchain-drift] Found ${report.errors.length} error(s):`);
      for (const e of report.errors) console.error(`  - ${e}`);
    }
    for (const w of report.warnings) console.warn(`  warning: ${w}`);
  }

  process.exitCode = report.ok ? 0 : 1;
}

const isMainModule = process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMainModule) main();
