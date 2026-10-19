#!/usr/bin/env node
/**
 * @file check-safe-casts.mjs
 * @description V2-SC-161 — audits every explicit integer-narrowing and signed conversion in the
 *              canonical V2 surface against the committed inventory in
 *              `config/safe-cast-inventory.json`.
 *
 * Solidity's explicit `uintN(x)` conversion silently keeps the low N bits of `x`. The gate
 * therefore requires every narrowing cast site in canonical V2 to be declared with a
 * classification and a justification:
 *
 *   - `proven-safe` — the operand is already bounded below `type(uintN).max` by a prior check,
 *                     a compile-time constant, an enum ordinal, or a same-width byte conversion;
 *                     `bound` states the proof.
 *   - `guarded`     — the cast is the bounded conversion inside `V2SafeCast`, preceded by an
 *                     explicit `value > type(uintN).max` check that reverts `SafeCastOverflow`.
 *
 * The inventory is compared in both directions (undeclared site, occurrence drift, stale entry),
 * the raw narrowing of `block.timestamp` / `block.chainid` is forbidden outright (it must go
 * through `V2SafeCast`), and a set of anchors proves the guarded paths are still wired.
 *
 * Usage:
 *   node scripts/check-safe-casts.mjs           # verify (exit 1 on drift)
 *   node scripts/check-safe-casts.mjs --report  # print the detected cast inventory
 */

import { readdir, readFile } from "node:fs/promises";
import { existsSync, statSync } from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "..");

export const INVENTORY_PATH = resolve(REPO_ROOT, "config", "safe-cast-inventory.json");

/**
 * Canonical V2 scope (directories are scanned recursively). Legacy V1 contracts listed in
 * `contracts/LEGACY_V1.md` (reward/, settlement/, disputes/, non-v2 governance/, root V1
 * contracts, …), mocks, and tests are intentionally out of scope.
 */
export const CANONICAL_SCOPE = [
  "contracts/v2",
  "contracts/governance/v2",
  "contracts/upgrade",
  "contracts/verification",
  "contracts/performance",
  "contracts/libraries",
  "contracts/ClaimRegistry.sol"
];

export const CLASSIFICATIONS = ["proven-safe", "guarded"];

/** Unsigned widths strictly narrower than 256 bits. */
const NARROW_WIDTHS = Array.from({ length: 31 }, (_, i) => (i + 1) * 8);

/**
 * `uintN(` for N < 256 (narrowing) and `intN(` for any N (signed conversion — can change sign
 * or truncate). `type(uint64)` never matches because the type name is followed by `)`.
 */
const CAST_REGEX = new RegExp(
  `\\b(?:(uint)(${NARROW_WIDTHS.join("|")})|(int)(${[...NARROW_WIDTHS, 256].join("|")})?)\\s*\\(`,
  "g"
);

/** Operands whose raw narrowing is forbidden in canonical V2: use V2SafeCast instead. */
export const FORBIDDEN_RAW_OPERANDS = ["block.timestamp", "block.chainid", "block.number"];

/**
 * Blanks Solidity comments and string-literal contents while preserving offsets and lines, so
 * patterns are only matched in code.
 * @param {string} source Solidity source.
 * @returns {string} Source with comments and string contents blanked out.
 */
export function stripCommentsAndStrings(source) {
  let out = "";
  let i = 0;
  const n = source.length;
  const blank = (s) => s.replace(/[^\r\n]/g, " ");
  while (i < n) {
    const c = source[i];
    const next = source[i + 1];
    if (c === "/" && next === "/") {
      let j = i;
      while (j < n && source[j] !== "\n" && source[j] !== "\r") j++;
      out += blank(source.slice(i, j));
      i = j;
    } else if (c === "/" && next === "*") {
      const end = source.indexOf("*/", i + 2);
      const j = end === -1 ? n : end + 2;
      out += blank(source.slice(i, j));
      i = j;
    } else if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < n && source[j] !== c) {
        if (source[j] === "\\") j++;
        j++;
      }
      out += c + blank(source.slice(i + 1, Math.min(j, n))) + (j < n ? c : "");
      i = j + 1;
    } else {
      out += c;
      i++;
    }
  }
  return out;
}

/**
 * Normalizes an expression for fingerprinting (collapses all whitespace).
 * @param {string} text Expression text.
 * @returns {string} Normalized expression.
 */
export function normalizeExpression(text) {
  return text
    .replace(/\s+/g, " ")
    .replace(/\(\s+/g, "(")
    .replace(/\s+\)/g, ")")
    .trim();
}

/**
 * Detects every narrowing / signed cast in a Solidity source.
 * @param {string} source Solidity source.
 * @returns {Array<{expression: string, operand: string, width: number, kind: string, line: number}>}
 */
export function detectCasts(source) {
  const code = stripCommentsAndStrings(source);
  const casts = [];
  CAST_REGEX.lastIndex = 0;
  let match;
  while ((match = CAST_REGEX.exec(code)) !== null) {
    const openIndex = match.index + match[0].length - 1;
    let depth = 0;
    let closeIndex = -1;
    for (let j = openIndex; j < code.length; j++) {
      if (code[j] === "(") depth++;
      else if (code[j] === ")") {
        depth--;
        if (depth === 0) {
          closeIndex = j;
          break;
        }
      }
    }
    if (closeIndex === -1) continue;
    const typeName = code.slice(match.index, openIndex).trim();
    // Use the original source for the operand so string literals remain readable in reports.
    const operand = normalizeExpression(source.slice(openIndex + 1, closeIndex));
    const signed = match[3] === "int";
    const width = signed ? Number(match[4] ?? 256) : Number(match[2]);
    casts.push({
      expression: `${typeName}(${operand})`,
      operand,
      width,
      kind: signed ? "signed" : "narrowing",
      line: code.slice(0, match.index).split(/\r\n|\r|\n/).length
    });
  }
  return casts;
}

async function collectSolidityFiles(path) {
  if (!existsSync(path)) return [];
  if (statSync(path).isFile()) return path.endsWith(".sol") ? [path] : [];
  const results = [];
  for (const entry of await readdir(path, { withFileTypes: true })) {
    const full = resolve(path, entry.name);
    if (entry.isDirectory()) results.push(...(await collectSolidityFiles(full)));
    else if (entry.isFile() && entry.name.endsWith(".sol")) results.push(full);
  }
  return results;
}

/**
 * Builds the detected inventory: fingerprint `file|expression` -> site summary.
 * @param {string} [rootDir] Repository root.
 * @param {string[]} [scope] Scope entries relative to `rootDir`.
 * @returns {Promise<Map<string, {file: string, expression: string, width: number, kind: string, lines: number[], operand: string}>>}
 */
export async function detectInventory(rootDir = REPO_ROOT, scope = CANONICAL_SCOPE) {
  const detected = new Map();
  const files = new Set();
  for (const entry of scope) {
    for (const file of await collectSolidityFiles(resolve(rootDir, entry))) files.add(file);
  }
  for (const file of [...files].sort()) {
    const rel = relative(rootDir, file).split(sep).join("/");
    for (const cast of detectCasts(await readFile(file, "utf8"))) {
      const key = fingerprint(rel, cast.expression);
      const existing = detected.get(key);
      if (existing) existing.lines.push(cast.line);
      else {
        detected.set(key, {
          file: rel,
          expression: cast.expression,
          operand: cast.operand,
          width: cast.width,
          kind: cast.kind,
          lines: [cast.line]
        });
      }
    }
  }
  return detected;
}

/**
 * Stable fingerprint of a cast site.
 * @param {string} file Repo-relative file.
 * @param {string} expression Normalized cast expression.
 * @returns {string} Fingerprint.
 */
export function fingerprint(file, expression) {
  return `${file}|${normalizeExpression(expression)}`;
}

/**
 * Reads the declared inventory.
 * @param {string} [path] Inventory path.
 * @returns {Promise<Map<string, object>>} Declared inventory keyed by fingerprint.
 */
export async function readInventory(path = INVENTORY_PATH) {
  const parsed = JSON.parse(await readFile(path, "utf8"));
  return inventoryFromEntries(parsed.casts ?? []);
}

/**
 * Indexes raw inventory entries by fingerprint.
 * @param {object[]} entries Inventory entries.
 * @returns {Map<string, object>} Declared inventory.
 */
export function inventoryFromEntries(entries) {
  const declared = new Map();
  for (const entry of entries) {
    declared.set(fingerprint(entry.file, entry.expression), { ...entry, occurrences: entry.occurrences ?? 1 });
  }
  return declared;
}

/**
 * Compares the detected inventory against the declared one.
 * @param {Map<string, object>} detected Detected inventory.
 * @param {Map<string, object>} declared Declared inventory.
 * @returns {string[]} Drift description lines (empty when in policy).
 */
export function diffInventory(detected, declared) {
  const problems = [];
  for (const [key, site] of detected) {
    const where = `${site.file}:${site.lines.join(",")}`;
    if (FORBIDDEN_RAW_OPERANDS.includes(site.operand)) {
      problems.push(
        `${where}: raw narrowing \`${site.expression}\` is forbidden — use V2SafeCast (timestamp64/timestamp48/toUintN) so an out-of-range value reverts SafeCastOverflow`
      );
      continue;
    }
    const entry = declared.get(key);
    if (!entry) {
      problems.push(
        `${where}: undeclared ${site.kind} cast \`${site.expression}\` (${site.kind === "signed" ? "int" : "uint"}${site.width}) — guard it with V2SafeCast or add a proven-safe inventory entry with its bound`
      );
      continue;
    }
    if (entry.occurrences !== site.lines.length) {
      problems.push(
        `${where}: \`${site.expression}\` occurs ${site.lines.length} time(s) but the inventory declares ${entry.occurrences}`
      );
    }
    if (entry.width !== site.width) {
      problems.push(`${where}: \`${site.expression}\` has width ${site.width} but the inventory declares ${entry.width}`);
    }
    if (!CLASSIFICATIONS.includes(entry.classification)) {
      problems.push(`${where}: invalid classification "${entry.classification}" (expected ${CLASSIFICATIONS.join(" | ")})`);
    }
    if (!entry.bound || entry.bound.trim().length < 10) {
      problems.push(`${where}: inventory entry for \`${site.expression}\` needs an explicit bound`);
    }
    if (!entry.justification || entry.justification.trim().length < 20) {
      problems.push(`${where}: inventory entry for \`${site.expression}\` needs a meaningful justification`);
    }
    if (entry.classification === "guarded" && !site.file.endsWith("V2SafeCast.sol")) {
      problems.push(
        `${where}: only the bounded conversions inside V2SafeCast may be classified "guarded"; route \`${site.expression}\` through V2SafeCast`
      );
    }
  }
  for (const [key, entry] of declared) {
    if (!detected.has(key)) {
      problems.push(`${entry.file}: inventory entry \`${entry.expression}\` is stale — the cast is no longer present`);
    }
  }
  return problems;
}

/** Guard anchors: the bounded conversions and the wiring of each guarded field must exist. */
export const GUARD_ANCHORS = [
  ...[8, 16, 24, 32, 48, 64, 96, 128].map((w) => ({
    file: "contracts/v2/libraries/V2SafeCast.sol",
    regex: new RegExp(
      `if\\s*\\(\\s*value\\s*>\\s*type\\(uint${w}\\)\\.max\\s*\\)\\s*revert\\s+V2Errors\\.SafeCastOverflow\\(\\s*field\\s*,\\s*value\\s*,\\s*type\\(uint${w}\\)\\.max\\s*\\)\\s*;\\s*return\\s+uint${w}\\(\\s*value\\s*\\)`
    ),
    description: `toUint${w} must check value > type(uint${w}).max before narrowing`
  })),
  {
    file: "contracts/v2/libraries/V2SafeCast.sol",
    regex: /if\s*\(\s*value\s*<\s*0\s*\)\s*revert\s+V2Errors\.SafeCastNegative\(\s*field\s*,\s*value\s*\)/,
    description: "toUint256(int256) must reject negative values"
  },
  {
    file: "contracts/v2/libraries/V2Errors.sol",
    regex: /error\s+SafeCastOverflow\s*\(\s*bytes32\s+field\s*,\s*uint256\s+value\s*,\s*uint256\s+max\s*\)/,
    description: "V2Errors.SafeCastOverflow(bytes32,uint256,uint256) must keep its stable ABI"
  },
  {
    file: "contracts/v2/libraries/V2Errors.sol",
    regex: /error\s+SafeCastNegative\s*\(\s*bytes32\s+field\s*,\s*int256\s+value\s*\)/,
    description: "V2Errors.SafeCastNegative(bytes32,int256) must keep its stable ABI"
  },
  ...[
    ["contracts/v2/Claims.sol", "FIELD_CLAIM_CREATED_AT"],
    ["contracts/v2/Claims.sol", "FIELD_CLAIM_EVENT_TIMESTAMP"],
    ["contracts/v2/EvidenceRegistry.sol", "FIELD_EVIDENCE_COMMITTED_AT"],
    ["contracts/v2/ModuleRegistry.sol", "FIELD_MODULE_CHANGED_AT"],
    ["contracts/v2/ModuleRegistry.sol", "FIELD_MODULE_ACTIVATED_AT"],
    ["contracts/v2/StakeVault.sol", "FIELD_VAULT_EVENT_TIMESTAMP"],
    ["contracts/v2/EmergencyControls.sol", "FIELD_EMERGENCY_EVENT_TIMESTAMP"],
    ["contracts/v2/ConsumerGuaranteesAnchor.sol", "FIELD_GUARANTEES_CHAIN_ID"],
    ["contracts/v2/SupplyChainAttestationAnchor.sol", "FIELD_ATTESTATION_CHAIN_ID"],
    ["contracts/governance/v2/TruthBountyGovernanceToken.sol", "FIELD_GOVERNANCE_CLOCK"],
    ["contracts/libraries/CanonicalEventLibrary.sol", "FIELD_CANONICAL_EVENT_TIMESTAMP"],
    ["contracts/ClaimRegistry.sol", "FIELD_REGISTRY_CREATED_AT"],
    ["contracts/ClaimRegistry.sol", "FIELD_REGISTRY_CANONICAL_CREATED_AT"]
  ].map(([file, field]) => ({
    file,
    regex: new RegExp(`V2SafeCast\\.(?:timestamp64|timestamp48|toUint\\d+)\\([^;]*V2SafeCast\\.${field}\\s*\\)`),
    description: `guarded narrowing for V2SafeCast.${field} must stay wired`
  }))
];

/**
 * Verifies the documented guard anchors are still implemented.
 * @param {string} [rootDir] Repository root.
 * @returns {Promise<string[]>} Missing anchor descriptions.
 */
export async function checkGuardAnchors(rootDir = REPO_ROOT) {
  const missing = [];
  for (const anchor of GUARD_ANCHORS) {
    const file = resolve(rootDir, anchor.file);
    if (!existsSync(file)) {
      missing.push(`${anchor.file}: file is missing (${anchor.description})`);
      continue;
    }
    const code = stripCommentsAndStrings(await readFile(file, "utf8"));
    if (!anchor.regex.test(code)) missing.push(`${anchor.file}: ${anchor.description}`);
  }
  return missing;
}

async function main() {
  const report = process.argv.includes("--report");
  const detected = await detectInventory();

  if (report) {
    for (const site of [...detected.values()]) {
      console.log(`${site.file}:${site.lines.join(",")}  ${site.kind}/${site.width}  ${site.expression}`);
    }
    const total = [...detected.values()].reduce((sum, site) => sum + site.lines.length, 0);
    console.log(`Detected ${total} cast occurrence(s) at ${detected.size} distinct site(s).`);
    process.exit(0);
  }

  console.log("==> Verifying the V2 safe-cast inventory (V2-SC-161)...");
  const declared = await readInventory();
  const problems = [...diffInventory(detected, declared), ...(await checkGuardAnchors())];

  if (problems.length === 0) {
    const total = [...detected.values()].reduce((sum, site) => sum + site.lines.length, 0);
    console.log(
      `✓ ${total} narrowing/signed cast occurrence(s) at ${detected.size} site(s) match the declared inventory and all ${GUARD_ANCHORS.length} guard anchors are present.`
    );
    process.exit(0);
  }

  console.error(`\n❌ Safe-cast inventory drift detected (${problems.length} problem(s)):`);
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(__filename)) {
  main().catch((error) => {
    console.error("Fatal error during safe-cast check:", error);
    process.exit(1);
  });
}
