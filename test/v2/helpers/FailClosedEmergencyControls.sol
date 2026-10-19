// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IEmergencyControls} from "../../../contracts/v2/interfaces/IEmergencyControls.sol";
import {IV2Module} from "../../../contracts/v2/interfaces/IV2Module.sol";
import {V2Errors} from "../../../contracts/v2/libraries/V2Errors.sol";
import {V2Scopes} from "../../../contracts/v2/libraries/V2Scopes.sol";

/// @title FailClosedEmergencyControls
/// @notice Scoped emergency control plane fixture for TruthBounty V2 tests.
contract FailClosedEmergencyControls is ERC165, AccessControl, IEmergencyControls {
    event ScopePauseRecorded(
        bytes32 indexed scope,
        address indexed actor,
        uint256 indexed sequence,
        uint256 unlockReadyAt,
        string reason
    );

    event ScopeUnpauseRecorded(
        bytes32 indexed scope,
        address indexed actor,
        uint256 indexed sequence,
        bytes32 proposalRef,
        uint256 pausedDuration
    );

    event RecoveryConditionDeclared(bytes32 indexed scope, bytes32 indexed conditionId, string description);

    event RecoveryConditionSatisfied(
        bytes32 indexed scope,
        bytes32 indexed conditionId,
        address indexed actor,
        string evidence
    );

    event RecoveryConditionWaived(
        bytes32 indexed scope,
        bytes32 indexed conditionId,
        address indexed actor,
        string justification
    );

    event RecoveryDelayUpdated(uint256 previousDelay, uint256 newDelay);

    event ScopeRegistered(bytes32 indexed scope, string description);
    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    /// @notice May pause any scope. Cannot reopen.
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /// @notice May attest that a documented recovery condition has been met.
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");

    /// @notice Governance: may reopen, document/waive recovery conditions, and manage the scope set.
    bytes32 public constant SCOPE_ADMIN_ROLE = keccak256("SCOPE_ADMIN_ROLE");

    // -------------------------------------------------------------------------
    // Timelock bounds
    // -------------------------------------------------------------------------

    /// @notice Minimum recovery timelock applied to a newly paused scope.
    uint256 public constant MIN_RECOVERY_DELAY = 1 hours;

    /// @notice Maximum recovery timelock applied to a newly paused scope.
    uint256 public constant MAX_RECOVERY_DELAY = 30 days;

    /// @notice Recovery timelock applied to scopes paused from now on.
    uint256 public recoveryDelay;

    /// @notice Monotonic counter stamped on every pause and reopening for indexer ordering.
    uint256 public emergencySequence;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Documented precondition that must be met before a paused scope may reopen.
    struct RecoveryCondition {
        bool declared;
        bool satisfied;
        bool waived;
        string description;
        address decidedBy;
        uint256 decidedAt;
    }

    /// @notice Pause and recovery posture of a single scope.
    struct ScopeState {
        bool known;
        bool paused;
        uint256 pausedAt;
        uint256 unlockReadyAt;
        uint256 lastUnpausedAt;
        bytes32[] conditionIds;
        mapping(bytes32 => RecoveryCondition) conditions;
    }

    mapping(bytes32 => ScopeState) private _scopes;
    bytes32[] private _knownScopes;

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    /// @param admin Address receiving every emergency role. MUST be handed to governance after
    ///        deployment; it exists so a fresh deployment is operable.
    /// @param initialRecoveryDelay Recovery timelock for newly paused scopes, within bounds.
    constructor(address admin, uint256 initialRecoveryDelay) {
        if (admin == address(0)) revert V2Errors.ZeroAddress();
        _assertDelayInBounds(initialRecoveryDelay);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
        _grantRole(RECOVERY_ROLE, admin);
        _grantRole(SCOPE_ADMIN_ROLE, admin);

        recoveryDelay = initialRecoveryDelay;

        bytes32[] memory scopes = V2Scopes.canonicalScopes();
        for (uint256 i = 0; i < scopes.length; ++i) {
            _scopes[scopes[i]].known = true;
            _knownScopes.push(scopes[i]);
        }
    }

    // -------------------------------------------------------------------------
    // Module surface
    // -------------------------------------------------------------------------

    /// @inheritdoc IV2Module
    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IEmergencyControls).interfaceId || interfaceId == type(IV2Module).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // -------------------------------------------------------------------------
    // Enforcement surface
    // -------------------------------------------------------------------------

    /// @dev Emergency control method
    function requireOperationAllowed(bytes32 scope) external view {
        _requireKnownScope(scope);
        if (_isPaused(scope)) revert V2Errors.ScopePaused(scope);
    }

    /// @dev Emergency control method
    function isOperationAllowed(bytes32 scope) external view returns (bool) {
        // Fail closed: an unknown scope is never reported as allowed.
        if (!_scopes[scope].known) return false;
        return !_isPaused(scope);
    }

    /// @dev Emergency control method
    function paused(bytes32 scope) external view override returns (bool) {
        // Fail closed: querying an unknown scope is an explicit error, never `false`.
        _requireKnownScope(scope);
        return _isPaused(scope);
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    /// @dev Emergency control method
    function pause(bytes32 scope) external {
        _pause(scope, "", msg.sender);
    }

    /// @dev Emergency control method
    function pauseWithReason(bytes32 scope, string calldata reason) external {
        _pause(scope, reason, msg.sender);
    }

    function _pause(bytes32 scope, string memory reason, address actor) private {
        _requireKnownScope(scope);
        if (!hasRole(EMERGENCY_ROLE, actor) && !hasRole(SCOPE_ADMIN_ROLE, actor)) {
            revert V2Errors.UnauthorizedEmergencyCaller(actor);
        }

        ScopeState storage state = _scopes[scope];
        if (state.paused) revert V2Errors.ScopeAlreadyPaused(scope);

        // A fresh pause must be documented and satisfied from scratch.
        _clearRecoveryConditions(scope);

        state.paused = true;
        state.pausedAt = block.timestamp;
        state.unlockReadyAt = block.timestamp + recoveryDelay;

        uint256 sequence = ++emergencySequence;

        emit EmergencyPaused(scope, actor);
        emit ScopePauseRecorded(scope, actor, sequence, state.unlockReadyAt, reason);
    }

    // -------------------------------------------------------------------------
    // Recovery
    // -------------------------------------------------------------------------

    /// @dev Emergency control method
    function declareRecoveryCondition(bytes32 scope, bytes32 conditionId, string calldata description)
        external
    {
        _requireKnownScope(scope);
        _requireRole(SCOPE_ADMIN_ROLE, msg.sender);
        if (conditionId == bytes32(0)) revert V2Errors.InvalidArgument("condition id required");
        if (bytes(description).length == 0) revert V2Errors.InvalidArgument("condition description required");

        ScopeState storage state = _scopes[scope];
        if (!state.paused) revert V2Errors.ScopeNotPaused(scope);
        if (state.conditions[conditionId].declared) {
            revert V2Errors.RecoveryConditionAlreadyDeclared(scope, conditionId);
        }

        state.conditions[conditionId] = RecoveryCondition({
            declared: true,
            satisfied: false,
            waived: false,
            description: description,
            decidedBy: address(0),
            decidedAt: 0
        });
        state.conditionIds.push(conditionId);

        emit RecoveryConditionDeclared(scope, conditionId, description);
    }

    /// @dev Emergency control method
    function satisfyRecoveryCondition(bytes32 scope, bytes32 conditionId, string calldata evidence) external {
        _requireKnownScope(scope);
        _requireRole(RECOVERY_ROLE, msg.sender);

        ScopeState storage state = _scopes[scope];
        if (!state.paused) revert V2Errors.ScopeNotPaused(scope);

        RecoveryCondition storage condition = state.conditions[conditionId];
        if (!condition.declared) revert V2Errors.RecoveryConditionNotFound(scope, conditionId);
        if (condition.satisfied || condition.waived) {
            revert V2Errors.RecoveryConditionAlreadyResolved(scope, conditionId);
        }

        condition.satisfied = true;
        condition.decidedBy = msg.sender;
        condition.decidedAt = block.timestamp;

        emit RecoveryConditionSatisfied(scope, conditionId, msg.sender, evidence);
    }

    /// @dev Emergency control method
    function waiveRecoveryCondition(bytes32 scope, bytes32 conditionId, string calldata justification)
        external
    {
        _requireKnownScope(scope);
        _requireRole(SCOPE_ADMIN_ROLE, msg.sender);
        if (bytes(justification).length == 0) revert V2Errors.InvalidArgument("justification required");

        ScopeState storage state = _scopes[scope];
        if (!state.paused) revert V2Errors.ScopeNotPaused(scope);

        RecoveryCondition storage condition = state.conditions[conditionId];
        if (!condition.declared) revert V2Errors.RecoveryConditionNotFound(scope, conditionId);
        if (condition.satisfied || condition.waived) {
            revert V2Errors.RecoveryConditionAlreadyResolved(scope, conditionId);
        }

        // A waiver is an auditable governance decision, not a silent bypass.
        condition.waived = true;
        condition.decidedBy = msg.sender;
        condition.decidedAt = block.timestamp;

        emit RecoveryConditionWaived(scope, conditionId, msg.sender, justification);
    }

    // -------------------------------------------------------------------------
    // Reopening
    // -------------------------------------------------------------------------

    /// @dev Emergency control method
    function unpause(bytes32 scope) external {
        _unpause(scope, bytes32(0), msg.sender);
    }

    /// @dev Emergency control method
    function unpauseWithReference(bytes32 scope, bytes32 proposalRef) external {
        _unpause(scope, proposalRef, msg.sender);
    }

    function _unpause(bytes32 scope, bytes32 proposalRef, address actor) private {
        _requireKnownScope(scope);
        _requireRole(SCOPE_ADMIN_ROLE, actor);

        ScopeState storage state = _scopes[scope];
        if (!state.paused) revert V2Errors.ScopeNotPaused(scope);

        // Prerequisite 1 — the recovery timelock captured at pause time has elapsed.
        if (block.timestamp < state.unlockReadyAt) {
            revert V2Errors.RecoveryTimelockActive(scope, state.unlockReadyAt);
        }

        // Prerequisite 2 — recovery was documented at all.
        uint256 conditionCount = state.conditionIds.length;
        if (conditionCount == 0) revert V2Errors.NoRecoveryConditionsDeclared(scope);

        // Prerequisite 3 — every documented condition is satisfied or explicitly waived.
        for (uint256 i = 0; i < conditionCount; ++i) {
            bytes32 conditionId = state.conditionIds[i];
            RecoveryCondition storage condition = state.conditions[conditionId];
            if (!condition.satisfied && !condition.waived) {
                revert V2Errors.RecoveryPrerequisitesUnmet(scope, conditionId);
            }
        }

        uint256 pausedDuration = block.timestamp - state.pausedAt;

        state.paused = false;
        state.pausedAt = 0;
        state.unlockReadyAt = 0;
        state.lastUnpausedAt = block.timestamp;
        _clearRecoveryConditions(scope);

        uint256 sequence = ++emergencySequence;

        emit EmergencyUnpaused(scope, actor);
        emit ScopeUnpauseRecorded(scope, actor, sequence, proposalRef, pausedDuration);
    }

    // -------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------

    /// @dev Emergency control method
    function registerScope(bytes32 scope, string calldata description) external {
        _requireRole(SCOPE_ADMIN_ROLE, msg.sender);
        if (scope == bytes32(0)) revert V2Errors.InvalidArgument("scope required");
        if (bytes(description).length == 0) revert V2Errors.InvalidArgument("scope description required");
        if (_scopes[scope].known) revert V2Errors.ScopeAlreadyRegistered(scope);

        _scopes[scope].known = true;
        _knownScopes.push(scope);

        emit ScopeRegistered(scope, description);
    }

    /// @dev Emergency control method
    function setRecoveryDelay(uint256 newDelay) external {
        _requireRole(SCOPE_ADMIN_ROLE, msg.sender);
        _assertDelayInBounds(newDelay);

        uint256 previous = recoveryDelay;
        recoveryDelay = newDelay;

        emit RecoveryDelayUpdated(previous, newDelay);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @dev Emergency control method
    function isKnownScope(bytes32 scope) external view returns (bool) {
        return _scopes[scope].known;
    }

    /// @dev Emergency control method
    function isScopeCanonical(bytes32 scope) external pure returns (bool) {
        return V2Scopes.isCanonical(scope);
    }

    /// @dev Emergency control method
    function recoveryReadyAt(bytes32 scope) external view returns (uint256) {
        _requireKnownScope(scope);
        return _scopes[scope].unlockReadyAt;
    }

    /// @dev Emergency control method
    function scopeUnpausedAt(bytes32 scope) external view returns (uint256) {
        _requireKnownScope(scope);
        return _scopes[scope].lastUnpausedAt;
    }

    /// @dev Emergency control method
    function recoveryStatus(bytes32 scope)
        external
        view
        returns (bool isPaused, uint256 readyAt, uint256 declaredConditions, uint256 outstandingConditions)
    {
        _requireKnownScope(scope);
        ScopeState storage state = _scopes[scope];

        isPaused = _isPaused(scope);
        readyAt = state.unlockReadyAt;
        declaredConditions = state.conditionIds.length;

        uint256 outstanding;
        for (uint256 i = 0; i < declaredConditions; ++i) {
            RecoveryCondition storage condition = state.conditions[state.conditionIds[i]];
            if (!condition.satisfied && !condition.waived) {
                ++outstanding;
            }
        }
        outstandingConditions = outstanding;
    }

    /// @dev Emergency control method
    function scopeCount() external view returns (uint256) {
        return _knownScopes.length;
    }

    /// @dev Emergency control method
    function scopeAt(uint256 index) external view returns (bytes32) {
        return _knownScopes[index];
    }

    /// @dev Emergency control method
    function recoveryConditionCount(bytes32 scope) external view returns (uint256) {
        _requireKnownScope(scope);
        return _scopes[scope].conditionIds.length;
    }

    /// @dev Emergency control method
    function recoveryConditionAt(bytes32 scope, uint256 index) external view returns (bytes32) {
        _requireKnownScope(scope);
        return _scopes[scope].conditionIds[index];
    }

    /// @dev Emergency control method
    function recoveryCondition(bytes32 scope, bytes32 conditionId)
        external
        view
        returns (
            bool declared,
            bool satisfied,
            bool waived,
            string memory description,
            address decidedBy,
            uint256 decidedAt
        )
    {
        _requireKnownScope(scope);
        RecoveryCondition storage condition = _scopes[scope].conditions[conditionId];
        return (
            condition.declared,
            condition.satisfied,
            condition.waived,
            condition.description,
            condition.decidedBy,
            condition.decidedAt
        );
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Reverts for any scope outside the known-scope set. The single fail-closed gate.
    function _requireKnownScope(bytes32 scope) private view {
        if (!_scopes[scope].known) revert V2Errors.UnknownOperation(scope);
    }

    function _requireRole(bytes32 role, address actor) private view {
        if (!hasRole(role, actor)) revert V2Errors.UnauthorizedEmergencyCaller(actor);
    }

    /// @dev A scope is paused when it is paused directly, or when the protocol-wide kill switch is
    ///      engaged. `global` and `governance_recovery` are exempt from the cascade: the kill
    ///      switch must not be able to suppress the recovery path that lifts it.
    function _isPaused(bytes32 scope) private view returns (bool) {
        if (_scopes[scope].paused) return true;
        if (scope == V2Scopes.GLOBAL || scope == V2Scopes.GOVERNANCE_RECOVERY) return false;
        return _scopes[V2Scopes.GLOBAL].paused;
    }

    function _clearRecoveryConditions(bytes32 scope) private {
        ScopeState storage state = _scopes[scope];
        bytes32[] storage conditionIds = state.conditionIds;
        uint256 length = conditionIds.length;
        for (uint256 i = 0; i < length; ++i) {
            delete state.conditions[conditionIds[i]];
        }
        delete state.conditionIds;
    }

    function _assertDelayInBounds(uint256 delay) private pure {
        if (delay < MIN_RECOVERY_DELAY || delay > MAX_RECOVERY_DELAY) {
            revert V2Errors.InvalidArgument("recovery delay out of bounds");
        }
    }
}
