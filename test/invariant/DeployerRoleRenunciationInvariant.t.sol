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
 * @title DeployerRoleRenunciationHandler
 * @notice Handler contract for stateful invariant testing of V2-SC-127.
 * @dev Simulates sequences of deployment, role wiring, and renunciation operations.
 *      The invariant is: once full handoff is performed, the deployer can never hold
 *      any protocol role again through any sequence of public calls.
 */
contract DeployerRoleRenunciationHandler is Test {
    GovernedModuleRegistry public registry;
    TimelockController public timelock;
    GovernanceGuardian public guardianContract;
    TruthBountyGovernanceToken public govToken;
    TruthBountyGovernor public governor;

    address public deployer;
    address public guardian;
    bool public handoffComplete;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    bytes32 constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    constructor(
        GovernedModuleRegistry _registry,
        TimelockController _timelock,
        GovernanceGuardian _guardianContract,
        TruthBountyGovernanceToken _govToken,
        TruthBountyGovernor _governor,
        address _deployer,
        address _guardian
    ) {
        registry = _registry;
        timelock = _timelock;
        guardianContract = _guardianContract;
        govToken = _govToken;
        governor = _governor;
        deployer = _deployer;
        guardian = _guardian;
    }

    /// @notice Execute the complete handoff sequence.
    function performHandoff() external {
        if (handoffComplete) return;

        vm.startPrank(deployer);
        GovernanceRoleTopology.configure(timelock, governor, guardian, 2 days);
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, deployer);
        registry.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        registry.renounceRole(REGISTRY_ADMIN_ROLE, deployer);
        guardianContract.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        vm.stopPrank();

        handoffComplete = true;
    }

    /// @notice Attempt to re-grant DEFAULT_ADMIN_ROLE to deployer on registry.
    function attemptRegrantRegistryAdmin() external {
        if (!handoffComplete) return;
        vm.prank(deployer);
        try registry.grantRole(DEFAULT_ADMIN_ROLE, deployer) {} catch {}
    }

    /// @notice Attempt to re-grant timelock administration to deployer.
    function attemptRegrantTimelockAdmin() external {
        if (!handoffComplete) return;
        vm.prank(deployer);
        try timelock.grantRole(DEFAULT_ADMIN_ROLE, deployer) {} catch {}
        vm.prank(deployer);
        try timelock.grantRole(TIMELOCK_ADMIN_ROLE, deployer) {} catch {}
    }

    /// @notice Attempt to re-grant REGISTRY_ADMIN_ROLE to deployer.
    function attemptRegrantRegistryAdminRole() external {
        if (!handoffComplete) return;
        vm.prank(deployer);
        try registry.grantRole(REGISTRY_ADMIN_ROLE, deployer) {} catch {}
    }

    /// @notice Attempt to grant deployer any role on guardianContract.
    function attemptRegrantGuardianAdmin() external {
        if (!handoffComplete) return;
        vm.prank(deployer);
        try guardianContract.grantRole(DEFAULT_ADMIN_ROLE, deployer) {} catch {}
    }
}

/**
 * @title DeployerRoleRenunciationInvariantTest
 * @notice Stateful invariant test for V2-SC-127.
 * @dev INVARIANT: After handoff, the deployer address holds zero protocol roles on
 *      all deployment target contracts, and no sequence of calls can re-grant roles.
 */
contract DeployerRoleRenunciationInvariantTest is Test {
    DeployerRoleRenunciationHandler handler;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    address deployer = address(0xD1);
    address guardian = address(0xA1);

    GovernedModuleRegistry registry;
    TruthBountyGovernanceToken govToken;
    TimelockController timelock;
    TruthBountyGovernor governor;
    GovernanceGuardian guardianContract;

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

        handler = new DeployerRoleRenunciationHandler(
            registry, timelock, guardianContract, govToken, governor, deployer, guardian
        );

        // Perform handoff so the invariant applies
        handler.performHandoff();

        targetContract(address(handler));
    }

    /// @notice INVARIANT: deployer holds zero roles on all target contracts after handoff.
    function invariant_DeployerHoldsNoRoles() public view {
        if (!handler.handoffComplete()) return;

        address[] memory targets = new address[](4);
        targets[0] = address(registry);
        targets[1] = address(timelock);
        targets[2] = address(guardianContract);
        targets[3] = address(govToken);

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, targets);

        assertEq(violations.length, 0, "INVARIANT VIOLATED: deployer regained roles after handoff");
    }

    /// @notice INVARIANT: timelock retains self-administration capability.
    function invariant_TimelockSelfAdministered() public view {
        if (!handler.handoffComplete()) return;

        assertTrue(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)),
            "INVARIANT VIOLATED: timelock lost self-administration"
        );
        assertFalse(
            timelock.hasRole(keccak256("TIMELOCK_ADMIN_ROLE"), address(timelock)),
            "INVARIANT VIOLATED: legacy TIMELOCK_ADMIN_ROLE granted"
        );
    }

    /// @notice INVARIANT: governor retains proposer role on timelock.
    function invariant_GovernorRetainsProposerRole() public view {
        if (!handler.handoffComplete()) return;

        assertTrue(
            timelock.hasRole(keccak256("PROPOSER_ROLE"), address(governor)),
            "INVARIANT VIOLATED: governor lost proposer role"
        );
    }
}
