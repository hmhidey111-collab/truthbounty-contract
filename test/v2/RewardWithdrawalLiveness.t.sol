// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title RewardWithdrawalLivenessTest — PREWAVE-SC-051
 *
 * @notice Proves that withdrawal/payout liveness holds under hostile recipients for the
 *         reward and deferral-queue exit paths:
 *           - one hostile recipient cannot block the other recipients in a batch;
 *           - a failed payout remains owed exactly once;
 *           - retry is permission-safe;
 *           - custody is conserved.
 *
 * The harness reuses the repo's hostile-recipient mock token so a single recipient can be
 * made to revert or to return `false` on transfer.
 */

import "forge-std/Test.sol";
import {RewardEngine} from "../../contracts/reward/RewardEngine.sol";
import {RewardDeferralQueue} from "../../contracts/reward/RewardDeferralQueue.sol";
import {IRewardDeferralQueue} from "../../contracts/reward/IRewardDeferralQueue.sol";
import {HostileRecipientERC20} from "../../contracts/mocks/HostileRecipientERC20.sol";
import {HostileTokenRecipient} from "../../contracts/mocks/HostileTokenRecipient.sol";
import {MockRewardReputationOracle} from "../../contracts/mocks/MockRewardReputationOracle.sol";

contract RewardWithdrawalLivenessTest is Test {
    RewardEngine internal engine;
    RewardDeferralQueue internal queue;
    HostileRecipientERC20 internal token;
    MockRewardReputationOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal distributor = makeAddr("distributor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    /// @dev A contract recipient that would revert if the token called its hook.
    HostileTokenRecipient internal hostileContract;

    bytes32 internal constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    function setUp() public {
        vm.startPrank(admin);

        token = new HostileRecipientERC20();
        oracle = new MockRewardReputationOracle();
        hostileContract = new HostileTokenRecipient();

        engine = new RewardEngine(address(oracle), admin, admin);
        engine.setRewardToken(address(token));
        engine.grantRole(DISTRIBUTOR_ROLE, distributor);

        queue = new RewardDeferralQueue(address(engine), admin);
        queue.grantRole(queue.ENQUEUE_ROLE(), distributor);
        engine.grantRole(DISTRIBUTOR_ROLE, address(queue));

        token.approve(address(engine), 1_000_000 ether);
        engine.fundRewardPool(1_000_000 ether);

        vm.stopPrank();
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _sid(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode("settlement", n));
    }

    function _cid(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode("calculation", n));
    }

    function _distributionId(address recipient, uint256 claimId, bytes32 sId, bytes32 cId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(recipient, claimId, sId, cId));
    }

    function _assertConserved() internal view {
        assertEq(
            token.balanceOf(address(engine)),
            engine.totalReserved() + engine.availableRewardBalance(),
            "custody must be conserved"
        );
    }

    /// @dev Public mapping getters return tuples, so extract the status field explicitly.
    function _distributionStatus(bytes32 id)
        internal
        view
        returns (RewardEngine.DistributionStatus status)
    {
        (,,,,,, status,) = engine.rewardDistributions(id);
    }

    // ── RewardEngine.allocateRewardsBatch ─────────────────────────────────────

    function test_batch_isolatesRevertingRecipient() public {
        address hostile = address(hostileContract);
        token.setFault(hostile, HostileRecipientERC20.Fault.Revert);

        uint256 amountHostile = 100 ether;
        uint256 amountAlice = 200 ether;

        address[] memory recipients = new address[](2);
        recipients[0] = hostile;
        recipients[1] = alice;

        uint256[] memory claimIds = new uint256[](2);
        claimIds[0] = 1;
        claimIds[1] = 2;

        bytes32[] memory sIds = new bytes32[](2);
        sIds[0] = _sid(1);
        sIds[1] = _sid(2);

        bytes32[] memory cIds = new bytes32[](2);
        cIds[0] = _cid(1);
        cIds[1] = _cid(2);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountHostile;
        amounts[1] = amountAlice;

        bool[] memory immediate = new bool[](2);
        immediate[0] = true;
        immediate[1] = true;

        bytes32 hostileId = _distributionId(hostile, 1, sIds[0], cIds[0]);

        vm.prank(distributor);
        engine.allocateRewardsBatch(recipients, claimIds, sIds, cIds, amounts, immediate);

        // The clean recipient was still paid in full.
        assertEq(token.balanceOf(alice), amountAlice, "clean recipient must be paid");

        // The hostile row is owed exactly once as a pull credit.
        assertEq(
            uint256(_distributionStatus(hostileId)),
            uint256(RewardEngine.DistributionStatus.CLAIMABLE)
        );
        assertEq(engine.claimableRewards(hostile), amountHostile);

        // Nothing leaked to the hostile recipient.
        assertEq(token.balanceOf(hostile), 0);

        _assertConserved();
    }

    function test_batch_isolatesFalseReturnRecipient() public {
        token.setFault(bob, HostileRecipientERC20.Fault.ReturnFalse);

        uint256 amountBob = 150 ether;
        uint256 amountAlice = 50 ether;

        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;

        uint256[] memory claimIds = new uint256[](2);
        claimIds[0] = 11;
        claimIds[1] = 10;

        bytes32[] memory sIds = new bytes32[](2);
        sIds[0] = _sid(11);
        sIds[1] = _sid(10);

        bytes32[] memory cIds = new bytes32[](2);
        cIds[0] = _cid(11);
        cIds[1] = _cid(10);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountAlice;
        amounts[1] = amountBob;

        bool[] memory immediate = new bool[](2);
        immediate[0] = true;
        immediate[1] = true;

        bytes32 bobId = _distributionId(bob, 10, sIds[1], cIds[1]);

        vm.prank(distributor);
        engine.allocateRewardsBatch(recipients, claimIds, sIds, cIds, amounts, immediate);

        assertEq(token.balanceOf(alice), amountAlice);
        assertEq(
            uint256(_distributionStatus(bobId)),
            uint256(RewardEngine.DistributionStatus.CLAIMABLE)
        );
        assertEq(engine.claimableRewards(bob), amountBob);
    }

    function test_deferred_retryIsExactlyOnceAndPermissionSafe() public {
        token.setFault(bob, HostileRecipientERC20.Fault.ReturnFalse);

        uint256 amount = 321 ether;
        bytes32 sId = _sid(42);
        bytes32 cId = _cid(42);
        bytes32 bobId = _distributionId(bob, 42, sId, cId);

        address[] memory recipients = new address[](1);
        recipients[0] = bob;
        uint256[] memory claimIds = new uint256[](1);
        claimIds[0] = 42;
        bytes32[] memory sIds = new bytes32[](1);
        sIds[0] = sId;
        bytes32[] memory cIds = new bytes32[](1);
        cIds[0] = cId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        bool[] memory immediate = new bool[](1);
        immediate[0] = true;

        vm.prank(distributor);
        engine.allocateRewardsBatch(recipients, claimIds, sIds, cIds, amounts, immediate);

        assertEq(token.balanceOf(bob), 0, "not paid yet");
        uint256 distributedBefore = engine.totalDistributed();

        // A third party cannot redirect or claim another account's credit.
        vm.prank(stranger);
        vm.expectRevert(RewardEngine.UnauthorizedRewardClaim.selector);
        engine.claimReward(bobId);

        // Later recovery: the entitled caller pulls its balance once the recipient can
        // receive tokens again.
        token.setFault(bob, HostileRecipientERC20.Fault.None);
        vm.prank(bob);
        engine.claimReward(bobId);

        assertEq(token.balanceOf(bob), amount);
        assertEq(engine.totalDistributed(), distributedBefore + amount);

        // Retrying cannot double-pay.
        vm.prank(bob);
        vm.expectRevert(RewardEngine.RewardNotClaimable.selector);
        engine.claimReward(bobId);
        assertEq(token.balanceOf(bob), amount);
    }

    function test_mixedBatch_nonImmediateAndImmediateWithHostile() public {
        address hostile = address(hostileContract);
        token.setFault(hostile, HostileRecipientERC20.Fault.Revert);

        uint256 claimableAmount = 10 ether;
        uint256 immediateAmount = 40 ether;
        uint256 hostileAmount = 20 ether;

        address[] memory recipients = new address[](3);
        recipients[0] = bob;
        recipients[1] = alice;
        recipients[2] = hostile;

        uint256[] memory claimIds = new uint256[](3);
        claimIds[0] = 1;
        claimIds[1] = 2;
        claimIds[2] = 3;

        bytes32[] memory sIds = new bytes32[](3);
        sIds[0] = _sid(1);
        sIds[1] = _sid(2);
        sIds[2] = _sid(3);

        bytes32[] memory cIds = new bytes32[](3);
        cIds[0] = _cid(1);
        cIds[1] = _cid(2);
        cIds[2] = _cid(3);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = claimableAmount;
        amounts[1] = immediateAmount;
        amounts[2] = hostileAmount;

        bool[] memory immediate = new bool[](3);
        immediate[0] = false;
        immediate[1] = true;
        immediate[2] = true;

        vm.prank(distributor);
        engine.allocateRewardsBatch(recipients, claimIds, sIds, cIds, amounts, immediate);

        assertEq(engine.claimableRewards(bob), claimableAmount);
        assertEq(token.balanceOf(alice), immediateAmount);
        assertEq(engine.claimableRewards(hostile), hostileAmount);
        assertEq(token.balanceOf(hostile), 0);

        _assertConserved();
    }

    function test_batch_trampolineNotExternallyCallable() public {
        vm.prank(stranger);
        vm.expectRevert(RewardEngine.SelfCallOnly.selector);
        engine._allocateRewardExternal(alice, 1, _sid(1), _cid(1), 1 ether, true);
    }

    // ── RewardDeferralQueue.fulfillBatch ──────────────────────────────────────

    function test_queue_batchIsolatesHostileEntryAndRetryIsPermissionless() public {
        token.setFault(bob, HostileRecipientERC20.Fault.ReturnFalse);

        uint256 amountBob = 75 ether;
        uint256 amountAlice = 25 ether;

        vm.startPrank(distributor);
        bytes32 bobId = queue.enqueue(bob, 1, _sid(1), _cid(1), amountBob);
        bytes32 aliceId = queue.enqueue(alice, 2, _sid(2), _cid(2), amountAlice);
        vm.stopPrank();

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bobId;
        ids[1] = aliceId;

        // Anyone may trigger fulfillment.
        vm.prank(stranger);
        queue.fulfillBatch(ids);

        assertTrue(queue.isFulfilled(aliceId), "clean entry fulfilled");
        assertTrue(queue.isPending(bobId), "hostile entry remains owed");
        assertEq(token.balanceOf(alice), amountAlice);
        assertEq(token.balanceOf(bob), 0);
        assertEq(queue.totalFulfilled(), 1);

        // Recover: once the recipient can receive, ANY caller can retry the entry.
        token.setFault(bob, HostileRecipientERC20.Fault.None);
        vm.prank(stranger);
        queue.fulfill(bobId);

        assertEq(token.balanceOf(bob), amountBob);
        assertTrue(queue.isFulfilled(bobId));

        // Exactly once.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IRewardDeferralQueue.AlreadyFulfilled.selector, bobId));
        queue.fulfill(bobId);
        assertEq(token.balanceOf(bob), amountBob);

        _assertConserved();
    }
}
