#!/usr/bin/env node
/**
 * @file check-optimism-sepolia-release.mjs
 * @description STAB-SC-007 — fail-closed gate for the canonical Optimism Sepolia release package.
 *
 * Levels:
 *   --offline (default)  structural, chain, ABI, address, role, block, cursor, consumer and
 *                        secret checks against the committed package — no build, no network.
 *   --with-artifacts     additionally rebuild-compares ABI, bytecode, init code and immutable
 *                        slots against `out/` (Foundry) or `artifacts/` (Hardhat).
 *   --onchain            read-only JSON-RPC verification: chain id, code presence, runtime
 *                        length, immutable-free code hashes, deployment block hash.
 *
 * Exit codes: 0 = pass, 1 = drift/invalid, 2 = usage error.
 *
 * Usage:
 *   node scripts/check-optimism-sepolia-release.mjs
 *   node scripts/check-optimism-sepolia-release.mjs --with-artifacts --artifacts hardhat
 *   node scripts/check-optimism-sepolia-release.mjs --onchain --rpc-url $OPTIMISM_SEPOLIA_RPC_URL
 */

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

import {
  RELEASE_CHECKSUM_PATH,
  RELEASE_MANIFEST_PATH,
  computeFileChecksum,
  repoRoot,
  validateReleasePackage,
  verifyOnchain,
} from "./lib/releasePackage.mjs";

function parseArgs(argv) {
  const args = { withArtifacts: false, onchain: false, json: false, artifacts: "auto", rpcUrl: null };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--with-artifacts") args.withArtifacts = true;
    else if (arg === "--onchain") args.onchain = true;
    else if (arg === "--json") args.json = true;
    else if (arg === "--artifacts") args.artifacts = argv[++i];
    else if (arg === "--rpc-url") args.rpcUrl = argv[++i];
    else if (arg === "--help" || arg === "-h") args.help = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  return args;
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(`error: ${error.message}`);
    process.exit(2);
  }
  if (args.help) {
    console.log(
      "Usage: node scripts/check-optimism-sepolia-release.mjs " +
        "[--with-artifacts] [--artifacts auto|foundry|hardhat] [--onchain --rpc-url URL] [--json]",
    );
    return;
  }

  const rootDir = process.env.RELEASE_REPO_ROOT ? resolve(process.env.RELEASE_REPO_ROOT) : repoRoot();
  const manifestPath = join(rootDir, RELEASE_MANIFEST_PATH);
  const checksumPath = join(rootDir, RELEASE_CHECKSUM_PATH);
  const problems = [];

  if (!existsSync(manifestPath)) {
    console.error(`error: release package missing: ${RELEASE_MANIFEST_PATH}`);
    process.exit(1);
  }
  const bytes = readFileSync(manifestPath);
  const pkg = JSON.parse(bytes.toString("utf8"));

  if (!existsSync(checksumPath)) {
    problems.push(`checksum file missing: ${RELEASE_CHECKSUM_PATH}`);
  } else {
    const [committed] = readFileSync(checksumPath, "utf8").trim().split(/\s+/);
    const actual = computeFileChecksum(bytes);
    if (committed !== actual) {
      problems.push(`release.sha256 mismatch: committed ${committed}, file hashes to ${actual}`);
    }
  }

  problems.push(
    ...validateReleasePackage(pkg, {
      rootDir,
      withArtifacts: args.withArtifacts,
      artifactPreference: args.artifacts === "auto" ? "hardhat" : args.artifacts,
    }),
  );

  let observations = null;
  if (args.onchain) {
    const rpcUrl = args.rpcUrl ?? process.env.OPTIMISM_SEPOLIA_RPC_URL;
    if (!rpcUrl) {
      console.error("error: --onchain requires --rpc-url or OPTIMISM_SEPOLIA_RPC_URL");
      process.exit(2);
    }
    try {
      const result = await verifyOnchain(pkg, rpcUrl);
      problems.push(...result.problems);
      observations = result.observations;
    } catch (error) {
      problems.push(`on-chain verification failed: ${error.message}`);
    }
  }

  if (args.json) {
    console.log(
      JSON.stringify(
        {
          ok: problems.length === 0,
          releaseId: pkg.releaseId,
          packageChecksum: pkg.packageChecksum,
          status: pkg.status,
          contracts: pkg.contracts?.length ?? 0,
          problems,
          observations,
        },
        null,
        2,
      ),
    );
  } else if (problems.length === 0) {
    console.log(`release package OK: ${pkg.releaseName}`);
    console.log(`releaseId:       ${pkg.releaseId}`);
    console.log(`packageChecksum: ${pkg.packageChecksum}`);
    console.log(`status:          ${pkg.status}`);
    console.log(`contracts:       ${pkg.contracts.length}`);
  } else {
    for (const problem of problems) console.error(`FAIL: ${problem}`);
    console.error(`${problems.length} release-package problem(s).`);
  }

  process.exit(problems.length === 0 ? 0 : 1);
}

main();
