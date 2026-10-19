import { expect } from "chai";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { ethers } from "hardhat";

const CLAIM_ID = 1n;
const CONTENT_DIGEST = ethers.id("evidence-content");
const CONTENT_DIGEST_2 = ethers.id("evidence-content-2");
const METADATA_DIGEST = ethers.id("evidence-metadata");
const METADATA_DIGEST_2 = ethers.id("evidence-metadata-2");

enum ClaimStatus {
  Pending,
  UnderVerification,
  VerifiedTrue,
  VerifiedFalse,
  Disputed,
  Cancelled,
}

async function deployFixture() {
  const [admin, contributor, otherContributor, claimant] = await ethers.getSigners();

  const ClaimRegistry = await ethers.getContractFactory("MockEvidenceClaimRegistry");
  const claimRegistry = await ClaimRegistry.deploy();
  await claimRegistry.waitForDeployment();

  const EvidenceRegistry = await ethers.getContractFactory("EvidenceRegistry");
  const evidence = await EvidenceRegistry.deploy(admin.address, await claimRegistry.getAddress());
  await evidence.waitForDeployment();

  const deadline = BigInt(await time.latest()) + 7n * 24n * 60n * 60n;
  await claimRegistry.setClaim(CLAIM_ID, claimant.address, deadline, ClaimStatus.Pending);

  return { admin, contributor, otherContributor, claimant, claimRegistry, evidence, deadline };
}

describe("EvidenceRegistry", function () {
  it("commits digest-only evidence and emits canonical reconstruction events", async function () {
    const { evidence, contributor } = await loadFixture(deployFixture);

    const expectedId = await evidence.computeEvidenceId(CLAIM_ID, contributor.address, CONTENT_DIGEST, METADATA_DIGEST, 0);

    await expect(evidence.connect(contributor).commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0))
      .to.emit(evidence, "EvidenceSubmittedV1")
      .withArgs(CLAIM_ID, expectedId, contributor.address, CONTENT_DIGEST, anyValue, 1)
      .and.to.emit(evidence, "EvidenceCommitted")
      .withArgs(CLAIM_ID, expectedId, contributor.address, CONTENT_DIGEST, METADATA_DIGEST, 0, anyValue, 1);

    const stored = await evidence.getEvidenceCommitment(expectedId);
    expect(stored.id).to.equal(expectedId);
    expect(stored.claimId).to.equal(CLAIM_ID);
    expect(stored.contributor).to.equal(contributor.address);
    expect(stored.contentDigest).to.equal(CONTENT_DIGEST);
    expect(stored.metadataDigest).to.equal(METADATA_DIGEST);
    expect(stored.nonce).to.equal(0n);
  });

  it("derives different IDs for different contributors using the same nonce", async function () {
    const { evidence, contributor, otherContributor } = await loadFixture(deployFixture);

    const firstId = await evidence.computeEvidenceId(CLAIM_ID, contributor.address, CONTENT_DIGEST, METADATA_DIGEST, 0);
    const secondId = await evidence.computeEvidenceId(CLAIM_ID, otherContributor.address, CONTENT_DIGEST, METADATA_DIGEST, 0);

    await evidence.connect(contributor).commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0);
    await evidence.connect(otherContributor).commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0);

    expect(firstId).to.not.equal(secondId);
    expect(await evidence.evidenceCount(CLAIM_ID)).to.equal(2n);
    expect(await evidence.nextContributorNonce(contributor.address)).to.equal(1n);
    expect(await evidence.nextContributorNonce(otherContributor.address)).to.equal(1n);
  });

  it("enforces contributor nonce order", async function () {
    const { evidence, contributor } = await loadFixture(deployFixture);

    await expect(evidence.connect(contributor).commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 1))
      .to.be.revertedWithCustomError(evidence, "InvalidNonce")
      .withArgs(contributor.address, 0, 1);

    await evidence.connect(contributor).commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0);

    await expect(evidence.connect(contributor).commitEvidence(CLAIM_ID, CONTENT_DIGEST_2, METADATA_DIGEST_2, 0))
      .to.be.revertedWithCustomError(evidence, "InvalidNonce")
      .withArgs(contributor.address, 1, 0);
  });

  it("rejects duplicate commitments from the same contributor", async function () {
    const { evidence, contributor } = await loadFixture(deployFixture);

    await evidence.connect(contributor).commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0);

    await expect(evidence.connect(contributor).commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 1))
      .to.be.revertedWithCustomError(evidence, "DuplicateEvidence");
  });

  it("rejects zero content or metadata digests", async function () {
    const { evidence, contributor } = await loadFixture(deployFixture);

    await expect(evidence.connect(contributor).commitEvidence(CLAIM_ID, ethers.ZeroHash, METADATA_DIGEST, 0))
      .to.be.revertedWithCustomError(evidence, "ZeroDigest");

    await expect(evidence.connect(contributor).commitEvidence(CLAIM_ID, CONTENT_DIGEST, ethers.ZeroHash, 0))
      .to.be.revertedWithCustomError(evidence, "ZeroDigest");
  });

  it("bounds raw metadata before hashing it", async function () {
    const { evidence, contributor } = await loadFixture(deployFixture);
    const maximum = Number(await evidence.MAX_METADATA_BYTES());

    await evidence.connect(contributor).submitEvidence(CLAIM_ID, CONTENT_DIGEST, "a".repeat(maximum));

    await expect(
      evidence.connect(contributor).submitEvidence(CLAIM_ID, CONTENT_DIGEST_2, "a".repeat(maximum + 1)),
    )
      .to.be.revertedWithCustomError(evidence, "MetadataTooLarge")
      .withArgs(maximum + 1, maximum);
    expect(await evidence.nextContributorNonce(contributor.address)).to.equal(1n);
  });

  it("rejects invalid claims", async function () {
    const { evidence, contributor } = await loadFixture(deployFixture);

    await expect(evidence.connect(contributor).commitEvidence(999, CONTENT_DIGEST, METADATA_DIGEST, 0))
      .to.be.revertedWithCustomError(evidence, "InvalidClaim")
      .withArgs(999);
  });

  it("rejects commitments after the claim evidence window", async function () {
    const { evidence, contributor, deadline } = await loadFixture(deployFixture);

    await time.increaseTo(deadline + 1n);

    await expect(evidence.connect(contributor).commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0))
      .to.be.revertedWithCustomError(evidence, "EvidenceWindowClosed");
  });

  it("rejects commitments while paused", async function () {
    const { evidence, admin, contributor } = await loadFixture(deployFixture);

    await evidence.connect(admin).pause();

    await expect(evidence.connect(contributor).commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0))
      .to.be.revertedWithCustomError(evidence, "EnforcedPause");
  });

  it("rejects finalized and cancelled claim statuses", async function () {
    const { evidence, contributor, claimRegistry } = await loadFixture(deployFixture);

    for (const status of [ClaimStatus.VerifiedTrue, ClaimStatus.VerifiedFalse, ClaimStatus.Disputed, ClaimStatus.Cancelled]) {
      await claimRegistry.setClaimStatus(CLAIM_ID, status);
      await expect(evidence.connect(contributor).commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0))
        .to.be.revertedWithCustomError(evidence, "ClaimFinalized")
        .withArgs(CLAIM_ID, status);
    }
  });

  it("paginates deterministic claim evidence sets", async function () {
    const { evidence, contributor } = await loadFixture(deployFixture);

    const ids = [];
    for (let i = 0; i < 3; i++) {
      const contentDigest = ethers.id(`content-${i}`);
      const metadataDigest = ethers.id(`metadata-${i}`);
      ids.push(await evidence.computeEvidenceId(CLAIM_ID, contributor.address, contentDigest, metadataDigest, i));
      await evidence.connect(contributor).commitEvidence(CLAIM_ID, contentDigest, metadataDigest, i);
    }

    const firstPage = await evidence.claimEvidence(CLAIM_ID, 0, 2);
    expect(firstPage.evidenceIds).to.deep.equal(ids.slice(0, 2));
    expect(firstPage.nextCursor).to.equal(2n);

    const secondPage = await evidence.claimEvidence(CLAIM_ID, 2, 2);
    expect(secondPage.evidenceIds).to.deep.equal(ids.slice(2));
    expect(secondPage.nextCursor).to.equal(3n);
  });

  it("bounds per-claim evidence storage", async function () {
    const { evidence, contributor } = await loadFixture(deployFixture);
    const maxEvidence = Number(await evidence.MAX_EVIDENCE_PER_CLAIM());

    for (let i = 0; i < maxEvidence; i++) {
      await evidence.connect(contributor).commitEvidence(
        CLAIM_ID,
        ethers.id(`bounded-content-${i}`),
        ethers.id(`bounded-metadata-${i}`),
        i,
      );
    }

    expect(await evidence.evidenceCount(CLAIM_ID)).to.equal(BigInt(maxEvidence));
    await expect(
      evidence.connect(contributor).commitEvidence(
        CLAIM_ID,
        ethers.id("bounded-content-over-limit"),
        ethers.id("bounded-metadata-over-limit"),
        maxEvidence,
      ),
    )
      .to.be.revertedWithCustomError(evidence, "EvidenceLimitReached")
      .withArgs(CLAIM_ID, maxEvidence);
  });

  it("submitEvidence hashes metadata bytes and advances the contributor nonce", async function () {
    const { evidence, contributor } = await loadFixture(deployFixture);

    const metadata = ethers.toUtf8Bytes("off-chain metadata reference");
    const metadataDigest = ethers.keccak256(metadata);
    const expectedId = await evidence.computeEvidenceId(CLAIM_ID, contributor.address, CONTENT_DIGEST, metadataDigest, 0);

    await expect(evidence.connect(contributor).submitEvidence(CLAIM_ID, CONTENT_DIGEST, metadata))
      .to.emit(evidence, "EvidenceSubmitted")
      .withArgs(expectedId, CLAIM_ID, contributor.address, CONTENT_DIGEST);

    const stored = await evidence.getEvidenceCommitment(expectedId);
    expect(stored.metadataDigest).to.equal(metadataDigest);
    expect(await evidence.nextContributorNonce(contributor.address)).to.equal(1n);
  });
});
