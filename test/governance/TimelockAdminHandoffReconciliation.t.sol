// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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
 * @title TimelockAdminHandoffReconciliation
 * @notice Gate B (#690) regression + conformance suite for the timelock administration handoff.
 *
 * @dev OpenZeppelin `TimelockController >= 5.0` administers its role graph with
 *      `DEFAULT_ADMIN_ROLE` (0x00); the retired `TIMELOCK_ADMIN_ROLE` is a phantom that must never
 *      be granted. Before this reconciliation the handoff only moved the phantom role, leaving the
 *      bootstrap deployer as a permanent `DEFAULT_ADMIN_ROLE` holder on the timelock — residual,
 *      privileged authority and the direct cause of `testFuzz_ArbitraryAddress_NoRolesAfterHandoff`.
 *
 *      This suite proves:
 *        - the exact role graph before and after handoff (snapshot comparison);
 *        - the approved timelock/governor graph is machine-verifiable via `checkExpectations`;
 *        - arbitrary EOAs, deployed contracts, proposer/executor/canceller identities and the zero
 *          address never carry unintended authority;
 *        - legacy and duplicate grants are impossible or inert.
 */
contract TimelockAdminHandoffReconciliationTest is Test {
    GovernedModuleRegistry internal registry;
    TruthBountyGovernanceToken internal govToken;
    TimelockController internal timelock;
    TruthBountyGovernor internal governor;
    GovernanceGuardian internal guardianContract;

    address internal deployer = address(0xD1);
    address internal guardian = address(0xA1);

    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 internal constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant LEGACY_TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    // AccessControl event topic0 hashes (OpenZeppelin 5.x signatures).
    bytes32 internal constant ROLE_GRANTED = keccak256("RoleGranted(bytes32,address,address)");
    bytes32 internal constant ROLE_REVOKED = keccak256("RoleRevoked(bytes32,address,address)");

    function setUp() public {
        vm.startPrank(deployer);
        registry = new GovernedModuleRegistry(deployer);
        govToken = new TruthBountyGovernanceToken(deployer, 1_000_000_000 ether);
        address[] memory empty = new address[](0);
        timelock = new TimelockController(2 days, empty, empty, deployer);
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
        guardianContract = new GovernanceGuardian(deployer, guardian, ITruthBountyGovernor(address(governor)));
        vm.stopPrank();

        vm.prank(guardian);
        governor.setGovernanceGuardianModule(address(guardianContract));
    }

    /// @dev Mirrors `DeployGovernanceV2.s.sol` and `_performFullHandoff` in the deployment/fuzz
    ///      fixtures: wire topology, retire the bootstrap timelock admin, hand registry admin to
    ///      the timelock, then renounce every deployer role.
    function _performFullHandoff() internal {
        vm.startPrank(deployer);
        GovernanceRoleTopology.configure(timelock, governor, guardian, 2 days);
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);
        registry.grantRole(REGISTRY_ADMIN_ROLE, address(timelock));
        registry.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        registry.renounceRole(REGISTRY_ADMIN_ROLE, deployer);
        guardianContract.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        vm.stopPrank();
    }

    function _targets() internal view returns (address[] memory t) {
        t = new address[](4);
        t[0] = address(registry);
        t[1] = address(timelock);
        t[2] = address(guardianContract);
        t[3] = address(govToken);
    }

    function _allAccounts() internal view returns (address[] memory a) {
        a = new address[](8);
        a[0] = deployer;
        a[1] = guardian;
        a[2] = address(0);
        a[3] = address(governor);
        a[4] = address(timelock);
        a[5] = address(registry);
        a[6] = address(guardianContract);
        a[7] = address(govToken);
    }

    function _contains(
        PostDeploymentRoleCheck.RoleGrant[] memory graph,
        address account,
        address target,
        bytes32 role
    ) internal pure returns (bool) {
        for (uint256 i; i < graph.length; ++i) {
            if (graph[i].account == account && graph[i].target == target && graph[i].role == role) {
                return true;
            }
        }
        return false;
    }

    function _topicAddress(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }

    /// @dev The exact role edges the approved governance graph may contain for `account`.
    function _isApprovedEdge(address account, address target, bytes32 role) internal view returns (bool) {
        if (account == address(governor)) {
            return target == address(timelock) && (role == PROPOSER_ROLE || role == CANCELLER_ROLE);
        }
        if (account == address(timelock)) {
            return (target == address(timelock) && role == DEFAULT_ADMIN_ROLE) ||
                (target == address(registry) && role == REGISTRY_ADMIN_ROLE);
        }
        if (account == guardian) {
            return (target == address(timelock) && role == CANCELLER_ROLE) ||
                (target == address(guardianContract) && role == GUARDIAN_ROLE);
        }
        if (account == address(0)) {
            return target == address(timelock) && role == EXECUTOR_ROLE;
        }
        return false;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Role-graph snapshots
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Before handoff the deployer anchors the bootstrap graph.
    function test_RoleGraph_BeforeHandoff_ContainsDeployerAuthority() public view {
        PostDeploymentRoleCheck.RoleGrant[] memory graph =
            PostDeploymentRoleCheck.roleGraph(_allAccounts(), _targets());

        assertTrue(_contains(graph, deployer, address(timelock), DEFAULT_ADMIN_ROLE), "pre: deployer timelock admin");
        assertTrue(_contains(graph, deployer, address(registry), DEFAULT_ADMIN_ROLE), "pre: deployer registry admin");
        assertTrue(_contains(graph, deployer, address(registry), REGISTRY_ADMIN_ROLE), "pre: deployer registry updater");
        assertTrue(
            _contains(graph, deployer, address(guardianContract), DEFAULT_ADMIN_ROLE),
            "pre: deployer guardian admin"
        );
    }

    /// @notice After handoff the graph is exactly the approved governance topology.
    function test_RoleGraph_AfterHandoff_ExactlyApprovedGraph() public {
        _performFullHandoff();

        PostDeploymentRoleCheck.RoleGrant[] memory graph =
            PostDeploymentRoleCheck.roleGraph(_allAccounts(), _targets());

        assertEq(graph.length, 7, "post-handoff graph must contain exactly the approved edges");

        assertTrue(_contains(graph, address(timelock), address(timelock), DEFAULT_ADMIN_ROLE), "timelock self-admin");
        assertTrue(_contains(graph, address(governor), address(timelock), PROPOSER_ROLE), "governor proposer");
        assertTrue(_contains(graph, address(governor), address(timelock), CANCELLER_ROLE), "governor canceller");
        assertTrue(_contains(graph, guardian, address(timelock), CANCELLER_ROLE), "guardian canceller");
        assertTrue(_contains(graph, address(0), address(timelock), EXECUTOR_ROLE), "permissionless executor");
        assertTrue(_contains(graph, guardian, address(guardianContract), GUARDIAN_ROLE), "guardian role");
        assertTrue(
            _contains(graph, address(timelock), address(registry), REGISTRY_ADMIN_ROLE),
            "timelock registry admin"
        );

        assertFalse(_contains(graph, deployer, address(timelock), DEFAULT_ADMIN_ROLE), "no deployer timelock admin");
        assertFalse(_contains(graph, deployer, address(registry), REGISTRY_ADMIN_ROLE), "no deployer registry role");
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Machine-verifiable expected timelock / governor roles
    // ════════════════════════════════════════════════════════════════════════

    function test_ExpectedGovernanceGraph_MachineVerifiable() public {
        _performFullHandoff();

        PostDeploymentRoleCheck.RoleExpectation[] memory expectations =
            new PostDeploymentRoleCheck.RoleExpectation[](12);
        // Approved graph (must hold).
        expectations[0] = _expect(address(timelock), DEFAULT_ADMIN_ROLE, address(timelock), true);
        expectations[1] = _expect(address(timelock), PROPOSER_ROLE, address(governor), true);
        expectations[2] = _expect(address(timelock), CANCELLER_ROLE, address(governor), true);
        expectations[3] = _expect(address(timelock), CANCELLER_ROLE, guardian, true);
        expectations[4] = _expect(address(timelock), EXECUTOR_ROLE, address(0), true);
        expectations[5] = _expect(address(guardianContract), GUARDIAN_ROLE, guardian, true);
        expectations[6] = _expect(address(registry), REGISTRY_ADMIN_ROLE, address(timelock), true);
        // Prohibited residual authority (must not hold).
        expectations[7] = _expect(address(timelock), DEFAULT_ADMIN_ROLE, deployer, false);
        expectations[8] = _expect(address(timelock), LEGACY_TIMELOCK_ADMIN_ROLE, address(timelock), false);
        expectations[9] = _expect(address(registry), REGISTRY_ADMIN_ROLE, deployer, false);
        expectations[10] = _expect(address(registry), DEFAULT_ADMIN_ROLE, deployer, false);
        expectations[11] = _expect(address(guardianContract), DEFAULT_ADMIN_ROLE, deployer, false);

        PostDeploymentRoleCheck.RoleExpectation[] memory violations =
            PostDeploymentRoleCheck.checkExpectations(expectations);
        assertEq(violations.length, 0, "approved governance graph not satisfied");
    }

    function _expect(
        address target,
        bytes32 role,
        address account,
        bool shouldHold
    ) internal pure returns (PostDeploymentRoleCheck.RoleExpectation memory) {
        return PostDeploymentRoleCheck.RoleExpectation({
            target: target,
            role: role,
            account: account,
            shouldHold: shouldHold
        });
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Fuzz — arbitrary accounts, contracts, identities, zero address
    // ════════════════════════════════════════════════════════════════════════

    function testFuzz_ArbitraryAccount_HoldsNoRoleAfterHandoff(address account) public {
        _performFullHandoff();

        vm.assume(account != address(governor));
        vm.assume(account != address(timelock));
        vm.assume(account != guardian);
        vm.assume(account != address(0));

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(account, _targets());
        assertEq(violations.length, 0, "arbitrary account retained a role");
    }

    function testFuzz_DeployedContract_HoldsNoUnintendedRole(uint8 which) public {
        _performFullHandoff();

        address[] memory contracts = new address[](3);
        contracts[0] = address(registry);
        contracts[1] = address(guardianContract);
        contracts[2] = address(govToken);

        address account = contracts[which % contracts.length];
        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(account, _targets());
        assertEq(violations.length, 0, "deployed non-timelock contract retained a role");
    }

    /// @notice Whichever proposer/executor/canceller identity the seed selects, the identity holds
    ///         only approved edges — and an approved identity is never silently empty.
    function testFuzz_Identity_OnlyApprovedRoleSet(uint8 seed) public {
        _performFullHandoff();

        address[5] memory identities = [address(governor), address(timelock), guardian, address(0), deployer];
        address who = identities[seed % identities.length];

        address[] memory accounts = new address[](1);
        accounts[0] = who;

        PostDeploymentRoleCheck.RoleGrant[] memory graph =
            PostDeploymentRoleCheck.roleGraph(accounts, _targets());

        if (who == deployer) {
            assertEq(graph.length, 0, "deployer retained a role after handoff");
            return;
        }

        assertGt(graph.length, 0, "approved identity must hold at least one role edge");
        for (uint256 i; i < graph.length; ++i) {
            assertTrue(
                _isApprovedEdge(who, graph[i].target, graph[i].role),
                "identity holds an unapproved role edge after handoff"
            );
        }
    }

    function testFuzz_ZeroAddress_OnlyExecutorSentinel(address unrelated) public {
        _performFullHandoff();

        assertTrue(timelock.hasRole(EXECUTOR_ROLE, address(0)), "zero address sentinel missing");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, address(0)), "zero address held timelock admin");
        assertFalse(timelock.hasRole(PROPOSER_ROLE, address(0)), "zero address held proposer");

        vm.assume(unrelated != address(0));
        assertFalse(
            PostDeploymentRoleCheck.safeCheckRole(address(timelock), EXECUTOR_ROLE, unrelated),
            "sentinel leaked to a non-zero account"
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Negative — legacy and duplicate grants
    // ════════════════════════════════════════════════════════════════════════

    /// @notice The handoff never grants the retired legacy administration role.
    function test_Negative_LegacyTimelockAdminRole_NeverGranted() public {
        _performFullHandoff();

        assertFalse(timelock.hasRole(LEGACY_TIMELOCK_ADMIN_ROLE, address(timelock)), "legacy granted to timelock");
        assertFalse(timelock.hasRole(LEGACY_TIMELOCK_ADMIN_ROLE, deployer), "legacy granted to deployer");
        assertFalse(timelock.hasRole(LEGACY_TIMELOCK_ADMIN_ROLE, guardian), "legacy granted to guardian");
    }

    /// @notice A stale legacy grant is retired by the handoff and reported in the event.
    function test_Negative_LegacyGrant_RetiredDuringHandoff() public {
        // Simulate a pre-v5 deployment that still carries a TIMELOCK_ADMIN_ROLE grant for the admin.
        vm.prank(deployer);
        timelock.grantRole(LEGACY_TIMELOCK_ADMIN_ROLE, deployer);
        assertTrue(timelock.hasRole(LEGACY_TIMELOCK_ADMIN_ROLE, deployer), "setup: legacy grant missing");

        // finalizeTimelockAdmin retires the legacy grant, then the canonical admin, then emits the summary.
        // `recordLogs` is used instead of a chained `expectEmit`: the two revocations come from two
        // separate timelock calls, and foundry matches a queued batch of expectations against a
        // single call entry. `startPrank` is required because the internal `hasRole` probe consumes
        // a one-shot `prank` before `revokeRole` runs.
        vm.startPrank(deployer);
        vm.recordLogs();
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3, "handoff must emit two revocations and one summary");

        assertEq(logs[0].emitter, address(timelock), "legacy revocation must come from the timelock");
        assertEq(logs[0].topics[0], ROLE_REVOKED, "first event must be RoleRevoked");
        assertEq(logs[0].topics[1], LEGACY_TIMELOCK_ADMIN_ROLE, "legacy revocation role mismatch");
        assertEq(_topicAddress(logs[0].topics[2]), deployer, "legacy revocation account mismatch");

        assertEq(logs[1].emitter, address(timelock), "canonical revocation must come from the timelock");
        assertEq(logs[1].topics[0], ROLE_REVOKED, "second event must be RoleRevoked");
        assertEq(logs[1].topics[1], DEFAULT_ADMIN_ROLE, "canonical revocation role mismatch");
        assertEq(_topicAddress(logs[1].topics[2]), deployer, "canonical revocation account mismatch");

        assertEq(logs[2].emitter, address(this), "library summary must be emitted by the caller");
        assertEq(logs[2].topics[0], GovernanceRoleTopology.TimelockAdminFinalized.selector, "summary event mismatch");
        assertEq(_topicAddress(logs[2].topics[1]), address(timelock), "summary timelock mismatch");
        assertEq(_topicAddress(logs[2].topics[2]), deployer, "summary retired admin mismatch");
        assertTrue(abi.decode(logs[2].data, (bool)), "legacyRoleRetired must report the retired grant");

        assertFalse(timelock.hasRole(LEGACY_TIMELOCK_ADMIN_ROLE, deployer), "legacy grant survived handoff");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer), "canonical admin survived handoff");
    }

    /// @notice Duplicate grants of an already-held role add no new holder and emit nothing.
    function test_Negative_DuplicateGrant_IsInert() public {
        _performFullHandoff();

        PostDeploymentRoleCheck.RoleGrant[] memory before =
            PostDeploymentRoleCheck.roleGraph(_allAccounts(), _targets());

        // Re-grant roles the timelock already holds, from the timelock itself.
        vm.startPrank(address(timelock));
        timelock.grantRole(DEFAULT_ADMIN_ROLE, address(timelock));
        timelock.grantRole(PROPOSER_ROLE, address(governor));
        timelock.grantRole(EXECUTOR_ROLE, address(0));
        vm.stopPrank();

        PostDeploymentRoleCheck.RoleGrant[] memory afterGraph =
            PostDeploymentRoleCheck.roleGraph(_allAccounts(), _targets());

        assertEq(afterGraph.length, before.length, "duplicate grant changed the role graph");
        for (uint256 i; i < before.length; ++i) {
            assertTrue(
                _contains(afterGraph, before[i].account, before[i].target, before[i].role),
                "duplicate grant altered an existing edge"
            );
        }
    }

    /// @notice The deployer cannot re-acquire timelock administration after handoff.
    function test_Negative_DeployerCannotReacquireTimelockAdmin() public {
        _performFullHandoff();

        vm.prank(deployer);
        vm.expectRevert();
        timelock.grantRole(DEFAULT_ADMIN_ROLE, deployer);
    }

    /// @notice Finalization can never strip the timelock's own self-administration.
    function test_Negative_FinalizationCannotStripSelfAdministration() public {
        _performFullHandoff();

        vm.prank(address(timelock));
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, address(timelock));

        assertTrue(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)),
            "timelock lost self-administration"
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Events — every grant and revocation is observable
    // ════════════════════════════════════════════════════════════════════════

    /// @notice The handoff revocation and its library summary are both observable, in order.
    function test_Handoff_EmitsRevocationAndFinalization() public {
        vm.startPrank(deployer);
        GovernanceRoleTopology.configure(timelock, governor, guardian, 2 days);

        vm.recordLogs();
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "handoff must emit one revocation and one summary");

        assertEq(logs[0].emitter, address(timelock), "revocation must come from the timelock");
        assertEq(logs[0].topics[0], ROLE_REVOKED, "first event must be RoleRevoked");
        assertEq(logs[0].topics[1], DEFAULT_ADMIN_ROLE, "revoked role mismatch");
        assertEq(_topicAddress(logs[0].topics[2]), deployer, "revoked account mismatch");
        assertEq(_topicAddress(logs[0].topics[3]), deployer, "revocation sender mismatch");

        assertEq(logs[1].emitter, address(this), "library summary must be emitted by the caller");
        assertEq(logs[1].topics[0], GovernanceRoleTopology.TimelockAdminFinalized.selector, "summary event mismatch");
        assertEq(_topicAddress(logs[1].topics[1]), address(timelock), "summary timelock mismatch");
        assertEq(_topicAddress(logs[1].topics[2]), deployer, "summary retired admin mismatch");
        assertFalse(abi.decode(logs[1].data, (bool)), "no legacy grant should be reported");
    }
}
