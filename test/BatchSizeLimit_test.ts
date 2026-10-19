import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Audit #156 — Batch Payout Limit
 *
 * Verifies that MAX_BATCH_SIZE is enforced in every batch entry point:
 *   - TruthBountyClaims.settleClaimsBatch  (cap = 200)
 *   - VerifierSlashing.batchSlash          (cap = 50)
 *
 * Boundary cases checked per function:
 *   - empty batch reverts
 *   - exactly MAX_BATCH_SIZE succeeds
 *   - MAX_BATCH_SIZE + 1 reverts
 *   - mismatched array lengths revert
 */

describe("Batch Size Limit (#156)", function () {
  // ============================================================
  // TruthBountyClaims.settleClaimsBatch
  // ============================================================
  describe("TruthBountyClaims.settleClaimsBatch", function () {
    async function deployClaimsFixture() {
      const [owner, treasury, other] = await ethers.getSigners();

      const Token = await ethers.getContractFactory("TruthBountyToken");
      const token = await Token.deploy(owner.address);

      const Claims = await ethers.getContractFactory("TruthBountyClaims");
      const claims = await Claims.deploy(await token.getAddress(), owner.address);

      // Fund the contract so transfers in _settle succeed.
      const funding = ethers.parseEther("1000000");
      await token.transfer(await claims.getAddress(), funding);

      const MAX = Number(await claims.MAX_BATCH_SIZE());

      return { token, claims, owner, treasury, other, MAX };
    }

    // Helper: build N beneficiaries each receiving 1 wei (amount must be > 0).
    function buildBatch(n: number) {
      const beneficiaries: string[] = [];
      const amounts: bigint[] = [];
      for (let i = 0; i < n; i++) {
        beneficiaries.push(ethers.Wallet.createRandom().address);
        amounts.push(1n);
      }
      return { beneficiaries, amounts };
    }

    it("exposes MAX_BATCH_SIZE = 200", async function () {
      const { claims } = await loadFixture(deployClaimsFixture);
      expect(await claims.MAX_BATCH_SIZE()).to.equal(200);
    });

    // V2-SC-062: all settleClaimsBatch calls require a unique settlementId.
    function batchId(tag: string) {
      return ethers.keccak256(ethers.toUtf8Bytes(tag));
    }

    it("reverts on an empty batch", async function () {
      const { claims } = await loadFixture(deployClaimsFixture);
      await expect(claims.settleClaimsBatch([], [], batchId("empty"))).to.be.revertedWith(
        "No claims to settle"
      );
    });

    it("reverts on mismatched array lengths", async function () {
      const { claims } = await loadFixture(deployClaimsFixture);
      const a = ethers.Wallet.createRandom().address;
      await expect(
        claims.settleClaimsBatch([a], [1n, 2n], batchId("mismatch"))
      ).to.be.revertedWith("Arrays length mismatch");
    });

    it("succeeds at exactly MAX_BATCH_SIZE", async function () {
      const { claims, MAX } = await loadFixture(deployClaimsFixture);
      const { beneficiaries, amounts } = buildBatch(MAX);
      await expect(claims.settleClaimsBatch(beneficiaries, amounts, batchId("max")))
        .to.emit(claims, "BatchSettlementCompleted")
        .withArgs(MAX, batchId("max"));
    });

    it("reverts at MAX_BATCH_SIZE + 1", async function () {
      const { claims, MAX } = await loadFixture(deployClaimsFixture);
      const { beneficiaries, amounts } = buildBatch(MAX + 1);
      await expect(
        claims.settleClaimsBatch(beneficiaries, amounts, batchId("oversize"))
      ).to.be.revertedWith("Batch size too large");
    });
  });

  // ============================================================
  // VerifierSlashing.batchSlash
  // ============================================================
  describe("VerifierSlashing.batchSlash", function () {
    async function deploySlashingFixture() {
      const [owner, admin, settlement] = await ethers.getSigners();

      const Token = await ethers.getContractFactory("TruthBountyToken");
      const token = await Token.deploy(owner.address);

      const Staking = await ethers.getContractFactory("Staking");
      const staking = await Staking.deploy(
        await token.getAddress(),
        86400,
        owner.address
      );

      const MockTreasuryAccounting = await ethers.getContractFactory("MockTreasuryAccounting");
      const treasuryAccounting = await MockTreasuryAccounting.deploy();
      await staking.connect(owner).setTreasuryAccounting(await treasuryAccounting.getAddress());

      const VerifierSlashing = await ethers.getContractFactory("VerifierSlashing");
      const slashing = await VerifierSlashing.deploy(
        await staking.getAddress(),
        admin.address,
        admin.address
      );

      await staking.connect(owner).setSlashingContract(await slashing.getAddress());

      // Grant resolver/settlement role via the timelock.
      await slashing.connect(admin).scheduleResolverRoleGrant(settlement.address);
      await time.increase(2 * 24 * 60 * 60);
      await staking.executeResolverRoleGrant(await slashing.getAddress());
      await slashing.executeResolverRoleGrant(settlement.address);

      const MAX = Number(await slashing.MAX_BATCH_SIZE());

      return { token, staking, slashing, owner, admin, settlement, MAX };
    }

    // Build N distinct staked verifiers so each slash actually has stake to cut.
    async function buildStakedBatch(
      token: any,
      staking: any,
      n: number,
      percentage = 1
    ) {
      const verifiers: string[] = [];
      const percentages: number[] = [];
      const reasons: string[] = [];
      const stakeAmount = ethers.parseEther("100");

      for (let i = 0; i < n; i++) {
        const w = ethers.Wallet.createRandom().connect(ethers.provider);
        // Fund the EOA with gas + stake.
        await (await ethers.getSigners())[0].sendTransaction({
          to: w.address,
          value: ethers.parseEther("1"),
        });
        await token.transfer(w.address, stakeAmount);
        await token.connect(w).approve(await staking.getAddress(), stakeAmount);
        await staking.connect(w).stake(stakeAmount);

        verifiers.push(w.address);
        percentages.push(percentage);
        reasons.push("batch");
      }
      return { verifiers, percentages, reasons };
    }

    it("exposes MAX_BATCH_SIZE = 50", async function () {
      const { slashing } = await loadFixture(deploySlashingFixture);
      expect(await slashing.MAX_BATCH_SIZE()).to.equal(50);
    });

    it("reverts on an empty batch with EmptyBatch", async function () {
      const { slashing, settlement } = await loadFixture(deploySlashingFixture);
      await expect(
        slashing.connect(settlement).batchSlash([], [], [])
      ).to.be.revertedWithCustomError(slashing, "EmptyBatch");
    });

    it("reverts on mismatched array lengths with BatchLengthMismatch", async function () {
      const { slashing, settlement } = await loadFixture(deploySlashingFixture);
      const a = ethers.Wallet.createRandom().address;
      await expect(
        slashing.connect(settlement).batchSlash([a], [10, 15], ["r"])
      ).to.be.revertedWithCustomError(slashing, "BatchLengthMismatch");
    });

    it("reverts at MAX_BATCH_SIZE + 1 with BatchSizeExceeded", async function () {
      const { slashing, settlement, MAX } = await loadFixture(deploySlashingFixture);
      // No need to stake — the size check happens before any per-item work.
      const verifiers = Array.from({ length: MAX + 1 }, () =>
        ethers.Wallet.createRandom().address
      );
      const percentages = Array.from({ length: MAX + 1 }, () => 1);
      const reasons = Array.from({ length: MAX + 1 }, () => "r");

      await expect(
        slashing.connect(settlement).batchSlash(verifiers, percentages, reasons)
      )
        .to.be.revertedWithCustomError(slashing, "BatchSizeExceeded")
        .withArgs(MAX + 1, MAX);
    });

    it("succeeds at exactly MAX_BATCH_SIZE", async function () {
      const { token, staking, slashing, settlement, MAX } = await loadFixture(
        deploySlashingFixture
      );
      const { verifiers, percentages, reasons } = await buildStakedBatch(
        token,
        staking,
        MAX
      );

      await expect(
        slashing.connect(settlement).batchSlash(verifiers, percentages, reasons)
      ).to.not.be.reverted;

      // Spot-check first and last were slashed.
      expect(await slashing.getSlashCount(verifiers[0])).to.equal(1);
      expect(await slashing.getSlashCount(verifiers[MAX - 1])).to.equal(1);
    });
  });

  // ============================================================
  // MockReputationOracle.batchSetReputationScores
  // (test/dev mock — capped for consistency, not a production fix)
  // ============================================================
  describe("MockReputationOracle.batchSetReputationScores", function () {
    async function deployOracleFixture() {
      const [owner] = await ethers.getSigners();
      const Oracle = await ethers.getContractFactory("MockReputationOracle");
      const oracle = await Oracle.deploy();
      const MAX = Number(await oracle.MAX_BATCH_SIZE());
      return { oracle, owner, MAX };
    }

    function buildScores(n: number) {
      const users: string[] = [];
      const scores: bigint[] = [];
      for (let i = 0; i < n; i++) {
        users.push(ethers.Wallet.createRandom().address);
        scores.push(ethers.parseEther("1"));
      }
      return { users, scores };
    }

    it("exposes MAX_BATCH_SIZE = 200", async function () {
      const { oracle } = await loadFixture(deployOracleFixture);
      expect(await oracle.MAX_BATCH_SIZE()).to.equal(200);
    });

    it("reverts on an empty batch", async function () {
      const { oracle } = await loadFixture(deployOracleFixture);
      await expect(
        oracle.batchSetReputationScores([], [])
      ).to.be.revertedWith("Empty batch");
    });

    it("reverts on mismatched array lengths", async function () {
      const { oracle } = await loadFixture(deployOracleFixture);
      const a = ethers.Wallet.createRandom().address;
      await expect(
        oracle.batchSetReputationScores([a], [1n, 2n])
      ).to.be.revertedWith("Array length mismatch");
    });

    it("succeeds at exactly MAX_BATCH_SIZE", async function () {
      const { oracle, MAX } = await loadFixture(deployOracleFixture);
      const { users, scores } = buildScores(MAX);
      await expect(oracle.batchSetReputationScores(users, scores)).to.not.be
        .reverted;
      expect(await oracle.getReputationScore(users[0])).to.equal(scores[0]);
    });

    it("reverts at MAX_BATCH_SIZE + 1", async function () {
      const { oracle, MAX } = await loadFixture(deployOracleFixture);
      const { users, scores } = buildScores(MAX + 1);
      await expect(
        oracle.batchSetReputationScores(users, scores)
      ).to.be.revertedWith("Batch size too large");
    });
  });
});
