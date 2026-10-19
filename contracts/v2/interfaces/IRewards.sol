// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";

/// @notice Accrual and pull-based reward accounting interface.
/// @dev Accrual is authority-controlled and idempotency is required; claiming is a pull operation and must not let a caller withdraw another account's balance.
interface IRewards is IV2Module {
    /// @notice Emitted when a reward is credited to an account.
    /// @param claimId Source claim identifier.
    /// @param account Account credited.
    /// @param amount Reward amount in the configured asset's base units.
    event RewardAccrued(uint256 indexed claimId, address indexed account, uint256 amount);

    /// @notice Emitted when an account claims its accrued rewards.
    /// @param account Account whose balance was reduced.
    /// @param amount Amount claimed in asset base units.
    event RewardClaimed(address indexed account, uint256 amount);

    /// @notice Credits a reward to an account through the authorized settlement or rewards path.
    /// @dev Must verify the source claim outcome, caller authority, amount, and token funding; zero or unfunded accruals must revert.
    /// @param claimId Source claim identifier.
    /// @param account Account receiving the reward.
    /// @param amount Reward amount in asset base units.
    function accrue(uint256 claimId, address account, uint256 amount) external;

    /// @notice Claims the caller's accrued rewards.
    /// @dev Uses a pull-based boundary and must clear the balance before or atomically with any external transfer to prevent reentrancy.
    /// @param account Account whose balance is claimed; implementations may require it equals `msg.sender`.
    /// @return amount Amount transferred in asset base units.
    function claimRewards(address account) external returns (uint256 amount);

    /// @notice Reads the currently claimable reward balance.
    /// @param account Account to inspect.
    /// @return amount Claimable amount in asset base units.
    function claimable(address account) external view returns (uint256 amount);
}
