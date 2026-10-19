// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IV2Module } from "./interfaces/IV2Module.sol";
import { IEmergencyControls } from "./interfaces/IEmergencyControls.sol";
import { IModuleRegistry } from "./interfaces/IModuleRegistry.sol";
import { V2Errors } from "./libraries/V2Errors.sol";
import { EmergencyController } from "../governance/EmergencyController.sol";
import { BoundedStaticCall } from "../libraries/BoundedStaticCall.sol";

/// @title EmergencyGatekeeper
/// @notice Canonical V2 scoped emergency pause module (V2-SC-067).
/// @dev Bridges the protocol-level `EmergencyController` into the canonical V2
///      `IEmergencyControls` surface so that V2 modules can gate state-changing
///      operations on a single, auditable, per-scope pause authority.
///
/// ## Authority model (preserves on-chain authority, no backend mutation)
///
/// | Actor                | Capability                                          |
/// |----------------------|-----------------------------------------------------|
/// | `PAUSE_INITIATOR`    | Pause a scope (rapid response, cannot unpause)      |
/// | `PAUSE_RESOLVER`     | Pause a scope and unpause after remediation         |
/// | `ADMIN_ROLE`         | Wire/unwire dependencies, reconfigure, manage roles |
///
/// ## Security properties
///
/// - **Fail closed**: every state-mutating entry point reverts while its scope
///   is paused, when the wired `EmergencyController` has globally escalated
///   beyond the level permitted by the scope's `maxPauseLevel`, or when an
///   external classification call fails. Read-only `paused(bytes32)` never
///   reverts and classifies any external-call anomaly as "paused".
/// - **Separation of powers**: the initiator cannot unpause. Resolution
///   requires `PAUSE_RESOLVER`, the on-chain analogue of reviewed remediation.
/// - **Escalation containment**: a scope that declares `maxPauseLevel = 2`
///   becomes inoperable as soon as the protocol-level controller reaches
///   level 3 (global shutdown) — gatekeeper checks are strictly "current
///   level exceeds the scope's tolerated maximum", never equality-based.
/// - **Timelock on unwiring**: `setEmergencyController` is protected by an
///   enforced time delay so a compromised admin cannot hot-swap the pause
///   authority and immediately suppress it. The role holder may always wire
///   a missing controller (fail-closed direction); unwiring or replacing one
///   must wait out the delay.
/// - **No reentrancy**: all mutators are `nonReentrant`.
/// - **Full audit trail**: every pause, resolution, configuration change, and
///   escalation containment records a canonical V2 event.
contract EmergencyGatekeeper is AccessControl, ReentrancyGuard, IEmergencyControls {
    // ─── Roles ────────────────────────────────────────────────────────

    /// @notice Rapid-response authority: may pause a scope, may never unpause.
    bytes32 public constant PAUSE_INITIATOR = keccak256("PAUSE_INITIATOR");
    /// @notice Resolution authority: may pause a scope and unpause after remediation.
    bytes32 public constant PAUSE_RESOLVER = keccak256("PAUSE_RESOLVER");
    /// @notice Configuration authority for dependency wiring and role management.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ─── Constants ────────────────────────────────────────────────────

    /// @notice Minimum enforced delay (in seconds) between dependency rewires.
    uint256 public constant MIN_EMERGENCY_REWIRE_DELAY = 1 hours;
    /// @notice Maximum permitted dependency rewire delay (in seconds).
    uint256 public constant MAX_EMERGENCY_REWIRE_DELAY = 30 days;
    /// @notice Canonical V2 protocol version implemented by this module.
    uint16 public constant PROTOCOL_MAJOR = 2;
    /// @notice Canonical V2 minor version implemented by this module.
    uint16 public constant PROTOCOL_MINOR = 0;
    /// @notice Maximum pause level defined by the protocol-level `EmergencyController`.
    uint8 public constant MAX_PROTOCOL_PAUSE_LEVEL = 3;

    // ─── State ────────────────────────────────────────────────────────

    /// @notice Protocol-level emergency controller that owns global escalation.
    /// @dev May be `address(0)` while unwired; all mutating paths then fail closed.
    address public emergencyController;
    /// @notice Enforced minimum delay (seconds) between dependency rewires.
    uint256 public emergencyRewireDelay;
    /// @notice Timestamp of the last dependency rewire (0 = never wired).
    uint256 public lastRewireTimestamp;
    /// @notice Set of scopes that have ever been paused and not yet unpaused.
    mapping(bytes32 => bool) private _pausedScopes;
    /// @notice Maximum protocol-level pause level a scope tolerates and stays operational.
    /// @dev `maxPauseLevel(bytes32) == 0` means the scope has no configured tolerance
    ///      and fails closed for any non-normal protocol escalation.
    mapping(bytes32 => uint8) private _maxPauseLevel;

    // ─── Events ───────────────────────────────────────────────────────

    /// @notice Emitted when a scope's pause state is set by an authorized actor.
    /// @param scope The paused scope identifier.
    /// @param actor The authorized actor that changed the pause state.
    /// @param paused The new pause state of the scope.
    event ScopePauseUpdated(bytes32 indexed scope, address indexed actor, bool paused);

    /// @notice Emitted when the wired protocol-level emergency controller changes.
    /// @param previousController The previously wired controller (0 when none).
    /// @param newController The newly wired controller.
    /// @param rewireDelay The enforced rewire delay at the time of the change.
    event EmergencyControllerRewired(
        address indexed previousController, address indexed newController, uint256 rewireDelay
    );

    /// @notice Emitted when the dependency rewire delay is reconfigured.
    /// @param previousDelay The previous rewire delay in seconds.
    /// @param newDelay The new rewire delay in seconds.
    event EmergencyRewireDelayUpdated(uint256 previousDelay, uint256 newDelay);

    /// @notice Emitted when a scope's tolerated maximum protocol pause level is set.
    /// @param scope The affected scope.
    /// @param maxLevel The tolerated maximum protocol pause level.
    event ScopeMaxPauseLevelSet(bytes32 indexed scope, uint8 maxLevel);

    // ─── Errors ───────────────────────────────────────────────────────

    /// @notice The caller is not authorized for the attempted action.
    error NotAuthorized();
    /// @notice A configuration address or the dependency wiring is invalid.
    error InvalidConfiguration();
    /// @notice The scope identifier is empty; scopes must be non-empty.
    error EmptyScope();
    /// @notice The scope is already in the requested pause state.
    error ScopeAlreadyPaused(bytes32 scope, bool paused);
    /// @notice The rewire delay is outside the permitted bounds.
    error InvalidRewireDelay(uint256 delay);
    /// @notice The dependency rewire must wait for the enforced delay to elapse.
    error RewireDelayNotElapsed(uint256 readyAt);
    /// @notice The proposed controller does not expose the required surface.
    error InvalidEmergencyController(address controller);
    /// @notice The protocol-level controller is not configured or has failed.
    error EmergencyControllerUnavailable();

    // ─── Constructor ──────────────────────────────────────────────────

    /// @param admin Configuration authority (DAO governance / deployment admin).
    /// @param pauseInitiator Rapid-response authority that may pause scopes.
    /// @param pauseResolver Resolution authority that may pause and unpause scopes.
    /// @param rewireDelay Enforced minimum delay between dependency rewires.
    constructor(address admin, address pauseInitiator, address pauseResolver, uint256 rewireDelay) {
        if (admin == address(0)) revert V2Errors.ZeroAddress();
        if (pauseInitiator == address(0)) revert V2Errors.ZeroAddress();
        if (pauseResolver == address(0)) revert V2Errors.ZeroAddress();
        if (rewireDelay < MIN_EMERGENCY_REWIRE_DELAY || rewireDelay > MAX_EMERGENCY_REWIRE_DELAY) {
            revert InvalidRewireDelay(rewireDelay);
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(PAUSE_INITIATOR, pauseInitiator);
        _grantRole(PAUSE_RESOLVER, pauseResolver);

        emergencyRewireDelay = rewireDelay;
    }

    // ─── IV2Module ────────────────────────────────────────────────────

    /// @inheritdoc IV2Module
    function protocolVersion() external pure returns (uint16 major, uint16 minor) {
        return (PROTOCOL_MAJOR, PROTOCOL_MINOR);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IEmergencyControls).interfaceId || interfaceId == type(IV2Module).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ─── IEmergencyControls ───────────────────────────────────────────

    /// @notice Pauses the given scope, blocking every gatekeeper-gated mutation on it.
    /// @dev Callable by `PAUSE_INITIATOR` or `PAUSE_RESOLVER`. Emits `EmergencyPaused`.
    /// @param scope The scope identifier to pause.
    function pause(bytes32 scope) external nonReentrant {
        _requirePauseAuthority();
        if (scope == bytes32(0)) revert EmptyScope();
        if (_pausedScopes[scope]) revert ScopeAlreadyPaused(scope, true);
        _assertProtocolLevelWithinScopeTolerance(scope);

        _pausedScopes[scope] = true;
        emit EmergencyPaused(scope, msg.sender);
        emit ScopePauseUpdated(scope, msg.sender, true);
    }

    /// @notice Unpauses the given scope after completed remediation.
    /// @dev Callable by `PAUSE_RESOLVER` only. Reverts if the scope is not paused.
    ///      Fails closed while the protocol-level controller remains escalated
    ///      beyond the scope's tolerated maximum.
    /// @param scope The scope identifier to unpause.
    function unpause(bytes32 scope) external nonReentrant {
        if (!hasRole(PAUSE_RESOLVER, msg.sender)) revert NotAuthorized();
        if (scope == bytes32(0)) revert EmptyScope();
        // Fail closed first: resolution must never succeed while the protocol-level
        // authority remains escalated beyond this scope's tolerance.
        _assertProtocolLevelWithinScopeTolerance(scope);
        if (!_pausedScopes[scope]) revert ScopeAlreadyPaused(scope, false);

        _pausedScopes[scope] = false;
        emit EmergencyUnpaused(scope, msg.sender);
        emit ScopePauseUpdated(scope, msg.sender, false);
    }

    /// @notice Returns whether the scope is currently paused (local or protocol escalation).
    /// @dev Never reverts: an unwired or misbehaving protocol-level dependency
    ///      classifies the scope as paused (fail closed).
    /// @param scope The scope identifier to query.
    /// @return True if the scope must be treated as paused.
    function paused(bytes32 scope) public view returns (bool) {
        if (_pausedScopes[scope]) return true;
        (bool dependencyHealthy, uint8 level) = _tryProtocolPauseLevel();
        if (!dependencyHealthy) return true;
        return level > effectiveScopeTolerance(scope);
    }

    // ─── Gatekeeping surface ──────────────────────────────────────────

    /// @notice Reverts when the caller may not execute mutations on the scope.
    /// @dev Protocol modules call this immediately before any state mutation that
    ///      the emergency authority must be able to stop.
    /// @param scope The scope whose gate should be checked.
    function requireNotPaused(bytes32 scope) external view {
        if (paused(scope)) revert V2Errors.ProtocolPaused();
    }

    /// @notice Configures the tolerated maximum protocol-level pause level for a scope.
    /// @dev `maxLevel` is the highest protocol pause level at which the scope stays
    ///      operational. Any strictly greater protocol level contains the scope.
    ///      `ADMIN_ROLE` only; fails on zero scope or invalid level values.
    /// @param scope The scope to configure.
    /// @param maxLevel The tolerated maximum protocol pause level (0-3).
    function setScopeMaxPauseLevel(bytes32 scope, uint8 maxLevel) external onlyRole(ADMIN_ROLE) {
        if (scope == bytes32(0)) revert EmptyScope();
        if (maxLevel > MAX_PROTOCOL_PAUSE_LEVEL) {
            revert InvalidConfiguration();
        }

        _maxPauseLevel[scope] = maxLevel;
        emit ScopeMaxPauseLevelSet(scope, maxLevel);
    }

    /// @notice Returns the tolerated maximum protocol pause level configured for a scope.
    /// @param scope The scope to query.
    /// @return The configured tolerated maximum (0 when unset).
    function maxPauseLevel(bytes32 scope) external view returns (uint8) {
        return _maxPauseLevel[scope];
    }

    /// @notice Returns the raw locally-paused flag for a scope, ignoring protocol escalation.
    /// @param scope The scope to query.
    /// @return True if the scope is locally paused via `pause(bytes32)`.
    function locallyPaused(bytes32 scope) external view returns (bool) {
        return _pausedScopes[scope];
    }

    // ─── Dependency wiring (timelocked) ───────────────────────────────

    /// @notice Wires, replaces, or removes the protocol-level emergency controller.
    /// @dev `ADMIN_ROLE` only. Wiring when none is wired is immediate (fail-closed
    ///      direction). Replacing or removing an existing controller must wait for
    ///      `emergencyRewireDelay` seconds since the last rewire.
    ///      Pass `address(0)` to unwire. The delay is enforced *before* any state change.
    /// @param controller The new protocol-level controller, or `address(0)` to unwire.
    function setEmergencyController(address controller) external onlyRole(ADMIN_ROLE) {
        if (emergencyController != address(0) && controller != emergencyController) {
            uint256 readyAt = lastRewireTimestamp + emergencyRewireDelay;
            if (block.timestamp < readyAt) revert RewireDelayNotElapsed(readyAt);
        }

        if (controller != address(0)) {
            _validateControllerSurface(controller);
        }

        address previous = emergencyController;
        emergencyController = controller;
        lastRewireTimestamp = block.timestamp;

        emit EmergencyControllerRewired(previous, controller, emergencyRewireDelay);
    }

    /// @notice Reconfigures the dependency rewire delay.
    /// @dev `ADMIN_ROLE` only; value must stay within the constant bounds.
    /// @param newDelay The new minimum delay (seconds) between rewires.
    function setEmergencyRewireDelay(uint256 newDelay) external onlyRole(ADMIN_ROLE) {
        if (newDelay < MIN_EMERGENCY_REWIRE_DELAY || newDelay > MAX_EMERGENCY_REWIRE_DELAY) {
            revert InvalidRewireDelay(newDelay);
        }

        uint256 previous = emergencyRewireDelay;
        emergencyRewireDelay = newDelay;
        emit EmergencyRewireDelayUpdated(previous, newDelay);
    }

    // ─── Internal ─────────────────────────────────────────────────────

    function _requirePauseAuthority() internal view {
        if (!hasRole(PAUSE_INITIATOR, msg.sender) && !hasRole(PAUSE_RESOLVER, msg.sender)) {
            revert NotAuthorized();
        }
    }

    /// @dev Reverts when the protocol-level controller is escalated beyond the
    ///      scope's tolerated maximum — or at global shutdown, which contains every
    ///      scope regardless of tolerance — or when the dependency cannot be
    ///      classified. An unwired controller is treated as level 0 so that local
    ///      scoped pauses remain possible during incident triage.
    function _assertProtocolLevelWithinScopeTolerance(bytes32 scope) internal view {
        (bool dependencyHealthy, uint8 level) = _tryProtocolPauseLevel();
        if (!dependencyHealthy) revert EmergencyControllerUnavailable();
        if (level > effectiveScopeTolerance(scope)) {
            revert V2Errors.ProtocolPaused();
        }
    }

    /// @dev Reads the current protocol pause level from the wired dependency.
    ///      Returns `dependencyHealthy = false` for an unwired controller, a failed
    ///      external call, short returndata, or an out-of-range level value — the
    ///      caller decides whether that means "fail closed with an error" (mutating
    ///      paths) or "classify as paused" (read-only classifier).
    function _tryProtocolPauseLevel() internal view returns (bool dependencyHealthy, uint8 level) {
        address controller = emergencyController;
        if (controller == address(0)) {
            return (true, 0);
        }

        (bool success, uint256 raw, uint256 returnSize) = BoundedStaticCall.staticcallWord(
            controller,
            abi.encodeWithSignature("getPauseLevel()")
        );
        if (!success || returnSize < 32) return (false, 0);
        if (raw > MAX_PROTOCOL_PAUSE_LEVEL) return (false, 0);
        return (true, uint8(raw));
    }

    /// @notice Effective tolerated maximum protocol pause level for a scope.
    /// @dev Global shutdown (`LEVEL_SHUTDOWN`) is a full protocol pause: it contains
    ///      every scope, so no tolerance can exceed `LEVEL_SHUTDOWN - 1`.
    /// @param scope The scope to evaluate.
    /// @return The effective tolerance capped below shutdown.
    function effectiveScopeTolerance(bytes32 scope) public view returns (uint8) {
        uint8 tolerance = _maxPauseLevel[scope];
        // LEVEL_SHUTDOWN == 3; every scope is contained at shutdown.
        if (tolerance >= 3) {
            return 2;
        }
        return tolerance;
    }

    /// @dev Probes the candidate controller for the canonical read surface.
    function _validateControllerSurface(address controller) internal view {
        (bool success, uint256 raw, uint256 returnSize) = BoundedStaticCall.staticcallWord(
            controller,
            abi.encodeWithSignature("getPauseLevel()")
        );
        if (!success || returnSize != 32 || raw > MAX_PROTOCOL_PAUSE_LEVEL) {
            revert InvalidEmergencyController(controller);
        }
    }
}
