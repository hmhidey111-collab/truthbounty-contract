// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

/**
 * @title ITruthBountyGovernor
 * @notice TruthBounty governor surface including proposal-id helpers from `GovernorStorage`.
 * @dev Proposal targets must be governed modules; queueing and execution are governed by the timelock. The guardian may cancel through the governor's authorized path but has no special execution privilege.
 */
interface ITruthBountyGovernor is IGovernor {
    /// @notice Cancels a proposal when the caller is the proposer, guardian, or another governor-authorized actor.
    /// @dev Cancelling a pending proposal prevents queueing/execution; it cannot undo operations already executed by the timelock.
    /// @param proposalId Proposal to cancel.
    function cancel(uint256 proposalId) external;

    /// @notice Queues a successful proposal in the timelock.
    /// @dev Must revert until voting succeeds; queueing is permitted then, and the timelock delay must expire before execution. Queueing does not execute module calls.
    /// @param proposalId Proposal to queue.
    function queue(uint256 proposalId) external;

    /// @notice Executes a queued proposal after the timelock delay.
    /// @dev Native value isolation (V2-SC-153): TruthBounty V2 is token-denominated, so `msg.value`
    ///      must be zero. Attaching native currency reverts with
    ///      `TruthBountyGovernor.UnexpectedNativeValue`, and any proposal operation with a non-zero
    ///      native value reverts with `TruthBountyGovernor.NativeValueProposalNotAllowed` — the
    ///      governor never forwards or accounts for native currency. Any failed target call reverts
    ///      the complete execution and cannot produce partial protocol mutation.
    /// @param proposalId Proposal to execute.
    function execute(uint256 proposalId) external payable;
}
