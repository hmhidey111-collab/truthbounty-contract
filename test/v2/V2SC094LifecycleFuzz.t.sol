// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/v2/interfaces/IV2Types.sol";
import "../../contracts/v2/libraries/V2Lifecycle.sol";
import "../../contracts/v2/libraries/ProtocolModel.sol";

/// @dev Stateful wrapper that applies only transitions accepted by the production lifecycle library.
contract V2SC094LifecycleHarness {
    IV2Types.ClaimState public claimState;
    IV2Types.DisputeStatus public disputeStatus;
    IV2Types.SettlementStatus public settlementStatus;

    function transitionClaim(IV2Types.ClaimState next) external returns (bool accepted) {
        accepted = V2Lifecycle.isValidClaimTransition(claimState, next);
        if (accepted) claimState = next;
    }

    function transitionDispute(IV2Types.DisputeStatus next) external returns (bool accepted) {
        accepted = V2Lifecycle.isValidDisputeTransition(disputeStatus, next);
        if (accepted) disputeStatus = next;
    }

    function transitionSettlement(IV2Types.SettlementStatus next) external returns (bool accepted) {
        accepted = V2Lifecycle.isValidSettlementTransition(settlementStatus, next);
        if (accepted) settlementStatus = next;
    }
}

contract V2SC094LifecycleFuzzTest is Test {
    function testFuzz_claimTransitionSequencesAreCompleteAndTerminal(uint8[] calldata requests) public {
        V2SC094LifecycleHarness harness = new V2SC094LifecycleHarness();
        uint256 count = requests.length > 64 ? 64 : requests.length;

        for (uint256 i; i < count; ++i) {
            IV2Types.ClaimState previous = harness.claimState();
            IV2Types.ClaimState next = IV2Types.ClaimState(
                bound(uint256(requests[i]), 0, uint256(uint8(type(IV2Types.ClaimState).max)))
            );
            bool expected = V2Lifecycle.isValidClaimTransition(previous, next);
            assertEq(expected, ProtocolModel.isValidClaimTransition(previous, next));
            assertEq(harness.transitionClaim(next), expected);
            assertEq(uint256(harness.claimState()), uint256(expected ? next : previous));
            if (previous == IV2Types.ClaimState.Finalized) assertFalse(expected);
        }
    }

    function testFuzz_disputeAndSettlementSequencesCannotLeaveTerminalStates(uint8[] calldata requests) public {
        V2SC094LifecycleHarness harness = new V2SC094LifecycleHarness();
        uint256 count = requests.length > 64 ? 64 : requests.length;

        for (uint256 i; i < count; ++i) {
            IV2Types.DisputeStatus previousDispute = harness.disputeStatus();
            IV2Types.DisputeStatus nextDispute = IV2Types.DisputeStatus(
                bound(uint256(requests[i]), 0, uint256(uint8(type(IV2Types.DisputeStatus).max)))
            );
            bool disputeAccepted = V2Lifecycle.isValidDisputeTransition(previousDispute, nextDispute);
            assertEq(harness.transitionDispute(nextDispute), disputeAccepted);
            assertEq(
                uint256(harness.disputeStatus()),
                uint256(disputeAccepted ? nextDispute : previousDispute)
            );

            IV2Types.SettlementStatus previousSettlement = harness.settlementStatus();
            IV2Types.SettlementStatus nextSettlement = IV2Types.SettlementStatus(
                bound(uint256(requests[i]), 0, uint256(uint8(type(IV2Types.SettlementStatus).max)))
            );
            bool settlementAccepted = V2Lifecycle.isValidSettlementTransition(previousSettlement, nextSettlement);
            assertEq(harness.transitionSettlement(nextSettlement), settlementAccepted);
            assertEq(
                uint256(harness.settlementStatus()),
                uint256(settlementAccepted ? nextSettlement : previousSettlement)
            );
        }
    }

    function testFuzz_deadlineBoundary(uint64 deadline) public {
        deadline = uint64(bound(uint256(deadline), 1, type(uint64).max - 1));

        vm.warp(uint256(deadline) - 1);
        assertTrue(V2Lifecycle.isDeadlineValid(deadline));
        assertFalse(V2Lifecycle.isDeadlineExpired(deadline));
        assertEq(V2Lifecycle.timeUntilDeadline(deadline), 1);

        vm.warp(uint256(deadline));
        assertTrue(V2Lifecycle.isDeadlineValid(deadline));
        assertFalse(V2Lifecycle.isDeadlineExpired(deadline));
        assertEq(V2Lifecycle.timeUntilDeadline(deadline), 0);

        vm.warp(uint256(deadline) + 1);
        assertFalse(V2Lifecycle.isDeadlineValid(deadline));
        assertTrue(V2Lifecycle.isDeadlineExpired(deadline));
        assertEq(V2Lifecycle.timeUntilDeadline(deadline), 0);
    }

    function test_disputeCancellationIsTerminalAndClaimFinalizationCannotReopen() public {
        V2SC094LifecycleHarness harness = new V2SC094LifecycleHarness();
        assertTrue(harness.transitionDispute(IV2Types.DisputeStatus.OPEN));
        assertTrue(harness.transitionDispute(IV2Types.DisputeStatus.CANCELLED));
        assertFalse(harness.transitionDispute(IV2Types.DisputeStatus.OPEN));

        assertTrue(harness.transitionClaim(IV2Types.ClaimState.VerificationOpen));
        assertTrue(harness.transitionClaim(IV2Types.ClaimState.AwaitingSettlement));
        assertTrue(harness.transitionClaim(IV2Types.ClaimState.Finalized));
        assertFalse(harness.transitionClaim(IV2Types.ClaimState.VerificationOpen));
        assertEq(uint256(harness.claimState()), uint256(IV2Types.ClaimState.Finalized));
    }

    function testFuzz_settlementExecutionBoundary(uint64 executeAfter, uint64 offset) public pure {
        uint256 timestamp = uint256(executeAfter) + uint256(offset);
        assertEq(
            V2Lifecycle.canExecuteSettlement(IV2Types.SettlementStatus.PENDING, timestamp, executeAfter),
            timestamp >= executeAfter
        );
        assertFalse(V2Lifecycle.canExecuteSettlement(IV2Types.SettlementStatus.EXECUTED, timestamp, executeAfter));
        if (executeAfter != 0) {
            assertFalse(
                V2Lifecycle.canExecuteSettlement(
                    IV2Types.SettlementStatus.PENDING,
                    uint256(executeAfter) - 1,
                    executeAfter
                )
            );
        }
    }
}