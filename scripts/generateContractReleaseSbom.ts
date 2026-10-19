/**
 * V2-SC-088 — Contract Release SBOM and Provenance Attestation
 *
 * Produces dependency, compiler, optimizer, source-commit, artifact-hash,
 * and workflow-identity metadata for every release candidate.
 * Fail-closed on invalid configuration. No Stellar/Soroban/Freighter runtime.
 */
import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";

export const SBOM_SCHEMA_VERSION = 1;
export const PREDICATE_TYPE =
  "https://truthbounty.protocol/attestation/contract-release/v1";

export const FORBIDDEN_RUNTIME_PACKAGES = [
  "stellar",
  "@stellar/stellar-sdk",
  "@stellar/freighter-api",
  "freighter-api",
  "soroban-client",
  "@stellar/soroban-client",
] as const;

/** Canonical V2 contract sources included in release SBOM subjects. */
export const CANONICAL_RELEASE_SOURCES = [
  "contracts/ClaimRegistry.sol",
  "contracts/TruthBounty.sol",
  "contracts/VerificationSubmission.sol",
  "contracts/WeightedStaking.sol",
  "contracts/EvidenceManager.sol",
  "hardhat.config.ts",
  "foundry.toml",
  "package.json",
  "package-lock.json",
] as const;

export interface CompilerSettings {
  solidity: string;
  evmVersion: string;
  viaIR: boolean;
  optimizer: { enabled: boolean; runs: number };
}

export interface DependencyEntry {
  name: string;
  version: string;
  kind: "npm" | "git-submodule";
  rev?: string;
  integrity?: string;
}

export interface ArtifactHash {
  path: string;
  sha256: string;
  bytes: number;
}

export interface WorkflowIdentity {
  present: boolean;
  repository?: string;
  workflow?: string;
  workflowRef?: string;
  runId?: string;
  runAttempt?: string;
  ref?: string;
  sha?: string;
  serverUrl?: string;
}

export interface ContractReleaseSbom {
  schemaVersion: number;
  kind: "truthbounty.contract-release-sbom+provenance";
  protocol: string;
  releaseVersion: string;
  generatedAt: string;
  sourceCommit: string;
  compiler: CompilerSettings;
  dependencies: DependencyEntry[];
  artifacts: ArtifactHash[];
  workflowIdentity: WorkflowIdentity;
  attestation: {
    predicateType: string;
    subjects: Array<{ name: string; digest: { sha256: string } }>;
    materials: Array<{ uri: string; digest?: { sha256: string } }>;
  };
  checksum: string;
}

export interface GenerateOptions {
  rootDir: string;
  sourceCommit?: string;
  releaseVersion?: string;
  now?: Date;
  env?: NodeJS.ProcessEnv;
  /** Extra artifact paths relative to root (fail-closed if missing). */
  extraArtifacts?: string[];
}

export class SbomError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SbomError";
  }
}

function sha256Hex(content: string | Buffer): string {
  return crypto.createHash("sha256").update(content).digest("hex");
}

export function assertValidSourceCommit(commit: string): string {
  const normalized = (commit || "").trim().toLowerCase();
  if (!/^[0-9a-f]{40}$/.test(normalized)) {
    throw new SbomError(
      `Invalid sourceCommit: expected 40-char lowercase hex SHA, got ${JSON.stringify(commit)}`
    );
  }
  return normalized;
}

export function assertNoForbiddenRuntimeDeps(
  packageJson: Record<string, unknown>
): void {
  const sections = ["dependencies", "optionalDependencies", "peerDependencies"] as const;
  for (const section of sections) {
    const bag = packageJson[section];
    if (!bag || typeof bag !== "object") continue;
    for (const name of Object.keys(bag as Record<string, unknown>)) {
      const lower = name.toLowerCase();
      if (
        lower.includes("stellar") ||
        lower.includes("soroban") ||
        lower.includes("freighter") ||
        (FORBIDDEN_RUNTIME_PACKAGES as readonly string[]).includes(name)
      ) {
        throw new SbomError(
          `Forbidden runtime dependency ${name} in ${section}: Optimism/EVM only (no Stellar/Soroban/Freighter)`
        );
      }
    }
  }
}

export function parseHardhatCompiler(hardhatConfigSource: string): CompilerSettings {
  const versionMatch = hardhatConfigSource.match(
    /solidity\s*:\s*\{[\s\S]*?version\s*:\s*["']([^"']+)["']/
  );
  const evmMatch = hardhatConfigSource.match(/evmVersion\s*:\s*["']([^"']+)["']/);
  const viaIrMatch = hardhatConfigSource.match(/viaIR\s*:\s*(true|false)/);
  const optEnabledMatch = hardhatConfigSource.match(
    /optimizer\s*:\s*\{[\s\S]*?enabled\s*:\s*(true|false)/
  );
  const optRunsMatch = hardhatConfigSource.match(
    /optimizer\s*:\s*\{[\s\S]*?runs\s*:\s*(\d+)/
  );

  if (!versionMatch) {
    throw new SbomError("hardhat.config.ts missing solidity.version");
  }
  const enabled = optEnabledMatch ? optEnabledMatch[1] === "true" : false;
  const runs = optRunsMatch ? parseInt(optRunsMatch[1], 10) : 0;
  if (enabled && (!Number.isFinite(runs) || runs <= 0)) {
    throw new SbomError("optimizer.enabled=true requires positive optimizer.runs");
  }

  return {
    solidity: versionMatch[1],
    evmVersion: evmMatch ? evmMatch[1] : "default",
    viaIR: viaIrMatch ? viaIrMatch[1] === "true" : false,
    optimizer: { enabled, runs },
  };
}

export function collectNpmDependencies(
  packageJson: Record<string, unknown>
): DependencyEntry[] {
  const out: DependencyEntry[] = [];
  for (const section of ["dependencies", "devDependencies"] as const) {
    const bag = packageJson[section];
    if (!bag || typeof bag !== "object") continue;
    for (const [name, version] of Object.entries(bag as Record<string, string>)) {
      out.push({ name, version: String(version), kind: "npm" });
    }
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out;
}

export function collectFoundryLockDeps(foundryLockRaw: string | null): DependencyEntry[] {
  if (!foundryLockRaw) return [];
  let parsed: Record<string, { rev?: string }>;
  try {
    parsed = JSON.parse(foundryLockRaw);
  } catch {
    throw new SbomError("foundry.lock is not valid JSON");
  }
  const out: DependencyEntry[] = [];
  for (const [name, meta] of Object.entries(parsed)) {
    if (!meta || typeof meta !== "object" || !meta.rev) {
      throw new SbomError(`foundry.lock entry ${name} missing rev`);
    }
    if (!/^[0-9a-f]{7,40}$/i.test(meta.rev)) {
      throw new SbomError(`foundry.lock entry ${name} has invalid rev`);
    }
    out.push({
      name,
      version: meta.rev,
      kind: "git-submodule",
      rev: meta.rev.toLowerCase(),
    });
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out;
}

export function resolveSourceCommit(
  explicit: string | undefined,
  env: NodeJS.ProcessEnv
): string {
  const candidate =
    explicit ||
    env.RELEASE_SOURCE_COMMIT ||
    env.GITHUB_SHA ||
    env.SOURCE_COMMIT ||
    "";
  return assertValidSourceCommit(candidate);
}

export function readWorkflowIdentity(env: NodeJS.ProcessEnv): WorkflowIdentity {
  const repository = env.GITHUB_REPOSITORY;
  const workflow = env.GITHUB_WORKFLOW;
  const runId = env.GITHUB_RUN_ID;
  if (!repository && !workflow && !runId) {
    return { present: false };
  }
  // Fail closed: partial CI identity is invalid for release attestation.
  if (!repository || !workflow || !runId) {
    throw new SbomError(
      "Incomplete workflow identity: GITHUB_REPOSITORY, GITHUB_WORKFLOW, and GITHUB_RUN_ID are all required when any CI var is set"
    );
  }
  return {
    present: true,
    repository,
    workflow,
    workflowRef: env.GITHUB_WORKFLOW_REF,
    runId,
    runAttempt: env.GITHUB_RUN_ATTEMPT,
    ref: env.GITHUB_REF,
    sha: env.GITHUB_SHA ? env.GITHUB_SHA.toLowerCase() : undefined,
    serverUrl: env.GITHUB_SERVER_URL || "https://github.com",
  };
}

function safeRead(rootDir: string, relPath: string): Buffer {
  const posix = relPath.replace(/\\/g, "/");
  if (posix.startsWith("/") || posix.split("/").includes("..")) {
    throw new SbomError(`Path traversal rejected: ${relPath}`);
  }
  const normalized = path.normalize(posix);
  if (normalized.split(path.sep).includes("..")) {
    throw new SbomError(`Path traversal rejected: ${relPath}`);
  }
  const abs = path.join(rootDir, normalized);
  const rootAbs = path.resolve(rootDir);
  if (!path.resolve(abs).startsWith(rootAbs + path.sep) && path.resolve(abs) !== rootAbs) {
    throw new SbomError(`Artifact path escapes repository root: ${relPath}`);
  }
  if (!fs.existsSync(abs)) {
    throw new SbomError(`Required release artifact missing: ${relPath}`);
  }
  return fs.readFileSync(abs);
}

export function hashArtifacts(
  rootDir: string,
  relativePaths: string[]
): ArtifactHash[] {
  const seen = new Set<string>();
  const out: ArtifactHash[] = [];
  for (const rel of relativePaths) {
    if (seen.has(rel)) continue;
    seen.add(rel);
    const buf = safeRead(rootDir, rel);
    out.push({
      path: rel.replace(/\\/g, "/"),
      sha256: sha256Hex(buf),
      bytes: buf.length,
    });
  }
  out.sort((a, b) => a.path.localeCompare(b.path));
  return out;
}

function stableChecksum(doc: Omit<ContractReleaseSbom, "checksum">): string {
  const canonical = JSON.stringify(doc);
  return sha256Hex(canonical);
}

export function generateContractReleaseSbom(
  options: GenerateOptions
): ContractReleaseSbom {
  const env = options.env || process.env;
  const rootDir = options.rootDir;
  if (!rootDir || !fs.existsSync(rootDir)) {
    throw new SbomError("rootDir does not exist");
  }

  const pkgPath = path.join(rootDir, "package.json");
  if (!fs.existsSync(pkgPath)) {
    throw new SbomError("package.json missing");
  }
  const packageJson = JSON.parse(fs.readFileSync(pkgPath, "utf-8")) as Record<
    string,
    unknown
  >;
  assertNoForbiddenRuntimeDeps(packageJson);

  const releaseVersion =
    (options.releaseVersion ||
      env.RELEASE_VERSION ||
      (typeof packageJson.version === "string" ? packageJson.version : "") ||
      "").trim();
  if (!releaseVersion || releaseVersion === "0.0.0") {
    throw new SbomError("releaseVersion is required and must not be 0.0.0");
  }

  const hardhatPath = path.join(rootDir, "hardhat.config.ts");
  if (!fs.existsSync(hardhatPath)) {
    throw new SbomError("hardhat.config.ts missing");
  }
  const compiler = parseHardhatCompiler(fs.readFileSync(hardhatPath, "utf-8"));

  const sourceCommit = resolveSourceCommit(options.sourceCommit, env);
  const workflowIdentity = readWorkflowIdentity(env);
  if (
    workflowIdentity.present &&
    workflowIdentity.sha &&
    workflowIdentity.sha !== sourceCommit
  ) {
    throw new SbomError(
      `sourceCommit ${sourceCommit} does not match GITHUB_SHA ${workflowIdentity.sha}`
    );
  }

  const foundryLockPath = path.join(rootDir, "foundry.lock");
  const foundryLockRaw = fs.existsSync(foundryLockPath)
    ? fs.readFileSync(foundryLockPath, "utf-8")
    : null;

  const dependencies = [
    ...collectNpmDependencies(packageJson),
    ...collectFoundryLockDeps(foundryLockRaw),
  ];

  const artifactPaths = [
    ...CANONICAL_RELEASE_SOURCES.filter((p) =>
      fs.existsSync(path.join(rootDir, p))
    ),
    ...(options.extraArtifacts || []),
  ];
  // Fail closed: every declared canonical source that exists must be hashed;
  // package.json and hardhat.config.ts are mandatory.
  for (const required of ["package.json", "hardhat.config.ts"] as const) {
    if (!artifactPaths.includes(required)) {
      throw new SbomError(`Mandatory artifact missing from hash set: ${required}`);
    }
  }
  const artifacts = hashArtifacts(rootDir, artifactPaths);

  const subjects = artifacts.map((a) => ({
    name: a.path,
    digest: { sha256: a.sha256 },
  }));

  const materials: Array<{ uri: string; digest?: { sha256: string } }> = [
    { uri: `git+https://github.com/DigiNodes/truthbounty-contract@${sourceCommit}` },
  ];
  for (const dep of dependencies) {
    if (dep.kind === "git-submodule" && dep.rev) {
      materials.push({
        uri: `git+submodule:${dep.name}@${dep.rev}`,
        digest: { sha256: sha256Hex(dep.rev) },
      });
    } else {
      materials.push({ uri: `pkg:npm/${dep.name}@${dep.version}` });
    }
  }

  const generatedAt = (options.now || new Date()).toISOString();
  const partial: Omit<ContractReleaseSbom, "checksum"> = {
    schemaVersion: SBOM_SCHEMA_VERSION,
    kind: "truthbounty.contract-release-sbom+provenance",
    protocol: "TruthBounty",
    releaseVersion,
    generatedAt,
    sourceCommit,
    compiler,
    dependencies,
    artifacts,
    workflowIdentity,
    attestation: {
      predicateType: PREDICATE_TYPE,
      subjects,
      materials,
    },
  };

  return { ...partial, checksum: stableChecksum(partial) };
}

export function writeContractReleaseSbom(
  options: GenerateOptions,
  outPath?: string
): { sbom: ContractReleaseSbom; outPath: string } {
  const sbom = generateContractReleaseSbom(options);
  const target =
    outPath ||
    path.join(
      options.rootDir,
      "deployments",
      "sbom",
      `contract-release-sbom-${sbom.releaseVersion}.json`
    );
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, JSON.stringify(sbom, null, 2) + "\n", "utf-8");
  return { sbom, outPath: target };
}

if (require.main === module) {
  try {
    const rootDir = process.cwd();
    const { sbom, outPath } = writeContractReleaseSbom({ rootDir });
    console.log(`Wrote contract release SBOM + provenance → ${outPath}`);
    console.log(`sourceCommit=${sbom.sourceCommit}`);
    console.log(`checksum=${sbom.checksum}`);
    console.log(`artifacts=${sbom.artifacts.length} dependencies=${sbom.dependencies.length}`);
    process.exit(0);
  } catch (err) {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  }
}
