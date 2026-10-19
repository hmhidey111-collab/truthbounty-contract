import { expect } from "chai";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  ABI_ARTIFACT_PROTOCOL_VERSION,
  ABI_ARTIFACT_RELEASE_VERSION,
  buildAbiArtifactExport,
  checkFreeze,
  diffAgainstFreeze,
  type AbiArtifactExport,
} from "../scripts/exportVersionedAbiArtifacts";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.join(__dirname, "..");

describe("Versioned ABI and event artifact exports (V2-SC-131)", function () {
  let bundle: AbiArtifactExport;

  before(function () {
    bundle = buildAbiArtifactExport(rootDir);
  });

  it("derives a deterministic export for identical sources", function () {
    const regenerated = buildAbiArtifactExport(rootDir);
    expect(regenerated.checksum).to.equal(bundle.checksum);
    expect(regenerated.modules.map((m) => m.digest)).to.deep.equal(bundle.modules.map((m) => m.digest));
  });

  it("keeps the committed freeze in sync with the canonical sources", function () {
    expect(checkFreeze(rootDir)).to.deep.equal([]);
  });

  it("pins the release and protocol version in the export", function () {
    expect(bundle.releaseVersion).to.equal(ABI_ARTIFACT_RELEASE_VERSION);
    expect(bundle.protocolVersion).to.deep.equal({ ...ABI_ARTIFACT_PROTOCOL_VERSION });
    expect(bundle.checksum).to.match(/^0x[0-9a-f]{64}$/);
  });

  it("assigns a unique ERC-165 interface id to every canonical module", function () {
    const ids = bundle.modules.map((module) => module.interfaceId);
    expect(new Set(ids).size, "interface id collision between canonical modules").to.equal(ids.length);
    for (const module of bundle.modules) {
      expect(module.interfaceId, `${module.name} must advertise a bytes4 id`).to.match(/^0x[0-9a-f]{8}$/);
    }
  });

  it("keeps function and error selectors unique within each module", function () {
    for (const module of bundle.modules) {
      for (const entries of [module.functions, module.errors]) {
        const selectors = entries.map((entry) => entry.selector);
        expect(new Set(selectors).size, `${module.name} has a selector collision`).to.equal(selectors.length);
      }
    }
  });

  it("keeps every event within the three indexed parameter limit", function () {
    for (const fragment of bundle.canonicalAbi) {
      if (fragment.type !== "event") continue;
      const indexed = (fragment.inputs ?? []).filter((input) => input.indexed).length;
      expect(indexed, `${fragment.signature} exceeds the EVM indexed parameter limit`).to.be.at.most(3);
    }
  });

  it("exports an address manifest of module identity without embedded addresses", function () {
    expect(bundle.addressManifest.modules).to.have.length(bundle.modules.length);
    for (const entry of bundle.addressManifest.modules) {
      expect(entry.moduleId).to.match(/^0x[0-9a-f]{64}$/);
      expect(entry.interfaceId).to.match(/^0x[0-9a-f]{8}$/);
    }
    expect(JSON.stringify(bundle.addressManifest)).to.not.match(/"0x[0-9a-fA-F]{40}"/);
  });

  it("covers every module function, error, and event in the canonical ABI", function () {
    const canonical = new Set(bundle.canonicalAbi.map((fragment) => fragment.signature));
    for (const module of bundle.modules) {
      for (const entry of [...module.functions, ...module.errors, ...module.events]) {
        expect(canonical.has(entry.signature), `${entry.signature} missing from canonical ABI`).to.equal(true);
      }
    }
  });

  it("reports drift when a module interface changes", function () {
    const frozen = buildAbiArtifactExport(rootDir);
    const mutated: AbiArtifactExport = JSON.parse(JSON.stringify(frozen));
    mutated.modules[0].digest = "0x" + "00".repeat(32);
    mutated.modules[0].interfaceId = "0xdeadbeef";
    mutated.checksum = "0x" + "11".repeat(32);
    const drifts = diffAgainstFreeze(frozen, mutated);
    expect(drifts.length).to.be.greaterThan(0);
    expect(drifts.join("\n")).to.match(/interfaceId drift|digest drift/);
  });
});
