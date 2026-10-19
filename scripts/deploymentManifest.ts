import { keccak256, toUtf8Bytes } from "ethers";

export type ManifestValue =
  | string
  | number
  | boolean
  | null
  | ManifestValue[]
  | { [key: string]: ManifestValue };

export interface DeploymentManifest {
  schemaVersion: string;
  protocolVersion: string;
  chainId: string;
  module: string;
  deployer: string;
  startingNonce: number;
  compiler: {
    version: string;
    evmVersion: string;
    viaIR: boolean;
    optimizer: {
      enabled: boolean;
      runs: number;
    };
  };
  contracts: Array<{
    name: string;
    artifact: string;
    salt: string;
    nonce: number;
    address: string;
    constructorArgs: ManifestValue[];
    libraries: Record<string, string>;
    bytecodeHash: string;
    deployedBytecodeHash: string;
  }>;
  transactions: Array<{
    index: number;
    nonce: number;
    action: string;
    contract: string;
    dependsOn: string[];
    inputHash: string;
  }>;
}

function canonicalize(value: ManifestValue): string {
  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalize(item)).join(",")}]`;
  }

  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalize(value[key])}`)
      .join(",")}}`;
  }

  return JSON.stringify(value);
}

export function canonicalManifestJson(manifest: DeploymentManifest): string {
  return canonicalize(manifest as unknown as ManifestValue);
}

export function canonicalManifestValue(value: ManifestValue): string {
  return canonicalize(value);
}

export function manifestHash(manifest: DeploymentManifest): string {
  return keccak256(toUtf8Bytes(canonicalManifestJson(manifest)));
}

export function validateManifest(manifest: DeploymentManifest): void {
  if (!manifest.schemaVersion || !manifest.protocolVersion || !manifest.module) {
    throw new Error("Manifest version and module identifiers are required");
  }

  const transactionIndexes = manifest.transactions.map((transaction) => transaction.index);
  if (new Set(transactionIndexes).size !== transactionIndexes.length) {
    throw new Error("Manifest transaction indexes must be unique");
  }

  for (const [position, transaction] of manifest.transactions.entries()) {
    if (transaction.index !== position) {
      throw new Error("Manifest transaction indexes must be contiguous and ordered");
    }
    if (transaction.nonce !== manifest.startingNonce + position) {
      throw new Error("Manifest transaction nonces must match deployment order");
    }
  }

  const contractNames = new Set(manifest.contracts.map((contract) => contract.name));
  if (contractNames.size !== manifest.contracts.length) throw new Error("Manifest contract names must be unique");
  const deployed = new Set<string>();
  for (const transaction of manifest.transactions) {
    if (!contractNames.has(transaction.contract)) {
      throw new Error(`Manifest transaction references unknown contract: ${transaction.contract}`);
    }
    for (const dependency of transaction.dependsOn) {
      if (!contractNames.has(dependency)) {
        throw new Error(`Manifest transaction references unknown dependency: ${dependency}`);
      }
      if (!deployed.has(dependency)) throw new Error(`Manifest dependency must be deployed earlier: ${dependency}`);
    }
    if (transaction.action === "deploy") {
      if (deployed.has(transaction.contract)) throw new Error(`Duplicate deployment: ${transaction.contract}`);
      const contract = manifest.contracts.find(contract => contract.name === transaction.contract)!;
      if (contract.nonce !== transaction.nonce) throw new Error("Contract nonce must match its deployment transaction");
      deployed.add(transaction.contract);
    } else if (!deployed.has(transaction.contract)) throw new Error("Call target must be deployed earlier");
  }
  if (deployed.size !== contractNames.size) throw new Error("Every manifest contract must have a deployment transaction");
}
