#!/usr/bin/env node
/**
 * @file check-storage-namespaces.mjs
 * @description V2-SC-159 — detects upgradeable storage namespace and reserved-slot collisions.
 *
 * The V2-SC-121 manifest (`storage-layouts/manifest.json`) freezes the *linear* layout of every
 * upgradeable canonical module. Linear diffs cannot see storage that lives outside the linear
 * region: ERC-7201 namespaces, unstructured (EIP-1967 style) slots and the ERC-1967 proxy
 * reserved slots. This checker inventories all of them from source, without a compiler, and
 * writes a deterministic per-module slot/namespace manifest
 * (`storage-layouts/namespace-manifest.json`).
 *
 * It fails when:
 *   - an ERC-7201 namespace id is defined by more than one contract       (duplicate-namespace)
 *   - an `erc7201:` annotation has no constant equal to its formula slot  (namespace-slot-mismatch)
 *   - two computed slots of one composed module overlap                   (slot-overlap)
 *   - module storage reuses an ERC-1967 implementation/admin/beacon slot  (reserved-slot-reuse)
 *   - the linear storage contributor order changes vs the committed
 *     manifest (C3 linearization reorder, inserted base, removed base)    (inheritance-reorder)
 *   - variables inside a contributor are reordered/removed/renamed        (layout-reorder)
 *   - a namespace or unstructured slot disappears or moves                (namespace-removed, unstructured-slot-*)
 *   - the module set differs from the V2-SC-121 frozen manifest           (coverage)
 *   - the source-derived linear order disagrees with the V2-SC-121 frozen
 *     manifest without an acknowledged entry in the policy               (layout-discrepancy)
 *   - the committed manifest is not byte-identical to the regenerated one (manifest-drift)
 *
 * Usage:
 *   node scripts/check-storage-namespaces.mjs                  # verify (exit 1 on any problem)
 *   node scripts/check-storage-namespaces.mjs --report         # print the per-module inventory
 *   node scripts/check-storage-namespaces.mjs --write          # regenerate after review; refuses
 *                                                              # on collisions or unsafe transitions
 *   node scripts/check-storage-namespaces.mjs --write --allow-unsafe-transition
 *                                                              # layout-breaking migration that a
 *                                                              # maintainer has reviewed
 */

import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, posix, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { eip1967Slot, erc7201Slot, keccak256 } from "./lib/keccak256.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "..");

export const MANIFEST_RELATIVE_PATH = "storage-layouts/namespace-manifest.json";
export const POLICY_RELATIVE_PATH = "scripts/storage-namespace-policy.json";
export const FROZEN_LAYOUT_RELATIVE_PATH = "storage-layouts/manifest.json";
export const SOURCE_ROOTS = ["contracts", "contracts-vrm", "lib/openzeppelin-contracts-upgradeable"];
export const MANIFEST_SCHEMA_VERSION = 1;
export const DIGEST_DOMAIN = "TB-STORAGE-NAMESPACE-V1";
/** OpenZeppelin v5 sources that are resolved through the policy, never parsed for the manifest. */
export const EXTERNAL_IMPORT_PREFIXES = ["@openzeppelin/contracts/", "forge-std/"];
/** Where the installed OpenZeppelin package lives when `npm ci` has run (cross-check only). */
export const EXTERNAL_PACKAGE_ROOT = "node_modules/@openzeppelin/contracts";

const IDENT = "[A-Za-z_$][\\w$]*";
const NON_STORAGE_KEYWORDS = new Set([
  "function",
  "modifier",
  "event",
  "error",
  "using",
  "struct",
  "enum",
  "constructor",
  "receive",
  "fallback",
  "type"
]);

// ---------------------------------------------------------------------------
// Lexing and parsing
// ---------------------------------------------------------------------------

/**
 * Single-pass lexer that blanks comments (and, in the skeleton, string contents) while
 * preserving every offset and newline, so positions are comparable across the three views.
 * @param {string} source Solidity source.
 * @returns {{code: string, skeleton: string, comments: Array<{start: number, end: number, text: string}>}}
 */
export function lexSolidity(source) {
  const code = [];
  const skeleton = [];
  const comments = [];
  let i = 0;
  const n = source.length;
  const blank = (ch) => (ch === "\n" || ch === "\r" ? ch : " ");
  while (i < n) {
    const ch = source[i];
    const next = source[i + 1];
    if (ch === "/" && next === "/") {
      const start = i;
      while (i < n && source[i] !== "\n") {
        code.push(blank(source[i]));
        skeleton.push(blank(source[i]));
        i++;
      }
      comments.push({ start, end: i, text: source.slice(start, i) });
      continue;
    }
    if (ch === "/" && next === "*") {
      const start = i;
      const close = source.indexOf("*/", i + 2);
      const end = close === -1 ? n : close + 2;
      for (; i < end; i++) {
        code.push(blank(source[i]));
        skeleton.push(blank(source[i]));
      }
      comments.push({ start, end, text: source.slice(start, end) });
      continue;
    }
    if (ch === '"' || ch === "'") {
      const quote = ch;
      code.push(ch);
      skeleton.push(ch);
      i++;
      while (i < n && source[i] !== quote && source[i] !== "\n") {
        if (source[i] === "\\" && i + 1 < n) {
          code.push(source[i], source[i + 1]);
          skeleton.push(" ", " ");
          i += 2;
          continue;
        }
        code.push(source[i]);
        skeleton.push(" ");
        i++;
      }
      if (i < n) {
        code.push(source[i]);
        skeleton.push(source[i]);
        i++;
      }
      continue;
    }
    code.push(ch);
    skeleton.push(ch);
    i++;
  }
  return { code: code.join(""), skeleton: skeleton.join(""), comments };
}

function matchBrace(text, openIndex) {
  let depth = 0;
  for (let i = openIndex; i < text.length; i++) {
    if (text[i] === "{") depth++;
    else if (text[i] === "}") {
      depth--;
      if (depth === 0) return i;
    }
  }
  return text.length - 1;
}

function stripParenthesized(text) {
  let previous;
  let current = text;
  do {
    previous = current;
    current = current.replace(/\([^()]*\)/g, "");
  } while (current !== previous);
  return current;
}

/**
 * Splits an assignment at the first `=` that is not part of `==`, `=>`, `<=`, `>=` or `!=`.
 * @param {string} statement Declaration statement.
 * @returns {string} The declaration part before the initializer.
 */
function declarationPart(statement) {
  const match = /(?<![=!<>])=(?![=>])/.exec(statement);
  return match ? statement.slice(0, match.index) : statement;
}

/**
 * Extracts the persistent (linear) state variables declared directly in a contract body, in
 * declaration order. Constants, immutables and transient variables are excluded because they
 * never occupy a persistent storage slot.
 * @param {string} skeleton Skeleton view of the file.
 * @param {number} bodyStart Index of the contract's opening brace.
 * @param {number} bodyEnd Index of the contract's closing brace.
 * @returns {string[]} Variable names.
 */
export function extractStateVariables(skeleton, bodyStart, bodyEnd) {
  const names = [];
  let depth = 0;
  let buffer = "";
  for (let i = bodyStart + 1; i < bodyEnd; i++) {
    const ch = skeleton[i];
    if (ch === "{") {
      depth++;
      continue;
    }
    if (ch === "}") {
      depth--;
      if (depth === 0) buffer = "";
      continue;
    }
    if (depth !== 0) continue;
    if (ch === ";") {
      const statement = buffer.replace(/\s+/g, " ").trim();
      buffer = "";
      if (!statement) continue;
      const first = statement.match(new RegExp(`^${IDENT}`))?.[0];
      if (!first || NON_STORAGE_KEYWORDS.has(first)) continue;
      if (/\b(constant|immutable|transient)\b/.test(statement)) continue;
      const name = declarationPart(statement).trim().match(new RegExp(`(${IDENT})\\s*$`))?.[1];
      if (name) names.push(name);
      continue;
    }
    buffer += ch;
  }
  return names;
}

/**
 * Evaluates a `bytes32 constant` initializer when it is a slot literal or one of the standard
 * slot derivations. Returns null for anything else.
 * @param {string} expression Initializer expression (code view).
 * @returns {{value: string, derivation: string, id?: string} | null}
 */
export function evaluateSlotExpression(expression) {
  const e = expression.replace(/\s+/g, "");
  if (/^0x[0-9a-fA-F]{64}$/.test(e)) return { value: e.toLowerCase(), derivation: "literal" };
  const stringArg = '(?:"([^"]*)"|bytes\\("([^"]*)"\\)|abi\\.encodePacked\\("([^"]*)"\\))';
  const erc7201 = new RegExp(
    `^keccak256\\(abi\\.encode\\(uint256\\(keccak256\\(${stringArg}\\)\\)-1\\)\\)&~bytes32\\(uint256\\(0xff\\)\\)$`
  ).exec(e);
  if (erc7201) {
    const id = erc7201[1] ?? erc7201[2] ?? erc7201[3];
    return { value: erc7201Slot(id), derivation: "erc7201", id };
  }
  const eip1967 = new RegExp(`^bytes32\\(uint256\\(keccak256\\(${stringArg}\\)\\)-1\\)$`).exec(e);
  if (eip1967) {
    const id = eip1967[1] ?? eip1967[2] ?? eip1967[3];
    return { value: eip1967Slot(id), derivation: "eip1967", id };
  }
  const plain = new RegExp(`^keccak256\\(${stringArg}\\)$`).exec(e);
  if (plain) {
    const id = plain[1] ?? plain[2] ?? plain[3];
    return { value: keccak256(id), derivation: "keccak256", id };
  }
  return null;
}

/**
 * Parses one Solidity file into imports and contract declarations with their bases, linear
 * state variables, ERC-7201 namespaces, unstructured slots and 32-byte hex literals.
 * @param {string} source Solidity source.
 * @returns {{imports: string[], contracts: object[]}}
 */
export function parseSolidity(source) {
  const { code, skeleton, comments } = lexSolidity(source);
  const imports = [];
  for (const m of code.matchAll(/\bimport\s+(?:[^;]*?\bfrom\s+)?["']([^"']+)["']\s*(?:as\s+\w+\s*)?;/g)) {
    imports.push(m[1]);
  }

  const contracts = [];
  const declaration = new RegExp(`\\b(abstract\\s+)?(contract|library|interface)\\s+(${IDENT})\\s*(?:is\\s+([^{;]*))?\\{`, "g");
  for (const m of skeleton.matchAll(declaration)) {
    const bodyStart = m.index + m[0].length - 1;
    const bodyEnd = matchBrace(skeleton, bodyStart);
    const bases = m[4]
      ? stripParenthesized(m[4])
          .split(",")
          .map((b) => b.trim().split(".").pop())
          .filter(Boolean)
      : [];
    contracts.push({
      name: m[3],
      kind: m[2],
      abstract: Boolean(m[1]),
      bases,
      bodyStart,
      bodyEnd,
      stateVariables: extractStateVariables(skeleton, bodyStart, bodyEnd),
      namespaces: [],
      unstructuredSlots: [],
      hexLiterals: []
    });
  }
  const enclosing = (index) => contracts.find((c) => index > c.bodyStart && index < c.bodyEnd && c.kind !== "interface");

  for (const contract of contracts) {
    const body = code.slice(contract.bodyStart, contract.bodyEnd);
    const constants = new Map();
    for (const c of body.matchAll(
      new RegExp(`\\bbytes32\\s+(?:(?:private|internal|public|override)\\s+)*constant\\s+(${IDENT})\\s*=\\s*([^;]+);`, "g")
    )) {
      const evaluated = evaluateSlotExpression(c[2]);
      if (evaluated) constants.set(c[1], evaluated);
    }
    const slotUses = new Set();
    const slotContext = new RegExp(
      `(?:\\.slot\\s*:=\\s*|\\bsload\\s*\\(\\s*|\\bsstore\\s*\\(\\s*|StorageSlot\\s*\\.\\s*get\\w+Slot\\s*\\(\\s*)(${IDENT}|0x[0-9a-fA-F]{64})`,
      "g"
    );
    for (const u of body.matchAll(slotContext)) slotUses.add(u[1]);
    for (const h of body.matchAll(/0x[0-9a-fA-F]{64}(?![0-9a-fA-F])/g)) contract.hexLiterals.push(h[0].toLowerCase());
    contract.constants = Object.fromEntries([...constants].map(([k, v]) => [k, v.value]));

    // ERC-7201 annotations inside this contract.
    for (const comment of comments) {
      if (enclosing(comment.start) !== contract) continue;
      for (const a of comment.text.matchAll(/@custom:storage-location\s+erc7201:([A-Za-z0-9_.\-]+)/g)) {
        const after = skeleton.slice(comment.end, contract.bodyEnd);
        const struct = after.match(new RegExp(`\\bstruct\\s+(${IDENT})`))?.[1] ?? null;
        const id = a[1];
        const slot = erc7201Slot(id);
        const constant = [...constants].find(([, v]) => v.value === slot)?.[0] ?? null;
        contract.namespaces.push({ id, slot, struct, constant, annotated: true });
      }
    }
    const namespaceSlots = new Set(contract.namespaces.map((ns) => ns.slot));
    for (const [name, v] of constants) {
      if (v.derivation === "erc7201" && !namespaceSlots.has(v.value)) {
        contract.namespaces.push({ id: v.id, slot: v.value, struct: null, constant: name, annotated: false });
        namespaceSlots.add(v.value);
      }
    }
    for (const [name, v] of constants) {
      if (namespaceSlots.has(v.value)) continue;
      if (v.derivation === "eip1967" || slotUses.has(name)) {
        contract.unstructuredSlots.push({ name, slot: v.value, derivation: v.derivation, id: v.id ?? null });
      }
    }
    for (const use of slotUses) {
      if (!use.startsWith("0x")) continue;
      const value = use.toLowerCase();
      if (namespaceSlots.has(value)) continue;
      contract.unstructuredSlots.push({ name: `literal:${value}`, slot: value, derivation: "literal", id: null });
    }
  }
  return { imports, contracts };
}

// ---------------------------------------------------------------------------
// Source loading and name resolution
// ---------------------------------------------------------------------------

function listSolidityFiles(rootDir, relDir) {
  const abs = resolve(rootDir, relDir);
  if (!existsSync(abs)) return [];
  const out = [];
  for (const entry of readdirSync(abs, { withFileTypes: true })) {
    const rel = posix.join(relDir, entry.name);
    if (entry.isDirectory()) out.push(...listSolidityFiles(rootDir, rel));
    else if (entry.isFile() && entry.name.endsWith(".sol")) out.push(rel);
  }
  return out.sort();
}

/**
 * Reads every Solidity source the checker is allowed to parse.
 * @param {string} [rootDir] Repository root.
 * @returns {Map<string, string>} Repo-relative path -> source.
 */
export function loadRepositorySources(rootDir = REPO_ROOT) {
  const sources = new Map();
  for (const root of SOURCE_ROOTS) {
    for (const rel of listSolidityFiles(rootDir, root)) sources.set(rel, readFileSync(resolve(rootDir, rel), "utf8"));
  }
  return sources;
}

/**
 * Maps an import specifier to a repo-relative path, or null for policy-resolved externals.
 * @param {string} fromFile Importing file (repo-relative, posix).
 * @param {string} specifier Import path.
 * @returns {string | null}
 */
export function resolveImport(fromFile, specifier) {
  if (EXTERNAL_IMPORT_PREFIXES.some((p) => specifier.startsWith(p))) return null;
  if (specifier.startsWith("./") || specifier.startsWith("../")) return posix.normalize(posix.join(posix.dirname(fromFile), specifier));
  if (specifier.startsWith("@openzeppelin/contracts-upgradeable/")) {
    return posix.join("lib/openzeppelin-contracts-upgradeable", specifier.slice("@openzeppelin/contracts-upgradeable/".length));
  }
  return posix.normalize(specifier);
}

class Resolver {
  constructor(sources, policy) {
    this.sources = sources;
    this.policy = policy;
    this.parsed = new Map();
    this.visible = new Map();
    this.linearizations = new Map();
  }

  file(path) {
    if (!this.parsed.has(path)) {
      const source = this.sources.get(path);
      this.parsed.set(path, source === undefined ? null : parseSolidity(source));
    }
    return this.parsed.get(path);
  }

  /** Files whose global symbols are visible from `path` (transitive `import`). */
  visibleFiles(path) {
    if (this.visible.has(path)) return this.visible.get(path);
    const seen = new Set([path]);
    const queue = [path];
    while (queue.length > 0) {
      const current = queue.shift();
      const parsed = this.file(current);
      if (!parsed) continue;
      for (const specifier of parsed.imports) {
        const target = resolveImport(current, specifier);
        if (target && !seen.has(target)) {
          seen.add(target);
          queue.push(target);
        }
      }
    }
    const files = [...seen];
    this.visible.set(path, files);
    return files;
  }

  /** Resolves a base-contract name in the scope of `fromFile` (`external:<Name>` for externals). */
  resolve(name, fromFile) {
    if (fromFile.startsWith("external:")) {
      const external = this.policy.externalContracts?.[name];
      if (!external) throw new Error(`${fromFile}: external base '${name}' is not declared in ${POLICY_RELATIVE_PATH}`);
      return { key: `external:${name}`, name, file: external.source, contract: null, external };
    }
    const own = this.file(fromFile)?.contracts.filter((c) => c.name === name) ?? [];
    if (own.length === 1) return { key: `${fromFile}:${name}`, name, file: fromFile, contract: own[0], external: null };
    const candidates = [];
    for (const f of this.visibleFiles(fromFile)) {
      for (const c of this.file(f)?.contracts ?? []) if (c.name === name) candidates.push({ file: f, contract: c });
    }
    if (candidates.length === 1) {
      const [{ file, contract }] = candidates;
      return { key: `${file}:${name}`, name, file, contract, external: null };
    }
    if (candidates.length > 1) {
      throw new Error(`${fromFile}: base '${name}' is ambiguous (${candidates.map((c) => c.file).join(", ")})`);
    }
    const external = this.policy.externalContracts?.[name];
    if (external) return { key: `external:${name}`, name, file: external.source, contract: null, external };
    throw new Error(`${fromFile}: cannot resolve base '${name}'; declare it in ${POLICY_RELATIVE_PATH} externalContracts`);
  }

  basesOf(node) {
    if (node.external) return node.external.bases.map((b) => this.resolve(b, `external:${node.name}`));
    return node.contract.bases
      .map((b) => this.resolve(b, node.file))
      .filter((b) => !(b.contract && (b.contract.kind === "interface" || b.contract.kind === "library")));
  }

  /** C3 linearization, most-derived first, exactly as solc orders bases. */
  linearize(node, stack = []) {
    if (this.linearizations.has(node.key)) return this.linearizations.get(node.key);
    if (stack.includes(node.key)) throw new Error(`inheritance cycle: ${[...stack, node.key].join(" -> ")}`);
    const bases = this.basesOf(node);
    const reversed = [...bases].reverse();
    const sequences = reversed.map((b) => [...this.linearize(b, [...stack, node.key])]);
    sequences.push(reversed);
    const result = [node];
    for (;;) {
      const live = sequences.filter((s) => s.length > 0);
      if (live.length === 0) break;
      const head = live
        .map((s) => s[0])
        .find((candidate) => !live.some((s) => s.slice(1).some((x) => x.key === candidate.key)));
      if (!head) throw new Error(`${node.file}:${node.name}: linearization of inheritance graph is impossible`);
      result.push(head);
      for (const s of live) if (s[0].key === head.key) s.shift();
    }
    this.linearizations.set(node.key, result);
    return result;
  }
}

function nodeStorage(node) {
  return node.external ? [...node.external.linearStorage] : [...node.contract.stateVariables];
}

function nodeNamespaces(node) {
  if (node.external) return node.external.namespaces.map((ns) => ({ id: ns.id, slot: erc7201Slot(ns.id) }));
  return node.contract.namespaces.map((ns) => ({ id: ns.id, slot: ns.slot }));
}

function nodeUnstructured(node) {
  if (node.external) {
    return (node.external.unstructuredSlots ?? []).map((u) => ({
      name: u.name,
      slot: u.derivation === "eip1967" ? eip1967Slot(u.id) : u.slot.toLowerCase(),
      derivation: u.derivation
    }));
  }
  return node.contract.unstructuredSlots.map((u) => ({ name: u.name, slot: u.slot, derivation: u.derivation }));
}

// ---------------------------------------------------------------------------
// Manifest construction
// ---------------------------------------------------------------------------

/** Recursively key-sorted JSON without insignificant whitespace (digest preimage only). */
export function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

/**
 * Computes the reserved-slot table from the policy, recomputing each slot from its id.
 * @param {object} policy Parsed policy.
 * @returns {{reserved: object[], problems: object[]}}
 */
export function reservedSlotTable(policy) {
  const problems = [];
  const reserved = (policy.reservedSlots ?? []).map((r) => {
    const slot = r.derivation === "eip1967" ? eip1967Slot(r.id) : r.slot.toLowerCase();
    if (r.slot && r.slot.toLowerCase() !== slot) {
      problems.push({ code: "policy-integrity", message: `reserved slot ${r.name} declares ${r.slot} but ${r.id} derives ${slot}` });
    }
    return { name: r.name, standard: r.standard, id: r.id, slot };
  });
  for (const [name, ext] of Object.entries(policy.externalContracts ?? {})) {
    for (const ns of ext.namespaces ?? []) {
      const slot = erc7201Slot(ns.id);
      if (ns.slot && ns.slot.toLowerCase() !== slot) {
        problems.push({ code: "policy-integrity", message: `external ${name} declares erc7201:${ns.id} at ${ns.slot} but the formula gives ${slot}` });
      }
    }
  }
  return { reserved, problems };
}

/**
 * Builds the slot/namespace manifest for a set of modules and reports every collision.
 * Pure: all inputs are passed in, so the self-tests can use synthetic sources.
 * @param {{sources: Map<string, string>, modules: Array<{name: string, sourcePath: string}>, policy: object}} input
 * @returns {{manifest: object, problems: Array<{code: string, message: string}>}}
 */
export function buildNamespaceManifest({ sources, modules, policy }) {
  const resolver = new Resolver(sources, policy);
  const { reserved, problems } = reservedSlotTable(policy);
  const reservedBySlot = new Map(reserved.map((r) => [r.slot, r]));

  // 1. Source-level checks over every parseable file: annotation/constant agreement and the
  //    global namespace-definer registry (duplicate namespace detection).
  const definers = new Map();
  const addDefiner = (id, slot, definer) => {
    if (!definers.has(id)) definers.set(id, { slot, definers: new Set() });
    definers.get(id).definers.add(definer);
  };
  for (const path of [...sources.keys()].sort()) {
    const parsed = resolver.file(path);
    for (const contract of parsed?.contracts ?? []) {
      for (const ns of contract.namespaces) {
        addDefiner(ns.id, ns.slot, `${path}:${contract.name}`);
        if (ns.annotated && !ns.constant) {
          problems.push({
            code: "namespace-slot-mismatch",
            message: `${path}:${contract.name} annotates erc7201:${ns.id} but declares no bytes32 constant equal to its formula slot ${ns.slot}`
          });
        }
      }
    }
  }
  for (const [name, ext] of Object.entries(policy.externalContracts ?? {})) {
    for (const ns of ext.namespaces ?? []) addDefiner(ns.id, erc7201Slot(ns.id), `external:${name}`);
  }
  for (const [id, entry] of [...definers].sort(([a], [b]) => a.localeCompare(b))) {
    if (entry.definers.size > 1) {
      problems.push({
        code: "duplicate-namespace",
        message: `erc7201:${id} (${entry.slot}) is defined by more than one contract: ${[...entry.definers].sort().join(", ")}`
      });
    }
  }
  const slotOwners = new Map();
  for (const [id, entry] of definers) {
    if (!slotOwners.has(entry.slot)) slotOwners.set(entry.slot, []);
    slotOwners.get(entry.slot).push(id);
  }
  for (const [slot, ids] of slotOwners) {
    if (ids.length > 1) problems.push({ code: "slot-overlap", message: `namespaces ${ids.sort().join(", ")} compute the same slot ${slot}` });
    if (reservedBySlot.has(slot)) {
      problems.push({ code: "reserved-slot-reuse", message: `namespace erc7201:${ids[0]} computes the ERC-1967 ${reservedBySlot.get(slot).name} ${slot}` });
    }
  }

  // 2. Per-module composition.
  const moduleEntries = {};
  const registry = new Map();
  for (const mod of [...modules].sort((a, b) => a.name.localeCompare(b.name))) {
    const parsed = resolver.file(mod.sourcePath);
    const root = parsed?.contracts.find((c) => c.name === mod.name && c.kind === "contract");
    if (!root) {
      problems.push({ code: "coverage", message: `${mod.name}: contract not found in ${mod.sourcePath}` });
      continue;
    }
    let linearization;
    try {
      linearization = resolver.linearize({ key: `${mod.sourcePath}:${mod.name}`, name: mod.name, file: mod.sourcePath, contract: root, external: null });
    } catch (error) {
      problems.push({ code: "inheritance", message: `${mod.name}: ${error.message}` });
      continue;
    }

    const storageOrder = [...linearization]
      .reverse()
      .map((node) => ({ contract: node.name, variables: nodeStorage(node) }))
      .filter((entry) => entry.variables.length > 0);

    const namespaces = [];
    const unstructured = [];
    for (const node of linearization) {
      for (const ns of nodeNamespaces(node)) namespaces.push({ id: ns.id, slot: ns.slot, definedBy: node.name });
      for (const u of nodeUnstructured(node)) unstructured.push({ name: u.name, slot: u.slot, derivation: u.derivation, definedBy: node.name });
      if (!node.external) {
        for (const literal of node.contract.hexLiterals) {
          const hit = reservedBySlot.get(literal);
          if (hit) {
            problems.push({
              code: "reserved-slot-reuse",
              message: `${mod.name}: ${node.file}:${node.name} references the ERC-1967 ${hit.name} (${literal}); module storage must never address proxy-reserved slots`
            });
          }
        }
      }
    }
    namespaces.sort((a, b) => a.id.localeCompare(b.id));
    unstructured.sort((a, b) => a.slot.localeCompare(b.slot) || a.name.localeCompare(b.name));

    // Overlap: every computed slot of the composed module must be distinct and must not fall
    // inside a namespace's 256-slot aligned window, and none may be an ERC-1967 reserved slot.
    const computed = [
      ...namespaces.map((ns) => ({ label: `erc7201:${ns.id} (${ns.definedBy})`, slot: ns.slot, kind: "namespace" })),
      ...unstructured.map((u) => ({ label: `${u.definedBy}.${u.name}`, slot: u.slot, kind: "unstructured" }))
    ];
    const seen = new Map();
    for (const entry of computed) {
      const hit = reservedBySlot.get(entry.slot);
      if (hit) {
        problems.push({ code: "reserved-slot-reuse", message: `${mod.name}: ${entry.label} occupies the ERC-1967 ${hit.name} ${entry.slot}` });
      }
      if (seen.has(entry.slot) && seen.get(entry.slot) !== entry.label) {
        problems.push({ code: "slot-overlap", message: `${mod.name}: ${entry.label} and ${seen.get(entry.slot)} compute the same slot ${entry.slot}` });
      }
      seen.set(entry.slot, entry.label);
    }
    for (const ns of namespaces) {
      const base = BigInt(ns.slot);
      for (const other of [...computed, ...reserved.map((r) => ({ label: `ERC-1967 ${r.name}`, slot: r.slot, kind: "reserved" }))]) {
        if (other.slot === ns.slot) continue;
        const value = BigInt(other.slot);
        if (value > base && value <= base + 255n) {
          problems.push({
            code: other.kind === "reserved" ? "reserved-slot-reuse" : "slot-overlap",
            message: `${mod.name}: ${other.label} (${other.slot}) falls inside the 256-slot window of erc7201:${ns.id} (${ns.slot})`
          });
        }
      }
    }

    const entry = {
      sourcePath: mod.sourcePath,
      linearization: linearization.map((n) => n.name),
      storageOrder,
      namespaces,
      unstructuredSlots: unstructured,
      reservedSlots: reserved.map((r) => r.name)
    };
    entry.digest = keccak256(DIGEST_DOMAIN + canonicalJson(entry));
    moduleEntries[mod.name] = entry;
    for (const ns of namespaces) {
      if (!registry.has(ns.id)) registry.set(ns.id, { id: ns.id, slot: ns.slot, definedBy: ns.definedBy, modules: [] });
      registry.get(ns.id).modules.push(mod.name);
    }
  }

  const manifest = {
    schemaVersion: MANIFEST_SCHEMA_VERSION,
    issue: "V2-SC-159",
    generator: "scripts/check-storage-namespaces.mjs",
    derivations: {
      erc7201: "keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff))",
      eip1967: "bytes32(uint256(keccak256(bytes(id))) - 1)"
    },
    reservedSlots: reserved,
    namespaces: [...registry.values()].sort((a, b) => a.id.localeCompare(b.id)),
    modules: moduleEntries
  };
  return { manifest, problems };
}

/**
 * Serializes the manifest deterministically (construction order is already canonical).
 * @param {object} manifest Manifest.
 * @returns {string} JSON text with a trailing newline.
 */
export function serializeManifest(manifest) {
  return `${JSON.stringify(manifest, null, 2)}\n`;
}

// ---------------------------------------------------------------------------
// Upgrade-transition classification
// ---------------------------------------------------------------------------

const withoutGap = (vars) => vars.filter((v) => v !== "__gap");
const isPrefix = (prefix, full, eq = (a, b) => a === b) => prefix.length <= full.length && prefix.every((x, i) => eq(x, full[i]));

/**
 * Classifies the transition from a committed module entry to a regenerated one.
 * Unsafe changes are the ones that move or orphan existing state; safe ones are appends.
 * @param {string} name Module name.
 * @param {object | undefined} before Committed entry.
 * @param {object | undefined} after Regenerated entry.
 * @returns {{unsafe: Array<{code: string, message: string}>, safe: string[]}}
 */
export function classifyTransition(name, before, after) {
  const unsafe = [];
  const safe = [];
  if (!before && after) return { unsafe, safe: [`${name}: new module`] };
  if (before && !after) return { unsafe: [{ code: "module-removed", message: `${name}: module removed from the namespace manifest` }], safe };
  if (!before && !after) return { unsafe, safe };

  const beforeOrder = before.storageOrder.map((s) => s.contract);
  const afterOrder = after.storageOrder.map((s) => s.contract);
  if (!isPrefix(beforeOrder, afterOrder)) {
    unsafe.push({
      code: "inheritance-reorder",
      message: `${name}: linear storage contributor order changed from [${beforeOrder.join(", ")}] to [${afterOrder.join(", ")}]; inherited slots would move`
    });
  } else {
    for (const added of afterOrder.slice(beforeOrder.length)) safe.push(`${name}: appended storage contributor ${added}`);
    before.storageOrder.forEach((contributor, i) => {
      const bv = withoutGap(contributor.variables);
      const av = withoutGap(after.storageOrder[i].variables);
      if (!isPrefix(bv, av)) {
        unsafe.push({
          code: "layout-reorder",
          message: `${name}: variables of ${contributor.contract} changed from [${bv.join(", ")}] to [${av.join(", ")}]; only appends are upgrade-safe`
        });
      } else if (av.length > bv.length) {
        safe.push(`${name}: appended [${av.slice(bv.length).join(", ")}] to ${contributor.contract}`);
      }
    });
  }

  const afterNamespaces = new Map(after.namespaces.map((ns) => [ns.id, ns]));
  for (const ns of before.namespaces) {
    const now = afterNamespaces.get(ns.id);
    if (!now) unsafe.push({ code: "namespace-removed", message: `${name}: erc7201:${ns.id} (${ns.slot}) is no longer composed; its state would be orphaned` });
    else if (now.slot !== ns.slot) unsafe.push({ code: "namespace-moved", message: `${name}: erc7201:${ns.id} moved from ${ns.slot} to ${now.slot}` });
  }
  const beforeIds = new Set(before.namespaces.map((ns) => ns.id));
  for (const ns of after.namespaces) if (!beforeIds.has(ns.id)) safe.push(`${name}: appended namespace erc7201:${ns.id}`);

  const afterUnstructured = new Map(after.unstructuredSlots.map((u) => [`${u.definedBy}.${u.name}`, u]));
  for (const u of before.unstructuredSlots) {
    const now = afterUnstructured.get(`${u.definedBy}.${u.name}`);
    if (!now) unsafe.push({ code: "unstructured-slot-removed", message: `${name}: unstructured slot ${u.definedBy}.${u.name} (${u.slot}) was removed` });
    else if (now.slot !== u.slot) unsafe.push({ code: "unstructured-slot-moved", message: `${name}: unstructured slot ${u.definedBy}.${u.name} moved from ${u.slot} to ${now.slot}` });
  }
  return { unsafe, safe };
}

/**
 * Classifies every module transition between two manifests.
 * @param {object | null} committed Committed manifest (null when absent).
 * @param {object} regenerated Regenerated manifest.
 * @returns {{unsafe: object[], safe: string[]}}
 */
export function classifyManifestTransition(committed, regenerated) {
  const unsafe = [];
  const safe = [];
  if (!committed) return { unsafe, safe: ["namespace manifest created"] };
  const names = new Set([...Object.keys(committed.modules ?? {}), ...Object.keys(regenerated.modules ?? {})]);
  for (const name of [...names].sort()) {
    const result = classifyTransition(name, committed.modules?.[name], regenerated.modules?.[name]);
    unsafe.push(...result.unsafe);
    safe.push(...result.safe);
  }
  return { unsafe, safe };
}

// ---------------------------------------------------------------------------
// Integration with the V2-SC-121 frozen storage-layout manifest
// ---------------------------------------------------------------------------

/**
 * Module set of the V2-SC-121 frozen manifest.
 * @param {object} frozen Parsed storage-layouts/manifest.json.
 * @returns {Array<{name: string, sourcePath: string}>}
 */
export function modulesFromFrozenLayout(frozen) {
  return Object.entries(frozen.contracts ?? {})
    .map(([name, entry]) => ({ name, sourcePath: entry.sourcePath }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** Frozen linear variable order (by slot, then offset), labels stripped of the `@slot` suffix. */
export function frozenLinearOrder(entry) {
  return Object.entries(entry.slots ?? {})
    .map(([label, v]) => ({ name: label.split("@")[0], slot: BigInt(v.slot), offset: Number(v.offset) }))
    .sort((a, b) => (a.slot === b.slot ? a.offset - b.offset : a.slot < b.slot ? -1 : 1))
    .map((v) => v.name);
}

/**
 * Compares the source-derived linear order with the compiler-derived frozen layout.
 * @param {object} manifest Regenerated namespace manifest.
 * @param {object} frozen Frozen storage-layout manifest.
 * @param {object} policy Policy with acknowledged discrepancies.
 * @returns {Array<{code: string, message: string}>}
 */
export function checkFrozenLayoutAgreement(manifest, frozen, policy) {
  const problems = [];
  const acknowledged = new Map((policy.acknowledgedLayoutDiscrepancies ?? []).map((d) => [d.module, d]));
  const frozenNames = new Set(Object.keys(frozen.contracts ?? {}));
  for (const name of Object.keys(manifest.modules)) {
    if (!frozenNames.has(name)) problems.push({ code: "coverage", message: `${name}: present in the namespace manifest but not frozen by ${FROZEN_LAYOUT_RELATIVE_PATH}` });
  }
  for (const name of [...frozenNames].sort()) {
    const entry = manifest.modules[name];
    if (!entry) {
      problems.push({ code: "coverage", message: `${name}: frozen by ${FROZEN_LAYOUT_RELATIVE_PATH} but has no slot/namespace manifest entry` });
      continue;
    }
    const derived = entry.storageOrder.flatMap((s) => s.variables);
    const frozenOrder = frozenLinearOrder(frozen.contracts[name]);
    const agrees = derived.length === frozenOrder.length && derived.every((v, i) => v === frozenOrder[i]);
    const ack = acknowledged.get(name);
    if (!agrees && !ack) {
      problems.push({
        code: "layout-discrepancy",
        message: `${name}: source-derived linear order [${derived.join(", ")}] disagrees with the frozen layout [${frozenOrder.join(", ")}]`
      });
    } else if (agrees && ack) {
      problems.push({ code: "layout-discrepancy", message: `${name}: acknowledged layout discrepancy is stale — the orders now agree; remove the policy entry` });
    } else if (ack && (!ack.rationale || ack.rationale.trim().length < 40)) {
      problems.push({ code: "layout-discrepancy", message: `${name}: acknowledged layout discrepancy needs a meaningful rationale` });
    }
  }
  for (const name of acknowledged.keys()) {
    if (!frozenNames.has(name)) problems.push({ code: "layout-discrepancy", message: `${name}: acknowledged discrepancy names a module that is not frozen` });
  }
  return problems;
}

/**
 * When `npm ci` has installed OpenZeppelin, verifies the policy's external declarations against
 * the real sources (namespace slot literals present, linear storage names identical).
 * @param {object} policy Policy.
 * @param {string} [rootDir] Repository root.
 * @returns {{problems: object[], checked: number}}
 */
export function crossCheckExternalContracts(policy, rootDir = REPO_ROOT) {
  const problems = [];
  let checked = 0;
  for (const [name, ext] of Object.entries(policy.externalContracts ?? {})) {
    if (!ext.source.startsWith("@openzeppelin/contracts/")) continue;
    const file = resolve(rootDir, EXTERNAL_PACKAGE_ROOT, ext.source.slice("@openzeppelin/contracts/".length));
    if (!existsSync(file)) continue;
    const source = readFileSync(file, "utf8");
    const contract = parseSolidity(source).contracts.find((c) => c.name === name);
    if (!contract) continue;
    checked++;
    const declared = ext.linearStorage.join(", ");
    const actual = contract.stateVariables.join(", ");
    if (declared !== actual) {
      problems.push({ code: "external-drift", message: `${name}: policy declares linear storage [${declared}] but ${ext.source} declares [${actual}]` });
    }
    for (const ns of ext.namespaces ?? []) {
      if (!source.toLowerCase().includes(erc7201Slot(ns.id).slice(2))) {
        problems.push({ code: "external-drift", message: `${name}: ${ext.source} no longer contains the erc7201:${ns.id} slot ${erc7201Slot(ns.id)}` });
      }
    }
    for (const ns of contract.namespaces) {
      if (!(ext.namespaces ?? []).some((d) => d.id === ns.id)) {
        problems.push({ code: "external-drift", message: `${name}: ${ext.source} defines erc7201:${ns.id}, which the policy does not declare` });
      }
    }
  }
  return { problems, checked };
}

// ---------------------------------------------------------------------------
// Repository run
// ---------------------------------------------------------------------------

/**
 * Runs every check against the repository.
 * @param {string} [rootDir] Repository root.
 * @returns {{manifest: object, serialized: string, committed: string | null, problems: object[], transition: object, externalChecked: number}}
 */
export function checkRepository(rootDir = REPO_ROOT) {
  const policy = JSON.parse(readFileSync(resolve(rootDir, POLICY_RELATIVE_PATH), "utf8"));
  const frozen = JSON.parse(readFileSync(resolve(rootDir, FROZEN_LAYOUT_RELATIVE_PATH), "utf8"));
  const sources = loadRepositorySources(rootDir);
  const { manifest, problems } = buildNamespaceManifest({ sources, modules: modulesFromFrozenLayout(frozen), policy });
  problems.push(...checkFrozenLayoutAgreement(manifest, frozen, policy));
  const external = crossCheckExternalContracts(policy, rootDir);
  problems.push(...external.problems);

  const manifestPath = resolve(rootDir, MANIFEST_RELATIVE_PATH);
  const committed = existsSync(manifestPath) ? readFileSync(manifestPath, "utf8").replace(/\r\n/g, "\n") : null;
  const transition = classifyManifestTransition(committed ? JSON.parse(committed) : null, manifest);
  const serialized = serializeManifest(manifest);
  return { manifest, serialized, committed, problems, transition, externalChecked: external.checked };
}

function main() {
  const args = new Set(process.argv.slice(2));
  const result = checkRepository();

  if (args.has("--report")) {
    for (const [name, entry] of Object.entries(result.manifest.modules)) {
      console.log(`${name} (${entry.sourcePath})`);
      console.log(`  linearization: ${entry.linearization.join(" <- ")}`);
      console.log(`  storage order: ${entry.storageOrder.map((s) => `${s.contract}[${s.variables.join(",")}]`).join(" | ")}`);
      console.log(`  namespaces:    ${entry.namespaces.map((ns) => `${ns.id}@${ns.slot}`).join(", ") || "(none)"}`);
      console.log(`  unstructured:  ${entry.unstructuredSlots.map((u) => `${u.definedBy}.${u.name}@${u.slot}`).join(", ") || "(none)"}`);
    }
    for (const p of result.problems) console.log(`  ! [${p.code}] ${p.message}`);
    process.exit(0);
  }

  if (args.has("--write")) {
    if (result.problems.length > 0) {
      console.error(`❌ Refusing to write ${MANIFEST_RELATIVE_PATH}: resolve these problems first:`);
      for (const p of result.problems) console.error(`  - [${p.code}] ${p.message}`);
      process.exit(1);
    }
    if (result.transition.unsafe.length > 0 && !args.has("--allow-unsafe-transition")) {
      console.error(`❌ Refusing to write ${MANIFEST_RELATIVE_PATH}: the change is not upgrade-safe:`);
      for (const p of result.transition.unsafe) console.error(`  - [${p.code}] ${p.message}`);
      console.error("   A reviewed layout-breaking migration may pass --allow-unsafe-transition (see docs/storage-namespace-collisions.md).");
      process.exit(1);
    }
    writeFileSync(resolve(REPO_ROOT, MANIFEST_RELATIVE_PATH), result.serialized);
    for (const s of result.transition.safe) console.log(`  + ${s}`);
    console.log(`✓ Wrote ${MANIFEST_RELATIVE_PATH} (${Object.keys(result.manifest.modules).length} module(s)).`);
    process.exit(0);
  }

  console.log("==> Verifying storage namespace and reserved-slot isolation (V2-SC-159)...");
  const problems = [...result.problems, ...result.transition.unsafe];
  if (result.committed === null) {
    problems.push({ code: "manifest-drift", message: `${MANIFEST_RELATIVE_PATH} is missing; run with --write after review` });
  } else if (result.committed !== result.serialized) {
    problems.push({
      code: "manifest-drift",
      message: `${MANIFEST_RELATIVE_PATH} is out of date${result.transition.safe.length ? ` (${result.transition.safe.join("; ")})` : ""}; run node scripts/check-storage-namespaces.mjs --write and commit the reviewed diff`
    });
  }
  if (problems.length === 0) {
    const modules = Object.keys(result.manifest.modules).length;
    console.log(
      `✓ ${modules} upgradeable module(s): ${result.manifest.namespaces.length} ERC-7201 namespace(s), ` +
        `${result.manifest.reservedSlots.length} ERC-1967 reserved slot(s), no collisions, manifest up to date` +
        (result.externalChecked ? `, ${result.externalChecked} OpenZeppelin declaration(s) cross-checked.` : ".")
    );
    process.exit(0);
  }
  console.error(`\n❌ Storage namespace check failed (${problems.length} problem(s)):`);
  for (const p of problems) console.error(`  - [${p.code}] ${p.message}`);
  process.exit(1);
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(__filename)) {
  try {
    main();
  } catch (error) {
    console.error("Fatal error during storage namespace check:", error);
    process.exit(1);
  }
}

export { REPO_ROOT };
