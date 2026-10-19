import { artifacts, network } from "hardhat";
import "@nomicfoundation/hardhat-ethers";
import { parseEther } from "ethers";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { buildCanonicalV2Manifest } from "./canonicalV2Manifest.js";
import { manifestHash } from "./deploymentManifest.js";

function requiredAddress(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required to generate a deployment manifest`);
  }
  return value;
}

async function main(): Promise<void> {
  const { ethers } = await network.connect();
  const chain = await ethers.provider.getNetwork();
  const environment = process.env.DEPLOY_ENV ?? "local";
  const outputPath = process.env.MANIFEST_OUTPUT ?? `deployments/${environment}/canonical-v2-manifest.json`;
  const manifest = await buildCanonicalV2Manifest(artifacts, {
    chainId: chain.chainId,
    protocolVersion: process.env.RELEASE_VERSION ?? "2.0.0",
    deployer: requiredAddress("DEPLOYER_ADDRESS"),
    startingNonce: Number(process.env.DEPLOYMENT_STARTING_NONCE ?? "0"),
    libraries: {},
    initialSupply: process.env.INITIAL_SUPPLY ?? parseEther("10000000").toString(),
    minVerificationCount: process.env.MIN_VERIFICATION_COUNT ?? "1",
    minTotalWeight: process.env.MIN_TOTAL_WEIGHT ?? "0",
    minConfidenceBps: process.env.MIN_CONFIDENCE_BPS ?? "0",
    challengeWindowDuration: Number(process.env.CHALLENGE_WINDOW_DURATION ?? 259200),
    appealDuration: Number(process.env.APPEAL_DURATION ?? 259200),
    minAppealStake: process.env.MIN_APPEAL_STAKE ?? parseEther("200").toString(),
    appealMultiplierBps: Number(process.env.APPEAL_MULTIPLIER_BPS ?? 15000),
    maxWeightCap: process.env.MAX_WEIGHT_CAP ?? parseEther("100000").toString(),
  });

  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  console.log(`Manifest written to ${outputPath}`);
  console.log(`Manifest hash: ${manifestHash(manifest)}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});