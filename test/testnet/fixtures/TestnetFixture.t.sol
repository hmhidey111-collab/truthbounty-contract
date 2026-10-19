// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import "../../../contracts/TruthBounty.sol";
import "../../../contracts/governance/GovernanceController.sol";
import "../../../contracts/governance/EmergencyController.sol";
import "../../../contracts/governance/ParameterVersionRegistry.sol";
import "../../../contracts/upgrade/ProtocolUpgradeManager.sol";
import "../../../contracts/upgrade/StorageCompatibilityValidator.sol";
import "../../../contracts/MockERC20.sol";
import "../../../contracts/MockReputationOracle.sol";
import "../../../contracts/ClaimRegistry.sol";
import "../../../contracts/TruthBountyWeighted.sol";
import "../../../contracts/VerificationAggregator.sol";
import "../../../contracts/settlement/ProvisionalSettlementEngine.sol";
import "../../../contracts/disputes/AppealVerificationRound.sol";
import {StakeVault as AppealBondVault} from "../../../contracts/StakeVault.sol";
import "../../../contracts/interfaces/IAppealVerificationRound.sol";
import "../../../contracts/interfaces/ITruthBountyEvents.sol";
import "../../../contracts/interfaces/IParameterVersionRegistry.sol";

/// @title Testnet Deployment Fixture (V2-SC-130)
/// @notice Reusable deployment fixture for all V2 testnet test files.
///         Provides deterministic addresses and fully wired protocol contracts.
///
/// Acceptance Criteria:
///   AC-2: Minimum production contracts/libraries/scripts/fixtures implemented
///   AC-3: Affected interfaces, storage, events, roles mapped
contract TestnetFixture is Test {
    uint256 public constant MIN_STAKE = 100 * 10**18;
    uint256 public constant VERIFICATION_WINDOW = 2 days;
    uint256 public constant CHALLENGE_WINDOW = 3 days;
    uint256 public constant APPEAL_WINDOW = 3 days;

    bytes32 public constant REGISTRY_UPDATER_ROLE = keccak256("REGISTRY_UPDATER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant PROPOSAL_EXECUTOR_ROLE = keccak256("PROPOSAL_EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant EMERGENCY_COUNCIL = keccak256("EMERGENCY_COUNCIL");
    bytes32 public constant DAO_GOVERNANCE = keccak256("DAO_GOVERNANCE");
    bytes32 public constant VERSION_PROPOSER_ROLE = keccak256("VERSION_PROPOSER_ROLE");
    bytes32 public constant VERSION_EXECUTOR_ROLE = keccak256("VERSION_EXECUTOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant RECOVERY_EXECUTOR = keccak256("RECOVERY_EXECUTOR");

    address public deployer;
    address public admin;
    address public claimCreator;
    address public verifier1;
    address public verifier2;
    address public challenger;
    address public outsider;
    address public treasury;

    MockERC20 public token;
    GovernanceController public governanceController;
    EmergencyController public emergencyController;
    ParameterVersionRegistry public parameterVersionRegistry;
    ProtocolUpgradeManager public upgradeManager;
    StorageCompatibilityValidator public storageValidator;
    ClaimRegistry public claimRegistry;
    TruthBountyWeighted public truthBounty;
    VerificationAggregator public aggregator;
    ProvisionalSettlementEngine public settlementEngine;
    AppealVerificationRound public appealRound;
    MockReputationOracle public oracle;

    struct Deployment {
        MockERC20 token;
        GovernanceController governanceController;
        EmergencyController emergencyController;
        ParameterVersionRegistry parameterVersionRegistry;
        ProtocolUpgradeManager upgradeManager;
        StorageCompatibilityValidator storageValidator;
        ClaimRegistry claimRegistry;
        TruthBountyWeighted truthBounty;
        VerificationAggregator aggregator;
        ProvisionalSettlementEngine settlementEngine;
        AppealVerificationRound appealRound;
        MockReputationOracle oracle;
        address deployer;
        address admin;
    }

    function deploy() internal returns (Deployment memory d) {
        deployer = vm.addr(0);
        admin = vm.addr(1);
        claimCreator = vm.addr(2);
        verifier1 = vm.addr(3);
        verifier2 = vm.addr(4);
        challenger = vm.addr(5);
        outsider = vm.addr(6);
        treasury = vm.addr(7);

        token = new MockERC20("TruthBounty Token", "TBT");
        token.mint(deployer, 10_000_000 * 10**18);

        governanceController = new GovernanceController(deployer);
        emergencyController = new EmergencyController(deployer, deployer, deployer);
        parameterVersionRegistry = new ParameterVersionRegistry(deployer, address(governanceController));
        upgradeManager = new ProtocolUpgradeManager(deployer, address(governanceController));
        storageValidator = new StorageCompatibilityValidator();
        oracle = new MockReputationOracle();

        parameterVersionRegistry.grantRole(REGISTRY_UPDATER_ROLE, deployer);
        claimRegistry = new ClaimRegistry(deployer, address(parameterVersionRegistry));
        claimRegistry.grantRole(REGISTRY_UPDATER_ROLE, deployer);

        truthBounty = new TruthBountyWeighted(address(token), address(oracle), deployer, address(governanceController));
        aggregator = new VerificationAggregator(address(truthBounty), deployer, 0, 0, 0);
        settlementEngine = new ProvisionalSettlementEngine(
            address(claimRegistry), address(aggregator), CHALLENGE_WINDOW,
            address(governanceController), deployer
        );
        appealRound = new AppealVerificationRound(
            address(token), address(claimRegistry), address(oracle),
            address(new AppealBondVault(deployer, address(token))),
            IAppealVerificationRound.AppealRoundConfig({
                roundDuration: APPEAL_WINDOW,
                minStakeAmount: MIN_STAKE * 2,
                stakeMultiplierBps: 15000,
                maxWeightCap: 50000 * 10**18,
                parameterVersion: 1,
                maxAppealRounds: 1,
                appealBond: 100 * 10**18,
                appealBondEscalationBps: 15000,
                maxAppealBond: 1000 * 10**18,
                maxVotersPerRound: 100
            }),
            address(governanceController), deployer
        );

        claimRegistry.grantRole(REGISTRY_UPDATER_ROLE, address(settlementEngine));

        token.mint(claimCreator, 10000 * 10**18);
        token.mint(verifier1, 10000 * 10**18);
        token.mint(verifier2, 10000 * 10**18);
        token.mint(challenger, 10000 * 10**18);
        token.mint(outsider, 10000 * 10**18);
        token.mint(treasury, 10000 * 10**18);

        d = Deployment({
            token: token,
            governanceController: governanceController,
            emergencyController: emergencyController,
            parameterVersionRegistry: parameterVersionRegistry,
            upgradeManager: upgradeManager,
            storageValidator: storageValidator,
            claimRegistry: claimRegistry,
            truthBounty: truthBounty,
            aggregator: aggregator,
            settlementEngine: settlementEngine,
            appealRound: appealRound,
            oracle: oracle,
            deployer: deployer,
            admin: admin
        });
    }

    function setUp() public {
        deploy();
    }

    function grantRoles() internal {
        claimRegistry.grantRole(REGISTRY_UPDATER_ROLE, deployer);
        claimRegistry.grantRole(REGISTRY_UPDATER_ROLE, address(settlementEngine));
        governanceController.grantRole(GOVERNANCE_ROLE, deployer);
        governanceController.grantRole(PROPOSAL_EXECUTOR_ROLE, deployer);
        emergencyController.grantRole(EMERGENCY_COUNCIL, deployer);
        emergencyController.grantRole(DAO_GOVERNANCE, deployer);
        emergencyController.grantRole(GUARDIAN_ROLE, deployer);
        emergencyController.grantRole(RECOVERY_EXECUTOR, deployer);
    }

    function fundAccounts() internal {
        token.mint(claimCreator, 10000 * 10**18);
        token.mint(verifier1, 10000 * 10**18);
        token.mint(verifier2, 10000 * 10**18);
        token.mint(challenger, 10000 * 10**18);
        token.mint(outsider, 10000 * 10**18);
        token.mint(treasury, 10000 * 10**18);
    }

    function createClaimWithVote(uint256 claimId) internal {
        token.mint(verifier1, MIN_STAKE);
        vm.prank(verifier1);
        token.approve(address(truthBounty), MIN_STAKE);
        vm.prank(verifier1);
        truthBounty.stake(MIN_STAKE);
        vm.prank(verifier1);
        truthBounty.vote(claimId, true, MIN_STAKE);
    }

    function settleClaim(uint256 claimId) internal {
        vm.warp(block.timestamp + VERIFICATION_WINDOW + 100);
        vm.prank(outsider);
        truthBounty.settleClaim(claimId);
    }

    function verifyAllModulesNonZero(Deployment memory d) internal view {
        assertTrue(address(d.token) != address(0));
        assertTrue(address(d.governanceController) != address(0));
        assertTrue(address(d.emergencyController) != address(0));
        assertTrue(address(d.parameterVersionRegistry) != address(0));
        assertTrue(address(d.upgradeManager) != address(0));
        assertTrue(address(d.storageValidator) != address(0));
        assertTrue(address(d.claimRegistry) != address(0));
        assertTrue(address(d.truthBounty) != address(0));
        assertTrue(address(d.aggregator) != address(0));
        assertTrue(address(d.settlementEngine) != address(0));
        assertTrue(address(d.appealRound) != address(0));
        assertTrue(address(d.oracle) != address(0));
    }

    function verifyZeroAddressRejection() internal {
        vm.expectRevert("Zero address");
        new EmergencyController(address(0), deployer, deployer);
    }
}
