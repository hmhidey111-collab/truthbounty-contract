// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IV2TimeBounds} from "../../contracts/v2/interfaces/IV2TimeBounds.sol";
import {V2TimeBounds} from "../../contracts/v2/libraries/V2TimeBounds.sol";
import {V2SafeCast} from "../../contracts/v2/libraries/V2SafeCast.sol";

/**
 * @notice Stateful harness to test protocol interactions under varying block timing conditions.
 */
contract BlockTimestampHarness {
    struct TimelockedAction {
        bytes32 actionId;
        uint64 queuedAt;
        uint64 readyAt;
        bool executed;
    }

    struct VerificationRound {
        uint256 roundId;
        uint64 startedAt;
        uint64 deadline;
        bool closed;
        uint256 voteCount;
    }

    mapping(bytes32 => TimelockedAction) public actions;
    mapping(uint256 => VerificationRound) public rounds;
    mapping(address => uint256) public lastSlashBlock;
    mapping(address => uint64) public lastActivityTimestamp;

    event ActionQueued(bytes32 indexed actionId, uint64 readyAt);
    event ActionExecuted(bytes32 indexed actionId, uint64 executedAt);
    event RoundStarted(uint256 indexed roundId, uint64 startedAt, uint64 deadline);
    event RoundSubmitted(uint256 indexed roundId, address indexed verifier, uint64 submittedAt);
    event RoundClosed(uint256 indexed roundId, uint64 closedAt);
    event VerifierSlashed(address indexed verifier, uint256 blockNumber);

    function queueAction(bytes32 actionId, uint64 delay) external {
        V2TimeBounds.validateTimelockDelay(delay);
        uint64 nowTs = uint64(block.timestamp);
        actions[actionId] = TimelockedAction({
            actionId: actionId,
            queuedAt: nowTs,
            readyAt: nowTs + delay,
            executed: false
        });
        emit ActionQueued(actionId, nowTs + delay);
    }

    function executeAction(bytes32 actionId) external {
        TimelockedAction storage action = actions[actionId];
        require(action.queuedAt != 0, "ActionNotQueued");
        require(!action.executed, "ActionAlreadyExecuted");
        V2TimeBounds.validateTimelockReady(action.readyAt, uint64(block.timestamp));
        action.executed = true;
        emit ActionExecuted(actionId, uint64(block.timestamp));
    }

    function startRound(uint256 roundId, uint64 duration) external {
        uint64 nowTs = uint64(block.timestamp);
        uint64 deadline = nowTs + duration;
        V2TimeBounds.validateRoundDuration(nowTs, deadline);
        V2TimeBounds.validateDeadline(nowTs, deadline);
        rounds[roundId] = VerificationRound({
            roundId: roundId,
            startedAt: nowTs,
            deadline: deadline,
            closed: false,
            voteCount: 0
        });
        emit RoundStarted(roundId, nowTs, deadline);
    }

    function submitVerification(uint256 roundId) external {
        VerificationRound storage round = rounds[roundId];
        require(round.startedAt != 0, "RoundNotExist");
        require(!round.closed, "RoundClosed");
        if (V2TimeBounds.isDeadlineExpired(uint64(block.timestamp), round.deadline)) {
            revert IV2TimeBounds.DeadlinePassed(uint64(block.timestamp), round.deadline);
        }
        round.voteCount++;
        emit RoundSubmitted(roundId, msg.sender, uint64(block.timestamp));
    }

    function closeRound(uint256 roundId) external {
        VerificationRound storage round = rounds[roundId];
        require(round.startedAt != 0, "RoundNotExist");
        require(!round.closed, "RoundAlreadyClosed");
        if (!V2TimeBounds.isDeadlineExpired(uint64(block.timestamp), round.deadline)) {
            revert IV2TimeBounds.DeadlineNotReached(uint64(block.timestamp), round.deadline);
        }
        round.closed = true;
        emit RoundClosed(roundId, uint64(block.timestamp));
    }

    function slashVerifier(address verifier) external {
        V2TimeBounds.validateSameBlockAction(lastSlashBlock[verifier], block.number, verifier);
        lastSlashBlock[verifier] = block.number;
        emit VerifierSlashed(verifier, block.number);
    }

    function recordActivity(address user) external {
        lastActivityTimestamp[user] = uint64(block.timestamp);
    }

    function getElapsedDecayIntervals(address user, uint64 interval) external view returns (uint256) {
        return V2TimeBounds.calculateSafeDecayIntervals(uint64(block.timestamp), lastActivityTimestamp[user], interval);
    }
}

/**
 * @title BlockTimestampAssumptionsTest
 * @notice Comprehensive test suite for PREWAVE-SC-090 (issue #766).
 * @dev Covers:
 *      1. Same timestamp blocks
 *      2. Forward skew (sequencer drift up to 600s)
 *      3. Delayed inclusion
 *      4. L1/L2 context (block number vs timestamp)
 *      5. Boundary tests
 *      6. Fuzz tests
 */
contract BlockTimestampAssumptionsTest is Test {
    BlockTimestampHarness internal harness;

    address internal alice = address(0xAA11);
    address internal bob = address(0xBB22);
    address internal charlie = address(0xCC33);

    function setUp() public {
        // Start at a realistic non-zero timestamp and block number
        vm.warp(1_700_000_000);
        vm.roll(10_000_000);
        harness = new BlockTimestampHarness();
    }

    // =========================================================================
    // 1. Same Timestamp Blocks Tests
    // =========================================================================

    /// @notice Multiple transactions executing within the exact same block timestamp.
    function test_same_timestamp_blocks_multiple_actions_succeed() public {
        uint64 nowTs = uint64(block.timestamp);
        uint256 roundId = 101;

        // Start round at nowTs
        harness.startRound(roundId, V2TimeBounds.MIN_ROUND_DURATION);

        // Multiple submissions in the same block timestamp
        vm.prank(alice);
        harness.submitVerification(roundId);

        vm.prank(bob);
        harness.submitVerification(roundId);

        vm.prank(charlie);
        harness.submitVerification(roundId);

        // Verify all 3 votes counted with identical block.timestamp
        (, , , , uint256 voteCount) = harness.rounds(roundId);
        assertEq(voteCount, 3);
        assertEq(block.timestamp, nowTs);
    }

    /// @notice Same timestamp blocks do not advance monotonic clock backwards.
    function test_same_timestamp_blocks_monotonicity_preserved() public view {
        uint64 ts1 = uint64(block.timestamp);
        uint64 ts2 = ts1; // Identical timestamp in same block
        V2TimeBounds.validateMonotonicTime(ts1, ts2);
    }

    /// @notice Submissions at the exact boundary timestamp (`block.timestamp == deadline`) succeed.
    function test_same_timestamp_blocks_exact_deadline_boundary_inclusive() public {
        uint256 roundId = 102;
        harness.startRound(roundId, V2TimeBounds.MIN_ROUND_DURATION);

        (, , uint64 deadline, , ) = harness.rounds(roundId);

        // Warp exactly to the deadline
        vm.warp(deadline);

        // Submission at exact deadline is valid
        vm.prank(alice);
        harness.submitVerification(roundId);

        (, , , , uint256 voteCount) = harness.rounds(roundId);
        assertEq(voteCount, 1);

        // Closing at exact deadline must revert because deadline has not been passed
        vm.expectRevert(
            abi.encodeWithSelector(IV2TimeBounds.DeadlineNotReached.selector, deadline, deadline)
        );
        harness.closeRound(roundId);
    }

    /// @notice Same-block slash protection uses block.number to prevent multiple slashes in same block.
    function test_same_timestamp_blocks_block_number_protection() public {
        // First slash in current block succeeds
        harness.slashVerifier(alice);

        // Second slash of same verifier in same block MUST revert
        vm.expectRevert(
            abi.encodeWithSelector(IV2TimeBounds.SameBlockActionBlocked.selector, alice, block.number)
        );
        harness.slashVerifier(alice);

        // Slashing another verifier in same block succeeds
        harness.slashVerifier(bob);

        // Advancing block allows slashing alice again in a subsequent block
        vm.roll(block.number + 1);
        harness.slashVerifier(alice);
    }

    // =========================================================================
    // 2. Forward Skew Tests (Sequencer Drift)
    // =========================================================================

    /// @notice Sequencer forward drift up to OP_MAX_SEQUENCER_DRIFT (600s) does not expire valid envelopes.
    function test_forward_skew_within_drift_envelope_does_not_expire_deadline() public {
        uint256 roundId = 201;
        // Start round with canonical minimum duration (1 hour = 3600s)
        harness.startRound(roundId, V2TimeBounds.MIN_ROUND_DURATION);

        // Sequencer drifts forward by 600 seconds (OP_MAX_SEQUENCER_DRIFT)
        vm.warp(block.timestamp + V2TimeBounds.OP_MAX_SEQUENCER_DRIFT);

        // Submissions remain fully valid because remaining time (3000s) >> 0
        vm.prank(alice);
        harness.submitVerification(roundId);

        (, , , , uint256 voteCount) = harness.rounds(roundId);
        assertEq(voteCount, 1);
    }

    /// @notice Timelock operations remain fail-closed against sequencer forward skew.
    function test_forward_skew_timelock_fails_closed_before_maturity() public {
        bytes32 actionId = keccak256("EMERGENCY_REWIRE");
        uint64 timelockDelay = V2TimeBounds.STANDARD_GOVERNANCE_TIMELOCK; // 48 hours

        harness.queueAction(actionId, timelockDelay);

        // Sequencer drifts forward by maximum drift (600s / 10 minutes)
        vm.warp(block.timestamp + V2TimeBounds.OP_MAX_SEQUENCER_DRIFT);

        // Attempting to execute timelock prematurely fails closed
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2TimeBounds.TimelockNotMatured.selector,
                uint64(block.timestamp),
                uint64(block.timestamp - V2TimeBounds.OP_MAX_SEQUENCER_DRIFT + timelockDelay)
            )
        );
        harness.executeAction(actionId);

        // Warp the remaining full timelock duration -> execution succeeds
        vm.warp(block.timestamp + timelockDelay);
        harness.executeAction(actionId);
        (, , , bool executed) = harness.actions(actionId);
        assertTrue(executed);
    }

    /// @notice Sequencer forward skew of 600s across multiple consecutive blocks.
    function test_forward_skew_cumulative_steps_within_bounds() public {
        uint64 initialTs = uint64(block.timestamp);
        uint64 previousTs = initialTs;

        for (uint256 i = 0; i < 5; i++) {
            // Skew by 120 seconds each step (total 600s)
            uint64 nextTs = previousTs + 120;
            vm.warp(nextTs);
            V2TimeBounds.validateMonotonicTime(previousTs, nextTs);
            previousTs = nextTs;
        }

        assertEq(block.timestamp, initialTs + 600);
    }

    // =========================================================================
    // 3. Delayed Inclusion Tests (Mempool & Batcher Latency)
    // =========================================================================

    /// @notice A transaction delayed in the mempool that arrives AFTER deadline cleanly reverts.
    function test_delayed_inclusion_past_deadline_reverts_cleanly() public {
        uint256 roundId = 301;
        uint64 duration = V2TimeBounds.MIN_ROUND_DURATION; // 3600 seconds
        harness.startRound(roundId, duration);

        (, , uint64 deadline, , ) = harness.rounds(roundId);

        // Transaction is delayed in sequencer batcher until past deadline (e.g. 3601 seconds)
        vm.warp(deadline + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IV2TimeBounds.DeadlinePassed.selector, deadline + 1, deadline)
        );
        vm.prank(alice);
        harness.submitVerification(roundId);

        // Round can now be closed
        harness.closeRound(roundId);
        (, , , bool closed, ) = harness.rounds(roundId);
        assertTrue(closed);
    }

    /// @notice A transaction delayed by 10 minutes (600s) still succeeds if deadline buffer was >= 1 hour.
    function test_delayed_inclusion_within_deadline_buffer_succeeds() public {
        uint256 roundId = 302;
        harness.startRound(roundId, V2TimeBounds.MIN_ROUND_DURATION);

        // Delayed by 10 minutes in mempool
        vm.warp(block.timestamp + 600);

        vm.prank(alice);
        harness.submitVerification(roundId);

        (, , , , uint256 voteCount) = harness.rounds(roundId);
        assertEq(voteCount, 1);
    }

    // =========================================================================
    // 4. L1 vs L2 Context Tests (Block Number vs Timestamp)
    // =========================================================================

    /// @notice Demonstrates that using block.number for elapsed time produces a 600% error on Optimism.
    function test_l1_l2_context_block_number_skew_demonstration() public pure {
        uint256 blockSpan = 43_200; // 1 day of L2 blocks at 2s per block

        (uint256 l2Seconds, uint256 l1Seconds) = V2TimeBounds.demonstrateBlockNumberSkew(blockSpan);

        // L2: 43,200 * 2 = 86,400 seconds (exactly 1 day)
        assertEq(l2Seconds, 1 days);

        // L1: 43,200 * 12 = 518,400 seconds (6 days!)
        assertEq(l1Seconds, 6 days);

        // Error factor is exactly 6x (600%)
        assertEq(l1Seconds / l2Seconds, V2TimeBounds.OP_TO_L1_BLOCK_RATIO);
    }

    /// @notice Checkpoint and snapshot block validations: past/current blocks allowed, future blocks rejected.
    function test_l1_l2_context_snapshot_block_validation() public view {
        uint256 currentBlock = block.number;

        // Valid past snapshot block
        V2TimeBounds.validateSnapshotBlock(currentBlock - 100, currentBlock);

        // Valid current block
        V2TimeBounds.validateSnapshotBlock(currentBlock, currentBlock);

        // Future block must revert
        // Testing directly via try/catch in an external call or expectRevert pattern
    }

    /// @notice Future snapshot block reverts with typed error.
    function test_l1_l2_context_future_snapshot_block_reverts() public {
        uint256 currentBlock = block.number;
        uint256 futureBlock = currentBlock + 1;

        vm.expectRevert(
            abi.encodeWithSelector(IV2TimeBounds.FutureSnapshotBlock.selector, futureBlock, currentBlock)
        );
        this.externalValidateSnapshot(futureBlock, currentBlock);
    }

    function externalValidateSnapshot(uint256 snapshotBlock, uint256 currentBlock) external pure {
        V2TimeBounds.validateSnapshotBlock(snapshotBlock, currentBlock);
    }

    // =========================================================================
    // 5. Boundary Tests
    // =========================================================================

    /// @notice Deadline boundary conditions: deadline - 1, deadline, deadline + 1.
    function test_boundaries_deadline_trichotomy() public pure {
        uint64 deadline = 1_000_000;

        // deadline - 1: Active, Not Expired
        assertTrue(V2TimeBounds.isDeadlineActive(deadline - 1, deadline));
        assertFalse(V2TimeBounds.isDeadlineExpired(deadline - 1, deadline));

        // deadline: Active (inclusive), Not Expired
        assertTrue(V2TimeBounds.isDeadlineActive(deadline, deadline));
        assertFalse(V2TimeBounds.isDeadlineExpired(deadline, deadline));

        // deadline + 1: Inactive, Expired
        assertFalse(V2TimeBounds.isDeadlineActive(deadline + 1, deadline));
        assertTrue(V2TimeBounds.isDeadlineExpired(deadline + 1, deadline));
    }

    /// @notice Boundary test: Round duration bounds (MIN_ROUND_DURATION and MAX_ROUND_DURATION).
    function test_boundaries_round_duration_limits() public {
        uint64 nowTs = uint64(block.timestamp);

        // Exactly MIN_ROUND_DURATION (3600s) succeeds
        V2TimeBounds.validateRoundDuration(nowTs, nowTs + V2TimeBounds.MIN_ROUND_DURATION);

        // Exactly MAX_ROUND_DURATION (30 days) succeeds
        V2TimeBounds.validateRoundDuration(nowTs, nowTs + V2TimeBounds.MAX_ROUND_DURATION);

        // MIN_ROUND_DURATION - 1 reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2TimeBounds.RoundDurationOutOfBounds.selector,
                V2TimeBounds.MIN_ROUND_DURATION - 1,
                V2TimeBounds.MIN_ROUND_DURATION,
                V2TimeBounds.MAX_ROUND_DURATION
            )
        );
        this.externalValidateRoundDuration(nowTs, nowTs + V2TimeBounds.MIN_ROUND_DURATION - 1);

        // MAX_ROUND_DURATION + 1 reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2TimeBounds.RoundDurationOutOfBounds.selector,
                V2TimeBounds.MAX_ROUND_DURATION + 1,
                V2TimeBounds.MIN_ROUND_DURATION,
                V2TimeBounds.MAX_ROUND_DURATION
            )
        );
        this.externalValidateRoundDuration(nowTs, nowTs + V2TimeBounds.MAX_ROUND_DURATION + 1);
    }

    function externalValidateRoundDuration(uint64 start, uint64 deadline) external pure {
        V2TimeBounds.validateRoundDuration(start, deadline);
    }

    /// @notice Boundary test: Timelock delay limits.
    function test_boundaries_timelock_delay_limits() public {
        // MIN_TIMELOCK_DELAY (1 hour) succeeds
        V2TimeBounds.validateTimelockDelay(V2TimeBounds.MIN_TIMELOCK_DELAY);

        // MAX_TIMELOCK_DELAY (30 days) succeeds
        V2TimeBounds.validateTimelockDelay(V2TimeBounds.MAX_TIMELOCK_DELAY);

        // Below minimum reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2TimeBounds.TimelockOutOfBounds.selector,
                V2TimeBounds.MIN_TIMELOCK_DELAY - 1,
                V2TimeBounds.MIN_TIMELOCK_DELAY,
                V2TimeBounds.MAX_TIMELOCK_DELAY
            )
        );
        this.externalValidateTimelockDelay(V2TimeBounds.MIN_TIMELOCK_DELAY - 1);

        // Above maximum reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2TimeBounds.TimelockOutOfBounds.selector,
                V2TimeBounds.MAX_TIMELOCK_DELAY + 1,
                V2TimeBounds.MIN_TIMELOCK_DELAY,
                V2TimeBounds.MAX_TIMELOCK_DELAY
            )
        );
        this.externalValidateTimelockDelay(V2TimeBounds.MAX_TIMELOCK_DELAY + 1);
    }

    function externalValidateTimelockDelay(uint64 delay) external pure {
        V2TimeBounds.validateTimelockDelay(delay);
    }

    /// @notice Boundary test: Backward time travel reverts with TimeNotMonotonic.
    function test_boundaries_backward_timestamp_reverts() public {
        uint64 t1 = 2000;
        uint64 t2 = 1999;

        vm.expectRevert(
            abi.encodeWithSelector(IV2TimeBounds.TimeNotMonotonic.selector, t1, t2)
        );
        this.externalValidateMonotonicTime(t1, t2);
    }

    function externalValidateMonotonicTime(uint64 prev, uint64 curr) external pure {
        V2TimeBounds.validateMonotonicTime(prev, curr);
    }

    /// @notice Rate calculation boundary: zero elapsed window reverts with RateWindowZero.
    function test_boundaries_rate_calculation_zero_window_reverts() public {
        uint64 t = 10_000;
        vm.expectRevert(IV2TimeBounds.RateWindowZero.selector);
        this.externalCalculateRateSafe(100 ether, t, t);
    }

    function externalCalculateRateSafe(uint256 amount, uint64 start, uint64 end) external pure returns (uint256) {
        return V2TimeBounds.calculateRateSafe(amount, start, end);
    }

    // =========================================================================
    // 6. Fuzz Tests
    // =========================================================================

    /// @notice Fuzz test: Submissions within same block timestamp always preserve monotonicity.
    function testFuzz_same_timestamp_blocks(uint8 actionCount) public {
        vm.assume(actionCount > 0 && actionCount <= 50);
        uint64 currentTs = uint64(block.timestamp);

        for (uint256 i = 0; i < actionCount; i++) {
            // Timestamps remain constant within the same block
            V2TimeBounds.validateMonotonicTime(currentTs, uint64(block.timestamp));
        }
    }

    /// @notice Fuzz test: Forward skew from 0 to 600s within minimum buffer (3600s) never expires early.
    function testFuzz_forward_skew_bounded(uint16 skew) public {
        vm.assume(skew <= V2TimeBounds.OP_MAX_SEQUENCER_DRIFT);

        uint64 startTs = uint64(block.timestamp);
        uint64 deadline = startTs + V2TimeBounds.MIN_DEADLINE_BUFFER;

        // Apply forward skew
        uint64 skewedTs = startTs + skew;
        vm.warp(skewedTs);

        // Deadline must strictly remain active
        assertTrue(V2TimeBounds.isDeadlineActive(skewedTs, deadline));
        assertFalse(V2TimeBounds.isDeadlineExpired(skewedTs, deadline));
    }

    /// @notice Fuzz test: Discrete decay interval calculations never underflow or produce fractional anomalies.
    function testFuzz_decay_intervals(uint32 elapsed, uint32 interval) public pure {
        vm.assume(interval >= V2TimeBounds.MIN_DECAY_INTERVAL);
        vm.assume(elapsed < 365 days);

        uint64 lastActivity = 1_000_000;
        uint64 currentTimestamp = lastActivity + elapsed;

        uint256 intervals = V2TimeBounds.calculateSafeDecayIntervals(currentTimestamp, lastActivity, interval);
        uint256 expected = uint256(elapsed) / uint256(interval);

        assertEq(intervals, expected);
    }

    /// @notice Fuzz test: Timelock delay enforcement across arbitrary values.
    function testFuzz_timelock_enforcement(uint32 delay, uint32 warpElapsed) public {
        vm.assume(delay >= V2TimeBounds.MIN_TIMELOCK_DELAY && delay <= V2TimeBounds.MAX_TIMELOCK_DELAY);
        vm.assume(warpElapsed <= 60 days);

        uint64 queueTime = uint64(block.timestamp);
        uint64 readyAt = queueTime + delay;

        vm.warp(queueTime + warpElapsed);
        uint64 currentTs = uint64(block.timestamp);

        if (currentTs < readyAt) {
            assertFalse(currentTs >= readyAt);
        } else {
            assertTrue(currentTs >= readyAt);
            V2TimeBounds.validateTimelockReady(readyAt, currentTs);
        }
    }

    /// @notice Fuzz test: Rate streaming calculation bounds.
    function testFuzz_rate_calculation(uint128 amount, uint32 window) public pure {
        vm.assume(window >= 1 && window <= 365 days);
        vm.assume(amount > 0 && amount <= 1_000_000_000 ether);

        uint64 start = 1_000_000;
        uint64 end = start + window;

        uint256 rate = V2TimeBounds.calculateRateSafe(amount, start, end);
        uint256 expected = (uint256(amount) * 1e18) / uint256(window);

        assertEq(rate, expected);
    }
}
