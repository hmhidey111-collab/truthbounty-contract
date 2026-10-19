import { getAddress, getCreateAddress, keccak256, toUtf8Bytes } from "ethers";
import type { Signer, Provider, TransactionReceipt } from "ethers";
import { mkdir, open, readFile, rename, unlink } from "node:fs/promises";
import { dirname } from "node:path";
import { canonicalManifestValue } from "./deploymentManifest.js";

export interface DeploymentStep {
  index: number;
  nonce: number;
  contract: string;
  action: "deploy" | "call";
  dependsOn: number[];
  to: string | null;
  data: string;
  value: string;
}

export interface DeploymentPlan {
  chainId: string;
  deployer: string;
  startingNonce: number;
  steps: DeploymentStep[];
}

export interface RecordedTransaction {
  index: number;
  nonce: number;
  hash?: string;
  receipt?: {
    blockHash: string;
    blockNumber: number;
    transactionIndex: number;
    contractAddress: string | null;
  };
  codeHash?: string;
}

export interface DeploymentCheckpoint {
  schemaVersion: 1;
  planHash: string;
  transactions: RecordedTransaction[];
}

export interface CheckpointStore {
  acquire(): Promise<void>;
  release(): Promise<void>;
  load(): Promise<DeploymentCheckpoint | undefined>;
  save(checkpoint: DeploymentCheckpoint): Promise<void>;
}

/** Atomic, flushed journal writes; the lock covers validation, broadcasts and receipts.
 * A process crash deliberately leaves the lock for operator review before removal.
 * The journal contains public transaction metadata, never signing keys.
 */
export function fileCheckpointStore(file: string): CheckpointStore {
  let lock: Awaited<ReturnType<typeof open>> | undefined;
  return {
    async acquire() {
      await mkdir(dirname(file), { recursive: true });
      lock = await open(`${file}.lock`, "wx", 0o600);
    },
    async release() {
      if (lock) {
        await lock.close();
        lock = undefined;
        await unlink(`${file}.lock`);
      }
    },
    async load() {
      try { return JSON.parse(await readFile(file, "utf8")); }
      catch (error: any) { if (error.code === "ENOENT") return undefined; throw error; }
    },
    async save(checkpoint) {
      const temporary = `${file}.tmp`;
      const handle = await open(temporary, "w", 0o600);
      try {
        await handle.writeFile(`${JSON.stringify(checkpoint, null, 2)}\n`);
        await handle.sync();
      } finally { await handle.close(); }
      await rename(temporary, file);
      const directory = await open(dirname(file), "r");
      try { await directory.sync(); } finally { await directory.close(); }
    },
  };
}

export function memoryCheckpointStore(): CheckpointStore {
  let checkpoint: DeploymentCheckpoint | undefined;
  let locked = false;
  return {
    async acquire() { if (locked) throw new Error("Deployment already running"); locked = true; },
    async release() { locked = false; },
    async load() { return checkpoint && structuredClone(checkpoint); },
    async save(value) { checkpoint = structuredClone(value); },
  };
}

export function deploymentPlanHash(plan: DeploymentPlan): string {
  return keccak256(toUtf8Bytes(canonicalManifestValue(plan as any)));
}

export function validateDeploymentPlan(plan: DeploymentPlan): void {
  if (!/^[1-9][0-9]*$/.test(plan.chainId) || !Number.isSafeInteger(plan.startingNonce) || plan.startingNonce < 0) {
    throw new Error("Invalid deployment chain or starting nonce");
  }
  getAddress(plan.deployer);
  const deployed = new Map<string, number>();
  for (const [index, step] of plan.steps.entries()) {
    if (step.index !== index || step.nonce !== plan.startingNonce + index || !Number.isSafeInteger(step.nonce)) {
      throw new Error("Deployment indexes and nonces must be contiguous and ordered");
    }
    if (!/^0x(?:[0-9a-fA-F]{2})+$/.test(step.data) || !/^(0|[1-9][0-9]*)$/.test(step.value)) {
      throw new Error("Invalid deployment transaction input");
    }
    if (new Set(step.dependsOn).size !== step.dependsOn.length || step.dependsOn.some(
      dependency => !Number.isSafeInteger(dependency) || dependency < 0 || dependency >= index,
    )) throw new Error("Deployment dependencies must precede their consumer");
    if (step.action === "deploy") {
      if (step.to !== null || deployed.has(step.contract)) throw new Error("Duplicate or invalid deployment");
      deployed.set(step.contract, index);
    } else if (step.action === "call") {
      const target = deployed.get(step.contract);
      if (target === undefined || !step.dependsOn.includes(target) || !step.to ||
          getAddress(step.to) !== getCreateAddress({ from: plan.deployer, nonce: plan.steps[target].nonce })) {
        throw new Error("Call target must be an earlier deployment dependency");
      }
    } else throw new Error("Unknown deployment action");
  }
}

async function requireNonce(provider: Provider, plan: DeploymentPlan, completed: number): Promise<void> {
  const expected = plan.startingNonce + completed;
  const [latest, pending] = await Promise.all([
    provider.getTransactionCount(plan.deployer, "latest"),
    provider.getTransactionCount(plan.deployer, "pending"),
  ]);
  if (latest !== expected || pending !== expected) {
    throw new Error(`Deployment nonce drift: expected ${expected}, latest ${latest}, pending ${pending}`);
  }
}

async function verifyTransaction(
  provider: Provider, plan: DeploymentPlan, record: RecordedTransaction,
): Promise<TransactionReceipt> {
  if (!record.hash) throw new Error(`Ambiguous broadcast at index ${record.index}; reconcile its hash before resuming`);
  const step = plan.steps[record.index];
  const [transaction, receipt] = await Promise.all([
    provider.getTransaction(record.hash), provider.getTransactionReceipt(record.hash),
  ]);
  if (!transaction || !receipt) throw new Error(`Transaction ${record.hash} pending or unavailable; never rebroadcast automatically`);
  if (transaction.hash !== record.hash || receipt.hash !== record.hash || receipt.status !== 1 ||
      getAddress(transaction.from) !== getAddress(plan.deployer) || getAddress(receipt.from) !== getAddress(plan.deployer) ||
      transaction.chainId !== BigInt(plan.chainId) || transaction.nonce !== step.nonce ||
      transaction.to !== step.to || receipt.to !== step.to || transaction.data !== step.data ||
      transaction.value !== BigInt(step.value)) throw new Error(`Transaction mismatch at index ${step.index}`);
  const block = await provider.getBlock(receipt.blockNumber);
  if (!block || block.hash !== receipt.blockHash || block.transactions[receipt.index] !== record.hash) {
    throw new Error(`Noncanonical receipt at index ${step.index}`);
  }
  const recordedReceipt = {
    blockHash: receipt.blockHash, blockNumber: receipt.blockNumber,
    transactionIndex: receipt.index, contractAddress: receipt.contractAddress,
  };
  if (record.receipt && JSON.stringify(record.receipt) !== JSON.stringify(recordedReceipt)) {
    throw new Error(`Prior receipt changed at index ${step.index}`);
  }
  if (step.action === "deploy") {
    const address = getCreateAddress({ from: plan.deployer, nonce: step.nonce });
    if (receipt.contractAddress !== address) throw new Error(`Deployment address mismatch at index ${step.index}`);
    const [atReceipt, current] = await Promise.all([
      provider.getCode(address, receipt.blockNumber), provider.getCode(address),
    ]);
    const codeHash = keccak256(atReceipt);
    if (atReceipt === "0x" || keccak256(current) !== codeHash || (record.codeHash && record.codeHash !== codeHash)) {
      throw new Error(`Deployment code hash mismatch at index ${step.index}`);
    }
    record.codeHash = codeHash;
  } else if (receipt.contractAddress !== null || record.codeHash !== undefined) {
    throw new Error(`Invalid call receipt at index ${step.index}`);
  }
  record.receipt = recordedReceipt;
  return receipt;
}

/** No automatic replacement or rebroadcast, even when an RPC times out or loses a transaction.
 * An intent without a returned hash requires an operator-supplied hash, which is verified against
 * the exact sender, chain, nonce, destination, calldata, value, successful receipt and CREATE address.
 */
export async function runDeployment(
  plan: DeploymentPlan, signer: Signer, store: CheckpointStore,
  reconcile?: { index: number; hash: string },
): Promise<DeploymentCheckpoint> {
  validateDeploymentPlan(plan);
  const provider = signer.provider;
  if (!provider || getAddress(await signer.getAddress()) !== getAddress(plan.deployer) ||
      (await provider.getNetwork()).chainId !== BigInt(plan.chainId)) throw new Error("Deployment chain or signer mismatch");
  await store.acquire();
  try {
    const checkpoint = await store.load() ?? { schemaVersion: 1, planHash: deploymentPlanHash(plan), transactions: [] };
    if (checkpoint.schemaVersion !== 1 || checkpoint.planHash !== deploymentPlanHash(plan) ||
        !Array.isArray(checkpoint.transactions) || checkpoint.transactions.length > plan.steps.length) {
      throw new Error("Deployment checkpoint does not match plan");
    }
    for (const [index, record] of checkpoint.transactions.entries()) {
      if (record.index !== index || record.nonce !== plan.steps[index].nonce ||
          (index < checkpoint.transactions.length - 1 && (!record.receipt || !record.codeHash && plan.steps[index].action === "deploy"))) {
        throw new Error("Deployment checkpoint must be an ordered receipt prefix");
      }
      if (!record.hash && reconcile?.index === index) record.hash = reconcile.hash;
      await verifyTransaction(provider, plan, record);
    }
    await store.save(checkpoint);
    await requireNonce(provider, plan, checkpoint.transactions.length);
    for (const step of plan.steps.slice(checkpoint.transactions.length)) {
      await requireNonce(provider, plan, step.index);
      if (step.action === "deploy" && await provider.getCode(getCreateAddress({ from: plan.deployer, nonce: step.nonce })) !== "0x") {
        throw new Error(`Deployment address already contains code at index ${step.index}`);
      }
      const record: RecordedTransaction = { index: step.index, nonce: step.nonce };
      checkpoint.transactions.push(record);
      // This must succeed durably before invoking the signer. Losing the RPC response is ambiguous.
      await store.save(checkpoint);
      const response = await signer.sendTransaction({
        chainId: BigInt(plan.chainId), nonce: step.nonce, to: step.to, data: step.data, value: BigInt(step.value),
      });
      record.hash = response.hash;
      await store.save(checkpoint);
      await response.wait(1);
      await verifyTransaction(provider, plan, record);
      await store.save(checkpoint);
    }
    await requireNonce(provider, plan, plan.steps.length);
    return checkpoint;
  } finally { await store.release(); }
}
