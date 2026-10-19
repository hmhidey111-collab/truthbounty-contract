import { expect } from "chai";
import { describe, it } from "mocha";

import {
  TRACKED_CONTRACTS,
  assertLayoutCompatible,
  findUntrackedGapContracts,
  loadBaselineManifest,
  loadCurrentLayouts,
  stabilizeLayout,
  validateStorageLayouts,
} from "../scripts/validateStorageLayouts";

describe("Upgradeable Storage Layout Compatibility (V2-SC-046)", function () {
  // Layout loading compiles nothing but parses the build-info JSON (~MBs);
  // cache the two loads for the whole suite.
  let baseline: ReturnType<typeof loadBaselineManifest>;
  let current: ReturnType<typeof loadCurrentLayouts>;

  before(function () {
    this.timeout(120_000);
    baseline = loadBaselineManifest();
    current = loadCurrentLayouts();
  });

  describe("manifest integrity", function () {
    it("tracks every declared upgradeable contract", function () {
      expect(TRACKED_CONTRACTS.length).to.be.greaterThan(0);
      for (const tracked of TRACKED_CONTRACTS) {
        expect(baseline.contracts, `baseline missing ${tracked.name}`).to.have.property(
          tracked.name,
        );
        expect(current, `compiled output missing ${tracked.name}`).to.have.property(tracked.name);
      }
    });

    it("contains no stale manifest entries", function () {
      const trackedNames = new Set(TRACKED_CONTRACTS.map((c) => c.name));
      for (const name of Object.keys(baseline.contracts)) {
        expect(trackedNames.has(name), `${name} in manifest is not tracked`).to.be.true;
      }
    });

    it("manifest and compiled layout agree on the source file", function () {
      for (const tracked of TRACKED_CONTRACTS) {
        expect(
          baseline.contracts[tracked.name].file,
          `manifest file drift for ${tracked.name}`,
        ).to.equal(tracked.file);
      }
    });

    it("fail-closed guard: every __gap contract is tracked", function () {
      const untracked = findUntrackedGapContracts();
      expect(untracked, `untracked gap contracts: ${untracked.join(", ")}`).to.be.empty;
    });
  });

  describe("compatibility gate", function () {
    it("all tracked layouts are compatible with the committed baseline", function () {
      for (const tracked of TRACKED_CONTRACTS) {
        // Throws with a detailed report on any unsafe change.
        assertLayoutCompatible(baseline.contracts[tracked.name], current[tracked.name]);
      }
    });

    it("validateStorageLayouts passes end-to-end", async function () {
      this.timeout(120_000);
      const result = await validateStorageLayouts();
      expect(result.issues, result.issues.join("; ")).to.be.empty;
      expect(result.passed).to.be.true;
      expect(result.checked).to.have.lengthOf(TRACKED_CONTRACTS.length);
    });
  });

  describe("detector regression coverage (fails against prior unsafe behaviour)", function () {
    it("blocks type mutation of an existing slot", function () {
      const name = "MockUpgradeable";
      const mutated = JSON.parse(JSON.stringify(current[name]));
      const target = mutated.storage.find((s: any) => s.label === "value");
      expect(target, "expected a `value` variable in MockUpgradeable").to.exist;
      target.type = "t_address";
      mutated.types["t_address"] = mutated.types["t_uint256"];

      expect(() =>
        assertLayoutCompatible(baseline.contracts[name], mutated),
      ).to.throw(/incompatible/i);
    });

    it("blocks slot deletion", function () {
      const name = "MockUpgradeable";
      const deleted = JSON.parse(JSON.stringify(current[name]));
      deleted.storage = deleted.storage.filter((s: any) => s.label !== "value");

      expect(() =>
        assertLayoutCompatible(baseline.contracts[name], deleted),
      ).to.throw(/incompatible/i);
    });

    it("blocks variable reordering (slot swap)", function () {
      // Use a contract with at least two storage variables.
      const name = "DisputeResolution";
      const reordered = JSON.parse(JSON.stringify(current[name]));
      expect(reordered.storage.length).to.be.greaterThan(1);
      // Swap the slots of the first two variables.
      const first = reordered.storage[0];
      reordered.storage[0] = { ...reordered.storage[1], slot: first.slot };
      reordered.storage[1] = { ...first, slot: reordered.storage[1].slot };

      expect(() =>
        assertLayoutCompatible(baseline.contracts[name], reordered),
      ).to.throw(/incompatible/i);
    });

    it("blocks consumption of a reserved storage gap", function () {
      const name = "TimelockOwnedProxyAdmin";
      const consumed = JSON.parse(JSON.stringify(current[name]));
      const gap = consumed.storage.find((s: any) => s.label === "__gap");
      expect(gap, "expected a __gap variable").to.exist;
      // Replace the gap with a same-slot real variable (unsafe retype of the array).
      consumed.storage = consumed.storage.map((s: any) =>
        s.label === "__gap" ? { ...s, label: "claimed", type: "t_uint256" } : s,
      );
      consumed.types["t_uint256"] = { label: "uint256", numberOfBytes: "32" };

      expect(() =>
        assertLayoutCompatible(baseline.contracts[name], consumed),
      ).to.throw(/incompatible/i);
    });

    it("allows append-only growth within the same major version", function () {
      const name = "MockUpgradeable";
      const grown = JSON.parse(JSON.stringify(current[name]));
      const last = grown.storage[grown.storage.length - 1];
      grown.storage.push({
        contract: name,
        label: "appendedVar",
        type: "t_uint256",
        offset: 0,
        slot: String(Number(last.slot) + 1),
      });

      expect(() => assertLayoutCompatible(baseline.contracts[name], grown)).to.not.throw();
    });

    it("enum members are stabilized as strings, not spread objects", function () {
      const stabilized = stabilizeLayout({
        storage: [],
        types: {
          "t_enum(Demo)1": {
            label: "enum Demo",
            members: ["A", "B"],
            numberOfBytes: "1",
          },
        },
      });
      expect(stabilized.types["t_enum(Demo)1"].members).to.deep.equal(["A", "B"]);
    });
  });
});
