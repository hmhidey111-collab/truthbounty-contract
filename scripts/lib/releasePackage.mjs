/**
 * @file releasePackage.mjs
 * @description STAB-SC-007 — canonical Optimism Sepolia release package.
 *
 * Dependency-free (Node built-ins + the repository's pure-JS keccak) library that:
 *   - derives deterministic CREATE2 addresses from a pinned factory, salt and init code,
 *   - canonicalises and checksums ABIs / bytecode / constructor inputs,
 *   - computes the immutable release ID and the package checksum,
 *   - validates every acceptance criterion of the release package fail-closed.
 *
 * No network access, no private keys, no deployment side effects. Every function is a pure
 * function of committed inputs (plus, optionally, build outputs) so identical inputs always
 * yield byte-identical packages.
 *
 * Consumers: scripts/generateOptimismSepoliaReleasePackage.mjs (writer),
 *            scripts/check-optimism-sepolia-release.mjs (CI gate),
 *            scripts/lib/releasePackageConsumer.mjs (API + frontend smoke tests).
 */

import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { keccak256 } from "./keccak256.mjs";
import { readToolchainPins } from "../check-release-reproducibility.mjs";

export const RELEASE_SCHEMA_VERSION = 1;
export const RELEASE_KIND = "truthbounty.optimism-sepolia.release-package";
export const RELEASE_DEFINITION_PATH = "config/optimism-sepolia-release.json";
export const RELEASE_DIR = "deployments/releases/optimism-sepolia";
export const RELEASE_MANIFEST_PATH = `${RELEASE_DIR}/release.json`;
export const RELEASE_CHECKSUM_PATH = `${RELEASE_DIR}/release.sha256`;
export const RELEASE_ARTIFACT_PINS_PATH = `${RELEASE_DIR}/artifact-pins.json`;
export const RELEASE_ABI_DIR = `${RELEASE_DIR}/abis`;

export const OPTIMISM_SEPOLIA_CHAIN_ID = 11155420;
export const OPTIMISM_SEPOLIA_EXPLORER = "https://sepolia-optimism.etherscan.io";

/** Package states. Only `published` may be consumed for a pinned testnet journey. */
export const RELEASE_STATUSES = Object.freeze(["candidate", "published"]);

/** Deployment-evidence classes. */
export const EVIDENCE_CLASSES = Object.freeze(["fork-rehearsal", "optimism-sepolia"]);

/** Well-known burn / sentinel addresses that may never appear in a release package. */
export const PLACEHOLDER_ADDRESSES = Object.freeze([
  "0x0000000000000000000000000000000000000000",
  "0x0000000000000000000000000000000000000001",
  "0x0000000000000000000000000000000000000002",
  "0x0000000000000000000000000000000000000003",
  "0x0000000000000000000000000000000000000004",
  "0x0000000000000000000000000000000000000005",
  "0x0000000000000000000000000000000000000006",
  "0x0000000000000000000000000000000000000007",
  "0x0000000000000000000000000000000000000008",
  "0x0000000000000000000000000000000000000009",
  "0x000000000000000000000000000000000000dead",
  "0xdeadbeef00000000000000000000000000000000",
  "0x1111111111111111111111111111111111111111",
  "0x2222222222222222222222222222222222222222",
  "0x3333333333333333333333333333333333333333",
  "0x4444444444444444444444444444444444444444",
  "0x5555555555555555555555555555555555555555",
  "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
]);

/** Canonical local / framework fixture addresses that are forbidden in a testnet package. */
export const LOCAL_FIXTURE_ADDRESSES = Object.freeze([
  "0x5fbdb2315678afecb367f032d93f642f64180aa3", // hardhat account #0
  "0xe7f1725e7734ce288f8367e1bb143e90bb3f0512", // hardhat account #1
  "0x9fe46736679d2d9a65f0992f2272de9f3c7fa6e0",
  "0xcf7ed3acca5a467e9e704c703e8d87f634fb0fc9",
  "0xdc64a140aa3e981100a9beca4e685f962f0cf6c9",
  "0x0165878a594ca255338adfa4d48449f69242eb8f",
  "0xa513e6e4b8f2a923d98304ec87f64353c4d5c853",
  "0x2279b7a0a67db372996a5fab50d91eaa73d2ebe6",
]);

/** Role classes the release package must document. */
export const REQUIRED_ROLE_CLASSES = Object.freeze([
  "governance",
  "timelock",
  "guardian",
  "upgradeAdmin",
  "treasury",
  "operational",
]);

/** Every secret-shaped string that must never leak into a published package. */
export const FORBIDDEN_SECRET_PATTERNS = Object.freeze([
  /0x[0-9a-fA-F]{64}\b/, // 32-byte private key material
  /\b(private[-_ ]?key|mnemonic|seed[-_ ]?phrase|secret[-_ ]?key)\b/i,
  /\b[a-zA-Z0-9+/]{60,}={0,2}\b/, // base64 blob
  /\b[A-Z0-9]{20,}\b/, // API-key-like uppercase token
]);

const HEX_0X = /^0x[0-9a-fA-F]*$/;
const ADDRESS_0X = /^0x[0-9a-fA-F]{40}$/;
const BYTES32_0X = /^0x[0-9a-fA-F]{64}$/;

// ─────────────────────────────────────────────────────────────────────────────
//  Byte / hash helpers
// ─────────────────────────────────────────────────────────────────────────────

export function hexToBytes(hex) {
  if (typeof hex !== "string") throw new Error("hex value must be a string");
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (clean.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(clean)) {
    throw new Error(`invalid hex string: ${String(hex).slice(0, 34)}…`);
  }
  return Uint8Array.from(Buffer.from(clean, "hex"));
}

export function bytesToHex(bytes) {
  return "0x" + Buffer.from(bytes).toString("hex");
}

export function concatBytes(...parts) {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export function keccakHex(hex) {
  return keccak256(hexToBytes(hex));
}

export function keccakUtf8(text) {
  return keccak256(text);
}

export function sha256Hex(input) {
  return createHash("sha256").update(input).digest("hex");
}

export function sha256FileHex(path) {
  return sha256Hex(readFileSync(path));
}

// ─────────────────────────────────────────────────────────────────────────────
//  Canonical JSON (RFC 8785 spirit: sorted keys, no insignificant whitespace)
// ─────────────────────────────────────────────────────────────────────────────

export function canonicalize(value) {
  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalize(item)).join(",")}]`;
  }
  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value)
      .filter((key) => value[key] !== undefined)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalize(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value ?? null);
}

export function canonicalSha256(value) {
  return sha256Hex(Buffer.from(canonicalize(value), "utf8"));
}

export function canonicalKeccak(value) {
  return keccakUtf8(canonicalize(value));
}

// ─────────────────────────────────────────────────────────────────────────────
//  Minimal, spec-compliant ABI encoder (static + dynamic params, tuples, arrays)
// ─────────────────────────────────────────────────────────────────────────────

function parseSolidityType(param) {
  const raw = param.type;
  if (raw === "tuple" || raw.startsWith("tuple")) {
    const suffix = raw.slice("tuple".length);
    return {
      base: "tuple",
      name: param.name,
      components: (param.components ?? []).map(parseSolidityType),
      array: suffix || null,
    };
  }
  const arrayMatch = raw.match(/^(.*)\[(\d*)\]$/);
  if (arrayMatch) {
    const inner = parseSolidityType({ ...param, type: arrayMatch[1] });
    return { ...inner, array: arrayMatch[2] === "" ? "dynamic" : Number(arrayMatch[2]) };
  }
  return { base: raw, array: null, components: null, name: param.name };
}

function isDynamicType(type) {
  if (type.array !== null) {
    if (type.array === "dynamic") return true;
    return isDynamicType({ ...type, array: null });
  }
  if (type.base === "bytes" || type.base === "string") return true;
  if (type.base === "tuple") return type.components.some(isDynamicType);
  return false;
}

function staticSizeOf(type) {
  if (type.array !== null) {
    if (type.array === "dynamic") throw new Error("dynamic array has no static size");
    return type.array * staticSizeOf({ ...type, array: null });
  }
  if (type.base === "tuple") {
    return type.components.reduce((sum, component) => sum + staticSizeOf(component), 0);
  }
  return 32;
}

function uintWord(value, bits, signed) {
  let big;
  if (typeof value === "bigint") big = value;
  else if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw new Error(`unsafe integer ${value}`);
    big = BigInt(value);
  } else if (typeof value === "string") big = BigInt(value);
  else throw new Error(`cannot encode ${typeof value} as int${bits}`);

  const limit = 1n << BigInt(bits);
  if (signed) {
    const min = -(limit >> 1n);
    const max = (limit >> 1n) - 1n;
    if (big < min || big > max) throw new Error(`value ${big} out of range for int${bits}`);
    if (big < 0n) big += limit;
  } else if (big < 0n || big >= limit) {
    throw new Error(`value ${big} out of range for uint${bits}`);
  }
  return Uint8Array.from(Buffer.from(big.toString(16).padStart(64, "0"), "hex"));
}

function padRight(bytes) {
  const padded = new Uint8Array(Math.ceil(bytes.length / 32) * 32);
  padded.set(bytes);
  return padded;
}

function encodeStatic(type, value) {
  if (type.array !== null) {
    if (type.array === "dynamic") throw new Error("dynamic array is not static");
    const values = Array.isArray(value) ? value : [];
    if (values.length !== type.array) throw new Error(`expected ${type.array} array items, got ${values.length}`);
    return concatBytes(
      ...values.map((item) => encodeStatic({ ...type, array: null }, item)),
    );
  }
  if (type.base === "tuple") {
    if (value === null || typeof value !== "object") throw new Error("tuple value must be an object");
    return concatBytes(
      ...type.components.map((component, index) =>
        encodeStatic(component, value[index] !== undefined ? value[index] : value[component.name ?? index]),
      ),
    );
  }
  switch (type.base) {
    case "address": {
      if (!ADDRESS_0X.test(String(value))) throw new Error(`invalid address ${value}`);
      return Uint8Array.from(Buffer.from(String(value).slice(2).toLowerCase().padStart(64, "0"), "hex"));
    }
    case "bool": {
      if (typeof value !== "boolean") throw new Error(`bool expected, got ${typeof value}`);
      return uintWord(value ? 1 : 0, 256, false);
    }
    case "bytes32":
      if (!BYTES32_0X.test(String(value))) throw new Error(`invalid bytes32 ${value}`);
      return hexToBytes(value);
    case "bytes":
    case "string":
      throw new Error(`${type.base} is dynamic and cannot be encoded statically`);
    default: {
      const uintMatch = type.base.match(/^uint(\d+)$/);
      if (uintMatch) return uintWord(value, Number(uintMatch[1]), false);
      const intMatch = type.base.match(/^int(\d+)$/);
      if (intMatch) return uintWord(value, Number(intMatch[1]), true);
      const fixedBytes = type.base.match(/^bytes(\d+)$/);
      if (fixedBytes) {
        const width = Number(fixedBytes[1]);
        const bytes = hexToBytes(String(value));
        if (bytes.length !== width) throw new Error(`bytes${width} expected, got ${bytes.length} bytes`);
        return padRight(bytes);
      }
      if (type.base === "function") {
        const bytes = hexToBytes(String(value));
        if (bytes.length !== 24) throw new Error("function type must be 24 bytes");
        return padRight(bytes);
      }
      throw new Error(`unsupported ABI type: ${type.base}`);
    }
  }
}

function encodeValue(type, value) {
  if (!isDynamicType(type)) return encodeStatic(type, value);
  if (type.array === "dynamic") {
    if (!Array.isArray(value)) throw new Error("dynamic array value must be an array");
    const inner = { ...type, array: null };
    return concatBytes(
      uintWord(value.length, 256, false),
      encodeSequence(new Array(value.length).fill(inner), value),
    );
  }
  if (type.array !== null) {
    const inner = { ...type, array: null };
    return encodeSequence(new Array(type.array).fill(inner), value);
  }
  if (type.base === "bytes" || type.base === "string") {
    const bytes = typeof value === "string" && type.base === "bytes"
      ? hexToBytes(value)
      : Uint8Array.from(Buffer.from(String(value ?? ""), "utf8"));
    return concatBytes(uintWord(bytes.length, 256, false), padRight(bytes));
  }
  if (type.base === "tuple") {
    return encodeSequence(type.components, value);
  }
  throw new Error(`cannot encode dynamic type ${type.base}`);
}

/** Encode a parameter list with correct head/tail placement. */
function encodeSequence(types, values) {
  if (!Array.isArray(values)) throw new Error("expected an array of values");
  if (types.length !== values.length) {
    throw new Error(`expected ${types.length} values, got ${values.length}`);
  }
  const heads = [];
  const tails = [];
  let headLength = 0;
  let tailLength = 0;
  const encoded = types.map((type, index) => {
    const dynamic = isDynamicType(type);
    headLength += dynamic ? 32 : staticSizeOf(type);
    return dynamic ? encodeValue(type, values[index]) : null;
  });
  for (let i = 0; i < types.length; i += 1) {
    if (encoded[i] === null) {
      heads.push(encodeStatic(types[i], values[i]));
    } else {
      heads.push(uintWord(headLength + tailLength, 256, false));
      tails.push(encoded[i]);
      tailLength += encoded[i].length;
    }
  }
  return concatBytes(...heads, ...tails);
}

/**
 * @notice Encode constructor arguments exactly as solc would append them to creation code.
 * @param inputs ABI `constructor.inputs` array (may be empty).
 * @param args Positional JSON values (objects for tuples).
 */
export function encodeAbiParameters(inputs, args) {
  const types = (inputs ?? []).map(parseSolidityType);
  const values = args ?? [];
  if (types.length !== values.length) {
    throw new Error(`constructor arity mismatch: ABI expects ${types.length}, definition supplies ${values.length}`);
  }
  return bytesToHex(encodeSequence(types, values));
}

// ─────────────────────────────────────────────────────────────────────────────
//  CREATE2
// ─────────────────────────────────────────────────────────────────────────────

export function deriveSalt(saltDomain, name) {
  return keccakUtf8(`${saltDomain}:${name}`);
}

export function initCodeHashOf(creationBytecodeHex, encodedArgsConstructorHex) {
  const suffix = encodedArgsConstructorHex === "0x" ? "" : encodedArgsConstructorHex.slice(2);
  return keccakHex(`${creationBytecodeHex}${suffix}`);
}

export function deriveCreate2Address(factory, salt, initCodeHash) {
  if (!ADDRESS_0X.test(factory)) throw new Error(`invalid factory address ${factory}`);
  if (!BYTES32_0X.test(salt)) throw new Error(`invalid salt ${salt}`);
  if (!BYTES32_0X.test(initCodeHash)) throw new Error(`invalid init code hash ${initCodeHash}`);
  const digest = keccak256(
    concatBytes(new Uint8Array([0xff]), hexToBytes(factory), hexToBytes(salt), hexToBytes(initCodeHash)),
  );
  // The address is the low 20 bytes (last 40 hex characters) of the digest.
  return `0x${digest.slice(26)}`;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Artifact discovery / pinning
// ─────────────────────────────────────────────────────────────────────────────

function collectArtifactFiles(dir, files = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "build-info") continue;
      collectArtifactFiles(full, files);
      continue;
    }
    if (entry.name.endsWith(".json")) files.push(full);
  }
  return files;
}

function readFoundryArtifact(file) {
  const json = JSON.parse(readFileSync(file, "utf8"));
  if (!json.bytecode || typeof json.bytecode.object !== "string") return null;
  const contractName = json.contractName ?? file.split("/").pop().replace(/\.json$/, "");
  if (!json.abi) return null;
  return {
    contractName,
    source: json.ast?.absolutePath ?? json.sourceName ?? null,
    abi: json.abi,
    bytecode: `0x${json.bytecode.object}`,
    deployedBytecode: `0x${json.deployedBytecode?.object ?? ""}`,
    linkReferences: json.bytecode.linkReferences ?? {},
    immutableReferences: json.deployedBytecode?.immutableReferences ?? {},
  };
}

function readHardhatArtifact(file) {
  let json;
  try {
    json = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
  if (typeof json.contractName !== "string" || typeof json.bytecode !== "string") return null;
  if (json.bytecode === "0x" && json.deployedBytecode === "0x") return null;
  return {
    contractName: json.contractName,
    source: json.sourceName ?? null,
    abi: json.abi ?? [],
    bytecode: json.bytecode,
    deployedBytecode: json.deployedBytecode ?? "0x",
    linkReferences: json.linkReferences ?? {},
    immutableReferences: json.immutableReferences ?? json.deployedBytecode?.immutableReferences ?? {},
  };
}

/**
 * @notice Locate reproducible build outputs (Foundry `out/` first, then Hardhat `artifacts/`).
 * @returns {{kind: string, dir: string}|null}
 */
export function findBuildOutputs(rootDir, prefer = "auto") {
  const foundryOut = join(rootDir, "out");
  const hardhatArtifacts = join(rootDir, "artifacts", "contracts");
  const hasFoundry = existsSync(foundryOut) && statSync(foundryOut).isDirectory() && readdirSync(foundryOut).length > 0;
  const hasHardhat = existsSync(hardhatArtifacts);
  if (prefer === "hardhat") {
    if (hasHardhat) return { kind: "hardhat", dir: join(rootDir, "artifacts") };
    return null;
  }
  if (prefer === "foundry") {
    if (hasFoundry) return { kind: "foundry", dir: foundryOut };
    return null;
  }
  if (hasFoundry) return { kind: "foundry", dir: foundryOut };
  if (hasHardhat) return { kind: "hardhat", dir: join(rootDir, "artifacts") };
  return null;
}

/** Read every build artifact keyed by contract name (first writer wins, deterministic order). */
export function loadBuildArtifacts(rootDir, prefer = "auto") {
  const build = findBuildOutputs(rootDir, prefer);
  if (build === null) return null;
  const byName = new Map();
  for (const file of collectArtifactFiles(build.dir).sort()) {
    const artifact = build.kind === "foundry" ? readFoundryArtifact(file) : readHardhatArtifact(file);
    if (artifact === null || byName.has(artifact.contractName)) continue;
    byName.set(artifact.contractName, artifact);
  }
  return { kind: build.kind, byName };
}

/** Load the committed release manifest. */
export function loadReleasePackage(rootDir = REPO_ROOT) {
  const path = join(rootDir, RELEASE_MANIFEST_PATH);
  if (!existsSync(path)) throw new Error(`release package missing: ${RELEASE_MANIFEST_PATH}`);
  return JSON.parse(readFileSync(path, "utf8"));
}

export function loadArtifactPins(rootDir) {
  const path = join(rootDir, RELEASE_ARTIFACT_PINS_PATH);
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf8"));
}

export function abiFileRelative(name) {
  return `${RELEASE_ABI_DIR}/${name}.json`;
}

export function loadAbi(rootDir, name) {
  const path = join(rootDir, abiFileRelative(name));
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf8"));
}

// ─────────────────────────────────────────────────────────────────────────────
//  Release ID / package checksum
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @notice Immutable release identity.
 * @dev Bounded to the component set that defines *what* is deployed on *which* chain with
 *      *which* artifacts — never to mutable evidence (status, block numbers, custody
 *      assignments, verification links). Promotion from `candidate` to `published`
 *      therefore does not change the release ID consumers pin.
 */
export function computeReleaseId(pkg) {
  const core = {
    chainId: pkg.network?.chainId,
    releaseName: pkg.releaseName,
    protocolVersion: pkg.protocolVersion,
    configurationVersion: pkg.configurationVersion,
    saltDomain: pkg.deterministicDeployment?.saltDomain,
    factory: pkg.deterministicDeployment?.factory?.address,
    toolchain: pkg.toolchain,
    contracts: (pkg.contracts ?? []).map((contract) => ({
      name: contract.name,
      source: contract.source,
      sourceSha256: contract.sourceSha256,
      address: contract.address,
      salt: contract.deployment?.salt,
      initCodeHash: contract.deployment?.initCodeHash,
      constructorArgsSha256: contract.deployment?.constructorArgsSha256,
      bytecodeKeccak: contract.artifact?.bytecodeKeccak,
      deployedBytecodeKeccak: contract.artifact?.deployedBytecodeKeccak,
      abiSha256: contract.artifact?.abiSha256,
    })),
    roleGrants: (pkg.roleGrants ?? []).map((grant) => ({
      contract: grant.contract,
      role: grant.role,
      custodyRef: grant.holder?.custodyRef ?? null,
    })),
    roleOwnership: (pkg.roleOwnership ?? []).map((entry) => ({
      class: entry.class,
      custodyRef: entry.holder?.custodyRef ?? null,
    })),
  };
  return canonicalKeccak(core);
}

/** sha256 over the canonical document with `packageChecksum` removed. */
export function computePackageChecksum(pkg) {
  const clone = JSON.parse(JSON.stringify(pkg));
  delete clone.packageChecksum;
  // The consumer blocks pin the checksum they consume; normalise the self-reference so the
  // digest stays well-defined while still covering every other consumer field.
  for (const consumer of ["api", "frontend"]) {
    if (clone.consumers?.[consumer]) clone.consumers[consumer].packageChecksum = null;
  }
  return `sha256:${canonicalSha256(clone)}`;
}

/** sha256 of the exact committed manifest bytes (what `sha256sum -c` verifies). */
export function computeFileChecksum(bytes) {
  return sha256Hex(bytes);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Validation
// ─────────────────────────────────────────────────────────────────────────────

function fail(problems, message) {
  problems.push(message);
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function collectStrings(value, trail = "$", out = []) {
  if (typeof value === "string") out.push({ trail, value });
  else if (Array.isArray(value)) value.forEach((item, i) => collectStrings(item, `${trail}[${i}]`, out));
  else if (isPlainObject(value)) {
    for (const [key, item] of Object.entries(value)) collectStrings(item, `${trail}.${key}`, out);
  }
  return out;
}

/** Addresses, bytecode hashes and other pure digests are expected — never secret material. */
const DIGEST_SHAPED = /^(0x)?[0-9a-fA-F]{40,}$/;

export function findSecretLeaks(pkg) {
  const problems = [];
  for (const { trail, value } of collectStrings(pkg)) {
    if (DIGEST_SHAPED.test(value) || /^[0-9]+$/.test(value)) continue;
    // A bare upper-snake token is an environment-variable *name* (e.g. rpcUrlEnv), not a key.
    if (/^[A-Z][A-Z0-9_]*$/.test(value)) continue;
    if (/\b(private[-_ ]?key|mnemonic|seed[-_ ]?phrase|secret[-_ ]?key)\b\s*[:=]\s*\S+/i.test(value) ||
        /--private-key\s+\S+/i.test(value)) {
      problems.push(`secret-shaped value at ${trail}: secret material assignment`);
      continue;
    }
    if (/0x[0-9a-fA-F]{64}\b/.test(value)) {
      problems.push(`secret-shaped value at ${trail}: embedded 32-byte hex key material`);
      continue;
    }
    if (/\b[A-Za-z0-9+/]{60,}={0,2}\b/.test(value) && /[A-Z]/.test(value) && /[a-z]/.test(value) && /[+/=]/.test(value)) {
      problems.push(`secret-shaped value at ${trail}: base64-shaped blob`);
      continue;
    }
    // Environment-variable references ($OPTIMISM_SEPOLIA_RPC_URL) are required and are not keys.
    const withoutEnvRefs = value.replace(/\$\{?[A-Z][A-Z0-9_]*\}?/g, "");
    if (/\b[A-Z][A-Z0-9_]{19,}\b/.test(withoutEnvRefs)) {
      problems.push(`secret-shaped value at ${trail}: API-key-shaped token`);
    }
  }
  return problems;
}

export function validateToolchain(pkg, rootDir) {
  const problems = [];
  const expected = pkg.toolchain ?? {};
  let pins;
  try {
    pins = readToolchainPins(rootDir);
  } catch (error) {
    return [`toolchain config unreadable: ${error.message}`];
  }
  if (pins.hardhat.solc !== expected.solc) {
    fail(problems, `toolchain drift: hardhat solidity ${pins.hardhat.solc} != package ${expected.solc}`);
  }
  if (pins.hardhat.evmVersion !== expected.evmVersion) {
    fail(problems, `toolchain drift: hardhat evmVersion ${pins.hardhat.evmVersion} != package ${expected.evmVersion}`);
  }
  if (pins.hardhat.viaIR !== expected.viaIR) {
    fail(problems, `toolchain drift: hardhat viaIR ${pins.hardhat.viaIR} != package ${expected.viaIR}`);
  }
  if (pins.hardhat.optimizerEnabled !== expected.optimizer?.enabled) {
    fail(problems, `toolchain drift: hardhat optimizer.enabled ${pins.hardhat.optimizerEnabled} != package ${expected.optimizer?.enabled}`);
  }
  if (pins.hardhat.optimizerRuns !== expected.optimizer?.runs) {
    fail(problems, `toolchain drift: hardhat optimizer.runs ${pins.hardhat.optimizerRuns} != package ${expected.optimizer?.runs}`);
  }
  if (pins.foundry.solc !== expected.solc) {
    fail(problems, `toolchain drift: foundry solc ${pins.foundry.solc} != package ${expected.solc}`);
  }
  if (pins.foundry.optimizerRuns !== expected.optimizer?.runs) {
    fail(problems, `toolchain drift: foundry optimizer_runs ${pins.foundry.optimizerRuns} != package ${expected.optimizer?.runs}`);
  }
  if (pins.foundry.viaIR !== expected.viaIR) {
    fail(problems, `toolchain drift: foundry via_ir ${pins.foundry.viaIR} != package ${expected.viaIR}`);
  }
  if (expected.evmVersion !== "cancun") {
    fail(problems, `release policy: evmVersion must be cancun, found ${expected.evmVersion}`);
  }
  if (expected.metadataBytecodeHash !== "ipfs") {
    fail(problems, `release policy: metadata bytecodeHash must be ipfs, found ${expected.metadataBytecodeHash}`);
  }
  return problems;
}

/**
 * @notice Validate the complete release package fail-closed.
 * @param pkg Parsed `release.json`.
 * @param options.rootDir Repository root (defaults to this file's repository).
 * @param options.withArtifacts Recompute ABI/bytecode/init-code hashes from build outputs.
 * @param options.definition Parsed release definition (defaults to config/optimism-sepolia-release.json).
 */
export function validateReleasePackage(pkg, options = {}) {
  const rootDir = options.rootDir ?? REPO_ROOT;
  const problems = [];
  if (!isPlainObject(pkg)) return ["release package is not an object"];

  // ── Identity & schema ────────────────────────────────────────────────────
  if (pkg.schemaVersion !== RELEASE_SCHEMA_VERSION) fail(problems, `schemaVersion must be ${RELEASE_SCHEMA_VERSION}`);
  if (pkg.kind !== RELEASE_KIND) fail(problems, `kind must be ${RELEASE_KIND}`);
  if (!RELEASE_STATUSES.includes(pkg.status)) fail(problems, `status must be one of ${RELEASE_STATUSES.join(", ")}`);
  if (typeof pkg.releaseName !== "string" || pkg.releaseName.length < 3) fail(problems, "releaseName is required");
  if (typeof pkg.protocolVersion !== "string" || !/^\d+\.\d+\.\d+/.test(pkg.protocolVersion)) {
    fail(problems, "protocolVersion must be a semantic version");
  }
  if (!Number.isInteger(pkg.configurationVersion) || pkg.configurationVersion < 1) {
    fail(problems, "configurationVersion must be a positive integer");
  }

  // ── Network ──────────────────────────────────────────────────────────────
  if (pkg.network?.chainId !== OPTIMISM_SEPOLIA_CHAIN_ID) {
    fail(problems, `chain drift: chainId ${pkg.network?.chainId} != ${OPTIMISM_SEPOLIA_CHAIN_ID} (Optimism Sepolia only)`);
  }
  if (pkg.network?.name !== "optimism-sepolia") fail(problems, `network.name must be optimism-sepolia`);
  if (pkg.network?.caip2 !== `eip155:${OPTIMISM_SEPOLIA_CHAIN_ID}`) {
    fail(problems, `network.caip2 must be eip155:${OPTIMISM_SEPOLIA_CHAIN_ID}`);
  }
  if (pkg.network?.explorerBase !== OPTIMISM_SEPOLIA_EXPLORER) {
    fail(problems, `network.explorerBase must be ${OPTIMISM_SEPOLIA_EXPLORER}`);
  }

  problems.push(...validateToolchain(pkg, rootDir));

  // ── Deterministic deployment ─────────────────────────────────────────────
  const deployment = pkg.deterministicDeployment ?? {};
  if (deployment.method !== "create2") fail(problems, "deterministicDeployment.method must be create2");
  if (!ADDRESS_0X.test(String(deployment.factory?.address))) {
    fail(problems, "deterministicDeployment.factory.address must be a 20-byte address");
  }
  if (!BYTES32_0X.test(String(deployment.factory?.codeHash))) {
    fail(problems, "deterministicDeployment.factory.codeHash must be a 32-byte hash");
  } else if (/^0x0+$/.test(String(deployment.factory.codeHash))) {
    fail(problems, "deterministicDeployment.factory.codeHash must be the observed runtime code hash, not zero");
  }
  if (typeof deployment.saltDomain !== "string" || deployment.saltDomain.length < 8) {
    fail(problems, "deterministicDeployment.saltDomain is required");
  }
  if (!isPlainObject(deployment.bootstrapAdmin) || !ADDRESS_0X.test(String(deployment.bootstrapAdmin.address))) {
    fail(problems, "deterministicDeployment.bootstrapAdmin.address is required");
  }

  // ── Contracts ────────────────────────────────────────────────────────────
  const contracts = pkg.contracts;
  if (!Array.isArray(contracts) || contracts.length === 0) {
    return problems.concat(["contracts must be a non-empty array"]);
  }
  const seenNames = new Set();
  const seenAddresses = new Map();
  const addressesByName = new Map();
  for (const contract of contracts) {
    const label = contract?.name ?? "<unnamed>";
    if (typeof contract?.name !== "string" || contract.name.length === 0) fail(problems, "contract without a name");
    if (seenNames.has(contract?.name)) fail(problems, `duplicate contract name: ${contract?.name}`);
    seenNames.add(contract?.name);
    addressesByName.set(contract?.name, contract?.address);

    const address = String(contract?.address ?? "").toLowerCase();
    if (!ADDRESS_0X.test(address)) fail(problems, `${label}: address is not a 20-byte hex address`);
    if (PLACEHOLDER_ADDRESSES.map((a) => a.toLowerCase()).includes(address)) {
      fail(problems, `${label}: placeholder/burn address forbidden (${address})`);
    }
    if (LOCAL_FIXTURE_ADDRESSES.map((a) => a.toLowerCase()).includes(address)) {
      fail(problems, `${label}: local framework fixture address forbidden (${address})`);
    }
    if (seenAddresses.has(address)) {
      fail(problems, `${label}: duplicate address ${address} also used by ${seenAddresses.get(address)}`);
    }
    seenAddresses.set(address, label);

    if (typeof contract?.source !== "string" || !contract.source.startsWith("contracts/") || !contract.source.endsWith(".sol")) {
      fail(problems, `${label}: source must be a Solidity file under contracts/`);
    } else {
      const sourcePath = join(rootDir, contract.source);
      if (!existsSync(sourcePath)) {
        fail(problems, `${label}: source missing: ${contract.source}`);
      } else if (contract.sourceSha256 !== sha256FileHex(sourcePath)) {
        fail(problems, `${label}: source drift: ${contract.source} sha256 ${sha256FileHex(sourcePath)} != pin ${contract.sourceSha256}`);
      }
    }

    const salt = String(contract?.deployment?.salt ?? "");
    if (!BYTES32_0X.test(salt)) fail(problems, `${label}: deployment.salt must be 32 bytes`);
    const expectedSalt = deriveSalt(deployment.saltDomain, label);
    if (salt !== expectedSalt) fail(problems, `${label}: salt ${salt} != derived ${expectedSalt}`);

    const initCodeHash = String(contract?.deployment?.initCodeHash ?? "");
    if (!BYTES32_0X.test(initCodeHash)) fail(problems, `${label}: deployment.initCodeHash must be 32 bytes`);
    const derived = deriveCreate2Address(deployment.factory?.address, salt, initCodeHash);
    if (address !== derived.toLowerCase()) {
      fail(problems, `${label}: address ${address} != CREATE2 ${derived} (factory/salt/init-code drift)`);
    }
    const argsDigest = canonicalSha256(contract?.deployment?.constructorArgs ?? []);
    if (contract?.deployment?.constructorArgsSha256 !== argsDigest) {
      fail(problems, `${label}: constructorArgsSha256 mismatch (args mutated)`);
    }

    const artifact = contract?.artifact ?? {};
    for (const field of ["bytecodeKeccak", "deployedBytecodeKeccak", "abiSha256", "abiFileSha256"]) {
      if (!BYTES32_0X.test(String(artifact[field] ?? ""))) fail(problems, `${label}: artifact.${field} must be 32 bytes`);
    }
    if (!Number.isInteger(artifact.creationBytes) || artifact.creationBytes <= 0) {
      fail(problems, `${label}: artifact.creationBytes must be a positive integer`);
    }
    if (!Number.isInteger(artifact.runtimeBytes) || artifact.runtimeBytes <= 0) {
      fail(problems, `${label}: artifact.runtimeBytes must be a positive integer`);
    }
    if (artifact.creationBytes > 49_152) fail(problems, `${label}: creation code exceeds the EIP-3860 init-code limit`);
    if (artifact.runtimeBytes > 24_576) fail(problems, `${label}: runtime code exceeds the EIP-170 limit`);
    if (artifact.linkReferences !== 0) fail(problems, `${label}: canonical modules must link no libraries`);

    const abiPath = contract?.artifact?.abiFile;
    if (typeof abiPath !== "string" || !abiPath.startsWith(`${RELEASE_ABI_DIR}/`)) {
      fail(problems, `${label}: artifact.abiFile must live under ${RELEASE_ABI_DIR}/`);
    } else {
      const abs = join(rootDir, abiPath);
      if (!existsSync(abs)) {
        fail(problems, `${label}: ABI file missing: ${abiPath}`);
      } else {
        const bytes = readFileSync(abs);
        if (`0x${sha256Hex(bytes)}` !== String(contract.artifact.abiFileSha256)) {
          fail(problems, `${label}: ABI file drift: ${abiPath}`);
        }
        const abi = JSON.parse(bytes.toString("utf8"));
        if (canonicalKeccak(abi) !== contract.artifact.abiSha256) {
          fail(problems, `${label}: ABI checksum drift`);
        }
      }
    }

    if (!["none", "erc1967", "module-registry"].includes(contract?.proxy?.kind)) {
      fail(problems, `${label}: proxy.kind must be one of none, erc1967, module-registry`);
    }
    if (contract?.proxy?.kind === "erc1967") {
      if (!ADDRESS_0X.test(String(contract.proxy.admin))) fail(problems, `${label}: ERC1967 proxy requires an admin address`);
    }

    if (contract?.sourceVerification !== undefined) {
      const url = contract.sourceVerification?.url;
      if (url !== null && (typeof url !== "string" || !url.startsWith(OPTIMISM_SEPOLIA_EXPLORER) || !url.includes(address) || !url.includes("#code"))) {
        fail(problems, `${label}: source verification URL must point at ${OPTIMISM_SEPOLIA_EXPLORER}/address/<address>#code`);
      }
      if (pkg.status === "published" && contract.sourceVerification?.status !== "verified") {
        fail(problems, `${label}: published package requires verified source (status=${contract.sourceVerification?.status})`);
      }
    }
  }

  // ── Role ownership ───────────────────────────────────────────────────────
  const roleOwnership = pkg.roleOwnership;
  if (!Array.isArray(roleOwnership)) {
    fail(problems, "roleOwnership must be an array");
  } else {
    const classes = new Set(roleOwnership.map((entry) => entry?.class));
    for (const required of REQUIRED_ROLE_CLASSES) {
      if (!classes.has(required)) fail(problems, `roleOwnership missing required class: ${required}`);
    }
    for (const entry of roleOwnership) {
      if (!entry?.holder || typeof entry.holder !== "object") {
        fail(problems, `roleOwnership.${entry?.class}: holder is required`);
        continue;
      }
      const holderAddress = entry.holder.address;
      if (!ADDRESS_0X.test(String(holderAddress))) {
        fail(problems, `roleOwnership.${entry.class}: holder.address is not a 20-byte address`);
      }
      if (!["assigned", "unassigned"].includes(entry.holder.custody)) {
        fail(problems, `roleOwnership.${entry.class}: holder.custody must be assigned or unassigned`);
      }
      if (entry.holder.custody === "assigned" && entry.holder.label === undefined) {
        fail(problems, `roleOwnership.${entry.class}: assigned custody requires a human-readable label`);
      }
    }
  }

  // ── Role grants: no retained deployer authority, complete wiring ──────────
  const roleGrants = pkg.roleGrants;
  const bootstrap = String(deployment.bootstrapAdmin?.address ?? "").toLowerCase();
  if (!Array.isArray(roleGrants) || roleGrants.length === 0) {
    fail(problems, "roleGrants must be a non-empty array");
  } else {
    const grantKeys = new Set();
    for (const grant of roleGrants) {
      const key = `${grant?.contract}:${grant?.role}`;
      if (grantKeys.has(key)) fail(problems, `duplicate role grant ${key}`);
      grantKeys.add(key);
      if (!seenNames.has(grant?.contract)) fail(problems, `role grant targets unknown contract ${grant?.contract}`);
      if (typeof grant?.role !== "string" || grant.role.length === 0) fail(problems, `${key}: role name required`);
      if (grant?.roleHash !== keccakUtf8(String(grant?.role))) {
        fail(problems, `${key}: role hash drift`);
      }
      if (!grant?.holder || typeof grant.holder !== "object") {
        fail(problems, `${key}: holder required`);
        continue;
      }
      if (grant.holder.address !== undefined && !ADDRESS_0X.test(String(grant.holder.address))) {
        fail(problems, `${key}: holder.address invalid`);
      }
      if (String(grant.holder.address ?? "").toLowerCase() === bootstrap) {
        fail(problems, `${key}: deployer/bootstrap admin retains authority after finalization`);
      }
      if (grant.holder.kind === "custody" && typeof grant.holder.custodyRef !== "string") {
        fail(problems, `${key}: custody holder requires custodyRef`);
      }
    }
  }

  // ── Finalization ─────────────────────────────────────────────────────────
  const finalization = pkg.finalization ?? {};
  if (finalization.bootstrapAdmin === undefined || String(finalization.bootstrapAdmin).toLowerCase() !== bootstrap) {
    fail(problems, "finalization.bootstrapAdmin must equal deterministicDeployment.bootstrapAdmin.address");
  }
  if (finalization.deployerAuthorityRemoved !== true) {
    fail(problems, "finalization.deployerAuthorityRemoved must be true");
  }
  if (!Array.isArray(finalization.steps) || finalization.steps.length === 0) {
    fail(problems, "finalization.steps must be a non-empty array");
  } else {
    const actions = new Set(finalization.steps.map((step) => step?.action));
    if (!actions.has("renounce")) fail(problems, "finalization must renounce bootstrap authority");
    if (!actions.has("verify")) fail(problems, "finalization must verify the post-transfer role state");
    const renounceTargets = finalization.steps
      .filter((step) => step?.action === "renounce")
      .map((step) => `${step?.contract}:${step?.role}:${String(step?.account ?? "").toLowerCase()}`);
    for (const contract of contracts) {
      const covered = renounceTargets.some((target) => target.startsWith(`${contract.name}:`));
      if (contract.accessControl === true && !covered) {
        fail(problems, `${contract.name}: finalization does not renounce bootstrap authority`);
      }
    }
  }

  // ── Deployment block & event cursor ──────────────────────────────────────
  const blockNumber = pkg.deployment?.blockNumber;
  const blockHash = pkg.deployment?.blockHash;
  const cursor = pkg.deployment?.eventStartCursor;
  if (pkg.status === "candidate") {
    if (!Array.isArray(pkg.blockers) || pkg.blockers.length === 0) {
      fail(problems, "candidate package must declare the blockers that prevent publication");
    }
    if (blockNumber !== null || blockHash !== null) {
      fail(problems, "candidate package must not claim a deployment block (evidence must be produced, not asserted)");
    }
    if (cursor?.blockNumber !== null || cursor?.blockHash !== null) {
      fail(problems, "candidate package must not claim an event start cursor");
    }
  } else if (pkg.status === "published") {
    if (!Number.isInteger(blockNumber) || blockNumber <= 0) {
      fail(problems, "published package requires a positive deployment.blockNumber");
    }
    if (!BYTES32_0X.test(String(blockHash))) {
      fail(problems, "published package requires a 32-byte deployment.blockHash");
    }
    if (cursor?.blockNumber !== blockNumber) {
      fail(problems, "eventStartCursor.blockNumber must equal the deployment block");
    }
    if (cursor?.blockHash !== blockHash) {
      fail(problems, "eventStartCursor.blockHash must equal the deployment block hash");
    }
    if (!Number.isInteger(pkg.deployment?.timestamp) || pkg.deployment.timestamp <= 0) {
      fail(problems, "published package requires a positive deployment timestamp");
    }
    if (Array.isArray(pkg.blockers) && pkg.blockers.length !== 0) {
      fail(problems, "published package cannot carry unresolved blockers");
    }
    if (pkg.evidenceClass !== "optimism-sepolia") {
      fail(problems, "published package requires evidenceClass=optimism-sepolia (fork rehearsals cannot be published)");
    }
    if (pkg.verification?.onchain?.status !== "verified") {
      fail(problems, "published package requires on-chain verification evidence");
    }
    // Publication requires real owners: every custody slot must be assigned before a package
    // can be consumed for a pinned testnet journey.
    for (const entry of roleOwnership ?? []) {
      if (entry?.holder?.custody !== "assigned") {
        fail(problems, `published package requires assigned custody for role class ${entry?.class}`);
      }
    }
    for (const grant of roleGrants ?? []) {
      if (grant?.holder?.custody === "unassigned") {
        fail(problems, `published package requires assigned custody for ${grant.contract}:${grant.role}`);
      }
    }
    if (deployment.bootstrapAdmin?.custody !== "assigned") {
      fail(problems, "published package requires an assigned bootstrapAdmin custody slot");
    }
    for (const contract of contracts) {
      if (!Number.isInteger(contract?.deployment?.deploymentBlock) || contract.deployment.deploymentBlock <= 0) {
        fail(problems, `${contract.name}: published package requires a per-contract deploymentBlock`);
      }
      if (!BYTES32_0X.test(String(contract?.deployment?.txHash ?? ""))) {
        fail(problems, `${contract.name}: published package requires the deployment transaction hash`);
      }
      if (contract?.sourceVerification?.status !== "verified") {
        fail(problems, `${contract.name}: published package requires verified source`);
      }
      if (contract?.onchain?.codePresent !== true) {
        fail(problems, `${contract.name}: published package requires code-present evidence`);
      }
    }
    const maxBlock = Math.max(...contracts.map((c) => c?.deployment?.deploymentBlock ?? 0));
    if (Number.isInteger(blockNumber) && maxBlock > blockNumber) {
      fail(problems, "deployment.blockNumber precedes a contract deployment block");
    }
  }

  // ── Verification / consumers / commands / rollback ───────────────────────
  if (pkg.verification?.explorer?.totalCount !== contracts.length) {
    fail(problems, "verification.explorer.totalCount must cover every canonical contract");
  }
  for (const consumer of ["api", "frontend"]) {
    const entry = pkg.consumers?.[consumer];
    if (!isPlainObject(entry)) {
      fail(problems, `consumers.${consumer} must be present`);
      continue;
    }
    if (entry.releaseId !== pkg.releaseId) fail(problems, `consumers.${consumer}.releaseId must equal the package releaseId`);
    if (entry.packageChecksum !== pkg.packageChecksum) {
      fail(problems, `consumers.${consumer}.packageChecksum must equal the package checksum`);
    }
    if (!Array.isArray(entry.requiredContracts) || entry.requiredContracts.length === 0) {
      fail(problems, `consumers.${consumer}.requiredContracts must be non-empty`);
    } else {
      for (const name of entry.requiredContracts) {
        if (!seenNames.has(name)) fail(problems, `consumers.${consumer}.requiredContracts references unknown ${name}`);
      }
    }
  }
  for (const key of ["build", "generate", "check", "deploy", "verify", "onchain", "reproduce"]) {
    if (typeof pkg.commands?.[key] !== "string" || pkg.commands[key].length === 0) {
      fail(problems, `commands.${key} is required`);
    }
  }
  if (typeof pkg.commands?.reproduce === "string" && !/clean/i.test(pkg.commands.reproduce)) {
    fail(problems, "commands.reproduce must run from a clean environment");
  }
  if (typeof pkg.commands?.deploy === "string" && !pkg.commands.deploy.includes("optimismSepolia")) {
    fail(problems, "commands.deploy must target the optimismSepolia network");
  }
  for (const key of ["pause", "unpause", "roleTransfer", "upgradeRollback", "recovery"]) {
    if (typeof pkg.rollback?.[key] !== "string" || pkg.rollback[key].length === 0) {
      fail(problems, `rollback.${key} is required`);
    }
  }

  // ── Release ID, checksum and secrets ─────────────────────────────────────
  const releaseId = computeReleaseId(pkg);
  if (pkg.releaseId !== releaseId) fail(problems, `releaseId drift: recomputed ${releaseId} != package ${pkg.releaseId}`);
  const checksum = computePackageChecksum(pkg);
  if (pkg.packageChecksum !== checksum) {
    fail(problems, `packageChecksum drift: recomputed ${checksum} != package ${pkg.packageChecksum}`);
  }
  problems.push(...findSecretLeaks(pkg));

  // ── Committed artifact pins: offline tamper detection ────────────────────
  const pins = loadArtifactPins(rootDir);
  if (pins === null) {
    fail(problems, `artifact pins missing: ${RELEASE_ARTIFACT_PINS_PATH}`);
  } else {
    for (const contract of contracts) {
      const pin = pins.contracts?.[contract.name];
      if (!pin) {
        fail(problems, `${contract.name}: artifact pin missing`);
        continue;
      }
      for (const field of [
        "bytecodeKeccak",
        "deployedBytecodeKeccak",
        "creationBytes",
        "runtimeBytes",
        "immutableSlots",
        "linkReferences",
      ]) {
        if (pin[field] !== contract.artifact[field]) {
          fail(problems, `${contract.name}: artifact pin drift on ${field} (pin ${pin[field]} != package ${contract.artifact[field]})`);
        }
      }
      if (pin.abiSha256 !== contract.artifact.abiSha256) {
        fail(problems, `${contract.name}: artifact pin drift on abiSha256`);
      }
    }
  }

  // ── Optional artifact recomputation ──────────────────────────────────────
  if (options.withArtifacts) {
    const build = loadBuildArtifacts(rootDir, options.artifactPreference ?? "hardhat");
    if (build === null) {
      fail(problems, "no build outputs found: run `forge build` or `npx hardhat compile` before `--with-artifacts`");
    } else {
      for (const contract of contracts) {
        const artifact = build.byName.get(contract.name);
        if (!artifact) {
          fail(problems, `${contract.name}: rebuilt artifact missing from ${build.kind} outputs`);
          continue;
        }
        const bytecodeKeccak = keccakHex(artifact.bytecode);
        if (bytecodeKeccak !== contract.artifact.bytecodeKeccak) {
          fail(problems, `${contract.name}: bytecode drift: rebuilt ${bytecodeKeccak} != package ${contract.artifact.bytecodeKeccak}`);
        }
        const deployedKeccak = keccakHex(artifact.deployedBytecode);
        if (deployedKeccak !== contract.artifact.deployedBytecodeKeccak) {
          fail(problems, `${contract.name}: deployedBytecode drift: rebuilt ${deployedKeccak} != package ${contract.artifact.deployedBytecodeKeccak}`);
        }
        if (canonicalKeccak(artifact.abi) !== contract.artifact.abiSha256) {
          fail(problems, `${contract.name}: ABI drift between rebuild and pinned ABI`);
        }
        const ctor = artifact.abi.find((entry) => entry.type === "constructor");
        const encoded = encodeAbiParameters(ctor?.inputs ?? [], contract.deployment.constructorArgs);
        const initHash = initCodeHashOf(artifact.bytecode, encoded);
        if (initHash !== contract.deployment.initCodeHash) {
          fail(problems, `${contract.name}: initCodeHash drift: rebuilt ${initHash} != package ${contract.deployment.initCodeHash}`);
        }
        const immutableSlots = Object.keys(artifact.immutableReferences ?? {}).length;
        if (immutableSlots !== contract.artifact.immutableSlots) {
          fail(problems, `${contract.name}: immutable slot drift: rebuilt ${immutableSlots} != package ${contract.artifact.immutableSlots}`);
        }
      }
    }
  }

  return problems;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Package construction
// ─────────────────────────────────────────────────────────────────────────────

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

export function repoRoot() {
  return REPO_ROOT;
}

function mustReadJson(path) {
  if (!existsSync(path)) throw new Error(`required file missing: ${path}`);
  return JSON.parse(readFileSync(path, "utf8"));
}

function resolveArgValue(value, name, definition, addressBook) {
  if (typeof value === "string" && value.startsWith("$contract:")) {
    const target = value.slice("$contract:".length);
    if (!addressBook.has(target)) throw new Error(`${name}: constructor arg references unknown contract ${target}`);
    return addressBook.get(target);
  }
  if (isPlainObject(value) && typeof value.custody === "string") {
    const custody = definition.custody?.[value.custody];
    if (!custody) throw new Error(`${name}: unknown custody slot ${value.custody}`);
    return custody.address;
  }
  if (Array.isArray(value)) return value.map((item) => resolveArgValue(item, name, definition, addressBook));
  if (isPlainObject(value)) {
    const out = {};
    for (const [key, item] of Object.entries(value)) out[key] = resolveArgValue(item, name, definition, addressBook);
    return out;
  }
  return value;
}

/**
 * @notice Build the canonical release package from the reviewed definition + artifacts.
 * @dev Deterministic: identical definition, sources and artifacts produce byte-identical JSON.
 *      Addresses are derived from CREATE2 before any constructor value is resolved, and each
 *      resolved constructor argument is either a literal, a suite contract reference or a
 *      custody slot — never an embedding of a private key or an unbounded expression.
 */
export function buildReleasePackage(options = {}) {
  const rootDir = options.rootDir ?? REPO_ROOT;
  const definition = options.definition ?? mustReadJson(join(rootDir, RELEASE_DEFINITION_PATH));
  const artifacts = options.artifacts ?? loadBuildArtifacts(rootDir);
  const pins = options.pins ?? loadArtifactPins(rootDir);
  if (artifacts === null && pins === null) {
    throw new Error(
      "no artifacts available: run `forge build` / `npx hardhat compile`, or commit artifact-pins.json",
    );
  }

  const contractSpecs = definition.contracts ?? [];
  if (contractSpecs.length === 0) throw new Error("release definition declares no contracts");

  // 1. Static address book for suite-contract references (addresses are arg-independent
  //    only when the init code is known, so resolve them in dependency order below).
  const addressBook = new Map();
  const contracts = [];

  for (const spec of contractSpecs) {
    const pinned = pins?.contracts?.[spec.name] ?? null;
    const built = artifacts?.byName.get(spec.name) ?? null;
    const source = built?.source ?? pinned?.source ?? spec.source;
    if (!source) throw new Error(`${spec.name}: source path unknown`);

    // Prefer a freshly built artifact; fall back to the reviewed pin.
    const creationBytecode = built?.bytecode ?? null;
    if (built === null && pinned === null) throw new Error(`${spec.name}: no artifact or pin available`);
    if (built === null) {
      throw new Error(
        `${spec.name}: build outputs missing. Artifact-only generation would silently skip ` +
          `init-code verification, so run \`forge build\` or \`npx hardhat compile\` first.`,
      );
    }

    const ctor = (built.abi ?? []).find((entry) => entry.type === "constructor");
    const resolvedArgs = (spec.constructorArgs ?? []).map((value) =>
      resolveArgValue(value, spec.name, definition, addressBook),
    );
    const encodedArgs = encodeAbiParameters(ctor?.inputs ?? [], resolvedArgs);
    const salt = deriveSalt(definition.deterministicDeployment.saltDomain, spec.name);
    const initCodeHash = initCodeHashOf(creationBytecode, encodedArgs);
    const address = deriveCreate2Address(definition.deterministicDeployment.factory.address, salt, initCodeHash);
    addressBook.set(spec.name, address);

    const abi = built.abi;
    const abiBytes = Buffer.from(`${JSON.stringify(abi, null, 2)}\n`, "utf8");
    const deployedBytecode = built.deployedBytecode;
    const immutableSlots = Object.keys(built.immutableReferences ?? {}).length;

    contracts.push({
      name: spec.name,
      kind: spec.kind,
      source,
      sourceSha256: sha256FileHex(join(rootDir, source)),
      address,
      interfaces: spec.interfaces ?? [],
      accessControl: spec.accessControl === true,
      deployment: {
        method: "create2",
        salt,
        initCodeHash,
        constructorArgs: resolvedArgs,
        constructorArgsSha256: canonicalSha256(resolvedArgs),
        deploymentBlock: null,
        txHash: null,
      },
      artifact: {
        abiFile: abiFileRelative(spec.name),
        abiSha256: canonicalKeccak(abi),
        abiFileSha256: `0x${sha256Hex(abiBytes)}`,
        bytecodeKeccak: keccakHex(creationBytecode),
        deployedBytecodeKeccak: keccakHex(deployedBytecode),
        creationBytes: (creationBytecode.length - 2) / 2,
        runtimeBytes: (deployedBytecode.length - 2) / 2,
        immutableSlots,
        linkReferences: Object.keys(built.linkReferences ?? {}).length,
      },
      proxy: spec.proxy ?? { kind: "none", implementation: "self" },
      sourceVerification: {
        status: "pending",
        provider: "etherscan",
        standardJson: true,
        url: null,
      },
      onchain: { codePresent: null, observedCodeHash: null, checkedAtBlock: null },
    });
  }

  // 2. Role ownership (final state, after deployer authority is removed).
  const roleOwnership = (definition.roleOwnership ?? []).map((entry) => ({
    class: entry.class,
    description: entry.description,
    mechanism: entry.mechanism,
    holder: resolveHolder(entry.holder, definition),
  }));

  // 3. Role grants per contract — holder types: custody slot or suite contract.
  const roleGrants = [];
  for (const spec of contractSpecs) {
    for (const grant of spec.roles ?? []) {
      const holder = grant.contract
        ? { kind: "contract", contract: grant.contract, address: addressBook.get(grant.contract) }
        : resolveCustodyHolder(grant.custody, definition);
      if (!holder.address) throw new Error(`${spec.name}:${grant.role}: unresolved holder`);
      roleGrants.push({
        contract: spec.name,
        role: grant.role,
        roleHash: keccakUtf8(grant.role),
        holder,
        grantedAt: "finalization",
      });
    }
  }

  const bootstrapAddress = definition.custody?.bootstrapAdmin?.address;
  const finalizationSteps = buildFinalizationSteps(contractSpecs, roleGrants, definition, bootstrapAddress);
  const totalContracts = contracts.length;

  const status = definition.status ?? "candidate";
  const packageCore = {
    schemaVersion: RELEASE_SCHEMA_VERSION,
    kind: RELEASE_KIND,
    status,
    releaseName: definition.releaseName,
    protocolVersion: definition.protocolVersion,
    configurationVersion: definition.configurationVersion,
    evidenceClass: definition.evidenceClass,
    network: {
      name: "optimism-sepolia",
      chainId: OPTIMISM_SEPOLIA_CHAIN_ID,
      caip2: `eip155:${OPTIMISM_SEPOLIA_CHAIN_ID}`,
      explorerBase: OPTIMISM_SEPOLIA_EXPLORER,
      rpcUrlEnv: "OPTIMISM_SEPOLIA_RPC_URL",
    },
    toolchain: {
      solc: definition.build.solc,
      evmVersion: definition.build.evmVersion,
      viaIR: definition.build.viaIR,
      optimizer: { enabled: true, runs: definition.build.optimizerRuns },
      metadataBytecodeHash: definition.build.metadataBytecodeHash,
      node: definition.build.node,
      npm: definition.build.npm,
      foundry: definition.build.foundry,
    },
    deterministicDeployment: {
      method: "create2",
      factory: {
        address: definition.deterministicDeployment.factory.address,
        kind: "deterministic-deployment-proxy",
        codeHash: definition.deterministicDeployment.factory.codeHash,
      },
      saltDomain: definition.deterministicDeployment.saltDomain,
      bootstrapAdmin: {
        custodyRef: "bootstrapAdmin",
        address: bootstrapAddress,
        custody: "unassigned",
      },
      noncePlan: definition.deterministicDeployment.noncePlan,
    },
    contracts,
    roleOwnership,
    roleGrants,
    finalization: {
      bootstrapAdmin: bootstrapAddress,
      deployerAuthorityRemoved: true,
      verification: "script/deploy/VerifyRoleRenunciation.s.sol + PostDeploymentRoleCheck",
      steps: finalizationSteps,
    },
    deployment: {
      blockNumber: null,
      blockHash: null,
      timestamp: null,
      eventStartCursor: { blockNumber: null, blockHash: null },
      referenceBlock: definition.referenceBlock,
      pendingEvidence: ["blockNumber", "blockHash", "timestamp", "eventStartCursor"],
    },
    verification: {
      explorer: {
        provider: "etherscan",
        baseUrl: OPTIMISM_SEPOLIA_EXPLORER,
        status: "pending",
        verifiedCount: 0,
        totalCount: totalContracts,
      },
      onchain: {
        status: "not-run",
        command: "node scripts/check-optimism-sepolia-release.mjs --onchain --rpc-url $OPTIMISM_SEPOLIA_RPC_URL",
        codeChecks: 0,
      },
    },
    commands: definition.commands,
    rollback: definition.rollback,
    consumers: {
      api: {
        issue: "#586",
        entry: "scripts/lib/releasePackageConsumer.mjs",
        releaseId: null,
        packageChecksum: null,
        requiredContracts: definition.consumers.api,
      },
      frontend: {
        catalog: "UX-SC-001",
        entry: "scripts/lib/releasePackageConsumer.mjs",
        releaseId: null,
        packageChecksum: null,
        requiredContracts: definition.consumers.frontend,
      },
    },
    blockers: definition.blockers ?? [],
    disclaimers: definition.disclaimers ?? [],
  };

  packageCore.releaseId = computeReleaseId(packageCore);
  packageCore.consumers.api.releaseId = packageCore.releaseId;
  packageCore.consumers.frontend.releaseId = packageCore.releaseId;
  packageCore.packageChecksum = computePackageChecksum(packageCore);
  packageCore.consumers.api.packageChecksum = packageCore.packageChecksum;
  packageCore.consumers.frontend.packageChecksum = packageCore.packageChecksum;
  // The checksum covers the consumer blocks; recompute once they are populated.
  packageCore.packageChecksum = computePackageChecksum(packageCore);
  packageCore.consumers.api.packageChecksum = packageCore.packageChecksum;
  packageCore.consumers.frontend.packageChecksum = packageCore.packageChecksum;

  return { package: packageCore, abis: buildAbiFiles(contracts, artifacts) };
}

function resolveCustodyHolder(custodyRef, definition) {
  const custody = definition.custody?.[custodyRef];
  if (!custody) throw new Error(`unknown custody slot: ${custodyRef}`);
  return {
    kind: "custody",
    custodyRef,
    custody: custody.custody,
    label: custody.label,
    address: custody.address,
  };
}

function resolveHolder(holder, definition) {
  if (holder?.custodyRef) {
    const resolved = resolveCustodyHolder(holder.custodyRef, definition);
    return {
      custodyRef: resolved.custodyRef,
      custody: resolved.custody,
      label: resolved.label,
      address: resolved.address,
      mechanism: holder.mechanism,
    };
  }
  if (holder?.contract) {
    return { contract: holder.contract, custody: "suite-contract", address: holder.address ?? null };
  }
  throw new Error("roleOwnership holder must reference a custody slot or a suite contract");
}

function buildFinalizationSteps(contractSpecs, roleGrants, definition, bootstrapAddress) {
  const steps = [];
  let index = 0;
  for (const grant of roleGrants) {
    index += 1;
    steps.push({
      step: index,
      action: "grant",
      contract: grant.contract,
      role: grant.role,
      roleHash: grant.roleHash,
      account: grant.holder.address,
    });
  }
  for (const spec of contractSpecs) {
    if (spec.accessControl !== true) continue;
    index += 1;
    steps.push({
      step: index,
      action: "renounce",
      contract: spec.name,
      role: "DEFAULT_ADMIN_ROLE",
      roleHash: keccakUtf8("DEFAULT_ADMIN_ROLE"),
      account: bootstrapAddress,
    });
  }
  index += 1;
  steps.push({
    step: index,
    action: "verify",
    contract: null,
    role: null,
    account: bootstrapAddress,
    check: "PostDeploymentRoleCheck.checkAllRoles(bootstrapAdmin, canonicalContracts) == 0 violations",
  });
  return steps;
}

function buildAbiFiles(contracts, artifacts) {
  const files = [];
  for (const contract of contracts) {
    const artifact = artifacts.byName.get(contract.name);
    files.push({
      path: contract.artifact.abiFile,
      content: `${JSON.stringify(artifact.abi, null, 2)}\n`,
    });
  }
  return files;
}

/** Build the deterministic `artifact-pins.json` contents from build outputs. */
export function buildArtifactPins(rootDir, contractNames, prefer = "auto") {
  const artifacts = loadBuildArtifacts(rootDir, prefer);
  if (artifacts === null) throw new Error("no build outputs available to pin");
  const contracts = {};
  for (const name of [...contractNames].sort()) {
    const artifact = artifacts.byName.get(name);
    if (!artifact) throw new Error(`artifact missing for ${name}`);
    contracts[name] = {
      source: artifact.source,
      bytecodeKeccak: keccakHex(artifact.bytecode),
      deployedBytecodeKeccak: keccakHex(artifact.deployedBytecode),
      creationBytes: (artifact.bytecode.length - 2) / 2,
      runtimeBytes: (artifact.deployedBytecode.length - 2) / 2,
      immutableSlots: Object.keys(artifact.immutableReferences ?? {}).length,
      linkReferences: Object.keys(artifact.linkReferences ?? {}).length,
      abiSha256: canonicalKeccak(artifact.abi),
    };
  }
  return {
    schemaVersion: 1,
    kind: "truthbounty.release-artifact-pins",
    buildOutputKind: artifacts.kind,
    toolchain: {
      solc: "0.8.28",
      evmVersion: "cancun",
      viaIR: true,
      optimizer: { enabled: true, runs: 200 },
      metadataBytecodeHash: "ipfs",
    },
    contracts,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
//  On-chain verification (read-only)
// ─────────────────────────────────────────────────────────────────────────────

async function rpc(rpcUrl, method, params) {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  if (!response.ok) throw new Error(`RPC ${method} failed with HTTP ${response.status}`);
  const body = await response.json();
  if (body.error) throw new Error(`RPC ${method} error: ${body.error.message}`);
  return body.result;
}

/**
 * @notice Read-only on-chain verification of a release package.
 * @dev Checks chain id, code presence, runtime length (plus appended immutables),
 *      deployed-bytecode hashes for immutable-free contracts, and the deployment block hash.
 *      Never broadcasts and never handles keys.
 */
export async function verifyOnchain(pkg, rpcUrl, options = {}) {
  const problems = [];
  const chainIdHex = await rpc(rpcUrl, "eth_chainId", []);
  const chainId = Number.parseInt(chainIdHex, 16);
  if (chainId !== pkg.network?.chainId) {
    problems.push(`RPC chain id ${chainId} != package chain id ${pkg.network?.chainId}`);
    return { problems, observations: {} };
  }
  const observations = { chainId, contracts: {} };

  // Deterministic deployment precondition: the pinned factory must carry exactly the pinned
  // runtime. If it does not, no address in the package can be reproduced by anyone.
  const factory = pkg.deterministicDeployment?.factory;
  if (factory?.address && factory?.codeHash) {
    const factoryCode = await rpc(rpcUrl, "eth_getCode", [factory.address, "latest"]);
    if (factoryCode === "0x") {
      problems.push(`CREATE2 factory ${factory.address} has no code — deterministic deployment is impossible`);
    } else {
      const factoryHash = keccakHex(factoryCode);
      observations.factory = { address: factory.address, codeHash: factoryHash, bytes: (factoryCode.length - 2) / 2 };
      if (factoryHash !== factory.codeHash) {
        problems.push(`CREATE2 factory code hash ${factoryHash} != pinned ${factory.codeHash}`);
      }
    }
  } else {
    problems.push("package does not pin a CREATE2 factory address and code hash");
  }

  // The reference block proves the package was built against a real, identifiable chain view.
  const reference = pkg.deployment?.referenceBlock;
  if (reference?.number && reference?.hash) {
    const block = await rpc(rpcUrl, "eth_getBlockByNumber", [`0x${Number(reference.number).toString(16)}`, false]);
    if (!block) {
      problems.push(`reference block ${reference.number} not found on chain`);
    } else {
      observations.referenceBlock = { number: Number.parseInt(block.number, 16), hash: block.hash };
      if (String(block.hash).toLowerCase() !== String(reference.hash).toLowerCase()) {
        problems.push(`reference block hash ${block.hash} != pinned ${reference.hash}`);
      }
      if (Number(reference.chainId) !== chainId) {
        problems.push(`reference block chain ${reference.chainId} != RPC chain ${chainId}`);
      }
    }
  }

  for (const contract of pkg.contracts ?? []) {
    const code = await rpc(rpcUrl, "eth_getCode", [contract.address, "latest"]);
    const codeBytes = (code.length - 2) / 2;
    const expectedBytes = contract.artifact.runtimeBytes + 32 * contract.artifact.immutableSlots;
    const observed = { codePresent: codeBytes > 0, codeBytes };
    if (codeBytes === 0) {
      problems.push(`${contract.name}: no code at ${contract.address} (EOA or undeployed)`);
    } else if (codeBytes !== expectedBytes) {
      problems.push(
        `${contract.name}: runtime length ${codeBytes} != expected ${expectedBytes} ` +
          `(artifact ${contract.artifact.runtimeBytes} + ${contract.artifact.immutableSlots} immutable slots)`,
      );
    } else if (contract.artifact.immutableSlots === 0) {
      const observedHash = keccakHex(code);
      observed.codeHash = observedHash;
      if (observedHash !== contract.artifact.deployedBytecodeKeccak) {
        problems.push(`${contract.name}: on-chain runtime code hash ${observedHash} != artifact ${contract.artifact.deployedBytecodeKeccak}`);
      }
    } else {
      // Immutable slots are patched at deploy time; the runtime hash cannot equal the artifact
      // hash, so record that the identity check is by length only.
      observed.codeHashSkipped = "immutables";
    }
    observations.contracts[contract.name] = observed;
  }

  if (Number.isInteger(pkg.deployment?.blockNumber)) {
    const block = await rpc(rpcUrl, "eth_getBlockByNumber", [`0x${pkg.deployment.blockNumber.toString(16)}`, false]);
    if (!block) {
      problems.push(`deployment block ${pkg.deployment.blockNumber} not found on chain`);
    } else {
      observations.blockHash = block.hash;
      observations.blockNumber = Number.parseInt(block.number, 16);
      if (pkg.deployment.blockHash && block.hash.toLowerCase() !== String(pkg.deployment.blockHash).toLowerCase()) {
        problems.push(`deployment block hash ${block.hash} != package ${pkg.deployment.blockHash}`);
      }
    }
  }

  if (options.requirePublished && pkg.status !== "published") {
    problems.push(`package status is ${pkg.status}; publication requires status=published`);
  }
  return { problems, observations };
}

export { REPO_ROOT };
