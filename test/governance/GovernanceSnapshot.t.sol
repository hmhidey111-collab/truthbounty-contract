// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {GovernanceSnapshot} from "../../contracts/governance/v2/GovernanceSnapshot.sol";
import {IGovernanceSnapshot} from "../../contracts/governance/v2/IGovernanceSnapshot.sol";
import {GovernedModuleRegistry} from "../../contracts/governance/v2/GovernedModuleRegistry.sol";
import {TruthBountyGovernanceToken} from "../../contracts/governance/v2/TruthBountyGovernanceToken.sol";
import {TruthBountyGovernor} from "../../contracts/governance/v2/TruthBountyGovernor.sol";
import {GovernanceGuardian} from "../../contracts/governance/v2/GovernanceGuardian.sol";
import {ITruthBountyGovernor} from "../../contracts/governance/v2/ITruthBountyGovernor.sol";
import {GovernanceRoleTopology} from "../../contracts/governance/v2/GovernanceRoleTopology.sol";
import {MockGovernedModule} from "../../contracts/mocks/MockGovernedModule.sol";

// ============================================================================
// Isolated GovernanceSnapshot unit tests
// ============================================================================

contract GovernanceSnapshotTest is Test {
    GovernanceSnapshot internal snapshot;

    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");
    address internal stranger = makeAddr("stranger");

    event SnapshotRegistered(uint256 indexed proposalId, uint48 indexed snapshotTimestamp, address indexed registrar);

    function setUp() public {
        snapshot = new GovernanceSnapshot(admin, registrar);
    }

    // -------------------------------------------------------------------------
    // Construction / Role assignment
    // -------------------------------------------------------------------------

    function test_AdminReceivesDefaultAdminRole() public view {
        assertTrue(snapshot.hasRole(snapshot.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_RegistrarReceivesSnapshotRegistrarRole() public view {
        bytes32 role = snapshot.SNAPSHOT_REGISTRAR_ROLE();
        assertTrue(snapshot.hasRole(role, registrar));
    }

    function test_StrangerHasNoRoles() public view {
        bytes32 regRole = snapshot.SNAPSHOT_REGISTRAR_ROLE();
        assertFalse(snapshot.hasRole(regRole, stranger));
        assertFalse(snapshot.hasRole(snapshot.DEFAULT_ADMIN_ROLE(), stranger));
    }

    function test_ZeroAdminRevertsConstruction() public {
        vm.expectRevert();
        new GovernanceSnapshot(address(0), registrar);
    }

    function test_ZeroRegistrarRevertsConstruction() public {
        vm.expectRevert();
        new GovernanceSnapshot(admin, address(0));
    }

    // -------------------------------------------------------------------------
    // registerSnapshot — success path
    // -------------------------------------------------------------------------

    function test_RegisterSnapshot_StoresGivenTimestamp() public {
        uint256 proposalId = 1;
        uint48 ts = 12345;

        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, ts);

        assertEq(snapshot.getSnapshotTimestamp(proposalId), ts);
    }

    function test_RegisterSnapshot_SetsHasSnapshot() public {
        vm.prank(registrar);
        snapshot.registerSnapshot(42, 1000);

        assertTrue(snapshot.hasSnapshot(42));
    }

    function test_RegisterSnapshot_EmitsEvent() public {
        uint256 proposalId = 7;
        uint48 ts = 9999;

        vm.expectEmit(true, true, true, true);
        emit SnapshotRegistered(proposalId, ts, registrar);

        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, ts);
    }

    function test_RegisterSnapshot_MultipleDistinctProposals() public {
        vm.prank(registrar);
        snapshot.registerSnapshot(1, 100);
        vm.prank(registrar);
        snapshot.registerSnapshot(2, 200);

        assertEq(snapshot.getSnapshotTimestamp(1), 100);
        assertEq(snapshot.getSnapshotTimestamp(2), 200);
    }

    function test_RegisterSnapshot_MaxUint256ProposalId() public {
        uint256 maxId = type(uint256).max;
        vm.prank(registrar);
        snapshot.registerSnapshot(maxId, 1000);
        assertTrue(snapshot.hasSnapshot(maxId));
    }

    function test_RegisterSnapshot_MaxUint48Timestamp() public {
        uint256 proposalId = 99;
        uint48 maxTs = type(uint48).max;

        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, maxTs);

        assertEq(snapshot.getSnapshotTimestamp(proposalId), maxTs);
    }

    // -------------------------------------------------------------------------
    // registerSnapshot — authorization failures
    // -------------------------------------------------------------------------

    function test_RegisterSnapshot_RevertsIfCallerLacksRole() public {
        bytes32 role = snapshot.SNAPSHOT_REGISTRAR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        vm.prank(stranger);
        snapshot.registerSnapshot(1, 1000);
    }

    function test_RegisterSnapshot_RevertsIfAdminCallsDirectly() public {
        bytes32 role = snapshot.SNAPSHOT_REGISTRAR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role)
        );
        vm.prank(admin);
        snapshot.registerSnapshot(1, 1000);
    }

    // -------------------------------------------------------------------------
    // registerSnapshot — input validation failures
    // -------------------------------------------------------------------------

    function test_RegisterSnapshot_RevertsOnZeroProposalId() public {
        vm.expectRevert(IGovernanceSnapshot.InvalidProposalId.selector);
        vm.prank(registrar);
        snapshot.registerSnapshot(0, 1000);
    }

    function test_RegisterSnapshot_RevertsOnZeroTimestamp() public {
        vm.expectRevert(IGovernanceSnapshot.InvalidSnapshotTimestamp.selector);
        vm.prank(registrar);
        snapshot.registerSnapshot(1, 0);
    }

    function test_RegisterSnapshot_RevertsOnDuplicateProposalId() public {
        vm.prank(registrar);
        snapshot.registerSnapshot(5, 1000);

        vm.expectRevert(abi.encodeWithSelector(IGovernanceSnapshot.SnapshotAlreadyRegistered.selector, uint256(5)));
        vm.prank(registrar);
        snapshot.registerSnapshot(5, 2000);
    }

    // -------------------------------------------------------------------------
    // getSnapshotTimestamp — failure paths
    // -------------------------------------------------------------------------

    function test_GetSnapshotTimestamp_RevertsIfNoSnapshot() public {
        vm.expectRevert(abi.encodeWithSelector(IGovernanceSnapshot.SnapshotNotFound.selector, uint256(999)));
        snapshot.getSnapshotTimestamp(999);
    }

    function test_GetSnapshotTimestamp_RevertsForZeroId() public {
        vm.expectRevert(abi.encodeWithSelector(IGovernanceSnapshot.SnapshotNotFound.selector, uint256(0)));
        snapshot.getSnapshotTimestamp(0);
    }

    // -------------------------------------------------------------------------
    // hasSnapshot — all paths
    // -------------------------------------------------------------------------

    function test_HasSnapshot_FalseBeforeRegister() public view {
        assertFalse(snapshot.hasSnapshot(1));
    }

    function test_HasSnapshot_TrueAfterRegister() public {
        vm.prank(registrar);
        snapshot.registerSnapshot(1, 5000);
        assertTrue(snapshot.hasSnapshot(1));
    }

    function test_HasSnapshot_ZeroIdReturnsFalse() public view {
        assertFalse(snapshot.hasSnapshot(0));
    }

    // -------------------------------------------------------------------------
    // Role management (admin grants/revokes)
    // -------------------------------------------------------------------------

    function test_AdminCanGrantRegistrarRole() public {
        address newRegistrar = makeAddr("newRegistrar");
        bytes32 role = snapshot.SNAPSHOT_REGISTRAR_ROLE();
        vm.prank(admin);
        snapshot.grantRole(role, newRegistrar);

        assertTrue(snapshot.hasRole(role, newRegistrar));

        vm.prank(newRegistrar);
        snapshot.registerSnapshot(10, 1000);
        assertTrue(snapshot.hasSnapshot(10));
    }

    function test_AdminCanRevokeRegistrarRole() public {
        bytes32 role = snapshot.SNAPSHOT_REGISTRAR_ROLE();
        vm.prank(admin);
        snapshot.revokeRole(role, registrar);

        assertFalse(snapshot.hasRole(role, registrar));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, registrar, role)
        );
        vm.prank(registrar);
        snapshot.registerSnapshot(1, 1000);
    }

    // -------------------------------------------------------------------------
    // Immutability: snapshot value cannot be changed after registration
    // -------------------------------------------------------------------------

    function test_SnapshotValueIsImmutableAfterRegistration() public {
        uint256 proposalId = 1;
        uint48 originalTs = 1000;

        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, originalTs);

        // Second registration attempt must revert
        vm.expectRevert(abi.encodeWithSelector(IGovernanceSnapshot.SnapshotAlreadyRegistered.selector, proposalId));
        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, 999999);

        // Value is still the original timestamp
        assertEq(snapshot.getSnapshotTimestamp(proposalId), originalTs);
    }
}

// ============================================================================
// Integration: GovernanceSnapshot wired into TruthBountyGovernor
// ============================================================================

contract GovernanceSnapshotIntegrationTest is Test {
    uint48 internal constant VOTING_DELAY = 1;
    uint32 internal constant VOTING_PERIOD = 100;
    uint256 internal constant TIMELOCK_DELAY = 1 days;
    uint256 internal constant QUORUM_NUMERATOR = 4;
    uint256 internal constant TOKEN_SUPPLY = 1_000_000 ether;

    TruthBountyGovernanceToken internal token;
    GovernedModuleRegistry internal registry;
    TimelockController internal timelock;
    GovernanceSnapshot internal snapshot;
    TruthBountyGovernor internal governor;
    GovernanceGuardian internal guardianContract;
    MockGovernedModule internal module;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal voter = makeAddr("voter");
    address internal proposer = makeAddr("proposer");

    function setUp() public {
        vm.startPrank(admin);

        registry = new GovernedModuleRegistry(admin);
        token = new TruthBountyGovernanceToken(admin, TOKEN_SUPPLY);
        // Distribute 200K to proposer, 700K to voter; admin retains 100K for later operations
        // (e.g. test_VotingPowerFrozenAtSnapshot_DelegationAfterProposalDoesNotHelp)
        token.transfer(proposer, 200_000 ether);
        token.transfer(voter, 700_000 ether);
        // admin holds the remaining 100_000 ether

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, admin);

        snapshot = new GovernanceSnapshot(admin, admin);

        governor = new TruthBountyGovernor(
            token,
            timelock,
            registry,
            IGovernanceSnapshot(address(snapshot)),
            guardian,
            VOTING_DELAY,
            VOTING_PERIOD,
            100_000 ether,
            QUORUM_NUMERATOR
        );

        bytes32 registrarRole = snapshot.SNAPSHOT_REGISTRAR_ROLE();
        snapshot.grantRole(registrarRole, address(governor));
        snapshot.revokeRole(registrarRole, admin);

        guardianContract = new GovernanceGuardian(admin, guardian, ITruthBountyGovernor(address(governor)));
        GovernanceRoleTopology.configure(timelock, governor, guardian, TIMELOCK_DELAY);
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, admin);
        bytes32 registryAdminRole = registry.REGISTRY_ADMIN_ROLE();
        registry.grantRole(registryAdminRole, address(timelock));

        module = new MockGovernedModule();
        registry.registerModule("MOCK_MODULE", address(module));

        vm.stopPrank();

        vm.prank(guardian);
        governor.setGovernanceGuardianModule(address(guardianContract));

        vm.prank(proposer);
        token.delegate(proposer);
        vm.prank(voter);
        token.delegate(voter);

        // Warp so delegation is in the past (getPastVotes works)
        vm.warp(block.timestamp + 2);
    }

    function _proposalCalldata(uint256 value) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockGovernedModule.setValue.selector, value);
    }

    function _buildProposal(uint256 value)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(module);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = _proposalCalldata(value);
    }

    // -------------------------------------------------------------------------
    // Snapshot is registered automatically on propose
    // -------------------------------------------------------------------------

    function test_ProposeRegistersSnapshot() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildProposal(1);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, "test");

        assertTrue(snapshot.hasSnapshot(proposalId));
        assertEq(snapshot.getSnapshotTimestamp(proposalId), governor.proposalSnapshot(proposalId));
    }

    function test_SnapshotMatchesGovernorProposalSnapshot() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildProposal(1);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, "test");

        // OZ governor proposalSnapshot returns clock() + votingDelay at proposal creation
        uint256 govSnapshot = governor.proposalSnapshot(proposalId);
        uint48 canonicalSnapshot = snapshot.getSnapshotTimestamp(proposalId);

        assertEq(govSnapshot, canonicalSnapshot);
    }

    function test_MultipleProposalsHaveDistinctSnapshots() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildProposal(1);

        vm.warp(1000);
        vm.prank(proposer);
        uint256 proposalId1 = governor.propose(targets, values, calldatas, "proposal 1");

        vm.warp(2000);
        vm.prank(proposer);
        uint256 proposalId2 = governor.propose(targets, values, calldatas, "proposal 2");

        // Each snapshot is clock() + votingDelay at proposal creation
        assertEq(snapshot.getSnapshotTimestamp(proposalId1), governor.proposalSnapshot(proposalId1));
        assertEq(snapshot.getSnapshotTimestamp(proposalId2), governor.proposalSnapshot(proposalId2));
        assertTrue(snapshot.getSnapshotTimestamp(proposalId1) < snapshot.getSnapshotTimestamp(proposalId2));
        assertTrue(proposalId1 != proposalId2);
    }

    // -------------------------------------------------------------------------
    // Voting power is frozen at snapshot: post-proposal token changes don't matter
    // -------------------------------------------------------------------------

    function test_VotingPowerFrozenAtSnapshot_TransferAfterProposalDoesNotHelp() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildProposal(1);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, "test");

        uint48 snapshotTs = snapshot.getSnapshotTimestamp(proposalId);

        // Advance past snapshot, then proposer sends tokens to voter
        vm.warp(snapshotTs + 1);
        vm.prank(proposer);
        token.transfer(voter, 200_000 ether);

        // Voter's historical balance at the snapshot timestamp is still 800_000
        uint256 votingPower = token.getPastVotes(voter, snapshotTs);
        assertEq(votingPower, 800_000 ether);
    }

    function test_VotingPowerFrozenAtSnapshot_DelegationAfterProposalDoesNotHelp() public {
        address newDelegatee = makeAddr("newDelegatee");

        // Give newDelegatee tokens and delegate BEFORE proposal — snapshot captures it
        vm.prank(admin);
        token.transfer(newDelegatee, 50_000 ether);
        vm.prank(newDelegatee);
        token.delegate(newDelegatee);
        vm.warp(block.timestamp + 1); // ensure delegation is past

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildProposal(1);
        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, "test");
        uint48 snapshotTs = snapshot.getSnapshotTimestamp(proposalId);

        // Advance past snapshot; voter delegates to newDelegatee AFTER snapshot
        vm.warp(snapshotTs + 1);
        vm.prank(voter);
        token.delegate(newDelegatee);

        // newDelegatee's votes at snapshot = 50_000 (only their own pre-proposal balance)
        uint256 votingPowerAtSnapshot = token.getPastVotes(newDelegatee, snapshotTs);
        assertEq(votingPowerAtSnapshot, 50_000 ether);
    }

    // -------------------------------------------------------------------------
    // Snapshot record is consistent with the OZ voting period
    // -------------------------------------------------------------------------

    function test_SnapshotTimestampIsBeforeVotingOpens() public {
        uint256 ts = 5000;
        vm.warp(ts);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildProposal(1);
        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, "test");

        uint48 snapshotTs = snapshot.getSnapshotTimestamp(proposalId);

        // Snapshot is clock() + votingDelay = ts + 1
        assertEq(snapshotTs, uint48(ts + VOTING_DELAY));
    }

    // -------------------------------------------------------------------------
    // governanceSnapshot address on governor
    // -------------------------------------------------------------------------

    function test_GovernorExposesSnapshotAddress() public view {
        assertEq(address(governor.governanceSnapshot()), address(snapshot));
    }

    // -------------------------------------------------------------------------
    // Governor without snapshot (zero address) still works
    // -------------------------------------------------------------------------

    function test_GovernorWithoutSnapshotStillProposes() public {
        // Deploy a governor with snapshot=address(0)
        GovernedModuleRegistry noSnapRegistry = new GovernedModuleRegistry(admin);

        vm.startPrank(admin);
        address[] memory ps = new address[](0);
        address[] memory ex = new address[](0);
        TimelockController noSnapTimelock = new TimelockController(TIMELOCK_DELAY, ps, ex, admin);

        TruthBountyGovernor noSnapGovernor = new TruthBountyGovernor(
            token,
            noSnapTimelock,
            noSnapRegistry,
            IGovernanceSnapshot(address(0)), // no snapshot
            guardian,
            VOTING_DELAY,
            VOTING_PERIOD,
            100_000 ether,
            QUORUM_NUMERATOR
        );

        MockGovernedModule noSnapModule = new MockGovernedModule();
        noSnapRegistry.registerModule("MOCK", address(noSnapModule));
        GovernanceRoleTopology.configure(noSnapTimelock, noSnapGovernor, guardian, TIMELOCK_DELAY);
        GovernanceRoleTopology.finalizeTimelockAdmin(noSnapTimelock, admin);
        vm.stopPrank();

        GovernanceGuardian noSnapGuardian =
            new GovernanceGuardian(admin, guardian, ITruthBountyGovernor(address(noSnapGovernor)));
        vm.prank(guardian);
        noSnapGovernor.setGovernanceGuardianModule(address(noSnapGuardian));

        // Proposal creation should succeed without snapshot
        bytes memory cd = abi.encodeWithSelector(MockGovernedModule.setValue.selector, uint256(1));
        address[] memory t = new address[](1);
        t[0] = address(noSnapModule);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = cd;

        vm.prank(proposer);
        uint256 noSnapProposalId = noSnapGovernor.propose(t, v, c, "no snapshot test");
        assertGt(noSnapProposalId, 0);
    }
}
