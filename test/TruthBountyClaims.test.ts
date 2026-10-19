import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { ethers } from "hardhat";

// V2-SC-062: all settleClaim / settleClaimsBatch calls require a unique settlementId.
// Helper to produce deterministic test ids.
function sid(tag: string) {
  return ethers.keccak256(ethers.toUtf8Bytes(tag));
}

describe("TruthBountyClaims", function () {
  async function deployFixture() {
    const [admin, user, other] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const TruthBountyClaims = await ethers.getContractFactory("TruthBountyClaims");

    const token = await MockERC20.deploy("Test Token", "TT");
    await token.waitForDeployment();

    const claims = await TruthBountyClaims.deploy(await token.getAddress(), admin.address);
    await claims.waitForDeployment();

    return { admin, user, other, token, claims };
  }

  it("emits ClaimSettled and transfers tokens for single claim", async function () {
    const { admin, user, token, claims } = await loadFixture(deployFixture);

    const amount = ethers.parseUnits("100", 18);

    // Fund the claims contract
    await token.mint(claims.target, amount);

    await expect(claims.connect(admin).settleClaim(user.address, amount, sid("single-1")))
      .to.emit(claims, "ClaimSettled")
      .withArgs(user.address, amount, sid("single-1"));

    expect(await token.balanceOf(user.address)).to.equal(amount);
  });

  it("processes a batch and emits BatchSettlementCompleted and ClaimSettled events", async function () {
    const { admin, user, other, token, claims } = await loadFixture(deployFixture);

    const a1 = ethers.parseUnits("10", 18);
    const a2 = ethers.parseUnits("20", 18);
    const total = a1 + a2;

    // Fund contract
    await token.mint(claims.target, total);

    await expect(
      claims.connect(admin).settleClaimsBatch([user.address, other.address], [a1, a2], sid("batch-1"))
    )
      .to.emit(claims, "BatchSettlementCompleted")
      .withArgs(2, sid("batch-1"));

    expect(await token.balanceOf(user.address)).to.equal(a1);
    expect(await token.balanceOf(other.address)).to.equal(a2);
  });

  // Audit #190: ensures renamed internal _settle params do not shadow
  // event/storage identifiers and that single + batch paths still emit
  // the correct indexed args and token amounts.
  it("does not introduce shadowing: ClaimSettled args match across single and batch paths", async function () {
    const { admin, user, other, token, claims } = await loadFixture(deployFixture);

    const singleAmount = ethers.parseUnits("5", 18);
    const batch1 = ethers.parseUnits("7", 18);
    const batch2 = ethers.parseUnits("9", 18);
    await token.mint(claims.target, singleAmount + batch1 + batch2);

    // Single path
    await expect(claims.connect(admin).settleClaim(user.address, singleAmount, sid("shadow-single")))
      .to.emit(claims, "ClaimSettled")
      .withArgs(user.address, singleAmount, sid("shadow-single"));

    // Batch path - same internal _settle, no shadowing across iterations
    const tx = claims
      .connect(admin)
      .settleClaimsBatch([user.address, other.address], [batch1, batch2], sid("shadow-batch"));
    await expect(tx).to.emit(claims, "ClaimSettled").withArgs(user.address, batch1, sid("shadow-batch"));
    await expect(tx).to.emit(claims, "ClaimSettled").withArgs(other.address, batch2, sid("shadow-batch"));

    expect(await token.balanceOf(user.address)).to.equal(singleAmount + batch1);
    expect(await token.balanceOf(other.address)).to.equal(batch2);
  });
});
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import hre from "hardhat";

describe("TruthBountyClaims", function () {
  async function deployFixture() {
    const [owner, otherAccount, beneficiary1, beneficiary2, beneficiary3] =
      await hre.ethers.getSigners();

    // Deploy Token
    const Token = await hre.ethers.getContractFactory("TruthBountyToken");
    const token = await Token.deploy(owner.address);

    // Deploy Mock Failing ERC20
    const MockFailing = await hre.ethers.getContractFactory("MockFailingERC20");
    const failingToken = await MockFailing.deploy();

    // Deploy Claims Contract
    const Claims = await hre.ethers.getContractFactory("TruthBountyClaims");
    const claims = await Claims.deploy(token.target, owner.address);

    // Fund the Claims contract with regular tokens
    const fundAmount = hre.ethers.parseUnits("1000", 18);
    await token.transfer(claims.target, fundAmount);

    // Fund the Claims contract with failing tokens
    await failingToken.transfer(claims.target, fundAmount);

    return {
      token,
      failingToken,
      claims,
      owner,
      otherAccount,
      beneficiary1,
      beneficiary2,
      beneficiary3,
    };
  }

  describe("Settlement", function () {
    it("Should settle a single claim", async function () {
      const { token, claims, beneficiary1 } = await loadFixture(deployFixture);

      const amount = hre.ethers.parseUnits("10", 18);
      const id = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("test-single-1"));

      await expect(claims.settleClaim(beneficiary1.address, amount, id))
        .to.emit(claims, "ClaimSettled")
        .withArgs(beneficiary1.address, amount, id);

      expect(await token.balanceOf(beneficiary1.address)).to.equal(amount);
    });

    it("Should settle a batch of claims", async function () {
      const { token, claims, beneficiary1, beneficiary2, beneficiary3 } =
        await loadFixture(deployFixture);

      const amounts = [
        hre.ethers.parseUnits("10", 18),
        hre.ethers.parseUnits("20", 18),
        hre.ethers.parseUnits("30", 18),
      ];

      const beneficiaries = [
        beneficiary1.address,
        beneficiary2.address,
        beneficiary3.address,
      ];

      const id = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("test-batch-1"));

      await expect(claims.settleClaimsBatch(beneficiaries, amounts, id))
        .to.emit(claims, "BatchSettlementCompleted")
        .withArgs(3, id);

      expect(await token.balanceOf(beneficiary1.address)).to.equal(amounts[0]);
      expect(await token.balanceOf(beneficiary2.address)).to.equal(amounts[1]);
      expect(await token.balanceOf(beneficiary3.address)).to.equal(amounts[2]);
    });

    it("Should revert on array mismatch", async function () {
      const { claims, beneficiary1 } = await loadFixture(deployFixture);

      const id = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("mismatch"));
      await expect(
        claims.settleClaimsBatch([beneficiary1.address], [], id),
      ).to.be.revertedWith("Arrays length mismatch");
    });

    it("Should revert if caller is not owner", async function () {
      const { claims, otherAccount, beneficiary1 } =
        await loadFixture(deployFixture);
      const id = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("rbac-1"));
      await expect(
        claims.connect(otherAccount).settleClaim(beneficiary1.address, 100, id),
      )
        .to.be.revertedWithCustomError(claims, "AccessControlUnauthorizedAccount");
    });

    it("Gas comparison (Log only)", async function () {
      const { claims, beneficiary1, beneficiary2 } =
        await loadFixture(deployFixture);
      const amount = hre.ethers.parseUnits("10", 18);

      const id1 = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("gas-single"));
      const gasSingle = await claims.settleClaim.estimateGas(
        beneficiary1.address,
        amount,
        id1,
      );
      console.log(`Gas for single claim: ${gasSingle.toString()}`);

      const id2 = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("gas-batch"));
      const gasBatch = await claims.settleClaimsBatch.estimateGas(
        [beneficiary1.address, beneficiary2.address],
        [amount, amount],
        id2,
      );
      console.log(`Gas for batch of 2 claims: ${gasBatch.toString()}`);
      console.log(`Average gas per claim in batch: ${Number(gasBatch) / 2}`);
    });
  });

  describe("Rescue Tokens", function () {
    it("Should rescue tokens successfully with normal ERC20", async function () {
      const { token, claims, owner } = await loadFixture(deployFixture);

      const amount = hre.ethers.parseUnits("10", 18);
      const initialBalance = await token.balanceOf(owner.address);

      await expect(claims.rescueTokens(token.target, owner.address, amount))
        .to.not.be.reverted;

      expect(await token.balanceOf(owner.address)).to.equal(initialBalance + amount);
    });

    it("Should revert when rescuing tokens from failing ERC20", async function () {
      const { failingToken, claims, owner } = await loadFixture(deployFixture);

      const amount = hre.ethers.parseUnits("10", 18);

      await expect(claims.rescueTokens(failingToken.target, owner.address, amount))
        .to.be.reverted;
    });

    it("Should revert if caller does not have TREASURY_ROLE", async function () {
      const { token, claims, otherAccount, owner } = await loadFixture(deployFixture);

      const amount = hre.ethers.parseUnits("10", 18);

      await expect(claims.connect(otherAccount).rescueTokens(token.target, owner.address, amount))
        .to.be.revertedWithCustomError(claims, "AccessControlUnauthorizedAccount");
    });
  });
});
