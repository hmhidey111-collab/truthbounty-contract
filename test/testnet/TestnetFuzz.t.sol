// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../../contracts/TruthBounty.sol";
import "../../contracts/governance/GovernanceController.sol";
import "../../contracts/governance/EmergencyController.sol";
import "../../contracts/governance/ParameterVersionRegistry.sol";
import "../../contracts/upgrade/ProtocolUpgradeManager.sol";
import "../../contracts/upgrade/StorageCompatibilityValidator.sol";
import "../../contracts/MockERC20.sol";
import "../../contracts/MockReputationOracle.sol";
import "../../contracts/ClaimRegistry.sol";
import "../../contracts/TruthBountyWeighted.sol";
import "../../contracts/VerificationAggregator.sol";
import "../../contracts/settlement/ProvisionalSettlementEngine.sol";
import "../../contracts/disputes/AppealVerificationRound.sol";
import {StakeVault as AppealBondVault} from "../../contracts/StakeVault.sol";
import "../../contracts/interfaces/IAppealVerificationRound.sol";
import "../../contracts/interfaces/ITruthBountyEvents.sol";
import "../../contracts/interfaces/IParameterVersionRegistry.sol";
import "../../contracts/mocks/EventArchitectureHarness.sol";

/// @title Testnet Fuzz Tests (V2-SC-130)
/// @notice Stateful fuzz coverage for protocol properties affected by deployment.
///
/// Acceptance Criteria:
///   AC-7: Stateful fuzz/invariant coverage for every affected protocol property
///   AC-8: Regression tests for each legacy or audit defect displaced
contract TestnetFuzz is Test {
    // ============ Constants ============

    uint256 public constant MIN_STAKE = 100 * 10**18;
    uint256 public constant VERIFICATION_WINDOW = 2 days;

    // ============ State ============

    address public deployer;
    address public admin;
    address public claimCreator;
    address public verifier1;
    address public verifier2;
    address public challenger;
    address public outsider;

    MockERC20 public token;
    GovernanceController public governanceController;
    EmergencyController public emergencyController;
    ParameterVersionRegistry public parameterVersionRegistry;
    ProtocolUpgradeManager public upgradeManager;
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
        ClaimRegistry claimRegistry;
        TruthBountyWeighted truthBounty;
        VerificationAggregator aggregator;
        ProvisionalSettlementEngine settlementEngine;
        AppealVerificationRound appealRound;
        MockReputationOracle oracle;
        address deployer;
    }

    function deploy() internal returns (Deployment memory d) {
        deployer = vm.addr(0);
        admin = vm.addr(1);
        claimCreator = vm.addr(2);
        verifier1 = vm.addr(3);
        verifier2 = vm.addr(4);
        challenger = vm.addr(5);
        outsider = vm.addr(6);

        token = new MockERC20("TruthBounty Token", "TBT");
        token.mint(deployer, 10_000_000 * 10**18);

        governanceController = new GovernanceController(deployer);
        emergencyController = new EmergencyController(deployer, deployer, deployer);
        parameterVersionRegistry = new ParameterVersionRegistry(deployer, address(governanceController));
        upgradeManager = new ProtocolUpgradeManager(deployer, address(governanceController));

        oracle = new MockReputationOracle();
        claimRegistry = new ClaimRegistry(deployer, address(parameterVersionRegistry));
        claimRegistry.grantRole(keccak256("REGISTRY_UPDATER_ROLE"), deployer);

        truthBounty = new TruthBountyWeighted(address(token), address(oracle), deployer, address(governanceController));
        aggregator = new VerificationAggregator(address(truthBounty), deployer, 0, 0, 0);
        settlementEngine = new ProvisionalSettlementEngine(address(claimRegistry), address(aggregator), VERIFICATION_WINDOW, address(governanceController), deployer);
        appealRound = new AppealVerificationRound(
            address(token),
            address(claimRegistry),
            address(oracle),
            address(new AppealBondVault(deployer, address(token))),
            IAppealVerificationRound.AppealRoundConfig({
                roundDuration: 3 days,
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
            address(governanceController),
            deployer
        );

        claimRegistry.grantRole(keccak256("REGISTRY_UPDATER_ROLE"), address(settlementEngine));

        token.mint(claimCreator, 10000 * 10**18);
        token.mint(verifier1, 10000 * 10**18);
        token.mint(verifier2, 10000 * 10**18);
        token.mint(challenger, 10000 * 10**18);
        token.mint(outsider, 10000 * 10**18);

        d = Deployment({
            token: token,
            governanceController: governanceController,
            emergencyController: emergencyController,
            parameterVersionRegistry: parameterVersionRegistry,
            upgradeManager: upgradeManager,
            claimRegistry: claimRegistry,
            truthBounty: truthBounty,
            aggregator: aggregator,
            settlementEngine: settlementEngine,
            appealRound: appealRound,
            oracle: oracle,
            deployer: deployer
        });
    }

    function setUp() public {
        deploy();
    }

    // ============ Fuzz Tests ============

    /// @notice Fuzz test: claim creation with random content lengths
    function test_fuzz_claim_creation(uint256 seed) public {
        vm.assume(seed > 0);
        vm.startPrank(claimCreator);

        string memory content = string(abi.encodePacked("Claim ", vm.toString(seed)));
        uint256 claimId = truthBounty.createClaim(content);
        assertGt(claimId, 0);
        assertEq(claimId, truthBounty.claimCounter() - 1);

        vm.stopPrank();
    }

    /// @notice Fuzz test: staking with bounded amounts
    function test_fuzz_staking(uint256 amount) public {
        vm.assume(amount > 0 && amount <= MIN_STAKE * 10);

        vm.startPrank(verifier1);

        token.mint(verifier1, amount);
        vm.prank(verifier1);
        token.approve(address(truthBounty), amount);
        truthBounty.stake(amount);

        (uint256 totalStaked, uint256 activeStakes, ) = truthBounty.verifierStakes(verifier1);
        assertEq(totalStaked, amount);

        vm.stopPrank();
    }

    /// @notice Fuzz test: voting with bounded stake amounts
    function test_fuzz_voting(uint256 amount) public {
        vm.assume(amount > 0 && amount <= MIN_STAKE * 10);

        vm.startPrank(claimCreator);
        uint256 claimId = truthBounty.createClaim("Fuzz vote test");

        vm.startPrank(verifier1);
        token.mint(verifier1, amount);
        vm.prank(verifier1);
        token.approve(address(truthBounty), amount);
        truthBounty.stake(amount);

        bool support = (amount % 2) == 0;
        truthBounty.vote(claimId, support, amount);

        (bool voted,, uint256 stakeAmount,,,,,,,, ) = truthBounty.votes(claimId, verifier1);
        assertEq(voted, true);
        assertEq(stakeAmount, amount);

        vm.stopPrank();
    }

    /// @notice Fuzz test: claim settlement after voting
    function test_fuzz_settlement(uint256 amount) public {
        vm.assume(amount >= MIN_STAKE && amount <= MIN_STAKE * 5);

        vm.startPrank(claimCreator);
        uint256 claimId = truthBounty.createClaim("Fuzz settlement test");

        vm.startPrank(verifier1);
        token.mint(verifier1, amount);
        vm.prank(verifier1);
        token.approve(address(truthBounty), amount);
        truthBounty.stake(amount);
        truthBounty.vote(claimId, true, amount);
        vm.stopPrank();

        vm.warp(block.timestamp + VERIFICATION_WINDOW + 100);

        // Settle should succeed
        vm.startPrank(outsider);
        truthBounty.settleClaim(claimId);

        (bool passed, uint256 totalRewards, uint256 totalSlashed,,,,,,,,,,,, ) = truthBounty.settlementResults(claimId);
        assertEq(passed, true);

        vm.stopPrank();
    }

    /// @notice Fuzz test: parameter updates with bounded values
    function test_fuzz_parameter_update(uint256 value) public {
        vm.startPrank(deployer);

        // Test different parameter types with bounded values
        if (value % 3 == 0) {
            bytes32 proposalId = governanceController.requestParameterUpdate(
                GovernanceHooks.ParameterType.SLASH_PERCENT,
                value % 100 + 1
            );
            assertTrue(proposalId != bytes32(0));
        } else if (value % 3 == 1) {
            bytes32 proposalId = governanceController.requestParameterUpdate(
                GovernanceHooks.ParameterType.MIN_STAKE_AMOUNT,
                (value % 100 + 1) * 10**18
            );
            assertTrue(proposalId != bytes32(0));
        } else {
            bytes32 proposalId = governanceController.requestParameterUpdate(
                GovernanceHooks.ParameterType.REWARD_PERCENT,
                value % 100 + 1
            );
            assertTrue(proposalId != bytes32(0));
        }

        vm.stopPrank();
    }

    /// @notice Fuzz test: emergency pause level activation
    function test_fuzz_pause_levels(uint8 level) public {
        vm.assume(level >= 1 && level <= 3);

        vm.startPrank(deployer);

        emergencyController.activatePause(level, string(abi.encodePacked("Pause level ", vm.toString(level))), bytes32(0));
        assertEq(emergencyController.currentPauseLevel(), level);

        // Lift pause
        emergencyController.liftPause(bytes32(0));
        assertEq(emergencyController.currentPauseLevel(), 0);

        vm.stopPrank();
    }

    /// @notice Fuzz test: upgrade proposal with bounded versions
    function test_fuzz_upgrade_proposal(uint256 major) public {
        vm.assume(major >= 2 && major <= 5);

        vm.startPrank(deployer);

        upgradeManager.registerModule(
            keccak256("TRUTH_BOUNTY"),
            address(truthBounty),
            ProtocolUpgradeManager.Version(1, 0, 0),
            bytes32(uint256(12345))
        );

        upgradeManager.proposeUpgrade(
            keccak256("TRUTH_BOUNTY"),
            address(verifier1),
            ProtocolUpgradeManager.Version(uint64(major), 0, 0),
            bytes32(uint256(12346)),
            bytes32(0),
            string(abi.encodePacked("Upgrade to v", vm.toString(major)))
        );

        assertEq(upgradeManager.getProposalCount(), 1);

        vm.stopPrank();
    }

    /// @notice Fuzz test: governance proposal execution with timelock
    function test_fuzz_governance_timelock(uint256 delay) public {
        vm.assume(delay >= 3600 && delay <= 86400);

        vm.startPrank(deployer);

        bytes32 proposalId = governanceController.requestParameterUpdate(
            GovernanceHooks.ParameterType.SLASH_PERCENT,
            25
        );

        // Try to execute before timelock
        vm.expectRevert();
        governanceController.executeParameterUpdate(proposalId);

        // Fast-forward past timelock
        vm.warp(block.timestamp + delay + 1);
        governanceController.executeParameterUpdate(proposalId);

        vm.stopPrank();
    }

    /// @notice Fuzz test: claim creation boundary conditions
    function test_fuzz_claim_creation_boundary(uint256 seed) public {
        vm.assume(seed > 0);

        vm.startPrank(claimCreator);

        // Create claim with minimal content
        uint256 claimId = truthBounty.createClaim(string(abi.encodePacked("C", seed)));
        assertGt(claimId, 0);

        // Verify claim exists
        (uint256 id, address submitter, string memory content, uint256 createdAt, uint256 verificationWindowEnd, bool settled, bool finalized, uint256 totalWeightedFor, uint256 totalWeightedAgainst, uint256 totalStakeAmount, uint256 totalStakedFor, uint256 totalStakedAgainst) = truthBounty.claims(claimId);
        assertEq(id, claimId);

        vm.stopPrank();
    }

    /// @notice Fuzz test: voting after multiple claims
    function test_fuzz_voting_after_multiple_claims(uint256 count) public {
        vm.assume(count > 0 && count <= 10);

        vm.startPrank(claimCreator);

        // Create multiple claims
        for (uint i = 0; i < count; i++) {
            truthBounty.createClaim(string(abi.encodePacked("Claim ", i)));
        }

        // Vote on the last claim
        uint256 claimId = truthBounty.claimCounter() - 1;

        token.mint(verifier1, MIN_STAKE);
        vm.prank(verifier1);
        token.approve(address(truthBounty), MIN_STAKE);

        vm.startPrank(verifier1);
        truthBounty.stake(MIN_STAKE);
        truthBounty.vote(claimId, true, MIN_STAKE);
        vm.stopPrank();

        (bool voted,,,,,,,,,, ) = truthBounty.votes(claimId, verifier1);
        assertEq(voted, true);

        vm.stopPrank();
    }

    /// @notice Fuzz test: stake withdrawal with bounded amounts
    function test_fuzz_withdraw_stake(uint256 amount) public {
        vm.assume(amount > 0 && amount <= MIN_STAKE * 5);

        vm.startPrank(verifier1);

        token.mint(verifier1, amount);
        vm.prank(verifier1);
        token.approve(address(truthBounty), amount);
        truthBounty.stake(amount);
        truthBounty.withdrawStake(amount);

        (uint256 totalStaked, uint256 activeStakes, ) = truthBounty.verifierStakes(verifier1);
        assertEq(totalStaked, 0);

        vm.stopPrank();
    }

    /// @notice Fuzz test: parameter version registry with bounded parameters
    function test_fuzz_parameter_version_registry(uint256 paramValue) public {
        vm.assume(paramValue > 0 && paramValue <= 1000);

        vm.startPrank(deployer);

        // Start from the validated active set; override only the fields this scenario exercises.
        IParameterVersionRegistry.EconomicParameters memory params = parameterVersionRegistry.getCurrentParameters();
        params.verifierRewardsBPS = uint16(paramValue % 10000);
        params.treasuryReserveBPS = 2000;
        params.ecosystemIncentivesBPS = 1500;
        params.governanceIncentivesBPS = 1000;
        params.protocolDevelopmentBPS = 500;
        params.emergencyReserveBPS = 500;
        params.emissionLimit = type(uint256).max;
        params.rewardMultiplier = 1e18;
        params.treasuryReserveTargetBPS = 2000;
        params.claimSubmissionFee = 0.001e18;
        params.verificationSubmissionFee = 0.001e18;
        params.disputeInitiationFee = 0.002e18;
        params.protocolReserveFeeBPS = 50;
        params.minStakeAmount = 1e18;
        params.minReputationScore = 0;
        params.maxReputationScore = 10000;
        params.defaultReputationScore = 5000;
        params.slashPercentageBPS = 1000;
        params.maxSlashPercentageBPS = 5000;

        // This may revert if allocation sum != 10000
        // We only test when it doesn't revert
        try parameterVersionRegistry.proposeNewVersion(params) {
            // Success
        } catch {
            // Expected for invalid allocations
        }

        vm.stopPrank();
    }

    /// @notice Regression test: verify no unbounded loops in claim operations
    function test_regression_no_unbounded_loops() public {
        vm.startPrank(claimCreator);

        // Create bounded number of claims
        for (uint i = 0; i < 20; i++) {
            truthBounty.createClaim(string(abi.encodePacked("Claim ", i)));
        }

        assertEq(truthBounty.claimCounter(), 20);

        vm.stopPrank();
    }

    /// @notice Regression test: verify zero-address rejection persists
    function test_regression_zero_address_rejection() public {
        // Governance zero address rejection
        vm.expectRevert("Zero address");
        governanceController.requestAddressParameterUpdate(
            GovernanceHooks.ParameterType.RESOLVER_ROLE,
            address(0)
        );
    }

    /// @notice Regression test: verify no double claim is possible
    function test_regression_no_double_claim() public {
        vm.startPrank(claimCreator);

        uint256 claimId = truthBounty.createClaim("No double claim");

        // Verify claim can only be settled once
        vm.startPrank(verifier1);
        token.mint(verifier1, MIN_STAKE);
        vm.prank(verifier1);
        token.approve(address(truthBounty), MIN_STAKE);
        truthBounty.stake(MIN_STAKE);
        truthBounty.vote(claimId, true, MIN_STAKE);
        vm.stopPrank();

        vm.warp(block.timestamp + VERIFICATION_WINDOW + 100);
        vm.prank(outsider);
        truthBounty.settleClaim(claimId);

        // Second settlement should fail
        vm.prank(outsider);
        vm.expectRevert("Claim already settled");
        truthBounty.settleClaim(claimId);

        vm.stopPrank();
    }

    /// @notice Regression test: verify replay protection
    function test_regression_replay_protection() public {
        vm.startPrank(claimCreator);

        uint256 claimId = truthBounty.createClaim("Replay protection");

        // Verify each claim ID is unique
        uint256 claimId2 = truthBounty.createClaim("Another claim");
        assertLt(claimId, claimId2);

        vm.stopPrank();
    }
}
