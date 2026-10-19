import { expect } from "chai";
import { buildCanonicalV2Manifest } from "../../scripts/canonicalV2Manifest.js";
import {
  canonicalManifestJson,
  canonicalManifestValue,
  manifestHash,
  validateManifest,
} from "../../scripts/deploymentManifest.js";

const inputs = {
  chainId: 31337,
  protocolVersion: "2.0.0",
  deployer: "0x000000000000000000000000000000000000dEaD",
  startingNonce: 0,
  libraries: {},
  initialSupply: "10000000000000000000000000",
  minVerificationCount: "1",
  minTotalWeight: "0",
  minConfidenceBps: "0",
  challengeWindowDuration: 259200,
  appealDuration: 259200,
  minAppealStake: "200000000000000000000",
  appealMultiplierBps: 15000,
  maxWeightCap: "100000000000000000000000",
};

function artifactReader() {
  return {
    async readArtifact(name: string) {
      return {
        contractName: name,
        sourceName: `contracts/${name}.sol`,
        abi: [],
        bytecode: "0x6000",
        deployedBytecode: "0x6000",
        linkReferences: {},
        deployedLinkReferences: {},
      };
    },
  };
}

describe("Canonical V2 deployment manifest", () => {
  it("sorts object keys without changing array order", () => {
    expect(canonicalManifestValue({ z: 1, a: ["first", "second"] })).to.equal(
      '{"a":["first","second"],"z":1}',
    );
  });

  it("produces the same canonical bytes and hash for repeated inputs", async () => {
    const first = await buildCanonicalV2Manifest(artifactReader(), inputs);
    const second = await buildCanonicalV2Manifest(artifactReader(), { ...inputs });

    expect(canonicalManifestJson(first)).to.equal(canonicalManifestJson(second));
    expect(manifestHash(first)).to.equal(manifestHash(second));
  });

  it("preserves canonical deployment and wiring order", async () => {
    const manifest = await buildCanonicalV2Manifest(artifactReader(), inputs);

    expect(manifest.transactions.map((transaction) => transaction.contract)).to.deep.equal([
      "GovernanceController",
      "RewardToken",
      "StakeVault",
      "MockReputationOracle",
      "ParameterVersionRegistry",
      "ClaimRegistry",
      "TruthBountyWeighted",
      "VerificationAggregator",
      "ProvisionalSettlementEngine",
      "AppealVerificationRound",
      "ClaimRegistry",
      "StakeVault",
    ]);
    expect(manifest.transactions[manifest.transactions.length - 1].action).to.equal("call:grantRole");
    expect(manifest.transactions[7].dependsOn).to.deep.equal(["TruthBountyWeighted"]);
    expect(manifest.contracts[0].address).to.match(/^0x[0-9a-fA-F]{40}$/);
    expect(manifest.contracts[0].salt).to.match(/^0x[0-9a-fA-F]{64}$/);
    expect(manifest.contracts[0].nonce).to.equal(0);
  });

  it("rejects duplicate transaction indexes", () => {
    expect(() =>
      validateManifest({
        schemaVersion: "1",
        protocolVersion: "2.0.0",
        chainId: "31337",
        module: "CanonicalV2Module",
        deployer: "0x000000000000000000000000000000000000dEaD",
        startingNonce: 0,
        compiler: {
          version: "0.8.28",
          evmVersion: "cancun",
          viaIR: true,
          optimizer: { enabled: true, runs: 200 },
        },
        contracts: [],
        transactions: [
          { index: 0, nonce: 0, action: "deploy", contract: "A", dependsOn: [], inputHash: "0x" },
          { index: 0, nonce: 0, action: "deploy", contract: "A", dependsOn: [], inputHash: "0x" },
        ],
      }),
    ).to.throw("transaction indexes must be unique");
  });

  it("rejects transactions that reference unknown contracts", () => {
    expect(() =>
      validateManifest({
        schemaVersion: "1",
        protocolVersion: "2.0.0",
        chainId: "31337",
        module: "CanonicalV2Module",
        deployer: "0x000000000000000000000000000000000000dEaD",
        startingNonce: 0,
        compiler: {
          version: "0.8.28",
          evmVersion: "cancun",
          viaIR: true,
          optimizer: { enabled: true, runs: 200 },
        },
        contracts: [],
        transactions: [{ index: 0, nonce: 0, action: "deploy", contract: "Missing", dependsOn: [], inputHash: "0x" }],
      }),
    ).to.throw("unknown contract: Missing");
  });

  it("rejects non-contiguous transaction order", () => {
    expect(() =>
      validateManifest({
        schemaVersion: "1",
        protocolVersion: "2.0.0",
        chainId: "31337",
        module: "CanonicalV2Module",
        deployer: "0x000000000000000000000000000000000000dEaD",
        startingNonce: 0,
        compiler: {
          version: "0.8.28",
          evmVersion: "cancun",
          viaIR: true,
          optimizer: { enabled: true, runs: 200 },
        },
        contracts: [{ name: "A", artifact: "A", salt: "0x", nonce: 0, address: "0x", constructorArgs: [], libraries: {}, bytecodeHash: "0x", deployedBytecodeHash: "0x" }],
        transactions: [{ index: 1, nonce: 0, action: "deploy", contract: "A", dependsOn: [], inputHash: "0x" }],
      }),
    ).to.throw("contiguous and ordered");
  });

  it("rejects dependency reordering before broadcast", async () => {
    const manifest = await buildCanonicalV2Manifest(artifactReader(), inputs);
    manifest.transactions[0].dependsOn = ["RewardToken"];
    expect(() => validateManifest(manifest)).to.throw("dependency must be deployed earlier");
  });

  it("includes the same bond and parameter registry constructor dependencies as the canonical helper", async () => {
    const manifest = await buildCanonicalV2Manifest(artifactReader(), { ...inputs, startingNonce: 40, finalizeDeployerRoles: true });
    expect(manifest.contracts.find(contract => contract.name === "ClaimRegistry")!.constructorArgs).to.deep.equal([
      { "$ref": "deployer" }, { "$ref": "parameterVersionRegistry" },
    ]);
    expect(manifest.transactions[9].dependsOn).to.include("StakeVault");
    expect(manifest.transactions.at(-1)!.action).to.equal("call:renounceRole");
    expect(manifest.transactions.map(tx => tx.nonce)).to.deep.equal(Array.from({ length: 13 }, (_, index) => 40 + index));
  });

  it("rejects a zero deployer address", async () => {
    try {
      await buildCanonicalV2Manifest(artifactReader(), {
        ...inputs,
        deployer: "0x0000000000000000000000000000000000000000",
      });
      expect.fail("zero deployer address was accepted");
    } catch (error) {
      expect(String(error)).to.contain("zero address");
    }
  });
});