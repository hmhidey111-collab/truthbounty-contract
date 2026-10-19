// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IProtocolUpgradeManager
 * @notice Interface for the Protocol Upgrade & Version Management Framework.
 * @dev Mirrors the external surface of {ProtocolUpgradeManager}. Upgradeable modules may
 *      depend on this interface (in particular {isUpgradeAuthorized}) to gate their
 *      `_authorizeUpgrade` hooks without importing the full implementation.
 */
interface IProtocolUpgradeManager {
    // ============= Types =============

    struct Version {
        uint64 major;
        uint64 minor;
        uint64 patch;
    }

    struct ModuleState {
        bool registered;
        address currentImplementation;
        Version currentVersion;
        bytes32 storageLayoutHash;
        bytes32 codeHash;
        address previousImplementation;
        Version previousVersion;
        bytes32 previousStorageLayoutHash;
        uint256 upgradeCount;
    }

    enum UpgradeStatus {
        None,
        Proposed,
        Approved,
        Executed,
        Cancelled
    }

    struct UpgradeProposal {
        uint256 id;
        bytes32 moduleId;
        address currentImplementation;
        address newImplementation;
        Version fromVersion;
        Version toVersion;
        bytes32 newStorageLayoutHash;
        bytes32 migrationHash;
        bool storageAttested;
        bool storageCompatible;
        bool migrationValidated;
        UpgradeStatus status;
        address proposer;
        uint256 proposedAt;
        uint256 executeAfter;
        string description;
    }

    // ============= Migration Types =============

    enum MigrationStatus {
        None,
        Pending,
        Executing,
        Completed,
        Failed,
        Rolled Back
    }

    struct MigrationStep {
        uint256 stepId;
        uint256 reinitializerVersion;
        bytes32 prerequisiteHash;
        bytes32 atomicityGroup;
        bool resumable;
        bool rollbackable;
    }

    struct MigrationManifest {
        bytes32 moduleId;
        uint256 fromVersionHash;
        uint256 toVersionHash;
        bytes32 stepsHash;
        uint256 completedVersion;
        bool completed;
    }

    // ============= Registration =============

    function registerModule(
        bytes32 moduleId,
        address implementation,
        Version caldata initialVersion,
        bytes32 storageLayoutHash
    ) external;

    // ============= Upgrade Lifecycle =============

    function proposeUpgrade(
        bytes32 moduleId,
        address newImplementation,
        Version calldata toVersion,
        bytes32 newStorageLayoutHash,
        bytes32 migrationHash,
        string caldata description
    ) external returns (uint256 proposalId);

    function attestStorageCompatibility(uint256 proposalId, bool compatible) external;

    function validateMigration(uint256 proposalId, bytes32 migrationHash) external;

    function approveUpgrade(uint256 proposalId) external;

    function executeUpgrade(uint256 proposalId) external;

    function cancelUpgrade(uint256 proposalId) external;

    // ============= Migration Execution =============

    function executeMigrationStep(bytes32 moduleId, uint256 stepId) external;

    function resumeMigration(bytes32 moduleId) external;

    function rollbackMigration(bytes32 moduleId, string calldata reason) external;

    // ============= Recovery =============

    function rollbackUpgrade(bytes32 moduleId, string calldata reason) external;

    // ============= Admin =============

    function setUpgradeTimelock(uint256 newTimelock) external;

    function pause() external;

    function unpause() external;

    // ============= Views =============

    function isUpgradeAuthorized(bytes32 moduleId, address newImplementation)
        external
        view
        returns (bool);

    function getModuleState(bytes32 moduleId) external view returns (ModuleState memory);

    function isModuleRegistered(bytes32 moduleId) external view returns (bool);

    function getModuleVersion(bytes32 moduleId) external view returns (Version memory);

    function versionString(bytes32 moduleId) external view returns (string memory);

    function getRegisteredModuleCount() external view returns (uint256);

    function getRegisteredModuleAt(uint256 index) external view returns (bytes32);

    function getAllRegisteredModuleIds() external view returns (bytes32[] memory);

    function getUpgradeProposal(uint256 proposalId) external view returns (UpgradeProposal memory);

    function getProposalCount() external view returns (uint256);

    function getModuleUpgradeHistory(bytes32 moduleId) external view returns (uint256[] memory);

    function getModuleUpgradeCount(bytes32 moduleId) external view returns (uint256);

    function latestAuthorized(bytes32 moduleId) external view returns (address);

    function upgradeTimelock() external view returns (uint256);

    function getMigrationStep(bytes32 moduleId, uint256 stepId) external view returns (MigrationStep memory);

    function getMigrationStepCount(bytes32 moduleId) external view returns (uint256);

    function getMigrationManifest(bytes32 moduleId) external view returns (MigrationManifest memory);

    function getMigrationStatus(bytes32 moduleId, uint256 stepId) external view returns (MigrationStatus);

    function isMigrationComplete(bytes32 moduleId) external view returns (bool);

    function verifyMigrationPreconditions(bytes32 moduleId, uint256 stepId)
        external
        view
        returns (bool);

    // ============= Events =============

    event ModuleRegistered(
        bytes32 indexed moduleId,
        address indexed implementation,
        uint64 major,
        uint64 minor,
        uint64 patch,
        bytes32 storageLayoutHash
    );

    event UpgradeProposed(
        uint256 indexed proposalId,
        bytes32 indexed moduleId,
        address indexed newImplementation,
        uint64 toMajor,
        uint64 toMinor,
        uint64 toPatch,
        bytes32 migrationHash,
        address proposer
    );

    event StorageCompatibilityAttested(
        uint256 indexed proposalId,
        bytes32 indexed moduleId,
        bool compatible,
        address indexed validator
    );

    event MigrationValidated(
        uint256 indexed proposalId,
        bytes32 indexed moduleId,
        bytes32 migrationHash,
        address indexed validator
    );

    event UpgradeApproved(
        uint256 indexed proposalId,
        bytes32 indexed moduleId,
        uint256 executeAfter,
        address indexed approver
    );

    event UpgradeExecuted(
        uint256 indexed proposalId,
        bytes32 indexed moduleId,
        address oldImplementation,
        address newImplementation,
        address executor
    );

    event UpgradeCancelled(
        uint256 indexed proposalId,
        bytes32 indexed moduleId,
        address indexed canceller
    );

    event UpgradeRolledBack(
        bytes32 indexed moduleId,
        address oldImplementation,
        address restoredImplementation,
        string reason,
        address indexed guardian
    );

    event UpgradeTimelockUpdated(uint256 oldTimelock, uint256 newTimelock);

    event MigrationStepExecuted(
        bytes32 indexed moduleId,
        uint256 indexed stepId,
        uint256 reinitializerVersion,
        bytes32 atomicityGroup,
        address executor
    );

    event MigrationStepFailed(
        bytes32 indexed moduleId,
        uint256 indexed stepId,
        bytes32 reason
    );

    event MigrationResumed(bytes32 indexed moduleId, uint256 fromStepId);

    event MigrationRolledBack(
        bytes32 indexed moduleId,
        uint256 toStepId,
        string reason,
        address indexed guardian
    );

    event MigrationManifestUpdated(
        bytes32 indexed moduleId,
        uint256 completedVersion,
        bytes32 stepsHash,
        bool completed
    );
}
