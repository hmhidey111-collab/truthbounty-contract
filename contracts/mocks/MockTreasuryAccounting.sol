// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../treasury/ITreasuryAccounting.sol";

/**
 * @title MockTreasuryAccounting
 * @dev Lightweight test double for ITreasuryAccounting that records calls
 *      without enforcing token-flow invariants. Used by unit-test fixtures
 *      that deploy Staking but do not need real treasury accounting.
 */
contract MockTreasuryAccounting is ITreasuryAccounting {
    uint256 public stakingReserve;
    uint256 public slashedTreasury;
    uint256 public totalStakeRecorded;
    uint256 public totalUnstakeRecorded;
    uint256 public totalSlashRecorded;
    uint256 public totalRewardRecorded;
    uint256 public totalFeeRecorded;
    uint256 public totalDonationRecorded;

    function recordStake(address user, uint256 amount) external {
        stakingReserve += amount;
        totalStakeRecorded += amount;
    }

    function depositToAccount(TreasuryAccount targetAccount, uint256 amount) external {
        if (targetAccount == TreasuryAccount.STAKING_RESERVE) {
            stakingReserve += amount;
        } else if (targetAccount == TreasuryAccount.SLASHED_TREASURY) {
            slashedTreasury += amount;
        }
    }

    function recordUnstake(address user, uint256 amount) external {
        stakingReserve -= amount;
        totalUnstakeRecorded += amount;
    }

    function recordSlash(address verifier, uint256 amount) external {
        stakingReserve -= amount;
        slashedTreasury += amount;
        totalSlashRecorded += amount;
    }


    function recordRewardDistribution(address recipient, uint256 amount) external {
        totalRewardRecorded += amount;
    }

    function transferBetweenAccounts(
        TreasuryAccount fromAccount,
        TreasuryAccount toAccount,
        uint256 amount,
        string calldata movementType
    ) external {
        if (fromAccount == TreasuryAccount.STAKING_RESERVE) {
            stakingReserve -= amount;
        } else if (fromAccount == TreasuryAccount.SLASHED_TREASURY) {
            slashedTreasury -= amount;
        }
        if (toAccount == TreasuryAccount.STAKING_RESERVE) {
            stakingReserve += amount;
        } else if (toAccount == TreasuryAccount.SLASHED_TREASURY) {
            slashedTreasury += amount;
        }
        if (keccak256(bytes(movementType)) == keccak256(bytes("FEE"))) {
            totalFeeRecorded += amount;
        } else if (keccak256(bytes(movementType)) == keccak256(bytes("DONATION"))) {
            totalDonationRecorded += amount;
        }
    }

    function getAccountBalance(TreasuryAccount account) external view returns (uint256) {
        if (account == TreasuryAccount.STAKING_RESERVE) return stakingReserve;
        if (account == TreasuryAccount.SLASHED_TREASURY) return slashedTreasury;
        return 0;
    }

    function getAccountBalances() external view returns (uint256[6] memory balances) {
        balances[uint256(TreasuryAccount.STAKING_RESERVE)] = stakingReserve;
        balances[uint256(TreasuryAccount.SLASHED_TREASURY)] = slashedTreasury;
    }

    function calculateTotalAssets() external view returns (uint256) {
        return stakingReserve + slashedTreasury;
    }

    function getTrackedCustody() external view returns (uint256) {
        return stakingReserve + slashedTreasury;
    }

    function getAccountedComponents() external view returns (uint256) {
        return totalStakeRecorded + totalRewardRecorded + totalFeeRecorded + totalDonationRecorded
            - totalUnstakeRecorded - totalSlashRecorded;
    }

    function reconcile(uint256 observedBalance) external view returns (int256 delta) {
        delta = int256(observedBalance) - int256(getTrackedCustody());
    }
}
