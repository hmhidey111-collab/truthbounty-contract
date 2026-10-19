import { expect } from "chai";
import { ethers } from "hardhat";
import { keccak256, toUtf8Bytes, ZeroAddress, ZeroHash } from "ethers";

describe("Create2AddressPlanner", function () {
  async function deployFixture() {
    const [admin, plannerRole, stranger] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("Create2AddressPlanner");
    const planner = await Factory.deploy(admin.address);
    await planner.waitForDeployment();
    const PLANNER_ROLE = await planner.PLANNER_ROLE();
    await (await planner.connect(admin).grantRole(PLANNER_ROLE, plannerRole.address)).wait();
    return { planner, admin, plannerRole, stranger };
  }

  it("plans a deterministic address from a reviewed salt", async function () {
    const { planner, plannerRole } = await deployFixture();
    const moduleId = keccak256(toUtf8Bytes("STAKE_VAULT"));
    const reviewedSalt = keccak256(toUtf8Bytes("salt-1"));
    const initCodeHash = keccak256(toUtf8Bytes("init-code"));
    const deployer = plannerRole.address;

    const derived = await planner.deriveSalt(moduleId, reviewedSalt);
    const expected = await planner.computeAddress(deployer, derived, initCodeHash);

    await expect(
      planner.connect(plannerRole).planAddress(moduleId, reviewedSalt, initCodeHash, deployer)
    )
      .to.emit(planner, "AddressPlanned")
      .withArgs(moduleId, expected, deployer, derived, initCodeHash);

    const plan = await planner.getPlan(moduleId);
    expect(plan.reserved).to.equal(true);
    expect(plan.predicted).to.equal(expected);
    expect(await planner.isReadyForRegistration(moduleId)).to.equal(false);
  });

  it("rejects unauthorized planners and zero inputs", async function () {
    const { planner, stranger, plannerRole } = await deployFixture();
    const moduleId = keccak256(toUtf8Bytes("CLAIMS"));
    const salt = keccak256(toUtf8Bytes("s"));
    const initHash = keccak256(toUtf8Bytes("i"));

    await expect(
      planner.connect(stranger).planAddress(moduleId, salt, initHash, stranger.address)
    ).to.be.reverted;

    await expect(
      planner.connect(plannerRole).planAddress(ZeroHash, salt, initHash, plannerRole.address)
    ).to.be.revertedWithCustomError(planner, "ZeroModuleId");

    await expect(
      planner.connect(plannerRole).planAddress(moduleId, ZeroHash, initHash, plannerRole.address)
    ).to.be.revertedWithCustomError(planner, "ZeroSalt");

    await expect(
      planner.connect(plannerRole).planAddress(moduleId, salt, ZeroHash, plannerRole.address)
    ).to.be.revertedWithCustomError(planner, "ZeroInitCodeHash");

    await expect(
      planner.connect(plannerRole).planAddress(moduleId, salt, initHash, ZeroAddress)
    ).to.be.revertedWithCustomError(planner, "ZeroDeployer");
  });

  it("verifies bytecode before registration readiness", async function () {
    const { planner, plannerRole } = await deployFixture();
    const moduleId = keccak256(toUtf8Bytes("EVIDENCE"));
    const reviewedSalt = keccak256(toUtf8Bytes("salt-2"));
    const initCodeHash = keccak256(toUtf8Bytes("init-2"));
    const deployer = plannerRole.address;
    const runtime = toUtf8Bytes("runtime-bytecode-fixture");

    await (await planner.connect(plannerRole).planAddress(moduleId, reviewedSalt, initCodeHash, deployer)).wait();
    await expect(planner.connect(plannerRole).verifyBytecode(moduleId, runtime))
      .to.emit(planner, "BytecodeVerified");

    expect((await planner.getPlan(moduleId)).bytecodeVerified).to.equal(true);
    // No on-chain code at predicted EOA-style address => confirm must fail closed
    await expect(planner.confirmDeployment(moduleId)).to.be.reverted;
    expect(await planner.isReadyForRegistration(moduleId)).to.equal(false);
  });
});
