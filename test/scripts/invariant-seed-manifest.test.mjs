/**
 * @file invariant-seed-manifest.test.mjs
 * @description Unit tests for deterministic invariant seed publication and reproduction.
 *
 * The manifest is the contract between a recorded invariant failure and the
 * engineer who has to reproduce it later. These tests pin the properties that
 * make a seed trustworthy: every entry carries its toolchain, commit, campaign
 * configuration and one-command reproduction, the recorded command matches the
 * command the tooling would generate, the referenced sequence exists on disk,
 * and any malformed or missing metadata fails closed instead of replaying a
 * seed under the wrong conditions.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  MANIFEST_PATH,
  SEED_DIR,
  SeedManifestError,
  buildReproCommand,
  findOrphanSequences,
  findSeed,
  loadSeedManifest,
  parseReproCommand,
  resolveReproduction,
  validateSeedManifest
} from "../../scripts/repro-invariant-seed.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "../..");

/**
 * @param {Partial<any>} [overrides]
 * @returns {any}
 */
function seed(overrides = {}) {
  const base = {
    id: "v2-stakevault-release-exceeds-lock",
    invariantContract: "V2SecurityAuditInvariantTest",
    invariant: "invariant_obligationsNeverExceedCustody",
    summary:
      "Release the same lock cell twice in one campaign, the second time for the full original principal, " +
      "so the second release attempts to credit claimable balance from an already-drained lock.",
    origin: "authored-minimal-regression",
    sequenceFile: "v2-stakevault-release-exceeds-lock/sequence.json",
    state: "rejected",
    campaign: { runs: 500, depth: 20, seed: "0x5eed0001" },
    commit: "461902c1c4a2091b863ee198f1aa7486345a783b",
    repro:
      "forge test --invariant-contract V2SecurityAuditInvariantTest " +
      "--match-test \"^invariant_obligationsNeverExceedCustody$\" " +
      "--invariant-runs 500 --invariant-depth 20 --invariant-seed 0x5eed0001 " +
      "--fuzz-seed 0x5eed0001 --corpus-dir v2-stakevault-release-exceeds-lock"
  };
  const merged = { ...base, ...overrides };
  if (overrides.rejectedBecause === undefined && merged.state === "rejected") {
    merged.rejectedBecause =
      "Investigation showed the lock cell is decremented before claimable credit, so obligations never " +
      "exceed custody; retained as a permanent regression sequence for the custody invariant.";
  }
  return merged;
}

/**
 * @param {any[]} [seeds]
 * @returns {{ manifestPath: string, sequenceDir: string, root: string }}
 */
function scaffold(seeds = [seed()]) {
  const root = mkdtempSync(join(tmpdir(), "seeds-"));
  const sequenceDir = join(root, SEED_DIR);
  mkdirSync(sequenceDir, { recursive: true });
  for (const entry of seeds) {
    const target = join(sequenceDir, entry.sequenceFile);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, JSON.stringify({ local_time: [], calls: [] }));
  }
  const manifestPath = join(root, MANIFEST_PATH);
  writeFileSync(
    manifestPath,
    JSON.stringify(
      {
        schemaVersion: 1,
        protocolVersion: "2.0",
        toolchain: { name: "forge", version: "1.6.0-nightly" },
        seeds
      },
      null,
      2
    )
  );
  return { manifestPath, sequenceDir, root };
}

/**
 * @param {string} manifestPath
 * @returns {any}
 */
function loadScaffolded(manifestPath) {
  return loadSeedManifest(manifestPath);
}

describe("invariant seed reproduction commands", () => {
  it("generates one deterministic command that pins the whole campaign shape", () => {
    const command = buildReproCommand(seed());
    assert.match(command, /^forge test /);
    assert.match(command, /--invariant-contract V2SecurityAuditInvariantTest/);
    assert.match(command, /--match-test "\^invariant_obligationsNeverExceedCustody\$"/);
    assert.match(command, /--invariant-runs 500/);
    assert.match(command, /--invariant-depth 20/);
    assert.match(command, /--invariant-seed 0x5eed0001/);
    assert.match(command, /--fuzz-seed 0x5eed0001/);
    assert.match(command, /--corpus-dir v2-stakevault-release-exceeds-lock$/);
  });

  it("is stable: the same seed always produces the same command", () => {
    assert.equal(buildReproCommand(seed()), buildReproCommand(seed()));
  });

  it("parses back into an argv whose anchors survive shell quoting", () => {
    const argv = parseReproCommand(buildReproCommand(seed()));
    assert.equal(argv[0], "forge");
    assert.equal(argv[1], "test");
    assert.ok(argv.includes("^invariant_obligationsNeverExceedCustody$"));
    assert.equal(argv.filter((token) => token.startsWith("--corpus-dir")).length, 1);
  });

  it("propagates a different campaign shape into a different command", () => {
    const other = buildReproCommand(seed({ campaign: { runs: 64, depth: 5, seed: "0xdeadbeef" } }));
    assert.notEqual(other, buildReproCommand(seed()));
    assert.match(other, /--invariant-runs 64/);
    assert.match(other, /--invariant-seed 0xdeadbeef/);
  });
});

describe("invariant seed manifest validation (fail closed)", () => {
  it("accepts a fully documented seed with a matching command and a sequence on disk", () => {
    const { manifestPath } = scaffold();
    const manifest = loadScaffolded(manifestPath);
    assert.equal(manifest.seeds.length, 1);
    assert.deepEqual(validateSeedManifest(manifest.seeds), []);
  });

  it("fails closed on a manifest that is not valid JSON", () => {
    const { manifestPath } = scaffold();
    writeFileSync(manifestPath, "{ not json");
    assert.throws(() => loadScaffolded(manifestPath), SeedManifestError);
  });

  it("fails closed on a missing manifest file", () => {
    assert.throws(() => loadSeedManifest("test/corpus/invariant/seeds/missing.json"), SeedManifestError);
  });

  it("fails closed when the toolchain is not recorded", () => {
    const { manifestPath } = scaffold();
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    delete manifest.toolchain;
    writeFileSync(manifestPath, JSON.stringify(manifest));
    assert.throws(() => loadScaffolded(manifestPath), /toolchain/);
  });

  it("fails closed when the commit is not recorded", () => {
    const { manifestPath } = scaffold();
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    delete manifest.seeds[0].commit;
    writeFileSync(manifestPath, JSON.stringify(manifest));
    assert.throws(() => loadScaffolded(manifestPath), /\.commit/);
  });

  it("fails closed when the campaign runs or depth is missing", () => {
    for (const field of ["runs", "depth", "seed"]) {
      const { manifestPath } = scaffold();
      const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
      delete manifest.seeds[0].campaign[field];
      writeFileSync(manifestPath, JSON.stringify(manifest));
      assert.throws(() => loadScaffolded(manifestPath), new RegExp(`campaign\\.${field}`), `expected ${field} to be required`);
    }
  });

  it("fails closed on a non-hexadecimal campaign seed", () => {
    const { manifestPath } = scaffold();
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.seeds[0].campaign.seed = "1234";
    writeFileSync(manifestPath, JSON.stringify(manifest));
    assert.throws(() => loadScaffolded(manifestPath), /must be a hex string/);
  });

  it("fails closed on a campaign depth of zero", () => {
    const { manifestPath } = scaffold();
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.seeds[0].campaign.depth = 0;
    writeFileSync(manifestPath, JSON.stringify(manifest));
    assert.throws(() => loadScaffolded(manifestPath), /positive integer/);
  });

  it("fails closed on an unknown seed state", () => {
    const { manifestPath } = scaffold();
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.seeds[0].state = "maybe";
    writeFileSync(manifestPath, JSON.stringify(manifest));
    assert.throws(() => loadScaffolded(manifestPath), /state must be one of/);
  });

  it("fails closed when the provenance of the sequence is not recorded", () => {
    const { manifestPath } = scaffold();
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    delete manifest.seeds[0].origin;
    writeFileSync(manifestPath, JSON.stringify(manifest));
    assert.throws(() => loadScaffolded(manifestPath), /origin/);
  });

  it("fails closed on an unknown provenance value", () => {
    const { manifestPath } = scaffold();
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.seeds[0].origin = "copied-from-twitter";
    writeFileSync(manifestPath, JSON.stringify(manifest));
    assert.throws(() => loadScaffolded(manifestPath), /origin must be one of/);
  });

  it("requires a resolution note for a rejected seed", () => {
    const { manifestPath } = scaffold();
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    delete manifest.seeds[0].rejectedBecause;
    writeFileSync(manifestPath, JSON.stringify(manifest));
    assert.throws(() => loadScaffolded(manifestPath), /rejectedBecause/);
  });

  it("requires a fixing commit for a seed marked fixed", () => {
    const { manifestPath } = scaffold();
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.seeds[0].state = "fixed";
    writeFileSync(manifestPath, JSON.stringify(manifest));
    assert.throws(() => loadScaffolded(manifestPath), /fixedIn/);
  });

  it("fails closed on duplicate seed ids", () => {
    const { manifestPath } = scaffold([seed(), seed()]);
    assert.throws(() => loadScaffolded(manifestPath), /duplicates/);
  });

  it("fails closed when a sequence path escapes the seed directory", () => {
    const { manifestPath } = scaffold();
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.seeds[0].sequenceFile = "../../escape.json";
    writeFileSync(manifestPath, JSON.stringify(manifest));
    assert.throws(() => loadScaffolded(manifestPath), /relative path inside/);
  });

  it("fails closed when the sequence is not isolated in a per-seed directory", () => {
    const { manifestPath } = scaffold();
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.seeds[0].sequenceFile = "sequence.json";
    writeFileSync(manifestPath, JSON.stringify(manifest));
    assert.throws(() => loadScaffolded(manifestPath), /directory named after the seed/);
  });

  it("fails closed when a sequence file is missing from disk", () => {
    const { manifestPath, sequenceDir } = scaffold();
    const manifest = loadScaffolded(manifestPath);
    const entry = manifest.seeds[0];
    assert.ok(existsSync(join(sequenceDir, entry.sequenceFile)));
    const problems = validateSeedManifest([{ ...entry, sequenceFile: `${entry.id}/absent.json` }], sequenceDir);
    assert.equal(problems.length, 1);
    assert.match(problems[0], /sequence file missing/);
  });

  it("fails closed when the recorded reproduction command has drifted", () => {
    const { manifestPath } = scaffold();
    const manifest = loadScaffolded(manifestPath);
    const entry = { ...manifest.seeds[0], repro: "forge test --invariant-runs 1" };
    const problems = validateSeedManifest([entry]);
    assert.equal(problems.length, 1);
    assert.match(problems[0], /repro command drifted/);
  });

  it("fails closed when the recorded command drops the pinned campaign depth", () => {
    const { manifestPath } = scaffold();
    const manifest = loadScaffolded(manifestPath);
    const entry = { ...manifest.seeds[0] };
    entry.repro = entry.repro.replace("--invariant-depth 20 ", "");
    const problems = validateSeedManifest([entry]);
    assert.equal(problems.length, 1);
    assert.match(problems[0], /drifted/);
  });

  it("fails closed when the recorded command points at another seed's corpus directory", () => {
    const { manifestPath } = scaffold();
    const manifest = loadScaffolded(manifestPath);
    const entry = { ...manifest.seeds[0] };
    entry.repro = entry.repro.replace(/--corpus-dir \S+$/, "--corpus-dir some-other-seed");
    const problems = validateSeedManifest([entry]);
    assert.equal(problems.length, 1);
    assert.match(problems[0], /drifted/);
  });

  it("reports a sequence file that no seed references", () => {
    const { manifestPath, sequenceDir } = scaffold();
    const manifest = loadScaffolded(manifestPath);
    writeFileSync(join(sequenceDir, "orphan.json"), "{}");
    const orphans = findOrphanSequences(manifest.seeds, sequenceDir);
    assert.deepEqual(orphans, ["orphan.json"]);
  });

  it("reports an unreferenced sequence nested under a seed directory", () => {
    const { manifestPath, sequenceDir } = scaffold();
    const manifest = loadScaffolded(manifestPath);
    writeFileSync(join(sequenceDir, manifest.seeds[0].id, "stray.json"), "{}");
    const orphans = findOrphanSequences(manifest.seeds, sequenceDir);
    assert.deepEqual(orphans, [`${manifest.seeds[0].id}/stray.json`]);
  });
});

describe("invariant seed lookup and execution", () => {
  it("resolves a registered seed id", () => {
    const { manifestPath } = scaffold();
    const manifest = loadScaffolded(manifestPath);
    const found = findSeed(manifest.seeds, "v2-stakevault-release-exceeds-lock");
    assert.equal(found.invariantContract, "V2SecurityAuditInvariantTest");
  });

  it("fails closed on an unknown seed id and lists the known ones", () => {
    const { manifestPath } = scaffold();
    const manifest = loadScaffolded(manifestPath);
    assert.throws(
      () => findSeed(manifest.seeds, "not-a-seed"),
      (error) =>
        error instanceof SeedManifestError && /v2-stakevault-release-exceeds-lock/.test(error.message)
    );
  });

  it("fails closed on an empty lookup", () => {
    assert.throws(() => findSeed([], "any"), /Known seeds: \(none\)/);
  });

  it("a dry run resolves the command without executing the analyzer", () => {
    const entry = seed();
    const reproduction = resolveReproduction(entry, { dryRun: true });
    assert.equal(reproduction.command, entry.repro);
    assert.equal(reproduction.argv[0], "forge");
  });
});

describe("published invariant seed registry", () => {
  it("is a valid, fully documented, self-consistent manifest", () => {
    const manifest = loadSeedManifest();
    assert.equal(manifest.protocolVersion, "2.0");
    assert.ok(manifest.seeds.length > 0, "the registry must publish at least one seed");
    assert.deepEqual(validateSeedManifest(manifest.seeds), []);
    assert.deepEqual(findOrphanSequences(manifest.seeds), []);
  });

  it("records a pinned analyzer toolchain", () => {
    const manifest = loadSeedManifest();
    assert.equal(manifest.toolchain.name, "forge");
    assert.match(manifest.toolchain.version, /^\d+\.\d+\.\d+/);
  });

  it("uses unique, sortable, lowercase seed ids", () => {
    const manifest = loadSeedManifest();
    const ids = manifest.seeds.map((entry) => entry.id);
    assert.equal(new Set(ids).size, ids.length);
    for (const id of ids) {
      assert.match(id, /^[a-z0-9][a-z0-9-]*$/, `seed id "${id}" must be lowercase kebab-case`);
    }
  });

  it("pins every seed to a full-length commit", () => {
    for (const entry of loadSeedManifest().seeds) {
      assert.match(entry.commit, /^[0-9a-f]{40}$/, `seed ${entry.id} must pin a full commit sha`);
    }
  });

  it("documents a summary and a resolution for every seed", () => {
    for (const entry of loadSeedManifest().seeds) {
      assert.ok(entry.summary.length >= 40, `seed ${entry.id} needs a substantive summary`);
      if (entry.state === "rejected") {
        assert.ok(entry.rejectedBecause.length >= 40, `seed ${entry.id} needs a documented reason`);
      }
      if (entry.state === "fixed") {
        assert.match(entry.fixedIn, /^[0-9a-f]{40}$/);
      }
    }
  });

  it("points every seed at a canonical V2 invariant, not a legacy contract", () => {
    for (const entry of loadSeedManifest().seeds) {
      assert.match(entry.invariant, /^invariant_/);
      assert.doesNotMatch(`${entry.invariantContract}${entry.summary}`, /stellar|soroban|freighter/i);
    }
  });

  it("points every seed at an invariant that actually exists in the repository", () => {
    for (const entry of loadSeedManifest().seeds) {
      const source = findInvariantSource(entry.invariantContract);
      assert.ok(source, `could not locate a Solidity source declaring ${entry.invariantContract}`);
      const contents = readFileSync(source, "utf8");
      assert.ok(
        contents.includes(`contract ${entry.invariantContract}`),
        `${entry.invariantContract} is not declared in ${relative(REPO_ROOT, source)}`
      );
      assert.ok(
        contents.includes(`function ${entry.invariant}(`),
        `${entry.invariantContract}.${entry.invariant} is not declared in ${relative(REPO_ROOT, source)}`
      );
    }
  });

  it("resolves every handler selector used by a committed sequence to an allowlisted handler function", () => {
    for (const entry of loadSeedManifest().seeds) {
      const sequence = JSON.parse(readFileSync(resolve(REPO_ROOT, SEED_DIR, entry.sequenceFile), "utf8"));
      assert.ok(Array.isArray(sequence.calls) && sequence.calls.length > 0, `${entry.id} has no calls`);
      for (const call of sequence.calls) {
        assert.ok(Array.isArray(call) && call.length >= 2, `${entry.id} has a malformed call`);
        assert.match(call[0], /^0x[0-9a-f]{8}$/, `${entry.id} call selector must be 4 bytes`);
        for (const argument of call.slice(1)) {
          assert.match(argument, /^0x[0-9a-f]{64}$/, `${entry.id} call argument must be a 32-byte word`);
        }
        const signature = ALLOWED_HANDLER_SELECTORS[call[0]];
        assert.ok(
          signature,
          `${entry.id} uses selector ${call[0]}, which is not an allowlisted invariant handler entry point`
        );
        const source = findHandlerSource(signature.slice(0, signature.indexOf("(")));
        assert.ok(source, `could not locate a handler declaring ${signature}`);
      }
    }
  });
});

/**
 * Function selectors of the invariant handler entry points a committed sequence
 * may call. Recorded here rather than computed so the allowlist is reviewable
 * and a sequence cannot smuggle in an arbitrary call target.
 */
const ALLOWED_HANDLER_SELECTORS = {
  "0x0894284a": "depositStake(uint256,uint256,uint256)",
  "0x2b3e4164": "releaseStake(uint256,uint256,uint256)",
  "0x441a3e70": "withdraw(uint256,uint256)",
  "0xc30ccf1a": "slashStake(uint256,uint256,uint256)",
  "0xc8477551": "settleConclusive(uint256,uint256,uint256,uint256)",
  "0x5bbdc3cb": "refundInconclusive(uint256,uint256,uint256,uint256)",
  "0xfb3264d8": "attemptReinitialize(uint64,uint256)",
  "0xdbf3824d": "attemptInitialize(address,uint256)"
};

const TEST_SOURCE_DIRS = ["test/invariant", "test/v2", "test/fuzz", "test"];

/**
 * @param {string} file
 * @returns {string}
 */
function findInvariantSource(file) {
  for (const directory of TEST_SOURCE_DIRS) {
    const absolute = resolve(REPO_ROOT, directory);
    if (!existsSync(absolute)) continue;
    const direct = resolve(absolute, file);
    if (existsSync(direct)) return direct;
    for (const candidate of readdirSync(absolute)) {
      if (!candidate.endsWith(".sol")) continue;
      const path = resolve(absolute, candidate);
      if (readFileSync(path, "utf8").includes(`contract ${file} `)) return path;
    }
  }
  return null;
}

/**
 * @param {string} name
 * @returns {string}
 */
function findHandlerSource(name) {
  for (const directory of TEST_SOURCE_DIRS) {
    const absolute = resolve(REPO_ROOT, directory);
    if (!existsSync(absolute)) continue;
    for (const candidate of readdirSync(absolute)) {
      if (!candidate.endsWith(".sol")) continue;
      const path = resolve(absolute, candidate);
      if (readFileSync(path, "utf8").includes(`function ${name}(`)) return path;
    }
  }
  return null;
}
