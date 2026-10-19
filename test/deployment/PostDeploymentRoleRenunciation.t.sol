// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {PostDeploymentRoleCheck} from "../../contracts/deployment/PostDeploymentRoleCheck.sol";
import {GovernedModuleRegistry} from "../../contracts/governance/v2/GovernedModuleRegistry.sol";
import {TruthBountyGovernanceToken} from "../../contracts/governance/v2/TruthBountyGovernanceToken.sol";
import {TruthBountyGovernor} from "../../contracts/governance/v2/TruthBountyGovernor.sol";
import {IGovernanceSnapshot} from "../../contracts/governance/v2/IGovernanceSnapshot.sol";
import {GovernanceGuardian} from "../../contracts/governance/v2/GovernanceGuardian.sol";
import {ITruthBountyGovernor} from "../../contracts/governance/v2/ITruthBountyGovernor.sol";
import {GovernanceRoleTopology} from "../../contracts/governance/v2/GovernanceRoleTopology.sol";

/**
 * @title PostDeploymentRoleCheckHarness
 * @dev External wrapper around the internal `PostDeploymentRoleCheck` library calls.
 *      `vm.expectRevert` can only observe a revert raised by a call made from a lower call
 *      depth, so an internal library call (inlined into the test) cannot be asserted with it.
 */
contract PostDeploymentRoleCheckHarness {
    function assertNoRolesRetained(address account, address[] memory targets) external {
        PostDeploymentRoleCheck.assertNoRolesRetained(account, targets);
    }
}

/**
 * @title PostDeploymentRoleRenunciationTest
 * @notice Foundry test suite for V2-SC-127 — Automate Post-Deployment Role Renunciation Checks.
 * @dev Deploys the full V2 governance suite, wires roles, performs handoff, and verifies
 *      that the deployer retains absolutely zero protocol roles afterward.
 *
 *      Test categories:
 *        - Positive: after correct handoff, deployer has no roles
 *        - Negative: before handoff, deployer correctly holds bootstrap roles
 *        - Boundary: partial renunciation leaves violations
 *        - Authorization: deployer cannot re-acquire roles after handoff
 *        - Replay: repeated checks produce identical results
 *        - Failure-path: skipping renunciation steps is detected
 */
contract PostDeploymentRoleRenunciationTest is Test {
    // ── Actors ───────────────────────────────────────────────────────────
    address deployer = address(0xD1);
    address guardian = address(0xA1);
    address otherUser = address(0xB1);

    // ── Deployed contracts ───────────────────────────────────────────────
    GovernedModuleRegistry registry;
    TruthBountyGovernanceToken govToken;
    TimelockController timelock;
    TruthBountyGovernor governor;
    GovernanceGuardian guardianContract;

    // ── Role constants ───────────────────────────────────────────────────
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");
    bytes32 constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    bytes32 constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    function setUp() public {
        vm.startPrank(deployer);

        // 1. GovernedModuleRegistry — deployer gets DEFAULT_ADMIN_ROLE + REGISTRY_ADMIN_ROLE
        registry = new GovernedModuleRegistry(deployer);

        // 2. Governance token — no AccessControl roles, just ERC20
        govToken = new TruthBountyGovernanceToken(deployer, 1_000_000_000 ether);

        // 3. TimelockController — deployer gets DEFAULT_ADMIN_ROLE initially (OZ >= 5.0)
        address[] memory empty = new address[](0);
        timelock = new TimelockController(2 days, empty, empty, deployer);

        // 4. Governor — no direct roles to deployer
        governor = new TruthBountyGovernor(
            IVotes(address(govToken)),
            timelock,
            registry,
            IGovernanceSnapshot(address(0)),
            guardian,
            uint48(1 days),
            uint32(3 days),
            100_000 ether,
            4
        );

        // 5. GovernanceGuardian — deployer gets DEFAULT_ADMIN_ROLE
        guardianContract = new GovernanceGuardian(deployer, guardian, ITruthBountyGovernor(address(governor)));

        vm.stopPrank();

        // Guardian wires the guardian module
        vm.prank(guardian);
        governor.setGovernanceGuardianModule(address(guardianContract));
    }

    // ════════════════════════════════════════════════════════════════════
    //  Helper: build targets array
    // ════════════════════════════════════════════════════════════════════

    function _targets() internal view returns (address[] memory t) {
        t = new address[](4);
        t[0] = address(registry);
        t[1] = address(timelock);
        t[2] = address(guardianContract);
        t[3] = address(govToken); // not AccessControl, should be handled gracefully
    }

    function _performFullHandoff() internal {
        vm.startPrank(deployer);

        // Wire governance topology roles
        GovernanceRoleTopology.configure(timelock, governor, guardian, 2 days);
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);

        // Transfer registry admin to timelock (grant lives on the registry, not the timelock;
        // after finalization the deployer no longer holds timelock administration).
        registry.grantRole(REGISTRY_ADMIN_ROLE, address(timelock));

        // Renounce deployer roles on GovernedModuleRegistry
        registry.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        registry.renounceRole(REGISTRY_ADMIN_ROLE, deployer);

        // Renounce deployer roles on GovernanceGuardian
        guardianContract.renounceRole(DEFAULT_ADMIN_ROLE, deployer);

        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════════
    //  POSITIVE TESTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice After complete handoff, deployer retains zero roles.
    function test_FullHandoff_DeployerRetainsNoRoles() public {
        _performFullHandoff();

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());

        assertEq(violations.length, 0, "deployer retains roles after full handoff");
    }

    /// @notice assertNoRolesRetained succeeds after correct handoff.
    function test_AssertNoRolesRetained_PassesAfterHandoff() public {
        _performFullHandoff();

        // Should not revert
        PostDeploymentRoleCheck.assertNoRolesRetained(deployer, _targets());
    }

    /// @notice RoleRenunciationCheckPassed event is emitted on success.
    function test_CheckPassed_EventEmitted() public {
        _performFullHandoff();

        vm.expectEmit(true, false, false, true);
        emit PostDeploymentRoleCheck.RoleRenunciationCheckPassed(
            deployer,
            _targets().length,
            PostDeploymentRoleCheck.ROLE_CATALOG_SIZE
        );
        PostDeploymentRoleCheck.assertNoRolesRetained(deployer, _targets());
    }

    /// @notice Governor and timelock correctly hold their assigned roles.
    function test_GovernorHoldsProposerRole() public {
        _performFullHandoff();

        assertTrue(timelock.hasRole(PROPOSER_ROLE, address(governor)));
        assertTrue(timelock.hasRole(CANCELLER_ROLE, address(governor)));
        assertTrue(timelock.hasRole(CANCELLER_ROLE, guardian));
        assertTrue(timelock.hasRole(EXECUTOR_ROLE, address(0))); // permissionless execution
        assertTrue(timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)));
    }

    /// @notice Deployer is fully removed from timelock after finalization.
    function test_DeployerRemovedFromTimelock() public {
        _performFullHandoff();

        assertFalse(timelock.hasRole(TIMELOCK_ADMIN_ROLE, deployer));
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(timelock.hasRole(PROPOSER_ROLE, deployer));
        assertFalse(timelock.hasRole(EXECUTOR_ROLE, deployer));
        assertFalse(timelock.hasRole(CANCELLER_ROLE, deployer));
    }

    /// @notice Deployer is fully removed from GovernedModuleRegistry.
    function test_DeployerRemovedFromRegistry() public {
        _performFullHandoff();

        assertFalse(registry.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(registry.hasRole(REGISTRY_ADMIN_ROLE, deployer));
    }

    /// @notice Deployer is fully removed from GovernanceGuardian.
    function test_DeployerRemovedFromGuardian() public {
        _performFullHandoff();

        assertFalse(guardianContract.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(guardianContract.hasRole(GUARDIAN_ROLE, deployer));
    }

    // ════════════════════════════════════════════════════════════════════
    //  NEGATIVE TESTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Before handoff, deployer correctly holds bootstrap roles.
    function test_BeforeHandoff_DeployerHasRoles() public view {
        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());

        // deployer should hold: DEFAULT_ADMIN_ROLE + REGISTRY_ADMIN_ROLE on registry,
        // DEFAULT_ADMIN_ROLE on timelock, DEFAULT_ADMIN_ROLE on guardianContract
        assertTrue(violations.length > 0, "deployer should hold roles before handoff");
    }

    /// @notice assertNoRolesRetained reverts before handoff.
    function test_AssertNoRolesRetained_RevertsBeforeHandoff() public {
        PostDeploymentRoleCheckHarness harness = new PostDeploymentRoleCheckHarness();

        vm.expectRevert("PostDeploymentRoleCheck: deployer retains unauthorized roles");
        harness.assertNoRolesRetained(deployer, _targets());
    }

    /// @notice Violation events are emitted for each retained role.
    function test_ViolationEventsEmitted() public {
        PostDeploymentRoleCheckHarness harness = new PostDeploymentRoleCheckHarness();
        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());
        assertGt(violations.length, 0, "deployer must hold bootstrap roles before handoff");

        for (uint256 i; i < violations.length; ++i) {
            vm.expectEmit(true, true, true, true, address(harness));
            emit PostDeploymentRoleCheck.RoleRenunciationViolation(
                deployer,
                violations[i].target,
                violations[i].role
            );
        }

        vm.expectRevert("PostDeploymentRoleCheck: deployer retains unauthorized roles");
        harness.assertNoRolesRetained(deployer, _targets());
    }

    /// @notice The specific roles deployer holds before handoff are correct.
    function test_SpecificDeployerRolesBeforeHandoff() public view {
        assertTrue(registry.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertTrue(registry.hasRole(REGISTRY_ADMIN_ROLE, deployer));
        // OZ TimelockController >= 5.0 grants DEFAULT_ADMIN_ROLE to the constructor admin.
        assertTrue(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertTrue(guardianContract.hasRole(DEFAULT_ADMIN_ROLE, deployer));
    }

    /// @notice Zero address deployer returns zero violations (guard).
    function test_ZeroAddressDeployer_ReturnsEmpty() public view {
        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(address(0), _targets());
        assertEq(violations.length, 0);
    }

    /// @notice Empty targets returns zero violations.
    function test_EmptyTargets_ReturnsEmpty() public view {
        address[] memory empty = new address[](0);
        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, empty);
        assertEq(violations.length, 0);
    }

    // ════════════════════════════════════════════════════════════════════
    //  BOUNDARY TESTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Partial renunciation — only registry roles renounced — still detected.
    function test_PartialRenunciation_RegistryOnly() public {
        vm.startPrank(deployer);
        registry.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        registry.renounceRole(REGISTRY_ADMIN_ROLE, deployer);
        vm.stopPrank();

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());

        // Still has DEFAULT_ADMIN_ROLE on timelock and DEFAULT_ADMIN_ROLE on guardianContract
        assertTrue(violations.length > 0, "partial renunciation should still have violations");
    }

    /// @notice Partial renunciation — only timelock finalized — still detected.
    function test_PartialRenunciation_TimelockOnly() public {
        vm.startPrank(deployer);
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);
        vm.stopPrank();

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());

        // Still has roles on registry and guardianContract
        assertTrue(violations.length > 0, "partial timelock-only renunciation should fail");
    }

    /// @notice Target with zero address in the array is safely skipped.
    function test_ZeroAddressTarget_SafelySkipped() public {
        _performFullHandoff();

        address[] memory targets = new address[](3);
        targets[0] = address(registry);
        targets[1] = address(0); // should be skipped
        targets[2] = address(timelock);

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, targets);

        assertEq(violations.length, 0);
    }

    /// @notice Non-contract address (EOA) in targets is safely handled.
    function test_EOATarget_SafelyHandled() public {
        _performFullHandoff();

        address[] memory targets = new address[](2);
        targets[0] = address(registry);
        targets[1] = address(0xDEAD); // EOA, no code

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, targets);

        assertEq(violations.length, 0);
    }

    /// @notice Non-AccessControl contract in targets is safely handled.
    function test_NonAccessControlTarget_SafelyHandled() public {
        _performFullHandoff();

        address[] memory targets = new address[](2);
        targets[0] = address(registry);
        targets[1] = address(govToken); // ERC20, not AccessControl

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, targets);

        assertEq(violations.length, 0);
    }

    // ════════════════════════════════════════════════════════════════════
    //  AUTHORIZATION TESTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Deployer cannot re-grant DEFAULT_ADMIN_ROLE to itself after renunciation.
    function test_DeployerCannotReacquireAdminAfterRenunciation() public {
        _performFullHandoff();

        // deployer no longer has DEFAULT_ADMIN_ROLE on registry
        vm.prank(deployer);
        vm.expectRevert();
        registry.grantRole(DEFAULT_ADMIN_ROLE, deployer);
    }

    /// @notice Deployer cannot re-grant REGISTRY_ADMIN_ROLE after renunciation.
    function test_DeployerCannotReacquireRegistryAdminAfterRenunciation() public {
        _performFullHandoff();

        vm.prank(deployer);
        vm.expectRevert();
        registry.grantRole(REGISTRY_ADMIN_ROLE, deployer);
    }

    /// @notice Deployer cannot re-grant timelock administration after finalization.
    function test_DeployerCannotReacquireTimelockAdmin() public {
        _performFullHandoff();

        vm.prank(deployer);
        vm.expectRevert();
        timelock.grantRole(DEFAULT_ADMIN_ROLE, deployer);

        // The retired legacy role is likewise un-grantable by the deployer.
        vm.prank(deployer);
        vm.expectRevert();
        timelock.grantRole(TIMELOCK_ADMIN_ROLE, deployer);
    }

    /// @notice Random user cannot acquire admin roles.
    function test_RandomUserCannotAcquireRoles() public {
        _performFullHandoff();

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(otherUser, _targets());

        assertEq(violations.length, 0, "other user should have no roles");
    }

    /// @notice Guardian retains only GUARDIAN_ROLE and CANCELLER_ROLE, not admin.
    function test_GuardianOnlyHasGuardianAndCancellerRoles() public {
        _performFullHandoff();

        // Guardian should have GUARDIAN_ROLE on guardianContract
        assertTrue(guardianContract.hasRole(GUARDIAN_ROLE, guardian));

        // Guardian should have CANCELLER_ROLE on timelock
        assertTrue(timelock.hasRole(CANCELLER_ROLE, guardian));

        // Guardian should NOT have DEFAULT_ADMIN_ROLE or TIMELOCK_ADMIN_ROLE
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, guardian));
        assertFalse(timelock.hasRole(TIMELOCK_ADMIN_ROLE, guardian));
        assertFalse(registry.hasRole(DEFAULT_ADMIN_ROLE, guardian));
    }

    // ════════════════════════════════════════════════════════════════════
    //  REPLAY TESTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Repeated checks produce identical results.
    function test_RepeatedChecksAreIdempotent() public {
        _performFullHandoff();

        PostDeploymentRoleCheck.RoleViolation[] memory v1 =
            PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());
        PostDeploymentRoleCheck.RoleViolation[] memory v2 =
            PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());

        assertEq(v1.length, v2.length);
        assertEq(v1.length, 0);
    }

    /// @notice Repeated assertNoRolesRetained calls succeed consistently.
    function test_RepeatedAssertions_Succeed() public {
        _performFullHandoff();

        PostDeploymentRoleCheck.assertNoRolesRetained(deployer, _targets());
        PostDeploymentRoleCheck.assertNoRolesRetained(deployer, _targets());
        PostDeploymentRoleCheck.assertNoRolesRetained(deployer, _targets());
    }

    /// @notice State before handoff is consistently detected across checks.
    function test_RepeatedChecks_BeforeHandoff_Consistent() public view {
        PostDeploymentRoleCheck.RoleViolation[] memory v1 =
            PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());
        PostDeploymentRoleCheck.RoleViolation[] memory v2 =
            PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());

        assertEq(v1.length, v2.length);
        for (uint256 i; i < v1.length; ++i) {
            assertEq(v1[i].target, v2[i].target);
            assertEq(v1[i].role, v2[i].role);
        }
    }

    // ════════════════════════════════════════════════════════════════════
    //  FAILURE-PATH TESTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Missing GovernanceRoleTopology.finalizeTimelockAdmin leaves DEFAULT_ADMIN_ROLE.
    function test_MissingTimelockFinalization_DetectsViolation() public {
        vm.startPrank(deployer);

        // Wire topology but skip finalizeTimelockAdmin
        GovernanceRoleTopology.configure(timelock, governor, guardian, 2 days);
        // NOT calling: GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);

        // Renounce other roles
        registry.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        registry.renounceRole(REGISTRY_ADMIN_ROLE, deployer);
        guardianContract.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        vm.stopPrank();

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());

        assertTrue(violations.length > 0, "should detect timelock administration violation");

        // Verify the specific violation: the canonical OZ >= 5.0 timelock admin role.
        bool foundTimelockAdmin = false;
        for (uint256 i; i < violations.length; ++i) {
            if (violations[i].target == address(timelock) && violations[i].role == DEFAULT_ADMIN_ROLE) {
                foundTimelockAdmin = true;
            }
        }
        assertTrue(foundTimelockAdmin, "DEFAULT_ADMIN_ROLE on timelock violation not found");
    }

    /// @notice Missing registry admin renunciation is detected.
    function test_MissingRegistryRenunciation_DetectsViolation() public {
        vm.startPrank(deployer);

        GovernanceRoleTopology.configure(timelock, governor, guardian, 2 days);
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);
        // NOT renouncing registry roles
        guardianContract.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        vm.stopPrank();

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());

        assertTrue(violations.length >= 2, "should detect registry violations");

        bool foundRegistryAdmin = false;
        bool foundDefaultAdmin = false;
        for (uint256 i; i < violations.length; ++i) {
            if (violations[i].target == address(registry)) {
                if (violations[i].role == REGISTRY_ADMIN_ROLE) foundRegistryAdmin = true;
                if (violations[i].role == DEFAULT_ADMIN_ROLE) foundDefaultAdmin = true;
            }
        }
        assertTrue(foundRegistryAdmin, "REGISTRY_ADMIN_ROLE not detected");
        assertTrue(foundDefaultAdmin, "DEFAULT_ADMIN_ROLE on registry not detected");
    }

    /// @notice Missing guardian admin renunciation is detected.
    function test_MissingGuardianRenunciation_DetectsViolation() public {
        vm.startPrank(deployer);

        GovernanceRoleTopology.configure(timelock, governor, guardian, 2 days);
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);
        registry.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        registry.renounceRole(REGISTRY_ADMIN_ROLE, deployer);
        // NOT renouncing guardianContract admin
        vm.stopPrank();

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());

        assertTrue(violations.length > 0, "should detect guardian admin violation");

        bool found = false;
        for (uint256 i; i < violations.length; ++i) {
            if (violations[i].target == address(guardianContract) && violations[i].role == DEFAULT_ADMIN_ROLE) {
                found = true;
            }
        }
        assertTrue(found, "DEFAULT_ADMIN_ROLE on guardianContract not detected");
    }

    // ════════════════════════════════════════════════════════════════════
    //  ROLE CATALOG INTEGRITY
    // ════════════════════════════════════════════════════════════════════

    /// @notice Role catalog returns the expected number of roles.
    function test_RoleCatalogSize() public pure {
        bytes32[] memory roles = PostDeploymentRoleCheck.roleCatalog();
        assertEq(roles.length, PostDeploymentRoleCheck.ROLE_CATALOG_SIZE);
    }

    /// @notice Role catalog contains DEFAULT_ADMIN_ROLE at index 0.
    function test_RoleCatalogContainsDefaultAdmin() public pure {
        bytes32[] memory roles = PostDeploymentRoleCheck.roleCatalog();
        assertEq(roles[0], bytes32(0));
    }

    /// @notice Role catalog values are deterministic.
    function test_RoleCatalog_Deterministic() public pure {
        bytes32[] memory a = PostDeploymentRoleCheck.roleCatalog();
        bytes32[] memory b = PostDeploymentRoleCheck.roleCatalog();
        assertEq(a.length, b.length);
        for (uint256 i; i < a.length; ++i) {
            assertEq(a[i], b[i]);
        }
    }

    /// @notice safeCheckRole returns true when deployer holds a role.
    function test_SafeCheckRole_ReturnsTrue() public view {
        assertTrue(PostDeploymentRoleCheck.safeCheckRole(address(registry), DEFAULT_ADMIN_ROLE, deployer));
    }

    /// @notice safeCheckRole returns false for non-held role.
    function test_SafeCheckRole_ReturnsFalse() public view {
        assertFalse(PostDeploymentRoleCheck.safeCheckRole(address(registry), DEFAULT_ADMIN_ROLE, otherUser));
    }

    /// @notice safeCheckRole returns false for EOA target.
    function test_SafeCheckRole_EOA_ReturnsFalse() public view {
        assertFalse(PostDeploymentRoleCheck.safeCheckRole(address(0xDEAD), DEFAULT_ADMIN_ROLE, deployer));
    }
}
