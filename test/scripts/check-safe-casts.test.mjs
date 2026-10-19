#!/usr/bin/env node
/**
 * @file check-safe-casts.test.mjs
 * @description Self-tests for the V2-SC-161 safe-cast inventory checker, using synthetic Solidity
 *              fixtures, plus a live-repository verification so the committed inventory can never
 *              drift from the canonical V2 sources.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  detectCasts,
  detectInventory,
  diffInventory,
  inventoryFromEntries,
  readInventory,
  checkGuardAnchors,
  stripCommentsAndStrings,
  normalizeExpression,
  fingerprint
} from "../../scripts/check-safe-casts.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "../..");

const entry = (overrides) => ({
  file: "contracts/v2/Fixture.sol",
  expression: "uint8(raw)",
  width: 8,
  classification: "proven-safe",
  unit: "asset decimals",
  bound: "raw <= 36 checked on the preceding line",
  justification: "decimals are bounded before the narrowing conversion",
  ...overrides
});

async function withFixture(files, fn) {
  const root = await mkdtemp(join(tmpdir(), "safe-cast-"));
  try {
    for (const [path, content] of Object.entries(files)) {
      await mkdir(dirname(join(root, path)), { recursive: true });
      await writeFile(join(root, path), content);
    }
    return await fn(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

describe("stripCommentsAndStrings", () => {
  test("blanks comments and string contents while preserving offsets and lines", () => {
    const source = 'uint64 a; // uint64(x)\n/* uint8(y) */\nstring s = "uint16(z)";\n';
    const stripped = stripCommentsAndStrings(source);
    assert.equal(stripped.length, source.length);
    assert.equal(stripped.split("\n").length, source.split("\n").length);
    assert.deepEqual(detectCasts(source), []);
  });
});

describe("detectCasts", () => {
  test("detects narrowing casts with balanced operands and width", () => {
    const casts = detectCasts("function f() { uint64 t = uint64(block.timestamp); x = uint8( foo(a, (b)) ); }");
    assert.deepEqual(
      casts.map(({ expression, width, kind }) => ({ expression, width, kind })),
      [
        { expression: "uint64(block.timestamp)", width: 64, kind: "narrowing" },
        { expression: "uint8(foo(a, (b)))", width: 8, kind: "narrowing" }
      ]
    );
  });

  test("detects every narrow width from uint8 to uint248", () => {
    for (let w = 8; w < 256; w += 8) {
      const [cast] = detectCasts(`x = uint${w}(v);`);
      assert.equal(cast?.width, w, `uint${w} must be detected`);
    }
  });

  test("ignores widening, type() bounds, declarations, and uint256", () => {
    const source = `
      uint64 public changedAt;
      mapping(address => uint64) private start;
      function f(uint64 a) external pure returns (uint64) {
        uint256 w = uint256(a);
        if (w > type(uint64).max) revert();
        return a;
      }`;
    assert.deepEqual(detectCasts(source), []);
  });

  test("flags signed conversions, including negative-to-unsigned tooling fixtures", () => {
    const casts = detectCasts("int256 d = int256(amount); int8 s = int8(d); uint256 u = uint256(int256(-1));");
    assert.deepEqual(
      casts.map(({ expression, kind, width }) => ({ expression, kind, width })),
      [
        { expression: "int256(amount)", kind: "signed", width: 256 },
        { expression: "int8(d)", kind: "signed", width: 8 },
        { expression: "int256(-1)", kind: "signed", width: 256 }
      ]
    );
  });

  test("normalizes whitespace so formatting changes keep the fingerprint", () => {
    assert.equal(normalizeExpression("uint64(\n   block.timestamp\n )"), "uint64(block.timestamp)");
    assert.equal(fingerprint("a.sol", "uint8(  x )"), fingerprint("a.sol", "uint8(x)"));
  });
});

describe("diffInventory", () => {
  const site = (expression, lines = [10], width = 8, operand = "raw") => [
    fingerprint("contracts/v2/Fixture.sol", expression),
    { file: "contracts/v2/Fixture.sol", expression, operand, width, kind: "narrowing", lines }
  ];

  test("reports a new unlisted narrowing cast", () => {
    const problems = diffInventory(new Map([site("uint8(raw)")]), new Map());
    assert.equal(problems.length, 1);
    assert.match(problems[0], /undeclared narrowing cast `uint8\(raw\)` \(uint8\)/);
  });

  test("forbids raw narrowing of block.timestamp and block.chainid even when declared", () => {
    const ts = site("uint64(block.timestamp)", [5], 64, "block.timestamp");
    const chain = site("uint64(block.chainid)", [6], 64, "block.chainid");
    const declared = inventoryFromEntries([
      entry({ expression: "uint64(block.timestamp)", width: 64 }),
      entry({ expression: "uint64(block.chainid)", width: 64 })
    ]);
    const problems = diffInventory(new Map([ts, chain]), declared);
    assert.equal(problems.filter((p) => /is forbidden — use V2SafeCast/.test(p)).length, 2);
  });

  test("reports occurrence drift when a proven-safe expression is copied to a new line", () => {
    const problems = diffInventory(new Map([site("uint8(raw)", [10, 42])]), inventoryFromEntries([entry()]));
    assert.equal(problems.length, 1);
    assert.match(problems[0], /occurs 2 time\(s\) but the inventory declares 1/);
  });

  test("reports width mismatch, bad classification, and missing proof", () => {
    const declared = inventoryFromEntries([
      entry({ width: 16, classification: "trusted", bound: "", justification: "short" })
    ]);
    const problems = diffInventory(new Map([site("uint8(raw)")]), declared);
    assert.ok(problems.some((p) => /width 8 but the inventory declares 16/.test(p)));
    assert.ok(problems.some((p) => /invalid classification "trusted"/.test(p)));
    assert.ok(problems.some((p) => /needs an explicit bound/.test(p)));
    assert.ok(problems.some((p) => /needs a meaningful justification/.test(p)));
  });

  test("only V2SafeCast conversions may be classified guarded", () => {
    const problems = diffInventory(new Map([site("uint8(raw)")]), inventoryFromEntries([entry({ classification: "guarded" })]));
    assert.equal(problems.length, 1);
    assert.match(problems[0], /only the bounded conversions inside V2SafeCast/);
  });

  test("reports a stale inventory entry", () => {
    const problems = diffInventory(new Map(), inventoryFromEntries([entry()]));
    assert.equal(problems.length, 1);
    assert.match(problems[0], /stale/);
  });

  test("accepts an exactly matching inventory", () => {
    const declared = inventoryFromEntries([entry({ occurrences: 2 })]);
    assert.deepEqual(diffInventory(new Map([site("uint8(raw)", [3, 9])]), declared), []);
  });
});

describe("detectInventory (synthetic tree)", () => {
  test("scans only the configured scope and groups identical expressions per file", async () => {
    await withFixture(
      {
        "contracts/v2/A.sol": "contract A { function f(uint256 r) external pure { uint8(r); uint8(r); uint16(r); } }",
        "contracts/legacy/B.sol": "contract B { function f() external view returns (uint64) { return uint64(block.timestamp); } }"
      },
      async (root) => {
        const detected = await detectInventory(root, ["contracts/v2"]);
        assert.equal(detected.size, 2);
        assert.deepEqual(detected.get(fingerprint("contracts/v2/A.sol", "uint8(r)")).lines, [1, 1]);
        assert.ok(![...detected.keys()].some((k) => k.startsWith("contracts/legacy/")));
      }
    );
  });

  test("an unguarded timestamp narrowing added to canonical V2 fails the gate", async () => {
    await withFixture(
      { "contracts/v2/New.sol": "contract N { uint64 t; function f() external { t = uint64(block.timestamp); } }" },
      async (root) => {
        const problems = diffInventory(await detectInventory(root, ["contracts/v2"]), new Map());
        assert.equal(problems.length, 1);
        assert.match(problems[0], /contracts\/v2\/New\.sol:1: raw narrowing `uint64\(block\.timestamp\)` is forbidden/);
      }
    );
  });
});

describe("live repository (V2-SC-161)", () => {
  test("declared inventory matches the canonical V2 sources exactly", async () => {
    const detected = await detectInventory(REPO_ROOT);
    const declared = await readInventory();
    assert.deepEqual(diffInventory(detected, declared), []);
    assert.equal(detected.size, declared.size);
  });

  test("every guarded field and bounded conversion anchor is implemented", async () => {
    assert.deepEqual(await checkGuardAnchors(REPO_ROOT), []);
  });

  test("the inventory contains no raw clock or chain-id narrowing", async () => {
    const declared = await readInventory();
    for (const e of declared.values()) {
      assert.ok(!/block\.(timestamp|chainid|number)/.test(e.expression), `${e.file}: ${e.expression}`);
    }
  });
});
