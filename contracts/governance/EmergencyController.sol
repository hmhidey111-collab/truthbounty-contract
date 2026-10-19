// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EmergencyPauseOrdering} from "./libraries/EmergencyPauseOrdering.sol";

/**
 * @title EmergencyController
 * @notice Emergency Pause & Circuit Breaker Framework for TruthBounty Protocol
 * @dev Implements multi-level protocol pause with governance-controlled recovery.
 *
 * \## Pause Levels
 *
 * | Level | Name     | Effect |
 * |-------|----------|--------|
 * | 0     | Normal   | Full protocol operation |
 * | 1     | HighRisk | Pause new claim creation, staking, verification submission. Read-only + governance still active. |
 * | 2     | Financial| Pause reward distribution, treasury transfers, withdrawals. Read-only + governance still active. |
 * | 3     | Shutdown | Global emergency shutdown. Only governance recovery operations remain. |
 *
 * \## Roles
 *
 * | Role                 | Can Activate | Can Lift | Notes |
 * |----------------------|-------------|----------|-------|
 * | EMERGENCY_COUNCIL    | Yes (L1-L3) | No       | Rapid response — cannot unilaterally lift |
 * | DAO_GOVERNANCE       | Yes (L1-L2) | Yes      | Full governance control |
 * | TIMELOCK_CONTROLLER  | Yes (L1)    | No       | Narrow scope, time-delayed |
 *
 * \## Security Properties
 *
 * - Emergency Council can pause but CANNOT unpause (separation of powers)
 * - DAO Governance is required for recovery (no unilateral unpause)
 * - All emergency actions emit immutable audit events
 * - Protected functions query this contract's pause state
 * - Read operations remain available at all levels
 * - Operation allow/deny matrix: EmergencyPauseOrdering (V2-SC-117)
 */
contract EmergencyController is AccessControlEnumerable, ReentrancyGuard {
    // ─── Custom Errors ────────────────────────────────────────────────
    error NotAuthorizedForLevel(address caller, uint8 currentLevel);
    error InvalidPauseLevel(uint8 level);
    error AlreadyAtLevel(uint8 level);
    error CannotLiftBelowCurrent(uint8 current, uint8 attempted);
    error ProtocolNotPaused();
    error RecoveryNotComplete();
    error InvalidRecoveryStep(uint8 step);
    error ZeroAddress();
    error NoChangeRequested();
    error ReasonTooLong(uint256 actual, uint256 maximum);

    /// @notice Raised when a role admin change is requested with no effective change.
    error RoleAdminUnchanged(bytes32 role, bytes32 currentAdmin);

    /// @notice Raised when a role admin change would remove the last admin of DEFAULT_ADMIN_ROLE.
    error CannotRemoveLastAdmin();

    /// @notice Raised when an operation identifier is not part of the classified operation set.
    /// @dev Emergency checks fail closed: an unclassified operation is rejected, never allowed.
    error UnknownOperation(bytes32 operationType);

    /// @notice Raised by the enforcement variant when a known operation is blocked at the current level.
    error OperationBlocked(bytes32 operationType, uint8 pauseLevel);

    // ─── Constants ────────────────────────────────────────────────────

    /// @notice Normal operation — no restrictions
    uint8 public constant LEVEL_NORMAL = 0;
    /// @notice Pause high-risk operations (claims, staking, verification)
    uint8 public constant LEVEL_HIGH_RISK = 1;
    /// @notice Pause financial operations (rewards, treasury, withdrawals)
    uint8 public constant LEVEL_FINANCIAL = 2;
    /// @notice Global emergency shutdown
    uint8 public constant LEVEL_SHUTDOWN = 3;

    uint16 public constant EVENT_SCHEMA_VERSION = 1;
    uint8 public constant MAX_PAUSE_LEVEL = 3;
    /// @notice Maximum emergency reason length persisted on-chain.
    uint256 public constant MAX_REASON_BYTES = 256;

    // ─── Operation Tiers ──────────────────────────────────────────────

    /// @notice Operation is not classified; emergency checks reject it.
    uint8 internal constant TIER_UNKNOWN = 0;
    /// @notice Blocked from LEVEL_HIGH_RISK upward.
    uint8 internal constant TIER_HIGH_RISK = 1;
    /// @notice Blocked from LEVEL_FINANCIAL upward.
    uint8 internal constant TIER_FINANCIAL = 2;
    /// @notice Permitted at every level; reserved for governance recovery.
    uint8 internal constant TIER_GOVERNANCE = 3;

    // ─── Roles ────────────────────────────────────────────────────────

    /// @notice Can activate any pause level (rapid response)
    bytes32 public constant EMERGENCY_COUNCIL = keccak256("EMERGENCY_COUNCIL");
    /// @notice Can activate L1-L2 and lift any pause (full governance)
    bytes32 public constant DAO_GOVERNANCE = keccak256("DAO_GOVERNANCE");
    /// @notice Can activate L1 only with time delay (narrow scope)
    bytes32 public constant TIMELOCK_CONTROLLER = keccak256("TIMELOCK_CONTROLLER");
    /// @notice Can execute recovery steps after pause is lifted
    bytes32 public constant RECOVERY_EXECUTOR = keccak256("RECOVERY_EXECUTOR");

    // ─── State ────────────────────────────────────────────────────────

    /// @notice Current pause level (0 = normal)
    uint8 public currentPauseLevel = LEVEL_NORMAL;

    /// @notice Whether recovery procedure has been completed after the last pause
    bool public recoveryComplete = true;

    /// @notice Timestamp of the most recent pause activation
    uint256 public lastPauseTimestamp;

    /// @notice Timestamp when the current pause was lifted (0 if still active)
    uint256 public lastLiftTimestamp;

    /// @notice Timelock controller's cooldown between activations
    uint256 public timelockCooldown = 1 hours;

    /// @notice Last time the timelock controller activated a pause
    uint256 public lastTimelockActivation;

    // ─── Audit Trail ──────────────────────────────────────────────────

    struct EmergencyRecord {
        uint8 level;
        uint256 timestamp;
        address initiator;
        string reason;
        bytes32 proposalRef;
        uint256 recoveryTimestamp;
    }

    /// @notice All emergency actions, indexed chronologically
    EmergencyRecord[] public emergencyHistory;

    // ─── Events ───────────────────────────────────────────────────────

    event EmergencyPauseActivated(
        uint8 indexed level,
        address indexed executor,
        string reason,
        bytes32 indexed proposalRef
    );

    event EmergencyPauseLifted(
        uint8 indexed previousLevel,
        address indexed executor,
        bytes32 indexed proposalRef
    );

    event EmergencyActionRecorded(bytes32 indexed actionId);

    event RecoveryStepCompleted(
        uint8 indexed step,
        address indexed executor,
        string description
    );

    event RecoveryFinalised(address indexed executor, uint256 timestamp);

    /// @notice Emitted when the timelock cooldown is updated by governance.
    event TimelockCooldownUpdated(
        uint256 indexed previousCooldown,
        uint256 indexed newCooldown,
        address indexed executor
    );

    /// @notice Emitted when a role's admin is changed.
    event RoleAdminChanged(
        bytes32 indexed role,
        bytes32 indexed previousAdminRole,
        bytes32 indexed newAdminRole
    );

    /// @notice Emitted when a role is granted to an account.
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    /// @notice Emitted when a role is revoked from an account.
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    // ─── Constructor ──────────────────────────────────────────────────

    /**
     * @param emergencyCouncil Address authorised for rapid emergency response
     * @param daoGovernance Address of the DAO governance contract or multisig
     * @param timelockController Address of the timelock controller
     */
    constructor(
        address emergencyCouncil,
        address daoGovernance,
        address timelockController
    ) {
        if (emergencyCouncil == address(0)) revert ZeroAddress();
        if (daoGovernance == address(0)) revert ZeroAddress();
        if (timelockController == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, daoGovernance);
        _grantRole(EMERGENCY_COUNCIL, emergencyCouncil);
        _grantRole(DAO_GOVERNANCE, daoGovernance);
        _grantRole(TIMELOCK_CONTROLLER, timelockController);
        _grantRole(RECOVERY_EXECUTOR, daoGovernance);
    }

    // ─── Pause Activation ─────────────────────────────────────────────

    /**
     * @notice Activate an emergency pause at the specified level.
     * @dev Can only increase the pause level (not decrease). Use `liftPause` to lower.
     * @param level The pause level to activate (must be > current level)
     * @param reason Human-readable reason for the pause (stored on-chain)
     * @param proposalRef Optional governance proposal reference (bytes32(0) if none)
     */
    function activatePause(
        uint8 level,
        string calldata reason,
        bytes32 proposalRef
    ) external nonReentrant {
        if (level > MAX_PAUSE_LEVEL) revert InvalidPauseLevel(level);
        if (level <= currentPauseLevel) revert AlreadyAtLevel(currentPauseLevel);
        if (level == LEVEL_NORMAL) revert InvalidPauseLevel(level);

        // Authorisation check based on level
        if (level == LEVEL_SHUTDOWN) {
            // Only EMERGENCY_COUNCIL or DAO_GOVERNANCE can trigger full shutdown
            if (
                !hasRole(EMERGENCY_COUNCIL, msg.sender) &&
                !hasRole(DAO_GOVERNANCE, msg.sender)
            ) revert NotAuthorizedForLevel(msg.sender, level);
        } else if (level == LEVEL_FINANCIAL) {
            if (
                !hasRole(EMERGENCY_COUNCIL, msg.sender) &&
                !hasRole(DAO_GOVERNANCE, msg.sender)
            ) revert NotAuthorizedForLevel(msg.sender, level);
        } else if (level == LEVEL_HIGH_RISK) {
            // All three roles can activate L1
            if (hasRole(TIMELOCK_CONTROLLER, msg.sender)) {
                // Timelock cooldown enforcement
                if (block.timestamp < lastTimelockActivation + timelockCooldown) {
                    revert("Timelock cooldown not elapsed");
                }
                lastTimelockActivation = block.timestamp;
            } else if (
                !hasRole(EMERGENCY_COUNCIL, msg.sender) &&
                !hasRole(DAO_GOVERNANCE, msg.sender)
            ) {
                revert NotAuthorizedForLevel(msg.sender, level);
            }
        }

        uint256 reasonLength = bytes(reason).length;
        if (reasonLength > MAX_REASON_BYTES) revert ReasonTooLong(reasonLength, MAX_REASON_BYTES);

        currentPauseLevel = level;
        lastPauseTimestamp = block.timestamp;
        lastLiftTimestamp = 0;
        recoveryComplete = false;

        emergencyHistory.push(
            EmergencyRecord({
                level: level,
                timestamp: block.timestamp,
                initiator: msg.sender,
                reason: reason,
                proposalRef: proposalRef,
                recoveryTimestamp: 0
            })
        );

        bytes32 actionId = keccak256(
            abi.encode(level, msg.sender, reason, block.timestamp)
        );

        emit EmergencyPauseActivated(level, msg.sender, reason, proposalRef);
        emit EmergencyActionRecorded(actionId);
    }

    // ─── Pause Lifting ─────────────────────────────────────────────────

    /**
     * @notice Lift the emergency pause entirely, returning to LEVEL_NORMAL.
     * @dev Only DAO_GOVERNANCE can lift a pause. Emergency Council cannot unilaterally lift.
     * @param proposalRef Governance proposal reference authorising the lift
     */
    function liftPause(bytes32 proposalRef) external nonReentrant {
        if (currentPauseLevel == LEVEL_NORMAL) revert ProtocolNotPaused();

        // Only DAO governance can lift — Emergency Council CANNOT
        if (!hasRole(DAO_GOVERNANCE, msg.sender)) {
            revert("Only DAO governance can lift pause");
        }

        uint8 previousLevel = currentPauseLevel;
        currentPauseLevel = LEVEL_NORMAL;
        lastLiftTimestamp = block.timestamp;
        recoveryComplete = false; // Recovery must be performed after lifting

        // Update the last emergency record with recovery timestamp
        if (emergencyHistory.length > 0) {
            emergencyHistory[emergencyHistory.length - 1].recoveryTimestamp = block.timestamp;
        }

        emit EmergencyPauseLifted(previousLevel, msg.sender, proposalRef);
        emit EmergencyActionRecorded(
            keccak256(abi.encode("lift", previousLevel, msg.sender, block.timestamp))
        );
    }

    // ─── Recovery Procedure ────────────────────────────────────────────

    uint8 public recoveryStep = 0;
    uint8 public constant MAX_RECOVERY_STEP = 3;

    /**
     * @notice Complete a step of the staged recovery procedure.
     * @dev Recovery must be performed sequentially (step 1 → 2 → 3).
     *      Protocol must be at LEVEL_NORMAL before recovery begins.
     *      Step bounds enforced by EmergencyPauseOrdering (V2-SC-117).
     * @param description Description of the recovery action taken
     */
    function completeRecoveryStep(string calldata description) external {
        if (currentPauseLevel != LEVEL_NORMAL) revert("Protocol is still paused");
        if (recoveryComplete) revert("Recovery already complete");
        if (!hasRole(RECOVERY_EXECUTOR, msg.sender)) {
            revert("Not authorised for recovery");
        }

        uint8 nextStep = recoveryStep + 1;
        EmergencyPauseOrdering.requireValidRecoveryStep(nextStep);

        recoveryStep = nextStep;

        emit RecoveryStepCompleted(nextStep, msg.sender, description);

        // Finalise after last step
        if (recoveryStep == MAX_RECOVERY_STEP) {
            recoveryComplete = true;
            recoveryStep = 0;
            emit RecoveryFinalised(msg.sender, block.timestamp);
        }
    }

    // ─── Read Interface ────────────────────────────────────────────────

    /**
     * @notice Check if a specific operation type is currently allowed.
     * @dev Called by protocol modules before executing restricted operations.
     *      Authoritative matrix: EmergencyPauseOrdering (V2-SC-117 / #503).
     *      Operation id hashes are unchanged vs the prior inline implementation.
     * @param operationType The operation category to check
     * @return True if the operation is allowed at the current pause level
     */
    function isOperationAllowed(bytes32 operationType) external view returns (bool) {
        return EmergencyPauseOrdering.isOperationAllowed(currentPauseLevel, operationType);
    }

    /**
     * @notice Returns the current pause level.
     */
    function getPauseLevel() external view returns (uint8) {
        return currentPauseLevel;
    }

    /**
     * @notice Returns the number of emergency actions in the audit trail.
     */
    function getEmergencyHistoryCount() external view returns (uint256) {
        return emergencyHistory.length;
    }

    /**
     * @notice Returns a page of emergency history records.
     * @param start Index to start from
     * @param count Maximum number of records to return
     */
    function getEmergencyHistory(
        uint256 start,
        uint256 count
    ) external view returns (EmergencyRecord[] memory) {
        uint256 end = start + count;
        if (end > emergencyHistory.length) {
            end = emergencyHistory.length;
        }
        if (start >= end) return new EmergencyRecord[](0);

        EmergencyRecord[] memory page = new EmergencyRecord[](end - start);
        for (uint256 i = start; i < end; i++) {
            page[i - start] = emergencyHistory[i];
        }
        return page;
    }

    /**
     * @notice Returns recovery status details.
     */
    function getRecoveryStatus()
        external
        view
        returns (
            bool isComplete,
            uint8 currentStep,
            bool isPaused,
            uint8 pauseLevel
        )
    {
        return (recoveryComplete, recoveryStep, currentPauseLevel != LEVEL_NORMAL, currentPauseLevel);
    }

    /**
     * @notice Returns the addresses authorised for each emergency role.
     */
    function getAuthorisedRoles()
        external
        view
        returns (
            uint256 emergencyCouncilCount,
            uint256 daoGovernanceCount,
            uint256 timelockControllerCount
        )
    {
        return (
            getRoleMemberCount(EMERGENCY_COUNCIL),
            getRoleMemberCount(DAO_GOVERNANCE),
            getRoleMemberCount(TIMELOCK_CONTROLLER)
        );
    }

    // ─── Admin ─────────────────────────────────────────────────────────

    /**
     * @notice Update the timelock controller's cooldown period.
     * @dev Only DAO_GOVERNANCE can change this.
     */
    function setTimelockCooldown(uint256 newCooldown) external onlyRole(DAO_GOVERNANCE) {
        uint256 previousCooldown = timelockCooldown;
        if (previousCooldown == newCooldown) revert NoChangeRequested();
        timelockCooldown = newCooldown;
        emit TimelockCooldownUpdated(previousCooldown, newCooldown, msg.sender);
    }
}
