#!/usr/bin/env node
/**
 * @file check-encode-packed.mjs
 * @description V2-SC-160 — static gate against ambiguous packed-encoding commitments.
 *
 * Every packed encoding in the scanned trees (Solidity `abi.encodePacked`, and `bytes.concat` /
 * `string.concat` fed straight into a hash; off-chain `solidityPacked*` / viem `encodePacked`)
 * must be declared in `scripts/encode-packed-policy.json` with a classification and a
 * justification. The inventory is checked in both directions: an unlisted use fails, a stale
 * entry fails, and a listed entry fails when its declared shape violates its classification
 * (e.g. a "digest" entry that feeds two variable-length operands into a hash, or any
 * variable-length operand into a hash inside the canonical V2 scope).
 *
 * Entries are keyed by a stable fingerprint — the first 12 hex chars of sha256 over the
 * whitespace-free call expression — so line moves do not churn the policy while any edit to
 * the expression itself forces a re-review.
 *
 * Usage:
 *   node scripts/check-encode-packed.mjs            # verify (exit 1 on drift or violation)
 *   node scripts/check-encode-packed.mjs --report   # print the detected inventory
 *   node scripts/check-encode-packed.mjs --json     # print the detected inventory as JSON
 */

import { readdir, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, extname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
export const REPO_ROOT = resolve(__dirname, "..");
export const POLICY_PATH = resolve(REPO_ROOT, "scripts", "encode-packed-policy.json");

/** Trees that are scanned (dependencies under lib/ and node_modules/ are never scanned). */
export const SCAN_ROOTS = ["contracts", "contracts-vrm", "script", "scripts", "test"];
const SKIP_DIRS = new Set(["node_modules", "lib", "out", "cache", "artifacts", "typechain-types", "coverage"]);
const SOL_EXTS = new Set([".sol"]);
const JS_EXTS = new Set([".ts", ".js", ".mjs", ".cjs"]);

/**
 * The gate and its self-test quote the patterns they police, and the cross-tool vector checker
 * deliberately recomputes the retired packed forms from the committed vectors to prove they
 * collide; none of them produces a protocol commitment, so they are not policy subjects.
 */
export const EXCLUDED_FILES = new Set([
  "scripts/check-encode-packed.mjs",
  "scripts/check-encode-packed-vectors.mjs",
  "test/scripts/check-encode-packed.test.mjs"
]);

export const CLASSIFICATIONS = new Set([
  "FIXED_WIDTH",
  "LENGTH_PREFIXED",
  "SINGLE_DYNAMIC",
  "PROTOCOL_DEFINED",
  "LEGACY_MIRROR",
  "NON_DIGEST",
  "DELIMITED_VALIDATED"
]);

/** Classifications that are allowed to feed a hash inside the canonical V2 scope. */
const CANONICAL_DIGEST_CLASSES = new Set(["FIXED_WIDTH", "LENGTH_PREFIXED", "PROTOCOL_DEFINED"]);
const DIGEST_CLASSES = new Set(["FIXED_WIDTH", "LENGTH_PREFIXED", "SINGLE_DYNAMIC", "PROTOCOL_DEFINED", "LEGACY_MIRROR"]);
const NON_DIGEST_CLASSES = new Set(["NON_DIGEST", "DELIMITED_VALIDATED", "LEGACY_MIRROR"]);

const MIN_JUSTIFICATION = 40;

// ---------------------------------------------------------------------------------------------
// Lexing helpers
// ---------------------------------------------------------------------------------------------

/**
 * Blanks comments (keeping newlines and offsets) while leaving string literals intact, so that
 * `"https://..."` inside a string is not mistaken for a comment and commented-out code is ignored.
 * @param {string} source Solidity or JS/TS source.
 * @param {boolean} [js] Treat backticks as template-literal delimiters.
 * @returns {string} Source with comments replaced by spaces.
 */
export function stripComments(source, js = false) {
  let out = "";
  let i = 0;
  const n = source.length;
  while (i < n) {
    const c = source[i];
    const d = source[i + 1];
    if (c === "/" && d === "/") {
      while (i < n && source[i] !== "\n" && source[i] !== "\r") {
        out += " ";
        i++;
      }
      continue;
    }
    if (c === "/" && d === "*") {
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
    if (c === '"' || c === "'" || (js && c === "`")) {
      const end = skipString(source, i);
      out += source.slice(i, end);
      i = end;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

/** Returns the index just past the string literal that starts at `start`. */
function skipString(text, start) {
  const quote = text[start];
  let i = start + 1;
  while (i < text.length) {
    if (text[i] === "\\") {
      i += 2;
      continue;
    }
    if (text[i] === quote) return i + 1;
    i++;
  }
  return text.length;
}

/**
 * Blanks the contents of string literals (keeping the quotes and offsets) so that pattern
 * matching never fires on text that merely quotes a packed call.
 */
export function blankStrings(code, js = false) {
  let out = "";
  let i = 0;
  while (i < code.length) {
    const c = code[i];
    if (c === '"' || c === "'" || (js && c === "`")) {
      const end = skipString(code, i);
      out += c + " ".repeat(Math.max(0, end - i - 2)) + (end - i >= 2 ? code[end - 1] : "");
      i = end;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

/** Index of the parenthesis that closes the one at `open`, string-aware; -1 if unbalanced. */
export function findClosingParen(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === '"' || c === "'" || c === "`") {
      i = skipString(text, i) - 1;
      continue;
    }
    if (c === "(") depth++;
    else if (c === ")") {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/** Splits an argument list on top-level commas (string- and bracket-aware). */
export function splitArgs(inner) {
  const args = [];
  let depth = 0;
  let current = "";
  for (let i = 0; i < inner.length; i++) {
    const c = inner[i];
    if (c === '"' || c === "'" || c === "`") {
      const end = skipString(inner, i);
      current += inner.slice(i, end);
      i = end - 1;
      continue;
    }
    if (c === "(" || c === "[" || c === "{") depth++;
    if (c === ")" || c === "]" || c === "}") depth--;
    if (c === "," && depth === 0) {
      args.push(current.trim());
      current = "";
      continue;
    }
    current += c;
  }
  if (current.trim().length > 0) args.push(current.trim());
  return args;
}

/** Removes whitespace outside string literals — the canonical form behind a fingerprint. */
export function normalize(text) {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"' || c === "'" || c === "`") {
      const end = skipString(text, i);
      out += text.slice(i, end);
      i = end - 1;
      continue;
    }
    if (!/\s/.test(c)) out += c;
  }
  return out;
}

/** Stable 12-hex-char fingerprint of a call expression. */
export function fingerprint(callText) {
  return createHash("sha256").update(normalize(callText)).digest("hex").slice(0, 12);
}

// ---------------------------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------------------------

const SOL_PACKED = /\babi\s*\.\s*encodePacked\s*\(/g;
const SOL_CONCAT = /\b(bytes|string)\s*\.\s*concat\s*\(/g;
const JS_PACKED = /\b(solidityPackedKeccak256|solidityPackedSha256|solidityPacked|solidityKeccak256|solidityPack|encodePacked)\s*\(/g;
const JS_HASHING = new Set(["solidityPackedKeccak256", "solidityPackedSha256", "solidityKeccak256"]);

/** True when the expression ending at `index` is the direct argument of a hash function. */
function isDigestContext(code, index) {
  let before = code.slice(Math.max(0, index - 200), index);
  before = before.replace(/(?:[A-Za-z_$][\w$]*\s*\.\s*)+$/, ""); // drop `ethers.` / `hre.ethers.`
  return /\b(?:keccak256|sha256|ripemd160)\s*\(\s*$/.test(before);
}

function lineOf(code, index) {
  let line = 1;
  for (let i = 0; i < index; i++) if (code[i] === "\n") line++;
  return line;
}

/**
 * Finds every tracked packed encoding in one source file.
 * @param {string} source File contents.
 * @param {"sol"|"js"} lang Source language.
 * @returns {Array<{kind: string, line: number, text: string, fingerprint: string, context: string, args: string[], jsTypes: string[]|null}>}
 */
export function detectPackedUses(source, lang) {
  const js = lang === "js";
  const code = stripComments(source, js);
  const searchable = blankStrings(code, js);
  const uses = [];
  const patterns = lang === "sol" ? [SOL_PACKED, SOL_CONCAT] : [JS_PACKED];
  for (const pattern of patterns) {
    pattern.lastIndex = 0;
    let match;
    while ((match = pattern.exec(searchable)) !== null) {
      const open = match.index + match[0].length - 1;
      const close = findClosingParen(code, open);
      if (close < 0) continue;
      const text = code.slice(match.index, close + 1);
      const args = splitArgs(code.slice(open + 1, close));
      let kind;
      let context = isDigestContext(searchable, match.index) ? "digest" : "non-digest";
      let jsTypes = null;
      if (pattern === SOL_PACKED) kind = "abi.encodePacked";
      else if (pattern === SOL_CONCAT) {
        kind = `${match[1]}.concat`;
        // concat is only policed where it builds a hash preimage.
        if (context !== "digest") continue;
      } else {
        kind = match[1];
        if (JS_HASHING.has(kind)) context = "digest";
        jsTypes = parseJsTypeList(args[0]);
      }
      uses.push({ kind, line: lineOf(code, match.index), text, fingerprint: fingerprint(text), context, args, jsTypes });
    }
  }
  return uses;
}

/** Parses the `["address", "uint256"]` type list of an ethers/viem packed call. */
export function parseJsTypeList(arg) {
  if (!arg) return null;
  const trimmed = arg.trim();
  if (!trimmed.startsWith("[") || !trimmed.endsWith("]")) return null;
  const items = splitArgs(trimmed.slice(1, -1));
  const types = [];
  for (const item of items) {
    const m = /^(["'`])([^"'`]*)\1$/.exec(item.trim());
    if (!m) return null;
    types.push(m[2]);
  }
  return types;
}

// ---------------------------------------------------------------------------------------------
// Operand typing
// ---------------------------------------------------------------------------------------------

/** True for packed operand types whose encoded width depends on the value. */
export function isDynamicType(type) {
  return type === "string" || type === "bytes" || /\[\]$/.test(type);
}

const STATIC_TYPE = /^(?:address|bool|bytes(?:[1-9]|[12]\d|3[0-2])|u?int(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)?)$/;

/**
 * Best-effort inference of an operand's packed width class from the expression and the file's
 * declarations: "literal", "static", "dynamic", or "unknown". Used to cross-check the declared
 * operand types so a policy entry cannot mislabel a string as fixed-width.
 */
export function inferOperandClass(arg, source) {
  const a = normalize(arg);
  if (/^(?:hex|unicode)?(["']).*\1$/s.test(a)) return "literal";
  if (/^type\([\w.]+\)\.(?:creationCode|runtimeCode)$/.test(a)) return "dynamic";
  if (/^(?:abi\.encode\w*|bytes\.concat|string\.concat)\(/.test(a) && a.endsWith(")")) return "dynamic";
  if (/^(?:bytes|string)\(.*\)$/s.test(a)) return "dynamic";
  if (/^(?:keccak256|sha256)\(.*\)$/s.test(a)) return "static";
  const cast = /^(\w+)\(.*\)$/s.exec(a);
  if (cast && STATIC_TYPE.test(cast[1])) return "static";
  if (/\.length$/.test(a)) return "static";
  if (/^(?:block\.(?:timestamp|number|chainid|basefee|prevrandao)|msg\.sender|tx\.origin)$/.test(a)) return "static";
  if (/^\d+$/.test(a)) return "static";
  if (/^[A-Za-z_$][\w$]*$/.test(a)) {
    const name = a.replace(/\$/g, "\\$");
    if (new RegExp(`\\b(?:string|bytes)\\s+(?:memory|calldata|storage)\\s+${name}\\b`).test(source)) return "dynamic";
    if (new RegExp(`\\b\\w+(?:\\[\\d*\\])+\\s+(?:memory|calldata|storage)\\s+${name}\\b`).test(source)) return "dynamic";
    const staticDecl = new RegExp(
      `\\b(?:address(?:\\s+payable)?|bool|bytes(?:[1-9]|[12]\\d|3[0-2])|u?int\\d*)\\s+(?:(?:public|private|internal|immutable|constant|indexed)\\s+)*${name}\\b`
    );
    if (staticDecl.test(source)) return "static";
  }
  return "unknown";
}

// ---------------------------------------------------------------------------------------------
// Inventory
// ---------------------------------------------------------------------------------------------

async function collectFiles(dir) {
  if (!existsSync(dir)) return [];
  const entries = await readdir(dir, { withFileTypes: true });
  const results = [];
  for (const entry of entries) {
    const full = resolve(dir, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) results.push(...(await collectFiles(full)));
    } else if (entry.isFile()) {
      const ext = extname(entry.name);
      if (SOL_EXTS.has(ext) || (JS_EXTS.has(ext) && !entry.name.endsWith(".d.ts"))) results.push(full);
    }
  }
  return results;
}

/**
 * Scans the repository and groups detected uses by (file, fingerprint).
 * @param {string} [rootDir] Repository root.
 * @returns {Promise<Map<string, {file: string, fingerprint: string, count: number, uses: object[], source: string}>>}
 */
export async function detectInventory(rootDir = REPO_ROOT) {
  const detected = new Map();
  for (const root of SCAN_ROOTS) {
    for (const file of await collectFiles(resolve(rootDir, root))) {
      const rel = relative(rootDir, file).split(sep).join("/");
      if (EXCLUDED_FILES.has(rel)) continue;
      const lang = SOL_EXTS.has(extname(file)) ? "sol" : "js";
      const source = await readFile(file, "utf8");
      for (const use of detectPackedUses(source, lang)) {
        const key = `${rel}#${use.fingerprint}`;
        const group = detected.get(key) ?? { file: rel, fingerprint: use.fingerprint, count: 0, uses: [], source, lang };
        group.count++;
        group.uses.push(use);
        detected.set(key, group);
      }
    }
  }
  return detected;
}

/** Reads the committed policy. */
export async function readPolicy(path = POLICY_PATH) {
  return JSON.parse(await readFile(path, "utf8"));
}

/** True when `file` is inside the canonical V2 scope declared by the policy. */
export function isCanonical(file, policy) {
  return (policy.canonicalScope ?? []).some((prefix) => (prefix.endsWith("/") ? file.startsWith(prefix) : file === prefix));
}

/**
 * Validates one policy entry against the detected group it describes.
 * @returns {string[]} Problems for this entry.
 */
export function validateEntry(entry, group, policy) {
  const where = `${entry.file} [${entry.fingerprint}] ${entry.excerpt ?? ""}`.trim();
  const problems = [];
  const use = group.uses[0];

  if (!CLASSIFICATIONS.has(entry.classification)) {
    problems.push(`${where}: unknown classification "${entry.classification}"`);
    return problems;
  }
  if (!entry.justification || entry.justification.trim().length < MIN_JUSTIFICATION) {
    problems.push(`${where}: needs a justification of at least ${MIN_JUSTIFICATION} characters`);
  }
  if ((entry.count ?? 1) !== group.count) {
    problems.push(`${where}: declared count ${entry.count ?? 1} but ${group.count} occurrence(s) detected`);
  }
  if (entry.context !== use.context) {
    problems.push(`${where}: declared context "${entry.context}" but detected "${use.context}"`);
  }
  if (entry.kind && entry.kind !== use.kind) {
    problems.push(`${where}: declared kind "${entry.kind}" but detected "${use.kind}"`);
  }

  const canonical = isCanonical(entry.file, policy);

  if (use.context === "digest") {
    if (!DIGEST_CLASSES.has(entry.classification)) {
      problems.push(`${where}: classification ${entry.classification} cannot feed a hash`);
    }
    if (!Array.isArray(entry.args)) {
      problems.push(`${where}: digest entries must declare their operand types in "args"`);
      return problems;
    }
    const isJs = group.lang === "js";
    const operandCount = isJs ? (use.jsTypes ? use.jsTypes.length : entry.args.length) : use.args.length;
    if (entry.args.length !== operandCount) {
      problems.push(`${where}: declares ${entry.args.length} operand(s) but the expression has ${operandCount}`);
      return problems;
    }
    // Cross-check declared operand types against what the source proves.
    for (let i = 0; i < operandCount; i++) {
      const declared = entry.args[i];
      if (isJs) {
        // Off-chain packers carry an explicit type list; it is authoritative. A string value in
        // an off-chain type list is still variable-length, so it may not be declared "literal".
        if (use.jsTypes && use.jsTypes[i] !== declared) {
          problems.push(`${where}: operand ${i} declared "${declared}" but the type list says "${use.jsTypes[i]}"`);
        }
        continue;
      }
      const inferred = inferOperandClass(use.args[i], group.source);
      if (inferred === "literal" && declared !== "literal") {
        problems.push(`${where}: operand ${i} (${normalize(use.args[i])}) is a string literal and must be declared "literal"`);
      } else if (inferred !== "literal" && declared === "literal") {
        problems.push(`${where}: operand ${i} (${normalize(use.args[i])}) is not a compile-time string literal but is declared "literal"`);
      } else if (inferred === "dynamic" && !isDynamicType(declared)) {
        problems.push(`${where}: operand ${i} (${normalize(use.args[i])}) is variable-length but declared "${declared}"`);
      } else if (inferred === "static" && isDynamicType(declared)) {
        problems.push(`${where}: operand ${i} (${normalize(use.args[i])}) is fixed-width but declared "${declared}"`);
      }
    }
    const dynamicIdx = entry.args.map((t, i) => (isDynamicType(t) ? i : -1)).filter((i) => i >= 0);

    switch (entry.classification) {
      case "FIXED_WIDTH":
        if (dynamicIdx.length > 0) problems.push(`${where}: FIXED_WIDTH entry has ${dynamicIdx.length} variable-length operand(s)`);
        break;
      case "LENGTH_PREFIXED": {
        if (dynamicIdx.length === 0) problems.push(`${where}: LENGTH_PREFIXED entry has no variable-length operand`);
        for (const i of dynamicIdx) {
          const operand = normalize(use.args[i]).replace(/^bytes\((.*)\)$/s, "$1");
          const prefix = i > 0 ? normalize(use.args[i - 1]) : "";
          const m = /^uint256\(bytes\((.*)\)\.length\)$/s.exec(prefix) ?? /^uint256\((.*)\.length\)$/s.exec(prefix);
          if (!m || m[1] !== operand) {
            problems.push(`${where}: variable-length operand ${i} is not immediately preceded by uint256(bytes(${operand}).length)`);
          }
        }
        break;
      }
      case "SINGLE_DYNAMIC":
        if (dynamicIdx.length !== 1) problems.push(`${where}: SINGLE_DYNAMIC entry has ${dynamicIdx.length} variable-length operand(s)`);
        break;
      case "PROTOCOL_DEFINED":
        if (!entry.standard || entry.standard.trim().length === 0) {
          problems.push(`${where}: PROTOCOL_DEFINED entry must cite the external "standard" that fixes the byte layout`);
        }
        break;
      case "LEGACY_MIRROR":
        break;
      default:
        break;
    }
    if (dynamicIdx.length >= 2 && !["LENGTH_PREFIXED", "PROTOCOL_DEFINED", "LEGACY_MIRROR"].includes(entry.classification)) {
      problems.push(`${where}: two or more variable-length operands feed a hash — ambiguous packed commitment`);
    }
    if (canonical && !CANONICAL_DIGEST_CLASSES.has(entry.classification)) {
      problems.push(`${where}: canonical V2 digests must be FIXED_WIDTH, LENGTH_PREFIXED or PROTOCOL_DEFINED (found ${entry.classification}); use typed abi.encode`);
    }
  } else if (!NON_DIGEST_CLASSES.has(entry.classification)) {
    problems.push(`${where}: classification ${entry.classification} is reserved for hash preimages, but this use is not hashed`);
  }

  if (entry.classification === "LEGACY_MIRROR") {
    if (!entry.file.startsWith("test/")) problems.push(`${where}: LEGACY_MIRROR is only permitted in test/ fixtures`);
    if (!entry.mirrors || entry.mirrors.trim().length === 0) problems.push(`${where}: LEGACY_MIRROR entry must name the retired scheme it "mirrors"`);
  }
  if (entry.classification === "DELIMITED_VALIDATED") {
    if (!entry.guard || !new RegExp(`\\b${entry.guard}\\s*\\(`).test(stripComments(group.source))) {
      problems.push(`${where}: DELIMITED_VALIDATED entry must name a "guard" function that is called in the file`);
    }
  }
  return problems;
}

/**
 * Compares the detected inventory with the committed policy, in both directions.
 * @returns {string[]} Problems (empty when in policy).
 */
export function diffInventory(detected, policy) {
  const problems = [];
  const declared = new Map();
  for (const entry of policy.entries ?? []) {
    const key = `${entry.file}#${entry.fingerprint}`;
    if (declared.has(key)) problems.push(`${entry.file} [${entry.fingerprint}]: duplicate policy entry`);
    declared.set(key, entry);
  }
  for (const [key, group] of detected) {
    const entry = declared.get(key);
    if (!entry) {
      const use = group.uses[0];
      problems.push(
        `${group.file}:${use.line}: unlisted ${use.kind} (${use.context}) [${group.fingerprint}] ${normalize(use.text).slice(0, 100)} — ` +
          `replace it with typed abi.encode, or add a reviewed entry to scripts/encode-packed-policy.json`
      );
      continue;
    }
    problems.push(...validateEntry(entry, group, policy));
  }
  for (const [key, entry] of declared) {
    if (!detected.has(key)) {
      problems.push(`${entry.file} [${entry.fingerprint}]: stale policy entry — no matching packed encoding detected (${entry.excerpt ?? ""})`);
    }
  }
  return problems;
}

/** Anchors: the V2-SC-160 replacements must stay in place. */
export const POLICY_ANCHORS = [
  {
    file: "contracts/libraries/CanonicalEventLibrary.sol",
    regex: /OPERATION_ID_SCHEME_V2\s*=\s*keccak256\(\s*"TruthBounty\.CanonicalEventLibrary\.operationId\.v2"\s*\)/,
    description: "operation-id scheme tag must be keccak256(\"TruthBounty.CanonicalEventLibrary.operationId.v2\")"
  },
  {
    file: "contracts/libraries/CanonicalEventLibrary.sol",
    regex: /keccak256\(\s*abi\.encode\(\s*OPERATION_ID_SCHEME_V2\s*,\s*domain\s*,\s*nonce\s*,\s*actor\s*\)\s*\)/,
    description: "computeOperationId must hash abi.encode(OPERATION_ID_SCHEME_V2, domain, nonce, actor)"
  },
  {
    file: "contracts/upgrade/UpgradeController.sol",
    regex: /UPGRADE_HASH_SCHEME_V2\s*=\s*keccak256\(\s*"TruthBounty\.UpgradeController\.upgradeHash\.v2"\s*\)/,
    description: "upgrade-hash scheme tag must be keccak256(\"TruthBounty.UpgradeController.upgradeHash.v2\")"
  },
  {
    file: "contracts/upgrade/UpgradeController.sol",
    regex: /UPGRADE_PROPOSAL_ID_SCHEME_V2\s*=\s*keccak256\(\s*"TruthBounty\.UpgradeController\.proposalId\.v2"\s*\)/,
    description: "proposal-id scheme tag must be keccak256(\"TruthBounty.UpgradeController.proposalId.v2\")"
  },
  {
    file: "contracts/upgrade/UpgradeController.sol",
    regex: /upgradeHash\s*=\s*keccak256\(\s*abi\.encode\(\s*UPGRADE_HASH_SCHEME_V2\s*,/,
    description: "upgradeHash must be a version-tagged abi.encode commitment"
  },
  {
    file: "contracts/upgrade/UpgradeController.sol",
    regex: /proposalId\s*=\s*keccak256\(\s*abi\.encode\(\s*UPGRADE_PROPOSAL_ID_SCHEME_V2\s*,/,
    description: "proposalId must be a version-tagged abi.encode commitment"
  },
  {
    file: "contracts/v2/SupplyChainAttestationAnchor.sol",
    regex: /_requireNoDelimiter\(\s*deps\[i\]\.name\s*\)[\s\S]*_requireNoDelimiter\(\s*deps\[i\]\.version\s*\)[\s\S]*_requireNoDelimiter\(\s*deps\[i\]\.kind\s*\)[\s\S]*_requireNoDelimiter\(\s*deps\[i\]\.rev\s*\)[\s\S]*_requireNoDelimiter\(\s*deps\[i\]\.integrity\s*\)/,
    description: "packDependencies must reject '|' in every dependency field"
  },
  {
    file: "contracts/v2/SupplyChainAttestationAnchor.sol",
    regex: /_requireNoDelimiter\(\s*artifacts\[i\]\.path\s*\)[\s\S]*_requireNoDelimiter\(\s*subjects\[i\]\.name\s*\)[\s\S]*_requireNoDelimiter\(\s*materials\[i\]\.uri\s*\)/,
    description: "packArtifacts/packSubjects/packMaterials must reject '|' in their free-form field"
  }
];

/** Verifies the documented replacements are still implemented. */
export async function checkPolicyAnchors(rootDir = REPO_ROOT) {
  const missing = [];
  for (const anchor of POLICY_ANCHORS) {
    const file = resolve(rootDir, anchor.file);
    if (!existsSync(file)) {
      missing.push(`${anchor.file}: file is missing (${anchor.description})`);
      continue;
    }
    if (!anchor.regex.test(stripComments(await readFile(file, "utf8")))) {
      missing.push(`${anchor.file}: ${anchor.description}`);
    }
  }
  return missing;
}

function describe(group) {
  const use = group.uses[0];
  return {
    file: group.file,
    line: use.line,
    fingerprint: group.fingerprint,
    count: group.count,
    kind: use.kind,
    context: use.context,
    operands: use.args.map((a) => normalize(a)),
    inferred: use.jsTypes ?? use.args.map((a) => inferOperandClass(a, group.source))
  };
}

async function main() {
  const detected = await detectInventory();
  const sorted = [...detected.values()].sort((a, b) => (a.file === b.file ? a.uses[0].line - b.uses[0].line : a.file < b.file ? -1 : 1));

  if (process.argv.includes("--json")) {
    console.log(JSON.stringify(sorted.map(describe), null, 2));
    process.exit(0);
  }
  if (process.argv.includes("--report")) {
    for (const group of sorted) {
      const d = describe(group);
      console.log(`${d.file}:${d.line} [${d.fingerprint}] x${d.count} ${d.kind} ${d.context} (${d.inferred.join(", ")})`);
    }
    console.log(`Detected ${sorted.length} distinct packed encoding(s).`);
    process.exit(0);
  }

  console.log("==> Verifying the packed-encoding commitment policy (V2-SC-160)...");
  const policy = await readPolicy();
  const problems = [...diffInventory(detected, policy), ...(await checkPolicyAnchors())];

  if (problems.length === 0) {
    const total = sorted.reduce((sum, g) => sum + g.count, 0);
    console.log(`✓ ${total} packed encoding(s) in ${sorted.length} distinct expression(s) match the reviewed policy; all V2-SC-160 anchors are present.`);
    process.exit(0);
  }

  console.error(`\n❌ Packed-encoding policy violation(s) detected (${problems.length}):`);
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(__filename)) {
  main().catch((error) => {
    console.error("Fatal error during packed-encoding policy check:", error);
    process.exit(1);
  });
}
