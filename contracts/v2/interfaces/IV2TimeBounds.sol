// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IV2TimeBounds
 * @notice Canonical V2 interface defining block timestamp and number assumptions,
 *         bounds, and validation errors for the TruthBounty protocol on Optimism (OP Stack).
 * @dev Governed by PREWAVE-SC-090 (issue #766).
 *
 *      AUTHORITATIVE CLOCK SPECIFICATION:
 *      1. `block.timestamp` is the SOLE authoritative time source for all time-based state transitions
 *         (deadlines, decay intervals, timelocks, cooldowns, round lifecycle, and settlement finality).
 *      2. On Optimism (OP Stack), `block.timestamp` advances monotonically per block (target 2.0s).
 *         The sequencer timestamp drift is bounded by `max_sequencer_drift` (canonical 600s).
 *      3. All protocol deadlines require minimum duration envelopes (>= 1 hour) so that sequencer
 *         drift of <= 600s cannot prematurely expire or invalidate honest transactions.
 *      4. `block.number` reflects the L2 execution block index (~2.0s per block, ~43,200 blocks/day),
 *         which advances ~6x faster than Ethereum L1 (~12.0s per block, ~7,200 blocks/day).
 *         `block.number` MUST NEVER be used as a clock or duration measurement in protocol logic.
 *      5. Permissible uses of `block.number` are strictly bounded to:
 *         (a) Same-block mutation and reentrancy barriers (e.g. anti-double-slashing per block).
 *         (b) Historical snapshot and checkpoint indexing (e.g. voting power binary search).
 *         (c) Discrete sequence and ordering assertions within a block.
 *
 *      DEADLINE SEMANTICS (authoritative, inclusive/exclusive):
 *      - `DeadlinePassed` MUST be thrown when `block.timestamp > deadline` (deadline is INCLUSIVE;
 *        actions are valid at exactly `block.timestamp == deadline`).
 *      - `DeadlineNotReached` MUST be thrown when `block.timestamp <= deadline` (deadline is EXCLUSIVE
 *        for maturity; actions become valid strictly after `deadline`).
 *      - Appeal rollover boundaries inherit the same inclusive/exclusive rules per round.
 */
interface IV2TimeBounds {
    // =========================================================================
    // Custom Errors
    // =========================================================================

    /// @notice Thrown when an action is attempted after the deadline has expired.
    /// @param currentTimestamp Current block timestamp (`block.timestamp`).
    /// @param deadline Configured expiration timestamp.
    error DeadlinePassed(uint64 currentTimestamp, uint64 deadline);

    /// @notice Thrown when an action requiring deadline expiration is called prematurely.
    /// @param currentTimestamp Current block timestamp (`block.timestamp`).
    /// @param deadline Configured expiration timestamp that must be passed.
    error DeadlineNotReached(uint64 currentTimestamp, uint64 deadline);

    /// @notice Thrown when a proposed deadline duration is shorter than the minimum safe envelope.
    /// @param duration Proposed duration in seconds.
    /// @param minDuration Protocol minimum safe duration in seconds.
    error DeadlineTooShort(uint64 duration, uint64 minDuration);

    /// @notice Thrown when a proposed deadline duration extends beyond the maximum allowed horizon.
    /// @param duration Proposed duration in seconds.
    /// @param maxDuration Protocol maximum allowed duration in seconds.
    error DeadlineTooFar(uint64 duration, uint64 maxDuration);

    /// @notice Thrown when a round duration is outside acceptable minimum and maximum bounds.
    /// @param duration Proposed round duration in seconds.
    /// @param minDuration Minimum allowed round duration.
    /// @param maxDuration Maximum allowed round duration.
    error RoundDurationOutOfBounds(uint64 duration, uint64 minDuration, uint64 maxDuration);

    /// @notice Thrown when attempting to execute a timelocked operation before its unlock timestamp.
    /// @param currentTimestamp Current block timestamp.
    /// @param readyAt Earliest timestamp at which execution is allowed.
    error TimelockNotMatured(uint64 currentTimestamp, uint64 readyAt);

    /// @notice Thrown when a configured timelock delay violates minimum or maximum protocol envelopes.
    /// @param delay Configured delay in seconds.
    /// @param minDelay Minimum permissible timelock delay.
    /// @param maxDelay Maximum permissible timelock delay.
    error TimelockOutOfBounds(uint64 delay, uint64 minDelay, uint64 maxDelay);

    /// @notice Thrown when a proposed timelock delay change is scheduled without a mandatory
    ///         delay-increase or with an immediate decrease attempt.
    /// @param currentDelay Currently active timelock delay in seconds.
    /// @param proposedDelay Proposed new timelock delay in seconds.
    error TimelockDelayDecreaseProhibited(uint64 currentDelay, uint64 proposedDelay);

    /// @notice Thrown when a timelock delay change is scheduled while another change is pending.
    /// @param pendingReadyAt Timestamp at which the pending delay change becomes executable.
    error TimelockDelayChangeAlreadyPending(uint64 pendingReadyAt);

    /// @notice Thrown when a timelock delay change is executed before its scheduled readiness.
    /// @param currentTimestamp Current block timestamp.
    /// @param readyAt Earliest timestamp at which the delay change is executable.
    error TimelockDelayChangeNotMatured(uint64 currentTimestamp, uint64 readyAt);

    /// @notice Thrown when a scheduled timelock delay change has expired past its grace window.
    /// @param currentTimestamp Current block timestamp.
    /// @param expiry Timestamp at which the scheduled change expired.
    error TimelockDelayChangeExpired(uint64 currentTimestamp, uint64 expiry);

    /// @notice Thrown when a timelock operation is scheduled with a duplicate operation identifier.
    /// @param operationId Collision-safe operation identifier derived from target, value, data,
    ///        predecessor, and salt.
    error TimelockOperationAlreadyScheduled(bytes32 operationId);

    /// @notice Thrown when a timelock operation references a predecessor that is not yet done.
    /// @param operationId Operation identifier being executed.
    /// @param predecessor Required predecessor operation identifier.
    error TimelockPredecessorNotDone(bytes32 operationId, bytes32 predecessor);

    /// @notice Thrown when a timelock operation is executed without satisfying the self-call
    ///         requirement for delay-changing administration.
    /// @param caller Address that attempted the administrative call.
    /// @param requiredSelf Address that must be the caller (the timelock itself).
    error TimelockSelfCallRequired(address caller, address requiredSelf);

    /// @notice Thrown when block timestamp moves backwards (violating monotonicity).
    /// @param previousTimestamp Previous recorded block timestamp.
    /// @param currentTimestamp Current block timestamp.
    error TimeNotMonotonic(uint64 previousTimestamp, uint64 currentTimestamp);

    /// @notice Thrown when a decay interval of zero is supplied to decay calculation.
    error DecayIntervalZero();

    /// @notice Thrown when a zero-length time window is supplied for rate or streaming calculations.
    error RateWindowZero();

    /// @notice Thrown to reject attempts to measure elapsed time using block.number on Optimism.
    /// @param blockNumber Current or referenced L2 block number.
    /// @param l2Timestamp Authoritative L2 timestamp that must be used instead.
    error BlockNumberClockProhibited(uint256 blockNumber, uint256 l2Timestamp);

    /// @notice Thrown when a checkpoint or snapshot block is in the future.
    /// @param snapshotBlock Specified snapshot block number.
    /// @param currentBlock Current L2 block number (`block.number`).
    error FutureSnapshotBlock(uint256 snapshotBlock, uint256 currentBlock);

    /// @notice Thrown when multiple mutations of the same type occur within the same block.
    /// @param account The address restricted to single mutation per block.
    /// @param blockNumber The current block number where an action already executed.
    error SameBlockActionBlocked(address account, uint256 blockNumber);
}
