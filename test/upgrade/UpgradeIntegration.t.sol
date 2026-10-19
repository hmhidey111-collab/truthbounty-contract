// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/upgrade/IUpgradeController.sol";
import "../../contracts/upgrade/IVersionRegistry.sol";
import "../../contracts/upgrade/UpgradeController.sol";
import "../../contracts/upgrade/VersionRegistry.sol";
import "../../contracts/upgrade/StorageCompatibilityValidator.sol";

contract UpgradeIntegrationTest is Test {
    UpgradeController public controller;
    VersionRegistry public registry;
    StorageCompatibilityValidator public validator;

    address public admin = address(0x1);
    address public target = address(0x100);
    address public impl1 = address(0x200);
    address public impl2 = address(0x300);

    function setUp() public {
        registry = new VersionRegistry(admin);
        validator = new StorageCompatibilityValidator();
        controller = new UpgradeController(admin, address(registry), address(validator));

        vm.startPrank(admin);
        controller.grantRole(controller.DEFAULT_ADMIN_ROLE(), address(this));
        registry.grantRole(registry.REGISTRY_ROLE(), address(this));
        controller.setCurrentImplementation(target, impl1);
        vm.stopPrank();
    }

    function test_FullUpgradeLifecycle() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            impl2,
            "2.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        controller.scheduleUpgrade(proposalId);
        vm.warp(block.timestamp + 7 days);
        controller.executeUpgrade(proposalId);

        assertEq(controller.currentImplementation(target), impl2);

        IUpgradeController.UpgradeProposal memory proposal = controller.getProposal(proposalId);
        assertEq(uint256(proposal.status), uint256(IUpgradeController.UpgradeStatus.EXECUTED));
        assertEq(proposal.newImplementation, impl2);
    }

    function test_VersionRegistry_Integration() public {
        registry.registerVersion(
            "TruthBounty",
            impl1,
            target,
            "1.0.0",
            bytes32(0),
            keccak256("v1")
        );

        bytes32 proposalId = controller.proposeUpgrade(
            target,
            impl2,
            "2.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        controller.scheduleUpgrade(proposalId);
        vm.warp(block.timestamp + 7 days);
        controller.executeUpgrade(proposalId);

        registry.registerVersion(
            "TruthBounty",
            impl2,
            target,
            "2.0.0",
            bytes32(0),
            keccak256("v2")
        );

        IVersionRegistry.VersionEntry memory entry = registry.getLatestVersion("TruthBounty");
        assertEq(entry.semanticVersion, "2.0.0");
        assertEq(entry.implementation, impl2);
    }

    function test_ProposeScheduleExecuteCancel_Flow() public {
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            impl2,
            "2.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        controller.cancelUpgrade(proposalId);

        IUpgradeController.UpgradeProposal memory proposal = controller.getProposal(proposalId);
        assertEq(uint256(proposal.status), uint256(IUpgradeController.UpgradeStatus.CANCELLED));
    }

    function test_MultipleUpgrades_SameContract() public {
        bytes32 p1 = controller.proposeUpgrade(
            target,
            impl2,
            "2.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );
        controller.scheduleUpgrade(p1);
        vm.warp(block.timestamp + 7 days);
        controller.executeUpgrade(p1);

        address impl3 = address(0x400);
        bytes32 p2 = controller.proposeUpgrade(
            target,
            impl3,
            "3.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );
        controller.scheduleUpgrade(p2);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        controller.executeUpgrade(p2);

        assertEq(controller.currentImplementation(target), impl3);

        bytes32[] memory history = controller.getUpgradeHistory(target);
        assertEq(history.length, 2);
    }

    function test_StorageValidator_CompatibleUpgrade() public {
        validator.registerLayout(impl1, 52, 50, keccak256("v1"));
        validator.registerLayout(impl2, 55, 50, keccak256("v2"));

        bytes32 proposalId = controller.proposeUpgrade(
            target,
            impl2,
            "2.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        controller.scheduleUpgrade(proposalId);
        vm.warp(block.timestamp + 7 days);
        controller.executeUpgrade(proposalId);

        assertEq(controller.currentImplementation(target), impl2);
    }

    function test_StorageValidator_IncompatibleUpgrade_Reverts() public {
        validator.registerLayout(impl1, 55, 50, keccak256("v1"));
        validator.registerLayout(impl2, 50, 50, keccak256("v2"));

        bytes32 proposalId = controller.proposeUpgrade(
            target,
            impl2,
            "2.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        controller.scheduleUpgrade(proposalId);
        vm.warp(block.timestamp + 7 days);

        vm.expectRevert(abi.encodeWithSelector(StorageCompatibilityValidator.IncompatibleStorageLayout.selector, "New implementation has fewer storage slots"));
        controller.executeUpgrade(proposalId);
    }

    function test_ValidateStorageCompatibility() public {
        validator.registerLayout(impl1, 52, 50, keccak256("v1"));
        validator.registerLayout(impl2, 55, 50, keccak256("v2"));

        StorageCompatibilityValidator.CompatibilityReport memory report =
            validator.validateStorageCompatibility(impl1, impl2);

        assertTrue(report.compatible);
        assertEq(report.currentSlotCount, 52);
        assertEq(report.newSlotCount, 55);
    }

    function test_IncompatibleStorage_ReturnsFalse() public {
        validator.registerLayout(impl1, 60, 50, keccak256("v1"));
        validator.registerLayout(impl2, 50, 50, keccak256("v2"));

        StorageCompatibilityValidator.CompatibilityReport memory report =
            validator.validateStorageCompatibility(impl1, impl2);

        assertFalse(report.compatible);
    }

    function test_RollbackUpgrade_FullLifecycle() public {
        bytes32 p1 = controller.proposeUpgrade(
            target,
            impl2,
            "2.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );
        controller.scheduleUpgrade(p1);
        vm.warp(block.timestamp + 7 days);
        controller.executeUpgrade(p1);

        assertEq(controller.currentImplementation(target), impl2);

        bytes32 rollbackProposal = controller.proposeUpgrade(
            target,
            impl1,
            "2.0.0-rollback",
            IUpgradeController.UpgradeType.ROLLBACK,
            bytes32(0)
        );
        controller.scheduleUpgrade(rollbackProposal);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        controller.executeUpgrade(rollbackProposal);

        assertEq(controller.currentImplementation(target), impl1);

        bytes32[] memory history = controller.getUpgradeHistory(target);
        assertEq(history.length, 2);
    }

    function test_EmergencyUpgrade_ShorterDelay() public {
        vm.prank(admin);
        bytes32 proposalId = controller.proposeUpgrade(
            target,
            impl2,
            "2.0.0-emergency",
            IUpgradeController.UpgradeType.EMERGENCY,
            bytes32(0)
        );

        controller.scheduleUpgrade(proposalId);

        vm.warp(block.timestamp + 24 hours);

        controller.executeUpgrade(proposalId);
        assertEq(controller.currentImplementation(target), impl2);
    }

    function test_GetPendingUpgrades_Filtering() public {
        bytes32 p1 = controller.proposeUpgrade(
            target,
            impl2,
            "2.0.0",
            IUpgradeController.UpgradeType.STANDARD,
            bytes32(0)
        );

        bytes32[] memory pendingBefore = controller.getPendingUpgrades(target);
        assertEq(pendingBefore.length, 0);

        controller.scheduleUpgrade(p1);

        bytes32[] memory pendingAfter = controller.getPendingUpgrades(target);
        assertEq(pendingAfter.length, 1);
    }
}
