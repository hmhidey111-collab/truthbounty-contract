// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Types} from "../interfaces/IV2Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ProtocolModel
/// @notice Independent reference model for TruthBounty V2 lifecycle and accounting rules.
/// @dev This is intentionally decoupled from the production state-machine library so that
///      differential tests can compare the authoritative Solidity implementation against
///      a second, reviewable model for transitions, voting outcomes, and rounding.
library ProtocolModel {
    uint256 internal constant BPS_SCALE = 10_000;

    enum ClaimOutcome {
        VERIFIED_TRUE,
        VERIFIED_FALSE,
        INCONCLUSIVE
    }

    error InvalidRoundingPolicy(uint8 roundingPolicy);
    error WinningWeightExceedsTotal(uint256 winningWeight, uint256 totalWeight);

    function calculateWeights(bool[] memory voted, bool[] memory support, uint256[] memory effectiveStake)
        internal
        pure
        returns (uint256 trueWeight, uint256 falseWeight, uint256 count)
    {
        for (uint256 i = 0; i < voted.length; ++i) {
            if (!voted[i]) continue;

            if (support[i]) {
                trueWeight += effectiveStake[i];
            } else {
                falseWeight += effectiveStake[i];
            }
            count++;
        }
    }

    function calculateConfidence(uint256 winningWeight, uint256 totalWeight)
        internal
        pure
        returns (uint256)
    {
        if (winningWeight > totalWeight) {
            revert WinningWeightExceedsTotal(winningWeight, totalWeight);
        }
        if (totalWeight == 0) return 0;
        return Math.mulDiv(winningWeight, BPS_SCALE, totalWeight);
    }

    function resolveOutcome(uint256 trueWeight, uint256 falseWeight, uint256 totalWeight)
        internal
        pure
        returns (ClaimOutcome outcome, uint256 confidence)
    {
        if (totalWeight == 0 || trueWeight == falseWeight) {
            return (ClaimOutcome.INCONCLUSIVE, 0);
        }

        if (trueWeight > falseWeight) {
            confidence = calculateConfidence(trueWeight, totalWeight);
            return (ClaimOutcome.VERIFIED_TRUE, confidence);
        }

        confidence = calculateConfidence(falseWeight, totalWeight);
        return (ClaimOutcome.VERIFIED_FALSE, confidence);
    }

    function isValidClaimTransition(IV2Types.ClaimState currentState, IV2Types.ClaimState nextState)
        internal
        pure
        returns (bool)
    {
        if (currentState == IV2Types.ClaimState.None) {
            return nextState == IV2Types.ClaimState.VerificationOpen;
        }
        if (currentState == IV2Types.ClaimState.VerificationOpen) {
            return nextState == IV2Types.ClaimState.ChallengeWindow
                || nextState == IV2Types.ClaimState.AwaitingSettlement;
        }
        if (currentState == IV2Types.ClaimState.ChallengeWindow) {
            return nextState == IV2Types.ClaimState.Disputed
                || nextState == IV2Types.ClaimState.AwaitingSettlement
                || nextState == IV2Types.ClaimState.Finalized;
        }
        if (currentState == IV2Types.ClaimState.AwaitingSettlement) {
            return nextState == IV2Types.ClaimState.Finalized;
        }
        if (currentState == IV2Types.ClaimState.Disputed) {
            return nextState == IV2Types.ClaimState.Finalized;
        }
        if (currentState == IV2Types.ClaimState.Finalized) {
            return false;
        }
        return false;
    }

    function isValidEvidenceTransition(IV2Types.EvidenceStatus currentStatus, IV2Types.EvidenceStatus nextStatus)
        internal
        pure
        returns (bool)
    {
        if (currentStatus == IV2Types.EvidenceStatus.NONE) {
            return nextStatus == IV2Types.EvidenceStatus.SUBMITTED;
        }
        if (currentStatus == IV2Types.EvidenceStatus.SUBMITTED) {
            return nextStatus == IV2Types.EvidenceStatus.ACCEPTED
                || nextStatus == IV2Types.EvidenceStatus.REJECTED
                || nextStatus == IV2Types.EvidenceStatus.REVOKED;
        }
        if (currentStatus == IV2Types.EvidenceStatus.ACCEPTED) {
            return nextStatus == IV2Types.EvidenceStatus.REVOKED;
        }
        return false;
    }

    function isValidDisputeTransition(IV2Types.DisputeStatus currentStatus, IV2Types.DisputeStatus nextStatus)
        internal
        pure
        returns (bool)
    {
        if (currentStatus == IV2Types.DisputeStatus.NONE) {
            return nextStatus == IV2Types.DisputeStatus.OPEN;
        }
        if (currentStatus == IV2Types.DisputeStatus.OPEN) {
            return nextStatus == IV2Types.DisputeStatus.RESOLVED
                || nextStatus == IV2Types.DisputeStatus.ESCALATED
                || nextStatus == IV2Types.DisputeStatus.CANCELLED;
        }
        return false;
    }

    function isValidSettlementTransition(IV2Types.SettlementStatus currentStatus, IV2Types.SettlementStatus nextStatus)
        internal
        pure
        returns (bool)
    {
        if (currentStatus == IV2Types.SettlementStatus.NONE) {
            return nextStatus == IV2Types.SettlementStatus.PENDING;
        }
        if (currentStatus == IV2Types.SettlementStatus.PENDING) {
            return nextStatus == IV2Types.SettlementStatus.EXECUTED
                || nextStatus == IV2Types.SettlementStatus.BLOCKED
                || nextStatus == IV2Types.SettlementStatus.REFUNDED;
        }
        return false;
    }

    function isClaimOpen(IV2Types.ClaimState state) internal pure returns (bool) {
        return state == IV2Types.ClaimState.VerificationOpen;
    }

    function isClaimVerified(IV2Types.ClaimState state) internal pure returns (bool) {
        return state == IV2Types.ClaimState.ChallengeWindow || state == IV2Types.ClaimState.AwaitingSettlement;
    }

    function isClaimDisputed(IV2Types.ClaimState state) internal pure returns (bool) {
        return state == IV2Types.ClaimState.Disputed;
    }

    function isTerminalSettlementStatus(IV2Types.SettlementStatus status) internal pure returns (bool) {
        return status == IV2Types.SettlementStatus.EXECUTED
            || status == IV2Types.SettlementStatus.BLOCKED
            || status == IV2Types.SettlementStatus.REFUNDED;
    }

    function validRoundingPolicy(uint8 roundingPolicy) internal pure returns (bool) {
        return roundingPolicy <= 2;
    }

    function splitAmount(uint256 total, uint256 shareBps, uint8 roundingPolicy) internal pure returns (uint256 amount) {
        if (!validRoundingPolicy(roundingPolicy)) revert InvalidRoundingPolicy(roundingPolicy);

        uint256 numerator = total * shareBps;
        uint256 floor = numerator / BPS_SCALE;
        if (shareBps == 0 || total == 0) return 0;

        if (roundingPolicy == 0) {
            return floor;
        }

        uint256 remainder = numerator % BPS_SCALE;
        if (roundingPolicy == 1) {
            return remainder == 0 ? floor : floor + 1;
        }

        // Round-half-up for the canonical model: exactly half or more rounds upward.
        return (remainder * 2 >= BPS_SCALE) ? floor + 1 : floor;
    }

    function rewardSplit(uint256 rewardPool, uint256 verifierShareBps, uint8 roundingPolicy)
        internal
        pure
        returns (uint256 verifierReward, uint256 treasuryCut)
    {
        verifierReward = splitAmount(rewardPool, verifierShareBps, roundingPolicy);
        treasuryCut = rewardPool - verifierReward;
    }
}
