import { expect } from "chai";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { ethers } from "hardhat";
import type { ClaimRegistry, VerificationSubmission, MockERC20 } from "../typechain-types";
import { deployClaimRegistry } from "./helpers/deployClaimRegistry";

describe("VerificationSubmission", function () {
    const MIN_STAKE = ethers.parseEther("100");
    const VALID_CID = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG";
    const TYPICAL_STATEMENT = "The unemployment rate in Germany fell to 5.1% in Q1 2026 according to Destatis.";
    
    async function futureDeadline(offsetSeconds = 7 * 24 * 60 * 60) {
        const now = await time.latest();
        return now + offsetSeconds;
    }

    async function deployFixture() {
        const [admin, updater, verifier1, verifier2, claimCreator] = await ethers.getSigners();

        // 1. Deploy ClaimRegistry
        const registry = await deployClaimRegistry(admin.address);

        const REGISTRY_UPDATER_ROLE = await registry.REGISTRY_UPDATER_ROLE();
        await registry.connect(admin).grantRole(REGISTRY_UPDATER_ROLE, updater.address);

        // 2. Deploy MockERC20 Token
        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        const token = (await MockERC20Factory.deploy("Bounty", "BOUNTY")) as MockERC20;
        await token.waitForDeployment();

        // Give tokens to verifiers
        await token.mint(verifier1.address, ethers.parseEther("1000"));
        await token.mint(verifier2.address, ethers.parseEther("1000"));

        // 3. Deploy VerificationSubmission
        const VerificationSubmissionFactory = await ethers.getContractFactory("VerificationSubmission");
        const submissionEngine = (await VerificationSubmissionFactory.deploy(
            await registry.getAddress(),
            await token.getAddress(),
            MIN_STAKE
        )) as VerificationSubmission;
        await submissionEngine.waitForDeployment();

        // Approve token spending
        await token.connect(verifier1).approve(await submissionEngine.getAddress(), ethers.MaxUint256);
        await token.connect(verifier2).approve(await submissionEngine.getAddress(), ethers.MaxUint256);

        // Create a claim
        const deadline = await futureDeadline();
        await registry.connect(claimCreator).createClaim(TYPICAL_STATEMENT, VALID_CID, deadline);
        const claimId = 1n;

        return { registry, token, submissionEngine, admin, updater, verifier1, verifier2, claimCreator, claimId, deadline };
    }

    describe("Deployment", function () {
        it("should set immutable variables correctly", async function () {
            const { registry, token, submissionEngine } = await loadFixture(deployFixture);
            
            expect(await submissionEngine.claimRegistry()).to.equal(await registry.getAddress());
            expect(await submissionEngine.stakingToken()).to.equal(await token.getAddress());
            expect(await submissionEngine.minStakeAmount()).to.equal(MIN_STAKE);
            expect(await submissionEngine.getVerificationCount()).to.equal(0);
        });
    });

    describe("submitVerification - Success", function () {
        it("should allow a valid verification and lock stake", async function () {
            const { registry, token, submissionEngine, updater, verifier1, claimId } = await loadFixture(deployFixture);

            // Change claim status to UnderVerification
            await registry.connect(updater).updateClaimStatus(claimId, 1);

            const initialBalance = await token.balanceOf(verifier1.address);
            const engineBalanceInitial = await token.balanceOf(await submissionEngine.getAddress());

            await expect(submissionEngine.connect(verifier1).submitVerification(claimId, 0 /* TRUE */, MIN_STAKE))
                .to.emit(submissionEngine, "VerificationSubmitted")
                .withArgs(claimId, 1n, verifier1.address, 0, MIN_STAKE);

            // Verify stake was locked
            expect(await token.balanceOf(verifier1.address)).to.equal(initialBalance - MIN_STAKE);
            expect(await token.balanceOf(await submissionEngine.getAddress())).to.equal(engineBalanceInitial + MIN_STAKE);

            // Verify state
            const v = await submissionEngine.getVerification(1);
            expect(v.id).to.equal(1n);
            expect(v.claimId).to.equal(claimId);
            expect(v.verifier).to.equal(verifier1.address);
            expect(v.verdict).to.equal(0);
            expect(v.stake).to.equal(MIN_STAKE);

            expect(await submissionEngine.hasVerified(claimId, verifier1.address)).to.be.true;
            expect(await submissionEngine.getVerifierStake(claimId, verifier1.address)).to.equal(MIN_STAKE);
            expect(await submissionEngine.getVerificationCount()).to.equal(1);
        });

        it("multiple verifiers can verify the same claim", async function () {
            const { registry, submissionEngine, updater, verifier1, verifier2, claimId } = await loadFixture(deployFixture);
            await registry.connect(updater).updateClaimStatus(claimId, 1);

            await submissionEngine.connect(verifier1).submitVerification(claimId, 0 /* TRUE */, MIN_STAKE);
            await submissionEngine.connect(verifier2).submitVerification(claimId, 1 /* FALSE */, MIN_STAKE + 50n);

            expect(await submissionEngine.getVerificationCount()).to.equal(2);
            const claimVerifications = await submissionEngine.getClaimVerifications(claimId);
            expect(claimVerifications.length).to.equal(2);
            expect(claimVerifications[0]).to.equal(1n);
            expect(claimVerifications[1]).to.equal(2n);
        });
    });

    describe("submitVerification - Validation Failures", function () {
        it("reverts if claim is not in UnderVerification status", async function () {
            const { submissionEngine, verifier1, claimId } = await loadFixture(deployFixture);
            
            // Claim is Pending (0), not UnderVerification (1)
            await expect(submissionEngine.connect(verifier1).submitVerification(claimId, 0, MIN_STAKE))
                .to.be.revertedWithCustomError(submissionEngine, "InvalidClaimState");
        });

        it("reverts if verification window is closed", async function () {
            const { registry, submissionEngine, updater, verifier1, claimId, deadline } = await loadFixture(deployFixture);
            await registry.connect(updater).updateClaimStatus(claimId, 1);

            // Fast forward past deadline
            await time.increaseTo(Number(deadline) + 1);

            await expect(submissionEngine.connect(verifier1).submitVerification(claimId, 0, MIN_STAKE))
                .to.be.revertedWithCustomError(submissionEngine, "VerificationWindowClosed");
        });

        it("accepts inclusion at the deadline and rejects inclusion after it", async function () {
            const { registry, submissionEngine, updater, verifier1, verifier2, claimId, deadline } =
                await loadFixture(deployFixture);
            await registry.connect(updater).updateClaimStatus(claimId, 1);

            await time.setNextBlockTimestamp(Number(deadline));
            await submissionEngine.connect(verifier1).submitVerification(claimId, 0, MIN_STAKE);
            expect((await submissionEngine.getVerification(1)).submittedAt).to.equal(BigInt(deadline));

            await time.setNextBlockTimestamp(Number(deadline) + 1);
            await expect(submissionEngine.connect(verifier2).submitVerification(claimId, 1, MIN_STAKE))
                .to.be.revertedWithCustomError(submissionEngine, "VerificationWindowClosed");
            expect(await submissionEngine.getVerificationCount()).to.equal(1);
        });

        it("reverts on duplicate verification from same wallet", async function () {
            const { registry, submissionEngine, updater, verifier1, claimId } = await loadFixture(deployFixture);
            await registry.connect(updater).updateClaimStatus(claimId, 1);

            await submissionEngine.connect(verifier1).submitVerification(claimId, 0, MIN_STAKE);

            await expect(submissionEngine.connect(verifier1).submitVerification(claimId, 1, MIN_STAKE))
                .to.be.revertedWithCustomError(submissionEngine, "AlreadyVerified");
        });

        it("reverts if stake is insufficient", async function () {
            const { registry, submissionEngine, updater, verifier1, claimId } = await loadFixture(deployFixture);
            await registry.connect(updater).updateClaimStatus(claimId, 1);

            const tooLowStake = MIN_STAKE - 1n;
            await expect(submissionEngine.connect(verifier1).submitVerification(claimId, 0, tooLowStake))
                .to.be.revertedWithCustomError(submissionEngine, "InsufficientStake");
        });
    });

    describe("Paginated Verifications Query", function () {
        it("supports paginated retrieval of verifications", async function () {
            const { registry, submissionEngine, updater, verifier1, verifier2, claimId } = await loadFixture(deployFixture);
            await registry.connect(updater).updateClaimStatus(claimId, 1);

            await submissionEngine.connect(verifier1).submitVerification(claimId, 0, MIN_STAKE);
            await submissionEngine.connect(verifier2).submitVerification(claimId, 1, MIN_STAKE);

            const [verificationsPage1, total1] = await submissionEngine.getClaimVerificationsPaginated(claimId, 0, 1);
            expect(total1).to.equal(2);
            expect(verificationsPage1.length).to.equal(1);
            expect(verificationsPage1[0]).to.equal(1n);

            const [verificationsPage2, total2] = await submissionEngine.getClaimVerificationsPaginated(claimId, 1, 5);
            expect(total2).to.equal(2);
            expect(verificationsPage2.length).to.equal(1);
            expect(verificationsPage2[0]).to.equal(2n);

            const [verificationsEmpty, totalEmpty] = await submissionEngine.getClaimVerificationsPaginated(claimId, 10, 5);
            expect(totalEmpty).to.equal(2);
            expect(verificationsEmpty.length).to.equal(0);
        });
    });

    describe("Gas Benchmarks", function () {
        it("measures gas for first verification submission", async function () {
            const { registry, submissionEngine, updater, verifier1, claimId } = await loadFixture(deployFixture);
            await registry.connect(updater).updateClaimStatus(claimId, 1);

            const tx = await submissionEngine.connect(verifier1).submitVerification(claimId, 0, MIN_STAKE);
            const receipt = await tx.wait();

            console.log(`\n  ┌─ Gas Benchmarks ─────────────────────────────────────`);
            console.log(`  │  First verification:       ${receipt?.gasUsed.toString()} gas`);
            expect(receipt?.gasUsed).to.be.greaterThan(50_000n);
        });

        it("measures gas for subsequent verification submission", async function () {
            const { registry, submissionEngine, updater, verifier1, verifier2, claimId } = await loadFixture(deployFixture);
            await registry.connect(updater).updateClaimStatus(claimId, 1);

            await submissionEngine.connect(verifier1).submitVerification(claimId, 0, MIN_STAKE);

            const tx = await submissionEngine.connect(verifier2).submitVerification(claimId, 1, MIN_STAKE);
            const receipt = await tx.wait();

            console.log(`  │  Subsequent verification:  ${receipt?.gasUsed.toString()} gas`);
            console.log(`  └────────────────────────────────────────────────────────\n`);
            expect(receipt?.gasUsed).to.be.greaterThan(40_000n);
        });
    });
});
