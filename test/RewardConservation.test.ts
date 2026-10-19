import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

/*
 * PREWAVE-SC-038 — Reward Accrual and Claim Conservation
 * ─────────────────────────────────────────────────────────
 * Acceptance criteria verification:
 *   1. Claimed + pending + retained dust equals funded allocation.
 *   2. Repeat claims are single-pay.
 *   3. Rounding policy is explicit (floor division, documented).
 *   4. Insufficient funding fails without corrupting accrual.
 */

describe("RewardEngine SC-038 Conservation", function () {
  async function deployFixture() {
    const [admin, distributor, recipientA, recipientB] =
      await ethers.getSigners();

    const Token = await ethers.getContractFactory("MockRewardToken");
    const token = await Token.deploy();

    const Oracle = await ethers.getContractFactory(
      "MockRewardReputationOracle"
    );
    const oracle = await Oracle.deploy();

    const RewardEngine = await ethers.getContractFactory("RewardEngine");
    const rewards = await RewardEngine.deploy(
      await oracle.getAddress(),
      admin.address,
      admin.address
    );

    await rewards.setRewardToken(await token.getAddress());

    const distributorRole = await rewards.DISTRIBUTOR_ROLE();
    await rewards.grantRole(distributorRole, distributor.address);

    return {
      admin,
      distributor,
      recipientA,
      recipientB,
      token,
      oracle,
      rewards,
    };
  }

  // ── AC1: Claimed + pending + retained dust == funded ──────────────────

  it("AC1: claimed + pending + retained dust equals funded allocation", async function () {
    const { rewards, token, distributor, recipientA } =
      await loadFixture(deployFixture);

    const funding = ethers.parseEther("100000");
    await token.approve(await rewards.getAddress(), funding);
    await rewards.fundRewardPool(funding);

    // Allocate some claimable, some immediate
    const claimableAmt = ethers.parseEther("120");
    const immediateAmt = ethers.parseEther("80");
    const settlementA = ethers.id("settlement-a");
    const calcA = ethers.id("calc-a");
    const settlementB = ethers.id("settlement-b");
    const calcB = ethers.id("calc-b");

    await rewards
      .connect(distributor)
      .allocateReward(recipientA.address, 1, settlementA, calcA, claimableAmt, false);
    await rewards
      .connect(distributor)
      .allocateReward(recipientA.address, 2, settlementB, calcB, immediateAmt, true);

    const distributed = await rewards.totalDistributed();
    const reserved = await rewards.totalReserved();
    const available = await rewards.availableRewardBalance();
    const funded = await rewards.totalFunded();

    // claimed + pending + retained dust == funded
    expect(distributed + reserved + available).to.equal(funded);
    expect(funded).to.equal(funding);

    // funded - distributed == token balance
    const balance = await token.balanceOf(await rewards.getAddress());
    expect(funded - distributed).to.equal(balance);
  });

  // ── AC2: Repeat claims are single-pay ─────────────────────────────────

  it("AC2: repeat claims are single-pay (claiming twice reverts)", async function () {
    const { rewards, token, distributor, recipientA } =
      await loadFixture(deployFixture);

    const funding = ethers.parseEther("10000");
    await token.approve(await rewards.getAddress(), funding);
    await rewards.fundRewardPool(funding);

    const amount = ethers.parseEther("500");
    const settlement = ethers.id("settlement");
    const calc = ethers.id("calc");
    const distId = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "bytes32", "bytes32"],
        [recipientA.address, 1, settlement, calc]
      )
    );

    await rewards
      .connect(distributor)
      .allocateReward(recipientA.address, 1, settlement, calc, amount, false);

    // First claim succeeds
    await expect(rewards.connect(recipientA).claimReward(distId))
      .to.emit(rewards, "RewardClaimed")
      .withArgs(recipientA.address, distId, amount);

    // Second claim on same distribution ID reverts
    await expect(
      rewards.connect(recipientA).claimReward(distId)
    ).to.be.revertedWithCustomError(rewards, "RewardNotClaimable");

    // claimableRewards is 0 after single claim
    expect(await rewards.claimableRewards(recipientA.address)).to.equal(0);
  });

  // ── AC2b: batch repeat claims are single-pay ──────────────────────────

  it("AC2b: batch claim with already-claimed ID reverts", async function () {
    const { rewards, token, distributor, recipientA } =
      await loadFixture(deployFixture);

    const funding = ethers.parseEther("10000");
    await token.approve(await rewards.getAddress(), funding);
    await rewards.fundRewardPool(funding);

    const id1 = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "bytes32", "bytes32"],
        [recipientA.address, 101, ethers.id("s1"), ethers.id("c1")]
      )
    );
    const id2 = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "bytes32", "bytes32"],
        [recipientA.address, 102, ethers.id("s2"), ethers.id("c2")]
      )
    );

    await rewards
      .connect(distributor)
      .allocateReward(recipientA.address, 101, ethers.id("s1"), ethers.id("c1"), ethers.parseEther("100"), false);
    await rewards
      .connect(distributor)
      .allocateReward(recipientA.address, 102, ethers.id("s2"), ethers.id("c2"), ethers.parseEther("200"), false);

    // Claim first one
    await rewards.connect(recipientA).claimReward(id1);

    // Batch claim including already-claimed ID reverts
    await expect(
      rewards.connect(recipientA).claimRewardsBatch([id1, id2])
    ).to.be.revertedWithCustomError(rewards, "RewardNotClaimable");

    // State unchanged after failed batch
    expect(await rewards.claimableRewards(recipientA.address)).to.equal(
      ethers.parseEther("200")
    );
    expect(await rewards.totalDistributed()).to.equal(0);
  });

  // ── AC3: Rounding policy is explicit (floor) ──────────────────────────

  it("AC3: rounding is floor division — allocateReward preserves exact amounts", async function () {
    const { rewards, token, distributor, recipientA } =
      await loadFixture(deployFixture);

    const funding = ethers.parseEther("10000");
    await token.approve(await rewards.getAddress(), funding);
    await rewards.fundRewardPool(funding);

    // Allocate exact small amounts that would expose rounding
    const amounts = [
      1n,
      ethers.parseEther("0.001"),
      ethers.parseEther("0.01"),
      ethers.parseEther("1"),
      ethers.parseEther("100"),
    ];

    let expectedReserved = 0n;
    for (let i = 0; i < amounts.length; i++) {
      await rewards
        .connect(distributor)
        .allocateReward(
          recipientA.address,
          BigInt(i + 1),
          ethers.id(`s-${i}`),
          ethers.id(`c-${i}`),
          amounts[i],
          false
        );
      expectedReserved += amounts[i];
    }

    // No rounding loss: reserved equals sum of exact inputs
    expect(await rewards.totalReserved()).to.equal(expectedReserved);
    expect(await rewards.totalAllocated()).to.equal(expectedReserved);
    expect(await rewards.claimableRewards(recipientA.address)).to.equal(
      expectedReserved
    );
  });

  // ── AC4: Insufficient funding fails without corrupting accrual ────────

  it("AC4: insufficient funding reverts WITHOUT corrupting accrual state", async function () {
    const { rewards, token, distributor, recipientA } =
      await loadFixture(deployFixture);

    const funding = ethers.parseEther("100");
    await token.approve(await rewards.getAddress(), funding);
    await rewards.fundRewardPool(funding);

    // Snapshot pre-state
    const preFunded = await rewards.totalFunded();
    const preAllocated = await rewards.totalAllocated();
    const preDistributed = await rewards.totalDistributed();
    const preReserved = await rewards.totalReserved();
    const preBalance = await token.balanceOf(await rewards.getAddress());
    const preClaimable = await rewards.claimableRewards(recipientA.address);

    // Attempt to allocate more than available
    const oversized = funding + 1n;
    await expect(
      rewards
        .connect(distributor)
        .allocateReward(recipientA.address, 999, ethers.id("s"), ethers.id("c"), oversized, false)
    ).to.be.revertedWithCustomError(rewards, "InsufficientRewardPool");

    // State is completely unchanged
    expect(await rewards.totalFunded()).to.equal(preFunded);
    expect(await rewards.totalAllocated()).to.equal(preAllocated);
    expect(await rewards.totalDistributed()).to.equal(preDistributed);
    expect(await rewards.totalReserved()).to.equal(preReserved);
    expect(await token.balanceOf(await rewards.getAddress())).to.equal(
      preBalance
    );
    expect(await rewards.claimableRewards(recipientA.address)).to.equal(
      preClaimable
    );
    // No distribution record was created
    const postRecord = await rewards.rewardDistributions(
      ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["address", "uint256", "bytes32", "bytes32"],
          [recipientA.address, 999, ethers.id("s"), ethers.id("c")]
        )
      )
    );
    expect(postRecord.status).to.equal(0); // NONE
  });

  // ── Multi-user, multi-round scenario ───────────────────────────────────

  it("multi-user multi-round: conservation holds across many actors and rounds", async function () {
    const { rewards, token, distributor, recipientA, recipientB } =
      await loadFixture(deployFixture);

    const funding = ethers.parseEther("1000000");
    await token.approve(await rewards.getAddress(), funding);
    await rewards.fundRewardPool(funding);

    const rounds = 5;
    const perRound = [
      ethers.parseEther("50"),
      ethers.parseEther("100"),
      ethers.parseEther("0.5"),
      ethers.parseEther("200"),
      ethers.parseEther("1"),
    ];

    let expectedDistributed = 0n;
    let expectedReserved = 0n;

    for (let r = 0; r < rounds; r++) {
      // Round r: allocate to A (claimable) and B (immediate)
      const claimable = perRound[r];
      const immediate = ethers.parseEther(String(10 ** (r % 3 + 1)));

      const claimId = BigInt(r + 1);
      const settlement = ethers.id(`settlement-${r}`);
      const calc = ethers.id(`calc-${r}`);

      await rewards
        .connect(distributor)
        .allocateReward(recipientA.address, claimId, settlement, calc, claimable, false);
      await rewards
        .connect(distributor)
        .allocateReward(recipientB.address, claimId + 1000, settlement, calc, immediate, true);

      expectedReserved += claimable;
      expectedDistributed += immediate;
    }

    expect(await rewards.totalDistributed()).to.equal(expectedDistributed);
    expect(await rewards.totalReserved()).to.equal(expectedReserved);
    expect(await rewards.totalAllocated()).to.equal(expectedDistributed + expectedReserved);

    // Conservation
    const available = await rewards.availableRewardBalance();
    const funded = await rewards.totalFunded();
    expect(expectedDistributed + expectedReserved + available).to.equal(funded);

    // Per-recipient claimable correctness
    let aSum = 0n;
    for (let r = 0; r < rounds; r++) {
      aSum += perRound[r];
    }
    expect(await rewards.claimableRewards(recipientA.address)).to.equal(aSum);
    expect(await rewards.claimableRewards(recipientB.address)).to.equal(0);
  });

  // ── Zero/dust edge cases ───────────────────────────────────────────────

  it("zero/dust: allocating 1 wei works, claiming returns exactly 1 wei", async function () {
    const { rewards, token, distributor, recipientA } =
      await loadFixture(deployFixture);

    const funding = ethers.parseEther("100");
    await token.approve(await rewards.getAddress(), funding);
    await rewards.fundRewardPool(funding);

    const dustAmount = 1n; // 1 wei
    const settlement = ethers.id("dust-settlement");
    const calc = ethers.id("dust-calc");
    const distId = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "bytes32", "bytes32"],
        [recipientA.address, 1, settlement, calc]
      )
    );

    await rewards
      .connect(distributor)
      .allocateReward(recipientA.address, 1, settlement, calc, dustAmount, false);

    expect(await rewards.claimableRewards(recipientA.address)).to.equal(dustAmount);

    const balBefore = await token.balanceOf(recipientA.address);
    await rewards.connect(recipientA).claimReward(distId);
    const balAfter = await token.balanceOf(recipientA.address);

    expect(balAfter - balBefore).to.equal(dustAmount);
    expect(await rewards.claimableRewards(recipientA.address)).to.equal(0);
  });

  // ── Max-value fuzz-like stress ─────────────────────────────────────────

  it("max-value: funding with large amounts preserves conservation", async function () {
    const { rewards, token, distributor, recipientA } =
      await loadFixture(deployFixture);

    // Fund with a very large amount
    const largeFunding = ethers.parseEther("1000000"); // 1M ETH
    await token.approve(await rewards.getAddress(), largeFunding);
    await rewards.fundRewardPool(largeFunding);

    // Allocate the maximum possible (all of it) as claimable
    const allocAmount = largeFunding;
    await rewards
      .connect(distributor)
      .allocateReward(recipientA.address, 1, ethers.id("s"), ethers.id("c"), allocAmount, false);

    // Conservation must hold
    const distributed = await rewards.totalDistributed();
    const reserved = await rewards.totalReserved();
    const available = await rewards.availableRewardBalance();
    const funded = await rewards.totalFunded();

    expect(distributed + reserved + available).to.equal(funded);
    expect(reserved).to.equal(largeFunding);
    expect(distributed).to.equal(0);

    // Claim it
    const distId = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "bytes32", "bytes32"],
        [recipientA.address, 1, ethers.id("s"), ethers.id("c")]
      )
    );
    await rewards.connect(recipientA).claimReward(distId);

    expect(await rewards.totalDistributed()).to.equal(largeFunding);
    expect(await rewards.totalReserved()).to.equal(0);
    expect(await rewards.availableRewardBalance()).to.equal(0);
    expect(distributed + reserved + available).to.equal(funded);
  });

  // ── Allocation then failed claim doesn't leak state ────────────────────

  it("failed claim reverts without changing any state", async function () {
    const { rewards, token, distributor, recipientA, recipientB } =
      await loadFixture(deployFixture);

    const funding = ethers.parseEther("1000");
    await token.approve(await rewards.getAddress(), funding);
    await rewards.fundRewardPool(funding);

    const distId = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "bytes32", "bytes32"],
        [recipientA.address, 1, ethers.id("s"), ethers.id("c")]
      )
    );

    await rewards
      .connect(distributor)
      .allocateReward(recipientA.address, 1, ethers.id("s"), ethers.id("c"), ethers.parseEther("100"), false);

    // Non-recipient tries to claim — must revert
    await expect(
      rewards.connect(recipientB).claimReward(distId)
    ).to.be.revertedWithCustomError(rewards, "UnauthorizedRewardClaim");

    // State unchanged
    expect(await rewards.claimableRewards(recipientA.address)).to.equal(
      ethers.parseEther("100")
    );
    expect(await rewards.totalReserved()).to.equal(ethers.parseEther("100"));
    expect(await rewards.totalDistributed()).to.equal(0);
  });
});
