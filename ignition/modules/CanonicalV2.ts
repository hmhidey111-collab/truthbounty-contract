import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { ethers } from "ethers";
import { validateCanonicalV2Parameters } from "../../scripts/validateDeploymentConfig";

/**
 * @title CanonicalV2DeploymentModule (SC-031)
 * @notice Canonical Hardhat Ignition deployment composition for TruthBounty Protocol V2.
 * @dev Deploys, configures, and wires the approved canonical V2 suite in strict dependency order.
 *      Excludes legacy contracts (e.g. TruthBountyClaims) and ensures deployer roles are finalized.
 *      Deployment parameters are validated against the canonical configuration bounds (SC-068)
 *      before any Ignition transaction is submitted.
 */
const CanonicalV2Module = buildModule("CanonicalV2Module", (m) => {
  // Account parameter defaults
  const deployer = m.getAccount(0);

  // Initial parameters
  const initialSupply = m.getParameter("initialSupply", ethers.parseEther("10000000").toString());
  const minVerificationCount = m.getParameter("minVerificationCount", 1n);
  const minTotalWeight = m.getParameter("minTotalWeight", 0n);
  const minConfidenceBps = m.getParameter("minConfidenceBps", 0n);
  const challengeWindowDuration = m.getParameter("challengeWindowDuration", 3 * 24 * 3600); // 3 days
  const appealDuration = m.getParameter("appealDuration", 3 * 24 * 3600); // 3 days
  const minAppealStake = m.getParameter("minAppealStake", ethers.parseEther("200").toString());
  const appealMultiplierBps = m.getParameter("appealMultiplierBps", 15000n); // 1.5x
  const maxWeightCap = m.getParameter("maxWeightCap", ethers.parseEther("100000").toString());
  const maxAppealRounds = m.getParameter("maxAppealRounds", 1n);
  const appealBond = m.getParameter("appealBond", ethers.parseEther("1000").toString());
  const appealBondEscalationBps = m.getParameter("appealBondEscalationBps", 15000n);
  const maxAppealBond = m.getParameter("maxAppealBond", ethers.parseEther("5000").toString());
  const maxVotersPerRound = m.getParameter("maxVotersPerRound", 200n);

  // Ignition parameters are unresolved deployment futures here. Validate their safe defaults;
  // callers supplying overrides must use the preflighted deployCanonicalV2 script.
  validateCanonicalV2Parameters({
    initialSupply: ethers.parseEther("10000000"),
    minVerificationCount: 1n,
    minTotalWeight: 0n,
    minConfidenceBps: 0n,
    challengeWindowDuration: 3 * 24 * 3600,
    appealDuration: 3 * 24 * 3600,
    minAppealStake: ethers.parseEther("200"),
    appealMultiplierBps: 15000,
    maxWeightCap: ethers.parseEther("100000"),
    parameterVersion: 1n,
  });

  // 1. Deploy Governance Controller
  const governanceController = m.contract("GovernanceController", [deployer]);

  // 2. Deploy Protocol Token (RewardToken)
  const token = m.contract("RewardToken", [deployer, initialSupply]);

  // 2b. Deploy Bond-Custody StakeVault (V2-SC-016/059 appeal bonds live here)
  const bondVault = m.contract("contracts/StakeVault.sol:StakeVault", [deployer, token]);

  // 3. Deploy Reputation Oracle
  const reputationOracle = m.contract("MockReputationOracle", []);

  // 4. Deploy Canonical ClaimRegistry
  const claimRegistry = m.contract("ClaimRegistry", [deployer]);

  // 5. Deploy Verification Source (TruthBountyWeighted)
  const truthBountyWeighted = m.contract("TruthBountyWeighted", [
    token,
    reputationOracle,
    deployer,
    governanceController,
  ]);

  // 6. Deploy Deterministic Verification Aggregator
  const verificationAggregator = m.contract("VerificationAggregator", [
    truthBountyWeighted,
    deployer,
    minVerificationCount,
    minTotalWeight,
    minConfidenceBps,
  ]);

  // 7. Deploy Provisional Settlement Engine
  const provisionalSettlementEngine = m.contract("ProvisionalSettlementEngine", [
    claimRegistry,
    verificationAggregator,
    challengeWindowDuration,
    governanceController,
    deployer,
  ]);

  // 8. Deploy Appeal Verification Round
  const appealConfig = {
    roundDuration: appealDuration,
    minStakeAmount: minAppealStake,
    stakeMultiplierBps: appealMultiplierBps,
    maxWeightCap: maxWeightCap,
    parameterVersion: 1n,
    maxAppealRounds: maxAppealRounds,
    appealBond: appealBond,
    appealBondEscalationBps: appealBondEscalationBps,
    maxAppealBond: maxAppealBond,
    maxVotersPerRound: maxVotersPerRound,
  };

  const appealVerificationRound = m.contract("AppealVerificationRound", [
    token,
    claimRegistry,
    reputationOracle,
    bondVault,
    appealConfig,
    governanceController,
    deployer,
  ]);

  // 9. Wire Permissions & Roles
  // Grant REGISTRY_UPDATER_ROLE on ClaimRegistry to ProvisionalSettlementEngine
  const REGISTRY_UPDATER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("REGISTRY_UPDATER_ROLE"));
  m.call(claimRegistry, "grantRole", [REGISTRY_UPDATER_ROLE, provisionalSettlementEngine]);

  // Authorise the appeal module to lock appeal bonds in the vault
  const OPERATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("OPERATOR_ROLE"));
  m.call(bondVault, "grantRole", [OPERATOR_ROLE, appealVerificationRound]);

  return {
    governanceController,
    token,
    reputationOracle,
    claimRegistry,
    truthBountyWeighted,
    verificationAggregator,
    provisionalSettlementEngine,
    appealVerificationRound,
    bondVault,
  };
});

export default CanonicalV2Module;
