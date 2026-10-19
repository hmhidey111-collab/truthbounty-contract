import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { ethers } from "hardhat";
import type { StakeVault, MockERC20, MockFailingBondERC20 } from "../typechain-types";

describe("StakeVault (bond ledger)", function () {
    const AMOUNT = ethers.parseEther("100");

    async function deployFixture() {
        const [admin, operator, depositor, recipient] = await ethers.getSigners();

        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        const token = (await MockERC20Factory.deploy("Bounty", "BOUNTY")) as MockERC20;
        await token.waitForDeployment();

        const StakeVaultFactory = await ethers.getContractFactory("contracts/StakeVault.sol:StakeVault");
        const vault = (await StakeVaultFactory.deploy(admin.address, await token.getAddress())) as StakeVault;
        await vault.waitForDeployment();

        const OPERATOR_ROLE = await vault.OPERATOR_ROLE();
        await vault.connect(admin).grantRole(OPERATOR_ROLE, operator.address);

        // Fund the depositor so it can post the bond.
        await token.mint(depositor.address, ethers.parseEther("1000"));
        await token.connect(depositor).approve(await vault.getAddress(), ethers.MaxUint256);

        return { vault, token, admin, operator, depositor, recipient };
    }

    describe("Deployment", function () {
        it("sets the initial bond token", async function () {
            const { vault, token } = await loadFixture(deployFixture);
            expect(await vault.bondToken()).to.equal(await token.getAddress());
        });

        it("starts with zero locked total", async function () {
            const { vault } = await loadFixture(deployFixture);
            expect(await vault.totalLocked()).to.equal(0n);
        });
    });

    describe("lockBond", function () {
        it("vaults the token and records the lock", async function () {
            const { vault, token, operator, depositor } = await loadFixture(deployFixture);
            const vaultBefore = await token.balanceOf(await vault.getAddress());

            await expect(vault.connect(operator).lockBond(1, await token.getAddress(), depositor.address, AMOUNT))
                .to.emit(vault, "BondLocked")
                .withArgs(1, await token.getAddress(), depositor.address, AMOUNT, operator.address);

            expect(await token.balanceOf(await vault.getAddress())).to.equal(vaultBefore + AMOUNT);
            expect(await vault.totalLocked()).to.equal(AMOUNT);

            const lock = await vault.getLock(1);
            expect(lock.lockId).to.equal(1n);
            expect(lock.token).to.equal(await token.getAddress());
            expect(lock.depositor).to.equal(depositor.address);
            expect(lock.amount).to.equal(AMOUNT);
            expect(lock.released).to.equal(false);
        });

        it("reverts for a non-operator", async function () {
            const { vault, token, depositor } = await loadFixture(deployFixture);
            const [caller] = await ethers.getSigners();
            await expect(vault.connect(caller).lockBond(1, await token.getAddress(), depositor.address, AMOUNT))
                .to.be.revertedWithCustomError(vault, "AccessControlUnauthorizedAccount");
        });

        it("reverts on a duplicate lock id", async function () {
            const { vault, token, operator, depositor } = await loadFixture(deployFixture);
            await vault.connect(operator).lockBond(1, await token.getAddress(), depositor.address, AMOUNT);
            await expect(vault.connect(operator).lockBond(1, await token.getAddress(), depositor.address, AMOUNT))
                .to.be.revertedWithCustomError(vault, "LockAlreadyExists");
        });

        it("with a failing transfer token reverts and records nothing", async function () {
            const { vault, admin, operator, depositor } = await loadFixture(deployFixture);
            const FailingFactory = await ethers.getContractFactory("MockFailingBondERC20");
            const failing = (await FailingFactory.deploy()) as MockFailingBondERC20;
            await failing.waitForDeployment();

            await vault.connect(admin).setBondToken(await failing.getAddress());
            await failing.mint(depositor.address, AMOUNT);
            await failing.connect(depositor).approve(await vault.getAddress(), ethers.MaxUint256);

            await expect(vault.connect(operator).lockBond(2, await failing.getAddress(), depositor.address, ethers.parseEther("1")))
                .to.be.reverted;

            // No partial ledger entry.
            const lock = await vault.getLock(2);
            expect(lock.lockId).to.equal(0n);
            expect(await vault.totalLocked()).to.equal(0n);
        });
    });

    describe("releaseBond", function () {
        it("releases to the recipient and removes the lock from the ledger", async function () {
            const { vault, token, operator, depositor, recipient } = await loadFixture(deployFixture);
            const recipientBefore = await token.balanceOf(recipient.address);

            await vault.connect(operator).lockBond(1, await token.getAddress(), depositor.address, AMOUNT);

            await expect(vault.connect(operator).releaseBond(1, recipient.address))
                .to.emit(vault, "BondReleased")
                .withArgs(1, recipient.address, AMOUNT, operator.address);

            expect(await token.balanceOf(recipient.address)).to.equal(recipientBefore + AMOUNT);
            expect(await vault.totalLocked()).to.equal(0n);

            const lock = await vault.getLock(1);
            expect(lock.released).to.equal(true);
            expect(lock.releasedTo).to.equal(recipient.address);
        });

        it("reverts when releasing a non-existent lock", async function () {
            const { vault, operator, recipient } = await loadFixture(deployFixture);
            await expect(vault.connect(operator).releaseBond(99, recipient.address))
                .to.be.revertedWithCustomError(vault, "LockNotFound");
        });

        it("reverts when releasing an already-released lock", async function () {
            const { vault, token, operator, depositor, recipient } = await loadFixture(deployFixture);
            await vault.connect(operator).lockBond(1, await token.getAddress(), depositor.address, AMOUNT);
            await vault.connect(operator).releaseBond(1, recipient.address);
            await expect(vault.connect(operator).releaseBond(1, recipient.address))
                .to.be.revertedWithCustomError(vault, "LockAlreadyReleased");
        });

        it("reverts for a non-operator", async function () {
            const { vault, token, operator, depositor, recipient } = await loadFixture(deployFixture);
            await vault.connect(operator).lockBond(1, await token.getAddress(), depositor.address, AMOUNT);
            await expect(vault.connect(depositor).releaseBond(1, recipient.address))
                .to.be.revertedWithCustomError(vault, "AccessControlUnauthorizedAccount");
        });
    });

    describe("ledger reconciliation", function () {
        it("totalLocked reconciles across multiple locks and releases", async function () {
            const { vault, token, operator, depositor, recipient } = await loadFixture(deployFixture);
            await token.mint(depositor.address, ethers.parseEther("5000"));

            for (let i = 1; i <= 5; i++) {
                await vault.connect(operator).lockBond(i, await token.getAddress(), depositor.address, ethers.parseEther("10"));
            }
            expect(await vault.totalLocked()).to.equal(ethers.parseEther("50"));

            await vault.connect(operator).releaseBond(2, recipient.address);
            await vault.connect(operator).releaseBond(5, recipient.address);
            expect(await vault.totalLocked()).to.equal(ethers.parseEther("30"));
        });
    });
});

describe("StakeVault V2 custody", function () {
    async function deployFixture() {
        const [admin, verifier, verifier2, settlement, slashing] = await ethers.getSigners();

        const MockModuleRegistry = await ethers.getContractFactory("MockModuleRegistry");
        const registry = await MockModuleRegistry.deploy();

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        const token = await MockERC20.deploy("Stake", "STK");
        const tokenB = await MockERC20.deploy("Alt", "ALT");

        const StakeVault = await ethers.getContractFactory("contracts/v2/StakeVault.sol:StakeVault");
        const vault = await StakeVault.deploy(await registry.getAddress(), await token.getAddress(), admin.address);

        await vault.setSupportedAsset(await tokenB.getAddress(), true);

        const MODULE_SETTLEMENT = await vault.MODULE_SETTLEMENT();
        const MODULE_SLASHING = await vault.MODULE_SLASHING();
        await registry.permitModule(MODULE_SETTLEMENT, settlement.address);
        await registry.permitModule(MODULE_SLASHING, slashing.address);

        const amount = ethers.parseEther("100");
        await token.mint(verifier.address, ethers.parseEther("1000"));
        await token.mint(verifier2.address, ethers.parseEther("1000"));
        await tokenB.mint(verifier.address, ethers.parseEther("1000"));

        await token.connect(verifier).approve(await vault.getAddress(), ethers.MaxUint256);
        await token.connect(verifier2).approve(await vault.getAddress(), ethers.MaxUint256);
        await tokenB.connect(verifier).approve(await vault.getAddress(), ethers.MaxUint256);

        return { vault, registry, token, tokenB, admin, verifier, verifier2, settlement, slashing, amount };
    }

    it("implements IStakeCustody with ERC-165", async function () {
        const { vault } = await deployFixture();
        const iStakeCustody = await ethers.getContractAt("IStakeCustody", await vault.getAddress());
        expect(await iStakeCustody.protocolVersion()).to.deep.equal([2n, 0n]);
        expect(await vault.supportsInterface("0x01ffc9a7")).to.equal(true);
    });

    it("deposits, releases, and withdraws stake via pull primitive", async function () {
        const { vault, token, verifier, settlement, amount } = await deployFixture();
        const claimId = 1n;

        await expect(vault.connect(verifier).depositStake(claimId, amount))
            .to.emit(vault, "StakeDeposited")
            .withArgs(verifier.address, claimId, amount);

        expect(await vault.staked(claimId, verifier.address)).to.equal(amount);
        expect(await vault.totalStaked(claimId)).to.equal(amount);

        await expect(vault.connect(settlement).releaseStake(claimId, verifier.address, amount))
            .to.emit(vault, "StakeReleased")
            .withArgs(verifier.address, claimId, amount);

        expect(await vault.claimableBalance(await token.getAddress(), verifier.address)).to.equal(amount);

        const before = await token.balanceOf(verifier.address);
        await expect(vault.connect(verifier).withdraw(await token.getAddress(), amount))
            .to.emit(vault, "VaultWithdrawn")
            .withArgs(await token.getAddress(), verifier.address, amount);
        expect(await token.balanceOf(verifier.address)).to.equal(before + amount);
    });

    it("slashes stake into protocol allocation", async function () {
        const { vault, token, verifier, slashing, amount } = await deployFixture();
        const claimId = 7n;
        const reason = ethers.id("slash");

        await vault.connect(verifier).depositStake(claimId, amount);
        await expect(vault.connect(slashing).slashStake(claimId, verifier.address, amount, reason))
            .to.emit(vault, "StakeSlashed")
            .withArgs(verifier.address, claimId, amount, reason);

        expect(await vault.protocolAllocation(await token.getAddress())).to.equal(amount);
        expect(await vault.staked(claimId, verifier.address)).to.equal(0n);
    });

    it("isolates claims and assets", async function () {
        const { vault, token, tokenB, verifier, settlement, amount } = await deployFixture();

        await vault.connect(verifier).depositStake(1n, amount);
        await vault.connect(verifier).depositStake(2n, amount * 2n);
        await vault.connect(verifier).deposit(await tokenB.getAddress(), amount);

        await vault.connect(settlement).lock(
            await tokenB.getAddress(),
            verifier.address,
            1n,
            0n,
            3, // BOUNTY_ESCROW
            amount
        );

        expect(await vault.staked(2n, verifier.address)).to.equal(amount * 2n);
        expect(await vault.totalCustody(await token.getAddress())).to.equal(amount * 3n);
        expect(await vault.totalCustody(await tokenB.getAddress())).to.equal(amount);
    });

    it("rejects unauthorized lock mutations", async function () {
        const { vault, token, verifier, verifier2, amount } = await deployFixture();
        await vault.connect(verifier).deposit(await token.getAddress(), amount);

        await expect(
            vault.connect(verifier2).lock(await token.getAddress(), verifier.address, 1n, 0n, 2, amount)
        ).to.be.revertedWithCustomError(vault, "UnauthorizedModule");
    });

    it("reconciles custody with bucket totals", async function () {
        const { vault, token, verifier, amount } = await deployFixture();
        await vault.connect(verifier).depositStake(1n, amount);

        const [custody, obligations] = await vault.reconcile(await token.getAddress());
        expect(custody).to.equal(amount);
        expect(obligations).to.equal(amount);
        expect(custody).to.equal(obligations);
    });
});
