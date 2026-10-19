import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Interface, keccak256, toUtf8Bytes } from "ethers";
import { buildAbiArtifactExport } from "../../scripts/exportVersionedAbiArtifacts.js";
import { buildCollisionReport, buildEventLayout, findAbiCollisions, compareEventLayouts } from "../../scripts/canonical-abi-gates.mjs";

const read = (file: string) => JSON.parse(readFileSync(file, "utf8"));
const bundle = read("exports/abi/v2/2.0.0-2.0/manifest.json");
const extension = bundle.extensions.find((entry: any) => entry.name === "IUntrackedAssetRecovery");
const policy = read("deployments/config/asset-recovery.json");
const normalized = (abi: any[]) => new Interface(abi).fragments.map(fragment => fragment.format("full")).sort();

describe("V2 governed recovery ABI, authority, storage and consumer handoff", () => {
  it("matches the current extension source without changing released ownership interfaces", () => {
    const current = buildAbiArtifactExport(process.cwd());
    assert.deepEqual(bundle.extensions, current.extensions);
    assert.equal(bundle.modules.some((module: any) => module.name === "IUntrackedAssetRecovery"), false);
    assert.equal(extension.source, policy.source);
    assert.equal(extension.events.length, 3);
    assert.equal(extension.functions.length, 4);
  });

  it("matches the actual compiled Solidity ABI including indexed fields and return types", () => {
    const artifact = read("out/asset-recovery/IUntrackedAssetRecovery.sol/IUntrackedAssetRecovery.json");
    assert.deepEqual(normalized(extension.abi), normalized(artifact.abi));
  });

  it("keeps all recovery selectors and error/event artifacts collision free", () => {
    assert.deepEqual(findAbiCollisions(bundle, read("config/abi-collision-allowlist.json")), []);
    assert.deepEqual(buildCollisionReport(bundle), read("schemas/abi-collision-report-v2.json"));
    assert.deepEqual(compareEventLayouts(read("schemas/event-layout-v2.json"), buildEventLayout(bundle)), []);
  });

  it("pins every V2 holder, pause policy, fixed delay and storage namespace", () => {
    assert.equal(policy.hosts.length, 10);
    assert.equal(new Set(policy.hosts.map((host: any) => host.source)).size, 10);
    assert.equal(policy.mandatoryDelaySeconds, "172800");
    const implementation = readFileSync(policy.implementation, "utf8");
    assert.ok(implementation.includes("ASSET_RECOVERY_DELAY = 2 days"));
    assert.ok(implementation.includes(policy.storage.slot));
    assert.ok(implementation.includes(`erc7201:${policy.storage.namespace}`));
    for (const host of policy.hosts) {
      const source = readFileSync(host.source, "utf8");
      assert.ok(source.includes("UntrackedAssetRecovery"), host.source);
      assert.ok(source.includes("function _reservedAssetBalance"), host.source);
      assert.ok(source.includes("function _checkAssetRecoveryAuthority"), host.source);
      assert.ok(source.includes("function _requireAssetRecoveryAllowed"), host.source);
    }
    const selector = keccak256(toUtf8Bytes("executeAssetRecovery(bytes32)")).slice(0, 10);
    assert.equal(extension.functions.find((entry: any) => entry.signature === "executeAssetRecovery(bytes32)").selector, selector);
  });

  it("does not add arbitrary targets, calldata, attached value or delay setters", () => {
    const iface = new Interface(extension.abi);
    assert.deepEqual(iface.fragments.filter(fragment => fragment.type === "function").map(fragment => fragment.format("sighash")).sort(), [
      "cancelAssetRecovery(bytes32)", "executeAssetRecovery(bytes32)",
      "queueAssetRecovery(address,address,uint256,bytes32)", "recoverableBalance(address)",
    ]);
    for (const fragment of iface.fragments as any[]) if (fragment.type === "function") assert.notEqual(fragment.stateMutability, "payable");
  });

  it("preserves the exact frozen linear storage slots, widths, offsets and gaps", () => {
    const frozen = read("storage-layouts/manifest.json");
    for (const name of ["StakeVault", "TreasuryManagement"]) {
      const artifact = read(`out/asset-recovery/${name}.sol/${name}.json`);
      const layout = artifact.storageLayout;
      const actual = Object.fromEntries(layout.storage.map((entry: any) => [entry.label + "@" + entry.slot, {
        slot: entry.slot, offset: entry.offset, numberOfBytes: layout.types[entry.type].numberOfBytes,
      }]));
      const expected = Object.fromEntries(Object.entries(frozen.contracts[name].slots).map(([key, entry]: any) => [key, {
        slot: entry.slot, offset: entry.offset, numberOfBytes: entry.numberOfBytes,
      }]));
      assert.deepEqual(actual, expected, name);
    }
  });

  it("keeps every affected deployable inside its existing bytecode budget", () => {
    const budgets = read("config/deployment-size-budgets.json");
    for (const host of policy.hosts) {
      const name = host.source.split("/").at(-1)!.replace(".sol", "");
      const directory = host.source === "contracts/v2/StakeVault.sol" ? "v2/StakeVault.sol" : name + ".sol";
      // Foundry disambiguates the two same-named StakeVault artifacts in metadata.
      const entries = host.source.endsWith("StakeVault.sol") ? ["StakeVault.sol", "v2/StakeVault.sol"] : [directory];
      let artifact: any;
      for (const entry of entries) {
        try {
          const candidate = read(`out/asset-recovery/${entry}/${name}.json`);
          const metadata = typeof candidate.metadata === "string" ? JSON.parse(candidate.metadata) : candidate.metadata;
          if (Object.keys(metadata.settings.compilationTarget).some(path => path.endsWith(host.source))) { artifact = candidate; break; }
        } catch (error: any) { if (error.code !== "ENOENT") throw error; }
      }
      assert.ok(artifact, host.source);
      const size = artifact.deployedBytecode.object.replace(/^0x/, "").length / 2;
      const budget = budgets.contracts[name]?.hardLimitBytes ?? budgets.defaults.hardLimitBytes;
      assert.ok(size <= budget, `${host.source}: ${size} > ${budget}`);
    }
  });
});
