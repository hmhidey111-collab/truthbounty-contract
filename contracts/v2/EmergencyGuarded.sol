// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEmergencyControls} from "./interfaces/IEmergencyControls.sol";
import {V2Errors} from "./libraries/V2Errors.sol";

/// @title EmergencyGuarded
/// @notice Fail-closed emergency-control mixin for canonical V2 modules.
/// @dev A module inherits this contract, calls `_setEmergencyControls` once during wiring, and
///      applies `whenOperationAllowed(<scope>)` to every state-mutating entry point, using a scope
///      constant from `V2Scopes`.
///
///      The guard is deliberately fail closed in two ways:
///
///      - If no control plane is configured, every guarded mutation reverts with
///        `EmergencyControlsNotConfigured`. An unwired module is frozen, never open.
///      - If the configured control plane cannot be reached, or the scope is unknown to it, the
///        call reverts. `EmergencyControls.requireOperationAllowed` rejects unknown scopes, so a
///        typo in a scope constant freezes the module rather than bypassing the control plane.
///
///      The configuration setter is intentionally *not* guarded. Governance must always be able to
///      repair a broken or superseded control-plane reference during a pause; guarding the setter
///      would make a misconfigured pause unrecoverable.
abstract contract EmergencyGuarded {
    /// @notice The canonical emergency control plane consulted by every guarded mutation.
    IEmergencyControls public emergencyControls;

    /// @notice Emitted when a module is wired to (or rewired from) a control plane.
    event EmergencyControlsConfigured(address indexed previousControls, address indexed newControls);

    /// @notice Reverts unless `scope` is canonical and currently operable.
    modifier whenOperationAllowed(bytes32 scope) {
        _requireOperationAllowed(scope);
        _;
    }

    /// @dev Wires the module to a control plane. Implementations expose this through an
    ///      administrator-gated external setter with their own role model.
    function _setEmergencyControls(address controls) internal {
        if (controls == address(0)) revert V2Errors.ZeroAddress();
        address previous = address(emergencyControls);
        emergencyControls = IEmergencyControls(controls);
        emit EmergencyControlsConfigured(previous, controls);
    }

    /// @dev Fail-closed guard. Reverts when the module is unwired, when the scope is unknown to the
    ///      control plane, or when the scope is paused.
    function _requireOperationAllowed(bytes32 scope) internal view {
        IEmergencyControls controls = emergencyControls;
        if (address(controls) == address(0)) revert V2Errors.EmergencyControlsNotConfigured();
        if (controls.paused(scope)) revert V2Errors.ScopePaused(scope);
    }
}
