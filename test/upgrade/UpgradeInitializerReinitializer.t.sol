// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../../contracts/governance/GovernanceOwnable.sol";
import "./UpgradeInitializerHarness.sol";

/**
 * @title UpgradeInitializerReinitializerTest
 * @notice V2-SC-122 — initializer and reinitializer behavior for ProtocolUpgradeable.
 *
 * Verified here:
 *  1. Implementation contracts can be neither initialized nor reinitialized directly.
 *  2. Proxy initialization is atomic and single-shot: a body that reverts leaves no
 *     partial state (including no consumed version), and the next call can succeed.
 *  3. Reinitializers are version-safe: only strictly increasing versions apply, and
 *     replays or out-of-order calls revert without changing state.
 *  4. A caller that fails the role check does not consume the version it attempted.
 */
contract UpgradeInitializerReinitializerTest is Test {
    /// @dev Mirrors {Initializable-Initialized} so the emitted version can be asserted.
    event Initialized(uint64 version);

    address internal constant ADMIN = address(0xA11CE);
    address internal constant GOVERNANCE = address(0x6006);
    address internal constant UPGRADE_CONTROLLER = address(0xC0FFEE);
    address internal constant ATTACKER = address(0xBAD);

    uint256 internal constant INITIAL_VALUE = 7;

    UpgradeInitializerHarness internal implementation;
    UpgradeInitializerHarness internal proxied;

    function setUp() public {
        implementation = new UpgradeInitializerHarness();
        proxied = UpgradeInitializerHarness(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        UpgradeInitializerHarness.initializeHarness,
                        (ADMIN, UPGRADE_CONTROLLER, GOVERNANCE, INITIAL_VALUE)
                    )
                )
            )
        );
    }

    // ── Implementations cannot be initialized directly ────────────────────────

    function test_ImplementationIsLockedAgainstInitializeAndReinitialize() public {
        assertEq(
            implementation.initializedVersion(),
            type(uint64).max,
            "implementation must be locked by _disableInitializers"
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initializeHarness(ATTACKER, address(0), address(0), 1);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.reinitializeAt(2, 1);

        assertEq(implementation.initializedVersion(), type(uint64).max);
    }

    // ── Proxy initialization is atomic and single-shot ────────────────────────

    function test_ProxyInitializesOnceWithExpectedState() public {
        assertEq(proxied.initializedVersion(), 1);
        assertEq(proxied.value(), INITIAL_VALUE);
        assertEq(address(proxied.upgradeController()), UPGRADE_CONTROLLER);
        assertEq(proxied.governanceController(), GOVERNANCE);
        assertEq(proxied.emergencyAdmin(), ADMIN);
        assertTrue(proxied.hasRole(proxied.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertTrue(proxied.hasRole(proxied.GOVERNANCE_ADMIN_ROLE(), ADMIN));
        assertTrue(proxied.hasRole(proxied.RECOVERY_ROLE(), ADMIN));
        assertTrue(proxied.hasRole(proxied.GOVERNANCE_ROLE(), GOVERNANCE));
        assertFalse(proxied.hasRole(proxied.DEFAULT_ADMIN_ROLE(), ATTACKER));
    }

    function test_SecondInitializeCallRevertsAndChangesNothing() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        proxied.initializeHarness(ATTACKER, address(0), address(0), 99);

        assertEq(proxied.initializedVersion(), 1);
        assertEq(proxied.value(), INITIAL_VALUE);
        assertFalse(proxied.hasRole(proxied.DEFAULT_ADMIN_ROLE(), ATTACKER));
    }

    function test_UnguardedSetupRevertsWithNotInitializing() public {
        UpgradeInitializerHarness fresh =
            UpgradeInitializerHarness(address(new UninitializedUpgradeProxy(address(implementation))));
        assertEq(fresh.initializedVersion(), 0, "proxy must start uninitialized");

        vm.expectRevert(Initializable.NotInitializing.selector);
        vm.prank(ATTACKER);
        fresh.initializeUnguarded(ATTACKER);

        assertEq(fresh.initializedVersion(), 0);
        assertEq(fresh.governanceController(), address(0));
        assertFalse(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), ATTACKER));
    }

    function test_FailedInitializeIsAtomicAndRetryable() public {
        UpgradeInitializerHarness fresh =
            UpgradeInitializerHarness(address(new UninitializedUpgradeProxy(address(implementation))));

        // Zero admin fails inside the initializer body, after `initializer` has already
        // written version 1 — the revert has to roll that write back too.
        vm.expectRevert(GovernanceOwnable.ZeroAddress.selector);
        fresh.initializeHarness(address(0), UPGRADE_CONTROLLER, GOVERNANCE, 42);

        assertEq(fresh.initializedVersion(), 0, "failed init must leave the proxy uninitialized");
        assertEq(fresh.value(), 0);
        assertEq(address(fresh.upgradeController()), address(0));
        assertEq(fresh.governanceController(), address(0));
        assertEq(fresh.emergencyAdmin(), address(0));

        fresh.initializeHarness(ADMIN, UPGRADE_CONTROLLER, GOVERNANCE, 42);
        assertEq(fresh.initializedVersion(), 1);
        assertEq(fresh.value(), 42);
        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), ADMIN));
    }

    // ── Reinitializers are version-safe ───────────────────────────────────────

    function test_ReinitializerAcceptsOnlyStrictlyIncreasingVersions() public {
        vm.prank(ADMIN);
        proxied.reinitializeAt(2, 11);
        assertEq(proxied.initializedVersion(), 2);
        assertEq(proxied.value(), 11);

        vm.prank(ADMIN);
        proxied.reinitializeAt(3, 12);
        assertEq(proxied.initializedVersion(), 3);
        assertEq(proxied.value(), 12);

        // Replaying or going backwards reverts and leaves state alone.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(ADMIN);
        proxied.reinitializeAt(3, 13);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(ADMIN);
        proxied.reinitializeAt(2, 13);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(ADMIN);
        proxied.reinitializeAt(1, 13);

        assertEq(proxied.initializedVersion(), 3);
        assertEq(proxied.value(), 12);
    }

    function test_ReinitializerAtZeroIsRejected() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(ADMIN);
        proxied.reinitializeAt(0, 5);

        assertEq(proxied.initializedVersion(), 1);
        assertEq(proxied.value(), INITIAL_VALUE);
    }

    function test_ReinitializerFloorIsTheHighestVersionApplied() public {
        // A version is consumed once, and the floor is the highest version applied —
        // not the last one called.
        vm.prank(ADMIN);
        proxied.reinitializeAt(5, 50);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(ADMIN);
        proxied.reinitializeAt(2, 2);

        vm.prank(ADMIN);
        proxied.reinitializeAt(6, 60);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(ADMIN);
        proxied.reinitializeAt(5, 55);

        assertEq(proxied.initializedVersion(), 6);
        assertEq(proxied.value(), 60);
    }

    function test_ReinitializerAtMaxVersionLocksFurtherReinitialization() public {
        vm.prank(ADMIN);
        proxied.reinitializeAt(type(uint64).max, 77);
        assertEq(proxied.initializedVersion(), type(uint64).max);
        assertEq(proxied.value(), 77);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(ADMIN);
        proxied.reinitializeAt(type(uint64).max, 78);
    }

    function test_UnauthorizedReinitializerDoesNotConsumeTheVersion() public {
        // The attacker clears the version guard but fails the role check, so the whole
        // call rolls back and version 2 stays available to the admin.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, ATTACKER, proxied.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(ATTACKER);
        proxied.reinitializeAt(2, 99);

        assertEq(proxied.initializedVersion(), 1, "failed reinit must not consume version 2");
        assertEq(proxied.value(), INITIAL_VALUE);

        vm.prank(ADMIN);
        proxied.reinitializeAt(2, 99);
        assertEq(proxied.initializedVersion(), 2);
        assertEq(proxied.value(), 99);
    }

    function test_ReinitializationEmitsTheAppliedVersion() public {
        vm.expectEmit(false, false, false, true);
        emit Initialized(2);
        vm.prank(ADMIN);
        proxied.reinitializeAt(2, 11);

        assertEq(proxied.initializedVersion(), 2);
    }
}
