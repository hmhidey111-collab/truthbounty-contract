// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/tokenomics/TokenomicsEngine.sol";
import "../../contracts/tokenomics/ITokenomicsEngine.sol";
import "../../contracts/treasury/TreasuryAccounting.sol";
import "../../contracts/MockERC20.sol";

interface ITokenomicsEngineView {
    function sourceAllocations(uint256)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bool
        );
}

contract TokenomicsFuzzTest is Test {
    TokenomicsEngine tokenomics;
    TreasuryAccounting treasuryAccounting;
    MockERC20 token;

    address admin = address(0xDeAD);
    address distributor = address(0xBEEF);

    uint256 constant INITIAL_SUPPLY = 1_000_000e18;

    function setUp() public {
        token = new MockERC20("TruthBounty Test", "TBT");
        token.mint(address(this), INITIAL_SUPPLY);

        treasuryAccounting = new TreasuryAccounting(
            address(token),
            address(0),
            admin
        );

        vm.startPrank(admin);
        treasuryAccounting.grantRole(treasuryAccounting.ADMIN_ROLE(), distributor);
        treasuryAccounting.grantRole(treasuryAccounting.TREASURY_MANAGER_ROLE(), admin);
        vm.stopPrank();

        tokenomics = new TokenomicsEngine(
            address(treasuryAccounting),
            address(token),
            admin,
            address(0)
        );

        vm.startPrank(admin);
        tokenomics.grantRole(tokenomics.DISTRIBUTOR_ROLE(), distributor);
        vm.stopPrank();

        // Distribution deposits shift account balances: disable the staking-reserve
        // ratio invariant (mirrors TokenomicsEngine.t.sol) so treasury validation does
        // not trip on allocations that never touch the staking reserve.
        vm.startPrank(admin);
        treasuryAccounting.setMinStakingReserveRatio(0);
        vm.stopPrank();
    }

    /// @dev `distributeRevenue` pulls tokens from `msg.sender` (the distributor), so funds
    ///      and allowance must be provisioned on the distributor account, not the test.
    function _fundDistributor(uint256 amount) internal {
        token.mint(distributor, amount);
        vm.prank(distributor);
        token.approve(address(tokenomics), type(uint256).max);
    }

    // ============ Fuzz: Allocation BPS Summation ============

    function testFuzz_AllocationConfig_ValidBPSSummation(
        uint256 verifier,
        uint256 treasuryAmount,
        uint256 ecosystem,
        uint256 governance,
        uint256 protocol,
        uint256 emergency
    ) external {
        // Clamp each to valid BPS range
        verifier = bound(verifier, 0, 10000);
        treasuryAmount = bound(treasuryAmount, 0, 10000);
        ecosystem = bound(ecosystem, 0, 10000);
        governance = bound(governance, 0, 10000);
        protocol = bound(protocol, 0, 10000);
        emergency = bound(emergency, 0, 10000);
        require(verifier + treasuryAmount + ecosystem + governance + protocol + emergency == 10000, "BPS sum must be 10000");

        // Only test valid configurations
        if (
            verifier + treasuryAmount + ecosystem + governance + protocol + emergency != 10000
        ) {
            return;
        }

        vm.startPrank(admin);
        ITokenomicsEngine.SourceAllocation memory config = ITokenomicsEngine.SourceAllocation({
            verifierRewardsBPS: verifier,
            treasuryReserveBPS: treasuryAmount,
            ecosystemIncentivesBPS: ecosystem,
            governanceIncentivesBPS: governance,
            protocolDevelopmentBPS: protocol,
            emergencyReserveBPS: emergency,
            active: true
        });
        tokenomics.setSourceAllocation(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
            config
        );
        vm.stopPrank();

        ITokenomicsEngine.SourceAllocation memory stored = tokenomics.getAllocationConfig(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES
        );
        assertEq(stored.verifierRewardsBPS, verifier);
        assertEq(stored.treasuryReserveBPS, treasuryAmount);
        assertEq(stored.ecosystemIncentivesBPS, ecosystem);
        assertEq(stored.governanceIncentivesBPS, governance);
        assertEq(stored.protocolDevelopmentBPS, protocol);
        assertEq(stored.emergencyReserveBPS, emergency);
    }

    // ============ Fuzz: Distribution Amounts ============

    function testFuzz_DistributeRevenue_RandomAmounts(
        uint256 amount
    ) external {
        amount = bound(amount, 1, INITIAL_SUPPLY / 10);

        _fundDistributor(amount);

        vm.startPrank(distributor);
        bytes32 distributionId = tokenomics.distributeRevenue(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
            amount
        );
        vm.stopPrank();

        ITokenomicsEngine.DistributionRecord memory record = tokenomics.getDistributionRecord(distributionId);
        assertEq(record.totalAmount, amount);

        uint256 sum = record.verifierRewards
            + record.treasuryReserve
            + record.ecosystemIncentives
            + record.governanceIncentives
            + record.protocolDevelopment
            + record.emergencyReserve;
        assertEq(sum, amount);
    }

    // ============ Fuzz: Multi-Source Batch ============

    function testFuzz_AllocateBatch_RandomSources(
        uint256 count,
        uint256 totalAmount
    ) external {
        count = bound(count, 1, 5);
        // Every per-source amount must be >= 1 so no ZeroAmount revert can occur mid-batch.
        totalAmount = bound(totalAmount, count, INITIAL_SUPPLY / 10);

        ITokenomicsEngine.RevenueSource[] memory sources = new ITokenomicsEngine.RevenueSource[](count);
        uint256[] memory amounts = new uint256[](count);

        uint256 perSource = totalAmount / count;
        uint256 remainder = totalAmount % count;

        for (uint256 i = 0; i < count; i++) {
            sources[i] = ITokenomicsEngine.RevenueSource(i);
            amounts[i] = i < remainder ? perSource + 1 : perSource;
        }

        _fundDistributor(totalAmount);

        vm.startPrank(distributor);
        bytes32[] memory distributionIds = tokenomics.allocateBatch(sources, amounts);
        vm.stopPrank();

        assertEq(distributionIds.length, count);
        assertEq(tokenomics.totalDistributed(), totalAmount);
    }

    // ============ Fuzz: Emission Limit Enforcement ============

    function testFuzz_EmissionLimit_RandomLimits(
        uint256 limit,
        uint256 attempt1,
        uint256 attempt2
    ) external {
        limit = bound(limit, 1, 10_000e18);
        attempt1 = bound(attempt1, 1, 10_000e18);
        attempt2 = bound(attempt2, 1, 10_000e18);

        vm.startPrank(admin);
        tokenomics.setEmissionLimit(limit);
        vm.stopPrank();

        uint256 totalAttempted = attempt1 + attempt2;

        _fundDistributor(totalAttempted);

        vm.startPrank(distributor);

        if (attempt1 <= limit) {
            tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, attempt1);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(TokenomicsEngine.EmissionLimitExceeded.selector, attempt1, limit)
            );
            tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, attempt1);
        }

        if (attempt1 + attempt2 > limit && attempt1 <= limit) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    TokenomicsEngine.EmissionLimitExceeded.selector,
                    attempt1 + attempt2,
                    limit
                )
            );
            tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, attempt2);
        }

        vm.stopPrank();
    }

    // ============ Fuzz: Reward Multiplier ============

    function testFuzz_RewardMultiplier_RandomMultipliers(
        uint256 multiplier,
        uint256 amount
    ) external {
        multiplier = bound(multiplier, 1, 5e18);
        amount = bound(amount, 1, INITIAL_SUPPLY / 10);

        vm.startPrank(admin);
        tokenomics.setRewardMultiplier(multiplier);
        vm.stopPrank();

        _fundDistributor(amount);
        // Pre-fund the engine so every rescaled share can be deposited before the
        // reconciliation check runs (max payout is 2.6x `amount` at multiplier 5e18).
        token.mint(address(tokenomics), amount * 2);

        // Mirror the engine's maths: floor(amount * 4000 / 10000), then scale by the
        // multiplier. When the scaled verifier share differs from the base share the
        // shares no longer sum to `amount` and the engine must fail closed.
        uint256 baseVerifier = (amount * 4000) / 10000;
        uint256 scaledVerifier = (baseVerifier * multiplier) / 1e18;

        vm.startPrank(distributor);
        if (scaledVerifier != baseVerifier) {
            vm.expectRevert(TokenomicsEngine.InvalidAllocation.selector);
            tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, amount);
            vm.stopPrank();

            assertEq(tokenomics.totalDistributed(), 0);
        } else {
            bytes32 distributionId = tokenomics.distributeRevenue(
                ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
                amount
            );
            vm.stopPrank();

            ITokenomicsEngine.DistributionRecord memory record = tokenomics.getDistributionRecord(distributionId);
            assertEq(record.verifierRewards, scaledVerifier);
        }
    }

    // ============ Fuzz: Deterministic Distribution IDs ============

    function testFuzz_DistributionId_Deterministic(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);

        // Two distributions are executed from the same sender in the same block.
        _fundDistributor(amount * 2);

        vm.startPrank(distributor);
        bytes32 id1 = tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, amount);
        bytes32 id2 = tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.TREASURY_ALLOCATION, amount);
        vm.stopPrank();

        assertTrue(id1 != id2, "IDs must be unique across sources");
    }

    // ============ Fuzz: BPS Validation ============

    function testFuzz_InvalidBPSConfiguration_Reverts(
        uint256 verifier,
        uint256 treasuryAmount,
        uint256 ecosystem,
        uint256 governance,
        uint256 protocol,
        uint256 emergency
    ) external {
        // Bound first, then only exercise configurations that do NOT sum to 10000.
        verifier = bound(verifier, 1, 9999);
        treasuryAmount = bound(treasuryAmount, 1, 9999);
        ecosystem = bound(ecosystem, 1, 9999);
        governance = bound(governance, 1, 9999);
        protocol = bound(protocol, 1, 9999);
        emergency = bound(emergency, 1, 9999);

        uint256 total = verifier + treasuryAmount + ecosystem + governance + protocol + emergency;
        if (total == 10000) return;

        vm.startPrank(admin);
        ITokenomicsEngine.SourceAllocation memory config = ITokenomicsEngine.SourceAllocation({
            verifierRewardsBPS: verifier,
            treasuryReserveBPS: treasuryAmount,
            ecosystemIncentivesBPS: ecosystem,
            governanceIncentivesBPS: governance,
            protocolDevelopmentBPS: protocol,
            emergencyReserveBPS: emergency,
            active: true
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenomicsEngine.AllocationConfigInvalid.selector,
                "basis points do not sum to 10000"
            )
        );
        tokenomics.setSourceAllocation(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
            config
        );
        vm.stopPrank();
    }
}
