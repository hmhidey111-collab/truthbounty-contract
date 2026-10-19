import { expect } from "chai";
import { ethers } from "hardhat";
import { Signer } from "ethers";

// ─────────────────────────────────────────────────────────────────────────────
// SC-028 Integration Tests
//
// Verifies FeeManager compatibility with:
//   1. Treasury  — fee routing lands in the same treasury used by TruthBountyClaims
//   2. Governance — GovernanceController can update FeeManager fee schedules
//   3. Claims    — a protocol module collecting claim fees before settling
//   4. Verification — a protocol module collecting verification fees
//   5. Reward Engine — fee collection before reward calculation
// ─────────────────────────────────────────────────────────────────────────────

// ── Fee type identifiers (must match FeeManager constants) ───────────────────

const CLAIM_SUBMISSION_FEE        = ethers.keccak256(ethers.toUtf8Bytes("CLAIM_SUBMISSION_FEE"));
const VERIFICATION_SUBMISSION_FEE = ethers.keccak256(ethers.toUtf8Bytes("VERIFICATION_SUBMISSION_FEE"));
const DISPUTE_INITIATION_FEE      = ethers.keccak256(ethers.toUtf8Bytes("DISPUTE_INITIATION_FEE"));
const PROTOCOL_SERVICE_FEE        = ethers.keccak256(ethers.toUtf8Bytes("PROTOCOL_SERVICE_FEE"));

// ── Allocation targets (must match FeeManager constants) ────────────────────

const ALLOC_TREASURY_RESERVE       = ethers.keccak256(ethers.toUtf8Bytes("TREASURY_RESERVE"));
const ALLOC_SECURITY_FUND          = ethers.keccak256(ethers.toUtf8Bytes("SECURITY_FUND"));
const ALLOC_ECOSYSTEM_FUND         = ethers.keccak256(ethers.toUtf8Bytes("ECOSYSTEM_FUND"));
const ALLOC_CONTRIBUTOR_INCENTIVES = ethers.keccak256(ethers.toUtf8Bytes("CONTRIBUTOR_INCENTIVES"));
const ALLOC_EMERGENCY_RESERVE      = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_RESERVE"));

// ── Roles ────────────────────────────────────────────────────────────────────

const COLLECTOR_ROLE  = ethers.keccak256(ethers.toUtf8Bytes("COLLECTOR_ROLE"));
const GOVERNANCE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("GOVERNANCE_ROLE"));
const TREASURY_ROLE   = ethers.keccak256(ethers.toUtf8Bytes("TREASURY_ROLE"));

// ── Helpers ──────────────────────────────────────────────────────────────────

const ONE_TOKEN   = ethers.parseEther("1");
const LARGE_MINT  = ethers.parseEther("1000000");

// ─────────────────────────────────────────────────────────────────────────────
// Shared fixture — deploys every system used across all integration suites
// ─────────────────────────────────────────────────────────────────────────────

async function deployIntegrationFixture() {
    const [
        admin,
        collector,
        payer,
        beneficiary,
        treasuryAddr,
        securityAddr,
        ecosystemAddr,
        contributorsAddr,
        emergencyAddr,
        other,
    ] = await ethers.getSigners();

    // ── ERC20 fee / bounty token ─────────────────────────────────────────────
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const token = await MockERC20.deploy("TruthBounty Token", "TBT");
    await token.waitForDeployment();

    await token.mint(await payer.getAddress(),        LARGE_MINT);
    await token.mint(await admin.getAddress(),         LARGE_MINT);
    await token.mint(await beneficiary.getAddress(),   LARGE_MINT);

    // ── FeeManager ───────────────────────────────────────────────────────────
    const FeeManager = await ethers.getContractFactory("FeeManager");
    const feeManager = await FeeManager.deploy(
        await token.getAddress(),
        await admin.getAddress(),
        ethers.ZeroAddress,                   // governance controller wired later
        await treasuryAddr.getAddress(),
        await securityAddr.getAddress(),
        await ecosystemAddr.getAddress(),
        await contributorsAddr.getAddress(),
        await emergencyAddr.getAddress()
    );
    await feeManager.waitForDeployment();

    // Grant collector role to the `collector` signer (simulates a protocol module)
    await feeManager.connect(admin).grantRole(COLLECTOR_ROLE, await collector.getAddress());

    // Payer approves FeeManager
    await token.connect(payer).approve(await feeManager.getAddress(), LARGE_MINT);
    await token.connect(admin).approve(await feeManager.getAddress(), LARGE_MINT);

    // ── TruthBountyClaims ────────────────────────────────────────────────────
    // Uses the same token so treasury receives both fee revenue and claim payouts
    const TruthBountyClaims = await ethers.getContractFactory("TruthBountyClaims");
    const claimsContract = await TruthBountyClaims.deploy(
        await token.getAddress(),
        await admin.getAddress()
    );
    await claimsContract.waitForDeployment();

    // Fund the claims contract with tokens it will pay out
    await token.mint(await claimsContract.getAddress(), LARGE_MINT);

    // ── GovernanceController ─────────────────────────────────────────────────
    const GovernanceController = await ethers.getContractFactory("GovernanceController");
    const govController = await GovernanceController.deploy(await admin.getAddress());
    await govController.waitForDeployment();

    // Grant GovernanceController GOVERNANCE_ROLE on FeeManager so it can
    // update fee schedules on behalf of DAO governance
    await feeManager.connect(admin).grantRole(
        GOVERNANCE_ROLE,
        await govController.getAddress()
    );

    // ── MockReputationOracle (required by RewardEngine) ──────────────────────
    const MockOracle = await ethers.getContractFactory("MockReputationOracle");
    const oracle = await MockOracle.deploy();
    await oracle.waitForDeployment();

    // ── RewardEngine ─────────────────────────────────────────────────────────
    const RewardEngine = await ethers.getContractFactory("RewardEngine");
    const rewardEngine = await RewardEngine.deploy(
        await oracle.getAddress(),
        await admin.getAddress(),
        ethers.ZeroAddress          // no external governance controller needed for tests
    );
    await rewardEngine.waitForDeployment();

    return {
        token,
        feeManager,
        claimsContract,
        govController,
        rewardEngine,
        oracle,
        admin,
        collector,
        payer,
        beneficiary,
        treasuryAddr,
        securityAddr,
        ecosystemAddr,
        contributorsAddr,
        emergencyAddr,
        other,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Treasury Integration
// ─────────────────────────────────────────────────────────────────────────────

describe("FeeManager Integration — Treasury", function () {
    it("Fee revenue lands in treasury reserve address used by the protocol", async function () {
        const { feeManager, token, collector, payer, treasuryAddr } =
            await deployIntegrationFixture();

        const before = await token.balanceOf(await treasuryAddr.getAddress());

        await feeManager.connect(collector).collectFee(
            CLAIM_SUBMISSION_FEE,
            await payer.getAddress(),
            ONE_TOKEN
        );

        const after = await token.balanceOf(await treasuryAddr.getAddress());

        // Treasury reserve receives 40% (4000 bps)
        expect(after - before).to.equal((ONE_TOKEN * 4000n) / 10000n);
    });

    it("All five allocation targets receive their correct shares", async function () {
        const {
            feeManager, token, collector, payer,
            treasuryAddr, securityAddr, ecosystemAddr, contributorsAddr, emergencyAddr,
        } = await deployIntegrationFixture();

        const fee = ethers.parseEther("10000");

        const [tBefore, sBefore, eBefore, cBefore, emBefore] = await Promise.all([
            token.balanceOf(await treasuryAddr.getAddress()),
            token.balanceOf(await securityAddr.getAddress()),
            token.balanceOf(await ecosystemAddr.getAddress()),
            token.balanceOf(await contributorsAddr.getAddress()),
            token.balanceOf(await emergencyAddr.getAddress()),
        ]);

        await feeManager.connect(collector).collectFee(
            CLAIM_SUBMISSION_FEE,
            await payer.getAddress(),
            fee
        );

        const [tAfter, sAfter, eAfter, cAfter, emAfter] = await Promise.all([
            token.balanceOf(await treasuryAddr.getAddress()),
            token.balanceOf(await securityAddr.getAddress()),
            token.balanceOf(await ecosystemAddr.getAddress()),
            token.balanceOf(await contributorsAddr.getAddress()),
            token.balanceOf(await emergencyAddr.getAddress()),
        ]);

        expect(tAfter  - tBefore).to.equal(ethers.parseEther("4000")); // 40%
        expect(sAfter  - sBefore).to.equal(ethers.parseEther("2000")); // 20%
        expect(eAfter  - eBefore).to.equal(ethers.parseEther("2000")); // 20%
        expect(cAfter  - cBefore).to.equal(ethers.parseEther("1000")); // 10%
        expect(emAfter - emBefore).to.equal(ethers.parseEther("1000")); // 10%
    });

    it("TruthBountyClaims can settle rewards after FeeManager routing is complete", async function () {
        const { feeManager, claimsContract, token, collector, payer, beneficiary, admin } =
            await deployIntegrationFixture();

        // Step 1: claim fee collected by FeeManager
        await feeManager.connect(collector).collectFee(
            CLAIM_SUBMISSION_FEE,
            await payer.getAddress(),
            ONE_TOKEN
        );

        // Step 2: treasury (admin) settles the claim reward via TruthBountyClaims
        // V2-SC-062: unique settlementId required
        const sid1 = ethers.keccak256(ethers.toUtf8Bytes("fee-integration-treasury-1"));
        await claimsContract.connect(admin).settleClaim(
            await beneficiary.getAddress(),
            ethers.parseEther("5"),
            sid1
        );

        // Both systems operational; beneficiary received reward
        expect(await token.balanceOf(await beneficiary.getAddress())).to.be.gt(
            LARGE_MINT
        );
        // FeeManager accounting is intact
        expect(await feeManager.getTotalFeesCollected()).to.equal(ONE_TOKEN);
    });

    it("getTreasuryDistributions returns matching data after multi-fee collection", async function () {
        const { feeManager, collector, payer } = await deployIntegrationFixture();

        await feeManager.connect(collector).collectFee(
            CLAIM_SUBMISSION_FEE,
            await payer.getAddress(),
            ethers.parseEther("10000")
        );
        await feeManager.connect(collector).collectFee(
            VERIFICATION_SUBMISSION_FEE,
            await payer.getAddress(),
            ethers.parseEther("10000")
        );

        const [names, , amounts, shares] = await feeManager.getTreasuryDistributions();

        expect(names.length).to.equal(5);

        // First target is treasury reserve (40%)
        expect(names[0]).to.equal(ALLOC_TREASURY_RESERVE);
        expect(shares[0]).to.equal(4000n);
        // Treasury reserve received 40% of 20,000 tokens = 8,000
        expect(amounts[0]).to.equal(ethers.parseEther("8000"));
    });
});

// ─────────────────────────────────────────────────────────────────────────────
// 2. Governance Integration
// ─────────────────────────────────────────────────────────────────────────────

describe("FeeManager Integration — Governance", function () {
    it("GovernanceController address is granted GOVERNANCE_ROLE on FeeManager", async function () {
        const { feeManager, govController } = await deployIntegrationFixture();
        expect(
            await feeManager.hasRole(GOVERNANCE_ROLE, await govController.getAddress())
        ).to.be.true;
    });

    it("Admin acting as governance can update fee schedules through governance role", async function () {
        const { feeManager, admin } = await deployIntegrationFixture();

        const newFixed = ethers.parseEther("2");

        await expect(
            feeManager.connect(admin).updateFeeSchedule(
                CLAIM_SUBMISSION_FEE,
                newFixed,
                0,
                0,
                0
            )
        )
            .to.emit(feeManager, "FeeScheduleUpdated")
            .withArgs(CLAIM_SUBMISSION_FEE, ethers.parseEther("0.001"), newFixed);

        const schedule = await feeManager.getFeeSchedule(CLAIM_SUBMISSION_FEE);
        expect(schedule.fixedAmount).to.equal(newFixed);
    });

    it("Governance version increments after each fee schedule update", async function () {
        const { feeManager, admin } = await deployIntegrationFixture();

        const v0 = await feeManager.globalGovVersion();

        await feeManager.connect(admin).updateFeeSchedule(
            CLAIM_SUBMISSION_FEE, ethers.parseEther("1"), 0, 0, 0
        );
        await feeManager.connect(admin).updateFeeSchedule(
            VERIFICATION_SUBMISSION_FEE, ethers.parseEther("1.5"), 0, 0, 0
        );

        expect(await feeManager.globalGovVersion()).to.equal(v0 + 2n);
    });

    it("Governance can replace allocation targets; subsequent fees route correctly", async function () {
        const { feeManager, token, admin, collector, payer, treasuryAddr, securityAddr } =
            await deployIntegrationFixture();

        // Governance reorganises routing: 70% treasury, 30% security
        const newTargets = [
            {
                name:        ALLOC_TREASURY_RESERVE,
                recipient:   await treasuryAddr.getAddress(),
                basisPoints: 7000n,
                active:      true,
            },
            {
                name:        ALLOC_SECURITY_FUND,
                recipient:   await securityAddr.getAddress(),
                basisPoints: 3000n,
                active:      true,
            },
        ];

        await feeManager.connect(admin).setAllocationTargets(newTargets);

        const fee = ethers.parseEther("10000");
        const tBefore = await token.balanceOf(await treasuryAddr.getAddress());

        await feeManager.connect(collector).collectFee(
            CLAIM_SUBMISSION_FEE,
            await payer.getAddress(),
            fee
        );

        const tAfter = await token.balanceOf(await treasuryAddr.getAddress());
        // Treasury should receive 70%
        expect(tAfter - tBefore).to.equal(ethers.parseEther("7000"));
    });

    it("Non-governance address cannot update fee schedules", async function () {
        const { feeManager, other } = await deployIntegrationFixture();

        await expect(
            feeManager.connect(other).updateFeeSchedule(
                CLAIM_SUBMISSION_FEE, ethers.parseEther("99"), 0, 0, 0
            )
        ).to.be.revertedWithCustomError(feeManager, "UnauthorizedGovernance");
    });

    it("Governance can deactivate a fee type; re-activation restores collection", async function () {
        const { feeManager, admin, collector, payer } = await deployIntegrationFixture();

        await feeManager.connect(admin).setFeeActive(DISPUTE_INITIATION_FEE, false);
        await expect(
            feeManager.connect(collector).collectFee(
                DISPUTE_INITIATION_FEE,
                await payer.getAddress(),
                ONE_TOKEN
            )
        ).to.be.revertedWithCustomError(feeManager, "FeeTypeNotActive");

        // Re-activate
        await feeManager.connect(admin).setFeeActive(DISPUTE_INITIATION_FEE, true);
        await expect(
            feeManager.connect(collector).collectFee(
                DISPUTE_INITIATION_FEE,
                await payer.getAddress(),
                ONE_TOKEN
            )
        ).to.emit(feeManager, "FeeCollected");
    });
});

// ─────────────────────────────────────────────────────────────────────────────
// 3. Claims Integration
// ─────────────────────────────────────────────────────────────────────────────

describe("FeeManager Integration — Claims", function () {
    it("Claim submission fee is collected before claim settlement", async function () {
        const { feeManager, claimsContract, token, collector, payer, beneficiary, admin } =
            await deployIntegrationFixture();

        const claimFee = ethers.parseEther("0.001");

        // 1. Protocol module collects claim submission fee via FeeManager
        await feeManager.connect(collector).collectFee(
            CLAIM_SUBMISSION_FEE,
            await payer.getAddress(),
            claimFee
        );

        // 2. Claim is settled; beneficiary receives reward
        // V2-SC-062: unique settlementId required
        const claimSid = ethers.keccak256(ethers.toUtf8Bytes("claims-integration-1"));
        await claimsContract.connect(admin).settleClaim(
            await beneficiary.getAddress(),
            ethers.parseEther("10"),
            claimSid
        );

        // FeeManager registered the fee
        expect(await feeManager.getFeesByType(CLAIM_SUBMISSION_FEE)).to.equal(claimFee);
        expect(await feeManager.getFeeRecordCount()).to.equal(1);
    });

    it("Batch claim settlement works alongside fee collection", async function () {
        const { feeManager, claimsContract, collector, payer, admin, other } =
            await deployIntegrationFixture();

        const signers = await ethers.getSigners();
        const recipients = signers.slice(10, 13).map(s => s.address);
        const amounts   = [
            ethers.parseEther("1"),
            ethers.parseEther("2"),
            ethers.parseEther("3"),
        ];

        // Collect one fee per claim submission
        for (let i = 0; i < recipients.length; i++) {
            await feeManager.connect(collector).collectFee(
                CLAIM_SUBMISSION_FEE,
                await payer.getAddress(),
                ethers.parseEther("0.001")
            );
        }

        // Batch settle rewards
        // V2-SC-062: unique settlementId required
        const batchSid = ethers.keccak256(ethers.toUtf8Bytes("fee-integration-batch-1"));
        await claimsContract.connect(admin).settleClaimsBatch(recipients, amounts, batchSid);

        // Three fee records created
        expect(await feeManager.getFeeRecordCount()).to.equal(3);
        // Total collected = 3 × 0.001
        expect(await feeManager.getTotalFeesCollected()).to.equal(
            ethers.parseEther("0.003")
        );
    });

    it("Fee accounting invariant holds after claim fee batch", async function () {
        const { feeManager, collector, payer } = await deployIntegrationFixture();

        const fees = [
            ethers.parseEther("0.001"),
            ethers.parseEther("0.005"),
            ethers.parseEther("0.01"),
        ];

        for (const fee of fees) {
            await feeManager.connect(collector).collectFee(
                CLAIM_SUBMISSION_FEE,
                await payer.getAddress(),
                fee
            );
        }

        const collected   = await feeManager.getTotalFeesCollected();
        const distributed = await feeManager.getTotalFeesDistributed();
        const retained    = await feeManager.getRetainedBalance();

        expect(collected).to.equal(distributed + retained);
    });
});

// ─────────────────────────────────────────────────────────────────────────────
// 4. Verification Integration
// ─────────────────────────────────────────────────────────────────────────────

describe("FeeManager Integration — Verification", function () {
    it("Verification submission fee is collected from a verifier", async function () {
        const { feeManager, collector, payer } = await deployIntegrationFixture();

        const verificationFee = ethers.parseEther("0.001");

        await expect(
            feeManager.connect(collector).collectFee(
                VERIFICATION_SUBMISSION_FEE,
                await payer.getAddress(),
                verificationFee
            )
        )
            .to.emit(feeManager, "FeeCollected")
            .withArgs(VERIFICATION_SUBMISSION_FEE, await payer.getAddress(), verificationFee);

        expect(await feeManager.getFeesByType(VERIFICATION_SUBMISSION_FEE)).to.equal(
            verificationFee
        );
    });

    it("Dispute initiation fee is collected separately from verification fee", async function () {
        const { feeManager, collector, payer } = await deployIntegrationFixture();

        await feeManager.connect(collector).collectFee(
            VERIFICATION_SUBMISSION_FEE,
            await payer.getAddress(),
            ethers.parseEther("0.001")
        );
        await feeManager.connect(collector).collectFee(
            DISPUTE_INITIATION_FEE,
            await payer.getAddress(),
            ethers.parseEther("0.002")
        );

        expect(await feeManager.getFeesByType(VERIFICATION_SUBMISSION_FEE)).to.equal(
            ethers.parseEther("0.001")
        );
        expect(await feeManager.getFeesByType(DISPUTE_INITIATION_FEE)).to.equal(
            ethers.parseEther("0.002")
        );
        expect(await feeManager.getTotalFeesCollected()).to.equal(
            ethers.parseEther("0.003")
        );
    });

    it("Multiple verifiers can pay verification fees independently", async function () {
        const { feeManager, token, admin, collector } = await deployIntegrationFixture();

        const signers = await ethers.getSigners();
        const verifiers = signers.slice(10, 14);
        const fee = ethers.parseEther("0.001");

        for (const verifier of verifiers) {
            await token.mint(await verifier.getAddress(), ethers.parseEther("1"));
            await token.connect(verifier).approve(await feeManager.getAddress(), fee);
            await feeManager.connect(collector).collectFee(
                VERIFICATION_SUBMISSION_FEE,
                await verifier.getAddress(),
                fee
            );
        }

        expect(await feeManager.getFeeRecordCount()).to.equal(4);
        expect(await feeManager.getTotalFeesCollected()).to.equal(
            fee * BigInt(verifiers.length)
        );
    });

    it("Verification fee schedule can be updated by governance between rounds", async function () {
        const { feeManager, admin, collector, payer } = await deployIntegrationFixture();

        // Round 1: collect at default rate
        const oldFee = ethers.parseEther("0.001");
        await feeManager.connect(collector).collectFee(
            VERIFICATION_SUBMISSION_FEE,
            await payer.getAddress(),
            oldFee
        );

        // Governance updates fee
        const newFee = ethers.parseEther("0.002");
        await feeManager.connect(admin).updateFeeSchedule(
            VERIFICATION_SUBMISSION_FEE,
            newFee,
            0,
            0,
            0
        );

        // Round 2: collect at new rate
        await feeManager.connect(collector).collectFee(
            VERIFICATION_SUBMISSION_FEE,
            await payer.getAddress(),
            newFee
        );

        expect(await feeManager.getFeesByType(VERIFICATION_SUBMISSION_FEE)).to.equal(
            oldFee + newFee
        );
        expect(await feeManager.getFeeRecordCount()).to.equal(2);
    });
});

// ─────────────────────────────────────────────────────────────────────────────
// 5. Reward Engine Integration
// ─────────────────────────────────────────────────────────────────────────────

describe("FeeManager Integration — Reward Engine", function () {
    it("RewardEngine and FeeManager deploy successfully in the same environment", async function () {
        const { feeManager, rewardEngine } = await deployIntegrationFixture();
        expect(await feeManager.getAddress()).to.be.properAddress;
        expect(await rewardEngine.getAddress()).to.be.properAddress;
    });

    it("Protocol service fee is collected before reward calculation", async function () {
        const { feeManager, rewardEngine, collector, payer, admin, oracle } =
            await deployIntegrationFixture();

        const serviceFee = ethers.parseEther("0.0005");

        // Step 1: collect protocol service fee
        await feeManager.connect(collector).collectFee(
            PROTOCOL_SERVICE_FEE,
            await payer.getAddress(),
            serviceFee
        );

        // Step 2: reward engine calculates a reward for the same payer
        const calc = await rewardEngine.calculateReward(
            await payer.getAddress(),
            ethers.parseEther("100"),   // effectiveStake
            ethers.parseEther("1000"),  // activeStake
            0                           // ClaimCategory.TRIVIAL
        );

        // Both operations succeed; fee accounting is intact
        expect(await feeManager.getFeesByType(PROTOCOL_SERVICE_FEE)).to.equal(serviceFee);
        // calculateReward succeeded (returned without reverting) — reward engine is operational
        expect(calc).to.not.be.undefined;
    });

    it("Fee accounting remains consistent after multiple reward-cycle fee collections", async function () {
        const { feeManager, rewardEngine, collector, payer, admin, oracle } =
            await deployIntegrationFixture();

        const rounds = 5;
        const feePerRound = ethers.parseEther("0.0005");

        for (let i = 0; i < rounds; i++) {
            // Collect service fee for this reward round
            await feeManager.connect(collector).collectFee(
                PROTOCOL_SERVICE_FEE,
                await payer.getAddress(),
                feePerRound
            );

            // Calculate reward for the round
            await rewardEngine.calculateReward(
                await payer.getAddress(),
                ethers.parseEther("100"),   // effectiveStake
                ethers.parseEther("1000"),  // activeStake
                0                           // ClaimCategory.TRIVIAL
            );
        }

        // Five fee records, one per round
        expect(await feeManager.getFeeRecordCount()).to.equal(rounds);
        expect(await feeManager.getTotalFeesCollected()).to.equal(
            feePerRound * BigInt(rounds)
        );

        // Core invariant: collected == distributed + retained
        const collected   = await feeManager.getTotalFeesCollected();
        const distributed = await feeManager.getTotalFeesDistributed();
        const retained    = await feeManager.getRetainedBalance();
        expect(collected).to.equal(distributed + retained);
    });

    it("RewardEngine governance parameters can be updated independently from FeeManager", async function () {
        const { feeManager, rewardEngine, admin } = await deployIntegrationFixture();

        // Update RewardEngine base rate — should not affect FeeManager state
        const before = await feeManager.globalGovVersion();

        await rewardEngine.connect(admin).setBaseRewardRate(ethers.parseEther("2"));

        // FeeManager governance version unchanged
        expect(await feeManager.globalGovVersion()).to.equal(before);
    });
});
