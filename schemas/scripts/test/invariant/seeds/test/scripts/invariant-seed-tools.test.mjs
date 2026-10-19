import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const tool = path.join(root, "scripts/invariant-seed-tools.mjs");
const fixture = path.join(root, "test/invariant/seeds/known-counterexample.json");

function run(args, extraEnv = {}) {
  return spawnSync(process.execPath, [tool, ...args], {
    encoding: "utf8",
    env: { ...process.env, ...extraEnv },
  });
}

function tmpJson(obj) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "inv-seed-"));
  const file = path.join(dir, "seed.json");
  fs.writeFileSync(file, JSON.stringify(obj, null, 2));
  return file;
}

test("known counterexample validates", () => {
  const r = run(["validate", fixture]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /ok/);
});

test("corrupt seed fails validation", () => {
  const file = tmpJson({ schemaVersion: 1, kind: "invariant" });
  const r = run(["validate", file]);
  assert.notEqual(r.status, 0);
});

test("toolchain change is visible in bound metadata", () => {
  const base = JSON.parse(fs.readFileSync(fixture, "utf8"));
  delete base.toolchain;
  const file = tmpJson(base);
  const r = run(["bind-env", file], {
    FORGE_VERSION: "9.9.9-test",
    SOLC_VERSION: "0.8.28",
    GITHUB_SHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  });
  assert.equal(r.status, 0, r.stderr);
  const bound = JSON.parse(fs.readFileSync(file, "utf8"));
  assert.equal(bound.toolchain.forge, "9.9.9-test");
  assert.equal(bound.commit, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
});

test("minimized replay metadata", () => {
  const base = JSON.parse(fs.readFileSync(fixture, "utf8"));
  base.minimized = false;
  const file = tmpJson(base);
  const r = run(["minimize-meta", file]);
  assert.equal(r.status, 0, r.stderr);
  const out = r.stdout.trim();
  const min = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.equal(min.minimized, true);
});

test("fixed seed remains regression — replay-cmd is deterministic", () => {
  const r1 = run(["replay-cmd", fixture]);
  const r2 = run(["replay-cmd", fixture]);
  assert.equal(r1.status, 0, r1.stderr);
  assert.equal(r1.stdout, r2.stdout);
  assert.match(r1.stdout, /--fuzz-seed 119/);
  assert.match(r1.stdout, /ExampleInvariant/);
});

test("artifact upload payload has no secrets", () => {
  const dirty = JSON.parse(fs.readFileSync(fixture, "utf8"));
  dirty.counterexample = {
    privateKey: "0x" + "11".repeat(32),
    call: "ok",
  };
  const file = tmpJson(dirty);
  const bad = run(["validate", file]);
  assert.notEqual(bad.status, 0);

  const red = run(["redact", file]);
  assert.equal(red.status, 0, red.stderr);
  const outPath = red.stdout.trim();
  const cleaned = JSON.parse(fs.readFileSync(outPath, "utf8"));
  assert.equal(cleaned.counterexample.privateKey, undefined);
  const ok = run(["validate", outPath]);
  assert.equal(ok.status, 0, ok.stderr);
});
