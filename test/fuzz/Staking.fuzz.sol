// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/staking.sol";
import "../../contracts/mocks/MockTreasuryAccounting.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract StakingFuzzTest is Test {
    Staking public staking;
    MockERC20 public stakingToken;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);
    address public slashingContract = address(0x5);
    
    uint256 public constant INITIAL_LOCK_DURATION = 86400; // 1 day
    uint256 public constant MAX_STAKE_AMOUNT = 1000000e18; // 1M tokens
    
    event Staked(address indexed user, uint256 amount, uint256 totalStaked, uint256 unlockTime);
    event Unstaked(address indexed user, uint256 amount, uint256 remainingStake);
    event StakeSlashed(address indexed user, uint256 amount, uint256 remainingStake);
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy mock ERC20 token
        stakingToken = new MockERC20("TruthBounty Token", "TBT", 18);
        
        // Deploy staking contract
        staking = new Staking(address(stakingToken), INITIAL_LOCK_DURATION, owner);
        
        // Configure treasury accounting
        staking.setTreasuryAccounting(address(new MockTreasuryAccounting()));
        
        // Set slashing contract
        staking.setSlashingContract(slashingContract);
        
        // Advance past the resolver role timelock and apply the grant
        vm.warp(block.timestamp + staking.MIN_RESOLVER_ROLE_CHANGE_DELAY());
        staking.executeResolverRoleGrant(staking.resolverRoleChangeId(slashingContract, true), slashingContract);
        
        // Mint tokens to test users
        stakingToken.mint(user1, 1000000e18);
        stakingToken.mint(user2, 1000000e18);
        stakingToken.mint(user3, 1000000e18);
        
        vm.stopPrank();
    }
    
    /// @dev Fuzz test for staking with random amounts
    function testFuzz_Stake_RandomAmounts(
        uint256 stakeAmount
    ) public {
        // Bound stake amount to reasonable range
        vm.assume(stakeAmount > 0 && stakeAmount <= 10000e18);
        
        // Approve tokens for staking
        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        
        // Get initial state
        (uint256 initialStaked,,) = staking.getStakeInfo(user1);
        uint256 initialBalance = stakingToken.balanceOf(address(staking));
        
        // Stake tokens
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit Staked(user1, stakeAmount, initialStaked + stakeAmount, block.timestamp + INITIAL_LOCK_DURATION);
        
        staking.stake(stakeAmount);
        
        // Verify final state
        (uint256 finalStaked, uint256 unlockTime,) = staking.getStakeInfo(user1);
        uint256 finalBalance = stakingToken.balanceOf(address(staking));
        
        assertEq(finalStaked, initialStaked + stakeAmount, "Staked amount should increase");
        assertEq(unlockTime, block.timestamp + INITIAL_LOCK_DURATION, "Unlock time should be set correctly");
        assertEq(finalBalance, initialBalance + stakeAmount, "Contract balance should increase");
        
        // Verify user balance decreased
        assertEq(stakingToken.balanceOf(user1), 1000000e18 - stakeAmount, "User balance should decrease");
    }
    
    /// @dev Fuzz test for multiple stakes in sequence
    function testFuzz_MultipleStakes_Sequence(
        uint256[] calldata stakeAmounts
    ) public {
        // Ensure reasonable array size
        vm.assume(stakeAmounts.length > 0 && stakeAmounts.length <= 20);
        
        uint256 totalStaked = 0;
        uint256 initialContractBalance = stakingToken.balanceOf(address(staking));
        
        for (uint256 i = 0; i < stakeAmounts.length; i++) {
            // Bound each stake amount
            uint256 boundedAmount = bound(stakeAmounts[i], 1, 1000e18);
            
            // Ensure user has enough tokens
            if (totalStaked + boundedAmount > 1000000e18) break;
            
            // Approve and stake
            vm.prank(user1);
            stakingToken.approve(address(staking), boundedAmount);
            
            vm.prank(user1);
            staking.stake(boundedAmount);
            
            totalStaked += boundedAmount;
        }
        
        // Verify final state
        (uint256 finalStaked,,) = staking.getStakeInfo(user1);
        assertEq(finalStaked, totalStaked, "Total staked should match sum of all stakes");
        assertEq(
            stakingToken.balanceOf(address(staking)),
            initialContractBalance + totalStaked,
            "Contract balance should reflect total stakes"
        );
    }
    
    /// @dev Fuzz test for unstaking with random amounts and timing
    function testFuzz_Unstake_RandomAmountsAndTiming(
        uint256 stakeAmount,
        uint256 unstakeAmount,
        uint256 timeJump
    ) public {
        // Bound inputs
        vm.assume(stakeAmount > 0 && stakeAmount <= 10000e18);
        vm.assume(unstakeAmount > 0 && unstakeAmount <= stakeAmount);
        vm.assume(timeJump <= 365 days); // Max 1 year
        
        // Setup: stake tokens
        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        
        vm.prank(user1);
        staking.stake(stakeAmount);
        
        // Jump forward in time if needed
        if (timeJump > 0) {
            vm.warp(block.timestamp + timeJump);
        }
        
        // Attempt to unstake
        bool shouldSucceed = block.timestamp >= (block.timestamp - timeJump + INITIAL_LOCK_DURATION);
        
        if (shouldSucceed) {
            (uint256 initialStaked,,) = staking.getStakeInfo(user1);
            uint256 initialBalance = stakingToken.balanceOf(user1);
            
            vm.prank(user1);
            vm.expectEmit(true, true, true, true);
            emit Unstaked(user1, unstakeAmount, initialStaked - unstakeAmount);
            
            staking.unstake(unstakeAmount);
            
            // Verify state changes
            (uint256 finalStaked,,) = staking.getStakeInfo(user1);
            assertEq(finalStaked, initialStaked - unstakeAmount, "Staked amount should decrease");
            assertEq(stakingToken.balanceOf(user1), initialBalance + unstakeAmount, "User should receive tokens");
        } else {
            // Should revert due to lock period
            vm.prank(user1);
            vm.expectRevert("Stake is still locked");
            staking.unstake(unstakeAmount);
        }
    }
    
    /// @dev Fuzz test for boundary conditions
    function testFuzz_BoundaryConditions_EdgeCases(
        uint256 stakeAmount
    ) public {
        // Test with very small and very large amounts
        vm.assume(stakeAmount > 0 && stakeAmount <= MAX_STAKE_AMOUNT);
        
        // Test minimum stake (1 wei)
        if (stakeAmount == 1) {
            vm.prank(user1);
            stakingToken.approve(address(staking), 1);
            
            vm.prank(user1);
            staking.stake(1);
            
            (uint256 staked,,) = staking.getStakeInfo(user1);
            assertEq(staked, 1, "Should be able to stake minimum amount");
        }
        
        // Test maximum reasonable stake
        if (stakeAmount >= 100000e18) {
            vm.prank(user2);
            stakingToken.approve(address(staking), stakeAmount);
            
            vm.prank(user2);
            staking.stake(stakeAmount);
            
            (uint256 staked,,) = staking.getStakeInfo(user2);
            assertEq(staked, stakeAmount, "Should be able to stake large amounts");
        }
    }
    
    /// @dev Fuzz test for concurrent users staking
    function testFuzz_ConcurrentUsers_MultipleStakers(
        uint256 amount1,
        uint256 amount2,
        uint256 amount3
    ) public {
        // Bound amounts
        amount1 = bound(amount1, 1, 10000e18);
        amount2 = bound(amount2, 1, 10000e18);
        amount3 = bound(amount3, 1, 10000e18);
        
        // User 1 stakes
        vm.prank(user1);
        stakingToken.approve(address(staking), amount1);
        vm.prank(user1);
        staking.stake(amount1);
        
        // User 2 stakes
        vm.prank(user2);
        stakingToken.approve(address(staking), amount2);
        vm.prank(user2);
        staking.stake(amount2);
        
        // User 3 stakes
        vm.prank(user3);
        stakingToken.approve(address(staking), amount3);
        vm.prank(user3);
        staking.stake(amount3);
        
        // Verify all stakes are recorded correctly
        (uint256 staked1,,) = staking.getStakeInfo(user1);
        (uint256 staked2,,) = staking.getStakeInfo(user2);
        (uint256 staked3,,) = staking.getStakeInfo(user3);
        
        assertEq(staked1, amount1, "User 1 stake incorrect");
        assertEq(staked2, amount2, "User 2 stake incorrect");
        assertEq(staked3, amount3, "User 3 stake incorrect");
        
        // Verify total contract balance
        uint256 totalStaked = amount1 + amount2 + amount3;
        assertEq(stakingToken.balanceOf(address(staking)), totalStaked, "Total contract balance incorrect");
    }
    
    /// @dev Fuzz test for slashing mechanism
    function testFuzz_Slashing_RandomAmounts(
        uint256 stakeAmount,
        uint256 slashAmount
    ) public {
        // Bound amounts
        vm.assume(stakeAmount > 0 && stakeAmount <= 10000e18);
        vm.assume(slashAmount > 0 && slashAmount <= stakeAmount);
        
        // Setup stake
        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);
        
        // Verify initial state
        (uint256 initialStaked,,) = staking.getStakeInfo(user1);
        uint256 initialContractBalance = stakingToken.balanceOf(address(staking));
        
        // Perform slash
        vm.prank(slashingContract);
        vm.expectEmit(true, true, true, true);
        emit StakeSlashed(user1, slashAmount, initialStaked - slashAmount);
        
        staking.forceSlash(user1, slashAmount);
        
        // Verify final state
        (uint256 finalStaked,,) = staking.getStakeInfo(user1);
        uint256 finalContractBalance = stakingToken.balanceOf(address(staking));
        
        assertEq(finalStaked, initialStaked - slashAmount, "Staked amount should decrease by slash amount");
        assertEq(finalContractBalance, initialContractBalance - slashAmount, "Slashed tokens transferred to slashing contract");
        assertEq(stakingToken.balanceOf(slashingContract), slashAmount, "Slashing contract received slashed tokens");
    }
    
    /// @dev Fuzz test for invalid operations
    function testFuzz_InvalidOperations_RevertConditions(
        uint256 stakeAmount,
        uint256 unstakeAmount
    ) public {
        // Test staking 0 tokens
        vm.prank(user1);
        vm.expectRevert("Cannot stake 0");
        staking.stake(0);

        // Test unstaking more than staked
        uint256 boundedStake = bound(stakeAmount, 1, 10000e18);
        uint256 tooMuch = bound(unstakeAmount, boundedStake + 1, boundedStake + 10000e18);

        vm.prank(user1);
        stakingToken.approve(address(staking), boundedStake);
        vm.prank(user1);
        staking.stake(boundedStake);

        vm.prank(user1);
        vm.expectRevert("Insufficient staked balance");
        staking.unstake(tooMuch);
    }
    
    /// @dev Fuzz test for lock duration updates
    function testFuzz_LockDurationUpdate_FutureStakes(
        uint256 newDuration,
        uint256 stakeAmount
    ) public {
        // Bound inputs
        vm.assume(newDuration > 0 && newDuration <= 365 days);
        vm.assume(stakeAmount > 0 && stakeAmount <= 10000e18);
        
        // Update lock duration
        vm.prank(owner);
        staking.setLockDuration(newDuration);
        
        // Stake after update
        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);
        
        // Verify new lock duration is used
        (, uint256 unlockTime,) = staking.getStakeInfo(user1);
        assertEq(unlockTime, block.timestamp + newDuration, "Should use new lock duration");
    }
    
    /// @dev Fuzz test for getStakeInfo accuracy
    function testFuzz_GetStakeInfo_AccurateTiming(
        uint256 stakeAmount,
        uint256 timeJump
    ) public {
        // Bound inputs
        vm.assume(stakeAmount > 0 && stakeAmount <= 10000e18);
        vm.assume(timeJump <= 365 days);
        
        // Setup stake
        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);
        
        // Jump forward in time
        vm.warp(block.timestamp + timeJump);
        
        // Get stake info
        (uint256 amount, uint256 unlockTime, uint256 timeRemaining) = staking.getStakeInfo(user1);
        
        assertEq(amount, stakeAmount, "Staked amount should be correct");
        assertEq(unlockTime, block.timestamp - timeJump + INITIAL_LOCK_DURATION, "Unlock time should be correct");
        
        // Verify time remaining calculation
        uint256 expectedRemaining = 0;
        if (block.timestamp < unlockTime) {
            expectedRemaining = unlockTime - block.timestamp;
        }
        assertEq(timeRemaining, expectedRemaining, "Time remaining should be accurate");
    }
}

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol) {
        _mint(msg.sender, 1000000000 * 10**decimals); // 1B tokens for testing
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function decimals() public view override returns (uint8) {
        return 18;
    }
}
