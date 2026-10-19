// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";
import {IV2Types} from "./IV2Types.sol";


/// @notice Settlement queue and execution interface.
/// @dev Settlement is pull-based: queueing records the obligation and execution credits or transfers only the authorized net amount. Fee arithmetic must be explicit and fail closed.
interface ISettlement is IV2Module {
    /// @notice Emitted when a settlement becomes queued and executable after its timelock.
    /// @param claimId Claim being settled.
    /// @param recipient Account entitled to the net amount.
    /// @param grossAmount Gross settlement in asset base units.
    /// @param fee Protocol fee in asset base units.
    /// @param executableAt Earliest Unix timestamp in seconds for execution.
    event SettlementQueued(uint256 indexed claimId, address indexed recipient, uint256 grossAmount, uint256 fee, uint64 executableAt);

    /// @notice Emitted when the queued settlement is executed exactly once.
    /// @param claimId Claim being settled.
    /// @param recipient Account credited with the net amount.
    /// @param netAmount Gross amount minus fee in asset base units.
    event SettlementExecuted(uint256 indexed claimId, address indexed recipient, uint256 netAmount);

    /// @notice Emitted when a settlement is cancelled and the obligation is voided.
    /// @param claimId Claim being cancelled.
    event SettlementCancelled(uint256 indexed claimId);

    /// @notice Emitted when a settlement execution fails due to an external payout failure.
    /// @param claimId Claim being settled.
    /// @param reason ABI-encoded reason code.
    event SettlementFailed(uint256 indexed claimId, bytes reason);

    /// @notice Queues the canonical settlement for a finalized claim.
    /// @dev Must validate final outcome, recipient, fee, and timelock before recording a pending settlement; repeated queueing must revert or be explicitly idempotent.
    /// @param claimId Claim to queue.
    function queueSettlement(uint256 claimId) external;

    /// @notice Executes a pending settlement at or after its executable timestamp.
    /// @dev Must fail closed if the timelock has not elapsed, funds are insufficient, or the settlement was already executed. External token calls must revert atomically on failure.
    /// @param claimId Claim to execute.
    function executeSettlement(uint256 claimId) external;

    /// @notice Cancels a pending settlement before execution.
    /// @dev Only callable by authorized roles or under emergency controls.
    /// @param claimId Claim to cancel.
    function cancelSettlement(uint256 claimId) external;

    /// @notice Reads the current settlement record.
    /// @param claimId Claim to inspect.
    /// @return settlement Settlement status, amounts, recipient, and execution timestamp.
    function getSettlement(uint256 claimId) external view returns (IV2Types.Settlement memory settlement);
}
