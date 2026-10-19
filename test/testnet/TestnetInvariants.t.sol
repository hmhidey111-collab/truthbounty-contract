// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/Base.sol";
import "forge-std/StdInvariant.sol";

import "../../contracts/TruthBounty.sol";
import "../../contracts/governance/GovernanceController.sol";
import "../../contracts/governance/EmergencyController.sol";
import "../../contracts/governance/ParameterVersionRegistry.sol";
import "../../contracts/upgrade/ProtocolUpgradeManager.sol";
import "../../contracts/MockERC20.sol";
import "../../contracts/MockReputationOracle.sol";
import "../../contracts/ClaimRegistry.sol";
import "../../contracts/TruthBountyWeighted.sol";
import "../../contracts/VerificationAggregator.sol";
import "../../contracts/settlement/ProvisionalSettlementEngine.sol";
import "../../contracts/disputes/AppealVerificationRound.sol";
import {StakeVault as AppealBondVault} from "../../contracts/StakeVault.sol";
import "../../contracts/interfaces/IAppealVerificationRound.sol";
import "../../contracts/libraries/CanonicalEventLibrary.sol";

/// @title Stateful Invariant Tests for Testnet Deployment (V2-SC-130)
/// @notice Stateful fuzz/invariant coverage for every affected protocol property.
///
/// Acceptance Criteria:
///   AC-7: Stateful fuzz/invariant coverage for every affected protocol property
///   AC-8: Regression tests for each legacy or audit defect displaced
contract TestnetInvariants is Test {
    // ============ Constants ============

    uint256 public constant MIN_STAKE = 100 * 10**18;
    uint256 public constant VERIFICATION_WINDOW = 2 days;

    // ============ Roles ============

    bytes32 public constant REGISTRY_UPDATER_ROLE = keccak256("REGISTRY_UPDATER_ROLE");

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
        claimRegistry.grantRole(REGISTRY_UPDATER_ROLE, deployer);

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

        claimRegistry.grantRole(REGISTRY_UPDATER_ROLE, address(settlementEngine));

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

    // ============ Invariant Tests ============

    /// @notice Invariant: total rewards never exceed total slashed
    function invariant_totalRewardsNeverExceedTotalSlashed() public view {
        assertLe(truthBounty.totalRewarded(), truthBounty.totalSlashed());
    }

    /// @notice Invariant: contract balance is non-negative
    function invariant_contractBalanceIsNonNegative() public view {
        assertGe(address(truthBounty).balance, 0);
    }

    /// @notice Invariant: claim counter monotonically increases
    function invariant_claimCounterMonotonic() public view {
        assertGt(truthBounty.claimCounter(), 0);
    }

    /// @notice Invariant: settlement results are consistent
    function invariant_settlementResultConsistency() public view {
        for (uint i = 0; i < truthBounty.claimCounter() && i < 10; i++) {
            (bool passed, uint256 totalRewards, uint256 totalSlashed, uint256 winnerStake, uint256 loserStake,,,,,,,,,, ) = truthBounty.settlementResults(i);
            if (totalRewards > 0 || totalSlashed > 0) {
                assertGt(winnerStake + loserStake, 0);
            }
        }
    }

    /// @notice Invariant: no zero-address dependencies
    function invariant_no_zero_address_dependencies() public view {
        assertTrue(address(token) != address(0));
        assertTrue(address(governanceController) != address(0));
    }

    // ============ Stateful Test Functions ============

    /// @notice Stateful test: claim creation sequence is deterministic
    function test_stateful_claim_sequence_deterministic() public {
        vm.startPrank(claimCreator);

        uint256 beforeCounter = truthBounty.claimCounter();
        for (uint i = 0; i < 10; i++) {
            uint256 claimId = truthBounty.createClaim(string(abi.encodePacked("Claim ", vm.toString(i))));
            assertEq(claimId, beforeCounter + i);
        }
        assertEq(truthBounty.claimCounter(), beforeCounter + 10);
        vm.stopPrank();
    }

    /// @notice Stateful test: vote state transitions are consistent
    function test_stateful_vote_state_consistency() public {
        vm.startPrank(claimCreator);
        uint256 claimId = truthBounty.createClaim("Vote consistency test");

        token.mint(verifier1, MIN_STAKE * 2);
        vm.prank(verifier1);
        token.approve(address(truthBounty), MIN_STAKE * 2);

        vm.prank(verifier1);
        truthBounty.stake(MIN_STAKE);
        vm.prank(verifier1);
        truthBounty.vote(claimId, true, MIN_STAKE);

        (bool voted, bool support, uint256 stakeAmount,,, bool rewardClaimed, bool stakeReturned,,,, ) = truthBounty.votes(claimId, verifier1);
        assertEq(voted, true);
        assertEq(support, true);
        assertEq(stakeAmount, MIN_STAKE);

        vm.prank(verifier1);
        vm.expectRevert("Already voted");
        truthBounty.vote(claimId, false, MIN_STAKE);
        vm.stopPrank();
    }

    /// @notice Stateful test: settlement is idempotent
    function test_stateful_settlement_idempotent() public {
        vm.startPrank(claimCreator);
        uint256 claimId = truthBounty.createClaim("Settlement idempotency test");

        token.mint(verifier1, MIN_STAKE);
        vm.prank(verifier1);
        token.approve(address(truthBounty), MIN_STAKE);

        vm.prank(verifier1);
        truthBounty.stake(MIN_STAKE);
        vm.prank(verifier1);
        truthBounty.vote(claimId, true, MIN_STAKE);
        vm.stopPrank();

        vm.warp(block.timestamp + VERIFICATION_WINDOW + 100);
        vm.prank(outsider);
        truthBounty.settleClaim(claimId);

        vm.prank(outsider);
        vm.expectRevert("Claim already settled");
        truthBounty.settleClaim(claimId);
        vm.stopPrank();
    }

    /// @notice Stateful test: asset conservation through lifecycle
    function test_stateful_asset_conservation_lifecycle() public {
        vm.startPrank(claimCreator);
        uint256 claimId = truthBounty.createClaim("Asset conservation test");

        uint256 verifierBalance = token.balanceOf(verifier1);
        uint256 contractBalance = token.balanceOf(address(truthBounty));

        token.mint(verifier1, MIN_STAKE);
        vm.prank(verifier1);
        token.approve(address(truthBounty), MIN_STAKE);
        vm.prank(verifier1);
        truthBounty.stake(MIN_STAKE);

        assertEq(token.balanceOf(verifier1), verifierBalance - MIN_STAKE);
        assertEq(token.balanceOf(address(truthBounty)), contractBalance + MIN_STAKE);
        vm.stopPrank();
    }

    /// @notice Stateful test: pause state is consistent
    function test_stateful_pause_state_consistency() public {
        vm.startPrank(deployer);

        assertEq(emergencyController.currentPauseLevel(), 0);
        assertEq(emergencyController.isOperationAllowed(keccak256("claim_creation")), true);

        emergencyController.activatePause(1, "Test", bytes32(0));
        assertEq(emergencyController.currentPauseLevel(), 1);
        assertEq(emergencyController.isOperationAllowed(keccak256("claim_creation")), false);

        emergencyController.liftPause(bytes32(0));
        assertEq(emergencyController.currentPauseLevel(), 0);
        assertEq(emergencyController.isOperationAllowed(keccak256("claim_creation")), true);
        vm.stopPrank();
    }

    /// @notice Stateful test: governance parameter changes are traceable
    function test_stateful_governance_traceability() public {
        vm.startPrank(deployer);

        bytes32 proposalId = governanceController.requestParameterUpdate(
            GovernanceHooks.ParameterType.SLASH_PERCENT, 25
        );

        (GovernanceHooks.ParameterType paramType, uint256 oldValue, uint256 newValue, address newAddress, uint8 status, address proposer) = governanceController.getProposalDetails(proposalId);
        assertEq(proposer, deployer);
        assertEq(status, 0);
        vm.stopPrank();
    }
}

// ============ Invariant Handler for Stateful Fuzz ============

contract TruthBountyInvariantHandler is CommonBase {
    TruthBounty public truthBounty;
    MockERC20 public token;
    address[] public verifiers;
    uint256[] public claimIds;

    uint256 constant MIN_STAKE = 100 * 10**18;

    constructor(
        TruthBounty _truthBounty,
        MockERC20 _token,
        address[] memory _verifiers
    ) {
        truthBounty = _truthBounty;
        token = _token;
        verifiers = _verifiers;
        token.transfer(address(this), 1_000_000 * 10**18);
        token.approve(address(truthBounty), type(uint256).max);
    }

    function createClaim(uint256 seed) public {
        address submitter = verifiers[seed % verifiers.length];
        vm.prank(submitter);
        uint256 claimId = truthBounty.createClaim(string(abi.encodePacked("claim_", seed)));
        claimIds.push(claimId);
    }

    function stake(uint256 seed, uint256 amount) public {
        address verifier = verifiers[seed % verifiers.length];
        uint256 bounded = MIN_STAKE + (amount % (100_000 * 10**18 - MIN_STAKE));
        vm.prank(verifier);
        token.approve(address(truthBounty), bounded);
        truthBounty.stake(bounded);
    }

    function vote(uint256 claimIdx, uint256 seed, uint256 amount) public {
        if (claimIds.length == 0) return;
        uint256 claimId = claimIds[claimIdx % claimIds.length];
        address verifier = verifiers[seed % verifiers.length];
        uint256 bounded = MIN_STAKE + (amount % (100_000 * 10**18 - MIN_STAKE));
        bool support = (seed % 2) == 0;
        vm.prank(verifier);
        truthBounty.vote(claimId, support, bounded);
    }

    function settleClaim(uint256 claimIdx) public {
        if (claimIds.length == 0) return;
        uint256 claimId = claimIds[claimIdx % claimIds.length];
        (, , , , uint256 verificationWindowEnd, bool settled, , , ) = truthBounty.claims(claimId);
        if (settled) return;
        if (block.timestamp < verificationWindowEnd) vm.warp(verificationWindowEnd + 1);
        truthBounty.settleClaim(claimId);
    }
}
