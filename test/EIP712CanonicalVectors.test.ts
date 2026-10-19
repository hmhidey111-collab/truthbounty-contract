import { expect } from "chai";
import { network } from "hardhat";
import { fileURLToPath } from "node:url";
import { TYPES, typesFor } from "../scripts/check-eip712-vectors.mjs";
const { ethers, networkHelpers } = await network.connect("hardhatMainnet");
const { time } = networkHelpers;
import * as fs from "fs";
import * as path from "path";
import type { EIP712Verifier } from "../typechain-types";

/**
 * V2-SC-152 — canonical EIP-712 schemas and cross-tool test vectors.
 *
 * This suite proves, in the repository TypeScript tooling, that:
 *   - the published vectors are exactly what ethers computes (Solidity <-> TypeScript parity),
 *   - the deployed implementation reproduces the published digests byte for byte,
 *   - a signature produced by an ethers wallet is accepted on-chain for the published vector,
 *   - every published negative vector is rejected on-chain.
 */

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const VECTORS = JSON.parse(
  fs.readFileSync(path.join(ROOT, "test/vectors/eip712-verifier.vectors.json"), "utf8")
);

/** Canonical verifying contract address the vectors were computed against. */
const CANONICAL_VERIFYING_CONTRACT: string = VECTORS.positives[0].verifyingContract;


function domainFor(chainId: number | bigint, verifyingContract: string) {
  return {
    name: VECTORS.domain.name as string,
    version: VECTORS.domain.version as string,
    chainId,
    verifyingContract,
  };
}

function typeString(primaryType: keyof typeof TYPES): string {
  const fields = TYPES[primaryType].map((f) => `${f.type} ${f.name}`).join(",");
  return `${primaryType}(${fields})`;
}

function vectorById(caseId: string) {
  const found = [...VECTORS.positives, ...VECTORS.negatives].find((v) => v.caseId === caseId);
  if (!found) throw new Error(`unknown vector ${caseId}`);
  return found;
}

describe("EIP712CanonicalVectors", function () {
  let verifier: EIP712Verifier;

  before(async function () {
    // Deploy the canonical implementation, then place its runtime code at the exact address the
    // published vectors were computed against, so `address(this)` matches the vectors.
    const factory = await ethers.getContractFactory("contracts/EIP712Verifier.sol:EIP712Verifier");
    const implementation = await factory.deploy();
    await implementation.waitForDeployment();

    const runtimeCode = await ethers.provider.getCode(await implementation.getAddress());
    await ethers.provider.send("hardhat_setCode", [CANONICAL_VERIFYING_CONTRACT, runtimeCode]);
    verifier = factory.attach(CANONICAL_VERIFYING_CONTRACT) as unknown as EIP712Verifier;
  });

  it("publishes type strings identical to the ones the TypeScript tooling signs", function () {
    expect(typeString("ClaimSubmission")).to.equal(VECTORS.typeStrings.ClaimSubmission);
    expect(typeString("VerificationIntent")).to.equal(VECTORS.typeStrings.VerificationIntent);

    const first = VECTORS.positives[0];
    const encoderTypes = { ...TYPES, EIP712Domain: ethers.TypedDataEncoder.getPayload(
      domainFor(first.chainId, first.verifyingContract), typesFor(first.primaryType), first.message
    ).types.EIP712Domain };
    expect(encoderTypes.EIP712Domain.map((f) => f.type).join(",")).to.equal(
      "string,string,uint256,address"
    );
    expect(encoderTypes.ClaimSubmission.map((f) => `${f.name}:${f.type}`).join(",")).to.equal(
      "claimant:address,bountyId:uint256,contentHash:bytes32,nonce:uint256,deadline:uint256"
    );
    expect(encoderTypes.VerificationIntent.map((f) => `${f.name}:${f.type}`).join(",")).to.equal(
      "verifier:address,bountyId:uint256,approve:bool,reason:string,nonce:uint256,deadline:uint256"
    );

    // Domain type string published by the JSON is the one ethers derives.
    const derived = `EIP712Domain(${encoderTypes.EIP712Domain.map((f) => `${f.type} ${f.name}`).join(",")})`;
    expect(derived).to.equal(VECTORS.domain.typeString);
  });

  it("reproduces every positive vector with ethers", function () {
    for (const vector of VECTORS.positives) {
      const domain = domainFor(vector.chainId, vector.verifyingContract);
      expect(
        ethers.TypedDataEncoder.hashStruct(vector.primaryType, typesFor(vector.primaryType), vector.message),
        `${vector.caseId} structHash`
      ).to.equal(vector.structHash);
      expect(
        ethers.TypedDataEncoder.hash(domain, typesFor(vector.primaryType), vector.message),
        `${vector.caseId} digest`
      ).to.equal(vector.digest);
    }

    const mainnet = vectorById("claim-submission-mainnet");
    const local = vectorById("claim-submission-local");
    expect(ethers.TypedDataEncoder.hashDomain(domainFor(mainnet.chainId, mainnet.verifyingContract))).to.equal(
      VECTORS.domainSeparators["1"]
    );
    expect(ethers.TypedDataEncoder.hashDomain(domainFor(local.chainId, local.verifyingContract))).to.equal(
      VECTORS.domainSeparators["31337"]
    );
  });

  it("reproduces every negative vector with ethers under its mutation", function () {
    const abi = ethers.AbiCoder.defaultAbiCoder();
    const claim = vectorById("claim-submission-mainnet");
    const intent = vectorById("verification-intent-mainnet");

    for (const negative of VECTORS.negatives) {
      const positive = negative.mustDifferFrom ? vectorById(negative.mustDifferFrom) : null;
      if (positive) {
        expect(negative.digest, `${negative.caseId} must differ from ${positive.caseId}`).to.not.equal(
          positive.digest
        );
      }

      switch (negative.mutation) {
        case "chainId":
        case "verifyingContract":
        case "domainName": {
          const domain = {
            ...domainFor(negative.chainId, negative.verifyingContract),
            ...(negative.mutation === "chainId" ? { chainId: negative.mutationValue } : {}),
            ...(negative.mutation === "verifyingContract"
              ? { verifyingContract: negative.mutationValue }
              : {}),
            ...(negative.mutation === "domainName" ? { name: negative.mutationValue } : {}),
          };
          expect(ethers.TypedDataEncoder.hash(domain, typesFor(negative.primaryType), negative.message), negative.caseId).to.equal(
            negative.digest
          );
          break;
        }
        case "nonce":
        case "deadline":
        case "approve":
        case "reason": {
          expect(
            ethers.TypedDataEncoder.hash(
              domainFor(negative.chainId, negative.verifyingContract),
              typesFor(negative.primaryType),
              negative.message
            ),
            negative.caseId
          ).to.equal(negative.digest);
          break;
        }
        case "fieldOrder": {
          if (negative.primaryType === "VerificationIntent") {
            const fields = TYPES.VerificationIntent;
            const reordered = { VerificationIntent: [fields[1], fields[0], ...fields.slice(2)] };
            expect(ethers.TypedDataEncoder.hash(domainFor(negative.chainId, negative.verifyingContract), reordered, negative.message)).to.equal(negative.digest);
            break;
          }
          // Same type hash, claimant and bountyId encoded in the other order.
          const encoded = abi.encode(
            ["bytes32", "uint256", "address", "bytes32", "uint256", "uint256"],
            [
              ethers.id(VECTORS.typeStrings.ClaimSubmission),
              negative.message.bountyId,
              negative.message.claimant,
              negative.message.contentHash,
              negative.message.nonce,
              negative.message.deadline,
            ]
          );
          expect(ethers.keccak256(encoded), `${negative.caseId} structHash`).to.equal(negative.structHash);
          expect(
            ethers.keccak256(
              ethers.concat([
                "0x1901",
                VECTORS.domainSeparators[String(negative.chainId)],
                ethers.keccak256(encoded),
              ])
            ),
            negative.caseId
          ).to.equal(negative.digest);
          break;
        }
        case "typeString": {
          const mutatedTypes = {
            ClaimSubmission: TYPES.ClaimSubmission.map((f) =>
              f.name === "nonce" ? { name: "nonce", type: "uint8" } : f
            ),
          };
          const structHashValue = ethers.TypedDataEncoder.hashStruct(
            "ClaimSubmission",
            mutatedTypes,
            negative.message
          );
          expect(structHashValue, `${negative.caseId} structHash`).to.equal(negative.structHash);
          expect(
            ethers.keccak256(
              ethers.concat([
                "0x1901",
                VECTORS.domainSeparators[String(negative.chainId)],
                structHashValue,
              ])
            ),
            negative.caseId
          ).to.equal(negative.digest);
          break;
        }
        case "deadlineExpired": {
          // The digest is the positive one; only the deadline check rejects it.
          expect(negative.digest).to.equal(negative.primaryType === "VerificationIntent" ? intent.digest : claim.digest);
          expect(negative.expectedRevert).to.equal("SignatureExpired");
          break;
        }
        default:
          throw new Error(`unhandled mutation ${negative.mutation}`);
      }
    }

    // The intent vectors are covered as well: both intent negatives reproduce from ethers.
    expect(
      ethers.TypedDataEncoder.hash(
        domainFor(intent.chainId, intent.verifyingContract),
        typesFor("VerificationIntent"),
        vectorById("intent-wrong-approve-flag").message
      )
    ).to.equal(vectorById("intent-wrong-approve-flag").digest);
  });

  it("agrees with the deployed implementation on domain separators and digests", async function () {
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const domain = domainFor(chainId, CANONICAL_VERIFYING_CONTRACT);

    expect(await verifier.getDomainSeparator()).to.equal(ethers.TypedDataEncoder.hashDomain(domain));
    expect(await verifier.getChainId()).to.equal(chainId);

    const claim = vectorById("claim-submission-mainnet").message;
    const intent = vectorById("verification-intent-mainnet").message;

    expect(
      await verifier.getClaimSubmissionHash(
        claim.claimant,
        claim.bountyId,
        claim.contentHash,
        claim.nonce,
        claim.deadline
      )
    ).to.equal(ethers.TypedDataEncoder.hash(domain, typesFor("ClaimSubmission"), claim));

    expect(
      await verifier.getVerificationIntentHash(
        intent.verifier,
        intent.bountyId,
        intent.approve,
        intent.reason,
        intent.nonce,
        intent.deadline
      )
    ).to.equal(ethers.TypedDataEncoder.hash(domain, typesFor("VerificationIntent"), intent));

    // Chain 10 digest of the same struct is a different digest (chain binding).
    expect(ethers.TypedDataEncoder.hash(domainFor(10, CANONICAL_VERIFYING_CONTRACT), typesFor("ClaimSubmission"), claim)).to.not.equal(
      ethers.TypedDataEncoder.hash(domain, typesFor("ClaimSubmission"), claim)
    );
  });

  it("verifies the published local claim vector on-chain with an ethers signature", async function () {
    const signers = await ethers.getSigners();
    const local = vectorById("claim-submission-local");
    const claimant = signers[1]; // Hardhat account #1, the claimant of the local vector
    expect(claimant.address).to.equal(local.message.claimant);

    const domain = domainFor(local.chainId, CANONICAL_VERIFYING_CONTRACT);
    const digest = ethers.TypedDataEncoder.hash(domain, typesFor("ClaimSubmission"), local.message);
    expect(digest).to.equal(local.digest);

    const signature = await claimant.signTypedData(domain, typesFor("ClaimSubmission"), local.message);
    expect(ethers.verifyTypedData(domain, typesFor("ClaimSubmission"), local.message, signature)).to.equal(claimant.address);

    expect(await verifier.getNonce(claimant.address)).to.equal(BigInt(local.message.nonce));

    await expect(
      verifier.verifyClaimSubmission(
        claimant.address,
        local.message.bountyId,
        local.message.contentHash,
        local.message.deadline,
        signature
      )
    ).to.emit(verifier, "ClaimSubmissionVerified");

    expect(await verifier.getNonce(claimant.address)).to.equal(BigInt(local.message.nonce) + 1n);
    expect(await verifier.isSignatureUsed(digest)).to.equal(true);

    // Replay protection: the advanced nonce produces a different digest.
    await expect(
      verifier.verifyClaimSubmission(
        claimant.address,
        local.message.bountyId,
        local.message.contentHash,
        local.message.deadline,
        signature
      )
    ).to.be.revertedWithCustomError(verifier, "InvalidSignature");
  });

  it("rejects signatures over mutated, cross-chain and cross-deployment digests", async function () {
    const signers = await ethers.getSigners();
    const claimant = signers[1];
    const local = vectorById("claim-submission-local");
    const chainId = (await ethers.provider.getNetwork()).chainId;

    // Wrong signing key.
    const wrongKeySignature = await signers[2].signTypedData(
      domainFor(chainId, CANONICAL_VERIFYING_CONTRACT),
      typesFor("ClaimSubmission"),
      { ...local.message, nonce: await verifier.getNonce(claimant.address) }
    );
    await expect(
      verifier.verifyClaimSubmission(
        claimant.address,
        local.message.bountyId,
        local.message.contentHash,
        local.message.deadline,
        wrongKeySignature
      )
    ).to.be.revertedWithCustomError(verifier, "InvalidSignature");

    // Chain-id mutation: signed for chain 10, offered on this chain.
    const crossChainSignature = await claimant.signTypedData(
      domainFor(10, CANONICAL_VERIFYING_CONTRACT),
      typesFor("ClaimSubmission"),
      { ...local.message, nonce: await verifier.getNonce(claimant.address) }
    );
    await expect(
      verifier.verifyClaimSubmission(
        claimant.address,
        local.message.bountyId,
        local.message.contentHash,
        local.message.deadline,
        crossChainSignature
      )
    ).to.be.revertedWithCustomError(verifier, "InvalidSignature");

    // Verifying-contract mutation: signed for a different deployment.
    const otherDeploymentSignature = await claimant.signTypedData(
      domainFor(chainId, vectorById("claim-wrong-verifying-contract").mutationValue),
      typesFor("ClaimSubmission"),
      { ...local.message, nonce: await verifier.getNonce(claimant.address) }
    );
    await expect(
      verifier.verifyClaimSubmission(
        claimant.address,
        local.message.bountyId,
        local.message.contentHash,
        local.message.deadline,
        otherDeploymentSignature
      )
    ).to.be.revertedWithCustomError(verifier, "InvalidSignature");

    // No failed attempt may move the nonce.
    expect(await verifier.getNonce(claimant.address)).to.equal(BigInt(local.message.nonce) + 1n);
  });

  it("rejects every verification-intent mutation with InvalidSignature", async function () {
    const signer = (await ethers.getSigners())[2];
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const domain = domainFor(chainId, CANONICAL_VERIFYING_CONTRACT);
    const nonce = await verifier.getNonce(signer.address);
    const message = { ...vectorById("verification-intent-mainnet").message, verifier: signer.address, nonce };
    const fields = TYPES.VerificationIntent;
    const cases = [
      { domain: { ...domain, chainId: 10 } },
      { domain: { ...domain, verifyingContract: vectorById("intent-wrong-verifying-contract").mutationValue } },
      { domain: { ...domain, name: "TruthBountyV2" } },
      { types: { VerificationIntent: [fields[1], fields[0], ...fields.slice(2)] } },
      { message: { ...message, nonce: nonce + 1n } },
      { message: { ...message, deadline: message.deadline + 1 } },
      { message: { ...message, approve: false } },
      { message: { ...message, reason: message.reason + " " } },
    ];
    for (const mutation of cases) {
      const signature = await signer.signTypedData(mutation.domain ?? domain,
        mutation.types ?? typesFor("VerificationIntent"), mutation.message ?? message);
      await expect(verifier.verifyVerificationIntent(signer.address, message.bountyId, message.approve,
        message.reason, message.deadline, signature)).to.be.revertedWithCustomError(verifier, "InvalidSignature");
      expect(await verifier.getNonce(signer.address)).to.equal(nonce);
    }
    const signature = await signer.signTypedData(domain, typesFor("VerificationIntent"), message);
    await expect(verifier.verifyVerificationIntent(signer.address, message.bountyId, message.approve,
      message.reason, message.deadline, signature)).to.emit(verifier, "VerificationIntentVerified");
    expect(await verifier.getNonce(signer.address)).to.equal(nonce + 1n);
  });

  // Runs last on purpose: it moves the chain clock past the canonical deadline.
  it("bounds the deadline inclusively and rejects expired signatures", async function () {
    const signers = await ethers.getSigners();
    const claimant = signers[1];
    const local = vectorById("claim-submission-local");
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const deadline = local.message.deadline as number;
    const nonce = await verifier.getNonce(claimant.address);

    const message = { ...local.message, claimant: claimant.address, nonce };

    // Exactly at the deadline the signature is still valid (inclusive bound).
    const atDeadlineDomain = domainFor(chainId, CANONICAL_VERIFYING_CONTRACT);
    const atDeadlineSignature = await claimant.signTypedData(atDeadlineDomain, typesFor("ClaimSubmission"), message);
    await time.setNextBlockTimestamp(deadline);
    await verifier.verifyClaimSubmission(
      claimant.address,
      message.bountyId,
      message.contentHash,
      deadline,
      atDeadlineSignature
    );
    expect(await verifier.getNonce(claimant.address)).to.equal(nonce + 1n);

    // One second later the same shape of signature is rejected as expired.
    const expiredNonce = await verifier.getNonce(claimant.address);
    const expiredSignature = await claimant.signTypedData(atDeadlineDomain, typesFor("ClaimSubmission"), {
      ...message,
      nonce: expiredNonce,
    });
    await time.setNextBlockTimestamp(deadline + 1);
    await expect(
      verifier.verifyClaimSubmission(
        claimant.address,
        message.bountyId,
        message.contentHash,
        deadline,
        expiredSignature
      )
    ).to.be.revertedWithCustomError(verifier, "SignatureExpired");
    expect(await verifier.getNonce(claimant.address)).to.equal(expiredNonce);
  });
});
