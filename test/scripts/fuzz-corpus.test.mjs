/**
 * @file fuzz-corpus.test.mjs
 * @description Unit tests for the persistent protocol fuzz corpus.
 *
 * The committed corpus is the regression memory of the canonical V2 fuzz
 * targets. These tests pin the properties that keep it useful and honest: every
 * required target category is covered, every entry records the fuzz target it
 * feeds, the minimal inputs it replays, why it was retained, and the
 * postcondition it asserts, every referenced sequence exists as a valid Foundry
 * corpus payload, and the manifest never drifts into referencing legacy or
 * alternate-chain contracts or embedding secret-shaped material.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  CORPUS_DIR,
  CorpusManifestError,
  MANIFEST_PATH,
  REQUIRED_CATEGORIES,
  SEQUENCE_DIR,
  assertHexPayload,
  buildReplayCommand,
  findOrphanSequences,
  loadCorpusManifest,
  parseReplayCommand,
  selectEntries,
  validateCorpus
} from "../../scripts/replay-fuzz-corpus.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "../..");
const TEST_SOURCE_DIRS = ["test/fuzz", "test/v2", "test/invariant", "test"];

/**
 * Locates the Solidity source file that declares a test contract.
 *
 * @param {string} contract
 * @returns {string | null}
 */
function findTestSource(contract) {
  for (const directory of TEST_SOURCE_DIRS) {
    for (const suffix of [".sol", ".t.sol"]) {
      const candidate = resolve(REPO_ROOT, directory, `${contract}${suffix}`);
      if (existsSync(candidate)) return candidate;
    }
  }
  for (const directory of TEST_SOURCE_DIRS) {
    const absolute = resolve(REPO_ROOT, directory);
    if (!existsSync(absolute)) continue;
    for (const file of readdirSync(absolute)) {
      if (file.endsWith(".sol") && readFileSync(resolve(absolute, file), "utf8").includes(`contract ${contract}`)) {
        return resolve(absolute, file);
      }
    }
  }
  return null;
}

/**
 * @param {Partial<any>} [overrides]
 * @returns {any}
 */
function entry(overrides = {}) {
  return {
    id: "amount-units-max-decimals",
    category: "arithmetic",
    contract: "V2SecurityAuditFuzz_StakeVault",
    test: "testFuzz_reconcile_postRoundTrip",
    sequenceFile: "amount-units-max-decimals.hex",
    rationale:
      "Deposit and release at the maximum bounded amount so the vault's obligation arithmetic is " +
      "exercised at the top of the allowed envelope rather than only near zero.",
    expected: "reconcile() returns custody equal to obligations and totalCustody equals the ERC20 balance",
    discoveredBy: "forge test --match-contract V2SecurityAuditFuzz_StakeVault --fuzz-seed 0x5eed",
    inputs: [
      { name: "claimId", value: "1" },
      { name: "depositAmt", value: "1000000000000000000000000" },
      { name: "releaseAmt", value: "1000000000000000000000000" }
    ],
    ...overrides
  };
}

/**
 * @param {any} [overrides]
 * @returns {any}
 */
function manifest(overrides = {}) {
  return {
    schemaVersion: 1,
    protocolVersion: "2.0",
    categories: {
      parsing:
        "Interface-id, digest, page-limit and metadata parsing at malformed and extreme boundaries.",
      arithmetic:
        "Bounded amount conversion, obligation accounting and rounding across the full decimal envelope.",
      lifecycle:
        "Claim, evidence and settlement state-machine transitions including terminal and timelock edges.",
      authorization:
        "Role-gated mutation paths, lock-mutator authority and caller-identity checks that must fail closed.",
      custody:
        "Multi-asset custody conservation: totalCustody against ERC20 balance and per-account claimable balances."
    },
    targets: [
      {
        contract: "V2SecurityAuditFuzz_StakeVault",
        test: "testFuzz_reconcile_postRoundTrip",
        category: "custody",
        property: "custody equals obligations after a deposit/release round trip"
      }
    ],
    entries: [entry()],
    ...overrides
  };
}

/**
 * @param {any} [payload]
 * @returns {{ manifestPath: string, sequenceDir: string, root: string }}
 */
function scaffold(payload = manifest(), sequences = { "amount-units-max-decimals.hex": "0a" + "00".repeat(95) }) {
  const root = mkdtempSync(join(tmpdir(), "corpus-"));
  const sequenceDir = join(root, SEQUENCE_DIR);
  mkdirSync(sequenceDir, { recursive: true });
  for (const [name, content] of Object.entries(sequences)) {
    writeFileSync(join(sequenceDir, name), content);
  }
  mkdirSync(dirname(join(root, MANIFEST_PATH)), { recursive: true });
  const manifestPath = join(root, MANIFEST_PATH);
  writeFileSync(manifestPath, JSON.stringify(payload, null, 2));
  return { manifestPath, sequenceDir, root };
}

describe("fuzz corpus replay commands", () => {
  it("generates one deterministic command that pins the target and the seed", () => {
    const command = buildReplayCommand(entry());
    assert.match(command, /^forge test /);
    assert.match(command, /--match-contract \^V2SecurityAuditFuzz_StakeVault\$/);
    assert.match(command, /--match-test \^testFuzz_reconcile_postRoundTrip\$/);
    assert.match(command, /--fuzz-runs 256/);
    assert.match(command, /--fuzz-seed 0x5eed/);
    assert.match(command, /--corpus-dir test\/corpus\/fuzz/);
  });

  it("is stable and honours an explicit campaign shape", () => {
    assert.equal(buildReplayCommand(entry()), buildReplayCommand(entry()));
    const wide = buildReplayCommand(entry(), { fuzzRuns: 5000, fuzzSeed: "0xfeed" });
    assert.match(wide, /--fuzz-runs 5000/);
    assert.match(wide, /--fuzz-seed 0xfeed/);
  });

  it("parses back into an argv whose first token is the analyzer binary", () => {
    const argv = parseReplayCommand(buildReplayCommand(entry()));
    assert.equal(argv[0], "forge");
    assert.equal(argv[1], "test");
  });
});

describe("corpus payload validation", () => {
  it("accepts a non-empty even-length hex payload", () => {
    assert.equal(assertHexPayload("0a00ff\n", "case"), "0a00ff");
  });

  it("rejects an empty payload", () => {
    assert.throws(() => assertHexPayload("   \n", "case"), CorpusManifestError);
  });

  it("rejects an odd-length payload", () => {
    assert.throws(() => assertHexPayload("0a0", "case"), /odd-length/);
  });

  it("rejects a payload that is not hex", () => {
    assert.throws(() => assertHexPayload("not-hex", "case"), /not a hex payload/);
  });
});

describe("fuzz corpus manifest validation (fail closed)", () => {
  it("accepts a well-formed manifest", () => {
    const { manifestPath } = scaffold();
    const loaded = loadCorpusManifest(manifestPath);
    assert.equal(loaded.entries.length, 1);
    assert.equal(loaded.entries[0].category, "arithmetic");
  });

  it("fails closed on a manifest that is not valid JSON", () => {
    const { manifestPath } = scaffold();
    writeFileSync(manifestPath, "{ not json");
    assert.throws(() => loadCorpusManifest(manifestPath), CorpusManifestError);
  });

  it("fails closed on a missing manifest file", () => {
    assert.throws(() => loadCorpusManifest("test/corpus/fuzz/missing.json"), CorpusManifestError);
  });

  it("fails closed when a required category is undocumented", () => {
    const { manifestPath } = scaffold(manifest({ categories: { ...manifest().categories, custody: "too short" } }));
    assert.throws(() => loadCorpusManifest(manifestPath), /categories\.custody/);
  });

  it("fails closed on an unknown category", () => {
    const categories = { ...manifest().categories, soroban: "x".repeat(50) };
    const { manifestPath } = scaffold(manifest({ categories }));
    assert.throws(() => loadCorpusManifest(manifestPath), /is not a required category/);
  });

  it("fails closed on a duplicate entry id", () => {
    const { manifestPath } = scaffold(manifest({ entries: [entry(), entry()] }));
    assert.throws(() => loadCorpusManifest(manifestPath), /duplicates/);
  });

  it("fails closed on an entry id that is not lowercase kebab-case", () => {
    const { manifestPath } = scaffold(manifest({ entries: [entry({ id: "Amount_Units" })] }));
    assert.throws(() => loadCorpusManifest(manifestPath), /lowercase kebab-case/);
  });

  it("fails closed on a rationale that does not explain the retained case", () => {
    const { manifestPath } = scaffold(manifest({ entries: [entry({ rationale: "found by fuzzing" })] }));
    assert.throws(() => loadCorpusManifest(manifestPath), /rationale/);
  });

  it("fails closed when the expected postcondition is missing", () => {
    const { manifestPath } = scaffold(manifest({ entries: [entry({ expected: "" })] }));
    assert.throws(() => loadCorpusManifest(manifestPath), /expected/);
  });

  it("fails closed when the seed inputs are not recorded", () => {
    const { manifestPath } = scaffold(manifest({ entries: [entry({ inputs: [] })] }));
    assert.throws(() => loadCorpusManifest(manifestPath), /inputs/);
  });

  it("fails closed when a named input has no value", () => {
    const { manifestPath } = scaffold(manifest({ entries: [entry({ inputs: [{ name: "amount" }] })] }));
    assert.throws(() => loadCorpusManifest(manifestPath), /inputs\[0\]\.value/);
  });

  it("fails closed when a sequence file escapes the corpus directory", () => {
    const { manifestPath } = scaffold(manifest({ entries: [entry({ sequenceFile: "../escape.hex" })] }));
    assert.throws(() => loadCorpusManifest(manifestPath), /bare file name/);
  });

  it("fails closed when the fuzz target is not a Solidity identifier", () => {
    const { manifestPath } = scaffold(manifest({ entries: [entry({ contract: "Vault; drop" })] }));
    assert.throws(() => loadCorpusManifest(manifestPath), /Solidity identifier/);
  });

  it("fails closed when the target is not a Foundry test entry point", () => {
    const { manifestPath } = scaffold(manifest({ entries: [entry({ test: "runFuzzer" })] }));
    assert.throws(() => loadCorpusManifest(manifestPath), /Foundry test entry point/);
  });

  it("fails closed when a category is missing from the entry", () => {
    const { manifestPath } = scaffold(manifest({ entries: [entry({ category: "gas" })] }));
    assert.throws(() => loadCorpusManifest(manifestPath), /is not a required category/);
  });
});

describe("corpus coverage validation (fail closed)", () => {
  it("fails when a required category has no committed regression case", () => {
    const { manifestPath, root } = scaffold();
    const loaded = loadCorpusManifest(manifestPath);
    const sequenceDir = join(root, SEQUENCE_DIR);
    mkdirSync(join(sequenceDir, "empty-dir"), { recursive: true });
    const problems = validateCorpus(loaded.entries, sequenceDir);
    for (const category of REQUIRED_CATEGORIES.filter((name) => name !== "arithmetic")) {
      assert.ok(
        problems.some((problem) => problem.includes(`"${category}"`)),
        `expected a coverage problem for ${category}`
      );
    }
  });

  it("fails when a referenced sequence file is missing", () => {
    const { manifestPath, root } = scaffold();
    const loaded = loadCorpusManifest(manifestPath);
    const problems = validateCorpus(loaded.entries, join(root, SEQUENCE_DIR, "elsewhere"));
    assert.ok(problems.some((problem) => /sequence file missing/.test(problem)));
  });

  it("fails when a committed sequence file is not a valid payload", () => {
    const { manifestPath, root } = scaffold(manifest(), { "amount-units-max-decimals.hex": "zz" });
    const loaded = loadCorpusManifest(manifestPath);
    const problems = validateCorpus(loaded.entries, join(root, SEQUENCE_DIR));
    assert.ok(problems.some((problem) => /not a hex payload/.test(problem)));
  });

  it("reports a committed sequence file that no entry references", () => {
    const { manifestPath, root } = scaffold(manifest(), {
      "amount-units-max-decimals.hex": "00",
      "stray.hex": "00"
    });
    const loaded = loadCorpusManifest(manifestPath);
    const orphans = findOrphanSequences(loaded.entries, join(root, SEQUENCE_DIR));
    assert.deepEqual(orphans, ["stray.hex"]);
  });

  it("selects a single category and rejects an unknown one", () => {
    const entries = [
      entry({ id: "a", category: "arithmetic" }),
      entry({ id: "b", category: "custody" })
    ];
    assert.deepEqual(
      selectEntries(entries, "custody").map((item) => item.id),
      ["b"]
    );
    assert.equal(selectEntries(entries, undefined).length, 2);
    assert.throws(() => selectEntries(entries, "soroban"), CorpusManifestError);
  });
});

describe("published protocol fuzz corpus", () => {
  it("is a valid manifest with complete coverage and no orphaned sequences", () => {
    const manifest = loadCorpusManifest();
    assert.equal(manifest.protocolVersion, "2.0");
    assert.ok(manifest.entries.length > 0, "the corpus must publish at least one regression case");
    assert.deepEqual(validateCorpus(manifest.entries), []);
    assert.deepEqual(findOrphanSequences(manifest.entries), []);
  });

  it("covers every required target category", () => {
    const manifest = loadCorpusManifest();
    const covered = new Set(manifest.entries.map((item) => item.category));
    for (const category of REQUIRED_CATEGORIES) {
      assert.ok(covered.has(category), `no committed corpus entry covers "${category}"`);
    }
  });

  it("registers at least one declared fuzz target per category", () => {
    const manifest = loadCorpusManifest();
    for (const category of REQUIRED_CATEGORIES) {
      assert.ok(
        manifest.targets.some((target) => target.category === category),
        `no fuzz target is declared for "${category}"`
      );
    }
  });

  it("points every entry at a declared fuzz target", () => {
    const manifest = loadCorpusManifest();
    const declared = new Set(manifest.targets.map((target) => `${target.contract}::${target.test}`));
    for (const item of manifest.entries) {
      assert.ok(
        declared.has(`${item.contract}::${item.test}`),
        `${item.id} targets ${item.contract}::${item.test}, which is not a declared fuzz target`
      );
    }
  });

  it("points every entry at a test that exists in the repository", () => {
    const manifest = loadCorpusManifest();
    for (const item of manifest.entries) {
      const source = findTestSource(item.contract);
      assert.ok(source, `could not locate a Solidity source declaring ${item.contract}`);
      const contents = readFileSync(source, "utf8");
      assert.ok(
        contents.includes(`${item.test}(`) || contents.includes(`${item.test} (`),
        `${item.contract}.${item.test} is not declared in ${relative(REPO_ROOT, source)}`
      );
    }
  });

  it("records minimal numeric or identifier inputs for every entry", () => {
    for (const item of loadCorpusManifest().entries) {
      for (const input of item.inputs) {
        assert.match(
          input.name,
          /^[A-Za-z_][A-Za-z0-9_]*$/,
          `${item.id} input name "${input.name}" must be a Solidity parameter name`
        );
        assert.ok(input.value.length > 0, `${item.id} input ${input.name} must record a value`);
      }
    }
  });

  it("never references legacy, alternate-chain, or secret-shaped material", () => {
    const raw = readFileSync(resolve(REPO_ROOT, MANIFEST_PATH), "utf8");
    assert.doesNotMatch(raw, /stellar|soroban|freighter/i);
    assert.doesNotMatch(raw, /private[_-]?key|mnemonic|secret|api[_-]?key|0x[a-fA-F0-9]{64}(?!.*commit)/i);
    for (const item of loadCorpusManifest().entries) {
      for (const target of [item.contract, item.test, item.rationale, item.expected]) {
        assert.doesNotMatch(target, /stellar|soroban|freighter/i);
      }
    }
  });

  it("is wired into Foundry as the persistent corpus directory", () => {
    const foundryToml = readFileSync(resolve(REPO_ROOT, "foundry.toml"), "utf8");
    assert.match(foundryToml, /corpus_dir\s*=\s*"test\/corpus\/fuzz"/);
    assert.match(foundryToml, new RegExp(`failure_persist_dir\\s*=\\s*"${CORPUS_DIR}/failures"`));
  });
});
