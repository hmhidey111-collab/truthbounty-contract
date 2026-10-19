import { expect } from "chai";
import * as path from "path";
import {
  MANIFEST_SCHEMA_VERSION,
  HASH_DOMAIN,
  canonicalJsonStringify,
  computeCanonicalHash,
  extractSlots,
  normalizeTypeId,
  classifyContractDrift,
  classifyManifestDrift,
  parseApprovedDrift,
  emptyManifest,
  addContract,
  serializeManifest,
  readFrozenManifest,
  TRACKED_STORAGE_CONTRACTS,
  MAX_TRACKED_CONTRACTS,
  MAX_TRACKED_SLOTS,
  type ContractManifest,
  type StorageVarEntry,
} from "../scripts/storageLayoutManifest";

const ROOT = path.resolve(__dirname, "..");

function varEntry(slot: number, type = "t_uint256", bytes = "32", offset = 0): StorageVarEntry {
  return { slot: String(slot), offset, type, numberOfBytes: bytes };
}

function makeContract(
  slots: Record<string, StorageVarEntry>,
  sourcePath = "contracts/test/Mock.sol",
  frozenAt = "2026-01-01T00:00:00.000Z"
): ContractManifest {
  return {
    sourcePath,
    kind: "upgradeable",
    canonicalHash: computeCanonicalHash(sourcePath, slots),
    frozenAt,
    slots,
  };
}

describe("Storage-layout manifest core (V2-SC-121)", function () {
  // -------------------------------------------------------------------------
  // Canonical JSON
  // -------------------------------------------------------------------------
  describe("canonicalJsonStringify", function () {
    it("sorts object keys recursively", function () {
      const input = { b: 1, a: { d: 2, c: [ { z: 3, y: 4 } ] } };
      expect(canonicalJsonStringify(input)).to.equal('{"a":{"c":[{"y":4,"z":3}],"d":2},"b":1}');
    });

    it("emits no insignificant whitespace", function () {
      const input = { key: "value", nested: { x: [1, 2] } };
      expect(canonicalJsonStringify(input)).to.not.contain(" ");
    });

    it("preserves string values of numeric slots verbatim", function () {
      // solc encodes slot/size as strings; leading zeros must survive.
      const input = { slot: "007", numberOfBytes: "32" };
      expect(canonicalJsonStringify(input)).to.equal('{"numberOfBytes":"32","slot":"007"}');
    });

    it("is stable across key insertion order", function () {
      expect(canonicalJsonStringify({ a: 1, b: 2 })).to.equal(canonicalJsonStringify({ b: 2, a: 1 }));
    });
  });

  // -------------------------------------------------------------------------
  // Canonical hash
  // -------------------------------------------------------------------------
  describe("computeCanonicalHash", function () {
    it("produces 32-byte hex digests", function () {
      const h = computeCanonicalHash("contracts/a.sol", { x: varEntry(0) });
      expect(h).to.match(/^0x[0-9a-f]{64}$/);
    });

    it("is deterministic", function () {
      const a = computeCanonicalHash("contracts/a.sol", { x: varEntry(0) });
      const b = computeCanonicalHash("contracts/a.sol", { x: varEntry(0) });
      expect(a).to.equal(b);
    });

    it("changes when a slot changes (positive drift signal)", function () {
      const a = computeCanonicalHash("contracts/a.sol", { x: varEntry(0) });
      const b = computeCanonicalHash("contracts/a.sol", { x: varEntry(1) });
      expect(a).to.not.equal(b);
    });

    it("changes when a type changes (negative: byte-collision classes rejected)", function () {
      const a = computeCanonicalHash("contracts/a.sol", { x: varEntry(0, "t_uint256") });
      const b = computeCanonicalHash("contracts/a.sol", { x: varEntry(0, "t_array(t_uint256)2_storage", "64") });
      expect(a).to.not.equal(b);
    });

    it("changes when the source path changes", function () {
      const a = computeCanonicalHash("contracts/a.sol", { x: varEntry(0) });
      const b = computeCanonicalHash("contracts/b.sol", { x: varEntry(0) });
      expect(a).to.not.equal(b);
    });

    it("is domain-separated from other protocol hashes", function () {
      // The preimage starts with the ASCII domain tag; a different domain must
      // not collide for identical entries.
      const h = computeCanonicalHash("contracts/a.sol", {});
      expect(h).to.not.equal(computeCanonicalHash("contracts/a.sol", { x: varEntry(0) }));
      expect(HASH_DOMAIN).to.equal("TB-STORAGE-LAYOUT-V1");
    });

    it("is order-insensitive over the slot map", function () {
      const a = computeCanonicalHash("contracts/a.sol", { x: varEntry(0), y: varEntry(1) });
      const b = computeCanonicalHash("contracts/a.sol", { y: varEntry(1), x: varEntry(0) });
      expect(a).to.equal(b);
    });
  });

  // -------------------------------------------------------------------------
  // solc type normalization
  // -------------------------------------------------------------------------
  describe("normalizeTypeId", function () {
    const types = {
      "t_struct(RoleData)17432_storage": { label: "struct AccessControl.RoleData", numberOfBytes: "64" },
      "t_struct(RoleData)99999_storage": { label: "struct AccessControl.RoleData", numberOfBytes: "64" },
      "t_struct(RoleData)17433_storage": { label: "struct AccessControl.RoleData", numberOfBytes: "96" },
    };

    it("strips astId from user-defined type ids", function () {
      const a = normalizeTypeId("t_struct(RoleData)17432_storage", types);
      const b = normalizeTypeId("t_struct(RoleData)99999_storage", types);
      expect(a).to.equal(b);
    });

    it("retains size changes of user-defined types", function () {
      const small = normalizeTypeId("t_struct(RoleData)17432_storage", types);
      const big = normalizeTypeId("t_struct(RoleData)17433_storage", types);
      expect(small).to.not.equal(big);
    });

    it("normalizes astId inside composite mapping ids", function () {
      const compositeTypes = {
        "t_struct(RoleData)111_storage": { label: "struct AccessControl.RoleData", numberOfBytes: "64" },
        "t_struct(RoleData)222_storage": { label: "struct AccessControl.RoleData", numberOfBytes: "64" },
      };
      const a = normalizeTypeId("t_mapping(t_bytes32,t_struct(RoleData)111_storage)", compositeTypes);
      const b = normalizeTypeId("t_mapping(t_bytes32,t_struct(RoleData)222_storage)", compositeTypes);
      expect(a).to.equal(b);
    });

    it("preserves array length drift", function () {
      expect(normalizeTypeId("t_array(t_uint256)50_storage", {})).to.not.equal(
        normalizeTypeId("t_array(t_uint256)49_storage", {})
      );
    });

    it("leaves elementary ids untouched", function () {
      expect(normalizeTypeId("t_uint256", {})).to.equal("t_uint256");
      expect(normalizeTypeId("t_address", {})).to.equal("t_address");
    });
  });

  // -------------------------------------------------------------------------
  // extractSlots
  // -------------------------------------------------------------------------
  describe("extractSlots", function () {
    it("keys variables as label@slot", function () {
      const layout = {
        storage: [
          { astId: 1, contract: "f.sol:C", label: "x", offset: 0, slot: "0", type: "t_uint256" },
          { astId: 2, contract: "f.sol:C", label: "y", offset: 0, slot: "1", type: "t_bool" },
        ],
        types: { t_uint256: { encoding: "inplace", label: "uint256", numberOfBytes: "32" } },
      };
      const slots = extractSlots(layout, "C");
      expect(Object.keys(slots)).to.have.members(["x@0", "y@1"]);
    });

    it("disambiguates inherited duplicate labels (two __gap arrays)", function () {
      const layout = {
        storage: [
          { astId: 1, contract: "f.sol:Base", label: "__gap", offset: 0, slot: "3", type: "t_array(t_uint256)50_storage" },
          { astId: 2, contract: "f.sol:Derived", label: "__gap", offset: 0, slot: "54", type: "t_array(t_uint256)46_storage" },
        ],
        types: {},
      };
      const slots = extractSlots(layout, "Derived");
      expect(Object.keys(slots)).to.have.members(["__gap@3", "__gap@54"]);
    });

    it("rejects layouts exceeding the bounded slot count", function () {
      const items = [];
      for (let i = 0; i <= MAX_TRACKED_SLOTS; i++) {
        items.push({ astId: i, contract: "f.sol:C", label: `v${i}`, offset: 0, slot: String(i), type: "t_uint256" });
      }
      const layout = { storage: items, types: {} };
      expect(() => extractSlots(layout, "C")).to.throw(/MAX_TRACKED_SLOTS/);
    });
  });

  // -------------------------------------------------------------------------
  // Drift classification
  // -------------------------------------------------------------------------
  describe("classifyContractDrift", function () {
    it("reports unchanged for identical layouts", function () {
      const slots = { "x@0": varEntry(0), "__gap@1": varEntry(1, "t_array(t_uint256)10_storage", "320") } as Record<string, StorageVarEntry>;
      const frozen = makeContract(slots);
      const finding = classifyContractDrift("C", frozen, { ...frozen, canonicalHash: computeCanonicalHash("contracts/test/Mock.sol", slots) });
      expect(finding.classification).to.equal("unchanged");
    });

    it("reports slot-drift when a frozen variable moves", function () {
      const frozen = makeContract({ "x@0": varEntry(0) } as Record<string, StorageVarEntry>);
      const fresh = makeContract({ "x@1": varEntry(1) } as Record<string, StorageVarEntry>);
      const finding = classifyContractDrift("C", frozen, fresh);
      expect(finding.classification).to.equal("slot-drift");
      expect(finding.details.join(" ")).to.contain("moved");
    });

    it("reports slot-drift for variable removal", function () {
      const frozen = makeContract({ "x@0": varEntry(0), "y@1": varEntry(1) } as Record<string, StorageVarEntry>);
      const fresh = makeContract({ "x@0": varEntry(0) } as Record<string, StorageVarEntry>);
      expect(classifyContractDrift("C", frozen, fresh).classification).to.equal("slot-drift");
    });

    it("reports slot-drift for insertion before the append boundary", function () {
      const frozen = makeContract({
        "x@0": varEntry(0),
        "__gap@1": varEntry(1, "t_array(t_uint256)10_storage", "320"),
      } as Record<string, StorageVarEntry>);
      const fresh = makeContract({
        "x@0": varEntry(0),
        "w@1": varEntry(1),
        "__gap@2": varEntry(2, "t_array(t_uint256)10_storage", "320"),
      } as Record<string, StorageVarEntry>);
      expect(classifyContractDrift("C", frozen, fresh).classification).to.equal("slot-drift");
    });

    it("reports appended for gap-shrink append at the tail", function () {
      const frozen = makeContract({
        "x@0": varEntry(0),
        "__gap@1": varEntry(1, "t_array(t_uint256)10_storage", "320"),
      } as Record<string, StorageVarEntry>);
      const fresh = makeContract({
        "x@0": varEntry(0),
        "__gap@1": varEntry(1, "t_array(t_uint256)9_storage", "288"),
        "newX@10": varEntry(10),
      } as Record<string, StorageVarEntry>);
      const finding = classifyContractDrift("C", frozen, fresh);
      expect(finding.classification).to.equal("appended");
    });

    it("reports appended for keep-gap append strictly after the gap", function () {
      const frozen = makeContract({
        "x@0": varEntry(0),
        "__gap@1": varEntry(1, "t_array(t_uint256)10_storage", "320"),
      } as Record<string, StorageVarEntry>);
      const fresh = makeContract({
        "x@0": varEntry(0),
        "__gap@1": varEntry(1, "t_array(t_uint256)10_storage", "320"),
        "newX@11": varEntry(11),
      } as Record<string, StorageVarEntry>);
      expect(classifyContractDrift("C", frozen, fresh).classification).to.equal("appended");
    });

    it("rejects append whose gap grew, moved, appeared or disappeared", function () {
      const frozen = makeContract({
        "x@0": varEntry(0),
        "__gap@1": varEntry(1, "t_array(t_uint256)10_storage", "320"),
      } as Record<string, StorageVarEntry>);
      const grew = makeContract({
        "x@0": varEntry(0),
        "__gap@1": varEntry(1, "t_array(t_uint256)11_storage", "352"),
        "newX@12": varEntry(12),
      } as Record<string, StorageVarEntry>);
      expect(classifyContractDrift("C", frozen, grew).classification).to.equal("slot-drift");
    });

    it("reports slot-drift when gap changes without any append", function () {
      const frozen = makeContract({
        "x@0": varEntry(0),
        "__gap@1": varEntry(1, "t_array(t_uint256)10_storage", "320"),
      } as Record<string, StorageVarEntry>);
      const fresh = makeContract({
        "x@0": varEntry(0),
        "__gap@1": varEntry(1, "t_array(t_uint256)9_storage", "288"),
      } as Record<string, StorageVarEntry>);
      expect(classifyContractDrift("C", frozen, fresh).classification).to.equal("slot-drift");
    });

    it("reports slot-drift on hash mismatch with identical slots (encoding drift)", function () {
      const slots = { "x@0": varEntry(0) } as Record<string, StorageVarEntry>;
      const frozen = makeContract(slots);
      const fresh: ContractManifest = {
        ...frozen,
        sourcePath: "contracts/other/Mock.sol",
        canonicalHash: computeCanonicalHash("contracts/other/Mock.sol", slots),
      };
      expect(classifyContractDrift("C", frozen, fresh).classification).to.equal("slot-drift");
    });

    it("classifies brand-new contracts as new", function () {
      const fresh = makeContract({ "x@0": varEntry(0) });
      expect(classifyContractDrift("C", undefined, fresh).classification).to.equal("new");
    });

    it("detects byte-width collision classes via size field", function () {
      const frozen = makeContract({ "x@0": varEntry(0, "t_uint256", "32") } as Record<string, StorageVarEntry>);
      const fresh = makeContract({ "x@0": varEntry(0, "t_bytes32", "32") } as Record<string, StorageVarEntry>);
      expect(classifyContractDrift("C", frozen, fresh).classification).to.equal("slot-drift");
    });
  });

  describe("classifyManifestDrift", function () {
    it("passes when frozen and fresh match", function () {
      const frozen = emptyManifest("0.8.28");
      addContract(frozen, { name: "A", sourcePath: "a.sol", kind: "upgradeable" }, { "x@0": varEntry(0) } as Record<string, StorageVarEntry>);
      const fresh = emptyManifest("0.8.28");
      addContract(fresh, { name: "A", sourcePath: "a.sol", kind: "upgradeable" }, { "x@0": varEntry(0) } as Record<string, StorageVarEntry>);
      const report = classifyManifestDrift(frozen, fresh);
      expect(report.pass).to.be.true;
      expect(report.findings).to.be.empty;
    });

    it("fails on removed contracts", function () {
      const frozen = emptyManifest("0.8.28");
      addContract(frozen, { name: "A", sourcePath: "a.sol", kind: "upgradeable" }, { "x@0": varEntry(0) } as Record<string, StorageVarEntry>);
      const fresh = emptyManifest("0.8.28");
      const report = classifyManifestDrift(frozen, fresh);
      expect(report.pass).to.be.false;
      expect(report.findings[0].classification).to.equal("removed");
    });

    it("passes on new contracts (manifest diff requires review, not rejection)", function () {
      const frozen = emptyManifest("0.8.28");
      const fresh = emptyManifest("0.8.28");
      addContract(fresh, { name: "B", sourcePath: "b.sol", kind: "upgradeable" }, { "x@0": varEntry(0) } as Record<string, StorageVarEntry>);
      expect(classifyManifestDrift(frozen, fresh).pass).to.be.true;
    });

    it("treats an approved target hash as passing", function () {
      const frozen = emptyManifest("0.8.28");
      addContract(frozen, { name: "A", sourcePath: "a.sol", kind: "upgradeable" }, { "x@0": varEntry(0) } as Record<string, StorageVarEntry>);
      const freshSlots = { "x@1": varEntry(1) } as Record<string, StorageVarEntry>;
      const fresh = emptyManifest("0.8.28");
      addContract(fresh, { name: "A", sourcePath: "a.sol", kind: "upgradeable" }, freshSlots);
      const approved = new Set([fresh.contracts["A"].canonicalHash]);
      const report = classifyManifestDrift(frozen, fresh, approved);
      expect(report.pass).to.be.true;
      expect(report.findings[0].classification).to.equal("approved");
    });

    it("fails drift for contracts not covered by an approval", function () {
      const frozen = emptyManifest("0.8.28");
      addContract(frozen, { name: "A", sourcePath: "a.sol", kind: "upgradeable" }, { "x@0": varEntry(0) } as Record<string, StorageVarEntry>);
      const fresh = emptyManifest("0.8.28");
      addContract(fresh, { name: "A", sourcePath: "a.sol", kind: "upgradeable" }, { "x@1": varEntry(1) } as Record<string, StorageVarEntry>);
      expect(classifyManifestDrift(frozen, fresh).pass).to.be.false;
    });

    it("enforces the bounded manifest size", function () {
      const frozen = emptyManifest("0.8.28");
      const fresh = emptyManifest("0.8.28");
      // Build an oversized fresh manifest directly (bypassing the addContract guard).
      const slots = { "x@0": varEntry(0) } as Record<string, StorageVarEntry>;
      for (let i = 0; i <= MAX_TRACKED_CONTRACTS; i++) {
        fresh.contracts[`C${i}`] = {
          sourcePath: `c${i}.sol`,
          kind: "upgradeable",
          canonicalHash: computeCanonicalHash(`c${i}.sol`, slots),
          frozenAt: "2026-01-01T00:00:00.000Z",
          slots,
        };
      }
      expect(() => classifyManifestDrift(frozen, fresh)).to.throw(/MAX_TRACKED_CONTRACTS/);
    });
  });

  describe("parseApprovedDrift", function () {
    it("extracts hashes from exact-format lines", function () {
      const md = [
        "# Approved drift",
        "",
        "- `StakeVault` → `0x" + "ab".repeat(32) + "` (PR #999, append-only)",
        "- `FeeManager` → `0x" + "cd".repeat(32) + "` (PR #1000, layout-breaking)",
      ].join("\n");
      const set = parseApprovedDrift(md);
      expect(set.size).to.equal(2);
      expect(set.has("0x" + "ab".repeat(32))).to.be.true;
    });

    it("ignores malformed lines (negative)", function () {
      const md = "- StakeVault → 0xdeadbeef (no backticks, short hash)";
      expect(parseApprovedDrift(md).size).to.equal(0);
    });

    it("returns an empty set for the initial-freeze ledger", function () {
      expect(parseApprovedDrift("- (none yet — initial freeze performed by the V2-SC-121 PR itself)\n").size).to.equal(0);
    });
  });

  // -------------------------------------------------------------------------
  // Manifest assembly / serialization
  // -------------------------------------------------------------------------
  describe("manifest assembly", function () {
    it("serializes contracts in alphabetical order (order is not drift)", function () {
      const m = emptyManifest("0.8.28");
      addContract(m, { name: "Zeta", sourcePath: "z.sol", kind: "upgradeable" }, { "x@0": varEntry(0) } as Record<string, StorageVarEntry>);
      addContract(m, { name: "Alpha", sourcePath: "a.sol", kind: "upgradeable" }, { "x@0": varEntry(0) } as Record<string, StorageVarEntry>);
      const json = JSON.parse(serializeManifest(m));
      expect(Object.keys(json.contracts)).to.deep.equal(["Alpha", "Zeta"]);
    });

    it("rejects duplicate contract names", function () {
      const m = emptyManifest("0.8.28");
      addContract(m, { name: "A", sourcePath: "a.sol", kind: "upgradeable" }, {});
      expect(() => addContract(m, { name: "A", sourcePath: "a.sol", kind: "upgradeable" }, {})).to.throw(/duplicate/);
    });

    it("stamps the frozen schema version", function () {
      const m = emptyManifest("0.8.28");
      expect(m.schemaVersion).to.equal(MANIFEST_SCHEMA_VERSION);
      expect(MANIFEST_SCHEMA_VERSION).to.equal(1);
    });
  });

  // -------------------------------------------------------------------------
  // Frozen artifact integrity (repo-level regression)
  // -------------------------------------------------------------------------
  describe("frozen manifest artifact", function () {
    const manifest = readFrozenManifest(ROOT);

    it("exists and is schema v1", function () {
      expect(manifest).to.not.be.null;
      expect(manifest!.schemaVersion).to.equal(1);
    });

    it("covers the full reviewed contract inventory", function () {
      const names = Object.keys(manifest!.contracts);
      expect(names).to.have.lengthOf(TRACKED_STORAGE_CONTRACTS.length);
      for (const tracked of TRACKED_STORAGE_CONTRACTS) {
        expect(names, tracked.name).to.include(tracked.name);
      }
    });

    it("records non-empty slot maps and canonical hashes for every contract", function () {
      for (const [name, entry] of Object.entries(manifest!.contracts)) {
        expect(Object.keys(entry.slots).length, `${name} slots`).to.be.greaterThan(0);
        expect(entry.canonicalHash, `${name} hash`).to.match(/^0x[0-9a-f]{64}$/);
      }
    });

    it("round-trips the canonical hash of the frozen slot map", function () {
      for (const [name, entry] of Object.entries(manifest!.contracts)) {
        const recomputed = computeCanonicalHash(entry.sourcePath, entry.slots);
        expect(recomputed, `${name} hash mismatch`).to.equal(entry.canonicalHash);
      }
    });
  });
});
