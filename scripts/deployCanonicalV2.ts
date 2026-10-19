import { artifacts, network } from "hardhat";
import "@nomicfoundation/hardhat-ethers";
import type { Signer } from "ethers";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { validateCanonicalV2Parameters } from "./validateDeploymentConfig.js";

import { buildCanonicalV2Manifest } from "./canonicalV2Manifest.js";
import { canonicalManifestValue } from "./deploymentManifest.js";
import type { ManifestValue } from "./deploymentManifest.js";
import { fileCheckpointStore, memoryCheckpointStore, runDeployment } from "./resumableDeployment.js";
import type { DeploymentPlan, DeploymentCheckpoint, CheckpointStore } from "./resumableDeployment.js";
import { writeFile, rename } from "node:fs/promises";

export type DeploymentSigner = Signer & {
  address: string;
};
export interface CanonicalV2Suite {
  deployer: DeploymentSigner;
  governanceController: any;
  token: any;
  oracle: any;
  claimRegistry: any;
  truthBountyWeighted: any;
  aggregator: any;
  provisionalSettlementEngine: any;
  appealVerificationRound: any;
  bondVault: any;
  deployment: { plan: DeploymentPlan; checkpoint: DeploymentCheckpoint };
}

export interface DeploymentOptions {
  /** A persistent deployment must keep the same explicit starting nonce on every resume. */
  startingNonce?: number;
  checkpointFile?: string;
  checkpointStore?: CheckpointStore;
  reconcile?: { index: number; hash: string };
  initialSupply?: bigint;
  minVerificationCount?: bigint;
  minTotalWeight?: bigint;
  minConfidenceBps?: bigint;
  challengeWindowDuration?: number;
  appealDuration?: number;
  minAppealStake?: bigint;
  appealMultiplierBps?: number;
  maxWeightCap?: bigint;
  maxAppealRounds?: bigint;
  appealBond?: bigint;
  appealBondEscalationBps?: bigint;
  maxAppealBond?: bigint;
  maxVotersPerRound?: bigint;
  finalizeDeployerRoles?: boolean;
}

/**
 * @notice Deploys the complete canonical TruthBounty V2 suite in deterministic dependency order.
 * @param deployer The signer executing the deployment.
 * @param options Optional configuration parameters.
 */
export async function deployCanonicalV2(
  deployer: DeploymentSigner,
  options: DeploymentOptions = {}
): Promise<CanonicalV2Suite> {
  const { ethers } = await network.connect();
  const initialSupply = options.initialSupply ?? ethers.parseEther("10000000");
  const minVerificationCount = options.minVerificationCount ?? 1n;
  const minTotalWeight = options.minTotalWeight ?? 0n;
  const minConfidenceBps = options.minConfidenceBps ?? 0n;
  const challengeWindowDuration = options.challengeWindowDuration ?? 3 * 24 * 3600;
  const appealDuration = options.appealDuration ?? 3 * 24 * 3600;
  const minAppealStake = options.minAppealStake ?? ethers.parseEther("200");
  const appealMultiplierBps = options.appealMultiplierBps ?? 15000;
  const maxWeightCap = options.maxWeightCap ?? ethers.parseEther("100000");
  const maxAppealRounds = options.maxAppealRounds ?? 1n;
  const appealBond = options.appealBond ?? ethers.parseEther("1000");
  const appealBondEscalationBps = options.appealBondEscalationBps ?? 15000;
  const maxAppealBond = options.maxAppealBond ?? ethers.parseEther("5000");
  const maxVotersPerRound = options.maxVotersPerRound ?? 200n;
  const finalizeDeployerRoles = options.finalizeDeployerRoles ?? false;

  validateCanonicalV2Parameters({
    initialSupply,
    minVerificationCount,
    minTotalWeight,
    minConfidenceBps,
    challengeWindowDuration,
    appealDuration,
    minAppealStake,
    appealMultiplierBps,
    maxWeightCap,
  });
  console.log("Deployment config validated:", deployer.address);

  if ((options.checkpointFile || options.checkpointStore) && options.startingNonce === undefined) {
    throw new Error("Resumable deployment requires an explicit startingNonce for safe resume");
  }
  if (options.checkpointFile && options.checkpointStore) throw new Error("Choose one checkpoint store");
  const startingNonce = options.startingNonce ?? await ethers.provider.getTransactionCount(deployer.address, "pending");
  const chainId = (await ethers.provider.getNetwork()).chainId;
  const manifest = await buildCanonicalV2Manifest(artifacts, {
    chainId, protocolVersion: "2.0.0", deployer: deployer.address, startingNonce, libraries: {},
    initialSupply: initialSupply.toString(), minVerificationCount: minVerificationCount.toString(),
    minTotalWeight: minTotalWeight.toString(), minConfidenceBps: minConfidenceBps.toString(),
    challengeWindowDuration, appealDuration, minAppealStake: minAppealStake.toString(),
    appealMultiplierBps, maxWeightCap: maxWeightCap.toString(),
    maxAppealRounds: maxAppealRounds.toString(), appealBond: appealBond.toString(),
    appealBondEscalationBps: appealBondEscalationBps.toString(), maxAppealBond: maxAppealBond.toString(),
    maxVotersPerRound: maxVotersPerRound.toString(), finalizeDeployerRoles,
  });
  const aliases: Record<string, string> = {
    governanceController: "GovernanceController", token: "RewardToken", bondVault: "StakeVault",
    reputationOracle: "MockReputationOracle", parameterVersionRegistry: "ParameterVersionRegistry",
    claimRegistry: "ClaimRegistry", truthBountyWeighted: "TruthBountyWeighted",
    verificationAggregator: "VerificationAggregator", provisionalSettlementEngine: "ProvisionalSettlementEngine",
    appealVerificationRound: "AppealVerificationRound",
  };
  const addresses = Object.fromEntries(manifest.contracts.map(contract => [contract.name, contract.address]));
  const resolve = (value: ManifestValue): any => {
    if (Array.isArray(value)) return value.map(resolve);
    if (value !== null && typeof value === "object") {
      if ("$ref" in value) {
        const reference = value["$ref"] as string;
        const address = reference === "deployer" ? deployer.address : addresses[aliases[reference]];
        if (!address) throw new Error(`Unknown deployment reference: ${reference}`);
        return address;
      }
      return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, resolve(item)]));
    }
    return value;
  };
  const factories = Object.fromEntries(await Promise.all(manifest.contracts.map(async contract => [
    contract.name, await ethers.getContractFactory(contract.artifact, deployer),
  ])));
  const plan: DeploymentPlan = { chainId: chainId.toString(), deployer: deployer.address, startingNonce, steps: [] };
  for (const transaction of manifest.transactions) {
    const contract = manifest.contracts.find(contract => contract.name === transaction.contract)!;
    let data: string;
    if (transaction.action === "deploy") {
      data = (await factories[contract.name].getDeployTransaction(...contract.constructorArgs.map(resolve))).data;
    } else {
      const role = ethers.id(contract.name === "StakeVault" ? "OPERATOR_ROLE" : "REGISTRY_UPDATER_ROLE");
      const account = transaction.action === "call:renounceRole" ? deployer.address :
        addresses[contract.name === "StakeVault" ? "AppealVerificationRound" : "ProvisionalSettlementEngine"];
      data = factories[contract.name].interface.encodeFunctionData(transaction.action.slice(5), [role, account]);
    }
    plan.steps.push({
      index: transaction.index, nonce: transaction.nonce, contract: contract.name,
      action: transaction.action === "deploy" ? "deploy" : "call",
      dependsOn: transaction.dependsOn.map(name => manifest.transactions.findIndex(
        prior => prior.action === "deploy" && prior.contract === name,
      )),
      to: transaction.action === "deploy" ? null : contract.address, data, value: "0",
    });
  }
  const store = options.checkpointStore ?? (options.checkpointFile ? fileCheckpointStore(options.checkpointFile) : memoryCheckpointStore());
  const checkpoint = await runDeployment(plan, deployer, store, options.reconcile);
  if (options.checkpointFile) {
    const file = `${options.checkpointFile}.manifest.json`;
    const result = {
      ...manifest, executionPlanHash: checkpoint.planHash,
      transactions: manifest.transactions.map((transaction, index) => ({ ...transaction, ...checkpoint.transactions[index] })),
    };
    await writeFile(`${file}.tmp`, `${canonicalManifestValue(result as any)}\n`, { mode: 0o600 });
    await rename(`${file}.tmp`, file);
  }
  const attach = (name: string) => factories[name].attach(addresses[name]);
  return {
    deployer, governanceController: attach("GovernanceController"), token: attach("RewardToken"),
    oracle: attach("MockReputationOracle"), claimRegistry: attach("ClaimRegistry"),
    truthBountyWeighted: attach("TruthBountyWeighted"), aggregator: attach("VerificationAggregator"),
    provisionalSettlementEngine: attach("ProvisionalSettlementEngine"), appealVerificationRound: attach("AppealVerificationRound"),
    bondVault: attach("StakeVault"), deployment: { plan, checkpoint },
  };
}

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  console.log("Deploying Canonical V2 Suite with deployer:", deployer.address);
  if (!process.env.DEPLOYMENT_STARTING_NONCE) throw new Error("DEPLOYMENT_STARTING_NONCE is required");
  const suite = await deployCanonicalV2(deployer, {
    startingNonce: Number(process.env.DEPLOYMENT_STARTING_NONCE),
    checkpointFile: process.env.DEPLOYMENT_CHECKPOINT ?? `deployments/${process.env.DEPLOY_ENV ?? "local"}/canonical-v2-checkpoint.json`,
  });
  console.log("Canonical V2 Suite deployed successfully:");
  console.log("- GovernanceController:", await suite.governanceController.getAddress());
  console.log("- Token:", await suite.token.getAddress());
  console.log("- ReputationOracle:", await suite.oracle.getAddress());
  console.log("- ClaimRegistry:", await suite.claimRegistry.getAddress());
  console.log("- TruthBountyWeighted:", await suite.truthBountyWeighted.getAddress());
  console.log("- VerificationAggregator:", await suite.aggregator.getAddress());
  console.log("- ProvisionalSettlementEngine:", await suite.provisionalSettlementEngine.getAddress());
  console.log("- AppealVerificationRound:", await suite.appealVerificationRound.getAddress());
  console.log("- BondVault:", await suite.bondVault.getAddress());
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
