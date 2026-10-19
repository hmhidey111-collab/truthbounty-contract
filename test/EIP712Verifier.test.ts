import { expect } from "chai";
import { ethers } from "hardhat";
import { EIP712Verifier } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("EIP712Verifier", function () {
  let verifier: EIP712Verifier;
  let owner: SignerWithAddress;
  let claimant: SignerWithAddress;
  let verifierSigner: SignerWithAddress;

  const DOMAIN_NAME = "TruthBounty";
  const DOMAIN_VERSION = "1";

  beforeEach(async function () {
    [owner, claimant, verifierSigner] = await ethers.getSigners();

    const EIP712Verifier = await ethers.getContractFactory("contracts/decay.sol:EIP712Verifier");
    verifier = await EIP712Verifier.deploy();
    await verifier.waitForDeployment();
  });

  describe("Domain Separator", function () {
    it("should return a valid domain separator", async function () {
      const domainSeparator = await verifier.getDomainSeparator();
      expect(domainSeparator).to.not.equal(ethers.ZeroHash);
    });

    it("bounds verification reason hashing and rejects oversized signatures", async function () {
      const deadline = BigInt(await time.latest() + 3600);
      const maximumReason = "r".repeat(256);

      const digest = await verifier.getVerificationIntentHash(
        verifierSigner.address,
        1,
        true,
        maximumReason,
        0,
        deadline,
      );
      expect(digest).to.not.equal(ethers.ZeroHash);

      await expect(
        verifier.getVerificationIntentHash(
          verifierSigner.address,
          1,
          true,
          "r".repeat(257),
          0,
          deadline,
        ),
      )
        .to.be.revertedWithCustomError(verifier, "ReasonTooLong")
        .withArgs(257, 256);

      await expect(
        verifier.verifyClaimSubmission(
          claimant.address,
          1,
          ethers.ZeroHash,
          deadline,
          `0x${"11".repeat(66)}`,
        ),
      ).to.be.revertedWithCustomError(verifier, "InvalidSignature");
    });
  });

  describe("Claim Submission Signing", function () {
    it("should verify a valid claim submission signature", async function () {
      const bountyId = 1n;
      const contentHash = ethers.keccak256(ethers.toUtf8Bytes("claim content"));
      const nonce = await verifier.getNonce(claimant.address);
      const deadline = BigInt(await time.latest() + 3600); // 1 hour from now

      const domain = {
        name: DOMAIN_NAME,
        version: DOMAIN_VERSION,
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await verifier.getAddress(),
      };

      const types = {
        ClaimSubmission: [
          { name: "claimant", type: "address" },
          { name: "bountyId", type: "uint256" },
          { name: "contentHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };

      const value = {
        claimant: claimant.address,
        bountyId,
        contentHash,
        nonce,
        deadline,
      };

      const signature = await claimant.signTypedData(domain, types, value);

      await expect(
        verifier.verifyClaimSubmission(
          claimant.address,
          bountyId,
          contentHash,
          deadline,
          signature
        )
      )
        .to.emit(verifier, "ClaimSubmissionVerified")
        .withArgs(claimant.address, bountyId, contentHash, nonce);
    });

    it("should reject an invalid signature", async function () {
      const bountyId = 1n;
      const contentHash = ethers.keccak256(ethers.toUtf8Bytes("claim content"));
      const deadline = BigInt(await time.latest() + 3600);

      // Sign with wrong signer
      const domain = {
        name: DOMAIN_NAME,
        version: DOMAIN_VERSION,
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await verifier.getAddress(),
      };

      const types = {
        ClaimSubmission: [
          { name: "claimant", type: "address" },
          { name: "bountyId", type: "uint256" },
          { name: "contentHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };

      const value = {
        claimant: claimant.address,
        bountyId,
        contentHash,
        nonce: 0n,
        deadline,
      };

      // Sign with owner instead of claimant
      const signature = await owner.signTypedData(domain, types, value);

      await expect(
        verifier.verifyClaimSubmission(
          claimant.address,
          bountyId,
          contentHash,
          deadline,
          signature
        )
      ).to.be.revertedWithCustomError(verifier, "InvalidSignature");
    });

    it("should reject expired signature", async function () {
      const bountyId = 1n;
      const contentHash = ethers.keccak256(ethers.toUtf8Bytes("claim content"));
      const deadline = BigInt(await time.latest() - 3600); // 1 hour ago

      const domain = {
        name: DOMAIN_NAME,
        version: DOMAIN_VERSION,
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await verifier.getAddress(),
      };

      const types = {
        ClaimSubmission: [
          { name: "claimant", type: "address" },
          { name: "bountyId", type: "uint256" },
          { name: "contentHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };

      const value = {
        claimant: claimant.address,
        bountyId,
        contentHash,
        nonce: 0n,
        deadline,
      };

      const signature = await claimant.signTypedData(domain, types, value);

      await expect(
        verifier.verifyClaimSubmission(
          claimant.address,
          bountyId,
          contentHash,
          deadline,
          signature
        )
      ).to.be.revertedWithCustomError(verifier, "SignatureExpired");
    });

    it("should reject replay attacks (same signature twice)", async function () {
      const bountyId = 1n;
      const contentHash = ethers.keccak256(ethers.toUtf8Bytes("claim content"));
      const nonce = await verifier.getNonce(claimant.address);
      const deadline = BigInt(await time.latest() + 3600);

      const domain = {
        name: DOMAIN_NAME,
        version: DOMAIN_VERSION,
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await verifier.getAddress(),
      };

      const types = {
        ClaimSubmission: [
          { name: "claimant", type: "address" },
          { name: "bountyId", type: "uint256" },
          { name: "contentHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };

      const value = {
        claimant: claimant.address,
        bountyId,
        contentHash,
        nonce,
        deadline,
      };

      const signature = await claimant.signTypedData(domain, types, value);

      // First verification should succeed
      await verifier.verifyClaimSubmission(
        claimant.address,
        bountyId,
        contentHash,
        deadline,
        signature
      );

      // Second verification with same signature should fail
      await expect(
        verifier.verifyClaimSubmission(
          claimant.address,
          bountyId,
          contentHash,
          deadline,
          signature
        )
      ).to.be.revertedWithCustomError(verifier, "InvalidSignature");
    });

    it("should increment nonce after verification", async function () {
      const bountyId = 1n;
      const contentHash = ethers.keccak256(ethers.toUtf8Bytes("claim content"));
      const nonceBefore = await verifier.getNonce(claimant.address);
      const deadline = BigInt(await time.latest() + 3600);

      const domain = {
        name: DOMAIN_NAME,
        version: DOMAIN_VERSION,
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await verifier.getAddress(),
      };

      const types = {
        ClaimSubmission: [
          { name: "claimant", type: "address" },
          { name: "bountyId", type: "uint256" },
          { name: "contentHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };

      const value = {
        claimant: claimant.address,
        bountyId,
        contentHash,
        nonce: nonceBefore,
        deadline,
      };

      const signature = await claimant.signTypedData(domain, types, value);

      await verifier.verifyClaimSubmission(
        claimant.address,
        bountyId,
        contentHash,
        deadline,
        signature
      );

      const nonceAfter = await verifier.getNonce(claimant.address);
      expect(nonceAfter).to.equal(nonceBefore + 1n);
    });
  });

  describe("Verification Intent Signing", function () {
    it("should verify a valid verification intent signature", async function () {
      const bountyId = 1n;
      const approve = true;
      const reason = "Valid claim with sufficient evidence";
      const nonce = await verifier.getNonce(verifierSigner.address);
      const deadline = BigInt(await time.latest() + 3600);

      const domain = {
        name: DOMAIN_NAME,
        version: DOMAIN_VERSION,
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await verifier.getAddress(),
      };

      const types = {
        VerificationIntent: [
          { name: "verifier", type: "address" },
          { name: "bountyId", type: "uint256" },
          { name: "approve", type: "bool" },
          { name: "reason", type: "string" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };

      const value = {
        verifier: verifierSigner.address,
        bountyId,
        approve,
        reason,
        nonce,
        deadline,
      };

      const signature = await verifierSigner.signTypedData(domain, types, value);

      await expect(
        verifier.verifyVerificationIntent(
          verifierSigner.address,
          bountyId,
          approve,
          reason,
          deadline,
          signature
        )
      )
        .to.emit(verifier, "VerificationIntentVerified")
        .withArgs(verifierSigner.address, bountyId, approve, nonce);
    });

    it("should reject invalid verification intent signature", async function () {
      const bountyId = 1n;
      const approve = true;
      const reason = "Valid claim";
      const deadline = BigInt(await time.latest() + 3600);

      const domain = {
        name: DOMAIN_NAME,
        version: DOMAIN_VERSION,
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await verifier.getAddress(),
      };

      const types = {
        VerificationIntent: [
          { name: "verifier", type: "address" },
          { name: "bountyId", type: "uint256" },
          { name: "approve", type: "bool" },
          { name: "reason", type: "string" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };

      const value = {
        verifier: verifierSigner.address,
        bountyId,
        approve,
        reason,
        nonce: 0n,
        deadline,
      };

      // Sign with wrong signer
      const signature = await owner.signTypedData(domain, types, value);

      await expect(
        verifier.verifyVerificationIntent(
          verifierSigner.address,
          bountyId,
          approve,
          reason,
          deadline,
          signature
        )
      ).to.be.revertedWithCustomError(verifier, "InvalidSignature");
    });
  });

  describe("Hash Generation", function () {
    it("should generate consistent claim submission hashes", async function () {
      const claimantAddr = claimant.address;
      const bountyId = 1n;
      const contentHash = ethers.keccak256(ethers.toUtf8Bytes("test"));
      const nonce = 0n;
      const deadline = BigInt(await time.latest() + 3600);

      const hash1 = await verifier.getClaimSubmissionHash(
        claimantAddr,
        bountyId,
        contentHash,
        nonce,
        deadline
      );

      const hash2 = await verifier.getClaimSubmissionHash(
        claimantAddr,
        bountyId,
        contentHash,
        nonce,
        deadline
      );

      expect(hash1).to.equal(hash2);
    });

    it("should generate different hashes for different inputs", async function () {
      const claimantAddr = claimant.address;
      const contentHash = ethers.keccak256(ethers.toUtf8Bytes("test"));
      const nonce = 0n;
      const deadline = BigInt(await time.latest() + 3600);

      const hash1 = await verifier.getClaimSubmissionHash(
        claimantAddr,
        1n,
        contentHash,
        nonce,
        deadline
      );

      const hash2 = await verifier.getClaimSubmissionHash(
        claimantAddr,
        2n,
        contentHash,
        nonce,
        deadline
      );

      expect(hash1).to.not.equal(hash2);
    });
  });
});
