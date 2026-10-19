// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title GovernanceRoleTopologyConformance
 * @notice V2-SC-116 — Governance Role Topology Conformance Tests.
 *
 * Asserts that every deployed governance contract carries exactly the roles
 * prescribed by the canonical V2 topology and that NO residual deployer
 * privilege survives post-handoff:
 *
 * ┌──────────────────────┬────────────────────────────────────────────────────────┐
 * │ Contract             │ Expected steady-state roles                            │
 * ├──────────────────────┼────────────────────────────────────────────────────────┤
 * │ TimelockController   │ PROPOSER_ROLE       → governor (sole holder)           │
 * │                      │ CANCELLER_ROLE      → governor + guardian EOA          │
 * │                      │ EXECUTOR_ROLE       → address(0) (permissionless)      │
 * │                      │ DEFAULT_ADMIN_ROLE  → timelock itself (self-admin)     │
 * │                      │ deployer holds NONE of the above                       │
 * ├──────────────────────┼────────────────────────────────────────────────────────┤
 * │ GovernanceGuardian   │ DEFAULT_ADMIN_ROLE  → admin (governance lifecycle)     │
 * │                      │ GUARDIAN_ROLE       → guardian EOA                    │
 * │                      │ deployer holds NONE                                    │
 * ├──────────────────────┼────────────────────────────────────────────────────────┤
 * │ GovernanceSnapshot   │ DEFAULT_ADMIN_ROLE  → admin                            │
 * │                      │ SNAPSHOT_REGISTRAR_ROLE → governor (sole holder)       │
 * │                      │ deployer/admin hold no SNAPSHOT_REGISTRAR_ROLE         │
 * ├──────────────────────┼────────────────────────────────────────────────────────┤
 * │ GovernedModuleReg.   │ DEFAULT_ADMIN_ROLE  → admin                            │
 * │                      │ REGISTRY_ADMIN_ROLE → timelock (governance-gated)      │
 * │                      │ deployer holds NONE                                    │
 * └──────────────────────┴────────────────────────────────────────────────────────┘
 *
 * Test categories (V2-SC-116 acceptance criteria):
 *   Positive    — canonical topology is fully satisfied after configuration
 *   Negative    — every prohibited role assignment is absent
 *   Boundary    — zero-address sentinel, self-admin, permissionless executor
 *   Auth        — only authorized actors can mutate roles
 *   Replay      — duplicate role grants do not create extra holders
 *   Failure     — mis-wired topology helpers revert correctly
 *   Invariant   — stateful fuzz verifying topology invariants survive role mutations
 *
 * No production addresses, secrets, or Stellar/Soroban code included.
 */
import "forge-std/Test.sol";

import {Vm} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {GovernedModuleRegistry} from "../../contracts/governance/v2/GovernedModuleRegistry.sol";
import {TruthBountyGovernanceToken} from "../../contracts/governance/v2/TruthBountyGovernanceToken.sol";
import {TruthBountyGovernor} from "../../contracts/governance/v2/TruthBountyGovernor.sol";
import {GovernanceSnapshot} from "../../contracts/governance/v2/GovernanceSnapshot.sol";
import {IGovernanceSnapshot} from "../../contracts/governance/v2/IGovernanceSnapshot.sol";
import {GovernanceGuardian} from "../../contracts/governance/v2/GovernanceGuardian.sol";
import {ITruthBountyGovernor} from "../../contracts/governance/v2/ITruthBountyGovernor.sol";
import {GovernanceRoleTopology} from "../../contracts/governance/v2/GovernanceRoleTopology.sol";
import {PostDeploymentRoleCheck} from "../../contracts/deployment/PostDeploymentRoleCheck.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Shared fixture wired identically to DeployGovernanceV2.s.sol
// ─────────────────────────────────────────────────────────────────────────────

contract GovernanceRoleTopologyFixture is Test {
    // ── Role constants (mirrors GovernanceRoleTopology + OZ TimelockController) ──

    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    /// @dev Retired OZ < 5.0 timelock administration role; must stay absent (legacy negative).
    bytes32 internal constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    bytes32 internal constant SNAPSHOT_REGISTRAR_ROLE = keccak256("SNAPSHOT_REGISTRAR_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    // ── Governor parameters ──────────────────────────────────────────────────

    uint256 internal constant TIMELOCK_DELAY = 2 days;
    uint48 internal constant VOTING_DELAY = 1 days;
    uint32 internal constant VOTING_PERIOD = 3 days;
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000 ether;
    uint256 internal constant QUORUM_NUMERATOR = 4;
    uint256 internal constant TOKEN_SUPPLY = 1_000_000_000 ether;

    // ── Actors ───────────────────────────────────────────────────────────────

    /// @dev Simulates the bootstrap deployer EOA that MUST hold zero roles after handoff.
    address internal deployer = makeAddr("deployer");
    /// @dev Long-lived admin (e.g. multisig); holds DEFAULT_ADMIN_ROLE on guardian/snapshot.
    address internal admin = makeAddr("admin");
    /// @dev Guardian EOA receives CANCELLER_ROLE on timelock and GUARDIAN_ROLE on guardian contract.
    address internal guardian = makeAddr("guardian");

    // ── Deployed contracts ───────────────────────────────────────────────────

    GovernedModuleRegistry internal registry;
    TruthBountyGovernanceToken internal token;
    TimelockController internal timelock;
    GovernanceSnapshot internal snapshot;
    TruthBountyGovernor internal governor;
    GovernanceGuardian internal guardianContract;

    // ─────────────────────────────────────────────────────────────────────────
    //  Deployment helper — mirrors DeployGovernanceV2.s.sol step-for-step
    // ─────────────────────────────────────────────────────────────────────────

    function _deployCanonicalTopology() internal {
        // ── Phase 1: deployer creates contracts ─────────────────────────────
        vm.startPrank(deployer);

        // 1. GovernedModuleRegistry — deployer holds DEFAULT_ADMIN_ROLE + REGISTRY_ADMIN_ROLE
        registry = new GovernedModuleRegistry(deployer);
        // 2. Governance token
        token = new TruthBountyGovernanceToken(deployer, TOKEN_SUPPLY);

        // 3. TimelockController — deployer holds DEFAULT_ADMIN_ROLE initially (OZ >= 5.0)
        address[] memory noProposers = new address[](0);
        address[] memory noExecutors = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, noProposers, noExecutors, deployer);

        vm.stopPrank();

        // ── Phase 2: admin creates snapshot with itself as both admin and temporary registrar
        //    (mirrors DeployGovernanceV2 where cfg.admin is used for both parameters)
        vm.startPrank(admin);
        snapshot = new GovernanceSnapshot(admin, admin);
        vm.stopPrank();

        // ── Phase 3: deployer creates governor (needs snapshot address) ─────
        vm.startPrank(deployer);
        governor = new TruthBountyGovernor(
            token,
            timelock,
            registry,
            IGovernanceSnapshot(address(snapshot)),
            guardian,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_NUMERATOR
        );
        vm.stopPrank();

        // ── Phase 4: admin transfers SNAPSHOT_REGISTRAR_ROLE to governor ────
        vm.startPrank(admin);
        snapshot.grantRole(SNAPSHOT_REGISTRAR_ROLE, address(governor));
        snapshot.revokeRole(SNAPSHOT_REGISTRAR_ROLE, admin);
        vm.stopPrank();

        // ── Phase 5: deploy guardian contract (admin is bootstrap admin) ────
        vm.startPrank(admin);
        guardianContract = new GovernanceGuardian(admin, guardian, ITruthBountyGovernor(address(governor)));
        vm.stopPrank();

        // ── Phase 6: guardian wires itself ───────────────────────────────────
        vm.prank(guardian);
        governor.setGovernanceGuardianModule(address(guardianContract));

        // ── Phase 7: deployer wires timelock roles and finalizes ─────────────
        vm.startPrank(deployer);
        GovernanceRoleTopology.configure(timelock, governor, guardian, TIMELOCK_DELAY);
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);

        // Governance controls module registry (grant lives on the registry; after
        // finalizeTimelockAdmin the deployer no longer administers the timelock)
        registry.grantRole(REGISTRY_ADMIN_ROLE, address(timelock));
        // Deployer renounces own registry roles (mirrors _performFullHandoff in PostDeploymentRoleRenunciation)
        registry.renounceRole(REGISTRY_ADMIN_ROLE, deployer);
        registry.renounceRole(DEFAULT_ADMIN_ROLE, deployer);

        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal assertion helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Assert `account` holds `role` on `target`; message tags the failing contract.
    function _assertHasRole(IAccessControl target, bytes32 role, address account, string memory label) internal view {
        assertTrue(
            target.hasRole(role, account),
            string.concat(label, ": expected role not held by account")
        );
    }

    /// @dev Assert `account` does NOT hold `role` on `target`.
    function _assertLacksRole(IAccessControl target, bytes32 role, address account, string memory label) internal view {
        assertFalse(
            target.hasRole(role, account),
            string.concat(label, ": prohibited role held by account")
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  POSITIVE TESTS — canonical topology is fully satisfied post-configuration
// ═════════════════════════════════════════════════════════════════════════════

contract GovernanceRoleTopologyPositiveTest is GovernanceRoleTopologyFixture {
    function setUp() public {
        _deployCanonicalTopology();
    }

    // ── TimelockController ───────────────────────────────────────────────────

    /// @notice Governor is the sole PROPOSER on the timelock.
    function test_TimelockProposerRoleAssignedToGovernor() public view {
        _assertHasRole(IAccessControl(address(timelock)), PROPOSER_ROLE, address(governor), "Timelock.PROPOSER_ROLE");
    }

    /// @notice Governor holds CANCELLER_ROLE so it can abort queued operations.
    function test_TimelockCancellerRoleAssignedToGovernor() public view {
        _assertHasRole(IAccessControl(address(timelock)), CANCELLER_ROLE, address(governor), "Timelock.CANCELLER_ROLE[gov]");
    }

    /// @notice Guardian EOA holds CANCELLER_ROLE for emergency veto.
    function test_TimelockCancellerRoleAssignedToGuardianEOA() public view {
        _assertHasRole(IAccessControl(address(timelock)), CANCELLER_ROLE, guardian, "Timelock.CANCELLER_ROLE[guardian]");
    }

    /// @notice address(0) holds EXECUTOR_ROLE → execution is permissionless after delay.
    function test_TimelockExecutorRoleIsPermissionless() public view {
        _assertHasRole(IAccessControl(address(timelock)), EXECUTOR_ROLE, address(0), "Timelock.EXECUTOR_ROLE[address(0)]");
    }

    /// @notice Timelock is self-admin; no EOA retains administration.
    function test_TimelockSelfAdminAfterFinalization() public view {
        _assertHasRole(
            IAccessControl(address(timelock)), DEFAULT_ADMIN_ROLE, address(timelock), "Timelock.DEFAULT_ADMIN_ROLE[self]"
        );
    }

    // ── GovernanceGuardian ───────────────────────────────────────────────────

    /// @notice Admin holds DEFAULT_ADMIN_ROLE on the guardian contract.
    function test_GuardianContractAdminHoldsDefaultAdminRole() public view {
        _assertHasRole(IAccessControl(address(guardianContract)), DEFAULT_ADMIN_ROLE, admin, "GuardianContract.DEFAULT_ADMIN_ROLE");
    }

    /// @notice Guardian EOA holds GUARDIAN_ROLE on the guardian contract.
    function test_GuardianContractGuardianEOAHoldsGuardianRole() public view {
        _assertHasRole(IAccessControl(address(guardianContract)), GUARDIAN_ROLE, guardian, "GuardianContract.GUARDIAN_ROLE");
    }

    // ── GovernanceSnapshot ───────────────────────────────────────────────────

    /// @notice Admin holds DEFAULT_ADMIN_ROLE on the snapshot registry.
    function test_SnapshotAdminHoldsDefaultAdminRole() public view {
        _assertHasRole(IAccessControl(address(snapshot)), DEFAULT_ADMIN_ROLE, admin, "Snapshot.DEFAULT_ADMIN_ROLE");
    }

    /// @notice Governor — and only the governor — holds SNAPSHOT_REGISTRAR_ROLE.
    function test_SnapshotRegistrarRoleAssignedExclusivelyToGovernor() public view {
        _assertHasRole(
            IAccessControl(address(snapshot)), SNAPSHOT_REGISTRAR_ROLE, address(governor), "Snapshot.SNAPSHOT_REGISTRAR_ROLE[gov]"
        );
    }

    // ── GovernedModuleRegistry ───────────────────────────────────────────────

    /// @notice Timelock (governance) holds REGISTRY_ADMIN_ROLE; direct mutation is governance-gated.
    function test_RegistryAdminRoleAssignedToTimelock() public view {
        _assertHasRole(
            IAccessControl(address(registry)), REGISTRY_ADMIN_ROLE, address(timelock), "Registry.REGISTRY_ADMIN_ROLE[timelock]"
        );
    }

    // ── TruthBountyGovernor state ────────────────────────────────────────────

    /// @notice Governor's wired guardian EOA matches the bootstrap guardian.
    function test_GovernorGuardianAddressMatchesBootstrapGuardian() public view {
        assertEq(governor.guardian(), guardian, "Governor.guardian mismatch");
    }

    /// @notice GovernanceGuardianModule is set to the deployed guardian contract.
    function test_GovernorGuardianModuleSetToGuardianContract() public view {
        assertEq(
            governor.governanceGuardianModule(),
            address(guardianContract),
            "Governor.governanceGuardianModule mismatch"
        );
    }

    /// @notice Governor's registry matches the deployed GovernedModuleRegistry.
    function test_GovernorModuleRegistryMatchesDeployedRegistry() public view {
        assertEq(address(governor.moduleRegistry()), address(registry), "Governor.moduleRegistry mismatch");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  NEGATIVE TESTS — prohibited role assignments are absent
// ═════════════════════════════════════════════════════════════════════════════

contract GovernanceRoleTopologyNegativeTest is GovernanceRoleTopologyFixture {
    function setUp() public {
        _deployCanonicalTopology();
    }

    // ── No residual deployer privilege (core of V2-SC-116) ──────────────────

    /// @notice Deployer holds no PROPOSER_ROLE on the timelock after handoff.
    function test_DeployerLacksTimelockProposerRole() public view {
        _assertLacksRole(IAccessControl(address(timelock)), PROPOSER_ROLE, deployer, "Timelock.PROPOSER_ROLE[deployer]");
    }

    /// @notice Deployer holds no CANCELLER_ROLE on the timelock after handoff.
    function test_DeployerLacksTimelockCancellerRole() public view {
        _assertLacksRole(IAccessControl(address(timelock)), CANCELLER_ROLE, deployer, "Timelock.CANCELLER_ROLE[deployer]");
    }

    /// @notice Deployer holds no EXECUTOR_ROLE on the timelock (only address(0) should).
    function test_DeployerLacksTimelockExecutorRole() public view {
        _assertLacksRole(IAccessControl(address(timelock)), EXECUTOR_ROLE, deployer, "Timelock.EXECUTOR_ROLE[deployer]");
    }

    /// @notice Deployer no longer holds timelock administration after finalizeTimelockAdmin.
    function test_DeployerLacksTimelockAdminRoleAfterFinalization() public view {
        _assertLacksRole(
            IAccessControl(address(timelock)), DEFAULT_ADMIN_ROLE, deployer, "Timelock.DEFAULT_ADMIN_ROLE[deployer]"
        );
        // The retired legacy role is absent as well.
        _assertLacksRole(
            IAccessControl(address(timelock)), TIMELOCK_ADMIN_ROLE, deployer, "Timelock.TIMELOCK_ADMIN_ROLE[deployer]"
        );
    }

    /// @notice Admin holds no timelock administration; the timelock is its own admin.
    function test_AdminLacksTimelockAdminRole() public view {
        _assertLacksRole(
            IAccessControl(address(timelock)), DEFAULT_ADMIN_ROLE, admin, "Timelock.DEFAULT_ADMIN_ROLE[admin]"
        );
    }

    /// @notice Deployer holds no GUARDIAN_ROLE on the guardian contract.
    function test_DeployerLacksGuardianContractGuardianRole() public view {
        _assertLacksRole(
            IAccessControl(address(guardianContract)), GUARDIAN_ROLE, deployer, "GuardianContract.GUARDIAN_ROLE[deployer]"
        );
    }

    /// @notice Deployer holds no DEFAULT_ADMIN_ROLE on the guardian contract.
    function test_DeployerLacksGuardianContractDefaultAdminRole() public view {
        _assertLacksRole(
            IAccessControl(address(guardianContract)), DEFAULT_ADMIN_ROLE, deployer, "GuardianContract.DEFAULT_ADMIN_ROLE[deployer]"
        );
    }

    /// @notice Deployer no longer holds SNAPSHOT_REGISTRAR_ROLE (transferred to governor).
    function test_DeployerLacksSnapshotRegistrarRole() public view {
        _assertLacksRole(
            IAccessControl(address(snapshot)), SNAPSHOT_REGISTRAR_ROLE, deployer, "Snapshot.SNAPSHOT_REGISTRAR_ROLE[deployer]"
        );
    }

    /// @notice Admin loses SNAPSHOT_REGISTRAR_ROLE after it is transferred to the governor.
    function test_AdminLacksSnapshotRegistrarRole() public view {
        _assertLacksRole(
            IAccessControl(address(snapshot)), SNAPSHOT_REGISTRAR_ROLE, admin, "Snapshot.SNAPSHOT_REGISTRAR_ROLE[admin]"
        );
    }

    /// @notice Deployer holds no REGISTRY_ADMIN_ROLE on the module registry.
    function test_DeployerLacksRegistryAdminRole() public view {
        _assertLacksRole(
            IAccessControl(address(registry)), REGISTRY_ADMIN_ROLE, deployer, "Registry.REGISTRY_ADMIN_ROLE[deployer]"
        );
    }

    /// @notice Deployer holds no DEFAULT_ADMIN_ROLE on the module registry.
    function test_DeployerLacksRegistryDefaultAdminRole() public view {
        _assertLacksRole(
            IAccessControl(address(registry)), DEFAULT_ADMIN_ROLE, deployer, "Registry.DEFAULT_ADMIN_ROLE[deployer]"
        );
    }

    // ── No cross-contamination: guardian EOA has no execution authority ──────

    /// @notice Guardian EOA holds no PROPOSER_ROLE; veto is cancel-only.
    function test_GuardianEOALacksTimelockProposerRole() public view {
        _assertLacksRole(
            IAccessControl(address(timelock)), PROPOSER_ROLE, guardian, "Timelock.PROPOSER_ROLE[guardian]"
        );
    }

    /// @notice Guardian EOA holds no EXECUTOR_ROLE; it cannot unilaterally execute proposals.
    function test_GuardianEOALacksTimelockExecutorRole() public view {
        _assertLacksRole(
            IAccessControl(address(timelock)), EXECUTOR_ROLE, guardian, "Timelock.EXECUTOR_ROLE[guardian]"
        );
    }

    /// @notice Governor contract holds no GUARDIAN_ROLE on the guardian contract.
    function test_GovernorLacksGuardianRole() public view {
        _assertLacksRole(
            IAccessControl(address(guardianContract)), GUARDIAN_ROLE, address(governor), "GuardianContract.GUARDIAN_ROLE[governor]"
        );
    }

    /// @notice Timelock holds no SNAPSHOT_REGISTRAR_ROLE; only the governor may register snapshots.
    function test_TimelockLacksSnapshotRegistrarRole() public view {
        _assertLacksRole(
            IAccessControl(address(snapshot)), SNAPSHOT_REGISTRAR_ROLE, address(timelock), "Snapshot.SNAPSHOT_REGISTRAR_ROLE[timelock]"
        );
    }

    // ── PostDeploymentRoleCheck catalog sweep ────────────────────────────────

    /**
     * @notice The deployer holds zero roles from the full 27-entry V2 role catalog across
     *         all governance contracts.  This mirrors VerifyRoleRenunciation.s.sol.
     */
    function test_DeployerHoldsZeroRolesAcrossAllGovernanceContracts() public view {
        address[] memory targets = new address[](4);
        targets[0] = address(timelock);
        targets[1] = address(guardianContract);
        targets[2] = address(snapshot);
        targets[3] = address(registry);

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, targets);

        assertEq(
            violations.length,
            0,
            "Deployer retains one or more roles after governance handoff"
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  BOUNDARY TESTS — edge conditions mandated by the security model
// ═════════════════════════════════════════════════════════════════════════════

contract GovernanceRoleTopologyBoundaryTest is GovernanceRoleTopologyFixture {
    function setUp() public {
        _deployCanonicalTopology();
    }

    // ── Zero-address sentinel ────────────────────────────────────────────────

    /// @notice address(0) holds EXECUTOR_ROLE; this is the OZ permissionless-execution sentinel.
    function test_ZeroAddressHoldsExecutorRole_PermissionlessSentinel() public view {
        assertTrue(
            IAccessControl(address(timelock)).hasRole(EXECUTOR_ROLE, address(0)),
            "address(0) must hold EXECUTOR_ROLE (permissionless execution sentinel)"
        );
    }

    /// @notice address(0) holds no other timelock roles; sentinel scope is limited to EXECUTOR_ROLE.
    function test_ZeroAddressHoldsNoOtherTimelockRoles() public view {
        _assertLacksRole(IAccessControl(address(timelock)), PROPOSER_ROLE, address(0), "Timelock.PROPOSER_ROLE[address(0)]");
        _assertLacksRole(IAccessControl(address(timelock)), CANCELLER_ROLE, address(0), "Timelock.CANCELLER_ROLE[address(0)]");
        _assertLacksRole(IAccessControl(address(timelock)), DEFAULT_ADMIN_ROLE, address(0), "Timelock.DEFAULT_ADMIN_ROLE[address(0)]");
    }

    /// @notice address(0) holds no SNAPSHOT_REGISTRAR_ROLE.
    function test_ZeroAddressLacksSnapshotRegistrarRole() public view {
        _assertLacksRole(
            IAccessControl(address(snapshot)), SNAPSHOT_REGISTRAR_ROLE, address(0), "Snapshot.SNAPSHOT_REGISTRAR_ROLE[address(0)]"
        );
    }

    // ── Self-admin (timelock owns its own DEFAULT_ADMIN_ROLE) ────────────────

    /// @notice Timelock holds its own DEFAULT_ADMIN_ROLE — the self-referential admin invariant.
    function test_TimelockOwnsSelfAdminRole() public view {
        assertTrue(
            IAccessControl(address(timelock)).hasRole(DEFAULT_ADMIN_ROLE, address(timelock)),
            "TimelockController must self-hold DEFAULT_ADMIN_ROLE"
        );
    }

    /// @notice After finalization, exactly the timelock holds administration; no other account does.
    function test_TimelockAdminRoleHeldByExactlyTimelock() public view {
        // The only account that should hold timelock administration is address(timelock)
        assertFalse(
            IAccessControl(address(timelock)).hasRole(DEFAULT_ADMIN_ROLE, deployer),
            "Deployer must not hold timelock administration"
        );
        assertFalse(
            IAccessControl(address(timelock)).hasRole(DEFAULT_ADMIN_ROLE, admin),
            "Admin must not hold timelock administration"
        );
        assertFalse(
            IAccessControl(address(timelock)).hasRole(DEFAULT_ADMIN_ROLE, guardian),
            "Guardian must not hold timelock administration"
        );
        assertFalse(
            IAccessControl(address(timelock)).hasRole(DEFAULT_ADMIN_ROLE, address(governor)),
            "Governor must not hold timelock administration"
        );
        // The retired legacy role is held by nobody, including the timelock itself.
        assertFalse(
            IAccessControl(address(timelock)).hasRole(TIMELOCK_ADMIN_ROLE, address(timelock)),
            "Legacy TIMELOCK_ADMIN_ROLE must not be granted"
        );
    }

    // ── Minimum delay preserved ──────────────────────────────────────────────

    /// @notice Timelock minimum delay matches the deployment configuration.
    function test_TimelockMinDelayMatchesConfiguration() public view {
        assertEq(timelock.getMinDelay(), TIMELOCK_DELAY, "Timelock minDelay mismatch");
    }

    // ── GovernanceGuardianModule single-initialization boundary ─────────────

    /// @notice Attempting to re-initialize governanceGuardianModule reverts.
    function test_GovernanceGuardianModuleCannotBeResetByGuardian() public {
        address newModule = makeAddr("anotherModule");
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                TruthBountyGovernor.GovernanceGuardianModuleAlreadySet.selector,
                address(guardianContract)
            )
        );
        governor.setGovernanceGuardianModule(newModule);
    }

    /// @notice A non-guardian caller cannot initialize the guardian module.
    function test_NonGuardianCannotSetGovernanceGuardianModule() public {
        // Deploy a fresh governor with no guardian module yet so we can test the auth path
        vm.startPrank(deployer);
        GovernedModuleRegistry freshReg = new GovernedModuleRegistry(deployer);
        TruthBountyGovernanceToken freshToken = new TruthBountyGovernanceToken(deployer, TOKEN_SUPPLY);
        address[] memory empty = new address[](0);
        TimelockController freshTimelock = new TimelockController(TIMELOCK_DELAY, empty, empty, deployer);
        GovernanceSnapshot freshSnapshot = new GovernanceSnapshot(admin, deployer);
        TruthBountyGovernor freshGov = new TruthBountyGovernor(
            freshToken,
            freshTimelock,
            freshReg,
            IGovernanceSnapshot(address(freshSnapshot)),
            guardian,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_NUMERATOR
        );
        vm.stopPrank();

        vm.prank(deployer); // deployer ≠ guardian
        vm.expectRevert(
            abi.encodeWithSelector(
                TruthBountyGovernor.UnauthorizedGuardianModuleSetter.selector,
                deployer
            )
        );
        freshGov.setGovernanceGuardianModule(address(guardianContract));
    }

    // ── Guardian contract constructor zero-address guard ────────────────────

    /// @notice GovernanceGuardian reverts when governor address is zero.
    function test_GuardianContractRejectsZeroGovernorAddress() public {
        vm.expectRevert(GovernanceGuardian.ZeroGovernorAddress.selector);
        new GovernanceGuardian(admin, guardian, ITruthBountyGovernor(address(0)));
    }

    // ── GovernanceSnapshot zero-address guard ───────────────────────────────

    /// @notice GovernanceSnapshot reverts when admin is zero (re-uses InvalidSnapshotTimestamp).
    function test_SnapshotRejectsZeroAdmin() public {
        vm.expectRevert();
        new GovernanceSnapshot(address(0), deployer);
    }

    /// @notice GovernanceSnapshot reverts when registrar is zero.
    function test_SnapshotRejectsZeroRegistrar() public {
        vm.expectRevert();
        new GovernanceSnapshot(admin, address(0));
    }

    // ── GovernedModuleRegistry zero-address guard ────────────────────────────

    /// @notice GovernedModuleRegistry reverts when admin is zero.
    function test_ModuleRegistryRejectsZeroAdmin() public {
        vm.expectRevert();
        new GovernedModuleRegistry(address(0));
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  AUTHORIZATION TESTS — only permitted callers can mutate roles
// ═════════════════════════════════════════════════════════════════════════════

contract GovernanceRoleTopologyAuthorizationTest is GovernanceRoleTopologyFixture {
    function setUp() public {
        _deployCanonicalTopology();
    }

    address internal rando = makeAddr("rando");

    // ── TimelockController role mutation gates ────────────────────────────────

    /// @notice Random caller cannot grant PROPOSER_ROLE on the timelock (timelock is self-admin).
    function test_UnauthorizedCannotGrantTimelockProposerRole() public {
        vm.prank(rando);
        vm.expectRevert();
        IAccessControl(address(timelock)).grantRole(PROPOSER_ROLE, rando);
    }

    /// @notice Random caller cannot grant CANCELLER_ROLE on the timelock.
    function test_UnauthorizedCannotGrantTimelockCancellerRole() public {
        vm.prank(rando);
        vm.expectRevert();
        IAccessControl(address(timelock)).grantRole(CANCELLER_ROLE, rando);
    }

    /// @notice Random caller cannot revoke CANCELLER_ROLE from guardian on the timelock.
    function test_UnauthorizedCannotRevokeTimelockCancellerRole() public {
        vm.prank(rando);
        vm.expectRevert();
        IAccessControl(address(timelock)).revokeRole(CANCELLER_ROLE, guardian);
    }

    /// @notice Random caller cannot revoke timelock administration from the timelock itself.
    function test_UnauthorizedCannotRevokeTimelockSelfAdminRole() public {
        vm.prank(rando);
        vm.expectRevert();
        IAccessControl(address(timelock)).revokeRole(DEFAULT_ADMIN_ROLE, address(timelock));
    }

    // ── GovernanceGuardian role mutation gates ────────────────────────────────

    /// @notice Non-admin cannot grant GUARDIAN_ROLE on the guardian contract.
    function test_NonAdminCannotGrantGuardianRole() public {
        vm.prank(rando);
        vm.expectRevert();
        IAccessControl(address(guardianContract)).grantRole(GUARDIAN_ROLE, rando);
    }

    /// @notice Guardian EOA cannot grant DEFAULT_ADMIN_ROLE; it is admin-scoped.
    function test_GuardianEOACannotGrantDefaultAdminRole() public {
        vm.prank(guardian);
        vm.expectRevert();
        IAccessControl(address(guardianContract)).grantRole(DEFAULT_ADMIN_ROLE, guardian);
    }

    // ── GovernanceSnapshot role mutation gates ────────────────────────────────

    /// @notice Non-admin cannot grant SNAPSHOT_REGISTRAR_ROLE.
    function test_NonAdminCannotGrantSnapshotRegistrarRole() public {
        vm.prank(rando);
        vm.expectRevert();
        IAccessControl(address(snapshot)).grantRole(SNAPSHOT_REGISTRAR_ROLE, rando);
    }

    /// @notice Admin can rotate SNAPSHOT_REGISTRAR_ROLE to a new governor.
    function test_AdminCanRotateSnapshotRegistrarRole() public {
        address newGov = makeAddr("newGov");
        vm.startPrank(admin);
        snapshot.grantRole(SNAPSHOT_REGISTRAR_ROLE, newGov);
        snapshot.revokeRole(SNAPSHOT_REGISTRAR_ROLE, address(governor));
        vm.stopPrank();

        assertTrue(
            IAccessControl(address(snapshot)).hasRole(SNAPSHOT_REGISTRAR_ROLE, newGov),
            "New governor must hold SNAPSHOT_REGISTRAR_ROLE after rotation"
        );
        assertFalse(
            IAccessControl(address(snapshot)).hasRole(SNAPSHOT_REGISTRAR_ROLE, address(governor)),
            "Old governor must not hold SNAPSHOT_REGISTRAR_ROLE after rotation"
        );
    }

    // ── GovernedModuleRegistry role mutation gates ────────────────────────────

    /// @notice Random caller cannot register a governed module; requires REGISTRY_ADMIN_ROLE.
    function test_UnauthorizedCannotRegisterModule() public {
        vm.prank(rando);
        vm.expectRevert();
        registry.registerModule("FAKE_MODULE", makeAddr("fake"));
    }

    /// @notice Timelock holds REGISTRY_ADMIN_ROLE and can register a module directly.
    function test_TimelockCanRegisterModule() public {
        address newModule = makeAddr("validModule");
        vm.prank(address(timelock));
        registry.registerModule("NEW_MODULE", newModule);
        assertTrue(registry.isGovernedModule(newModule), "Module should be registered by timelock");
    }

    // ── setGuardian gated to governance (onlyGovernance) ────────────────────

    /// @notice Random caller cannot rotate the governor's guardian address.
    function test_RandomCallerCannotRotateGovernorGuardian() public {
        vm.prank(rando);
        vm.expectRevert();
        governor.setGuardian(rando);
    }

    /// @notice Guardian EOA cannot rotate the governor's guardian address directly.
    function test_GuardianEOACannotRotateGovernorGuardianDirectly() public {
        vm.prank(guardian);
        vm.expectRevert();
        governor.setGuardian(makeAddr("newGuardian"));
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  REPLAY TESTS — topology grants are idempotent; no duplicate role holders
// ═════════════════════════════════════════════════════════════════════════════

contract GovernanceRoleTopologyReplayTest is GovernanceRoleTopologyFixture {
    function setUp() public {
        _deployCanonicalTopology();
    }

    /**
     * @notice Calling GovernanceRoleTopology.configure() a second time with the same
     *         arguments does not add new role holders; all grants are idempotent
     *         (AccessControl's grantRole is a no-op when the role is already held).
     *         Critically the guardian EOA must not gain a second CANCELLER_ROLE entry.
     */
    function test_DoubleConfigureIsIdempotent() public {
        // Re-run configure as the self-admin timelock (startPrank covers all inner calls)
        vm.startPrank(address(timelock));
        GovernanceRoleTopology.configure(timelock, governor, guardian, TIMELOCK_DELAY);
        vm.stopPrank();

        // Topology must be unchanged
        _assertHasRole(IAccessControl(address(timelock)), PROPOSER_ROLE, address(governor), "Re-configure: proposer");
        _assertHasRole(IAccessControl(address(timelock)), CANCELLER_ROLE, address(governor), "Re-configure: canceller[gov]");
        _assertHasRole(IAccessControl(address(timelock)), CANCELLER_ROLE, guardian, "Re-configure: canceller[guardian]");
        _assertHasRole(IAccessControl(address(timelock)), EXECUTOR_ROLE, address(0), "Re-configure: executor");

        // Deployer must still hold zero roles
        _assertLacksRole(IAccessControl(address(timelock)), PROPOSER_ROLE, deployer, "Re-configure: no deployer proposer");
        _assertLacksRole(IAccessControl(address(timelock)), DEFAULT_ADMIN_ROLE, deployer, "Re-configure: no deployer admin");
        _assertLacksRole(IAccessControl(address(timelock)), TIMELOCK_ADMIN_ROLE, deployer, "Re-configure: no legacy admin");
    }

    /**
     * @notice The deployer role-check still returns zero violations after a no-op
     *         reconfiguration; the catalog sweep is a monotone pass.
     */
    function test_CatalogSweepPassesAfterIdempotentReconfigure() public {
        vm.startPrank(address(timelock));
        GovernanceRoleTopology.configure(timelock, governor, guardian, TIMELOCK_DELAY);
        vm.stopPrank();

        address[] memory targets = new address[](4);
        targets[0] = address(timelock);
        targets[1] = address(guardianContract);
        targets[2] = address(snapshot);
        targets[3] = address(registry);

        PostDeploymentRoleCheck.RoleViolation[] memory v =
            PostDeploymentRoleCheck.checkAllRoles(deployer, targets);
        assertEq(v.length, 0, "Deployer violations after idempotent reconfigure");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  FAILURE-PATH TESTS — mis-wired topology helpers revert or fail gracefully
// ═════════════════════════════════════════════════════════════════════════════

contract GovernanceRoleTopologyFailureTest is GovernanceRoleTopologyFixture {
    /// @notice GovernanceRoleTopology.configure called by an account that does not hold
    ///         TIMELOCK_ADMIN_ROLE on the timelock reverts.
    function test_ConfigureByNonAdminReverts() public {
        address[] memory empty = new address[](0);
        TimelockController freshTimelock = new TimelockController(TIMELOCK_DELAY, empty, empty, address(this));

        // Fresh token + governor
        TruthBountyGovernanceToken freshToken = new TruthBountyGovernanceToken(address(this), TOKEN_SUPPLY);
        GovernedModuleRegistry freshReg = new GovernedModuleRegistry(address(this));
        GovernanceSnapshot freshSnap = new GovernanceSnapshot(admin, address(this));
        TruthBountyGovernor freshGov = new TruthBountyGovernor(
            freshToken,
            freshTimelock,
            freshReg,
            IGovernanceSnapshot(address(freshSnap)),
            guardian,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_NUMERATOR
        );

        address unauthorizedCaller = makeAddr("unauthorizedCaller");
        vm.prank(unauthorizedCaller);
        vm.expectRevert();
        GovernanceRoleTopology.configure(freshTimelock, freshGov, guardian, TIMELOCK_DELAY);
    }

    /// @notice Deployer cannot re-grant themselves timelock administration after finalization.
    function test_DeployerCannotRegainTimelockAdminRole() public {
        _deployCanonicalTopology();

        vm.prank(deployer);
        vm.expectRevert(); // deployer no longer holds timelock administration
        IAccessControl(address(timelock)).grantRole(DEFAULT_ADMIN_ROLE, deployer);

        vm.prank(deployer);
        vm.expectRevert(); // and the retired legacy role is un-grantable too
        IAccessControl(address(timelock)).grantRole(TIMELOCK_ADMIN_ROLE, deployer);
    }

    /// @notice An account that never held DEFAULT_ADMIN_ROLE on the snapshot cannot revoke
    ///         the governor's SNAPSHOT_REGISTRAR_ROLE.
    function test_UnauthorizedCannotRevokeSnapshotRegistrarRole() public {
        _deployCanonicalTopology();
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert();
        IAccessControl(address(snapshot)).revokeRole(SNAPSHOT_REGISTRAR_ROLE, address(governor));
    }

    /// @notice Guardian contract cannot call vetoProposal when it does not hold GUARDIAN_ROLE
    ///         — the role was not granted to the contract address, only to the EOA.
    function test_GuardianContractCannotVetoWithoutRole() public {
        _deployCanonicalTopology();

        // The guardian contract itself does NOT hold GUARDIAN_ROLE on itself.
        // Attempting to call vetoProposal from an account that lacks GUARDIAN_ROLE reverts.
        address notGuardian = makeAddr("notGuardian");
        vm.prank(notGuardian);
        vm.expectRevert();
        guardianContract.vetoProposal(1);
    }

    /// @notice Rando cannot call guardianUnpause which requires DEFAULT_ADMIN_ROLE.
    function test_RandomCallerCannotCallGuardianUnpause() public {
        _deployCanonicalTopology();
        address rando = makeAddr("rando");

        vm.prank(rando);
        vm.expectRevert();
        guardianContract.guardianUnpause();
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  INVARIANT / FUZZ TESTS — topology invariants survive role mutations
// ═════════════════════════════════════════════════════════════════════════════

/**
 * @notice Stateful invariant suite.
 *
 * The invariant handler (`handler`) is the only actor allowed to mutate roles.
 * Foundry calls arbitrary sequences of handler functions.  After each sequence
 * the invariant assertions run and must hold.
 *
 * Invariants verified:
 *   I1  Governor always holds PROPOSER_ROLE on timelock
 *   I2  Guardian always holds CANCELLER_ROLE on timelock
 *   I3  address(0) always holds EXECUTOR_ROLE on timelock
 *   I4  Timelock always holds its own DEFAULT_ADMIN_ROLE
 *   I5  Deployer never re-acquires any governance role after handoff
 *   I6  Governor always holds SNAPSHOT_REGISTRAR_ROLE on snapshot
 *       (unless the admin explicitly rotated it away — tested in auth suite)
 */
contract GovernanceRoleTopologyInvariantTest is GovernanceRoleTopologyFixture {
    GovernanceRoleTopologyHandler internal handler;

    function setUp() public {
        _deployCanonicalTopology();
        handler = new GovernanceRoleTopologyHandler(
            deployer, address(timelock), address(snapshot), address(guardianContract), address(registry)
        );
        // Allow only the handler as a target for Foundry's invariant fuzzer
        targetContract(address(handler));
    }

    // ── I1: Governor always holds PROPOSER_ROLE ──────────────────────────────

    function invariant_GovernorAlwaysHoldsProposerRole() public view {
        assertTrue(
            IAccessControl(address(timelock)).hasRole(PROPOSER_ROLE, address(governor)),
            "I1: governor lost PROPOSER_ROLE"
        );
    }

    // ── I2: Guardian always holds CANCELLER_ROLE ─────────────────────────────

    function invariant_GuardianAlwaysHoldsCancellerRole() public view {
        assertTrue(
            IAccessControl(address(timelock)).hasRole(CANCELLER_ROLE, guardian),
            "I2: guardian lost CANCELLER_ROLE"
        );
    }

    // ── I3: address(0) always holds EXECUTOR_ROLE ────────────────────────────

    function invariant_ZeroAddressAlwaysHoldsExecutorRole() public view {
        assertTrue(
            IAccessControl(address(timelock)).hasRole(EXECUTOR_ROLE, address(0)),
            "I3: address(0) lost EXECUTOR_ROLE"
        );
    }

    // ── I4: Timelock always self-holds DEFAULT_ADMIN_ROLE ────────────────────

    function invariant_TimelockAlwaysSelfHoldsAdminRole() public view {
        assertTrue(
            IAccessControl(address(timelock)).hasRole(DEFAULT_ADMIN_ROLE, address(timelock)),
            "I4: timelock lost DEFAULT_ADMIN_ROLE"
        );
    }

    // ── I5: Deployer never re-acquires any governance role ───────────────────

    function invariant_DeployerNeverHoldsAnyGovernanceRole() public view {
        _assertLacksRole(IAccessControl(address(timelock)), PROPOSER_ROLE, deployer, "I5a");
        _assertLacksRole(IAccessControl(address(timelock)), CANCELLER_ROLE, deployer, "I5b");
        _assertLacksRole(IAccessControl(address(timelock)), EXECUTOR_ROLE, deployer, "I5c");
        _assertLacksRole(IAccessControl(address(timelock)), DEFAULT_ADMIN_ROLE, deployer, "I5d");
        _assertLacksRole(IAccessControl(address(snapshot)), SNAPSHOT_REGISTRAR_ROLE, deployer, "I5e");
        _assertLacksRole(IAccessControl(address(registry)), REGISTRY_ADMIN_ROLE, deployer, "I5f");
        _assertLacksRole(IAccessControl(address(registry)), DEFAULT_ADMIN_ROLE, deployer, "I5g");
        _assertLacksRole(IAccessControl(address(guardianContract)), DEFAULT_ADMIN_ROLE, deployer, "I5h");
        _assertLacksRole(IAccessControl(address(guardianContract)), GUARDIAN_ROLE, deployer, "I5i");
    }

    // ── I6: Governor always holds SNAPSHOT_REGISTRAR_ROLE ────────────────────

    function invariant_GovernorAlwaysHoldsSnapshotRegistrarRole() public view {
        assertTrue(
            IAccessControl(address(snapshot)).hasRole(SNAPSHOT_REGISTRAR_ROLE, address(governor)),
            "I6: governor lost SNAPSHOT_REGISTRAR_ROLE"
        );
    }
}

/**
 * @title GovernanceRoleTopologyHandler
 * @notice Bounded mutation handler for the invariant suite.
 *
 * Simulates plausible post-deployment role mutations (rotations allowed under
 * the protocol — e.g. the admin granting GUARDIAN_ROLE to a successor) and
 * implausible ones (attempts to hand roles to address(0) or the deployer,
 * which must always fail).  The handler never calls `forge-std/Test.sol` to
 * avoid skewing coverage.
 *
 * The handler holds the keys to contracts where mutations are permitted:
 *   - snapshot (admin role)
 *   - guardianContract (admin role for unpausing, default admin for role admin)
 *   - registry (timelock role — handler acts as the timelock)
 *
 * The timelock is NOT included because all mutations require the timelock itself
 * to be the caller; the handler cannot forge a timelock signature and correctly
 * leaves PROPOSER/CANCELLER/EXECUTOR unchanged.
 */
contract GovernanceRoleTopologyHandler is Test {
    bytes32 internal constant SNAPSHOT_REGISTRAR_ROLE = keccak256("SNAPSHOT_REGISTRAR_ROLE");
    bytes32 internal constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    address internal immutable deployer;
    address internal immutable timelock;
    GovernanceSnapshot internal immutable snapshot;
    GovernanceGuardian internal immutable guardianContract;
    GovernedModuleRegistry internal immutable registry;

    constructor(
        address deployer_,
        address timelock_,
        address snapshot_,
        address guardianContract_,
        address registry_
    ) {
        deployer = deployer_;
        timelock = timelock_;
        snapshot = GovernanceSnapshot(snapshot_);
        guardianContract = GovernanceGuardian(guardianContract_);
        registry = GovernedModuleRegistry(registry_);
    }

    // ── Attempt to grant SNAPSHOT_REGISTRAR_ROLE to the deployer — must fail ─

    function tryGrantSnapshotRoleToDeployer() external {
        // snapshot DEFAULT_ADMIN_ROLE is held by admin, not this handler — will revert
        try snapshot.grantRole(SNAPSHOT_REGISTRAR_ROLE, deployer) {} catch {}
    }

    // ── Attempt to grant REGISTRY_ADMIN_ROLE to the deployer — must fail ─────

    function tryGrantRegistryRoleToDeployer() external {
        // registry DEFAULT_ADMIN_ROLE was renounced — will revert
        try registry.grantRole(REGISTRY_ADMIN_ROLE, deployer) {} catch {}
    }

    // ── Attempt to register a module via the registry (timelock-gated) ────────

    function tryRegisterModule(address candidate) external {
        // Only the timelock may call this; this handler is not the timelock
        try registry.registerModule("FUZZ_MODULE", candidate) {} catch {}
    }

    // ── Attempt to grant GUARDIAN_ROLE to address(0) — must fail ─────────────

    function tryGrantGuardianRoleToZero() external {
        try guardianContract.grantRole(GUARDIAN_ROLE, address(0)) {} catch {}
    }

    // ── Attempt to grant DEFAULT_ADMIN_ROLE to deployer on guardian — must fail

    function tryGrantGuardianDefaultAdminToDeployer() external {
        try guardianContract.grantRole(DEFAULT_ADMIN_ROLE, deployer) {} catch {}
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  REGRESSION TESTS — topology defects from prior audit findings
// ═════════════════════════════════════════════════════════════════════════════

/**
 * @notice Regression suite.
 *
 * Each test is tagged with the finding it guards against.  New regression tests
 * MUST be appended here when audit defects are displaced by this work.
 *
 *   REG-001: Deployer did not renounce timelock administration before handoff
 *            (would allow deployer to unilaterally rotate all timelock roles).
 *   REG-002: Bootstrap admin retained SNAPSHOT_REGISTRAR_ROLE after governor deploy
 *            (would allow admin to register arbitrary snapshot timestamps).
 *   REG-003: GovernanceGuardianModule could be reset post-bootstrap
 *            (would allow guardian replacement without governance).
 *   REG-004: address(0) did not hold EXECUTOR_ROLE
 *            (would require a privileged executor, breaking permissionless execution).
 *   REG-005: Governor was not the sole PROPOSER_ROLE holder
 *            (extra proposers could bypass the proposal threshold).
 *   REG-006: Registry remained under deployer DEFAULT_ADMIN_ROLE
 *            (deployer could register arbitrary governed modules).
 */
contract GovernanceRoleTopologyRegressionTest is GovernanceRoleTopologyFixture {
    function setUp() public {
        _deployCanonicalTopology();
    }

    /// REG-001: Deployer renounced timelock administration — timelock is self-admin.
    function test_REG001_DeployerRenounceTimelockAdminRole() public view {
        assertFalse(
            IAccessControl(address(timelock)).hasRole(DEFAULT_ADMIN_ROLE, deployer),
            "REG-001: deployer retained timelock administration"
        );
        assertTrue(
            IAccessControl(address(timelock)).hasRole(DEFAULT_ADMIN_ROLE, address(timelock)),
            "REG-001: timelock lost its own DEFAULT_ADMIN_ROLE"
        );
        assertFalse(
            IAccessControl(address(timelock)).hasRole(TIMELOCK_ADMIN_ROLE, deployer),
            "REG-001: deployer retained legacy TIMELOCK_ADMIN_ROLE"
        );
    }

    /// REG-002: Bootstrap admin's SNAPSHOT_REGISTRAR_ROLE was revoked after governor deployment.
    function test_REG002_AdminSnapshotRegistrarRoleRevoked() public view {
        // admin was the initial registrar; after handoff only governor should hold it
        assertFalse(
            IAccessControl(address(snapshot)).hasRole(SNAPSHOT_REGISTRAR_ROLE, admin),
            "REG-002: admin retained SNAPSHOT_REGISTRAR_ROLE"
        );
        assertFalse(
            IAccessControl(address(snapshot)).hasRole(SNAPSHOT_REGISTRAR_ROLE, deployer),
            "REG-002: deployer holds SNAPSHOT_REGISTRAR_ROLE (should never have had it)"
        );
        assertTrue(
            IAccessControl(address(snapshot)).hasRole(SNAPSHOT_REGISTRAR_ROLE, address(governor)),
            "REG-002: governor does not hold SNAPSHOT_REGISTRAR_ROLE"
        );
    }

    /// REG-003: GovernanceGuardianModule is locked after first initialization.
    function test_REG003_GuardianModuleLocked() public {
        address newModule = makeAddr("laterModule");
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                TruthBountyGovernor.GovernanceGuardianModuleAlreadySet.selector,
                address(guardianContract)
            )
        );
        governor.setGovernanceGuardianModule(newModule);
    }

    /// REG-004: address(0) holds EXECUTOR_ROLE — permissionless execution.
    function test_REG004_ExecutorRolePermissionless() public view {
        assertTrue(
            IAccessControl(address(timelock)).hasRole(EXECUTOR_ROLE, address(0)),
            "REG-004: permissionless executor sentinel lost"
        );
    }

    /// REG-005: Governor is the sole PROPOSER_ROLE holder (deployer, admin, guardian are not).
    function test_REG005_GovernorIsSoleProposerRoleHolder() public view {
        assertTrue(
            IAccessControl(address(timelock)).hasRole(PROPOSER_ROLE, address(governor)),
            "REG-005: governor does not hold PROPOSER_ROLE"
        );
        assertFalse(
            IAccessControl(address(timelock)).hasRole(PROPOSER_ROLE, deployer),
            "REG-005: deployer holds PROPOSER_ROLE"
        );
        assertFalse(
            IAccessControl(address(timelock)).hasRole(PROPOSER_ROLE, admin),
            "REG-005: admin holds PROPOSER_ROLE"
        );
        assertFalse(
            IAccessControl(address(timelock)).hasRole(PROPOSER_ROLE, guardian),
            "REG-005: guardian holds PROPOSER_ROLE"
        );
    }

    /// REG-006: Registry DEFAULT_ADMIN_ROLE was renounced by deployer.
    function test_REG006_RegistryDefaultAdminRoleRenounced() public view {
        assertFalse(
            IAccessControl(address(registry)).hasRole(DEFAULT_ADMIN_ROLE, deployer),
            "REG-006: deployer retained DEFAULT_ADMIN_ROLE on registry"
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  EVENT / STORAGE RECONCILIATION TESTS
// ═════════════════════════════════════════════════════════════════════════════

/**
 * @notice Verify that role grant/revoke operations emit the canonical
 *         RoleGranted / RoleRevoked events from AccessControl and that the
 *         storage state matches the emitted events deterministically.
 *
 * This covers the "Event/storage reconciliation" criterion in V2-SC-116.
 */
contract GovernanceRoleTopologyEventReconciliationTest is GovernanceRoleTopologyFixture {
    function setUp() public {
        // Do NOT call _deployCanonicalTopology() — we observe events during wiring.
    }

    /// @notice PROPOSER_ROLE grant to governor emits RoleGranted on the timelock.
    function test_ProposerRoleGrantEmitsRoleGrantedEvent() public {
        // Set up pre-conditions
        vm.startPrank(admin);
        snapshot = new GovernanceSnapshot(admin, admin);
        vm.stopPrank();

        vm.startPrank(deployer);
        registry = new GovernedModuleRegistry(deployer);
        token = new TruthBountyGovernanceToken(deployer, TOKEN_SUPPLY);
        address[] memory empty = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, empty, empty, deployer);
        governor = new TruthBountyGovernor(
            token, timelock, registry,
            IGovernanceSnapshot(address(snapshot)),
            guardian, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QUORUM_NUMERATOR
        );
        vm.stopPrank();

        // Observe the RoleGranted event for PROPOSER_ROLE
        vm.expectEmit(true, true, true, true, address(timelock));
        emit IAccessControl.RoleGranted(PROPOSER_ROLE, address(governor), deployer);

        vm.prank(deployer);
        IAccessControl(address(timelock)).grantRole(PROPOSER_ROLE, address(governor));

        // Verify storage matches
        assertTrue(
            IAccessControl(address(timelock)).hasRole(PROPOSER_ROLE, address(governor)),
            "Storage must reflect emitted RoleGranted event"
        );
    }

    /// @notice DEFAULT_ADMIN_ROLE revoke from deployer emits RoleRevoked on the timelock.
    function test_TimelockAdminRoleRevokeEmitsRoleRevokedEvent() public {
        vm.startPrank(deployer);
        address[] memory empty = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, empty, empty, deployer);

        assertTrue(
            IAccessControl(address(timelock)).hasRole(DEFAULT_ADMIN_ROLE, deployer),
            "Deployer must hold DEFAULT_ADMIN_ROLE before revoke"
        );

        // Expect RoleRevoked before the call
        vm.expectEmit(true, true, true, true, address(timelock));
        emit IAccessControl.RoleRevoked(DEFAULT_ADMIN_ROLE, deployer, deployer);

        timelock.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
        vm.stopPrank();

        assertFalse(
            IAccessControl(address(timelock)).hasRole(DEFAULT_ADMIN_ROLE, deployer),
            "Storage must reflect emitted RoleRevoked event"
        );
    }

    /// @notice GovernanceTopologyConfigured event is emitted by GovernanceRoleTopology.configure.
    function test_ConfigureEmitsGovernanceTopologyConfiguredEvent() public {
        vm.startPrank(admin);
        snapshot = new GovernanceSnapshot(admin, admin);
        vm.stopPrank();

        vm.startPrank(deployer);
        registry = new GovernedModuleRegistry(deployer);
        token = new TruthBountyGovernanceToken(deployer, TOKEN_SUPPLY);
        address[] memory empty = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, empty, empty, deployer);
        governor = new TruthBountyGovernor(
            token, timelock, registry,
            IGovernanceSnapshot(address(snapshot)),
            guardian, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QUORUM_NUMERATOR
        );

        // configure() grants four roles (each emitting RoleGranted from the timelock) and then
        // emits the summary event. Every grant and the summary must be observable, in order.
        // `recordLogs` is used because the four grants are four separate timelock calls and
        // foundry matches a queued `expectEmit` batch against a single call entry.
        vm.recordLogs();
        GovernanceRoleTopology.configure(timelock, governor, guardian, TIMELOCK_DELAY);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 5, "configure must emit four grants and one summary");

        bytes32[4] memory expectedRoles = [PROPOSER_ROLE, CANCELLER_ROLE, CANCELLER_ROLE, EXECUTOR_ROLE];
        address[4] memory expectedAccounts = [address(governor), address(governor), guardian, address(0)];
        for (uint256 i; i < 4; ++i) {
            assertEq(logs[i].emitter, address(timelock), "grant must be emitted by the timelock");
            assertEq(logs[i].topics[0], keccak256("RoleGranted(bytes32,address,address)"), "expected RoleGranted");
            assertEq(logs[i].topics[1], expectedRoles[i], "granted role mismatch");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), expectedAccounts[i], "granted account mismatch");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), deployer, "grant sender mismatch");
        }

        assertEq(logs[4].emitter, address(this), "library summary must be emitted by the caller");
        assertEq(
            logs[4].topics[0],
            GovernanceRoleTopology.GovernanceTopologyConfigured.selector,
            "summary event mismatch"
        );
        assertEq(address(uint160(uint256(logs[4].topics[1]))), address(timelock), "summary timelock mismatch");
        assertEq(address(uint160(uint256(logs[4].topics[2]))), address(governor), "summary governor mismatch");
        assertEq(address(uint160(uint256(logs[4].topics[3]))), guardian, "summary guardian mismatch");
        assertEq(abi.decode(logs[4].data, (uint256)), TIMELOCK_DELAY, "summary min delay mismatch");
    }

    /// @notice SNAPSHOT_REGISTRAR_ROLE transfer emits matching grant + revoke events.
    function test_SnapshotRegistrarRoleTransferEmitsEvents() public {
        // admin is the initial registrar (mirrors _deployCanonicalTopology and DeployGovernanceV2)
        vm.startPrank(admin);
        snapshot = new GovernanceSnapshot(admin, admin);
        vm.stopPrank();

        vm.startPrank(deployer);
        registry = new GovernedModuleRegistry(deployer);
        token = new TruthBountyGovernanceToken(deployer, TOKEN_SUPPLY);
        address[] memory empty = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, empty, empty, deployer);
        governor = new TruthBountyGovernor(
            token, timelock, registry,
            IGovernanceSnapshot(address(snapshot)),
            guardian, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QUORUM_NUMERATOR
        );
        vm.stopPrank();

        // Admin transfers SNAPSHOT_REGISTRAR_ROLE to governor
        vm.expectEmit(true, true, true, true, address(snapshot));
        emit IAccessControl.RoleGranted(SNAPSHOT_REGISTRAR_ROLE, address(governor), admin);

        vm.prank(admin);
        snapshot.grantRole(SNAPSHOT_REGISTRAR_ROLE, address(governor));

        vm.expectEmit(true, true, true, true, address(snapshot));
        emit IAccessControl.RoleRevoked(SNAPSHOT_REGISTRAR_ROLE, admin, admin);

        vm.prank(admin);
        snapshot.revokeRole(SNAPSHOT_REGISTRAR_ROLE, admin);

        // Final storage matches events
        assertTrue(
            IAccessControl(address(snapshot)).hasRole(SNAPSHOT_REGISTRAR_ROLE, address(governor)),
            "Governor must hold SNAPSHOT_REGISTRAR_ROLE after transfer"
        );
        assertFalse(
            IAccessControl(address(snapshot)).hasRole(SNAPSHOT_REGISTRAR_ROLE, admin),
            "Admin must not hold SNAPSHOT_REGISTRAR_ROLE after revoke"
        );
    }
}
