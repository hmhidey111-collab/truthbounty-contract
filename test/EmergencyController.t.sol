// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import "../contracts/governance/EmergencyController.sol";

/**
 * @title EmergencyControllerTest
 * @notice Unit tests for the Emergency Pause & Circuit Breaker Framework
 */
contract EmergencyControllerTest is Test {
    EmergencyController public controller;

    address public emergencyCouncil = makeAddr("emergencyCouncil");
    address public daoGovernance = makeAddr("daoGovernance");
    address public timelockController = makeAddr("timelockController");
    address public unauthorisedUser = makeAddr("unauthorisedUser");
    address public recoveryExecutor = makeAddr("recoveryExecutor");

    function setUp() public {
        controller = new EmergencyController(
            emergencyCouncil,
            daoGovernance,
            timelockController
        );
        // Resolve the role before pranking: the staticcall would otherwise consume the prank.
        bytes32 recoveryRole = controller.RECOVERY_EXECUTOR();
        vm.prank(daoGovernance);
        controller.grantRole(recoveryRole, recoveryExecutor);
    }

    /// @dev Prank-safe activation: the level view call is resolved before the prank is set.
    function _activatePauseAs(address who, uint8 level, string memory reason) internal {
        vm.prank(who);
        controller.activatePause(level, reason, bytes32(0));
    }

    // ─── Initialisation ───────────────────────────────────────────────

    function test_initialState() public view {
        assertEq(controller.currentPauseLevel(), controller.LEVEL_NORMAL());
        assertEq(controller.recoveryComplete(), true);
        assertEq(controller.getEmergencyHistoryCount(), 0);
    }

    function test_constructor_revertsZeroAddress() public {
        vm.expectRevert(EmergencyController.ZeroAddress.selector);
        new EmergencyController(address(0), daoGovernance, timelockController);
    }

    // ─── Pause Activation ─────────────────────────────────────────────

    function test_emergencyCouncil_canActivateLevel1() public {
        uint8 level = controller.LEVEL_HIGH_RISK();
        _activatePauseAs(emergencyCouncil, level, "Security incident");
        assertEq(controller.currentPauseLevel(), level);
    }

    function test_emergencyCouncil_canActivateLevel3() public {
        uint8 level = controller.LEVEL_SHUTDOWN();
        _activatePauseAs(emergencyCouncil, level, "Critical exploit");
        assertEq(controller.currentPauseLevel(), level);
    }

    function test_activatePauseRejectsReasonAboveByteLimit() public {
        uint256 maximum = controller.MAX_REASON_BYTES();
        string memory oversizedReason = new string(maximum + 1);

        vm.expectRevert(
            abi.encodeWithSelector(EmergencyController.ReasonTooLong.selector, maximum + 1, maximum)
        );
        vm.prank(emergencyCouncil);
        controller.activatePause(controller.LEVEL_HIGH_RISK(), oversizedReason, bytes32(0));

        assertEq(controller.currentPauseLevel(), controller.LEVEL_NORMAL());
        assertEq(controller.getEmergencyHistoryCount(), 0);
    }

    function test_daoGovernance_canActivateLevel2() public {
        uint8 level = controller.LEVEL_FINANCIAL();
        _activatePauseAs(daoGovernance, level, "Oracle failure");
        assertEq(controller.currentPauseLevel(), level);
    }

    function test_timelock_canActivateLevel1() public {
        uint8 level = controller.LEVEL_HIGH_RISK();
        // The timelock is rate-limited against `lastTimelockActivation` (0 at deploy).
        vm.warp(block.timestamp + controller.timelockCooldown() + 1);
        _activatePauseAs(timelockController, level, "Scheduled maintenance");
        assertEq(controller.currentPauseLevel(), level);
    }

    function test_timelock_cannotActivateLevel2() public {
        uint8 level = controller.LEVEL_FINANCIAL();
        vm.prank(timelockController);
        vm.expectRevert(
            abi.encodeWithSelector(EmergencyController.NotAuthorizedForLevel.selector, timelockController, level)
        );
        controller.activatePause(level, "Not allowed", bytes32(0));
    }

    function test_unauthorised_cannotActivate() public {
        uint8 level = controller.LEVEL_HIGH_RISK();
        vm.prank(unauthorisedUser);
        vm.expectRevert(
            abi.encodeWithSelector(EmergencyController.NotAuthorizedForLevel.selector, unauthorisedUser, level)
        );
        controller.activatePause(level, "Hack attempt", bytes32(0));
    }

    function test_cannotActivateSameOrLowerLevel() public {
        uint8 level = controller.LEVEL_HIGH_RISK();
        _activatePauseAs(emergencyCouncil, level, "First");

        vm.prank(emergencyCouncil);
        vm.expectRevert(abi.encodeWithSelector(EmergencyController.AlreadyAtLevel.selector, level));
        controller.activatePause(level, "Duplicate", bytes32(0));
    }

    function test_cannotActivateLevel0() public {
        // Level 0 equals the current (normal) level, so activation is rejected before
        // any level-specific validation: AlreadyAtLevel is raised, not InvalidPauseLevel.
        vm.prank(emergencyCouncil);
        vm.expectRevert(abi.encodeWithSelector(EmergencyController.AlreadyAtLevel.selector, 0));
        controller.activatePause(0, "Invalid", bytes32(0));
    }

    function test_cannotActivateAboveMaxLevel() public {
        vm.prank(emergencyCouncil);
        vm.expectRevert(
            abi.encodeWithSelector(EmergencyController.InvalidPauseLevel.selector, 99)
        );
        controller.activatePause(99, "Invalid", bytes32(0));
    }

    function test_timelockCooldown_enforced() public {
        uint8 level = controller.LEVEL_HIGH_RISK();
        // The timelock is rate-limited against `lastTimelockActivation` (0 at deploy).
        vm.warp(block.timestamp + controller.timelockCooldown() + 1);
        _activatePauseAs(timelockController, level, "First");

        // Lift via governance
        vm.prank(daoGovernance);
        controller.liftPause(bytes32(0));

        // Timelock tries again immediately — should fail
        vm.prank(timelockController);
        vm.expectRevert("Timelock cooldown not elapsed");
        controller.activatePause(level, "Too soon", bytes32(0));

        // After cooldown
        vm.warp(block.timestamp + controller.timelockCooldown() + 1);
        _activatePauseAs(timelockController, level, "After cooldown");
        assertEq(controller.currentPauseLevel(), level);
    }

    // ─── Pause Lifting ─────────────────────────────────────────────────

    function test_daoGovernance_canLiftPause() public {
        _activatePauseAs(emergencyCouncil, controller.LEVEL_HIGH_RISK(), "Test");

        vm.prank(daoGovernance);
        controller.liftPause(bytes32(0));

        assertEq(controller.currentPauseLevel(), controller.LEVEL_NORMAL());
    }

    function test_emergencyCouncil_cannotLiftPause() public {
        _activatePauseAs(emergencyCouncil, controller.LEVEL_HIGH_RISK(), "Test");

        vm.prank(emergencyCouncil);
        vm.expectRevert("Only DAO governance can lift pause");
        controller.liftPause(bytes32(0));
    }

    function test_cannotLiftWhenNotPaused() public {
        vm.prank(daoGovernance);
        vm.expectRevert(EmergencyController.ProtocolNotPaused.selector);
        controller.liftPause(bytes32(0));
    }

    // ─── Recovery ─────────────────────────────────────────────────────

    function test_recoveryFlow_completes() public {
        // Activate and lift
        _activatePauseAs(emergencyCouncil, controller.LEVEL_HIGH_RISK(), "Test");
        vm.prank(daoGovernance);
        controller.liftPause(bytes32(0));

        // Complete recovery steps
        vm.startPrank(recoveryExecutor);
        controller.completeRecoveryStep("Validation complete");
        controller.completeRecoveryStep("State verified");
        controller.completeRecoveryStep("All systems operational");
        vm.stopPrank();

        (bool complete, uint8 step, bool paused, uint8 level) = controller.getRecoveryStatus();
        assertTrue(complete);
        assertEq(step, 0);
        assertFalse(paused);
    }

    function test_recovery_mustBePaused() public {
        vm.prank(recoveryExecutor);
        vm.expectRevert("Recovery already complete");
        controller.completeRecoveryStep("Should fail");
    }

    // ─── Audit Trail ──────────────────────────────────────────────────

    function test_auditTrail_recordsActions() public {
        uint8 level = controller.LEVEL_HIGH_RISK();
        _activatePauseAs(emergencyCouncil, level, "First incident");

        assertEq(controller.getEmergencyHistoryCount(), 1);

        EmergencyController.EmergencyRecord[] memory history = controller.getEmergencyHistory(0, 10);
        assertEq(history[0].level, level);
        assertEq(history[0].initiator, emergencyCouncil);
        assertEq(history[0].reason, "First incident");
    }

    // ─── Read Interface ───────────────────────────────────────────────

    function test_isOperationAllowed_normalState() public view {
        assertTrue(controller.isOperationAllowed(keccak256("claim_creation")));
        assertTrue(controller.isOperationAllowed(keccak256("reward_distribution")));
    }

    function test_isOperationAllowed_level1_blocksHighRisk() public {
        _activatePauseAs(emergencyCouncil, controller.LEVEL_HIGH_RISK(), "Test");

        assertFalse(controller.isOperationAllowed(keccak256("claim_creation")));
        assertFalse(controller.isOperationAllowed(keccak256("staking")));
        assertTrue(controller.isOperationAllowed(keccak256("reward_distribution")));
    }

    function test_isOperationAllowed_level3_onlyGovernance() public {
        _activatePauseAs(emergencyCouncil, controller.LEVEL_SHUTDOWN(), "Critical");

        assertFalse(controller.isOperationAllowed(keccak256("claim_creation")));
        assertFalse(controller.isOperationAllowed(keccak256("reward_distribution")));
        assertTrue(controller.isOperationAllowed(keccak256("governance_recovery")));
    }

    // ─── Events ───────────────────────────────────────────────────────

    function test_emitsEmergencyPauseActivated() public {
        uint8 level = controller.LEVEL_HIGH_RISK();
        vm.prank(emergencyCouncil);
        vm.expectEmit(true, true, true, true);
        emit EmergencyController.EmergencyPauseActivated(level, emergencyCouncil, "Test reason", bytes32(0));
        controller.activatePause(level, "Test reason", bytes32(0));
    }

    function test_emitsEmergencyPauseLifted() public {
        uint8 level = controller.LEVEL_HIGH_RISK();
        _activatePauseAs(emergencyCouncil, level, "Test");

        vm.prank(daoGovernance);
        vm.expectEmit(true, true, true, true);
        emit EmergencyController.EmergencyPauseLifted(level, daoGovernance, bytes32(0));
        controller.liftPause(bytes32(0));
    }
}
