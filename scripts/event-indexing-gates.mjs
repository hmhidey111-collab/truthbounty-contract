// PREWAVE-SC-089 (#765) — event indexing policy gate.
//
// Classifies every V2 event field as indexed (topic) or unindexed (data) from
// query need, privacy, cardinality, topic limit and gas, pins the resulting
// topic layout, and records the deterministic LOG gas of every event.
//
// Pure Node, no compiler: released events come from the frozen layout manifest
// (schemas/event-layout-v2.json); commit-reveal events are parsed from the
// Solidity interface source, so the gate also covers events that are not part of
// the canonical ABI export.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { EVENT_LAYOUT_MANIFEST, compareEventLayouts } from "./canonical-abi-gates.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const INDEXING_POLICY = "config/event-indexing-policy.json";
export const INDEXING_GAS_REPORT = "schemas/event-indexing-gas-report-v2.json";
export const COMMIT_REVEAL_SOURCE = "contracts/v2/interfaces/IV2CommitReveal.sol";
export const RELEASED_LAYOUT_SOURCE = "released-layout";

// EVM LOG cost model: LOG_BASE + LOG_TOPIC per topic + LOG_DATA per data byte.
export const LOG_GAS = Object.freeze({ base: 375, topic: 375, dataByte: 8 });
export const WORD_BYTES = 32;
// Cost of moving one static 32-byte word from log data into a topic.
export const INDEX_TOGGLE_GAS = LOG_GAS.topic - LOG_GAS.dataByte * WORD_BYTES;

/* ------------------------------------------------------------------ keccak */

const MASK = (1n << 64n) - 1n;
const ROUND_CONSTANTS = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
const ROTATIONS = [
  [0, 36, 3, 41, 18],
  [1, 44, 10, 45, 2],
  [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56],
  [27, 20, 39, 8, 14],
];
const rotl = (value, amount) => {
  const n = BigInt(amount) % 64n;
  return n === 0n ? value : ((value << n) | (value >> (64n - n))) & MASK;
};

function keccakF(state) {
  for (let round = 0; round < 24; round += 1) {
    const c = [0, 1, 2, 3, 4].map((x) => state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]);
    const d = [0, 1, 2, 3, 4].map((x) => c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1));
    for (let i = 0; i < 25; i += 1) state[i] ^= d[i % 5];
    const b = new Array(25).fill(0n);
    for (let x = 0; x < 5; x += 1) {
      for (let y = 0; y < 5; y += 1) b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(state[x + 5 * y], ROTATIONS[x][y]);
    }
    for (let x = 0; x < 5; x += 1) {
      for (let y = 0; y < 5; y += 1) {
        state[x + 5 * y] = b[x + 5 * y] ^ ((~b[((x + 1) % 5) + 5 * y] & MASK) & b[((x + 2) % 5) + 5 * y]);
      }
    }
    state[0] ^= ROUND_CONSTANTS[round];
  }
}

/** Ethereum keccak-256 (original padding, not NIST SHA3). Returns 0x-prefixed hex. */
export function keccak256Hex(input) {
  const data = typeof input === "string" ? Buffer.from(input, "utf8") : Buffer.from(input);
  const rate = 136;
  const padded = Buffer.concat([data, Buffer.alloc(rate - (data.length % rate))]);
  padded[data.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  const state = new Array(25).fill(0n);
  for (let offset = 0; offset < padded.length; offset += rate) {
    for (let i = 0; i < rate / 8; i += 1) state[i] ^= padded.readBigUInt64LE(offset + i * 8);
    keccakF(state);
  }
  const out = Buffer.alloc(32);
  for (let i = 0; i < 4; i += 1) out.writeBigUInt64LE(state[i], i * 8);
  return `0x${out.toString("hex")}`;
}

/* ------------------------------------------------------- Solidity events */

const ELEMENTARY = /^(?:u?int(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)?|address|bool|bytes(?:[1-9]|[12][0-9]|3[0-2])?|string)(?:\[\d*\])*$/;
const isDynamicType = (type) => type === "string" || type === "bytes" || /\[\]/.test(type);

const stripComments = (source) => source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");

/** Parse `event` declarations from Solidity source; enums resolve to uint8. */
export function parseSolidityEvents(source, file = "<source>") {
  const clean = stripComments(source);
  const enums = new Set([...clean.matchAll(/\benum\s+(\w+)/g)].map((match) => match[1]));
  const events = [];
  for (const match of clean.matchAll(/\bevent\s+(\w+)\s*\(([^)]*)\)\s*(anonymous)?\s*;/g)) {
    const fields = match[2].split(",").map((part) => part.trim()).filter(Boolean).map((raw, index) => {
      const tokens = raw.split(/\s+/);
      const indexed = tokens.includes("indexed");
      const rest = tokens.filter((token) => token !== "indexed");
      if (rest.length < 1 || rest.length > 2) throw new Error(`${file}: cannot parse event parameter "${raw}" in ${match[1]}`);
      const type = enums.has(rest[0]) ? "uint8" : rest[0];
      if (!ELEMENTARY.test(type)) throw new Error(`${file}: unsupported event parameter type "${rest[0]}" in ${match[1]}`);
      return { index, name: rest[1] ?? "", type, indexed };
    });
    const signature = `${match[1]}(${fields.map((field) => field.type).join(",")})`;
    const anonymous = Boolean(match[3]);
    events.push({ name: match[1], signature, topic0: anonymous ? null : keccak256Hex(signature), anonymous, fields, source: file });
  }
  return events.sort((a, b) => a.signature.localeCompare(b.signature));
}

/* -------------------------------------------------------------- gas model */

/** Deterministic LOG gas for one event layout. Dynamic fields are lower-bounded. */
export function eventLogGas(event) {
  const indexed = event.fields.filter((field) => field.indexed);
  const data = event.fields.filter((field) => !field.indexed);
  const dynamic = data.some((field) => isDynamicType(field.type));
  const dataBytes = data.reduce((sum, field) => sum + (isDynamicType(field.type) ? 2 * WORD_BYTES : WORD_BYTES), 0);
  const topics = (event.anonymous ? 0 : 1) + indexed.length;
  return {
    topics,
    indexedFields: indexed.length,
    dataBytes,
    dynamic,
    logGas: LOG_GAS.base + LOG_GAS.topic * topics + LOG_GAS.dataByte * dataBytes,
  };
}

export function buildGasReport(policy) {
  const events = policy.events.map((event) => ({
    signature: event.signature,
    source: event.source,
    ...eventLogGas(event),
  })).sort((a, b) => a.signature.localeCompare(b.signature) || a.source.localeCompare(b.source));
  const max = events.reduce((best, event) => (event.logGas > best.logGas ? event : best), events[0] ?? { logGas: 0, signature: "" });
  return {
    schemaVersion: 1,
    protocol: "TruthBounty",
    releaseVersion: policy.releaseVersion,
    model: { ...LOG_GAS, indexToggleGasPerStaticWord: INDEX_TOGGLE_GAS, note: "LOG gas only; excludes memory expansion and the emitting call's own execution." },
    eventCount: events.length,
    totalLogGas: events.reduce((sum, event) => sum + event.logGas, 0),
    maxLogGas: { signature: max.signature, logGas: max.logGas },
    events,
  };
}

/* ----------------------------------------------------------- derive events */

const readJson = (rootDir, relative) => JSON.parse(fs.readFileSync(path.join(rootDir, relative), "utf8"));

/** Every event the policy must classify: released layout plus commit-reveal source. */
export function deriveEvents(rootDir = root) {
  const layout = readJson(rootDir, EVENT_LAYOUT_MANIFEST);
  const released = (layout.events ?? []).map((event) => ({
    name: event.signature.slice(0, event.signature.indexOf("(")),
    signature: event.signature,
    topic0: event.topic0,
    anonymous: Boolean(event.anonymous),
    fields: event.fields,
    source: RELEASED_LAYOUT_SOURCE,
  }));
  const source = fs.readFileSync(path.join(rootDir, COMMIT_REVEAL_SOURCE), "utf8");
  return [...released, ...parseSolidityEvents(source, COMMIT_REVEAL_SOURCE)];
}

/* ------------------------------------------------------------------ rules */

const EXCEPTION_RULES = new Set([
  "low-cardinality-indexed",
  "high-cardinality-indexed",
  "claim-key-not-indexed",
  "protected-emitted",
]);
const INDEXED_CLASSES = new Set(["projection-key", "filter-key"]);
const ALL_CLASSES = new Set(["projection-key", "filter-key", "payload"]);
const LOW_CARDINALITY_TYPES = /^(?:bool|uint8)$/;
const key = (event) => `${event.source}::${event.signature}`;

function expectedPhase(event, rules) {
  if (event.source === RELEASED_LAYOUT_SOURCE) return "public";
  if ((rules.revealPhaseEvents ?? []).includes(event.name ?? event.signature.slice(0, event.signature.indexOf("(")))) return "reveal";
  return rules.phaseBySource?.[event.source] ?? "public";
}

/**
 * Check a policy against the derived events. Returns sorted problem strings.
 * `derived` is the output of deriveEvents(); `policy` the parsed policy JSON.
 */
export function checkIndexingPolicy(derived, policy, { gasReport } = {}) {
  const problems = [];
  const rules = policy.rules ?? {};
  const maxTopics = rules.maxIndexedTopics ?? 3;
  const neverEmit = new RegExp(rules.protected?.neverEmitPattern ?? "(?!)");
  const revealOnly = new RegExp(rules.protected?.revealOnlyPattern ?? "(?!)");
  const highCardinality = new RegExp(rules.highCardinalityPattern ?? "(?!)", "i");
  const claimKeys = new Set(rules.claimKeyFields ?? []);

  const policyByKey = new Map(policy.events.map((event) => [key(event), event]));
  const derivedByKey = new Map(derived.map((event) => [key(event), event]));

  for (const event of derived) {
    if (!policyByKey.has(key(event))) problems.push(`unclassified event ${event.signature} (${event.source})`);
  }
  for (const event of policy.events) {
    if (!derivedByKey.has(key(event))) problems.push(`stale policy entry ${event.signature} (${event.source}): event no longer exists`);
  }

  // Topic layouts are frozen: drift against the pinned policy layout is an error,
  // and any change must arrive as a new versioned event name.
  const pinned = { events: policy.events.map(({ signature, topic0, anonymous, fields }) => ({
    signature,
    topic0,
    anonymous,
    fields: fields.map(({ index, name, type, indexed }) => ({ index, name, type, indexed })),
  })) };
  const current = { events: derived.map(({ signature, topic0, anonymous, fields }) => ({
    signature,
    topic0,
    anonymous,
    fields: fields.map(({ index, name, type, indexed }) => ({ index, name, type, indexed })),
  })) };
  for (const problem of compareEventLayouts(pinned, current)) problems.push(`layout: ${problem}`);

  for (const event of policy.events) {
    const label = event.signature;
    const used = new Set();
    const exception = (rule, field) => {
      const hit = (event.exceptions ?? []).find((item) => item.rule === rule && item.field === field);
      if (hit) used.add(`${rule}:${field}`);
      return hit;
    };

    if (!event.anonymous && event.topic0 !== keccak256Hex(label)) problems.push(`topic0 does not match keccak256(${label})`);
    if (event.anonymous) problems.push(`anonymous event ${label}: anonymous events are forbidden (no topic0 means no safe projection filter)`);

    const indexedCount = event.fields.filter((field) => field.indexed).length;
    if (indexedCount > (event.anonymous ? 4 : maxTopics)) problems.push(`topic limit exceeded by ${label}: ${indexedCount} indexed fields`);

    const phase = expectedPhase(event, rules);
    if (event.phase !== phase) problems.push(`phase mismatch for ${label}: policy says ${event.phase}, expected ${phase}`);

    const fieldNames = new Set();
    for (const field of event.fields) {
      const where = `${label}.${field.name}`;
      fieldNames.add(field.name);
      if (!ALL_CLASSES.has(field.class)) {
        problems.push(`unclassified field ${where}: class must be one of ${[...ALL_CLASSES].join(", ")}`);
        continue;
      }
      if (typeof field.reason !== "string" || !field.reason.trim()) problems.push(`field ${where} has no classification reason`);
      if (INDEXED_CLASSES.has(field.class) !== Boolean(field.indexed)) {
        problems.push(`class mismatch for ${where}: class ${field.class} but indexed=${field.indexed}`);
      }

      const name = field.name.toLowerCase();
      if (neverEmit.test(name)) problems.push(`protected field ${where} must never be emitted`);
      if (revealOnly.test(name)) {
        if (field.indexed) problems.push(`protected field ${where} must never be indexed`);
        if (event.phase === "commit") problems.push(`pre-reveal leak: ${where} emitted by a commit-phase event`);
        else if (event.phase !== "reveal" && !exception("protected-emitted", field.name)) {
          problems.push(`protected field ${where} emitted outside the reveal phase without a documented exception`);
        }
      }

      if (field.indexed) {
        if (isDynamicType(field.type)) problems.push(`dynamic type indexed for ${where}: topic holds only a hash, the value is unrecoverable`);
        if (LOW_CARDINALITY_TYPES.test(field.type) && !exception("low-cardinality-indexed", field.name)) {
          problems.push(`low-cardinality indexed field ${where} (${field.type}) wastes a topic`);
        }
        if (highCardinality.test(field.name) && !exception("high-cardinality-indexed", field.name)) {
          problems.push(`high-cardinality indexed field ${where} needs a documented lookup reason`);
        }
      } else if (claimKeys.has(field.name) && !exception("claim-key-not-indexed", field.name)) {
        problems.push(`claim-scoped event ${label} must index ${field.name}`);
      }
    }

    const keys = event.projectionKeys ?? [];
    if (keys.length === 0) problems.push(`${label} declares no required projection key`);
    for (const name of keys) {
      const field = event.fields.find((item) => item.name === name);
      if (!field) problems.push(`required projection key ${label}.${name} is not an event field`);
      else if (!field.indexed) problems.push(`required projection key ${label}.${name} is not indexed`);
    }
    for (const field of event.fields.filter((item) => item.class === "projection-key")) {
      if (!keys.includes(field.name)) problems.push(`projection-key field ${label}.${field.name} missing from projectionKeys`);
    }

    for (const item of event.exceptions ?? []) {
      if (!EXCEPTION_RULES.has(item.rule)) problems.push(`exception ${item.rule} on ${label} is not an allowed exception rule`);
      else if (!fieldNames.has(item.field)) problems.push(`exception on ${label} references unknown field ${item.field}`);
      else if (typeof item.reason !== "string" || !item.reason.trim()) problems.push(`exception ${item.rule}:${item.field} on ${label} has no reason`);
      else if (!used.has(`${item.rule}:${item.field}`)) problems.push(`stale exception ${item.rule}:${item.field} on ${label}`);
    }

    const gas = eventLogGas(event);
    if (typeof event.logGasBudget !== "number") problems.push(`${label} has no logGasBudget`);
    else if (gas.logGas > event.logGasBudget) problems.push(`gas budget exceeded by ${label}: ${gas.logGas} > ${event.logGasBudget}`);
  }

  if (gasReport !== undefined && JSON.stringify(gasReport) !== JSON.stringify(buildGasReport(policy))) {
    problems.push(`gas report drift: ${INDEXING_GAS_REPORT} does not match the policy`);
  }
  return problems.sort();
}

export function checkEventIndexingGates(rootDir = root) {
  const policy = readJson(rootDir, INDEXING_POLICY);
  const gasReport = readJson(rootDir, INDEXING_GAS_REPORT);
  return checkIndexingPolicy(deriveEvents(rootDir), policy, { gasReport });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.includes("--write-gas-report")) {
    const policy = readJson(root, INDEXING_POLICY);
    fs.writeFileSync(path.join(root, INDEXING_GAS_REPORT), `${JSON.stringify(buildGasReport(policy), null, 2)}\n`);
    console.log(`Wrote ${INDEXING_GAS_REPORT}`);
  } else {
    const problems = checkEventIndexingGates();
    if (problems.length) {
      for (const problem of problems) console.error(`EVENT-INDEXING: ${problem}`);
      process.exitCode = 1;
    } else console.log("Event indexing policy is complete, privacy-safe, layout-frozen and within gas budgets.");
  }
}
