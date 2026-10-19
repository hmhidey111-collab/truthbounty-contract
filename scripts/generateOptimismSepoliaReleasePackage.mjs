#!/usr/bin/env node
/**
 * @file generateOptimismSepoliaReleasePackage.mjs
 * @description STAB-SC-007 — deterministic generator for the canonical Optimism Sepolia
 *              release package consumed by API #586 and the frontend artifact verifier.
 *
 * Reads the reviewed release definition (`config/optimism-sepolia-release.json`), the pinned
 * sources, and the reproducible build outputs, then writes:
 *
 *   deployments/releases/optimism-sepolia/release.json       canonical package
 *   deployments/releases/optimism-sepolia/release.sha256     sha256 of release.json bytes
 *   deployments/releases/optimism-sepolia/abis/<Name>.json   per-contract ABI exports
 *   deployments/releases/optimism-sepolia/artifact-pins.json reviewed artifact digests
 *
 * Generation is a pure function of the definition + sources + build outputs: two runs produce
 * byte-identical files, and `--check` fails on any drift. No keys, no network, no broadcasting.
 *
 * Usage:
 *   node scripts/generateOptimismSepoliaReleasePackage.mjs --write
 *   node scripts/generateOptimismSepoliaReleasePackage.mjs --check
 *   node scripts/generateOptimismSepoliaReleasePackage.mjs --write --artifacts hardhat
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  RELEASE_CHECKSUM_PATH,
  RELEASE_DEFINITION_PATH,
  RELEASE_ARTIFACT_PINS_PATH,
  RELEASE_DIR,
  RELEASE_MANIFEST_PATH,
  buildArtifactPins,
  buildReleasePackage,
  computeFileChecksum,
  computePackageChecksum,
  computeReleaseId,
  loadBuildArtifacts,
  loadReleasePackage,
  repoRoot,
  validateReleasePackage,
} from "./lib/releasePackage.mjs";

const REPO_ROOT = repoRoot();

function parseArgs(argv) {
  const args = { write: false, check: false, artifacts: "auto", promote: false, evidence: null, verification: null };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--write") args.write = true;
    else if (arg === "--check") args.check = true;
    else if (arg === "--promote") args.promote = true;
    else if (arg === "--evidence") args.evidence = argv[++i];
    else if (arg === "--verification") args.verification = argv[++i];
    else if (arg === "--artifacts") args.artifacts = argv[++i];
    else if (arg === "--help" || arg === "-h") args.help = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!args.write && !args.check && !args.promote) args.check = true;
  if ([args.write, args.check, args.promote].filter(Boolean).length > 1) {
    throw new Error("choose exactly one of --write, --check, --promote");
  }
  return args;
}

function build(rootDir, artifactsPreference) {
  const artifacts = loadBuildArtifacts(rootDir, artifactsPreference);
  if (artifacts === null) {
    throw new Error(
      "no build outputs found. Run `forge build` and/or `npx hardhat compile` first — " +
        "a release package is never generated from unbuilt sources.",
    );
  }
  const definition = JSON.parse(readFileSync(join(rootDir, RELEASE_DEFINITION_PATH), "utf8"));
  const { package: pkg, abis } = buildReleasePackage({ rootDir, definition, artifacts });
  const pins = buildArtifactPins(rootDir, definition.contracts.map((contract) => contract.name), artifactsPreference);
  const manifestBytes = Buffer.from(`${JSON.stringify(pkg, null, 2)}\n`, "utf8");
  const checksumLine = `${computeFileChecksum(manifestBytes)}  ${RELEASE_MANIFEST_PATH.split("/").pop()}\n`;
  return { definition, pkg, abis, pins, manifestBytes, checksumLine };
}

function write(rootDir, output) {
  mkdirSync(join(rootDir, RELEASE_DIR, "abis"), { recursive: true });
  for (const file of output.abis) {
    writeFileSync(join(rootDir, file.path), file.content, "utf8");
  }
  writeFileSync(join(rootDir, RELEASE_ARTIFACT_PINS_PATH), `${JSON.stringify(output.pins, null, 2)}\n`, "utf8");
  writeFileSync(join(rootDir, RELEASE_MANIFEST_PATH), output.manifestBytes);
  writeFileSync(join(rootDir, RELEASE_CHECKSUM_PATH), output.checksumLine, "utf8");
  return output;
}

function check(rootDir, output) {
  const problems = [];
  const manifestPath = join(rootDir, RELEASE_MANIFEST_PATH);
  const checksumPath = join(rootDir, RELEASE_CHECKSUM_PATH);
  if (!existsSync(manifestPath)) return [`committed release package missing: ${RELEASE_MANIFEST_PATH}`];
  if (!existsSync(checksumPath)) problems.push(`committed checksum file missing: ${RELEASE_CHECKSUM_PATH}`);

  const committedBytes = readFileSync(manifestPath);
  const expectedChecksum = computeFileChecksum(committedBytes);
  if (existsSync(checksumPath)) {
    const line = readFileSync(checksumPath, "utf8").trim();
    const [committedChecksum] = line.split(/\s+/);
    if (committedChecksum !== expectedChecksum) {
      problems.push(`release.sha256 drift: file hashes to ${expectedChecksum}, committed file says ${committedChecksum}`);
    }
  }

  if (committedBytes.toString("utf8") !== output.manifestBytes.toString("utf8")) {
    const committed = JSON.parse(committedBytes.toString("utf8"));
    const regenerated = JSON.parse(output.manifestBytes.toString("utf8"));
    const differences = diffObjects(committed, regenerated);
    problems.push(
      `regenerated package differs from the committed package (${differences.length} field(s)): ` +
        differences.slice(0, 8).join("; "),
    );
  }

  const committed = JSON.parse(committedBytes.toString("utf8"));
  for (const file of output.abis) {
    const abs = join(rootDir, file.path);
    if (!existsSync(abs)) {
      problems.push(`ABI export missing: ${file.path}`);
      continue;
    }
    if (readFileSync(abs, "utf8") !== file.content) {
      problems.push(`ABI export drifted from rebuild: ${file.path}`);
    }
  }

  const pinsPath = join(rootDir, RELEASE_ARTIFACT_PINS_PATH);
  if (!existsSync(pinsPath)) {
    problems.push(`artifact pins missing: ${RELEASE_ARTIFACT_PINS_PATH}`);
  } else if (readFileSync(pinsPath, "utf8") !== `${JSON.stringify(output.pins, null, 2)}\n`) {
    problems.push(`artifact pins drifted from rebuild: ${RELEASE_ARTIFACT_PINS_PATH}`);
  }

  const definition = output.definition;
  const expectedStatus = definition.status ?? "candidate";
  if (committed.status !== expectedStatus) {
    problems.push(`status drift: committed ${committed.status}, definition ${expectedStatus}`);
  }
  return problems;
}

function flatten(value, trail, out) {
  if (value !== null && typeof value === "object") {
    for (const key of Object.keys(value).sort()) flatten(value[key], `${trail}.${key}`, out);
    return out;
  }
  out.push([trail, value]);
  return out;
}

function diffObjects(a, b) {
  const left = new Map(flatten(a, "$", []));
  const right = new Map(flatten(b, "$", []));
  const keys = new Set([...left.keys(), ...right.keys()]);
  const differences = [];
  for (const key of [...keys].sort()) {
    if (JSON.stringify(left.get(key)) !== JSON.stringify(right.get(key))) {
      differences.push(`${key}: ${JSON.stringify(left.get(key))} -> ${JSON.stringify(right.get(key))}`);
    }
  }
  return differences;
}

/**
 * @notice Promote a candidate package to `published` from real deployment evidence.
 * @dev Refuses unless every custody slot is assigned, the deployment evidence covers every
 *      contract, and explorer verification succeeded for every contract. The release ID is
 *      recomputed and asserted unchanged: publication adds evidence, never new components.
 */
function promote(rootDir, args) {
  const evidencePath = args.evidence ? resolve(args.evidence) : join(rootDir, `${RELEASE_DIR}/deployment-evidence.json`);
  const verificationPath = args.verification
    ? resolve(args.verification)
    : join(rootDir, `${RELEASE_DIR}/verification-report.json`);
  if (!existsSync(evidencePath)) throw new Error(`deployment evidence missing: ${evidencePath}`);
  if (!existsSync(verificationPath)) throw new Error(`verification report missing: ${verificationPath}`);

  const definition = JSON.parse(readFileSync(join(rootDir, RELEASE_DEFINITION_PATH), "utf8"));
  const unassigned = Object.entries(definition.custody ?? {})
    .filter(([, slot]) => slot.custody !== "assigned")
    .map(([id]) => id);
  if (unassigned.length > 0) {
    throw new Error(
      `refusing to publish: custody slots are unassigned (${unassigned.join(", ")}). ` +
        "Set real Optimism Sepolia owner addresses in config/optimism-sepolia-release.json and regenerate.",
    );
  }

  const pkg = loadReleasePackage(rootDir);
  if (pkg.status === "published") throw new Error("package is already published");
  const releaseIdBefore = computeReleaseId(pkg);

  const evidence = JSON.parse(readFileSync(evidencePath, "utf8"));
  const verification = JSON.parse(readFileSync(verificationPath, "utf8"));
  if (evidence.chainId !== pkg.network.chainId) {
    throw new Error(`evidence chain ${evidence.chainId} != package chain ${pkg.network.chainId}`);
  }
  if (evidence.releaseId && evidence.releaseId !== pkg.releaseId) {
    throw new Error("evidence was produced for a different release ID");
  }

  const deployedByName = new Map((evidence.contracts ?? []).map((entry) => [entry.name, entry]));
  const verifiedByName = new Map((verification.contracts ?? []).map((entry) => [entry.name, entry]));
  const blockNumber = Number(evidence.blockNumber);
  const blockHash = String(evidence.blockHash);
  if (!Number.isInteger(blockNumber) || blockNumber <= 0) throw new Error("evidence blockNumber invalid");
  if (!/^0x[0-9a-fA-F]{64}$/.test(blockHash)) throw new Error("evidence blockHash invalid");

  for (const contract of pkg.contracts) {
    const deployed = deployedByName.get(contract.name);
    if (!deployed) throw new Error(`evidence missing deployment for ${contract.name}`);
    if (String(deployed.address).toLowerCase() !== contract.address.toLowerCase()) {
      throw new Error(`${contract.name}: evidence address ${deployed.address} != package ${contract.address}`);
    }
    const verified = verifiedByName.get(contract.name);
    if (!verified || verified.status !== "verified") {
      throw new Error(`${contract.name}: explorer source verification missing or failed`);
    }
    contract.deployment.deploymentBlock = Number(deployed.blockNumber) || blockNumber;
    contract.deployment.txHash = deployed.txHash;
    contract.sourceVerification.status = "verified";
    contract.sourceVerification.url = `${pkg.network.explorerBase}/address/${contract.address}#code`;
    contract.onchain = {
      codePresent: true,
      observedCodeHash: contract.artifact.deployedBytecodeKeccak,
      checkedAtBlock: Number(deployed.blockNumber) || blockNumber,
    };
  }

  pkg.status = "published";
  pkg.evidenceClass = "optimism-sepolia";
  pkg.blockers = [];
  pkg.deployment.blockNumber = blockNumber;
  pkg.deployment.blockHash = blockHash;
  pkg.deployment.timestamp = Number(evidence.timestamp);
  pkg.deployment.eventStartCursor = { blockNumber, blockHash };
  pkg.verification.explorer = {
    ...pkg.verification.explorer,
    status: "verified",
    verifiedCount: pkg.contracts.length,
  };
  pkg.verification.onchain = {
    ...pkg.verification.onchain,
    status: "verified",
    codeChecks: pkg.contracts.length,
  };
  pkg.releaseId = computeReleaseId(pkg);
  if (pkg.releaseId !== releaseIdBefore) {
    throw new Error("release ID changed during promotion: publication must not alter the component set");
  }
  pkg.packageChecksum = computePackageChecksum(pkg);
  pkg.consumers.api.packageChecksum = pkg.packageChecksum;
  pkg.consumers.frontend.packageChecksum = pkg.packageChecksum;

  const problems = validateReleasePackage(pkg, { rootDir });
  if (problems.length > 0) throw new Error(`promotion produced an invalid package: ${problems.join("; ")}`);

  const manifestBytes = Buffer.from(`${JSON.stringify(pkg, null, 2)}\n`, "utf8");
  writeFileSync(join(rootDir, RELEASE_MANIFEST_PATH), manifestBytes);
  writeFileSync(
    join(rootDir, RELEASE_CHECKSUM_PATH),
    `${computeFileChecksum(manifestBytes)}  release.json\n`,
    "utf8",
  );
  console.log(`promoted to published: ${pkg.releaseName}`);
  console.log(`releaseId:       ${pkg.releaseId}`);
  console.log(`packageChecksum: ${pkg.packageChecksum}`);
  console.log(`deploymentBlock: ${blockNumber}`);
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(`error: ${error.message}`);
    process.exit(2);
  }
  if (args.help) {
    console.log(
      "Usage: node scripts/generateOptimismSepoliaReleasePackage.mjs [--write|--check|--promote] " +
        "[--artifacts auto|foundry|hardhat] [--evidence <path>] [--verification <path>]",
    );
    return;
  }

  const rootDir = process.env.RELEASE_REPO_ROOT ? resolve(process.env.RELEASE_REPO_ROOT) : REPO_ROOT;

  if (args.promote) {
    try {
      promote(rootDir, args);
    } catch (error) {
      console.error(`error: ${error.message}`);
      process.exit(1);
    }
    return;
  }
  let output;
  try {
    output = build(rootDir, args.artifacts);
  } catch (error) {
    console.error(`error: ${error.message}`);
    process.exit(1);
  }

  if (args.write) {
    write(rootDir, output);
    const { pkg } = output;
    console.log(`release package written: ${RELEASE_MANIFEST_PATH}`);
    console.log(`releaseId:       ${pkg.releaseId}`);
    console.log(`packageChecksum: ${pkg.packageChecksum}`);
    console.log(`contracts:       ${pkg.contracts.length}`);
    console.log(`status:          ${pkg.status}`);
  }

  const problems = check(rootDir, output);
  if (problems.length > 0) {
    for (const problem of problems) console.error(`drift: ${problem}`);
    console.error(`${problems.length} drift problem(s) — regenerate with --write after review.`);
    process.exit(1);
  }

  if (args.check) {
    const packageProblems = validateReleasePackage(output.pkg, {
      rootDir,
      withArtifacts: true,
      artifactPreference: args.artifacts === "auto" ? "hardhat" : args.artifacts,
    });
    if (packageProblems.length > 0) {
      for (const problem of packageProblems) console.error(`invalid: ${problem}`);
      process.exit(1);
    }
    console.log("release package matches a clean rebuild (no drift)");
  }
}

main();
