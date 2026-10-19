import { expect } from "chai";
import { ethers } from "hardhat";

describe("FinalRewardAllocator", function () {
  async function deploy() {
    const [admin, settlement, first, second, remainder] = await ethers.getSigners();
    const registry = await (await ethers.getContractFactory("MockModuleRegistry")).deploy();
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Reward", "RWD");
    const allocator = await (await ethers.getContractFactory("FinalRewardAllocator")).deploy(
      registry,
      8,
    );
    await registry.registerModule(await allocator.MODULE_SETTLEMENT(), settlement.address);
    await token.mint(settlement.address, 1000);
    await token.connect(settlement).approve(allocator, 1000);
    return { admin, settlement, first, second, remainder, registry, token, allocator };
  }

  it("records weighted entitlements and sends integer remainder explicitly", async function () {
    const { settlement, first, second, remainder, token, allocator } = await deploy();
    const settlementId = ethers.id("settlement-1");
    await allocator.connect(settlement).fund(token, 101, settlementId);
    await allocator.connect(settlement).finalizeRewards(settlementId, token, 0, [{
      category: 2,
      accounts: [first.address, second.address],
      effectiveWeights: [1, 2],
      amount: 101,
      remainderRecipient: remainder.address,
    }]);

    expect(await allocator.claimable(token, first)).to.equal(33);
    expect(await allocator.claimable(token, second)).to.equal(67);
    expect(await allocator.claimable(token, remainder)).to.equal(1);
    expect(await allocator.finalized(settlementId)).to.equal(true);
  });

  it("rejects duplicate finalization and allocation beyond the tagged pool", async function () {
    const { settlement, first, token, allocator } = await deploy();
    const settlementId = ethers.id("settlement-2");
    await allocator.connect(settlement).fund(token, 10, settlementId);
    const allocation = {
      category: 0,
      accounts: [first.address],
      effectiveWeights: [1],
      amount: 11,
      remainderRecipient: first.address,
    };
    await expect(allocator.connect(settlement).finalizeRewards(settlementId, token, 1, [allocation]))
      .to.be.revertedWithCustomError(allocator, "PoolExceeded");

    const valid = { ...allocation, amount: 10 };
    await allocator.connect(settlement).finalizeRewards(settlementId, token, 1, [valid]);
    await expect(allocator.connect(settlement).finalizeRewards(settlementId, token, 1, [valid]))
      .to.be.revertedWithCustomError(allocator, "SettlementAlreadyFinalized");
  });

  it("allows only the registered settlement module to create pools", async function () {
    const { admin, token, allocator } = await deploy();
    await token.mint(admin.address, 1);
    await token.approve(allocator, 1);
    await expect(allocator.fund(token, 1, ethers.id("unauthorized")))
      .to.be.revertedWithCustomError(allocator, "UnauthorizedSettlementModule");
  });
});
