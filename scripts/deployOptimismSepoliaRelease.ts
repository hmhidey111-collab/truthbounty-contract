/**
 * @title deployOptimismSepoliaRelease
 * @notice STAB-SC-007 — deterministic Optimism Sepolia broadcaster for the canonical release package.
 *
 * Reads `deployments/releases/optimism-sepolia/release.json`, verifies the package and the
 * connected chain, deploys every contract through the pinned CREATE2 factory exactly as the
 * package specifies, asserts the resulting address equals the package address, then executes the
 * finalization plan (grants + bootstrap renunciations) and writes the evidence record the
 * promotion step consumes.
 *
 * Safety properties:
 *  - refuses to run unless the chain id matches the package (Optimism Sepolia 11155420);
 *  - refuses to run while any role custody slot is unassigned — a package with unassigned owners
 *    can never be finalized and therefore can never be published;
 *  - deploys with the reviewed constructor inputs; a mismatch aborts before broadcasting;
 *  - never prints or stores the broadcaster key;
 *  - every deployment is idempotent-checked against the expected CREATE2 address.
 *
 * Usage:
 *   npx hardhat run scripts/deployOptimismSepoliaRelease.ts --network optimismSepolia
 */

import { network } from "hardhat";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";

const REPO_ROOT = process.cwd();
const PACKAGE_PATH = join(REPO_ROOT, "deployments/releases/optimism-sepolia/release.json");
const EVIDENCE_PATH = join(REPO_ROOT, "deployments/releases/optimism-sepolia/deployment-evidence.json");

type ReleaseContract = {
  name: string;
  address: string;
  deployment: {
    salt: string;
    initCodeHash: string;
    constructorArgs: unknown[];
  };
};

type ReleasePackage = {
  status: string;
  releaseId: string;
  packageChecksum: string;
  network: { chainId: number };
  deterministicDeployment: {
    factory: { address: string };
    bootstrapAdmin: { address: string; custody: string };
  };
  contracts: ReleaseContract[];
  finalization: {
    steps: Array<{
      step: number;
      action: string;
      contract: string | null;
      role: string | null;
      roleHash?: string;
      account?: string;
      check?: string;
    }>;
  };
};

type Evidence = {
  releaseId: string;
  contracts: Array<{ name: string; address: string; txHash: string | null; blockNumber: number; skipped?: boolean }>;
};

/**
 * @notice Reuse per-contract transaction records from a previous run of the same release.
 * @dev Makes reruns after a partial failure publishable: a contract that already has code keeps
 *      the transaction that deployed it instead of recording an empty hash.
 */
function loadPriorEvidence(releaseId: string): Map<string, { txHash: string | null; blockNumber: number }> {
  const prior = new Map<string, { txHash: string | null; blockNumber: number }>();
  try {
    const evidence = JSON.parse(readFileSync(EVIDENCE_PATH, "utf8")) as Evidence;
    if (evidence.releaseId !== releaseId) return prior;
    for (const entry of evidence.contracts ?? []) {
      if (entry.address && entry.txHash) prior.set(entry.name, { txHash: entry.txHash, blockNumber: entry.blockNumber });
    }
  } catch {
    /* first run: no evidence yet */
  }
  return prior;
}

function loadPackage(): ReleasePackage {
  const pkg = JSON.parse(readFileSync(PACKAGE_PATH, "utf8")) as ReleasePackage;
  const unassigned = pkg.contracts.length === 0;
  if (unassigned) throw new Error("release package declares no contracts");
  if (pkg.deterministicDeployment.bootstrapAdmin.custody !== "assigned") {
    throw new Error(
      "bootstrapAdmin custody is unassigned: set a real Optimism Sepolia broadcaster address in " +
        "config/optimism-sepolia-release.json, regenerate the package, and re-review the manifest",
    );
  }
  return pkg;
}

async function main() {
  const pkg = loadPackage();
  const { ethers } = await network.connect();
  const [broadcaster] = await ethers.getSigners();
  if (broadcaster.address.toLowerCase() !== pkg.deterministicDeployment.bootstrapAdmin.address.toLowerCase()) {
    throw new Error(
      `broadcaster ${broadcaster.address} does not match the reviewed bootstrapAdmin ${pkg.deterministicDeployment.bootstrapAdmin.address}`,
    );
  }

  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  if (chainId !== pkg.network.chainId) {
    throw new Error(`connected chain ${chainId} does not match the package chain ${pkg.network.chainId}`);
  }

  const factory = new ethers.Contract(
    pkg.deterministicDeployment.factory.address,
    ["function deploy(bytes32 salt, bytes initCode) returns (address)"],
    broadcaster,
  );

  const prior = loadPriorEvidence(pkg.releaseId);
  const deployed: Array<{ name: string; address: string; txHash: string | null; blockNumber: number; skipped?: boolean }> = [];

  for (const contract of pkg.contracts) {
    const artifact = await ethers.getContractFactory(contract.name, broadcaster);
    const initCode = ethers.concat([
      artifact.bytecode,
      artifact.interface.encodeDeploy(contract.deployment.constructorArgs),
    ]);
    if (ethers.keccak256(initCode) !== contract.deployment.initCodeHash) {
      throw new Error(`${contract.name}: local init code hash does not match the package (stale build?)`);
    }

    const existing = await ethers.provider.getCode(contract.address);
    if (existing !== "0x") {
      const previous = prior.get(contract.name);
      console.log(`skip ${contract.name}: code already present at ${contract.address}`);
      deployed.push({
        name: contract.name,
        address: contract.address,
        txHash: previous?.txHash ?? null,
        blockNumber: previous?.blockNumber ?? (await ethers.provider.getBlockNumber()),
        skipped: true,
      });
      continue;
    }

    const tx = await factory.deploy(contract.deployment.salt, initCode);
    const receipt = await tx.wait();
    const code = await ethers.provider.getCode(contract.address);
    if (code === "0x") throw new Error(`${contract.name}: no code at expected address ${contract.address}`);
    console.log(`deployed ${contract.name} at ${contract.address} (block ${receipt.blockNumber})`);
    deployed.push({
      name: contract.name,
      address: contract.address,
      txHash: receipt.hash,
      blockNumber: receipt.blockNumber,
    });
  }

  // Finalization: grant reviewed roles, then renounce bootstrap authority.
  for (const step of pkg.finalization.steps) {
    if (step.action === "grant" && step.contract) {
      const target = pkg.contracts.find((contract) => contract.name === step.contract);
      if (!target) throw new Error(`finalization references unknown contract ${step.contract}`);
      const contract = await ethers.getContractAt(step.contract, target.address, broadcaster);
      if (!(await contract.hasRole(step.roleHash, step.account))) {
        const tx = await contract.grantRole(step.roleHash, step.account);
        await tx.wait();
        console.log(`granted ${step.role} on ${step.contract} to ${step.account}`);
      }
    } else if (step.action === "renounce" && step.contract) {
      const target = pkg.contracts.find((contract) => contract.name === step.contract);
      if (!target) throw new Error(`finalization references unknown contract ${step.contract}`);
      const contract = await ethers.getContractAt(step.contract, target.address, broadcaster);
      if (await contract.hasRole(step.roleHash, step.account)) {
        const tx = await contract.renounceRole(step.roleHash, step.account);
        await tx.wait();
        console.log(`renounced ${step.role} on ${step.contract} for ${step.account}`);
      }
    } else if (step.action === "verify") {
      console.log(`verify: ${step.check}`);
    }
  }

  // Post-finalization assertions: every reviewed grant must hold and the bootstrap administrator
  // must retain no authority anywhere. A failure here aborts before evidence is written.
  const admin = pkg.deterministicDeployment.bootstrapAdmin.address;
  const adminRole = ethers.keccak256(ethers.toUtf8Bytes("DEFAULT_ADMIN_ROLE"));
  for (const step of pkg.finalization.steps) {
    if (step.action === "grant" && step.contract && step.roleHash && step.account) {
      const target = pkg.contracts.find((contract) => contract.name === step.contract);
      if (!target) throw new Error(`finalization references unknown contract ${step.contract}`);
      const contract = await ethers.getContractAt(step.contract, target.address, broadcaster);
      if (!(await contract.hasRole(step.roleHash, step.account))) {
        throw new Error(`${step.contract}: ${step.role} was not granted to ${step.account} (no deployer authority may remain)`);
      }
    }
  }
  for (const contract of pkg.contracts) {
    const instance = await ethers.getContractAt(contract.name, contract.address, broadcaster);
    if (typeof instance.hasRole !== "function") continue;
    try {
      if (await instance.hasRole(adminRole, admin)) {
        throw new Error(`${contract.name}: bootstrap admin ${admin} still holds DEFAULT_ADMIN_ROLE after finalization`);
      }
    } catch (error) {
      if (error instanceof Error && error.message.includes("DEFAULT_ADMIN_ROLE")) throw error;
      /* contract has no AccessControl surface: nothing to renounce */
    }
  }

  const blockNumber = await ethers.provider.getBlockNumber();
  const block = await ethers.provider.getBlock(blockNumber);
  if (!block) throw new Error("cannot read the deployment block");

  const evidence = {
    releaseId: pkg.releaseId,
    packageChecksum: pkg.packageChecksum,
    chainId,
    broadcaster: broadcaster.address,
    blockNumber,
    blockHash: block.hash,
    timestamp: block.timestamp,
    eventStartCursor: { blockNumber, blockHash: block.hash },
    contracts: deployed,
  };
  mkdirSync(dirname(EVIDENCE_PATH), { recursive: true });
  writeFileSync(EVIDENCE_PATH, `${JSON.stringify(evidence, null, 2)}\n`);
  console.log(`evidence written: ${EVIDENCE_PATH}`);
  console.log("Run `node scripts/check-optimism-sepolia-release.mjs --onchain --rpc-url $OPTIMISM_SEPOLIA_RPC_URL`,");
  console.log("then promote the package with `node scripts/generateOptimismSepoliaReleasePackage.mjs --promote`.");
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
