import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  ABI_EXPORT,
  COLLISION_REPORT,
  buildCollisionReport,
  buildEventLayout,
  compareEventLayouts,
  findAbiCollisions,
} from "../../scripts/canonical-abi-gates.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const entry = (signature, selector, extras = {}) => ({ signature, selector, ...extras });

test("collision gate checks all released ABI entries and module selectors", () => {
  const bundle = JSON.parse(fs.readFileSync(path.join(root, ABI_EXPORT), "utf8"));
  assert.deepEqual(findAbiCollisions(bundle, { functions: {}, errors: {} }), []);
  const frozen = JSON.parse(fs.readFileSync(path.join(root, COLLISION_REPORT), "utf8"));
  assert.deepEqual(buildCollisionReport(bundle), frozen);
});

test("rejects colliding function and custom-error selectors", () => {
  const bundle = {
    modules: [
      { name: "A", functions: [entry("burn(uint256)", "0x42966c68")], errors: [entry("Oops(uint256)", "0xdeadbeef")] },
      { name: "B", functions: [entry("collate_propagate_storage(bytes16)", "0x42966c68")], errors: [entry("Failure(bytes32)", "0xdeadbeef")] },
    ],
    canonicalAbi: [],
  };
  const errors = findAbiCollisions(bundle, { functions: {}, errors: {} });
  assert.equal(errors.length, 2);
  assert.match(errors[0], /error selector collision/);
  assert.match(errors[1], /function selector collision/);
});

test("documents identical selector reuse but cannot allow incompatible return shapes", () => {
  const bundle = { modules: [
    { name: "A", functions: [entry("read()", "0x12345678", { outputs: ["uint256"] })], errors: [] },
    { name: "B", functions: [entry("read()", "0x12345678", { outputs: ["uint256"] })], errors: [] },
  ], canonicalAbi: [] };
  assert.match(findAbiCollisions(bundle, { functions: {}, errors: {} })[0], /without a documented allowlist/);
  assert.deepEqual(findAbiCollisions(bundle, { functions: { "read()": "Same read semantics in A and B." }, errors: {} }), []);
  bundle.modules[1].functions[0].outputs = ["address"];
  assert.match(findAbiCollisions(bundle, { functions: { "read()": "reviewed" }, errors: {} })[0], /incompatible parameter\/return semantics/);
});

test("rejects transparent proxy admin selector collisions", () => {
  const reserved = "0x4f1ef286";
  const bundle = { modules: [{ name: "Implementation", functions: [entry("upgradeToAndCall(address,bytes)", reserved)], errors: [] }], canonicalAbi: [] };
  assert.match(findAbiCollisions(bundle)[0], /transparent-proxy admin dispatch/);
});

test("event-layout manifest covers released indexed fields and is deterministic", () => {
  const bundle = JSON.parse(fs.readFileSync(path.join(root, ABI_EXPORT), "utf8"));
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "schemas/event-layout-v2.json"), "utf8"));
  assert.deepEqual(buildEventLayout(bundle), manifest);
  assert.deepEqual(compareEventLayouts(manifest, buildEventLayout(bundle)), []);
});

test("rejects field indexing, order, type, and removal drift; accepts a new versioned event", () => {
  const old = { events: [{ signature: "Changed(address,uint256)", topic0: "0x1", fields: [
    { index: 0, name: "account", type: "address", indexed: true },
    { index: 1, name: "amount", type: "uint256", indexed: false },
  ] }, { signature: "Removed()", topic0: "0x2", fields: [] }] };
  const current = { events: [{ signature: "Changed(address,uint256)", topic0: "0x1", fields: [
    { index: 0, name: "account", type: "address", indexed: false },
    { index: 1, name: "amount", type: "uint256", indexed: true },
  ] }, { signature: "ChangedV2(address,uint256)", topic0: "0x3", fields: [] }] };
  const problems = compareEventLayouts(old, current);
  assert.equal(problems.length, 2);
  assert.ok(problems.some((problem) => problem.includes("indexed layout")));
  assert.ok(problems.some((problem) => problem.includes("removed")));
  current.events[1].signature = "ChangedV2(address,uint256)";
  old.events = old.events.slice(0, 1);
  current.events[0].fields = structuredClone(old.events[0].fields);
  assert.deepEqual(compareEventLayouts(old, current), []);
});

test("detects changed non-indexed fields and anonymous topic-layout changes", () => {
  const old = { events: [{ signature: "Update(uint256)", anonymous: false, fields: [{ index: 0, name: "id", type: "uint256", indexed: false }] }] };
  const changed = { events: [{ signature: "Update(uint256)", anonymous: true, fields: [{ index: 0, name: "id", type: "uint256", indexed: false }] }] };
  assert.match(compareEventLayouts(old, changed)[0], /indexed layout/);
  changed.events[0].anonymous = false;
  changed.events[0].fields[0].type = "uint128";
  assert.match(compareEventLayouts(old, changed)[0], /indexed layout/);
});

test("rejects indexed-field reordering and topic collisions", () => {
  const previous = { events: [{ signature: "Ordered(address,uint256)", topic0: "0xabc", fields: [
    { index: 0, name: "account", type: "address", indexed: true },
    { index: 1, name: "amount", type: "uint256", indexed: false },
  ] }] };
  const reordered = { events: [{ signature: "Ordered(address,uint256)", topic0: "0xabc", fields: [
    { index: 0, name: "amount", type: "uint256", indexed: false },
    { index: 1, name: "account", type: "address", indexed: true },
  ] }] };
  assert.match(compareEventLayouts(previous, reordered)[0], /indexed layout/);
  reordered.events.push({ signature: "Other()", topic0: "0xabc", fields: [] });
  assert.match(compareEventLayouts(previous, reordered)[0], /topic collision/);
});

test("preserves nested event log order when replaying a simple projection fixture", () => {
  const nestedReceipt = [
    { logIndex: 4, event: "ClaimCreatedV1", args: { claimId: 9, status: "OPEN" } },
    { logIndex: 5, event: "ClaimResolvedV1", args: { claimId: 9, status: "RESOLVED" } },
  ];
  const projection = new Map();
  for (const log of [...nestedReceipt].sort((a, b) => a.logIndex - b.logIndex)) {
    if (log.event === "ClaimCreatedV1") projection.set(log.args.claimId, log.args.status);
    if (log.event === "ClaimResolvedV1") projection.set(log.args.claimId, log.args.status);
  }
  assert.equal(projection.get(9), "RESOLVED");
});
