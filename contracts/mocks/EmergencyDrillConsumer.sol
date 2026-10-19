// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { EmergencyGatekeeper } from "../v2/EmergencyGatekeeper.sol";
import { V2Errors } from "../v2/libraries/V2Errors.sol";

/// @title EmergencyDrillConsumer
/// @notice Minimal V2-style protocol module used by the Emergency Pause & Recovery
///         Exercise Suite (V2-SC-067) to demonstrate gate enforcement end-to-end.
/// @dev Holds a synthetic asset balance ("solvency") so drills can prove that pausing
///      a scope freezes protocol mutations without ever letting the gate modify state
///      that outlives the failed call. Purely a test fixture: not deployed to production.
contract EmergencyDrillConsumer {
    /// @notice The gatekeeper whose pause state gates this module's mutations.
    EmergencyGatekeeper public immutable gatekeeper;

    /// @notice Synthetic escrowed value, keyed by scope, account, and claim id.
    mapping(bytes32 => mapping(address => mapping(uint256 => uint256))) public escrow;
    /// @notice Number of successful mutations per scope (activity telemetry for drills).
    mapping(bytes32 => uint256) public mutationCount;

    /// @notice Emitted when a gated mutation is accepted.
    event EscrowLocked(bytes32 indexed scope, address indexed account, uint256 indexed claimId, uint256 amount);
    /// @notice Emitted when a gated release is accepted.
    event EscrowReleased(bytes32 indexed scope, address indexed account, uint256 indexed claimId, uint256 amount);

    /// @param gatekeeper_ The gatekeeper that owns the pause state for this module.
    constructor(address gatekeeper_) {
        if (gatekeeper_ == address(0)) revert V2Errors.ZeroAddress();
        gatekeeper = EmergencyGatekeeper(gatekeeper_);
    }

    /// @notice Mutates state on the given scope; reverts while the scope is gated shut.
    /// @param scope Scope identifier the mutation is filed under.
    /// @param account Beneficiary account.
    /// @param claimId Claim the escrow belongs to.
    /// @param amount Escrow amount (synthetic units).
    function lock(bytes32 scope, address account, uint256 claimId, uint256 amount) external {
        if (amount == 0) revert V2Errors.ZeroAmount();
        gatekeeper.requireNotPaused(scope);
        escrow[scope][account][claimId] += amount;
        mutationCount[scope] += 1;
        emit EscrowLocked(scope, account, claimId, amount);
    }

    /// @notice Releases escrow on the given scope; reverts while the scope is gated shut.
    /// @param scope Scope identifier the release is filed under.
    /// @param account Beneficiary account.
    /// @param claimId Claim the escrow belongs to.
    /// @param amount Released amount (synthetic units).
    function release(bytes32 scope, address account, uint256 claimId, uint256 amount) external {
        if (amount == 0) revert V2Errors.ZeroAmount();
        gatekeeper.requireNotPaused(scope);
        uint256 held = escrow[scope][account][claimId];
        if (held < amount) revert V2Errors.InsufficientClaimable(account, amount, held);
        escrow[scope][account][claimId] = held - amount;
        mutationCount[scope] += 1;
        emit EscrowReleased(scope, account, claimId, amount);
    }
}
