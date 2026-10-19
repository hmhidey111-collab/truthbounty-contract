// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GovernanceSnapshot} from "../../contracts/governance/v2/GovernanceSnapshot.sol";
import {IGovernanceSnapshot} from "../../contracts/governance/v2/IGovernanceSnapshot.sol";

/**
 * @title GovernanceSnapshotFuzz
 * @notice Fuzz and property-based tests for GovernanceSnapshot.
 *
 * Properties verified:
 *   P1  registerSnapshot is idempotent-resistant: calling twice with the same proposalId reverts.
 *   P2  getSnapshotTimestamp returns exactly the timestamp passed to registerSnapshot.
 *   P3  hasSnapshot is false before and true after exactly one registerSnapshot call.
 *   P4  Different proposalIds are fully independent.
 *   P5  The stored timestamp cannot exceed uint48 max.
 *   P6  Unauthorized callers always revert regardless of proposalId or timestamp.
 *   P7  proposalId == 0 always reverts.
 *   P8  snapshotTimestamp == 0 always reverts.
 *   P9  getSnapshotTimestamp always reverts for unregistered proposalId.
 *   P10 Snapshot value is stable after registration.
 */
contract GovernanceSnapshotFuzz is Test {
    GovernanceSnapshot internal snapshot;

    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        snapshot = new GovernanceSnapshot(admin, registrar);
    }

    // -------------------------------------------------------------------------
    // P1 — Duplicate registration always reverts
    // -------------------------------------------------------------------------

    function testFuzz_DuplicateRegistrationReverts(uint256 proposalId, uint48 ts1, uint48 ts2) public {
        proposalId = bound(proposalId, 1, type(uint256).max);
        vm.assume(ts1 > 0);
        vm.assume(ts2 > 0);

        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, ts1);

        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceSnapshot.SnapshotAlreadyRegistered.selector, proposalId)
        );
        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, ts2);
    }

    // -------------------------------------------------------------------------
    // P2 — getSnapshotTimestamp returns exactly the passed timestamp
    // -------------------------------------------------------------------------

    function testFuzz_SnapshotTimestampMatchesRegistered(uint256 proposalId, uint48 ts) public {
        proposalId = bound(proposalId, 1, type(uint256).max);
        vm.assume(ts > 0);

        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, ts);

        assertEq(snapshot.getSnapshotTimestamp(proposalId), ts);
    }

    // -------------------------------------------------------------------------
    // P3 — hasSnapshot state transitions correctly
    // -------------------------------------------------------------------------

    function testFuzz_HasSnapshotStateTransitions(uint256 proposalId, uint48 ts) public {
        proposalId = bound(proposalId, 1, type(uint256).max);
        vm.assume(ts > 0);

        assertFalse(snapshot.hasSnapshot(proposalId), "should be false before registration");

        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, ts);

        assertTrue(snapshot.hasSnapshot(proposalId), "should be true after registration");
    }

    // -------------------------------------------------------------------------
    // P4 — Independent proposal IDs don't interfere
    // -------------------------------------------------------------------------

    function testFuzz_IndependentProposalIdsAreIsolated(
        uint256 proposalIdA,
        uint256 proposalIdB,
        uint48 tsA,
        uint48 tsB
    ) public {
        // Ensure distinct IDs
        proposalIdA = bound(proposalIdA, 1, type(uint256).max / 2);
        proposalIdB = bound(proposalIdB, type(uint256).max / 2 + 1, type(uint256).max);
        vm.assume(tsA > 0);
        vm.assume(tsB > 0);

        vm.prank(registrar);
        snapshot.registerSnapshot(proposalIdA, tsA);

        vm.prank(registrar);
        snapshot.registerSnapshot(proposalIdB, tsB);

        assertEq(snapshot.getSnapshotTimestamp(proposalIdA), tsA);
        assertEq(snapshot.getSnapshotTimestamp(proposalIdB), tsB);
    }

    // -------------------------------------------------------------------------
    // P5 — Stored timestamp never exceeds uint48 boundary (no overflow)
    // -------------------------------------------------------------------------

    function testFuzz_StoredTimestampNeverExceedsUint48(uint256 proposalId, uint48 ts) public {
        proposalId = bound(proposalId, 1, type(uint256).max);
        vm.assume(ts > 0);

        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, ts);

        uint48 stored = snapshot.getSnapshotTimestamp(proposalId);
        assertEq(stored, ts, "stored timestamp must equal registered timestamp");
        assertLe(stored, type(uint48).max, "must fit in uint48");
    }

    // -------------------------------------------------------------------------
    // P6 — Unauthorized callers always revert
    // -------------------------------------------------------------------------

    function testFuzz_UnauthorizedCallerAlwaysReverts(address caller, uint256 proposalId, uint48 ts) public {
        vm.assume(caller != registrar);
        proposalId = bound(proposalId, 1, type(uint256).max);
        vm.assume(ts > 0);

        vm.expectRevert();
        vm.prank(caller);
        snapshot.registerSnapshot(proposalId, ts);
    }

    // -------------------------------------------------------------------------
    // P7 — Zero proposalId always reverts regardless of caller role or timestamp
    // -------------------------------------------------------------------------

    function testFuzz_ZeroProposalIdAlwaysReverts(uint48 ts) public {
        vm.assume(ts > 0);

        vm.expectRevert(IGovernanceSnapshot.InvalidProposalId.selector);
        vm.prank(registrar);
        snapshot.registerSnapshot(0, ts);
    }

    // -------------------------------------------------------------------------
    // P8 — Zero timestamp always reverts
    // -------------------------------------------------------------------------

    function testFuzz_ZeroTimestampAlwaysReverts(uint256 proposalId) public {
        proposalId = bound(proposalId, 1, type(uint256).max);

        vm.expectRevert(IGovernanceSnapshot.InvalidSnapshotTimestamp.selector);
        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, 0);
    }

    // -------------------------------------------------------------------------
    // P9 — getSnapshotTimestamp always reverts for unregistered proposalId
    // -------------------------------------------------------------------------

    function testFuzz_GetSnapshotTimestampRevertsIfUnregistered(uint256 proposalId) public {
        proposalId = bound(proposalId, 1, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceSnapshot.SnapshotNotFound.selector, proposalId)
        );
        snapshot.getSnapshotTimestamp(proposalId);
    }

    // -------------------------------------------------------------------------
    // P10 — Snapshot value is stable under repeated queries
    // -------------------------------------------------------------------------

    function testFuzz_SnapshotValueIsStable(uint256 proposalId, uint48 ts) public {
        proposalId = bound(proposalId, 1, type(uint256).max);
        vm.assume(ts > 0);

        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, ts);

        // Query multiple times — must always return the same value
        assertEq(snapshot.getSnapshotTimestamp(proposalId), ts);
        assertEq(snapshot.getSnapshotTimestamp(proposalId), ts);
        assertEq(snapshot.getSnapshotTimestamp(proposalId), ts);
    }

    // -------------------------------------------------------------------------
    // P11 — Registrar role transfer: new holder can register, old cannot
    // -------------------------------------------------------------------------

    function testFuzz_RoleTransferChangesWriteAccess(address newRegistrar, uint256 proposalId, uint48 ts) public {
        vm.assume(newRegistrar != address(0));
        vm.assume(newRegistrar != registrar);
        vm.assume(newRegistrar != admin);
        proposalId = bound(proposalId, 1, type(uint256).max);
        vm.assume(ts > 0);

        bytes32 role = snapshot.SNAPSHOT_REGISTRAR_ROLE();

        // Transfer role
        vm.prank(admin);
        snapshot.grantRole(role, newRegistrar);
        vm.prank(admin);
        snapshot.revokeRole(role, registrar);

        // Old registrar cannot register
        vm.expectRevert();
        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, ts);

        // New registrar can
        vm.prank(newRegistrar);
        snapshot.registerSnapshot(proposalId, ts);
        assertTrue(snapshot.hasSnapshot(proposalId));
    }
}
