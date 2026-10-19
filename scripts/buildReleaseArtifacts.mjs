/**
 * @title buildReleaseArtifacts
 * @notice STAB-SC-007 — rebuild the canonical release artifacts deterministically.
 *
 * Compiles exactly the canonical suite declared in `config/optimism-sepolia-release.json` with the
 * pinned release toolchain (solc 0.8.28, optimizer 200, viaIR, cancun, ipfs metadata) and writes
 * Hardhat-format artifacts under `artifacts/contracts/**`. Those artifacts are what
 * `generateOptimismSepoliaReleasePackage.mjs` reads and what `check-optimism-sepolia-release.mjs
 * --with-artifacts` re-derives the ABI / bytecode / immutable pins from.
 *
 * Why a scoped build instead of `forge build`:
 *  - the release identity covers only the canonical suite, so only that suite may influence the
 *    artifact pins. Compiling unrelated files would let an unrelated source edit change a
 *    release-critical digest (or, as at HEAD, fail the build for reasons outside this package);
 *  - `forge build` and `npx hardhat compile` both compile the whole tree, which currently fails on
 *    pre-existing syntax errors in `contracts/deployment/MigrationManager.sol`,
 *    `contracts/upgrade/IProtocolUpgradeManager.sol` and `contracts/upgrade/VersionRegistry.sol`
 *    (none of which are release sources).
 *
 * Determinism: the compiler input is a pure function of the declared sources plus the dependency
 * closure. Import resolution is explicit (`@openzeppelin/*` → `node_modules`, `contracts/*` → repo
 * root, everything else → relative to the importer), so the same checkout always yields the same
 * artifact bytes. Re-running this script is a no-op for the committed pins; the gate enforces it.
 *
 * Usage:
 *   node scripts/buildReleaseArtifacts.mjs            # compile and write artifacts
 *   node scripts/buildReleaseArtifacts.mjs --check    # compile in memory, compare, write nothing
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DEFINITION_PATH = "config/optimism-sepolia-release.json";
const ARTIFACTS_DIR = "artifacts";
const PINNED_SOLC = "0.8.28";

/** Release compiler settings — must match the `toolchain` block the gate validates. */
const SETTINGS = Object.freeze({
  optimizer: { enabled: true, runs: 200 },
  viaIR: true,
  evmVersion: "cancun",
  metadata: { bytecodeHash: "ipfs" },
  outputSelection: {
    "*": {
      "*": [
        "abi",
        "evm.bytecode.object",
        "evm.bytecode.linkReferences",
        "evm.deployedBytecode.object",
        "evm.deployedBytecode.immutableReferences",
      ],
    },
  },
});

/**
 * @notice Load solc at the pinned version, refusing any other compiler.
 * @dev `solc-0.8.28` (an npm alias of solc@0.8.28) is preferred so the pin cannot drift with the
 *      `solc` dependency used elsewhere in the repo.
 */
function loadSolc() {
  const require = createRequire(import.meta.url);
  let loaded;
  try {
    loaded = require("solc-0.8.28");
  } catch {
    loaded = require("solc");
  }
  const version = loaded.version();
  if (!version.startsWith(PINNED_SOLC)) {
    throw new Error(
      `release artifacts must be built with solc ${PINNED_SOLC}, but the resolved compiler is ${version}. ` +
        "Install the pinned compiler (npm install) instead of relaxing the pin.",
    );
  }
  return loaded;
}

/** Resolve an import to an absolute path, or throw with the importing file named. */
function resolveImport(specifier, fromAbsolute) {
  if (specifier.startsWith("@openzeppelin/contracts/")) {
    return join(REPO_ROOT, "node_modules", specifier);
  }
  if (specifier.startsWith("contracts/")) {
    return join(REPO_ROOT, specifier);
  }
  return join(dirname(fromAbsolute), specifier);
}

/** Stable compiler-input key for an absolute path. */
function sourceKey(absolute) {
  const prefix = join(REPO_ROOT, "node_modules") + "/";
  if (absolute.startsWith(prefix)) return absolute.slice(prefix.length);
  return relative(REPO_ROOT, absolute);
}

/** Depth-first import closure, de-duplicated by absolute path. */
function collectSources(relativePath) {
  const sources = {};
  const seen = new Set();
  const walk = (absolute) => {
    if (seen.has(absolute)) return;
    if (!existsSync(absolute)) throw new Error(`release source missing: ${relative(REPO_ROOT, absolute)}`);
    seen.add(absolute);
    const content = readFileSync(absolute, "utf8");
    sources[sourceKey(absolute)] = { content };
    const pattern = /import\s+(?:[^"']*from\s+)?["']([^"']+)["']/g;
    let match;
    while ((match = pattern.exec(content)) !== null) {
      walk(resolveImport(match[1], absolute));
    }
  };
  walk(join(REPO_ROOT, relativePath));
  return sources;
}

function main() {
  const checkOnly = process.argv.includes("--check");
  const definition = JSON.parse(readFileSync(join(REPO_ROOT, DEFINITION_PATH), "utf8"));

  const targets = definition.contracts.map((contract) => ({
    name: contract.name,
    source: contract.source,
  }));
  if (targets.length === 0) throw new Error("release definition declares no contracts");

  const sources = {};
  for (const target of targets) Object.assign(sources, collectSources(target.source));

  const solc = loadSolc();
  const started = Date.now();
  const output = JSON.parse(
    solc.compile(JSON.stringify({ language: "Solidity", sources, settings: SETTINGS })),
  );
  const failures = (output.errors ?? []).filter((entry) => entry.severity === "error");
  if (failures.length > 0) {
    for (const failure of failures.slice(0, 8)) console.error(failure.formattedMessage);
    throw new Error(`${failures.length} compiler error(s) in the canonical release suite`);
  }

  let written = 0;
  let unchanged = 0;
  const drifted = [];
  for (const target of targets) {
    const compiled = output.contracts?.[target.source]?.[target.name];
    if (!compiled) throw new Error(`${target.name} was not produced by the pinned compiler`);

    const artifact = {
      contractName: target.name,
      sourceName: target.source,
      abi: compiled.abi,
      bytecode: `0x${compiled.evm.bytecode.object ?? ""}`,
      deployedBytecode: `0x${compiled.evm.deployedBytecode.object ?? ""}`,
      linkReferences: compiled.evm.bytecode.linkReferences ?? {},
      immutableReferences: compiled.evm.deployedBytecode.immutableReferences ?? {},
    };
    const bytes = `${JSON.stringify(artifact, null, 2)}`;
    const path = join(REPO_ROOT, ARTIFACTS_DIR, target.source, `${target.name}.json`);

    if (existsSync(path) && readFileSync(path, "utf8") === bytes) {
      unchanged += 1;
      continue;
    }
    if (checkOnly) {
      drifted.push(target.name);
      continue;
    }
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, bytes);
    written += 1;
  }

  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  if (checkOnly) {
    if (drifted.length > 0) {
      throw new Error(
        `release artifacts are stale for ${drifted.join(", ")} — run ` +
          "`node scripts/buildReleaseArtifacts.mjs` and re-review the regenerated package",
      );
    }
    console.log(
      `release artifacts match a clean rebuild: ${targets.length} contracts, ` +
        `${Object.keys(sources).length} sources, solc ${PINNED_SOLC} (${seconds}s)`,
    );
    return;
  }
  console.log(
    `release artifacts: ${written} written, ${unchanged} unchanged, ` +
      `${targets.length} contracts, ${Object.keys(sources).length} sources, solc ${PINNED_SOLC} (${seconds}s)`,
  );
}

try {
  main();
} catch (error) {
  console.error(`error: ${error.message}`);
  process.exitCode = 1;
}
