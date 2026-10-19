// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HostilePauseAuthority
/// @notice Adversarial stand-in for the protocol-level `EmergencyController`, used by
///         the Emergency Pause & Recovery Exercise Suite (V2-SC-067) to prove that the
///         V2 `EmergencyGatekeeper` fails closed when the wired dependency misbehaves.
/// @dev Purely a test fixture: not deployed to production.
contract HostilePauseAuthority {
    /// @notice Dependency failure modes exercised by the drills.
    enum FailureMode {
        None,
        /// @notice Every call reverts (dependency destroyed / selfdestructed).
        AlwaysRevert,
        /// @notice Calls succeed but return fewer than 32 bytes (malformed returndata).
        ShortReturndata,
        /// @notice Calls succeed but return garbage in the expected slot.
        CorruptReturndata
    }

    /// @notice Current failure mode injected into the dependency.
    FailureMode public mode;
    /// @notice Pause level reported when `mode == None`.
    uint8 public reportedLevel;

    /// @param initialLevel The pause level to report in healthy mode.
    constructor(uint8 initialLevel) {
        reportedLevel = initialLevel;
    }

    /// @notice Injects a failure mode (drill control, intentionally unrestricted).
    function setMode(FailureMode newMode) external {
        mode = newMode;
    }

    /// @notice Sets the level reported in healthy mode (drill control).
    function setReportedLevel(uint8 newLevel) external {
        reportedLevel = newLevel;
    }

    /// @notice Emulates `EmergencyController.getPauseLevel()`.
    /// @dev Reverts or returns malformed data according to the injected failure mode.
    function getPauseLevel() external view returns (uint8) {
        FailureMode m = mode;
        if (m == FailureMode.AlwaysRevert) {
            revert("dependency destroyed");
        }
        if (m == FailureMode.ShortReturndata) {
            assembly {
                mstore(0x00, 0x01)
                return(0x00, 0x02)
            }
        }
        if (m == FailureMode.CorruptReturndata) {
            assembly {
                mstore(0x00, sub(0, 1))
                return(0x00, 0x20)
            }
        }
        return reportedLevel;
    }
}
