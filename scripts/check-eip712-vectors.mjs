#!/usr/bin/env node
/**
 * @file check-eip712-vectors.mjs
 * @description Canonical EIP-712 vector registry and drift check for EIP712Verifier (V2-SC-152).
 *
 * The repository carries one EIP-712 implementation in two files
 * (`contracts/EIP712Verifier.sol` and `contracts/decay.sol`). They must sign the same bytes:
 * same domain type hash, same struct type strings, same field order, same nonce and deadline
 * semantics. This script is the single source of truth for that surface.
 *
 * What it enforces
 *   1. `test/vectors/eip712-verifier.vectors.json` matches vectors recomputed with ethers v6.
 *   2. `contracts/test/EIP712CanonicalVectors.sol` mirrors the JSON byte for byte (no hand edits).
 *   3. Every implementation in IMPLEMENTATION_PATHS declares the canonical domain/struct type
 *      strings and field order, so a rename or field shuffle cannot land silently.
 *   4. A signature produced by an EIP-712 wallet over a vector digest recovers to the signer,
 *      i.e. the digest really is the message wallets sign.
 *
 * Usage
 *   node scripts/check-eip712-vectors.mjs           # check (CI); non-zero exit on drift
 *   node scripts/check-eip712-vectors.mjs --emit    # deterministically regenerate JSON and Solidity mirror
 *
 * No private key and no signature is stored anywhere in this repository: signature tests derive
 * material at runtime from the publicly documented Hardhat test key.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";

const __dirname = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(__dirname, "..");
export const VECTORS_PATH = resolve(REPO_ROOT, "test/vectors/eip712-verifier.vectors.json");
export const DOCUMENTATION_PATH = resolve(REPO_ROOT, "docs/EIP712_SIGNING.md");
export const CONSTANTS_PATH = resolve(REPO_ROOT, "contracts/test/EIP712CanonicalVectors.sol");
export const IMPLEMENTATION_PATHS = [
  "contracts/EIP712Verifier.sol",
  "contracts/decay.sol",
];

export const DOMAIN_NAME = "TruthBounty";
export const DOMAIN_VERSION = "1";
export const VERIFYING_CONTRACT = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
/** Second deployment address used by the wrong-verifying-contract negative vector. */
export const WRONG_VERIFYING_CONTRACT = "0x000000000000000000000000000000000000bEEF";
export const SUITE = "truthbounty/eip712-vectors/v1";

export const DOMAIN_TYPE_STRING =
  "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
export const CLAIM_TYPE_STRING =
  "ClaimSubmission(address claimant,uint256 bountyId,bytes32 contentHash,uint256 nonce,uint256 deadline)";
export const VERIFICATION_INTENT_TYPE_STRING =
  "VerificationIntent(address verifier,uint256 bountyId,bool approve,string reason,uint256 nonce,uint256 deadline)";
export const MUTATED_CLAIM_TYPE_STRING =
  "ClaimSubmission(address claimant,uint256 bountyId,bytes32 contentHash,uint8 nonce,uint256 deadline)";

export const CHAIN_ID_MAINNET = 1;
export const CHAIN_ID_LOCAL = 31337;
export const CHAIN_ID_WRONG = 10;

export const CANONICAL_DEADLINE = 4102444800; // 2100-01-01T00:00:00Z (far-future bound: no test needs to warp backwards)

export const CLAIMANT_A = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
export const CLAIMANT_B = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
export const VERIFIER_A = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";

export const TYPES = {
  ClaimSubmission: [
    { name: "claimant", type: "address" },
    { name: "bountyId", type: "uint256" },
    { name: "contentHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  VerificationIntent: VERIFICATION_INTENT_TYPE_STRING
    .slice("VerificationIntent(".length, -1)
    .split(",")
    .map((field) => {
      const [type, name] = field.split(" ");
      return { name, type };
    }),
};

/** `uint8 nonce` variant used only as a negative vector (type-string drift). */
export const MUTATED_TYPES = {
  ...TYPES,
  ClaimSubmission: [
    { name: "claimant", type: "address" },
    { name: "bountyId", type: "uint256" },
    { name: "contentHash", type: "bytes32" },
    { name: "nonce", type: "uint8" },
    { name: "deadline", type: "uint256" },
  ],
};

export const CLAIM_A_CONTENT = "truthbounty:claim:42";
export const CLAIM_B_CONTENT = "truthbounty:claim:1";
export const INTENT_A_REASON = "evidence verified";
export const INTENT_B_REASON = "content hash mismatch";
export const CONTENT_HASH_A = ethers.keccak256(ethers.toUtf8Bytes(CLAIM_A_CONTENT));
export const CONTENT_HASH_B = ethers.keccak256(ethers.toUtf8Bytes(CLAIM_B_CONTENT));

export const CLAIM_A = {
  claimant: CLAIMANT_A,
  bountyId: 42,
  contentHash: CONTENT_HASH_A,
  nonce: 7,
  deadline: CANONICAL_DEADLINE,
};
export const CLAIM_B = {
  claimant: CLAIMANT_B,
  bountyId: 1,
  contentHash: CONTENT_HASH_B,
  nonce: 0,
  deadline: CANONICAL_DEADLINE,
};
export const INTENT_A = {
  verifier: VERIFIER_A,
  bountyId: 42,
  approve: true,
  reason: INTENT_A_REASON,
  nonce: 3,
  deadline: CANONICAL_DEADLINE,
};
export const INTENT_B = {
  verifier: VERIFIER_A,
  bountyId: 42,
  approve: false,
  reason: INTENT_B_REASON,
  nonce: 4,
  deadline: CANONICAL_DEADLINE,
};

export function domainFor(chainId, verifyingContract = VERIFYING_CONTRACT) {
  return { name: DOMAIN_NAME, version: DOMAIN_VERSION, chainId, verifyingContract };
}

/**
 * Return only the requested primary type.
 *
 * ethers v6 rejects a type map containing two unrelated roots because it cannot
 * infer one unambiguous primary type. Keeping both canonical operations in the
 * registry is useful, but every encoder/signature call must select exactly one.
 */
export function typesFor(primaryType, types = TYPES) {
  const fields = types[primaryType];
  if (!fields) throw new Error(`unknown EIP-712 primary type: ${primaryType}`);
  return { [primaryType]: fields };
}

/** Struct hash exactly as the Solidity `keccak256(abi.encode(typeHash, ...fields))` does it. */
export function structHash(primaryType, message, types = TYPES) {
  return ethers.TypedDataEncoder.hashStruct(primaryType, typesFor(primaryType, types), message);
}

/** Digest exactly as `_hashTypedDataV4` does it: keccak256(0x1901 || domainSeparator || structHash). */
export function digestFor(chainId, primaryType, message, types = TYPES, verifyingContract = VERIFYING_CONTRACT) {
  return ethers.TypedDataEncoder.hash(
    domainFor(chainId, verifyingContract),
    typesFor(primaryType, types),
    message
  );
}

function mutatedFieldOrderStructHash() {
  // Field order drift: identical type string, claimant and bountyId encoded the other way round.
  const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
    ["bytes32", "uint256", "address", "bytes32", "uint256", "uint256"],
    [ethers.id(CLAIM_TYPE_STRING), CLAIM_A.bountyId, CLAIM_A.claimant, CLAIM_A.contentHash, CLAIM_A.nonce, CLAIM_A.deadline]
  );
  return ethers.keccak256(encoded);
}

function digestOfStruct(domainSeparator, structHashValue) {
  return ethers.keccak256(ethers.concat(["0x1901", domainSeparator, structHashValue]));
}

function vector(caseId, operation, chainId, message, structHashValue, digest) {
  return {
    caseId,
    operation,
    primaryType: operation === "claimSubmission" ? "ClaimSubmission" : "VerificationIntent",
    chainId,
    verifyingContract: VERIFYING_CONTRACT,
    message,
    structHash: structHashValue,
    digest,
  };
}

/**
 * Recompute every vector. Deterministic apart from the signature-recovery probe, which is
 * intentionally excluded from the artifact.
 */
export async function buildVectors() {
  const domainSeparators = {
    [String(CHAIN_ID_MAINNET)]: ethers.TypedDataEncoder.hashDomain(domainFor(CHAIN_ID_MAINNET)),
    [String(CHAIN_ID_LOCAL)]: ethers.TypedDataEncoder.hashDomain(domainFor(CHAIN_ID_LOCAL)),
  };

  const positives = [
    vector(
      "claim-submission-mainnet",
      "claimSubmission",
      CHAIN_ID_MAINNET,
      CLAIM_A,
      structHash("ClaimSubmission", CLAIM_A),
      digestFor(CHAIN_ID_MAINNET, "ClaimSubmission", CLAIM_A)
    ),
    vector(
      "claim-submission-local",
      "claimSubmission",
      CHAIN_ID_LOCAL,
      CLAIM_B,
      structHash("ClaimSubmission", CLAIM_B),
      digestFor(CHAIN_ID_LOCAL, "ClaimSubmission", CLAIM_B)
    ),
    vector(
      "verification-intent-mainnet",
      "verificationIntent",
      CHAIN_ID_MAINNET,
      INTENT_A,
      structHash("VerificationIntent", INTENT_A),
      digestFor(CHAIN_ID_MAINNET, "VerificationIntent", INTENT_A)
    ),
    vector(
      "verification-intent-local",
      "verificationIntent",
      CHAIN_ID_LOCAL,
      INTENT_B,
      structHash("VerificationIntent", INTENT_B),
      digestFor(CHAIN_ID_LOCAL, "VerificationIntent", INTENT_B)
    ),
  ];

  const wrongChainDomain = ethers.TypedDataEncoder.hashDomain(domainFor(CHAIN_ID_WRONG));
  const wrongContractDomain = ethers.TypedDataEncoder.hashDomain(
    domainFor(CHAIN_ID_MAINNET, WRONG_VERIFYING_CONTRACT)
  );
  const wrongNameDomain = ethers.TypedDataEncoder.hashDomain({
    ...domainFor(CHAIN_ID_MAINNET),
    name: "TruthBountyV2",
  });

  const messageNonce8 = { ...CLAIM_A, nonce: 8 };
  const messageDeadlinePlus1 = { ...CLAIM_A, deadline: CANONICAL_DEADLINE + 1 };
  const messageApproveFalse = { ...INTENT_A, approve: false };
  const messageReasonTrailingSpace = { ...INTENT_A, reason: `${INTENT_A_REASON} ` };

  const fieldOrderStructHashValue = mutatedFieldOrderStructHash();
  const mutatedTypeStructHashValue = ethers.TypedDataEncoder.hashStruct(
    "ClaimSubmission",
    typesFor("ClaimSubmission", MUTATED_TYPES),
    CLAIM_A
  );

  const negatives = [
    {
      ...vector(
        "claim-wrong-chain-id",
        "claimSubmission",
        CHAIN_ID_MAINNET,
        CLAIM_A,
        structHash("ClaimSubmission", CLAIM_A),
        digestOfStruct(wrongChainDomain, structHash("ClaimSubmission", CLAIM_A))
      ),
      mutation: "chainId",
      mutationValue: CHAIN_ID_WRONG,
      mustDifferFrom: "claim-submission-mainnet",
      note: "digest is domain-bound; a mainnet signature must not verify on chain 10",
    },
    {
      ...vector(
        "claim-wrong-verifying-contract",
        "claimSubmission",
        CHAIN_ID_MAINNET,
        CLAIM_A,
        structHash("ClaimSubmission", CLAIM_A),
        digestOfStruct(wrongContractDomain, structHash("ClaimSubmission", CLAIM_A))
      ),
      mutation: "verifyingContract",
      mutationValue: WRONG_VERIFYING_CONTRACT,
      mustDifferFrom: "claim-submission-mainnet",
      note: "a signature for one deployment must not replay on another; the same bytecode is deployed at this address by the tests",
    },
    {
      ...vector(
        "claim-wrong-domain-name",
        "claimSubmission",
        CHAIN_ID_MAINNET,
        CLAIM_A,
        structHash("ClaimSubmission", CLAIM_A),
        digestOfStruct(wrongNameDomain, structHash("ClaimSubmission", CLAIM_A))
      ),
      mutation: "domainName",
      mutationValue: "TruthBountyV2",
      mustDifferFrom: "claim-submission-mainnet",
      note: "the domain name is part of the signed payload",
    },
    {
      ...vector(
        "claim-wrong-nonce",
        "claimSubmission",
        CHAIN_ID_MAINNET,
        messageNonce8,
        structHash("ClaimSubmission", messageNonce8),
        digestFor(CHAIN_ID_MAINNET, "ClaimSubmission", messageNonce8)
      ),
      mutation: "nonce",
      mutationValue: 8,
      mustDifferFrom: "claim-submission-mainnet",
      note: "nonce is inside the struct hash, so a stale nonce cannot replay",
    },
    {
      ...vector(
        "claim-wrong-deadline",
        "claimSubmission",
        CHAIN_ID_MAINNET,
        messageDeadlinePlus1,
        structHash("ClaimSubmission", messageDeadlinePlus1),
        digestFor(CHAIN_ID_MAINNET, "ClaimSubmission", messageDeadlinePlus1)
      ),
      mutation: "deadline",
      mutationValue: CANONICAL_DEADLINE + 1,
      mustDifferFrom: "claim-submission-mainnet",
      note: "deadline is inside the struct hash and checked against block.timestamp",
    },
    {
      ...vector(
        "claim-mutated-field-order",
        "claimSubmission",
        CHAIN_ID_MAINNET,
        CLAIM_A,
        fieldOrderStructHashValue,
        digestOfStruct(domainSeparators[String(CHAIN_ID_MAINNET)], fieldOrderStructHashValue)
      ),
      mutation: "fieldOrder",
      mutationValue: "claimant<->bountyId",
      mustDifferFrom: "claim-submission-mainnet",
      note: "field order is part of the encoding: swapping claimant/bountyId changes the digest",
    },
    {
      ...vector(
        "claim-mutated-type-string",
        "claimSubmission",
        CHAIN_ID_MAINNET,
        CLAIM_A,
        mutatedTypeStructHashValue,
        digestOfStruct(domainSeparators[String(CHAIN_ID_MAINNET)], mutatedTypeStructHashValue)
      ),
      mutation: "typeString",
      mutationValue: MUTATED_CLAIM_TYPE_STRING,
      mutationTypeString: MUTATED_CLAIM_TYPE_STRING,
      mustDifferFrom: "claim-submission-mainnet",
      note: "any change to the type string changes the type hash and therefore the digest",
    },
    {
      ...vector(
        "intent-wrong-approve-flag",
        "verificationIntent",
        CHAIN_ID_MAINNET,
        messageApproveFalse,
        structHash("VerificationIntent", messageApproveFalse),
        digestFor(CHAIN_ID_MAINNET, "VerificationIntent", messageApproveFalse)
      ),
      mutation: "approve",
      mutationValue: false,
      mustDifferFrom: "verification-intent-mainnet",
      note: "the approve flag is inside the signed payload, so a reject approval cannot be flipped",
    },
    {
      ...vector(
        "intent-wrong-reason",
        "verificationIntent",
        CHAIN_ID_MAINNET,
        messageReasonTrailingSpace,
        structHash("VerificationIntent", messageReasonTrailingSpace),
        digestFor(CHAIN_ID_MAINNET, "VerificationIntent", messageReasonTrailingSpace)
      ),
      mutation: "reason",
      mutationValue: `${INTENT_A_REASON} `,
      mustDifferFrom: "verification-intent-mainnet",
      note: "the reason is hashed with keccak256(bytes(reason)); trailing whitespace changes it",
    },
    {
      ...vector(
        "claim-expired-deadline",
        "claimSubmission",
        CHAIN_ID_MAINNET,
        CLAIM_A,
        structHash("ClaimSubmission", CLAIM_A),
        digestFor(CHAIN_ID_MAINNET, "ClaimSubmission", CLAIM_A)
      ),
      mutation: "deadlineExpired",
      mutationValue: "block.timestamp > deadline",
      mustDifferFrom: null,
      expectedRevert: "SignatureExpired",
      note: "digest matches the positive vector; reverts only because block.timestamp > deadline",
    },
  ];

  const intentBase = positives.find((v) => v.caseId === "verification-intent-mainnet");
  const intentMutation = (id, mutation, mutationValue, message, hash, domain = domainSeparators[String(CHAIN_ID_MAINNET)]) => ({
    ...vector(id, "verificationIntent", CHAIN_ID_MAINNET, message, hash, digestOfStruct(domain, hash)),
    mutation, mutationValue, mustDifferFrom: intentBase.caseId, expectedRevert: "InvalidSignature",
  });
  negatives.push(
    intentMutation("intent-wrong-chain-id", "chainId", CHAIN_ID_WRONG, INTENT_A, intentBase.structHash, wrongChainDomain),
    intentMutation("intent-wrong-verifying-contract", "verifyingContract", WRONG_VERIFYING_CONTRACT, INTENT_A, intentBase.structHash, wrongContractDomain),
    intentMutation("intent-wrong-domain-name", "domainName", "TruthBountyV2", INTENT_A, intentBase.structHash, wrongNameDomain),
  );
  for (const [field, value] of [["nonce", INTENT_A.nonce + 1], ["deadline", CANONICAL_DEADLINE + 1]]) {
    const message = { ...INTENT_A, [field]: value };
    negatives.push(intentMutation(`intent-wrong-${field}`, field, value, message, structHash("VerificationIntent", message)));
  }
  const swappedFields = { VerificationIntent: [TYPES.VerificationIntent[1], TYPES.VerificationIntent[0], ...TYPES.VerificationIntent.slice(2)] };
  negatives.push(intentMutation("intent-mutated-field-order", "fieldOrder", "verifier<->bountyId", INTENT_A,
    structHash("VerificationIntent", INTENT_A, swappedFields)));
  negatives.push({ ...intentBase, caseId: "intent-expired-deadline", mutation: "deadlineExpired",
    mutationValue: "block.timestamp > deadline", mustDifferFrom: null, expectedRevert: "SignatureExpired" });

  return {
    schema: SUITE,
    description:
      "Canonical EIP-712 vectors for contracts/EIP712Verifier.sol. Regenerate with: node scripts/check-eip712-vectors.mjs --emit. Verify with: node scripts/check-eip712-vectors.mjs",
    signaturePolicy:
      "No signature is committed. Tests derive signatures at runtime with vm.sign (Foundry) and wallet.signTypedData (ethers) using the well-known Hardhat test key 0xac0974...ff80 only; production keys must never appear here.",
    canonicalSigningKeyReference: {
      kind: "well-known-hardhat-account-0-test-key",
      address: CLAIMANT_A,
      note: "test-only key, publicly documented by Hardhat; never funded on mainnet by this repository",
    },
    domain: {
      name: DOMAIN_NAME,
      version: DOMAIN_VERSION,
      typeString: DOMAIN_TYPE_STRING,
    },
    typeStrings: {
      ClaimSubmission: CLAIM_TYPE_STRING,
      VerificationIntent: VERIFICATION_INTENT_TYPE_STRING,
    },
    entryPoints: {
      ClaimSubmission:
        "EIP712Verifier.verifyClaimSubmission / EIP712Verifier.getClaimSubmissionHash",
      VerificationIntent:
        "EIP712Verifier.verifyVerificationIntent / EIP712Verifier.getVerificationIntentHash",
    },
    implementations: IMPLEMENTATION_PATHS,
    constants: {
      EIP712Domain: ethers.id(DOMAIN_TYPE_STRING),
      nameHash: ethers.id(DOMAIN_NAME),
      versionHash: ethers.id(DOMAIN_VERSION),
      ClaimSubmission: ethers.id(CLAIM_TYPE_STRING),
      VerificationIntent: ethers.id(VERIFICATION_INTENT_TYPE_STRING),
    },
    domainSeparators,
    deadlineSemantics:
      "verifyClaimSubmission/verifyVerificationIntent revert with SignatureExpired when block.timestamp > deadline; a signature valid at deadline is accepted (inclusive bound).",
    nonceSemantics:
      "nonces[account] starts at 0, is embedded in the struct hash, and increments by exactly 1 on every successful verification; a digest can never be used twice (usedSignatures).",
    positives,
    negatives,
  };
}

/** Expected Solidity constant values, derived from the vectors (never hand written). */
export function expectedConstants(doc) {
  const byId = Object.fromEntries(doc.positives.map((v) => [v.caseId, v]));
  const negById = Object.fromEntries(doc.negatives.map((v) => [v.caseId, v]));
  return {
    CHAIN_ID_MAINNET: { value: CHAIN_ID_MAINNET, kind: "uint256" },
    CHAIN_ID_LOCAL: { value: CHAIN_ID_LOCAL, kind: "uint256" },
    CHAIN_ID_WRONG: { value: CHAIN_ID_WRONG, kind: "uint256" },
    BOUNTY_ID_A: { value: CLAIM_A.bountyId, kind: "uint256" },
    BOUNTY_ID_B: { value: CLAIM_B.bountyId, kind: "uint256" },
    CLAIM_NONCE_A: { value: CLAIM_A.nonce, kind: "uint256" },
    CLAIM_NONCE_B: { value: CLAIM_B.nonce, kind: "uint256" },
    INTENT_NONCE_A: { value: INTENT_A.nonce, kind: "uint256" },
    INTENT_NONCE_B: { value: INTENT_B.nonce, kind: "uint256" },
    CANONICAL_DEADLINE: { value: CANONICAL_DEADLINE, kind: "uint256" },
    ...Object.fromEntries(doc.negatives.filter((v) => v.caseId.startsWith("intent-") && v.mustDifferFrom)
      .map((v) => [v.caseId.replaceAll("-", "_").toUpperCase() + "_DIGEST", { value: v.digest, kind: "bytes32" }])),
    VERIFYING_CONTRACT: { value: VERIFYING_CONTRACT, kind: "address" },
    CLAIMANT_A: { value: CLAIMANT_A, kind: "address" },
    CLAIMANT_B: { value: CLAIMANT_B, kind: "address" },
    VERIFIER_A: { value: VERIFIER_A, kind: "address" },
    DOMAIN_TYPE_HASH: { value: doc.constants.EIP712Domain, kind: "bytes32" },
    CLAIM_SUBMISSION_TYPE_HASH: { value: doc.constants.ClaimSubmission, kind: "bytes32" },
    VERIFICATION_INTENT_TYPE_HASH: { value: doc.constants.VerificationIntent, kind: "bytes32" },
    NAME_HASH: { value: doc.constants.nameHash, kind: "bytes32" },
    VERSION_HASH: { value: doc.constants.versionHash, kind: "bytes32" },
    DOMAIN_SEPARATOR_MAINNET: {
      value: doc.domainSeparators[String(CHAIN_ID_MAINNET)],
      kind: "bytes32",
    },
    DOMAIN_SEPARATOR_LOCAL: {
      value: doc.domainSeparators[String(CHAIN_ID_LOCAL)],
      kind: "bytes32",
    },
    CLAIM_MAINNET_STRUCT_HASH: {
      value: byId["claim-submission-mainnet"].structHash,
      kind: "bytes32",
    },
    CLAIM_LOCAL_STRUCT_HASH: { value: byId["claim-submission-local"].structHash, kind: "bytes32" },
    INTENT_MAINNET_STRUCT_HASH: {
      value: byId["verification-intent-mainnet"].structHash,
      kind: "bytes32",
    },
    INTENT_LOCAL_STRUCT_HASH: { value: byId["verification-intent-local"].structHash, kind: "bytes32" },
    CLAIM_MAINNET_DIGEST: { value: byId["claim-submission-mainnet"].digest, kind: "bytes32" },
    CLAIM_LOCAL_DIGEST: { value: byId["claim-submission-local"].digest, kind: "bytes32" },
    INTENT_MAINNET_DIGEST: { value: byId["verification-intent-mainnet"].digest, kind: "bytes32" },
    INTENT_LOCAL_DIGEST: { value: byId["verification-intent-local"].digest, kind: "bytes32" },
    CLAIM_WRONG_CHAIN_ID_DIGEST: { value: negById["claim-wrong-chain-id"].digest, kind: "bytes32" },
    CLAIM_WRONG_VERIFYING_CONTRACT_DIGEST: {
      value: negById["claim-wrong-verifying-contract"].digest,
      kind: "bytes32",
    },
    CLAIM_WRONG_DOMAIN_NAME_DIGEST: {
      value: negById["claim-wrong-domain-name"].digest,
      kind: "bytes32",
    },
    CLAIM_WRONG_NONCE_DIGEST: { value: negById["claim-wrong-nonce"].digest, kind: "bytes32" },
    CLAIM_WRONG_DEADLINE_DIGEST: { value: negById["claim-wrong-deadline"].digest, kind: "bytes32" },
    CLAIM_MUTATED_FIELD_ORDER_DIGEST: {
      value: negById["claim-mutated-field-order"].digest,
      kind: "bytes32",
    },
    CLAIM_MUTATED_TYPE_STRING_DIGEST: {
      value: negById["claim-mutated-type-string"].digest,
      kind: "bytes32",
    },
    CLAIM_MUTATED_FIELD_ORDER_STRUCT_HASH: {
      value: negById["claim-mutated-field-order"].structHash,
      kind: "bytes32",
    },
    CLAIM_MUTATED_TYPE_STRING_STRUCT_HASH: {
      value: negById["claim-mutated-type-string"].structHash,
      kind: "bytes32",
    },
    WRONG_VERIFYING_CONTRACT: { value: WRONG_VERIFYING_CONTRACT, kind: "address" },
    DOMAIN_TYPE_STRING: { value: DOMAIN_TYPE_STRING, kind: "string" },
    CLAIM_TYPE_STRING: { value: CLAIM_TYPE_STRING, kind: "string" },
    VERIFICATION_INTENT_TYPE_STRING: { value: VERIFICATION_INTENT_TYPE_STRING, kind: "string" },
    MUTATED_CLAIM_TYPE_STRING: { value: MUTATED_CLAIM_TYPE_STRING, kind: "string" },
    CLAIM_A_CONTENT: { value: CLAIM_A_CONTENT, kind: "string" },
    CLAIM_B_CONTENT: { value: CLAIM_B_CONTENT, kind: "string" },
    INTENT_A_REASON: { value: INTENT_A_REASON, kind: "string" },
    INTENT_B_REASON: { value: INTENT_B_REASON, kind: "string" },
  };
}

/**
 * Parse the constant surface of the Solidity mirror:
 *   bytes32 internal constant NAME = 0x...;
 *   address internal constant NAME = 0x...;
 *   string  internal constant NAME = "...";
 */
export function extractConstants(soliditySource) {
  const found = {};
  const re =
    /(?:bytes32|address|string|uint256)\s+internal\s+constant\s+(\w+)\s*=\s*(0x[0-9a-fA-F]+|[0-9]+|"[^"]*")\s*;/g;
  let match;
  while ((match = re.exec(soliditySource)) !== null) {
    found[match[1]] = match[2].startsWith('"') ? match[2].slice(1, -1) : match[2];
  }
  return found;
}

/** Compare a Solidity constants mirror against expected values; returns actionable problems. */
export function compareConstants(soliditySource, expected) {
  const found = extractConstants(soliditySource);
  const problems = [];
  const normalise = (value, kind) => {
    if (kind === "uint256") return String(value);
    if (kind === "string") return value;
    if (kind !== "address") return value.toLowerCase();
    try {
      return ethers.getAddress(value.toLowerCase());
    } catch {
      return value.toLowerCase();
    }
  };
  for (const [name, spec] of Object.entries(expected)) {
    const want = normalise(spec.value, spec.kind);
    const have = found[name];
    if (have === undefined) {
      problems.push(`missing constant ${name} (expected ${want})`);
      continue;
    }
    const got = normalise(have, spec.kind);
    if (got !== want) {
      problems.push(`constant ${name}\n    expected ${want}\n    found    ${got}`);
    }
  }
  for (const name of Object.keys(found)) {
    if (!(name in expected)) {
      problems.push(`unexpected constant ${name} in the mirror (not part of ${SUITE})`);
    }
  }
  return problems;
}

/** Every implementation must literally contain the canonical type strings and field order. */
export function compareImplementations(sources) {
  const problems = [];
  for (const [path, source] of Object.entries(sources)) {
    const code = source.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, "");
    for (const [label, typeString] of [
      ["_DOMAIN_TYPE_HASH", DOMAIN_TYPE_STRING],
      ["CLAIM_SUBMISSION_TYPEHASH", CLAIM_TYPE_STRING],
      ["VERIFICATION_INTENT_TYPEHASH", VERIFICATION_INTENT_TYPE_STRING],
    ]) {
      const declaration = code.match(new RegExp(`bytes32\\s+(?:private|public|internal)\\s+constant\\s+${label}\\s*=\\s*keccak256\\(\\s*"([^"]*)"\\s*\\)\\s*;`));
      if (declaration?.[1] !== typeString) {
        problems.push(
          `${path} does not declare the canonical ${label} type string\n    expected "${typeString}"; found ${declaration ? JSON.stringify(declaration[1]) : "missing keccak256 declaration"}`
        );
      }
    }
    if (!source.includes("nonces[") || !source.includes("usedSignatures[")) {
      problems.push(`${path} is missing the nonce/used-signature replay state`);
    }
  }
  return problems;
}

/** Deep comparison of two vector documents with a readable expected/found diff. */
export function compareDocuments(expected, actual, prefix = "") {
  const problems = [];
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || actual.length !== expected.length) {
      problems.push(`${prefix}: length ${actual?.length ?? "n/a"} != expected ${expected.length}`);
      return problems;
    }
    expected.forEach((item, i) => problems.push(...compareDocuments(item, actual[i], `${prefix}[${i}]`)));
    return problems;
  }
  if (expected !== null && typeof expected === "object") {
    if (actual === null || typeof actual !== "object") {
      problems.push(`${prefix}: expected object, found ${JSON.stringify(actual)}`);
      return problems;
    }
    for (const key of new Set([...Object.keys(expected), ...Object.keys(actual)])) {
      if (!(key in actual)) {
        problems.push(`${prefix}.${key}: missing (expected ${JSON.stringify(expected[key])})`);
        continue;
      }
      if (!(key in expected)) {
        problems.push(`${prefix}.${key}: unexpected key (found ${JSON.stringify(actual[key])})`);
        continue;
      }
      problems.push(...compareDocuments(expected[key], actual[key], `${prefix}.${key}`));
    }
    return problems;
  }
  if (expected !== actual) {
    problems.push(`${prefix}: expected ${JSON.stringify(expected)}\n    found    ${JSON.stringify(actual)}`);
  }
  return problems;
}

/** A signature over a vector digest must recover to the signing wallet (no key is stored). */
export async function checkSignatureRecovery(domain, primaryType, message, expectedDigest) {
  const wallet = ethers.Wallet.createRandom();
  const selectedTypes = typesFor(primaryType);
  const signature = await wallet.signTypedData(domain, selectedTypes, message);
  const recovered = ethers.recoverAddress(expectedDigest, signature);
  if (recovered !== wallet.address) {
    throw new Error(
      `signature recovery drift: recovered ${recovered} but signed by ${wallet.address}`
    );
  }
  const viaTypes = ethers.verifyTypedData(domain, selectedTypes, message, signature);
  if (viaTypes !== wallet.address) {
    throw new Error(`verifyTypedData drift: ${viaTypes} != ${wallet.address}`);
  }
}

function readImplSources(root = REPO_ROOT) {
  const sources = {};
  for (const path of IMPLEMENTATION_PATHS) {
    sources[path] = readFileSync(resolve(root, path), "utf8");
  }
  return sources;
}

export async function runCheck(root = REPO_ROOT) {
  const expected = await buildVectors();
  const problems = [];

  const actual = JSON.parse(readFileSync(resolve(root, "test/vectors/eip712-verifier.vectors.json"), "utf8"));
  problems.push(...compareDocuments(expected, actual, "test/vectors/eip712-verifier.vectors.json"));

  const solidity = readFileSync(resolve(root, "contracts/test/EIP712CanonicalVectors.sol"), "utf8");
  problems.push(...compareConstants(solidity, expectedConstants(expected)).map((p) => `contracts/test/EIP712CanonicalVectors.sol: ${p}`));
  problems.push(...compareDocumentation(readFileSync(resolve(root, "docs/EIP712_SIGNING.md"), "utf8"), expected));
  problems.push(...compareImplementations(readImplSources(root)));

  if (problems.length > 0) {
    console.error(`EIP-712 drift detected (${problems.length} difference(s)):\n`);
    for (const problem of problems) console.error(`  - ${problem}`);
    console.error(
      "\nRegenerate with `node scripts/check-eip712-vectors.mjs --emit`, after reviewing the canonical source; JSON and Solidity mirror are regenerated together."
    );
    throw new Error("EIP-712 canonical vectors are out of date");
  }

  const mainnetDomain = domainFor(CHAIN_ID_MAINNET);
  await checkSignatureRecovery(mainnetDomain, "ClaimSubmission", CLAIM_A, expected.positives[0].digest);
  await checkSignatureRecovery(
    domainFor(CHAIN_ID_LOCAL),
    "VerificationIntent",
    INTENT_B,
    expected.positives[3].digest
  );

  return expected;
}

/** Render the entire mirror from canonical inputs, including numeric payload fields. */
export function renderConstants(doc) {
  const lines = Object.entries(expectedConstants(doc)).map(([name, { kind, value }]) =>
    `    ${kind} internal constant ${name} = ${kind === "string" ? JSON.stringify(value) : value};`);
  return `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test-only mirror of test/vectors/eip712-verifier.vectors.json.
/// @dev Generated by node scripts/check-eip712-vectors.mjs --emit. Do not edit.
library EIP712CanonicalVectors {
${lines.join("\n")}

    function claimAContentHash() internal pure returns (bytes32) {
        return keccak256(bytes(CLAIM_A_CONTENT));
    }

    function claimBContentHash() internal pure returns (bytes32) {
        return keccak256(bytes(CLAIM_B_CONTENT));
    }
}
`;
}

export function compareDocumentation(source, doc) {
  const row = `| \`VerificationIntent\` | \`${doc.typeStrings.VerificationIntent}\` | \`${doc.constants.VerificationIntent}\` |`;
  return source.includes(row) ? [] : [
    `docs/EIP712_SIGNING.md: VerificationIntent row drift; expected ${row}`,
  ];
}

export async function emitVectors(root = REPO_ROOT) {
  const problems = compareImplementations(readImplSources(root));
  if (problems.length) throw new Error(problems.join("\n"));
  const doc = await buildVectors();
  writeFileSync(resolve(root, "test/vectors/eip712-verifier.vectors.json"), `${JSON.stringify(doc, null, 2)}\n`);
  writeFileSync(resolve(root, "contracts/test/EIP712CanonicalVectors.sol"), renderConstants(doc));
  return doc;
}

const isDirectRun =
  process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));

if (isDirectRun) {
  (process.argv.includes("--emit") ? emitVectors() : runCheck())
    .then((doc) => console.log(
      `EIP-712 vectors OK: ${doc.positives.length} positive, ${doc.negatives.length} negative, ${IMPLEMENTATION_PATHS.length} implementations verified`
    ))
    .catch((error) => {
      console.error(`scripts/check-eip712-vectors.mjs: ${error.message}`);
      process.exitCode = 1;
    });
}
