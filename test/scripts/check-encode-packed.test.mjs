#!/usr/bin/env node
/**
 * @file check-encode-packed.test.mjs
 * @description Self-tests for the V2-SC-160 packed-encoding gate (synthetic fixtures for every
 *              rule), plus live-repository verification of the committed policy and of the
 *              cross-tool digest vectors.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  blankStrings,
  checkPolicyAnchors,
  detectInventory,
  detectPackedUses,
  diffInventory,
  fingerprint,
  inferOperandClass,
  isCanonical,
  normalize,
  parseJsTypeList,
  readPolicy,
  splitArgs,
  stripComments,
  validateEntry
} from "../../scripts/check-encode-packed.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "../..");
const JUSTIFICATION = "synthetic fixture justification that is long enough to pass";

const SOURCE = `
contract Fixture {
  function twoDynamic(string memory x, string memory y) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(x, y));
  }
  function fixedWidth(address u, uint256 s) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(u, s));
  }
  // keccak256(abi.encodePacked(commented, out))
  string constant QUOTED = "abi.encodePacked(quoted, text)";
  function label(string memory n) internal pure returns (string memory) {
    return string(abi.encodePacked(n, "|"));
  }
  function concatDigest(bytes memory p, bytes memory q) internal pure returns (bytes32) {
    return keccak256(bytes.concat(p, q));
  }
  function lengthPrefixed(string memory a, string memory b) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked("TAG", uint256(bytes(a).length), bytes(a), uint256(bytes(b).length), bytes(b)));
  }
}`;

const uses = detectPackedUses(SOURCE, "sol");
const [twoDynamic, fixedWidth, label, lengthPrefixed, concatDigest] = [
  uses.find((u) => u.args.join() === "x,y"),
  uses.find((u) => u.args.join() === "u,s"),
  uses.find((u) => u.args[0] === "n"),
  uses.find((u) => u.args[0] === '"TAG"'),
  uses.find((u) => u.kind === "bytes.concat")
];
const POLICY = { canonicalScope: ["contracts/v2/"], entries: [] };

function groupFor(use, file = "contracts/v2/Fixture.sol", source = SOURCE, lang = "sol") {
  return { file, fingerprint: use.fingerprint, count: 1, uses: [use], source, lang };
}

function entryFor(use, extra, file = "contracts/v2/Fixture.sol") {
  return { file, fingerprint: use.fingerprint, context: use.context, justification: JUSTIFICATION, ...extra };
}

describe("lexing", () => {
  test("stripComments blanks comments but keeps string literals and offsets", () => {
    const source = 'a; // abi.encodePacked(x)\n/* keccak256(\n) */ b = "https://x";';
    const stripped = stripComments(source);
    assert.equal(stripped.length, source.length);
    assert.equal(stripped.split("\n").length, source.split("\n").length);
    assert.ok(!stripped.includes("encodePacked"));
    assert.ok(stripped.includes('"https://x"'), "a // inside a string is not a comment");
  });

  test("blankStrings hides quoted text from the pattern matcher", () => {
    const blanked = blankStrings('x = "abi.encodePacked(a, b)";');
    assert.ok(!blanked.includes("encodePacked"));
    assert.equal(blanked.length, 'x = "abi.encodePacked(a, b)";'.length);
  });

  test("splitArgs respects nesting and strings", () => {
    assert.deepEqual(splitArgs('a, f(b, c), "d,e", [g, h]'), ["a", "f(b, c)", '"d,e"', "[g, h]"]);
  });

  test("fingerprint is whitespace-insensitive but content-sensitive", () => {
    assert.equal(fingerprint("abi.encodePacked(a,  b)"), fingerprint("abi.encodePacked(\n a,\n b\n)"));
    assert.notEqual(fingerprint("abi.encodePacked(a, b)"), fingerprint("abi.encodePacked(b, a)"));
    assert.equal(normalize('f( "a b" , c )'), 'f("a b",c)');
  });

  test("parseJsTypeList reads ethers type lists", () => {
    assert.deepEqual(parseJsTypeList('["address", "uint256"]'), ["address", "uint256"]);
    assert.equal(parseJsTypeList("types"), null);
  });
});

describe("detectPackedUses", () => {
  test("finds live uses only (not comments or quoted text) and classifies the context", () => {
    assert.equal(uses.length, 5);
    assert.equal(twoDynamic.context, "digest");
    assert.equal(fixedWidth.context, "digest");
    assert.equal(label.context, "non-digest");
    assert.equal(concatDigest.context, "digest");
  });

  test("tracks bytes.concat only when it feeds a hash", () => {
    const found = detectPackedUses("contract C { function f(bytes memory a, bytes memory b) internal pure returns (bytes memory) { return bytes.concat(a, b); } }", "sol");
    assert.equal(found.length, 0);
  });

  test("detects off-chain packers and their type lists", () => {
    const ts = 'const x = ethers.keccak256(ethers.solidityPacked(["string", "string"], [a, b]));\nconst y = ethers.solidityPackedKeccak256(["address"], [u]);\nconst z = "solidityPacked(";';
    const found = detectPackedUses(ts, "js");
    assert.equal(found.length, 2);
    assert.deepEqual(found[0].jsTypes, ["string", "string"]);
    assert.equal(found[0].context, "digest");
    assert.equal(found[1].context, "digest", "solidityPackedKeccak256 always hashes");
  });
});

describe("inferOperandClass", () => {
  test("uses literals, casts, and declarations", () => {
    assert.equal(inferOperandClass('"TAG"', SOURCE), "literal");
    assert.equal(inferOperandClass("x", SOURCE), "dynamic");
    assert.equal(inferOperandClass("u", SOURCE), "static");
    assert.equal(inferOperandClass("uint256(bytes(a).length)", SOURCE), "static");
    assert.equal(inferOperandClass("bytes(a)", SOURCE), "dynamic");
    assert.equal(inferOperandClass("type(Foo).creationCode", SOURCE), "dynamic");
    assert.equal(inferOperandClass("keccak256(x)", SOURCE), "static");
    assert.equal(inferOperandClass("block.timestamp", SOURCE), "static");
    assert.equal(inferOperandClass("someCall()", SOURCE), "unknown");
  });
});

describe("validateEntry", () => {
  test("rejects a FIXED_WIDTH label on variable-length operands", () => {
    const problems = validateEntry(entryFor(twoDynamic, { classification: "FIXED_WIDTH", args: ["bytes32", "bytes32"] }), groupFor(twoDynamic), POLICY);
    assert.ok(problems.some((p) => /variable-length but declared "bytes32"/.test(p)));
  });

  test("rejects two variable-length operands feeding a hash (constructive collision pattern)", () => {
    const problems = validateEntry(
      entryFor(twoDynamic, { classification: "SINGLE_DYNAMIC", args: ["string", "string"] }, "contracts/Legacy.sol"),
      groupFor(twoDynamic, "contracts/Legacy.sol"),
      POLICY
    );
    assert.ok(problems.some((p) => /two or more variable-length operands feed a hash/.test(p)));
  });

  test("rejects SINGLE_DYNAMIC digests inside the canonical scope", () => {
    const single = detectPackedUses("contract C { function f(string memory d, uint256 n) internal pure returns (bytes32) { return keccak256(abi.encodePacked(d, n)); } }", "sol")[0];
    const source = "string memory d, uint256 n";
    const canonical = validateEntry(entryFor(single, { classification: "SINGLE_DYNAMIC", args: ["string", "uint256"] }), groupFor(single, "contracts/v2/Fixture.sol", source), POLICY);
    assert.ok(canonical.some((p) => /canonical V2 digests must be/.test(p)));
    const legacy = validateEntry(
      entryFor(single, { classification: "SINGLE_DYNAMIC", args: ["string", "uint256"] }, "contracts/Legacy.sol"),
      groupFor(single, "contracts/Legacy.sol", source),
      POLICY
    );
    assert.deepEqual(legacy, []);
  });

  test("accepts a correctly declared FIXED_WIDTH digest in the canonical scope", () => {
    assert.deepEqual(validateEntry(entryFor(fixedWidth, { classification: "FIXED_WIDTH", args: ["address", "uint256"] }), groupFor(fixedWidth), POLICY), []);
  });

  test("checks operand arity", () => {
    const problems = validateEntry(entryFor(fixedWidth, { classification: "FIXED_WIDTH", args: ["address"] }), groupFor(fixedWidth), POLICY);
    assert.ok(problems.some((p) => /declares 1 operand/.test(p)));
  });

  test("accepts LENGTH_PREFIXED only when every variable-length operand is length prefixed", () => {
    const ok = validateEntry(
      entryFor(lengthPrefixed, { classification: "LENGTH_PREFIXED", args: ["literal", "uint256", "bytes", "uint256", "bytes"] }),
      groupFor(lengthPrefixed),
      POLICY
    );
    assert.deepEqual(ok, []);
    const bad = detectPackedUses("contract C { function f(string memory a, string memory b) internal pure returns (bytes32) { return keccak256(abi.encodePacked(uint256(bytes(a).length), bytes(a), bytes(b))); } }", "sol")[0];
    const problems = validateEntry(
      entryFor(bad, { classification: "LENGTH_PREFIXED", args: ["uint256", "bytes", "bytes"] }),
      groupFor(bad, "contracts/v2/Fixture.sol", "string memory a, string memory b"),
      POLICY
    );
    assert.ok(problems.some((p) => /not immediately preceded by uint256/.test(p)));
  });

  test("keeps hash-only classifications off non-hashed uses and vice versa", () => {
    assert.deepEqual(validateEntry(entryFor(label, { classification: "NON_DIGEST" }), groupFor(label), POLICY), []);
    const problems = validateEntry(entryFor(label, { classification: "FIXED_WIDTH" }), groupFor(label), POLICY);
    assert.ok(problems.some((p) => /reserved for hash preimages/.test(p)));
    const mislabel = validateEntry(entryFor(fixedWidth, { classification: "NON_DIGEST", context: "non-digest" }), groupFor(fixedWidth), POLICY);
    assert.ok(mislabel.some((p) => /declared context "non-digest" but detected "digest"/.test(p)));
  });

  test("requires a guard for DELIMITED_VALIDATED and a test/ location for LEGACY_MIRROR", () => {
    const noGuard = validateEntry(entryFor(label, { classification: "DELIMITED_VALIDATED", guard: "_requireNoDelimiter" }), groupFor(label), POLICY);
    assert.ok(noGuard.some((p) => /must name a "guard"/.test(p)));
    const mirror = validateEntry(
      entryFor(twoDynamic, { classification: "LEGACY_MIRROR", args: ["string", "string"], mirrors: "retired scheme" }),
      groupFor(twoDynamic),
      POLICY
    );
    assert.ok(mirror.some((p) => /only permitted in test\//.test(p)));
  });

  test("requires a meaningful justification and a known classification", () => {
    assert.ok(validateEntry(entryFor(fixedWidth, { classification: "FIXED_WIDTH", args: ["address", "uint256"], justification: "ok" }), groupFor(fixedWidth), POLICY).length > 0);
    assert.ok(validateEntry(entryFor(fixedWidth, { classification: "SAFE" }), groupFor(fixedWidth), POLICY).length > 0);
  });

  test("off-chain type lists are authoritative", () => {
    const ts = 'const x = ethers.keccak256(ethers.solidityPacked(["string", "string"], [a, b]));';
    const [use] = detectPackedUses(ts, "js");
    const problems = validateEntry(
      { file: "test/a.ts", fingerprint: use.fingerprint, context: "digest", classification: "FIXED_WIDTH", args: ["bytes32", "bytes32"], justification: JUSTIFICATION },
      groupFor(use, "test/a.ts", ts, "js"),
      POLICY
    );
    assert.ok(problems.some((p) => /type list says "string"/.test(p)));
  });
});

describe("diffInventory", () => {
  test("reports unlisted uses and stale entries", () => {
    const detected = new Map([[`contracts/v2/Fixture.sol#${fixedWidth.fingerprint}`, groupFor(fixedWidth)]]);
    const unlisted = diffInventory(detected, POLICY);
    assert.equal(unlisted.length, 1);
    assert.match(unlisted[0], /unlisted abi\.encodePacked/);

    const stale = diffInventory(new Map(), { entries: [{ file: "contracts/Old.sol", fingerprint: "deadbeef0000" }] });
    assert.equal(stale.length, 1);
    assert.match(stale[0], /stale policy entry/);
  });

  test("reports an occurrence-count drift", () => {
    const group = { ...groupFor(fixedWidth), count: 2, uses: [fixedWidth, fixedWidth] };
    const detected = new Map([[`contracts/v2/Fixture.sol#${fixedWidth.fingerprint}`, group]]);
    const policy = { ...POLICY, entries: [entryFor(fixedWidth, { classification: "FIXED_WIDTH", args: ["address", "uint256"] })] };
    assert.ok(diffInventory(detected, policy).some((p) => /declared count 1 but 2/.test(p)));
  });
});

describe("live repository (V2-SC-160)", () => {
  test("every packed encoding matches the reviewed policy", async () => {
    const detected = await detectInventory(REPO_ROOT);
    const policy = await readPolicy();
    assert.deepEqual(diffInventory(detected, policy), []);
    assert.equal(detected.size, policy.entries.length);
  });

  test("no canonical V2 digest relies on a variable-length packed operand", async () => {
    const policy = await readPolicy();
    for (const entry of policy.entries) {
      if (entry.context === "digest" && isCanonical(entry.file, policy)) {
        assert.ok(["FIXED_WIDTH", "LENGTH_PREFIXED", "PROTOCOL_DEFINED"].includes(entry.classification), `${entry.file} ${entry.excerpt}`);
      }
    }
  });

  test("the V2-SC-160 replacements are still in place", async () => {
    assert.deepEqual(await checkPolicyAnchors(REPO_ROOT), []);
  });

  test("cross-tool digest vectors reproduce with ethers and match the Solidity mirror", async () => {
    const vectors = await import("../../scripts/check-encode-packed-vectors.mjs");
    const doc = JSON.parse(readFileSync(vectors.VECTORS_PATH, "utf8"));
    assert.deepEqual(vectors.verifyVectors(doc), []);
    assert.deepEqual(vectors.compareMirror(readFileSync(vectors.MIRROR_PATH, "utf8"), vectors.expectedMirror(doc)), []);
    assert.deepEqual(vectors.compareWithEip712Suite(doc, JSON.parse(readFileSync(vectors.EIP712_VECTORS_PATH, "utf8"))), []);
  });

  test("the vector checker detects a tampered digest", async () => {
    const vectors = await import("../../scripts/check-encode-packed-vectors.mjs");
    const doc = JSON.parse(readFileSync(vectors.VECTORS_PATH, "utf8"));
    doc.versioned[0].digest = `0x${"00".repeat(32)}`;
    assert.ok(vectors.verifyVectors(doc).length > 0);
  });
});
