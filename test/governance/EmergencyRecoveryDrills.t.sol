// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import "../../contracts/governance/EmergencyController.sol";
import "../../contracts/governance/EmergencyProtected.sol";
import "../../contracts/governance/ParameterVersionRegistry.sol";
import "../../contracts/v2/EmergencyControls.sol";
import "../../contracts/v2/interfaces/V2EmergencyProtectedFixture.sol";
import {IEmergencyControls} from "../../contracts/v2/interfaces/IEmergencyControls.sol";
import {IV2Module} from "../../contracts/v2/interfaces/IV2Module.sol";
import {IParameterVersionRegistry} from "../../contracts/interfaces/IParameterVersionRegistry.sol";
import {V2Errors} from "../../contracts/v2/libraries/V2Errors.sol";

/**
 * @title MockProtectedProtocolModule
 * @notice Mock protocol module implementing EmergencyProtected to simulate protocol mutations
 *         across claim creation, staking, verification, and withdrawals during emergency drills.
 */
contract MockProtectedProtocolModule is EmergencyProtected {
    uint256 public activeClaimsCount;
    uint256 public verificationsCount;
    uint256 public totalStaked;
    uint256 public totalWithdrawn;
    uint256 public rewardsDistributed;
    uint256 public governanceRecoveryActions;

    constructor(address controller) {
        _setEmergencyController(controller);
    }

    function createClaim(bytes32 subject) external whenNotPaused(keccak256("claim_creation")) returns (uint256) {
        subject; // silence unused warning
        activeClaimsCount++;
        return activeClaimsCount;
    }

    function stake(uint256 amount) external whenNotPaused(keccak256("staking")) {
        totalStaked += amount;
    }

    function submitVerification(uint256 claimId) external whenNotPaused(keccak256("verification_submission")) {
        claimId;
        verificationsCount++;
    }

    function withdraw(uint256 amount) external whenNotPaused(keccak256("withdrawal")) {
        totalWithdrawn += amount;
    }

    function distributeReward(uint256 amount) external whenNotPaused(keccak256("reward_distribution")) {
        rewardsDistributed += amount;
    }

    function executeGovernanceRecovery() external whenNotPaused(keccak256("governance_recovery")) {
        governanceRecoveryActions++;
    }
}

/**
 * @title EmergencyRecoveryDrillsTest
 * @notice V2-SC-118 Emergency Recovery & Unpause Drills End-to-End Suite.
 * @dev Validates the 6 stages of the canonical emergency response lifecycle:
 *      1. Incident Trigger & Multi-Level Pause Activation (L1 HighRisk, L2 Financial, L3 Shutdown)
 *      2. Diagnosis & State Freezing (Lockouts verified, read integrity preserved)
 *      3. Configuration Repair under Timelocked Governance Authorization
 *      4. Reconciliation of Balances & Active-State Invariants
 *      5. Stepwise Recovery Execution (Steps 1 -> 2 -> 3) and Formal Unpause
 *      6. Post-Unpause Resumption of Normal Protocol Operations
 *      Plus direct V2 mutation path gating drills with V2EmergencyProtectedFixture and EmergencyControls.
 */
contract EmergencyRecoveryDrillsTest is Test {
    EmergencyController public controller;
    MockProtectedProtocolModule public module;
    ParameterVersionRegistry public paramRegistry;
    EmergencyControls public v2EmergencyControls;
    V2EmergencyProtectedFixture public v2Fixture;

    address public admin = makeAddr("admin");
    address public emergencyCouncil = makeAddr("emergencyCouncil");
    address public daoGovernance = makeAddr("daoGovernance");
    address public timelockController = makeAddr("timelockController");
    address public recoveryExecutor = makeAddr("recoveryExecutor");
    address public attacker = makeAddr("attacker");
    address public regularUser = makeAddr("regularUser");

    bytes32 public constant PROPOSAL_REF = keccak256("GOV-PROPOSAL-V2-EMERGENCY-DRILL-001");
    bytes32 public constant REPAIR_PROPOSAL_REF = keccak256("GOV-PROPOSAL-V2-PARAM-REPAIR-002");

    uint8 internal constant LEVEL_NORMAL = 0;
    uint8 internal constant LEVEL_HIGH_RISK = 1;
    uint8 internal constant LEVEL_FINANCIAL = 2;
    uint8 internal constant LEVEL_SHUTDOWN = 3;
    bytes32 internal constant RECOVERY_EXECUTOR_ROLE = keccak256("RECOVERY_EXECUTOR");

    event EmergencyPauseActivated(
        uint8 indexed level,
        address indexed executor,
        string reason,
        bytes32 indexed proposalRef
    );

    event EmergencyPauseLifted(
        uint8 indexed previousLevel,
        address indexed executor,
        bytes32 indexed proposalRef
    );

    event EmergencyActionRecorded(bytes32 indexed actionId);

    event RecoveryStepCompleted(
        uint8 indexed step,
        address indexed executor,
        string description
    );

    event RecoveryFinalised(address indexed executor, uint256 timestamp);

    function setUp() public {
        vm.startPrank(admin);

        controller = new EmergencyController(
            emergencyCouncil,
            daoGovernance,
            timelockController
        );

        module = new MockProtectedProtocolModule(address(controller));

        paramRegistry = new ParameterVersionRegistry(admin, daoGovernance);

        v2EmergencyControls = new EmergencyControls(admin, emergencyCouncil, daoGovernance);

        v2Fixture = new V2EmergencyProtectedFixture(address(v2EmergencyControls));

        // Grant version proposer and executor roles to daoGovernance
        paramRegistry.grantRole(paramRegistry.VERSION_PROPOSER_ROLE(), daoGovernance);
        paramRegistry.grantRole(paramRegistry.VERSION_EXECUTOR_ROLE(), daoGovernance);

        vm.stopPrank();

        // Authorize recovery executor in EmergencyController using pre-cached constant
        vm.prank(daoGovernance);
        controller.grantRole(RECOVERY_EXECUTOR_ROLE, recoveryExecutor);
    }

    // =========================================================================
    // STAGE 1: Incident Trigger & Multi-Level Pause Activation
    // =========================================================================

    function test_Stage1_EmergencyCouncil_Activates_Level1_HighRisk() public {
        vm.expectEmit(true, true, true, true);
        emit EmergencyPauseActivated(
            LEVEL_HIGH_RISK,
            emergencyCouncil,
            "Exploit detected: abnormal claim flood",
            PROPOSAL_REF
        );

        vm.prank(emergencyCouncil);
        controller.activatePause(
            LEVEL_HIGH_RISK,
            "Exploit detected: abnormal claim flood",
            PROPOSAL_REF
        );

        assertEq(controller.currentPauseLevel(), LEVEL_HIGH_RISK);
        assertFalse(controller.recoveryComplete());
        assertEq(controller.getEmergencyHistoryCount(), 1);

        EmergencyController.EmergencyRecord[] memory history = controller.getEmergencyHistory(0, 1);
        assertEq(history[0].level, LEVEL_HIGH_RISK);
        assertEq(history[0].initiator, emergencyCouncil);
        assertEq(history[0].reason, "Exploit detected: abnormal claim flood");
        assertEq(history[0].proposalRef, PROPOSAL_REF);
    }

    function test_Stage1_EmergencyCouncil_Escalates_To_Level2_Financial() public {
        vm.prank(emergencyCouncil);
        controller.activatePause(LEVEL_HIGH_RISK, "Initial risk", PROPOSAL_REF);

        vm.expectEmit(true, true, true, true);
        emit EmergencyPauseActivated(
            LEVEL_FINANCIAL,
            emergencyCouncil,
            "Escalation: drain pattern detected on payouts",
            PROPOSAL_REF
        );

        vm.prank(emergencyCouncil);
        controller.activatePause(
            LEVEL_FINANCIAL,
            "Escalation: drain pattern detected on payouts",
            PROPOSAL_REF
        );

        assertEq(controller.currentPauseLevel(), LEVEL_FINANCIAL);
        assertEq(controller.getEmergencyHistoryCount(), 2);
    }

    function test_Stage1_EmergencyCouncil_Escalates_To_Level3_Shutdown() public {
        vm.prank(emergencyCouncil);
        controller.activatePause(
            LEVEL_SHUTDOWN,
            "Catastrophic failure: global protocol shutdown",
            PROPOSAL_REF
        );

        assertEq(controller.currentPauseLevel(), LEVEL_SHUTDOWN);
    }

    function test_Stage1_Rejects_Unauthorized_Callers() public {
        bytes memory expectedErr = abi.encodeWithSelector(
            EmergencyController.NotAuthorizedForLevel.selector,
            attacker,
            LEVEL_HIGH_RISK
        );

        vm.expectRevert(expectedErr);
        vm.prank(attacker);
        controller.activatePause(LEVEL_HIGH_RISK, "Malicious pause", bytes32(0));
    }

    function test_Stage1_SeparationOfPowers_CouncilCannotUnpause() public {
        vm.prank(emergencyCouncil);
        controller.activatePause(LEVEL_HIGH_RISK, "Security threat", PROPOSAL_REF);

        // Emergency Council attempts to unilaterally lift the pause
        vm.expectRevert("Only DAO governance can lift pause");
        vm.prank(emergencyCouncil);
        controller.liftPause(PROPOSAL_REF);
    }

    function test_Stage1_CannotActivateLowerOrSameLevel() public {
        vm.prank(emergencyCouncil);
        controller.activatePause(LEVEL_FINANCIAL, "Financial pause", PROPOSAL_REF);

        bytes memory expectedErr = abi.encodeWithSelector(
            EmergencyController.AlreadyAtLevel.selector,
            LEVEL_FINANCIAL
        );

        vm.expectRevert(expectedErr);
        vm.prank(emergencyCouncil);
        controller.activatePause(LEVEL_HIGH_RISK, "Attempting downgrade", PROPOSAL_REF);
    }

    function test_Stage1_TimelockController_CooldownEnforced() public {
        uint256 cooldown = controller.timelockCooldown();

        vm.prank(timelockController);
        controller.activatePause(LEVEL_HIGH_RISK, "Timelock pause", PROPOSAL_REF);

        // Governance lifts
        vm.prank(daoGovernance);
        controller.liftPause(PROPOSAL_REF);

        // Immediate reactivation by timelock must revert
        vm.expectRevert("Timelock cooldown not elapsed");
        vm.prank(timelockController);
        controller.activatePause(LEVEL_HIGH_RISK, "Immediate replay", PROPOSAL_REF);

        // Elapse cooldown
        vm.warp(block.timestamp + cooldown + 1);
        vm.prank(timelockController);
        controller.activatePause(LEVEL_HIGH_RISK, "Post cooldown", PROPOSAL_REF);
        assertEq(controller.currentPauseLevel(), LEVEL_HIGH_RISK);
    }

    // =========================================================================
    // STAGE 2: Diagnosis & State Freezing (Operation Lockouts & Read Access)
    // =========================================================================

    function test_Stage2_StateFreezing_Level1_BlocksHighRiskOnly() public {
        // Initially normal, operations succeed
        module.createClaim(bytes32("claim-1"));
        module.stake(100 ether);
        module.submitVerification(1);
        module.withdraw(10 ether);

        // Pause Level 1
        vm.prank(emergencyCouncil);
        controller.activatePause(LEVEL_HIGH_RISK, "Incident L1", PROPOSAL_REF);

        // High-risk operations must revert
        vm.expectRevert(
            abi.encodeWithSelector(EmergencyProtected.OperationPaused.selector, keccak256("claim_creation"), 0)
        );
        module.createClaim(bytes32("claim-blocked"));

        vm.expectRevert(
            abi.encodeWithSelector(EmergencyProtected.OperationPaused.selector, keccak256("staking"), 0)
        );
        module.stake(50 ether);

        vm.expectRevert(
            abi.encodeWithSelector(EmergencyProtected.OperationPaused.selector, keccak256("verification_submission"), 0)
        );
        module.submitVerification(1);

        // Financial operations and read queries remain active at Level 1
        module.withdraw(5 ether);
        assertEq(module.totalWithdrawn(), 15 ether);
        assertEq(module.activeClaimsCount(), 1);
        assertEq(controller.getPauseLevel(), LEVEL_HIGH_RISK);
    }

    function test_Stage2_StateFreezing_Level2_BlocksHighRiskAndFinancial() public {
        // Pause Level 2
        vm.prank(emergencyCouncil);
        controller.activatePause(LEVEL_FINANCIAL, "Incident L2", PROPOSAL_REF);

        // High-risk blocked
        vm.expectRevert(
            abi.encodeWithSelector(EmergencyProtected.OperationPaused.selector, keccak256("claim_creation"), 0)
        );
        module.createClaim(bytes32("claim-blocked"));

        // Financial blocked
        vm.expectRevert(
            abi.encodeWithSelector(EmergencyProtected.OperationPaused.selector, keccak256("withdrawal"), 0)
        );
        module.withdraw(10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(EmergencyProtected.OperationPaused.selector, keccak256("reward_distribution"), 0)
        );
        module.distributeReward(10 ether);

        // Reads remain operational
        assertEq(controller.isOperationAllowed(keccak256("claim_creation")), false);
        assertEq(controller.isOperationAllowed(keccak256("withdrawal")), false);
        assertEq(controller.isOperationAllowed(keccak256("read_data")), true);
    }

    function test_Stage2_StateFreezing_Level3_BlocksAllExceptGovernanceRecovery() public {
        // Pause Level 3
        vm.prank(emergencyCouncil);
        controller.activatePause(LEVEL_SHUTDOWN, "Incident L3 Shutdown", PROPOSAL_REF);

        // All standard operations blocked
        assertFalse(controller.isOperationAllowed(keccak256("claim_creation")));
        assertFalse(controller.isOperationAllowed(keccak256("staking")));
        assertFalse(controller.isOperationAllowed(keccak256("verification_submission")));
        assertFalse(controller.isOperationAllowed(keccak256("reward_distribution")));
        assertFalse(controller.isOperationAllowed(keccak256("withdrawal")));

        // Only governance recovery is allowed
        assertTrue(controller.isOperationAllowed(keccak256("governance_recovery")));
        module.executeGovernanceRecovery();
        assertEq(module.governanceRecoveryActions(), 1);
    }

    // =========================================================================
    // STAGE 3: Configuration Repair under Timelocked Governance Authorization
    // =========================================================================

    function test_Stage3_ConfigurationRepair_EnforcesTimelock() public {
        // Create an existing claim under genesis version
        paramRegistry.recordClaimCreation(1);
        assertEq(paramRegistry.getClaimVersion(1), 1);

        // Activate L2 pause to freeze financial/risk state during repair
        vm.prank(emergencyCouncil);
        controller.activatePause(LEVEL_FINANCIAL, "Diagnosing parameter defect", PROPOSAL_REF);

        // Prepare repaired economic parameters
        IParameterVersionRegistry.EconomicParameters memory repairedParams;
        repairedParams.verifierRewardsBPS = 3500;
        repairedParams.treasuryReserveBPS = 2500;
        repairedParams.ecosystemIncentivesBPS = 1500;
        repairedParams.governanceIncentivesBPS = 1000;
        repairedParams.protocolDevelopmentBPS = 1000;
        repairedParams.emergencyReserveBPS = 500;
        repairedParams.emissionLimit = 1_000_000 ether;
        repairedParams.rewardMultiplier = 1e18;
        repairedParams.treasuryReserveTargetBPS = 2500;
        repairedParams.claimSubmissionFee = 0.002e18;
        repairedParams.verificationSubmissionFee = 0.002e18;
        repairedParams.disputeInitiationFee = 0.004e18;
        repairedParams.protocolReserveFeeBPS = 100;
        repairedParams.minStakeAmount = 2e18;
        repairedParams.minReputationScore = 0;
        repairedParams.maxReputationScore = 10000;
        repairedParams.defaultReputationScore = 5000;
        repairedParams.slashPercentageBPS = 1500;
        repairedParams.maxSlashPercentageBPS = 5000;

        // Propose repaired parameter version via DAO governance actor
        vm.prank(daoGovernance);
        uint256 repairedVersionId = paramRegistry.proposeNewVersion(repairedParams);
        assertEq(repairedVersionId, 2);

        // Attempt early activation before timelock elapses (MIN_ECONOMIC_PARAMETER_TIMELOCK = 2 days)
        vm.expectRevert();
        vm.prank(daoGovernance);
        paramRegistry.activateVersion(repairedVersionId);

        // Fast forward 2 days to satisfy timelock delay
        vm.warp(block.timestamp + 2 days + 1);

        // Execute activation via DAO governance actor
        vm.prank(daoGovernance);
        paramRegistry.activateVersion(repairedVersionId);

        // Verify configuration repair active
        assertEq(paramRegistry.currentActiveVersionId(), 2);
    }

    // =========================================================================
    // STAGE 4: Reconciliation of Balances & Active-State Invariants
    // =========================================================================

    function test_Stage4_Reconciliation_PreservesActiveClaimImmutability() public {
        // Pre-incident claim creation under version 1
        paramRegistry.recordClaimCreation(101);
        assertEq(paramRegistry.getClaimVersion(101), 1);

        // Trigger pause
        vm.prank(emergencyCouncil);
        controller.activatePause(LEVEL_HIGH_RISK, "Pause for reconciliation", PROPOSAL_REF);

        // Activate new version 2 (after warp)
        IParameterVersionRegistry.EconomicParameters memory repairedParams;
        repairedParams.verifierRewardsBPS = 3500;
        repairedParams.treasuryReserveBPS = 2500;
        repairedParams.ecosystemIncentivesBPS = 1500;
        repairedParams.governanceIncentivesBPS = 1000;
        repairedParams.protocolDevelopmentBPS = 1000;
        repairedParams.emergencyReserveBPS = 500;
        repairedParams.emissionLimit = 1_000_000 ether;
        repairedParams.rewardMultiplier = 1e18;
        repairedParams.treasuryReserveTargetBPS = 2500;
        repairedParams.claimSubmissionFee = 0.002e18;
        repairedParams.verificationSubmissionFee = 0.002e18;
        repairedParams.disputeInitiationFee = 0.004e18;
        repairedParams.protocolReserveFeeBPS = 100;
        repairedParams.minStakeAmount = 2e18;
        repairedParams.minReputationScore = 0;
        repairedParams.maxReputationScore = 10000;
        repairedParams.defaultReputationScore = 5000;
        repairedParams.slashPercentageBPS = 1500;
        repairedParams.maxSlashPercentageBPS = 5000;

        vm.prank(daoGovernance);
        uint256 v2Id = paramRegistry.proposeNewVersion(repairedParams);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(daoGovernance);
        paramRegistry.activateVersion(v2Id);

        // Immutability Invariant: existing claim 101 still uses version 1!
        assertEq(paramRegistry.getClaimVersion(101), 1);

        // New claim after repair will use version 2
        paramRegistry.recordClaimCreation(102);
        assertEq(paramRegistry.getClaimVersion(102), 2);
    }

    // =========================================================================
    // STAGE 5: Stepwise Recovery Execution & Formal Unpause
    // =========================================================================

    function test_Stage5_StepwiseRecovery_SequentialExecution() public {
        // Trigger pause
        vm.prank(emergencyCouncil);
        controller.activatePause(LEVEL_HIGH_RISK, "Incident active", PROPOSAL_REF);

        // Step 1 before liftPause must revert (protocol must be unpaused first)
        vm.expectRevert("Protocol is still paused");
        vm.prank(recoveryExecutor);
        controller.completeRecoveryStep("Diagnosis complete");

        // DAO Governance formally lifts the pause
        vm.expectEmit(true, true, true, true);
        emit EmergencyPauseLifted(LEVEL_HIGH_RISK, daoGovernance, PROPOSAL_REF);
        vm.prank(daoGovernance);
        controller.liftPause(PROPOSAL_REF);

        assertEq(controller.currentPauseLevel(), LEVEL_NORMAL);
        assertFalse(controller.recoveryComplete());
        assertEq(controller.recoveryStep(), 0);

        // Step 1: Health check & configuration repair verification
        vm.expectEmit(true, true, false, true);
        emit RecoveryStepCompleted(1, recoveryExecutor, "Step 1: Configuration repair verified");
        vm.prank(recoveryExecutor);
        controller.completeRecoveryStep("Step 1: Configuration repair verified");

        assertEq(controller.recoveryStep(), 1);
        assertFalse(controller.recoveryComplete());

        // Unauthorized caller attempts Step 2
        vm.expectRevert("Not authorised for recovery");
        vm.prank(attacker);
        controller.completeRecoveryStep("Malicious step");

        // Step 2: State reconciliation & invariant verification
        vm.expectEmit(true, true, false, true);
        emit RecoveryStepCompleted(2, recoveryExecutor, "Step 2: Balance invariants reconciled");
        vm.prank(recoveryExecutor);
        controller.completeRecoveryStep("Step 2: Balance invariants reconciled");

        assertEq(controller.recoveryStep(), 2);
        assertFalse(controller.recoveryComplete());

        // Step 3: Operational sign-off & recovery finalization
        vm.expectEmit(true, true, false, true);
        emit RecoveryStepCompleted(3, recoveryExecutor, "Step 3: All systems operational");
        vm.expectEmit(true, false, false, true);
        emit RecoveryFinalised(recoveryExecutor, block.timestamp);
        vm.prank(recoveryExecutor);
        controller.completeRecoveryStep("Step 3: All systems operational");

        // Verification of complete recovery
        (bool complete, uint8 step, bool paused, uint8 level) = controller.getRecoveryStatus();
        assertTrue(complete);
        assertEq(step, 0);
        assertFalse(paused);
        assertEq(level, LEVEL_NORMAL);

        // Calling completeRecoveryStep after full recovery must revert
        vm.expectRevert("Recovery already complete");
        vm.prank(recoveryExecutor);
        controller.completeRecoveryStep("Extra step");
    }

    // =========================================================================
    // STAGE 6: Post-Unpause Resumption of Normal Protocol Operations
    // =========================================================================

    function test_Stage6_PostUnpause_ResumesFullProtocolOperations() public {
        // 1. Initial incident & pause
        vm.prank(emergencyCouncil);
        controller.activatePause(LEVEL_SHUTDOWN, "Critical incident", PROPOSAL_REF);

        // 2. Lift pause by governance
        vm.prank(daoGovernance);
        controller.liftPause(PROPOSAL_REF);

        // 3. Complete all 3 recovery steps
        vm.startPrank(recoveryExecutor);
        controller.completeRecoveryStep("Stage 1 verified");
        controller.completeRecoveryStep("Stage 2 verified");
        controller.completeRecoveryStep("Stage 3 verified");
        vm.stopPrank();

        // 4. Verify all protocol operations resume cleanly
        assertTrue(controller.isOperationAllowed(keccak256("claim_creation")));
        assertTrue(controller.isOperationAllowed(keccak256("staking")));
        assertTrue(controller.isOperationAllowed(keccak256("verification_submission")));
        assertTrue(controller.isOperationAllowed(keccak256("reward_distribution")));
        assertTrue(controller.isOperationAllowed(keccak256("withdrawal")));

        uint256 claimId = module.createClaim(bytes32("claim-post-recovery"));
        assertEq(claimId, 1);

        module.stake(250 ether);
        assertEq(module.totalStaked(), 250 ether);

        module.submitVerification(claimId);
        assertEq(module.verificationsCount(), 1);

        module.withdraw(50 ether);
        assertEq(module.totalWithdrawn(), 50 ether);
    }

    // =========================================================================
    // V2 CANONICAL EMERGENCY CONTROLS (IEmergencyControls) & FIXTURE DRILLS
    // =========================================================================

    function test_V2_EmergencyControls_ScopedPause_Drills() public {
        bytes32 claimsScope = v2EmergencyControls.SCOPE_CLAIMS();
        bytes32 treasuryScope = v2EmergencyControls.SCOPE_TREASURY();
        bytes32 globalScope = v2EmergencyControls.SCOPE_ALL();

        // Baseline: V2 mutation path succeeds when not paused
        uint256 claimId = v2Fixture.createClaim(bytes32("v2-subject"), 100 ether, "");
        assertEq(claimId, 1);

        // 1. Emergency role pauses claims scope
        vm.expectEmit(true, true, false, true);
        emit IEmergencyControls.EmergencyPaused(claimsScope, emergencyCouncil);
        vm.prank(emergencyCouncil);
        v2EmergencyControls.pause(claimsScope);

        assertTrue(v2EmergencyControls.paused(claimsScope));
        assertFalse(v2EmergencyControls.paused(treasuryScope));

        // 2. V2 mutation path fails closed when paused
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        v2Fixture.createClaim(bytes32("v2-blocked"), 50 ether, "");

        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        v2Fixture.cancelClaim(claimId);

        // Read operations remain unblocked
        assertEq(v2Fixture.getClaim(claimId).id, 1);

        // 3. Emergency role CANNOT unpause
        bytes memory unauthorizedUnpause = abi.encodeWithSelector(
            EmergencyControls.UnauthorizedToUnpause.selector,
            emergencyCouncil
        );
        vm.expectRevert(unauthorizedUnpause);
        vm.prank(emergencyCouncil);
        v2EmergencyControls.unpause(claimsScope);

        // 4. Admin cannot bypass governance to unpause
        bytes memory adminUnauthorizedUnpause = abi.encodeWithSelector(
            EmergencyControls.UnauthorizedToUnpause.selector,
            admin
        );
        vm.expectRevert(adminUnauthorizedUnpause);
        vm.prank(admin);
        v2EmergencyControls.unpause(claimsScope);

        // 5. Governance unpauses claims scope with 4-arg event
        vm.expectEmit(true, true, false, true);
        emit IEmergencyControls.EmergencyUnpaused(claimsScope, daoGovernance);
        vm.prank(daoGovernance);
        v2EmergencyControls.unpause(claimsScope);
        assertFalse(v2EmergencyControls.paused(claimsScope));

        // Mutation resumes post-unpause
        uint256 nextClaimId = v2Fixture.createClaim(bytes32("v2-resumed"), 150 ether, "");
        assertEq(nextClaimId, 2);

        // 6. Global pause halts all scopes
        vm.prank(emergencyCouncil);
        v2EmergencyControls.pause(globalScope);

        assertTrue(v2EmergencyControls.paused(globalScope));
        assertTrue(v2EmergencyControls.paused(claimsScope));
        assertTrue(v2EmergencyControls.paused(treasuryScope));
        assertTrue(v2EmergencyControls.paused(keccak256("RANDOM_MODULE")));

        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        v2Fixture.createClaim(bytes32("v2-global-blocked"), 10 ether, "");

        // 7. Governance lifts global pause
        vm.prank(daoGovernance);
        v2EmergencyControls.unpause(globalScope);

        assertFalse(v2EmergencyControls.paused(globalScope));
        assertFalse(v2EmergencyControls.paused(claimsScope));
    }
}
