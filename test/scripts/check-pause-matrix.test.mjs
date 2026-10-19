#!/usr/bin/env node
/**
 * @file check-pause-matrix.test.mjs
 * @description Self-tests for the V2-SC-162 pause matrix checker with synthetic fixtures, plus a
 *              live-repository verification so the committed matrix can never drift from sources.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  sanitize,
  normalizeParams,
  extractOperations,
  parseMirror,
  parseSolidityVersion,
  validateMatrixShape,
  checkModule,
  checkMirror,
  checkVersioning,
  checkGuardAnchors,
  computeDigest,
  canonicalLines,
  runChecks
} from "../../scripts/check-pause-matrix.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "../..");

/** Synthetic registry-resolved module with one gated op, one exit, one view, and one internal. */
const FIXTURE_SOURCE = `
  contract Vault is V2PauseGuard {
    // function commented(uint256 a) external {}
    string internal constant NOTE = "function fake(uint256) external { }";

    function stake(uint256 claimId, IV2Types.LockCategory category, bytes calldata /* meta */) external nonReentrant {
      _requireScopeNotPaused(PauseMatrix.SCOPE_STAKING);
      if (claimId == 0) { revert(); }
    }

    function withdraw(address asset, uint256 amount) external nonReentrant {
      _requireExitsNotShutdown();
    }

    function balance(address a) external view returns (uint256) { return 0; }

    function _internalHelper(uint256 x) internal returns (uint256) { return x; }

    function _pauseAuthority() internal view override returns (bool, address) {
      return _registryPauseAuthority(address(0));
    }
  }
`;

function fixtureModule(overrides = {}) {
  return {
    name: "Vault",
    file: "contracts/v2/Vault.sol",
    authority: "registry",
    operations: [
      {
        signature: "stake(uint256,IV2Types.LockCategory,bytes)",
        class: "RISK_INCREASING",
        gates: ["SCOPE_STAKING"],
        rationale: "new exposure: stake locks principal"
      },
      {
        signature: "withdraw(address,uint256)",
        class: "RISK_REDUCING",
        gates: ["EXIT_SHUTDOWN_ONLY"],
        rationale: "pull of already-final caller-owned value"
      }
    ],
    ...overrides
  };
}

function fixtureMatrix(modules = [fixtureModule()], extra = {}) {
  const matrix = { schemaVersion: 1, matrixVersion: 1, modules, excluded: [], ...extra };
  if (!matrix.history) matrix.history = [{ version: 1, digest: computeDigest(matrix) }];
  return matrix;
}

describe("sanitize", () => {
  test("blanks comments and string contents while preserving length and lines", () => {
    const source = 'a // x {\n/* } */ b "{//}" c';
    const out = sanitize(source);
    assert.equal(out.length, source.length);
    assert.equal(out.split("\n").length, source.split("\n").length);
    assert.ok(!out.includes("{"), "braces inside comments and strings must be blanked");
    assert.ok(sanitize(source, { keepStrings: true }).includes('"{//}"'), "keepStrings preserves literals");
  });
});

describe("normalizeParams", () => {
  test("drops names and data locations, keeps qualified and array types", () => {
    assert.deepEqual(
      normalizeParams("bytes32 settlementId, address asset, FinalOutcome outcome, Allocation[] calldata allocations"),
      ["bytes32", "address", "FinalOutcome", "Allocation[]"]
    );
    assert.deepEqual(normalizeParams(""), []);
    assert.deepEqual(normalizeParams("bytes calldata  "), ["bytes"]);
  });
});

describe("extractOperations", () => {
  test("finds only external/public state-mutating functions with source-level signatures", () => {
    const ops = extractOperations(FIXTURE_SOURCE);
    assert.deepEqual(
      ops.map((op) => op.signature),
      ["stake(uint256,IV2Types.LockCategory,bytes)", "withdraw(address,uint256)"]
    );
    const [stake, withdraw] = ops;
    assert.deepEqual(stake.scopes, ["SCOPE_STAKING"]);
    assert.equal(stake.exitGate, false);
    assert.deepEqual(withdraw.scopes, []);
    assert.equal(withdraw.exitGate, true);
  });

  test("detects modifier-style gates and local pause modifiers", () => {
    const ops = extractOperations(`
      contract M {
        function a() external whenScopeNotPaused(PauseMatrix.SCOPE_CLAIMS) whenNotPaused returns (uint256 x) { x = 1; }
      }
    `);
    assert.equal(ops.length, 1);
    assert.deepEqual(ops[0].scopes, ["SCOPE_CLAIMS"]);
    assert.equal(ops[0].localPause, true);
  });
});

describe("checkModule", () => {
  test("accepts a module that matches its matrix entry", () => {
    assert.deepEqual(checkModule(fixtureModule(), FIXTURE_SOURCE), []);
  });

  test("reports an unclassified operation", () => {
    const module = fixtureModule({ operations: [fixtureModule().operations[0]] });
    const problems = checkModule(module, FIXTURE_SOURCE);
    assert.equal(problems.length, 1);
    assert.match(problems[0], /unclassified operation withdraw\(address,uint256\)/);
  });

  test("reports a stale matrix entry", () => {
    const module = fixtureModule();
    module.operations.push({
      signature: "removed(uint256)",
      class: "RISK_INCREASING",
      gates: ["SCOPE_STAKING"],
      rationale: "operation that no longer exists"
    });
    assert.ok(checkModule(module, FIXTURE_SOURCE).some((p) => /stale matrix entry removed\(uint256\)/.test(p)));
  });

  test("reports a risk-increasing operation without its fail-closed gate", () => {
    const source = FIXTURE_SOURCE.replace("_requireScopeNotPaused(PauseMatrix.SCOPE_STAKING);", "");
    const problems = checkModule(fixtureModule(), source);
    assert.ok(problems.some((p) => /missing its fail-closed gate PauseMatrix\.SCOPE_STAKING/.test(p)), problems.join("\n"));
  });

  test("reports a risk-increasing operation gated on the wrong scope", () => {
    const source = FIXTURE_SOURCE.replace("PauseMatrix.SCOPE_STAKING", "PauseMatrix.SCOPE_CLAIMS");
    const problems = checkModule(fixtureModule(), source);
    assert.ok(problems.some((p) => /missing its fail-closed gate/.test(p)));
    assert.ok(problems.some((p) => /unexpected gate PauseMatrix\.SCOPE_CLAIMS/.test(p)));
  });

  test("reports a risk-reducing exit guarded by a scoped pause", () => {
    const source = FIXTURE_SOURCE.replace(
      "_requireExitsNotShutdown();",
      "_requireExitsNotShutdown(); _requireScopeNotPaused(PauseMatrix.SCOPE_SETTLEMENT);"
    );
    const problems = checkModule(fixtureModule(), source);
    assert.ok(problems.some((p) => /RISK_REDUCING exit is guarded by scope pause PauseMatrix\.SCOPE_SETTLEMENT/.test(p)));
  });

  test("reports a risk-reducing exit guarded by a local whenNotPaused modifier", () => {
    const source = FIXTURE_SOURCE.replace(
      "function withdraw(address asset, uint256 amount) external nonReentrant",
      "function withdraw(address asset, uint256 amount) external whenNotPaused nonReentrant"
    );
    const problems = checkModule(fixtureModule(), source);
    assert.ok(problems.some((p) => /RISK_REDUCING exit is guarded by a local whenNotPaused modifier/.test(p)));
  });

  test("reports a value exit that lost its shutdown-only gate", () => {
    const source = FIXTURE_SOURCE.replace("_requireExitsNotShutdown();", "");
    assert.ok(checkModule(fixtureModule(), source).some((p) => /missing _requireExitsNotShutdown/.test(p)));
  });

  test("rejects a non-literal scope gate", () => {
    const source = FIXTURE_SOURCE.replace("_requireScopeNotPaused(PauseMatrix.SCOPE_STAKING);", "_requireScopeNotPaused(someScope);");
    assert.ok(checkModule(fixtureModule(), source).some((p) => /must name a PauseMatrix\.SCOPE_\* constant/.test(p)));
  });

  test("resolves gatedVia through an internal call to a gated public operation", () => {
    const source = `
      contract E is V2WiredPauseGuard {
        function submit(uint256 id) external returns (uint256) { return commit(id); }
        function commit(uint256 id) public whenNotPaused returns (uint256) {
          _requireScopeNotPaused(PauseMatrix.SCOPE_EVIDENCE);
          return id;
        }
        function setPauseAuthority(address a) external { _wirePauseAuthority(a); }
      }
    `;
    const module = {
      name: "E",
      file: "contracts/v2/E.sol",
      authority: "wired",
      operations: [
        { signature: "submit(uint256)", class: "RISK_INCREASING", gates: ["SCOPE_EVIDENCE"], gatedVia: "commit(uint256)", localPause: true, rationale: "adds evidence via the gated commit path" },
        { signature: "commit(uint256)", class: "RISK_INCREASING", gates: ["SCOPE_EVIDENCE"], localPause: true, rationale: "adds evidence to a claim under nested pause" },
        { signature: "setPauseAuthority(address)", class: "NEUTRAL", gates: [], rationale: "write-once authority wiring" }
      ]
    };
    assert.deepEqual(checkModule(module, source), []);
    const broken = source.replace("return commit(id);", "return id;");
    assert.ok(checkModule(module, broken).some((p) => /gatedVia target commit\(uint256\) is never called/.test(p)));
  });

  test("requires wired modules to expose a NEUTRAL setPauseAuthority", () => {
    const module = fixtureModule({ authority: "wired" });
    const problems = checkModule(module, FIXTURE_SOURCE);
    assert.ok(problems.some((p) => /must inherit V2WiredPauseGuard/.test(p)));
    assert.ok(problems.some((p) => /must expose setPauseAuthority\(address\) classified NEUTRAL/.test(p)));
  });
});

describe("validateMatrixShape", () => {
  test("rejects a risk-increasing entry with no scope and a risk-reducing entry with a scope", () => {
    const module = fixtureModule();
    module.operations[0].gates = [];
    module.operations[1].gates = ["SCOPE_SETTLEMENT"];
    const problems = validateMatrixShape(fixtureMatrix([module]));
    assert.ok(problems.some((p) => /must fail closed on at least one scope/.test(p)));
    assert.ok(problems.some((p) => /must not be unconditionally scope-gated/.test(p)));
  });

  test("rejects unknown classes, unknown gates, and missing rationales", () => {
    const module = fixtureModule();
    module.operations[0].class = "SOMETIMES";
    module.operations[1].gates = ["SCOPE_UNKNOWN"];
    module.operations[1].rationale = "";
    const problems = validateMatrixShape(fixtureMatrix([module]));
    assert.ok(problems.some((p) => /unknown class SOMETIMES/.test(p)));
    assert.ok(problems.some((p) => /unknown gate SCOPE_UNKNOWN/.test(p)));
    assert.ok(problems.some((p) => /needs a meaningful rationale/.test(p)));
  });
});

describe("mirror and versioning", () => {
  const MIRROR = `
    library PauseMatrix {
      uint16 internal constant PAUSE_MATRIX_VERSION = 1;
      function classify(string memory m, string memory s) internal pure returns (RiskClass, bytes32, bytes32) {
        bytes32 k = _key(m, s);
        if (k == _key("Vault", "stake(uint256,IV2Types.LockCategory,bytes)")) return (RiskClass.RISK_INCREASING, SCOPE_STAKING, NO_GATE);
        if (k == _key("Vault", "withdraw(address,uint256)")) return (RiskClass.RISK_REDUCING, EXIT_SHUTDOWN_ONLY, NO_GATE);
        revert UnclassifiedOperation(m, s);
      }
    }
  `;

  test("parses the mirror and its version", () => {
    const mirror = parseMirror(MIRROR);
    assert.equal(mirror.size, 2);
    assert.deepEqual(mirror.get("Vault|withdraw(address,uint256)"), { class: "RISK_REDUCING", gates: ["EXIT_SHUTDOWN_ONLY"] });
    assert.equal(parseSolidityVersion(MIRROR), 1);
  });

  test("accepts a mirror that matches the JSON matrix", () => {
    assert.deepEqual(checkMirror(fixtureMatrix(), parseMirror(MIRROR)), []);
  });

  test("reports mirror class and gate drift in both directions", () => {
    const drifted = MIRROR.replace("RiskClass.RISK_REDUCING, EXIT_SHUTDOWN_ONLY", "RiskClass.NEUTRAL, NO_GATE").replace(
      'revert UnclassifiedOperation',
      'if (k == _key("Vault", "extra()")) return (RiskClass.NEUTRAL, NO_GATE, NO_GATE);\n revert UnclassifiedOperation'
    );
    const problems = checkMirror(fixtureMatrix(), parseMirror(drifted));
    assert.ok(problems.some((p) => /class NEUTRAL != matrix RISK_REDUCING/.test(p)));
    assert.ok(problems.some((p) => /gates \[\] != matrix \[EXIT_SHUTDOWN_ONLY\]/.test(p)));
    assert.ok(problems.some((p) => /Vault\|extra\(\) is not in the JSON matrix/.test(p)));
  });

  test("reports a Solidity / JSON version mismatch", () => {
    assert.ok(checkVersioning(fixtureMatrix(), 2).some((p) => /version mismatch/.test(p)));
  });

  test("reports a classification change without a version bump", () => {
    const matrix = fixtureMatrix();
    matrix.modules[0].operations[1].class = "NEUTRAL";
    matrix.modules[0].operations[1].gates = [];
    assert.ok(checkVersioning(matrix, 1).some((p) => /classification changed without a version bump/.test(p)));
  });

  test("accepts a bumped version with a fresh history entry", () => {
    const matrix = fixtureMatrix();
    const original = matrix.history[0];
    matrix.modules[0].operations[1].gates = [];
    matrix.matrixVersion = 2;
    matrix.history = [original, { version: 2, digest: computeDigest(matrix) }];
    assert.deepEqual(checkVersioning(matrix, 2), []);
  });

  test("canonical lines are order-independent", () => {
    const a = fixtureMatrix();
    const b = fixtureMatrix([fixtureModule({ operations: [...fixtureModule().operations].reverse() })]);
    assert.deepEqual(canonicalLines(a), canonicalLines(b));
    assert.equal(computeDigest(a), computeDigest(b));
  });
});

describe("guard anchors", () => {
  test("reports a guard that no longer fails closed on an unresolved authority", () => {
    const guard = `
      function isScopePaused(bytes32 s) public view returns (bool) { (bool resolved, address a) = _pauseAuthority(); if (!resolved) return false; }
    `;
    assert.ok(checkGuardAnchors(guard).some((p) => /fail closed when the authority cannot be resolved/.test(p)));
  });
});

describe("live repository (V2-SC-162)", () => {
  test("pause matrix, module sources, mirror, and version history agree", async () => {
    assert.deepEqual(await runChecks(REPO_ROOT), []);
  });
});
