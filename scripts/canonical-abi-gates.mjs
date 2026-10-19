import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const ABI_EXPORT = "exports/abi/v2/2.0.0-2.0/manifest.json";
export const COLLISION_ALLOWLIST = "config/abi-collision-allowlist.json";
export const EVENT_LAYOUT_MANIFEST = "schemas/event-layout-v2.json";
export const COLLISION_REPORT = "schemas/abi-collision-report-v2.json";
const PROXY_RESERVED = new Map([["0x4f1ef286", "transparent-proxy admin dispatch"]]);

const canonicalSignature = (entry) => {
  const inputs = (entry.inputs ?? []).map((input) => canonicalType(input)).join(",");
  return `${entry.name}(${inputs})`;
};

function canonicalType(param) {
  if (param.type?.startsWith("tuple")) {
    return `(${(param.components ?? []).map(canonicalType).join(",")})${param.type.slice(5)}`;
  }
  return param.type;
}

const functionShape = (entry, signature = canonicalSignature(entry)) =>
  `${signature}->(${(entry.outputs ?? []).map(canonicalType).join(",")})|${entry.stateMutability ?? "nonpayable"}`;

export function findAbiCollisions(bundle, allowlist = { functions: {}, errors: {} }) {
  const problems = [];
  const entries = [];
  for (const module of [...(bundle.modules ?? []), ...(bundle.extensions ?? [])]) {
    for (const entry of module.functions ?? []) entries.push({
      kind: "function", signature: entry.signature, selector: entry.selector, module: module.name,
      shape: `${entry.signature}->(${(entry.outputs ?? []).join(",")})|${entry.stateMutability ?? "nonpayable"}`,
    });
    for (const entry of module.errors ?? []) entries.push({ kind: "error", signature: entry.signature, selector: entry.selector, module: module.name, shape: entry.signature });
  }
  const moduleSignatures = new Set(entries.map((entry) => `${entry.kind}:${entry.signature}`));
  for (const entry of bundle.canonicalAbi ?? []) {
    if (entry.type !== "function" && entry.type !== "error") continue;
    const signature = entry.signature ?? canonicalSignature(entry);
    if (moduleSignatures.has(`${entry.type}:${signature}`)) continue;
    const moduleEntry = (bundle.modules ?? []).flatMap((module) => module[entry.type === "function" ? "functions" : "errors"] ?? [])
      .find((candidate) => candidate.signature === signature);
    entries.push({
      kind: entry.type,
      signature,
      selector: entry.selector ?? moduleEntry?.selector,
      module: entry.source ?? "canonical ABI",
      shape: entry.type === "function" ? functionShape(entry, signature) : signature,
    });
  }

  for (const kind of ["function", "error"]) {
    const groups = new Map();
    for (const entry of entries.filter((candidate) => candidate.kind === kind)) {
      const selector = entry.selector ?? selectorOf(entry.signature);
      const group = groups.get(selector) ?? [];
      group.push({ ...entry, selector });
      groups.set(selector, group);
    }
    for (const [selector, group] of groups) {
      const signatures = [...new Set(group.map((entry) => entry.signature))].sort();
      const shapes = [...new Set(group.map((entry) => entry.shape))];
      if (kind === "function" && PROXY_RESERVED.has(selector)) {
        problems.push(`${kind} selector ${selector} (${signatures.join(", ")}) collides with ${PROXY_RESERVED.get(selector)}`);
      }
      if (signatures.length > 1) {
        problems.push(`${kind} selector collision ${selector}: ${signatures.join(" <> ")}`);
      } else if (group.length > 1) {
        const key = signatures[0];
        if (shapes.length > 1) {
          problems.push(`${kind} ${key} has incompatible parameter/return semantics across modules`);
        } else {
          const allowlistKind = kind === "function" ? "functions" : "errors";
          if (typeof allowlist[allowlistKind]?.[key] !== "string" || !allowlist[allowlistKind][key].trim()) {
          problems.push(`${kind} ${key} is duplicated across modules without a documented allowlist entry`);
          }
        }
      }
    }
  }
  return problems.sort();
}

export function buildCollisionReport(bundle) {
  const entries = [];
  for (const module of [...(bundle.modules ?? []), ...(bundle.extensions ?? [])]) {
    for (const kind of ["function", "error", "event"]) {
      for (const entry of module[kind === "function" ? "functions" : `${kind}s`] ?? []) {
        entries.push({ kind, signature: entry.signature, selector: kind === "event" ? null : entry.selector,
          topic0: kind === "event" ? entry.topic0 : null, contract: module.name, source: module.source });
      }
    }
  }
  return { schemaVersion: 1, releaseVersion: bundle.releaseVersion,
    entries: entries.sort((a, b) => a.kind.localeCompare(b.kind) || a.signature.localeCompare(b.signature) || a.contract.localeCompare(b.contract)) };
}

function eventLayout(bundle) {
  const events = [];
  const abi = [...(bundle.canonicalAbi ?? []), ...(bundle.extensions ?? []).flatMap(extension => extension.abi ?? [])];
  for (const event of abi.filter((entry) => entry.type === "event")) {
    const signature = event.signature ?? canonicalSignature(event);
    events.push({
      module: event.source ?? (bundle.extensions ?? []).find(extension => extension.abi?.includes(event))?.name ?? "canonical ABI",
      signature,
      topic0: event.anonymous ? null : (event.topic0 ?? event.topic ?? [...(bundle.modules ?? []), ...(bundle.extensions ?? [])].flatMap((module) => module.events ?? []).find((candidate) => candidate.signature === signature)?.topic0),
      anonymous: Boolean(event.anonymous),
      fields: (event.inputs ?? []).map((input, index) => ({ index, name: input.name ?? "", type: canonicalType(input), indexed: Boolean(input.indexed) })),
    });
  }
  return events.sort((a, b) => a.signature.localeCompare(b.signature) || a.module.localeCompare(b.module));
}

export function compareEventLayouts(previous, current) {
  const problems = [];
  const topics = new Map();
  for (const event of current.events ?? []) {
    if (event.anonymous || !event.topic0) continue;
    const signatures = topics.get(event.topic0) ?? new Set();
    signatures.add(event.signature);
    topics.set(event.topic0, signatures);
  }
  for (const [topic, signatures] of topics) {
    if (signatures.size > 1) problems.push(`event topic collision ${topic}: ${[...signatures].sort().join(" <> ")}`);
  }
  const oldBySig = new Map((previous.events ?? []).map((event) => [event.signature, event]));
  const newBySig = new Map((current.events ?? []).map((event) => [event.signature, event]));
  for (const [signature, oldEvent] of oldBySig) {
    const next = newBySig.get(signature);
    if (!next) {
      problems.push(`released event removed: ${signature}`);
      continue;
    }
    if (JSON.stringify(oldEvent.fields) !== JSON.stringify(next.fields) || Boolean(oldEvent.anonymous) !== Boolean(next.anonymous)) {
      problems.push(`indexed layout or field order/type drift for ${signature}`);
    }
  }
  for (const [signature, event] of newBySig) {
    if (oldBySig.has(signature)) continue;
    const name = signature.slice(0, signature.indexOf("("));
    if (!/(?:V|Version)[2-9][0-9]*$/.test(name)) problems.push(`new event ${signature} must use a new versioned event name`);
    if (!event.topic0) problems.push(`new versioned event ${signature} is missing topic0`);
  }
  return problems.sort();
}

export function buildEventLayout(bundle) {
  return { schemaVersion: 1, protocol: "TruthBounty", releaseVersion: bundle.releaseVersion, events: eventLayout(bundle) };
}

function readJson(relative) { return JSON.parse(fs.readFileSync(path.join(root, relative), "utf8")); }

export function checkCanonicalAbiGates(rootDir = root) {
  const bundle = JSON.parse(fs.readFileSync(path.join(rootDir, ABI_EXPORT), "utf8"));
  const allowlist = JSON.parse(fs.readFileSync(path.join(rootDir, COLLISION_ALLOWLIST), "utf8"));
  const problems = findAbiCollisions(bundle, allowlist).map((item) => `ABI: ${item}`);
  const collisionReport = JSON.parse(fs.readFileSync(path.join(rootDir, COLLISION_REPORT), "utf8"));
  if (JSON.stringify(collisionReport) !== JSON.stringify(buildCollisionReport(bundle))) problems.push(`ABI: deterministic collision report drift: ${COLLISION_REPORT}`);
  const frozen = JSON.parse(fs.readFileSync(path.join(rootDir, EVENT_LAYOUT_MANIFEST), "utf8"));
  problems.push(...compareEventLayouts(frozen, buildEventLayout(bundle)).map((item) => `EVENT: ${item}`));
  return problems;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.includes("--write-event-manifest") || process.argv.includes("--write-manifests")) {
    const bundle = readJson(ABI_EXPORT);
    for (const [relative, value] of [[EVENT_LAYOUT_MANIFEST, buildEventLayout(bundle)], [COLLISION_REPORT, buildCollisionReport(bundle)]]) {
      fs.writeFileSync(path.join(root, relative), `${JSON.stringify(value, null, 2)}\n`);
      console.log(`Wrote ${relative}`);
    }
  } else {
    const problems = checkCanonicalAbiGates();
    if (problems.length) {
      for (const problem of problems) console.error(problem);
      process.exitCode = 1;
    } else console.log("Canonical ABI selectors and indexed event layouts are collision-free and compatible.");
  }
}
