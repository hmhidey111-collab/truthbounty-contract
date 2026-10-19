// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "./libraries/BoundedSafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./utils/ResolverRoleTimelock.sol";
import "./treasury/ITreasuryAccounting.sol";

contract Staking is ReentrancyGuard, ResolverRoleTimelock {
    using SafeERC20 for IERC20;
    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    
    // The token being staked (TruthBountyToken)
    IERC20 public stakingToken;

    // Duration in seconds that tokens must be locked after staking
    uint256 public lockDuration;
    
    // Address authorized to slash stakes (VerifierSlashing contract)
    address public slashingContract;

    // Treasury accounting contract for protocol-wide financial tracking
    ITreasuryAccounting public treasuryAccounting;
    /// @notice Destination for all confiscated verifier collateral.
    address public treasury;

    struct StakeInfo {
        uint256 amount;      // Total amount currently staked
        uint256 unlockTime;  // Timestamp when the stake allows withdrawal
    }

    // Mapping of user address to their stake details
    mapping(address => StakeInfo) public stakes;

    // Events for frontend indexing
    event Staked(address indexed user, uint256 amount, uint256 totalStaked, uint256 unlockTime);
    event Unstaked(address indexed user, uint256 amount, uint256 remainingStake);
    event LockDurationUpdated(uint256 newDuration);
    event StakeSlashed(address indexed user, uint256 amount, uint256 remainingStake);
    event SlashingContractUpdated(address newSlashingContract);
    event TreasuryAccountingUpdated(address newTreasuryAccounting);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /**
     * @param _stakingToken Address of the TruthBountyToken
     * @param _initialLockDuration Initial lock time in seconds (e.g., 86400 for 1 day)
     * @param initialAdmin Initial admin address
     */
    constructor(address _stakingToken, uint256 _initialLockDuration, address initialAdmin) {
        require(_stakingToken != address(0), "Invalid token address");
        require(initialAdmin != address(0), "Invalid admin address");
        
        stakingToken = IERC20(_stakingToken);
        lockDuration = _initialLockDuration;
        treasury = initialAdmin;
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        
        _setRoleAdmin(RESOLVER_ROLE, ADMIN_ROLE);
    }

    /**
     * @dev Set the treasury accounting contract (admin only)
     * @param _treasuryAccounting Address of the deployed TreasuryAccounting contract
     */
    function setTreasuryAccounting(address _treasuryAccounting) external onlyRole(ADMIN_ROLE) {
        require(_treasuryAccounting != address(0), "Invalid treasury address");
        treasuryAccounting = ITreasuryAccounting(_treasuryAccounting);
        emit TreasuryAccountingUpdated(_treasuryAccounting);
    }

    function _resolverRole() internal pure override returns (bytes32) {
        return RESOLVER_ROLE;
    }

    /**
     * @dev Stake tokens into the contract. 
     * Resets the unlock timer for the ENTIRE balance to prevent manipulation.
     * @param amount The amount of tokens to stake.
     */
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Cannot stake 0");
        require(address(treasuryAccounting) != address(0), "Treasury not configured");

        // Transfer tokens from user to contract (requires approve())
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        // Record the stake in treasury accounting
        treasuryAccounting.recordStake(msg.sender, amount);

        StakeInfo storage info = stakes[msg.sender];
        
        // Update balance
        info.amount += amount;
        
        // Reset lock period based on current time + duration
        info.unlockTime = block.timestamp + lockDuration;

        emit Staked(msg.sender, amount, info.amount, info.unlockTime);
    }

    /**
     * @dev Withdraw staked tokens. Can only be called after lock period expires.
     * @param amount The amount to withdraw.
     */
    function unstake(uint256 amount) external nonReentrant {
        StakeInfo storage info = stakes[msg.sender];
        
        require(info.amount >= amount, "Insufficient staked balance");
        require(block.timestamp >= info.unlockTime, "Stake is still locked");
        require(amount > 0, "Cannot unstake 0");
        require(address(treasuryAccounting) != address(0), "Treasury not configured");

        // Update balance
        info.amount -= amount;

        // Record the unstake in treasury accounting before transferring
        treasuryAccounting.recordUnstake(msg.sender, amount);

        // Transfer tokens back to user
        stakingToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount, info.amount);
    }

    /**
     * @dev Returns the full stake info for a user.
     */
    function getStakeInfo(address user) external view returns (uint256 amount, uint256 unlockTime, uint256 timeRemaining) {
        StakeInfo memory info = stakes[user];
        
        uint256 remaining = 0;
        if (block.timestamp < info.unlockTime) {
            remaining = info.unlockTime - block.timestamp;
        }

        return (info.amount, info.unlockTime, remaining);
    }

    /**
     * @dev Admin function to update the lock duration for FUTURE stakes.
     */
    function setLockDuration(uint256 _duration) external onlyRole(ADMIN_ROLE) {
        lockDuration = _duration;
        emit LockDurationUpdated(_duration);
    }
    
    /// @notice Update the Treasury destination for confiscated collateral.
    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        require(newTreasury != address(0), "Invalid treasury");
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @dev Set the authorized slashing contract
     * @param _slashingContract Address of the VerifierSlashing contract
     */
    function setSlashingContract(address _slashingContract) external onlyRole(ADMIN_ROLE) {
        require(_slashingContract != address(0), "Invalid slashing contract");
        
        // Revoke role from old slashing contract if it exists, or cancel an unexecuted grant.
        if (slashingContract != address(0)) {
            if (hasRole(RESOLVER_ROLE, slashingContract)) {
                _scheduleResolverRoleRevoke(slashingContract);
            } else {
                bytes32 pendingGrant = resolverRoleChangeId(slashingContract, true);
                if (resolverRoleChangeReadyAt[pendingGrant] != 0) {
                    delete resolverRoleChangeReadyAt[pendingGrant];
                    emit ResolverRoleChangeCancelled(pendingGrant, slashingContract, true);
                }
            }
        }
        
        slashingContract = _slashingContract;
        if (!hasRole(RESOLVER_ROLE, _slashingContract)) {
            _scheduleResolverRoleGrant(_slashingContract);
        }
        
        emit SlashingContractUpdated(_slashingContract);
    }
    
    /**
     * @dev Force slash a verifier's stake (only callable by slashing contract)
     * @param user Address of the user to slash
     * @param amount Amount to slash from their stake
     */
    function forceSlash(address user, uint256 amount) external {
        if (!hasRole(RESOLVER_ROLE, msg.sender)) {
            revert("Only authorized resolvers can slash");
        }
        // Slashing contract check as secondary safeguard
        require(slashingContract != address(0), "Slashing contract not set");
        require(msg.sender == slashingContract, "Only active slashing contract");
        require(address(treasuryAccounting) != address(0), "Treasury not configured");
        
        StakeInfo storage info = stakes[user];
        require(info.amount >= amount, "Insufficient stake to slash");
        
        // Reduce the staked amount
        info.amount -= amount;
        
        // Record the slash in treasury accounting - moves from staking reserve to slashed treasury
        treasuryAccounting.recordSlash(user, amount);
        // Transfer the slashed tokens to the slashing contract for routing
        stakingToken.transfer(msg.sender, amount);

        emit StakeSlashed(user, amount, info.amount);
    }
}
