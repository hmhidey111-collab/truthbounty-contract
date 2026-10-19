import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  ClaimRegistry,
  VerificationAggregator,
  AppealVerificationRound,
  RewardToken,
  MockReputationOracle,
  GovernanceController,
  StakeVault,
} from "../../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { deployClaimRegistry } from "../helpers/deployClaimRegistry";

describe("AppealVerificationRound (SC-017)", () => {
  let admin: SignerWithAddress;
  let claimCreator: SignerWithAddress;
  let appellant1: SignerWithAddress;
  let appellant2: SignerWithAddress;
  let outsider: SignerWithAddress;

  let token: RewardToken;
  let oracle: MockReputationOracle;
  let govController: GovernanceController;
  let claimRegistry: ClaimRegistry;
  let vault: StakeVault;
  let appealManager: AppealVerificationRound;
  let appealAggregator: VerificationAggregator;

  const APPEAL_DURATION = 3 * 24 * 3600; // 3 days
  const MIN_APPEAL_STAKE = ethers.parseEther("200");
  const STAKE_MULTIPLIER_BPS = 15000; // 1.5x
  const MAX_WEIGHT_CAP = ethers.parseEther("10000");
  const MAX_APPEAL_ROUNDS = 2;
  const APPEAL_BOND = ethers.parseEther("1000");
  const APPEAL_BOND_ESCALATION_BPS = 15000; // 1.5x per round
  const MAX_APPEAL_BOND = ethers.parseEther("5000");
  const MAX_VOTERS_PER_ROUND = 5;

  const OPERATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("OPERATOR_ROLE"));

  const baseAppealConfig = {
    roundDuration: APPEAL_DURATION,
    minStakeAmount: MIN_APPEAL_STAKE,
    stakeMultiplierBps: STAKE_MULTIPLIER_BPS,
    maxWeightCap: MAX_WEIGHT_CAP,
    parameterVersion: 1,
    maxAppealRounds: MAX_APPEAL_ROUNDS,
    appealBond: APPEAL_BOND,
    appealBondEscalationBps: APPEAL_BOND_ESCALATION_BPS,
    maxAppealBond: MAX_APPEAL_BOND,
    maxVotersPerRound: MAX_VOTERS_PER_ROUND,
  };

  beforeEach(async () => {
    [admin, claimCreator, appellant1, appellant2, outsider] = await ethers.getSigners();

    // 1. Deploy Token
    const TokenFactory = await ethers.getContractFactory("RewardToken");
    token = await TokenFactory.deploy(admin.address, ethers.parseEther("1000000"));
    await token.waitForDeployment();

    // 2. Deploy Bond-Custody StakeVault (V2-SC-016/059)
    const StakeVaultFactory = await ethers.getContractFactory("contracts/StakeVault.sol:StakeVault");
    vault = (await StakeVaultFactory.deploy(admin.address, await token.getAddress())) as StakeVault;
    await vault.waitForDeployment();

    // 3. Deploy Mock Oracle
    const OracleFactory = await ethers.getContractFactory("MockReputationOracle");
    oracle = await OracleFactory.deploy();
    await oracle.waitForDeployment();

    // 4. Deploy Governance Controller
    const GovFactory = await ethers.getContractFactory("GovernanceController");
    govController = await GovFactory.deploy(admin.address);
    await govController.waitForDeployment();

    // 5. Deploy ClaimRegistry
    claimRegistry = await deployClaimRegistry(admin.address);

    // 6. Deploy AppealVerificationRound
    const AppealFactory = await ethers.getContractFactory("AppealVerificationRound");

    appealManager = await AppealFactory.deploy(
      await token.getAddress(),
      await claimRegistry.getAddress(),
      await oracle.getAddress(),
      await vault.getAddress(),
      baseAppealConfig,
      await govController.getAddress(),
      admin.address
    );
    await appealManager.waitForDeployment();

    // 7. Authorise the appeal module to lock appeal bonds in the vault
    await vault.grantRole(OPERATOR_ROLE, await appealManager.getAddress());

    // 8. Deploy VerificationAggregator pointing to AppealVerificationRound
    const AggFactory = await ethers.getContractFactory("VerificationAggregator");
    appealAggregator = await AggFactory.deploy(
      await appealManager.getAddress(),
      admin.address,
      0, // minCount
      0, // minWeight
      0  // minConfidence
    );
    await appealAggregator.waitForDeployment();

    // Fund appellants and approve vote stakes (to the appeal contract) and bonds (to the vault)
    await token.transfer(appellant1.address, ethers.parseEther("1000"));
    await token.transfer(appellant2.address, ethers.parseEther("1000"));
    await token.connect(appellant1).approve(await appealManager.getAddress(), ethers.MaxUint256);
    await token.connect(appellant2).approve(await appealManager.getAddress(), ethers.MaxUint256);
    await token.connect(appellant1).approve(await vault.getAddress(), ethers.MaxUint256);
    await token.connect(appellant2).approve(await vault.getAddress(), ethers.MaxUint256);

    // Fund and approve the permissionless round openers (admin + outsider)
    await token.transfer(outsider.address, ethers.parseEther("10000"));
    await token.connect(outsider).approve(await vault.getAddress(), ethers.MaxUint256);
    await token.connect(admin).approve(await vault.getAddress(), ethers.MaxUint256);

    // Set reputations
    await oracle.setReputationScore(appellant1.address, ethers.parseEther("1.0")); // 1.0x
    await oracle.setReputationScore(appellant2.address, ethers.parseEther("1.2")); // 1.2x
  });

  describe("Appeal Round Lifecycle", () => {
    let claimId: bigint;

    beforeEach(async () => {
      const now = await time.latest();
      const sampleCID = "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco";
      await claimRegistry.connect(claimCreator).createClaim(
        "Claim Under Dispute Test 123",
        sampleCID,
        now + 86400
      );
      claimId = 1n;
    });

    it("opens an appeal round with frozen immutable parameters", async () => {
      const tx = await appealManager.connect(outsider).openAppealRound(claimId);
      await expect(tx).to.emit(appealManager, "AppealRoundOpened");

      const round = await appealManager.getAppealRound(claimId);
      expect(round.status).to.equal(1); // OPEN
      expect(round.minStakeAmount).to.equal(MIN_APPEAL_STAKE);
      expect(round.stakeMultiplierBps).to.equal(STAKE_MULTIPLIER_BPS);
      expect(round.roundIndex).to.equal(1n);
      expect(round.maxRounds).to.equal(BigInt(MAX_APPEAL_ROUNDS));
      expect(round.requiredBond).to.equal(APPEAL_BOND);
      expect(round.maxVoters).to.equal(BigInt(MAX_VOTERS_PER_ROUND));
      expect(await appealManager.isAppealOpen(claimId)).to.be.true;
    });

    it("locks the opener's bond in the vault before committing round state", async () => {
      const tx = await appealManager.connect(outsider).openAppealRound(claimId);

      // Bond leaves the opener and lands in vaulted custody (not in the appeal contract)
      await expect(tx).to.changeTokenBalances(
        token,
        [outsider, await vault.getAddress()],
        [-APPEAL_BOND, APPEAL_BOND]
      );

      const round = await appealManager.getAppealRound(claimId);
      expect(await vault.totalLocked()).to.equal(APPEAL_BOND);

      const lock = await vault.getLock(round.bondLockId);
      expect(lock.depositor).to.equal(outsider.address);
      expect(lock.amount).to.equal(APPEAL_BOND);
      expect(lock.token).to.equal(await token.getAddress());
      expect(lock.released).to.be.false;

      // The reported bond lock reconciles with the round's bondLockId
      const appealBondLock = await appealManager.getAppealBondLock(claimId);
      expect(appealBondLock.lockId).to.equal(round.bondLockId);
      expect(appealBondLock.amount).to.equal(APPEAL_BOND);
    });

    it("reverts on duplicate appeal round opening for the same claim", async () => {
      await appealManager.openAppealRound(claimId);
      await expect(appealManager.openAppealRound(claimId)).to.be.revertedWithCustomError(
        appealManager,
        "AppealRoundAlreadyExists"
      );
    });

    it("reverts if claim does not exist in registry", async () => {
      await expect(appealManager.openAppealRound(999)).to.be.revertedWithCustomError(
        claimRegistry,
        "ClaimNotFound"
      );
    });

    it("accepts valid appeal votes, custodies stake, and computes weights", async () => {
      await appealManager.openAppealRound(claimId);

      const stake = ethers.parseEther("200");
      // appellant1 (1.0 rep, 1.5x appeal multiplier) -> 200 * 1.5 = 300 effective weight
      await expect(appealManager.connect(appellant1).submitAppealVote(claimId, true, stake))
        .to.emit(appealManager, "AppealVoteSubmitted")
        .withArgs(claimId, appellant1.address, true, stake, ethers.parseEther("300"));

      // Check contract token balance
      expect(await token.balanceOf(await appealManager.getAddress())).to.equal(stake);

      const vote = await appealManager.getAppealVote(claimId, appellant1.address);
      expect(vote.voted).to.be.true;
      expect(vote.support).to.be.true;
      expect(vote.effectiveStake).to.equal(ethers.parseEther("300"));
    });

    it("reverts if vote stake is below minStakeAmount", async () => {
      await appealManager.openAppealRound(claimId);
      const lowStake = ethers.parseEther("50");
      await expect(
        appealManager.connect(appellant1).submitAppealVote(claimId, true, lowStake)
      ).to.be.revertedWithCustomError(appealManager, "InsufficientStake");
    });

    it("reverts on duplicate voting by the same address in the appeal round", async () => {
      await appealManager.openAppealRound(claimId);
      await appealManager.connect(appellant1).submitAppealVote(claimId, true, MIN_APPEAL_STAKE);

      await expect(
        appealManager.connect(appellant1).submitAppealVote(claimId, false, MIN_APPEAL_STAKE)
      ).to.be.revertedWithCustomError(appealManager, "AlreadyVotedInAppeal");
    });

    it("reverts when voting after appeal deadline", async () => {
      await appealManager.openAppealRound(claimId);
      await time.increase(APPEAL_DURATION + 10);

      await expect(
        appealManager.connect(appellant1).submitAppealVote(claimId, true, MIN_APPEAL_STAKE)
      ).to.be.revertedWithCustomError(appealManager, "AppealRoundExpired");
    });

    it("permissionlessly closes the appeal round after deadline", async () => {
      await appealManager.openAppealRound(claimId);
      await appealManager.connect(appellant1).submitAppealVote(claimId, true, MIN_APPEAL_STAKE);

      await expect(appealManager.closeAppealRound(claimId)).to.be.revertedWithCustomError(
        appealManager,
        "AppealRoundNotExpired"
      );

      await time.increase(APPEAL_DURATION + 10);
      await expect(appealManager.connect(outsider).closeAppealRound(claimId))
        .to.emit(appealManager, "AppealRoundClosed");

      const round = await appealManager.getAppealRound(claimId);
      expect(round.status).to.equal(2); // CLOSED (round 1 of 2, path not yet terminal)
      expect(await appealManager.isAppealOpen(claimId)).to.be.false;
    });

    it("implements IVerificationSource and integrates seamlessly with VerificationAggregator", async () => {
      await appealManager.openAppealRound(claimId);

      // Appellant 1 votes TRUE with 200 stake (rep 1.0 -> weight 300)
      await appealManager.connect(appellant1).submitAppealVote(claimId, true, MIN_APPEAL_STAKE);
      // Appellant 2 votes FALSE with 200 stake (rep 1.2 -> 200 * 1.2 * 1.5 = 360 weight)
      await appealManager.connect(appellant2).submitAppealVote(claimId, false, MIN_APPEAL_STAKE);

      expect(await appealManager.getClaimVoterCount(claimId)).to.equal(2);
      expect(await appealManager.getClaimVoterAt(claimId, 0)).to.equal(appellant1.address);
      expect(await appealManager.getClaimVoterAt(claimId, 1)).to.equal(appellant2.address);

      // Aggregate via VerificationAggregator
      await appealAggregator.aggregateClaim(claimId);
      const aggResult = await appealAggregator.getAggregation(claimId);

      expect(aggResult.outcome).to.equal(1); // VERIFIED_FALSE (360 > 300)
      expect(aggResult.trueWeight).to.equal(ethers.parseEther("300"));
      expect(aggResult.falseWeight).to.equal(ethers.parseEther("360"));
      expect(aggResult.totalWeight).to.equal(ethers.parseEther("660"));
    });
  });

  describe("Governance & Configuration", () => {
    it("allows admin to update default appeal round config", async () => {
      const newConfig = {
        roundDuration: 5 * 24 * 3600,
        minStakeAmount: ethers.parseEther("500"),
        stakeMultiplierBps: 20000, // 2.0x
        maxWeightCap: ethers.parseEther("50000"),
        parameterVersion: 2,
        maxAppealRounds: 1,
        appealBond: APPEAL_BOND,
        appealBondEscalationBps: 10000,
        maxAppealBond: MAX_APPEAL_BOND,
        maxVotersPerRound: 200,
      };

      await expect(appealManager.setDefaultConfig(newConfig))
        .to.emit(appealManager, "DefaultAppealConfigUpdated");

      const cfg = await appealManager.defaultConfig();
      expect(cfg.minStakeAmount).to.equal(ethers.parseEther("500"));
      expect(cfg.maxAppealRounds).to.equal(1n);
      expect(cfg.maxVotersPerRound).to.equal(200n);
    });

    it("rejects unauthorized config changes", async () => {
      const newConfig = {
        roundDuration: 5 * 24 * 3600,
        minStakeAmount: ethers.parseEther("500"),
        stakeMultiplierBps: 20000,
        maxWeightCap: ethers.parseEther("50000"),
        parameterVersion: 2,
        maxAppealRounds: 1,
        appealBond: APPEAL_BOND,
        appealBondEscalationBps: 10000,
        maxAppealBond: MAX_APPEAL_BOND,
        maxVotersPerRound: 200,
      };

      await expect(
        appealManager.connect(outsider).setDefaultConfig(newConfig)
      ).to.be.revertedWithCustomError(appealManager, "UnauthorizedGovernance");
    });

    it("rejects invalid V2-SC-059 bond and cap configuration (fail closed)", async () => {
      const base = {
        roundDuration: APPEAL_DURATION,
        minStakeAmount: MIN_APPEAL_STAKE,
        stakeMultiplierBps: STAKE_MULTIPLIER_BPS,
        maxWeightCap: MAX_WEIGHT_CAP,
        parameterVersion: 1,
        maxAppealRounds: 1,
        appealBond: APPEAL_BOND,
        appealBondEscalationBps: APPEAL_BOND_ESCALATION_BPS,
        maxAppealBond: MAX_APPEAL_BOND,
        maxVotersPerRound: 200,
      };

      await expect(
        appealManager.setDefaultConfig({ ...base, maxAppealRounds: 0 })
      ).to.be.revertedWithCustomError(appealManager, "InvalidMaxAppealRounds");

      await expect(
        appealManager.setDefaultConfig({ ...base, maxAppealRounds: 4 })
      ).to.be.revertedWithCustomError(appealManager, "InvalidMaxAppealRounds");

      await expect(
        appealManager.setDefaultConfig({ ...base, appealBond: 0 })
      ).to.be.revertedWithCustomError(appealManager, "InvalidAppealBond");

      await expect(
        appealManager.setDefaultConfig({ ...base, appealBondEscalationBps: 9999 })
      ).to.be.revertedWithCustomError(appealManager, "InvalidBondEscalation");

      await expect(
        appealManager.setDefaultConfig({ ...base, appealBondEscalationBps: 40001 })
      ).to.be.revertedWithCustomError(appealManager, "InvalidBondEscalation");

      await expect(
        appealManager.setDefaultConfig({
          ...base,
          maxAppealBond: APPEAL_BOND - 1n,
          appealBond: APPEAL_BOND,
        })
      ).to.be.revertedWithCustomError(appealManager, "InvalidMaxAppealBond");

      await expect(
        appealManager.setDefaultConfig({ ...base, maxVotersPerRound: 0 })
      ).to.be.revertedWithCustomError(appealManager, "InvalidMaxVotersPerRound");

      await expect(
        appealManager.setDefaultConfig({ ...base, maxVotersPerRound: 201 })
      ).to.be.revertedWithCustomError(appealManager, "InvalidMaxVotersPerRound");
    });

    it("allows admin to re-point the bond vault and emits VaultUpdated", async () => {
      const StakeVaultFactory = await ethers.getContractFactory("contracts/StakeVault.sol:StakeVault");
      const newVault = (await StakeVaultFactory.deploy(admin.address, await token.getAddress())) as StakeVault;
      await newVault.waitForDeployment();

      await expect(appealManager.connect(admin).setVault(await newVault.getAddress()))
        .to.emit(appealManager, "VaultUpdated")
        .withArgs(await vault.getAddress(), await newVault.getAddress());

      expect(await appealManager.vault()).to.equal(await newVault.getAddress());
    });
  });

  describe("V2-SC-059: Bound Appeal Rounds & Prevent Griefing", () => {
    let claimId: bigint;

    beforeEach(async () => {
      const now = await time.latest();
      const sampleCID = "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco";
      await claimRegistry.connect(claimCreator).createClaim(
        "Bounded Appeal Claim",
        sampleCID,
        now + 86400
      );
      claimId = 1n;
    });

    const closeRound = async (id: bigint) => {
      const round = await appealManager.getAppealRound(id);
      await time.increaseTo(Number(round.deadline) + 1);
      await appealManager.connect(outsider).closeAppealRound(id);
    };

    it("R1-pre: a zero-allowance opener is rejected before any custody transfer (InsufficientBondAllowance)", async () => {
      // claimCreator owns no tokens and has not approved the vault: the ledger must
      // stay untouched and the round must not open (old contract opened without a bond).
      await expect(
        appealManager.connect(claimCreator).openAppealRound(claimId)
      ).to.be.revertedWithCustomError(appealManager, "InsufficientBondAllowance");

      expect(await vault.totalLocked()).to.equal(0);
      expect(await appealManager.getAppealRound(claimId).then((r) => r.status)).to.equal(0); // NONE
    });

    it("R1: a zero-balance opener with allowance cannot grief a lock (CustodyTransitionFailed, fail closed)", async () => {
      // approve() does not require funds; the vault transfer reverts and the open is
      // atomically rolled back with no lock and no round state.
      await token.connect(claimCreator).approve(await vault.getAddress(), ethers.MaxUint256);

      await expect(
        appealManager.connect(claimCreator).openAppealRound(claimId)
      ).to.be.revertedWithCustomError(appealManager, "CustodyTransitionFailed");

      expect(await vault.totalLocked()).to.equal(0);
      expect(await appealManager.getAppealRound(claimId).then((r) => r.status)).to.equal(0);
    });

    it("bonds escalate per round and are capped by maxAppealBond", async () => {
      expect(await appealManager.requiredAppealBond(1)).to.equal(APPEAL_BOND);
      expect(await appealManager.requiredAppealBond(2)).to.equal((APPEAL_BOND * 15000n) / 10000n);

      // Round 1 bond == base appeal bond
      await appealManager.connect(outsider).openAppealRound(claimId);
      let round = await appealManager.getAppealRound(claimId);
      expect(round.requiredBond).to.equal(APPEAL_BOND);
      expect((await vault.getLock(round.bondLockId)).amount).to.equal(APPEAL_BOND);

      await closeRound(claimId);

      // Round 2 bond == escalated bond; the vault ledger reconciles 1:1
      await appealManager.connect(outsider).openAppealRound(claimId);
      round = await appealManager.getAppealRound(claimId);
      expect(round.roundIndex).to.equal(2n);
      expect(round.requiredBond).to.equal((APPEAL_BOND * 15000n) / 10000n);
      expect((await vault.getLock(round.bondLockId)).amount).to.equal((APPEAL_BOND * 15000n) / 10000n);
      expect(await vault.totalLocked()).to.equal(APPEAL_BOND + (APPEAL_BOND * 15000n) / 10000n);
    });

    it("closing the final ladder round seals the path as terminal and emits AppealPathFinalized", async () => {
      await appealManager.connect(outsider).openAppealRound(claimId);
      await closeRound(claimId);
      expect(await appealManager.isAppealPathTerminal(claimId)).to.be.false;

      await appealManager.connect(outsider).openAppealRound(claimId);
      const round = await appealManager.getAppealRound(claimId);
      await time.increaseTo(Number(round.deadline) + 1);

      await expect(appealManager.connect(outsider).closeAppealRound(claimId))
        .to.emit(appealManager, "AppealPathFinalized")
        .withArgs(claimId, 2n, 0n, 0n, 0n);

      const closed = await appealManager.getAppealRound(claimId);
      expect(closed.status).to.equal(3); // RESOLVED
      expect(await appealManager.isAppealPathTerminal(claimId)).to.be.true;
    });

    it("R2: a terminal path can never be reopened (AppealPathTerminal), even with new funds", async () => {
      await appealManager.connect(outsider).openAppealRound(claimId);
      await closeRound(claimId);
      await appealManager.connect(outsider).openAppealRound(claimId);
      await closeRound(claimId);

      expect(await appealManager.isAppealPathTerminal(claimId)).to.be.true;

      await expect(
        appealManager.connect(outsider).openAppealRound(claimId)
      ).to.be.revertedWithCustomError(appealManager, "AppealPathTerminal");
    });

    it("R2: opening beyond a lowered ladder cap reverts (MaxAppealRoundsExceeded)", async () => {
      await appealManager.connect(outsider).openAppealRound(claimId);
      await closeRound(claimId);

      // Governance lowers the live cap below the rounds already opened
      await appealManager.connect(admin).setDefaultConfig({
        ...baseAppealConfig,
        maxAppealRounds: 1,
        appealBondEscalationBps: APPEAL_BOND_ESCALATION_BPS,
      });

      await expect(
        appealManager.connect(outsider).openAppealRound(claimId)
      ).to.be.revertedWithCustomError(appealManager, "MaxAppealRoundsExceeded");
    });

    it("R3: a voter flood past the per-round cap is bounded (VoterLimitExceeded)", async () => {
      await appealManager.connect(admin).setDefaultConfig({
        ...baseAppealConfig,
        maxVotersPerRound: 1,
        appealBondEscalationBps: APPEAL_BOND_ESCALATION_BPS,
      });
      await appealManager.connect(outsider).openAppealRound(claimId);

      await appealManager.connect(appellant1).submitAppealVote(claimId, true, MIN_APPEAL_STAKE);

      await expect(
        appealManager.connect(appellant2).submitAppealVote(claimId, false, MIN_APPEAL_STAKE)
      ).to.be.revertedWithCustomError(appealManager, "VoterLimitExceeded");

      const round = await appealManager.getAppealRound(claimId);
      expect(round.verifierCount).to.equal(1);
    });

    it("finalizeAppealRound is permissionless and idempotent-safe", async () => {
      await appealManager.connect(outsider).openAppealRound(claimId);
      const round = await appealManager.getAppealRound(claimId);
      await time.increaseTo(Number(round.deadline) + 1);

      // OPEN-but-expired: single call closes AND finalizes
      await expect(appealManager.connect(outsider).finalizeAppealRound(claimId))
        .to.emit(appealManager, "AppealRoundClosed")
        .to.emit(appealManager, "AppealPathFinalized");

      expect(await appealManager.isAppealPathTerminal(claimId)).to.be.true;

      // Second call reverts
      await expect(
        appealManager.connect(outsider).finalizeAppealRound(claimId)
      ).to.be.revertedWithCustomError(appealManager, "AppealPathAlreadyFinalized");
    });

    it("finalizeAppealRound on an active (non-expired) round reverts (AppealRoundNotExpired)", async () => {
      await appealManager.connect(outsider).openAppealRound(claimId);
      await expect(
        appealManager.connect(outsider).finalizeAppealRound(claimId)
      ).to.be.revertedWithCustomError(appealManager, "AppealRoundNotExpired");
    });

    it("finalizeAppealRound with no round reverts (AppealRoundNotClosed)", async () => {
      await expect(
        appealManager.connect(outsider).finalizeAppealRound(claimId)
      ).to.be.revertedWithCustomError(appealManager, "AppealRoundNotClosed");
    });

    it("finalizeAppealRound on a closed non-terminal round seals the ladder", async () => {
      await appealManager.connect(outsider).openAppealRound(claimId);
      await closeRound(claimId);
      expect(await appealManager.isAppealPathTerminal(claimId)).to.be.false;

      await expect(appealManager.connect(outsider).finalizeAppealRound(claimId))
        .to.emit(appealManager, "AppealPathFinalized");

      expect(await appealManager.isAppealPathTerminal(claimId)).to.be.true;
      expect((await appealManager.getAppealRound(claimId)).status).to.equal(3); // RESOLVED
    });

    it("the bond lock ledger survives round closure for SC-018 disposition (getAppealBondLock)", async () => {
      await appealManager.connect(outsider).openAppealRound(claimId);
      const round = await appealManager.getAppealRound(claimId);
      await time.increaseTo(Number(round.deadline) + 1);
      await appealManager.connect(outsider).closeAppealRound(claimId);

      // Bond is NOT disposed by the appeal module; the recorded lock enables SC-018.
      expect(await vault.totalLocked()).to.equal(APPEAL_BOND);
      const appealBondLock = await appealManager.getAppealBondLock(claimId);
      expect(appealBondLock.lockId).to.equal(round.bondLockId);
      expect(appealBondLock.released).to.be.false;
      expect(appealBondLock.amount).to.equal(APPEAL_BOND);
    });
  });
});