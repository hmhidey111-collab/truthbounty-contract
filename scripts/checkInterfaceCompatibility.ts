/**
 * V2-SC-135 — Build Protocol Interface Compatibility Matrix
 *
 * Compares interface ids, selectors, errors, structs, enums, events, and
 * version declarations across the canonical V2 modules and the published
 * off-chain artifacts, emits the matrix as a machine-readable manifest plus a
 * reviewable Markdown table, and fails closed on drift or on a documented
 * compatibility invariant violation.
 *
 * Source-derived (no compiler required). User-defined enums resolve to `uint8`
 * and structs to `tuple`/`(...)`, exactly as the Solidity ABI encoder
 * canonicalizes them.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { id } from "ethers";

export const COMPAT_MATRIX_SCHEMA_VERSION = 1;
export const COMPAT_PROTOCOL_VERSION = { major: 2, minor: 0 } as const;
export const COMPAT_MATRIX_JSON = "config/interface-compatibility-matrix.json";
export const COMPAT_MATRIX_DOC = "docs/v2/interface-compatibility-matrix.md";
export const PUBLISHED_EVENT_SCHEMA = "schemas/event-schema-v1.json";

/** Canonical module interfaces compared by the matrix. */
export const COMPAT_MODULE_SOURCES: Record<string, string> = {
  IConfiguration: "contracts/v2/interfaces/IConfiguration.sol",
  IModuleRegistry: "contracts/v2/interfaces/IModuleRegistry.sol",
  IClaims: "contracts/v2/interfaces/IClaims.sol",
  IEvidence: "contracts/v2/interfaces/IEvidence.sol",
  IStakeCustody: "contracts/v2/interfaces/IStakeCustody.sol",
  IVerification: "contracts/v2/interfaces/IVerification.sol",
  IAggregation: "contracts/v2/interfaces/IAggregation.sol",
  ISettlement: "contracts/v2/interfaces/ISettlement.sol",
  IDisputes: "contracts/v2/interfaces/IDisputes.sol",
  IRewards: "contracts/v2/interfaces/IRewards.sol",
  ISlashing: "contracts/v2/interfaces/ISlashing.sol",
  ITreasury: "contracts/v2/interfaces/ITreasury.sol",
  IReputationRoots: "contracts/v2/interfaces/IReputationRoots.sol",
  IGovernanceHooks: "contracts/v2/interfaces/IGovernanceHooks.sol",
  IEmergencyControls: "contracts/v2/interfaces/IEmergencyControls.sol",
  IFinalRewardAllocator: "contracts/v2/interfaces/IFinalRewardAllocator.sol",
};

export const COMPAT_BASE_MODULE_SOURCE = "contracts/v2/interfaces/IV2Module.sol";
export const COMPAT_AGGREGATE_MODULE_SOURCE = "contracts/v2/interfaces/ICanonicalV2.sol";
export const COMPAT_TYPE_REGISTRY_SOURCE = "contracts/v2/interfaces/IV2Types.sol";
export const COMPAT_VERSION_FIXTURE_SOURCE = "contracts/v2/interfaces/V2ConformanceFixture.sol";

/**
 * Selectors deliberately shared across modules. Each entry must be reviewed:
 * sharing a selector is only compatible when the selector carries the same
 * meaning in every module that exposes it.
 */
export const INTENTIONAL_SHARED_FUNCTIONS: Record<string, string> = {
  "protocolVersion()": "IV2Module base discovery surface; identical meaning in every module",
};

/** Canonical modules intentionally absent from the ICanonicalV2 aggregate manifest. */
export const INTENTIONAL_AGGREGATE_OMISSIONS: Record<string, string> = {
  IFinalRewardAllocator:
    "Published extension surface for the reward allocator; ICanonicalV2 names the 15 ownership modules from docs/v2/interface-ownership.md.",
};

/**
 * Event names deliberately emitted by more than one module. Distinct
 * signatures under one name are compatible only when consumers decode by
 * topic0 rather than by name.
 */
export const INTENTIONAL_EVENT_NAME_COLLISIONS: Record<string, string> = {
  RewardClaimed:
    "IRewards.RewardClaimed(address,uint256,uint64,uint16) and IFinalRewardAllocator.RewardClaimed(address,address,uint256) are distinct topic0 values; decode by topic0.",
};

export interface CompatibilityEntry {
  signature: string;
  hash: string;
  declaredIn: string;
}

export interface ModuleMatrixRow {
  name: string;
  source: string;
  kind: "module" | "base" | "aggregate" | "types";
  interfaceId: string;
  inherits: string[];
  functionCount: number;
  errorCount: number;
  eventCount: number;
  declaresProtocolVersion: boolean;
  declaresSupportsInterface: boolean;
  structs: string[];
  enums: string[];
  referencedStructs: string[];
  referencedEnums: string[];
  functions: CompatibilityEntry[];
  errors: CompatibilityEntry[];
  events: CompatibilityEntry[];
  digest: string;
}

export interface SharedSurface {
  signature: string;
  selector: string;
  modules: string[];
  intentional: boolean;
  note: string;
}

export interface InterfaceCompatibilityMatrix {
  schemaVersion: number;
  kind: "truthbounty.interface-compatibility-matrix";
  protocol: string;
  protocolVersion: { major: number; minor: number };
  sources: {
    modules: string;
    base: string;
    aggregate: string;
    typeRegistry: string;
    versionFixture: string;
    publishedEventSchema: string;
  };
  modules: ModuleMatrixRow[];
  aggregateManifest: {
    name: string | null;
    inherits: string[];
    declaredMembers: number;
    notNamed: string[];
    undocumentedOmissions: string[];
  };
  sharedFunctions: SharedSurface[];
  sharedErrors: SharedSurface[];
  eventNameCollisions: Array<{ name: string; signatures: string[]; modules: string[] }>;
  crossArtifacts: {
    canonicalEventTopics: number;
    publishedEventTopics: number;
    publishedTopicOverlap: number;
    publishedTopicsNotCanonical: number;
    canonicalTopicsNotPublished: number;
    versionFixtureDeclaration: string | null;
    documentedDivergences: string[];
  };
  invariants: Array<{ id: string; status: "pass" | "fail"; detail: string }>;
  digest: string;
}

export class CompatibilityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CompatibilityError";
  }
}

const ELEMENTARY_TYPES = new Set([
  "bool",
  "string",
  "bytes",
  "address",
  "uint8",
  "uint16",
  "uint32",
  "uint64",
  "uint128",
  "uint256",
  "int8",
  "int16",
  "int32",
  "int64",
  "int128",
  "int256",
  "bytes1",
  "bytes2",
  "bytes4",
  "bytes8",
  "bytes16",
  "bytes20",
  "bytes32",
]);

interface RawParameter {
  name: string;
  type: string;
  indexed: boolean;
}

interface RawEntry {
  kind: "function" | "error" | "event";
  name: string;
  inputs: RawParameter[];
}

interface ParsedInterface {
  name: string;
  inherits: string[];
  functions: RawEntry[];
  errors: RawEntry[];
  events: RawEntry[];
  structs: Array<{ name: string; fields: RawParameter[] }>;
  enums: string[];
}

interface TypeRegistry {
  enums: Set<string>;
  structs: Map<string, RawParameter[]>;
}

function stripComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
}

function readGroup(text: string, openIndex: number, open: string, close: string): { inner: string; end: number } {
  let depth = 0;
  for (let i = openIndex; i < text.length; i += 1) {
    if (text[i] === open) depth += 1;
    else if (text[i] === close) {
      depth -= 1;
      if (depth === 0) return { inner: text.slice(openIndex + 1, i), end: i };
    }
  }
  throw new CompatibilityError(`Unbalanced ${open}${close} group`);
}

function splitTopLevel(text: string, separator = ","): string[] {
  const parts: string[] = [];
  let depth = 0;
  let current = "";
  for (const char of text) {
    if (char === "(" || char === "[") depth += 1;
    if (char === ")" || char === "]") depth -= 1;
    if (char === separator && depth === 0) {
      parts.push(current);
      current = "";
    } else {
      current += char;
    }
  }
  if (current.trim().length > 0) parts.push(current);
  return parts;
}

function baseElementaryType(raw: string): string {
  const alias = raw.match(/^(uint|int)(\[[0-9]*\])*$/);
  if (alias) return `${alias[1]}256${alias[2] ?? ""}`;
  return raw;
}

function parseParameters(raw: string): RawParameter[] {
  const params: RawParameter[] = [];
  for (const chunk of splitTopLevel(raw)) {
    const trimmed = chunk.replace(/\s+/g, " ").trim();
    if (trimmed.length === 0) continue;
    const tokens = trimmed.split(" ");
    let indexed = false;
    const typeTokens: string[] = [];
    let name = "";
    for (const token of tokens) {
      if (token === "indexed") indexed = true;
      else if (token === "memory" || token === "calldata" || token === "storage" || token === "payable") continue;
      else if (typeTokens.length === 0) typeTokens.push(token);
      else name = token;
    }
    if (typeTokens.length === 0) continue;
    params.push({ name, type: baseElementaryType(typeTokens.join("")), indexed });
  }
  return params;
}

function parseInterfaceSource(source: string, sourcePath: string): ParsedInterface {
  const cleaned = stripComments(source);
  const declRe = /(?:^|\n)\s*(?:abstract\s+)?(?:interface|contract)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:is\s+([^{]+?))?\s*\{/;
  const decl = declRe.exec(cleaned);
  if (!decl) throw new CompatibilityError(`No interface or contract declaration found in ${sourcePath}`);
  const inherits = (decl[2] ?? "")
    .split(",")
    .map((entry) => entry.replace(/\(.*\)$/, "").trim())
    .filter((entry) => entry.length > 0);

  let body = readGroup(cleaned, decl.index + decl[0].length - 1, "{", "}").inner;
  const structs: Array<{ name: string; fields: RawParameter[] }> = [];
  const enums: string[] = [];
  const ranges: Array<[number, number]> = [];

  const structRe = /\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{/g;
  let structMatch: RegExpExecArray | null;
  while ((structMatch = structRe.exec(body)) !== null) {
    const open = structMatch.index + structMatch[0].length - 1;
    const { inner, end } = readGroup(body, open, "{", "}");
    structs.push({ name: structMatch[1], fields: parseParameters(splitTopLevel(inner, ";").join(",")) });
    ranges.push([structMatch.index, end]);
  }
  const enumRe = /\benum\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{/g;
  let enumMatch: RegExpExecArray | null;
  while ((enumMatch = enumRe.exec(body)) !== null) {
    const open = enumMatch.index + enumMatch[0].length - 1;
    const { end } = readGroup(body, open, "{", "}");
    enums.push(enumMatch[1]);
    ranges.push([enumMatch.index, end]);
  }
  ranges.sort((a, b) => b[0] - a[0]);
  for (const [start, end] of ranges) {
    body = body.slice(0, start) + " ".repeat(end - start + 1) + body.slice(end + 1);
  }

  const functions: RawEntry[] = [];
  const errors: RawEntry[] = [];
  const events: RawEntry[] = [];
  for (const chunk of body.split(";")) {
    const declaration = chunk.replace(/\s+/g, " ").trim();
    if (declaration.length === 0) continue;
    const match = /^(function|error|event)\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/.exec(declaration);
    if (!match) continue;
    const kind = match[1] as "function" | "error" | "event";
    const open = declaration.indexOf("(", match[0].length - 1);
    const inputs = parseParameters(readGroup(declaration, open, "(", ")").inner);
    const entry: RawEntry = { kind, name: match[2], inputs };
    if (kind === "function") functions.push(entry);
    else if (kind === "error") errors.push(entry);
    else events.push(entry);
  }

  const sortByName = (a: RawEntry, b: RawEntry) => a.name.localeCompare(b.name);
  return {
    name: decl[1],
    inherits,
    functions: functions.sort(sortByName),
    errors: errors.sort(sortByName),
    events: events.sort(sortByName),
    structs: structs.sort((a, b) => a.name.localeCompare(b.name)),
    enums: enums.sort(),
  };
}

function registerTypes(parsed: ParsedInterface, registry: TypeRegistry): void {
  for (const enumName of parsed.enums) {
    registry.enums.add(enumName);
    registry.enums.add(`${parsed.name}.${enumName}`);
  }
  for (const struct of parsed.structs) {
    registry.structs.set(struct.name, struct.fields);
    registry.structs.set(`${parsed.name}.${struct.name}`, struct.fields);
  }
}

function canonicalize(raw: string, registry: TypeRegistry, usedEnums: Set<string>, usedStructs: Set<string>): string {
  const normalized = baseElementaryType(raw);
  const arrayMatch = normalized.match(/(\[[0-9]*\])+$/);
  const suffix = arrayMatch ? arrayMatch[0] : "";
  const base = suffix ? normalized.slice(0, normalized.length - suffix.length) : normalized;
  if (ELEMENTARY_TYPES.has(base)) return base + suffix;
  if (registry.enums.has(base)) {
    usedEnums.add(base);
    return `uint8${suffix}`;
  }
  const fields = registry.structs.get(base);
  if (fields) {
    usedStructs.add(base);
    const components = fields.map((field) => canonicalize(field.type, registry, usedEnums, usedStructs));
    return `(${components.join(",")})${suffix}`;
  }
  throw new CompatibilityError(`Unknown ABI type: ${raw}`);
}

function signatureOf(entry: RawEntry, registry: TypeRegistry, usedEnums: Set<string>, usedStructs: Set<string>): string {
  const types = entry.inputs.map((input) => canonicalize(input.type, registry, usedEnums, usedStructs));
  return `${entry.name}(${types.join(",")})`;
}

function stableStringify(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map((entry) => stableStringify(entry)).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableStringify(record[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value === undefined ? null : value);
}

function readSource(rootDir: string, relativePath: string): string {
  const absolute = path.join(rootDir, relativePath);
  if (!fs.existsSync(absolute)) throw new CompatibilityError(`Required source missing: ${relativePath}`);
  return fs.readFileSync(absolute, "utf-8");
}

function toRow(
  parsed: ParsedInterface,
  source: string,
  kind: ModuleMatrixRow["kind"],
  registry: TypeRegistry
): ModuleMatrixRow {
  const usedEnums = new Set<string>();
  const usedStructs = new Set<string>();
  const build = (entries: RawEntry[], hashField: "selector" | "topic0") =>
    entries
      .map((entry) => {
        const signature = signatureOf(entry, registry, usedEnums, usedStructs);
        return { signature, hash: hashField === "selector" ? id(signature).slice(0, 10) : id(signature), declaredIn: parsed.name };
      })
      .sort((a, b) => a.signature.localeCompare(b.signature));

  const functions = build(parsed.functions, "selector");
  const errors = build(parsed.errors, "selector");
  const events = build(parsed.events, "topic0");
  const interfaceId =
    parsed.functions.length === 0
      ? "0x00000000"
      : functions.reduce((acc, entry) => `0x${(BigInt(acc) ^ BigInt(entry.hash)).toString(16).padStart(8, "0")}`, "0x00000000");

  const row: ModuleMatrixRow = {
    name: parsed.name,
    source,
    kind,
    interfaceId,
    inherits: [...parsed.inherits],
    functionCount: functions.length,
    errorCount: errors.length,
    eventCount: events.length,
    declaresProtocolVersion: parsed.functions.some((entry) => entry.name === "protocolVersion"),
    declaresSupportsInterface: parsed.functions.some((entry) => entry.name === "supportsInterface"),
    structs: parsed.structs.map((struct) => struct.name),
    enums: [...parsed.enums],
    referencedStructs: [...usedStructs].sort(),
    referencedEnums: [...usedEnums].sort(),
    functions,
    errors,
    events,
    digest: "",
  };
  row.digest = id(stableStringify({ ...row, digest: undefined }));
  return row;
}

interface EffectiveSurface {
  functions: CompatibilityEntry[];
  errors: CompatibilityEntry[];
  events: CompatibilityEntry[];
}

/** Declared surface plus every inherited declaration resolvable inside the canonical set. */
export function resolveEffectiveSurfaces(rows: ModuleMatrixRow[]): Map<string, EffectiveSurface> {
  const byName = new Map(rows.map((row) => [row.name, row]));
  const memo = new Map<string, EffectiveSurface>();
  const resolve = (name: string, seen: Set<string>): EffectiveSurface => {
    const cached = memo.get(name);
    if (cached) return cached;
    const row = byName.get(name);
    if (!row || seen.has(name)) return { functions: [], errors: [], events: [] };
    const nextSeen = new Set(seen).add(name);
    const surface: EffectiveSurface = {
      functions: [...row.functions],
      errors: [...row.errors],
      events: [...row.events],
    };
    for (const parent of row.inherits) {
      const inherited = resolve(parent, nextSeen);
      for (const entry of inherited.functions) {
        if (!surface.functions.some((own) => own.signature === entry.signature)) surface.functions.push(entry);
      }
      for (const entry of inherited.errors) {
        if (!surface.errors.some((own) => own.signature === entry.signature)) surface.errors.push(entry);
      }
      for (const entry of inherited.events) {
        if (!surface.events.some((own) => own.signature === entry.signature)) surface.events.push(entry);
      }
    }
    surface.functions.sort((a, b) => a.signature.localeCompare(b.signature));
    memo.set(name, surface);
    return surface;
  };
  for (const row of rows) resolve(row.name, new Set());
  return memo;
}

function sharedSurface(
  rows: ModuleMatrixRow[],
  surfaces: Map<string, EffectiveSurface>,
  pick: (surface: EffectiveSurface) => CompatibilityEntry[],
  allowlist: Record<string, string>
): SharedSurface[] {
  const bySignature = new Map<string, { hash: string; modules: Set<string> }>();
  for (const row of rows) {
    if (row.kind !== "module") continue;
    const surface = surfaces.get(row.name);
    if (!surface) continue;
    for (const entry of pick(surface)) {
      const bucket = bySignature.get(entry.signature) ?? { hash: entry.hash, modules: new Set<string>() };
      bucket.modules.add(row.name);
      bySignature.set(entry.signature, bucket);
    }
  }
  return [...bySignature.entries()]
    .filter(([, bucket]) => bucket.modules.size > 1)
    .map(([signature, bucket]) => ({
      signature,
      selector: bucket.hash,
      modules: [...bucket.modules].sort(),
      intentional: Object.prototype.hasOwnProperty.call(allowlist, signature),
      note: allowlist[signature] ?? "Undeclared cross-module selector sharing",
    }))
    .sort((a, b) => a.signature.localeCompare(b.signature));
}

function eventNameCollisions(rows: ModuleMatrixRow[]): Array<{ name: string; signatures: string[]; modules: string[] }> {
  const byName = new Map<string, { signatures: Set<string>; modules: Set<string> }>();
  for (const row of rows) {
    if (row.kind !== "module") continue;
    for (const entry of row.events) {
      const name = entry.signature.slice(0, entry.signature.indexOf("("));
      const bucket = byName.get(name) ?? { signatures: new Set<string>(), modules: new Set<string>() };
      bucket.signatures.add(entry.signature);
      bucket.modules.add(row.name);
      byName.set(name, bucket);
    }
  }
  return [...byName.entries()]
    .filter(([, bucket]) => bucket.signatures.size > 1)
    .map(([name, bucket]) => ({
      name,
      signatures: [...bucket.signatures].sort(),
      modules: [...bucket.modules].sort(),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

function readVersionFixture(rootDir: string): string | null {
  if (!fs.existsSync(path.join(rootDir, COMPAT_VERSION_FIXTURE_SOURCE))) return null;
  const cleaned = stripComments(readSource(rootDir, COMPAT_VERSION_FIXTURE_SOURCE));
  const match = /protocolVersion\s*\(\s*\)[^{]*\{([^}]*)\}/.exec(cleaned);
  if (!match) return null;
  const tuple = /return\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)/.exec(match[1]);
  if (!tuple) return null;
  return `${tuple[1]}.${tuple[2]}`;
}

function evaluateInvariants(
  modules: ModuleMatrixRow[],
  sharedFunctions: SharedSurface[],
  sharedErrors: SharedSurface[],
  eventCollisions: Array<{ name: string; signatures: string[]; modules: string[] }>,
  versionDeclaration: string | null
): Array<{ id: string; status: "pass" | "fail"; detail: string }> {
  const results: Array<{ id: string; status: "pass" | "fail"; detail: string }> = [];
  const add = (invariantId: string, ok: boolean, detail: string) =>
    results.push({ id: invariantId, status: ok ? "pass" : "fail", detail });

  const declared = modules.filter((row) => row.kind === "module");
  const ids = declared.map((row) => row.interfaceId);
  add(
    "unique-interface-ids",
    new Set(ids).size === ids.length,
    "Every module advertises a distinct ERC-165 interface id."
  );

  const missingBase = declared.filter((row) => !row.inherits.includes("IV2Module")).map((row) => row.name);
  add(
    "module-declares-migration-base",
    missingBase.length === 0,
    missingBase.length === 0
      ? "Every module inherits IV2Module and therefore exposes protocolVersion()."
      : `Modules missing IV2Module: ${missingBase.join(", ")}`
  );

  const badSelectors = declared
    .filter((row) => new Set(row.functions.map((entry) => entry.hash)).size !== row.functions.length)
    .map((row) => row.name);
  add(
    "unique-function-selectors",
    badSelectors.length === 0,
    badSelectors.length === 0 ? "No selector collision inside any module." : `Selector collisions: ${badSelectors.join(", ")}`
  );

  const unintentional = sharedFunctions.filter((entry) => !entry.intentional);
  add(
    "declared-shared-functions",
    unintentional.length === 0,
    unintentional.length === 0
      ? "Every cross-module selector is documented in INTENTIONAL_SHARED_FUNCTIONS."
      : `Undeclared shared selectors: ${unintentional.map((entry) => entry.signature).join(", ")}`
  );

  add(
    "unique-error-selectors",
    sharedErrors.length === 0,
    sharedErrors.length === 0 ? "Error selectors are unique across modules." : `Shared error selectors: ${sharedErrors.map((e) => e.signature).join(", ")}`
  );

  const undocumentedCollisions = eventCollisions.filter(
    (collision) => !Object.prototype.hasOwnProperty.call(INTENTIONAL_EVENT_NAME_COLLISIONS, collision.name)
  );
  add(
    "documented-event-name-collisions",
    undocumentedCollisions.length === 0,
    undocumentedCollisions.length === 0
      ? "Every duplicated event name is documented as topic0-distinguished."
      : `Undocumented event name collisions: ${undocumentedCollisions.map((entry) => entry.name).join(", ")}`
  );

  const aggregate = modules.find((row) => row.kind === "aggregate");
  const named = new Set(aggregate?.inherits ?? []);
  const notNamed = declared.map((row) => row.name).filter((name) => !named.has(name));
  const undocumentedOmissions = notNamed.filter(
    (name) => !Object.prototype.hasOwnProperty.call(INTENTIONAL_AGGREGATE_OMISSIONS, name)
  );
  const extraInherited = [...named].filter((name) => !declared.some((row) => row.name === name));
  const aggregateIsManifest =
    aggregate !== undefined &&
    aggregate.functionCount === 0 &&
    aggregate.errorCount === 0 &&
    aggregate.eventCount === 0 &&
    undocumentedOmissions.length === 0 &&
    extraInherited.length === 0;
  add(
    "aggregate-is-pure-manifest",
    aggregateIsManifest,
    aggregateIsManifest
      ? "ICanonicalV2 declares no members and names every canonical module (documented extensions excepted)."
      : `ICanonicalV2 manifest mismatch: undocumented omissions [${undocumentedOmissions.join(", ")}], unknown inherited names [${extraInherited.join(", ")}]`
  );

  const allRows = modules;
  const unresolvedTypes = allRows
    .filter((row) => row.kind === "module")
    .flatMap((row) => [...row.referencedStructs, ...row.referencedEnums])
    .filter((type) => {
      const base = type.split(".").pop() as string;
      return !allRows.some((row) => row.structs.includes(base) || row.enums.includes(base));
    });
  add(
    "resolved-user-types",
    unresolvedTypes.length === 0,
    unresolvedTypes.length === 0
      ? "Every referenced struct and enum is declared by a canonical module."
      : `Unresolved user types: ${unresolvedTypes.join(", ")}`
  );

  add(
    "protocol-version-declaration",
    versionDeclaration === `${COMPAT_PROTOCOL_VERSION.major}.${COMPAT_PROTOCOL_VERSION.minor}`,
    versionDeclaration === null
      ? "Version fixture does not declare protocolVersion()."
      : `Version fixture declares protocolVersion ${versionDeclaration}.`
  );

  return results;
}

/** Build the compatibility matrix from the canonical sources and published artifacts. */
export function buildCompatibilityMatrix(rootDir: string): InterfaceCompatibilityMatrix {
  const registry: TypeRegistry = { enums: new Set(), structs: new Map() };
  const registryParsed = [COMPAT_TYPE_REGISTRY_SOURCE, COMPAT_BASE_MODULE_SOURCE, COMPAT_AGGREGATE_MODULE_SOURCE]
    .filter((source) => fs.existsSync(path.join(rootDir, source)))
    .map((source) => parseInterfaceSource(readSource(rootDir, source), source));
  for (const parsed of registryParsed) registerTypes(parsed, registry);

  const moduleNames = Object.keys(COMPAT_MODULE_SOURCES).sort();
  const parsedModules = moduleNames.map((name) =>
    parseInterfaceSource(readSource(rootDir, COMPAT_MODULE_SOURCES[name]), COMPAT_MODULE_SOURCES[name])
  );
  for (const parsed of parsedModules) registerTypes(parsed, registry);

  const modules: ModuleMatrixRow[] = parsedModules.map((parsed) =>
    toRow(parsed, COMPAT_MODULE_SOURCES[parsed.name], "module", registry)
  );
  const kindOf = (name: string): ModuleMatrixRow["kind"] =>
    name === "IV2Module" ? "base" : name === "IV2Types" ? "types" : "aggregate";
  for (const parsed of registryParsed) {
    const source =
      parsed.name === "IV2Module"
        ? COMPAT_BASE_MODULE_SOURCE
        : parsed.name === "IV2Types"
          ? COMPAT_TYPE_REGISTRY_SOURCE
          : COMPAT_AGGREGATE_MODULE_SOURCE;
    modules.push(toRow(parsed, source, kindOf(parsed.name), registry));
  }
  modules.sort((a, b) => a.name.localeCompare(b.name));

  const surfaces = resolveEffectiveSurfaces(modules);
  const sharedFunctions = sharedSurface(modules, surfaces, (surface) => surface.functions, INTENTIONAL_SHARED_FUNCTIONS);
  const sharedErrors = sharedSurface(modules, surfaces, (surface) => surface.errors, {});
  const collisions = eventNameCollisions(modules);

  const canonicalTopics = new Set(modules.filter((row) => row.kind === "module").flatMap((row) => row.events.map((e) => e.hash)));
  let publishedTopics = new Set<string>();
  if (fs.existsSync(path.join(rootDir, PUBLISHED_EVENT_SCHEMA))) {
    const published = JSON.parse(readSource(rootDir, PUBLISHED_EVENT_SCHEMA)) as {
      events?: Array<{ topic0?: string }>;
    };
    publishedTopics = new Set((published.events ?? []).map((event) => (event.topic0 ?? "").toLowerCase()).filter(Boolean));
  }
  const overlap = [...canonicalTopics].filter((topic) => publishedTopics.has(topic));

  const versionDeclaration = readVersionFixture(rootDir);
  const invariants = evaluateInvariants(modules, sharedFunctions, sharedErrors, collisions, versionDeclaration);
  const aggregateRow = modules.find((row) => row.kind === "aggregate");
  const declaredModules = modules.filter((row) => row.kind === "module");
  const aggregateNamed = new Set(aggregateRow?.inherits ?? []);
  const aggregateNotNamed = declaredModules.map((row) => row.name).filter((name) => !aggregateNamed.has(name));

  const partial: Omit<InterfaceCompatibilityMatrix, "digest"> = {
    schemaVersion: COMPAT_MATRIX_SCHEMA_VERSION,
    kind: "truthbounty.interface-compatibility-matrix",
    protocol: "TruthBounty",
    protocolVersion: { ...COMPAT_PROTOCOL_VERSION },
    sources: {
      modules: "contracts/v2/interfaces",
      base: COMPAT_BASE_MODULE_SOURCE,
      aggregate: COMPAT_AGGREGATE_MODULE_SOURCE,
      typeRegistry: COMPAT_TYPE_REGISTRY_SOURCE,
      versionFixture: COMPAT_VERSION_FIXTURE_SOURCE,
      publishedEventSchema: PUBLISHED_EVENT_SCHEMA,
    },
    modules,
    aggregateManifest: {
      name: aggregateRow?.name ?? null,
      inherits: aggregateRow?.inherits ?? [],
      declaredMembers: (aggregateRow?.functionCount ?? 0) + (aggregateRow?.errorCount ?? 0) + (aggregateRow?.eventCount ?? 0),
      notNamed: aggregateNotNamed,
      undocumentedOmissions: aggregateNotNamed.filter(
        (name) => !Object.prototype.hasOwnProperty.call(INTENTIONAL_AGGREGATE_OMISSIONS, name)
      ),
    },
    sharedFunctions,
    sharedErrors,
    eventNameCollisions: collisions,
    crossArtifacts: {
      canonicalEventTopics: canonicalTopics.size,
      publishedEventTopics: publishedTopics.size,
      publishedTopicOverlap: overlap.length,
      publishedTopicsNotCanonical: publishedTopics.size - overlap.length,
      canonicalTopicsNotPublished: canonicalTopics.size - overlap.length,
      versionFixtureDeclaration: versionDeclaration,
      documentedDivergences: [
        `${PUBLISHED_EVENT_SCHEMA} publishes the legacy V1 event catalogue (${publishedTopics.size} topics) and shares ${overlap.length} topic0 with the ${canonicalTopics.size} canonical V2 events; consumers must treat the two catalogues as disjoint and read canonical V2 events from the V2-SC-131 export.`,
        ...aggregateNotNamed.map(
          (name) => `${name} is a canonical module interface that is not named by ${aggregateRow?.name ?? "the aggregate manifest"}: ${INTENTIONAL_AGGREGATE_OMISSIONS[name] ?? "undocumented"}`
        ),
        ...collisions.map(
          (collision) =>
            `${collision.name} is emitted by ${collision.modules.join(", ")} with distinct signatures; decode by topic0, not by name.`
        ),
      ],
    },
    invariants,
  };
  return { ...partial, digest: id(stableStringify(partial)) };
}

/** Render the human-reviewable Markdown matrix. */
export function renderCompatibilityMatrix(matrix: InterfaceCompatibilityMatrix): string {
  const lines: string[] = [];
  lines.push("# Protocol Interface Compatibility Matrix (`V2-SC-135`)");
  lines.push("");
  lines.push(
    `Generated from \`${matrix.sources.modules}\` by \`scripts/checkInterfaceCompatibility.ts\`. Protocol version ${matrix.protocolVersion.major}.${matrix.protocolVersion.minor}. Do not edit by hand — run the script with \`--write\`.`
  );
  lines.push("");
  lines.push("## Module matrix");
  lines.push("");
  lines.push("| Module | Kind | Interface ID | Inherits | Functions | Errors | Events | Structs | Enums | protocolVersion |");
  lines.push("|---|---|---|---|---|---|---|---|---|---|");
  for (const row of matrix.modules) {
    lines.push(
      `| \`${row.name}\` | ${row.kind} | \`${row.interfaceId === "0x00000000" && row.functionCount === 0 ? "not advertised (no declared members)" : row.interfaceId}\` | ${row.inherits.map((i) => `\`${i}\``).join(", ") || "—"} | ${row.functionCount} | ${row.errorCount} | ${row.eventCount} | ${row.structs.length} | ${row.enums.length} | ${row.declaresProtocolVersion ? "declared" : "inherited"} |`
    );
  }
  lines.push("");
  lines.push("## Shared function surface");
  lines.push("");
  if (matrix.sharedFunctions.length === 0) {
    lines.push("No function selector is declared by more than one module.");
  } else {
    lines.push("| Signature | Selector | Modules | Intentional | Note |");
    lines.push("|---|---|---|---|---|");
    for (const entry of matrix.sharedFunctions) {
      lines.push(
        `| \`${entry.signature}\` | \`${entry.selector}\` | ${entry.modules.map((m) => `\`${m}\``).join(", ")} | ${entry.intentional ? "yes" : "**no**"} | ${entry.note} |`
      );
    }
  }
  lines.push("");
  lines.push("## Event name collisions");
  lines.push("");
  if (matrix.eventNameCollisions.length === 0) {
    lines.push("No event name is used with more than one signature.");
  } else {
    lines.push("| Name | Signatures | Modules |");
    lines.push("|---|---|---|");
    for (const collision of matrix.eventNameCollisions) {
      lines.push(
        `| \`${collision.name}\` | ${collision.signatures.map((s) => `\`${s}\``).join("<br>")} | ${collision.modules.map((m) => `\`${m}\``).join(", ")} |`
      );
    }
  }
  lines.push("");
  lines.push("## Published artifact alignment");
  lines.push("");
  lines.push(`- \`${matrix.sources.publishedEventSchema}\`: ${matrix.crossArtifacts.publishedEventTopics} published topics.`);
  lines.push(`- Canonical event topics: ${matrix.crossArtifacts.canonicalEventTopics}.`);
  lines.push(`- Topic overlap: ${matrix.crossArtifacts.publishedTopicOverlap}.`);
  lines.push(
    `- Published-only topics (legacy V1 catalogue): ${matrix.crossArtifacts.publishedTopicsNotCanonical}; canonical-only topics: ${matrix.crossArtifacts.canonicalTopicsNotPublished}.`
  );
  lines.push(`- Version fixture declaration: \`${matrix.crossArtifacts.versionFixtureDeclaration ?? "none"}\`.`);
  lines.push("");
  lines.push("## Documented divergences");
  lines.push("");
  for (const divergence of matrix.crossArtifacts.documentedDivergences) {
    lines.push(`- ${divergence}`);
  }
  lines.push("");
  lines.push("## Aggregate manifest coverage");
  lines.push("");
  lines.push(
    `\`${matrix.aggregateManifest.name}\` declares ${matrix.aggregateManifest.declaredMembers} members and inherits ${matrix.aggregateManifest.inherits.length} interfaces. Not named: ${matrix.aggregateManifest.notNamed.map((n) => `\`${n}\``).join(", ") || "—"}.`
  );
  lines.push("");
  lines.push("## Invariants");
  lines.push("");
  lines.push("| Invariant | Status | Detail |");
  lines.push("|---|---|---|");
  for (const invariant of matrix.invariants) {
    lines.push(`| \`${invariant.id}\` | ${invariant.status} | ${invariant.detail} |`);
  }
  lines.push("");
  return lines.join("\n");
}

export function writeCompatibilityMatrix(rootDir: string): { jsonPath: string; docPath: string } {
  const matrix = buildCompatibilityMatrix(rootDir);
  const jsonPath = path.join(rootDir, COMPAT_MATRIX_JSON);
  const docPath = path.join(rootDir, COMPAT_MATRIX_DOC);
  fs.mkdirSync(path.dirname(jsonPath), { recursive: true });
  fs.mkdirSync(path.dirname(docPath), { recursive: true });
  fs.writeFileSync(jsonPath, `${JSON.stringify(matrix, null, 2)}\n`, "utf-8");
  fs.writeFileSync(docPath, renderCompatibilityMatrix(matrix), "utf-8");
  return { jsonPath, docPath };
}

/** Fail-closed check: invariant violations and drift against the committed matrix. */
export function checkCompatibility(rootDir: string): string[] {
  const current = buildCompatibilityMatrix(rootDir);
  const problems: string[] = [];
  for (const invariant of current.invariants) {
    if (invariant.status === "fail") problems.push(`invariant ${invariant.id}: ${invariant.detail}`);
  }
  const jsonPath = path.join(rootDir, COMPAT_MATRIX_JSON);
  const docPath = path.join(rootDir, COMPAT_MATRIX_DOC);
  if (!fs.existsSync(jsonPath)) {
    problems.push(`Committed matrix missing at ${COMPAT_MATRIX_JSON}; run with --write.`);
  } else {
    const committed = JSON.parse(fs.readFileSync(jsonPath, "utf-8")) as InterfaceCompatibilityMatrix;
    if (committed.digest !== current.digest) {
      problems.push(`matrix drift: committed ${committed.digest} != current ${current.digest}`);
    }
    for (const module of current.modules) {
      const previous = committed.modules.find((row) => row.name === module.name);
      if (!previous) problems.push(`module ${module.name} is missing from the committed matrix`);
      else if (previous.interfaceId !== module.interfaceId) {
        problems.push(`module ${module.name} interfaceId drift: committed ${previous.interfaceId} != current ${module.interfaceId}`);
      }
    }
  }
  if (!fs.existsSync(docPath)) {
    problems.push(`Committed matrix document missing at ${COMPAT_MATRIX_DOC}; run with --write.`);
  } else {
    const committedDoc = fs.readFileSync(docPath, "utf-8");
    if (committedDoc !== renderCompatibilityMatrix(current)) {
      problems.push(`matrix document drift: ${COMPAT_MATRIX_DOC} is stale`);
    }
  }
  return problems;
}

const invokedDirectly = process.argv[1] !== undefined && import.meta.url === new URL(`file://${process.argv[1]}`).href;

if (invokedDirectly) {
  const rootDir = process.cwd();
  if (process.argv.includes("--write")) {
    const { jsonPath, docPath } = writeCompatibilityMatrix(rootDir);
    const matrix = buildCompatibilityMatrix(rootDir);
    console.log(`Wrote compatibility matrix: ${jsonPath}`);
    console.log(`Wrote compatibility matrix document: ${docPath}`);
    console.log(
      `modules=${matrix.modules.length} sharedFunctions=${matrix.sharedFunctions.length} eventCollisions=${matrix.eventNameCollisions.length} digest=${matrix.digest}`
    );
    process.exit(0);
  }
  const problems = checkCompatibility(rootDir);
  if (problems.length > 0) {
    for (const problem of problems) console.error(`INCOMPATIBLE: ${problem}`);
    process.exit(1);
  }
  console.log("Interface compatibility matrix is current and all invariants pass.");
}
