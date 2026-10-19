// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";

/// @notice Slash proposal and execution interface.
/// @dev Proposals are immutable records. Execution is authority-gated, challenge/timelock aware, and may consume at most the recorded amount.
interface ISlashing is IV2Module {
    /// @notice Emitted when a slash proposal is created.
    /// @param proposalId Deterministic proposal identifier.
    /// @param claimId Claim associated with the proposal.
    /// @param verifier Verifier whose stake is proposed for slashing.
    /// @param amount Slash amount in asset base units.
    /// @param reason Stable reason code or digest.
    event SlashProposed(bytes32 indexed proposalId, uint256 indexed claimId, address indexed verifier, uint256 amount, bytes32 reason);

    /// @notice Emitted when a proposal is executed and custody is reduced.
    /// @param proposalId Executed proposal.
    /// @param verifier Verifier whose stake was reduced.
    /// @param amount Amount actually slashed in asset base units.
    event SlashExecuted(bytes32 indexed proposalId, address indexed verifier, uint256 amount);

    /// @notice Creates an immutable slash proposal.
    /// @dev Must require the proposer authority, valid claim and verifier, positive amount, and an amount no greater than the current stake.
    /// @param claimId Claim whose stake is affected.
    /// @param verifier Verifier account to slash.
    /// @param amount Requested slash amount in asset base units.
    /// @param reason Stable reason code or digest.
    /// @return proposalId Deterministic proposal identifier.
    function proposeSlash(uint256 claimId, address verifier, uint256 amount, bytes32 reason) external returns (bytes32 proposalId);

    /// @notice Executes an eligible slash proposal exactly once.
    /// @dev Must enforce proposal status, challenge period, caller authority, and current stake; failed custody calls must revert atomically.
    /// @param proposalId Proposal to execute.
    function executeSlash(bytes32 proposalId) external;

    /// @notice Reads the immutable slash amount for a proposal.
    /// @param proposalId Proposal to inspect.
    /// @return amount Slash amount in asset base units.
    function slashAmount(bytes32 proposalId) external view returns (uint256 amount);
}
