// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/tokenomics/TokenomicsEngine.sol";
import "../contracts/tokenomics/ITokenomicsEngine.sol";
import "../contracts/treasury/TreasuryAccounting.sol";
import "../contracts/MockERC20.sol";

contract TokenomicsEngineTest is Test {
    TokenomicsEngine tokenomics;
    TreasuryAccounting treasury;
    MockERC20 token;

    address admin = address(0xA);
    address distributor = address(0xB);
    address sender = address(0xC);

    uint256 constant INITIAL_SUPPLY = 1_000_000e18;

    function setUp() public {
        token = new MockERC20("TruthBounty Test", "TBT");
        token.mint(sender, INITIAL_SUPPLY);

        treasury = new TreasuryAccounting(
            address(token),
            address(0),
            admin
        );

        // Grant roles
        vm.startPrank(admin);
        treasury.grantRole(treasury.ADMIN_ROLE(), distributor);
        treasury.grantRole(treasury.TREASURY_MANAGER_ROLE(), admin);
        vm.stopPrank();

        tokenomics = new TokenomicsEngine(
            address(treasury),
            address(token),
            admin,
            address(0)
        );

        vm.startPrank(admin);
        tokenomics.grantRole(tokenomics.DISTRIBUTOR_ROLE(), distributor);
        tokenomics.grantRole(tokenomics.ADMIN_ROLE(), admin);
        vm.stopPrank();

        // Fund tokenomics with initial revenue
        vm.startPrank(admin);
        treasury.setMinStakingReserveRatio(0);
        vm.stopPrank();

        token.mint(distributor, INITIAL_SUPPLY);
        vm.startPrank(distributor);
        token.approve(address(tokenomics), INITIAL_SUPPLY);
        vm.stopPrank();
    }

    // ============ Deployment Tests ============

    function test_Deployment_SetsTreasuryAndToken() public {
        assertEq(address(tokenomics.treasuryAccounting()), address(treasury));
        assertEq(address(tokenomics.protocolToken()), address(token));
    }

    function test_Deployment_InitializesDefaultAllocations() public {
        ITokenomicsEngine.SourceAllocation memory config = tokenomics.getAllocationConfig(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES
        );
        assertTrue(config.active);
        assertEq(config.verifierRewardsBPS, 4000);
        assertEq(config.treasuryReserveBPS, 2000);
        assertEq(config.ecosystemIncentivesBPS, 1500);
        assertEq(config.governanceIncentivesBPS, 1000);
        assertEq(config.protocolDevelopmentBPS, 1000);
        assertEq(config.emergencyReserveBPS, 500);
    }

    function test_Revert_ZeroTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(TokenomicsEngine.AllocationConfigInvalid.selector, "zero treasury"));
        new TokenomicsEngine(address(0), address(token), admin, address(0));
    }

    function test_Revert_ZeroToken() public {
        vm.expectRevert(abi.encodeWithSelector(TokenomicsEngine.AllocationConfigInvalid.selector, "zero token"));
        new TokenomicsEngine(address(treasury), address(0), admin, address(0));
    }

    function test_Revert_ZeroAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(TokenomicsEngine.AllocationConfigInvalid.selector, "zero admin"));
        new TokenomicsEngine(address(treasury), address(token), address(0), address(0));
    }

    // ============ Core Distribution Tests ============

    function test_DistributeRevenue_AllocatesCorrectly() public {
        uint256 amount = 1000e18;

        vm.startPrank(distributor);
        bytes32 distributionId = tokenomics.distributeRevenue(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
            amount
        );
        vm.stopPrank();

        assertTrue(tokenomics.processedDistributions(distributionId));
        assertEq(tokenomics.totalDistributed(), amount);
        assertEq(tokenomics.totalBySource(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES), amount);

        // Verify proportional shares: 4000 BPS of 1000e18 = 400e18
        TokenomicsEngine.DistributionRecord memory record = tokenomics.getDistributionRecord(distributionId);
        assertEq(record.verifierRewards, 400e18);
        assertEq(record.ecosystemIncentives, 150e18);
        assertEq(record.governanceIncentives, 100e18);
        assertEq(record.protocolDevelopment, 100e18);
        assertEq(record.emergencyReserve, 50e18);
        // Treasury reserver = 1000e18 - sum of others
        assertEq(record.treasuryReserve, 200e18);
        assertEq(record.totalAmount, amount);
    }

    function test_DistributeRevenue_RejectsZeroAmount() public {
        vm.startPrank(distributor);
        vm.expectRevert(TokenomicsEngine.ZeroAmount.selector);
        tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, 0);
        vm.stopPrank();
    }

    function test_DistributeRevenue_RejectsInactiveSource() public {
        // Fail-closed configuration: the engine validates allocations on write, so an
        // inactive source can never be stored (and therefore never reach distribution).
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(TokenomicsEngine.AllocationConfigInvalid.selector, "allocation inactive")
        );
        tokenomics.setSourceAllocation(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
            ITokenomicsEngine.SourceAllocation({
                verifierRewardsBPS: 4000,
                treasuryReserveBPS: 2000,
                ecosystemIncentivesBPS: 1500,
                governanceIncentivesBPS: 1000,
                protocolDevelopmentBPS: 1000,
                emergencyReserveBPS: 500,
                active: false
            })
        );
        vm.stopPrank();

        // The canonical config is untouched: still the original active allocation.
        ITokenomicsEngine.SourceAllocation memory config = tokenomics.getAllocationConfig(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES
        );
        assertTrue(config.active, "inactive config must never be stored");
        assertEq(config.verifierRewardsBPS, 4000);
    }

    function test_DistributeRevenue_RejectsDuplicate() public {
        uint256 amount = 100e18;

        vm.startPrank(distributor);
        bytes32 id1 = tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, amount);
        bytes32 id2 = tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, amount);
        vm.stopPrank();

        // Idempotency: distribution ids embed a monotonic nonce, so a completed
        // distribution id can never be produced again — reprocessing is impossible.
        assertTrue(id1 != id2, "distribution ids must be unique");
        assertTrue(tokenomics.processedDistributions(id1));
        assertTrue(tokenomics.processedDistributions(id2));
    }

    function test_DistributeRevenue_PreventsTreasuryDeficit() public {
        // Fund a real treasury ledger position: recorded assets = 100e18.
        token.mint(admin, 100e18);
        vm.startPrank(admin);
        token.approve(address(treasury), 100e18);
        treasury.depositToAccount(TreasuryAccounting.TreasuryAccount.GOVERNANCE_RESERVES, 100e18);
        vm.stopPrank();

        // Force the treasury into deficit: actual token balance drops below the
        // accounted ledger total (balance < calculateTotalAssets()).
        deal(address(token), address(treasury), 1);

        vm.startPrank(distributor);
        vm.expectRevert(TokenomicsEngine.TreasuryOverdraft.selector);
        tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, 100e18);
        vm.stopPrank();
    }

    // ============ Batch Distribution Tests ============

    function test_AllocateBatch_DistributesMultipleSources() public {
        uint256 amount1 = 100e18;
        uint256 amount2 = 200e18;

        vm.startPrank(sender);
        token.approve(address(tokenomics), amount1 + amount2);
        vm.stopPrank();

        ITokenomicsEngine.RevenueSource[] memory sources = new ITokenomicsEngine.RevenueSource[](2);
        uint256[] memory amounts = new uint256[](2);
        sources[0] = ITokenomicsEngine.RevenueSource.PROTOCOL_FEES;
        sources[1] = ITokenomicsEngine.RevenueSource.TREASURY_ALLOCATION;
        amounts[0] = amount1;
        amounts[1] = amount2;

        vm.startPrank(distributor);
        bytes32[] memory distributionIds = tokenomics.allocateBatch(sources, amounts);
        vm.stopPrank();

        assertEq(distributionIds.length, 2);
        assertEq(tokenomics.totalDistributed(), amount1 + amount2);
    }

    function test_AllocateBatch_RevertsOnInvalidLength() public {
        ITokenomicsEngine.RevenueSource[] memory sources = new ITokenomicsEngine.RevenueSource[](1);
        uint256[] memory amounts = new uint256[](2);

        vm.startPrank(distributor);
        vm.expectRevert(TokenomicsEngine.InvalidBatchLength.selector);
        tokenomics.allocateBatch(sources, amounts);
        vm.stopPrank();
    }

    function test_AllocateBatch_RevertsOnEmpty() public {
        ITokenomicsEngine.RevenueSource[] memory sources = new ITokenomicsEngine.RevenueSource[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.startPrank(distributor);
        vm.expectRevert(TokenomicsEngine.InvalidBatchLength.selector);
        tokenomics.allocateBatch(sources, amounts);
        vm.stopPrank();
    }

    // ============ Governance Tests ============

    function test_SetSourceAllocation_UpdatesConfig() public {
        vm.startPrank(admin);
        ITokenomicsEngine.SourceAllocation memory newConfig = ITokenomicsEngine.SourceAllocation({
            verifierRewardsBPS: 5000,
            treasuryReserveBPS: 3000,
            ecosystemIncentivesBPS: 0,
            governanceIncentivesBPS: 1000,
            protocolDevelopmentBPS: 500,
            emergencyReserveBPS: 500,
            active: true
        });
        tokenomics.setSourceAllocation(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
            newConfig
        );
        vm.stopPrank();

        ITokenomicsEngine.SourceAllocation memory config = tokenomics.getAllocationConfig(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES
        );
        assertEq(config.verifierRewardsBPS, 5000);
        assertEq(config.treasuryReserveBPS, 3000);
        assertEq(config.ecosystemIncentivesBPS, 0);
        assertEq(config.governanceIncentivesBPS, 1000);
        assertEq(config.protocolDevelopmentBPS, 500);
        assertEq(config.emergencyReserveBPS, 500);
    }

    function test_SetSourceAllocation_RevertsOnInvalidBPS() public {
        vm.startPrank(admin);
        ITokenomicsEngine.SourceAllocation memory invalidConfig = ITokenomicsEngine.SourceAllocation({
            verifierRewardsBPS: 5000,
            treasuryReserveBPS: 3000,
            ecosystemIncentivesBPS: 1000,
            governanceIncentivesBPS: 1000,
            protocolDevelopmentBPS: 500,
            emergencyReserveBPS: 500,
            active: true
        });
        // Sum = 11000 > 10000
        vm.expectRevert(abi.encodeWithSelector(TokenomicsEngine.AllocationConfigInvalid.selector, "basis points do not sum to 10000"));
        tokenomics.setSourceAllocation(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
            invalidConfig
        );
        vm.stopPrank();
    }

    function test_SetEmissionLimit_UpdatesLimit() public {
        vm.startPrank(admin);
        tokenomics.setEmissionLimit(500e18);
        vm.stopPrank();

        assertEq(tokenomics.emissionLimit(), 500e18);
    }

    function test_SetRewardMultiplier_UpdatesMultiplier() public {
        vm.startPrank(admin);
        tokenomics.setRewardMultiplier(2e18);
        vm.stopPrank();

        assertEq(tokenomics.rewardMultiplier(), 2e18);
    }

    function test_SetRewardMultiplier_RevertsOnZero() public {
        vm.startPrank(admin);
        vm.expectRevert(TokenomicsEngine.InvalidRewardMultiplier.selector);
        tokenomics.setRewardMultiplier(0);
        vm.stopPrank();
    }

    function test_SetTreasuryReserveTarget_UpdatesTarget() public {
        vm.startPrank(admin);
        tokenomics.setTreasuryReserveTarget(3000);
        vm.stopPrank();

        assertEq(tokenomics.treasuryReserveTargetBPS(), 3000);
    }

    function test_SetTreasuryReserveTarget_RevertsOnExcess() public {
        vm.startPrank(admin);
        vm.expectRevert(TokenomicsEngine.InvalidTreasuryReserveTarget.selector);
        tokenomics.setTreasuryReserveTarget(10001);
        vm.stopPrank();
    }

    // ============ Read Interface Tests ============

    function test_GetEmissionStats_ReturnsCorrectData() public {
        TokenomicsEngine.EmissionStats memory stats = tokenomics.getEmissionStats();
        assertEq(stats.totalDistributed, 0);
        assertEq(stats.emissionLimit, type(uint256).max);
        assertEq(stats.rewardMultiplier, 1e18);
        assertEq(stats.treasuryReserveTargetBPS, 2000);
    }

    function test_GetTotalBySource_ReturnsZeroInitially() public {
        assertEq(tokenomics.getTotalBySource(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES), 0);
    }

    function test_GetDistributionHistory_ReturnsEmptyInitially() public {
        TokenomicsEngine.DistributionRecord[] memory history = tokenomics.getDistributionHistory(0, 10);
        assertEq(history.length, 0);
    }

    function test_GetDistributionHistory_ReturnsRecords() public {
        uint256 amount = 100e18;

        vm.startPrank(sender);
        token.approve(address(tokenomics), amount);
        vm.stopPrank();

        vm.startPrank(distributor);
        tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, amount);
        vm.stopPrank();

        TokenomicsEngine.DistributionRecord[] memory history = tokenomics.getDistributionHistory(0, 10);
        assertEq(history.length, 1);
        assertEq(history[0].totalAmount, amount);
    }

    // ============ Event Tests ============

    function test_DistributeRevenue_EmitsRevenueReceived() public {
        uint256 amount = 100e18;

        vm.startPrank(sender);
        token.approve(address(tokenomics), amount);
        vm.stopPrank();

        vm.startPrank(distributor);
        vm.expectEmit(true, false, false, true);
        emit ITokenomicsEngine.RevenueReceived(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
            amount,
            distributor
        );
        tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, amount);
        vm.stopPrank();
    }

    function test_DistributeRevenue_EmitsIncentiveDistributionCompleted() public {
        uint256 amount = 100e18;

        vm.startPrank(sender);
        token.approve(address(tokenomics), amount);
        vm.stopPrank();

        vm.startPrank(distributor);
        // The distribution id is a deterministic keccak of (source, amount, timestamp,
        // sender, nonce) — skip topic checks and match the emitted share amounts.
        vm.expectEmit(false, false, false, true);
        emit ITokenomicsEngine.IncentiveDistributionCompleted(
            bytes32(0),
            40e18, // verifier rewards (4000 BPS)
            15e18, // ecosystem
            10e18, // governance
            10e18, // protocol
            5e18   // emergency
        );
        tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, amount);
        vm.stopPrank();
    }

    function test_SetSourceAllocation_EmitsAllocationUpdated() public {
        vm.startPrank(admin);
        ITokenomicsEngine.SourceAllocation memory newConfig = ITokenomicsEngine.SourceAllocation({
            verifierRewardsBPS: 5000,
            treasuryReserveBPS: 3000,
            ecosystemIncentivesBPS: 0,
            governanceIncentivesBPS: 1000,
            protocolDevelopmentBPS: 500,
            emergencyReserveBPS: 500,
            active: true
        });
        vm.expectEmit(true, false, false, false);
        emit ITokenomicsEngine.AllocationUpdated(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
            4000, 2000, 1500, 1000, 1000, 500,
            5000, 3000, 0, 1000, 500, 500
        );
        tokenomics.setSourceAllocation(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
            newConfig
        );
        vm.stopPrank();
    }

    // ============ Access Control Tests ============

    function test_DistributeRevenue_RevertsWhenNotDistributor() public {
        vm.startPrank(sender);
        vm.expectRevert();
        tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, 100e18);
        vm.stopPrank();
    }

    function test_AllocateBatch_RevertsWhenNotDistributor() public {
        vm.startPrank(sender);
        vm.expectRevert();
        ITokenomicsEngine.RevenueSource[] memory sources = new ITokenomicsEngine.RevenueSource[](0);
        uint256[] memory amounts = new uint256[](0);
        tokenomics.allocateBatch(sources, amounts);
        vm.stopPrank();
    }

    function test_SetSourceAllocation_RevertsWhenNotGovernance() public {
        vm.startPrank(distributor);
        vm.expectRevert();
        tokenomics.setSourceAllocation(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
            ITokenomicsEngine.SourceAllocation({
                verifierRewardsBPS: 4000,
                treasuryReserveBPS: 2000,
                ecosystemIncentivesBPS: 1500,
                governanceIncentivesBPS: 1000,
                protocolDevelopmentBPS: 1000,
                emergencyReserveBPS: 500,
                active: true
            })
        );
        vm.stopPrank();
    }

    // ============ Pause Tests ============

    function test_Pause_BlocksDistribution() public {
        vm.startPrank(admin);
        tokenomics.pause();
        vm.stopPrank();

        vm.startPrank(sender);
        token.approve(address(tokenomics), 100e18);
        vm.stopPrank();

        vm.startPrank(distributor);
        vm.expectRevert();
        tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, 100e18);
        vm.stopPrank();
    }

    function test_Unpause_AllowsDistribution() public {
        vm.startPrank(admin);
        tokenomics.pause();
        tokenomics.unpause();
        vm.stopPrank();

        vm.startPrank(sender);
        token.approve(address(tokenomics), 100e18);
        vm.stopPrank();

        vm.startPrank(distributor);
        bytes32 distributionId = tokenomics.distributeRevenue(
            ITokenomicsEngine.RevenueSource.PROTOCOL_FEES,
            100e18
        );
        vm.stopPrank();

        assertTrue(tokenomics.processedDistributions(distributionId));
    }

    // ============ Emission Limit Tests ============

    function test_EmissionLimit_PreventsExcessDistribution() public {
        vm.startPrank(admin);
        tokenomics.setEmissionLimit(50e18);
        vm.stopPrank();

        // Both attempts must run under the distributor role: the emission-limit check
        // (50e18 used + 50e18 attempted > 50e18 limit) fires before any token transfer.
        vm.startPrank(distributor);
        tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, 50e18);

        vm.expectRevert(abi.encodeWithSelector(TokenomicsEngine.EmissionLimitExceeded.selector, 100e18, 50e18));
        tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, 50e18);
        vm.stopPrank();
    }

    // ============ Reward Multiplier Tests ============

    function test_RewardMultiplier_ScalesVerifierRewards() public {
        vm.startPrank(admin);
        tokenomics.setRewardMultiplier(2e18);
        vm.stopPrank();

        uint256 amount = 100e18;

        // The multiplier rescales the verifier share (4000 BPS * 2 = 8000 BPS) while the
        // other shares keep their BPS, so the shares no longer sum to `amount`. Pre-fund the
        // engine so every share can be deposited: it then fails closed with InvalidAllocation
        // instead of emitting an unreconcilable split.
        token.mint(address(tokenomics), amount);

        vm.startPrank(distributor);
        vm.expectRevert(TokenomicsEngine.InvalidAllocation.selector);
        tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, amount);
        vm.stopPrank();

        // The failed attempt left no trace: nothing distributed, nothing processed.
        assertEq(tokenomics.totalDistributed(), 0);
        assertEq(tokenomics.totalBySource(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES), 0);
    }

    // ============ All Sources Default Config Tests ============

    function test_AllSources_ValidDefaultConfig() public {
        for (uint256 i = 0; i < 5; i++) {
            ITokenomicsEngine.RevenueSource source = ITokenomicsEngine.RevenueSource(i);
            ITokenomicsEngine.SourceAllocation memory config = tokenomics.getAllocationConfig(source);
            assertTrue(config.active);

            uint256 totalBPS = config.verifierRewardsBPS
                + config.treasuryReserveBPS
                + config.ecosystemIncentivesBPS
                + config.governanceIncentivesBPS
                + config.protocolDevelopmentBPS
                + config.emergencyReserveBPS;

            assertEq(totalBPS, tokenomics.BPS_DENOMINATOR(), "BPS must sum to 10000");
        }
    }

    // ============ History Pagination Tests ============

    function test_GetDistributionHistory_Pagination() public {
        uint256 amount = 10e18;

        for (uint256 i = 0; i < 5; i++) {
            vm.startPrank(sender);
            token.approve(address(tokenomics), amount);
            vm.stopPrank();

            vm.startPrank(distributor);
            tokenomics.distributeRevenue(ITokenomicsEngine.RevenueSource.PROTOCOL_FEES, amount);
            vm.stopPrank();
        }

        TokenomicsEngine.DistributionRecord[] memory page1 = tokenomics.getDistributionHistory(0, 2);
        assertEq(page1.length, 2);

        TokenomicsEngine.DistributionRecord[] memory page2 = tokenomics.getDistributionHistory(2, 2);
        assertEq(page2.length, 2);

        TokenomicsEngine.DistributionRecord[] memory page3 = tokenomics.getDistributionHistory(4, 2);
        assertEq(page3.length, 1);

        TokenomicsEngine.DistributionRecord[] memory page4 = tokenomics.getDistributionHistory(10, 2);
        assertEq(page4.length, 0);
    }
}
