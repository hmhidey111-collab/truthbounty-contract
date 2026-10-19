#!/usr/bin/env node
/**
 * @file check-release-reproducibility.mjs
 * @description V2-SC-129 — rebuilds deployed artifacts from source and confirms
 *              compiler, optimizer, metadata, libraries, source hashes, and
 *              explorer-verification inputs match the approved release manifest.
 *
 * The approved manifest (`deployments/releases/v2-sc-129-release-manifest.json`)
 * pins the exact build inputs (solc 0.8.28, EVM `cancun`, `viaIR`, optimizer
 * enabled with 200 runs) and the expected outputs (per-source sha256,
 * per-artifact bytecode/deployedBytecode keccak256, zero link references, and
 * the explorer-verification field set). This checker is fail-closed: any drift
 * in toolchain pins, source bytes, bytecode, linked libraries, CBOR metadata,
 * or explorer inputs exits non-zero. It performs no deployment, holds no keys,
 * makes no network calls, and grants no settlement or treasury authority.
 *
 * Usage:
 *   node scripts/check-release-reproducibility.mjs                  # verify (exit 1 on drift)
 *   node scripts/check-release-reproducibility.mjs --write-manifest # regenerate computed
 *              hashes after maintainer review; refuses when toolchain pins drift
 *   node scripts/check-release-reproducibility.mjs --manifest <path>
 */

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { keccak256 } from "./lib/keccak256.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "..");

export const MANIFEST_RELATIVE_PATH = "deployments/releases/v2-sc-129-release-manifest.json";
export const HARDHAT_CONFIG_PATH = "hardhat.config.ts";
export const FOUNDRY_CONFIG_PATH = "foundry.toml";

export const FORBIDDEN_RUNTIME_PATTERNS = [/stellar/i, /soroban/i, /freighter/i];

const HEX_0X = /^0x[0-9a-fA-F]*$/;

function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function hexToBytes(hex) {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (clean.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(clean)) {
    throw new Error(`invalid hex string: ${hex.slice(0, 32)}…`);
  }
  return Uint8Array.from(Buffer.from(clean, "hex"));
}

export function keccakOfHex(hex) {
  return keccak256(hexToBytes(hex));
}

export function loadManifest(rootDir = REPO_ROOT, manifestRelative = MANIFEST_RELATIVE_PATH) {
  const absolute = resolve(rootDir, manifestRelative);
  if (!existsSync(absolute)) {
    throw new Error(`release manifest missing: ${manifestRelative} (run with --write-manifest to generate)`);
  }
  return { manifest: JSON.parse(readFileSync(absolute, "utf8")), absolute };
}

function matchSingle(haystack, regex, label) {
  const match = haystack.match(regex);
  if (!match) throw new Error(`cannot locate ${label} in toolchain config`);
  return match[1];
}

/**
 * Extract the pinned toolchain settings from hardhat.config.ts / foundry.toml
 * without compiling (pure text parse, deterministic, offline).
 */
export function readToolchainPins(rootDir = REPO_ROOT) {
  const hardhat = readFileSync(join(rootDir, HARDHAT_CONFIG_PATH), "utf8");
  const foundry = readFileSync(join(rootDir, FOUNDRY_CONFIG_PATH), "utf8");
  const hardhatSolc = matchSingle(hardhat, /version:\s*["'](\d+\.\d+\.\d+)["']/, "hardhat solidity version");
  const hardhatEvm = matchSingle(hardhat, /evmVersion:\s*["']([a-z]+)["']/, "hardhat evmVersion");
  const hardhatViaIR = /viaIR:\s*true/.test(hardhat);
  const hardhatRuns = Number(matchSingle(hardhat, /runs:\s*(\d+)/, "hardhat optimizer runs"));
  const hardhatOptimizer = /optimizer:\s*\{\s*enabled:\s*true/s.test(hardhat);
  const foundrySolc = matchSingle(foundry, /^\s*solc\s*=\s*["'](\d+\.\d+\.\d+)["']/m, "foundry solc pin");
  const foundryRuns = Number(matchSingle(foundry, /^\s*optimizer_runs\s*=\s*(\d+)/m, "foundry optimizer_runs"));
  const foundryOptimizer = /^\s*optimizer\s*=\s*true/m.test(foundry);
  const foundryViaIR = /^\s*via_ir\s*=\s*true/m.test(foundry);
  return {
    hardhat: { solc: hardhatSolc, evmVersion: hardhatEvm, viaIR: hardhatViaIR, optimizerEnabled: hardhatOptimizer, optimizerRuns: hardhatRuns },
    foundry: { solc: foundrySolc, optimizerEnabled: foundryOptimizer, optimizerRuns: foundryRuns, viaIR: foundryViaIR },
  };
}

export function checkToolchain(rootDir, manifest) {
  const problems = [];
  const expected = manifest.toolchain;
  if (!expected) return ["manifest is missing the toolchain pin block"];
  let pins;
  try {
    pins = readToolchainPins(rootDir);
  } catch (error) {
    return [`toolchain config unreadable: ${error.message}`];
  }
  const want = (label, actual, desired) => {
    if (actual !== desired) problems.push(`toolchain drift: ${label} is ${JSON.stringify(actual)}, manifest pins ${JSON.stringify(desired)}`);
  };
  want("hardhat solidity version", pins.hardhat.solc, expected.solc);
  want("hardhat evmVersion", pins.hardhat.evmVersion, expected.evmVersion);
  want("hardhat viaIR", pins.hardhat.viaIR, expected.viaIR);
  want("hardhat optimizer.enabled", pins.hardhat.optimizerEnabled, expected.optimizer.enabled);
  want("hardhat optimizer.runs", pins.hardhat.optimizerRuns, expected.optimizer.runs);
  want("foundry solc", pins.foundry.solc, expected.solc);
  want("foundry optimizer", pins.foundry.optimizerEnabled, expected.optimizer.enabled);
  want("foundry optimizer_runs", pins.foundry.optimizerRuns, expected.optimizer.runs);
  want("foundry via_ir", pins.foundry.viaIR, expected.viaIR);
  return problems;
}

export function checkSources(rootDir, manifest) {
  const problems = [];
  if (!Array.isArray(manifest.sources) || manifest.sources.length === 0) {
    return ["manifest pins no sources; refusing to verify an empty source set"];
  }
  const seen = new Set();
  for (const entry of manifest.sources) {
    if (seen.has(entry.path)) problems.push(`duplicate source pin: ${entry.path}`);
    seen.add(entry.path);
    const absolute = join(rootDir, entry.path);
    if (!existsSync(absolute) || !statSync(absolute).isFile()) {
      problems.push(`pinned source missing: ${entry.path}`);
      continue;
    }
    const bytes = readFileSync(absolute);
    const actual = sha256Hex(bytes);
    if (actual !== entry.sha256) {
      problems.push(`source drift: ${entry.path} sha256 ${actual} != manifest ${entry.sha256}`);
    }
    const text = bytes.toString("utf8");
    for (const pattern of FORBIDDEN_RUNTIME_PATTERNS) {
      if (pattern.test(text)) {
        problems.push(`forbidden alternate-chain runtime reference (${pattern}) in ${entry.path}`);
      }
    }
    if (/__\$\w+\$__/.test(text)) {
      problems.push(`unresolved link placeholder pattern in source ${entry.path}`);
    }
  }
  return problems;
}

/** Locate reproducible build outputs: Foundry `out/` first, then Hardhat `artifacts/`. */
export function findBuildOutputs(rootDir = REPO_ROOT) {
  const foundryOut = join(rootDir, "out");
  if (existsSync(foundryOut) && statSync(foundryOut).isDirectory()) {
    const entries = readdirSync(foundryOut);
    if (entries.length > 0) return { kind: "foundry", dir: foundryOut };
  }
  const hardhatArtifacts = join(rootDir, "artifacts", "contracts");
  if (existsSync(hardhatArtifacts)) return { kind: "hardhat", dir: join(rootDir, "artifacts") };
  return null;
}

function collectArtifactFiles(dir, kind, files = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (kind === "foundry" || entry.name !== "build-info") collectArtifactFiles(full, kind, files);
      continue;
    }
    if (!entry.name.endsWith(".json")) continue;
    if (kind === "foundry" && !entry.name.endsWith(".json")) continue;
    files.push(full);
  }
  return files;
}

function readFoundryArtifact(file) {
  const json = JSON.parse(readFileSync(file, "utf8"));
  if (!json.bytecode || typeof json.bytecode.object !== "string") return null;
  const contractName = json.contractName ?? file.split("/").pop().replace(/\.json$/, "");
  if (!contractName) return null;
  return {
    contractName,
    sourceName: json.ast?.absolutePath ?? json.sourceName ?? null,
    bytecode: json.bytecode.object,
    deployedBytecode: json.deployedBytecode?.object ?? null,
    linkReferences: json.bytecode?.linkReferences ?? {},
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
  if (json.bytecode === "0x" && typeof json.deployedBytecode === "string" && json.deployedBytecode === "0x") return null;
  return {
    contractName: json.contractName,
    sourceName: json.sourceName ?? null,
    bytecode: json.bytecode,
    deployedBytecode: json.deployedBytecode ?? null,
    linkReferences: json.linkReferences ?? {},
  };
}

/**
 * Decode the solc version embedded in the CBOR metadata tail of deployed bytecode.
 * Returns "major.minor.patch" or null when no trailing metadata is present.
 */
export function metadataSolcVersion(deployedBytecode) {
  if (typeof deployedBytecode !== "string" || !HEX_0X.test(deployedBytecode) || deployedBytecode.length < 12) return null;
  const bytes = hexToBytes(deployedBytecode);
  if (bytes.length < 6) return null;
  const metaLength = (bytes[bytes.length - 2] << 8) | bytes[bytes.length - 1];
  if (metaLength <= 0 || metaLength > bytes.length - 2) return null;
  const meta = bytes.subarray(bytes.length - 2 - metaLength, bytes.length - 2);
  // solc metadata is CBOR: {"ipfs":..,"solc":0x430008001c…} — the "solc" key is
  // text(4) 0x64 0x73("s") 0x6f("o") 0x6c("l") 0x63("c"), followed by a 3-byte
  // version bytes header 0x43 major minor patch.
  for (let i = 0; i + 6 < meta.length; i++) {
    if (meta[i] === 0x64 && meta[i + 1] === 0x73 && meta[i + 2] === 0x6f && meta[i + 3] === 0x6c && meta[i + 4] === 0x63) {
      const marker = meta[i + 5];
      if (marker === 0x43 && i + 9 <= meta.length) {
        return `${meta[i + 6]}.${meta[i + 7]}.${meta[i + 8]}`;
      }
    }
  }
  return null;
}

export function countLinkReferences(linkReferences) {
  let count = 0;
  for (const file of Object.values(linkReferences ?? {})) {
    for (const positions of Object.values(file ?? {})) count += (positions ?? []).length;
  }
  return count;
}

export function checkArtifacts(rootDir, manifest, build = findBuildOutputs(rootDir)) {
  if (!Array.isArray(manifest.artifacts) || manifest.artifacts.length === 0) {
    return ["manifest pins no artifacts; refusing to verify an empty artifact set"];
  }
  if (build === null) {
    return [
      "no build outputs found: run `forge build` (solc 0.8.28, cancun, viaIR, optimizer runs 200) " +
      "or `npx hardhat compile` before verifying reproducibility — unverified bytecode never passes",
    ];
  }
  const problems = [];
  const files = collectArtifactFiles(build.dir, build.kind);
  const byContract = new Map();
  for (const file of files) {
    const artifact = build.kind === "foundry" ? readFoundryArtifact(file) : readHardhatArtifact(file);
    if (artifact === null) continue;
    if (!byContract.has(artifact.contractName)) byContract.set(artifact.contractName, artifact);
  }
  for (const entry of manifest.artifacts) {
    const artifact = byContract.get(entry.contract);
    if (!artifact) {
      problems.push(`rebuilt artifact missing for pinned contract ${entry.contract} (${build.kind} outputs)`);
      continue;
    }
    for (const field of ["bytecode", "deployedBytecode"]) {
      const hex = artifact[field];
      if (typeof hex !== "string" || !HEX_0X.test(hex) || hex === "0x") {
        problems.push(`${entry.contract}: rebuilt ${field} is empty or malformed`);
        continue;
      }
      if (/__\$\w+\$__/.test(hex) || /__\w+_{2,}/.test(hex)) {
        problems.push(`${entry.contract}: rebuilt ${field} contains unresolved link placeholders`);
      }
    }
    const actualBytecode = keccakOfHex(artifact.bytecode);
    if (actualBytecode !== entry.bytecodeKeccak) {
      problems.push(`${entry.contract}: bytecode drift: rebuilt ${actualBytecode} != manifest ${entry.bytecodeKeccak}`);
    }
    if (artifact.deployedBytecode && entry.deployedBytecodeKeccak) {
      const actualDeployed = keccakOfHex(artifact.deployedBytecode);
      if (actualDeployed !== entry.deployedBytecodeKeccak) {
        problems.push(`${entry.contract}: deployedBytecode drift: rebuilt ${actualDeployed} != manifest ${entry.deployedBytecodeKeccak}`);
      }
      const embedded = metadataSolcVersion(artifact.deployedBytecode);
      if (embedded === null) {
        problems.push(`${entry.contract}: deployed bytecode carries no decodable solc CBOR metadata`);
      } else if (embedded !== manifest.toolchain.solc) {
        problems.push(`${entry.contract}: embedded metadata solc ${embedded} != manifest ${manifest.toolchain.solc}`);
      }
    }
    const linkCount = countLinkReferences(artifact.linkReferences);
    if (linkCount !== 0) {
      problems.push(`${entry.contract}: rebuilt output has ${linkCount} unresolved link references (canonical modules link none)`);
    }
    for (const [library, address] of Object.entries(entry.libraries ?? {})) {
      if (!/^0x[0-9a-fA-F]{40}$/.test(address) || /^0x0+$/.test(address)) {
        problems.push(`${entry.contract}: pinned library ${library} has a zero or malformed address`);
      }
    }
  }
  return problems;
}

const EXPLORER_REQUIRED_FIELDS = [
  "contract",
  "source",
  "compilerVersion",
  "evmVersion",
  "optimizerEnabled",
  "optimizerRuns",
  "viaIR",
  "bytecodeKeccak",
  "deployedBytecodeKeccak",
  "metadataSolc",
  "libraries",
];

export function checkExplorer(manifest) {
  const problems = [];
  const explorer = manifest.explorer;
  if (!explorer || typeof explorer !== "object") return ["manifest is missing the explorer verification block"];
  const missing = EXPLORER_REQUIRED_FIELDS.filter((field) => !(field in explorer));
  if (missing.length > 0) problems.push(`explorer block is missing required fields: ${missing.join(", ")}`);
  if (explorer.compilerVersion !== manifest.toolchain?.solc) {
    problems.push(`explorer compilerVersion ${explorer.compilerVersion} != toolchain ${manifest.toolchain?.solc}`);
  }
  if (explorer.evmVersion !== manifest.toolchain?.evmVersion) {
    problems.push(`explorer evmVersion ${explorer.evmVersion} != toolchain ${manifest.toolchain?.evmVersion}`);
  }
  if (explorer.optimizerRuns !== manifest.toolchain?.optimizer?.runs) {
    problems.push(`explorer optimizerRuns ${explorer.optimizerRuns} != toolchain ${manifest.toolchain?.optimizer?.runs}`);
  }
  if (explorer.viaIR !== manifest.toolchain?.viaIR) {
    problems.push(`explorer viaIR ${explorer.viaIR} != toolchain ${manifest.toolchain?.viaIR}`);
  }
  if (!Array.isArray(explorer.networks) || explorer.networks.length === 0) {
    problems.push("explorer block pins no target networks (optimism mainnet / sepolia verification endpoints)");
  }
  return problems;
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export function computeManifestDigest(manifest) {
  const { manifestDigest: _ignored, ...rest } = manifest;
  return keccak256(canonicalJson(rest));
}

export function checkDigest(manifest) {
  if (typeof manifest.manifestDigest !== "string" || !/^0x[0-9a-f]{64}$/.test(manifest.manifestDigest)) {
    return ["manifest digest is missing or malformed (expected 0x-prefixed 32-byte hex)"];
  }
  const actual = computeManifestDigest(manifest);
  if (actual !== manifest.manifestDigest) {
    return [`manifest digest mismatch: recomputed ${actual} != pinned ${manifest.manifestDigest} (manifest was edited without regeneration)`];
  }
  return [];
}

export function runAllChecks(rootDir = REPO_ROOT, manifestRelative = MANIFEST_RELATIVE_PATH) {
  const { manifest } = loadManifest(rootDir, manifestRelative);
  return [
    ...checkDigest(manifest),
    ...checkToolchain(rootDir, manifest),
    ...checkSources(rootDir, manifest),
    ...checkArtifacts(rootDir, manifest),
    ...checkExplorer(manifest),
  ];
}

/** Regenerate computed hash fields after maintainer review. Refuses on toolchain drift. */
export function regenerateManifest(rootDir = REPO_ROOT, manifestRelative = MANIFEST_RELATIVE_PATH) {
  const { manifest, absolute } = loadManifest(rootDir, manifestRelative);
  const toolchainProblems = checkToolchain(rootDir, manifest);
  if (toolchainProblems.length > 0) {
    throw new Error(`refusing to regenerate: toolchain drift\n- ${toolchainProblems.join("\n- ")}`);
  }
  for (const entry of manifest.sources) {
    entry.sha256 = sha256Hex(readFileSync(join(rootDir, entry.path)));
  }
  const build = findBuildOutputs(rootDir);
  if (build === null) throw new Error("refusing to regenerate: no build outputs found (run `forge build` first)");
  const files = collectArtifactFiles(build.dir, build.kind);
  const byContract = new Map();
  for (const file of files) {
    const artifact = build.kind === "foundry" ? readFoundryArtifact(file) : readHardhatArtifact(file);
    if (artifact !== null && !byContract.has(artifact.contractName)) byContract.set(artifact.contractName, artifact);
  }
  for (const entry of manifest.artifacts) {
    const artifact = byContract.get(entry.contract);
    if (!artifact) throw new Error(`refusing to regenerate: rebuilt artifact missing for ${entry.contract}`);
    entry.bytecodeKeccak = keccakOfHex(artifact.bytecode);
    entry.deployedBytecodeKeccak = artifact.deployedBytecode ? keccakOfHex(artifact.deployedBytecode) : entry.deployedBytecodeKeccak;
    entry.metadataSolc = metadataSolcVersion(artifact.deployedBytecode) ?? entry.metadataSolc;
    entry.libraries = entry.libraries ?? {};
  }
  manifest.manifestDigest = computeManifestDigest(manifest);
  mkdirSync(dirname(absolute), { recursive: true });
  writeFileSync(absolute, `${JSON.stringify(manifest, null, 2)}\n`);
  return absolute;
}

if (process.argv[1] && resolve(process.argv[1]) === __filename) {
  const args = process.argv.slice(2);
  const manifestIndex = args.indexOf("--manifest");
  const manifestRelative = manifestIndex >= 0 ? args[manifestIndex + 1] : MANIFEST_RELATIVE_PATH;
  try {
    if (args.includes("--write-manifest")) {
      const written = regenerateManifest(REPO_ROOT, manifestRelative);
      console.log(`Regenerated ${written}`);
    } else {
      const problems = runAllChecks(REPO_ROOT, manifestRelative);
      if (problems.length > 0) {
        for (const problem of problems) console.error(problem);
        process.exitCode = 1;
      } else {
        console.log("Release reproducibility verified: toolchain, sources, bytecode, metadata, libraries, and explorer inputs match the approved manifest.");
      }
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
