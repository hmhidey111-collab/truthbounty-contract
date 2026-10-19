// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProtocolExecutionBounds} from "../../performance/ProtocolExecutionBounds.sol";

/// @title AntiGriefing
/// @notice Pure helpers that reject dust stakes / bounties and claim-creation spam (V2-SC-105).
/// @dev Modules MUST apply these checks before mutating storage or emitting claim/stake events.
///      Thresholds are governance-configured; this library only evaluates them.
library AntiGriefing {
    /// @notice Stake or bounty is below the configured economic floor.
    error DustAmount(uint256 provided, uint256 minimum);

    /// @notice Account exceeded the per-window claim creation budget.
    error ClaimRateExceeded(address account, uint256 count, uint256 limit);

    /// @notice Account holds too many non-terminal claims (storage / indexer indexer griefing).
    error TooManyOpenClaims(address account, uint256 count, uint256 limit);

    /// @notice Submission fee was not paid in full.
    error InsufficientClaimFee(uint256 paid, uint256 required);

    /// @notice Appeal round exceeds the configured maximum depth.
    error AppealDepthExceeded(uint256 round, uint256 maxRounds);

    /// @notice Appeal bond calculation overflowed the configured cap.
    error AppealBondOverflow(uint256 computed, uint256 cap);

    /// @notice Appeal deadline has passed.
    error AppealDeadlinePassed(uint64 deadline, uint64 nowTs);

    /// @@notice Appeal cannot be opened because the claim is already terminal.
    error AppealTerminal(uint256 claimId);

    /// @notice Appeal cannot be opened because the current round is unresolved.
    error AppealRoundUnresolved(uint256 claimId, uint256 round);

    // @dev Reverts when `amount` is zero or strictly below `minimum`.
    function requireMinAmount(uint256 amount, uint256 minimum) internal pure {
        if (amount < minimum) revert DustAmount(amount, minimum);
    }

    // @dev Reverts when `paid` is below the required claim submission fee.
    function requireClaimFee(uint256 paid, uint256 required) internal pure {
        if (paid < required) revert InsufficientClaimFee(paid, required);
    }

    // @dev Sliding-window claim spam check. Returns the next window counters to persist.
    // @param account Claim creator.
    // @param nowTs Current block timestamp.
    // @param windowStart Start of the active rate window (0 if unset).
    // @param claimsInWindow Claims already created in the active window.
    // @param maxPerWindow Maximum allowed creations per window (0 => protocol default).
    // @param windowLength Window length in seconds (0 => protocol default).
    // @return newWindowStart Window start after this creation.
    // @return newClaimsInWindow Claim count after this creation.
    function nextClaimWindow(
        address account,
        uint64 nowTs,
        uint64 windowStart,
        uint256 claimsInWindow,
        uint256 maxPerWindow,
        uint64 windowLength
    ) internal pure returns (uint64 newWindowStart, uint256 newClaimsInWindow) {
        uint256 limit = maxPerWindow == 0
            ? ProtocolExecutionBounds.MAX_CLAIMS_PER_ACCOUNT_WINDOW
            : maxPerWindow;
        uint64 window = windowLength == 0
            ? uint64(ProtocolExecutionBounds.CLAIM_SPAM_WINDOW_SECONDS)
            : windowLength;

        // V2-SC-161: compare in uint256 so a window start near type(uint64).max cannot overflow
        // (panic) the uint64 sum; the comparison is otherwise identical.
        if (windowStart == 0 || uint256(nowTs) >= uint256(windowStart) + uint256(window)) {
            return (nowTs, 1);
        }

        uint256 next = claimsInWindow + 1;
        if (next > limit) revert ClaimRateExceeded(account, next, limit);
        return (windowStart, next);
    }

    // @dev Ensures open (non-terminal) claim inventory stays bounded per creator.
    function requireOpenClaimCapacity(address account, uint256 openCount, uint256 maxOpen) internal pure {
        uint256 limit = maxOpen == 0 ? ProtocolExecutionBounds.MAX_OPEN_CLAIMS_PER_CREATOR : maxOpen;
        if (openCount >= limit) revert TooManyOpenClaims(account, openCount, limit);
    }

    // -----------------------------------------------------------------------------
    // V2-SC-042: Bounded appeal depth + economic escalation
    // -----------------------------------------------------------------------------

    // @dev Returns the canonical maximum appeal round depth. A governance-supplied
    //      value of 0 falls back to the protocol default; any supplied value is
    //      clamped to the hard ceiling so no actor can extend depth indefinitely.
    function maxAppealRounds(uint256 configured) pure returns (uint256) {
        if (configured == 0) return ProtocolExecutionBounds.MAX_APPEEAL_ROUNDS;
        if (configured > ProtocolExecutionBounds.MAX_APPEEAL_ROUNDS) {
            return ProtocolExecutionBounds.MAX_APPEAL_ROUNDS;
        }
        return configured;
    }

    // @dev Reverts when an appeal attempt exceeds the final appealable round.
    //      Rounds are 1-indexed; the maximum allowed round is `maxRounds`.
    function requireAppealDepth(uint256 round, uint256 maxRounds) internal pure {
        if (round == 0 || round > maxRounds) revert AppealDepthExceeded(round, maxRounds);
    }

    // @dev Reverts when the appeal deadline has passed. The deadline is the
    //      absolute timestamp at which the current round must be appealed by.
    function requireAppealDeadline(uint64 deadline, uint64 nowTs) internal pure {
        if (nowTs > deadline) revert AppealDeadlinePassed(deadline, nowTs);
    }

    // @dev Returns the exact, bounded appeal bond for the given round.
    //      The bond grows geometrically by `multiplierBps` per round (basis points),
    //      starting from `baseBond` at round 1. The result is always clamped to
    //      `maxBond` and never exceeds it. All arithmetic is exact integer math.
    //      A multiplier of 0 is treated as 10000 bps (1.00 x), so bonds never shrink.
    function appealBondForRound(
        uint256 round,
        uint256 baseBond,
        uint256 multiplierBps,
        uint256 maxBond
    ) internal pure returns (uint256) {
        if (round == 0) return 0;
        if (baseBond == 0) return 0;
        if (maxBond == 0) return 0;

        uint256 multiplier = multiplierBps == 0 ? 10_000 : multiplierBps;

        // Exact integer geometric growth: baseBond * multiplier^(round-1) / 10000^(round-1)
        // We iterate with overflow guards and early-clamp to maxBond so the
        // computation is bounded even for adversarially large rounds.
        uint256 bond = baseBond;
        for (uint256 i = 1; i < round; ++i) {
            // bond * multiplier may overflow uint256; detect and clamp.
            if (bond > ((type(uint256).max - 1) / multiplier)) {
                return maxBond;
            }
            uint256 grown = (bond * multiplier) / 10_000;
            if (grown <= bond) {
                // Multiplier < 1.00x would shrink the bond; forbid shrinkage.
                grown = bond;
            }
            if (grown >= maxBond) return maxBond;
            bond = grown;
        }
        if (bond > maxBond) return maxBond;
        return bond;
    }

    // @dev Reverts when the computed bond exceeds the configured cap. Used by callers
    //      that want a strict cap check rather than a clamp.
    function requireBondCap(uint256 computed, uint256 cap) internal pure {
        if (cap != 0 && computed > cap) revert AppealBondOverflow(computed, cap);
    }

    // @dev Reverts when an appeal attempt is made against a terminal claim.
    function requireAppealable(bool terminal, uint256 claimId) internal pure {
        if (terminal) revert AppealTerminal(claimId);
    }

    // @dev Reverts when the current round is not yet resolved, preventing an appeal
    //      from being opened against an in-flight round.
    function requireRoundResolved(bool resolved, uint256 claimId, uint256 round) internal pure {
        if (!resolved) revert AppealRoundUnresolved(claimId, round);
    }

    // @dev Returns the next round index given the current round and the maximum.
    //      Reverts if the current round is already at the maximum, so the appeal
    //      counter is finite and cannot be reset by any actor.
    function nextAppealRound(uint256 currentRound, uint256 maxRounds) internal pure returns (uint256) {
        uint256 next = currentRound + 1;
        if (next > maxRounds) revert AppealDepthExceeded(next, maxRounds);
        return next;
    }
}
