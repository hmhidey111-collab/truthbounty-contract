// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GovernanceSnapshot} from "../../contracts/governance/v2/GovernanceSnapshot.sol";
import {IGovernanceSnapshot} from "../../contracts/governance/v2/IGovernanceSnapshot.sol";

// ============================================================================
// Handler — bounded call sequences for the invariant suite
// ============================================================================

/**
 * @title GovernanceSnapshotHandler
 * @notice Wraps GovernanceSnapshot operations for invariant testing via the
 *         Foundry invariant fuzzer. Tracks ghost variables that must match
 *         on-chain state at every step.
 */
contract GovernanceSnapshotHandler is Test {
    GovernanceSnapshot public snapshot;
    address public registrar;

    // Ghost: set of proposalIds that have been successfully registered
    uint256[] public registeredIds;
    mapping(uint256 => bool) public isRegistered;
    mapping(uint256 => uint48) public registeredTimestamp;

    // Counters for statistical coverage assertions
    uint256 public callCount;
    uint256 public successCount;
    uint256 public duplicateRevertCount;
    uint256 public zeroIdRevertCount;

    constructor(GovernanceSnapshot _snapshot, address _registrar) {
        snapshot = _snapshot;
        registrar = _registrar;
    }

    function registerSnapshot(uint256 proposalId, uint256 warpAmount) external {
        callCount++;
        // Bound inputs
        proposalId = bound(proposalId, 0, 50); // small space so duplicates occur
        warpAmount = bound(warpAmount, 0, 1 hours);

        vm.warp(block.timestamp + warpAmount);
        uint48 ts = uint48(block.timestamp);

        if (proposalId == 0) {
            vm.expectRevert(IGovernanceSnapshot.InvalidProposalId.selector);
            vm.prank(registrar);
            snapshot.registerSnapshot(proposalId, ts);
            zeroIdRevertCount++;
            return;
        }

        if (ts == 0) {
            // Defensive: in practice block.timestamp > 0 always after initialization
            return;
        }

        if (isRegistered[proposalId]) {
            vm.expectRevert(
                abi.encodeWithSelector(IGovernanceSnapshot.SnapshotAlreadyRegistered.selector, proposalId)
            );
            vm.prank(registrar);
            snapshot.registerSnapshot(proposalId, ts);
            duplicateRevertCount++;
            return;
        }

        vm.prank(registrar);
        snapshot.registerSnapshot(proposalId, ts);

        isRegistered[proposalId] = true;
        registeredTimestamp[proposalId] = ts;
        registeredIds.push(proposalId);
        successCount++;
    }

    function registeredCount() external view returns (uint256) {
        return registeredIds.length;
    }
}

// ============================================================================
// Invariant test contract
// ============================================================================

/**
 * @title GovernanceSnapshotInvariant
 * @notice Stateful invariant suite for GovernanceSnapshot.
 *
 * Invariants:
 *   INV-1  Every proposalId in the handler ghost set has a snapshot in the contract.
 *   INV-2  The stored snapshot timestamp matches the ghost-recorded registration timestamp.
 *   INV-3  hasSnapshot returns true for every ghost-registered proposalId.
 *   INV-4  The contract's stored snapshot value is non-zero for every registered proposalId.
 *   INV-5  No unregistered proposalId (in the ghost set boundary) has a snapshot.
 *   INV-6  callCount >= successCount (no more successes than calls).
 *   INV-7  successCount + duplicateRevertCount + zeroIdRevertCount == callCount.
 */
contract GovernanceSnapshotInvariant is Test {
    GovernanceSnapshot internal snapshot;
    GovernanceSnapshotHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");

    function setUp() public {
        snapshot = new GovernanceSnapshot(admin, registrar);
        handler = new GovernanceSnapshotHandler(snapshot, registrar);

        // Grant handler registrar role so it can call registerSnapshot via prank
        vm.prank(admin);
        snapshot.grantRole(snapshot.SNAPSHOT_REGISTRAR_ROLE(), registrar);

        targetContract(address(handler));
    }

    // -------------------------------------------------------------------------
    // INV-1 + INV-2: ghost timestamps match on-chain state
    // -------------------------------------------------------------------------

    function invariant_GhostTimestampsMatchOnChain() public view {
        uint256 count = handler.registeredCount();
        for (uint256 i = 0; i < count; ++i) {
            uint256 pid = handler.registeredIds(i);
            uint48 ghostTs = handler.registeredTimestamp(pid);
            uint48 onChainTs = snapshot.getSnapshotTimestamp(pid);
            assertEq(onChainTs, ghostTs, "on-chain timestamp diverged from ghost");
        }
    }

    // -------------------------------------------------------------------------
    // INV-3: hasSnapshot is always true for registered IDs
    // -------------------------------------------------------------------------

    function invariant_HasSnapshotTrueForRegistered() public view {
        uint256 count = handler.registeredCount();
        for (uint256 i = 0; i < count; ++i) {
            uint256 pid = handler.registeredIds(i);
            assertTrue(snapshot.hasSnapshot(pid), "hasSnapshot false for registered id");
        }
    }

    // -------------------------------------------------------------------------
    // INV-4: stored timestamp is non-zero for all registered IDs
    // -------------------------------------------------------------------------

    function invariant_StoredTimestampNonZeroForRegistered() public view {
        uint256 count = handler.registeredCount();
        for (uint256 i = 0; i < count; ++i) {
            uint256 pid = handler.registeredIds(i);
            uint48 ts = snapshot.getSnapshotTimestamp(pid);
            assertGt(ts, 0, "stored timestamp is zero");
        }
    }

    // -------------------------------------------------------------------------
    // INV-5: unregistered proposalIds in boundary [1..50] have no snapshot
    //         (only those not in the ghost set)
    // -------------------------------------------------------------------------

    function invariant_UnregisteredIdsHaveNoSnapshot() public view {
        for (uint256 pid = 1; pid <= 50; ++pid) {
            if (!handler.isRegistered(pid)) {
                assertFalse(snapshot.hasSnapshot(pid), "unregistered id has snapshot");
            }
        }
    }

    // -------------------------------------------------------------------------
    // INV-6: successCount <= callCount
    // -------------------------------------------------------------------------

    function invariant_SuccessNotExceedsCalls() public view {
        assertLe(handler.successCount(), handler.callCount());
    }

    // -------------------------------------------------------------------------
    // INV-7: accounting identity holds
    // -------------------------------------------------------------------------

    function invariant_CountingIdentity() public view {
        assertEq(
            handler.successCount() + handler.duplicateRevertCount() + handler.zeroIdRevertCount(),
            handler.callCount(),
            "counting identity violated"
        );
    }

    // -------------------------------------------------------------------------
    // INV-8: registered count matches ghost set size
    // -------------------------------------------------------------------------

    function invariant_RegisteredCountConsistent() public view {
        assertEq(handler.registeredCount(), handler.successCount(), "registered count != success count");
    }
}
