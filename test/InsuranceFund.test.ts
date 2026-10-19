import { expect } from "chai";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { ethers } from "hardhat";

describe("InsuranceFund", function () {
  const INITIAL_FUND = ethers.parseEther("100000");
  const BASIL_POINTS = 10000n;

  async function deployFixture() {
    const [admin, governance, insuranceManager, claimant, other] =
      await ethers.getSigners();

    // Deploy mock token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const token = await MockERC20.deploy("MockToken", "MOCK");
    await token.waitForDeployment();

    await token.mint(admin.address, INITIAL_FUND * 10n);
    await token.mint(claimant.address, INITIAL_FUND);

    // Deploy InsuranceFund
    const InsuranceFund = await ethers.getContractFactory("InsuranceFund");
    const fund = await InsuranceFund.deploy(
      await token.getAddress(),
      admin.address,
      governance.address
    );
    await fund.waitForDeployment();

    // Grant roles
    await fund.grantRole(await fund.INSURANCE_MANAGER_ROLE(), insuranceManager.address);
    await fund.grantRole(await fund.GOVERNANCE_ROLE(), governance.address);

    // Fund the reserve
    await token.connect(admin).approve(await fund.getAddress(), INITIAL_FUND);
    await fund.connect(admin).fundReserve(
      3, // GOVERNANCE
      INITIAL_FUND
    );

    return { admin, governance, insuranceManager, claimant, other, token, fund };
  }

  // ============ Deployment ============

  describe("Deployment", function () {
    it("should set correct admin roles", async function () {
      const { admin, fund } = await loadFixture(deployFixture);
      expect(await fund.hasRole(await fund.DEFAULT_ADMIN_ROLE(), admin.address)).to.be.true;
      expect(await fund.hasRole(await fund.ADMIN_ROLE(), admin.address)).to.be.true;
      expect(await fund.hasRole(await fund.INSURANCE_MANAGER_ROLE(), admin.address)).to.be.true;
      expect(await fund.hasRole(await fund.PAUSER_ROLE(), admin.address)).to.be.true;
    });

    it("should enable all coverage categories by default", async function () {
      const { fund } = await loadFixture(deployFixture);
      expect(await fund.isCoverageEnabled(0)).to.be.true; // SMART_CONTRACT_FAILURE
      expect(await fund.isCoverageEnabled(1)).to.be.true; // ECONOMIC_ATTACK
      expect(await fund.isCoverageEnabled(2)).to.be.true; // ORACLE_FAILURE
      expect(await fund.isCoverageEnabled(3)).to.be.true; // GOVERNANCE_INCIDENT
    });

    it("should have zero claims initially", async function () {
      const { fund } = await loadFixture(deployFixture);
      expect(await fund.getClaimCount()).to.equal(0n);
      expect(await fund.getActiveClaims()).to.deep.equal([]);
    });

    it("should have correct reserve token set", async function () {
      const { fund, token } = await loadFixture(deployFixture);
      expect(await fund.reserveToken()).to.equal(await token.getAddress());
    });

    it("should default to 1-day payout timelock", async function () {
      const { fund } = await loadFixture(deployFixture);
      expect(await fund.getPayoutTimelock()).to.equal(86400n);
    });
  });

  // ============ Funding ============

  describe("Funding", function () {
    it("should accept funds and emit InsuranceFunded event", async function () {
      const { fund, token, admin } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("1000");

      await token.connect(admin).approve(await fund.getAddress(), amount);

      await expect(fund.connect(admin).fundReserve(0, amount)) // PROTOCOL_FEE
        .to.emit(fund, "InsuranceFunded")
        .withArgs(admin.address, 0, amount);

      expect(await token.balanceOf(await fund.getAddress())).to.equal(
        INITIAL_FUND + amount
      );
    });

    it("should track funding by source", async function () {
      const { fund, token, admin } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("500");

      await token.connect(admin).approve(await fund.getAddress(), amount);
      await fund.connect(admin).fundReserve(
        1, // SLASHED_STAKE
        amount
      );

      expect(await fund.getFundingTotalBySource(1)).to.equal(amount);
    });

    it("should revert zero amount funding", async function () {
      const { fund } = await loadFixture(deployFixture);
      await expect(
        fund.fundReserve(0, 0)
      ).to.be.revertedWithCustomError(fund, "InvalidFundingAmount");
    });

    it("should track funding history", async function () {
      const { fund, token, admin } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("500");

      await token.connect(admin).approve(await fund.getAddress(), amount);
      await fund.connect(admin).fundReserve(0, amount);

      const history = await fund.getFundingHistory(0, 10);
      // First record is from deployFixture, second is this one
      expect(history.length).to.equal(2);
      expect(history[1].amount).to.equal(amount);
      expect(history[1].funder).to.equal(admin.address);
    });
  });

  // ============ Claim Submission ============

  describe("Claim Submission", function () {
    it("should submit a claim and emit InsuranceClaimSubmitted", async function () {
      const { fund, claimant } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("1000");

      await expect(
        fund.connect(claimant).submitClaim(0, amount, "ipfs://test")
      )
        .to.emit(fund, "InsuranceClaimSubmitted")
        .withArgs(0, claimant.address, 0, amount);

      const claim = await fund.getClaim(0);
      expect(claim.claimant).to.equal(claimant.address);
      expect(claim.requestedAmount).to.equal(amount);
      expect(claim.state).to.equal(0); // SUBMITTED
    });

    it("bounds stored claim description URIs", async function () {
      const { fund, claimant } = await loadFixture(deployFixture);
      const maximum = Number(await fund.MAX_DESCRIPTION_URI_BYTES());

      await fund.connect(claimant).submitClaim(0, 100, "u".repeat(maximum));

      await expect(fund.connect(claimant).submitClaim(1, 100, "u".repeat(maximum + 1)))
        .to.be.revertedWithCustomError(fund, "DescriptionUriTooLong")
        .withArgs(maximum + 1, maximum);
      expect(await fund.getClaimCount()).to.equal(1n);
    });

    it("should increment claimCounter", async function () {
      const { fund, claimant } = await loadFixture(deployFixture);

      await fund.connect(claimant).submitClaim(0, 100, "ipfs://1");
      expect(await fund.getClaimCount()).to.equal(1n);

      await fund.connect(claimant).submitClaim(1, 200, "ipfs://2");
      expect(await fund.getClaimCount()).to.equal(2n);
    });

    it("should track active claims", async function () {
      const { fund, claimant } = await loadFixture(deployFixture);

      await fund.connect(claimant).submitClaim(0, 100, "ipfs://1");
      await fund.connect(claimant).submitClaim(0, 200, "ipfs://2");

      const active = await fund.getActiveClaims();
      expect(active.length).to.equal(2);
      expect(active[0]).to.equal(0n);
      expect(active[1]).to.equal(1n);
    });

    it("should reject duplicate claims", async function () {
      const { fund, claimant } = await loadFixture(deployFixture);

      await fund.connect(claimant).submitClaim(0, 100, "ipfs://test");

      await expect(
        fund.connect(claimant).submitClaim(0, 100, "ipfs://test")
      ).to.be.revertedWithCustomError(fund, "DuplicateIncident");
    });

    it("should reject zero-amount claims", async function () {
      const { fund, claimant } = await loadFixture(deployFixture);

      await expect(
        fund.connect(claimant).submitClaim(0, 0, "ipfs://test")
      ).to.be.revertedWithCustomError(fund, "InvalidFundingAmount");
    });

    it("should reject claims for disabled coverage", async function () {
      const { fund, claimant, admin } = await loadFixture(deployFixture);

      await fund.connect(admin).setCoverageEnabled(0, false);

      await expect(
        fund.connect(claimant).submitClaim(0, 100, "ipfs://test")
      ).to.be.revertedWithCustomError(fund, "CoverageDisabled");
    });
  });

  // ============ Claim Lifecycle ============

  describe("Claim Lifecycle", function () {
    it("should progress through full lifecycle: SUBMITTED → INVESTIGATING → APPROVED → PAID", async function () {
      const { fund, claimant, insuranceManager, governance, token } =
        await loadFixture(deployFixture);

      const amount = ethers.parseEther("1000");

      // 1. Submit
      await fund.connect(claimant).submitClaim(0, amount, "ipfs://incident");

      // 2. Investigate
      await fund.connect(insuranceManager).updateClaimState(0, 1); // INVESTIGATING
      let claim = await fund.getClaim(0);
      expect(claim.state).to.equal(1);

      // 3. Approve
      await fund.connect(governance).reviewAndApproveClaim(0, amount, "ipfs://audit");
      claim = await fund.getClaim(0);
      expect(claim.state).to.equal(3); // APPROVED

      // 4. Fast-forward past timelock and execute payout
      await time.increase(86401);
      const balanceBefore = await token.balanceOf(claimant.address);

      await expect(fund.executePayout(0))
        .to.emit(fund, "InsurancePayoutExecuted")
        .withArgs(claimant.address, amount, 0);

      const balanceAfter = await token.balanceOf(claimant.address);
      expect(balanceAfter - balanceBefore).to.equal(amount);

      claim = await fund.getClaim(0);
      expect(claim.state).to.equal(5); // PAID
    });

    it("should reject and emit InsuranceClaimRejected", async function () {
      const { fund, claimant, governance } = await loadFixture(deployFixture);

      await fund.connect(claimant).submitClaim(0, 100, "ipfs://test");

      await expect(fund.connect(governance).rejectClaim(0, "Invalid claim"))
        .to.emit(fund, "InsuranceClaimRejected")
        .withArgs(0, "Invalid claim", governance.address);

      const claim = await fund.getClaim(0);
      expect(claim.state).to.equal(4); // REJECTED
    });

    it("should remove rejected claims from active set", async function () {
      const { fund, claimant, governance } = await loadFixture(deployFixture);

      await fund.connect(claimant).submitClaim(0, 100, "ipfs://1");
      await fund.connect(claimant).submitClaim(0, 200, "ipfs://2");

      await fund.connect(governance).rejectClaim(0, "Invalid");

      const active = await fund.getActiveClaims();
      expect(active.length).to.equal(1);
      expect(active[0]).to.equal(1n);
    });

    it("should reject payout before timelock expires", async function () {
      const { fund, claimant, governance } = await loadFixture(deployFixture);

      await fund.connect(claimant).submitClaim(0, 100, "ipfs://test");
      await fund.connect(governance).reviewAndApproveClaim(0, 100, "ipfs://audit");

      await expect(
        fund.executePayout(0)
      ).to.be.revertedWithCustomError(fund, "PayoutTimelockActive");
    });

    it("should reject payout of non-approved claim", async function () {
      const { fund, claimant } = await loadFixture(deployFixture);

      await fund.connect(claimant).submitClaim(0, 100, "ipfs://test");

      await time.increase(86401);

      await expect(
        fund.executePayout(0)
      ).to.be.revertedWithCustomError(fund, "ClaimNotApproved");
    });

    it("should enforce max payout per claim", async function () {
      const { fund, claimant, governance, admin } = await loadFixture(deployFixture);

      await fund.connect(admin).setMaxPayoutPerClaim(ethers.parseEther("500"));

      await fund.connect(claimant).submitClaim(0, ethers.parseEther("1000"), "ipfs://test");

      await expect(
        fund.connect(governance).reviewAndApproveClaim(
          0,
          ethers.parseEther("1000"),
          "ipfs://audit"
        )
      ).to.be.revertedWithCustomError(fund, "AmountExceedsMaxPayout");
    });

    it("should enforce utilization limit", async function () {
      const { fund, claimant, governance, admin } = await loadFixture(deployFixture);

      // Set 10% utilization limit
      await fund.connect(admin).setGlobalUtilizationLimit(1000);

      // Try to claim more than 10% of reserve
      const excessiveAmount = INITIAL_FUND * 11n / 100n; // 11%
      await fund.connect(claimant).submitClaim(0, excessiveAmount, "ipfs://test");

      await expect(
        fund.connect(governance).reviewAndApproveClaim(0, excessiveAmount, "ipfs://audit")
      ).to.be.revertedWithCustomError(fund, "UtilisationLimitExceeded");
    });
  });

  // ============ Governance Controls ============

  describe("Governance Controls", function () {
    it("should update max payout and emit InsurancePolicyUpdated", async function () {
      const { fund, admin } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("2000");

      await expect(fund.connect(admin).setMaxPayoutPerClaim(amount))
        .to.emit(fund, "InsurancePolicyUpdated")
        .withArgs(ethers.id("MAX_PAYOUT_PER_CLAIM"), 0, amount);

      expect(await fund.getMaxPayoutPerClaim()).to.equal(amount);
    });

    it("should update utilization limit", async function () {
      const { fund, admin } = await loadFixture(deployFixture);

      await fund.connect(admin).setGlobalUtilizationLimit(1500);
      expect(await fund.getGlobalUtilizationLimit()).to.equal(1500n);
    });

    it("should reject utilization limit > 100%", async function () {
      const { fund, admin } = await loadFixture(deployFixture);

      await expect(
        fund.connect(admin).setGlobalUtilizationLimit(10001)
      ).to.be.revertedWith("Limit exceeds 100%");
    });

    it("should toggle coverage categories", async function () {
      const { fund, admin } = await loadFixture(deployFixture);

      expect(await fund.isCoverageEnabled(0)).to.be.true;
      await fund.connect(admin).setCoverageEnabled(0, false);
      expect(await fund.isCoverageEnabled(0)).to.be.false;
    });

    it("should update payout timelock", async function () {
      const { fund, admin } = await loadFixture(deployFixture);

      await fund.connect(admin).setPayoutTimelock(2 * 86400);
      expect(await fund.getPayoutTimelock()).to.equal(172800n);
    });

    it("should reject timelock > 30 days", async function () {
      const { fund, admin } = await loadFixture(deployFixture);

      await expect(
        fund.connect(admin).setPayoutTimelock(31 * 86400)
      ).to.be.revertedWith("Timelock too long");
    });

    it("should reject unauthorized governance actions", async function () {
      const { fund, other } = await loadFixture(deployFixture);

      await expect(
        fund.connect(other).setMaxPayoutPerClaim(100)
      ).to.be.revertedWithCustomError(fund, "UnauthorizedGovernance");
    });
  });

  // ============ View Functions ============

  describe("View Functions", function () {
    it("should return reserve balance", async function () {
      const { fund } = await loadFixture(deployFixture);
      expect(await fund.getReserveBalance()).to.equal(INITIAL_FUND);
    });

    it("should return utilization ratio", async function () {
      const { fund } = await loadFixture(deployFixture);
      expect(await fund.getUtilizationRatio()).to.equal(0n);
    });

    it("should return reserve metrics", async function () {
      const { fund } = await loadFixture(deployFixture);
      const metrics = await fund.getReserveMetrics();

      expect(metrics.currentBalance).to.equal(INITIAL_FUND);
      expect(metrics.totalFunded).to.equal(INITIAL_FUND);
      expect(metrics.totalPaidOut).to.equal(0n);
      expect(metrics.activeClaims).to.equal(0n);
      expect(metrics.utilisationBasisPoints).to.equal(0n);
    });

    it("should return funding history with pagination", async function () {
      const { fund, token, admin } = await loadFixture(deployFixture);

      const amount = ethers.parseEther("100");
      await token.connect(admin).approve(await fund.getAddress(), amount * 3n);
      for (let i = 0; i < 3; i++) {
        await fund.connect(admin).fundReserve(i, amount);
      }

      // Should have 4 records (1 from deploy + 3 new)
      const page1 = await fund.getFundingHistory(0, 2);
      expect(page1.length).to.equal(2);

      const page2 = await fund.getFundingHistory(2, 2);
      expect(page2.length).to.equal(2);
    });

    it("should reject getClaim for non-existent claim", async function () {
      const { fund } = await loadFixture(deployFixture);

      await expect(fund.getClaim(999)).to.be.revertedWithCustomError(
        fund,
        "ClaimNotFound"
      );
    });
  });

  // ============ Access Control ============

  describe("Access Control", function () {
    it("should allow admin to grant INSURANCE_MANAGER_ROLE", async function () {
      const { fund, admin, other } = await loadFixture(deployFixture);

      await fund.connect(admin).grantRole(await fund.INSURANCE_MANAGER_ROLE(), other.address);
      expect(await fund.hasRole(await fund.INSURANCE_MANAGER_ROLE(), other.address)).to.be.true;
    });

    it("should allow pause and unpause", async function () {
      const { fund, admin } = await loadFixture(deployFixture);

      await fund.connect(admin).pause();
      expect(await fund.paused()).to.be.true;

      await fund.connect(admin).unpause();
      expect(await fund.paused()).to.be.false;
    });

    it("should reject submitClaim when paused", async function () {
      const { fund, admin, claimant } = await loadFixture(deployFixture);

      await fund.connect(admin).pause();

      await expect(
        fund.connect(claimant).submitClaim(0, 100, "ipfs://test")
      ).to.be.reverted;
    });

    it("should allow emergency withdrawal by governance", async function () {
      const { fund, governance, token } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("1000");
      const amountStr = amount.toString();

      await fund.connect(governance).emergencyWithdrawal(governance.address, amountStr);

      const balance = await token.balanceOf(governance.address);
      expect(balance).to.be.gte(amount);
    });

    it("should reject emergency withdrawal by non-governance", async function () {
      const { fund, other } = await loadFixture(deployFixture);

      await expect(
        fund.connect(other).emergencyWithdrawal(other.address, 100)
      ).to.be.revertedWithCustomError(fund, "UnauthorizedGovernance");
    });
  });

  // ============ Events ============

  describe("Events", function () {
    it("should emit InsuranceClaimStateUpdated on state changes", async function () {
      const { fund, claimant, insuranceManager } = await loadFixture(deployFixture);

      await fund.connect(claimant).submitClaim(0, 100, "ipfs://test");

      await expect(fund.connect(insuranceManager).updateClaimState(0, 1))
        .to.emit(fund, "InsuranceClaimStateUpdated")
        .withArgs(0, 0, 1, insuranceManager.address);
    });

    it("should emit InsurancePolicyUpdated on config changes", async function () {
      const { fund, admin } = await loadFixture(deployFixture);

      await expect(fund.connect(admin).setMaxPayoutPerClaim(5000))
        .to.emit(fund, "InsurancePolicyUpdated");
    });

    it("should emit EmergencyWithdrawal on emergency withdrawal", async function () {
      const { fund, governance } = await loadFixture(deployFixture);

      await expect(
        fund.connect(governance).emergencyWithdrawal(governance.address, 1000)
      ).to.emit(fund, "EmergencyWithdrawal");
    });
  });
});
