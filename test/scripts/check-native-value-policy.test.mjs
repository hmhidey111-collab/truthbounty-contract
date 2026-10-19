#!/usr/bin/env node
/**
 * @file check-native-value-policy.test.mjs
 * @description Self-tests for the V2-SC-153 native-value policy checker, plus a live-repository
 *              verification so the declared inventory can never drift from the sources.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  detectInventory,
  detectSurfaces,
  diffInventory,
  readInventory,
  checkPolicyAnchors,
  stripComments
} from "../../scripts/check-native-value-policy.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "../..");

describe("stripComments", () => {
  test("blanks block and line comments while preserving offsets", () => {
    const source = "uint256 a; // payable\n/* msg.value */\nuint256 b;";
    const stripped = stripComments(source);
    assert.equal(stripped.split("\n").length, source.split("\n").length);
    assert.ok(!/payable/.test(stripped), "line-comment text must be blanked");
    assert.ok(!/msg\.value/.test(stripped), "block-comment text must be blanked");
  });
});

describe("detectSurfaces", () => {
  test("detects the canonical governor rejection surface", () => {
    const surfaces = detectSurfaces(`
      contract Governor {
        error UnexpectedNativeValue(uint256 value);

        receive() external payable {
          revert UnexpectedNativeValue(msg.value);
        }
      }
    `);
    assert.deepEqual(surfaces, ["receive", "payable", "msg.value"]);
  });

  test("ignores native-value words that only appear in documentation", () => {
    assert.deepEqual(detectSurfaces("/// @notice Rejected claims MUST NOT become payable.\ncontract C {}"), []);
  });

  test("detects forced-native-value and native-balance reads", () => {
    assert.deepEqual(
      detectSurfaces("contract A { function f(address payable t) external { selfdestruct(t); } }"),
      ["payable", "selfdestruct"]
    );
    assert.deepEqual(detectSurfaces("contract B { function f() external view returns (uint256) { return address(this).balance; } }"), [
      "nativeBalance"
    ]);
  });
});

describe("diffInventory", () => {
  test("reports an undeclared surface", () => {
    const detected = new Map([["contracts/New.sol", ["payable"]]]);
    const declared = new Map();
    const problems = diffInventory(detected, declared);
    assert.equal(problems.length, 1);
    assert.match(problems[0], /undeclared native-value surface/);
  });

  test("reports a partially declared surface set", () => {
    const detected = new Map([["contracts/New.sol", ["payable", "msg.value"]]]);
    const declared = new Map([["contracts/New.sol", { surfaces: ["payable"], rationale: "documented governance rejection path" }]]);
    const problems = diffInventory(detected, declared);
    assert.equal(problems.length, 1);
    assert.match(problems[0], /do not cover \[msg\.value\]/);
  });

  test("reports a stale inventory entry", () => {
    const detected = new Map();
    const declared = new Map([["contracts/Old.sol", { surfaces: ["payable"], rationale: "documented governance rejection path" }]]);
    const problems = diffInventory(detected, declared);
    assert.equal(problems.length, 1);
    assert.match(problems[0], /stale/);
  });

  test("accepts an exactly matching inventory", () => {
    const detected = new Map([["contracts/New.sol", ["payable", "msg.value"]]]);
    const declared = new Map([
      ["contracts/New.sol", { surfaces: ["msg.value", "payable"], rationale: "documented governance rejection path" }]
    ]);
    assert.deepEqual(diffInventory(detected, declared), []);
  });
});

describe("live repository (V2-SC-153)", () => {
  test("declared inventory matches the contract sources exactly", async () => {
    const detected = await detectInventory(REPO_ROOT);
    const declared = await readInventory();
    assert.deepEqual(diffInventory(detected, declared), []);
    assert.equal(detected.size, declared.size);
    assert.ok(detected.size > 0, "the inventory must track the canonical rejection surfaces");
  });

  test("all documented rejection anchors are implemented", async () => {
    assert.deepEqual(await checkPolicyAnchors(REPO_ROOT), []);
  });
});
