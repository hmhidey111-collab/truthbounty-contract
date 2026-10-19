import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

import {
  MANIFEST_RELATIVE_PATH,
  checkArtifacts,
  checkDigest,
  checkExplorer,
  checkSources,
  checkToolchain,
  computeManifestDigest,
  countLinkReferences,
  keccakOfHex,
  loadManifest,
  metadataSolcVersion,
  readToolchainPins,
  runAllChecks,
} from "../../scripts/check-release-reproducibility.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "../..");

/** Build a minimal CBOR-metadata deployed bytecode embedding solc major.minor.patch. */
function deployedWithMetadata(prefixHex, major, minor, patch) {
  const ipfs = Buffer.alloc(34, 0xab);
  const meta = Buffer.concat([
    Buffer.from([0xa2, 0x64, ...Buffer.from("ipfs"), 0x58, 0x22]),
    ipfs,
    Buffer.from([0x64, ...Buffer.from("solc"), 0x43, major, minor, patch]),
  ]);
  const suffix = Buffer.alloc(2);
  suffix.writeUInt16BE(meta.length, 0);
  return `${prefixHex}${meta.toString("hex")}${suffix.toString("hex")}`;
}

function fixtureManifest(dir, overrides = {}) {
  const sourcePath = "contracts/v2/Fixture.sol";
  const sourceBytes = "pragma solidity ^0.8.28;\ncontract Fixture {}";
  mkdirSync(join(dir, "contracts/v2"), { recursive: true });
  writeFileSync(join(dir, sourcePath), sourceBytes);
  const bytecode = "0x600a600b";
  const deployed = deployedWithMetadata("0x600a", 0, 8, 28);
  const artifactDir = join(dir, "out", "Fixture.sol");
  mkdirSync(artifactDir, { recursive: true });
  writeFileSync(
    join(artifactDir, "Fixture.json"),
    JSON.stringify({
      bytecode: { object: bytecode, linkReferences: {} },
      deployedBytecode: { object: deployed, linkReferences: {} },
    }),
  );
  writeFileSync(join(dir, "hardhat.config.ts"), 'version: "0.8.28", evmVersion: "cancun", viaIR: true, optimizer: { enabled: true, runs: 200 }');
  writeFileSync(join(dir, "foundry.toml"), 'solc = "0.8.28"\noptimizer = true\noptimizer_runs = 200\nvia_ir = true\n');
  const manifest = {
    schemaVersion: 1,
    toolchain: { solc: "0.8.28", evmVersion: "cancun", viaIR: true, optimizer: { enabled: true, runs: 200 } },
    sources: [{ path: sourcePath, sha256: createHash("sha256").update(sourceBytes).digest("hex") }],
    artifacts: [
      {
        contract: "Fixture",
        source: sourcePath,
        bytecodeKeccak: keccakOfHex(bytecode),
        deployedBytecodeKeccak: keccakOfHex(deployed),
        metadataSolc: "0.8.28",
        libraries: {},
      },
    ],
    explorer: {
      contract: "Fixture",
      source: sourcePath,
      compilerVersion: "0.8.28",
      evmVersion: "cancun",
      optimizerEnabled: true,
      optimizerRuns: 200,
      viaIR: true,
      bytecodeKeccak: "pinned",
      deployedBytecodeKeccak: "pinned",
      metadataSolc: "0.8.28",
      libraries: "none",
      networks: ["optimism sepolia (chain id 11155420)"],
    },
    ...overrides,
  };
  manifest.manifestDigest = computeManifestDigest(manifest);
  const manifestRelative = "manifest.json";
  writeFileSync(join(dir, manifestRelative), JSON.stringify(manifest, null, 2));
  return { dir, manifestRelative, manifest, sourcePath, bytecode, deployed };
}

function freshFixture(overrides) {
  return fixtureManifest(mkdtempSync(join(tmpdir(), "v2-sc-129-")), overrides);
}

describe("V2-SC-129 release reproducibility checker", () => {
  it("positive: pristine fixture verifies cleanly and deterministically (replay)", () => {
    const { dir, manifestRelative } = freshFixture();
    const first = runAllChecks(dir, manifestRelative);
    const second = runAllChecks(dir, manifestRelative);
    assert.deepEqual(first, []);
    assert.deepEqual(second, first);
  });

  it("positive: approved repo manifest verifies against real build outputs", (t) => {
    const hasFoundryOutputs = (() => {
      try {
        return readdirSync(join(REPO_ROOT, "out")).length > 0;
      } catch {
        return false;
      }
    })();
    const hasHardhatOutputs = (() => {
      try {
        return readdirSync(join(REPO_ROOT, "artifacts", "contracts")).length > 0;
      } catch {
        return false;
      }
    })();
    if (!hasFoundryOutputs && !hasHardhatOutputs) {
      t.skip("no build outputs present; run `forge build` first (CI runs this in the test job)");
      return;
    }
    const problems = runAllChecks(REPO_ROOT, MANIFEST_RELATIVE_PATH);
    assert.deepEqual(problems, []);
  });

  it("negative: tampered source bytes fail with a source-drift problem", () => {
    const { dir, manifestRelative, sourcePath } = freshFixture();
    writeFileSync(join(dir, sourcePath), "pragma solidity ^0.8.28;\ncontract Fixture { uint256 x; }");
    const problems = runAllChecks(dir, manifestRelative);
    assert.match(problems.join("\n"), /source drift/);
  });

  it("negative: tampered optimizer runs in toolchain config fail", () => {
    const { dir, manifestRelative } = freshFixture();
    writeFileSync(join(dir, "foundry.toml"), 'solc = "0.8.28"\noptimizer = true\noptimizer_runs = 199\nvia_ir = true\n');
    const problems = runAllChecks(dir, manifestRelative);
    assert.match(problems.join("\n"), /toolchain drift.*optimizer_runs/);
  });

  it("negative: tampered bytecode fails with a bytecode-drift problem", () => {
    const { dir, manifestRelative } = freshFixture();
    const artifactFile = join(dir, "out", "Fixture.sol", "Fixture.json");
    const artifact = JSON.parse(readFileSync(artifactFile, "utf8"));
    artifact.bytecode.object = "0x600c600d";
    writeFileSync(artifactFile, JSON.stringify(artifact));
    const problems = runAllChecks(dir, manifestRelative);
    assert.match(problems.join("\n"), /bytecode drift/);
  });

  it("negative: zero-address library pin fails", () => {
    const { dir, manifestRelative, manifest } = freshFixture();
    manifest.artifacts[0].libraries = { SomeLib: "0x0000000000000000000000000000000000000000" };
    manifest.manifestDigest = computeManifestDigest(manifest);
    writeFileSync(join(dir, manifestRelative), JSON.stringify(manifest, null, 2));
    const problems = runAllChecks(dir, manifestRelative);
    assert.match(problems.join("\n"), /zero or malformed/);
  });

  it("negative: hand-edited manifest fails the digest check", () => {
    const { dir, manifestRelative, manifest } = freshFixture();
    manifest.toolchain.optimizer.runs = 200;
    manifest.sources.push({ path: "contracts/v2/Extra.sol", sha256: "abc" });
    writeFileSync(join(dir, manifestRelative), JSON.stringify(manifest, null, 2));
    const { manifest: loaded } = loadManifest(dir, manifestRelative);
    assert.match(checkDigest(loaded).join("\n"), /digest mismatch/);
  });

  it("negative: incomplete explorer block fails", () => {
    const { manifest } = freshFixture();
    delete manifest.explorer.networks;
    delete manifest.explorer.viaIR;
    const problems = checkExplorer(manifest);
    assert.ok(problems.some((problem) => problem.includes("target networks")));
    assert.ok(problems.some((problem) => problem.includes("viaIR")));
  });

  it("boundary: optimizer runs 199 and 201 both fail, 200 passes", () => {
    const { dir, manifestRelative } = freshFixture();
    for (const runs of [199, 201]) {
      writeFileSync(join(dir, "foundry.toml"), `solc = "0.8.28"\noptimizer = true\noptimizer_runs = ${runs}\nvia_ir = true\n`);
      const problems = checkToolchain(dir, loadManifest(dir, manifestRelative).manifest);
      assert.ok(problems.some((problem) => problem.includes("optimizer_runs")), `runs=${runs} must fail`);
    }
    writeFileSync(join(dir, "foundry.toml"), 'solc = "0.8.28"\noptimizer = true\noptimizer_runs = 200\nvia_ir = true\n');
    assert.deepEqual(checkToolchain(dir, loadManifest(dir, manifestRelative).manifest), []);
  });

  it("boundary: empty source and artifact sets are rejected (never vacuously true)", () => {
    const { manifest } = freshFixture();
    assert.deepEqual(checkSources("/tmp", { ...manifest, sources: [] }).length === 0, false);
    assert.match(checkSources("/tmp", { ...manifest, sources: [] }).join("\n"), /empty source set/);
    assert.match(checkArtifacts("/tmp", { ...manifest, artifacts: [] }).join("\n"), /empty artifact set/);
  });

  it("boundary: a single unresolved link reference fails", () => {
    assert.equal(countLinkReferences({ "Lib.sol": { Lib: [{ start: 0, length: 20 }] } }), 1);
    const { dir, manifestRelative } = freshFixture();
    const artifactFile = join(dir, "out", "Fixture.sol", "Fixture.json");
    const artifact = JSON.parse(readFileSync(artifactFile, "utf8"));
    artifact.bytecode.linkReferences = { "Lib.sol": { Lib: [{ start: 0, length: 20 }] } };
    writeFileSync(artifactFile, JSON.stringify(artifact));
    const problems = runAllChecks(dir, manifestRelative);
    assert.match(problems.join("\n"), /link references/);
  });

  it("boundary: CBOR metadata decoder pins the embedded solc version", () => {
    assert.equal(metadataSolcVersion(deployedWithMetadata("0x600a", 0, 8, 28)), "0.8.28");
    assert.equal(metadataSolcVersion(deployedWithMetadata("0x600a", 0, 8, 27)), "0.8.27");
    assert.equal(metadataSolcVersion("0x600a"), null);
    assert.equal(metadataSolcVersion("0x"), null);
  });

  it("authorization: the checker grants no authority and touches no secrets or network", () => {
    const source = readFileSync(resolve(REPO_ROOT, "scripts/check-release-reproducibility.mjs"), "utf8");
    for (const forbidden of ["fetch(", "XMLHttpRequest", "PRIVATE_KEY", "mnemonic", "etherscan", "verifyContract", "grantRole", "transfer(", "call("]) {
      assert.ok(!source.includes(forbidden), `checker must not contain ${forbidden}`);
    }
    const pins = readToolchainPins(REPO_ROOT);
    assert.equal(pins.hardhat.solc, "0.8.28");
    assert.equal(pins.foundry.solc, "0.8.28");
  });

  it("replay: digest computation is deterministic across repeated runs", () => {
    const { manifest } = freshFixture();
    assert.equal(computeManifestDigest(manifest), computeManifestDigest(manifest));
    assert.match(manifest.manifestDigest, /^0x[0-9a-f]{64}$/);
  });

  it("failure-path: missing manifest throws an actionable error", () => {
    assert.throws(() => loadManifest(mkdtempSync(join(tmpdir(), "v2-sc-129-")), "missing.json"), /release manifest missing/);
  });

  it("failure-path: missing build outputs fail closed (never silently pass)", () => {
    const dir = mkdtempSync(join(tmpdir(), "v2-sc-129-"));
    const { manifest } = freshFixture();
    const problems = checkArtifacts(dir, manifest, null);
    assert.match(problems.join("\n"), /no build outputs found/);
  });

  it("failure-path: alternate-chain runtime references in pinned sources fail", () => {
    const { dir, manifestRelative, sourcePath } = freshFixture();
    writeFileSync(join(dir, sourcePath), "pragma solidity ^0.8.28;\n// soroban bridge\ncontract Fixture {}");
    const { manifest } = loadManifest(dir, manifestRelative);
    const problems = checkSources(dir, { ...manifest, sources: [{ path: sourcePath, sha256: createHash("sha256").update(readFileSync(join(dir, sourcePath))).digest("hex") }] });
    assert.match(problems.join("\n"), /alternate-chain/);
  });
});
