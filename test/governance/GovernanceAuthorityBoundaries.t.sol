// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GovernanceAuthorityBoundaries} from "../../contracts/governance/v2/GovernanceAuthorityBoundaries.sol";
import {IGovernanceAuthorityBoundaries} from "../../contracts/governance/v2/IGovernanceAuthorityBoundaries.sol";
import {GovernanceAuthorityMatrix} from "../../contracts/governance/v2/libraries/GovernanceAuthorityMatrix.sol";

contract GovernanceAuthorityBoundariesTest is Test {
    GovernanceAuthorityBoundaries internal boundaries;

    address internal admin = makeAddr("authorityAdmin");
    address internal governor = makeAddr("governor");
    address internal timelock = makeAddr("timelock");
    address internal guardian = makeAddr("guardian");
    address internal registry = makeAddr("registry");
    address internal configuration = makeAddr("configuration");
    address internal treasury = makeAddr("treasury");
    address internal operations = makeAddr("operations");

    function setUp() public {
        boundaries = new GovernanceAuthorityBoundaries(admin);
    }

    function _bind(IGovernanceAuthorityBoundaries.AuthorityRole role, address account) internal {
        vm.prank(admin);
        boundaries.bindAuthority(role, account);
    }

    // ---------------------------------------------------------------------
    // Binding / overlap rejection
    // ---------------------------------------------------------------------

    function test_BindAllCanonicalAuthorities() public {
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR, governor);
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.TIMELOCK, timelock);
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN, guardian);
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.REGISTRY, registry);
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.CONFIGURATION, configuration);
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY, treasury);
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.OPERATIONS, operations);

        assertEq(boundaries.authorityOf(IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR), governor);
        assertEq(boundaries.authorityOf(IGovernanceAuthorityBoundaries.AuthorityRole.TIMELOCK), timelock);
        assertEq(boundaries.authorityOf(IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN), guardian);
        assertEq(boundaries.authorityOf(IGovernanceAuthorityBoundaries.AuthorityRole.REGISTRY), registry);
        assertEq(boundaries.authorityOf(IGovernanceAuthorityBoundaries.AuthorityRole.CONFIGURATION), configuration);
        assertEq(boundaries.authorityOf(IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY), treasury);
        assertEq(boundaries.authorityOf(IGovernanceAuthorityBoundaries.AuthorityRole.OPERATIONS), operations);
    }

    function test_BindRejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IGovernanceAuthorityBoundaries.ZeroAuthorityAddress.selector);
        boundaries.bindAuthority(IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR, address(0));
    }

    function test_BindRejectsDuplicateRole() public {
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR, governor);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceAuthorityBoundaries.AuthorityAlreadyBound.selector,
                IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR,
                governor
            )
        );
        boundaries.bindAuthority(IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR, operations);
    }

    function test_BindRejectsOverlappingAuthority() public {
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR, governor);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceAuthorityBoundaries.OverlappingAuthority.selector,
                governor,
                IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR,
                IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY
            )
        );
        boundaries.bindAuthority(IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY, governor);
    }

    function test_BindRequiresAuthorityAdmin() public {
        vm.prank(operations);
        vm.expectRevert();
        boundaries.bindAuthority(IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR, governor);
    }

    function test_RevokeAuthorityClearsBinding() public {
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN, guardian);
        assertTrue(boundaries.isAuthorityBound(IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN));

        vm.prank(admin);
        boundaries.revokeAuthority(IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN);

        assertFalse(boundaries.isAuthorityBound(IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN));
        assertEq(boundaries.authorityOf(IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN), address(0));

        (IGovernanceAuthorityBoundaries.AuthorityRole role, bool bound) = boundaries.boundRoleOf(guardian);
        assertFalse(bound);
        assertEq(uint256(role), uint256(IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR));
    }

    function test_RevokeUnboundAuthorityReverts() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceAuthorityBoundaries.AuthorityNotBound.selector,
                IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY
            )
        );
        boundaries.revokeAuthority(IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY);
    }

    function test_RevokeRequiresAuthorityAdmin() public {
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN, guardian);

        vm.prank(operations);
        vm.expectRevert();
        boundaries.revokeAuthority(IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN);
    }

    function test_RevokedAccountCanBeRebound() public {
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.OPERATIONS, operations);
        vm.prank(admin);
        boundaries.revokeAuthority(IGovernanceAuthorityBoundaries.AuthorityRole.OPERATIONS);

        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY, operations);
        assertEq(boundaries.authorityOf(IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY), operations);
    }

    // ---------------------------------------------------------------------
    // Capability matrix
    // ---------------------------------------------------------------------

    function test_GovernorCapabilityMatrix() public {
        assertTrue(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR,
                IGovernanceAuthorityBoundaries.Capability.PROPOSE_PROPOSAL
            )
        );
        assertTrue(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR,
                IGovernanceAuthorityBoundaries.Capability.QUEUE_PROPOSAL
            )
        );
        assertTrue(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR,
                IGovernanceAuthorityBoundaries.Capability.CANCEL_PROPOSAL
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR,
                IGovernanceAuthorityBoundaries.Capability.EXECUTE_PROPOSAL
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR,
                IGovernanceAuthorityBoundaries.Capability.RELEASE_TREASURY_FUNDS
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR,
                IGovernanceAuthorityBoundaries.Capability.PAUSE_PROTOCOL
            )
        );
    }

    function test_TimelockCapabilityMatrix() public {
        assertTrue(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.TIMELOCK,
                IGovernanceAuthorityBoundaries.Capability.EXECUTE_PROPOSAL
            )
        );
        assertTrue(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.TIMELOCK,
                IGovernanceAuthorityBoundaries.Capability.SET_TIMELOCK_ROLES
            )
        );
        assertTrue(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.TIMELOCK,
                IGovernanceAuthorityBoundaries.Capability.UPGRADE_IMPLEMENTATION
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.TIMELOCK,
                IGovernanceAuthorityBoundaries.Capability.PROPOSE_PROPOSAL
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.TIMELOCK,
                IGovernanceAuthorityBoundaries.Capability.CANCEL_PROPOSAL
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.TIMELOCK,
                IGovernanceAuthorityBoundaries.Capability.RELEASE_TREASURY_FUNDS
            )
        );
    }

    function test_GuardianCapabilityMatrix() public {
        assertTrue(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN,
                IGovernanceAuthorityBoundaries.Capability.CANCEL_PROPOSAL
            )
        );
        assertTrue(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN,
                IGovernanceAuthorityBoundaries.Capability.PAUSE_PROTOCOL
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN,
                IGovernanceAuthorityBoundaries.Capability.PROPOSE_PROPOSAL
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN,
                IGovernanceAuthorityBoundaries.Capability.EXECUTE_PROPOSAL
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN,
                IGovernanceAuthorityBoundaries.Capability.RELEASE_TREASURY_FUNDS
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN,
                IGovernanceAuthorityBoundaries.Capability.REGISTER_GOVERNED_MODULE
            )
        );
    }

    function test_RegistryCapabilityMatrix() public {
        assertTrue(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.REGISTRY,
                IGovernanceAuthorityBoundaries.Capability.REGISTER_GOVERNED_MODULE
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.REGISTRY,
                IGovernanceAuthorityBoundaries.Capability.SET_PROTOCOL_PARAMETER
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.REGISTRY,
                IGovernanceAuthorityBoundaries.Capability.RELEASE_TREASURY_FUNDS
            )
        );
    }

    function test_ConfigurationCapabilityMatrix() public {
        assertTrue(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.CONFIGURATION,
                IGovernanceAuthorityBoundaries.Capability.SET_PROTOCOL_PARAMETER
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.CONFIGURATION,
                IGovernanceAuthorityBoundaries.Capability.REGISTER_GOVERNED_MODULE
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.CONFIGURATION,
                IGovernanceAuthorityBoundaries.Capability.RELEASE_TREASURY_FUNDS
            )
        );
    }

    function test_TreasuryCapabilityMatrix() public {
        assertTrue(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY,
                IGovernanceAuthorityBoundaries.Capability.RELEASE_TREASURY_FUNDS
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY,
                IGovernanceAuthorityBoundaries.Capability.REGISTER_GOVERNED_MODULE
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY,
                IGovernanceAuthorityBoundaries.Capability.SET_PROTOCOL_PARAMETER
            )
        );
    }

    function test_OperationsCapabilityMatrix() public {
        assertTrue(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.OPERATIONS,
                IGovernanceAuthorityBoundaries.Capability.ROTATE_OPERATIONAL_ROLE
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.OPERATIONS,
                IGovernanceAuthorityBoundaries.Capability.PROPOSE_PROPOSAL
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.OPERATIONS,
                IGovernanceAuthorityBoundaries.Capability.CANCEL_PROPOSAL
            )
        );
        assertFalse(
            boundaries.isCapabilityAllowed(
                IGovernanceAuthorityBoundaries.AuthorityRole.OPERATIONS,
                IGovernanceAuthorityBoundaries.Capability.PAUSE_PROTOCOL
            )
        );
    }

    function test_OnlyCancelProposalIsShared() public {
        uint256 shared;
        for (uint256 i = 0; i < GovernanceAuthorityMatrix.CAPABILITY_COUNT; ++i) {
            IGovernanceAuthorityBoundaries.Capability capability = IGovernanceAuthorityBoundaries.Capability(i);
            if (!boundaries.isCapabilityExclusive(capability)) {
                ++shared;
                assertEq(
                    uint256(capability),
                    uint256(IGovernanceAuthorityBoundaries.Capability.CANCEL_PROPOSAL)
                );
            }
        }
        assertEq(shared, 1);
    }

    function test_SoleRoleForExclusiveCapability() public {
        assertEq(
            uint256(
                boundaries.soleRoleForCapability(
                    IGovernanceAuthorityBoundaries.Capability.PROPOSE_PROPOSAL
                )
            ),
            uint256(IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR)
        );
        assertEq(
            uint256(
                boundaries.soleRoleForCapability(
                    IGovernanceAuthorityBoundaries.Capability.REGISTER_GOVERNED_MODULE
                )
            ),
            uint256(IGovernanceAuthorityBoundaries.AuthorityRole.REGISTRY)
        );
        assertEq(
            uint256(
                boundaries.soleRoleForCapability(IGovernanceAuthorityBoundaries.Capability.PAUSE_PROTOCOL)
            ),
            uint256(IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN)
        );
    }

    function test_SoleRoleForSharedCapabilityReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceAuthorityBoundaries.SharedCapability.selector,
                IGovernanceAuthorityBoundaries.Capability.CANCEL_PROPOSAL
            )
        );
        boundaries.soleRoleForCapability(IGovernanceAuthorityBoundaries.Capability.CANCEL_PROPOSAL);
    }

    function test_RolesForSharedCapabilityReturnsGovernorAndGuardian() public {
        IGovernanceAuthorityBoundaries.AuthorityRole[] memory roles =
            boundaries.rolesForCapability(IGovernanceAuthorityBoundaries.Capability.CANCEL_PROPOSAL);
        assertEq(roles.length, 2);
        assertEq(uint256(roles[0]), uint256(IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR));
        assertEq(uint256(roles[1]), uint256(IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN));
    }

    function test_RolesForExclusiveCapabilityReturnsSingleRole() public {
        IGovernanceAuthorityBoundaries.AuthorityRole[] memory roles =
            boundaries.rolesForCapability(IGovernanceAuthorityBoundaries.Capability.RELEASE_TREASURY_FUNDS);
        assertEq(roles.length, 1);
        assertEq(uint256(roles[0]), uint256(IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY));
    }

    function test_CapabilitiesOfGovernor() public {
        IGovernanceAuthorityBoundaries.Capability[] memory caps =
            boundaries.capabilitiesOf(IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR);
        assertEq(caps.length, 3);
        assertEq(uint256(caps[0]), uint256(IGovernanceAuthorityBoundaries.Capability.PROPOSE_PROPOSAL));
        assertEq(uint256(caps[1]), uint256(IGovernanceAuthorityBoundaries.Capability.QUEUE_PROPOSAL));
        assertEq(uint256(caps[2]), uint256(IGovernanceAuthorityBoundaries.Capability.CANCEL_PROPOSAL));
    }

    function test_CapabilitiesOfTreasury() public {
        IGovernanceAuthorityBoundaries.Capability[] memory caps =
            boundaries.capabilitiesOf(IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY);
        assertEq(caps.length, 1);
        assertEq(uint256(caps[0]), uint256(IGovernanceAuthorityBoundaries.Capability.RELEASE_TREASURY_FUNDS));
    }

    // ---------------------------------------------------------------------
    // Account-scoped authorization and fail-closed enforcement
    // ---------------------------------------------------------------------

    function test_IsAuthorizedForBoundAccount() public {
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.TIMELOCK, timelock);

        assertTrue(
            boundaries.isAuthorizedFor(
                timelock, IGovernanceAuthorityBoundaries.Capability.UPGRADE_IMPLEMENTATION
            )
        );
        assertFalse(
            boundaries.isAuthorizedFor(
                timelock, IGovernanceAuthorityBoundaries.Capability.PROPOSE_PROPOSAL
            )
        );
        assertFalse(
            boundaries.isAuthorizedFor(
                timelock, IGovernanceAuthorityBoundaries.Capability.RELEASE_TREASURY_FUNDS
            )
        );
    }

    function test_IsAuthorizedForUnboundAccountIsFalse() public {
        assertFalse(
            boundaries.isAuthorizedFor(treasury, IGovernanceAuthorityBoundaries.Capability.RELEASE_TREASURY_FUNDS)
        );
    }

    function test_RequireCapabilityPassesWhenGranted() public {
        boundaries.requireCapability(
            IGovernanceAuthorityBoundaries.AuthorityRole.CONFIGURATION,
            IGovernanceAuthorityBoundaries.Capability.SET_PROTOCOL_PARAMETER
        );
    }

    function test_RequireCapabilityRevertsWhenNotGranted() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceAuthorityBoundaries.CapabilityNotGranted.selector,
                IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN,
                IGovernanceAuthorityBoundaries.Capability.RELEASE_TREASURY_FUNDS
            )
        );
        boundaries.requireCapability(
            IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN,
            IGovernanceAuthorityBoundaries.Capability.RELEASE_TREASURY_FUNDS
        );
    }

    function test_PublishAuthorityMatrixEmitsCanonicalDimensions() public {
        vm.expectEmit(false, false, false, true);
        emit IGovernanceAuthorityBoundaries.GovernanceAuthorityMatrixPublished(address(this), 7, 11);
        boundaries.publishAuthorityMatrix();
    }

    // ---------------------------------------------------------------------
    // Invariants / completeness
    // ---------------------------------------------------------------------

    function test_CompletenessEveryCapabilityCovered() public {
        for (uint256 i = 0; i < GovernanceAuthorityMatrix.CAPABILITY_COUNT; ++i) {
            IGovernanceAuthorityBoundaries.Capability capability = IGovernanceAuthorityBoundaries.Capability(i);
            IGovernanceAuthorityBoundaries.AuthorityRole[] memory roles = boundaries.rolesForCapability(capability);
            assertGe(roles.length, 1);
            if (boundaries.isCapabilityExclusive(capability)) {
                assertEq(roles.length, 1);
            } else {
                assertEq(roles.length, 2);
            }
        }
    }

    function test_CompletenessEveryRoleHasCapabilities() public {
        for (uint256 i = 0; i < GovernanceAuthorityMatrix.ROLE_COUNT; ++i) {
            IGovernanceAuthorityBoundaries.AuthorityRole role = IGovernanceAuthorityBoundaries.AuthorityRole(i);
            IGovernanceAuthorityBoundaries.Capability[] memory caps = boundaries.capabilitiesOf(role);
            assertGt(caps.length, 0);
        }
    }

    function testFuzz_BindRejectsOverlappingAccount(address account, address second) public {
        vm.assume(account != address(0));
        vm.assume(second != address(0));
        vm.assume(second != account);

        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR, account);
        _bind(IGovernanceAuthorityBoundaries.AuthorityRole.TREASURY, second);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceAuthorityBoundaries.OverlappingAuthority.selector,
                account,
                IGovernanceAuthorityBoundaries.AuthorityRole.GOVERNOR,
                IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN
            )
        );
        boundaries.bindAuthority(IGovernanceAuthorityBoundaries.AuthorityRole.GUARDIAN, account);
    }

    function testFuzz_EveryRoleHasAtLeastOneCapability(uint8 roleSeed) public {
        IGovernanceAuthorityBoundaries.AuthorityRole role = IGovernanceAuthorityBoundaries.AuthorityRole(
            uint256(roleSeed) % GovernanceAuthorityMatrix.ROLE_COUNT
        );
        IGovernanceAuthorityBoundaries.Capability[] memory caps = boundaries.capabilitiesOf(role);
        assertGt(caps.length, 0);
    }

    function testFuzz_ExclusiveCapabilityHasSingleOwner(uint8 capabilitySeed) public {
        IGovernanceAuthorityBoundaries.Capability capability = IGovernanceAuthorityBoundaries.Capability(
            uint256(capabilitySeed) % GovernanceAuthorityMatrix.CAPABILITY_COUNT
        );
        IGovernanceAuthorityBoundaries.AuthorityRole[] memory roles = boundaries.rolesForCapability(capability);
        if (boundaries.isCapabilityExclusive(capability)) {
            assertEq(roles.length, 1);
            assertEq(
                uint256(boundaries.soleRoleForCapability(capability)),
                uint256(roles[0])
            );
        }
    }
}
