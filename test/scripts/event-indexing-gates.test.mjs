import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  COMMIT_REVEAL_SOURCE,
  INDEXING_GAS_REPORT,
  INDEXING_POLICY,
  INDEX_TOGGLE_GAS,
  buildGasReport,
  checkEventIndexingGates,
  checkIndexingPolicy,
  deriveEvents,
  eventLogGas,
  keccak256Hex,
  parseSolidityEvents,
} from "../../scripts/event-indexing-gates.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const readJson = (relative) => JSON.parse(fs.readFileSync(path.join(root, relative), "utf8"));
const realPolicy = readJson(INDEXING_POLICY);

const field = (index, name, type, indexed, cls = indexed ? "filter-key" : "payload") =>
  ({ index, name, type, indexed, class: cls, reason: "fixture" });
const claimId = (index = 0) => field(index, "claimId", "uint256", true, "projection-key");

function entry(name, fields, extra = {}) {
  const signature = `${name}(${fields.map((item) => item.type).join(",")})`;
  const event = {
    signature,
    topic0: extra.anonymous ? null : keccak256Hex(signature),
    anonymous: false,
    source: "fixture",
    phase: "public",
    projectionKeys: fields.filter((item) => item.class === "projection-key").map((item) => item.name),
    fields,
    ...extra,
  };
  event.logGasBudget = extra.logGasBudget ?? eventLogGas(event).logGas;
  return event;
}
const policyOf = (...events) => ({ releaseVersion: "fixture", rules: structuredClone(realPolicy.rules), events });
const derivedOf = (policy) => policy.events.map(({ signature, topic0, anonymous, source, fields }) => ({
  name: signature.slice(0, signature.indexOf("(")),
  signature,
  topic0,
  anonymous,
  source,
  fields: fields.map(({ index, name, type, indexed }) => ({ index, name, type, indexed })),
}));
const check = (policy, derived = derivedOf(policy)) => checkIndexingPolicy(derived, policy);
const has = (problems, pattern) => problems.some((problem) => pattern.test(problem));

/* ---------------------------------------------------------- repository state */

test("committed policy, pinned layout and gas report are consistent", () => {
  assert.deepEqual(checkEventIndexingGates(root), []);
});

test("keccak256 matches known vectors and every released topic0", () => {
  assert.equal(keccak256Hex(""), "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
  assert.equal(keccak256Hex("transfer(address,uint256)").slice(0, 10), "0xa9059cbb");
  const released = deriveEvents(root).filter((event) => event.source === "released-layout");
  assert.equal(released.length, 40);
  for (const event of released) assert.equal(keccak256Hex(event.signature), event.topic0, event.signature);
});

test("policy classifies every derived event and every field with a reason", () => {
  const derived = deriveEvents(root);
  assert.equal(realPolicy.events.length, derived.length);
  for (const event of realPolicy.events) {
    for (const item of event.fields) {
      assert.ok(["projection-key", "filter-key", "payload"].includes(item.class), `${event.signature}.${item.name}`);
      assert.ok(item.reason.trim().length > 0, `${event.signature}.${item.name} reason`);
    }
  }
});

test("commit-phase events never carry pre-reveal data and reveal data is never indexed", () => {
  const protectedName = new RegExp(
    `${realPolicy.rules.protected.neverEmitPattern}|${realPolicy.rules.protected.revealOnlyPattern}`,
  );
  const commitEvents = realPolicy.events.filter((event) => event.source === COMMIT_REVEAL_SOURCE && event.phase === "commit");
  assert.equal(commitEvents.length, 5);
  for (const event of commitEvents) {
    for (const item of event.fields) assert.ok(!protectedName.test(item.name.toLowerCase()), `${event.signature}.${item.name}`);
  }
  const reveal = realPolicy.events.find((event) => event.signature.startsWith("VoteRevealed("));
  assert.equal(reveal.phase, "reveal");
  for (const name of ["decision", "rationaleHash"]) assert.equal(reveal.fields.find((item) => item.name === name).indexed, false);
});

test("required projection keys are indexed on every released and commit-reveal event", () => {
  for (const event of realPolicy.events) {
    assert.ok(event.projectionKeys.length > 0, event.signature);
    for (const name of event.projectionKeys) assert.equal(event.fields.find((item) => item.name === name)?.indexed, true, `${event.signature}.${name}`);
    const claim = event.fields.find((item) => item.name === "claimId");
    if (claim) assert.equal(claim.indexed, true, `${event.signature} claimId`);
    assert.ok(event.fields.filter((item) => item.indexed).length <= 3, event.signature);
  }
});

/* ------------------------------------------------------------------- parser */

test("parses commit-reveal source events, resolving enums to uint8", () => {
  const events = parseSolidityEvents(fs.readFileSync(path.join(root, COMMIT_REVEAL_SOURCE), "utf8"), COMMIT_REVEAL_SOURCE);
  assert.deepEqual(events.map((event) => event.name).sort(), [
    "CommitReplaced", "CommitSubmitted", "MissedRevealRecorded", "RoundRegistered", "VoteRevealed", "VoterSlashed",
  ]);
  const round = events.find((event) => event.name === "RoundRegistered");
  assert.equal(round.fields.at(-1).type, "uint8");
  assert.equal(round.signature, "RoundRegistered(uint256,uint256,uint64,uint64,uint64,uint8)");
});

test("parser ignores comments, detects anonymous events and rejects unknown types", () => {
  const source = `
    // event Hidden(uint256 indexed x);
    /* event AlsoHidden(uint256 x); */
    enum Mode { A, B }
    event Seen(address indexed who, Mode mode) anonymous;
  `;
  const events = parseSolidityEvents(source, "fixture.sol");
  assert.equal(events.length, 1);
  assert.equal(events[0].anonymous, true);
  assert.equal(events[0].topic0, null);
  assert.equal(events[0].signature, "Seen(address,uint8)");
  assert.throws(() => parseSolidityEvents("event Bad(Struct s);", "fixture.sol"), /unsupported event parameter type/);
});

/* --------------------------------------------- protected rationale / salt data */

test("protected salt and raw rationale are rejected in any event, indexed or not", () => {
  const leaky = entry("CommitSubmittedV2", [claimId(), field(1, "salt", "bytes32", false), field(2, "rationale", "bytes32", false)], { source: COMMIT_REVEAL_SOURCE, phase: "commit" });
  const problems = check(policyOf(leaky));
  assert.ok(has(problems, /protected field CommitSubmittedV2\(.*\)\.salt must never be emitted/));
  assert.ok(has(problems, /protected field .*\.rationale must never be emitted/));

  const indexedSalt = entry("RevealV2", [claimId(), field(1, "voterSalt", "bytes32", true)], {});
  assert.ok(has(check(policyOf(indexedSalt)), /voterSalt must never be emitted/));
});

test("pre-reveal decision and rationale hash cannot leak from commit-phase events", () => {
  const commit = entry("CommitSubmittedV2", [claimId(), field(1, "decision", "uint8", false), field(2, "rationaleHash", "bytes32", false)], { source: COMMIT_REVEAL_SOURCE, phase: "commit" });
  const problems = check(policyOf(commit));
  assert.ok(has(problems, /pre-reveal leak: .*decision emitted by a commit-phase event/));
  assert.ok(has(problems, /pre-reveal leak: .*rationaleHash emitted by a commit-phase event/));
});

test("reveal data is only allowed unindexed in the reveal-phase event", () => {
  const reveal = entry("VoteRevealed", [claimId(), field(1, "decision", "uint8", false), field(2, "rationaleHash", "bytes32", false)], { source: COMMIT_REVEAL_SOURCE, phase: "reveal" });
  assert.deepEqual(check(policyOf(reveal)), []);

  const indexed = entry("VoteRevealed", [claimId(), field(1, "rationaleHash", "bytes32", true)], { source: COMMIT_REVEAL_SOURCE, phase: "reveal" });
  const problems = check(policyOf(indexed));
  assert.ok(has(problems, /rationaleHash must never be indexed/));

  const movedToPublic = entry("VoteRevealed", [claimId(), field(1, "decision", "uint8", false)], { source: COMMIT_REVEAL_SOURCE, phase: "public" });
  assert.ok(has(check(policyOf(movedToPublic)), /phase mismatch for VoteRevealed/));
});

test("a verdict emitted outside the reveal phase needs a documented exception", () => {
  const base = () => entry("VerdictV2", [claimId(), field(1, "supportsClaim", "bool", false)]);
  assert.ok(has(check(policyOf(base())), /emitted outside the reveal phase without a documented exception/));

  const excepted = base();
  excepted.exceptions = [{ rule: "protected-emitted", field: "supportsClaim", reason: "direct path, no commit phase" }];
  assert.deepEqual(check(policyOf(excepted)), []);

  excepted.exceptions[0].reason = "  ";
  assert.ok(has(check(policyOf(excepted)), /has no reason/));
});

test("exceptions cannot waive never-emit, topic-limit or anonymous rules", () => {
  const salty = entry("SaltedV2", [claimId(), field(1, "salt", "bytes32", false)]);
  salty.exceptions = [{ rule: "protected-never-emit", field: "salt", reason: "please" }];
  const problems = check(policyOf(salty));
  assert.ok(has(problems, /not an allowed exception rule/));
  assert.ok(has(problems, /salt must never be emitted/));
});

/* --------------------------------------------------- cardinality and topic cost */

test("high-cardinality indexed fields need a documented lookup reason", () => {
  const hashIndexed = () => entry("CommittedV2", [claimId(), field(1, "commitmentHash", "bytes32", true)]);
  assert.ok(has(check(policyOf(hashIndexed())), /high-cardinality indexed field .*commitmentHash/));

  const excepted = hashIndexed();
  excepted.exceptions = [{ rule: "high-cardinality-indexed", field: "commitmentHash", reason: "looked up by value" }];
  assert.deepEqual(check(policyOf(excepted)), []);

  const timestamp = entry("StampedV2", [claimId(), field(1, "timestamp", "uint64", true)]);
  assert.ok(has(check(policyOf(timestamp)), /high-cardinality indexed field .*timestamp/));
});

test("unused exceptions are stale and low-cardinality or dynamic indexed fields are rejected", () => {
  const stale = entry("QuietV2", [claimId(), field(1, "hash", "bytes32", false)]);
  stale.exceptions = [{ rule: "high-cardinality-indexed", field: "hash", reason: "not actually indexed" }];
  assert.ok(has(check(policyOf(stale)), /stale exception high-cardinality-indexed:hash/));

  const flag = entry("FlagV2", [claimId(), field(1, "accepted", "bool", true)]);
  assert.ok(has(check(policyOf(flag)), /low-cardinality indexed field .*accepted/));

  const text = entry("TextV2", [claimId(), field(1, "memo", "string", true)]);
  assert.ok(has(check(policyOf(text)), /dynamic type indexed/));
});

test("a fourth indexed topic is rejected", () => {
  const four = entry("WideV2", [claimId(), field(1, "a", "address", true), field(2, "b", "address", true), field(3, "c", "address", true)]);
  assert.ok(has(check(policyOf(four)), /topic limit exceeded by WideV2/));
});

/* --------------------------------------------------------- topic layout drift */

test("topic-order drift against the pinned layout is rejected", () => {
  const pinned = policyOf(entry("OrderedV2", [claimId(0), field(1, "account", "address", true), field(2, "amount", "uint256", false)]));
  const drifted = derivedOf(pinned);
  drifted[0].fields = [
    { index: 0, name: "account", type: "address", indexed: true },
    { index: 1, name: "claimId", type: "uint256", indexed: true },
    { index: 2, name: "amount", type: "uint256", indexed: false },
  ];
  assert.ok(has(check(pinned, drifted), /layout: indexed layout or field order\/type drift for OrderedV2/));
});

test("flipping a field between indexed and data is drift, not a silent change", () => {
  const pinned = policyOf(entry("FlipV2", [claimId(0), field(1, "account", "address", true), field(2, "amount", "uint256", false)]));
  const flipped = derivedOf(pinned);
  flipped[0].fields[2].indexed = true;
  assert.ok(has(check(pinned, flipped), /drift for FlipV2/));
});

test("removed events, unversioned additions and topic collisions are rejected; versioned additions must be classified", () => {
  const pinned = policyOf(entry("KeepV2", [claimId()]), entry("GoneV2", [claimId()]));
  const derived = derivedOf(pinned).filter((event) => event.signature.startsWith("KeepV2"));
  const problems = check(pinned, derived);
  assert.ok(has(problems, /layout: released event removed: GoneV2/));
  assert.ok(has(problems, /stale policy entry GoneV2/));

  const withNew = [...derivedOf(pinned), { name: "Fresh", signature: "Fresh(uint256)", topic0: keccak256Hex("Fresh(uint256)"), anonymous: false, source: "fixture", fields: [{ index: 0, name: "claimId", type: "uint256", indexed: true }] }];
  assert.ok(has(check(pinned, withNew), /new event Fresh\(uint256\) must use a new versioned event name/));

  const versioned = [...derivedOf(pinned), { ...withNew.at(-1), name: "FreshV2", signature: "FreshV2(uint256)", topic0: keccak256Hex("FreshV2(uint256)") }];
  const versionedProblems = check(pinned, versioned);
  assert.ok(has(versionedProblems, /unclassified event FreshV2\(uint256\)/));
  assert.ok(!has(versionedProblems, /versioned event name/));

  const tampered = structuredClone(pinned);
  tampered.events[0].topic0 = `0x${"11".repeat(32)}`;
  assert.ok(has(check(tampered), /topic0 does not match keccak256\(KeepV2/));
});

/* ----------------------------------------------------------- anonymous events */

test("anonymous events are forbidden even within the four-topic limit", () => {
  const anon = entry("AnonV2", [claimId(), field(1, "a", "address", true), field(2, "b", "address", true), field(3, "c", "address", true)], { anonymous: true });
  const problems = check(policyOf(anon));
  assert.ok(has(problems, /anonymous event AnonV2\(.*\): anonymous events are forbidden/));
  assert.ok(!has(problems, /topic limit/), "four topics are legal for anonymous events");

  const live = deriveEvents(root).find((event) => event.anonymous);
  assert.equal(live, undefined, "no released event is anonymous");
});

test("an anonymous event pinned as non-anonymous is layout drift", () => {
  const pinned = policyOf(entry("ToggleV2", [claimId()]));
  const drifted = derivedOf(pinned);
  drifted[0].anonymous = true;
  assert.ok(has(check(pinned, drifted), /drift for ToggleV2/));
});

/* ----------------------------------------------- required projection keys */

test("required projection keys must exist, be indexed and be declared", () => {
  const noKeys = entry("NoKeyV2", [field(0, "account", "address", true)]);
  assert.ok(has(check(policyOf(noKeys)), /NoKeyV2\(.*\) declares no required projection key/));

  const unindexed = entry("KeyV2", [claimId(0), field(1, "settlementId", "bytes32", false)], { projectionKeys: ["claimId", "settlementId", "ghost"] });
  const problems = check(policyOf(unindexed));
  assert.ok(has(problems, /projection key .*settlementId is not indexed/));
  assert.ok(has(problems, /projection key .*ghost is not an event field/));

  const undeclared = entry("UndeclaredV2", [claimId(0)], { projectionKeys: [] });
  assert.ok(has(check(policyOf(undeclared)), /projection-key field .*claimId missing from projectionKeys/));
});

test("claim-scoped events must index claimId unless a reason is documented", () => {
  const unindexed = () => entry("ScopedV2", [field(0, "claimId", "uint256", false), field(1, "id", "bytes32", true, "projection-key")]);
  assert.ok(has(check(policyOf(unindexed())), /claim-scoped event ScopedV2\(.*\) must index claimId/));

  const excepted = unindexed();
  excepted.exceptions = [{ rule: "claim-key-not-indexed", field: "claimId", reason: "claim is derived from id" }];
  assert.deepEqual(check(policyOf(excepted)), []);
});

test("class and indexing must agree and every field needs a reason", () => {
  const mismatch = entry("MismatchV2", [claimId(0), field(1, "account", "address", true, "payload")]);
  assert.ok(has(check(policyOf(mismatch)), /class mismatch for .*account: class payload but indexed=true/));

  const unreasoned = entry("UnreasonedV2", [claimId(0), { ...field(1, "amount", "uint256", false), reason: "" }]);
  assert.ok(has(check(policyOf(unreasoned)), /field .*amount has no classification reason/));

  const unclassified = entry("UnclassifiedV2", [claimId(0), { ...field(1, "amount", "uint256", false), class: "maybe" }]);
  assert.ok(has(check(policyOf(unclassified)), /unclassified field .*amount/));
});

/* ------------------------------------------------------------------------ gas */

test("LOG gas follows 375 + 375 per topic + 8 per data byte", () => {
  const aggregation = realPolicy.events.find((event) => event.signature.startsWith("AggregationFinalized("));
  // topic0 + claimId = 2 topics; five 32-byte data words.
  assert.deepEqual(eventLogGas(aggregation), { topics: 2, indexedFields: 1, dataBytes: 160, dynamic: false, logGas: 375 + 2 * 375 + 8 * 160 });
  assert.equal(eventLogGas(aggregation).logGas, 2405);

  const anonymous = eventLogGas({ anonymous: true, fields: [field(0, "a", "address", true), field(1, "b", "uint256", false)] });
  assert.equal(anonymous.topics, 1);
  assert.equal(anonymous.logGas, 375 + 375 + 8 * 32);

  const dynamic = eventLogGas({ anonymous: false, fields: [field(0, "memo", "string", false)] });
  assert.equal(dynamic.dynamic, true);
  assert.equal(dynamic.dataBytes, 64);
});

test("indexing one more static word costs exactly 119 gas", () => {
  const asData = { anonymous: false, fields: [claimId(0), field(1, "account", "address", false)] };
  const asTopic = { anonymous: false, fields: [claimId(0), field(1, "account", "address", true)] };
  assert.equal(INDEX_TOGGLE_GAS, 119);
  assert.equal(eventLogGas(asTopic).logGas - eventLogGas(asData).logGas, INDEX_TOGGLE_GAS);
});

test("a gas regression on an event is rejected against its recorded budget", () => {
  const lean = entry("LeanV2", [claimId(0), field(1, "amount", "uint256", false)]);
  assert.deepEqual(check(policyOf(lean)), []);
  const heavier = structuredClone(lean);
  heavier.fields.push(field(2, "extra", "uint256", false));
  heavier.signature = lean.signature;
  const pinned = policyOf(lean);
  const grown = policyOf({ ...heavier, topic0: lean.topic0, logGasBudget: lean.logGasBudget });
  const problems = checkIndexingPolicy(derivedOf(grown), grown);
  assert.ok(has(problems, /gas budget exceeded by LeanV2/));
  assert.ok(pinned.events[0].logGasBudget < eventLogGas(heavier).logGas);
});

test("gas report is deterministic, complete and matches the committed artifact", () => {
  const report = buildGasReport(realPolicy);
  assert.deepEqual(report, buildGasReport(structuredClone(realPolicy)));
  assert.deepEqual(report, readJson(INDEXING_GAS_REPORT));
  assert.equal(report.eventCount, realPolicy.events.length);
  assert.equal(report.totalLogGas, report.events.reduce((sum, event) => sum + event.logGas, 0));
  assert.equal(report.maxLogGas.logGas, Math.max(...report.events.map((event) => event.logGas)));
  for (const event of report.events) {
    const budget = realPolicy.events.find((item) => item.signature === event.signature && item.source === event.source).logGasBudget;
    assert.ok(event.logGas <= budget, event.signature);
  }
});

test("a stale gas report is rejected", () => {
  const stale = structuredClone(readJson(INDEXING_GAS_REPORT));
  stale.totalLogGas += 1;
  const problems = checkIndexingPolicy(deriveEvents(root), realPolicy, { gasReport: stale });
  assert.ok(has(problems, /gas report drift/));
});

/* ------------------------------------------------------------- completeness */

test("an unclassified event and a stale policy entry are both reported", () => {
  const derived = deriveEvents(root);
  const missing = realPolicy.events.slice(1);
  assert.ok(has(checkIndexingPolicy(derived, { ...realPolicy, events: missing }), /unclassified event /));

  const withGhost = { ...realPolicy, events: [...realPolicy.events, entry("GhostV2", [claimId(0)])] };
  assert.ok(has(checkIndexingPolicy(derived, withGhost), /stale policy entry GhostV2/));
});
