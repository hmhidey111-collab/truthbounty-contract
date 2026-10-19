/**
 * @file static-analysis-gate.test.mjs
 * @description Unit tests for the zero-new-finding static analysis baseline gate.
 *
 * Covers the four properties the gate must never violate:
 *   1. A clean analyzer run with a matching baseline passes.
 *   2. A finding that is absent from the baseline fails (zero-new-finding).
 *   3. A baseline entry only suppresses a finding when its disposition is
 *      suppressible and its justification is documented; anything else fails closed.
 *   4. Malformed configuration, a malformed report, or a toolchain that does not
 *      match the pin all fail closed instead of reporting success.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  GateError,
  checkToolchainPin,
  describeFinding,
  diffAgainstBaseline,
  fingerprintFinding,
  formatResult,
  loadBaseline,
  loadConfig,
  normalizeReport
} from "../../scripts/static-analysis-gate.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "../..");

const JUSTIFICATION =
  "Guardian-less admin path is intentional: the module is immutable behind ERC1967 and " +
  "the only caller is the TimelockController, so the finding does not describe a reachable attack.";

/**
 * @param {Partial<any>} [overrides]
 * @returns {any}
 */
function finding(overrides = {}) {
  return {
    check: "reentrancy-eth",
    impact: "High",
    confidence: "Medium",
    description: "Reentrancy in StakeVault.withdraw",
    elements: [
      {
        type: "function",
        name: "withdraw",
        source_mapping: { filename_relative: "contracts/v2/StakeVault.sol", start: 0, length: 10 }
      }
    ],
    ...overrides
  };
}

describe("static analysis fingerprinting", () => {
  it("produces a stable fingerprint that ignores line and column movement", () => {
    const a = fingerprintFinding(finding());
    const b = fingerprintFinding(
      finding({
        elements: [
          {
            type: "function",
            name: "withdraw",
            source_mapping: { filename_relative: "contracts/v2/StakeVault.sol", start: 900, length: 40 }
          }
        ]
      })
    );
    assert.equal(a, b);
  });

  it("changes the fingerprint when a new call site appears", () => {
    const a = fingerprintFinding(finding());
    const b = fingerprintFinding(
      finding({
        elements: [
          {
            type: "function",
            name: "deposit",
            source_mapping: { filename_relative: "contracts/v2/StakeVault.sol", start: 0, length: 10 }
          }
        ]
      })
    );
    assert.notEqual(a, b);
  });

  it("changes the fingerprint when the detector, impact, or source file changes", () => {
    const base = fingerprintFinding(finding());
    assert.notEqual(base, fingerprintFinding(finding({ check: "uninitialized-storage" })));
    assert.notEqual(base, fingerprintFinding(finding({ impact: "Low" })));
    assert.notEqual(base, fingerprintFinding(finding({ confidence: "High" })));
    assert.notEqual(
      base,
      fingerprintFinding(
        finding({
          elements: [
            {
              type: "function",
              name: "withdraw",
              source_mapping: { filename_relative: "contracts/v2/EvidenceRegistry.sol" }
            }
          ]
        })
      )
    );
  });

  it("resolves a contract name for a function finding that names no contract element", () => {
    const described = describeFinding(finding());
    assert.equal(described.detector, "reentrancy-eth");
    assert.equal(described.impact, "High");
    assert.equal(described.sourceFile, "contracts/v2/StakeVault.sol");
    assert.equal(described.element, "function withdraw");
  });

  it("prefers an explicit contract element over the first element name", () => {
    const described = describeFinding(
      finding({
        elements: [
          { type: "function", name: "withdraw", source_mapping: { filename_relative: "contracts/v2/StakeVault.sol" } },
          { type: "contract", name: "StakeVault", source_mapping: { filename_relative: "contracts/v2/StakeVault.sol" } }
        ]
      })
    );
    assert.equal(described.contract, "StakeVault");
  });

  it("tolerates a detector with no elements array", () => {
    const described = describeFinding({ check: "x", impact: "Low", confidence: "Low" });
    assert.equal(described.element, "unknown unknown");
    assert.equal(described.sourceFile, "unknown");
  });
});

describe("static analysis report normalization", () => {
  it("normalizes a well-formed Slither report", () => {
    const findings = normalizeReport({ success: true, results: { detectors: [finding()] } });
    assert.equal(findings.length, 1);
    assert.equal(findings[0].detector, "reentrancy-eth");
  });

  it("fails closed on a report with no results object", () => {
    assert.throws(() => normalizeReport({ success: true }), GateError);
  });

  it("fails closed on a report whose detectors field is not an array", () => {
    assert.throws(() => normalizeReport({ results: { detectors: {} } }), GateError);
  });

  it("fails closed on a non-object report", () => {
    assert.throws(() => normalizeReport("not json"), GateError);
  });
});

describe("baseline diffing", () => {
  it("passes when every reported finding is already triaged", () => {
    const observed = normalizeReport({ results: { detectors: [finding()] } });
    const entries = [
      {
        fingerprint: observed[0].fingerprint,
        disposition: "false-positive",
        justification: JUSTIFICATION
      }
    ];
    const diff = diffAgainstBaseline(observed, entries, ["false-positive", "accepted-risk"]);
    assert.deepEqual(diff.newFindings, []);
    assert.deepEqual(diff.resolvedFingerprints, []);
  });

  it("fails on a finding that is absent from the baseline", () => {
    const observed = normalizeReport({ results: { detectors: [finding()] } });
    const diff = diffAgainstBaseline(observed, [], ["false-positive", "accepted-risk"]);
    assert.equal(diff.newFindings.length, 1);
    assert.equal(diff.newFindings[0].fingerprint, observed[0].fingerprint);
  });

  it("fails when a single run reports a second, untriaged call site", () => {
    const observed = normalizeReport({ results: { detectors: [finding()] } });
    const second = finding({
      elements: [
        {
          type: "function",
          name: "deposit",
          source_mapping: { filename_relative: "contracts/v2/StakeVault.sol" }
        }
      ]
    });
    const both = normalizeReport({ results: { detectors: [finding(), second] } });
    const diff = diffAgainstBaseline(both, [], ["false-positive", "accepted-risk"]);
    assert.equal(diff.newFindings.length, 2);
  });

  it("reports a baseline entry that the analyzer no longer observes as stale", () => {
    const observed = normalizeReport({ results: { detectors: [] } });
    const entries = [{ fingerprint: "deadbeefdeadbeef", disposition: "accepted-risk", justification: JUSTIFICATION }];
    const diff = diffAgainstBaseline(observed, entries, ["false-positive", "accepted-risk"]);
    assert.deepEqual(diff.newFindings, []);
    assert.deepEqual(diff.resolvedFingerprints, ["deadbeefdeadbeef"]);
  });

  it("refuses to suppress a finding whose disposition is not suppressible", () => {
    const observed = normalizeReport({ results: { detectors: [finding()] } });
    const entries = [
      { fingerprint: observed[0].fingerprint, disposition: "ignore", justification: JUSTIFICATION }
    ];
    assert.throws(
      () => diffAgainstBaseline(observed, entries, ["false-positive", "accepted-risk"]),
      GateError
    );
  });
});

describe("toolchain pinning", () => {
  it("accepts a version that matches the pin", () => {
    assert.equal(checkToolchainPin("Slither 0.11.6", "0.11.6"), null);
  });

  it("rejects a version that does not match the pin", () => {
    const mismatch = checkToolchainPin("Slither 0.10.3", "0.11.6");
    assert.ok(mismatch);
    assert.match(mismatch, /0\.10\.3/);
    assert.match(mismatch, /0\.11\.6/);
  });

  it("rejects unparsable version output", () => {
    assert.match(checkToolchainPin("", "0.11.6"), /could not parse/);
  });
});

describe("baseline and config validation (fail closed)", () => {
  /**
   * @param {any} [overrides]
   * @returns {{ root: string, configPath: string, baselinePath: string }}
   */
  function scaffold(overrides = {}) {
    const root = mkdtempSync(join(tmpdir(), "sa-gate-"));
    const baseline = {
      schemaVersion: 1,
      entries: [
        {
          fingerprint: "0123456789abcdef",
          detector: "reentrancy-eth",
          disposition: "false-positive",
          justification: JUSTIFICATION,
          reviewedBy: "security-review",
          reviewedOn: "2026-09-26"
        }
      ],
      ...overrides
    };
    mkdirSync(join(root, "config"), { recursive: true });
    const configPath = join(root, "config", "static-analysis.json");
    const baselinePath = join(root, "config", "slither-baseline.json");
    writeFileSync(configPath, JSON.stringify({
      schemaVersion: 1,
      toolchain: { slither: "0.11.6", cryticCompile: "0.4.2", solc: "0.8.28", python: "3.12" },
      requirementsFile: "config/requirements-static-analysis.txt",
      scope: { target: "contracts/v2", filterPaths: ["lib", "test"] },
      baselineFile: baselinePath,
      reportFile: join(root, "out", "slither.json"),
      suppressibleDispositions: ["false-positive", "accepted-risk"],
      minJustificationLength: 80
    }));
    writeFileSync(baselinePath, JSON.stringify(baseline));
    return { root, configPath, baselinePath };
  }

  it("accepts a fully documented baseline", () => {
    const { baselinePath } = scaffold();
    const loaded = loadBaseline(baselinePath, ["false-positive", "accepted-risk"], 80);
    assert.equal(loaded.entries.length, 1);
    assert.equal(loaded.entries[0].disposition, "false-positive");
  });

  it("fails closed on a baseline file that is not valid JSON", () => {
    const { root, baselinePath } = scaffold();
    writeFileSync(baselinePath, "{ not json");
    assert.throws(() => loadBaseline(baselinePath, ["false-positive"], 80), GateError);
    assert.ok(root);
  });

  it("fails closed when an entry has no justification", () => {
    const { baselinePath } = scaffold();
    writeFileSync(
      baselinePath,
      JSON.stringify({
        entries: [
          {
            fingerprint: "0123456789abcdef",
            detector: "reentrancy-eth",
            disposition: "false-positive",
            reviewedBy: "security-review",
            reviewedOn: "2026-09-26"
          }
        ]
      })
    );
    assert.throws(() => loadBaseline(baselinePath, ["false-positive"], 80), /justification/);
  });

  it("fails closed when a justification is a placeholder rather than a rationale", () => {
    const { baselinePath } = scaffold();
    writeFileSync(
      baselinePath,
      JSON.stringify({
        entries: [
          {
            fingerprint: "0123456789abcdef",
            detector: "reentrancy-eth",
            disposition: "false-positive",
            justification: "false positive",
            reviewedBy: "security-review",
            reviewedOn: "2026-09-26"
          }
        ]
      })
    );
    assert.throws(() => loadBaseline(baselinePath, ["false-positive"], 80), /justification/);
  });

  it("fails closed when a disposition is not suppressible", () => {
    const { baselinePath } = scaffold();
    writeFileSync(
      baselinePath,
      JSON.stringify({
        entries: [
          {
            fingerprint: "0123456789abcdef",
            detector: "reentrancy-eth",
            disposition: "wont-fix",
            justification: JUSTIFICATION,
            reviewedBy: "security-review",
            reviewedOn: "2026-09-26"
          }
        ]
      })
    );
    assert.throws(() => loadBaseline(baselinePath, ["false-positive", "accepted-risk"], 80), /not suppressible/);
  });

  it("fails closed when reviewer metadata is missing", () => {
    const { baselinePath } = scaffold();
    writeFileSync(
      baselinePath,
      JSON.stringify({
        entries: [
          {
            fingerprint: "0123456789abcdef",
            detector: "reentrancy-eth",
            disposition: "false-positive",
            justification: JUSTIFICATION
          }
        ]
      })
    );
    assert.throws(() => loadBaseline(baselinePath, ["false-positive"], 80), /reviewedBy/);
  });

  it("requires a tracking reference for an accepted risk", () => {
    const { baselinePath } = scaffold();
    writeFileSync(
      baselinePath,
      JSON.stringify({
        entries: [
          {
            fingerprint: "0123456789abcdef",
            detector: "reentrancy-eth",
            disposition: "accepted-risk",
            justification: JUSTIFICATION,
            reviewedBy: "security-review",
            reviewedOn: "2026-09-26"
          }
        ]
      })
    );
    assert.throws(() => loadBaseline(baselinePath, ["false-positive", "accepted-risk"], 80), /trackedBy/);
  });

  it("fails closed on duplicate fingerprints", () => {
    const { baselinePath } = scaffold();
    const entry = {
      fingerprint: "0123456789abcdef",
      detector: "reentrancy-eth",
      disposition: "false-positive",
      justification: JUSTIFICATION,
      reviewedBy: "security-review",
      reviewedOn: "2026-09-26"
    };
    writeFileSync(baselinePath, JSON.stringify({ entries: [entry, entry] }));
    assert.throws(() => loadBaseline(baselinePath, ["false-positive"], 80), /duplicates/);
  });

  it("fails closed on a missing baseline file", () => {
    assert.throws(
      () => loadBaseline("config/does-not-exist-baseline.json", ["false-positive"], 80),
      GateError
    );
  });

  it("loads the repository configuration and its pinned toolchain", () => {
    const config = loadConfig("config/static-analysis.json");
    assert.equal(config.toolchain.slither, "0.11.6");
    assert.equal(config.toolchain.solc, "0.8.28");
    assert.deepEqual(config.suppressibleDispositions, ["false-positive", "accepted-risk"]);
  });

  it("pins the analyzer versions listed in the requirements file", () => {
    const config = loadConfig("config/static-analysis.json");
    const requirements = readFileSync(resolve(REPO_ROOT, config.requirementsFile), "utf8");
    assert.match(requirements, new RegExp(`slither-analyzer==${config.toolchain.slither.replace(/\./g, "\\.")}`));
    assert.match(requirements, new RegExp(`crytic-compile==${config.toolchain.cryticCompile.replace(/\./g, "\\.")}`));
  });

  it("fails closed when the configuration omits a pinned toolchain entry", () => {
    const root = mkdtempSync(join(tmpdir(), "sa-cfg-"));
    mkdirSync(join(root, "config"), { recursive: true });
    const configPath = join(root, "config", "static-analysis.json");
    writeFileSync(
      configPath,
      JSON.stringify({
        toolchain: { slither: "0.11.6" },
        scope: { target: "contracts/v2", filterPaths: [] },
        baselineFile: "b.json",
        reportFile: "r.json",
        suppressibleDispositions: ["false-positive"],
        minJustificationLength: 80
      })
    );
    assert.throws(() => loadConfig(configPath), /toolchain\.(cryticCompile|solc|python)/);
  });
});

describe("gate reporting", () => {
  it("reports success and stale entries without failing", () => {
    const lines = formatResult({
      passed: true,
      findings: [],
      newFindings: [],
      resolvedFingerprints: ["deadbeefdeadbeef"],
      config: {
        scope: { target: "contracts/v2" },
        toolchain: { slither: "0.11.6", solc: "0.8.28" },
        minJustificationLength: 80,
        suppressibleDispositions: ["false-positive", "accepted-risk"]
      },
      baseline: { entries: [] }
    });
    const text = lines.join("\n");
    assert.match(text, /no new unresolved findings/);
    assert.match(text, /deadbeefdeadbeef/);
    assert.doesNotMatch(text, /FAILED/);
  });

  it("reports each new finding with its fingerprint and remediation", () => {
    const observed = normalizeReport({ results: { detectors: [finding()] } });
    const lines = formatResult({
      passed: false,
      findings: observed,
      newFindings: observed,
      resolvedFingerprints: [],
      config: {
        scope: { target: "contracts/v2" },
        toolchain: { slither: "0.11.6", solc: "0.8.28" },
        minJustificationLength: 80,
        suppressibleDispositions: ["false-positive", "accepted-risk"]
      },
      baseline: { entries: [] }
    });
    const text = lines.join("\n");
    assert.match(text, /FAILED: 1 new unresolved finding/);
    assert.match(text, /reentrancy-eth/);
    assert.ok(text.includes(observed[0].fingerprint));
    assert.match(text, /config\/slither-baseline\.json/);
  });
});
