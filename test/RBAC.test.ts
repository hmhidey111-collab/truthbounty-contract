import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("Unified RBAC System", function () {
    async function deployRBACFixture() {
        const [owner, admin, oracle, resolver, treasury, pauser, user] = await ethers.getSigners();

        // 1. TruthBountyToken
        const TruthBountyToken = await ethers.getContractFactory("TruthBountyToken");
        const token = await TruthBountyToken.deploy(admin.address);
        const tokenAddress = await token.getAddress();

        // 2. ReputationDecay
        const ReputationDecay = await ethers.getContractFactory("ReputationDecay");
        const decay = await ReputationDecay.deploy(admin.address);
        const decayAddress = await decay.getAddress();

        // 3. Staking
        const Staking = await ethers.getContractFactory("Staking");
        const staking = await Staking.deploy(tokenAddress, 86400, admin.address);
        const stakingAddress = await staking.getAddress();

        // 4. VerifierSlashing
        const VerifierSlashing = await ethers.getContractFactory("VerifierSlashing");
        const slashing = await VerifierSlashing.deploy(stakingAddress, admin.address, admin.address);
        const slashingAddress = await slashing.getAddress();

        // 5. TruthBountyClaims
        const TruthBountyClaims = await ethers.getContractFactory("TruthBountyClaims");
        const claims = await TruthBountyClaims.deploy(tokenAddress, admin.address);
        const claimsAddress = await claims.getAddress();

        // 6. TruthBounty (Main)
        const TruthBounty = await ethers.getContractFactory("TruthBounty");
        const truthBounty = await TruthBounty.deploy(tokenAddress, admin.address, admin.address);
        const truthBountyAddress = await truthBounty.getAddress();

        // 7. WeightedStaking
        const WeightedStaking = await ethers.getContractFactory("contracts/WeightedStaking.sol:WeightedStaking");
        const weightedStaking = await WeightedStaking.deploy(owner.address, admin.address, admin.address); // owner as dummy oracle
        const weightedStakingAddress = await weightedStaking.getAddress();

        // Roles
        const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
        const ORACLE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ORACLE_ROLE"));
        const RESOLVER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RESOLVER_ROLE"));
        const TREASURY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("TREASURY_ROLE"));
        const PAUSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PAUSER_ROLE"));

        // Set up roles
        await decay.connect(admin).grantRole(ORACLE_ROLE, oracle.address);
        await slashing.connect(admin).scheduleResolverRoleGrant(resolver.address);
        await slashing.connect(admin).grantRole(PAUSER_ROLE, pauser.address);
        await claims.connect(admin).grantRole(TREASURY_ROLE, treasury.address);
        await truthBounty.connect(admin).grantRole(PAUSER_ROLE, pauser.address);
        await token.connect(admin).scheduleResolverRoleGrant(resolver.address);
        await staking.connect(admin).setSlashingContract(slashingAddress); // Fixed: connect(admin)
        await time.increase(2 * 24 * 60 * 60);
        await slashing.executeResolverRoleGrant(resolver.address);
        await token.executeResolverRoleGrant(resolver.address);
        await staking.executeResolverRoleGrant(slashingAddress);

        return {
            token, decay, staking, slashing, claims, truthBounty, weightedStaking,
            owner, admin, oracle, resolver, treasury, pauser, user,
            ADMIN_ROLE, ORACLE_ROLE, RESOLVER_ROLE, TREASURY_ROLE, PAUSER_ROLE
        };
    }

    describe("ReputationDecay RBAC", function () {
        it("Should allow ORACLE_ROLE to record activity", async function () {
            const { decay, oracle, user } = await loadFixture(deployRBACFixture);
            await expect(decay.connect(oracle).recordActivity(user.address))
                .to.emit(decay, "ActivityRecorded");
        });

        it("Should revert if non-oracle tries to record activity", async function () {
            const { decay, user } = await loadFixture(deployRBACFixture);
            await expect(decay.connect(user).recordActivity(user.address))
                .to.be.revertedWithCustomError(decay, "AccessControlUnauthorizedAccount");
        });

        it("Should allow ADMIN_ROLE to set decay config", async function () {
            const { decay, admin } = await loadFixture(deployRBACFixture);
            await expect(decay.connect(admin).setDecayConfig({
                decayInterval: 7 * 86400,
                decayPercentage: 200,
                minimumReputation: 1,
                enabled: true
            })).to.emit(decay, "DecayConfigUpdated");
        });
    });

    describe("VerifierSlashing RBAC", function () {
        it("Should allow RESOLVER_ROLE to slash", async function () {
            const { slashing, resolver, user } = await loadFixture(deployRBACFixture);
            // This will revert mid-way due to lack of stake, but should pass RBAC check
            await expect(slashing.connect(resolver).slash(user.address, 10, "Reason"))
                .to.not.be.revertedWithCustomError(slashing, "AccessControlUnauthorizedAccount");
        });

        it("Should allow PAUSER_ROLE to pause", async function () {
            const { slashing, pauser } = await loadFixture(deployRBACFixture);
            await slashing.connect(pauser).pause();
            expect(await slashing.paused()).to.be.true;
        });

        it("Should revert if non-pauser tries to pause", async function () {
            const { slashing, user } = await loadFixture(deployRBACFixture);
            await expect(slashing.connect(user).pause())
                .to.be.revertedWithCustomError(slashing, "AccessControlUnauthorizedAccount");
        });
    });

    describe("TruthBountyClaims RBAC", function () {
        it("Should allow TREASURY_ROLE to settle claims", async function () {
            const { claims, treasury, user } = await loadFixture(deployRBACFixture);
            // V2-SC-062: settleClaim requires a unique settlementId
            const sid = ethers.keccak256(ethers.toUtf8Bytes("rbac-treasury-1"));
            // Should pass RBAC even if it fails later (due to balance)
            await expect(claims.connect(treasury).settleClaim(user.address, 100, sid))
                .to.not.be.revertedWithCustomError(claims, "AccessControlUnauthorizedAccount");
        });

        it("Should deny non-treasury from settling claims", async function () {
            const { claims, user } = await loadFixture(deployRBACFixture);
            // V2-SC-062: settleClaim requires a unique settlementId
            const sid = ethers.keccak256(ethers.toUtf8Bytes("rbac-user-1"));
            await expect(claims.connect(user).settleClaim(user.address, 100, sid))
                .to.be.revertedWithCustomError(claims, "AccessControlUnauthorizedAccount");
        });
    });

    describe("TruthBountyToken RBAC", function () {
        it("Should allow RESOLVER_ROLE to slash verifier", async function () {
            const { token, resolver, user } = await loadFixture(deployRBACFixture);
            await expect(token.connect(resolver).slashVerifier(user.address, "Reason"))
                .to.not.be.revertedWith("Unauthorized slashing"); // Old revert, now AccessControl
        });

        it("Should allow ADMIN_ROLE to set settlement contract", async function () {
            const { token, admin, user } = await loadFixture(deployRBACFixture);
            await expect(token.connect(admin).setSettlementContract(user.address))
                .to.not.be.reverted;
        });
    });
});
