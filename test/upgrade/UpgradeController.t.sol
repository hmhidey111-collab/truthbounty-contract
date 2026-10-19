// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/upgrade/IUpgradeController.sol";
import "../../contracts/upgrade/IVersionRegistry.sol";
import "../../contracts/upgrade/UpgradeController.sol";
import "../../contracts/upgrade/VersionRegistry.sol";
import "../../contracts/upgrade/StorageCompatibilityValidator.sol";

contract MockTargetContract {
    uint256 public value;
    uint256[49] private __gap;

    function initialize(uint256 _value) public {
        value = _value;
    }

    function setValue(uint256 _value) public {
        value = _value;
    }
}

contract MockTargetV2 {
    uint256 public value;
    uint256[49] private __gap;

    function initialize(uint256 _value) public {
        value = _value;
    }

    function setValue(uint256 _value) public {
        value = _value;
    }

    function newValue() public pure returns (uint256) {
        return 200;
    }
}

contract UpgradeControllerTest is Test {
    UpgradeController public controller;
    VersionRegistry public registry;
    StorageCompatibilityValidator public validator;

    address public admin = address(0x1);
    address public upgradeRole = address(0x2);
    address public emergencyRole = address(0x3);
    address public target = address(0x100);
    address public newImpl = address(0x200);
    address public currentImpl = address(0x300);

    function setUp() public {
        registry = new VersionRegistry(admin);
        validator = new StorageCompatibilityValidator();
        controller = new UpgradeController(admin, address(registry), address(validator));

        vm.startPrank(admin);
        controller.grantRole(controller.DEFAULT_ADMIN_ROLE(), address(this));
        controller.grantRole(controller.UPGRADE_ROLE(), upgradeRole);
        controller.grantRole(controller.EMERGENCY_UPGRADE_ROLE(), emergencyRole);
        vm.stopPrank();

        vm.prank(admin);
        controller.setCurrentImplementation(target, currentImpl);
    }

    function test_ProposeUpgrade_Standard() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        IUpgradeController.UpgradeProposal memory proposal = controller.getProposal(proposalId);
        assertEq(proposal.targetContract, target);
        assertEq(proposal.newImplementation, newImpl);
        assertEq(proposal.version, "1.0.0");
        assertEq(uint256(proposal.status), uint256(IUpgradeController.UpgradeStatus.PROPOSED));
        assertEq(uint256(proposal.upgradeType), uint256(IUpgradeController.UpgradeType.STANDARD));
    }

    function test_ProposeUpgrade_Emergency() public {
        vm.prank(emergencyRole);
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.EMERGENCY,
            bytes32(0)
        );

        IUpgradeController.UpgradeProposal memory proposal = controller.getProposal(proposalId);
        assertEq(uint256(proposal.upgradeType), uint256(IUpgradeController.UpgradeType.EMERGENCY));
        assertEq(uint256(proposal.status), uint256(IUpgradeController.UpgradeStatus.PROPOSED));
    }

    function test_ProposeUpgrade_RevertsWithZeroTarget() public {
        vm.expectRevert(abi.encodeWithSelector(UpgradeController.InvalidTarget.selector, address(0)));
        controller.proposeUpgrade(
            address(0),
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );
    }

    function test_ProposeUpgrade_RevertsWithZeroImpl() public {
        vm.expectRevert(abi.encodeWithSelector(UpgradeController.InvalidImplementation.selector, address(0)));
        controller.proposeUpgrade(
            target,
            address(0),
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );
    }

    function test_ProposeUpgrade_RevertsWithEmptyVersion() public {
        vm.expectRevert(abi.encodeWithSelector(UpgradeController.InvalidVersion.selector, ""));
        controller.proposeUpgrade(
            target,
            newImpl,
            "",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );
    }

    function test_ScheduleUpgrade() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        controller.scheduleUpgrade(proposalId);

        IUpgradeController.UpgradeProposal memory proposal = controller.getProposal(proposalId);
        assertEq(uint256(proposal.status), uint256(IUpgradeController.UpgradeStatus.SCHEDULED));
        assertGt(proposal.executeAfter, 0);
        assertGt(proposal.scheduledAt, 0);
    }

    function test_ScheduleUpgrade_RevertsWithoutRole() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        vm.prank(address(0x999));
        vm.expectRevert(UpgradeController.UnauthorizedEmergency.selector);
        controller.scheduleUpgrade(proposalId);
    }

    function test_ExecuteUpgrade() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        controller.scheduleUpgrade(proposalId);

        vm.warp(block.timestamp + 7 days);

        controller.executeUpgrade(proposalId);

        IUpgradeController.UpgradeProposal memory proposal = controller.getProposal(proposalId);
        assertEq(uint256(proposal.status), uint256(IUpgradeController.UpgradeStatus.EXECUTED));
        assertEq(controller.currentImplementation(target), newImpl);
    }

    function test_ExecuteUpgrade_RevertsBeforeDelay() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        controller.scheduleUpgrade(proposalId);

        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert();
        controller.executeUpgrade(proposalId);
    }

    function test_ExecuteUpgrade_RevertsAfterWindow() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        controller.scheduleUpgrade(proposalId);

        // Cross the 7-day standard delay plus the 7-day execution window.
        vm.warp(block.timestamp + 7 days + 7 days + 1);

        vm.expectRevert();
        controller.executeUpgrade(proposalId);
    }

    function test_CancelUpgrade() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        controller.cancelUpgrade(proposalId);

        IUpgradeController.UpgradeProposal memory proposal = controller.getProposal(proposalId);
        assertEq(uint256(proposal.status), uint256(IUpgradeController.UpgradeStatus.CANCELLED));
    }

    function test_CancelUpgrade_ByGovernance() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        vm.prank(address(0x999));
        vm.expectRevert();
        controller.cancelUpgrade(proposalId);

        controller.cancelUpgrade(proposalId);
    }

    function test_RollbackUpgrade() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        controller.scheduleUpgrade(proposalId);
        vm.warp(block.timestamp + 7 days);
        controller.executeUpgrade(proposalId);

        bytes32 rollbackId = controller.proposeUpgrade(
            target,
            currentImpl,
            "1.0.0-rollback",
            IUpgradeController.UpgradeType.ROLLBACK,
            bytes32(0)
        );

        controller.scheduleUpgrade(rollbackId);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        controller.executeUpgrade(rollbackId);

        assertEq(controller.currentImplementation(target), currentImpl);

        IUpgradeController.UpgradeProposal memory proposal = controller.getProposal(rollbackId);
        assertEq(uint256(proposal.status), uint256(IUpgradeController.UpgradeStatus.EXECUTED));
    }

    function test_EmergencyUpgrade_HasShorterDelay() public {
        vm.prank(emergencyRole);
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.EMERGENCY,
            bytes32(0)
        );

        controller.scheduleUpgrade(proposalId);

        vm.warp(block.timestamp + 24 hours);

        controller.executeUpgrade(proposalId);
        assertEq(controller.currentImplementation(target), newImpl);
    }

    function test_SetEmergencyDelay() public {
        uint256 newDelay = 12 hours;
        controller.setEmergencyDelay(newDelay);
        assertEq(controller.emergencyDelay(), newDelay);
    }

    function test_SetEmergencyDelay_RevertsInvalid() public {
        vm.expectRevert();
        controller.setEmergencyDelay(30 minutes);
    }

    function test_SetExecutionWindow() public {
        uint256 newWindow = 14 days;
        controller.setExecutionWindow(newWindow);
        assertEq(controller.executionWindow(), newWindow);
    }

    function test_GetUpgradeHistory() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        controller.scheduleUpgrade(proposalId);
        vm.warp(block.timestamp + 7 days);
        controller.executeUpgrade(proposalId);

        bytes32[] memory history = controller.getUpgradeHistory(target);
        assertEq(history.length, 1);
        assertEq(history[0], proposalId);
    }

    function test_GetPendingUpgrades() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        bytes32[] memory pending = controller.getPendingUpgrades(target);
        assertEq(pending.length, 0);

        controller.scheduleUpgrade(proposalId);

        pending = controller.getPendingUpgrades(target);
        assertEq(pending.length, 1);
    }

    function test_Pause_PreventsUpgrade() public {
        controller.pause();

        vm.expectRevert();
        controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );
    }

    function test_Unpause_AllowsUpgrade() public {
        controller.pause();
        controller.unpause();

        controller.proposeUpgrade(
            target,
            newImpl,
            "1.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );
    }
}
