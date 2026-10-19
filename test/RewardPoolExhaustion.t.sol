// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {RewardEngine} from "../contracts/reward/RewardEngine.sol";
import {RewardDeferralQueue} from "../contracts/reward/RewardDeferralQueue.sol";
import {IRewardDeferralQueue} from "../contracts/reward/IRewardDeferralQueue.sol";
import {MockRewardEngineHarness} from "../contracts/mocks/MockRewardEngineHarness.sol";
import {MockRewardToken} from "../contracts/mocks/MockRewardToken.sol";
import {MockRewardReputationOracle} from "../contracts/mocks/MockRewardReputationOracle.sol";
import {FeeOnTransferERC20} from "../contracts/mocks/FeeOnTransferERC20.sol";

/**
 * @title RewardPoolExhaustionTest
 * @notice V2-SC-108 – Foundry unit tests for RewardEngine pool exhaustion,
 *         deferred claim paths, partial funding, RewardDeferralQueue, and
 *         emergency / pause interactions.
 */
contract RewardPoolExhaustionTest is Test {
    // =========================================================================
    // Contracts under test
    // =========================================================================

    MockRewardEngineHarness internal engine;
    RewardDeferralQueue internal queue;
    MockRewardToken internal token;
    MockRewardReputationOracle internal oracle;

    // =========================================================================
    // Actors
    // =========================================================================

    address internal admin       = makeAddr("admin");
    address internal distributor = makeAddr("distributor");
    address internal alice       = makeAddr("alice");
    address internal bob         = makeAddr("bob");
    address internal carol       = makeAddr("carol");
    address internal stranger    = makeAddr("stranger");

    // =========================================================================
    // Roles (mirrors RewardEngine constants)
    // =========================================================================

    bytes32 internal constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 internal constant PAUSER_ROLE       = keccak256("PAUSER_ROLE");
    bytes32 internal constant ADMIN_ROLE        = keccak256("ADMIN_ROLE");
    bytes32 internal ENQUEUE_ROLE;

    // =========================================================================
    // setUp
    // =========================================================================

    function setUp() public {
        // Deploy mock dependencies
        vm.startPrank(admin);

        token  = new MockRewardToken();             // mints 1B ether to admin
        oracle = new MockRewardReputationOracle();

        // Deploy the harness (which extends RewardEngine)
        engine = new MockRewardEngineHarness(
            address(oracle),
            admin,
            admin               // governanceController = admin for tests
        );

        // Configure reward token
        engine.setRewardToken(address(token));

        // Grant DISTRIBUTOR_ROLE to the distributor actor
        engine.grantRole(DISTRIBUTOR_ROLE, distributor);

        // Deploy the deferral queue; admin is DEFAULT_ADMIN_ROLE
        queue = new RewardDeferralQueue(address(engine), admin);

        // Grant ENQUEUE_ROLE to distributor on the queue
        ENQUEUE_ROLE = queue.ENQUEUE_ROLE();
        queue.grantRole(ENQUEUE_ROLE, distributor);

        // Grant DISTRIBUTOR_ROLE on the engine to the queue so it can call
        // allocateReward() during fulfillment
        engine.grantRole(DISTRIBUTOR_ROLE, address(queue));

        vm.stopPrank();

        // Give alice, bob, carol some tokens (not strictly needed for pool
        // tests, but handy for funding helpers)
        vm.prank(admin);
        token.transfer(alice, 1_000_000 ether);
        vm.prank(admin);
        token.transfer(bob,   1_000_000 ether);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Approve + fundRewardPool from admin.
    function _fund(uint256 amount) internal {
        vm.startPrank(admin);
        token.approve(address(engine), amount);
        engine.fundRewardPool(amount);
        vm.stopPrank();
    }

    function _makeSettlementId(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode("settlement", n));
    }

    function _makeCalcId(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode("calc", n));
    }

    /// @dev Allocate a reward as the distributor.
    function _allocate(
        address recipient,
        uint256 claimId,
        bytes32 sId,
        bytes32 cId,
        uint256 amount,
        bool immediate
    ) internal returns (bytes32 distributionId) {
        vm.prank(distributor);
        distributionId = engine.allocateReward(
            recipient, claimId, sId, cId, amount, immediate
        );
    }

    /// @dev Compute the distributionId the same way the engine does.
    function _distributionId(
        address r,
        uint256 c,
        bytes32 s,
        bytes32 k
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(r, c, s, k));
    }

    // =========================================================================
    // ─── Positive Tests ────────────────────────────────────────────────────
    // =========================================================================

    function test_fundRewardPool_increasesTotalFunded() public {
        _fund(500 ether);
        assertEq(engine.totalFunded(), 500 ether);
    }

    function test_fundRewardPool_multipleDeposits_accumulate() public {
        _fund(100 ether);
        _fund(200 ether);
        _fund(300 ether);
        assertEq(engine.totalFunded(), 600 ether);
    }

    function test_allocate_deferred_updatesAllCounters() public {
        _fund(1000 ether);

        bytes32 sId = _makeSettlementId(1);
        bytes32 cId = _makeCalcId(1);
        bytes32 distId = _allocate(alice, 1, sId, cId, 100 ether, false);

        assertEq(engine.totalAllocated(), 100 ether);
        assertEq(engine.totalReserved(), 100 ether);
        assertEq(engine.totalDistributed(), 0);
        assertEq(engine.claimableRewards(alice), 100 ether);

        (,,,,,, RewardEngine.DistributionStatus status,) =
            _unpackDistribution(distId);
        assertEq(uint8(status), uint8(RewardEngine.DistributionStatus.CLAIMABLE));
    }

    function test_allocate_immediate_sendsTokensDirectly() public {
        _fund(1000 ether);
        uint256 aliceBefore = token.balanceOf(alice);

        bytes32 sId = _makeSettlementId(2);
        bytes32 cId = _makeCalcId(2);
        _allocate(alice, 2, sId, cId, 50 ether, true);

        assertEq(token.balanceOf(alice), aliceBefore + 50 ether);
        assertEq(engine.totalDistributed(), 50 ether);
        assertEq(engine.totalReserved(), 0);
    }

    function test_claim_deferred_transfersTokensAndUpdatesCounters() public {
        _fund(500 ether);
        bytes32 sId = _makeSettlementId(3);
        bytes32 cId = _makeCalcId(3);
        bytes32 distId = _allocate(alice, 3, sId, cId, 75 ether, false);

        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        engine.claimReward(distId);

        assertEq(token.balanceOf(alice), aliceBefore + 75 ether);
        assertEq(engine.totalDistributed(), 75 ether);
        assertEq(engine.totalReserved(), 0);
        assertEq(engine.claimableRewards(alice), 0);
    }

    function test_availableRewardBalance_reflectsReservations() public {
        _fund(200 ether);

        // Before any allocations
        assertEq(engine.availableRewardBalance(), 200 ether);

        // Deferred allocation reserves tokens
        bytes32 sId = _makeSettlementId(4);
        bytes32 cId = _makeCalcId(4);
        _allocate(alice, 4, sId, cId, 80 ether, false);

        assertEq(engine.availableRewardBalance(), 120 ether);
    }

    function test_exhaustedPool_refunded_thenAllocationSucceeds() public {
        // Fund 100, allocate all 100 immediately, then fund 50 more and allocate 50
        _fund(100 ether);
        _allocate(alice, 10, _makeSettlementId(10), _makeCalcId(10), 100 ether, true);
        assertEq(engine.availableRewardBalance(), 0);

        _fund(50 ether);
        assertEq(engine.availableRewardBalance(), 50 ether);

        // Should succeed now
        _allocate(alice, 11, _makeSettlementId(11), _makeCalcId(11), 50 ether, true);
        assertEq(engine.availableRewardBalance(), 0);
    }

    function test_deferralQueue_enqueueAndFulfillWhenPoolFilled() public {
        // Pool is empty – enqueue
        vm.prank(distributor);
        bytes32 qId = queue.enqueue(
            alice, 20,
            _makeSettlementId(20),
            _makeCalcId(20),
            100 ether
        );

        assertTrue(queue.isPending(qId));
        assertFalse(queue.canFulfill(qId));

        // Fund the engine
        _fund(200 ether);
        assertTrue(queue.canFulfill(qId));

        uint256 aliceBefore = token.balanceOf(alice);

        // Anyone can fulfill
        vm.prank(stranger);
        queue.fulfill(qId);

        assertTrue(queue.isFulfilled(qId));
        assertEq(token.balanceOf(alice), aliceBefore + 100 ether);
    }

    function test_deferralQueue_fulfillBatch_allPending() public {
        _fund(300 ether);

        bytes32[] memory ids = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(distributor);
            ids[i] = queue.enqueue(
                alice,
                100 + i,
                _makeSettlementId(100 + i),
                _makeCalcId(100 + i),
                50 ether
            );
        }

        vm.prank(stranger);
        queue.fulfillBatch(ids);

        for (uint256 i = 0; i < 3; i++) {
            assertTrue(queue.isFulfilled(ids[i]));
        }
        assertEq(queue.totalFulfilled(), 3);
    }

    function test_deferralQueue_canFulfill_returnsTrueAfterRefill() public {
        vm.prank(distributor);
        bytes32 qId = queue.enqueue(
            bob, 200,
            _makeSettlementId(200),
            _makeCalcId(200),
            77 ether
        );

        assertFalse(queue.canFulfill(qId));

        _fund(100 ether);
        assertTrue(queue.canFulfill(qId));
    }

    // =========================================================================
    // ─── Negative / Revert Tests ───────────────────────────────────────────
    // =========================================================================

    function test_allocate_revertsWhenPoolExhausted() public {
        // Pool is empty – any allocation must revert
        vm.prank(distributor);
        vm.expectRevert(RewardEngine.InsufficientRewardPool.selector);
        engine.allocateReward(
            alice, 300,
            _makeSettlementId(300),
            _makeCalcId(300),
            1 ether,
            false
        );
    }

    function test_allocate_revertsWhenPoolPartiallyExhausted() public {
        // Fund 100, reserve 90 via deferred, then attempt to allocate 11
        _fund(100 ether);
        _allocate(alice, 400, _makeSettlementId(400), _makeCalcId(400), 90 ether, false);
        // available = 10 ether

        vm.prank(distributor);
        vm.expectRevert(RewardEngine.InsufficientRewardPool.selector);
        engine.allocateReward(
            bob, 401,
            _makeSettlementId(401),
            _makeCalcId(401),
            11 ether,
            false
        );
    }

    function test_fundPool_revertsOnZeroAmount() public {
        vm.prank(admin);
        token.approve(address(engine), 1 ether);
        vm.prank(admin);
        vm.expectRevert(RewardEngine.InvalidRewardAmount.selector);
        engine.fundRewardPool(0);
    }

    function test_fundPool_revertsWithoutTokenSet() public {
        // Deploy a fresh engine without setting a token
        MockRewardEngineHarness freshEngine = new MockRewardEngineHarness(
            address(oracle),
            admin,
            admin
        );

        vm.prank(admin);
        vm.expectRevert(RewardEngine.RewardTokenNotConfigured.selector);
        freshEngine.fundRewardPool(100 ether);
    }

    function test_claim_revertsForWrongRecipient() public {
        _fund(100 ether);
        bytes32 distId = _allocate(alice, 500, _makeSettlementId(500), _makeCalcId(500), 10 ether, false);

        vm.prank(bob);
        vm.expectRevert(RewardEngine.UnauthorizedRewardClaim.selector);
        engine.claimReward(distId);
    }

    function test_claim_revertsForNonClaimableStatus() public {
        _fund(100 ether);
        // Immediate allocation → status = DISTRIBUTED, not CLAIMABLE
        bytes32 distId = _allocate(alice, 501, _makeSettlementId(501), _makeCalcId(501), 10 ether, true);

        vm.prank(alice);
        vm.expectRevert(RewardEngine.RewardNotClaimable.selector);
        engine.claimReward(distId);
    }

    function test_allocate_revertsForDuplicateSettlement() public {
        _fund(200 ether);
        bytes32 sId = _makeSettlementId(600);
        bytes32 cId = _makeCalcId(600);

        _allocate(alice, 600, sId, cId, 10 ether, false);

        vm.prank(distributor);
        vm.expectRevert(RewardEngine.DuplicateRewardSettlement.selector);
        engine.allocateReward(alice, 600, sId, cId, 10 ether, false);
    }

    function test_deferralQueue_enqueue_revertsWithoutRole() public {
        vm.prank(stranger);
        vm.expectRevert(); // AccessControl: missing role
        queue.enqueue(
            alice, 700,
            _makeSettlementId(700),
            _makeCalcId(700),
            5 ether
        );
    }

    function test_deferralQueue_fulfill_revertsWhenPoolStillEmpty() public {
        vm.prank(distributor);
        bytes32 qId = queue.enqueue(
            alice, 800,
            _makeSettlementId(800),
            _makeCalcId(800),
            50 ether
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IRewardDeferralQueue.InsufficientPoolForFulfillment.selector,
                qId,
                50 ether,
                0
            )
        );
        queue.fulfill(qId);
    }

    function test_deferralQueue_doubleFulfill_reverts() public {
        _fund(200 ether);

        vm.prank(distributor);
        bytes32 qId = queue.enqueue(
            alice, 900,
            _makeSettlementId(900),
            _makeCalcId(900),
            20 ether
        );

        queue.fulfill(qId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRewardDeferralQueue.AlreadyFulfilled.selector,
                qId
            )
        );
        queue.fulfill(qId);
    }

    function test_deferralQueue_cancelThenFulfill_reverts() public {
        _fund(100 ether);

        vm.prank(distributor);
        bytes32 qId = queue.enqueue(
            alice, 1000,
            _makeSettlementId(1000),
            _makeCalcId(1000),
            10 ether
        );

        vm.prank(admin);
        queue.cancelEnqueued(qId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRewardDeferralQueue.AlreadyCancelled.selector,
                qId
            )
        );
        queue.fulfill(qId);
    }

    // =========================================================================
    // ─── Boundary Tests ────────────────────────────────────────────────────
    // =========================================================================

    function test_allocate_exactlyExhaustingPool() public {
        _fund(100 ether);
        // Reserve 60 first
        _allocate(alice, 2000, _makeSettlementId(2000), _makeCalcId(2000), 60 ether, false);
        // available = 40; allocate exactly 40
        bytes32 distId = _allocate(bob, 2001, _makeSettlementId(2001), _makeCalcId(2001), 40 ether, false);

        assertEq(engine.availableRewardBalance(), 0);
        assertEq(engine.claimableRewards(alice), 60 ether);
        assertEq(engine.claimableRewards(bob), 40 ether);
        assertEq(distId, _distributionId(bob, 2001, _makeSettlementId(2001), _makeCalcId(2001)));
    }

    function test_allocate_oneWeiOverExhaustion_reverts() public {
        _fund(100 ether);
        _allocate(alice, 2100, _makeSettlementId(2100), _makeCalcId(2100), 100 ether, false);
        // available = 0; try to allocate 1 wei
        vm.prank(distributor);
        vm.expectRevert(RewardEngine.InsufficientRewardPool.selector);
        engine.allocateReward(
            bob, 2101,
            _makeSettlementId(2101),
            _makeCalcId(2101),
            1,
            false
        );
    }

    function test_claimBatch_maxBatchSize() public {
        uint256 N = 100;
        _fund(N * 1 ether);

        bytes32[] memory ids = new bytes32[](N);
        for (uint256 i = 0; i < N; i++) {
            ids[i] = _allocate(
                alice,
                3000 + i,
                _makeSettlementId(3000 + i),
                _makeCalcId(3000 + i),
                1 ether,
                false
            );
        }

        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        engine.claimRewardsBatch(ids);

        assertEq(token.balanceOf(alice), aliceBefore + N * 1 ether);
        assertEq(engine.totalDistributed(), N * 1 ether);
    }

    function test_claimBatch_exceedMaxBatchSize_reverts() public {
        uint256 N = engine.MAX_DISTRIBUTION_BATCH_SIZE() + 1;
        bytes32[] memory ids = new bytes32[](N);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                RewardEngine.DistributionBatchTooLarge.selector,
                N,
                engine.MAX_DISTRIBUTION_BATCH_SIZE()
            )
        );
        engine.claimRewardsBatch(ids);
    }

    function test_deferralQueue_fulfillBatch_maxBatchSize() public {
        uint256 N = queue.MAX_BATCH();
        _fund(N * 1 ether);

        bytes32[] memory ids = new bytes32[](N);
        for (uint256 i = 0; i < N; i++) {
            vm.prank(distributor);
            ids[i] = queue.enqueue(
                alice,
                4000 + i,
                _makeSettlementId(4000 + i),
                _makeCalcId(4000 + i),
                1 ether
            );
        }

        vm.prank(stranger);
        queue.fulfillBatch(ids);

        assertEq(queue.totalFulfilled(), N);
    }

    function test_deferralQueue_fulfillBatch_exceedMax_reverts() public {
        uint256 N = queue.MAX_BATCH() + 1;
        bytes32[] memory ids = new bytes32[](N);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRewardDeferralQueue.BatchTooLarge.selector,
                N,
                queue.MAX_BATCH()
            )
        );
        queue.fulfillBatch(ids);
    }

    function test_fundPool_exactMaxUint_cap() public {
        // Confirm that funding a very large but not overflow-inducing value works.
        // We can fund at most what admin holds: 1B ether total, minus amounts
        // already given to alice/bob.
        uint256 adminBalance = token.balanceOf(admin);
        vm.prank(admin);
        token.approve(address(engine), adminBalance);
        vm.prank(admin);
        engine.fundRewardPool(adminBalance);

        assertEq(engine.totalFunded(), adminBalance);
    }

    // =========================================================================
    // ─── Authorization Tests ───────────────────────────────────────────────
    // =========================================================================

    function test_allocate_revertsForNonDistributor() public {
        _fund(100 ether);
        vm.prank(stranger);
        vm.expectRevert(); // AccessControl: missing DISTRIBUTOR_ROLE
        engine.allocateReward(
            alice, 5000,
            _makeSettlementId(5000),
            _makeCalcId(5000),
            1 ether,
            false
        );
    }

    function test_pause_preventsAllocation() public {
        _fund(100 ether);
        vm.prank(admin);
        engine.pause();

        vm.prank(distributor);
        vm.expectRevert(); // Pausable: paused
        engine.allocateReward(
            alice, 5100,
            _makeSettlementId(5100),
            _makeCalcId(5100),
            1 ether,
            false
        );
    }

    function test_pause_preventsClaim() public {
        _fund(100 ether);
        bytes32 distId = _allocate(alice, 5200, _makeSettlementId(5200), _makeCalcId(5200), 10 ether, false);

        vm.prank(admin);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert(); // Pausable: paused
        engine.claimReward(distId);
    }

    function test_pause_preventsClaimBatch() public {
        _fund(100 ether);
        bytes32 distId = _allocate(alice, 5300, _makeSettlementId(5300), _makeCalcId(5300), 10 ether, false);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = distId;

        vm.prank(admin);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert(); // Pausable: paused
        engine.claimRewardsBatch(ids);
    }

    function test_unpause_restoresAllocation() public {
        _fund(100 ether);
        vm.prank(admin);
        engine.pause();

        vm.prank(admin);
        engine.unpause();

        // Should succeed now
        _allocate(alice, 5400, _makeSettlementId(5400), _makeCalcId(5400), 1 ether, false);
        assertEq(engine.totalAllocated(), 1 ether);
    }

    function test_pause_revertsForNonPauser() public {
        vm.prank(stranger);
        vm.expectRevert(); // AccessControl: missing PAUSER_ROLE
        engine.pause();
    }

    function test_setRewardToken_revertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(); // GovernanceOwnable: unauthorized
        engine.setRewardToken(address(token));
    }

    function test_deferralQueue_cancel_revertsForNonAdmin() public {
        vm.prank(distributor);
        bytes32 qId = queue.enqueue(
            alice, 5500,
            _makeSettlementId(5500),
            _makeCalcId(5500),
            5 ether
        );

        vm.prank(stranger);
        vm.expectRevert(); // AccessControl: missing DEFAULT_ADMIN_ROLE
        queue.cancelEnqueued(qId);
    }

    // =========================================================================
    // ─── Replay / Double-Claim Tests ──────────────────────────────────────
    // =========================================================================

    function test_claimReward_doubleClaimReverts() public {
        _fund(100 ether);
        bytes32 distId = _allocate(alice, 6000, _makeSettlementId(6000), _makeCalcId(6000), 10 ether, false);

        vm.prank(alice);
        engine.claimReward(distId);

        vm.prank(alice);
        vm.expectRevert(RewardEngine.RewardNotClaimable.selector);
        engine.claimReward(distId);
    }

    function test_claimBatch_doubleClaimReverts() public {
        _fund(100 ether);
        bytes32 distId = _allocate(alice, 6100, _makeSettlementId(6100), _makeCalcId(6100), 5 ether, false);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = distId;

        vm.prank(alice);
        engine.claimRewardsBatch(ids);

        // Second batch claim should revert
        vm.prank(alice);
        vm.expectRevert(RewardEngine.RewardNotClaimable.selector);
        engine.claimRewardsBatch(ids);
    }

    function test_allocate_replaySettlementReverts() public {
        _fund(200 ether);
        bytes32 sId = _makeSettlementId(6200);
        bytes32 cId = _makeCalcId(6200);

        _allocate(alice, 6200, sId, cId, 10 ether, true);

        vm.prank(distributor);
        vm.expectRevert(RewardEngine.DuplicateRewardSettlement.selector);
        engine.allocateReward(alice, 6200, sId, cId, 10 ether, true);
    }

    function test_deferralQueue_replayEnqueueDifferentNonce_succeeds() public {
        // Same params twice → different queueIds because of nonce
        vm.prank(distributor);
        bytes32 qId1 = queue.enqueue(
            alice, 6300,
            _makeSettlementId(6300),
            _makeCalcId(6300),
            5 ether
        );

        vm.prank(distributor);
        bytes32 qId2 = queue.enqueue(
            alice, 6300,
            _makeSettlementId(6300),
            _makeCalcId(6300),
            5 ether
        );

        assertFalse(qId1 == qId2, "QueueIds must be distinct");
        assertTrue(queue.isPending(qId1));
        assertTrue(queue.isPending(qId2));
        assertEq(queue.totalEnqueued(), 2);
    }

    // =========================================================================
    // ─── Emergency / Pause Interaction Tests ─────────────────────────────
    // =========================================================================

    function test_emergencyPause_preventsAllocationAndClaim() public {
        _fund(200 ether);
        bytes32 distId = _allocate(alice, 7000, _makeSettlementId(7000), _makeCalcId(7000), 10 ether, false);

        vm.prank(admin);
        engine.pause();

        // Allocation blocked
        vm.prank(distributor);
        vm.expectRevert();
        engine.allocateReward(
            bob, 7001,
            _makeSettlementId(7001),
            _makeCalcId(7001),
            1 ether,
            false
        );

        // Claim blocked
        vm.prank(alice);
        vm.expectRevert();
        engine.claimReward(distId);
    }

    function test_emergencyUnpause_restoresBothOps() public {
        _fund(200 ether);
        bytes32 distId = _allocate(alice, 7100, _makeSettlementId(7100), _makeCalcId(7100), 10 ether, false);

        vm.prank(admin);
        engine.pause();

        vm.prank(admin);
        engine.unpause();

        // Allocation works
        _allocate(bob, 7101, _makeSettlementId(7101), _makeCalcId(7101), 5 ether, false);

        // Claim works
        vm.prank(alice);
        engine.claimReward(distId);
    }

    function test_queuedClaims_survivePauseAndUnpause() public {
        // Enqueue while engine is paused (queue itself is not pausable)
        vm.prank(admin);
        engine.pause();

        vm.prank(distributor);
        bytes32 qId = queue.enqueue(
            alice, 7200,
            _makeSettlementId(7200),
            _makeCalcId(7200),
            30 ether
        );

        assertTrue(queue.isPending(qId));

        // Unpause and fund
        vm.prank(admin);
        engine.unpause();

        _fund(100 ether);

        // Fulfill after unpause
        queue.fulfill(qId);
        assertTrue(queue.isFulfilled(qId));
    }

    function test_poolExhaustion_duringEmergencyPause_behaviorCorrect() public {
        // Fund, then drain, then pause – confirm allocation still reverts with
        // pool error (pause check runs before pool check in the modifier chain,
        // so we actually get the paused revert first; both are valid test outcomes)
        _fund(50 ether);

        // Drain the pool so it is exhausted
        engine.drainPool(50 ether);
        assertEq(engine.availableRewardBalance(), 0);

        vm.prank(admin);
        engine.pause();

        vm.prank(distributor);
        // When paused, Pausable reverts before the pool check
        vm.expectRevert();
        engine.allocateReward(
            alice, 7300,
            _makeSettlementId(7300),
            _makeCalcId(7300),
            1 ether,
            false
        );
    }

    // =========================================================================
    // ─── Failure Path Tests ───────────────────────────────────────────────
    // =========================================================================

    function test_allocateBatch_revertsIfAnyEntryExceedsPool() public {
        // Fund exactly 200, then submit a batch whose middle entry pushes over
        _fund(200 ether);

        address[] memory recipients  = new address[](3);
        uint256[] memory claimIds    = new uint256[](3);
        bytes32[] memory sIds        = new bytes32[](3);
        bytes32[] memory cIds        = new bytes32[](3);
        uint256[] memory amounts     = new uint256[](3);
        bool[]    memory immediate   = new bool[](3);

        recipients[0] = alice;  claimIds[0] = 8000;
        recipients[1] = bob;    claimIds[1] = 8001;
        recipients[2] = carol;  claimIds[2] = 8002;

        for (uint256 i = 0; i < 3; i++) {
            sIds[i] = _makeSettlementId(8000 + i);
            cIds[i] = _makeCalcId(8000 + i);
            immediate[i] = false;
        }

        amounts[0] = 100 ether;   // ok
        amounts[1] = 200 ether;   // this will overflow available (200 - 100 = 100 available)
        amounts[2] = 10 ether;    // would be fine, but never reached

        vm.prank(distributor);
        vm.expectRevert(RewardEngine.InsufficientRewardPool.selector);
        engine.allocateRewardsBatch(
            recipients, claimIds, sIds, cIds, amounts, immediate
        );
    }

    function test_claimBatch_revertsIfAnyDistributionNotOwned() public {
        _fund(200 ether);
        bytes32 aliceDist = _allocate(alice, 8100, _makeSettlementId(8100), _makeCalcId(8100), 10 ether, false);
        bytes32 bobDist   = _allocate(bob,   8101, _makeSettlementId(8101), _makeCalcId(8101), 10 ether, false);

        // alice tries to batch-claim her own + bob's distribution → should revert
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = aliceDist;
        ids[1] = bobDist;

        vm.prank(alice);
        vm.expectRevert(RewardEngine.UnauthorizedRewardClaim.selector);
        engine.claimRewardsBatch(ids);
    }

    function test_fundPool_feeOnTransferToken_reverts() public {
        // Deploy a fee-on-transfer token and configure it on a fresh engine.
        // When we try to fundRewardPool the engine will receive fewer tokens
        // than the `amount` parameter specifies.  The engine uses safeTransferFrom
        // which succeeds at the ERC20 level but the actual balance deposited is
        // less – this verifies accounting integrity (the engine trusts the
        // reported amount, not the actual balance delta).
        //
        // A protocol-level defence against fee-on-transfer tokens is to verify
        // the balance before/after.  The current engine does NOT do this, so this
        // test documents the known behaviour: fundRewardPool succeeds but
        // totalFunded will be over-stated relative to the real balance.
        //
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20("FOT", "FOT", 100); // 1% fee
        feeToken.mint(admin, 10_000 ether);

        MockRewardEngineHarness fotEngine = new MockRewardEngineHarness(
            address(oracle),
            admin,
            admin
        );

        vm.prank(admin);
        fotEngine.setRewardToken(address(feeToken));

        vm.prank(admin);
        feeToken.approve(address(fotEngine), 1_000 ether);

        // fundRewardPool will succeed at the ERC20 level.
        vm.prank(admin);
        fotEngine.fundRewardPool(1_000 ether);

        // Actual balance is less than totalFunded because of the fee
        uint256 actualBalance = feeToken.balanceOf(address(fotEngine));
        assertLt(actualBalance, fotEngine.totalFunded());
    }

    // =========================================================================
    // ─── Event / Storage Reconciliation Tests ────────────────────────────
    // =========================================================================

    function test_rewardAllocated_eventFieldsMatchStorage() public {
        _fund(500 ether);

        bytes32 sId = _makeSettlementId(9000);
        bytes32 cId = _makeCalcId(9000);
        bytes32 expectedDistId = _distributionId(alice, 9000, sId, cId);

        vm.expectEmit(true, true, true, true);
        emit RewardEngine.RewardAllocated(
            alice,
            9000,
            sId,
            expectedDistId,
            50 ether,
            false
        );

        vm.prank(distributor);
        bytes32 actualDistId = engine.allocateReward(alice, 9000, sId, cId, 50 ether, false);

        assertEq(actualDistId, expectedDistId);

        // Verify storage
        (
            address recipient,
            uint256 claimId,
            bytes32 storedSId,
            bytes32 storedCId,
            uint256 amount,
            ,
            RewardEngine.DistributionStatus status,
            bytes32 storedDistId
        ) = _unpackDistribution(actualDistId);

        assertEq(recipient, alice);
        assertEq(claimId, 9000);
        assertEq(storedSId, sId);
        assertEq(storedCId, cId);
        assertEq(amount, 50 ether);
        assertEq(uint8(status), uint8(RewardEngine.DistributionStatus.CLAIMABLE));
        assertEq(storedDistId, expectedDistId);
    }

    function test_rewardClaimed_eventFieldsMatchStorage() public {
        _fund(200 ether);
        bytes32 sId = _makeSettlementId(9100);
        bytes32 cId = _makeCalcId(9100);
        bytes32 distId = _allocate(alice, 9100, sId, cId, 25 ether, false);

        vm.expectEmit(true, true, false, true);
        emit RewardEngine.RewardClaimed(alice, distId, 25 ether);

        vm.prank(alice);
        engine.claimReward(distId);

        // Post-claim storage check
        (,,,,, , RewardEngine.DistributionStatus status,) = _unpackDistribution(distId);
        assertEq(uint8(status), uint8(RewardEngine.DistributionStatus.DISTRIBUTED));
    }

    function test_rewardEnqueued_eventFieldsMatchStorage() public {
        bytes32 sId = _makeSettlementId(9200);
        bytes32 cId = _makeCalcId(9200);

        // We cannot predict queueId without knowing the nonce/timestamp, so we
        // capture it via expectEmit with checkTopic1=false for the queueId field,
        // then verify the stored entry.
        vm.expectEmit(false, true, true, true);
        emit IRewardDeferralQueue.RewardEnqueued(bytes32(0), alice, 9200, 15 ether);

        vm.prank(distributor);
        bytes32 qId = queue.enqueue(alice, 9200, sId, cId, 15 ether);

        // Verify stored entry
        IRewardDeferralQueue.PendingReward memory entry = queue.pendingEntry(qId);
        assertEq(entry.recipient, alice);
        assertEq(entry.claimId, 9200);
        assertEq(entry.settlementId, sId);
        assertEq(entry.calculationId, cId);
        assertEq(entry.amount, 15 ether);
        assertEq(uint8(entry.status), uint8(IRewardDeferralQueue.QueueStatus.PENDING));
    }

    function test_rewardFulfilled_eventFieldsMatchStorage() public {
        bytes32 sId = _makeSettlementId(9300);
        bytes32 cId = _makeCalcId(9300);

        vm.prank(distributor);
        bytes32 qId = queue.enqueue(alice, 9300, sId, cId, 8 ether);

        _fund(100 ether);

        vm.expectEmit(true, true, false, true);
        emit IRewardDeferralQueue.RewardFulfilled(qId, alice, 8 ether);

        queue.fulfill(qId);

        // Verify storage
        IRewardDeferralQueue.PendingReward memory entry = queue.pendingEntry(qId);
        assertEq(uint8(entry.status), uint8(IRewardDeferralQueue.QueueStatus.FULFILLED));
        assertEq(queue.totalFulfilled(), 1);
    }

    // =========================================================================
    // Internal utility: unpack a RewardDistribution from public mapping
    // =========================================================================

    /// @dev Return a full RewardDistribution struct via the harness getter.
    function _unpackDistribution(bytes32 distId)
        internal
        view
        returns (
            address recipient,
            uint256 claimId,
            bytes32 settlementId,
            bytes32 calculationId,
            uint256 amount,
            uint256 timestamp,
            RewardEngine.DistributionStatus status,
            bytes32 storedDistId
        )
    {
        RewardEngine.RewardDistribution memory d = engine.getDistribution(distId);
        recipient     = d.recipient;
        claimId       = d.claimId;
        settlementId  = d.settlementId;
        calculationId = d.calculationId;
        amount        = d.amount;
        timestamp     = d.timestamp;
        status        = d.status;
        storedDistId  = d.distributionId;
    }
}
