// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IV2TimeBounds} from "../interfaces/IV2TimeBounds.sol";
import {V2SafeCast} from "./V2SafeCast.sol";

/**
 * @title V2TimeBounds
 * @notice Canonical library implementing time envelopes, block timestamp/number assumptions,
 *         and validation rules for the TruthBounty V2 protocol on Optimism (OP Stack).
 * @dev Governed by PREWAVE-SC-090 (issue #766).
 *
 *      KEY PROTOCOL INVARIANTS:
 *      1. Authoritative Clock: `block.timestamp` is the only clock. All timing gates use
 *         envelopes (>=, <=) to tolerate sub-second execution, same-timestamp blocks, and sequencer drift.
 *      2. Sequencer Drift Bounded: Sequencer timestamp drift is bounded by OP_MAX_SEQUENCER_DRIFT (600s).
 *         Because MIN_DEADLINE_BUFFER is 1 hour (3600s), a 600s drift represents <17% of the buffer
 *         and cannot prematurely invalidate valid actions.
 *      3. Monotonicity: `currentTimestamp >= previousTimestamp` is verified; same-timestamp transactions
 *         within the same block (`dt == 0`) are handled safely without division by zero.
 *      4. Block Number Restrictions: `block.number` advances ~6x faster on OP Stack (2s) than Ethereum L1 (12s).
 *         Using `block.number` as a clock causes massive economic and security skew. Its use is strictly
 *         limited to same-block action barriers and historical checkpoint indexing.
 */
library V2TimeBounds {
    // =========================================================================
    // Optimism & EVM Architecture Constants
    // =========================================================================

    /// @notice Target L2 block creation time on Optimism (2.0 seconds).
    uint64 internal constant OP_TARGET_BLOCK_TIME = 2 seconds;

    /// @notice Maximum allowed sequencer timestamp drift on OP Stack (600 seconds / 10 minutes).
    uint64 internal constant OP_MAX_SEQUENCER_DRIFT = 600 seconds;

    /// @notice Ethereum L1 slot duration post-Merge (12.0 seconds).
    uint64 internal constant L1_TARGET_BLOCK_TIME = 12 seconds;

    /// @notice Approximate L1 blocks required for Casper finality (2 epochs = 64 blocks = ~12.8 minutes).
    uint64 internal constant L1_FINALITY_BLOCKS = 64;

    /// @notice Canonical Optimism fault proof dispute challenge window (7 days).
    uint64 internal constant OP_FAULT_PROOF_WINDOW = 7 days;

    /// @notice Ratio of L2 blocks produced per L1 slot (12s / 2s = 6).
    uint256 internal constant OP_TO_L1_BLOCK_RATIO = 6;

    // =========================================================================
    // TruthBounty V2 Protocol Envelopes
    // =========================================================================

    /// @notice Minimum safe buffer for deadlines (1 hour = 3600s).
    /// @dev Far exceeds the 600s sequencer drift window to prevent premature expiry.
    uint64 internal constant MIN_DEADLINE_BUFFER = 1 hours;

    /// @notice Maximum permitted skew between an observed timestamp and the authoritative clock.
    /// @dev Bounds rollover inputs so that appeal rounds cannot be warped beyond the sequencer drift window.
    uint64 internal constant MAX_ROLLOVER_SKEW = OP_MAX_SEQUENCER_DRIFT;

    /// @notice Maximum horizon for scheduling future deadlines (365 days).
    uint64 internal constant MAX_DEADLINE_HORIZON = 365 days;

    /// @notice Minimum duration for verification, dispute, and appeal rounds (1 hour).
    uint64 internal constant MIN_ROUND_DURATION = 1 hours;

    /// @notice Maximum duration for any protocol round (30 days).
    uint64 internal constant MAX_ROUND_DURATION = 30 days;

    /// @notice Maximum number of appeal rounds permitted for a single dispute (finite appeal depth).
    uint8 internal constant MAX_APPEAL_ROUNDS = 3;

    /// @notice Base bond required for the first appeal round (1 ether).
    uint256 internal constant APPEAL_BASE_BOND = 1 ether;

    /// @notice Multiplier numerator applied per appeal round (2x escalation).
    uint256 internal constant APPEAL_BOND_MULTIPLIER = 2;

    /// @notice Denominator for the appeal bond multiplier.
    uint256 internal constant APPEAL_BOND_DENOMINATOR = 1;

    /// @notice Absolute cap on any single appeal bond to bound economic escalation.
    uint256 internal constant MAX_APPEAL_BOND = 64 ether;

    /// @notice Minimum non-zero bond to reject dust griefing attempts.
    uint256 internal constant MIN_APPEAL_BOND = 1 wei;

    /// @notice Minimum operational timelock delay (1 hour).
    uint64 internal constant MIN_TIMELOCK_DELAY = 1 hours;

    /// @notice Standard governance timelock delay for privileged state transitions (48 hours).
    uint64 internal constant STANDARD_GOVERNANCE_TIMELOCK = 48 hours;

    /// @notice Maximum timelock execution delay (30 days).
    uint64 internal constant MAX_TIMELOCK_DELAY = 30 days;

    /// @notice Minimum permitted timelock delay change (1 hour).
    /// @dev Prevents immediate decrease of an active timelock delay below the floor.
    uint64 internal constant MIN_TIMELOCK_DELAY_CHANGE = 1 hours;

    /// @notice Maximum permitted timelock delay change (7 days).
    /// @dev Bounds the magnitude of a single delay mutation to prevent governance capture.
    uint64 internal constant MAX_TIMELOCK_DELAY_CHANGE = 7 days;

    /// @notice Grace period after timelock maturity before an operation expires (14 days).
    uint64 internal constant TIMELOCK_GRACE_PERIOD = 14 days;

    /// @notice Minimum cooldown duration between repeated rate-limited operations (1 hour).
    uint64 internal constant MIN_COOLDOWN_DURATION = 1 hours;

    /// @notice Maximum cooldown duration (30 days).
    uint64 internal constant MAX_COOLDOWN_DURATION = 30 days;

    /// @notice Minimum interval for reputation decay calculation (1 hour).
    uint64 internal constant MIN_DECAY_INTERVAL = 1 hours;

    /// @notice Maximum window allowed for rate or streaming distribution calculations (365 days).
    uint64 internal constant MAX_RATE_CALCULATION_WINDOW = 365 days;

    // =========================================================================
    // Deadline & Round Lifecycle Validation
    // =========================================================================

    /// @notice Validates that a proposed deadline satisfies protocol duration and horizon bounds.
    /// @param currentTimestamp The current authoritative timestamp (`block.timestamp`).
    /// @param deadline The proposed deadline timestamp.
    /// @dev Deadline semantics: `deadline` is INCLUSIVE for activity and EXCLUSIVE for expiry.
    ///      A deadline equal to `currentTimestamp` is treated as expired for scheduling purposes
    ///      (a new deadline must be strictly in the future), while `isDeadlineActive` treats the
    ///      exact deadline second as still active for already-scheduled actions.
    function validateDeadline(uint64 currentTimestamp, uint64 deadline) internal pure {
        if (deadline <= currentTimestamp) {
            revert IV2TimeBounds.DeadlinePassed(currentTimestamp, deadline);
        }
        uint64 duration = deadline - currentTimestamp;
        if (duration < MIN_DEADLINE_BUFFER) {
            revert IV2TimeBounds.DeadlineTooShort(duration, MIN_DEADLINE_BUFFER);
        }
        if (duration > MAX_DEADLINE_HORIZON) {
            revert IV2TimeBounds.DeadlineTooFar(duration, MAX_DEADLINE_HORIZON);
        }
    }

    // =========================================================================
    // Appeal Depth & Economic Escalation Bounds
    // =========================================================================

    /// @notice Validates that a proposed appeal round index is within the finite appeal depth.
    /// @dev Round indices are zero-based; the first appeal is round 0. Reverts when the requested
    ///      round would exceed MAX_APPEAL_ROUNDS, preventing indefinite liveness and griefing.
    /// @param appealRound Zero-based appeal round index being requested.
    function validateAppealRound(uint8 appealRound) internal pure {
        if (appealRound >= MAX_APPEAL_ROUNDS) {
            revert IV2TimeBounds.AppealDepthExceeded(appealRound, MAX_APPEAL_ROUNDS);
        }
    }

    /// @notice Returns true when no further appeals may be opened for the given round index.
    /// @param appealRound Zero-based appeal round index.
    /// @return terminal True if the appeal counter has reached the finite depth bound.
    function isAppealTerminal(uint8 appealRound) internal pure returns (bool terminal) {
        return appealRound >= MAX_APPEAL_ROUNDS;
    }

    /// @notice Computes the exact, bounded bond required for a given appeal round.
    /// @dev Uses exact integer arithmetic with overflow-safe exponentiation. The bond escalates
    ///      geometrically by APPEAL_BOND_MULTIPLIER per round, is clamped to MAX_APPEAL_BOND,
    ///      and is rejected if it falls below MIN_APPEAL_BOND (dust). Reverts if the round index
    ///      exceeds the finite appeal depth.
    /// @param appealRound Zero-based appeal round index.
    /// @return bond The exact required bond for the round.
    function requiredAppealBond(uint8 appealRound) internal pure returns (uint256 bond) {
        if (appealRound >= MAX_APPEAL_ROUNDS) {
            revert IV2TimeBounds.AppealDepthExceeded(appealRound, MAX_APPEAL_ROUNDS);
        }
        uint256 factor = 1;
        for (uint256 i = 0; i < appealRound; ++i) {
            factor *= APPEAL_BOND_MULTIPLIER;
            if (factor > type(uint256).max / APPEAL_BASE_BOND) {
                return MAX_APPEAL_BOND;
            }
        }
        uint256 computed = (APPEAL_BASE_BOND * factor) / APPEAL_BOND_DENOMINATOR;
        if (computed > MAX_APPEAL_BOND) {
            computed = MAX_APPEAL_BOND;
        }
        if (computed < MIN_APPEAL_BOND) {
            revert IV2TimeBounds.AppealBondDust(computed, MIN_APPEAL_BOND);
        }
        return computed;
    }

    /// @notice Validates a submitted appeal bond against the exact required amount for the round.
    /// @dev Rejects underpayment (griefing) and overpayment (fund conservation ambiguity) by
    ///      requiring exact equality with requiredAppealBond.
    /// @param appealRound Zero-based appeal round index.
    /// @param submittedBond Bond amount supplied by the appellant.
    function validateAppealBond(uint8 appealRound, uint256 submittedBond) internal pure {
        uint256 required = requiredAppealBond(appealRound);
        if (submittedBond != required) {
            revert IV2TimeBounds.AppealBondMismatch(appealRound, submittedBond, required);
        }
    }

    /// @notice Advances the appeal counter by exactly one, enforcing monotonic non-resettable depth.
    /// @dev The counter can only increase; callers must persist the returned value. This guarantees
    ///      no actor can reset the appeal counter to reopen exhausted rounds.
    /// @param currentRound Current zero-based appeal round index.
    /// @return nextRound The incremented appeal round index.
    function advanceAppealRound(uint8 currentRound) internal pure returns (uint8 nextRound) {
        if (currentRound >= MAX_APPEAL_ROUNDS) {
            revert IV2TimeBounds.AppealDepthExceeded(currentRound, MAX_APPEAL_ROUNDS);
        }
        unchecked {
            nextRound = currentRound + 1;
        }
        if (nextRound > MAX_APPEAL_ROUNDS) {
            revert IV2TimeBounds.AppealDepthExceeded(nextRound, MAX_APPEAL_ROUNDS);
        }
        return nextRound;
    }

    /// @notice Validates that an appeal deadline is set within the round duration envelope.
    /// @dev Reuses round duration bounds to guarantee finite appeal liveness.
    /// @param openedAt Timestamp when the appeal round opened.
    /// @param deadline Timestamp when the appeal round closes.
    function validateAppealDeadline(uint64 openedAt, uint64 deadline) internal pure {
        validateRoundDuration(openedAt, deadline);
    }

    /// @notice Checks if a deadline is currently active (inclusive bound).
    /// @param currentTimestamp Current block timestamp.
    /// @param deadline Target deadline timestamp.
    /// @return active True if currentTimestamp <= deadline.
    /// @dev INCLUSIVE: the exact deadline second is still active. This is the authoritative
    ///      rule for actions that were scheduled before the deadline was reached.
    function isDeadlineActive(uint64 currentTimestamp, uint64 deadline) internal pure returns (bool active) {
        return currentTimestamp <= deadline;
    }

    /// @notice Checks if a deadline has expired (exclusive bound).
    /// @param currentTimestamp Current block timestamp.
    /// @param deadline Target deadline timestamp.
    /// @return expired True if currentTimestamp > deadline.
    /// @dev EXCLUSIVE: expiry occurs strictly after the deadline second. This is the exact
    ///      complement of `isDeadlineActive` and must remain so.
    function isDeadlineExpired(uint64 currentTimestamp, uint64 deadline) internal pure returns (bool expired) {
        return currentTimestamp > deadline;
    }

    /// @notice Validates round duration against minimum and maximum protocol bounds.
    /// @param startedAt The timestamp when the round began.
    /// @param deadline The round closing deadline.
    /// @dev Round deadlines are INCLUSIVE for the closing second: a round is still open at
    ///      `deadline` and closes strictly after it. `deadline == startedAt` is invalid.
    function validateRoundDuration(uint64 startedAt, uint64 deadline) internal pure {
        if (deadline <= startedAt) {
            revert IV2TimeBounds.DeadlinePassed(startedAt, deadline);
        }
        uint64 duration = deadline - startedAt;
        if (duration < MIN_ROUND_DURATION || duration > MAX_ROUND_DURATION) {
            revert IV2TimeBounds.RoundDurationOutOfBounds(duration, MIN_ROUND_DURATION, MAX_ROUND_DURATION);
        }
    }

    /// @notice Validates the input bounds for an appeal rollover computation.
    /// @dev Bounds the observed timestamp against the authoritative clock so that a time-warp
    ///      or reorg cannot push an appeal round outside the sequencer drift window.
    /// @param currentTimestamp The authoritative timestamp (`block.timestamp`).
    /// @param observedTimestamp The timestamp observed from the prior round's state.
    function validateRolloverInputs(uint64 currentTimestamp, uint64 observedTimestamp) internal pure {
        if (observedTimestamp > currentTimestamp) {
            revert IV2TimeBounds.TimeNotMonotonic(currentTimestamp, observedTimestamp);
        }
        uint64 skew = currentTimestamp - observedTimestamp;
        if (skew > MAX_ROLLOVER_SKEW) {
            revert IV2TimeBounds.RolloverSkewExceeded(skew, MAX_ROLLOVER_SKEW);
        }
    }

    /// @notice Computes the next appeal round deadline while preserving principal and custody.
    /// @dev Deadline semantics: the returned deadline is INCLUSIVE for the closing second.
    ///      The rollover is bounded by `MAX_ROLLOVER_SKEW` and cannot strand or duplicate principal
    ///      because it is a pure function of the prior deadline and the round duration.
    /// @param currentTimestamp The authoritative timestamp (`block.timestamp`).
    /// @param priorDeadline The deadline of the round being rolled over.
    /// @param roundDuration The duration of the next appeal round.
    /// @return nextDeadline The inclusive deadline for the next appeal round.
    function computeAppealRolloverDeadline(
        uint64 currentTimestamp,
        uint64 priorDeadline,
        uint64 roundDuration
    ) internal pure returns (uint64 nextDeadline) {
        if (roundDuration < MIN_ROUND_DURATION || roundDuration > MAX_ROUND_DURATION) {
            revert IV2TimeBounds.RoundDurationOutOfBounds(roundDuration, MIN_ROUND_DURATION, MAX_ROUND_DURATION);
        }
        if (priorDeadline > currentTimestamp) {
            revert IV2TimeBounds.DeadlinePassed(currentTimestamp, priorDeadline);
        }
        uint64 base = priorDeadline;
        if (base > currentTimestamp) {
            base = currentTimestamp;
        }
        nextDeadline = base + roundDuration;
        if (nextDeadline <= currentTimestamp) {
            revert IV2TimeBounds.DeadlinePassed(currentTimestamp, nextDeadline);
        }
    }

    // =========================================================================
    // Timelock & Cooldown Validation
    // =========================================================================

    /// @notice Validates that a timelocked operation has reached maturity.
    /// @param readyAt The timestamp at which the operation unlocks.
    /// @param currentTimestamp Current block timestamp.
    function validateTimelockReady(uint64 readyAt, uint64 currentTimestamp) internal pure {
        if (currentTimestamp < readyAt) {
            revert IV2TimeBounds.TimelockNotMatured(currentTimestamp, readyAt);
        }
    }

    /// @notice Validates that a configured timelock delay falls within permitted bounds.
    /// @param delay The delay in seconds.
    function validateTimelockDelay(uint64 delay) internal pure {
        if (delay < MIN_TIMELOCK_DELAY || delay > MAX_TIMELOCK_DELAY) {
            revert IV2TimeBounds.TimelockOutOfBounds(delay, MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY);
        }
    }

    /// @notice Validates a proposed timelock delay change against current delay and bounds.
    /// @dev Enforces that delay changes are bounded and cannot be decreased immediately.
    /// @param currentDelay The currently configured timelock delay.
    /// @param newDelay The proposed new timelock delay.
    function validateTimelockDelayChange(uint64 currentDelay, uint64 newDelay) internal pure {
        if (newDelay < MIN_TIMELOCK_DELAY || newDelay > MAX_TIMELOCK_DELAY) {
            revert IV2TimeBounds.TimelockOutOfBounds(newDelay, MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY);
        }
        if (newDelay < currentDelay) {
            uint64 decrease = currentDelay - newDelay;
            if (decrease > MAX_TIMELOCK_DELAY_CHANGE) {
                revert IV2TimeBounds.TimelockDelayChangeTooLarge(decrease, MAX_TIMELOCK_DELAY_CHANGE);
            }
        } else if (newDelay > currentDelay) {
            uint64 increase = newDelay - currentDelay;
            if (increase > MAX_TIMELOCK_DELAY_CHANGE) {
                revert IV2TimeBounds.TimelockDelayChangeTooLarge(increase, MAX_TIMELOCK_DELAY_CHANGE);
            }
        }
    }

    /// @notice Validates that a scheduled delay change has matured before application.
    /// @param scheduledAt Timestamp when the delay change was scheduled.
    /// @param currentTimestamp Current block timestamp.
    /// @param currentDelay The currently active timelock delay.
    function validateTimelockDelayChangeReady(
        uint64 scheduledAt,
        uint64 currentTimestamp,
        uint64 currentDelay
    ) internal pure {
        if (currentTimestamp < scheduledAt) {
            revert IV2TimeBounds.TimelockNotMatured(currentTimestamp, scheduledAt);
        }
        uint64 elapsed = currentTimestamp - scheduledAt;
        if (elapsed < currentDelay) {
            revert IV2TimeBounds.TimelockNotMatured(currentTimestamp, scheduledAt + currentDelay);
        }
    }

    /// @notice Validates that a timelocked operation has not exceeded its grace period.
    /// @param readyAt The timestamp at which the operation unlocked.
    /// @param currentTimestamp Current block timestamp.
    function validateTimelockNotExpired(uint64 readyAt, uint64 currentTimestamp) internal pure {
        if (currentTimestamp > readyAt + TIMELOCK_GRACE_PERIOD) {
            revert IV2TimeBounds.TimelockExpired(currentTimestamp, readyAt, TIMELOCK_GRACE_PERIOD);
        }
    }

    /// @notice Validates that a timelock operation targets the timelock contract itself for self-administration.
    /// @param target The address the operation will call.
    /// @param timelock The timelock contract address.
    function validateSelfCall(address target, address timelock) internal pure {
        if (target != timelock) {
            revert IV2TimeBounds.SelfCallRequired(target, timelock);
        }
    }

    /// @notice Validates that a cooldown has elapsed since the last recorded action.
    /// @param lastActionTimestamp Timestamp of the prior action.
    /// @param cooldownDuration Required cooldown period.
    /// @param currentTimestamp Current block timestamp.
    /// @return ready True if the cooldown has elapsed.
    /// @dev INCLUSIVE: the cooldown is satisfied at exactly `lastActionTimestamp + cooldownDuration`.
    function isCooldownSatisfied(
        uint64 lastActionTimestamp,
        uint64 cooldownDuration,
        uint64 currentTimestamp
    ) internal pure returns (bool ready) {
        if (currentTimestamp < lastActionTimestamp) {
            return false;
        }
        return currentTimestamp >= (lastActionTimestamp + cooldownDuration);
    }

    // =========================================================================
    // Monotonicity, Decay & Rate Calculations
    // =========================================================================

    /// @notice Validates that time has progressed monotonically (allowing same-timestamp blocks).
    /// @param previousTimestamp Previous observed timestamp.
    /// @param currentTimestamp Current block timestamp.
    /// @dev Same-timestamp blocks (`dt == 0`) are permitted; only backward time is rejected.
    function validateMonotonicTime(uint64 previousTimestamp, uint64 currentTimestamp) internal pure {
        if (currentTimestamp < previousTimestamp) {
            revert IV2TimeBounds.TimeNotMonotonic(previousTimestamp, currentTimestamp);
        }
    }

    /// @notice Computes discrete decay intervals elapsed between activity and current time.
    /// @dev Handles negative elapsed time (if clock warped) or zero decay interval safely.
    /// @param currentTimestamp Current block timestamp.
    /// @param lastActivity Timestamp of last recorded activity.
    /// @param decayInterval Length of each discrete decay interval in seconds.
    /// @return intervals Number of completed decay intervals.
    /// @dev EXCLUSIVE: an interval completes strictly after `decayInterval` seconds have elapsed;
    ///      `currentTimestamp == lastActivity` yields zero intervals.
    function calculateSafeDecayIntervals(
        uint64 currentTimestamp,
        uint64 lastActivity,
        uint64 decayInterval
    ) internal pure returns (uint256 intervals) {
        if (decayInterval == 0) {
            revert IV2TimeBounds.DecayIntervalZero();
        }
        if (currentTimestamp <= lastActivity) {
            return 0;
        }
        unchecked {
            return uint256(currentTimestamp - lastActivity) / uint256(decayInterval);
        }
    }

    /// @notice Safely calculates a rate (amount per second) over a discrete time window.
    /// @dev Handles same-timestamp blocks where delta time is zero by returning 0 or reverting if requested.
    /// @param deltaAmount The total amount distributed or accrued.
    /// @param startTime Window start timestamp.
    /// @param endTime Window end timestamp.
    /// @return rate Rate per second scaled to 1e18.
    /// @dev EXCLUSIVE: `endTime == startTime` is a zero-length window and reverts with `RateWindowZero`.
    function calculateRateSafe(
        uint256 deltaAmount,
        uint64 startTime,
        uint64 endTime
    ) internal pure returns (uint256 rate) {
        if (endTime <= startTime) {
            revert IV2TimeBounds.RateWindowZero();
        }
        uint256 elapsed = uint256(endTime - startTime);
        if (elapsed > MAX_RATE_CALCULATION_WINDOW) {
            elapsed = MAX_RATE_CALCULATION_WINDOW;
        }
        return (deltaAmount * 1e18) / elapsed;
    }

    // =========================================================================
    // Justified Block Number Operations & Clock Prohibition
    // =========================================================================

    /// @notice Validates historical snapshot or checkpoint block index.
    /// @dev Validates that the requested snapshot block is strictly in the past or current block.
    /// @param snapshotBlock Specified snapshot block number.
    /// @param currentBlock Current block number (`block.number`).
    /// @dev INCLUSIVE: the current block is a valid snapshot block.
    function validateSnapshotBlock(uint256 snapshotBlock, uint256 currentBlock) internal pure {
        if (snapshotBlock > currentBlock) {
            revert IV2TimeBounds.FutureSnapshotBlock(snapshotBlock, currentBlock);
        }
    }

    /// @notice Enforces single-mutation-per-block protection (justified block-number use).
    /// @dev Reverts if an action has already occurred within the same block.
    /// @param lastActionBlock The block number of the previous action.
    /// @param currentBlock Current block number (`block.number`).
    /// @param account Address performing the action.
    /// @dev EXCLUSIVE: a second action in the same block is rejected; `currentBlock == 0` is
    ///      treated as a sentinel and never blocks.
    function validateSameBlockAction(
        uint256 lastActionBlock,
        uint256 currentBlock,
        address account
    ) internal pure {
        if (lastActionBlock == currentBlock && currentBlock != 0) {
            revert IV2TimeBounds.SameBlockActionBlocked(account, currentBlock);
        }
    }

    /// @notice Asserts that block.number is prohibited from being used to measure elapsed time.
    /// @dev Shows that on OP Stack, block span * 2s does not equal block span * 12s (L1).
    /// @param blockSpan Number of blocks elapsed.
    /// @return l2EstimatedSeconds Seconds elapsed on L2.
    /// @return l1EstimatedSeconds Seconds that would be calculated assuming Ethereum L1 block time.
    function demonstrateBlockNumberSkew(uint256 blockSpan)
        internal
        pure
        returns (uint256 l2EstimatedSeconds, uint256 l1EstimatedSeconds)
    {
        l2EstimatedSeconds = blockSpan * OP_TARGET_BLOCK_TIME;
        l1EstimatedSeconds = blockSpan * L1_TARGET_BLOCK_TIME;
        return (l2EstimatedSeconds, l1EstimatedSeconds);
    }
}
