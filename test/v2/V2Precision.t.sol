// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/v2/libraries/V2Precision.sol";
import "../../contracts/v2/libraries/V2Errors.sol";

/// @notice External wrapper so `vm.expectRevert` has a call boundary to observe.
/// @dev The library's functions are `internal`, so calling them directly from a
///      test would revert the test itself rather than a nested call.
contract PrecisionHarness {
    function mulDivDown(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return V2Precision.mulDivDown(a, b, d);
    }

    function mulDivUp(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return V2Precision.mulDivUp(a, b, d);
    }

    function wadDivDown(uint256 a, uint256 b) external pure returns (uint256) {
        return V2Precision.wadDivDown(a, b);
    }

    function bpsPortionDown(uint256 amount, uint256 bps) external pure returns (uint256) {
        return V2Precision.bpsPortionDown(amount, bps);
    }

    function percentPortionDown(uint256 amount, uint256 percent) external pure returns (uint256) {
        return V2Precision.percentPortionDown(amount, percent);
    }

    function requireBpsSumExact(uint256[] memory parts) external pure {
        V2Precision.requireBpsSumExact(parts);
    }

    function allocateByBps(uint256 total, uint256[] memory parts)
        external
        pure
        returns (uint256[] memory, uint256)
    {
        return V2Precision.allocateByBps(total, parts);
    }

    function allocateByBpsWithRemainderTo(uint256 total, uint256[] memory parts, uint256 index)
        external
        pure
        returns (uint256[] memory)
    {
        return V2Precision.allocateByBpsWithRemainderTo(total, parts, index);
    }

    function weightedAverageDown(uint256[] memory values, uint256[] memory weights)
        external
        pure
        returns (uint256)
    {
        return V2Precision.weightedAverageDown(values, weights);
    }
}

contract V2PrecisionTest is Test {
    PrecisionHarness internal harness;

    function setUp() public {
        harness = new PrecisionHarness();
    }

    // =========================================================================
    // Denominators
    // =========================================================================

    function test_denominators() public pure {
        assertEq(V2Precision.BPS_DENOMINATOR, 10_000);
        assertEq(V2Precision.PERCENT_DENOMINATOR, 100);
        assertEq(V2Precision.WAD, 1e18);
    }

    // =========================================================================
    // Rounding direction is the whole point
    // =========================================================================

    function test_mulDiv_roundsInBothDirections() public pure {
        // 10 * 1 / 3 == 3.33…
        assertEq(V2Precision.mulDivDown(10, 1, 3), 3);
        assertEq(V2Precision.mulDivUp(10, 1, 3), 4);
    }

    function test_mulDiv_exactDivisionAgrees() public pure {
        // No precision lost, so both directions must agree.
        assertEq(V2Precision.mulDivDown(10, 2, 4), 5);
        assertEq(V2Precision.mulDivUp(10, 2, 4), 5);
    }

    function test_mulDiv_intermediateProductExceeds256Bits() public pure {
        // a * b overflows uint256; mulDiv's 512-bit intermediate must not.
        uint256 huge = type(uint256).max;
        assertEq(V2Precision.mulDivDown(huge, 2, 4), huge / 2);
    }

    function test_mulDivDown_revertsOnZeroDenominator() public {
        vm.expectRevert(V2Errors.ZeroDenominator.selector);
        harness.mulDivDown(1, 1, 0);
    }

    function test_mulDivUp_revertsOnZeroDenominator() public {
        vm.expectRevert(V2Errors.ZeroDenominator.selector);
        harness.mulDivUp(1, 1, 0);
    }

    function test_wad_roundsInBothDirections() public pure {
        // 1 / 3 as a WAD ratio is 0.333…e18
        assertEq(V2Precision.wadDivDown(1, 3), 333333333333333333);
        assertEq(V2Precision.wadDivUp(1, 3), 333333333333333334);
    }

    function test_wadMul_roundsInBothDirections() public pure {
        // 10 * 0.5 == 5 exactly
        assertEq(V2Precision.wadMulDown(10, 0.5e18), 5);
        // 1 * 0.5 == 0.5, which truncates to 0 or rounds to 1
        assertEq(V2Precision.wadMulDown(1, 0.5e18), 0);
        assertEq(V2Precision.wadMulUp(1, 0.5e18), 1);
    }

    function test_wadDivDown_revertsOnZeroDenominator() public {
        vm.expectRevert(V2Errors.ZeroDenominator.selector);
        harness.wadDivDown(1, 0);
    }

    // =========================================================================
    // Basis points
    // =========================================================================

    function test_bpsPortion_roundsInBothDirections() public pure {
        // 1 bps of 15_000 == 1.5
        assertEq(V2Precision.bpsPortionDown(15_000, 1), 1);
        assertEq(V2Precision.bpsPortionUp(15_000, 1), 2);
    }

    function test_bpsPortion_fullAndZero() public pure {
        assertEq(V2Precision.bpsPortionDown(1234, V2Precision.BPS_DENOMINATOR), 1234);
        assertEq(V2Precision.bpsPortionDown(1234, 0), 0);
    }

    function test_bpsPortion_revertsAboveFullScale() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.BpsOutOfRange.selector, 10_001));
        harness.bpsPortionDown(100, 10_001);
    }

    function test_percentPortion_revertsAboveFullScale() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.PercentOutOfRange.selector, 101));
        harness.percentPortionDown(100, 101);
    }

    function test_percentPortion_roundsInBothDirections() public pure {
        // 33% of 10 == 3.3
        assertEq(V2Precision.percentPortionDown(10, 33), 3);
        assertEq(V2Precision.percentPortionUp(10, 33), 4);
    }

    function test_toBps_roundsInBothDirections() public pure {
        // 1 of 3 == 3333.33 bps
        assertEq(V2Precision.toBpsDown(1, 3), 3333);
        assertEq(V2Precision.toBpsUp(1, 3), 3334);
    }

    function test_toBps_zeroWholeIsZeroNotRevert() public pure {
        // A share of nothing is nothing; callers computing participation branch
        // on this rather than needing a try/catch.
        assertEq(V2Precision.toBpsDown(5, 0), 0);
        assertEq(V2Precision.toBpsUp(5, 0), 0);
    }

    // =========================================================================
    // Validation
    // =========================================================================

    function test_requireValidBps_acceptsBoundary() public pure {
        V2Precision.requireValidBps(0);
        V2Precision.requireValidBps(10_000);
    }

    function test_requireBpsSumExact_acceptsExactly100Percent() public view {
        uint256[] memory parts = new uint256[](3);
        parts[0] = 5_000;
        parts[1] = 3_000;
        parts[2] = 2_000;
        harness.requireBpsSumExact(parts);
    }

    function test_requireBpsSumExact_rejectsUnderAllocation() public {
        uint256[] memory parts = new uint256[](2);
        parts[0] = 5_000;
        parts[1] = 4_999;

        // Under-allocation strands value, which is why this is exact.
        vm.expectRevert(abi.encodeWithSelector(V2Errors.BpsSumNotExact.selector, 9_999));
        harness.requireBpsSumExact(parts);
    }

    function test_requireBpsSumExact_rejectsOverAllocation() public {
        uint256[] memory parts = new uint256[](2);
        parts[0] = 5_000;
        parts[1] = 5_001;

        vm.expectRevert(abi.encodeWithSelector(V2Errors.BpsSumNotExact.selector, 10_001));
        harness.requireBpsSumExact(parts);
    }

    function test_clampBps_doesNotRevert() public pure {
        assertEq(V2Precision.clampBps(12_345), 10_000);
        assertEq(V2Precision.clampBps(500), 500);
    }

    // =========================================================================
    // Allocation and dust
    // =========================================================================

    function test_allocateByBps_exactSplitLeavesNoDust() public view {
        uint256[] memory parts = new uint256[](2);
        parts[0] = 5_000;
        parts[1] = 5_000;

        (uint256[] memory amounts, uint256 remainder) = harness.allocateByBps(1_000, parts);

        assertEq(amounts[0], 500);
        assertEq(amounts[1], 500);
        assertEq(remainder, 0);
    }

    function test_allocateByBps_returnsDustRatherThanDroppingIt() public view {
        // 10 across three equal-ish parts cannot divide evenly.
        uint256[] memory parts = new uint256[](3);
        parts[0] = 3_334;
        parts[1] = 3_333;
        parts[2] = 3_333;

        (uint256[] memory amounts, uint256 remainder) = harness.allocateByBps(10, parts);

        uint256 allocated = amounts[0] + amounts[1] + amounts[2];
        assertEq(allocated + remainder, 10, "dust must be accounted for");
        assertGt(remainder, 0, "this split should produce dust");
    }

    function test_allocateByBps_remainderIsBoundedByPartCount() public view {
        uint256[] memory parts = new uint256[](4);
        parts[0] = 2_500;
        parts[1] = 2_500;
        parts[2] = 2_500;
        parts[3] = 2_500;

        (, uint256 remainder) = harness.allocateByBps(999_999_999, parts);

        assertLt(remainder, parts.length);
    }

    function test_allocateByBpsWithRemainderTo_sumsToTotalExactly() public view {
        uint256[] memory parts = new uint256[](3);
        parts[0] = 3_334;
        parts[1] = 3_333;
        parts[2] = 3_333;

        uint256[] memory amounts = harness.allocateByBpsWithRemainderTo(10, parts, 0);

        assertEq(amounts[0] + amounts[1] + amounts[2], 10);
    }

    function test_allocateByBpsWithRemainderTo_isDeterministic() public view {
        uint256[] memory parts = new uint256[](3);
        parts[0] = 3_334;
        parts[1] = 3_333;
        parts[2] = 3_333;

        uint256[] memory first = harness.allocateByBpsWithRemainderTo(10, parts, 2);
        uint256[] memory second = harness.allocateByBpsWithRemainderTo(10, parts, 2);

        for (uint256 i = 0; i < first.length; ++i) {
            assertEq(first[i], second[i]);
        }
    }

    function test_allocateByBpsWithRemainderTo_revertsOnBadIndex() public {
        uint256[] memory parts = new uint256[](2);
        parts[0] = 5_000;
        parts[1] = 5_000;

        vm.expectRevert(abi.encodeWithSelector(V2Errors.IndexOutOfBounds.selector, 2));
        harness.allocateByBpsWithRemainderTo(10, parts, 2);
    }

    function test_allocateByBps_rejectsPartsNotSummingTo100Percent() public {
        uint256[] memory parts = new uint256[](2);
        parts[0] = 1_000;
        parts[1] = 1_000;

        vm.expectRevert(abi.encodeWithSelector(V2Errors.BpsSumNotExact.selector, 2_000));
        harness.allocateByBps(100, parts);
    }

    // =========================================================================
    // Weights and confidence
    // =========================================================================

    function test_weightedAverageDown() public pure {
        uint256[] memory values = new uint256[](2);
        values[0] = 100;
        values[1] = 200;

        uint256[] memory weights = new uint256[](2);
        weights[0] = 1;
        weights[1] = 3;

        // (100*1 + 200*3) / 4 == 175
        assertEq(V2Precision.weightedAverageDown(values, weights), 175);
    }

    function test_weightedAverageDown_zeroTotalWeightIsZero() public pure {
        uint256[] memory values = new uint256[](2);
        values[0] = 100;
        values[1] = 200;
        uint256[] memory weights = new uint256[](2);

        assertEq(V2Precision.weightedAverageDown(values, weights), 0);
    }

    function test_weightedAverageDown_revertsOnLengthMismatch() public {
        uint256[] memory values = new uint256[](2);
        uint256[] memory weights = new uint256[](3);

        vm.expectRevert(V2Errors.LengthMismatch.selector);
        harness.weightedAverageDown(values, weights);
    }

    function test_requiredSupportUp_roundsUp() public pure {
        // 50% of 5 == 2.5; a threshold must not be clearable on 2.
        assertEq(V2Precision.requiredSupportUp(5, 5_000), 3);
    }

    function test_requiredSupportUp_exactStaysExact() public pure {
        assertEq(V2Precision.requiredSupportUp(10, 5_000), 5);
    }

    // =========================================================================
    // Fuzz — properties that must hold for any input
    // =========================================================================

    function testFuzz_upIsNeverBelowDown(uint256 amount, uint16 bps) public pure {
        amount = bound(amount, 0, type(uint128).max);
        vm.assume(bps <= 10_000);

        assertGe(V2Precision.bpsPortionUp(amount, bps), V2Precision.bpsPortionDown(amount, bps));
    }

    function testFuzz_upExceedsDownByAtMostOne(uint256 amount, uint16 bps) public pure {
        amount = bound(amount, 0, type(uint128).max);
        vm.assume(bps <= 10_000);

        uint256 down = V2Precision.bpsPortionDown(amount, bps);
        uint256 up = V2Precision.bpsPortionUp(amount, bps);

        assertLe(up - down, 1);
    }

    function testFuzz_portionNeverExceedsAmount(uint256 amount, uint16 bps) public pure {
        amount = bound(amount, 0, type(uint128).max);
        vm.assume(bps <= 10_000);

        // Value conservation: a share of an amount cannot exceed it.
        assertLe(V2Precision.bpsPortionDown(amount, bps), amount);
    }

    function testFuzz_allocationConservesTotal(uint256 total, uint16 firstPart) public view {
        total = bound(total, 0, type(uint128).max);
        uint256 first = bound(firstPart, 0, 10_000);

        uint256[] memory parts = new uint256[](2);
        parts[0] = first;
        parts[1] = 10_000 - first;

        (uint256[] memory amounts, uint256 remainder) = harness.allocateByBps(total, parts);

        // The property the whole library exists to guarantee: nothing is created
        // and nothing is lost.
        assertEq(amounts[0] + amounts[1] + remainder, total);
    }

    function testFuzz_remainderAssignmentSumsToTotal(uint256 total, uint16 firstPart) public view {
        total = bound(total, 0, type(uint128).max);
        uint256 first = bound(firstPart, 0, 10_000);

        uint256[] memory parts = new uint256[](2);
        parts[0] = first;
        parts[1] = 10_000 - first;

        uint256[] memory amounts = harness.allocateByBpsWithRemainderTo(total, parts, 0);

        assertEq(amounts[0] + amounts[1], total);
    }

    function testFuzz_requiredSupportNeverExceedsTotalWeight(uint256 totalWeight, uint16 bps)
        public
        pure
    {
        totalWeight = bound(totalWeight, 0, type(uint128).max);
        vm.assume(bps <= 10_000);

        assertLe(V2Precision.requiredSupportUp(totalWeight, bps), totalWeight);
    }
}
