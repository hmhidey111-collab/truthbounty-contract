#!/usr/bin/env node
/**
 * @file check-pause-matrix.mjs
 * @description V2-SC-162 — enforces the versioned emergency pause matrix.
 *
 * `config/pause-matrix.json` classifies every external / public state-mutating function on the
 * canonical V2 modules as RISK_INCREASING, NEUTRAL, or RISK_REDUCING and names the gates each one
 * must carry. This checker fails CI when:
 *
 *   - a module source declares an operation the matrix does not classify (or the matrix lists an
 *     operation the source no longer has);
 *   - the gates used in source disagree with the matrix — e.g. a risk-increasing operation without
 *     its scope gate, or a risk-reducing exit guarded by a scoped or module-local pause;
 *   - the Solidity mirror (`contracts/v2/libraries/PauseMatrix.sol`) disagrees with the JSON matrix;
 *   - `PAUSE_MATRIX_VERSION`, `matrixVersion`, and the latest `history` entry disagree, or the matrix
 *     content changed without a new history entry (digest drift);
 *   - a top-level `contracts/v2/*.sol` file is neither a classified module nor an explicit exclusion;
 *   - the fail-closed / fail-open / write-once anchors in `V2PauseGuard.sol` are missing.
 *
 * Usage:
 *   node scripts/check-pause-matrix.mjs            # verify (exit 1 on drift)
 *   node scripts/check-pause-matrix.mjs --report   # print detected operations and the digest
 */

import { readdir, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "..");

export const MATRIX_PATH = resolve(REPO_ROOT, "config", "pause-matrix.json");
export const MODULE_DIRECTORY = "contracts/v2";

export const CLASSES = ["RISK_INCREASING", "NEUTRAL", "RISK_REDUCING"];
export const EXIT_GATE = "EXIT_SHUTDOWN_ONLY";
export const SCOPE_GATES = [
  "SCOPE_CLAIMS",
  "SCOPE_EVIDENCE",
  "SCOPE_STAKING",
  "SCOPE_VERIFICATION",
  "SCOPE_SETTLEMENT",
  "SCOPE_TREASURY",
  "SCOPE_DISPUTES",
  "SCOPE_GOVERNANCE"
];

const SCOPE_GATE_RE = /\b(?:whenScopeNotPaused|_requireScopeNotPaused)\s*\(\s*PauseMatrix\s*\.\s*(SCOPE_[A-Z_]+)\s*\)/g;
const ANY_SCOPE_GATE_RE = /\b(?:whenScopeNotPaused|_requireScopeNotPaused)\s*\(/g;
const EXIT_GATE_RE = /\bwhenExitsNotShutdown\b|\b_requireExitsNotShutdown\s*\(\s*\)/;
const LOCAL_PAUSE_RE = /\bwhenNotPaused\b/;

// ---------------------------------------------------------------------------------------------
// Source sanitation and parsing
// ---------------------------------------------------------------------------------------------

/**
 * Single-pass Solidity sanitizer. Comments become spaces (newlines preserved); string literal
 * contents are blanked unless `keepStrings` is set, so braces or `//` inside strings never
 * confuse the structural parser.
 * @param {string} source Solidity source.
 * @param {{keepStrings?: boolean}} [options]
 * @returns {string} Sanitized source with identical length and line structure.
 */
export function sanitize(source, { keepStrings = false } = {}) {
  let out = "";
  let i = 0;
  const n = source.length;
  while (i < n) {
    const ch = source[i];
    const next = source[i + 1];
    if (ch === "/" && next === "/") {
      while (i < n && source[i] !== "\n" && source[i] !== "\r") {
        out += " ";
        i++;
      }
      continue;
    }
    if (ch === "/" && next === "*") {
      out += "  ";
      i += 2;
      while (i < n && !(source[i] === "*" && source[i + 1] === "/")) {
        out += source[i] === "\n" || source[i] === "\r" ? source[i] : " ";
        i++;
      }
      if (i < n) {
        out += "  ";
        i += 2;
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      const quote = ch;
      out += quote;
      i++;
      while (i < n && source[i] !== quote) {
        if (source[i] === "\\" && i + 1 < n) {
          out += keepStrings ? source[i] + source[i + 1] : "  ";
          i += 2;
          continue;
        }
        out += keepStrings ? source[i] : " ";
        i++;
      }
      if (i < n) {
        out += quote;
        i++;
      }
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}

/**
 * Returns the index of the delimiter that closes the one at `openIndex`, or -1.
 * @param {string} code Sanitized source.
 * @param {number} openIndex Index of the opening delimiter.
 * @param {string} open Opening character.
 * @param {string} close Closing character.
 * @returns {number}
 */
export function matchDelimiter(code, openIndex, open, close) {
  let depth = 0;
  for (let i = openIndex; i < code.length; i++) {
    if (code[i] === open) depth++;
    else if (code[i] === close) {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/**
 * Converts a parameter list into source-level types (data locations and names dropped).
 * @param {string} paramText Text between the parameter parentheses.
 * @returns {string[]} Parameter types in order.
 */
export function normalizeParams(paramText) {
  const params = [];
  let depth = 0;
  let current = "";
  for (const ch of paramText) {
    if (ch === "(" || ch === "[") depth++;
    if (ch === ")" || ch === "]") depth--;
    if (ch === "," && depth === 0) {
      params.push(current);
      current = "";
      continue;
    }
    current += ch;
  }
  params.push(current);
  return params
    .map((p) => p.trim())
    .filter((p) => p.length > 0)
    .map((p) => p.split(/\s+/)[0].replace(/\s+/g, ""));
}

/**
 * Detects the gates referenced in a piece of code.
 * @param {string} text Header and/or body text (sanitized).
 * @returns {{scopes: string[], exitGate: boolean, unresolvedScopeGates: number}}
 */
export function detectGates(text) {
  const scopes = new Set();
  let resolved = 0;
  for (const match of text.matchAll(SCOPE_GATE_RE)) {
    scopes.add(match[1]);
    resolved++;
  }
  const total = [...text.matchAll(ANY_SCOPE_GATE_RE)].length;
  return { scopes: [...scopes].sort(), exitGate: EXIT_GATE_RE.test(text), unresolvedScopeGates: total - resolved };
}

/**
 * Extracts external/public, non-view, non-pure functions that have a body.
 * @param {string} source Solidity source.
 * @returns {Array<{name: string, signature: string, header: string, body: string, scopes: string[],
 *   exitGate: boolean, localPause: boolean, unresolvedScopeGates: number}>}
 */
export function extractOperations(source) {
  const code = sanitize(source);
  const operations = [];
  const fnRe = /\bfunction\s+([A-Za-z_$][\w$]*)\s*\(/g;
  let match;
  while ((match = fnRe.exec(code)) !== null) {
    const name = match[1];
    const openParen = match.index + match[0].length - 1;
    const closeParen = matchDelimiter(code, openParen, "(", ")");
    if (closeParen < 0) break;

    let end = closeParen + 1;
    let depth = 0;
    for (; end < code.length; end++) {
      const ch = code[end];
      if (ch === "(") depth++;
      else if (ch === ")") depth--;
      else if (depth === 0 && (ch === "{" || ch === ";")) break;
    }
    const header = code.slice(closeParen + 1, end);
    if (code[end] !== "{") {
      fnRe.lastIndex = end + 1;
      continue;
    }
    const closeBrace = matchDelimiter(code, end, "{", "}");
    if (closeBrace < 0) break;
    const body = code.slice(end + 1, closeBrace);
    fnRe.lastIndex = closeBrace + 1;

    const headerWithoutReturns = stripReturns(header);
    if (!/\b(?:external|public)\b/.test(headerWithoutReturns)) continue;
    if (/\b(?:view|pure)\b/.test(headerWithoutReturns)) continue;

    const signature = `${name}(${normalizeParams(code.slice(openParen + 1, closeParen)).join(",")})`;
    const gates = detectGates(`${headerWithoutReturns}\n${body}`);
    operations.push({
      name,
      signature,
      header: headerWithoutReturns,
      body,
      scopes: gates.scopes,
      exitGate: gates.exitGate,
      localPause: LOCAL_PAUSE_RE.test(headerWithoutReturns),
      unresolvedScopeGates: gates.unresolvedScopeGates
    });
  }
  return operations;
}

function stripReturns(header) {
  const m = /\breturns\s*\(/.exec(header);
  if (!m) return header;
  const open = m.index + m[0].length - 1;
  const close = matchDelimiter(header, open, "(", ")");
  if (close < 0) return header;
  return header.slice(0, m.index) + " ".repeat(close + 1 - m.index) + header.slice(close + 1);
}

/**
 * Parses the Solidity mirror entries of `PauseMatrix.classify`.
 * @param {string} source PauseMatrix.sol source.
 * @returns {Map<string, {class: string, gates: string[]}>} Keyed by `Module|signature`.
 */
export function parseMirror(source) {
  const code = sanitize(source, { keepStrings: true });
  const entryRe =
    /if\s*\(\s*k\s*==\s*_key\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)\s*\)\s*return\s*\(\s*RiskClass\.([A-Z_]+)\s*,\s*([A-Z_]+)\s*,\s*([A-Z_]+)\s*\)\s*;/g;
  const entries = new Map();
  for (const m of code.matchAll(entryRe)) {
    const key = `${m[1]}|${m[2]}`;
    const gates = [m[4], m[5]].filter((g) => g !== "NO_GATE").sort();
    if (entries.has(key)) entries.set(key, { class: "DUPLICATE", gates });
    else entries.set(key, { class: m[3], gates });
  }
  return entries;
}

/**
 * Reads `PAUSE_MATRIX_VERSION` from the Solidity mirror.
 * @param {string} source PauseMatrix.sol source.
 * @returns {number|null}
 */
export function parseSolidityVersion(source) {
  const m = /PAUSE_MATRIX_VERSION\s*=\s*(\d+)\s*;/.exec(sanitize(source));
  return m ? Number(m[1]) : null;
}

// ---------------------------------------------------------------------------------------------
// Matrix semantics
// ---------------------------------------------------------------------------------------------

/**
 * Full gate set of a matrix operation (unconditional + conditional), sorted.
 * @param {{gates?: string[], conditionalGates?: string[]}} op
 * @returns {string[]}
 */
export function gateSet(op) {
  return [...new Set([...(op.gates ?? []), ...(op.conditionalGates ?? [])])].sort();
}

/**
 * Canonical digest lines: `Module|signature|CLASS|gate,gate` sorted.
 * @param {object} matrix Parsed matrix.
 * @returns {string[]}
 */
export function canonicalLines(matrix) {
  const lines = [];
  for (const module of matrix.modules ?? []) {
    for (const op of module.operations ?? []) {
      lines.push(`${module.name}|${op.signature}|${op.class}|${gateSet(op).join(",")}`);
    }
  }
  return lines.sort();
}

/**
 * Content digest of the classification (`sha256:<hex>`).
 * @param {object} matrix Parsed matrix.
 * @returns {string}
 */
export function computeDigest(matrix) {
  return `sha256:${createHash("sha256").update(canonicalLines(matrix).join("\n")).digest("hex")}`;
}

/**
 * Structural validation of the matrix itself (independent of any source).
 * @param {object} matrix Parsed matrix.
 * @returns {string[]} Problems.
 */
export function validateMatrixShape(matrix) {
  const problems = [];
  if (matrix.schemaVersion !== 1) problems.push(`schemaVersion must be 1 (found ${matrix.schemaVersion})`);
  if (!Number.isInteger(matrix.matrixVersion) || matrix.matrixVersion < 1) {
    problems.push(`matrixVersion must be a positive integer (found ${matrix.matrixVersion})`);
  }
  const names = new Set();
  const files = new Set();
  for (const module of matrix.modules ?? []) {
    if (names.has(module.name)) problems.push(`duplicate module name ${module.name}`);
    if (files.has(module.file)) problems.push(`duplicate module file ${module.file}`);
    names.add(module.name);
    files.add(module.file);
    if (!["registry", "wired", "none"].includes(module.authority)) {
      problems.push(`${module.name}: authority must be registry | wired | none (found ${module.authority})`);
    }
    const signatures = new Set();
    for (const op of module.operations ?? []) {
      const where = `${module.name}.${op.signature}`;
      if (signatures.has(op.signature)) problems.push(`${where}: duplicate operation`);
      signatures.add(op.signature);
      if (!CLASSES.includes(op.class)) problems.push(`${where}: unknown class ${op.class}`);
      if (!op.rationale || op.rationale.trim().length < 20) problems.push(`${where}: needs a meaningful rationale`);
      const gates = op.gates ?? [];
      const conditional = op.conditionalGates ?? [];
      for (const gate of gates) {
        if (gate !== EXIT_GATE && !SCOPE_GATES.includes(gate)) problems.push(`${where}: unknown gate ${gate}`);
      }
      for (const gate of conditional) {
        if (!SCOPE_GATES.includes(gate)) problems.push(`${where}: conditionalGates may only name SCOPE_* gates (found ${gate})`);
      }
      const scopes = gateSet(op).filter((g) => g !== EXIT_GATE);
      if (op.class === "RISK_INCREASING") {
        if (scopes.length === 0) problems.push(`${where}: RISK_INCREASING operation must fail closed on at least one scope`);
        if (gates.includes(EXIT_GATE)) problems.push(`${where}: RISK_INCREASING operation cannot use the exit gate`);
      } else if (op.class === "RISK_REDUCING") {
        if (gates.some((g) => g !== EXIT_GATE)) {
          problems.push(`${where}: RISK_REDUCING operation must not be unconditionally scope-gated`);
        }
        if (op.localPause) problems.push(`${where}: RISK_REDUCING operation must not sit behind a local pause`);
      } else if (op.class === "NEUTRAL") {
        if (gateSet(op).length > 0) problems.push(`${where}: NEUTRAL operation must not be gated`);
        if (op.localPause) problems.push(`${where}: NEUTRAL operation must not sit behind a local pause`);
      }
    }
    for (const op of module.inheritedOperations ?? []) {
      if (!CLASSES.includes(op.class)) problems.push(`${module.name}.${op.signature} (inherited): unknown class ${op.class}`);
      if (!op.rationale || op.rationale.trim().length < 20) {
        problems.push(`${module.name}.${op.signature} (inherited): needs a meaningful rationale`);
      }
    }
  }
  for (const entry of matrix.excluded ?? []) {
    if (files.has(entry.file)) problems.push(`${entry.file}: listed both as module and as exclusion`);
    if (!entry.rationale || entry.rationale.trim().length < 20) problems.push(`${entry.file}: exclusion needs a meaningful rationale`);
  }
  return problems;
}

/**
 * Compares one module's source against its matrix entry.
 * @param {object} module Matrix module entry.
 * @param {string} source Module Solidity source.
 * @returns {string[]} Problems.
 */
export function checkModule(module, source) {
  const problems = [];
  const detected = new Map();
  for (const op of extractOperations(source)) {
    if (detected.has(op.signature)) problems.push(`${module.name}: operation ${op.signature} is declared more than once`);
    detected.set(op.signature, op);
  }
  const declared = new Map((module.operations ?? []).map((op) => [op.signature, op]));

  for (const [signature] of detected) {
    if (!declared.has(signature)) {
      problems.push(`${module.name}: unclassified operation ${signature} — add it to config/pause-matrix.json and PauseMatrix.sol`);
    }
  }
  for (const [signature] of declared) {
    if (!detected.has(signature)) problems.push(`${module.name}: stale matrix entry ${signature} — no such operation in ${module.file}`);
  }

  let anyGate = false;
  for (const [signature, entry] of declared) {
    const op = detected.get(signature);
    if (!op) continue;
    const where = `${module.name}.${signature}`;
    if (op.unresolvedScopeGates > 0) problems.push(`${where}: scope gate must name a PauseMatrix.SCOPE_* constant`);

    let scopes = new Set(op.scopes);
    let exitGate = op.exitGate;
    let localPause = op.localPause;
    if (entry.gatedVia) {
      const target = detected.get(entry.gatedVia);
      const targetName = entry.gatedVia.split("(")[0];
      if (!target) {
        problems.push(`${where}: gatedVia target ${entry.gatedVia} does not exist`);
      } else if (!new RegExp(`\\b${targetName}\\s*\\(`).test(op.body)) {
        problems.push(`${where}: gatedVia target ${entry.gatedVia} is never called`);
      } else {
        target.scopes.forEach((s) => scopes.add(s));
        exitGate = exitGate || target.exitGate;
        localPause = localPause || target.localPause;
      }
    }

    const expectedScopes = gateSet(entry).filter((g) => g !== EXIT_GATE);
    const foundScopes = [...scopes].sort();
    for (const scope of expectedScopes) {
      if (!scopes.has(scope)) {
        problems.push(
          entry.class === "RISK_INCREASING"
            ? `${where}: RISK_INCREASING operation is missing its fail-closed gate PauseMatrix.${scope}`
            : `${where}: expected gate PauseMatrix.${scope} is missing`
        );
      }
    }
    for (const scope of foundScopes) {
      if (!expectedScopes.includes(scope)) {
        problems.push(
          entry.class === "RISK_REDUCING"
            ? `${where}: RISK_REDUCING exit is guarded by scope pause PauseMatrix.${scope} — exits must stay live under scoped pauses`
            : `${where}: unexpected gate PauseMatrix.${scope} not declared in the matrix`
        );
      }
    }

    const expectExit = (entry.gates ?? []).includes(EXIT_GATE);
    if (expectExit && !exitGate) problems.push(`${where}: value exit is missing _requireExitsNotShutdown()`);
    if (!expectExit && exitGate) problems.push(`${where}: _requireExitsNotShutdown() used but the matrix does not declare ${EXIT_GATE}`);

    const expectLocal = entry.localPause === true;
    if (localPause && !expectLocal) {
      problems.push(
        entry.class === "RISK_REDUCING"
          ? `${where}: RISK_REDUCING exit is guarded by a local whenNotPaused modifier`
          : `${where}: whenNotPaused used but the matrix does not declare localPause`
      );
    }
    if (!localPause && expectLocal) problems.push(`${where}: matrix declares localPause but whenNotPaused is missing`);

    if (foundScopes.length > 0 || exitGate) anyGate = true;
  }

  const code = sanitize(source);
  if (module.authority === "registry") {
    if (!/\bV2PauseGuard\b/.test(code)) problems.push(`${module.name}: registry-resolved module must inherit V2PauseGuard`);
    if (!/\b_registryPauseAuthority\s*\(/.test(code)) {
      problems.push(`${module.name}: registry-resolved module must resolve its authority via _registryPauseAuthority`);
    }
  } else if (module.authority === "wired") {
    if (!/\bV2WiredPauseGuard\b/.test(code)) problems.push(`${module.name}: wired module must inherit V2WiredPauseGuard`);
    const wiring = declared.get("setPauseAuthority(address)");
    if (!wiring || wiring.class !== "NEUTRAL") {
      problems.push(`${module.name}: wired module must expose setPauseAuthority(address) classified NEUTRAL`);
    }
  } else if (module.authority === "none" && anyGate) {
    problems.push(`${module.name}: authority "none" but the source uses pause gates`);
  }
  return problems;
}

/**
 * Compares the Solidity mirror against the JSON matrix.
 * @param {object} matrix Parsed matrix.
 * @param {Map<string, {class: string, gates: string[]}>} mirror Parsed mirror.
 * @returns {string[]} Problems.
 */
export function checkMirror(matrix, mirror) {
  const problems = [];
  const expected = new Map();
  for (const module of matrix.modules ?? []) {
    for (const op of module.operations ?? []) {
      expected.set(`${module.name}|${op.signature}`, { class: op.class, gates: gateSet(op) });
    }
  }
  for (const [key, want] of expected) {
    const got = mirror.get(key);
    if (!got) {
      problems.push(`PauseMatrix.sol: missing mirror entry for ${key}`);
      continue;
    }
    if (got.class !== want.class) problems.push(`PauseMatrix.sol: ${key} class ${got.class} != matrix ${want.class}`);
    if (got.gates.join(",") !== want.gates.join(",")) {
      problems.push(`PauseMatrix.sol: ${key} gates [${got.gates.join(", ")}] != matrix [${want.gates.join(", ")}]`);
    }
  }
  for (const key of mirror.keys()) {
    if (!expected.has(key)) problems.push(`PauseMatrix.sol: mirror entry ${key} is not in the JSON matrix`);
  }
  return problems;
}

/**
 * Versioning policy: Solidity constant, JSON matrixVersion, and history must agree, and the
 * latest history digest must match the current classification.
 * @param {object} matrix Parsed matrix.
 * @param {number|null} solidityVersion PAUSE_MATRIX_VERSION.
 * @returns {string[]} Problems.
 */
export function checkVersioning(matrix, solidityVersion) {
  const problems = [];
  if (solidityVersion === null) problems.push("PauseMatrix.sol: PAUSE_MATRIX_VERSION not found");
  else if (solidityVersion !== matrix.matrixVersion) {
    problems.push(`version mismatch: PauseMatrix.PAUSE_MATRIX_VERSION=${solidityVersion} but matrixVersion=${matrix.matrixVersion}`);
  }
  const history = matrix.history ?? [];
  if (history.length === 0) {
    problems.push("history must contain at least one entry");
    return problems;
  }
  const digests = new Set();
  let previous = 0;
  for (const entry of history) {
    if (!Number.isInteger(entry.version) || entry.version <= previous) {
      problems.push(`history versions must be strictly increasing (found ${entry.version} after ${previous})`);
    }
    previous = entry.version;
    if (!/^sha256:[0-9a-f]{64}$/.test(entry.digest ?? "")) problems.push(`history v${entry.version}: malformed digest`);
    if (digests.has(entry.digest)) problems.push(`history v${entry.version}: digest reused from an earlier version`);
    digests.add(entry.digest);
  }
  const latest = history[history.length - 1];
  if (latest.version !== matrix.matrixVersion) {
    problems.push(`latest history entry is v${latest.version} but matrixVersion is ${matrix.matrixVersion}`);
  }
  const digest = computeDigest(matrix);
  if (latest.digest !== digest) {
    problems.push(
      `classification changed without a version bump: computed ${digest} != history v${latest.version} ${latest.digest} — ` +
        "bump PAUSE_MATRIX_VERSION and matrixVersion and append a history entry"
    );
  }
  return problems;
}

/**
 * Every top-level `contracts/v2/*.sol` must be a classified module or an explicit exclusion.
 * @param {object} matrix Parsed matrix.
 * @param {string} rootDir Repository root.
 * @returns {Promise<string[]>} Problems.
 */
export async function checkCoverage(matrix, rootDir) {
  const problems = [];
  const listed = new Set([...(matrix.modules ?? []).map((m) => m.file), ...(matrix.excluded ?? []).map((e) => e.file)]);
  const dir = resolve(rootDir, MODULE_DIRECTORY);
  if (existsSync(dir)) {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.endsWith(".sol")) continue;
      const file = `${MODULE_DIRECTORY}/${entry.name}`;
      if (!listed.has(file)) problems.push(`${file}: canonical V2 file is neither classified in the pause matrix nor excluded`);
    }
  }
  for (const file of listed) {
    if (!existsSync(resolve(rootDir, file))) problems.push(`${file}: listed in the pause matrix but missing`);
  }
  return problems;
}

/** Semantic anchors the guard must keep (fail-closed risk path, fail-open exit path, write-once wiring). */
export const GUARD_ANCHORS = [
  {
    regex: /function\s+isScopePaused[\s\S]*?if\s*\(\s*!resolved\s*\)\s*return\s+true\s*;/,
    description: "isScopePaused must fail closed when the authority cannot be resolved"
  },
  {
    regex: /function\s+_queryScopePaused[\s\S]*?if\s*\(\s*!ok\s*\|\|\s*data\.length\s*<\s*32\s*\)\s*return\s+true\s*;/,
    description: "_queryScopePaused must fail closed on a reverting or malformed authority"
  },
  {
    regex: /function\s+exitsFrozen[\s\S]*?if\s*\(\s*!resolved\s*\|\|\s*authority\s*==\s*address\(0\)\s*\)\s*return\s+false\s*;/,
    description: "exitsFrozen must fail open when the authority is unresolved or unwired"
  },
  {
    regex: /EmergencyPauseOrdering\.OP_PULL_SETTLED_CLAIM/,
    description: "exit freeze must follow the V2-SC-117 pull_settled_claim rule (SHUTDOWN only)"
  },
  {
    regex: /if\s*\(\s*current\s*!=\s*address\(0\)\s*\)\s*revert\s+PauseAuthorityAlreadyWired/,
    description: "wired pause authority must be write-once"
  }
];

/**
 * Verifies the guard anchors.
 * @param {string} source V2PauseGuard.sol source.
 * @returns {string[]} Missing anchor descriptions.
 */
export function checkGuardAnchors(source) {
  const code = sanitize(source, { keepStrings: true });
  return GUARD_ANCHORS.filter(({ regex }) => !regex.test(code)).map(({ description }) => `V2PauseGuard.sol: ${description}`);
}

/**
 * Runs every check against a repository.
 * @param {string} [rootDir] Repository root.
 * @param {string} [matrixPath] Matrix path.
 * @returns {Promise<string[]>} Problems (empty when in policy).
 */
export async function runChecks(rootDir = REPO_ROOT, matrixPath = resolve(rootDir, "config", "pause-matrix.json")) {
  const matrix = JSON.parse(await readFile(matrixPath, "utf8"));
  const problems = [...validateMatrixShape(matrix)];

  for (const module of matrix.modules ?? []) {
    const file = resolve(rootDir, module.file);
    if (!existsSync(file)) continue; // reported by checkCoverage
    problems.push(...checkModule(module, await readFile(file, "utf8")));
  }

  const mirrorFile = resolve(rootDir, matrix.solidityMirror ?? "contracts/v2/libraries/PauseMatrix.sol");
  if (!existsSync(mirrorFile)) {
    problems.push(`${matrix.solidityMirror}: Solidity mirror is missing`);
  } else {
    const mirrorSource = await readFile(mirrorFile, "utf8");
    problems.push(...checkMirror(matrix, parseMirror(mirrorSource)));
    problems.push(...checkVersioning(matrix, parseSolidityVersion(mirrorSource)));
  }

  const guardFile = resolve(rootDir, matrix.guard ?? "contracts/v2/libraries/V2PauseGuard.sol");
  if (!existsSync(guardFile)) problems.push(`${matrix.guard}: pause guard is missing`);
  else problems.push(...checkGuardAnchors(await readFile(guardFile, "utf8")));

  problems.push(...(await checkCoverage(matrix, rootDir)));
  return problems;
}

async function main() {
  if (process.argv.includes("--report")) {
    const matrix = JSON.parse(await readFile(MATRIX_PATH, "utf8"));
    for (const module of matrix.modules ?? []) {
      const file = resolve(REPO_ROOT, module.file);
      if (!existsSync(file)) continue;
      for (const op of extractOperations(await readFile(file, "utf8"))) {
        const gates = [...op.scopes, ...(op.exitGate ? [EXIT_GATE] : []), ...(op.localPause ? ["whenNotPaused"] : [])];
        console.log(`${module.name}|${op.signature}|[${gates.join(", ")}]`);
      }
    }
    console.log(`digest: ${computeDigest(matrix)}`);
    process.exit(0);
  }

  console.log("==> Verifying the V2 emergency pause matrix (V2-SC-162)...");
  const problems = await runChecks();
  if (problems.length === 0) {
    console.log("✓ Pause matrix, module sources, Solidity mirror, and version history are consistent.");
    process.exit(0);
  }
  console.error(`\n❌ Pause matrix drift detected (${problems.length} problem(s)):`);
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(__filename)) {
  main().catch((error) => {
    console.error("Fatal error during pause matrix check:", error);
    process.exit(1);
  });
}
