// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { V2Errors } from "./V2Errors.sol";

/// @title V2Precision
/// @notice Canonical fixed-point, basis-point, weight, confidence, emission and
///         allocation arithmetic for the TruthBounty V2 protocol (V2-SC-100).
///
/// @dev ## Why this library exists
///
/// The same basis-point denominator was declared independently in seven
/// contracts under four different names — `BPS_DENOMINATOR`
/// (AppealVerificationRound, ParameterVersionRegistry, AllocationPolicies,
/// TokenomicsEngine), `BASIS_POINTS_DENOMINATOR` (FeeManager), `BASIS_POINTS`
/// (InsuranceFund) and `BPS` (EconomicSimulation) — while RewardEngine works in
/// `PERCENT_DENOMINATOR = 100`, a different scale entirely. Rounding direction
/// was decided per call site and mostly undocumented.
///
/// That is the gap this closes: one definition of each denominator, and one
/// rounding decision per operation, stated in the function name.
///
/// ## Rounding is named, never defaulted
///
/// Every operation that can lose precision exists in a `…Down` and a `…Up`
/// form. There is deliberately no unsuffixed variant: a caller must state the
/// direction, because "round however the compiler happens to" is how value
/// leaks. The convention across the protocol is to round **toward the
/// protocol** — down when paying out, up when charging or when computing a
/// support threshold that must be cleared.
///
/// ## Overflow
///
/// Solidity 0.8 checked arithmetic reverts on overflow, and `Math.mulDiv`
/// computes `a * b / d` over 512 bits so the intermediate product cannot
/// overflow even when `a * b` exceeds 2^256. Division by zero is rejected
/// explicitly with a named error rather than relying on a panic, so a caller
/// gets a diagnosable revert reason.
///
/// ## Truncation
///
/// Integer division truncates. Allocation helpers therefore return the
/// remainder alongside the parts, so dust is always accounted for rather than
/// silently dropped — see {allocateByBps}.
library V2Precision {
    // =========================================================================
    // Denominators
    // =========================================================================

    /// @notice Basis-point denominator. 10_000 bps == 100%.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Percentage denominator. 100 == 100%.
    /// @dev Retained because RewardEngine expresses shares as whole percents.
    ///      New code should prefer basis points.
    uint256 internal constant PERCENT_DENOMINATOR = 100;

    /// @notice Fixed-point scale for 18-decimal (WAD) values.
    uint256 internal constant WAD = 1e18;

    // =========================================================================
    // Core fixed-point
    // =========================================================================

    /// @notice `a * b / denominator`, truncating toward zero.
    /// @dev 512-bit intermediate, so `a * b` cannot overflow.
    function mulDivDown(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) revert V2Errors.ZeroDenominator();
        return Math.mulDiv(a, b, denominator);
    }

    /// @notice `a * b / denominator`, rounding away from zero.
    function mulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) revert V2Errors.ZeroDenominator();
        return Math.mulDiv(a, b, denominator, Math.Rounding.Ceil);
    }

    /// @notice `a * b / WAD`, truncating. For multiplying by an 18-decimal factor.
    function wadMulDown(uint256 a, uint256 wadFactor) internal pure returns (uint256) {
        return Math.mulDiv(a, wadFactor, WAD);
    }

    /// @notice `a * b / WAD`, rounding up.
    function wadMulUp(uint256 a, uint256 wadFactor) internal pure returns (uint256) {
        return Math.mulDiv(a, wadFactor, WAD, Math.Rounding.Ceil);
    }

    /// @notice `a * WAD / b`, truncating. Expresses `a / b` as an 18-decimal ratio.
    function wadDivDown(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert V2Errors.ZeroDenominator();
        return Math.mulDiv(a, WAD, b);
    }

    /// @notice `a * WAD / b`, rounding up.
    function wadDivUp(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert V2Errors.ZeroDenominator();
        return Math.mulDiv(a, WAD, b, Math.Rounding.Ceil);
    }

    // =========================================================================
    // Basis points and percents
    // =========================================================================

    /// @notice The `bps` share of `amount`, truncating. Use when paying out.
    function bpsPortionDown(uint256 amount, uint256 bps) internal pure returns (uint256) {
        requireValidBps(bps);
        return Math.mulDiv(amount, bps, BPS_DENOMINATOR);
    }

    /// @notice The `bps` share of `amount`, rounding up. Use when charging.
    function bpsPortionUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        requireValidBps(bps);
        return Math.mulDiv(amount, bps, BPS_DENOMINATOR, Math.Rounding.Ceil);
    }

    /// @notice The `percent` share of `amount`, truncating.
    function percentPortionDown(uint256 amount, uint256 percent) internal pure returns (uint256) {
        if (percent > PERCENT_DENOMINATOR) revert V2Errors.PercentOutOfRange(percent);
        return Math.mulDiv(amount, percent, PERCENT_DENOMINATOR);
    }

    /// @notice The `percent` share of `amount`, rounding up.
    function percentPortionUp(uint256 amount, uint256 percent) internal pure returns (uint256) {
        if (percent > PERCENT_DENOMINATOR) revert V2Errors.PercentOutOfRange(percent);
        return Math.mulDiv(amount, percent, PERCENT_DENOMINATOR, Math.Rounding.Ceil);
    }

    /// @notice Expresses `part` of `whole` in basis points, truncating.
    /// @dev Returns 0 when `whole` is 0: a share of nothing is nothing, which is
    ///      more useful to callers computing participation than a revert.
    function toBpsDown(uint256 part, uint256 whole) internal pure returns (uint256) {
        if (whole == 0) return 0;
        return Math.mulDiv(part, BPS_DENOMINATOR, whole);
    }

    /// @notice Expresses `part` of `whole` in basis points, rounding up.
    function toBpsUp(uint256 part, uint256 whole) internal pure returns (uint256) {
        if (whole == 0) return 0;
        return Math.mulDiv(part, BPS_DENOMINATOR, whole, Math.Rounding.Ceil);
    }

    /// @notice The `bps` share of `amount`, truncating, without validating `bps`.
    /// @dev For invariant harnesses and simulation paths that must exercise
    ///      out-of-range inputs without reverting on the validation guard.
    ///      Settlement paths must use {bpsPortionDown}.
    function bpsPortionDownUnchecked(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(amount, bps, BPS_DENOMINATOR);
    }

    /// @notice The `bps` share of `amount`, rounding up, without validating `bps`.
    /// @dev See {bpsPortionDownUnchecked}.
    function bpsPortionUpUnchecked(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(amount, bps, BPS_DENOMINATOR, Math.Rounding.Ceil);
    }

    // =========================================================================
    // Validation — fails closed
    // =========================================================================

    /// @notice Reverts unless `bps` is within `[0, BPS_DENOMINATOR]`.
    function requireValidBps(uint256 bps) internal pure {
        if (bps > BPS_DENOMINATOR) revert V2Errors.BpsOutOfRange(bps);
    }

    /// @notice Reverts unless `parts` sums to exactly `BPS_DENOMINATOR`.
    /// @dev The allocation-integrity rule FeeManager documents in prose. Exact
    ///      rather than "at most" on purpose: a split summing to less than 100%
    ///      silently strands value in the paying contract.
    function requireBpsSumExact(uint256[] memory parts) internal pure {
        uint256 total;
        for (uint256 i = 0; i < parts.length; ++i) {
            total += parts[i];
        }
        if (total != BPS_DENOMINATOR) revert V2Errors.BpsSumNotExact(total);
    }

    /// @notice Clamps `bps` into `[0, BPS_DENOMINATOR]` without reverting.
    /// @dev For reporting and simulation paths where an out-of-range input is
    ///      noise rather than an error. Settlement paths use {requireValidBps}.
    function clampBps(uint256 bps) internal pure returns (uint256) {
        return bps > BPS_DENOMINATOR ? BPS_DENOMINATOR : bps;
    }

    // =========================================================================
    // Allocation — dust is always returned, never dropped
    // =========================================================================

    /// @notice Splits `total` across `bpsParts`, truncating each part.
    /// @dev Every part rounds down, so the parts can sum to less than `total`.
    ///      The shortfall is returned as `remainder` instead of being absorbed:
    ///      the caller must decide who receives dust, and that decision belongs
    ///      to the allocation policy, not to this library.
    ///
    ///      `bpsParts` must sum to exactly `BPS_DENOMINATOR`, so
    ///      `remainder < bpsParts.length`.
    /// @return amounts Allocated amount per part, index-aligned with `bpsParts`.
    /// @return remainder `total - sum(amounts)`; strictly less than the number of parts.
    function allocateByBps(uint256 total, uint256[] memory bpsParts)
        internal
        pure
        returns (uint256[] memory amounts, uint256 remainder)
    {
        requireBpsSumExact(bpsParts);

        amounts = new uint256[](bpsParts.length);
        uint256 allocated;

        for (uint256 i = 0; i < bpsParts.length; ++i) {
            uint256 amount = Math.mulDiv(total, bpsParts[i], BPS_DENOMINATOR);
            amounts[i] = amount;
            allocated += amount;
        }

        remainder = total - allocated;
    }

    /// @notice {allocateByBps}, then assigns the remainder to one recipient.
    /// @dev Deterministic dust handling: the same inputs always put the dust in
    ///      the same place, so an allocation is reproducible from its inputs and
    ///      `sum(amounts) == total` exactly.
    /// @param remainderIndex Index in `bpsParts` that receives the dust.
    function allocateByBpsWithRemainderTo(
        uint256 total,
        uint256[] memory bpsParts,
        uint256 remainderIndex
    ) internal pure returns (uint256[] memory amounts) {
        if (remainderIndex >= bpsParts.length) revert V2Errors.IndexOutOfBounds(remainderIndex);

        uint256 remainder;
        (amounts, remainder) = allocateByBps(total, bpsParts);
        amounts[remainderIndex] += remainder;
    }

    // =========================================================================
    // Weights and confidence
    // =========================================================================

    /// @notice Weighted average of `values`, truncating.
    /// @dev Returns 0 when every weight is 0 rather than reverting: an
    ///      aggregation over no effective stake has no meaningful average, and
    ///      callers already branch on zero total weight for quorum.
    function weightedAverageDown(uint256[] memory values, uint256[] memory weights)
        internal
        pure
        returns (uint256)
    {
        if (values.length != weights.length) revert V2Errors.LengthMismatch();

        uint256 weightedTotal;
        uint256 totalWeight;

        for (uint256 i = 0; i < values.length; ++i) {
            weightedTotal += values[i] * weights[i];
            totalWeight += weights[i];
        }

        if (totalWeight == 0) return 0;
        return weightedTotal / totalWeight;
    }

    /// @notice Threshold weight that must be cleared, rounding **up**.
    /// @dev Up is the security-relevant direction: rounding a required-support
    ///      threshold down would let a vote pass on marginally less weight than
    ///      the configured percentage demands. Matches the "Round UP for
    ///      required support" rule in Aggregation.
    function requiredSupportUp(uint256 totalWeight, uint256 thresholdBps)
        internal
        pure
        returns (uint256)
    {
        requireValidBps(thresholdBps);
        return Math.mulDiv(totalWeight, thresholdBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
    }
}
