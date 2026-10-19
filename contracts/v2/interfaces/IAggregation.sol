// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";

/// @notice Weighted verification aggregation interface.
/// @dev Finalization is permissionless only when the implementation's claim window, quorum, and authority preconditions are satisfied.
interface IAggregation is IV2Module {
    /// @notice Emitted when a claim's weighted result becomes final.
    /// @param claimId Aggregated claim.
    /// @param accepted Final acceptance result.
    /// @param supportingWeight Total weight supporting the claim in configured weight units.
    /// @param opposingWeight Total weight opposing the claim in configured weight units.
    event AggregationFinalized(uint256 indexed claimId, bool accepted, uint256 supportingWeight, uint256 opposingWeight);

    /// @notice Finalizes aggregation for a claim after the configured verification deadline.
    /// @dev Must fail closed unless the claim is eligible, and must be idempotent or revert on repeated finalization.
    /// @param claimId Claim to aggregate.
    function finalizeAggregation(uint256 claimId) external;

    /// @notice Reads the current or final aggregate result.
    /// @param claimId Claim to inspect.
    /// @return finalized True once aggregation is immutable.
    /// @return accepted Accepted result when finalized.
    /// @return supportingWeight Supporting weight in configured units.
    /// @return opposingWeight Opposing weight in configured units.
    function outcome(uint256 claimId) external view returns (bool finalized, bool accepted, uint256 supportingWeight, uint256 opposingWeight);
}
