/**
 * V2-SC-131 — Freeze Versioned ABI and Event Artifact Exports
 *
 * Deterministically derives versioned ABI, selector, error, event, and address
 * manifest exports for API and frontend consumers from the canonical V2
 * interface sources, then fails closed on drift against the committed export.
 *
 * Source-derived (no compiler required), so the freeze can be verified at any
 * commit. User-defined enums resolve to `uint8` and structs to `tuple`/`(...)`
 * exactly as the Solidity ABI encoder canonicalizes them.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { id } from "ethers";

export const ABI_ARTIFACT_SCHEMA_VERSION = 1;
export const ABI_ARTIFACT_RELEASE_VERSION = "2.0.0";
export const ABI_ARTIFACT_PROTOCOL_VERSION = { major: 2, minor: 0 } as const;

/** Canonical module interfaces frozen by this export. */
export const CANONICAL_MODULE_SOURCES: Record<string, string> = {
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

/** Base discovery interface inherited by every canonical module. */
export const BASE_MODULE_SOURCE = "contracts/v2/interfaces/IV2Module.sol";
/** Additive surfaces do not alter the existing module ownership interfaces or ERC-165 IDs. */
export const CANONICAL_EXTENSION_SOURCES = {
  IUntrackedAssetRecovery: "contracts/interfaces/IUntrackedAssetRecovery.sol",
};
/** Named aggregate manifest of the complete V2 module topology. */
export const AGGREGATE_MODULE_SOURCE = "contracts/v2/interfaces/ICanonicalV2.sol";
/** Shared value-type registry used to canonicalize user-defined ABI types. */
export const TYPE_REGISTRY_SOURCE = "contracts/v2/interfaces/IV2Types.sol";

/** Concrete implementations used to resolve the address manifest. */
export const CANONICAL_IMPLEMENTATION_SOURCES = [
  "contracts/v2/Aggregation.sol",
  "contracts/v2/EvidenceRegistry.sol",
  "contracts/v2/StakeVault.sol",
  "contracts/v2/FinalRewardAllocator.sol",
  "contracts/v2/EmergencyGatekeeper.sol",
] as const;

/** Deployment environments referenced by the address manifest. */
export const ADDRESS_MANIFEST_NETWORKS = [
  { name: "optimism-mainnet", chainId: 10, config: "deployments/config/mainnet.json" },
  { name: "optimism-sepolia", chainId: 11155420, config: "deployments/config/testnet.json" },
  { name: "local", chainId: 31337, config: "deployments/config/local.json" },
] as const;

export interface AbiParameter {
  name: string;
  type: string;
  indexed?: boolean;
}

interface RawParameter {
  name: string;
  type: string;
  indexed: boolean;
}

interface RawEntry {
  kind: "function" | "error" | "event";
  name: string;
  inputs: RawParameter[];
  outputs: RawParameter[];
  stateMutability: string;
  anonymous?: boolean;
}

export interface AbiFragment {
  type: "function" | "error" | "event";
  name: string;
  signature: string;
  inputs: AbiParameter[];
  outputs?: AbiParameter[];
  stateMutability?: string;
  anonymous?: boolean;
}

export interface ParsedInterface {
  name: string;
  source: string;
  inherits: string[];
  functions: RawEntry[];
  errors: RawEntry[];
  events: RawEntry[];
  structs: Array<{ name: string; fields: RawParameter[] }>;
  enums: string[];
}

export interface ResolvedModule {
  name: string;
  source: string;
  interfaceId: string;
  inherits: string[];
  functions: Array<{ signature: string; selector: string; declaredIn: string }>;
  errors: Array<{ signature: string; selector: string; declaredIn: string }>;
  events: Array<{ signature: string; topic0: string; declaredIn: string }>;
  structs: string[];
  enums: string[];
  digest: string;
}

export interface AbiArtifactExport {
  schemaVersion: number;
  kind: "truthbounty.abi-artifact-exports";
  protocol: string;
  releaseVersion: string;
  protocolVersion: { major: number; minor: number };
  sourceRoot: string;
  aggregate: string;
  modules: ResolvedModule[];
  canonicalAbi: AbiFragment[];
  extensions?: Array<ResolvedModule & { abi: AbiFragment[]; policy: unknown }>;
  addressManifest: {
    note: string;
    networks: Array<{ name: string; chainId: number; config: string }>;
    modules: Array<{
      name: string;
      moduleId: string;
      interfaceId: string;
      implementation: string | null;
      implementationSource: string | null;
    }>;
  };
  checksum: string;
}

export class AbiArtifactError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AbiArtifactError";
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

export interface TypeRegistry {
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
  throw new AbiArtifactError(`Unbalanced ${open}${close} group`);
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

/** Extract the interface declaration, its inheritance list, and all members. */
export function parseInterfaceSource(source: string, sourcePath: string): ParsedInterface {
  const cleaned = stripComments(source);
  const declRe = /(?:^|\n)\s*(?:abstract\s+)?(?:interface|contract)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:is\s+([^{]+?))?\s*\{/;
  const decl = declRe.exec(cleaned);
  if (!decl) throw new AbiArtifactError(`No interface or contract declaration found in ${sourcePath}`);
  const name = decl[1];
  const inherits = (decl[2] ?? "")
    .split(",")
    .map((entry) => entry.replace(/\(.*\)$/, "").trim())
    .filter((entry) => entry.length > 0);

  const bodyStart = decl.index + decl[0].length - 1;
  let body = readGroup(cleaned, bodyStart, "{", "}").inner;

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
    if (declaration.startsWith("function ")) functions.push(parseEntry(declaration, "function", name));
    else if (declaration.startsWith("error ")) errors.push(parseEntry(declaration, "error", name));
    else if (declaration.startsWith("event ")) events.push(parseEntry(declaration, "event", name));
  }

  const sortByName = (a: RawEntry, b: RawEntry) => a.name.localeCompare(b.name);
  return {
    name,
    source: sourcePath,
    inherits,
    functions: functions.sort(sortByName),
    errors: errors.sort(sortByName),
    events: events.sort(sortByName),
    structs,
    enums,
  };
}

function parseEntry(declaration: string, kind: "function" | "error" | "event", declaredIn: string): RawEntry {
  const head = new RegExp(`^${kind}\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*`).exec(declaration);
  if (!head) throw new AbiArtifactError(`Malformed ${kind} declaration in ${declaredIn}: ${declaration}`);
  const open = declaration.indexOf("(", head[0].length - 1);
  const { inner, end } = readGroup(declaration, open, "(", ")");
  const tail = declaration.slice(end + 1);
  const entry: RawEntry = {
    kind,
    name: head[1],
    inputs: parseParameters(inner),
    outputs: [],
    stateMutability: kind === "function" ? stateMutabilityOf(tail) : "",
    anonymous: kind === "event" && /\banonymous\b/.test(tail),
  };
  if (kind === "function") {
    const returnsMatch = /returns\s*\(/.exec(tail);
    if (returnsMatch) {
      const returnsOpen = tail.indexOf("(", returnsMatch.index);
      entry.outputs = parseParameters(readGroup(tail, returnsOpen, "(", ")").inner);
    }
  }
  return entry;
}

function stateMutabilityOf(tail: string): string {
  if (/\bpure\b/.test(tail)) return "pure";
  if (/\bview\b/.test(tail)) return "view";
  if (/\bpayable\b/.test(tail)) return "payable";
  return "nonpayable";
}

function registerTypes(parsed: ParsedInterface[], registry: TypeRegistry): void {
  for (const entry of parsed) {
    for (const enumName of entry.enums) {
      registry.enums.add(enumName);
      registry.enums.add(`${entry.name}.${enumName}`);
    }
    for (const struct of entry.structs) {
      registry.structs.set(struct.name, struct.fields);
      registry.structs.set(`${entry.name}.${struct.name}`, struct.fields);
    }
  }
}

/** Canonicalize a Solidity type the way the ABI encoder does (enums→uint8, structs→tuple). */
export function canonicalizeType(raw: string, registry: TypeRegistry): string {
  const normalized = baseElementaryType(raw);
  const arrayMatch = normalized.match(/(\[[0-9]*\])+$/);
  const suffix = arrayMatch ? arrayMatch[0] : "";
  const base = suffix ? normalized.slice(0, normalized.length - suffix.length) : normalized;
  if (ELEMENTARY_TYPES.has(base)) return base + suffix;
  if (registry.enums.has(base)) return `uint8${suffix}`;
  const fields = registry.structs.get(base);
  if (fields) {
    const components = fields.map((field) => canonicalizeType(field.type, registry));
    return `(${components.join(",")})${suffix}`;
  }
  throw new AbiArtifactError(`Unknown ABI type: ${raw}`);
}

function parameterJson(parameter: RawParameter, registry: TypeRegistry): AbiParameter {
  const json: AbiParameter = { name: parameter.name, type: canonicalizeType(parameter.type, registry) };
  if (parameter.indexed) json.indexed = true;
  return json;
}

function resolveEntry(entry: RawEntry, registry: TypeRegistry): AbiFragment {
  const inputs = entry.inputs.map((input) => parameterJson(input, registry));
  const signature = `${entry.name}(${inputs.map((input) => input.type).join(",")})`;
  const fragment: AbiFragment = { type: entry.kind, name: entry.name, signature, inputs };
  if (entry.kind === "function") {
    fragment.outputs = entry.outputs.map((output) => parameterJson(output, registry));
    fragment.stateMutability = entry.stateMutability;
  } else if (entry.kind === "event") {
    if (entry.anonymous) fragment.anonymous = true;
  }
  return fragment;
}

function xorBytes4(left: string, right: string): string {
  return `0x${(BigInt(left) ^ BigInt(right)).toString(16).padStart(8, "0")}`;
}

/** ERC-165 interface id: XOR of the selectors declared directly in the interface. */
export function computeInterfaceId(fragments: AbiFragment[]): string {
  const idOf = (fragment: AbiFragment) => id(fragment.signature).slice(0, 10);
  return fragments
    .filter((fragment) => fragment.type === "function")
    .reduce((acc, fragment) => xorBytes4(acc, idOf(fragment)), "0x00000000");
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
  if (!fs.existsSync(absolute)) throw new AbiArtifactError(`Required canonical source missing: ${relativePath}`);
  return fs.readFileSync(absolute, "utf-8");
}

function resolveModule(parsed: ParsedInterface, registry: TypeRegistry): { module: ResolvedModule; fragments: AbiFragment[] } {
  const functions = parsed.functions.map((entry) => resolveEntry(entry, registry));
  const errors = parsed.errors.map((entry) => resolveEntry(entry, registry));
  const events = parsed.events.map((entry) => resolveEntry(entry, registry));
  const module: ResolvedModule = {
    name: parsed.name,
    source: parsed.source,
    interfaceId: computeInterfaceId(functions),
    inherits: [...parsed.inherits],
    functions: functions
      .map((fragment) => ({
        signature: fragment.signature,
        selector: id(fragment.signature).slice(0, 10),
        declaredIn: parsed.name,
      }))
      .sort((a, b) => a.signature.localeCompare(b.signature)),
    errors: errors
      .map((fragment) => ({
        signature: fragment.signature,
        selector: id(fragment.signature).slice(0, 10),
        declaredIn: parsed.name,
      }))
      .sort((a, b) => a.signature.localeCompare(b.signature)),
    events: events
      .map((fragment) => ({
        signature: fragment.signature,
        topic0: id(fragment.signature),
        declaredIn: parsed.name,
      }))
      .sort((a, b) => a.signature.localeCompare(b.signature)),
    structs: parsed.structs.map((struct) => struct.name).sort(),
    enums: [...parsed.enums].sort(),
    digest: "",
  };
  module.digest = id(stableStringify({ ...module, digest: undefined }));
  return { module, fragments: [...functions, ...errors, ...events] };
}

function resolveImplementations(rootDir: string, known: Set<string>): Map<string, { contract: string; source: string }> {
  const resolved = new Map<string, { contract: string; source: string }>();
  for (const sourcePath of CANONICAL_IMPLEMENTATION_SOURCES) {
    if (!fs.existsSync(path.join(rootDir, sourcePath))) continue;
    const cleaned = stripComments(readSource(rootDir, sourcePath));
    const match = /(?:^|\n)\s*(?:abstract\s+)?contract\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:is\s+([^{]+?))?\s*\{/.exec(cleaned);
    if (!match || !match[2]) continue;
    for (const parent of splitTopLevel(match[2])) {
      const base = parent.replace(/\(.*\)$/, "").trim();
      if (!known.has(base) || resolved.has(base)) continue;
      resolved.set(base, { contract: match[1], source: sourcePath });
    }
  }
  return resolved;
}

/** Build the deterministic, versioned export bundle from source at `rootDir`. */
export function buildAbiArtifactExport(rootDir: string): AbiArtifactExport {
  const registryFiles = [TYPE_REGISTRY_SOURCE, BASE_MODULE_SOURCE];
  const parsedRegistry = registryFiles
    .filter((source) => fs.existsSync(path.join(rootDir, source)))
    .map((source) => parseInterfaceSource(readSource(rootDir, source), source));
  const registry: TypeRegistry = { enums: new Set(), structs: new Map() };
  registerTypes(parsedRegistry, registry);

  const moduleNames = Object.keys(CANONICAL_MODULE_SOURCES).sort();
  const parsedModules = moduleNames.map((name) =>
    parseInterfaceSource(readSource(rootDir, CANONICAL_MODULE_SOURCES[name]), CANONICAL_MODULE_SOURCES[name])
  );
  registerTypes(parsedModules, registry);

  const parsedExtensions = Object.values(CANONICAL_EXTENSION_SOURCES)
    .filter(source => fs.existsSync(path.join(rootDir, source)))
    .map(source => parseInterfaceSource(readSource(rootDir, source), source));
  registerTypes(parsedExtensions, registry);
  const extensions = parsedExtensions.map(parsed => {
    const resolved = resolveModule(parsed, registry);
    return {
      ...resolved.module,
      abi: resolved.fragments,
      policy: JSON.parse(readSource(rootDir, "deployments/config/asset-recovery.json")),
    };
  });

  const resolved = parsedModules.map((parsed) => resolveModule(parsed, registry));
  const modules = resolved.map((entry) => entry.module);
  const resolvedFragments = resolved.flatMap((entry) => entry.fragments);

  const dedupe = (fragments: AbiFragment[]): AbiFragment[] => {
    const seen = new Map<string, AbiFragment>();
    for (const fragment of fragments) {
      if (!seen.has(fragment.signature)) seen.set(fragment.signature, fragment);
    }
    return [...seen.values()].sort((a, b) => a.signature.localeCompare(b.signature));
  };
  const canonicalAbi = [
    ...dedupe(resolvedFragments.filter((fragment) => fragment.type === "function")),
    ...dedupe(resolvedFragments.filter((fragment) => fragment.type === "error")),
    ...dedupe(resolvedFragments.filter((fragment) => fragment.type === "event")),
  ];

  const implementations = resolveImplementations(rootDir, new Set(moduleNames));
  const partial: Omit<AbiArtifactExport, "checksum"> = {
    schemaVersion: ABI_ARTIFACT_SCHEMA_VERSION,
    kind: "truthbounty.abi-artifact-exports",
    protocol: "TruthBounty",
    releaseVersion: ABI_ARTIFACT_RELEASE_VERSION,
    protocolVersion: { ...ABI_ARTIFACT_PROTOCOL_VERSION },
    sourceRoot: "contracts/v2/interfaces",
    aggregate: AGGREGATE_MODULE_SOURCE,
    modules,
    canonicalAbi,
    extensions,
    addressManifest: {
      note: "Module identity manifest. Concrete addresses are injected at deployment time from deployments/config and are never committed.",
      networks: ADDRESS_MANIFEST_NETWORKS.map((network) => ({ ...network })),
      modules: modules.map((module) => {
        const implementation = implementations.get(module.name);
        return {
          name: module.name,
          moduleId: id(module.name),
          interfaceId: module.interfaceId,
          implementation: implementation ? implementation.contract : null,
          implementationSource: implementation ? implementation.source : null,
        };
      }),
    },
  };

  return { ...partial, checksum: id(stableStringify(partial)) };
}

/** Committed freeze location for the versioned export. */
export function exportPath(rootDir: string): string {
  const version = `${ABI_ARTIFACT_RELEASE_VERSION}-${ABI_ARTIFACT_PROTOCOL_VERSION.major}.${ABI_ARTIFACT_PROTOCOL_VERSION.minor}`;
  return path.join(rootDir, "exports", "abi", "v2", version, "manifest.json");
}

/** Compare a freshly derived export against a committed freeze. */
export function diffAgainstFreeze(frozen: AbiArtifactExport, current: AbiArtifactExport): string[] {
  const drifts: string[] = [];
  if (frozen.checksum !== current.checksum) {
    drifts.push(`export checksum drift: frozen ${frozen.checksum} != current ${current.checksum}`);
  }
  const frozenModules = new Map(frozen.modules.map((module) => [module.name, module]));
  const currentModules = new Map(current.modules.map((module) => [module.name, module]));
  for (const name of [...new Set([...frozenModules.keys(), ...currentModules.keys()])].sort()) {
    const expected = frozenModules.get(name);
    const actual = currentModules.get(name);
    if (!expected) {
      drifts.push(`module ${name} is not present in the frozen export`);
      continue;
    }
    if (!actual) {
      drifts.push(`frozen module ${name} is missing from the current sources`);
      continue;
    }
    if (expected.digest !== actual.digest) {
      drifts.push(`module ${name} digest drift: frozen ${expected.digest} != current ${actual.digest}`);
    }
    if (expected.interfaceId !== actual.interfaceId) {
      drifts.push(`module ${name} interfaceId drift: frozen ${expected.interfaceId} != current ${actual.interfaceId}`);
    }
  }
  if (frozen.canonicalAbi.length !== current.canonicalAbi.length) {
    drifts.push(`canonical ABI size drift: frozen ${frozen.canonicalAbi.length} != current ${current.canonicalAbi.length}`);
  }
  return drifts;
}

export function checkFreeze(rootDir: string): string[] {
  const target = exportPath(rootDir);
  if (!fs.existsSync(target)) {
    return [`Committed ABI artifact export missing at ${target}; run with --write to freeze it.`];
  }
  const frozen = JSON.parse(fs.readFileSync(target, "utf-8")) as AbiArtifactExport;
  return diffAgainstFreeze(frozen, buildAbiArtifactExport(rootDir));
}

export function writeFreeze(rootDir: string): string {
  const target = exportPath(rootDir);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, `${JSON.stringify(buildAbiArtifactExport(rootDir), null, 2)}\n`, "utf-8");
  return target;
}

/** Publish additive extension handoffs without rewriting already released ownership ABIs. */
export function writeExtensionFreeze(rootDir: string): string {
  const target = exportPath(rootDir);
  const { checksum: previousChecksum, ...frozen } = JSON.parse(fs.readFileSync(target, "utf8"));
  const partial = { ...frozen, extensions: buildAbiArtifactExport(rootDir).extensions };
  fs.writeFileSync(target, `${JSON.stringify({ ...partial, checksum: id(stableStringify(partial)) }, null, 2)}\n`);
  return target;
}

const invokedDirectly = process.argv[1] !== undefined && import.meta.url === new URL(`file://${process.argv[1]}`).href;

if (invokedDirectly) {
  const rootDir = process.cwd();
  if (process.argv.includes("--write-extensions")) {
    console.log(`Froze additive ABI extensions at: ${writeExtensionFreeze(rootDir)}`);
    process.exit(0);
  }
  if (process.argv.includes("--write")) {
    const target = writeFreeze(rootDir);
    const bundle = buildAbiArtifactExport(rootDir);
    console.log(`Froze versioned ABI artifact exports at: ${target}`);
    console.log(
      `modules=${bundle.modules.length} abiEntries=${bundle.canonicalAbi.length} checksum=${bundle.checksum}`
    );
    process.exit(0);
  }
  const drifts = checkFreeze(rootDir);
  if (drifts.length > 0) {
    for (const drift of drifts) console.error(`DRIFT: ${drift}`);
    process.exit(1);
  }
  console.log("Versioned ABI artifact exports are frozen and drift-free.");
}
