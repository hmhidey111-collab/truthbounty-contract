#!/usr/bin/env node
/**
 * PREWAVE-SC-065 (#741) — Persist and replay invariant/fuzz failure seeds.
 *
 * Commands:
 *   validate <path>     Validate seed JSON (schema + no-secrets)
 *   redact <path>       Strip secret-like fields; write *.redacted.json
 *   replay-cmd <path>   Print deterministic forge replay command
 *   minimize-meta <path> Mark minimized=true and write sibling artifact
 *   bind-env <path>     Fill commit/toolchain from env if missing (CI)
 *
 * Env (CI, optional): GITHUB_SHA, FORGE_VERSION, SOLC_VERSION
 * Never reads or writes private keys, RPC secrets, or .env contents.
 */

import fs from "node:fs";
import path from "node:path";

const SCHEMA_VERSION = 1;
const SECRET_KEY_RE =
  /^(.*_)?(private[_-]?key|secret|mnemonic|api[_-]?key|token|password|passwd|auth)$/i;
const SECRET_VALUE_RE =
  /\b(0x[a-fA-F0-9]{64}|[a-zA-Z0-9+\/=]{80,}|sk_live_|ghp_|github_pat_)\b/;

function die(msg, code = 1) {
  console.error(`[invariant-seed] ${msg}`);
  process.exit(code);
}

function readJson(file) {
  if (!fs.existsSync(file)) die(`missing file: ${file}`);
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    die(`corrupt JSON: ${file}`);
  }
}

function writeJson(file, obj) {
  fs.writeFileSync(file, JSON.stringify(obj, null, 2) + "\n", "utf8");
}

function assertNoSecrets(value, trail = "$") {
  if (value === null || value === undefined) return;
  if (typeof value === "string") {
    if (SECRET_VALUE_RE.test(value)) {
      die(`secret-like value at ${trail}`);
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((v, i) => assertNoSecrets(v, `\( {trail}[ \){i}]`));
    return;
  }
  if (typeof value === "object") {
    for (const [k, v] of Object.entries(value)) {
      if (SECRET_KEY_RE.test(k)) die(`secret-like key at \( {trail}. \){k}`);
      assertNoSecrets(v, `\( {trail}. \){k}`);
    }
  }
}

function validateSeed(obj) {
  if (obj.schemaVersion !== SCHEMA_VERSION) {
    die(`schemaVersion must be ${SCHEMA_VERSION}`);
  }
  if (obj.kind !== "invariant" && obj.kind !== "fuzz") {
    die(`kind must be invariant|fuzz`);
  }
  if (typeof obj.test !== "string" || !obj.test.includes(":")) {
    die(`test must be Contract:testName`);
  }
  if (typeof obj.commit !== "string" || !/^[0-9a-f]{7,40}$/.test(obj.commit)) {
    die(`commit must be a git sha`);
  }
  if (!obj.toolchain || typeof obj.toolchain.forge !== "string" || typeof obj.toolchain.solc !== "string") {
    die(`toolchain.forge and toolchain.solc required`);
  }
  if (typeof obj.seed !== "string" || !/^[0-9]+$/.test(obj.seed)) {
    die(`seed must be a decimal string`);
  }
  if (typeof obj.createdAt !== "string" || Number.isNaN(Date.parse(obj.createdAt))) {
    die(`createdAt must be ISO date-time`);
  }
  assertNoSecrets(obj);
  return true;
}

function redact(obj) {
  const out = structuredClone(obj);
  function walk(node) {
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node)) {
      node.forEach(walk);
      return;
    }
    for (const k of Object.keys(node)) {
      if (SECRET_KEY_RE.test(k)) {
        delete node[k];
        continue;
      }
      if (typeof node[k] === "string" && SECRET_VALUE_RE.test(node[k])) {
        node[k] = "[REDACTED]";
        continue;
      }
      walk(node[k]);
    }
  }
  walk(out);
  return out;
}

function replayCmd(obj) {
  validateSeed(obj);
  const [contract, testName] = obj.test.split(":");
  // Deterministic local replay: pin seed + match exact test id.
  return [
    `forge test --match-contract ${JSON.stringify(contract)} --match-test ${JSON.stringify(testName)} --fuzz-seed ${obj.seed} -vvv`,
  ].join(" ");
}

function bindEnv(obj) {
  const next = { ...obj };
  if (!next.commit && process.env.GITHUB_SHA) {
    next.commit = process.env.GITHUB_SHA.slice(0, 40).toLowerCase();
  }
  next.toolchain = {
    forge: process.env.FORGE_VERSION || next.toolchain?.forge || "unknown",
    solc: process.env.SOLC_VERSION || next.toolchain?.solc || "0.8.28",
    runnerOs: process.env.RUNNER_OS || next.toolchain?.runnerOs || process.platform,
  };
  if (!next.createdAt) next.createdAt = new Date().toISOString();
  if (next.schemaVersion == null) next.schemaVersion = SCHEMA_VERSION;
  return next;
}

function main() {
  const [cmd, file] = process.argv.slice(2);
  if (!cmd || !file) {
    die(
      "usage: invariant-seed-tools.mjs <validate|redact|replay-cmd|minimize-meta|bind-env> <path>",
    );
  }
  const abs = path.resolve(file);

  if (cmd === "validate") {
    validateSeed(readJson(abs));
    console.log("ok");
    return;
  }
  if (cmd === "redact") {
    const red = redact(readJson(abs));
    const out = abs.replace(/\.json$/i, "") + ".redacted.json";
    writeJson(out, red);
    validateSeed(red);
    console.log(out);
    return;
  }
  if (cmd === "replay-cmd") {
    console.log(replayCmd(readJson(abs)));
    return;
  }
  if (cmd === "minimize-meta") {
    const obj = readJson(abs);
    obj.minimized = true;
    const out = abs.replace(/\.json$/i, "") + ".minimized.json";
    writeJson(out, obj);
    validateSeed(obj);
    console.log(out);
    return;
  }
  if (cmd === "bind-env") {
    const bound = bindEnv(readJson(abs));
    writeJson(abs, bound);
    validateSeed(bound);
    console.log("bound");
    return;
  }
  die(`unknown command: ${cmd}`);
}

main();
