import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
  ClaimRegistry,
  TruthBountyWeighted,
  VerificationAggregator,
  ProvisionalSettlementEngine,
  AppealVerificationRound,
  RewardToken,
  MockReputationOracle,
  GovernanceController,
  StakeVault,
} from "../../typechain-types";
import { deployClaimRegistry } from "../helpers/deployClaimRegistry";

export interface LifecycleAccounts {
  deployer: SignerWithAddress;
  claimCreator: SignerWithAddress;
  verifier1: SignerWithAddress;
  verifier2: SignerWithAddress;
  verifier3: SignerWithAddress;
  challenger: SignerWithAddress;
  appellant1: SignerWithAddress;
  appellant2: SignerWithAddress;
  outsider: SignerWithAddress;
}

export interface LifecycleEnvironment {
  accounts: LifecycleAccounts;
  contracts: {
    token: RewardToken;
    oracle: MockReputationOracle;
    govController: GovernanceController;
    claimRegistry: ClaimRegistry;
    truthBounty: TruthBountyWeighted;
    aggregator: VerificationAggregator;
    settlementEngine: ProvisionalSettlementEngine;
    appealRound: AppealVerificationRound;
    appealAggregator: VerificationAggregator;
    bondVault: StakeVault;
  };
  constants: {
    VERIFICATION_WINDOW: number;
    CHALLENGE_WINDOW: number;
    APPEAL_WINDOW: number;
    MIN_STAKE: bigint;
    MIN_APPEAL_STAKE: bigint;
    SAMPLE_CID: string;
  };
  helpers: {
    createClaim: (statement: string, deadlineOffset?: number) => Promise<{ claimId: bigint; deadline: number }>;
    stakeAndVote: (
      claimId: bigint,
      verifier: SignerWithAddress,
      support: boolean,
      amount: bigint,
      reputation?: bigint
    ) => Promise<void>;
    executeProvisionalSettlement: (claimId: bigint) => Promise<any>;
    openAppeal: (claimId: bigint) => Promise<any>;
    voteAppeal: (
      claimId: bigint,
      appellant: SignerWithAddress,
      support: boolean,
      amount: bigint,
      reputation?: bigint
    ) => Promise<any>;
    closeAndAggregateAppeal: (claimId: bigint) => Promise<any>;
  };
}

export async function deployLifecycleFixture(): Promise<LifecycleEnvironment> {
  const [
    deployer,
    claimCreator,
    verifier1,
    verifier2,
    verifier3,
    challenger,
    appellant1,
    appellant2,
    outsider,
  ] = await ethers.getSigners();

  const VERIFICATION_WINDOW = 2 * 24 * 3600; // 2 days
  const CHALLENGE_WINDOW = 3 * 24 * 3600; // 3 days
  const APPEAL_WINDOW = 3 * 24 * 3600; // 3 days
  const MIN_STAKE = ethers.parseEther("100");
  const MIN_APPEAL_STAKE = ethers.parseEther("200");
  const SAMPLE_CID = "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco";

  // 1. Deploy Token
  const TokenFactory = await ethers.getContractFactory("RewardToken", deployer);
  const token = await TokenFactory.deploy(deployer.address, ethers.parseEther("10000000"));
  await token.waitForDeployment();

  // 1b. Deploy Bond-Custody StakeVault (V2-SC-016/059 appeal bonds live here)
  const StakeVaultFactory = await ethers.getContractFactory(
    "contracts/StakeVault.sol:StakeVault",
    deployer
  );
  const bondVault = (await StakeVaultFactory.deploy(
    deployer.address,
    await token.getAddress()
  )) as StakeVault;
  await bondVault.waitForDeployment();

  // 2. Deploy Oracle
  const OracleFactory = await ethers.getContractFactory("MockReputationOracle", deployer);
  const oracle = await OracleFactory.deploy();
  await oracle.waitForDeployment();

  // 3. Deploy Governance Controller
  const GovFactory = await ethers.getContractFactory("GovernanceController", deployer);
  const govController = await GovFactory.deploy(deployer.address);
  await govController.waitForDeployment();

  // 4. Deploy ClaimRegistry
  const claimRegistry = await deployClaimRegistry(deployer.address);

  // 5. Deploy TruthBountyWeighted (Verification source)
  const TBFactory = await ethers.getContractFactory("TruthBountyWeighted", deployer);
  const truthBounty = await TBFactory.deploy(
    await token.getAddress(),
    await oracle.getAddress(),
    deployer.address,
    await govController.getAddress()
  );
  await truthBounty.waitForDeployment();

  // 6. Deploy First-round Verification Aggregator
  const AggFactory = await ethers.getContractFactory("VerificationAggregator", deployer);
  const aggregator = await AggFactory.deploy(
    await truthBounty.getAddress(),
    deployer.address,
    0, // minCount
    0, // minWeight
    0  // minConfidence
  );
  await aggregator.waitForDeployment();

  // 7. Deploy Provisional Settlement Engine
  const SettlementFactory = await ethers.getContractFactory("ProvisionalSettlementEngine", deployer);
  const settlementEngine = await SettlementFactory.deploy(
    await claimRegistry.getAddress(),
    await aggregator.getAddress(),
    CHALLENGE_WINDOW,
    await govController.getAddress(),
    deployer.address
  );
  await settlementEngine.waitForDeployment();

  // 8. Deploy Appeal Verification Round
  const AppealFactory = await ethers.getContractFactory("AppealVerificationRound", deployer);
  const appealConfig = {
    roundDuration: APPEAL_WINDOW,
    minStakeAmount: MIN_APPEAL_STAKE,
    stakeMultiplierBps: 15000n, // 1.5x
    maxWeightCap: ethers.parseEther("50000"),
    parameterVersion: 1n,
    maxAppealRounds: 1n,
    appealBond: ethers.parseEther("100"),
    appealBondEscalationBps: 10000n,
    maxAppealBond: ethers.parseEther("100"),
    maxVotersPerRound: 200n,
  };
  const appealRound = await AppealFactory.deploy(
    await token.getAddress(),
    await claimRegistry.getAddress(),
    await oracle.getAddress(),
    await bondVault.getAddress(),
    appealConfig,
    await govController.getAddress(),
    deployer.address
  );
  await appealRound.waitForDeployment();

  // Authorise the appeal module to lock appeal bonds in the vault
  const OPERATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("OPERATOR_ROLE"));
  await bondVault.grantRole(OPERATOR_ROLE, await appealRound.getAddress());

  // 9. Deploy Second-round Verification Aggregator (for appeals)
  const appealAggregator = await AggFactory.deploy(
    await appealRound.getAddress(),
    deployer.address,
    0,
    0,
    0
  );
  await appealAggregator.waitForDeployment();

  // 10. Wire Roles
  const REGISTRY_UPDATER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("REGISTRY_UPDATER_ROLE"));
  await claimRegistry.grantRole(REGISTRY_UPDATER_ROLE, await settlementEngine.getAddress());

  // 11. Distribute tokens & approve
  const fundedAccounts = [verifier1, verifier2, verifier3, challenger, appellant1, appellant2];
  for (const acct of fundedAccounts) {
    await token.transfer(acct.address, ethers.parseEther("10000"));
    await token.connect(acct).approve(await truthBounty.getAddress(), ethers.MaxUint256);
    await token.connect(acct).approve(await appealRound.getAddress(), ethers.MaxUint256);
    await token.connect(acct).approve(await bondVault.getAddress(), ethers.MaxUint256);
  }

  // Pre-seed 0th claim on TruthBountyWeighted so claim indices match 1-based ClaimRegistry
  await truthBounty.createClaim("Seed Claim 0");

  let claimSequence = 0;

  const createClaim = async (statement: string, deadlineOffset: number = VERIFICATION_WINDOW) => {
    claimSequence++;
    const now = await time.latest();
    const deadline = now + deadlineOffset;

    await truthBounty.connect(claimCreator).createClaim(statement);
    await claimRegistry.connect(claimCreator).createClaim(statement, SAMPLE_CID, deadline);

    return { claimId: BigInt(claimSequence), deadline };
  };

  const stakeAndVote = async (
    claimId: bigint,
    verifier: SignerWithAddress,
    support: boolean,
    amount: bigint,
    reputation?: bigint
  ) => {
    if (reputation !== undefined) {
      await oracle.setReputationScore(verifier.address, reputation);
    }
    await truthBounty.connect(verifier).stake(amount);
    await truthBounty.connect(verifier).vote(claimId, support, amount);
  };

  const executeProvisionalSettlement = async (claimId: bigint) => {
    const claim = await claimRegistry.getClaim(claimId);
    const now = await time.latest();
    if (BigInt(now) < claim.verificationDeadline) {
      await time.increaseTo(Number(claim.verificationDeadline) + 1);
    }
    return await settlementEngine.connect(outsider).provisionalSettle(claimId);
  };

  const openAppeal = async (claimId: bigint) => {
    return await appealRound.connect(challenger).openAppealRound(claimId);
  };

  const voteAppeal = async (
    claimId: bigint,
    appellant: SignerWithAddress,
    support: boolean,
    amount: bigint,
    reputation?: bigint
  ) => {
    if (reputation !== undefined) {
      await oracle.setReputationScore(appellant.address, reputation);
    }
    return await appealRound.connect(appellant).submitAppealVote(claimId, support, amount);
  };

  const closeAndAggregateAppeal = async (claimId: bigint) => {
    const round = await appealRound.getAppealRound(claimId);
    const now = await time.latest();
    if (BigInt(now) < round.deadline) {
      await time.increaseTo(Number(round.deadline) + 1);
    }
    await appealRound.connect(outsider).closeAppealRound(claimId);
    await appealAggregator.aggregateClaim(claimId);
    return await appealAggregator.getAggregation(claimId);
  };

  return {
    accounts: {
      deployer,
      claimCreator,
      verifier1,
      verifier2,
      verifier3,
      challenger,
      appellant1,
      appellant2,
      outsider,
    },
    contracts: {
      token,
      oracle,
      govController,
      claimRegistry,
      truthBounty,
      aggregator,
      settlementEngine,
      appealRound,
      appealAggregator,
      bondVault,
    },
    constants: {
      VERIFICATION_WINDOW,
      CHALLENGE_WINDOW,
      APPEAL_WINDOW,
      MIN_STAKE,
      MIN_APPEAL_STAKE,
      SAMPLE_CID,
    },
    helpers: {
      createClaim,
      stakeAndVote,
      executeProvisionalSettlement,
      openAppeal,
      voteAppeal,
      closeAndAggregateAppeal,
    },
  };
}
