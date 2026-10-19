// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
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
 * @title RoleRenunciationFuzz
 * @notice Fuzz tests for V2-SC-127 — verifies deployer role checks hold for arbitrary
 *         deployer addresses, target arrays, and partial handoff orderings.
 *
 * @dev Gate B reconciliation (#690): OpenZeppelin `TimelockController >= 5.0` administers its role
 *      graph through `DEFAULT_ADMIN_ROLE`, not the retired `TIMELOCK_ADMIN_ROLE`. The handoff
 *      therefore revokes `DEFAULT_ADMIN_ROLE`; every identity fuzz below proves that only the
 *      approved governance graph survives it.
 */
contract RoleRenunciationFuzz is Test {
    GovernedModuleRegistry registry;
    TruthBountyGovernanceToken govToken;
    TimelockController timelock;
    TruthBountyGovernor governor;
    GovernanceGuardian guardianContract;

    address deployer = address(0xD1);
    address guardian = address(0xA1);

    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 internal constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant LEGACY_TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    function setUp() public {
        vm.startPrank(deployer);
        registry = new GovernedModuleRegistry(deployer);
        govToken = new TruthBountyGovernanceToken(deployer, 1_000_000_000 ether);
        address[] memory empty = new address[](0);
        timelock = new TimelockController(2 days, empty, empty, deployer);
        governor = new TruthBountyGovernor(
            IVotes(address(govToken)), timelock, registry, IGovernanceSnapshot(address(0)), guardian,
            uint48(1 days), uint32(3 days), 100_000 ether, 4
        );
        guardianContract = new GovernanceGuardian(deployer, guardian, ITruthBountyGovernor(address(governor)));
        vm.stopPrank();

        vm.prank(guardian);
        governor.setGovernanceGuardianModule(address(guardianContract));
    }

    /// @dev Mirrors `DeployGovernanceV2.s.sol`: wire topology, retire bootstrap timelock admin,
    ///      hand registry admin to the timelock, then renounce every deployer role.
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

    /// @dev Accounts that legitimately hold at least one catalog role after handoff.
    function _isApprovedHolder(address account) internal view returns (bool) {
        return account == address(governor) || account == address(timelock) || account == guardian;
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

    /**
     * @notice After handoff, any fuzzed account (EOA or contract, except approved holders) has no
     *         roles. The bootstrap deployer is deliberately NOT excluded: it must hold zero roles.
     */
    function testFuzz_ArbitraryAddress_NoRolesAfterHandoff(address account) public {
        _performFullHandoff();

        vm.assume(!_isApprovedHolder(account));
        // address(0) is the permissionless EXECUTOR_ROLE sentinel; checked separately.
        vm.assume(account != address(0));

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(account, _targets());

        assertEq(violations.length, 0, "arbitrary account should have no roles after handoff");
    }

    /// @notice Arbitrary EOAs (no code) also hold zero roles after handoff.
    function testFuzz_ArbitraryEOA_NoRolesAfterHandoff(address account) public {
        _performFullHandoff();

        vm.assume(account.code.length == 0);
        vm.assume(!_isApprovedHolder(account));
        vm.assume(account != address(0));

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(account, _targets());
        assertEq(violations.length, 0, "arbitrary EOA should have no roles after handoff");
    }

    /**
     * @notice Fuzz the account position across the deployed contracts themselves. Only the
     *         timelock may hold a role (its own `DEFAULT_ADMIN_ROLE`); every other deployed
     *         contract address holds none.
     */
    function testFuzz_DeployedContractAsAccount_OnlyApprovedRoles(uint8 seed) public {
        _performFullHandoff();

        address[] memory accounts = new address[](4);
        accounts[0] = address(registry);
        accounts[1] = address(guardianContract);
        accounts[2] = address(govToken);
        accounts[3] = address(timelock);

        address account = accounts[seed % accounts.length];
        vm.assume(account != address(timelock));

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(account, _targets());
        assertEq(violations.length, 0, "deployed non-timelock contract should hold no roles");
    }

    /**
     * @notice Fuzz proposer / executor / canceller identities: whichever identity is selected,
     *         the graph after handoff contains exactly the approved edges and nothing else.
     */
    function testFuzz_ProposerExecutorCancellerIdentities_ApprovedGraph(uint8 identitySeed) public {
        _performFullHandoff();

        address[4] memory identities = [address(governor), address(0), guardian, deployer];
        address identity = identities[identitySeed % identities.length];

        address[] memory accounts = new address[](1);
        accounts[0] = identity;

        PostDeploymentRoleCheck.RoleGrant[] memory graph =
            PostDeploymentRoleCheck.roleGraph(accounts, _targets());

        if (identity == deployer) {
            assertEq(graph.length, 0, "deployer must hold no role edges after handoff");
            return;
        }

        // An approved identity must actually carry its approved edges; an empty graph would
        // otherwise make the loop below vacuously pass.
        assertGt(graph.length, 0, "approved identity must hold at least one role edge");

        for (uint256 i; i < graph.length; ++i) {
            assertTrue(
                _isApprovedEdge(identity, graph[i].target, graph[i].role),
                "identity holds an unapproved role edge after handoff"
            );
        }
    }

    /// @notice Address zero holds exactly one role after handoff: the EXECUTOR_ROLE sentinel.
    function testFuzz_ZeroAddress_OnlyExecutorSentinel(address unrelated) public {
        _performFullHandoff();

        address[] memory accounts = new address[](1);
        accounts[0] = address(0);

        PostDeploymentRoleCheck.RoleGrant[] memory graph =
            PostDeploymentRoleCheck.roleGraph(accounts, _targets());

        assertEq(graph.length, 1, "address(0) must hold exactly one role");
        assertEq(graph[0].role, EXECUTOR_ROLE, "address(0) sentinel must be EXECUTOR_ROLE");
        assertEq(graph[0].target, address(timelock), "address(0) sentinel must live on the timelock");

        // Unrelated accounts never inherit the sentinel.
        vm.assume(unrelated != address(0));
        assertFalse(PostDeploymentRoleCheck.safeCheckRole(address(timelock), EXECUTOR_ROLE, unrelated));
    }

    /// @notice The role graph only shrinks for the deployer: no edge it holds pre-handoff survives.
    function testFuzz_RoleGraphSnapshot_DeployerShrinksToZero(uint256) public {
        address[] memory accounts = new address[](1);
        accounts[0] = deployer;

        PostDeploymentRoleCheck.RoleGrant[] memory before =
            PostDeploymentRoleCheck.roleGraph(accounts, _targets());
        assertGt(before.length, 0, "deployer must hold bootstrap roles before handoff");

        _performFullHandoff();

        PostDeploymentRoleCheck.RoleGrant[] memory afterGraph =
            PostDeploymentRoleCheck.roleGraph(accounts, _targets());
        assertEq(afterGraph.length, 0, "deployer role graph must be empty after handoff");
    }

    /// @notice Before handoff, deployer violations count is consistent across calls.
    function testFuzz_ViolationCount_Consistent(uint8 callCount) public view {
        vm.assume(callCount > 0 && callCount <= 10);

        uint256 firstCount;
        for (uint256 i; i < callCount; ++i) {
            PostDeploymentRoleCheck.RoleViolation[] memory v =
                PostDeploymentRoleCheck.checkAllRoles(deployer, _targets());
            if (i == 0) {
                firstCount = v.length;
            } else {
                assertEq(v.length, firstCount, "violation count should be deterministic");
            }
        }
    }

    /// @notice roleCatalog always returns ROLE_CATALOG_SIZE entries.
    function testFuzz_RoleCatalogSize_Invariant(uint256) public pure {
        bytes32[] memory roles = PostDeploymentRoleCheck.roleCatalog();
        assertEq(roles.length, PostDeploymentRoleCheck.ROLE_CATALOG_SIZE);
    }

    /// @notice safeCheckRole on an arbitrary address with no code returns false.
    function testFuzz_SafeCheckRole_NoCode(address target, bytes32 role) public view {
        vm.assume(target.code.length == 0);
        assertFalse(PostDeploymentRoleCheck.safeCheckRole(target, role, deployer));
    }

    /// @notice Empty targets array always produces zero violations regardless of deployer.
    function testFuzz_EmptyTargets_ZeroViolations(address account) public view {
        address[] memory empty = new address[](0);
        PostDeploymentRoleCheck.RoleViolation[] memory v =
            PostDeploymentRoleCheck.checkAllRoles(account, empty);
        assertEq(v.length, 0);
    }

    /// @notice Targets array filled with zero addresses produces zero violations.
    function testFuzz_ZeroAddressTargets_ZeroViolations(uint8 size) public view {
        vm.assume(size > 0 && size <= 20);
        address[] memory targets = new address[](size);
        // All entries are address(0) by default
        PostDeploymentRoleCheck.RoleViolation[] memory v =
            PostDeploymentRoleCheck.checkAllRoles(address(0xD1), targets);
        assertEq(v.length, 0);
    }

    /// @notice Legacy `TIMELOCK_ADMIN_ROLE` is never granted: it is absent for every identity.
    function testFuzz_LegacyTimelockAdminRole_NeverGranted(address account) public {
        _performFullHandoff();
        assertFalse(
            PostDeploymentRoleCheck.safeCheckRole(address(timelock), LEGACY_TIMELOCK_ADMIN_ROLE, account),
            "legacy TIMELOCK_ADMIN_ROLE must never be granted"
        );
    }
}
