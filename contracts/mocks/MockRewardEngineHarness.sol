// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RewardEngine} from "../reward/RewardEngine.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockRewardEngineHarness
 * @notice Test harness that extends RewardEngine with a drainPool() helper
 *         so that Foundry tests can force pool-exhaustion scenarios.
 *
 * @dev drainPool() transfers `amount` of the reward token to address(1)
 *      (a dead address that cannot be address(0)) without updating
 *      totalFunded/totalAllocated, thereby making the available balance
 *      fall below any pending reservations.  This simulates the engine
 *      having been used up without triggering normal accounting paths.
 */
contract MockRewardEngineHarness is RewardEngine {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constructor – mirrors RewardEngine's constructor signature
    // =========================================================================

    constructor(
        address _reputationOracle,
        address initialAdmin,
        address _governanceController
    ) RewardEngine(_reputationOracle, initialAdmin, _governanceController) {}

    // =========================================================================
    // Test helpers
    // =========================================================================

    /**
     * @notice Transfer `amount` of the reward token out of the engine to a
     *         burn address, artificially reducing the available pool balance.
     *
     *         Callable by anyone in tests – no access control is intentional
     *         since this is a test-only function.
     *
     * @param amount Number of tokens to drain.
     */
    function drainPool(uint256 amount) external {
        require(address(rewardToken) != address(0), "Harness: token not set");
        require(amount > 0, "Harness: zero drain");

        // Transfer to a deterministic dead address (not address(0) to avoid
        // ERC20 transfer-to-zero reverts).
        rewardToken.safeTransfer(address(0xdead), amount);
    }

    /**
     * @notice Return a full RewardDistribution struct for the given distributionId.
     *         Solidity's auto-generated getter for a mapping to a struct returns
     *         individual tuple components rather than the struct itself, so we
     *         provide this explicit getter for tests.
     */
    function getDistribution(bytes32 distributionId)
        external
        view
        returns (RewardDistribution memory)
    {
        return rewardDistributions[distributionId];
    }
}
