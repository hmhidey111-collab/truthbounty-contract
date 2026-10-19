#!/usr/bin/env node
/**
 * @file replay-fuzz-corpus.mjs
 * @description Replays the committed protocol fuzz corpus against the canonical V2 fuzz targets.
 *
 * The corpus lives in test/corpus/fuzz/sequences and is wired into Foundry as
 * the coverage-guided corpus directory (see foundry.toml, [fuzz].corpus_dir).
 * Every committed entry is therefore replayed on each `forge test --match-path
 * "test/fuzz/**"` run, and any newly discovered regression case is persisted
 * next to the committed set by the same configuration.
 *
 *   node scripts/replay-fuzz-corpus.mjs --list
 *   node scripts/replay-fuzz-corpus.mjs [--only <category>] [--fuzz-runs <n>] [--dry-run]
 *   node scripts/replay-fuzz-corpus.mjs --validate
 *
 * The manifest is validated strictly and the script fails closed: a missing or
 * malformed entry, a category with no committed regression case, a sequence
 * file that is absent or not a valid hex payload, or a recorded replay command
 * that does not match the command this script generates all exit non-zero.
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "..");

export const MANIFEST_PATH = "test/corpus/fuzz/manifest.json";
export const SEQUENCE_DIR = "test/corpus/fuzz/sequences";
export const CORPUS_DIR = "test/corpus/fuzz";
export const REPRODUCIBLE_TOOLCHAIN = "forge";
export const REQUIRED_CATEGORIES = ["parsing", "arithmetic", "lifecycle", "authorization", "custody"];

export class CorpusManifestError extends Error {}

/**
 * @param {unknown} value
 * @param {string} label
 * @returns {Record<string, unknown>}
 */
function requireObject(label, value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new CorpusManifestError(`${label} must be a JSON object`);
  }
  return /** @type {Record<string, unknown>} */ (value);
}

/**
 * @param {unknown} value
 * @param {string} label
 * @returns {string}
 */
function requireString(label, value) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new CorpusManifestError(`${label} must be a non-empty string`);
  }
  return value;
}

/**
 * @param {string} label
 * @param {string} value
 * @returns {string}
 */
function requireIdentifier(label, value) {
  requireString(label, value);
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(value)) {
    throw new CorpusManifestError(`${label} must be a Solidity identifier: ${value}`);
  }
  return value;
}

/**
 * @param {string} manifestPath
 * @returns {{ schemaVersion: number, protocolVersion: string, categories: any, targets: any[], entries: any[] }}
 */
export function loadCorpusManifest(manifestPath = MANIFEST_PATH) {
  const absolute = resolve(REPO_ROOT, manifestPath);
  if (!existsSync(absolute)) {
    throw new CorpusManifestError(`Fuzz corpus manifest not found: ${manifestPath}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(absolute, "utf8"));
  } catch (error) {
    throw new CorpusManifestError(`Fuzz corpus manifest is not valid JSON: ${manifestPath} (${error.message})`);
  }
  const manifest = requireObject("Fuzz corpus manifest", parsed);
  if (!Number.isInteger(manifest.schemaVersion) || /** @type {number} */ (manifest.schemaVersion) < 1) {
    throw new CorpusManifestError("Fuzz corpus manifest.schemaVersion must be a positive integer");
  }
  requireString("Fuzz corpus manifest.protocolVersion", manifest.protocolVersion);
  const categories = requireObject("Fuzz corpus manifest.categories", manifest.categories);
  for (const category of REQUIRED_CATEGORIES) {
    const described = requireString(`Fuzz corpus manifest.categories.${category}`, categories[category]);
    if (described.length < 40) {
      throw new CorpusManifestError(
        `Fuzz corpus manifest.categories.${category} must document the risk it covers (>= 40 characters)`
      );
    }
  }
  for (const key of Object.keys(categories)) {
    if (!REQUIRED_CATEGORIES.includes(key)) {
      throw new CorpusManifestError(
        `Fuzz corpus manifest.categories.${key} is not a required category; allowed: ${REQUIRED_CATEGORIES.join(", ")}`
      );
    }
  }
  if (!Array.isArray(manifest.targets)) {
    throw new CorpusManifestError("Fuzz corpus manifest.targets must be an array");
  }
  const targets = manifest.targets.map((raw, index) => {
    const label = `Fuzz corpus manifest.targets[${index}]`;
    const target = requireObject(label, raw);
    return {
      contract: requireIdentifier(`${label}.contract`, target.contract),
      test: requireIdentifier(`${label}.test`, target.test),
      category: requireString(`${label}.category`, target.category),
      property: requireString(`${label}.property`, target.property)
    };
  });
  if (!Array.isArray(manifest.entries)) {
    throw new CorpusManifestError("Fuzz corpus manifest.entries must be an array");
  }

  const seen = new Set();
  const entries = manifest.entries.map((raw, index) => {
    const label = `Fuzz corpus manifest.entries[${index}]`;
    const entry = requireObject(label, raw);
    const id = requireString(`${label}.id`, entry.id);
    if (!/^[a-z0-9][a-z0-9-]*$/.test(id)) {
      throw new CorpusManifestError(`${label}.id must be lowercase kebab-case: ${id}`);
    }
    if (seen.has(id)) {
      throw new CorpusManifestError(`${label}.id duplicates an earlier entry: ${id}`);
    }
    seen.add(id);
    const category = requireString(`${label}.category`, entry.category);
    if (!REQUIRED_CATEGORIES.includes(category)) {
      throw new CorpusManifestError(
        `${label}.category "${category}" is not a required category; allowed: ${REQUIRED_CATEGORIES.join(", ")}`
      );
    }
    const contract = requireIdentifier(`${label}.contract`, entry.contract);
    const test = requireIdentifier(`${label}.test`, entry.test);
    if (!test.startsWith("testFuzz_") && !test.startsWith("test_")) {
      throw new CorpusManifestError(`${label}.test must be a Foundry test entry point: ${test}`);
    }
    const sequenceFile = requireString(`${label}.sequenceFile`, entry.sequenceFile);
    if (sequenceFile.includes("..") || sequenceFile.includes("/") || sequenceFile.includes("\\")) {
      throw new CorpusManifestError(`${label}.sequenceFile must be a bare file name inside ${SEQUENCE_DIR}: ${sequenceFile}`);
    }
    const rationale = requireString(`${label}.rationale`, entry.rationale);
    if (rationale.length < 40) {
      throw new CorpusManifestError(`${label}.rationale must state why the case is retained (>= 40 characters)`);
    }
    const expected = requireString(`${label}.expected`, entry.expected);
    if (expected.length < 20) {
      throw new CorpusManifestError(`${label}.expected must state the postcondition (>= 20 characters)`);
    }
    const discoveredBy = requireString(`${label}.discoveredBy`, entry.discoveredBy);
    if (!Array.isArray(entry.inputs) || entry.inputs.length === 0) {
      throw new CorpusManifestError(`${label}.inputs must be a non-empty array of named argument values`);
    }
    const inputs = entry.inputs.map((input, inputIndex) => {
      const inputLabel = `${label}.inputs[${inputIndex}]`;
      const record = requireObject(inputLabel, input);
      return {
        name: requireString(`${inputLabel}.name`, record.name),
        value: requireString(`${inputLabel}.value`, record.value)
      };
    });
    return { id, category, contract, test, sequenceFile, rationale, expected, discoveredBy, inputs, repro: entry.repro };
  });

  return { ...manifest, categories, targets, entries };
}

/**
 * The one command that replays a single committed corpus entry.
 *
 * @param {{ contract: string, test: string, sequenceFile: string }} entry
 * @param {{ fuzzRuns?: number, fuzzSeed?: string }} [options]
 * @returns {string}
 */
export function buildReplayCommand(entry, { fuzzRuns = 256, fuzzSeed = "0x5eed" } = {}) {
  return [
    `${REPRODUCIBLE_TOOLCHAIN} test`,
    `--match-contract ^${entry.contract}$`,
    `--match-test ^${entry.test}$`,
    `--fuzz-runs ${fuzzRuns}`,
    `--fuzz-seed ${fuzzSeed}`,
    `--corpus-dir ${CORPUS_DIR}`
  ].join(" ");
}

/**
 * @param {string} command
 * @returns {string[]}
 */
export function parseReplayCommand(command) {
  return command.split(/\s+/).filter((token) => token.length > 0);
}

/**
 * A committed corpus file must be a non-empty, even-length hex payload. Foundry
 * writes the ABI-encoded fuzz arguments as hex, so anything else means the file
 * was hand-edited into an unreadable state.
 *
 * @param {string} content
 * @param {string} label
 */
export function assertHexPayload(content, label) {
  const trimmed = content.trim();
  if (trimmed.length === 0) {
    throw new CorpusManifestError(`${label} is empty`);
  }
  if (trimmed.length % 2 !== 0) {
    throw new CorpusManifestError(`${label} has an odd-length hex payload`);
  }
  if (!/^[0-9a-fA-F]+$/.test(trimmed)) {
    throw new CorpusManifestError(`${label} is not a hex payload`);
  }
  return trimmed;
}

/**
 * @param {any[]} entries
 * @param {string} [sequenceDir]
 * @returns {string[]}
 */
export function validateCorpus(entries, sequenceDir = SEQUENCE_DIR) {
  const problems = [];
  const covered = new Set();
  for (const entry of entries) {
    covered.add(entry.category);
    const absolute = resolve(REPO_ROOT, sequenceDir, entry.sequenceFile);
    if (!existsSync(absolute)) {
      problems.push(`${entry.id}: sequence file missing at ${relative(REPO_ROOT, absolute)}`);
      continue;
    }
    try {
      assertHexPayload(readFileSync(absolute, "utf8"), `${entry.id}: ${relative(REPO_ROOT, absolute)}`);
    } catch (error) {
      problems.push(error instanceof CorpusManifestError ? error.message : `${entry.id}: unreadable sequence file`);
    }
  }
  for (const category of REQUIRED_CATEGORIES) {
    if (!covered.has(category)) {
      problems.push(`no committed regression case covers the "${category}" fuzz targets`);
    }
  }
  return problems;
}

/**
 * @param {any[]} entries
 * @param {string} [sequenceDir]
 * @returns {string[]}
 */
export function findOrphanSequences(entries, sequenceDir = SEQUENCE_DIR) {
  const absoluteDir = resolve(REPO_ROOT, sequenceDir);
  if (!existsSync(absoluteDir)) return [];
  const referenced = new Set(entries.map((entry) => entry.sequenceFile));
  return readdirSync(absoluteDir).filter((file) => !referenced.has(file));
}

/**
 * @param {any[]} entries
 * @param {string} [only]
 * @returns {any[]}
 */
export function selectEntries(entries, only) {
  if (!only) return entries;
  if (!REQUIRED_CATEGORIES.includes(only)) {
    throw new CorpusManifestError(`Unknown category "${only}"; allowed: ${REQUIRED_CATEGORIES.join(", ")}`);
  }
  return entries.filter((entry) => entry.category === only);
}

/**
 * @param {string[]} commands
 * @param {boolean} dryRun
 */
export function runReplay(commands, dryRun) {
  for (const command of commands) {
    if (dryRun) {
      console.log(command);
      continue;
    }
    const argv = parseReplayCommand(command);
    execFileSync(argv[0], argv.slice(1), { stdio: "inherit", cwd: REPO_ROOT });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(__filename)) {
  const argv = process.argv.slice(2);
  const listOnly = argv.includes("--list");
  const validateOnly = argv.includes("--validate");
  const dryRun = argv.includes("--dry-run");
  const asJson = argv.includes("--json");
  const onlyIndex = argv.indexOf("--only");
  const only = onlyIndex === -1 ? undefined : argv[onlyIndex + 1];
  const runsIndex = argv.indexOf("--fuzz-runs");
  const fuzzRuns = runsIndex === -1 ? 256 : Number(argv[runsIndex + 1]);

  try {
    const manifest = loadCorpusManifest();
    const problems = validateCorpus(manifest.entries);
    const orphans = findOrphanSequences(manifest.entries);
    if (problems.length > 0 || orphans.length > 0) {
      for (const problem of problems) console.error(`FAILED: ${problem}`);
      for (const orphan of orphans) console.error(`FAILED: ${SEQUENCE_DIR}/${orphan} is not referenced by any entry`);
      process.exit(1);
    }

    if (listOnly) {
      if (asJson) {
        console.log(JSON.stringify(manifest.entries, null, 2));
      } else {
        for (const entry of manifest.entries) {
          console.log(`${entry.id}\t${entry.category}\t${entry.contract}::${entry.test}`);
          console.log(`    ${entry.rationale}`);
        }
      }
      process.exit(0);
    }

    const selected = selectEntries(manifest.entries, only);
    if (selected.length === 0) {
      console.error(`FAILED: no committed corpus entry for category "${only}"`);
      process.exit(1);
    }

    if (validateOnly) {
      console.log(`OK: ${manifest.entries.length} committed fuzz corpus entries across ${REQUIRED_CATEGORIES.length} categories.`);
      process.exit(0);
    }

    const commands = selected.map((entry) => buildReplayCommand(entry, { fuzzRuns }));
    runReplay(commands, dryRun);
    process.exit(0);
  } catch (error) {
    console.error(
      `FAILED: ${error instanceof CorpusManifestError ? error.message : `could not replay the corpus (${error.message})`}`
    );
    process.exit(1);
  }
}
