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

/**
 * @title GovernanceSnapshotRegression
 * @notice Regression tests that demonstrate the security properties introduced by
 *         GovernanceSnapshot and the TruthBountyGovernor integration.
 *
 * ## Prior Unsafe Behaviour (the defect addressed)
 *
 *   Without a canonical snapshot registry:
 *   - There was no single, authoritative, on-chain record of the exact timestamp used
 *     as the voting-power reference for a given proposal.
 *   - Off-chain systems had to re-derive the timepoint from governor state, creating
 *     inconsistency vectors for indexers, auditors, and multi-sig tooling.
 *   - External contracts that need to verify "voting power at snapshot X" for a given
 *     proposal had no single authoritative source.
 *
 * ## What These Regression Tests Verify
 *
 *   R-1  A governor WITHOUT snapshot integration can create a proposal with no snapshot
 *        record — the unsafe precondition is reproducible.
 *   R-2  A governor WITH snapshot integration CANNOT create a proposal without a
 *        snapshot record — the fix eliminates the unsafe precondition.
 *   R-3  Snapshot manipulation after proposal creation is impossible: re-registration
 *        of the same proposalId reverts.
 *   R-4  The canonical snapshot timestamp is identical to the OZ governor's
 *        proposalSnapshot() — no divergence between the two authoritative sources.
 *   R-5  Flash-loan-style token acquisition after proposal creation does not change the
 *        historical voting power at the snapshot timestamp.
 *   R-6  Post-proposal delegation rerouting does not change the snapshot voting power.
 *   R-7  Snapshot registrar cannot be an untrusted EOA after proper role transfer.
 *   R-8  Failing snapshot registration (unauthorized registrar) prevents proposal creation.
 *   R-9  Two proposals with different descriptions at different timestamps get independent
 *        snapshots.
 */
contract GovernanceSnapshotRegression is Test {
    uint48 internal constant VOTING_DELAY = 1;
    uint32 internal constant VOTING_PERIOD = 100;
    uint256 internal constant TIMELOCK_DELAY = 1 days;
    uint256 internal constant QUORUM_NUMERATOR = 4;
    uint256 internal constant TOKEN_SUPPLY = 10_000_000 ether; // larger pool

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
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        vm.startPrank(admin);

        registry = new GovernedModuleRegistry(admin);
        token = new TruthBountyGovernanceToken(admin, TOKEN_SUPPLY);
        // admin keeps 9_000_000 ether, distributes 500_000 to proposer and 500_000 to voter
        token.transfer(proposer, 500_000 ether);
        token.transfer(voter, 500_000 ether);
        // admin retains 9_000_000 ether for later operations

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

        // Warp so delegation is in the past (getPastVotes works for proposal threshold check)
        vm.warp(block.timestamp + 2);
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
        calldatas[0] = abi.encodeWithSelector(MockGovernedModule.setValue.selector, value);
    }

    // =========================================================================
    // R-1: UNSAFE precondition is reproducible — governor WITHOUT snapshot
    //       has no canonical record
    // =========================================================================

    function test_R1_GovernorWithoutSnapshot_HasNoCanonicalRecord() public {
        // Deploy a legacy-style governor without snapshot integration
        GovernedModuleRegistry legacyReg = new GovernedModuleRegistry(admin);
        MockGovernedModule legacyModule = new MockGovernedModule();

        vm.startPrank(admin);
        address[] memory ps = new address[](0);
        address[] memory ex = new address[](0);
        TimelockController legacyTimelock = new TimelockController(TIMELOCK_DELAY, ps, ex, admin);

        TruthBountyGovernor legacyGovernor = new TruthBountyGovernor(
            token,
            legacyTimelock,
            legacyReg,
            IGovernanceSnapshot(address(0)), // ← no snapshot: unsafe precondition
            guardian,
            VOTING_DELAY,
            VOTING_PERIOD,
            100_000 ether,
            QUORUM_NUMERATOR
        );

        legacyReg.registerModule("M", address(legacyModule));
        GovernanceRoleTopology.configure(legacyTimelock, legacyGovernor, guardian, TIMELOCK_DELAY);
        GovernanceRoleTopology.finalizeTimelockAdmin(legacyTimelock, admin);
        vm.stopPrank();

        GovernanceGuardian legacyGuardian =
            new GovernanceGuardian(admin, guardian, ITruthBountyGovernor(address(legacyGovernor)));
        vm.prank(guardian);
        legacyGovernor.setGovernanceGuardianModule(address(legacyGuardian));

        // Build proposal targeting legacyModule
        address[] memory t = new address[](1);
        t[0] = address(legacyModule);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeWithSelector(MockGovernedModule.setValue.selector, uint256(1));

        vm.prank(proposer);
        uint256 proposalId = legacyGovernor.propose(t, v, c, "legacy");
        assertGt(proposalId, 0);

        // ← There is no canonical on-chain snapshot record for this proposal.
        //   This is the unsafe precondition.
        assertEq(address(legacyGovernor.governanceSnapshot()), address(0), "no snapshot registry");
    }

    // =========================================================================
    // R-2: FIXED — governor WITH snapshot always has canonical record after propose
    // =========================================================================

    function test_R2_GovernorWithSnapshot_AlwaysHasCanonicalRecord() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildProposal(1);
        vm.prank(proposer);
        uint256 proposalId = governor.propose(t, v, c, "fixed");

        // The fix: canonical snapshot is always present after propose
        assertTrue(snapshot.hasSnapshot(proposalId), "snapshot missing after propose");
        assertGt(snapshot.getSnapshotTimestamp(proposalId), 0, "snapshot timestamp is zero");
    }

    // =========================================================================
    // R-3: Snapshot cannot be manipulated after registration
    // =========================================================================

    function test_R3_SnapshotIsImmutableAfterRegistration() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildProposal(1);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(t, v, c, "test");
        uint48 originalTs = snapshot.getSnapshotTimestamp(proposalId);
        assertGt(originalTs, 0);

        // Advance time by a day
        vm.warp(block.timestamp + 1 days);

        bytes32 registrarRole = snapshot.SNAPSHOT_REGISTRAR_ROLE();

        // Admin can't grant — admin lost registrar role. Confirm governor holds it.
        assertFalse(snapshot.hasRole(registrarRole, attacker));

        // Even if we simulate a new admin granting the role (worst-case scenario)...
        // The snapshot entry is already set — re-registration reverts.
        vm.prank(admin); // admin has DEFAULT_ADMIN_ROLE
        snapshot.grantRole(registrarRole, attacker);

        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceSnapshot.SnapshotAlreadyRegistered.selector, proposalId)
        );
        vm.prank(attacker);
        snapshot.registerSnapshot(proposalId, uint48(block.timestamp));

        // Timestamp remains at original value
        assertEq(snapshot.getSnapshotTimestamp(proposalId), originalTs);
    }

    // =========================================================================
    // R-4: Canonical snapshot equals OZ governor proposalSnapshot — no divergence
    // =========================================================================

    function test_R4_CanonicalSnapshotMatchesGovernorProposalSnapshot() public {
        vm.warp(5555);
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildProposal(1);
        vm.prank(proposer);
        uint256 proposalId = governor.propose(t, v, c, "test");

        uint256 govSnap = governor.proposalSnapshot(proposalId);
        uint48 canonicalSnap = snapshot.getSnapshotTimestamp(proposalId);

        assertEq(govSnap, canonicalSnap, "governor and canonical snapshot diverged");
    }

    // =========================================================================
    // R-5: Flash-loan-style token acquisition after proposal creation cannot
    //      influence historical voting power at snapshot timestamp
    // =========================================================================

    function test_R5_PostProposalTokenAcquisitionDoesNotAffectSnapshot() public {
        // Setup: attacker starts with no tokens and no delegation
        assertEq(token.balanceOf(attacker), 0);

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildProposal(1);
        vm.prank(proposer);
        uint256 proposalId = governor.propose(t, v, c, "test");
        uint48 snapshotTs = snapshot.getSnapshotTimestamp(proposalId);

        // Advance past snapshot
        vm.warp(snapshotTs + 1);

        // Simulate flash-loan: attacker acquires large token balance AFTER snapshot
        // admin still has 9_000_000 ether
        vm.prank(admin);
        token.transfer(attacker, 500_000 ether);
        vm.prank(attacker);
        token.delegate(attacker);

        // Attacker's voting power AT the snapshot timestamp is still 0
        uint256 votingPowerAtSnapshot = token.getPastVotes(attacker, snapshotTs);
        assertEq(votingPowerAtSnapshot, 0, "flash-loan attack boosted snapshot voting power");

        // Attacker's current voting power IS 500_000 (showing the acquisition happened)
        // but it's irrelevant since voting uses the historical snapshot
        assertGt(token.getVotes(attacker), 0);
    }

    // =========================================================================
    // R-6: Post-proposal delegation rerouting does not change snapshot voting power
    // =========================================================================

    function test_R6_PostProposalDelegationDoesNotAffectSnapshot() public {
        // Setup: voter has 500_000 tokens delegated to themselves
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildProposal(1);
        vm.prank(proposer);
        uint256 proposalId = governor.propose(t, v, c, "test");
        uint48 snapshotTs = snapshot.getSnapshotTimestamp(proposalId);

        // Advance past snapshot so historical queries work
        vm.warp(snapshotTs + 1);

        uint256 voterPowerAtSnapshot = token.getPastVotes(voter, snapshotTs);
        assertEq(voterPowerAtSnapshot, 500_000 ether);

        // Voter re-delegates to attacker AFTER snapshot
        vm.prank(voter);
        token.delegate(attacker);

        // Snapshot voting power unchanged — still 500_000 for voter, 0 for attacker
        assertEq(token.getPastVotes(voter, snapshotTs), 500_000 ether);
        assertEq(token.getPastVotes(attacker, snapshotTs), 0);
    }

    // =========================================================================
    // R-7: After role transfer, untrusted EOA cannot register snapshots
    // =========================================================================

    function test_R7_UntrustedEOACannotRegisterSnapshot() public {
        bytes32 role = snapshot.SNAPSHOT_REGISTRAR_ROLE();

        // Attacker has no role
        assertFalse(snapshot.hasRole(role, attacker));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role)
        );
        vm.prank(attacker);
        snapshot.registerSnapshot(1, 1000);
    }

    // =========================================================================
    // R-8: If governor loses snapshot registrar role, proposal creation reverts
    //      (fail-closed: no proposal without snapshot)
    // =========================================================================

    function test_R8_ProposalCreationRevertsIfGovernorLosesRegistrarRole() public {
        // Admin revokes registrar role from governor
        bytes32 registrarRole = snapshot.SNAPSHOT_REGISTRAR_ROLE();
        vm.prank(admin);
        snapshot.revokeRole(registrarRole, address(governor));

        // Now any proposal attempt must revert because registerSnapshot will fail
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _buildProposal(1);
        vm.prank(proposer);
        vm.expectRevert(); // Access control revert propagates up through _propose
        governor.propose(t, v, c, "should fail");
    }

    // =========================================================================
    // R-9: Two proposals with different descriptions at different timestamps get
    //       independent, correct snapshots (no cross-contamination)
    // =========================================================================

    function test_R9_IdenticalDescriptionsGetIndependentSnapshots() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c1) = _buildProposal(1);
        (,, bytes[] memory c2) = _buildProposal(2);

        vm.warp(1000);
        vm.prank(proposer);
        uint256 pid1 = governor.propose(t, v, c1, "proposal A");

        vm.warp(2000);
        vm.prank(proposer);
        uint256 pid2 = governor.propose(t, v, c2, "proposal B");

        assertNotEq(pid1, pid2);
        // Each snapshot matches its own governor proposalSnapshot
        assertEq(snapshot.getSnapshotTimestamp(pid1), governor.proposalSnapshot(pid1));
        assertEq(snapshot.getSnapshotTimestamp(pid2), governor.proposalSnapshot(pid2));
        // And they're distinct
        assertTrue(snapshot.getSnapshotTimestamp(pid1) < snapshot.getSnapshotTimestamp(pid2));
    }
}
