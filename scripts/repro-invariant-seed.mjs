#!/usr/bin/env node
/**
 * @file repro-invariant-seed.mjs
 * @description Deterministic reproduction of persisted invariant failure seeds.
 *
 * Every entry in test/corpus/invariant/seeds/manifest.json records the exact
 * toolchain, commit, campaign configuration, and call sequence that produced an
 * invariant failure, plus a single reproduction command. This script is the only
 * supported way to execute one:
 *
 *   node scripts/repro-invariant-seed.mjs --list
 *   node scripts/repro-invariant-seed.mjs <seed-id> [--dry-run] [--json]
 *
 * The manifest is validated strictly. A missing or malformed field, an unknown
 * seed id, a seed file that is missing from disk, or a reproduction command that
 * does not match the command this script would generate all fail closed with a
 * non-zero exit code, so a seed can never be silently reproduced against the
 * wrong contract, the wrong campaign shape, or a drifted configuration.
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "..");

export const MANIFEST_PATH = "test/corpus/invariant/seeds/manifest.json";
export const SEED_DIR = "test/corpus/invariant/seeds/sequences";
export const REPRODUCIBLE_TOOLCHAIN = "forge";
export const VALID_STATES = ["open", "fixed", "rejected"];
export const VALID_ORIGINS = ["recorded-counterexample", "authored-minimal-regression"];

export class SeedManifestError extends Error {}

/**
 * @param {unknown} value
 * @returns {Record<string, unknown>}
 */
function requireObject(label, value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new SeedManifestError(`${label} must be a JSON object`);
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
    throw new SeedManifestError(`${label} must be a non-empty string`);
  }
  return value;
}

/**
 * @param {unknown} value
 * @param {string} label
 * @returns {number}
 */
function requirePositiveInteger(label, value) {
  if (!Number.isInteger(value) || /** @type {number} */ (value) < 1) {
    throw new SeedManifestError(`${label} must be a positive integer`);
  }
  return /** @type {number} */ (value);
}

/**
 * @param {string} manifestPath
 * @returns {{ schemaVersion: number, protocolVersion: string, toolchain: any, seeds: any[] }}
 */
export function loadSeedManifest(manifestPath = MANIFEST_PATH) {
  const absolute = resolve(REPO_ROOT, manifestPath);
  if (!existsSync(absolute)) {
    throw new SeedManifestError(`Invariant seed manifest not found: ${manifestPath}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(absolute, "utf8"));
  } catch (error) {
    throw new SeedManifestError(`Invariant seed manifest is not valid JSON: ${manifestPath} (${error.message})`);
  }
  const manifest = requireObject("Invariant seed manifest", parsed);
  if (!Number.isInteger(manifest.schemaVersion) || /** @type {number} */ (manifest.schemaVersion) < 1) {
    throw new SeedManifestError("Invariant seed manifest.schemaVersion must be a positive integer");
  }
  requireString("Invariant seed manifest.protocolVersion", manifest.protocolVersion);
  const toolchain = requireObject("Invariant seed manifest.toolchain", manifest.toolchain);
  requireString("Invariant seed manifest.toolchain.name", toolchain.name);
  requireString("Invariant seed manifest.toolchain.version", toolchain.version);
  if (!Array.isArray(manifest.seeds)) {
    throw new SeedManifestError("Invariant seed manifest.seeds must be an array");
  }

  const seen = new Set();
  const seeds = manifest.seeds.map((raw, index) => {
    const label = `Invariant seed manifest.seeds[${index}]`;
    const seed = requireObject(label, raw);
    const id = requireString(`${label}.id`, seed.id);
    if (seen.has(id)) {
      throw new SeedManifestError(`${label}.id duplicates an earlier seed: ${id}`);
    }
    seen.add(id);

    const invariantContract = requireString(`${label}.invariantContract`, seed.invariantContract);
    const invariant = requireString(`${label}.invariant`, seed.invariant);
    const summary = requireString(`${label}.summary`, seed.summary);
    const sequenceFile = requireString(`${label}.sequenceFile`, seed.sequenceFile);
    if (sequenceFile.includes("..") || sequenceFile.startsWith("/") || sequenceFile.includes("\\")) {
      throw new SeedManifestError(`${label}.sequenceFile must be a relative path inside ${SEED_DIR}: ${sequenceFile}`);
    }
    const sequenceDir = sequenceFile.split("/")[0];
    if (sequenceDir !== id) {
      throw new SeedManifestError(
        `${label}.sequenceFile must live in a directory named after the seed so that --corpus-dir replays exactly one sequence: expected "${id}/...", got "${sequenceFile}"`
      );
    }
    const state = requireString(`${label}.state`, seed.state);
    if (!VALID_STATES.includes(state)) {
      throw new SeedManifestError(`${label}.state must be one of ${VALID_STATES.join(", ")}`);
    }
    const origin = requireString(`${label}.origin`, seed.origin);
    if (!VALID_ORIGINS.includes(origin)) {
      throw new SeedManifestError(`${label}.origin must be one of ${VALID_ORIGINS.join(", ")}`);
    }
    const campaign = requireObject(`${label}.campaign`, seed.campaign);
    const runs = requirePositiveInteger(`${label}.campaign.runs`, campaign.runs);
    const depth = requirePositiveInteger(`${label}.campaign.depth`, campaign.depth);
    const invariantSeed = requireString(`${label}.campaign.seed`, campaign.seed);
    if (!/^0x[0-9a-fA-F]+$/.test(invariantSeed)) {
      throw new SeedManifestError(`${label}.campaign.seed must be a hex string: ${invariantSeed}`);
    }
    requireString(`${label}.commit`, seed.commit);
    requireString(`${label}.repro`, seed.repro);
    if (state === "fixed") {
      requireString(`${label}.fixedIn`, seed.fixedIn);
    }
    if (state === "rejected") {
      requireString(`${label}.rejectedBecause`, seed.rejectedBecause);
    }
    return {
      id,
      invariantContract,
      invariant,
      summary,
      sequenceFile,
      sequenceDir,
      state,
      origin,
      campaign: { runs, depth, seed: invariantSeed },
      commit: /** @type {string} */ (seed.commit),
      repro: /** @type {string} */ (seed.repro)
    };
  });

  return { ...manifest, seeds };
}

/**
 * The single command this script will execute for a seed. The manifest must
 * record exactly this string, so that a hand-edited or drifted entry is
 * rejected instead of being replayed under the wrong configuration.
 *
 * @param {{ id: string, invariantContract: string, invariant: string, sequenceFile: string, campaign: { runs: number, depth: number, seed: string } }} seed
 * @returns {string}
 */
export function buildReproCommand(seed) {
  return [
    `${REPRODUCIBLE_TOOLCHAIN} test`,
    `--invariant-contract ${seed.invariantContract}`,
    `--match-test "^${seed.invariant}$"`,
    `--invariant-runs ${seed.campaign.runs}`,
    `--invariant-depth ${seed.campaign.depth}`,
    `--invariant-seed ${seed.campaign.seed}`,
    `--fuzz-seed ${seed.campaign.seed}`,
    `--corpus-dir ${seed.sequenceDir}`
  ].join(" ");
}

/**
 * Splits a reproduction command into argv, stripping the shell quoting that
 * keeps the anchored `--match-test` regular expression intact.
 *
 * @param {string} command
 * @returns {string[]}
 */
export function parseReproCommand(command) {
  return command
    .split(/\s+/)
    .filter((token) => token.length > 0)
    .map((token) => token.replace(/^["'](.*)["']$/, "$1"));
}

/**
 * @param {Array<{ id: string, sequenceFile: string, repro: string }>} seeds
 * @param {string} [seedDir]
 * @returns {string[]} Validation problems; empty means the manifest is replayable.
 */
export function validateSeedManifest(seeds, seedDir = SEED_DIR) {
  const problems = [];
  for (const seed of seeds) {
    const expected = buildReproCommand(seed);
    if (seed.repro !== expected) {
      problems.push(`${seed.id}: repro command drifted; expected "${expected}"`);
    }
    const absolute = resolve(REPO_ROOT, seedDir, seed.sequenceFile);
    if (!existsSync(absolute)) {
      problems.push(`${seed.id}: sequence file missing at ${relative(REPO_ROOT, absolute)}`);
    }
  }
  return problems;
}
/**
 * @param {Array<any>} seeds
 * @param {string} id
 * @returns {any}
 */
export function findSeed(seeds, id) {
  const match = seeds.find((seed) => seed.id === id);
  if (!match) {
    const known = seeds.map((seed) => seed.id).join(", ") || "(none)";
    throw new SeedManifestError(`Unknown invariant seed "${id}". Known seeds: ${known}`);
  }
  return match;
}

/**
 * @param {string} dir
 * @param {string} [prefix]
 * @returns {string[]}
 */
function listSequenceFiles(dir, prefix = "") {
  const absoluteDir = resolve(REPO_ROOT, dir);
  if (!existsSync(absoluteDir)) return [];
  const results = [];
  for (const entry of readdirSync(absoluteDir, { withFileTypes: true })) {
    const entryPath = prefix.length > 0 ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      results.push(...listSequenceFiles(dir, entryPath));
    } else if (entry.name.endsWith(".json")) {
      results.push(entryPath);
    }
  }
  return results;
}

/**
 * @param {Array<any>} seeds
 * @param {string} [seedDir]
 * @returns {string[]} Sequence file names present on disk but absent from the manifest.
 */
export function findOrphanSequences(seeds, seedDir = SEED_DIR) {
  const referenced = new Set(seeds.map((seed) => seed.sequenceFile));
  return listSequenceFiles(seedDir).filter((file) => !referenced.has(file));
}

/**
 * @param {{ dryRun?: boolean }} [options]
 * @returns {{ seed: any, command: string, argv: string[] }}
 */
export function resolveReproduction(seed, { dryRun = false } = {}) {
  const command = buildReproCommand(seed);
  const argv = parseReproCommand(command);
  if (!dryRun) {
    execFileSync(argv[0], argv.slice(1), { stdio: "inherit", cwd: REPO_ROOT });
  }
  return { seed, command, argv };
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(__filename)) {
  const argv = process.argv.slice(2);
  const listOnly = argv.includes("--list");
  const dryRun = argv.includes("--dry-run");
  const asJson = argv.includes("--json");
  const positional = argv.filter((token) => !token.startsWith("--"));

  try {
    const manifest = loadSeedManifest();
    const problems = validateSeedManifest(manifest.seeds);
    const orphans = findOrphanSequences(manifest.seeds);
    if (problems.length > 0 || orphans.length > 0) {
      for (const problem of problems) console.error(`FAILED: ${problem}`);
      for (const orphan of orphans) console.error(`FAILED: ${SEED_DIR}/${orphan} is not referenced by any seed`);
      process.exit(1);
    }

    if (listOnly) {
      if (asJson) {
        console.log(JSON.stringify(manifest.seeds, null, 2));
      } else {
        for (const seed of manifest.seeds) {
          console.log(`${seed.id}\t${seed.state}\t${seed.invariantContract}::${seed.invariant}`);
          console.log(`    ${seed.summary}`);
          console.log(`    ${seed.repro}`);
        }
      }
      process.exit(0);
    }

    const seedId = positional[0];
    if (!seedId) {
      console.error("FAILED: provide a seed id, or --list to enumerate registered seeds");
      process.exit(1);
    }
    const seed = findSeed(manifest.seeds, seedId);
    const reproduction = resolveReproduction(seed, { dryRun });
    if (dryRun) {
      console.log(reproduction.command);
    }
    process.exit(0);
  } catch (error) {
    console.error(
      `FAILED: ${error instanceof SeedManifestError ? error.message : `could not reproduce the seed (${error.message})`}`
    );
    process.exit(1);
  }
}
