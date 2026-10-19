// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../../contracts/v2/FinalRewardAllocator.sol";
import "../../contracts/v2/interfaces/IFinalRewardAllocator.sol";
import "../../contracts/mocks/MockModuleRegistry.sol";
import "../../contracts/mocks/MockDecimalsERC20.sol";

/// @title RewardAllocationRoundingTest
/// @notice V2-SC-096 — reward allocation rounding and dust ownership.
///
/// @dev The two properties this file exists to pin down:
///
///      1. Rounding direction is down, per recipient. Nobody is ever paid more
///         than their exact pro-rata entitlement, so the shares can only ever
///         sum to at most the funded amount. Rounding up would let the shares
///         exceed the pool.
///
///      2. Dust is owned, not lost. Truncation means the shares usually sum to
///         strictly less than the amount. The shortfall goes to an explicit
///         remainderRecipient supplied by the settlement module, so for every
///         category sum(credited) == allocation.amount exactly. Dust is never
///         stranded in the allocator and never silently absorbed.
///
///      Decimals do not enter into either property: the allocator works only in
///      an asset's base units and never reads decimals(). That is asserted
///      directly rather than assumed, across the full supported range
///      (V2AmountUnits.MAX_ASSET_DECIMALS == 36).
contract RewardAllocationRoundingTest is Test {
    FinalRewardAllocator internal allocator;
    MockModuleRegistry internal registry;
    MockDecimalsERC20 internal token;

    address internal settlement = makeAddr("settlement");
    address internal outsider = makeAddr("outsider");
    address internal treasury = makeAddr("treasury");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant MAX_RECIPIENTS = 10;

    function setUp() public {
        registry = new MockModuleRegistry();
        token = new MockDecimalsERC20("Reward", "RWD", 18);
        allocator = new FinalRewardAllocator(address(registry), MAX_RECIPIENTS);
        registry.permitModule(allocator.MODULE_SETTLEMENT(), settlement);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _fund(uint256 amount, bytes32 settlementId) internal {
        token.mint(settlement, amount);
        vm.startPrank(settlement);
        token.approve(address(allocator), amount);
        allocator.fund(address(token), amount, settlementId);
        vm.stopPrank();
    }

    function _allocation(
        IFinalRewardAllocator.RewardCategory category,
        address[] memory accounts,
        uint256[] memory weights,
        uint256 amount,
        address remainderRecipient
    ) internal pure returns (IFinalRewardAllocator.Allocation memory) {
        return IFinalRewardAllocator.Allocation({
            category: category,
            accounts: accounts,
            effectiveWeights: weights,
            amount: amount,
            remainderRecipient: remainderRecipient
        });
    }

    function _three(address a, address b, address c) internal pure returns (address[] memory out) {
        out = new address[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _weights(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _finalize(bytes32 settlementId, IFinalRewardAllocator.Allocation memory allocation) internal {
        IFinalRewardAllocator.Allocation[] memory allocations = new IFinalRewardAllocator.Allocation[](1);
        allocations[0] = allocation;
        vm.prank(settlement);
        allocator.finalizeRewards(
            settlementId, address(token), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, allocations
        );
    }

    function _equalSplit(uint256 amount, bytes32 settlementId, address dustOwner) internal {
        _finalize(
            settlementId,
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights(1, 1, 1),
                amount,
                dustOwner
            )
        );
    }

    function _credited(address dustOwner) internal view returns (uint256) {
        return allocator.claimable(address(token), alice) + allocator.claimable(address(token), bob)
            + allocator.claimable(address(token), carol) + allocator.claimable(address(token), dustOwner);
    }

    // =========================================================================
    // Rounding direction
    // =========================================================================

    /// @dev 10 across three equal weights is 3.33... each. Each recipient is
    ///      truncated to 3, and the 1 that truncation left over is dust.
    function test_sharesRoundDownAndDustGoesToRemainderRecipient() public {
        _fund(10, bytes32("s1"));
        _equalSplit(10, bytes32("s1"), treasury);

        assertEq(allocator.claimable(address(token), alice), 3, "alice truncated");
        assertEq(allocator.claimable(address(token), bob), 3, "bob truncated");
        assertEq(allocator.claimable(address(token), carol), 3, "carol truncated");
        assertEq(allocator.claimable(address(token), treasury), 1, "dust is owned");
    }

    /// @dev The conservation property, stated directly.
    function test_conservation_creditedSumEqualsAllocationAmount() public {
        _fund(1_000_000, bytes32("s1"));
        _finalize(
            bytes32("s1"),
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights(7, 11, 13),
                1_000_000,
                treasury
            )
        );

        assertEq(_credited(treasury), 1_000_000, "no value created or destroyed");
    }

    function test_exactDivisionLeavesNoDust() public {
        _fund(9, bytes32("s1"));
        _equalSplit(9, bytes32("s1"), treasury);

        assertEq(allocator.claimable(address(token), alice), 3);
        assertEq(allocator.claimable(address(token), bob), 3);
        assertEq(allocator.claimable(address(token), carol), 3);
        assertEq(allocator.claimable(address(token), treasury), 0, "no dust when division is exact");
    }

    /// @dev Dust is credited on top of a share when the remainder recipient is
    ///      also a participant, not instead of it.
    function test_remainderRecipientMayAlsoBeAParticipant() public {
        _fund(10, bytes32("s1"));
        _equalSplit(10, bytes32("s1"), alice);

        assertEq(allocator.claimable(address(token), alice), 4, "share 3 plus dust 1");
        assertEq(allocator.claimable(address(token), bob), 3);
        assertEq(allocator.claimable(address(token), carol), 3);
    }

    /// @dev A weight small enough to truncate to nothing pays nothing. The value
    ///      is not lost: it lands in the dust and is therefore still owned.
    function test_weightTooSmallToEarnAUnitIsPaidNothingAndValueSurvivesAsDust() public {
        _fund(100, bytes32("s1"));
        _finalize(
            bytes32("s1"),
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights(1, 1, 1_000_000),
                100,
                treasury
            )
        );

        assertEq(allocator.claimable(address(token), alice), 0, "truncates to zero");
        assertEq(allocator.claimable(address(token), bob), 0, "truncates to zero");
        assertEq(_credited(treasury), 100, "conservation holds even when shares vanish");
    }

    /// @dev Determinism: identical inputs under a different settlement id
    ///      produce identical per-recipient deltas.
    function test_roundingIsDeterministic() public {
        _fund(10_001, bytes32("s1"));
        _finalize(
            bytes32("s1"),
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights(3, 5, 7),
                10_001,
                treasury
            )
        );

        uint256 aliceFirst = allocator.claimable(address(token), alice);
        uint256 bobFirst = allocator.claimable(address(token), bob);
        uint256 carolFirst = allocator.claimable(address(token), carol);
        uint256 treasuryFirst = allocator.claimable(address(token), treasury);

        _fund(10_001, bytes32("s2"));
        _finalize(
            bytes32("s2"),
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights(3, 5, 7),
                10_001,
                treasury
            )
        );

        assertEq(allocator.claimable(address(token), alice) - aliceFirst, aliceFirst);
        assertEq(allocator.claimable(address(token), bob) - bobFirst, bobFirst);
        assertEq(allocator.claimable(address(token), carol) - carolFirst, carolFirst);
        assertEq(allocator.claimable(address(token), treasury) - treasuryFirst, treasuryFirst);
    }

    // =========================================================================
    // The overflow this rounding change removes
    // =========================================================================

    /// @dev Regression for the displaced defect. The previous inline form was
    ///      `amount * effectiveWeights[i] / totalWeight`, which multiplies before
    ///      dividing: with a large amount and large effective weights the
    ///      intermediate product exceeds 2^256 and the settlement reverts even
    ///      though the result is representable. V2Precision.mulDivDown computes
    ///      the product over 512 bits, so this now settles.
    function test_largeAmountTimesLargeWeightDoesNotOverflow() public {
        uint256 amount = type(uint256).max / 4;
        uint256 weight = type(uint128).max;

        _fund(amount, bytes32("big"));
        _finalize(
            bytes32("big"),
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights(weight, weight, weight),
                amount,
                treasury
            )
        );

        assertEq(_credited(treasury), amount, "conservation at the top of the range");
    }

    // =========================================================================
    // Decimals independence across the supported range
    // =========================================================================

    /// @dev The allocator never reads decimals(); it works in base units only.
    ///      Same base-unit inputs must therefore give identical splits at every
    ///      supported decimals value, including both extremes (0 and the
    ///      V2AmountUnits maximum of 36).
    function test_roundingIsIndependentOfAssetDecimals() public {
        uint8[6] memory decimalsSet = [uint8(0), 2, 6, 8, 18, 36];

        uint256 expectedShare;
        uint256 expectedDust;

        for (uint256 d; d < decimalsSet.length; ++d) {
            MockModuleRegistry localRegistry = new MockModuleRegistry();
            FinalRewardAllocator localAllocator = new FinalRewardAllocator(address(localRegistry), MAX_RECIPIENTS);
            localRegistry.permitModule(localAllocator.MODULE_SETTLEMENT(), settlement);

            MockDecimalsERC20 localToken = new MockDecimalsERC20("Reward", "RWD", decimalsSet[d]);
            assertEq(localToken.decimals(), decimalsSet[d], "decimals wired");

            localToken.mint(settlement, 100);

            IFinalRewardAllocator.Allocation[] memory allocations = new IFinalRewardAllocator.Allocation[](1);
            allocations[0] = _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights(1, 1, 1),
                100,
                treasury
            );

            vm.startPrank(settlement);
            localToken.approve(address(localAllocator), 100);
            localAllocator.fund(address(localToken), 100, bytes32("s1"));
            localAllocator.finalizeRewards(
                bytes32("s1"), address(localToken), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, allocations
            );
            vm.stopPrank();

            uint256 share = localAllocator.claimable(address(localToken), alice);
            uint256 dust = localAllocator.claimable(address(localToken), treasury);

            if (d == 0) {
                expectedShare = share;
                expectedDust = dust;
                assertEq(share, 33, "100 over three equal weights");
                assertEq(dust, 1, "one base unit of dust");
            } else {
                assertEq(share, expectedShare, "share must not depend on decimals");
                assertEq(dust, expectedDust, "dust must not depend on decimals");
            }
        }
    }

    // =========================================================================
    // Every reward category, in one final outcome
    // =========================================================================

    /// @dev All five categories settle together, each with its own dust owner,
    ///      and conservation holds over the whole settlement rather than only
    ///      per category.
    function test_allFiveCategoriesConserveValueTogether() public {
        uint256 perCategory = 10;
        uint256 total = perCategory * 5;
        _fund(total, bytes32("s1"));

        address[5] memory dustOwners =
            [makeAddr("dust0"), makeAddr("dust1"), makeAddr("dust2"), makeAddr("dust3"), makeAddr("dust4")];

        IFinalRewardAllocator.Allocation[] memory allocations = new IFinalRewardAllocator.Allocation[](5);
        for (uint256 i; i < 5; ++i) {
            allocations[i] = _allocation(
                IFinalRewardAllocator.RewardCategory(i),
                _three(alice, bob, carol),
                _weights(1, 1, 1),
                perCategory,
                dustOwners[i]
            );
        }

        vm.prank(settlement);
        allocator.finalizeRewards(
            bytes32("s1"), address(token), IFinalRewardAllocator.FinalOutcome.DISPUTED, allocations
        );

        uint256 credited = allocator.claimable(address(token), alice) + allocator.claimable(address(token), bob)
            + allocator.claimable(address(token), carol);
        for (uint256 i; i < 5; ++i) {
            credited += allocator.claimable(address(token), dustOwners[i]);
            assertEq(allocator.claimable(address(token), dustOwners[i]), 1, "each category owns its own dust");
        }

        assertEq(credited, total, "conservation across all categories");
        assertEq(allocator.allocated(address(token)), total);
        assertTrue(allocator.finalized(bytes32("s1")));
        assertEq(uint8(allocator.finalOutcome(bytes32("s1"))), uint8(IFinalRewardAllocator.FinalOutcome.DISPUTED));
    }

    // =========================================================================
    // Failure paths — dust ownership must never be implicit
    // =========================================================================

    function test_rejectsZeroRemainderRecipient() public {
        _fund(10, bytes32("s1"));
        vm.expectRevert(FinalRewardAllocator.InvalidRemainderRecipient.selector);
        _equalSplit(10, bytes32("s1"), address(0));
    }

    function test_rejectsZeroEffectiveWeight() public {
        _fund(10, bytes32("s1"));
        vm.expectRevert(FinalRewardAllocator.ZeroEffectiveWeight.selector);
        _finalize(
            bytes32("s1"),
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights(1, 0, 1),
                10,
                treasury
            )
        );
    }

    function test_rejectsZeroAddressRecipient() public {
        _fund(10, bytes32("s1"));
        vm.expectRevert(FinalRewardAllocator.ZeroAddress.selector);
        _finalize(
            bytes32("s1"),
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, address(0), carol),
                _weights(1, 1, 1),
                10,
                treasury
            )
        );
    }

    function test_rejectsMismatchedWeightLength() public {
        _fund(10, bytes32("s1"));
        uint256[] memory shortWeights = new uint256[](2);
        shortWeights[0] = 1;
        shortWeights[1] = 1;

        vm.expectRevert(FinalRewardAllocator.InvalidRecipientCount.selector);
        _finalize(
            bytes32("s1"),
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                shortWeights,
                10,
                treasury
            )
        );
    }

    function test_rejectsRecipientCountAboveLimit() public {
        FinalRewardAllocator small = new FinalRewardAllocator(address(registry), 2);

        token.mint(settlement, 10);
        IFinalRewardAllocator.Allocation[] memory allocations = new IFinalRewardAllocator.Allocation[](1);
        allocations[0] = _allocation(
            IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
            _three(alice, bob, carol),
            _weights(1, 1, 1),
            10,
            treasury
        );

        vm.startPrank(settlement);
        token.approve(address(small), 10);
        small.fund(address(token), 10, bytes32("s1"));
        vm.expectRevert(FinalRewardAllocator.InvalidRecipientCount.selector);
        small.finalizeRewards(
            bytes32("s1"), address(token), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, allocations
        );
        vm.stopPrank();
    }

    function test_rejectsDuplicateCategory() public {
        _fund(20, bytes32("s1"));
        IFinalRewardAllocator.Allocation[] memory allocations = new IFinalRewardAllocator.Allocation[](2);
        allocations[0] = _allocation(
            IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
            _three(alice, bob, carol),
            _weights(1, 1, 1),
            10,
            treasury
        );
        allocations[1] = allocations[0];

        vm.prank(settlement);
        vm.expectRevert(FinalRewardAllocator.DuplicateCategory.selector);
        allocator.finalizeRewards(
            bytes32("s1"), address(token), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, allocations
        );
    }

    /// @dev Allocating more than was funded for this settlement must fail, so
    ///      dust can never be manufactured out of another settlement's pool.
    function test_rejectsAllocationBeyondSettlementPool() public {
        _fund(10, bytes32("s1"));
        vm.expectRevert(abi.encodeWithSelector(FinalRewardAllocator.PoolExceeded.selector, 11, 10));
        _equalSplit(11, bytes32("s1"), treasury);
    }

    /// @dev Funding is per settlement id, so one settlement cannot spend
    ///      another's pool even though both share the asset-level total.
    function test_settlementPoolsAreIsolated() public {
        _fund(10, bytes32("s1"));
        _fund(10, bytes32("s2"));

        vm.expectRevert(abi.encodeWithSelector(FinalRewardAllocator.PoolExceeded.selector, 20, 10));
        _equalSplit(20, bytes32("s1"), treasury);
    }

    function test_replayOfFinalizedSettlementReverts() public {
        _fund(20, bytes32("s1"));
        _equalSplit(10, bytes32("s1"), treasury);

        vm.expectRevert(
            abi.encodeWithSelector(FinalRewardAllocator.SettlementAlreadyFinalized.selector, bytes32("s1"))
        );
        _equalSplit(10, bytes32("s1"), treasury);
    }

    // =========================================================================
    // Authorization — no caller but the registered settlement module
    // =========================================================================

    function test_onlyRegisteredSettlementModuleMayFund() public {
        token.mint(outsider, 10);
        vm.startPrank(outsider);
        token.approve(address(allocator), 10);
        vm.expectRevert(
            abi.encodeWithSelector(FinalRewardAllocator.UnauthorizedSettlementModule.selector, outsider)
        );
        allocator.fund(address(token), 10, bytes32("s1"));
        vm.stopPrank();
    }

    function test_onlyRegisteredSettlementModuleMayFinalize() public {
        _fund(10, bytes32("s1"));
        IFinalRewardAllocator.Allocation[] memory allocations = new IFinalRewardAllocator.Allocation[](1);
        allocations[0] = _allocation(
            IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
            _three(alice, bob, carol),
            _weights(1, 1, 1),
            10,
            treasury
        );

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(FinalRewardAllocator.UnauthorizedSettlementModule.selector, outsider)
        );
        allocator.finalizeRewards(
            bytes32("s1"), address(token), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, allocations
        );
    }

    /// @dev Re-pointing the registry revokes the old module immediately. Without
    ///      this, a rotated-out settlement module would keep treasury authority.
    function test_repointingRegistryRevokesPreviousSettlementModule() public {
        registry.permitModule(allocator.MODULE_SETTLEMENT(), makeAddr("replacement"));

        token.mint(settlement, 10);
        vm.startPrank(settlement);
        token.approve(address(allocator), 10);
        vm.expectRevert(
            abi.encodeWithSelector(FinalRewardAllocator.UnauthorizedSettlementModule.selector, settlement)
        );
        allocator.fund(address(token), 10, bytes32("s1"));
        vm.stopPrank();
    }

    // =========================================================================
    // Claiming is pull-based and bounded by the credited entitlement
    // =========================================================================

    function test_claimTransfersExactlyTheCreditedDust() public {
        _fund(10, bytes32("s1"));
        _equalSplit(10, bytes32("s1"), treasury);

        vm.prank(treasury);
        allocator.claim(address(token), 1);

        assertEq(token.balanceOf(treasury), 1, "dust is withdrawable by its owner");
        assertEq(allocator.claimable(address(token), treasury), 0);
    }

    function test_claimCannotExceedEntitlement() public {
        _fund(10, bytes32("s1"));
        _equalSplit(10, bytes32("s1"), treasury);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FinalRewardAllocator.InsufficientClaimable.selector, 4, 3));
        allocator.claim(address(token), 4);
    }

    // =========================================================================
    // Fuzz — the properties, not the examples
    // =========================================================================

    /// @dev Conservation: whatever the weights, the credited total is exactly
    ///      the allocated amount.
    function testFuzz_creditedTotalAlwaysEqualsAmount(uint128 amount, uint64 w0, uint64 w1, uint64 w2) public {
        uint256 value = bound(amount, 1, type(uint128).max);
        uint256 weight0 = bound(w0, 1, type(uint64).max);
        uint256 weight1 = bound(w1, 1, type(uint64).max);
        uint256 weight2 = bound(w2, 1, type(uint64).max);

        _fund(value, bytes32("fz"));
        _finalize(
            bytes32("fz"),
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights(weight0, weight1, weight2),
                value,
                treasury
            )
        );

        assertEq(_credited(treasury), value, "dust is always owned");
    }

    /// @dev Rounding down means the dust is strictly smaller than the number of
    ///      recipients: each recipient can lose at most one base unit.
    function testFuzz_dustIsBoundedByRecipientCount(uint128 amount, uint64 w0, uint64 w1, uint64 w2) public {
        uint256 value = bound(amount, 1, type(uint128).max);
        uint256 weight0 = bound(w0, 1, type(uint64).max);
        uint256 weight1 = bound(w1, 1, type(uint64).max);
        uint256 weight2 = bound(w2, 1, type(uint64).max);

        _fund(value, bytes32("fz"));
        _finalize(
            bytes32("fz"),
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights(weight0, weight1, weight2),
                value,
                treasury
            )
        );

        assertLt(allocator.claimable(address(token), treasury), 3, "dust < recipient count");
    }

    /// @dev Nobody is ever paid more than their exact pro-rata entitlement.
    ///      This is the property that makes rounding down safe.
    function testFuzz_noRecipientExceedsProRataEntitlement(uint128 amount, uint64 w0, uint64 w1, uint64 w2)
        public
    {
        uint256 value = bound(amount, 1, type(uint128).max);
        uint256 weight0 = bound(w0, 1, type(uint64).max);
        uint256 weight1 = bound(w1, 1, type(uint64).max);
        uint256 weight2 = bound(w2, 1, type(uint64).max);
        uint256 totalWeight = weight0 + weight1 + weight2;

        _fund(value, bytes32("fz"));
        _finalize(
            bytes32("fz"),
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights(weight0, weight1, weight2),
                value,
                treasury
            )
        );

        assertLe(
            allocator.claimable(address(token), alice),
            Math.mulDiv(value, weight0, totalWeight),
            "alice never overpaid"
        );
        assertLe(
            allocator.claimable(address(token), bob),
            Math.mulDiv(value, weight1, totalWeight),
            "bob never overpaid"
        );
        assertLe(
            allocator.claimable(address(token), carol),
            Math.mulDiv(value, weight2, totalWeight),
            "carol never overpaid"
        );
    }

    /// @dev Equal weights must pay equal shares, whatever the amount.
    function testFuzz_equalWeightsPayEqualShares(uint128 amount) public {
        uint256 value = bound(amount, 1, type(uint128).max);

        _fund(value, bytes32("fz"));
        _finalize(
            bytes32("fz"),
            _allocation(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights(5, 5, 5),
                value,
                treasury
            )
        );

        uint256 share = allocator.claimable(address(token), alice);
        assertEq(allocator.claimable(address(token), bob), share);
        assertEq(allocator.claimable(address(token), carol), share);
        assertEq(share * 3 + allocator.claimable(address(token), treasury), value);
    }
}
