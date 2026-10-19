// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../../contracts/upgrade/ProtocolUpgradeable.sol";

/**
 * @title UUPS upgrade authorization (V2-SC-123)
 * @notice End-to-end validation that UUPS upgrades of a {ProtocolUpgradeable} proxy are
 *         gated on the canonical timelock-governed authority, that proxiable-UUID
 *         compatibility is enforced against the ERC-1967 implementation slot, and that
 *         direct (non-proxied) upgrade calls on the implementation fail.
 *
 * The suite drives the real OpenZeppelin UUPS path through an {ERC1967Proxy} plus a real
 * {TimelockController} rather than mocking the controller, so a regression anywhere in the
 * `_authorizeUpgrade -> proxiableUUID -> ERC1967Utils.upgradeToAndCall` chain fails a test.
 *
 * The UUPS revert selectors are built with `abi.encodeWithSignature` so the suite stays
 * agnostic to whether the upgradeable OpenZeppelin package re-exports the stateless
 * {UUPSUpgradeable} implementation or ships its own copy of it.
 */
contract UupsAuthHarness is ProtocolUpgradeable {
    uint256 public value;

    function initialize(
        address admin,
        address upgradeController,
        address governanceController,
        uint256 initialValue
    ) external initializer {
        _initializeProtocolUpgradeable(admin, upgradeController, governanceController);
        value = initialValue;
    }
}

/// @dev UUPS-shaped implementation whose `proxiableUUID` does not match the ERC-1967
///      implementation slot. The proxy must refuse it.
contract MismatchedProxiableUuidImplementation {
    bytes32 public constant WRONG_SLOT = keccak256("truthbounty.uups.wrong.proxiable.uuid");

    function proxiableUUID() external pure returns (bytes32) {
        return WRONG_SLOT;
    }
}

/// @dev Implementation that does not implement ERC-1822 at all. The proxy must refuse it
///      with {ERC1967Utils-ERC1967InvalidImplementation}.
contract NonUupsImplementation {
    uint256 public constant VERSION = 2;
}

contract UupsUpgradeAuthorizationTest is Test {
    address internal admin = address(0xA11CE);
    address internal governance = address(0x60);
    address internal stranger = address(0xBEEF);
    address internal rogueAdmin = address(0xBAD1);
    address internal controllerOnly = address(0xBAD2);

    TimelockController internal timelock;
    UupsAuthHarness internal implV1;
    UupsAuthHarness internal implV2;
    ERC1967Proxy internal proxy;
    UupsAuthHarness internal proxied;

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Mirrors `TimelockController._encodeStateBitmap(OperationState.Ready)`.
    ///      `OperationState` is `{Unset, Waiting, Ready, Done}`, so Ready is `1 << 2`.
    bytes32 internal constant TIMELOCK_READY_STATE_BITMAP = bytes32(uint256(1) << 2);

    /// @dev Reads the ERC-1967 implementation slot of the proxy. {ERC1967Utils.getImplementation}
    ///      is a no-argument library helper that reads `address(this)` storage, so it cannot be
    ///      used from the test contract to inspect the proxy.
    function _currentImplementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(proxy), ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _upgradeCall() internal view returns (bytes memory) {
        return abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(implV2), bytes(""));
    }

    function _operationId(bytes memory call) internal view returns (bytes32) {
        return timelock.hashOperation(address(proxy), 0, call, bytes32(0), bytes32(0));
    }

    function setUp() public {
        // Canonical, timelock-governed authority. The timelock is the sole proposer and the
        // executor role is left open so the delay, not the caller, is the gate.
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open executor role
        timelock = new TimelockController(2 days, proposers, executors, address(0));

        implV1 = new UupsAuthHarness();
        implV2 = new UupsAuthHarness();

        proxy = new ERC1967Proxy(
            address(implV1),
            abi.encodeCall(UupsAuthHarness.initialize, (admin, address(timelock), governance, uint256(7)))
        );
        proxied = UupsAuthHarness(address(proxy));

        // Grant the timelock both roles the UUPS authorization hook requires.
        vm.startPrank(admin);
        proxied.grantRole(proxied.UPGRADE_CONTROLLER_ROLE(), address(timelock));
        proxied.grantRole(proxied.DEFAULT_ADMIN_ROLE(), address(timelock));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Positive path
    // ---------------------------------------------------------------------

    /// The full governance flow: propose -> schedule -> wait exactly the min delay -> execute.
    function test_TimelockGovernedAuthorityUpgradesEndToEnd() public {
        bytes memory call = _upgradeCall();

        vm.prank(admin); // proposer role
        timelock.schedule(address(proxy), 0, call, bytes32(0), bytes32(0), timelock.getMinDelay());

        // Boundary: the operation becomes executable exactly at `scheduleTimestamp + minDelay`.
        vm.warp(block.timestamp + timelock.getMinDelay());
        timelock.execute(address(proxy), 0, call, bytes32(0), bytes32(0));

        assertEq(_currentImplementation(), address(implV2), "implementation not upgraded");
        assertEq(proxied.value(), 7, "storage not preserved across upgrade");
    }

    // ---------------------------------------------------------------------
    // Boundary + replay
    // ---------------------------------------------------------------------

    /// Executing before the timelock delay has elapsed is rejected as not-yet-ready.
    function test_UpgradeRejectedBeforeMinDelay() public {
        bytes memory call = _upgradeCall();
        bytes32 opId = _operationId(call);

        vm.prank(admin);
        timelock.schedule(address(proxy), 0, call, bytes32(0), bytes32(0), timelock.getMinDelay());

        vm.warp(block.timestamp + timelock.getMinDelay() - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                opId,
                TIMELOCK_READY_STATE_BITMAP
            )
        );
        timelock.execute(address(proxy), 0, call, bytes32(0), bytes32(0));

        assertEq(_currentImplementation(), address(implV1), "implementation changed before delay");
    }

    /// A scheduled upgrade cannot be executed twice.
    function test_TimelockOperationCannotBeReplayed() public {
        bytes memory call = _upgradeCall();
        bytes32 opId = _operationId(call);

        vm.prank(admin);
        timelock.schedule(address(proxy), 0, call, bytes32(0), bytes32(0), timelock.getMinDelay());

        vm.warp(block.timestamp + timelock.getMinDelay());
        timelock.execute(address(proxy), 0, call, bytes32(0), bytes32(0));
        assertEq(_currentImplementation(), address(implV2), "first execution did not upgrade");
        assertTrue(timelock.isOperationDone(opId), "operation not marked done");

        // The same operation id is already Done, so it can never be replayed.
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                opId,
                TIMELOCK_READY_STATE_BITMAP
            )
        );
        timelock.execute(address(proxy), 0, call, bytes32(0), bytes32(0));

        assertEq(_currentImplementation(), address(implV2), "replay altered the implementation");
    }

    // ---------------------------------------------------------------------
    // Authorization
    // ---------------------------------------------------------------------

    /// A caller with neither role is rejected by the DEFAULT_ADMIN_ROLE guard.
    function test_StrangerCannotUpgrade() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                bytes32(0)
            )
        );
        proxied.upgradeToAndCall(address(implV2), "");

        assertEq(_currentImplementation(), address(implV1), "implementation changed");
    }

    /// Holding the admin role without the upgrade-controller role is not enough.
    function test_AdminWithoutControllerRoleCannotUpgrade() public {
        vm.prank(admin);
        proxied.grantRole(proxied.DEFAULT_ADMIN_ROLE(), rogueAdmin);

        vm.prank(rogueAdmin);
        vm.expectRevert(ProtocolUpgradeable.UpgradeNotAuthorized.selector);
        proxied.upgradeToAndCall(address(implV2), "");

        assertEq(_currentImplementation(), address(implV1), "implementation changed");
    }

    /// Holding the upgrade-controller role without the admin role is not enough.
    function test_ControllerRoleWithoutAdminRoleCannotUpgrade() public {
        vm.prank(admin);
        proxied.grantRole(proxied.UPGRADE_CONTROLLER_ROLE(), controllerOnly);

        vm.prank(controllerOnly);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                controllerOnly,
                bytes32(0)
            )
        );
        proxied.upgradeToAndCall(address(implV2), "");

        assertEq(_currentImplementation(), address(implV1), "implementation changed");
    }

    /// Fuzz: no caller outside the privileged set can move the implementation.
    function testFuzz_UnprivilegedCallerCannotUpgrade(address caller) public {
        vm.assume(caller != admin && caller != address(timelock));

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                caller,
                bytes32(0)
            )
        );
        proxied.upgradeToAndCall(address(implV2), "");

        assertEq(_currentImplementation(), address(implV1), "implementation changed");
    }

    /// Fuzz: every wait strictly shorter than the min delay leaves the implementation intact.
    function testFuzz_UpgradeBlockedBeforeMinDelay(uint256 waitSeconds) public {
        uint256 minDelay = timelock.getMinDelay();
        waitSeconds = bound(waitSeconds, 0, minDelay - 1);

        bytes memory call = _upgradeCall();
        bytes32 opId = _operationId(call);

        vm.prank(admin);
        timelock.schedule(address(proxy), 0, call, bytes32(0), bytes32(0), minDelay);

        vm.warp(block.timestamp + waitSeconds);

        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                opId,
                TIMELOCK_READY_STATE_BITMAP
            )
        );
        timelock.execute(address(proxy), 0, call, bytes32(0), bytes32(0));

        assertEq(_currentImplementation(), address(implV1), "implementation changed before delay");
    }

    // ---------------------------------------------------------------------
    // Implementation compatibility
    // ---------------------------------------------------------------------

    /// An implementation that reports a non-ERC-1967 proxiable UUID is rejected.
    function test_IncompatibleProxiableUuidRejected() public {
        MismatchedProxiableUuidImplementation wrongUuid = new MismatchedProxiableUuidImplementation();

        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSignature("UUPSUnsupportedProxiableUUID(bytes32)", wrongUuid.proxiableUUID())
        );
        proxied.upgradeToAndCall(address(wrongUuid), "");

        assertEq(_currentImplementation(), address(implV1), "implementation changed");
    }

    /// An implementation that is not UUPS at all is rejected.
    function test_NonUupsImplementationRejected() public {
        NonUupsImplementation notUups = new NonUupsImplementation();

        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSignature("ERC1967InvalidImplementation(address)", address(notUups))
        );
        proxied.upgradeToAndCall(address(notUups), "");

        assertEq(_currentImplementation(), address(implV1), "implementation changed");
    }

    /// Calling `upgradeToAndCall` on the implementation directly must fail; only the proxy
    /// (delegatecall context) may upgrade.
    function test_DirectImplementationUpgradeRejected() public {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSignature("UUPSUnauthorizedCallContext()"));
        implV1.upgradeToAndCall(address(implV2), "");

        assertEq(_currentImplementation(), address(implV1), "proxy touched by direct call");
    }
}
