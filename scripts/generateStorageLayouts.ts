/**
 * Storage-layout manifest generator / CI checker (V2-SC-121).
 *
 * Compiles the tracked upgradeable contracts with solc 0.8.28 (the exact
 * compiler version and optimizer settings used by hardhat.config.ts) and
 * produces the frozen storage-layout manifest.
 *
 * Modes:
 *   --update   regenerate storage-layouts/manifest.json (freeze / re-freeze)
 *   --check    regenerate in memory and fail on unapproved drift (CI mode)
 *   --print    print the freshly generated manifest to stdout
 *
 * solc input is assembled to mirror hardhat.config.ts (0.8.28, via-IR,
 * optimizer 200, cancun) plus the `storageLayout` compiler output selector.
 */

/// <reference path="../types/solc.d.ts" />

import * as fs from "fs";
import * as path from "path";
import * as solc from "solc";
import { ethers } from "ethers";
import {
  TRACKED_STORAGE_CONTRACTS,
  MANIFEST_SCHEMA_VERSION,
  TOOL_NAME,
  TOOL_VERSION,
  MAX_TRACKED_CONTRACTS,
  MAX_TRACKED_SLOTS,
  emptyManifest,
  addContract,
  serializeManifest,
  extractSlots,
  readFrozenManifest,
  writeFrozenManifest,
  readApprovedDrift,
  classifyManifestDrift,
  type StorageLayoutManifest,
  type ContractManifest,
} from "./storageLayoutManifest";

const ROOT = path.resolve(__dirname, "..");
const SOLC_VERSION_PIN = "0.8.28";

// ---------------------------------------------------------------------------
// solc input assembly
// ---------------------------------------------------------------------------

const NODE_MODULES = path.join(ROOT, "node_modules");
const LIB_DIRS = [NODE_MODULES, path.join(NODE_MODULES, "@openzeppelin", "contracts")];

/** Resolve import paths the way solc's callback would, mirroring remappings. */
function resolveImportPath(importPath: string): string | null {
  const remapped = importPath
    .replace(/^@openzeppelin\/contracts-upgradeable\//, path.join("node_modules", "@openzeppelin", "contracts-upgradeable") + "/")
    .replace(/^@openzeppelin\/contracts\//, path.join("node_modules", "@openzeppelin", "contracts") + "/")
    .replace(/^forge-std\//, path.join("node_modules", "forge-std", "src") + "/");
  const candidates = remapped === importPath
    ? [path.join(ROOT, importPath), path.join(NODE_MODULES, importPath)]
    : [path.join(ROOT, remapped), path.join(ROOT, importPath), path.join(NODE_MODULES, importPath)];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

function readRemappings(): Array<{ from: string; to: string }> {
  const file = path.join(ROOT, "remappings.txt");
  if (!fs.existsSync(file)) return [];
  return fs
    .readFileSync(file, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith("//"))
    .map((line) => {
      const idx = line.indexOf("=");
      if (idx === -1) return null;
      return { from: line.slice(0, idx), to: line.slice(idx + 1) };
    })
    .filter((x): x is { from: string; to: string } => x !== null);
}

function applyRemappings(importPath: string, remappings: Array<{ from: string; to: string }>): string {
  for (const r of remappings) {
    if (importPath === r.from || importPath.startsWith(r.from.endsWith("/") ? r.from : r.from + "/")) {
      const suffix = importPath.slice(r.from.length);
      return path.join(ROOT, r.to, suffix.startsWith("/") ? suffix.slice(1) : suffix);
    }
  }
  return importPath;
}

/** Collect the full transitive source set for the tracked contracts. */
function collectSources(): { sources: Record<string, { content: string }>; entryUnits: Set<string> } {
  const remappings = readRemappings();
  const sources: Record<string, { content: string }> = {};
  const queue: string[] = TRACKED_STORAGE_CONTRACTS.map((c) => c.sourcePath);
  const seen = new Set<string>();
  const entryUnits = new Set<string>(TRACKED_STORAGE_CONTRACTS.map((c) => c.sourcePath));

  while (queue.length > 0) {
    const rel = queue.shift() as string;
    if (seen.has(rel)) continue;
    seen.add(rel);
    const abs = path.join(ROOT, rel);
    if (!fs.existsSync(abs)) {
      throw new Error(`collectSources: missing source file ${rel}`);
    }
    const content = fs.readFileSync(abs, "utf8");
    sources[rel] = { content };
    const importRe = /import\s+(?:"([^"]+)"|'([^']+)'|\{[^}]*\}\s*from\s*["']([^"']+)["']|[^;]*["']([^"']+)["'])/g;
    let m: RegExpExecArray | null;
    while ((m = importRe.exec(content)) !== null) {
      const raw = m[1] ?? m[2] ?? m[3] ?? m[4];
      if (!raw) continue;
      if (raw.startsWith("./") || raw.startsWith("../")) {
        const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(rel), raw));
        queue.push(resolved);
      } else {
        const remapped = applyRemappings(raw, remappings);
        const relResolved = path.relative(ROOT, remapped);
        queue.push(relResolved);
      }
    }
  }
  return { sources, entryUnits };
}

function buildSolcInput(sources: Record<string, { content: string }>) {
  return {
    language: "Solidity",
    sources,
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "cancun",
      viaIR: true,
      outputSelection: {
        "*": {
          "*": ["abi", "storageLayout"],
        },
      },
      remappings: readRemappings().map((r) => `${r.from}=${r.to}`),
    },
  };
}

// ---------------------------------------------------------------------------
// Compilation
// ---------------------------------------------------------------------------

interface SolcArtifact {
  storageLayout?: {
    storage: Array<{ astId: number; contract: string; label: string; offset: number; slot: string; type: string }>;
    types: Record<string, { encoding: string; label: string; numberOfBytes: string; base?: string }>;
  };
}

function compileAll(): Record<string, SolcArtifact> {
  const { sources } = collectSources();
  const input = buildSolcInput(sources);
  const serialized = JSON.stringify(input);
  const output = JSON.parse(solc.compile(serialized)) as {
    errors?: Array<{ severity: string; formattedMessage: string }>;
    contracts?: Record<string, Record<string, SolcArtifact>>;
  };

  const errors = (output.errors ?? []).filter((e) => e.severity === "error");
  if (errors.length > 0) {
    throw new Error(
      "solc compilation failed:\n" +
        errors.map((e) => e.formattedMessage).join("\n")
    );
  }

  const artifacts: Record<string, SolcArtifact> = {};
  const files = output.contracts ?? {};
  for (const fileKey of Object.keys(files)) {
    for (const contractName of Object.keys(files[fileKey])) {
      artifacts[contractName] = files[fileKey][contractName];
    }
  }
  if (process.env.DEBUG_DUMP_LAYOUT) {
    const name = process.env.DEBUG_DUMP_LAYOUT;
    fs.writeFileSync("/tmp/layout-dump.json", JSON.stringify(artifacts[name]?.storageLayout ?? {}, null, 2));
    console.error(`dumped ${name} layout to /tmp/layout-dump.json`);
  }
  return artifacts;
}

// ---------------------------------------------------------------------------
// Manifest generation
// ---------------------------------------------------------------------------

export function generateFreshManifest(solcVersionOverride?: string): StorageLayoutManifest {
  const artifacts = compileAll();
  const manifest = emptyManifest(solcVersionOverride ?? `${SOLC_VERSION_PIN}+pinned`);
  if (TRACKED_STORAGE_CONTRACTS.length > MAX_TRACKED_CONTRACTS) {
    throw new Error(`TRACKED_STORAGE_CONTRACTS exceeds MAX_TRACKED_CONTRACTS=${MAX_TRACKED_CONTRACTS}`);
  }
  for (const tracked of TRACKED_STORAGE_CONTRACTS) {
    const artifact = artifacts[tracked.name];
    if (artifact === undefined || artifact.storageLayout === undefined) {
      throw new Error(
        `generateFreshManifest: no storageLayout artifact for tracked contract '${tracked.name}' (${tracked.sourcePath})`
      );
    }
    const slots = extractSlots(artifact.storageLayout, tracked.name);
    if (Object.keys(slots).length > MAX_TRACKED_SLOTS) {
      throw new Error(`generateFreshManifest(${tracked.name}): slot count exceeds MAX_TRACKED_SLOTS=${MAX_TRACKED_SLOTS}`);
    }
    addContract(manifest, tracked, slots);
  }
  return manifest;
}

// ---------------------------------------------------------------------------
// CLI modes
// ---------------------------------------------------------------------------

function printDriftReport(report: ReturnType<typeof classifyManifestDrift>): void {
  const icons: Record<string, string> = {
    unchanged: "✅",
    approved: "✅",
    new: "➕",
    removed: "❌",
    "slot-drift": "❌",
    appended: "⚠️",
  };
  for (const finding of report.findings) {
    console.log(`${icons[finding.classification] ?? "•"} ${finding.contract}: ${finding.classification}`);
    for (const detail of finding.details) {
      console.log(`     ${detail}`);
    }
  }
}

function checkMode(): boolean {
  return checkStorageLayouts();
}

/** Programmatic check entry point (also used by scripts/validateStorageLayouts.ts). */
export function checkStorageLayouts(): boolean {
  const frozen = readFrozenManifest(ROOT);
  if (frozen === null) {
    console.error(
      `❌ ${path.join(ROOT, "storage-layouts/manifest.json")} not found.\n` +
        `   Generate and commit it first: npm run test:layouts:update`
    );
    return false;
  }

  const solcBuild = solc.version();
  if (!solcBuild.startsWith(SOLC_VERSION_PIN)) {
    console.error(
      `❌ solc version drift: installed solc ${solcBuild} does not match pinned ${SOLC_VERSION_PIN}.x`
    );
    return false;
  }
  if (!frozen.solc.startsWith(SOLC_VERSION_PIN)) {
    console.error(
      `❌ manifest was frozen with solc ${frozen.solc} but CI pins ${SOLC_VERSION_PIN}.x — re-freeze with the pinned compiler`
    );
    return false;
  }

  const fresh = generateFreshManifest(frozen.solc);
  const approved = readApprovedDrift(ROOT);
  const report = classifyManifestDrift(frozen, fresh, approved);

  console.log("==================================================");
  console.log("Canonical Storage-Layout Manifest Check (V2-SC-121)");
  console.log("==================================================");
  console.log(`frozen: solc ${frozen.solc}, ${Object.keys(frozen.contracts).length} contracts`);
  console.log("");

  printDriftReport(report);

  if (!report.pass) {
    console.log("");
    console.error("❌ Unapproved storage-layout drift detected.");
    console.error("");
    console.error("   To resolve:");
    console.error("   1. If intentional, run: npm run test:layouts:update");
    console.error("   2. Record the approved hash in storage-layouts/APPROVED_DRIFT.md:");
    console.error("      - `<Contract>` → `<newCanonicalHash>` (PR #NNN, classification)");
    console.error("   3. Obtain independent maintainer approval on the manifest diff PR.");
    return false;
  }

  console.log("");
  console.log(`✅ All ${Object.keys(fresh.contracts).length} tracked storage layouts match the frozen manifest.`);
  return true;
}

function updateMode(): void {
  const frozen = readFrozenManifest(ROOT);
  const fresh = generateFreshManifest(frozen?.solc);
  writeFrozenManifest(ROOT, fresh);
  console.log(
    `✅ Wrote ${path.join(ROOT, "storage-layouts/manifest.json")} ` +
      `(${Object.keys(fresh.contracts).length} contracts, solc ${fresh.solc}).`
  );
  if (frozen !== null) {
    const report = classifyManifestDrift(frozen, fresh, readApprovedDrift(ROOT));
    if (report.findings.length > 0) {
      console.log("Changes vs previously frozen manifest:");
      printDriftReport(report);
    }
  }
}

function main(): void {
  const mode = process.argv[2];
  switch (mode) {
    case "--update":
      updateMode();
      break;
    case "--check":
      process.exitCode = checkMode() ? 0 : 1;
      break;
    case "--print": {
      const manifest = generateFreshManifest();
      console.log(serializeManifest(manifest));
      break;
    }
    default:
      console.error("Usage: ts-node scripts/generateStorageLayouts.ts [--update|--check|--print]");
      process.exitCode = 2;
  }
}

if (require.main === module) {
  main();
}
