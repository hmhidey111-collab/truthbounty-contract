// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../../contracts/governance/GovernanceOwnable.sol";
import "../upgrade/UpgradeInitializerHarness.sol";

/**
 * @title UpgradeInitializerFuzzTest
 * @notice V2-SC-122 — fuzzed initializer/reinitializer guarantees for ProtocolUpgradeable.
 *
 * The deterministic suite pins specific versions; this one walks the whole version
 * space and the whole failure space:
 *  1. `reinitializeAt` succeeds for exactly the versions above the current one, and
 *     reverts for every version at or below it.
 *  2. `initializeHarness` can never run a second time, for any caller or value.
 *  3. A reverting initializer body leaves no partial state, for any arguments.
 *  4. The unguarded internal initializer reverts from any caller.
 */
contract UpgradeInitializerFuzzTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant GOVERNANCE = address(0x6006);
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
                        UpgradeInitializerHarness.initializeHarness, (ADMIN, address(0), GOVERNANCE, INITIAL_VALUE)
                    )
                )
            )
        );
    }

    function testFuzz_ReinitializerAcceptsExactlyIncreasingVersions(uint64 version, uint256 newValue) public {
        version = uint64(bound(uint256(version), 1, 4096));
        uint64 floor = proxied.initializedVersion();
        assertEq(floor, 1);

        if (version > floor) {
            vm.prank(ADMIN);
            proxied.reinitializeAt(version, newValue);

            assertEq(proxied.initializedVersion(), version);
            assertEq(proxied.value(), newValue);
        } else {
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            vm.prank(ADMIN);
            proxied.reinitializeAt(version, newValue);

            assertEq(proxied.initializedVersion(), floor, "rejected version must not be consumed");
            assertEq(proxied.value(), INITIAL_VALUE, "rejected version must not write state");
        }
    }

    function testFuzz_InitializeNeverRunsTwice(address newAdmin, uint256 newValue) public {
        vm.assume(newAdmin != address(0));
        vm.assume(newAdmin != ADMIN);
        vm.assume(newAdmin != GOVERNANCE);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        proxied.initializeHarness(newAdmin, address(0), address(0), newValue);

        assertEq(proxied.initializedVersion(), 1);
        assertEq(proxied.value(), INITIAL_VALUE);
        assertEq(proxied.governanceController(), GOVERNANCE);
        assertFalse(proxied.hasRole(proxied.DEFAULT_ADMIN_ROLE(), newAdmin));
    }

    function testFuzz_FailedInitializeLeavesNoPartialState(address upgradeController, address governanceController)
        public
    {
        UpgradeInitializerHarness fresh =
            UpgradeInitializerHarness(address(new UninitializedUpgradeProxy(address(implementation))));

        vm.expectRevert(GovernanceOwnable.ZeroAddress.selector);
        fresh.initializeHarness(address(0), upgradeController, governanceController, 1234);

        assertEq(fresh.initializedVersion(), 0, "version must not be consumed by a failed init");
        assertEq(fresh.value(), 0);
        assertEq(address(fresh.upgradeController()), address(0));
        assertEq(fresh.governanceController(), address(0));
        assertEq(fresh.emergencyAdmin(), address(0));
    }

    function testFuzz_UnguardedSetupRevertsForAnyCaller(address caller) public {
        vm.assume(caller != address(0));

        UpgradeInitializerHarness fresh =
            UpgradeInitializerHarness(address(new UninitializedUpgradeProxy(address(implementation))));

        vm.expectRevert(Initializable.NotInitializing.selector);
        vm.prank(caller);
        fresh.initializeUnguarded(caller);

        assertEq(fresh.initializedVersion(), 0);
        assertFalse(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), caller));
    }
}
