// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {VerifierAssignmentGuard} from "../../contracts/verification/VerifierAssignmentGuard.sol";
import {IVerifierAssignment} from "../../contracts/interfaces/IVerifierAssignment.sol";

contract VerifierAssignmentUniquenessTest is Test {
    VerifierAssignmentGuard internal guard;

    address internal admin = address(0xA11CE);
    address internal assigner = address(0xB0B);
    address internal verifierA = address(0xA);
    address internal verifierB = address(0xB);
    address internal claimAuthor = address(0xC1A11);

    uint256 internal constant ROUND = 1;
    uint256 internal constant CLAIM = 42;
    uint256 internal constant SNAP = 7;
    uint256 internal constant MIN_REP = 100;

    function setUp() public {
        guard = new VerifierAssignmentGuard(admin);
        bytes32 assignerRole = guard.ASSIGNER_ROLE();
        vm.prank(admin);
        guard.grantRole(assignerRole, assigner);

        address[] memory vs = new address[](2);
        vs[0] = verifierA;
        vs[1] = verifierB;
        uint256[] memory sc = new uint256[](2);
        sc[0] = 150;
        sc[1] = 50;

        vm.prank(assigner);
        guard.registerEligibilitySnapshot(SNAP, block.timestamp + 1 days, vs, sc);
        vm.prank(assigner);
        guard.openAssignmentRound(ROUND, CLAIM, claimAuthor, 2);
    }

    function test_DuplicateAssignment() public {
        vm.startPrank(assigner);
        guard.assignVerifier(ROUND, verifierA, 1 ether, SNAP, MIN_REP);
        vm.expectRevert(
            abi.encodeWithSelector(IVerifierAssignment.DuplicateAssignment.selector, ROUND, verifierA)
        );
        guard.assignVerifier(ROUND, verifierA, 1 ether, SNAP, MIN_REP);
        vm.stopPrank();
    }

    function test_IneligibleReputation() public {
        vm.prank(assigner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVerifierAssignment.IneligibleReputation.selector,
                verifierB,
                uint256(50),
                MIN_REP
            )
        );
        guard.assignVerifier(ROUND, verifierB, 1 ether, SNAP, MIN_REP);
    }

    function test_StaleReputationSnapshot() public {
        vm.warp(block.timestamp + 2 days);
        vm.prank(assigner);
        vm.expectRevert();
        guard.assignVerifier(ROUND, verifierA, 1 ether, SNAP, MIN_REP);
    }

    function test_SelfClaimConflict() public {
        address[] memory vs = new address[](1);
        vs[0] = claimAuthor;
        uint256[] memory sc = new uint256[](1);
        sc[0] = 200;
        vm.prank(assigner);
        guard.registerEligibilitySnapshot(8, block.timestamp + 1 days, vs, sc);
        vm.prank(assigner);
        guard.openAssignmentRound(2, CLAIM, claimAuthor, 2);
        vm.prank(assigner);
        vm.expectRevert(
            abi.encodeWithSelector(IVerifierAssignment.SelfClaimConflict.selector, CLAIM, claimAuthor)
        );
        guard.assignVerifier(2, claimAuthor, 1 ether, 8, MIN_REP);
    }

    function test_CapacityEdge() public {
        address c = address(0xC);
        address[] memory vs = new address[](1);
        vs[0] = c;
        uint256[] memory sc = new uint256[](1);
        sc[0] = 200;
        vm.prank(assigner);
        guard.registerEligibilitySnapshot(9, block.timestamp + 1 days, vs, sc);
        vm.prank(assigner);
        guard.openAssignmentRound(3, CLAIM, claimAuthor, 1);
        vm.prank(assigner);
        guard.assignVerifier(3, c, 1 ether, 9, MIN_REP);
        vm.prank(assigner);
        vm.expectRevert(
            abi.encodeWithSelector(IVerifierAssignment.CapacityExceeded.selector, uint256(3), uint256(1))
        );
        guard.assignVerifier(3, verifierA, 1 ether, SNAP, MIN_REP);
    }

    /// @dev Reorg model: after a deeper chain, prior assignment remains the only valid one;
    ///      a second assign of the same verifier still fails (no double seat on reorg-safe state).
    function test_ReorgModel_AssignmentStable() public {
        vm.prank(assigner);
        guard.assignVerifier(ROUND, verifierA, 1 ether, SNAP, MIN_REP);
        assertTrue(guard.isAssigned(ROUND, verifierA));
        assertEq(guard.assignmentCount(ROUND), 1);

        // Simulate alternate tip / later block without rolling back storage (L2 reorg model:
        // committed assignment is authoritative; duplicate selection must still fail closed).
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 60);

        vm.prank(assigner);
        vm.expectRevert(
            abi.encodeWithSelector(IVerifierAssignment.DuplicateAssignment.selector, ROUND, verifierA)
        );
        guard.assignVerifier(ROUND, verifierA, 1 ether, SNAP, MIN_REP);
        assertEq(guard.assignmentCount(ROUND), 1);
    }

    function test_ConcurrentSelection() public {
        vm.prank(assigner);
        guard.assignVerifier(ROUND, verifierA, 1 ether, SNAP, MIN_REP);
        vm.prank(assigner);
        vm.expectRevert(
            abi.encodeWithSelector(IVerifierAssignment.DuplicateAssignment.selector, ROUND, verifierA)
        );
        guard.assignVerifier(ROUND, verifierA, 2 ether, SNAP, MIN_REP);
    }

    function test_AssignmentEventReplay() public {
        vm.prank(assigner);
        vm.expectEmit(true, true, true, true);
        emit IVerifierAssignment.VerifierAssigned(
            ROUND,
            CLAIM,
            verifierA,
            1 ether,
            SNAP,
            150,
            uint64(block.timestamp),
            0
        );
        guard.assignVerifier(ROUND, verifierA, 1 ether, SNAP, MIN_REP);

        VerifierAssignmentGuard.AssignmentRecord memory rec = guard.getAssignment(ROUND, 0);
        assertEq(rec.verifier, verifierA);
        assertEq(rec.eligibilitySnapshotId, SNAP);
        assertEq(rec.reputationScore, 150);
    }
}
