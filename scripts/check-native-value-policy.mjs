#!/usr/bin/env node
/**
 * @file check-native-value-policy.mjs
 * @description V2-SC-153 — enforces the repository-wide native-value policy.
 *
 * TruthBounty V2 accounting is token-denominated. Every contract in `contracts/` (and
 * `contracts-vrm/`) must therefore either be free of native-value surfaces or be listed in
 * `scripts/native-value-policy.json` with a rationale. The inventory is checked in both
 * directions so that a new payable/receive/fallback surface, a new `msg.value` read, a new
 * `address(this).balance` read, or a new `selfdestruct` reference cannot land unnoticed, and so
 * that a stale inventory entry is reported as drift instead of silently passing.
 *
 * Usage:
 *   node scripts/check-native-value-policy.mjs           # verify (exit 1 on drift)
 *   node scripts/check-native-value-policy.mjs --report  # print the detected inventory
 */

import { readdir, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "..");

export const CONTRACT_ROOTS = ["contracts", "contracts-vrm"];
export const INVENTORY_PATH = resolve(REPO_ROOT, "scripts", "native-value-policy.json");

/** Native-value surfaces the policy tracks, in a stable report order. */
export const NATIVE_SURFACE_PATTERNS = [
  { id: "receive", regex: /(^|\s)receive\s*\(/m },
  { id: "fallback", regex: /(^|\s)fallback\s*\(/m },
  { id: "payable", regex: /\bpayable\b/ },
  { id: "msg.value", regex: /\bmsg\s*\.\s*value\b/ },
  { id: "nativeBalance", regex: /address\s*\(\s*this\s*\)\s*\.balance/ },
  { id: "selfdestruct", regex: /\bselfdestruct\s*\(/ }
];

/**
 * Strips Solidity comments while preserving line positions, so patterns are only matched in code.
 * @param {string} source Solidity source.
 * @returns {string} Source with comments blanked out.
 */
export function stripComments(source) {
  const withoutBlocks = source.replace(/\/\*[\s\S]*?\*\//g, (match) => match.replace(/[^\r\n]/g, " "));
  return withoutBlocks.replace(/\/\/[^\r\n]*/g, (match) => " ".repeat(match.length));
}

/**
 * Detects the native-value surfaces present in a Solidity source file.
 * @param {string} source Solidity source.
 * @returns {string[]} Sorted surface ids.
 */
export function detectSurfaces(source) {
  const code = stripComments(source);
  return NATIVE_SURFACE_PATTERNS.filter(({ regex }) => regex.test(code)).map(({ id }) => id);
}

/**
 * Recursively collects Solidity files under a directory.
 * @param {string} dir Absolute directory.
 * @returns {Promise<string[]>} Absolute file paths.
 */
async function findSolidityFiles(dir) {
  if (!existsSync(dir)) return [];
  const entries = await readdir(dir, { withFileTypes: true });
  const results = [];
  for (const entry of entries) {
    const full = resolve(dir, entry.name);
    if (entry.isDirectory()) results.push(...(await findSolidityFiles(full)));
    else if (entry.isFile() && entry.name.endsWith(".sol")) results.push(full);
  }
  return results;
}

/**
 * Builds the detected inventory (repo-relative path -> sorted surface ids).
 * @param {string} [rootDir] Repository root.
 * @returns {Promise<Map<string, string[]>>} Detected inventory.
 */
export async function detectInventory(rootDir = REPO_ROOT) {
  const detected = new Map();
  for (const root of CONTRACT_ROOTS) {
    for (const file of await findSolidityFiles(resolve(rootDir, root))) {
      const surfaces = detectSurfaces(await readFile(file, "utf8"));
      if (surfaces.length > 0) detected.set(relative(rootDir, file).split(sep).join("/"), surfaces);
    }
  }
  return detected;
}

/**
 * Reads the declared inventory.
 * @param {string} [path] Inventory path.
 * @returns {Promise<Map<string, {surfaces: string[], rationale: string}>>} Declared inventory.
 */
export async function readInventory(path = INVENTORY_PATH) {
  const parsed = JSON.parse(await readFile(path, "utf8"));
  const declared = new Map();
  for (const entry of parsed.nativeValueSurfaces ?? []) {
    declared.set(entry.file, { surfaces: [...entry.surfaces].sort(), rationale: entry.rationale });
  }
  return declared;
}

/**
 * Compares the detected inventory against the declared one.
 * @param {Map<string, string[]>} detected Detected inventory.
 * @param {Map<string, {surfaces: string[], rationale: string}>} declared Declared inventory.
 * @returns {string[]} Drift description lines (empty when in policy).
 */
export function diffInventory(detected, declared) {
  const problems = [];
  for (const [file, surfaces] of detected) {
    const entry = declared.get(file);
    if (!entry) {
      problems.push(`${file}: undeclared native-value surface(s) [${surfaces.join(", ")}] — add an inventory entry with a rationale or remove the surface`);
      continue;
    }
    const missing = surfaces.filter((s) => !entry.surfaces.includes(s));
    if (missing.length > 0) problems.push(`${file}: declared surfaces do not cover [${missing.join(", ")}]`);
    if (!entry.rationale || entry.rationale.trim().length < 20) {
      problems.push(`${file}: inventory entry needs a meaningful rationale`);
    }
  }
  for (const [file, entry] of declared) {
    if (!detected.has(file)) {
      problems.push(`${file}: inventory entry is stale — no native-value surface detected (declared [${entry.surfaces.join(", ")}])`);
      continue;
    }
    const stale = entry.surfaces.filter((s) => !detected.get(file).includes(s));
    if (stale.length > 0) problems.push(`${file}: inventory lists surface(s) no longer present [${stale.join(", ")}]`);
  }
  return problems;
}

/** Policy anchors: the canonical rejection must exist exactly where the policy documents it. */
export const POLICY_ANCHORS = [
  {
    file: "contracts/governance/v2/TruthBountyGovernor.sol",
    regex: /receive\s*\(\s*\)\s*external\s+payable[^{]*\{[^}]*revert\s+UnexpectedNativeValue\s*\(\s*msg\.value\s*\)/s,
    description: "governor receive() must revert with UnexpectedNativeValue(msg.value)"
  },
  {
    file: "contracts/governance/v2/TruthBountyGovernor.sol",
    regex: /execute\s*\(\s*uint256\s+proposalId\s*\)\s*public\s+payable\s+override\s*\{[^}]*_rejectNativeValue\s*\(\s*\)/s,
    description: "execute(uint256) must reject attached native value"
  },
  {
    file: "contracts/governance/v2/TruthBountyGovernor.sol",
    regex: /NativeValueProposalNotAllowed\s*\(\s*i\s*,\s*values\s*\[\s*i\s*\]\s*\)/s,
    description: "proposal values must be validated as native-value free"
  },
  {
    file: "contracts/upgrade/TimelockOwnedProxyAdmin.sol",
    regex: /if\s*\(\s*msg\.value\s*!=\s*0\s*\)\s*revert\s+UnexpectedNativeValue\s*\(\s*msg\.value\s*\)/s,
    description: "upgrade path must reject attached native value"
  }
];

/**
 * Verifies the documented rejection anchors are still implemented.
 * @param {string} [rootDir] Repository root.
 * @returns {Promise<string[]>} Missing anchor descriptions.
 */
export async function checkPolicyAnchors(rootDir = REPO_ROOT) {
  const missing = [];
  for (const anchor of POLICY_ANCHORS) {
    const file = resolve(rootDir, anchor.file);
    if (!existsSync(file)) {
      missing.push(`${anchor.file}: file is missing (${anchor.description})`);
      continue;
    }
    if (!anchor.regex.test(await readFile(file, "utf8"))) {
      missing.push(`${anchor.file}: ${anchor.description}`);
    }
  }
  return missing;
}

async function main() {
  const report = process.argv.includes("--report");
  const detected = await detectInventory();

  if (report) {
    for (const [file, surfaces] of [...detected].sort()) {
      console.log(`${file}: [${surfaces.join(", ")}]`);
    }
    console.log(`Detected ${detected.size} contract(s) with native-value surfaces.`);
    process.exit(0);
  }

  console.log("==> Verifying the V2 native-value policy (V2-SC-153)...");
  const declared = await readInventory();
  const problems = [...diffInventory(detected, declared), ...(await checkPolicyAnchors())];

  if (problems.length === 0) {
    console.log(`✓ ${detected.size} native-value contract file(s) match the declared inventory and all rejection anchors are present.`);
    process.exit(0);
  }

  console.error(`\n❌ Native-value policy drift detected (${problems.length} problem(s)):`);
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(__filename)) {
  main().catch((error) => {
    console.error("Fatal error during native-value policy check:", error);
    process.exit(1);
  });
}
