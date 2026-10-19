/**
 * Automated Upgradeable Storage Layout Compatibility Validator (V2-SC-046).
 *
 * Compares the storage layout of every tracked upgradeable contract against a
 * committed baseline manifest (`config/storage-layouts.json`) using the same
 * compatibility engine that backs the OpenZeppelin upgrades plugins
 * (`@openzeppelin/upgrades-core`). Any unsafe layout change — slot deletion,
 * variable reordering, type mutation, inheritance reordering, or unsafe gap
 * consumption — makes the comparison fail and blocks the change from being
 * merged or deployed.
 *
 * Usage:
 *   npx tsx scripts/validateStorageLayouts.ts           # validate (CI / pre-upgrade gate)
 *   npx tsx scripts/validateStorageLayouts.ts --update  # regenerate the manifest after an
 *                                                       # INTENTIONAL layout change
 *
 * The manifest is a review artifact: any diff to it must be justified in the PR
 * together with the migration/upgrade plan for the affected module.
 *
 * Policy (docs/upgrade-framework.md, "Storage compatibility policy"):
 * - Same-major upgrades must keep layouts append-only.
 * - Layout-breaking changes require a validated migration before approval.
 */

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);

// These libraries are CommonJS; require them explicitly so named exports always
// resolve, regardless of the module system of the caller.
const upgradesCore: any = require("@openzeppelin/upgrades-core");
const astUtils: any = require("solidity-ast/utils");

/** Path of the committed baseline manifest (relative to the project root). */
export const MANIFEST_PATH = path.join("config", "storage-layouts.json");

/** Directory holding Hardhat build-info files (relative to the project root). */
export const BUILD_INFO_DIR = path.join("artifacts", "build-info");

/** Root directory scanned for storage gaps that must be tracked. */
const CONTRACTS_DIR = "contracts";

/** Directories excluded from the storage-gap scan. */
const GAP_SCAN_EXCLUDED = new Set(["mocks", "test"]);

export interface TrackedContract {
  /** Contract name as it appears in the source file. */
  name: string;
  /** Source file path relative to the project root. */
  file: string;
  /** Why this contract is tracked. */
  note: string;
}

/**
 * Contracts whose storage layout is versioned in the baseline manifest.
 *
 * A contract must be listed here when it is deployed behind a proxy (or is a
 * base class of one): i.e. it declares a storage gap, inherits a contract that
 * does (e.g. GovernanceOwnable), or inherits UUPSUpgradeable.
 */
export const TRACKED_CONTRACTS: TrackedContract[] = [
  { name: "TruthBountyToken", file: "contracts/TruthBounty.sol", note: "UUPS proxy token module" },
  { name: "TruthBounty", file: "contracts/TruthBounty.sol", note: "inherits GovernanceOwnable (gap)" },
  { name: "DisputeResolution", file: "contracts/DisputeResolution.sol", note: "declares __gap" },
  { name: "StakeVault", file: "contracts/StakeVault.sol", note: "declares __gap" },
  { name: "ClaimLifecycle", file: "contracts/ClaimLifecycle.sol", note: "declares __gap" },
  { name: "WeightedStaking", file: "contracts/WeightedStaking.sol", note: "inherits GovernanceOwnable (gap)" },
  { name: "VerifierSlashing", file: "contracts/VerifierSlashing.sol", note: "inherits GovernanceOwnable (gap)" },
  { name: "VerificationRoundManager", file: "contracts/VerificationRoundManager.sol", note: "declares __gap" },
  { name: "FeeManager", file: "contracts/fees/FeeManager.sol", note: "declares __gap + GovernanceOwnable" },
  { name: "TokenomicsEngine", file: "contracts/tokenomics/TokenomicsEngine.sol", note: "declares __gap" },
  { name: "ReputationEngine", file: "contracts/reputation/ReputationEngine.sol", note: "declares __gap + GovernanceOwnable" },
  { name: "ReputationDecay", file: "contracts/ReputationDecay.sol", note: "declares __gap + GovernanceOwnable" },
  { name: "RewardEngine", file: "contracts/reward/RewardEngine.sol", note: "inherits GovernanceOwnable (gap)" },
  { name: "BootstrapController", file: "contracts/bootstrap/BootstrapController.sol", note: "inherits GovernanceOwnable (gap)" },
  { name: "MigrationManager", file: "contracts/deployment/MigrationManager.sol", note: "inherits GovernanceOwnable (gap)" },
  { name: "TreasuryManagement", file: "contracts/treasury/TreasuryManagement.sol", note: "declares __gap + GovernanceOwnable" },
  { name: "TreasuryAccounting", file: "contracts/treasury/TreasuryAccounting.sol", note: "inherits GovernanceOwnable (gap)" },
  { name: "InsuranceFund", file: "contracts/insurance/InsuranceFund.sol", note: "inherits GovernanceOwnable (gap)" },
  { name: "ProvisionalSettlementEngine", file: "contracts/settlement/ProvisionalSettlementEngine.sol", note: "inherits GovernanceOwnable (gap)" },
  { name: "AppealVerificationRound", file: "contracts/disputes/AppealVerificationRound.sol", note: "inherits GovernanceOwnable (gap)" },
  { name: "ReputationUpdateEngine", file: "contracts/ReputationUpdateEngine.sol", note: "inherits GovernanceOwnable (gap)" },
  { name: "TimelockOwnedProxyAdmin", file: "contracts/upgrade/TimelockOwnedProxyAdmin.sol", note: "declares __gap" },
  { name: "MockUpgradeable", file: "contracts/MockUpgradeable.sol", note: "UUPS test target" },
];

export interface StorageLayoutEntry {
  file: string;
  solcVersion: string;
  storage: Array<Record<string, unknown>>;
  types: Record<string, Record<string, unknown>>;
}

export interface LayoutManifest {
  schemaVersion: number;
  generator: string;
  solcVersion: string;
  contracts: Record<string, StorageLayoutEntry>;
}

export interface LayoutValidationResult {
  passed: boolean;
  issues: string[];
  checked: string[];
}

/** Remove compiler-internal metadata (astId/src) that churns without semantic change. */
function stripMeta(item: Record<string, unknown>): Record<string, unknown> {
  const { astId: _astId, src: _src, ...rest } = item;
  return rest;
}

/** Normalize an extracted layout into the stable form stored in the manifest. */
export function stabilizeLayout(layout: any): {
  storage: Array<Record<string, unknown>>;
  types: Record<string, Record<string, unknown>>;
} {
  const storage = (layout.storage ?? []).map(stripMeta);
  const types: Record<string, Record<string, unknown>> = {};
  for (const key of Object.keys(layout.types ?? {}).sort()) {
    const entry = stripMeta(layout.types[key]);
    if (Array.isArray(entry.members)) {
      // Struct members are objects and may carry compiler metadata; enum members
      // are plain strings and must be preserved verbatim.
      entry.members = (entry.members as Array<Record<string, unknown>>).map((m) =>
        typeof m === "string" ? m : stripMeta(m),
      );
    }
    types[key] = entry;
  }
  return { storage, types };
}

/**
 * Extract the storage layout of every tracked contract from the most recent
 * Hardhat build-info. Requires a prior `npx hardhat compile --force`.
 */
export function loadCurrentLayouts(
  buildInfoDir: string = BUILD_INFO_DIR,
): Record<string, StorageLayoutEntry> {
  const dirAbs = path.resolve(buildInfoDir);
  if (!fs.existsSync(dirAbs)) {
    throw new Error(
      `Build-info directory not found: ${buildInfoDir}. Run \`npx hardhat compile --force\` first.`,
    );
  }
  const outputFiles = fs
    .readdirSync(dirAbs)
    .filter((f) => f.endsWith(".output.json"))
    .sort(
      (a, b) =>
        fs.statSync(path.join(dirAbs, b)).mtimeMs - fs.statSync(path.join(dirAbs, a)).mtimeMs,
    );
  if (outputFiles.length === 0) {
    throw new Error(
      `No *.output.json build-info found in ${buildInfoDir}. Run \`npx hardhat compile --force\` first.`,
    );
  }

  const outputName = outputFiles[0];
  const inputName = outputName.replace(/\.output\.json$/, ".json");
  const solcOutput = JSON.parse(
    fs.readFileSync(path.join(dirAbs, outputName), "utf8"),
  ).output;
  const solcVersion: string = JSON.parse(fs.readFileSync(path.join(dirAbs, inputName), "utf8"))
    .solcVersion as string;

  const deref = astUtils.astDereferencer(solcOutput);
  const layouts: Record<string, StorageLayoutEntry> = {};

  for (const tracked of TRACKED_CONTRACTS) {
    const sourceKey = `project/${tracked.file}`;
    const sourceAst = solcOutput.sources?.[sourceKey]?.ast;
    if (!sourceAst) {
      throw new Error(`Source not found in build-info: ${tracked.file}`);
    }
    const contractDefs = Array.from(
      astUtils.findAll("ContractDefinition", sourceAst),
    ) as Array<any>;
    const contractDef = contractDefs.find((c) => c.name === tracked.name);
    if (!contractDef) {
      throw new Error(`Contract ${tracked.name} not found in ${tracked.file}`);
    }
    if (contractDef.contractKind !== "contract" || contractDef.abstract) {
      throw new Error(`${tracked.name} is abstract; tracked contracts must be concrete`);
    }
    const rawLayout = solcOutput.contracts?.[sourceKey]?.[tracked.name]?.storageLayout;
    if (!rawLayout) {
      throw new Error(
        `No storageLayout output for ${tracked.name}. Ensure hardhat.config.ts includes ` +
          `"storageLayout" in solidity.settings.outputSelection and recompile with ` +
          `\`npx hardhat compile --force\`.`,
      );
    }
    const extracted = upgradesCore.extractStorageLayout(contractDef, () => "", deref, rawLayout);
    layouts[tracked.name] = { file: tracked.file, solcVersion, ...stabilizeLayout(extracted) };
  }

  return layouts;
}

/** Load the committed baseline manifest. */
export function loadBaselineManifest(manifestPath: string = MANIFEST_PATH): LayoutManifest {
  if (!fs.existsSync(manifestPath)) {
    throw new Error(
      `Storage layout manifest not found: ${manifestPath}. Generate it with ` +
        `\`npx tsx scripts/validateStorageLayouts.ts --update\`.`,
    );
  }
  return JSON.parse(fs.readFileSync(manifestPath, "utf8")) as LayoutManifest;
}

/**
 * Assert that migrating from `baseline` to `updated` preserves storage layout
 * compatibility. Throws with a human-readable explanation on any unsafe change.
 */
export function assertLayoutCompatible(baseline: any, updated: any): void {
  upgradesCore.assertStorageUpgradeSafe(
    { storage: baseline.storage, types: baseline.types },
    { storage: updated.storage, types: updated.types },
  );
}

function* walkSolFiles(dir: string): Generator<string> {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (GAP_SCAN_EXCLUDED.has(entry.name)) continue;
      yield* walkSolFiles(full);
    } else if (entry.isFile() && entry.name.endsWith(".sol")) {
      yield full;
    }
  }
}

/**
 * Fail-closed guard: every concrete contract under contracts/ that declares a
 * storage gap must be explicitly tracked, so new upgradeable modules cannot
 * silently bypass the layout gate.
 */
export function findUntrackedGapContracts(
  trackedNames: string[] = TRACKED_CONTRACTS.map((c) => c.name),
  rootDir: string = CONTRACTS_DIR,
): string[] {
  const untracked: string[] = [];
  for (const file of walkSolFiles(rootDir)) {
    const content = fs.readFileSync(file, "utf8");
    if (!/uint256\[\d+\]\s+private\s+__gap/.test(content)) continue;
    // Concrete contract declarations only (abstract bases are reached through
    // their derived contracts' layouts).
    for (const match of content.matchAll(/^\s*contract\s+(\w+)/gm)) {
      const name = match[1];
      if (!trackedNames.includes(name)) untracked.push(`${name} (${file})`);
    }
  }
  return untracked.sort();
}

/** Write the baseline manifest from the current compiled layouts. */
export function writeManifest(
  manifestPath: string,
  layouts: Record<string, StorageLayoutEntry>,
): void {
  const solcVersions = new Set(Object.values(layouts).map((l) => l.solcVersion));
  const manifest: LayoutManifest = {
    schemaVersion: 1,
    generator: "scripts/validateStorageLayouts.ts (V2-SC-046, @openzeppelin/upgrades-core)",
    solcVersion: solcVersions.size === 1 ? [...solcVersions][0] : "mixed",
    contracts: layouts,
  };
  fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

/**
 * Validate the current compiled storage layouts against the committed baseline.
 *
 * Throws on incompatibility so callers (tests, CI) fail closed. With
 * `update: true`, regenerates the manifest instead of validating.
 */
export async function validateStorageLayouts(
  opts: { update?: boolean; manifestPath?: string; buildInfoDir?: string } = {},
): Promise<LayoutValidationResult> {
  const manifestPath = opts.manifestPath ?? MANIFEST_PATH;
  const trackedNames = TRACKED_CONTRACTS.map((c) => c.name);

  if (opts.update) {
    writeManifest(manifestPath, loadCurrentLayouts(opts.buildInfoDir));
    return { passed: true, issues: [], checked: trackedNames };
  }

  const issues: string[] = [];

  let current: Record<string, StorageLayoutEntry>;
  try {
    current = loadCurrentLayouts(opts.buildInfoDir);
  } catch (err) {
    return { passed: false, issues: [(err as Error).message], checked: [] };
  }

  let manifest: LayoutManifest;
  try {
    manifest = loadBaselineManifest(manifestPath);
  } catch (err) {
    return { passed: false, issues: [(err as Error).message], checked: Object.keys(current) };
  }

  const manifestContracts = manifest.contracts ?? {};
  const manifestNames = Object.keys(manifestContracts);

  for (const tracked of TRACKED_CONTRACTS) {
    const baseline = manifestContracts[tracked.name];
    if (baseline === undefined) {
      issues.push(
        `${tracked.name}: missing from manifest — run \`npx tsx scripts/validateStorageLayouts.ts --update\` after review.`,
      );
      continue;
    }
    try {
      assertLayoutCompatible(baseline, current[tracked.name]);
    } catch (err) {
      issues.push(`${tracked.name}: ${(err as Error).message}`);
    }
  }

  for (const name of manifestNames) {
    if (!trackedNames.includes(name)) {
      issues.push(
        `${name}: present in manifest but not tracked — remove it from the manifest or add it to TRACKED_CONTRACTS in scripts/validateStorageLayouts.ts`,
      );
    }
  }

  for (const untracked of findUntrackedGapContracts(trackedNames)) {
    issues.push(
      `${untracked}: declares a storage gap but is not tracked — add it to TRACKED_CONTRACTS in scripts/validateStorageLayouts.ts, regenerate the manifest with --update, and commit the result`,
    );
  }

  return { passed: issues.length === 0, issues, checked: trackedNames };
}

const isMain =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain) {
  const update = process.argv.includes("--update");
  validateStorageLayouts({ update })
    .then((result) => {
      if (update) {
        console.log(`✅ Storage layout manifest regenerated at ${MANIFEST_PATH}`);
        console.log(`   Contracts tracked: ${TRACKED_CONTRACTS.length}`);
        console.log(
          "   Review the diff carefully: every layout change must be justified by an explicit upgrade plan.",
        );
        return;
      }
      console.log("==================================================");
      console.log("Upgradeable Storage Layout Compatibility (V2-SC-046)");
      console.log("==================================================");
      for (const name of result.checked) {
        console.log(`✅ ${name}: layout compatible`);
      }
      if (result.passed) {
        console.log(`\nAll ${result.checked.length} tracked upgradeable layouts verified successfully.`);
      } else {
        console.error(`\n❌ Storage layout validation failed with ${result.issues.length} issue(s):`);
        for (const issue of result.issues) console.error(` - ${issue}`);
        process.exitCode = 1;
      }
    })
    .catch((err: unknown) => {
      console.error(err instanceof Error ? err.message : err);
      process.exitCode = 1;
    });
}
