#!/usr/bin/env node
/**
 * @file check-storage-namespaces.test.mjs
 * @description V2-SC-159 — self-tests for the storage namespace / reserved-slot collision checker.
 *
 * Synthetic fixtures (test/fixtures/storage-namespaces/fixtures.mjs) prove each failure class is
 * reported — namespace collision, inherited-layout reorder, reserved-slot overwrite — and that a
 * safe append passes. The live-repository block proves the committed manifest is deterministic,
 * covers every module frozen by V2-SC-121, and is free of collisions.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  buildNamespaceManifest,
  checkFrozenLayoutAgreement,
  checkRepository,
  classifyManifestTransition,
  evaluateSlotExpression,
  extractStateVariables,
  lexSolidity,
  modulesFromFrozenLayout,
  parseSolidity,
  reservedSlotTable,
  serializeManifest,
  FROZEN_LAYOUT_RELATIVE_PATH,
  MANIFEST_RELATIVE_PATH
} from "../../scripts/check-storage-namespaces.mjs";
import { eip1967Slot, erc7201Slot, keccak256, toWord } from "../../scripts/lib/keccak256.mjs";
import {
  COMPOSITION_V1,
  DUPLICATE_NAMESPACE,
  FIXTURE_POLICY,
  INSERTED_BASE,
  MISMATCHED_NAMESPACE_CONSTANT,
  NAMESPACE_DROPPED,
  OVERLAPPING_UNSTRUCTURED,
  REORDERED_BASES,
  REORDERED_VARIABLES,
  RESERVED_SLOT_OVERWRITE,
  SAFE_APPEND,
  UNSTRUCTURED_IN_NAMESPACE_WINDOW
} from "../fixtures/storage-namespaces/fixtures.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "../..");

const IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";
const BEACON_SLOT = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50";

const build = (fixture) => buildNamespaceManifest({ ...fixture, policy: FIXTURE_POLICY });
const codes = (problems) => [...new Set(problems.map((p) => p.code))].sort();

describe("keccak256 and slot derivations", () => {
  test("matches published Keccak-256 vectors", () => {
    assert.equal(keccak256(""), "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
    assert.equal(keccak256("abc"), "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45");
  });

  test("handles inputs across the 136-byte rate boundary", () => {
    for (const length of [135, 136, 137, 272, 300]) {
      assert.match(keccak256("x".repeat(length)), /^0x[0-9a-f]{64}$/);
    }
    assert.notEqual(keccak256("x".repeat(135)), keccak256("x".repeat(136)));
  });

  test("derives the ERC-1967 reserved slots", () => {
    assert.equal(eip1967Slot("eip1967.proxy.implementation"), IMPLEMENTATION_SLOT);
    assert.equal(eip1967Slot("eip1967.proxy.admin"), ADMIN_SLOT);
    assert.equal(eip1967Slot("eip1967.proxy.beacon"), BEACON_SLOT);
  });

  test("derives the OpenZeppelin v5 ERC-7201 namespace roots", () => {
    assert.equal(erc7201Slot("openzeppelin.storage.Initializable"), "0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00");
    assert.equal(erc7201Slot("openzeppelin.storage.ReentrancyGuard"), "0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00");
    assert.equal(erc7201Slot("openzeppelin.storage.Ownable"), "0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300");
  });

  test("agrees with ethers when it is installed", async (t) => {
    let ethers;
    try {
      ({ ethers } = await import("ethers"));
    } catch {
      t.skip("ethers is not installed in this environment");
      return;
    }
    for (const input of ["", "abc", "eip1967.proxy.admin", "x".repeat(300)]) {
      assert.equal(keccak256(input), ethers.keccak256(ethers.toUtf8Bytes(input)));
    }
    const id = "openzeppelin.storage.Initializable";
    const inner = BigInt(ethers.keccak256(ethers.toUtf8Bytes(id))) - 1n;
    const outer = BigInt(ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [inner]))) & ~0xffn;
    assert.equal(erc7201Slot(id), toWord(outer));
  });

  test("the vendored OpenZeppelin upgradeable constants match the formula (parser + keccak)", () => {
    const source = readFileSync(resolve(REPO_ROOT, "lib/openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol"), "utf8");
    const [contract] = parseSolidity(source).contracts.filter((c) => c.name === "OwnableUpgradeable");
    assert.equal(contract.namespaces.length, 1);
    assert.equal(contract.namespaces[0].id, "openzeppelin.storage.Ownable");
    assert.equal(contract.namespaces[0].constant, "OwnableStorageLocation");
    assert.deepEqual(contract.stateVariables, []);
  });
});

describe("parser", () => {
  test("lexer blanks comments and string contents while preserving offsets", () => {
    const source = 'uint256 a; // x { }\n/* { */ string s = "}{"; ';
    const { code, skeleton } = lexSolidity(source);
    assert.equal(code.length, source.length);
    assert.equal(skeleton.length, source.length);
    assert.ok(!skeleton.includes("{") && !skeleton.includes("}"));
    assert.ok(code.includes('"}{"'));
  });

  test("extracts only persistent state variables, in declaration order", () => {
    const { contracts } = parseSolidity(COMPOSITION_V1.sources.get("contracts/Bases.sol"));
    const byName = Object.fromEntries(contracts.map((c) => [c.name, c.stateVariables]));
    assert.deepEqual(byName.LinearA, ["a1", "a2"], "constants, immutables and named mapping keys handled");
    assert.deepEqual(byName.LinearB, ["b1", "b2", "__gap"]);
    assert.deepEqual(byName.AlphaNamespace, []);
    const module = parseSolidity(COMPOSITION_V1.sources.get("contracts/Module.sol")).contracts[0];
    assert.deepEqual(module.stateVariables, ["m1", "m2", "__gap"], "variables after functions keep their order");
    assert.deepEqual(module.bases, ["LinearA", "LinearB", "AlphaNamespace"]);
  });

  test("ignores transient variables and strips base constructor arguments", () => {
    const { contracts } = parseSolidity(
      'contract C is Base("a, b", 2), Other { uint256 transient t; uint256 kept; function f() external; }'
    );
    assert.deepEqual(contracts[0].bases, ["Base", "Other"]);
    const { skeleton } = lexSolidity('contract D { uint256 transient t; uint256 kept; }');
    assert.deepEqual(extractStateVariables(skeleton, skeleton.indexOf("{"), skeleton.lastIndexOf("}")), ["kept"]);
  });

  test("evaluates literal, ERC-7201, EIP-1967 and keccak slot expressions", () => {
    assert.equal(evaluateSlotExpression(IMPLEMENTATION_SLOT.toUpperCase().replace("0X", "0x")).value, IMPLEMENTATION_SLOT);
    assert.equal(
      evaluateSlotExpression('keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Ownable")) - 1)) & ~bytes32(uint256(0xff))').value,
      erc7201Slot("openzeppelin.storage.Ownable")
    );
    assert.equal(evaluateSlotExpression('bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)').value, ADMIN_SLOT);
    assert.equal(evaluateSlotExpression('keccak256("ADMIN_ROLE")').derivation, "keccak256");
    assert.equal(evaluateSlotExpression("SOME_OTHER_CONSTANT"), null);
  });
});

describe("module composition fixtures", () => {
  test("composes linear bases in C3 order and collects the namespace", () => {
    const { manifest, problems } = build(COMPOSITION_V1);
    assert.deepEqual(problems, []);
    const entry = manifest.modules.Module;
    assert.deepEqual(entry.linearization, ["Module", "AlphaNamespace", "LinearB", "LinearA"]);
    assert.deepEqual(
      entry.storageOrder.map((s) => s.contract),
      ["LinearA", "LinearB", "Module"]
    );
    assert.deepEqual(entry.namespaces, [{ id: "tb.fixture.Alpha", slot: erc7201Slot("tb.fixture.Alpha"), definedBy: "AlphaNamespace" }]);
    assert.deepEqual(entry.reservedSlots, ["IMPLEMENTATION_SLOT", "ADMIN_SLOT", "BEACON_SLOT"]);
    assert.match(entry.digest, /^0x[0-9a-f]{64}$/);
  });

  test("synthetic namespace collision: two definers of one id fail", () => {
    const { problems } = build(DUPLICATE_NAMESPACE);
    assert.deepEqual(codes(problems), ["duplicate-namespace"]);
    assert.match(problems.find((p) => p.code === "duplicate-namespace").message, /AlphaNamespace.*CopycatNamespace/);
  });

  test("an annotation whose constant does not match the formula fails", () => {
    const { problems } = build(MISMATCHED_NAMESPACE_CONSTANT);
    assert.ok(codes(problems).includes("namespace-slot-mismatch"));
  });

  test("identical unstructured slots in one composed module fail", () => {
    const { problems } = build(OVERLAPPING_UNSTRUCTURED);
    assert.deepEqual(codes(problems), ["slot-overlap"]);
  });

  test("an unstructured slot inside a namespace window fails", () => {
    const rootPlusOne = toWord(BigInt(erc7201Slot("tb.fixture.Alpha")) + 1n);
    const { problems } = build(UNSTRUCTURED_IN_NAMESPACE_WINDOW(rootPlusOne));
    assert.deepEqual(codes(problems), ["slot-overlap"]);
    assert.match(problems[0].message, /256-slot window of erc7201:tb\.fixture\.Alpha/);
  });

  test("reserved-slot overwrite: EIP-1967 derived constant and raw literal both fail", () => {
    const { problems } = build(RESERVED_SLOT_OVERWRITE);
    assert.deepEqual(codes(problems), ["reserved-slot-reuse"]);
    const text = problems.map((p) => p.message).join("\n");
    assert.match(text, /IMPLEMENTATION_SLOT/);
    assert.match(text, /ADMIN_SLOT/);
  });

  test("a policy reserved slot that disagrees with its id fails", () => {
    const policy = { ...FIXTURE_POLICY, reservedSlots: [{ ...FIXTURE_POLICY.reservedSlots[0], slot: ADMIN_SLOT }] };
    assert.deepEqual(codes(reservedSlotTable(policy).problems), ["policy-integrity"]);
  });
});

describe("upgrade transition fixtures", () => {
  const v1 = build(COMPOSITION_V1).manifest;
  const transition = (fixture) => {
    const { manifest, problems } = build(fixture);
    return { problems, ...classifyManifestTransition(v1, manifest) };
  };

  test("inherited-layout reorder fails", () => {
    const result = transition(REORDERED_BASES);
    assert.deepEqual(result.problems, []);
    assert.deepEqual(codes(result.unsafe), ["inheritance-reorder"]);
  });

  test("a storage base inserted between existing contributors fails", () => {
    assert.deepEqual(codes(transition(INSERTED_BASE).unsafe), ["inheritance-reorder"]);
  });

  test("variables reordered inside a contributor fail", () => {
    assert.deepEqual(codes(transition(REORDERED_VARIABLES).unsafe), ["layout-reorder"]);
  });

  test("dropping a composed namespace fails", () => {
    assert.deepEqual(codes(transition(NAMESPACE_DROPPED).unsafe), ["namespace-removed"]);
  });

  test("safe append (variable before a shrunk gap, appended namespace) passes", () => {
    const result = transition(SAFE_APPEND);
    assert.deepEqual(result.problems, []);
    assert.deepEqual(result.unsafe, []);
    assert.ok(result.safe.some((s) => /appended \[m3\] to Module/.test(s)));
    assert.ok(result.safe.some((s) => /appended namespace erc7201:tb\.fixture\.Beta/.test(s)));
  });

  test("removing a module fails", () => {
    const empty = build({ sources: COMPOSITION_V1.sources, modules: [] }).manifest;
    assert.deepEqual(codes(classifyManifestTransition(v1, empty).unsafe), ["module-removed"]);
  });

  test("manifests are deterministic and independent of module input order", () => {
    const twoModules = {
      sources: new Map([...COMPOSITION_V1.sources, ...OVERLAPPING_UNSTRUCTURED.sources]),
      modules: [...COMPOSITION_V1.modules, { name: "LinearA", sourcePath: "contracts/Bases.sol" }]
    };
    const forward = serializeManifest(build(twoModules).manifest);
    const reversed = serializeManifest(build({ ...twoModules, modules: [...twoModules.modules].reverse() }).manifest);
    assert.equal(forward, reversed);
    assert.equal(forward, serializeManifest(build(twoModules).manifest));
  });
});

describe("integration with the V2-SC-121 frozen layout", () => {
  const { manifest } = build(COMPOSITION_V1);
  const frozenFor = (labels) => ({
    contracts: {
      Module: {
        sourcePath: "contracts/Module.sol",
        slots: Object.fromEntries(labels.map((label, i) => [`${label}@${i}`, { slot: String(i), offset: 0 }]))
      }
    }
  });
  const agreeing = ["a1", "a2", "b1", "b2", "__gap", "m1", "m2", "__gap"];

  test("agreeing orders pass and the frozen module set drives coverage", () => {
    assert.deepEqual(checkFrozenLayoutAgreement(manifest, frozenFor(agreeing), FIXTURE_POLICY), []);
    assert.deepEqual(modulesFromFrozenLayout(frozenFor(agreeing)), [{ name: "Module", sourcePath: "contracts/Module.sol" }]);
  });

  test("an unacknowledged disagreement fails; an acknowledged one passes; a stale one fails", () => {
    const disagreeing = frozenFor(["a1", "a2", "b1", "b2", "__gap", "m2", "m1", "__gap"]);
    assert.deepEqual(codes(checkFrozenLayoutAgreement(manifest, disagreeing, FIXTURE_POLICY)), ["layout-discrepancy"]);
    const ack = { ...FIXTURE_POLICY, acknowledgedLayoutDiscrepancies: [{ module: "Module", rationale: "x".repeat(60) }] };
    assert.deepEqual(checkFrozenLayoutAgreement(manifest, disagreeing, ack), []);
    assert.deepEqual(codes(checkFrozenLayoutAgreement(manifest, frozenFor(agreeing), ack)), ["layout-discrepancy"]);
  });

  test("a frozen module without a namespace entry fails coverage", () => {
    const frozen = frozenFor(agreeing);
    frozen.contracts.Missing = { sourcePath: "contracts/Missing.sol", slots: {} };
    assert.deepEqual(codes(checkFrozenLayoutAgreement(manifest, frozen, FIXTURE_POLICY)), ["coverage"]);
  });
});

describe("live repository (V2-SC-159)", () => {
  const result = checkRepository(REPO_ROOT);

  test("no collisions, reserved-slot reuse, or unacknowledged layout discrepancies", () => {
    assert.deepEqual(result.problems, []);
  });

  test("the committed manifest is byte-identical to the regenerated one", () => {
    assert.notEqual(result.committed, null, `${MANIFEST_RELATIVE_PATH} must be committed`);
    assert.equal(result.committed, result.serialized);
    assert.deepEqual(result.transition.unsafe, []);
  });

  test("every module frozen by V2-SC-121 has a slot/namespace manifest entry", () => {
    const frozen = JSON.parse(readFileSync(resolve(REPO_ROOT, FROZEN_LAYOUT_RELATIVE_PATH), "utf8"));
    assert.deepEqual(Object.keys(result.manifest.modules).sort(), Object.keys(frozen.contracts).sort());
    for (const entry of Object.values(result.manifest.modules)) {
      assert.deepEqual(entry.reservedSlots, ["IMPLEMENTATION_SLOT", "ADMIN_SLOT", "BEACON_SLOT"]);
      for (const ns of entry.namespaces) assert.equal(ns.slot, erc7201Slot(ns.id));
    }
  });

  test("the reserved slots in the manifest are the ERC-1967 constants", () => {
    assert.deepEqual(
      result.manifest.reservedSlots.map((r) => r.slot),
      [IMPLEMENTATION_SLOT, ADMIN_SLOT, BEACON_SLOT]
    );
  });
});
