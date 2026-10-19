import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ethers } from "ethers";
import { resolve } from "node:path";
import {
  buildVectors,
  emitVectors,
  renderConstants,
  compareDocumentation,
  VERIFICATION_INTENT_TYPE_STRING,
  typesFor,
  compareConstants,
  compareDocuments,
  compareImplementations,
  expectedConstants,
  runCheck,
  SUITE,
  VECTORS_PATH,
  CONSTANTS_PATH,
  IMPLEMENTATION_PATHS,
  REPO_ROOT,
} from "../../scripts/check-eip712-vectors.mjs";

/**
 * V2-SC-152 — self-tests for the canonical vector drift check.
 *
 * These run without Foundry and without a network: they prove that the committed JSON, the
 * Solidity constants mirror, and the implementations are all in sync, and that a corrupted
 * mirror/vector is reported as drift with an actionable diff instead of passing silently.
 */

function readImplementationSources() {
  return Object.fromEntries(
    IMPLEMENTATION_PATHS.map((relative) => [relative, readFileSync(resolve(REPO_ROOT, relative), "utf8")])
  );
}

test("committed vectors match a deterministic rebuild", async () => {
  const rebuilt = await buildVectors();
  const committed = JSON.parse(readFileSync(VECTORS_PATH, "utf8"));
  assert.deepEqual(compareDocuments(rebuilt, committed, "vectors"), []);
});

test("solidity constant mirror matches the vectors", async () => {
  const doc = await buildVectors();
  const source = readFileSync(CONSTANTS_PATH, "utf8");
  assert.deepEqual(compareConstants(source, expectedConstants(doc)), []);
});

test("every implementation declares the canonical type strings", () => {
  assert.deepEqual(compareImplementations(readImplementationSources()), []);
});

test("drift in the solidity mirror fails with an actionable diff", async () => {
  const doc = await buildVectors();
  const source = readFileSync(CONSTANTS_PATH, "utf8");
  const corrupted = source.replace(
    /bytes32 internal constant CLAIM_MAINNET_DIGEST = 0x[0-9a-fA-F]{64};/,
    `bytes32 internal constant CLAIM_MAINNET_DIGEST = 0x${"ab".repeat(32)};`
  );
  assert.notEqual(corrupted, source, "fixture must actually change the canonical digest");

  const problems = compareConstants(corrupted, expectedConstants(doc));
  assert.equal(problems.length, 1, problems.join("\n"));
  assert.match(problems[0], /CLAIM_MAINNET_DIGEST/);
  assert.match(problems[0], /expected/);
  assert.match(problems[0], /0xabab/);
});

test("drift in the vector document is reported for the exact field", async () => {
  const doc = await buildVectors();
  const corrupted = JSON.parse(readFileSync(VECTORS_PATH, "utf8"));
  corrupted.positives[0].digest = `0x${"cd".repeat(32)}`;

  const problems = compareDocuments(doc, corrupted, "vectors");
  assert.ok(
    problems.some((problem) => problem.includes("positives[0].digest")),
    `expected a digest drift entry, got: ${problems.join(" | ")}`
  );
});

test("a renamed domain type string in an implementation is reported", () => {
  const sources = readImplementationSources();
  const first = Object.keys(sources)[0];
  sources[first] = sources[first].replace("uint256 chainId", "uint256 chainID");

  const problems = compareImplementations(sources);
  assert.equal(problems.length, 1, problems.join("\n"));
  assert.match(problems[0], new RegExp(first.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.match(problems[0], /chainId/);
});

test("the full check passes on the committed tree", async () => {
  const doc = await runCheck();
  assert.equal(doc.schema, SUITE);
  assert.ok(doc.positives.length >= 4);
  assert.ok(doc.negatives.length >= 9);
});


test("verification-intent schema and type hash have one canonical definition", async () => {
  const doc = await buildVectors();
  const encodedType = ethers.TypedDataEncoder.from(typesFor("VerificationIntent")).encodeType("VerificationIntent");
  assert.equal(encodedType, VERIFICATION_INTENT_TYPE_STRING);
  assert.equal(doc.constants.VerificationIntent, ethers.id(encodedType));
  assert.equal(expectedConstants(doc).VERIFICATION_INTENT_TYPE_STRING.value, encodedType);
});

for (const relative of IMPLEMENTATION_PATHS) {
  test(`${relative}: changed intent declaration cannot hide behind a canonical comment`, () => {
    const sources = readImplementationSources();
    sources[relative] = sources[relative].replace(VERIFICATION_INTENT_TYPE_STRING,
      VERIFICATION_INTENT_TYPE_STRING.replace("bool approve,string reason", "string reason,bool approve"));
    sources[relative] += `\n// "${VERIFICATION_INTENT_TYPE_STRING}"\n`;
    const problems = compareImplementations(sources);
    assert.equal(problems.length, 1);
    assert.ok(problems[0].includes(relative));
    assert.match(problems[0], /VERIFICATION_INTENT_TYPEHASH.*expected/s);
  });
}

test("numeric deadline drift in the Solidity mirror is rejected", async () => {
  const doc = await buildVectors();
  const source = renderConstants(doc).replace('CANONICAL_DEADLINE = 4102444800', 'CANONICAL_DEADLINE = 1767225600');
  assert.match(compareConstants(source, expectedConstants(doc)).join('\n'), /CANONICAL_DEADLINE.*4102444800.*1767225600/s);
});

test("documentation type hash drift identifies the source", async () => {
  const doc = await buildVectors();
  const source = readFileSync(resolve(REPO_ROOT, "docs/EIP712_SIGNING.md"), "utf8");
  assert.deepEqual(compareDocumentation(source, doc), []);
  assert.match(compareDocumentation(source.replace(doc.constants.VerificationIntent, ethers.ZeroHash), doc)[0],
    /docs\/EIP712_SIGNING.md: VerificationIntent/);
});

test("two fresh-tree regenerations are byte-identical to committed artifacts", async () => {
  const files = [...IMPLEMENTATION_PATHS, "test/vectors/eip712-verifier.vectors.json",
    "contracts/test/EIP712CanonicalVectors.sol", "docs/EIP712_SIGNING.md"];
  const roots = [];
  try {
    for (let run = 0; run < 2; run++) {
      const root = mkdtempSync(join(tmpdir(), "truthbounty-eip712-"));
      roots.push(root);
      for (const file of files) {
        const target = resolve(root, file);
        mkdirSync(resolve(target, ".."), { recursive: true });
        // Normalize Git's platform-specific checkout line endings, not artifact bytes.
        writeFileSync(target, readFileSync(resolve(REPO_ROOT, file), "utf8").replaceAll("\r\n", "\n"));
      }
      await emitVectors(root);
      await runCheck(root);
      for (const file of files) {
        assert.equal(readFileSync(resolve(root, file), "utf8"),
          readFileSync(resolve(REPO_ROOT, file), "utf8").replaceAll("\r\n", "\n"), file);
        if (run === 1) assert.deepEqual(readFileSync(resolve(root, file)), readFileSync(resolve(roots[0], file)), file);
      }
    }
  } finally {
    for (const root of roots) {
      assert.ok(resolve(root).startsWith(resolve(tmpdir()) + "/") || resolve(root).startsWith(resolve(tmpdir()) + "\\"));
      rmSync(root, { recursive: true, force: true });
    }
  }
});

test("every intent mutation changes recovery under the canonical domain", async () => {
  const doc = await buildVectors();
  const positive = doc.positives.find(v => v.caseId === "verification-intent-mainnet");
  const wallet = ethers.Wallet.createRandom();
  const signature = wallet.signingKey.sign(positive.digest).serialized;
  const negatives = doc.negatives.filter(v => v.primaryType === "VerificationIntent" && v.mustDifferFrom);
  assert.deepEqual(new Set(negatives.map(v => v.mutation)),
    new Set(["chainId", "verifyingContract", "domainName", "fieldOrder", "nonce", "deadline", "approve", "reason"]));
  for (const negative of negatives) {
    assert.notEqual(negative.digest, positive.digest, negative.caseId);
    assert.notEqual(ethers.recoverAddress(negative.digest, signature), wallet.address, negative.caseId);
  }
});
