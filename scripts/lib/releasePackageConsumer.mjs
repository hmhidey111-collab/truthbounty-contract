/**
 * @file releasePackageConsumer.mjs
 * @description STAB-SC-007 — the single read path used by every release-package consumer.
 *
 * API #586 and the frontend artifact verifier (UX-SC-001) must consume the *same* checksummed
 * package. This module is the only supported loader: it verifies the file checksum, recomputes
 * the canonical package checksum and release ID, and returns an immutable, consumer-specific
 * projection. Two consumers cannot silently disagree: `assertConsumersAgree` fails closed when
 * the release ID, checksum, address book, or ABI digest differs.
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import {
  RELEASE_CHECKSUM_PATH,
  RELEASE_MANIFEST_PATH,
  computeFileChecksum,
  computePackageChecksum,
  computeReleaseId,
  findSecretLeaks,
  repoRoot,
} from "./releasePackage.mjs";

export const CONSUMERS = Object.freeze(["api", "frontend"]);

function loadManifest(rootDir) {
  const path = join(rootDir, RELEASE_MANIFEST_PATH);
  if (!existsSync(path)) throw new Error(`release package missing: ${RELEASE_MANIFEST_PATH}`);
  return { path, bytes: readFileSync(path) };
}

function verifyFileChecksum(rootDir, bytes) {
  const path = join(rootDir, RELEASE_CHECKSUM_PATH);
  if (!existsSync(path)) throw new Error(`release checksum missing: ${RELEASE_CHECKSUM_PATH}`);
  const [committed] = readFileSync(path, "utf8").trim().split(/\s+/);
  const actual = computeFileChecksum(bytes);
  if (committed !== actual) {
    throw new Error(`release package checksum mismatch: committed ${committed}, actual ${actual}`);
  }
  return actual;
}

/**
 * @notice Load the canonical release package for one consumer.
 * @param {"api"|"frontend"} consumer Consumer profile.
 * @param {{rootDir?: string, allowCandidate?: boolean}} [options]
 * @returns {{
 *   consumer: string, releaseName: string, releaseId: string, packageChecksum: string,
 *   chainId: number, status: string, fileSha256: string,
 *   addresses: Record<string, string>, abis: Record<string, string>,
 *   contracts: Array<{name: string, address: string}>,
 *   deploymentBlock: number|null, eventStartCursor: {blockNumber: number|null, blockHash: string|null}
 * }}
 */
export function loadReleasePackageForConsumer(consumer, options = {}) {
  if (!CONSUMERS.includes(consumer)) throw new Error(`unknown consumer profile: ${consumer}`);
  const rootDir = options.rootDir ?? repoRoot();
  const { bytes } = loadManifest(rootDir);
  const pkg = JSON.parse(bytes.toString("utf8"));

  const fileSha256 = verifyFileChecksum(rootDir, bytes);
  if (computePackageChecksum(pkg) !== pkg.packageChecksum) {
    throw new Error("canonical package checksum mismatch: the manifest was edited after generation");
  }
  if (computeReleaseId(pkg) !== pkg.releaseId) {
    throw new Error("release ID mismatch: the canonical component set was mutated");
  }
  if (pkg.network?.chainId !== 11155420) {
    throw new Error(`refusing to consume a non-Optimism-Sepolia package (chain id ${pkg.network?.chainId})`);
  }
  if (pkg.status !== "published" && options.allowCandidate !== true) {
    throw new Error(`release package status is ${pkg.status}; consumers require a published package`);
  }
  const leaks = findSecretLeaks(pkg);
  if (leaks.length > 0) throw new Error(`release package contains secret-shaped values: ${leaks[0]}`);

  const profile = pkg.consumers?.[consumer];
  if (!profile) throw new Error(`release package has no ${consumer} consumer block`);
  if (profile.releaseId !== pkg.releaseId) throw new Error(`${consumer} consumer pins a different release ID`);
  if (profile.packageChecksum !== pkg.packageChecksum) {
    throw new Error(`${consumer} consumer pins a different package checksum`);
  }

  const byName = new Map(pkg.contracts.map((contract) => [contract.name, contract]));
  const addresses = {};
  const abis = {};
  for (const name of profile.requiredContracts) {
    const contract = byName.get(name);
    if (!contract) throw new Error(`${consumer} consumer requires unknown contract ${name}`);
    addresses[name] = contract.address;
    abis[name] = contract.artifact.abiSha256;
  }

  return Object.freeze({
    consumer,
    releaseName: pkg.releaseName,
    releaseId: pkg.releaseId,
    packageChecksum: pkg.packageChecksum,
    chainId: pkg.network.chainId,
    status: pkg.status,
    fileSha256: `sha256:${fileSha256}`,
    addresses: Object.freeze(addresses),
    abis: Object.freeze(abis),
    contracts: Object.freeze(pkg.contracts.map((contract) => ({ name: contract.name, address: contract.address }))),
    deploymentBlock: pkg.deployment?.blockNumber ?? null,
    eventStartCursor: Object.freeze({
      blockNumber: pkg.deployment?.eventStartCursor?.blockNumber ?? null,
      blockHash: pkg.deployment?.eventStartCursor?.blockHash ?? null,
    }),
  });
}

/**
 * @notice Assert that the API and frontend resolve the identical release package.
 * @returns {{releaseId: string, packageChecksum: string, addresses: Record<string, string>}}
 */
export function assertConsumersAgree(options = {}) {
  const api = loadReleasePackageForConsumer("api", options);
  const frontend = loadReleasePackageForConsumer("frontend", options);

  const checks = [
    ["releaseId", api.releaseId, frontend.releaseId],
    ["packageChecksum", api.packageChecksum, frontend.packageChecksum],
    ["fileSha256", api.fileSha256, frontend.fileSha256],
    ["chainId", api.chainId, frontend.chainId],
    ["deploymentBlock", api.deploymentBlock, frontend.deploymentBlock],
    ["eventStartCursor", JSON.stringify(api.eventStartCursor), JSON.stringify(frontend.eventStartCursor)],
  ];
  for (const [label, left, right] of checks) {
    if (left !== right) throw new Error(`consumer disagreement on ${label}: api=${left} frontend=${right}`);
  }
  for (const contract of api.contracts) {
    const other = frontend.contracts.find((entry) => entry.name === contract.name);
    if (!other) throw new Error(`frontend is missing contract ${contract.name}`);
    if (other.address.toLowerCase() !== contract.address.toLowerCase()) {
      throw new Error(`consumer disagreement on ${contract.name}: api=${contract.address} frontend=${other.address}`);
    }
  }
  return {
    releaseId: api.releaseId,
    packageChecksum: api.packageChecksum,
    addresses: Object.fromEntries(api.contracts.map((contract) => [contract.name, contract.address])),
  };
}
