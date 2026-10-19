#!/usr/bin/env node
/**
 * @file check-encode-packed-vectors.mjs
 * @description V2-SC-160 — cross-tool digest check for packed-encoding commitments.
 *
 * Recomputes every digest in test/vectors/encode-packed-commitments.vectors.json with ethers
 * (solidityPacked / AbiCoder / getCreate2Address), proves each collision fixture really
 * collides under the retired packed form and really separates under the V2 typed form, checks
 * the V2 scheme tags against the literal preimages in the contracts, and checks the Solidity
 * mirror (contracts/test/EncodePackedCommitmentVectors.sol) constant by constant. The Foundry
 * suite test/v2/EncodePackedCommitments.t.sol checks the same mirror against the live
 * contracts, closing the loop ethers <-> JSON <-> Solidity.
 *
 * Usage:
 *   node scripts/check-encode-packed-vectors.mjs
 */

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
export const REPO_ROOT = resolve(__dirname, "..");
export const VECTORS_PATH = resolve(REPO_ROOT, "test/vectors/encode-packed-commitments.vectors.json");
export const MIRROR_PATH = resolve(REPO_ROOT, "contracts/test/EncodePackedCommitmentVectors.sol");
export const EIP712_VECTORS_PATH = resolve(REPO_ROOT, "test/vectors/eip712-verifier.vectors.json");
export const SUITE = "truthbounty/encode-packed-vectors/v1";

const coder = ethers.AbiCoder.defaultAbiCoder();
const packedHash = (types, values) => ethers.keccak256(ethers.solidityPacked(types, values));
const encodedHash = (types, values) => ethers.keccak256(coder.encode(types, values));
const lower = (value) => String(value).toLowerCase();

function expectEqual(problems, label, found, expected) {
  if (lower(found) !== lower(expected)) problems.push(`${label}\n    expected ${expected}\n    found    ${found}`);
}

function expectDifferent(problems, label, a, b) {
  if (lower(a) === lower(b)) problems.push(`${label}: digests must differ but both are ${a}`);
}

function byId(list, key = "caseId") {
  return Object.fromEntries((list ?? []).map((item) => [item[key], item]));
}

/**
 * Recomputes every vector with ethers.
 * @param {object} doc Parsed vectors document.
 * @param {(path: string) => string} [readSource] Reads a repository file (for tag preimages).
 * @returns {string[]} Problems (empty when every vector is reproduced).
 */
export function verifyVectors(doc, readSource = (p) => readFileSync(resolve(REPO_ROOT, p), "utf8")) {
  const problems = [];
  if (doc.schema !== SUITE) problems.push(`schema must be ${SUITE}, found ${doc.schema}`);

  // ---- scheme tags ----
  const schemes = byId(doc.schemes, "id");
  for (const scheme of doc.schemes ?? []) {
    expectEqual(problems, `scheme ${scheme.id} tag`, ethers.keccak256(ethers.toUtf8Bytes(scheme.tagPreimage)), scheme.tag);
    if (scheme.abiTypes?.[0] !== "bytes32") problems.push(`scheme ${scheme.id}: the version tag must be the first ABI word`);
    const file = scheme.consumer.split("#")[0].trim();
    let source = "";
    try {
      source = readSource(file);
    } catch {
      problems.push(`scheme ${scheme.id}: consumer ${file} is missing`);
    }
    if (source && !source.includes(`keccak256("${scheme.tagPreimage}")`)) {
      problems.push(`scheme ${scheme.id}: ${file} does not define its tag as keccak256("${scheme.tagPreimage}")`);
    }
  }
  const tags = Object.values(schemes).map((s) => lower(s.tag));
  if (new Set(tags).size !== tags.length) problems.push("scheme tags must be pairwise distinct");

  // ---- constructive collision fixtures ----
  const collisions = byId(doc.collisions);
  const adjacent = collisions["adjacent-dynamic-strings"];
  if (!adjacent) problems.push("missing collision fixture adjacent-dynamic-strings");
  else {
    const left = ethers.solidityPacked(adjacent.packedTypes, adjacent.left);
    const right = ethers.solidityPacked(adjacent.packedTypes, adjacent.right);
    expectEqual(problems, "adjacent-dynamic-strings packed(left)", left, adjacent.packedHex);
    expectEqual(problems, "adjacent-dynamic-strings packed(right)", right, adjacent.packedHex);
    expectEqual(problems, "adjacent-dynamic-strings packed digest", ethers.keccak256(left), adjacent.packedDigest);
    expectEqual(problems, "adjacent-dynamic-strings encoded(left)", encodedHash(adjacent.packedTypes, adjacent.left), adjacent.encodedDigestLeft);
    expectEqual(problems, "adjacent-dynamic-strings encoded(right)", encodedHash(adjacent.packedTypes, adjacent.right), adjacent.encodedDigestRight);
    expectDifferent(problems, "adjacent-dynamic-strings typed encodings", adjacent.encodedDigestLeft, adjacent.encodedDigestRight);
  }

  const cross = collisions["cross-schema-operation-id-vs-upgrade-proposal-id"];
  if (!cross) problems.push("missing collision fixture cross-schema-operation-id-vs-upgrade-proposal-id");
  else {
    const proposal = packedHash(cross.legacyProposalId.packedTypes, cross.legacyProposalId.values);
    const operation = packedHash(cross.legacyOperationId.packedTypes, cross.legacyOperationId.values);
    expectEqual(problems, "cross-schema legacy proposal id", proposal, cross.legacyDigest);
    expectEqual(problems, "cross-schema legacy operation id (must collide)", operation, cross.legacyDigest);
    const opScheme = schemes["operationId.v2"];
    const propScheme = schemes["proposalId.v2"];
    if (opScheme && propScheme) {
      expectEqual(
        problems,
        "cross-schema V2 operation id",
        encodedHash(["bytes32", "bytes", "uint256", "address"], [opScheme.tag, ...cross.legacyOperationId.values]),
        cross.v2OperationId
      );
      expectEqual(
        problems,
        "cross-schema V2 proposal id",
        encodedHash(propScheme.abiTypes, [propScheme.tag, ...cross.legacyProposalId.values.slice(1)]),
        cross.v2ProposalId
      );
    }
    expectDifferent(problems, "cross-schema V2 ids", cross.v2OperationId, cross.v2ProposalId);
  }

  const delimiter = collisions["delimiter-shift"];
  if (!delimiter) problems.push("missing collision fixture delimiter-shift");
  else {
    const join = (r) => `${r.name}${delimiter.delimiter}${r.version}`;
    if (join(delimiter.left) !== delimiter.record || join(delimiter.right) !== delimiter.record) {
      problems.push(`delimiter-shift: both records must join to "${delimiter.record}"`);
    }
  }

  // ---- versioned (changed) digests ----
  for (const vector of doc.versioned ?? []) {
    const scheme = schemes[vector.scheme];
    if (!scheme) {
      problems.push(`${vector.caseId}: unknown scheme ${vector.scheme}`);
      continue;
    }
    expectEqual(problems, `${vector.caseId} V2 digest`, encodedHash(scheme.abiTypes, [scheme.tag, ...vector.values]), vector.digest);
    const legacyValues = [...(vector.legacyValuesPrefix ?? []), ...vector.values];
    expectEqual(problems, `${vector.caseId} legacy digest`, packedHash(vector.legacyPackedTypes, legacyValues), vector.legacyDigest);
    expectDifferent(problems, `${vector.caseId} V2 vs legacy`, vector.digest, vector.legacyDigest);
  }

  // ---- retained fixed-width patterns (compatibility vectors: must never change) ----
  for (const vector of doc.retained ?? []) {
    if (vector.caseId.startsWith("reputation-merkle-leaf")) {
      const inner = ethers.solidityPackedKeccak256(vector.packedTypes, vector.values);
      expectEqual(problems, `${vector.caseId} leaf`, ethers.keccak256(ethers.solidityPacked(["bytes32"], [inner])), vector.digest);
    } else if (vector.caseId.startsWith("create2-eip1014")) {
      const digest = packedHash(vector.packedTypes, vector.values);
      expectEqual(problems, `${vector.caseId} init code hash`, ethers.keccak256(vector.initCode), vector.values[3]);
      expectEqual(problems, `${vector.caseId} address (packed)`, ethers.getAddress(ethers.dataSlice(digest, 12)), vector.address);
      expectEqual(
        problems,
        `${vector.caseId} address (ethers.getCreate2Address)`,
        ethers.getCreate2Address(vector.values[1], vector.values[2], vector.values[3]),
        vector.address
      );
    } else {
      expectEqual(problems, `${vector.caseId} digest`, packedHash(vector.packedTypes, vector.values), vector.digest);
    }
    if (vector.valuePreimages) {
      vector.valuePreimages.forEach((preimage, i) =>
        expectEqual(problems, `${vector.caseId} value ${i} preimage`, ethers.keccak256(ethers.toUtf8Bytes(preimage)), vector.values[i])
      );
    }
    for (const type of vector.packedTypes ?? []) {
      if ((type === "string" || type === "bytes" || type.endsWith("[]")) && vector.caseId !== "appeal-bond-lock-id") {
        problems.push(`${vector.caseId}: retained packed vectors must be fixed-width (found ${type})`);
      }
    }
  }

  return problems;
}

/** Expected Solidity mirror constants, derived from the vectors (never hand written twice). */
export function expectedMirror(doc) {
  const schemes = byId(doc.schemes, "id");
  const collisions = byId(doc.collisions);
  const versioned = byId(doc.versioned);
  const retained = byId(doc.retained);
  const adjacent = collisions["adjacent-dynamic-strings"];
  const cross = collisions["cross-schema-operation-id-vs-upgrade-proposal-id"];
  const proposal = versioned["upgrade-proposal-id-v2"];
  const upgradeHash = versioned["upgrade-hash-v2"];
  const operation = versioned["operation-id-v2"];
  const eip712 = retained["eip712-typed-data-prefix"];
  const leafA = retained["reputation-merkle-leaf-a"];
  const leafB = retained["reputation-merkle-leaf-b"];
  const ex0 = retained["create2-eip1014-example-0"];
  const ex1 = retained["create2-eip1014-example-1"];
  const salt = retained["create2-derive-salt"];
  return {
    OPERATION_ID_SCHEME_V2: { value: schemes["operationId.v2"].tag, kind: "bytes32" },
    UPGRADE_HASH_SCHEME_V2: { value: schemes["upgradeHash.v2"].tag, kind: "bytes32" },
    UPGRADE_PROPOSAL_ID_SCHEME_V2: { value: schemes["proposalId.v2"].tag, kind: "bytes32" },
    PACKED_AB_C_DIGEST: { value: adjacent.packedDigest, kind: "bytes32" },
    ENCODED_AB_C_DIGEST: { value: adjacent.encodedDigestLeft, kind: "bytes32" },
    ENCODED_A_BC_DIGEST: { value: adjacent.encodedDigestRight, kind: "bytes32" },
    UPGRADE_TARGET: { value: proposal.values[0], kind: "address" },
    UPGRADE_NEW_IMPL: { value: proposal.values[1], kind: "address" },
    UPGRADE_CURRENT_IMPL: { value: upgradeHash.values[1], kind: "address" },
    UPGRADE_PROPOSER: { value: proposal.values[3], kind: "address" },
    UPGRADE_VERSION: { value: proposal.values[2], kind: "string" },
    UPGRADE_TIMESTAMP: { value: proposal.values[4], kind: "uint256" },
    LEGACY_UPGRADE_PROPOSAL_ID: { value: proposal.legacyDigest, kind: "bytes32" },
    LEGACY_UPGRADE_HASH: { value: upgradeHash.legacyDigest, kind: "bytes32" },
    UPGRADE_PROPOSAL_ID_V2: { value: proposal.digest, kind: "bytes32" },
    UPGRADE_HASH_V2: { value: upgradeHash.digest, kind: "bytes32" },
    COLLIDING_OPERATION_NONCE: { value: cross.legacyOperationId.values[1], kind: "uint256" },
    COLLIDING_OPERATION_ACTOR: { value: cross.legacyOperationId.values[2], kind: "address" },
    COLLIDING_OPERATION_ID_V2: { value: cross.v2OperationId, kind: "bytes32" },
    OPERATION_DOMAIN: { value: operation.values[0], kind: "string" },
    OPERATION_NONCE: { value: operation.values[1], kind: "uint256" },
    OPERATION_ACTOR: { value: operation.values[2], kind: "address" },
    OPERATION_ID_V2: { value: operation.digest, kind: "bytes32" },
    OPERATION_ID_LEGACY: { value: operation.legacyDigest, kind: "bytes32" },
    EIP712_DOMAIN_SEPARATOR: { value: eip712.values[1], kind: "bytes32" },
    EIP712_STRUCT_HASH: { value: eip712.values[2], kind: "bytes32" },
    EIP712_DIGEST: { value: eip712.digest, kind: "bytes32" },
    MERKLE_USER_A: { value: leafA.values[0], kind: "address" },
    MERKLE_SCORE_A: { value: leafA.values[1], kind: "uint256" },
    MERKLE_USER_B: { value: leafB.values[0], kind: "address" },
    MERKLE_SCORE_B: { value: leafB.values[1], kind: "uint256" },
    MERKLE_TIMESTAMP: { value: leafA.values[2], kind: "uint256" },
    MERKLE_LEAF_A: { value: leafA.digest, kind: "bytes32" },
    MERKLE_LEAF_B: { value: leafB.digest, kind: "bytes32" },
    MERKLE_NODE_AB: { value: retained["reputation-merkle-node-ab"].digest, kind: "bytes32" },
    CREATE2_INIT_CODE_00_HASH: { value: ex0.values[3], kind: "bytes32" },
    CREATE2_EX1_DEPLOYER: { value: ex1.values[1], kind: "address" },
    CREATE2_EIP1014_EX0: { value: ex0.address, kind: "address" },
    CREATE2_EIP1014_EX1: { value: ex1.address, kind: "address" },
    CREATE2_MODULE_ID: { value: salt.values[0], kind: "bytes32" },
    CREATE2_REVIEWED_SALT: { value: salt.values[1], kind: "bytes32" },
    CREATE2_DERIVED_SALT: { value: salt.digest, kind: "bytes32" },
    APPEAL_LOCK_ID_1_0: { value: retained["appeal-bond-lock-id"].digest, kind: "bytes32" }
  };
}

/** Parses `<type> internal constant NAME = value;` declarations from the Solidity mirror. */
export function extractConstants(soliditySource) {
  const found = {};
  const re = /\b(bytes32|address|string|uint256)\s+internal\s+constant\s+(\w+)\s*=\s*(0x[0-9a-fA-F]+|"[^"]*"|\d+)\s*;/g;
  let match;
  while ((match = re.exec(soliditySource)) !== null) {
    found[match[2]] = match[3].startsWith('"') ? match[3].slice(1, -1) : match[3];
  }
  return found;
}

/** Compares the Solidity mirror against the expected constants. */
export function compareMirror(soliditySource, expected) {
  const found = extractConstants(soliditySource);
  const problems = [];
  const norm = (value, kind) => (kind === "string" ? value : kind === "uint256" ? BigInt(value).toString() : lower(value));
  for (const [name, spec] of Object.entries(expected)) {
    if (!(name in found)) {
      problems.push(`mirror is missing constant ${name} (expected ${spec.value})`);
      continue;
    }
    if (norm(found[name], spec.kind) !== norm(spec.value, spec.kind)) {
      problems.push(`mirror constant ${name}\n    expected ${spec.value}\n    found    ${found[name]}`);
    }
    if (spec.kind === "address") {
      try {
        if (ethers.getAddress(found[name]) !== found[name]) problems.push(`mirror constant ${name} must be EIP-55 checksummed`);
      } catch {
        problems.push(`mirror constant ${name} is not an address`);
      }
    }
  }
  for (const name of Object.keys(found)) {
    if (!(name in expected)) problems.push(`mirror declares unexpected constant ${name} (not part of ${SUITE})`);
  }
  return problems;
}

/** The retained EIP-712 vector must stay identical to the V2-SC-152 canonical vector. */
export function compareWithEip712Suite(doc, eip712Doc) {
  const problems = [];
  const eip712 = byId(doc.retained)["eip712-typed-data-prefix"];
  const canonical = byId(eip712Doc.positives)["claim-submission-mainnet"];
  if (!canonical) return ["V2-SC-152 vector claim-submission-mainnet is missing"];
  expectEqual(problems, "EIP-712 domain separator vs V2-SC-152", eip712.values[1], eip712Doc.domainSeparators["1"]);
  expectEqual(problems, "EIP-712 struct hash vs V2-SC-152", eip712.values[2], canonical.structHash);
  expectEqual(problems, "EIP-712 digest vs V2-SC-152", eip712.digest, canonical.digest);
  return problems;
}

export function runCheck() {
  const doc = JSON.parse(readFileSync(VECTORS_PATH, "utf8"));
  const problems = [
    ...verifyVectors(doc),
    ...compareMirror(readFileSync(MIRROR_PATH, "utf8"), expectedMirror(doc)),
    ...compareWithEip712Suite(doc, JSON.parse(readFileSync(EIP712_VECTORS_PATH, "utf8")))
  ];
  if (problems.length > 0) {
    console.error(`Packed-commitment vector drift detected (${problems.length} difference(s)):\n`);
    for (const problem of problems) console.error(`  - ${problem}`);
    throw new Error("encode-packed commitment vectors are out of date");
  }
  return doc;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(__filename)) {
  try {
    const doc = runCheck();
    console.log(
      `Packed-commitment vectors OK: ${doc.schemes.length} V2 schemes, ${doc.collisions.length} collision fixtures, ` +
        `${doc.versioned.length} versioned digests, ${doc.retained.length} retained vectors, Solidity mirror in sync`
    );
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
