// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../governance/GovernanceOwnable.sol";
import "../interfaces/ITruthBountyEvents.sol";

contract MigrationManager is ReentrancyGuard, Pausable, GovernanceOwnable, ITruthBountyEvents {
    uint16 public constant EVENT_SCHEMA_VERSION = 1;
    bytes32 public constant ADMIN_ROLE = keccak(256("ADMIN_ROLE"));
    bytes32 public constant PAUSER_ROLE = keccak(256("PAUSER_ROLE"));
    bytes32 public constant MIGRATOR_ROLE = keccak(256("MIGRATOR_ROLE"));
    bytes32 public constant UPGRADER_ROLE = keccak(256("UPGRADER_ROLE"));

    /// @udev Reinitializer version boundaries. Version 0 is the initial deployed
    /// state; version 1 is the first authorized upgrade reinitializer. Each
    /// subsequent upgrade must advance the version by exactly one.
    uint64 public constant INITIAL_REINIT_VERSION = 0;
    uint64 public constant FIRST_UPGRADE_REINIT_VERSION = 1;

    /// @udev Migration step definition. Each step is executed exactly once,
    /// in ascending order, and only after all of its prerequisite steps have
    /// completed. The hash binds the description and the expected post-state
    /// so that operators cannot silently swap a step for a different one.
    struct MigrationStep {
        uint256 id;
        string description;
        bytes32 migrationHash;
        uint256[] prerequisites;
        bool registered;
        bool executed;
        uint256 executedAt;
        address executedBy;
    }

    /// @udev Release manifest entry. The manifest records completed reinit
    /// versions and the exact set of migration steps that have been executed.
    struct Release {
        string version;
        uint256 timestamp;
        bytes32 gitCommit;
        address deployedBy;
        bool finalized;
        mapping(bytes32 => address) modules;
        bytes32[] moduleKeys;
    }

    struct Migration {
        uint256 id;
        string description;
        uint256 timestamp;
        address executor;
        bool executed;
        bytes32 migrationHash;
    }

    uint256 public migrationCounter;
    string public currentVersion;
    bytes32 public currentGitCommit;
    uint256 public deployTimestamp;
    address public deployOperator;

    mapping(bytes32 => address) public addressRegistry;
    mapping(bytes32 => bool) public registeredModules;
    bytes32[] public registeredModuleKeys;

    mapping(uint256 => Migration) public migrations;
    uint256[] public migrationIds;

    /// @udev Ordered migration plan. Step ids are expected to be assigned in
    /// ascending order and executed in that order.
    mapping(uint256 => MigrationStep) internal migrationSteps;
    uint256[] internal migrationStepIds;
    uint256 public executedStepCount;

    /// @udev Current reinitializer version recorded in the manifest.
    uint64 public reinitializerVersion;

    /// @udev Manifest of completed reinit versions. Advanced only by the
    /// governance-timedock authorized upgrade path.
    mapping(uint64 => bool) public completedReinitVersions;
    uint64[] public completedReinitVersionList;

    bool public ownershipVerified;
    bool public deploymentVerified;

    event ReleaseCreated(
        string indexed version,
        bytes32 indexed gitCommit,
        address indexed deployedBy
    );

    event ReleaseFinalized(string indexed version);

    event ModuleRegisteredInRegistry(
        bytes32 indexed moduleId,
        address indexed moduleAddress
    );

    event MigrationExecuted(
        uint256 indexed migrationId,
        string description,
        address indexed executor
    );

    event AddressUpdated(
        bytes32 indexed moduleId,
        address indexed oldAddress,
        address indexed newAddress
    );

    event DeploymentVerified(bool ownershipTransferred, bool allModulesInitialized);

    event OwnershipTransferred(
        bytes32 indexed moduleId,
        address indexed oldOwner,
        address indexed newOwner
    );

    /// @udev Emitted when a migration step is registered in the ordered plan.
    event MigrationStepRegistered(
        uint256 indexed stepId,
        bytes32 indexed migrationHash,
        uint256[] prerequisites
    );

    /// @udev Emitted when a migration step completes successfully.
    event MigrationStepExecuted(
        uint256 indexed stepId,
        bytes32 indexed migrationHash,
        address indexed executor
    );

    /// @udev Emitted when a migration step is rolled back after a partial
    /// failure or governance-requested recovery.
    event MigrationStepRolledBack(
        uint256 indexed stepId,
        bytes32 indexed migrationHash,
        address indexed executor,
        string reason
    );

    /// @udev Emitted when the reinitializer version advances and the
    /// manifest records the completed version.
    event ReinitializerVersionAdvanced(
        uint64 indexed previousVersion,
        uint64 indexed newVersion,
        address indexed executor
    );

    /// @udev Emitted when a partial migration is detected and the contract
    /// is paused to prevent unsafe state from being exposed.
    event PartialMigrationDetected(
        uint256 indexed lastCompletedStep,
        uint256 indexed failedStep,
        string reason
    );

    error ReleaseAlreadyFinalized();
    error ReleaseNotFinalized();
    error ModuleAlreadyRegistered(bytes32 moduleId);
    error ModuleNotRegistered(bytes32 moduleId);
    error MigrationAlreadyExecuted(uint256 migrationId);
    error InvalidVersion();
    error InvalidAddress();
    error DeploymentNotVerified();
    error MigrationStepAlreadyRegistered(uint256 stepId);
    error MigrationStepNotRegistered(uint256 stepId);
    error MigrationStepAlreadyExecuted(uint256 stepId);
    error MigrationStepNotExecuted(uint256 stepId);
    error PrerequisiteNotSatisfied(uint256 stepId, uint256 prerequisiteId);
    error MigrationOutOfOrder(uint256 expectedStepId, uint256 actualStepId);
    error MigrationHashMismatch(bytes32 expectedHash, bytes32 actualHash);
    error ReinitializerVersionMismatch(uint64 expectedVersion, uint64 actualVersion);
    error ReinitializerVersionAlreadyCompleted(uint64 version);
    error PartialMigrationState(uint256 lastCompletedStep, uint256 failedStep);
    error NotTimelockExecutor(address caller);
    error InvalidPrerequisite(uint256 stepId, uint256 prerequisiteId);
    error EmergencyControlsActive();

    /// @udev Timelock executor authorized to advance the reinitializer version
    /// and record completed versions in the manifest.
    address public timelockExecutor;

    /// @udev Operation-scoped emergency control flag. When set, migration
    /// execution is blocked but governance roles and timelock authority are
    /// preserved.
    bool public emergencyControlsActive;

    modifier onlyTimelock() {
        if (msg.sender != timelockExecutor) revert NotTimelockExecutor(msg.sender);
        _;
    }

    modifier notEmergency() {
        if (emergencyControlsActive) revert EmergencyControlsActive();
        _;
    }

    constructor(
        address initialAdmin,
        address _governanceController,
        address _timelockExecutor
    ) {
        require(initialAdmin != address(0), "Invalid admin");
        require(_timelockExecutor != address(0), "Invalid timelock");
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(MIGRATOR_ROLE, initialAdmin);
        _grantRole(UPGRADER_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
        _setRoleAdmin(MIGRATOR_ROLE, ADMIN_ROLE);
        _setRoleAdmin(UPGRADER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
        timelockExecutor = _timelockExecutor;
        reinitializerVersion = INITIAL_REINIT_VERSION;
        completedReinitVersions[INITIAL_REINIT_VERSION] = true;
        completedReinitVersionList.push(INITIAL_REINIT_VERSION);
        _initializeGovernance(_governanceController, initialAdmin, initialAdmin);
    }

    /// @udev Advance the reinitializer version. Only the timelock executor
    /// can call this, and the version must advance by exactly one. The manifest
    /// records the completed version and emits evidence.
    function advanceReinitializerVersion(
        uint64 newVersion
    ) external onlyTimelock notEmergency {
        uint64 previous = reinitializerVersion;
        if (newVersion != previous + 1) {
            revert ReinitializerVersionMismatch(previous + 1, newVersion);
        }
        if (completedReinitVersions[newVersion]) {
            revert ReinitializerVersionAlreadyCompleted(newVersion);
        }
        reinitializerVersion = newVersion;
        completedReinitVersions[newVersion] = true;
        completedReinitVersionList.push(newVersion);
        emit ReinitializerVersionAdvanced(previous, newVersion, msg.sender);
    }

    /// @udev Register a migration step in the ordered plan. Prerequisites
    /// must already be registered and must have lower ids to enforce order.
    function registerMigrationStep(
        uint256 stepId,
        string caldata description,
        bytes32 migrationHash,
        uint256[] calldata prerequisites
    ) external onlyRole(MIGRATOR_ROLE) notEmergency {
        if (bytes(description).length == 0) revert InvalidVersion();
        if (migrationHash == bytes32(0)) revert InvalidVersion();
        if (migrationSteps[stepId].registered) {
            revert MigrationStepAlreadyRegistered(stepId);
        }
        // Enforce ascending id order for the plan.
        if (migrationStepIds.length > 0) {
            uint256 lastId = migrationStepIds[migrationStepIds.length - 1];
            if (stepId <= lastId) {
                revert MigrationOutOfOrder(lastId + 1, stepId);
            }
        }
        for (uint256 i = 0; i < prerequisites.length; i++) {
            uint256 prereq = prerequisites[i];
            if (prereq >= stepId) revert InvalidPrerequisite(stepId, prereq);
            if (!migrationSteps[prereq].registered) {
                revert PrerequisiteNotSatisfied(stepId, prereq);
            }
        }
        MigrationStep storage step = migrationSteps[stepId];
        step.id = stepId;
        step.description = description;
        step.migrationHash = migrationHash;
        step.prerequisites = prerequisites;
        step.registered = true;
        migrationStepIds.push(stepId);
        emit MigrationStepRegistered(stepId, migrationHash, prerequisites);
    }

    /// @udev Execute a migration step. Steps must be executed in ascending
    /// order, exactly once, and only after all prerequisites have completed.
    /// The hash must match the registered expected post-state.
    function executeMigrationStep(
        uint256 stepId,
        bytes32 expectedHash
    ) external onlyRole(MIGRATOR_ROLE) nonReentrant notEmergency {
        MigrationStep storage step = migrationSteps[stepId];
        if (!step.registered) revert MigrationStepNotRegistered(stepId);
        if (step.executed) revert MigrationStepAlreadyExecuted(stepId);
        if (step.migrationHash != expectedHash) {
            revert MigrationHashMismatch(step.migrationHash, expectedHash);
        }
        // Enforce execution order: the next step must be the lowest not-yet
        // executed step in the registered plan.
        uint256 expected = _nextExecutableStepId();
        if (stepId != expected) {
            revert MigrationOutOfOrder(expected, stepId);
        }
        for (uint256 i = 0; i < step.prerequisites.length; i++) {
            uint256 prereq = step.prerequisites[i];
            if (!migrationSteps[prereq].executed) {
                revert PrerequisiteNotSatisfied(stepId, prereq);
            }
        }
        step.executed = true;
        step.executedAt = block.timestamp;
        step.executedBy = msg.sender;
        executedStepCount += 1;
        emit MigrationStepExecuted(stepId, step.migrationHash, msg.sender);
    }

    /// @udev Roll back a migration step after a partial failure or governance
    /// recovery request. Rollback is only allowed for the most recently
    /// executed step and must be authorized by the timelock executor.
    function rollbackMigrationStep(
        uint256 stepId,
        string caldata reason
    ) external onlyTimelock notEmergency {
        MigrationStep storage step = migrationSteps[stepId];
        if (!step.registered) revert MigrationStepNotRegistered(stepId);
        if (!step.executed) revert MigrationStepNotExecuted(stepId);
        // Only the most recently executed step can be rolled back to keep the
        // ordered plan consistent.
        if (executedStepCount == 0) {
            revert MigrationStepNotExecuted(stepId);
        }
        uint256 lastExecuted = _lastExecutedStepId();
        if (stepId != lastExecuted) {
            revert MigrationOutOfOrder(lastExecuted, stepId);
        }
        step.executed = false;
        step.executedAt = 0;
        step.executedBy = address(0);
        executedStepCount -= 1;
        emit MigrationStepRolledBack(stepId, step.migrationHash, msg.sender, reason);
    }

    /// @udev Marked as partial migration when a step fails and the contract
    /// is paused. This ensures unsafe state is not exposed and the event
    /// provides evidence for operators.
    function flagPartialMigration(
        uint256 failedStep,
        string caldata reason
    ) external onlyRole(MIGRATOR_ROLE) {
        uint256 lastCompleted = _lastExecutedStepId();
        _pause();
        emit PartialMigrationDetected(lastCompleted, failedStep, reason);
    }

    /// @udev Emergency controls are operation-scoped and do not weaken the
    /// governance or timelock authority. They only block migration execution.
    function setEmergencyControls(bool active) external onlyRole(ADMIN_ROLE) {
        emergencyControlsActive = active;
    }

    function createRelease(
        string calldata version,
        bytes32 gitCommit
    ) external onlyRole(MIGRATOR_ROLE) nonReentrant {
        if (bytes(version).length == 0) revert InvalidVersion();
        currentVersion = version;
        currentGitCommit = gitCommit;
        deployTimestamp = block.timestamp;
        deployOperator = msg.sender;
        emit ReleaseCreated(version, gitCommit, msg.sender);
    }

    function registerModuleInRegistry(
        bytes32 moduleId,
        address moduleAddress
    ) external onlyRole(MIGRATOR_ROLE) {
        if (moduleAddress == address(0)) revert InvalidAddress();
        if (registeredModules[moduleId]) revert ModuleAlreadyRegistered(moduleId);
        addressRegistry[moduleId] = moduleAddress;
        registeredModules[moduleId] = true;
        registeredModuleKeys.push(moduleId);
        emit ModuleRegisteredInRegistry(moduleId, moduleAddress);
    }

    function updateModuleAddress(
        bytes32 moduleId,
        address newAddress
    ) external onlyRole(MIGRATOR_ROLE) {
        if (newAddress == address(0)) revert InvalidAddress();
        if (!registeredModules[moduleId]) revert ModuleNotRegistered(moduleId);
        address oldAddress = addressRegistry[moduleId];
        addressRegistry[moduleId] = newAddress;
        emit AddressUpdated(moduleId, oldAddress, newAddress);
    }

    function executeMigration(
        string caldata description,
        bytes32 migrationHash
    ) external onlyRole(MIGRATOR_ROLE) nonReentrant {
        uint256 id = migrationCounter++;
        migrations[id] = Migration({
            id: id,
            description: description,
            timestamp: block.timestamp,
            executor: msg.sender,
            executed: true,
            migrationHash: migrationHash
        });
        migrationIds.push(id);
        emit MigrationExecuted(id, description, msg.sender);
    }

    function verifyDeployment(
        bool _ownershipTransferred,
        bool _allModulesInitialized
    ) external onlyRole(MIGRATOR_ROLE) {
        ownershipVerified = _ownershipTransferred;
        deploymentVerified = _allModulesInitialized;
        emit DeploymentVerified(_ownershipTransferred, _allModulesInitialized);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); emit EmergencyPauseActivatedV1(
     msg.sender,
     keccak256("MANUAL_PAUSE"),
     uint64(block.timestamp),
     EVENT_SCHEMA_VERSION
 ); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); emit EmergencyPauseRecoveredV1(
     msg.sender,
     uint64(block.timestamp),
     EVENT_SCHEMA_VERSION
 ); }

    function getModuleAddress(bytes32 moduleId) external view returns (address) {
        if (!registeredModules[moduleId]) revert ModuleNotRegistered(moduleId);
        return addressRegistry[moduleId];
    }

    function getRegisteredModuleCount() external view returns (uint256) {
        return registeredModuleKeys.length;
    }

    function getRegisteredModuleAt(uint256 index) external view returns (bytes32 moduleId, address moduleAddress) {
        require(index < registeredModuleKeys.length, "Index out of bounds");
        moduleId = registeredModuleKeys[index];
        moduleAddress = addressRegistry[moduleId];
    }

    function getAllRegisteredModules() external view returns (bytes32[] memory ids, address[] memory addresses) {
        ids = registeredModuleKeys;
        addresses = new address ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            addresses[i] = addressRegistry[ids[i]];
        }
    }

    function getMigrationCount() external view returns (uint256) {
        return migrationIds.length;
    }

    function getMigrationAt(uint256 index) external view returns (Migration memory) {
        require(index < migrationIds.length, "Index out of bounds");
        return migrations[migrationIds[index]];
    }

    function getAllMigrations() external view returns (Migration[] memory) {
        Migration[] memory result = new Migration[](migrationIds.length);
        for (uint256 i = 0; i < migrationIds.length; i++) {
            result[i] = migrations[migrationIds[i]];
        }
        return result;
    }

    function isModuleRegistered(bytes32 moduleId) external view returns (bool) {
        return registeredModules[moduleId];
    }

    /// @udev Returns the number of registered migration steps.
    function getMigrationStepCount() external view returns (uint256) {
        return migrationStepIds.length;
    }

    /// @udev Returns a migration step by id.
    function getMigrationStep(uint256 stepId) external view returns (MigrationStep memory) {
        if (!migrationSteps[stepId].registered) revert MigrationStepNotRegistered(stepId);
        return migrationSteps[stepId];
    }

    /// @udev Returns the next executable step id and whether all steps are
    /// complete. Preconditions are machine-verifiable by consumers.
    function getNextExecutableStep() external view returns (uint256 nextStepId, bool allComplete) {
        allComplete = executedStepCount == migrationStepIds.length;
        if (allComplete) {
            return (0, true);
        }
        nextStepId = _nextExecutableStepId();
    }

    /// @udev Returns the manifest of completed reinit versions.
    function getCompletedReinitVersions() external view returns (uint64[] memory) {
        return completedReinitVersionList;
    }

    /// @udev Returns true if the given reinit version has been recorded as complete.
    function isReinitVersionCompleted(uint64 version) external view returns (bool) {
        return completedReinitVersions[version];
    }

    /// @udev Returns true if the migration plan is in a safe, consistent
    /// state: no partial execution that exposes unsafe state.
    function isManifestConsistent() external view returns (bool) {
        if (executedStepCount == 0) return true;
        // Every executed step must have all prerequisites executed and must be
        // part of the contiguous prefix of the registered plan.
        for (uint256 i = 0; i < migrationStepIds.length; i++) {
            uint256 stepId = migrationStepIds[i];
            MigrationStep storage step = migrationSteps[stepId];
            if (!step.executed) {
                // All subsequent steps must also be not executed.
                for (uint256 j = i + 1; j < migrationStepIds.length; j++) {
                    if (migrationSteps[migrationStepIds[j]].executed) return false;
                }
                return true;
            }
            for (uint256 k = 0; k < step.prerequisites.length; k++) {
                if (!migrationSteps[step.prerequisites[k]].executed) return false;
            }
        }
        return true;
    }

    /// @udev Returns the last executed step id in the contiguous prefix.
    function getLastCompletedStep() external view returns (uint256) {
        return _lastExecutedStepId();
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @udev Returns the lowest step id in the registered plan that has not
    /// yet been executed. Reverts if all steps are executed.
    function _nextExecutableStepId() internal view returns (uint256) {
        for (uint256 i = 0; i < migrationStepIds.length; i++) {
            uint256 stepId = migrationStepIds[i];
            if (!migrationSteps[stepId].executed) {
                return stepId;
            }
        }
        revert MigrationStepNotRegistered(0);
    }

    /// @udev Returns the highest step id in the contiguous executed prefix.
    /// Reverts if no step has been executed.
    function _lastExecutedStepId() internal view returns (uint256) {
        for (uint256 i = migrationStepIds.length; i > 0; i--) {
            uint256 stepId = migrationStepIds[i - 1];
            if (migrationSteps[stepId].executed) {
                return stepId;
            }
        }
        revert MigrationStepNotExecuted(0);
    }
}
