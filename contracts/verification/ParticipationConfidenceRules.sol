// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ParticipationThresholdTypes} from "./ParticipationThresholdTypes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ParticipationConfidenceRules
 * @notice Pure integer evaluation of participation thresholds and confidence (V2-SC-014).
 * @dev Confidence for conclusive outcomes is `winningWeight * 10_000 / totalWeight` (floor division).
 *      Inconclusive outcomes always expose confidence 0. Appeal rounds scale count/weight minimums
 *      using the frozen appeal multiplier with ceiling rounding (stricter thresholds).
 */
library ParticipationConfidenceRules {
    using ParticipationThresholdTypes for ParticipationThresholdTypes.FrozenRoundConfig;

    error InvalidConfidenceBps(uint256 value);
    error InvalidAppealMultiplierBps(uint256 value);
    error WinningWeightExceedsTotal(uint256 winningWeight, uint256 totalWeight);

    /**
     * @dev Validate basis-point bounds before a round config is frozen.
     */
    function validateConfig(ParticipationThresholdTypes.FrozenRoundConfig memory config) internal pure {
        if (config.minConfidenceBps > ParticipationThresholdTypes.BPS_DENOMINATOR) {
            revert InvalidConfidenceBps(config.minConfidenceBps);
        }
        if (config.appealMultiplierBps == 0 || config.appealMultiplierBps > ParticipationThresholdTypes.BPS_DENOMINATOR * 10) {
            revert InvalidAppealMultiplierBps(config.appealMultiplierBps);
        }
    }

    /**
     * @notice Evaluate thresholds using frozen round configuration and aggregated weights.
     * @param weights Aggregated true/false weights and verifier count.
     * @param config Frozen threshold configuration for the round.
     * @param roundKind FIRST or APPEAL round selector.
     */
    function evaluate(
        ParticipationThresholdTypes.WeightTotals memory weights,
        ParticipationThresholdTypes.FrozenRoundConfig memory config,
        ParticipationThresholdTypes.RoundKind roundKind
    ) internal pure returns (ParticipationThresholdTypes.ThresholdEvaluation memory result) {
        validateConfig(config);

        result.trueWeight = weights.trueWeight;
        result.falseWeight = weights.falseWeight;
        result.totalWeight = weights.trueWeight + weights.falseWeight;

        (result.effectiveMinVerifierCount, result.effectiveMinTotalWeight, result.effectiveMinConfidenceBps) =
            _effectiveThresholds(config, roundKind);

        if (result.totalWeight == 0 || weights.verifierCount == 0) {
            return _inconclusive(result, ParticipationThresholdTypes.InconclusiveReason.ZERO_PARTICIPATION);
        }

        if (weights.verifierCount < result.effectiveMinVerifierCount) {
            return _inconclusive(result, ParticipationThresholdTypes.InconclusiveReason.INSUFFICIENT_VERIFIER_COUNT);
        }

        if (result.totalWeight < result.effectiveMinTotalWeight) {
            return _inconclusive(result, ParticipationThresholdTypes.InconclusiveReason.INSUFFICIENT_TOTAL_WEIGHT);
        }

        if (weights.trueWeight == weights.falseWeight) {
            return _inconclusive(result, ParticipationThresholdTypes.InconclusiveReason.TIE);
        }

        uint256 winningWeight =
            weights.trueWeight > weights.falseWeight ? weights.trueWeight : weights.falseWeight;
        result.confidenceBps = _confidenceBps(winningWeight, result.totalWeight);

        if (result.confidenceBps < result.effectiveMinConfidenceBps) {
            return _inconclusive(result, ParticipationThresholdTypes.InconclusiveReason.INSUFFICIENT_CONFIDENCE);
        }

        result.reason = ParticipationThresholdTypes.InconclusiveReason.NONE;
        result.outcome = weights.trueWeight > weights.falseWeight
            ? ParticipationThresholdTypes.ClaimOutcome.VERIFIED_TRUE
            : ParticipationThresholdTypes.ClaimOutcome.VERIFIED_FALSE;
        return result;
    }

    /**
     * @notice Compute confidence basis points for a conclusive candidate.
     */
    function confidenceBps(uint256 winningWeight, uint256 totalWeight) internal pure returns (uint256) {
        return _confidenceBps(winningWeight, totalWeight);
    }

    function _confidenceBps(uint256 winningWeight, uint256 totalWeight) private pure returns (uint256) {
        if (winningWeight > totalWeight) revert WinningWeightExceedsTotal(winningWeight, totalWeight);
        if (totalWeight == 0) return 0;
        return Math.mulDiv(winningWeight, ParticipationThresholdTypes.BPS_DENOMINATOR, totalWeight);
    }

    function _effectiveThresholds(
        ParticipationThresholdTypes.FrozenRoundConfig memory config,
        ParticipationThresholdTypes.RoundKind roundKind
    )
        private
        pure
        returns (uint256 minVerifierCount, uint256 minTotalWeight, uint256 minConfidenceBps)
    {
        minConfidenceBps = config.minConfidenceBps;

        if (roundKind == ParticipationThresholdTypes.RoundKind.FIRST) {
            return (config.minVerifierCount, config.minTotalWeight, minConfidenceBps);
        }

        minVerifierCount = _scaleMinimum(config.minVerifierCount, config.appealMultiplierBps);
        minTotalWeight = _scaleMinimum(config.minTotalWeight, config.appealMultiplierBps);
    }

    /// @dev Ceiling multiply keeps appeal thresholds strictly >= scaled base minimums.
    function _scaleMinimum(uint256 baseMinimum, uint256 multiplierBps) private pure returns (uint256) {
        return Math.mulDiv(
            baseMinimum,
            multiplierBps,
            ParticipationThresholdTypes.BPS_DENOMINATOR,
            Math.Rounding.Ceil
        );
    }

    function _inconclusive(
        ParticipationThresholdTypes.ThresholdEvaluation memory result,
        ParticipationThresholdTypes.InconclusiveReason reason
    ) private pure returns (ParticipationThresholdTypes.ThresholdEvaluation memory) {
        result.outcome = ParticipationThresholdTypes.ClaimOutcome.INCONCLUSIVE;
        result.reason = reason;
        result.confidenceBps = 0;
        return result;
    }
}
