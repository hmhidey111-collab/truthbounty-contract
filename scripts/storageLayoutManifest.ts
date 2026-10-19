/**
 * Canonical storage-layout manifest core (V2-SC-121).
 *
 * Freezes the storage layout of every upgradeable V2 contract into a reviewed
 * manifest (storage-layouts/manifest.json) and classifies drift between the
 * frozen manifest and the freshly compiled layouts. The classification and the
 * hash preimage are specified in storage-layouts/MANIFEST_SPEC.md (v1, frozen).
 *
 * Determinism requirements enforced here:
 *  - canonical JSON: recursively sorted object keys, no insignificant whitespace
 *  - solc slot/size strings copied verbatim (never re-formatted)
 *  - domain-separated keccak256 preimage, mirrored by
 *    test/upgrade/StorageLayoutManifest.t.sol
 */

import * as fs from "fs";
import * as path from "path";
import { keccak256, toUtf8Bytes } from "ethers";

// ---------------------------------------------------------------------------
// Constants (frozen by MANIFEST_SPEC.md v1)
// ---------------------------------------------------------------------------

export const MANIFEST_SCHEMA_VERSION = 1;
export const HASH_DOMAIN = "TB-STORAGE-LAYOUT-V1";
export const TOOL_NAME = "generateStorageLayouts";
export const TOOL_VERSION = "1.0.0";
export const MANIFEST_RELATIVE_PATH = path.join("storage-layouts", "manifest.json");
export const APPROVED_DRIFT_RELATIVE_PATH = path.join("storage-layouts", "APPROVED_DRIFT.md");

/** Maximum number of contracts allowed in one manifest (bounds all loops). */
export const MAX_TRACKED_CONTRACTS = 256;
/** Maximum number of storage variables allowed per contract (bounds all loops). */
export const MAX_TRACKED_SLOTS = 512;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface StorageVarEntry {
  slot: string;
  offset: number;
  type: string;
  numberOfBytes: string;
}

export interface ContractManifest {
  sourcePath: string;
  kind: "upgradeable" | "proxy";
  canonicalHash: string;
  frozenAt: string;
  slots: Record<string, StorageVarEntry>;
}

export interface StorageLayoutManifest {
  schemaVersion: number;
  tool: { name: string; version: string };
  solc: string;
  generatedAt: string;
  contracts: Record<string, ContractManifest>;
}

export type DriftClassification =
  | "unchanged"
  | "approved"
  | "new"
  | "removed"
  | "slot-drift"
  | "appended";

export interface DriftFinding {
  contract: string;
  classification: DriftClassification;
  details: string[];
}

export interface DriftReport {
  findings: DriftFinding[];
  pass: boolean;
}

// ---------------------------------------------------------------------------
// Contract inventory — the authoritative, reviewed freeze scope
// ---------------------------------------------------------------------------

/**
 * Every contract whose storage layout is frozen by V2-SC-121.
 *
 * `kind: "proxy"` entries are the transparent/UUPS proxy shells whose storage
 * is the concatenated layout of the implementation plus proxy-level state;
 * their frozen artifact is the *implementation* layout under the proxy name.
 *
 * Additions to this list are themselves manifest changes and require the same
 * maintainer review as layout drift.
 */
export const TRACKED_STORAGE_CONTRACTS: ReadonlyArray<{
  name: string;
  sourcePath: string;
  kind: "upgradeable" | "proxy";
}> = [
  // Canonical V2 modules with __gap reservations (proxy-upgradeable surface).
  { name: "ProtocolUpgradeable", sourcePath: "contracts/upgrade/ProtocolUpgradeable.sol", kind: "upgradeable" },
  { name: "TimelockOwnedProxyAdmin", sourcePath: "contracts/upgrade/TimelockOwnedProxyAdmin.sol", kind: "upgradeable" },
  { name: "FeeManager", sourcePath: "contracts/fees/FeeManager.sol", kind: "upgradeable" },
  { name: "TokenomicsEngine", sourcePath: "contracts/tokenomics/TokenomicsEngine.sol", kind: "upgradeable" },
  { name: "TreasuryManagement", sourcePath: "contracts/treasury/TreasuryManagement.sol", kind: "upgradeable" },
  { name: "VerificationRoundManager", sourcePath: "contracts/VerificationRoundManager.sol", kind: "upgradeable" },
  { name: "DisputeResolution", sourcePath: "contracts/DisputeResolution.sol", kind: "upgradeable" },
  { name: "ReputationEngine", sourcePath: "contracts/reputation/ReputationEngine.sol", kind: "upgradeable" },
  { name: "ReputationDecay", sourcePath: "contracts/ReputationDecay.sol", kind: "upgradeable" },
  { name: "ClaimLifecycle", sourcePath: "contracts/ClaimLifecycle.sol", kind: "upgradeable" },
  { name: "StakeVault", sourcePath: "contracts/StakeVault.sol", kind: "upgradeable" },
  { name: "TruthBountyToken", sourcePath: "contracts/TruthBounty.sol", kind: "proxy" },
  { name: "TruthBounty", sourcePath: "contracts/TruthBounty.sol", kind: "upgradeable" },
  { name: "GovernanceOwnable", sourcePath: "contracts/governance/GovernanceOwnable.sol", kind: "upgradeable" },
];

/** Contracts compiled from a single source file; used to validate the inventory. */
export function trackedContractNames(): string[] {
  return TRACKED_STORAGE_CONTRACTS.map((c) => c.name);
}

// ---------------------------------------------------------------------------
// Canonical JSON (sorted keys, no insignificant whitespace)
// ---------------------------------------------------------------------------

/** Recursively sort object keys and serialize without insignificant whitespace. */
export function canonicalJsonStringify(value: unknown): string {
  if (value === null || typeof value === "number" || typeof value === "boolean") {
    return JSON.stringify(value);
  }
  if (typeof value === "string") {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJsonStringify).join(",")}]`;
  }
  if (typeof value === "object") {
    const keys = Object.keys(value as Record<string, unknown>).sort();
    const parts = keys.map(
      (k) => `${JSON.stringify(k)}:${canonicalJsonStringify((value as Record<string, unknown>)[k])}`
    );
    return `{${parts.join(",")}}`;
  }
  throw new Error(`canonicalJsonStringify: unsupported value type ${typeof value}`);
}

// ---------------------------------------------------------------------------
// Hashing — preimage frozen by MANIFEST_SPEC.md §3
// ---------------------------------------------------------------------------

function encodeLenPrefixed(s: string): string {
  // abi.encode(uint256(len) || bytes(s)) for the preimage, hex-encoded with 0x.
  const len = toUtf8Bytes(s).length;
  const lenHex = len.toString(16).padStart(64, "0");
  const dataHex = Buffer.from(s, "utf8").toString("hex");
  return "0x" + lenHex + dataHex;
}

function encodeUint256(v: number): string {
  if (!Number.isInteger(v) || v < 0 || v > 0xffffffff) {
    throw new Error(`encodeUint256: out of supported range: ${v}`);
  }
  return "0x" + v.toString(16).padStart(64, "0");
}

/**
 * keccak256("TB-STORAGE-LAYOUT-V1" ||
 *           uint256(schemaVersion) ||
 *           lenPrefixed(sourcePath) ||
 *           lenPrefixed(canonical entry JSON))
 *
 * Mirrored exactly by test/upgrade/StorageLayoutManifest.t.sol.
 */
export function computeCanonicalHash(sourcePath: string, slots: Record<string, StorageVarEntry>): string {
  const entryJson = canonicalJsonStringify({ slots });
  const preimage = [
    Buffer.from(toUtf8Bytes(HASH_DOMAIN)).toString("hex"),
    encodeUint256(MANIFEST_SCHEMA_VERSION).slice(2),
    encodeLenPrefixed(sourcePath).slice(2),
    encodeLenPrefixed(entryJson).slice(2),
  ].join("");
  return keccak256("0x" + preimage);
}

// ---------------------------------------------------------------------------
// solc storageLayout extraction
// ---------------------------------------------------------------------------

interface SolcStorageItem {
  astId: number;
  contract: string;
  label: string;
  offset: number;
  slot: string;
  type: string;
}

interface SolcStorageLayout {
  storage: SolcStorageItem[];
  types: Record<string, { encoding: string; label: string; numberOfBytes: string }>;
}

/**
 * Normalize a solc type identifier for hashing.
 *
 * solc embeds **AST IDs** in the type ids of user-defined types
 * (`t_struct(RoleData)17432_storage`, `t_contract(IUpgradeController)16027`)
 * *and inside composite type ids* (`t_mapping(t_bytes32,t_struct(RoleData)17432_storage)`).
 * These ids churn whenever *any* declaration in the compiled source set changes —
 * even an unrelated edit in another file — so raw ids would make the manifest
 * reject innocuous refactors.
 *
 * The churn-free identity of a user-defined type is its solc human label plus
 * its total byte size, so normalization recursively rewrites every user-defined
 * component to `udt:<label>:<bytes>b` while preserving the composite shape
 * (mapping key/value, array length and location). A real layout change (member
 * added, field widened, array resized) changes a label or a size and is still
 * detected as drift.
 */
export function normalizeTypeId(
  typeId: string,
  types: Record<string, { label?: string; numberOfBytes?: string }>
): string {
  return normalizeTypeRec(typeId, types);
}

function normalizeTypeRec(
  id: string,
  types: Record<string, { label?: string; numberOfBytes?: string }>
): string {
  if (id.startsWith("t_mapping(")) {
    const inner = id.slice("t_mapping(".length, -1);
    const [keyPart, valuePart] = splitTopLevelComma(inner);
    return `t_mapping(${normalizeTypeRec(keyPart, types)},${normalizeTypeRec(valuePart, types)})`;
  }
  const arrayMatch = /^t_array\((.*)\)((?:\d+_storage)|dyn_storage|calldata|memory|storage|ptr)$/.exec(id);
  if (arrayMatch !== null) {
    return `t_array(${normalizeTypeRec(arrayMatch[1], types)})${arrayMatch[2]}`;
  }
  if (/^t_(?:struct|enum|contract)\(/.test(id)) {
    const info = types[id];
    if (info === undefined || info.label === undefined) return id;
    return `udt:${info.label}:${info.numberOfBytes ?? "?"}b`;
  }
  return id;
}

/** Split `a,b` at the top-level comma (parenthesis-aware). Mapping ids have exactly one. */
function splitTopLevelComma(s: string): [string, string] {
  let depth = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === "(") depth++;
    else if (c === ")") depth--;
    else if (c === "," && depth === 0) {
      return [s.slice(0, i), s.slice(i + 1)];
    }
  }
  throw new Error(`splitTopLevelComma: no top-level comma in '${s}'`);
}

/** Extract the ordered slot map for one contract from a solc storageLayout.
 *
 * Keys are `${label}@${slot}`: solc attributes every variable of the flattened
 * inheritance chain to the compiled (most-derived) contract, so labels are NOT
 * unique — a derived contract plus its bases may each declare `__gap`, and the
 * `contract` field cannot disambiguate them. `astId` would disambiguate but
 * churns on unrelated edits to the same file, so `label@slot` is used: within
 * one layout a label can occupy a given slot at most once, making the key
 * deterministic, unique and churn-free. A rename of a variable is surfaced as
 * remove+add (slot-drift), which is the intended review outcome.
 */
export function extractSlots(
  layout: SolcStorageLayout,
  contractName: string
): Record<string, StorageVarEntry> {
  const out: Record<string, StorageVarEntry> = {};
  const items = layout.storage ?? [];
  if (items.length > MAX_TRACKED_SLOTS) {
    throw new Error(
      `extractSlots(${contractName}): ${items.length} storage variables exceeds MAX_TRACKED_SLOTS=${MAX_TRACKED_SLOTS}`
    );
  }
  for (const item of items) {
    const key = `${item.label}@${item.slot}`;
    if (out[key] !== undefined) {
      throw new Error(
        `extractSlots(${contractName}): duplicate storage key '${key}' (declaring '${item.contract}')`
      );
    }
    const typeInfo = layout.types?.[item.type];
    out[key] = {
      slot: String(item.slot),
      offset: Number(item.offset),
      type: normalizeTypeId(item.type, layout.types ?? {}),
      numberOfBytes: String(typeInfo?.numberOfBytes ?? "?"),
    };
  }
  return out;
}

// ---------------------------------------------------------------------------
// Manifest assembly
// ---------------------------------------------------------------------------

export function emptyManifest(solcVersion: string): StorageLayoutManifest {
  return {
    schemaVersion: MANIFEST_SCHEMA_VERSION,
    tool: { name: TOOL_NAME, version: TOOL_VERSION },
    solc: solcVersion,
    generatedAt: new Date().toISOString(),
    contracts: {},
  };
}

export function addContract(
  manifest: StorageLayoutManifest,
  entry: { name: string; sourcePath: string; kind: "upgradeable" | "proxy" },
  slots: Record<string, StorageVarEntry>
): void {
  const names = Object.keys(manifest.contracts);
  if (names.length >= MAX_TRACKED_CONTRACTS) {
    throw new Error(`addContract: manifest exceeds MAX_TRACKED_CONTRACTS=${MAX_TRACKED_CONTRACTS}`);
  }
  if (manifest.contracts[entry.name] !== undefined) {
    throw new Error(`addContract: duplicate contract '${entry.name}'`);
  }
  manifest.contracts[entry.name] = {
    sourcePath: entry.sourcePath,
    kind: entry.kind,
    canonicalHash: computeCanonicalHash(entry.sourcePath, slots),
    frozenAt: new Date().toISOString(),
    slots,
  };
}

/** Write the manifest with alphabetically re-keyed contracts (order is not drift). */
export function serializeManifest(manifest: StorageLayoutManifest): string {
  const sortedContracts: Record<string, ContractManifest> = {};
  for (const name of Object.keys(manifest.contracts).sort()) {
    sortedContracts[name] = manifest.contracts[name];
  }
  const ordered: StorageLayoutManifest = {
    schemaVersion: manifest.schemaVersion,
    tool: manifest.tool,
    solc: manifest.solc,
    generatedAt: manifest.generatedAt,
    contracts: sortedContracts,
  };
  return JSON.stringify(ordered, null, 2) + "\n";
}

// ---------------------------------------------------------------------------
// Drift detection
// ---------------------------------------------------------------------------

const GAP_LABEL = "__gap";

function isArrayType(type: string): boolean {
  return /t_array/.test(type);
}

function isGapKey(key: string): boolean {
  return key.startsWith(`${GAP_LABEL}@`);
}

/**
 * Classify drift for one contract between the frozen and freshly generated
 * layouts. Pure function: no fs, no clock — fully unit-testable.
 */
export function classifyContractDrift(
  contract: string,
  frozen: ContractManifest | undefined,
  fresh: ContractManifest
): DriftFinding {
  if (frozen === undefined) {
    return { contract, classification: "new", details: ["contract added to the manifest"] };
  }

  const details: string[] = [];

  // Compare fully-qualified slot keys (`DeclaringContract.label`).
  const frozenKeys = Object.keys(frozen.slots);
  const freshKeys = Object.keys(fresh.slots);

  const addedKeys = freshKeys.filter((k) => frozen.slots[k] === undefined);
  const removedKeys = frozenKeys.filter((k) => fresh.slots[k] === undefined);

  const changed: string[] = [];
  for (const key of frozenKeys) {
    if (fresh.slots[key] === undefined) continue;
    if (isGapKey(key)) continue; // gap resize is evaluated separately below
    const a = frozen.slots[key];
    const b = fresh.slots[key];
    if (a.slot !== b.slot || a.offset !== b.offset || a.type !== b.type || a.numberOfBytes !== b.numberOfBytes) {
      changed.push(
        `${key}: slot ${a.slot}→${b.slot}, offset ${a.offset}→${b.offset}, type ${a.type}→${b.type}, bytes ${a.numberOfBytes}→${b.numberOfBytes}`
      );
    }
  }

  // Append-only detection: additions must sit at/after the highest frozen slot
  // boundary, and the (last) gap must shrink correspondingly. Any movement of a
  // frozen variable, any removal, or any insert before the boundary is drift.
  const frozenGapKeys = frozenKeys.filter(isGapKey);
  const freshGapKeys = freshKeys.filter(isGapKey);

  const frozenEnd = frozenKeys.reduce((acc, k) => {
    if (isGapKey(k)) return acc; // gap end is the reservation itself
    const e = Number(frozen.slots[k].slot) + bytesToSlots(frozen.slots[k].numberOfBytes);
    return Math.max(acc, e);
  }, 0);

  let appendedAfterBoundary = false;
  let insertedBeforeBoundary = false;
  const insertedBeforeKeys: string[] = [];
  const appendedKeys: string[] = [];
  for (const key of addedKeys) {
    if (isGapKey(key)) continue;
    const slotNo = Number(fresh.slots[key].slot);
    if (slotNo >= frozenEnd) {
      appendedAfterBoundary = true;
      appendedKeys.push(key);
    } else {
      insertedBeforeBoundary = true;
      insertedBeforeKeys.push(key);
    }
  }

  // Gap drift: any gap key changed, appeared, or disappeared.
  let gapChanged = false;
  const gapChanges: string[] = [];
  for (const key of frozenGapKeys) {
    const b = fresh.slots[key];
    if (b === undefined) {
      gapChanged = true;
      gapChanges.push(`gap removed: ${key}`);
      continue;
    }
    const a = frozen.slots[key];
    if (a.slot !== b.slot || a.offset !== b.offset || a.type !== b.type || a.numberOfBytes !== b.numberOfBytes) {
      gapChanged = true;
      gapChanges.push(`gap changed: ${key} (${a.numberOfBytes}→${b.numberOfBytes} bytes)`);
    }
  }
  for (const key of freshGapKeys) {
    if (frozen.slots[key] === undefined) {
      gapChanged = true;
      gapChanges.push(`gap added: ${key}`);
    }
  }

  const hasSlotMovement = changed.length > 0 || removedKeys.length > 0 || insertedBeforeBoundary;

  if (hasSlotMovement) {
    if (changed.length > 0) details.push(...changed.map((c) => `moved: ${c}`));
    if (removedKeys.length > 0) details.push(`removed: ${removedKeys.join(", ")}`);
    if (insertedBeforeBoundary) {
      details.push(`inserted before append boundary (slot ${frozenEnd}): ${insertedBeforeKeys.join(", ")}`);
    }
    return { contract, classification: "slot-drift", details };
  }

  if (appendedAfterBoundary) {
    // Both proxy-safe append patterns are accepted:
    //   (a) shrink the gap in place and place the new variables into the freed
    //       slots at the gap's tail, or
    //   (b) keep the gap and place the new variables after it.
    // In both patterns no frozen variable moves. A gap that grew, moved, or
    // was added/removed alongside an append is drift: appends never require
    // growing a reservation.
    let gapShrankOnly = true;
    for (const key of frozenGapKeys) {
      const b = fresh.slots[key];
      if (b === undefined) {
        gapShrankOnly = false;
        break;
      }
      const a = frozen.slots[key];
      // The gap must stay at its slot and may only shrink or stay equal in
      // size (an array gap's type id changes with its length, so the byte
      // size is the semantic comparison).
      if (
        a.slot !== b.slot ||
        a.offset !== b.offset ||
        Number(b.numberOfBytes) > Number(a.numberOfBytes)
      ) {
        gapShrankOnly = false;
        break;
      }
    }
    const gapAppeared = freshGapKeys.some((k) => frozen.slots[k] === undefined);
    if (!gapShrankOnly || gapAppeared) {
      details.push(`appended ${appendedKeys.join(", ")} but a __gap reservation grew, moved, appeared or disappeared`);
      details.push(...gapChanges);
      return { contract, classification: "slot-drift", details };
    }
    details.push(`append-only growth: ${appendedKeys.join(", ")}`);
    details.push(...gapChanges);
    return { contract, classification: "appended", details };
  }

  if (gapChanged) {
    details.push(...gapChanges);
    details.push("__gap reservation changed without an accompanying append");
    return { contract, classification: "slot-drift", details };
  }

  if (frozen.canonicalHash !== fresh.canonicalHash) {
    // Hash differs with byte-identical slots: sourcePath/entry encoding drift.
    details.push(
      `canonicalHash mismatch with identical slot map (${frozen.canonicalHash} → ${fresh.canonicalHash})`
    );
    return { contract, classification: "slot-drift", details };
  }

  return { contract, classification: "unchanged", details };
}

function bytesToSlots(numberOfBytes: string): number {
  const n = Number(numberOfBytes);
  if (!Number.isFinite(n)) return 0;
  return Math.floor(n / 32);
}

/** Full report across all contracts; `pass` follows MANIFEST_SPEC.md §4. */
export function classifyManifestDrift(
  frozen: StorageLayoutManifest,
  fresh: StorageLayoutManifest,
  approvedHashes: ReadonlySet<string> = new Set()
): DriftReport {
  const findings: DriftFinding[] = [];
  const frozenNames = Object.keys(frozen.contracts);
  const freshNames = Object.keys(fresh.contracts);

  if (frozenNames.length > MAX_TRACKED_CONTRACTS || freshNames.length > MAX_TRACKED_CONTRACTS) {
    throw new Error(`classifyManifestDrift: manifest exceeds MAX_TRACKED_CONTRACTS=${MAX_TRACKED_CONTRACTS}`);
  }

  for (const name of freshNames) {
    const finding = classifyContractDrift(name, frozen.contracts[name], fresh.contracts[name]);
    if (finding.classification === "unchanged") continue;
    if (
      (finding.classification === "slot-drift" || finding.classification === "appended") &&
      approvedHashes.has(fresh.contracts[name].canonicalHash)
    ) {
      findings.push({ contract: name, classification: "approved", details: finding.details });
      continue;
    }
    findings.push(finding);
  }

  for (const name of frozenNames) {
    if (fresh.contracts[name] === undefined) {
      findings.push({ contract: name, classification: "removed", details: ["removed from the manifest"] });
    }
  }

  const pass = findings.every((f) => f.classification === "unchanged" || f.classification === "approved" || f.classification === "new");
  return { findings, pass };
}

// ---------------------------------------------------------------------------
// APPROVED_DRIFT.md parsing
// ---------------------------------------------------------------------------

/**
 * Approved-drift records are single markdown lines:
 *   - `CONTRACT_NAME` → `0xNEWHASH` (PR #NNN, classification)
 * Hashes on those lines are treated as maintainer-approved target layouts.
 */
export function parseApprovedDrift(md: string): Set<string> {
  const approved = new Set<string>();
  const lineRe = /^-\s+`([A-Za-z0-9_]+)`\s+→\s+`(0x[0-9a-fA-F]{64})`/gm;
  let m: RegExpExecArray | null;
  while ((m = lineRe.exec(md)) !== null) {
    approved.add(m[2]);
  }
  return approved;
}

// ---------------------------------------------------------------------------
// Disk helpers
// ---------------------------------------------------------------------------

export function readFrozenManifest(rootDir: string): StorageLayoutManifest | null {
  const file = path.join(rootDir, MANIFEST_RELATIVE_PATH);
  if (!fs.existsSync(file)) return null;
  const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as StorageLayoutManifest;
  if (parsed.schemaVersion !== MANIFEST_SCHEMA_VERSION) {
    throw new Error(
      `readFrozenManifest: schemaVersion ${parsed.schemaVersion} != frozen ${MANIFEST_SCHEMA_VERSION}`
    );
  }
  return parsed;
}

export function writeFrozenManifest(rootDir: string, manifest: StorageLayoutManifest): void {
  const file = path.join(rootDir, MANIFEST_RELATIVE_PATH);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, serializeManifest(manifest), "utf8");
}

export function readApprovedDrift(rootDir: string): Set<string> {
  const file = path.join(rootDir, APPROVED_DRIFT_RELATIVE_PATH);
  if (!fs.existsSync(file)) return new Set();
  return parseApprovedDrift(fs.readFileSync(file, "utf8"));
}
