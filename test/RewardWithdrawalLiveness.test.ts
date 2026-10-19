import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

/**
 * PREWAVE-SC-051 — Prove Withdrawal Liveness Under Hostile Recipients.
 *
 * These tests exercise the pull/retry-safe payout paths and prove that:
 *  - one hostile recipient cannot block other recipients;
 *  - a failed payout remains owed exactly once;
 *  - retry is permission-safe;
 *  - custody is conserved.
 */
describe("SC-051 Withdrawal liveness under hostile recipients", function () {
  // HostileRecipientERC20.Fault
  const NONE = 0;
  const REVERT = 1;
  const RETURN_FALSE = 2;

  const CLAIMABLE = 1;
  const DISTRIBUTED = 2;

  async function deployFixture() {
    const [admin, distributor, alice, bob, outsider] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("HostileRecipientERC20");
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

    const funding = ethers.parseEther("1000000");
    await token.approve(await rewards.getAddress(), funding);
    await rewards.fundRewardPool(funding);

    // A contract recipient whose transfers always revert.
    const Hostile = await ethers.getContractFactory("HostileTokenRecipient");
    const hostileRecipient = await Hostile.deploy();

    const Queue = await ethers.getContractFactory("RewardDeferralQueue");
    const queue = await Queue.deploy(await rewards.getAddress(), admin.address);
    await rewards.grantRole(distributorRole, await queue.getAddress());
    const enqueueRole = await queue.ENQUEUE_ROLE();
    await queue.grantRole(enqueueRole, admin.address);

    const ids = {
      sA: ethers.id("settlement-a"),
      sB: ethers.id("settlement-b"),
      sC: ethers.id("settlement-c"),
      cA: ethers.id("calculation-a"),
      cB: ethers.id("calculation-b"),
      cC: ethers.id("calculation-c"),
    };

    return {
      admin,
      distributor,
      alice,
      bob,
      outsider,
      token,
      rewards,
      queue,
      hostileRecipient,
      funding,
      ids,
    };
  }

  function distributionId(
    recipient: string,
    claimId: bigint,
    settlementId: string,
    calculationId: string
  ) {
    return ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "bytes32", "bytes32"],
        [recipient, claimId, settlementId, calculationId]
      )
    );
  }

  it("isolates a reverting recipient: others are paid, the hostile row stays owed", async function () {
    const { rewards, token, distributor, alice, hostileRecipient, ids } =
      await loadFixture(deployFixture);

    const hostile = await hostileRecipient.getAddress();
    await token.setFault(hostile, REVERT);

    const amountHostile = ethers.parseEther("100");
    const amountAlice = ethers.parseEther("200");

    const hostileId = distributionId(hostile, 1n, ids.sA, ids.cA);
    const aliceId = distributionId(alice.address, 2n, ids.sB, ids.cB);

    await expect(
      rewards.connect(distributor).allocateRewardsBatch(
        [hostile, alice.address],
        [1n, 2n],
        [ids.sA, ids.sB],
        [ids.cA, ids.cB],
        [amountHostile, amountAlice],
        [true, true]
      )
    )
      .to.emit(rewards, "RewardAllocationDeferred")
      .withArgs(hostile, hostileId, amountHostile);

    // The non-hostile recipient was still paid in full.
    expect(await token.balanceOf(alice.address)).to.equal(amountAlice);

    // The hostile row is recorded as a pull credit (owed exactly once).
    const hostileRecord = await rewards.rewardDistributions(hostileId);
    expect(hostileRecord.status).to.equal(CLAIMABLE);
    expect(await rewards.claimableRewards(hostile)).to.equal(amountHostile);

    // Custody is conserved: engine balance == reserved (owed) + available (idle).
    const engineBalance = await token.balanceOf(await rewards.getAddress());
    expect(engineBalance).to.equal(
      (await rewards.totalReserved()) +
        (await rewards.availableRewardBalance())
    );
  });

  it("isolates a false-returning recipient and keeps custody conserved", async function () {
    const { rewards, token, distributor, alice, bob, ids } =
      await loadFixture(deployFixture);

    await token.setFault(bob.address, RETURN_FALSE);

    const amountBob = ethers.parseEther("150");
    const amountAlice = ethers.parseEther("50");
    const bobId = distributionId(bob.address, 10n, ids.sA, ids.cA);

    await expect(
      rewards.connect(distributor).allocateRewardsBatch(
        [alice.address, bob.address],
        [11n, 10n],
        [ids.sB, ids.sA],
        [ids.cB, ids.cA],
        [amountAlice, amountBob],
        [true, true]
      )
    )
      .to.emit(rewards, "RewardAllocationDeferred")
      .withArgs(bob.address, bobId, amountBob);

    expect(await token.balanceOf(alice.address)).to.equal(amountAlice);
    expect((await rewards.rewardDistributions(bobId)).status).to.equal(
      CLAIMABLE
    );
    expect(await rewards.claimableRewards(bob.address)).to.equal(amountBob);
  });

  it("retries a deferred payout exactly once and only the entitled caller may retry", async function () {
    const { rewards, token, distributor, bob, outsider, ids } =
      await loadFixture(deployFixture);

    await token.setFault(bob.address, RETURN_FALSE);

    const amount = ethers.parseEther("321");
    const bobId = distributionId(bob.address, 42n, ids.sA, ids.cA);

    await rewards.connect(distributor).allocateRewardsBatch(
      [bob.address],
      [42n],
      [ids.sA],
      [ids.cA],
      [amount],
      [true]
    );

    // Owed exactly once, not paid yet.
    expect((await rewards.rewardDistributions(bobId)).status).to.equal(
      CLAIMABLE
    );
    expect(await token.balanceOf(bob.address)).to.equal(0);
    const distributedBefore = await rewards.totalDistributed();

    // A third party cannot redirect or claim another account's credit.
    await expect(
      rewards.connect(outsider).claimReward(bobId)
    ).to.be.revertedWithCustomError(rewards, "UnauthorizedRewardClaim");

    // Later recovery: once the recipient can receive, it pulls its balance.
    await token.setFault(bob.address, NONE);
    await expect(rewards.connect(bob).claimReward(bobId))
      .to.emit(rewards, "RewardClaimed")
      .withArgs(bob.address, bobId, amount);

    expect(await token.balanceOf(bob.address)).to.equal(amount);
    expect(await rewards.totalDistributed()).to.equal(
      distributedBefore + amount
    );

    // Retrying cannot double-pay.
    await expect(
      rewards.connect(bob).claimReward(bobId)
    ).to.be.revertedWithCustomError(rewards, "RewardNotClaimable");
    expect(await token.balanceOf(bob.address)).to.equal(amount);
  });

  it("deferral queue isolates a hostile entry and keeps it retryable by anyone", async function () {
    const { queue, rewards, token, alice, bob, outsider, ids } =
      await loadFixture(deployFixture);

    await token.setFault(bob.address, RETURN_FALSE);

    const amountBob = ethers.parseEther("75");
    const amountAlice = ethers.parseEther("25");

    await queue.enqueue(bob.address, 1n, ids.sA, ids.cA, amountBob);
    await queue.enqueue(alice.address, 2n, ids.sB, ids.cB, amountAlice);

    // Discover queue ids (enqueue returns them only off-chain; read from storage).
    const bobId = await queue.queueIdAt(0);
    const aliceId = await queue.queueIdAt(1);

    await expect(queue.fulfillBatch([bobId, aliceId]))
      .to.emit(queue, "RewardFulfillmentDeferred")
      .withArgs(bobId, bob.address, amountBob);

    // Non-hostile entry fulfilled; hostile entry remains PENDING (owed once).
    expect(await queue.isFulfilled(aliceId)).to.equal(true);
    expect(await queue.isPending(bobId)).to.equal(true);
    expect(await token.balanceOf(alice.address)).to.equal(amountAlice);
    expect(await token.balanceOf(bob.address)).to.equal(0);
    expect(await queue.totalFulfilled()).to.equal(1n);

    // Recovery: once the recipient can receive, ANY caller can retry the entry.
    await token.setFault(bob.address, NONE);
    await expect(queue.connect(outsider).fulfill(bobId))
      .to.emit(queue, "RewardFulfilled")
      .withArgs(bobId, bob.address, amountBob);

    expect(await token.balanceOf(bob.address)).to.equal(amountBob);
    expect(await queue.isFulfilled(bobId)).to.equal(true);
    // Exactly once.
    await expect(queue.fulfill(bobId)).to.be.revertedWithCustomError(
      queue,
      "AlreadyFulfilled"
    );
    expect(await token.balanceOf(bob.address)).to.equal(amountBob);

    // Engine custody still conserved.
    const engineBalance = await token.balanceOf(await rewards.getAddress());
    expect(engineBalance).to.equal(
      (await rewards.totalReserved()) +
        (await rewards.availableRewardBalance())
    );
  });

  it("keeps non-immediate batch rows and same-block exits working alongside a hostile row", async function () {
    const { rewards, token, distributor, alice, bob, hostileRecipient, ids } =
      await loadFixture(deployFixture);

    const hostile = await hostileRecipient.getAddress();
    await token.setFault(hostile, REVERT);

    const claimableAmount = ethers.parseEther("10");
    const immediateAmount = ethers.parseEther("40");
    const hostileAmount = ethers.parseEther("20");

    const claimableId = distributionId(bob.address, 1n, ids.sA, ids.cA);

    // One row is a pull credit, one an immediate payout to a clean recipient, and
    // one an immediate payout to a hostile recipient — all in one transaction.
    await rewards.connect(distributor).allocateRewardsBatch(
      [bob.address, alice.address, hostile],
      [1n, 2n, 3n],
      [ids.sA, ids.sB, ids.sC],
      [ids.cA, ids.cB, ids.cC],
      [claimableAmount, immediateAmount, hostileAmount],
      [false, true, true]
    );

    expect(await rewards.claimableRewards(bob.address)).to.equal(
      claimableAmount
    );
    expect((await rewards.rewardDistributions(claimableId)).status).to.equal(
      CLAIMABLE
    );
    expect(await token.balanceOf(alice.address)).to.equal(immediateAmount);
    expect(await rewards.claimableRewards(hostile)).to.equal(hostileAmount);

    // No immediate payout leaked to the hostile recipient.
    expect(await token.balanceOf(hostile)).to.equal(0);
  });

  it("the batch isolation trampoline is not externally callable", async function () {
    const { rewards, alice, outsider, ids } = await loadFixture(deployFixture);

    await expect(
      rewards.connect(outsider)._allocateRewardExternal(
        alice.address,
        1n,
        ids.sA,
        ids.cA,
        ethers.parseEther("1"),
        true
      )
    ).to.be.revertedWithCustomError(rewards, "SelfCallOnly");
  });
});
