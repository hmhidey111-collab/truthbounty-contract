import { expect } from "chai";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import {
  generateContractReleaseSbom,
  parseHardhatCompiler,
  assertValidSourceCommit,
  assertNoForbiddenRuntimeDeps,
  collectFoundryLockDeps,
  readWorkflowIdentity,
  hashArtifacts,
  SbomError,
  CANONICAL_RELEASE_SOURCES,
  PREDICATE_TYPE,
} from "../scripts/generateContractReleaseSbom";

const VALID_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

function makeFixture(overrides?: {
  hardhat?: string;
  packageJson?: Record<string, unknown>;
  foundryLock?: string | null;
  includeSources?: boolean;
}): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tb-sbom-"));
  const pkg = overrides?.packageJson || {
    name: "truth_bounty_contracts",
    version: "2.0.0-rc.1",
    dependencies: {
      "@openzeppelin/contracts": "^5.0.0",
      dotenv: "^16.0.0",
    },
    devDependencies: {
      hardhat: "^2.22.0",
    },
  };
  fs.writeFileSync(path.join(dir, "package.json"), JSON.stringify(pkg, null, 2));
  fs.writeFileSync(
    path.join(dir, "package-lock.json"),
    JSON.stringify({ name: "truth_bounty_contracts", lockfileVersion: 3 }, null, 2)
  );
  const hardhat =
    overrides?.hardhat ||
    `
import { HardhatUserConfig } from "hardhat/config";
const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      evmVersion: "cancun",
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
};
export default config;
`;
  fs.writeFileSync(path.join(dir, "hardhat.config.ts"), hardhat);
  fs.writeFileSync(
    path.join(dir, "foundry.toml"),
    `[profile.default]\noptimizer = true\noptimizer_runs = 200\n`
  );
  if (overrides?.foundryLock !== null) {
    fs.writeFileSync(
      path.join(dir, "foundry.lock"),
      overrides?.foundryLock ||
        JSON.stringify(
          {
            "lib/forge-std": { rev: "b3bc8b154382a75d0b0ef22d7fd4a0a5f0feee0e" },
            "lib/openzeppelin-contracts": {
              rev: "74edc4baff50b93c06977021ee9ba25987803291",
            },
          },
          null,
          2
        )
    );
  }
  if (overrides?.includeSources !== false) {
    fs.mkdirSync(path.join(dir, "contracts"), { recursive: true });
    for (const rel of CANONICAL_RELEASE_SOURCES) {
      if (!rel.startsWith("contracts/")) continue;
      fs.writeFileSync(path.join(dir, rel), `// fixture ${rel}\n`);
    }
  }
  return dir;
}

describe("Contract Release SBOM and Provenance (V2-SC-088)", function () {
  it("generates SBOM with compiler, deps, source commit, artifact hashes, workflow identity", function () {
    const root = makeFixture();
    const sbom = generateContractReleaseSbom({
      rootDir: root,
      sourceCommit: VALID_SHA,
      releaseVersion: "2.0.0-rc.1",
      env: {
        GITHUB_REPOSITORY: "DigiNodes/truthbounty-contract",
        GITHUB_WORKFLOW: "Release Candidate",
        GITHUB_RUN_ID: "12345",
        GITHUB_RUN_ATTEMPT: "1",
        GITHUB_REF: "refs/tags/v2.0.0-rc.1",
        GITHUB_SHA: VALID_SHA,
        GITHUB_WORKFLOW_REF:
          "DigiNodes/truthbounty-contract/.github/workflows/release.yml@refs/heads/main",
        GITHUB_SERVER_URL: "https://github.com",
      },
      now: new Date("2026-09-24T00:00:00.000Z"),
    });

    expect(sbom.schemaVersion).to.equal(1);
    expect(sbom.kind).to.equal("truthbounty.contract-release-sbom+provenance");
    expect(sbom.sourceCommit).to.equal(VALID_SHA);
    expect(sbom.compiler.solidity).to.equal("0.8.28");
    expect(sbom.compiler.optimizer.enabled).to.equal(true);
    expect(sbom.compiler.optimizer.runs).to.equal(200);
    expect(sbom.compiler.viaIR).to.equal(true);
    expect(sbom.dependencies.some((d) => d.name === "@openzeppelin/contracts")).to.equal(
      true
    );
    expect(sbom.dependencies.some((d) => d.kind === "git-submodule")).to.equal(true);
    expect(sbom.artifacts.length).to.be.greaterThan(3);
    expect(sbom.workflowIdentity.present).to.equal(true);
    expect(sbom.workflowIdentity.runId).to.equal("12345");
    expect(sbom.attestation.predicateType).to.equal(PREDICATE_TYPE);
    expect(sbom.attestation.subjects.length).to.equal(sbom.artifacts.length);
    expect(sbom.checksum).to.match(/^[0-9a-f]{64}$/);
  });

  it("is deterministic for identical inputs", function () {
    const root = makeFixture();
    const opts = {
      rootDir: root,
      sourceCommit: VALID_SHA,
      releaseVersion: "2.0.0-rc.1",
      env: {},
      now: new Date("2026-09-24T00:00:00.000Z"),
    };
    const a = generateContractReleaseSbom(opts);
    const b = generateContractReleaseSbom(opts);
    expect(a.checksum).to.equal(b.checksum);
    expect(a.artifacts).to.deep.equal(b.artifacts);
  });

  it("fails closed on invalid source commit", function () {
    expect(() => assertValidSourceCommit("abc")).to.throw(SbomError);
    expect(() => assertValidSourceCommit("")).to.throw(SbomError);
    const root = makeFixture();
    expect(() =>
      generateContractReleaseSbom({ rootDir: root, sourceCommit: "not-a-sha", env: {} })
    ).to.throw(SbomError);
  });

  it("fails closed when optimizer enabled without positive runs", function () {
    expect(() =>
      parseHardhatCompiler(`
        solidity: {
          version: "0.8.28",
          settings: { optimizer: { enabled: true, runs: 0 } }
        }
      `)
    ).to.throw(SbomError);
  });

  it("fails closed on missing solidity version", function () {
    expect(() => parseHardhatCompiler("const config = {}")).to.throw(SbomError);
  });

  it("fails closed on Stellar/Soroban/Freighter runtime dependencies", function () {
    expect(() =>
      assertNoForbiddenRuntimeDeps({
        dependencies: { "@stellar/stellar-sdk": "12.0.0" },
      })
    ).to.throw(SbomError);
    expect(() =>
      assertNoForbiddenRuntimeDeps({
        dependencies: { "soroban-client": "1.0.0" },
      })
    ).to.throw(SbomError);
    const root = makeFixture({
      packageJson: {
        name: "truth_bounty_contracts",
        version: "2.0.0-rc.1",
        dependencies: { freighter-api: "1.0.0" },
      },
    });
    expect(() =>
      generateContractReleaseSbom({
        rootDir: root,
        sourceCommit: VALID_SHA,
        env: {},
      })
    ).to.throw(SbomError);
  });

  it("fails closed on incomplete workflow identity", function () {
    expect(() =>
      readWorkflowIdentity({ GITHUB_REPOSITORY: "DigiNodes/truthbounty-contract" })
    ).to.throw(SbomError);
  });

  it("allows absent workflow identity for local generation", function () {
    const id = readWorkflowIdentity({});
    expect(id.present).to.equal(false);
  });

  it("fails closed when GITHUB_SHA mismatches sourceCommit", function () {
    const root = makeFixture();
    expect(() =>
      generateContractReleaseSbom({
        rootDir: root,
        sourceCommit: VALID_SHA,
        env: {
          GITHUB_REPOSITORY: "DigiNodes/truthbounty-contract",
          GITHUB_WORKFLOW: "CI",
          GITHUB_RUN_ID: "9",
          GITHUB_SHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        },
      })
    ).to.throw(SbomError);
  });

  it("fails closed on path traversal in artifact hashing", function () {
    const root = makeFixture();
    expect(() => hashArtifacts(root, ["../etc/passwd"])).to.throw(SbomError);
  });

  it("fails closed on invalid foundry.lock rev", function () {
    expect(() =>
      collectFoundryLockDeps(JSON.stringify({ "lib/x": { rev: "NOT_HEX" } }))
    ).to.throw(SbomError);
  });

  it("fails closed when releaseVersion is missing or placeholder", function () {
    const root = makeFixture({
      packageJson: {
        name: "truth_bounty_contracts",
        version: "0.0.0",
        dependencies: {},
      },
    });
    expect(() =>
      generateContractReleaseSbom({
        rootDir: root,
        sourceCommit: VALID_SHA,
        env: {},
      })
    ).to.throw(SbomError);
  });

  it("hashes only existing canonical sources without requiring full forge build", function () {
    const root = makeFixture({ includeSources: false });
    const sbom = generateContractReleaseSbom({
      rootDir: root,
      sourceCommit: VALID_SHA,
      releaseVersion: "2.0.0-rc.1",
      env: {},
    });
    expect(sbom.artifacts.some((a) => a.path === "package.json")).to.equal(true);
    expect(sbom.artifacts.some((a) => a.path === "hardhat.config.ts")).to.equal(true);
    expect(sbom.artifacts.every((a) => /^[0-9a-f]{64}$/.test(a.sha256))).to.equal(true);
  });
});
