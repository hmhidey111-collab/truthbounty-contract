// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./Staking.fuzz.sol";
import "../../contracts/WeightedStaking.sol";
import "../../contracts/staking.sol";
import "../../contracts/MockReputationOracle.sol";
import "../../contracts/mocks/MockTreasuryAccounting.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title IntegrationFuzzTest
 * @notice Fuzz tests for integration between WeightedStaking and basic Staking contracts
 */
contract IntegrationFuzzTest is Test {
    WeightedStaking public weightedStaking;
    Staking public staking;
    MockReputationOracle public mockOracle;
    MockERC20 public stakingToken;
    
    address public owner = address(0x1);
    address public verifier1 = address(0x2);
    address public verifier2 = address(0x3);
    address public verifier3 = address(0x4);
    address public slashingContract = address(0x5);
    
    uint256 public constant INITIAL_LOCK_DURATION = 86400; // 1 day
    uint256 public constant BASE_MULTIPLIER = 1e18;
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy mock oracle and token
        mockOracle = new MockReputationOracle();
        stakingToken = new MockERC20("TruthBounty Token", "TBT", 18);
        
        // Deploy contracts
        weightedStaking = new WeightedStaking(address(mockOracle), owner, address(0));
        staking = new Staking(address(stakingToken), INITIAL_LOCK_DURATION, owner);
        staking.setTreasuryAccounting(address(new MockTreasuryAccounting()));
        staking.setSlashingContract(slashingContract);

        // Advance past the resolver role timelock and apply the grant
        vm.warp(block.timestamp + staking.MIN_RESOLVER_ROLE_CHANGE_DELAY());
        staking.executeResolverRoleGrant(staking.resolverRoleChangeId(slashingContract, true), slashingContract);
        
        // Setup verifiers with tokens
        stakingToken.mint(verifier1, 100000e18);
        stakingToken.mint(verifier2, 100000e18);
        stakingToken.mint(verifier3, 100000e18);
        
        vm.stopPrank();
    }
    
    /// @dev Fuzz test for verifier staking with different reputation scores
    function testFuzz_VerifierStaking_ReputationWeighted(
        uint256 stake1,
        uint256 stake2,
        uint256 stake3,
        uint256 rep1,
        uint256 rep2,
        uint256 rep3
    ) public {
        // Bound inputs
        stake1 = bound(stake1, 1, 10000e18);
        stake2 = bound(stake2, 1, 10000e18);
        stake3 = bound(stake3, 1, 10000e18);
        
        rep1 = bound(rep1, 1e17, 10e18); // 0.1 to 10x reputation
        rep2 = bound(rep2, 1e17, 10e18);
        rep3 = bound(rep3, 1e17, 10e18);
        
        // Set reputation scores
        vm.prank(owner);
        mockOracle.setReputationScore(verifier1, rep1);
        vm.prank(owner);
        mockOracle.setReputationScore(verifier2, rep2);
        vm.prank(owner);
        mockOracle.setReputationScore(verifier3, rep3);
        
        // Calculate weighted stakes
        WeightedStaking.WeightedStakeResult memory result1 = weightedStaking.calculateWeightedStake(verifier1, stake1);
        WeightedStaking.WeightedStakeResult memory result2 = weightedStaking.calculateWeightedStake(verifier2, stake2);
        WeightedStaking.WeightedStakeResult memory result3 = weightedStaking.calculateWeightedStake(verifier3, stake3);
        
        // Perform actual staking
        vm.prank(verifier1);
        stakingToken.approve(address(staking), stake1);
        vm.prank(verifier1);
        staking.stake(stake1);
        
        vm.prank(verifier2);
        stakingToken.approve(address(staking), stake2);
        vm.prank(verifier2);
        staking.stake(stake2);
        
        vm.prank(verifier3);
        stakingToken.approve(address(staking), stake3);
        vm.prank(verifier3);
        staking.stake(stake3);
        
        // Verify staking was successful
        (uint256 staked1,,) = staking.getStakeInfo(verifier1);
        (uint256 staked2,,) = staking.getStakeInfo(verifier2);
        (uint256 staked3,,) = staking.getStakeInfo(verifier3);
        
        assertEq(staked1, stake1, "Verifier 1 stake should match");
        assertEq(staked2, stake2, "Verifier 2 stake should match");
        assertEq(staked3, stake3, "Verifier 3 stake should match");
        
        // Verify weighted calculations are consistent
        assertEq(result1.rawStake, stake1, "Weighted calculation should match raw stake");
        assertEq(result2.rawStake, stake2, "Weighted calculation should match raw stake");
        assertEq(result3.rawStake, stake3, "Weighted calculation should match raw stake");
        
        // Verify reputation-based weighting
        assertEq(result1.reputationScore, rep1, "Reputation score should be preserved");
        assertEq(result2.reputationScore, rep2, "Reputation score should be preserved");
        assertEq(result3.reputationScore, rep3, "Reputation score should be preserved");
    }
    
    /// @dev Fuzz test for slashing impact on weighted influence
    function testFuzz_SlashingImpact_WeightedInfluence(
        uint256 initialStake,
        uint256 slashAmount,
        uint256 reputationScore
    ) public {
        // Bound inputs
        initialStake = bound(initialStake, 1000e18, 100000e18);
        slashAmount = bound(slashAmount, 1, initialStake - 1);
        reputationScore = bound(reputationScore, 1e17, 10e18);
        
        // Setup verifier reputation
        vm.prank(owner);
        mockOracle.setReputationScore(verifier1, reputationScore);
        
        // Calculate initial weighted stake
        WeightedStaking.WeightedStakeResult memory initialResult = 
            weightedStaking.calculateWeightedStake(verifier1, initialStake);
        
        // Perform staking
        vm.prank(verifier1);
        stakingToken.approve(address(staking), initialStake);
        vm.prank(verifier1);
        staking.stake(initialStake);
        
        // Verify initial state
        (uint256 stakedBefore,,) = staking.getStakeInfo(verifier1);
        assertEq(stakedBefore, initialStake, "Initial stake should be correct");
        
        // Perform slashing
        vm.prank(slashingContract);
        staking.forceSlash(verifier1, slashAmount);
        
        // Calculate new weighted stake
        uint256 remainingStake = initialStake - slashAmount;
        WeightedStaking.WeightedStakeResult memory afterResult = 
            weightedStaking.calculateWeightedStake(verifier1, remainingStake);
        
        // Verify final state
        (uint256 stakedAfter,,) = staking.getStakeInfo(verifier1);
        assertEq(stakedAfter, remainingStake, "Remaining stake should be correct");
        
        // Verify weighted influence decreased proportionally
        assertEq(afterResult.rawStake, remainingStake, "Raw stake should match remaining");
        assertEq(afterResult.reputationScore, initialResult.reputationScore, "Reputation should be unchanged");
        
        // Weighted influence should decrease proportionally
        uint256 expectedInfluence = (remainingStake * afterResult.weight) / BASE_MULTIPLIER;
        assertEq(afterResult.effectiveStake, expectedInfluence, "Weighted influence should be proportional");
    }
    
    /// @dev Fuzz test for multiple staking cycles with reputation changes
    function testFuzz_MultipleCycles_ReputationChanges(
        uint256[] calldata stakeAmounts,
        uint256[] calldata reputationChanges
    ) public {
        // Cap the number of cycles to keep the test bounded
        uint256 cycles = stakeAmounts.length > 10 ? 10 : stakeAmounts.length;
        vm.assume(cycles > 0);
        
        uint256 totalStaked = 0;
        uint256 currentReputation = 1e18; // Start with default reputation
        
        for (uint256 i = 0; i < cycles; i++) {
            // Bound stake amount
            uint256 stakeAmount = bound(stakeAmounts[i], 1, 10000e18);
            
            // Ensure user has enough tokens
            if (totalStaked + stakeAmount > 100000e18) break;
            
            // Update reputation (reuse entries cyclically if arrays differ in length)
            currentReputation = reputationChanges.length == 0
                ? 1e18
                : bound(reputationChanges[i % reputationChanges.length], 1e17, 10e18);
            vm.prank(owner);
            mockOracle.setReputationScore(verifier1, currentReputation);
            
            // Calculate weighted stake with new reputation
            WeightedStaking.WeightedStakeResult memory result = 
                weightedStaking.calculateWeightedStake(verifier1, stakeAmount);
            
            // Perform staking
            vm.prank(verifier1);
            stakingToken.approve(address(staking), stakeAmount);
            vm.prank(verifier1);
            staking.stake(stakeAmount);
            
            totalStaked += stakeAmount;
            
            // Verify weighted calculation uses current reputation
            assertEq(result.reputationScore, currentReputation, "Should use current reputation");
            
            // Verify staking was successful
            (uint256 staked,,) = staking.getStakeInfo(verifier1);
            assertEq(staked, totalStaked, "Total staked should accumulate");
        }
    }
    
    /// @dev Fuzz test for edge case: very high reputation with small stakes
    function testFuzz_EdgeCase_HighReputationSmallStakes(
        uint256 stakeAmount,
        uint256 reputationScore
    ) public {
        // Test edge case: high reputation (10x) with small stakes
        stakeAmount = bound(stakeAmount, 1, 100e18); // Small stakes
        reputationScore = bound(reputationScore, 5e18, 10e18); // High reputation (5x-10x)
        
        vm.prank(owner);
        mockOracle.setReputationScore(verifier1, reputationScore);
        
        // Calculate weighted stake
        WeightedStaking.WeightedStakeResult memory result = 
            weightedStaking.calculateWeightedStake(verifier1, stakeAmount);
        
        // Perform staking
        vm.prank(verifier1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(verifier1);
        staking.stake(stakeAmount);
        
        // Verify high reputation gives proportionally higher influence
        uint256 expectedInfluence = (stakeAmount * result.weight) / BASE_MULTIPLIER;
        assertEq(result.effectiveStake, expectedInfluence, "High reputation should increase influence");
        assertGe(result.effectiveStake, stakeAmount, "Weighted stake should be >= raw stake for high reputation");
        
        // Verify staking works regardless of reputation
        (uint256 staked,,) = staking.getStakeInfo(verifier1);
        assertEq(staked, stakeAmount, "Staking should work for any reputation level");
    }
    
    /// @dev Fuzz test for emergency disable of weighted staking
    function testFuzz_EmergencyDisable_WeightedStaking(
        uint256 stakeAmount,
        uint256 reputationScore,
        bool disableWeighted
    ) public {
        // Bound inputs
        stakeAmount = bound(stakeAmount, 1, 10000e18);
        reputationScore = bound(reputationScore, 1e17, 10e18);
        
        // Set reputation
        vm.prank(owner);
        mockOracle.setReputationScore(verifier1, reputationScore);
        
        // Disable weighted staking if requested
        if (disableWeighted) {
            vm.prank(owner);
            weightedStaking.setWeightedStakingEnabled(false);
        }
        
        // Calculate weighted stake
        WeightedStaking.WeightedStakeResult memory result = 
            weightedStaking.calculateWeightedStake(verifier1, stakeAmount);
        
        // Perform staking
        vm.prank(verifier1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(verifier1);
        staking.stake(stakeAmount);
        
        // Verify behavior based on weighted staking status
        if (disableWeighted) {
            assertEq(result.effectiveStake, stakeAmount, "Should use equal weights when disabled");
            assertEq(result.reputationScore, BASE_MULTIPLIER, "Should use base reputation when disabled");
        } else {
            assertEq(result.reputationScore, reputationScore, "Should use actual reputation when enabled");
            // Weighted stake should reflect reputation
            uint256 expectedInfluence = (stakeAmount * result.weight) / BASE_MULTIPLIER;
            assertEq(result.effectiveStake, expectedInfluence, "Should use reputation-weighted influence");
        }
        
        // Staking should work regardless of weighted staking status
        (uint256 staked,,) = staking.getStakeInfo(verifier1);
        assertEq(staked, stakeAmount, "Staking should work regardless of weighted status");
    }
}
