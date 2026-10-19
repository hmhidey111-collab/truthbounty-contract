// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";
import {IV2Types} from "./IV2Types.sol";

/// @notice Claim creation and lifecycle interface.
/// @dev Claim IDs are monotonic; state changes are authorized by the module responsible for the target transition and are irreversible once terminal.
interface IClaims is IV2Module {
    /// @notice Emitted when a claim is created.
    /// @param claimId Newly assigned claim identifier.
    /// @param claimant Account that created the claim.
    /// @param subject Protocol-defined subject commitment.
    /// @param reward Reward in the configured asset's base units.
    event ClaimCreated(uint256 indexed claimId, address indexed claimant, bytes32 indexed subject, uint256 reward);

    /// @notice Emitted for every authorized claim lifecycle transition.
    /// @param claimId Claim whose state changed.
    /// @param previousState State before the transition.
    /// @param newState State after the transition.
    /// @param actor Authorized account that performed the transition.
    /// @param timestamp Unix timestamp in seconds.
    /// @param reasonCode Stable reason code for the transition.
    event ClaimStateChanged(uint256 indexed claimId, IV2Types.ClaimState previousState, IV2Types.ClaimState newState, address indexed actor, uint64 timestamp, bytes32 reasonCode);

    /// @notice Creates a claim with a subject commitment and configured reward.
    /// @dev Must validate subject, reward bounds, asset, metadata rules, and caller authorization; invalid input fails closed without creating state.
    /// @param subject Protocol-defined subject commitment.
    /// @param reward Reward amount in asset base units.
    /// @param metadata Implementation-defined, non-sensitive metadata; raw evidence must not be trusted from this field.
    /// @return claimId Newly assigned claim identifier.
    function createClaim(bytes32 subject, uint256 reward, bytes calldata metadata) external returns (uint256 claimId);

    /// @notice Cancels a claim when its state machine and cancellation authority permit it.
    /// @dev Must not permit cancellation after finalization or after obligations have been irreversibly assigned.
    /// @param claimId Claim to cancel.
    function cancelClaim(uint256 claimId) external;

    /// @notice Reads a canonical claim record.
    /// @param claimId Claim to read.
    /// @return claim Stored claim fields.
    function getClaim(uint256 claimId) external view returns (IV2Types.Claim memory claim);

    /// @notice Reads the lifecycle state used for transition authorization.
    /// @param claimId Claim to inspect.
    /// @return state Current lifecycle state.
    function stateOf(uint256 claimId) external view returns (IV2Types.ClaimState state);
}
