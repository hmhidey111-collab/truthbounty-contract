/**
 * @file check-optimism-sepolia-release.test.mjs
 * @description STAB-SC-007 — self-tests for the canonical Optimism Sepolia release package.
 *
 * Covers: schema/chain/toolchain drift, ABI and bytecode drift, CREATE2 address binding,
 * placeholder/local/duplicate/legacy addresses, role ownership and retained deployer authority,
 * deployment-block and event-cursor rules, consumer agreement, secret scanning, release-ID
 * stability across promotion, deterministic regeneration, and read-only on-chain verification.
 */

import { after, describe, it } from "node:test";
import assert from "node:assert/strict";
import { cpSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  RELEASE_ARTIFACT_PINS_PATH,
  RELEASE_DIR,
  RELEASE_MANIFEST_PATH,
  buildReleasePackage,
  computeFileChecksum,
  computePackageChecksum,
  computeReleaseId,
  deriveCreate2Address,
  deriveSalt,
  encodeAbiParameters,
  findSecretLeaks,
  keccakHex,
  keccakUtf8,
  loadBuildArtifacts,
  loadReleasePackage,
  repoRoot,
  sha256FileHex,
  validateReleasePackage,
  verifyOnchain,
} from "../../scripts/lib/releasePackage.mjs";
import {
  assertConsumersAgree,
  loadReleasePackageForConsumer,
} from "../../scripts/lib/releasePackageConsumer.mjs";

const REPO_ROOT = repoRoot();
let originalFetch = null;

function readPackage(root = REPO_ROOT) {
  return JSON.parse(readFileSync(join(root, RELEASE_MANIFEST_PATH), "utf8"));
}

function writePackage(root, pkg) {
  writeFileSync(join(root, RELEASE_MANIFEST_PATH), `${JSON.stringify(pkg, null, 2)}\n`);
  writeFileSync(
    join(root, "deployments/releases/optimism-sepolia/release.sha256"),
    `${computeFileChecksum(readFileSync(join(root, RELEASE_MANIFEST_PATH)))}  release.json\n`,
  );
}

/** Re-seal a mutated package so the intended invariant — not the digest — is what fails. */
function reseal(pkg) {
  pkg.releaseId = computeReleaseId(pkg);
  pkg.consumers.api.releaseId = pkg.releaseId;
  pkg.consumers.frontend.releaseId = pkg.releaseId;
  pkg.packageChecksum = computePackageChecksum(pkg);
  pkg.consumers.api.packageChecksum = pkg.packageChecksum;
  pkg.consumers.frontend.packageChecksum = pkg.packageChecksum;
  pkg.packageChecksum = computePackageChecksum(pkg);
  return pkg;
}

/** Isolated repository root containing exactly what the validator reads. */
function tempRepo(mutator) {
  const dir = mkdtempSync(join(tmpdir(), "stab-sc-007-"));
  mkdirSync(join(dir, "config"), { recursive: true });
  cpSync(join(REPO_ROOT, "config/optimism-sepolia-release.json"), join(dir, "config/optimism-sepolia-release.json"));
  cpSync(join(REPO_ROOT, "hardhat.config.ts"), join(dir, "hardhat.config.ts"));
  cpSync(join(REPO_ROOT, "foundry.toml"), join(dir, "foundry.toml"));
  cpSync(join(REPO_ROOT, RELEASE_DIR), join(dir, RELEASE_DIR), { recursive: true });
  const pkg = readPackage(dir);
  for (const contract of pkg.contracts) {
    mkdirSync(dirname(join(dir, contract.source)), { recursive: true });
    cpSync(join(REPO_ROOT, contract.source), join(dir, contract.source));
  }
  const mutated = mutator ? mutator(pkg, dir) ?? pkg : pkg;
  writePackage(dir, mutated);
  return { dir, pkg: mutated };
}

function problemsFor(pkg, options = {}) {
  const { dir } = tempRepo();
  writePackage(dir, pkg);
  const problems = validateReleasePackage(pkg, { rootDir: dir, ...options });
  rmSync(dir, { recursive: true, force: true });
  return problems;
}

function hasProblem(problems, pattern) {
  return problems.some((problem) => pattern.test(problem));
}

const BUILD = loadBuildArtifacts(REPO_ROOT, "hardhat");
const SKIP_BUILD = BUILD === null;

describe("STAB-SC-007 release package — committed package", () => {
  it("positive: the committed package validates cleanly offline", () => {
    const problems = validateReleasePackage(readPackage(), { rootDir: REPO_ROOT });
    assert.deepEqual(problems, []);
  });

  it("positive: release.sha256 matches the committed manifest bytes", () => {
    const bytes = readFileSync(join(REPO_ROOT, RELEASE_MANIFEST_PATH));
    const committed = readFileSync(join(REPO_ROOT, "deployments/releases/optimism-sepolia/release.sha256"), "utf8");
    assert.equal(committed.trim().split(/\s+/)[0], computeFileChecksum(bytes));
  });

  it("positive: the package targets Optimism Sepolia only", () => {
    const pkg = readPackage();
    assert.equal(pkg.network.chainId, 11155420);
    assert.equal(pkg.network.name, "optimism-sepolia");
    assert.equal(pkg.network.caip2, "eip155:11155420");
    assert.equal(pkg.network.explorerBase, "https://sepolia-optimism.etherscan.io");
  });

  it("positive: every contract is address-unique and artifact-identified", () => {
    const pkg = readPackage();
    const addresses = new Set();
    for (const contract of pkg.contracts) {
      assert.match(contract.address, /^0x[0-9a-fA-F]{40}$/);
      assert.ok(!addresses.has(contract.address.toLowerCase()), `duplicate address ${contract.address}`);
      addresses.add(contract.address.toLowerCase());
      assert.ok(contract.deployment.initCodeHash.startsWith("0x"));
      assert.ok(contract.artifact.bytecodeKeccak.startsWith("0x"));
      assert.ok(contract.artifact.abiSha256.startsWith("0x"));
      assert.ok(contract.artifact.runtimeBytes > 0);
      assert.ok(contract.artifact.runtimeBytes <= 24_576);
      assert.equal(contract.artifact.linkReferences, 0);
    }
  });

  it("positive: deployer/bootstrap authority is absent from every final role grant", () => {
    const pkg = readPackage();
    const bootstrap = pkg.deterministicDeployment.bootstrapAdmin.address.toLowerCase();
    for (const grant of pkg.roleGrants) {
      assert.notEqual(String(grant.holder.address).toLowerCase(), bootstrap, `${grant.contract}:${grant.role}`);
    }
    assert.equal(pkg.finalization.deployerAuthorityRemoved, true);
    assert.ok(pkg.finalization.steps.some((step) => step.action === "renounce"));
    assert.ok(pkg.finalization.steps.some((step) => step.action === "verify"));
  });

  it("positive: every required role class has a documented owner", () => {
    const pkg = readPackage();
    const classes = new Set(pkg.roleOwnership.map((entry) => entry.class));
    for (const required of ["governance", "timelock", "guardian", "upgradeAdmin", "treasury", "operational"]) {
      assert.ok(classes.has(required), `missing role class ${required}`);
      const entry = pkg.roleOwnership.find((item) => item.class === required);
      assert.match(entry.holder.address, /^0x[0-9a-fA-F]{40}$/);
      assert.ok(entry.description.length > 20);
      assert.ok(entry.mechanism.length > 20);
    }
  });

  it("positive: candidate packages declare blockers and never fake block evidence", () => {
    const pkg = readPackage();
    assert.equal(pkg.status, "candidate");
    assert.ok(pkg.blockers.length > 0);
    assert.equal(pkg.deployment.blockNumber, null);
    assert.equal(pkg.deployment.eventStartCursor.blockNumber, null);
  });

  it("positive: packageChecksum and releaseId recompute from the committed bytes", () => {
    const pkg = readPackage();
    assert.equal(computeReleaseId(pkg), pkg.releaseId);
    assert.equal(computePackageChecksum(pkg), pkg.packageChecksum);
  });

  it("positive: no secret material is embedded", () => {
    assert.deepEqual(findSecretLeaks(readPackage()), []);
  });
});

describe("STAB-SC-007 release package — consumers", () => {
  it("positive: API and frontend consume the identical release ID and checksum", () => {
    const result = assertConsumersAgree({ rootDir: REPO_ROOT, allowCandidate: true });
    const pkg = readPackage();
    assert.equal(result.releaseId, pkg.releaseId);
    assert.equal(result.packageChecksum, pkg.packageChecksum);
    assert.ok(Object.keys(result.addresses).length >= 8);
  });

  it("positive: both consumer profiles resolve every required contract", () => {
    const api = loadReleasePackageForConsumer("api", { rootDir: REPO_ROOT, allowCandidate: true });
    const frontend = loadReleasePackageForConsumer("frontend", { rootDir: REPO_ROOT, allowCandidate: true });
    assert.ok(Object.keys(api.addresses).length > 0);
    assert.ok(Object.keys(frontend.addresses).length > 0);
    for (const [name, address] of Object.entries(frontend.addresses)) {
      const match = api.contracts.find((contract) => contract.name === name);
      assert.ok(match, `api missing ${name}`);
      assert.equal(match.address.toLowerCase(), address.toLowerCase());
    }
  });

  it("negative: consumers refuse an unpublished candidate by default", () => {
    assert.throws(
      () => loadReleasePackageForConsumer("api", { rootDir: REPO_ROOT }),
      /status is candidate/,
    );
  });

  it("negative: consumers refuse a tampered manifest", () => {
    const { dir, pkg } = tempRepo();
    pkg.contracts[0].address = "0x00000000000000000000000000000000000000aa";
    writePackage(dir, pkg);
    assert.throws(
      () => loadReleasePackageForConsumer("api", { rootDir: dir, allowCandidate: true }),
      /checksum mismatch|release ID mismatch/,
    );
    rmSync(dir, { recursive: true, force: true });
  });

  it("negative: a consumer block pinning another release fails closed", () => {
    const pkg = reseal(readPackage());
    pkg.consumers.frontend.releaseId = `0x${"11".repeat(32)}`;
    const problems = problemsFor(pkg);
    assert.ok(hasProblem(problems, /frontend\.releaseId must equal the package releaseId/));
  });
});

describe("STAB-SC-007 release package — chain, toolchain and identity drift", () => {
  it("negative: wrong chain id is rejected", () => {
    const pkg = readPackage();
    pkg.network.chainId = 10;
    const problems = problemsFor(pkg);
    assert.ok(hasProblem(problems, /chain drift: chainId 10 != 11155420/));
  });

  it("negative: a non-Optimism-Sepolia explorer is rejected", () => {
    const pkg = readPackage();
    pkg.network.explorerBase = "https://etherscan.io";
    assert.ok(hasProblem(problemsFor(pkg), /explorerBase must be/));
  });

  it("negative: toolchain drift in hardhat.config.ts is rejected", () => {
    const { dir } = tempRepo();
    const config = readFileSync(join(dir, "hardhat.config.ts"), "utf8");
    writeFileSync(join(dir, "hardhat.config.ts"), config.replace('version: "0.8.28"', 'version: "0.8.27"'));
    const problems = validateReleasePackage(readPackage(dir), { rootDir: dir });
    assert.ok(hasProblem(problems, /hardhat solidity 0\.8\.27/));
    rmSync(dir, { recursive: true, force: true });
  });

  it("negative: a non-cancun EVM version is rejected by release policy", () => {
    const pkg = readPackage();
    pkg.toolchain.evmVersion = "prague";
    assert.ok(hasProblem(problemsFor(pkg), /evmVersion must be cancun|hardhat evmVersion/));
  });

  it("negative: a mutated release ID is rejected", () => {
    const pkg = readPackage();
    pkg.releaseId = `0x${"22".repeat(32)}`;
    assert.ok(hasProblem(problemsFor(pkg), /releaseId drift/));
  });

  it("negative: a mutated package checksum is rejected", () => {
    const pkg = readPackage();
    mutatePackageChecksum(pkg);
    assert.ok(hasProblem(problemsFor(pkg), /packageChecksum drift/));
  });

  it("positive: the release ID survives promotion (evidence only changes)", () => {
    const pkg = readPackage();
    const before = computeReleaseId(pkg);
    pkg.status = "published";
    pkg.evidenceClass = "optimism-sepolia";
    pkg.deployment.blockNumber = 50_300_000;
    pkg.deployment.blockHash = `0x${"ab".repeat(32)}`;
    pkg.deployment.timestamp = 1_792_300_000;
    pkg.deployment.eventStartCursor = { ...pkg.deployment.eventStartCursor, blockNumber: 50_300_000, blockHash: `0x${"ab".repeat(32)}` };
    assert.equal(computeReleaseId(pkg), before);
  });
});

function mutatePackageChecksum(pkg) {
  pkg.packageChecksum = `sha256:${"00".repeat(32)}`;
}

describe("STAB-SC-007 release package — artifact drift", () => {
  it("negative: ABI drift is rejected", () => {
    const pkg = readPackage();
    pkg.contracts[0].artifact.abiSha256 = `0x${"33".repeat(32)}`;
    assert.ok(hasProblem(problemsFor(pkg), /ABI checksum drift/));
  });

  it("negative: ABI file drift on disk is rejected", () => {
    const { dir } = tempRepo();
    const pkg = readPackage(dir);
    const abiPath = join(dir, pkg.contracts[0].artifact.abiFile);
    const abi = JSON.parse(readFileSync(abiPath, "utf8"));
    abi.push({ type: "function", name: "injected", inputs: [], outputs: [], stateMutability: "view" });
    writeFileSync(abiPath, `${JSON.stringify(abi, null, 2)}\n`);
    assert.ok(hasProblem(validateReleasePackage(pkg, { rootDir: dir }), /ABI file drift/));
    rmSync(dir, { recursive: true, force: true });
  });

  it("negative: bytecode checksum drift is rejected", () => {
    const pkg = readPackage();
    pkg.contracts[1].artifact.bytecodeKeccak = `0x${"44".repeat(32)}`;
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /artifact pin drift on bytecodeKeccak|bytecode drift/));
  });

  it("negative: deployed bytecode checksum drift is rejected", () => {
    const pkg = readPackage();
    pkg.contracts[1].artifact.deployedBytecodeKeccak = `0x${"45".repeat(32)}`;
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /artifact pin drift on deployedBytecodeKeccak|deployedBytecode drift/));
  });

  it("negative: constructor argument mutation breaks the address binding", () => {
    const pkg = readPackage();
    pkg.contracts[2].deployment.constructorArgs[3] = "123";
    const problems = problemsFor(pkg);
    assert.ok(hasProblem(problems, /constructorArgsSha256 mismatch|address .* != CREATE2/));
  });

  it("negative: init code hash mutation breaks the CREATE2 derivation", () => {
    const pkg = readPackage();
    pkg.contracts[0].deployment.initCodeHash = `0x${"55".repeat(32)}`;
    assert.ok(hasProblem(problemsFor(pkg), /!= CREATE2/));
  });

  it("negative: an EIP-170 oversized runtime is rejected", () => {
    const pkg = readPackage();
    pkg.contracts[0].artifact.runtimeBytes = 24_577;
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /EIP-170/));
  });

  it("negative: unresolved library links are rejected", () => {
    const pkg = readPackage();
    pkg.contracts[0].artifact.linkReferences = 1;
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /link no libraries/));
  });

  it("negative: source drift is rejected", () => {
    const { dir } = tempRepo();
    const source = readPackage(dir).contracts[0].source;
    writeFileSync(join(dir, source), `${readFileSync(join(dir, source), "utf8")}\n// drift\n`);
    assert.ok(hasProblem(validateReleasePackage(readPackage(dir), { rootDir: dir }), /source drift/));
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("STAB-SC-007 release package — address hygiene", () => {
  it("negative: placeholder/burn addresses are rejected", () => {
    const pkg = readPackage();
    pkg.contracts[0].address = "0x000000000000000000000000000000000000dead";
    assert.ok(hasProblem(problemsFor(pkg), /placeholder\/burn address/));
  });

  it("negative: local framework fixture addresses are rejected", () => {
    const pkg = readPackage();
    pkg.contracts[0].address = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
    assert.ok(hasProblem(problemsFor(pkg), /local framework fixture/));
  });

  it("negative: duplicate addresses are rejected", () => {
    const pkg = readPackage();
    pkg.contracts[1].address = pkg.contracts[0].address;
    assert.ok(hasProblem(problemsFor(pkg), /duplicate address/));
  });

  it("negative: a wrong-interface/unknown contract source is rejected", () => {
    const pkg = readPackage();
    pkg.contracts[0].source = "contracts/Nowhere.sol";
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /source missing|source must be/));
  });

  it("positive: addresses are the CREATE2 of the reviewed factory, salt and init code", () => {
    const pkg = readPackage();
    for (const contract of pkg.contracts) {
      const salt = deriveSalt(pkg.deterministicDeployment.saltDomain, contract.name);
      assert.equal(salt, contract.deployment.salt);
      assert.equal(
        deriveCreate2Address(pkg.deterministicDeployment.factory.address, salt, contract.deployment.initCodeHash),
        contract.address.toLowerCase(),
      );
    }
  });
});

describe("STAB-SC-007 release package — roles and finalization", () => {
  it("negative: a role granted to the bootstrap admin is rejected", () => {
    const pkg = readPackage();
    pkg.roleGrants[0].holder = {
      ...pkg.roleGrants[0].holder,
      address: pkg.deterministicDeployment.bootstrapAdmin.address,
    };
    assert.ok(hasProblem(problemsFor(pkg), /retains authority after finalization/));
  });

  it("negative: a missing role class is rejected", () => {
    const pkg = readPackage();
    pkg.roleOwnership = pkg.roleOwnership.filter((entry) => entry.class !== "treasury");
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /missing required class: treasury/));
  });

  it("negative: a finalization plan without renunciation is rejected", () => {
    const pkg = readPackage();
    pkg.finalization.steps = pkg.finalization.steps.filter((step) => step.action !== "renounce");
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /renounce bootstrap authority|does not renounce/));
  });

  it("negative: deployerAuthorityRemoved=false is rejected", () => {
    const pkg = readPackage();
    pkg.finalization.deployerAuthorityRemoved = false;
    assert.ok(hasProblem(problemsFor(pkg), /deployerAuthorityRemoved must be true/));
  });

  it("negative: a role hash that does not match its name is rejected", () => {
    const pkg = readPackage();
    pkg.roleGrants[0].roleHash = keccakUtf8("SOMETHING_ELSE");
    assert.ok(hasProblem(problemsFor(pkg), /role hash drift/));
  });
});

describe("STAB-SC-007 release package — deployment block and event cursor", () => {
  it("negative: a candidate package may not claim a deployment block", () => {
    const pkg = readPackage();
    pkg.deployment.blockNumber = 50_000_000;
    assert.ok(hasProblem(problemsFor(pkg), /must not claim a deployment block/));
  });

  it("negative: a published package without block evidence is rejected", () => {
    const pkg = readPackage();
    pkg.status = "published";
    pkg.evidenceClass = "optimism-sepolia";
    const problems = problemsFor(pkg);
    assert.ok(hasProblem(problems, /positive deployment\.blockNumber|on-chain verification evidence/));
  });

  it("negative: an event cursor that disagrees with the deployment block is rejected", () => {
    const pkg = publishablePackage();
    pkg.deployment.eventStartCursor = { blockNumber: 50_000_001, blockHash: pkg.deployment.blockHash };
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /eventStartCursor\.blockNumber must equal/));
  });

  it("negative: a cursor block hash that disagrees with the block is rejected", () => {
    const pkg = publishablePackage();
    pkg.deployment.eventStartCursor = { blockNumber: pkg.deployment.blockNumber, blockHash: `0x${"99".repeat(32)}` };
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /eventStartCursor\.blockHash must equal/));
  });

  it("negative: a deployment block preceding a contract block is rejected", () => {
    const pkg = publishablePackage();
    pkg.deployment.eventStartCursor = { blockNumber: pkg.deployment.blockNumber, blockHash: pkg.deployment.blockHash };
    pkg.contracts[0].deployment.deploymentBlock = pkg.deployment.blockNumber + 5;
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /precedes a contract deployment block/));
  });

  it("positive: a fully evidenced published package validates", () => {
    assert.deepEqual(problemsFor(publishablePackage()), []);
  });
});

function publishablePackage() {
  const pkg = readPackage();
  pkg.status = "published";
  pkg.evidenceClass = "optimism-sepolia";
  pkg.blockers = [];
  const blockNumber = 50_300_000;
  const blockHash = `0x${"ab".repeat(32)}`;
  pkg.deployment = {
    ...pkg.deployment,
    blockNumber,
    blockHash,
    timestamp: 1_792_300_000,
    eventStartCursor: { blockNumber, blockHash },
  };
  pkg.verification.explorer = { ...pkg.verification.explorer, status: "verified", verifiedCount: pkg.contracts.length };
  pkg.verification.onchain = { ...pkg.verification.onchain, status: "verified", codeChecks: pkg.contracts.length };
  for (const entry of pkg.roleOwnership) entry.holder = { ...entry.holder, custody: "assigned", label: "op-sepolia-owner" };
  for (const grant of pkg.roleGrants) {
    if (grant.holder.custody === "unassigned") grant.holder = { ...grant.holder, custody: "assigned" };
  }
  pkg.deterministicDeployment.bootstrapAdmin = { ...pkg.deterministicDeployment.bootstrapAdmin, custody: "assigned" };
  for (const contract of pkg.contracts) {
    contract.deployment = { ...contract.deployment, deploymentBlock: blockNumber - 3, txHash: `0x${"cd".repeat(32)}` };
    contract.sourceVerification = {
      ...contract.sourceVerification,
      status: "verified",
      url: `https://sepolia-optimism.etherscan.io/address/${contract.address}#code`,
    };
    contract.onchain = { codePresent: true, observedCodeHash: contract.artifact.deployedBytecodeKeccak, checkedAtBlock: blockNumber };
  }
  return reseal(pkg);
}

describe("STAB-SC-007 release package — commands, rollback and secrets", () => {
  it("negative: an embedded private key is rejected", () => {
    const pkg = readPackage();
    pkg.commands.deploy = "npx hardhat run scripts/deploy.ts --private-key 0x" + "ab".repeat(32);
    const problems = problemsFor(reseal(pkg));
    assert.ok(hasProblem(problems, /secret material assignment|embedded 32-byte hex/));
  });

  it("negative: an API-key-shaped token is rejected", () => {
    const pkg = readPackage();
    pkg.commands.verify = "ETHERSCAN=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456 npx hardhat verify";
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /API-key-shaped token/));
  });

  it("negative: missing rollback/recovery notes are rejected", () => {
    const pkg = readPackage();
    delete pkg.rollback.recovery;
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /rollback\.recovery is required/));
  });

  it("negative: a deployment command that is not pinned to optimismSepolia is rejected", () => {
    const pkg = readPackage();
    pkg.commands.deploy = "npx hardhat run scripts/deploy.ts --network mainnet";
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /must target the optimismSepolia network/));
  });

  it("negative: a reproduction command without a clean environment is rejected", () => {
    const pkg = readPackage();
    pkg.commands.reproduce = "forge build";
    assert.ok(hasProblem(problemsFor(reseal(pkg)), /must run from a clean environment/));
  });
});

describe("STAB-SC-007 release package — deterministic generation", () => {
  it("positive: two builds of the same inputs are byte-identical", { skip: SKIP_BUILD }, () => {
    const definition = JSON.parse(readFileSync(join(REPO_ROOT, "config/optimism-sepolia-release.json"), "utf8"));
    const first = buildReleasePackage({ rootDir: REPO_ROOT, definition, artifacts: BUILD }).package;
    const second = buildReleasePackage({ rootDir: REPO_ROOT, definition, artifacts: BUILD }).package;
    assert.equal(`${JSON.stringify(first, null, 2)}\n`, `${JSON.stringify(second, null, 2)}\n`);
  });

  it("positive: regeneration reproduces the committed package exactly", { skip: SKIP_BUILD }, () => {
    const definition = JSON.parse(readFileSync(join(REPO_ROOT, "config/optimism-sepolia-release.json"), "utf8"));
    const { package: regenerated } = buildReleasePackage({ rootDir: REPO_ROOT, definition, artifacts: BUILD });
    assert.equal(`${JSON.stringify(regenerated, null, 2)}\n`, readFileSync(join(REPO_ROOT, RELEASE_MANIFEST_PATH), "utf8"));
  });

  it("positive: artifact-pins.json is reproducible from the build", { skip: SKIP_BUILD }, () => {
    const pins = JSON.parse(readFileSync(join(REPO_ROOT, RELEASE_ARTIFACT_PINS_PATH), "utf8"));
    const pkg = readPackage();
    for (const contract of pkg.contracts) {
      const pinned = pins.contracts[contract.name];
      assert.ok(pinned, `missing pin for ${contract.name}`);
      assert.equal(pinned.bytecodeKeccak, contract.artifact.bytecodeKeccak);
      assert.equal(pinned.deployedBytecodeKeccak, contract.artifact.deployedBytecodeKeccak);
      assert.equal(pinned.immutableSlots, contract.artifact.immutableSlots);
    }
  });

  it("positive: rebuilt artifacts match every pinned checksum", { skip: SKIP_BUILD }, () => {
    const problems = validateReleasePackage(readPackage(), {
      rootDir: REPO_ROOT,
      withArtifacts: true,
      artifactPreference: "hardhat",
    });
    assert.deepEqual(problems, []);
  });

  it("negative: a stale build is detected by --with-artifacts", { skip: SKIP_BUILD }, () => {
    const pkg = readPackage();
    pkg.contracts[0].artifact.bytecodeKeccak = `0x${"77".repeat(32)}`;
    const problems = validateReleasePackage(reseal(pkg), {
      rootDir: REPO_ROOT,
      withArtifacts: true,
      artifactPreference: "hardhat",
    });
    assert.ok(hasProblem(problems, /bytecode drift/));
  });
});

describe("STAB-SC-007 release package — ABI encoding and CREATE2", () => {
  it("positive: ABI encoder matches the canonical static encoding", () => {
    const encoded = encodeAbiParameters(
      [{ type: "uint256" }, { type: "address" }, { type: "bool" }],
      ["1", "0x00000000000000000000000000000000000000ff", true],
    );
    assert.equal(
      encoded,
      "0x" +
        "0000000000000000000000000000000000000000000000000000000000000001" +
        "00000000000000000000000000000000000000000000000000000000000000ff" +
        "0000000000000000000000000000000000000000000000000000000000000001",
    );
  });

  it("positive: ABI encoder handles static tuples positionally by name", () => {
    const encoded = encodeAbiParameters(
      [
        {
          type: "tuple",
          components: [
            { name: "chainId", type: "uint64" },
            { name: "flag", type: "bool" },
          ],
        },
      ],
      [{ chainId: "11155420", flag: true }],
    );
    assert.equal(
      encoded,
      "0x" +
        "0000000000000000000000000000000000000000000000000000000000aa37dc" +
        "0000000000000000000000000000000000000000000000000000000000000001",
    );
  });

  it("negative: ABI encoder rejects arity and range violations", () => {
    assert.throws(() => encodeAbiParameters([{ type: "uint256" }], []), /arity mismatch/);
    assert.throws(() => encodeAbiParameters([{ type: "uint8" }], ["256"]), /out of range/);
    assert.throws(() => encodeAbiParameters([{ type: "address" }], ["0x1234"]), /invalid address/);
  });

  it("positive: CREATE2 derivation is deterministic and salt-domain separated", () => {
    const factory = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
    const saltA = deriveSalt("domain-a", "ModuleRegistry");
    const saltB = deriveSalt("domain-b", "ModuleRegistry");
    assert.notEqual(saltA, saltB);
    assert.equal(deriveSalt("domain-a", "ModuleRegistry"), saltA);
    const initCodeHash = keccakUtf8("init-code");
    const address = deriveCreate2Address(factory, saltA, initCodeHash);
    assert.match(address, /^0x[0-9a-f]{40}$/);
    assert.equal(deriveCreate2Address(factory, saltA, initCodeHash), address);
  });

  it("positive: source sha256 pins match the files on disk", () => {
    for (const contract of readPackage().contracts) {
      assert.equal(contract.sourceSha256, sha256FileHex(join(REPO_ROOT, contract.source)));
    }
  });
});

describe("STAB-SC-007 release package — on-chain verification", () => {
  after(() => {
    if (originalFetch !== null) globalThis.fetch = originalFetch;
    originalFetch = null;
  });

  it("negative: a chain-id mismatch fails closed", async () => {
    const pkg = readPackage();
    stubRpc({ eth_chainId: () => "0xa" });
    const { problems } = await verifyOnchain(pkg, "http://stub.invalid");
    assert.ok(hasProblem(problems, /RPC chain id 10 != package chain id 11155420/));
  });

  it("negative: an address without code (EOA) fails closed", async () => {
    const pkg = readPackage();
    stubRpc({ eth_chainId: () => "0xaa37dc", eth_getCode: () => "0x" });
    const { problems } = await verifyOnchain(pkg, "http://stub.invalid");
    assert.ok(hasProblem(problems, /no code at/));
  });

  it("negative: a runtime length mismatch fails closed", async () => {
    const pkg = readPackage();
    stubRpc({ eth_chainId: () => "0xaa37dc", eth_getCode: () => "0x6000" });
    const { problems } = await verifyOnchain(pkg, "http://stub.invalid");
    assert.ok(hasProblem(problems, /runtime length/));
  });

  it("positive: exact code length and hashes verify for an immutable-free contract", async () => {
    const code = "0x6001600055";
    const factoryCode = "0x60006000f3";
    const pkg = {
      network: { chainId: 11155420 },
      deployment: { blockNumber: null },
      deterministicDeployment: {
        factory: { address: "0x00000000000000000000000000000000000000f4", codeHash: keccakHex(factoryCode) },
      },
      status: "candidate",
      contracts: [
        {
          name: "Synthetic",
          address: "0x00000000000000000000000000000000000000aa",
          artifact: { runtimeBytes: (code.length - 2) / 2, immutableSlots: 0, deployedBytecodeKeccak: keccakHex(code) },
        },
      ],
    };
    stubRpc({
      eth_chainId: () => "0xaa37dc",
      eth_getCode: () => code,
      "eth_getCode:0x00000000000000000000000000000000000000f4": () => factoryCode,
    });
    const { problems, observations } = await verifyOnchain(pkg, "http://stub.invalid");
    assert.deepEqual(problems, []);
    assert.equal(observations.contracts.Synthetic.codePresent, true);
    assert.equal(observations.factory.codeHash, keccakHex(factoryCode));
  });

  it("negative: a CREATE2 factory whose code hash drifted fails closed", async () => {
    const code = "0x6001600055";
    const pkg = {
      network: { chainId: 11155420 },
      deployment: { blockNumber: null },
      deterministicDeployment: {
        factory: { address: "0x00000000000000000000000000000000000000f4", codeHash: keccakUtf8("other-factory") },
      },
      status: "candidate",
      contracts: [
        {
          name: "Synthetic",
          address: "0x00000000000000000000000000000000000000aa",
          artifact: { runtimeBytes: 5, immutableSlots: 0, deployedBytecodeKeccak: keccakHex(code) },
        },
      ],
    };
    stubRpc({ eth_chainId: () => "0xaa37dc", eth_getCode: () => code });
    const { problems } = await verifyOnchain(pkg, "http://stub.invalid");
    assert.ok(hasProblem(problems, /CREATE2 factory code hash .* != pinned/));
  });

  it("negative: a factory without code fails closed", async () => {
    const pkg = {
      network: { chainId: 11155420 },
      deployment: { blockNumber: null },
      deterministicDeployment: {
        factory: { address: "0x00000000000000000000000000000000000000f4", codeHash: keccakUtf8("factory") },
      },
      status: "candidate",
      contracts: [],
    };
    stubRpc({ eth_chainId: () => "0xaa37dc", eth_getCode: () => "0x" });
    const { problems } = await verifyOnchain(pkg, "http://stub.invalid");
    assert.ok(hasProblem(problems, /CREATE2 factory .* has no code/));
  });

  it("negative: a package without a pinned factory fails closed", async () => {
    const { problems } = await verifyOnchain(
      { network: { chainId: 11155420 }, deployment: { blockNumber: null }, status: "candidate", contracts: [] },
      "http://stub.invalid",
    );
    assert.ok(hasProblem(problems, /does not pin a CREATE2 factory/));
  });

  it("negative: a reference block the chain does not agree with fails closed", async () => {
    const pkg = {
      network: { chainId: 11155420 },
      deployment: {
        blockNumber: null,
        referenceBlock: { number: 50_207_495, hash: `0x${"11".repeat(32)}`, chainId: 11155420 },
      },
      deterministicDeployment: {
        factory: { address: "0x00000000000000000000000000000000000000f4", codeHash: keccakHex("0x60006000f3") },
      },
      status: "candidate",
      contracts: [],
    };
    stubRpc({
      eth_chainId: () => "0xaa37dc",
      eth_getCode: () => "0x60006000f3",
      eth_getBlockByNumber: () => ({ number: "0x2fe3b4f", hash: `0x${"22".repeat(32)}` }),
    });
    const { problems } = await verifyOnchain(pkg, "http://stub.invalid");
    assert.ok(hasProblem(problems, /reference block hash .* != pinned/));
  });

  it("negative: an on-chain hash mismatch fails closed", async () => {
    const code = "0x6001600055";
    const pkg = {
      network: { chainId: 11155420 },
      deployment: { blockNumber: null },
      deterministicDeployment: {
        factory: { address: "0x00000000000000000000000000000000000000f4", codeHash: keccakHex(code) },
      },
      status: "candidate",
      contracts: [
        {
          name: "Synthetic",
          address: "0x00000000000000000000000000000000000000aa",
          artifact: { runtimeBytes: 5, immutableSlots: 0, deployedBytecodeKeccak: keccakUtf8("other") },
        },
      ],
    };
    stubRpc({ eth_chainId: () => "0xaa37dc", eth_getCode: () => code });
    const { problems } = await verifyOnchain(pkg, "http://stub.invalid");
    assert.ok(hasProblem(problems, /on-chain runtime code hash/));
  });
});

function stubRpc(handlers) {
  if (originalFetch === null) originalFetch = globalThis.fetch;
  globalThis.fetch = async (_url, init) => {
    const { method, params } = JSON.parse(init.body);
    const handler = handlers[`${method}:${params?.[0]}`] ?? handlers[method];
    const result = handler ? handler() : null;
    return { ok: true, json: async () => ({ result }) };
  };
}

describe("STAB-SC-007 release package — publication guard", () => {
  it("negative: promotion refuses unassigned custody even with full evidence", () => {
    const { dir } = tempRepo();
    writeFileSync(
      join(dir, "deployments/releases/optimism-sepolia/deployment-evidence.json"),
      JSON.stringify({
        releaseId: readPackage(dir).releaseId,
        chainId: 11155420,
        blockNumber: 50_300_000,
        blockHash: `0x${"ab".repeat(32)}`,
        timestamp: 1_792_300_000,
        contracts: readPackage(dir).contracts.map((contract) => ({
          name: contract.name,
          address: contract.address,
          txHash: `0x${"cd".repeat(32)}`,
          blockNumber: 50_299_999,
        })),
      }),
    );
    writeFileSync(
      join(dir, "deployments/releases/optimism-sepolia/verification-report.json"),
      JSON.stringify({
        releaseId: readPackage(dir).releaseId,
        contracts: readPackage(dir).contracts.map((contract) => ({
          name: contract.name,
          address: contract.address,
          status: "verified",
        })),
      }),
    );
    const result = spawnSync(
      process.execPath,
      [join(REPO_ROOT, "scripts/generateOptimismSepoliaReleasePackage.mjs"), "--promote"],
      { env: { ...process.env, RELEASE_REPO_ROOT: dir }, encoding: "utf8" },
    );
    assert.equal(result.status, 1);
    assert.match(result.stderr, /custody slots are unassigned/);
    rmSync(dir, { recursive: true, force: true });
  });

  it("negative: the offline gate rejects a tampered committed manifest", () => {
    const { dir } = tempRepo((pkg) => {
      pkg.contracts[0].artifact.bytecodeKeccak = `0x${"66".repeat(32)}`;
    });
    const result = spawnSync(
      process.execPath,
      [join(REPO_ROOT, "scripts/check-optimism-sepolia-release.mjs")],
      { env: { ...process.env, RELEASE_REPO_ROOT: dir }, encoding: "utf8" },
    );
    assert.equal(result.status, 1);
    assert.match(result.stdout + result.stderr, /artifact pin drift|releaseId drift|release\.sha256 mismatch/);
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("STAB-SC-007 release package — repository hygiene", () => {
  it("positive: the stale legacy manifest is not consumed by the release package", () => {
    const pkg = readPackage();
    assert.ok(!JSON.stringify(pkg).includes("v2-sc-129-release-manifest"));
  });

  it("positive: the release manifest is byte-stable under repeated writes", () => {
    const bytes = readFileSync(join(REPO_ROOT, RELEASE_MANIFEST_PATH));
    const pkg = JSON.parse(bytes.toString("utf8"));
    assert.equal(`${JSON.stringify(pkg, null, 2)}\n`, bytes.toString("utf8"));
  });

  it("positive: the committed package is smaller than the repository file-size guard", () => {
    const bytes = readFileSync(join(REPO_ROOT, RELEASE_MANIFEST_PATH));
    assert.ok(bytes.length < 512 * 1024, `manifest is unexpectedly large: ${bytes.length} bytes`);
  });
});
