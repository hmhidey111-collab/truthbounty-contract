import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("VerifierSlashing Fuzz and Invariants", function () {
  async function deployFixture() {
    const [owner, admin, settlement, verifier] = await ethers.getSigners();

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

    const Slashing = await ethers.getContractFactory("VerifierSlashing");
    const slashing = await Slashing.deploy(
      await staking.getAddress(),
      admin.address,
      admin.address
    );

    await staking.connect(owner).setSlashingContract(
      await slashing.getAddress()
    );

    const SETTLEMENT_ROLE = await slashing.SETTLEMENT_ROLE();
    await slashing.connect(admin).scheduleResolverRoleGrant(
      settlement.address
    );

    await time.increase(2 * 24 * 60 * 60);
    await staking.executeResolverRoleGrant(await slashing.getAddress());
    await slashing.executeResolverRoleGrant(settlement.address);

    await staking.connect(owner).setTreasury(admin.address);

    const stakeAmount = ethers.parseEther("1000");
    await token.transfer(verifier.address, stakeAmount);
    await token
      .connect(verifier)
      .approve(await staking.getAddress(), stakeAmount);
    await staking.connect(verifier).stake(stakeAmount);

    return {
      token,
      staking,
      slashing,
      treasuryAccounting,
      owner,
      admin,
      settlement,
      verifier,
      stakeAmount,
      SETTLEMENT_ROLE
    };
  }

  it("fuzzes partial slash percentages deterministically", async function () {
    for (const percentage of [1, 3, 7, 10, 17, 25, 33, 49, 50]) {
      const {
        staking,
        slashing,
        settlement,
        verifier,
        stakeAmount
      } = await loadFixture(deployFixture);

      const expected = (stakeAmount * BigInt(percentage)) / 100n;

      await slashing.connect(settlement).slashVerifier(
        verifier.address,
        percentage,
        0,
        percentage,
        `fuzz-${percentage}`
      );

      const [remaining] = await staking.stakes(verifier.address);

      expect(remaining).to.equal(stakeAmount - expected);
      expect(await slashing.totalSlashed(verifier.address)).to.equal(
        expected
      );
    }
  });

  it("preserves locked stake accounting invariant", async function () {
    const {
      token,
      staking,
      slashing,
      admin,
      settlement,
      verifier,
      stakeAmount
    } = await loadFixture(deployFixture);

    const treasuryBefore = await token.balanceOf(admin.address);

    await slashing.connect(settlement).slashVerifier(
      verifier.address,
      9001,
      0,
      20,
      "first"
    );

    await slashing.connect(settlement).slashVerifier(
      verifier.address,
      9002,
      0,
      25,
      "second"
    );

    const [remainingStake] = await staking.stakes(verifier.address);
    const totalSlashed = await slashing.totalSlashed(verifier.address);
    const treasuryDelta =
      (await token.balanceOf(admin.address)) - treasuryBefore;

    expect(remainingStake + totalSlashed).to.equal(stakeAmount);
    expect(treasuryDelta).to.equal(totalSlashed);
    expect(
      await token.balanceOf(await staking.getAddress())
    ).to.equal(remainingStake);
  });

  it("rejects invalid percentages across boundary values", async function () {
    const { slashing, settlement, verifier } =
      await loadFixture(deployFixture);

    for (const percentage of [0, 51, 75, 100, 101, 1000]) {
      await expect(
        slashing.connect(settlement).slashVerifier(
          verifier.address,
          10000 + percentage,
          0,
          percentage,
          `invalid-${percentage}`
        )
      ).to.be.revertedWithCustomError(
        slashing,
        "InvalidPercentage"
      );
    }
  });

  it("records gas for partial and full slashing", async function () {
    const partial = await loadFixture(deployFixture);

    const partialTx = await partial.slashing
      .connect(partial.settlement)
      .slashVerifier(
        partial.verifier.address,
        111,
        0,
        25,
        "gas-partial"
      );

    const partialReceipt = await partialTx.wait();

    const full = await loadFixture(deployFixture);
    await full.slashing
      .connect(full.admin)
      .updateSlashingConfig(100, 0);

    const fullTx = await full.slashing
      .connect(full.settlement)
      .slashVerifier(
        full.verifier.address,
        222,
        0,
        100,
        "gas-full"
      );

    const fullReceipt = await fullTx.wait();

    console.log(
      `slashVerifier partial gas: ${partialReceipt!.gasUsed}`
    );
    console.log(
      `slashVerifier full gas: ${fullReceipt!.gasUsed}`
    );

    expect(partialReceipt!.gasUsed).to.be.greaterThan(0);
    expect(fullReceipt!.gasUsed).to.be.greaterThan(0);
  });
});
