import { expect } from "chai";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  COMPAT_MATRIX_DOC,
  COMPAT_MATRIX_JSON,
  COMPAT_PROTOCOL_VERSION,
  INTENTIONAL_AGGREGATE_OMISSIONS,
  INTENTIONAL_EVENT_NAME_COLLISIONS,
  buildCompatibilityMatrix,
  checkCompatibility,
  renderCompatibilityMatrix,
  resolveEffectiveSurfaces,
} from "../scripts/checkInterfaceCompatibility";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.join(__dirname, "..");

describe("Protocol interface compatibility matrix (V2-SC-135)", function () {
  it("builds a deterministic matrix with a checksum digest", function () {
    const first = buildCompatibilityMatrix(rootDir);
    const second = buildCompatibilityMatrix(rootDir);
    expect(first.digest).to.equal(second.digest);
    expect(first.digest).to.match(/^0x[0-9a-f]{64}$/);
    expect(first.modules.map((row) => row.digest)).to.deep.equal(second.modules.map((row) => row.digest));
  });

  it("keeps the committed matrix and document in sync with the sources", function () {
    expect(checkCompatibility(rootDir)).to.deep.equal([]);
  });

  it("passes every compatibility invariant", function () {
    const matrix = buildCompatibilityMatrix(rootDir);
    const failed = matrix.invariants.filter((invariant) => invariant.status === "fail");
    expect(failed, JSON.stringify(failed)).to.deep.equal([]);
  });

  it("assigns a distinct ERC-165 interface id to every canonical module", function () {
    const modules = buildCompatibilityMatrix(rootDir).modules.filter((row) => row.kind === "module");
    const ids = modules.map((row) => row.interfaceId);
    expect(new Set(ids).size).to.equal(ids.length);
    for (const interfaceId of ids) expect(interfaceId).to.match(/^0x[0-9a-f]{8}$/);
  });

  it("documents every cross-module shared selector instead of sharing silently", function () {
    const matrix = buildCompatibilityMatrix(rootDir);
    const surfaces = resolveEffectiveSurfaces(matrix.modules);
    for (const entry of matrix.sharedFunctions) {
      expect(entry.intentional, `${entry.signature} is shared without documentation`).to.equal(true);
      expect(entry.modules.length).to.be.greaterThan(1);
      for (const moduleName of entry.modules) {
        const surface = surfaces.get(moduleName);
        expect(surface, `${moduleName} missing from the matrix`).to.not.equal(undefined);
        expect(surface!.functions.some((fn) => fn.signature === entry.signature)).to.equal(true);
      }
    }
  });

  it("documents every duplicated event name as topic0-distinguished", function () {
    const matrix = buildCompatibilityMatrix(rootDir);
    for (const collision of matrix.eventNameCollisions) {
      expect(collision.signatures.length).to.be.greaterThan(1);
      expect(Object.prototype.hasOwnProperty.call(INTENTIONAL_EVENT_NAME_COLLISIONS, collision.name)).to.equal(true);
    }
  });

  it("treats ICanonicalV2 as a pure manifest and records undocumented omissions", function () {
    const matrix = buildCompatibilityMatrix(rootDir);
    expect(matrix.aggregateManifest.name).to.equal("ICanonicalV2");
    expect(matrix.aggregateManifest.declaredMembers).to.equal(0);
    expect(matrix.aggregateManifest.inherits.length).to.be.at.least(15);
    expect(matrix.aggregateManifest.undocumentedOmissions).to.deep.equal([]);
    for (const omission of matrix.aggregateManifest.notNamed) {
      expect(Object.prototype.hasOwnProperty.call(INTENTIONAL_AGGREGATE_OMISSIONS, omission)).to.equal(true);
    }
  });

  it("reconciles the canonical surface against the published event schema", function () {
    const matrix = buildCompatibilityMatrix(rootDir);
    expect(matrix.crossArtifacts.publishedEventTopics).to.be.greaterThan(0);
    expect(matrix.crossArtifacts.canonicalEventTopics).to.be.greaterThan(0);
    expect(matrix.crossArtifacts.publishedTopicOverlap).to.be.at.most(matrix.crossArtifacts.canonicalEventTopics);
    expect(matrix.crossArtifacts.documentedDivergences.length).to.be.greaterThan(0);
    expect(matrix.crossArtifacts.versionFixtureDeclaration).to.equal(
      `${COMPAT_PROTOCOL_VERSION.major}.${COMPAT_PROTOCOL_VERSION.minor}`
    );
  });

  it("fails closed on matrix drift", function () {
    const committed = JSON.parse(fs.readFileSync(path.join(rootDir, COMPAT_MATRIX_JSON), "utf-8"));
    const current = buildCompatibilityMatrix(rootDir);
    expect(committed.digest).to.equal(current.digest);
    expect(fs.readFileSync(path.join(rootDir, COMPAT_MATRIX_DOC), "utf-8")).to.equal(renderCompatibilityMatrix(current));

    const mutated = JSON.parse(JSON.stringify(current));
    mutated.modules[0].interfaceId = "0xdeadbeef";
    expect(mutated.modules[0].interfaceId).to.not.equal(committed.modules[0].interfaceId);
  });
});
