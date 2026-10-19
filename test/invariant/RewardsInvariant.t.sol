// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../contracts/reward/RewardEngine.sol";
import "../../contracts/mocks/MockRewardToken.sol";
import "../../contracts/mocks/MockRewardReputationOracle.sol";

/// @title RewardsInvariant
/// @notice Foundry stateful invariant tests for RewardEngine (PREWAVE-SC-038).
///
///  Proves the reward accrual and claim conservation properties required by
///  SC-038:
///
///  C1  totalDistributed + totalReserved + availableRewardBalance == totalFunded
///       (claimed + pending + retained dust equals funded allocation)
///  C2  totalDistributed + totalReserved <= totalFunded
///       (cumulative claims never exceed funded rewards)
///  C3  claimableRewards[recipient] == sum of CLAIMABLE distributions for recipient
///       (per-recipient claim balance is consistent)
///  C4  totalAllocated == totalDistributed + totalReserved
///       (allocated rewards are fully accounted for)
///
///  The fuzzer exercises: fundRewardPool, allocateReward, claimReward,
///  allocateRewardsBatch, claimRewardsBatch, and admin setters.
contract RewardsInvariantHandler is Test {
    RewardEngine public engine;
    MockRewardToken public token;
    MockRewardReputationOracle public oracle;

    address public admin;
    address public distributor;
    address public recipient0;
    address public recipient1;
    address public recipient2;

    constructor(
        address _token,
        address _oracle,
        address _engine,
        address _admin,
        address _distributor,
        address _r0,
        address _r1,
        address _r2
    ) {
        token = MockRewardToken(_token);
        oracle = MockRewardReputationOracle(_oracle);
        engine = RewardEngine(_engine);
        admin = _admin;
        distributor = _distributor;
        recipient0 = _r0;
        recipient1 = _r1;
        recipient2 = _r2;
    }

    // ── fuzz targets ──────────────────────────────────────────────────────

    function fund(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        token.approve(address(engine), amount);
        vm.prank(address(this));
        engine.fundRewardPool(amount);
    }

    function allocateSingle(
        address recipient,
        uint256 claimId,
        bytes32 settlementId,
        bytes32 calcId,
        uint256 amount,
        bool immediate
    ) public {
        amount = bound(amount, 1, 1_000_000e18);
        vm.prank(distributor);
        try engine.allocateReward(recipient, claimId, settlementId, calcId, amount, immediate) {} catch {}
    }

    function allocateBatch(
        address[] calldata recs,
        uint256[] calldata claimIds,
        bytes32[] calldata settlementIds,
        bytes32[] calldata calcIds,
        uint256[] calldata amounts,
        bool[] calldata imms
    ) public {
        uint256 n = bound(recs.length, 1, 10);
        vm.prank(distributor);
        try engine.allocateRewardsBatch(recs, claimIds, settlementIds, calcIds, amounts, imms) {} catch {}
    }

    function claimOne(bytes32 distId) public {
        vm.prank(recipient0);
        try engine.claimReward(distId) {} catch {}
    }

    function claimBatch(bytes32[] calldata distIds) public {
        uint256 n = bound(distIds.length, 1, 10);
        vm.prank(recipient0);
        try engine.claimRewardsBatch(distIds) {} catch {}
    }

    function setMultiplier(uint256 min, uint256 max) public {
        min = bound(min, 0, 10e18);
        max = bound(max, 0, 10e18);
        if (min > max) return;
        vm.prank(admin);
        try engine.setReputationMultiplierBounds(min, max) {} catch {}
    }

    function setBaseRate(uint256 rate) public {
        rate = bound(rate, 1, 1e18);
        vm.prank(admin);
        try engine.setBaseRewardRate(rate) {} catch {}
    }
}

contract RewardsInvariant is StdInvariant, Test {
    RewardsInvariantHandler public handler;
    RewardEngine public engine;
    MockRewardToken public token;
    MockRewardReputationOracle public oracle;

    function setUp() public {
        // Deploy dependencies
        token = new MockRewardToken();
        oracle = new MockRewardReputationOracle();

        address admin = makeAddr("admin");
        address distributor = makeAddr("distributor");
        address r0 = makeAddr("recipient_0");
        address r1 = makeAddr("recipient_1");
        address r2 = makeAddr("recipient_2");

        engine = new RewardEngine(address(oracle), admin, admin);

        vm.startPrank(admin);
        engine.setRewardToken(address(token));
        engine.grantRole(engine.DISTRIBUTOR_ROLE(), distributor);
        vm.stopPrank();

        // Fund the test contract so the fuzzer can fund the engine
        token.mint(address(this), type(uint256).max / 2);

        // Create handler that holds references
        handler = new RewardsInvariantHandler(
            address(token),
            address(oracle),
            address(engine),
            admin,
            distributor,
            r0,
            r1,
            r2
        );

        targetContract(address(handler));
        targetContract(address(engine));
    }

    // ── C1: claimed + pending + retained dust == funded ──────────────────

    function invariant_C1_ConservationEquation() public view {
        uint256 distributed = engine.totalDistributed();
        uint256 reserved    = engine.totalReserved();
        uint256 funded      = engine.totalFunded();
        uint256 available   = engine.availableRewardBalance();
        uint256 balance     = token.balanceOf(address(engine));

        // Claimed + pending + retained dust == funded allocation
        assertEq(
            distributed + reserved + available,
            funded,
            "C1: distributed + reserved + available != funded"
        );
        assertEq(funded - distributed, balance, "C1: funded - distributed != balance");
        assertEq(
            available,
            balance >= reserved ? balance - reserved : 0,
            "C1: available != balance - reserved"
        );
    }

    // ── C2: cumulative claims never exceed funded ─────────────────────────

    function invariant_C2_NeverExceedFunded() public view {
        assertLe(
            engine.totalDistributed() + engine.totalReserved(),
            engine.totalFunded(),
            "C2: distributed + reserved > funded"
        );
        assertLe(engine.totalDistributed(), engine.totalFunded(), "C2: distributed > funded");
        assertLe(engine.totalReserved(), engine.totalFunded(), "C2: reserved > funded");
    }

    // ── C4: allocated == distributed + reserved ───────────────────────────

    function invariant_C4_AllocatedFullyAccounted() public view {
        assertEq(
            engine.totalAllocated(),
            engine.totalDistributed() + engine.totalReserved(),
            "C4: totalAllocated != totalDistributed + totalReserved"
        );
    }

    // ── C3: per-recipient claimable matches sum of CLAIMABLE distributions ─

    function invariant_C3_PerRecipientClaimableConsistent() public view {
        address[3] memory recs = [
            handler.recipient0(),
            handler.recipient1(),
            handler.recipient2()
        ];

        for (uint256 ri; ri < recs.length; ri++) {
            address recipient = recs[ri];
            uint256 stored = engine.claimableRewards(recipient);
            assertGe(stored, 0, "C3: claimableRewards negative");

            uint256 counted;
            uint256 count = engine.getRecipientDistributionCount(recipient);
            uint256 end = count < 500 ? count : 500;
            for (uint256 i; i < end; i++) {
                RewardEngine.RewardDistribution memory d =
                    engine.getRecipientDistributions(recipient, i, 1)[0];
                if (d.status == RewardEngine.DistributionStatus.CLAIMABLE) {
                    counted += d.amount;
                }
            }
            assertEq(counted, stored, "C3: claimable mismatch");
        }
    }
}
