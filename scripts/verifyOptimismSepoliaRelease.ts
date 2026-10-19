/**
 * @title verifyOptimismSepoliaRelease
 * @notice STAB-SC-007 — explorer source verification for every canonical release-package contract.
 *
 * Verifies each contract with the exact compiler inputs recorded in the package
 * (solc 0.8.28, cancun, viaIR, optimizer 200, ipfs metadata) and the reviewed constructor
 * arguments, then writes a per-contract verification report that the promotion step consumes.
 *
 * Requires OPTIMISM_ETHERSCAN_API_KEY (or ETHERSCAN_API_KEY). Never touches keys.
 *
 * Usage:
 *   npx hardhat run scripts/verifyOptimismSepoliaRelease.ts --network optimismSepolia
 */

import hre from "hardhat";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";

const REPO_ROOT = process.cwd();
const PACKAGE_PATH = join(REPO_ROOT, "deployments/releases/optimism-sepolia/release.json");
const REPORT_PATH = join(REPO_ROOT, "deployments/releases/optimism-sepolia/verification-report.json");

type PackageContract = {
  name: string;
  source: string;
  address: string;
  deployment: { constructorArgs: unknown[]; initCodeHash: string };
};

async function main() {
  const pkg = JSON.parse(readFileSync(PACKAGE_PATH, "utf8")) as {
    releaseId: string;
    network: { chainId: number; explorerBase: string };
    contracts: PackageContract[];
  };

  const { ethers } = await hre.network.connect();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  if (chainId !== 0 && chainId !== pkg.network.chainId) {
    throw new Error(`connected chain ${chainId} does not match the package chain ${pkg.network.chainId}`);
  }

  const report: Array<{ name: string; address: string; status: string; url?: string; error?: string }> = [];

  for (const contract of pkg.contracts) {
    const url = `${pkg.network.explorerBase}/address/${contract.address}#code`;
    try {
      await hre.run("verify:verify", {
        address: contract.address,
        constructorArguments: contract.deployment.constructorArgs,
        contract: contract.source,
      });
      console.log(`verified ${contract.name} (${url})`);
      report.push({ name: contract.name, address: contract.address, status: "verified", url });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      // "Already Verified" is a success for release purposes.
      const alreadyVerified = /already verified/i.test(message);
      console.log(`${alreadyVerified ? "already verified" : "failed"} ${contract.name}: ${message}`);
      report.push({
        name: contract.name,
        address: contract.address,
        status: alreadyVerified ? "verified" : "failed",
        url,
        error: alreadyVerified ? undefined : message,
      });
    }
  }

  mkdirSync(dirname(REPORT_PATH), { recursive: true });
  writeFileSync(
    REPORT_PATH,
    `${JSON.stringify(
      {
        releaseId: pkg.releaseId,
        chainId: pkg.network.chainId,
        verified: report.filter((entry) => entry.status === "verified").length,
        total: report.length,
        contracts: report,
      },
      null,
      2,
    )}\n`,
  );

  const failed = report.length - report.filter((entry) => entry.status === "verified").length;
  console.log(`verification report written: ${REPORT_PATH}`);
  if (failed > 0) {
    console.error(`${failed} contract(s) failed source verification — the package cannot be published`);
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
