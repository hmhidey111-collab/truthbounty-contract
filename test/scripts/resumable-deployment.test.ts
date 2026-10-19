import { after, before, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { JsonRpcProvider, getCreateAddress, keccak256 } from "ethers";
import type { Signer } from "ethers";
import {
  fileCheckpointStore, memoryCheckpointStore, runDeployment, validateDeploymentPlan,
} from "../../scripts/resumableDeployment.js";
import type { CheckpointStore, DeploymentPlan } from "../../scripts/resumableDeployment.js";

// Real local EVM receipts without compiling unrelated protocol contracts.
const initCode = "0x6001600c60003960016000f300"; // CREATE returns one STOP byte.
let node: ReturnType<typeof spawn>;
let provider: JsonRpcProvider;
let signer: Signer;
let address: string;
let directory: string;
let plan: DeploymentPlan;

before(async () => {
  const server = createServer();
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as any).port;
  await new Promise<void>(resolve => server.close(() => resolve()));
  node = spawn(process.env.ANVIL ?? "anvil", ["--port", String(port), "--silent"], { stdio: "ignore" });
  provider = new JsonRpcProvider(`http://127.0.0.1:${port}`, undefined, { cacheTimeout: -1 });
  await new Promise<void>((resolve, reject) => {
    node.once("error", reject);
    const check = async () => {
      try { await provider.send("eth_chainId", []); resolve(); }
      catch { if (node.exitCode !== null) reject(new Error("Anvil exited")); else setTimeout(check, 30); }
    };
    check();
  });
  signer = await provider.getSigner(0);
  address = await signer.getAddress();
  directory = await mkdtemp(join(tmpdir(), "truthbounty-resume-"));
});

after(async () => {
  provider?.destroy();
  node?.kill();
  if (directory) await rm(directory, { recursive: true, force: true });
});

beforeEach(async () => {
  await provider.send("anvil_reset", []);
  plan = {
    chainId: "31337", deployer: address, startingNonce: 0,
    steps: [0, 1, 2].map(index => ({
      index, nonce: index, contract: `Module${index}`, action: "deploy", dependsOn: index ? [index - 1] : [],
      to: null, data: initCode, value: "0",
    })),
  };
  plan.steps.push({ index: 3, nonce: 3, contract: "Module0", action: "call", dependsOn: [0, 2],
    to: getCreateAddress({ from: address, nonce: 0 }), data: "0x12345678", value: "0" });
});

function interrupt(store: CheckpointStore, index: number, boundary: "intent" | "hash" | "receipt"): CheckpointStore {
  let active = true;
  return { ...store, async save(checkpoint) {
    await store.save(checkpoint);
    const record = checkpoint.transactions[index];
    if (active && record && (boundary === "intent" && !record.hash || boundary === "hash" && record.hash && !record.receipt ||
        boundary === "receipt" && record.receipt)) {
      active = false;
      throw new Error("simulated interruption");
    }
  } };
}

describe("ordered deployment resume against a real local EVM", () => {
  for (let index = 0; index < 4; index++) {
    for (const boundary of ["hash", "receipt"] as const) {
      it(`resumes after transaction ${index} at the ${boundary} checkpoint without duplicate broadcasts`, async () => {
        const store = memoryCheckpointStore();
        await assert.rejects(runDeployment(plan, signer, interrupt(store, index, boundary)), /simulated interruption/);
        const checkpoint = await runDeployment(plan, signer, store);
        assert.equal(await provider.getTransactionCount(address), 4);
        assert.deepEqual(checkpoint.transactions.map(tx => tx.nonce), [0, 1, 2, 3]);
        assert.equal(new Set(checkpoint.transactions.map(tx => tx.hash)).size, 4);
        for (const record of checkpoint.transactions) {
          const receipt = await provider.getTransactionReceipt(record.hash!);
          assert.equal(record.receipt!.blockHash, receipt!.blockHash);
          assert.equal(record.receipt!.transactionIndex, receipt!.index);
          if (index < 3) assert.equal(checkpoint.transactions[index].codeHash, keccak256("0x00"));
        }
        assert.deepEqual(await runDeployment(plan, signer, store), checkpoint);
        assert.equal(await provider.getTransactionCount(address), 4);
      });
    }
    it(`reconciles a lost RPC response at transaction ${index} using only its verified hash`, async () => {
      const store = memoryCheckpointStore();
      let hash = "";
      const ambiguous = {
        provider, getAddress: () => signer.getAddress(),
        async sendTransaction(request: any) {
          const tx = await signer.sendTransaction(request);
          if (request.nonce === index) { hash = tx.hash; throw new Error("lost RPC response"); }
          return tx;
        },
      } as any;
      await assert.rejects(runDeployment(plan, ambiguous, store), /lost RPC response/);
      await assert.rejects(runDeployment(plan, signer, store), /Ambiguous broadcast/);
      await runDeployment(plan, signer, store, { index, hash });
      assert.equal(await provider.getTransactionCount(address), 4);
    });
  }

  it("fails closed after an intent without a broadcast, including an RPC error before acceptance", async () => {
    const store = memoryCheckpointStore();
    await assert.rejects(runDeployment(plan, signer, interrupt(store, 0, "intent")), /interruption/);
    await assert.rejects(runDeployment(plan, signer, store), /Ambiguous broadcast/);
    assert.equal(await provider.getTransactionCount(address), 0);
  });

  it("rejects external confirmed nonce consumption before a fresh deployment and before resume", async () => {
    await signer.sendTransaction({ to: address });
    await assert.rejects(runDeployment(plan, signer, memoryCheckpointStore()), /nonce drift/);
    await provider.send("anvil_reset", []);
    const store = memoryCheckpointStore();
    await assert.rejects(runDeployment(plan, signer, interrupt(store, 1, "receipt")), /interruption/);
    await signer.sendTransaction({ to: address });
    await assert.rejects(runDeployment(plan, signer, store), /nonce drift/);
    assert.equal(await provider.getTransactionCount(address), 3);
  });

  it("rejects pending external nonce consumption", async () => {
    await provider.send("evm_setAutomine", [false]);
    try {
      await signer.sendTransaction({ to: address, nonce: 0 });
      await assert.rejects(runDeployment(plan, signer, memoryCheckpointStore()), /nonce drift/);
    } finally { await provider.send("evm_setAutomine", [true]); }
  });

  it("verifies every prior code hash and receipt before any new transaction", async () => {
    const store = memoryCheckpointStore();
    await assert.rejects(runDeployment(plan, signer, interrupt(store, 1, "receipt")), /interruption/);
    await provider.send("anvil_setCode", [getCreateAddress({ from: address, nonce: 0 }), "0x6000"]);
    await assert.rejects(runDeployment(plan, signer, store), /code hash mismatch/);
    assert.equal(await provider.getTransactionCount(address), 2);
  });

  it("rejects reorged receipts and never rebroadcasts the missing transaction", async () => {
    const snapshot = await provider.send("evm_snapshot", []);
    const store = memoryCheckpointStore();
    await assert.rejects(runDeployment(plan, signer, interrupt(store, 1, "receipt")), /interruption/);
    await provider.send("evm_revert", [snapshot]);
    await assert.rejects(runDeployment(plan, signer, store), /pending or unavailable/);
    assert.equal(await provider.getTransactionCount(address), 0);
  });

  it("rejects altered receipts even when the recorded transaction is valid", async () => {
    const store = memoryCheckpointStore();
    await runDeployment(plan, signer, store);
    const checkpoint = (await store.load())!;
    checkpoint.transactions[0].receipt!.blockHash = `0x${"ff".repeat(32)}`;
    await store.save(checkpoint);
    await assert.rejects(runDeployment(plan, signer, store), /Prior receipt changed/);
  });

  it("does not rebroadcast a known hash when the RPC cannot return its receipt", async () => {
    const store = memoryCheckpointStore();
    await assert.rejects(runDeployment(plan, signer, interrupt(store, 0, "hash")), /interruption/);
    const original = provider.getTransactionReceipt.bind(provider);
    provider.getTransactionReceipt = async () => null;
    try { await assert.rejects(runDeployment(plan, signer, store), /pending or unavailable/); }
    finally { provider.getTransactionReceipt = original; }
    assert.equal(await provider.getTransactionCount(address), 1);
  });

  it("rejects an unrelated transaction supplied as ambiguous-broadcast reconciliation", async () => {
    const store = memoryCheckpointStore();
    await assert.rejects(runDeployment(plan, signer, interrupt(store, 0, "intent")), /interruption/);
    const unrelated = await signer.sendTransaction({ to: address });
    await assert.rejects(runDeployment(plan, signer, store, { index: 0, hash: unrelated.hash }), /Transaction mismatch/);
  });

  it("rejects a different signer or chain before writing an intent", async () => {
    const store = memoryCheckpointStore();
    await assert.rejects(runDeployment(plan, await provider.getSigner(1), store), /chain or signer mismatch/);
    plan.chainId = "10";
    await assert.rejects(runDeployment(plan, signer, store), /chain or signer mismatch/);
    assert.equal(await store.load(), undefined);
    assert.equal(await provider.getTransactionCount(address), 0);
  });

  it("rejects failed receipts without advancing the ordered receipt prefix", async () => {
    const store = memoryCheckpointStore();
    plan.steps[0].data = "0x60006000fd"; // REVERT during creation.
    const uncheckedSigner = { provider, getAddress: () => signer.getAddress(),
      sendTransaction: (request: any) => signer.sendTransaction({ ...request, gasLimit: 100000 }),
    } as any;
    await assert.rejects(runDeployment(plan, uncheckedSigner, store));
    await assert.rejects(runDeployment(plan, signer, store), /Transaction mismatch/);
    assert.equal(await provider.getTransactionCount(address), 1);
  });

  it("rejects calldata or starting nonce changes across resume", async () => {
    const store = memoryCheckpointStore();
    await runDeployment(plan, signer, store);
    plan.steps[3].data = "0xdeadbeef";
    await assert.rejects(runDeployment(plan, signer, store), /checkpoint does not match plan/);
  });

  it("rejects forward or reordered dependencies, duplicate deployments and noncontiguous nonces", () => {
    plan.steps[0].dependsOn = [1];
    assert.throws(() => validateDeploymentPlan(plan), /dependencies must precede/);
    plan.steps[0].dependsOn = [];
    plan.steps[1].nonce = 3;
    assert.throws(() => validateDeploymentPlan(plan), /contiguous and ordered/);
    plan.steps[1].nonce = 1;
    plan.steps[1].contract = "Module0";
    assert.throws(() => validateDeploymentPlan(plan), /Duplicate/);
  });

  it("rejects a contract address collision before broadcast", async () => {
    await provider.send("anvil_setCode", [getCreateAddress({ from: address, nonce: 0 }), "0x00"]);
    await assert.rejects(runDeployment(plan, signer, memoryCheckpointStore()), /already contains code/);
    assert.equal(await provider.getTransactionCount(address), 0);
  });

  it("fails before broadcast if the intent cannot be saved", async () => {
    const store = memoryCheckpointStore();
    store.save = async checkpoint => { if (checkpoint.transactions.length) throw new Error("disk full"); };
    await assert.rejects(runDeployment(plan, signer, store), /disk full/);
    assert.equal(await provider.getTransactionCount(address), 0);
  });

  it("persists actual receipts atomically and prevents concurrent file writers", async () => {
    const file = join(directory, "checkpoint.json");
    const store = fileCheckpointStore(file);
    await store.acquire();
    await assert.rejects(runDeployment(plan, signer, fileCheckpointStore(file)), { code: "EEXIST" });
    await store.release();
    const checkpoint = await runDeployment(plan, signer, fileCheckpointStore(file));
    assert.deepEqual(JSON.parse(await readFile(file, "utf8")), checkpoint);
    assert.deepEqual(await runDeployment(plan, signer, fileCheckpointStore(file)), checkpoint);
  });
});
