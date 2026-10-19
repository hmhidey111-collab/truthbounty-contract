// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMigrationManager {
    struct Migration {
        uint256 id;
        string description;
        uint256 timestamp;
        address executor;
        bool executed;
        bytes32 migrationHash;
    }

    // Prewave SC-077: declared migration step with prerequisites and reinitializer version.
    struct MigrationStep {
        bytes32 stepId;
        uint64 version;
        uint64 reinitializerVersion;
        bytes32[] prerequisites;
        address expectedImplementation;
        bytes32 migrationHash;
        bool registered;
        bool completed;
    }

    function createRelease(string calldata version, bytes32 gitCommit) external;
    function registerModuleInRegistry(bytes32 moduleId, address moduleAddress) external;
    function updateModuleAddress(bytes32 moduleId, address newAddress) external;
    function executeMigration(string calldata description, bytes32 migrationHash) external;
    function verifyDeployment(bool ownershipTransferred, bool allModulesInitialized) external;

    // Prewave SC-077: ordered migration step registry and execution.
    function registerMigrationStep(
        bytes32 stepId,
        uint64 version,
        uint64 reinitializerVersion,
        bytes32[] calldata prerequisites,
        address expectedImplementation,
        bytes32 migrationHash
    ) external;

    function sealMigrationManifest() external;

    function executeMigrationStep(
        bytes32 stepId,
        uint64 reinitializerVersion,
        address implementation,
        bytes32 migrationHash
    ) external;

    function rollbackMigrationStep(bytes32 stepId, string calldata reason) external;

    function getMigrationStep(bytes32 stepId) external view returns (MigrationStep memory);
    function getMigrationStepCount() external view returns (uint256);
    function getMigrationStepAt(uint256 index) external view returns (MigrationStep memory);
    function isManifestSealed() external view returns (bool);
    function isStepExecutable(bytes32 stepId) external view returns (bool);

    function getModuleAddress(bytes32 moduleId) external view returns (address);
    function getRegisteredModuleCount() external view returns (uint256);
    function getRegisteredModuleAt(uint256 index) external view returns (bytes32 moduleId, address moduleAddress);
    function getAllRegisteredModules() external view returns (bytes32[] memory ids, address[] memory addresses);
    function getMigrationCount() external view returns (uint256);
    function getMigrationAt(uint256 index) external view returns (Migration memory);
    function getAllMigrations() external view returns (Migration[] memory);
    function isModuleRegistered(bytes32 moduleId) external view returns (bool);
    function isDeploymentVerified() external view returns (bool);

    event ReleaseCreated(string indexed version, bytes32 indexed gitCommit, address indexed deployedBy);
    event ModuleRegisteredInRegistry(bytes32 indexed moduleId, address indexed moduleAddress);
    event MigrationExecuted(uint256 indexed migrationId, string description, address indexed executor);
    event DeploymentVerified(bool ownershipTransferred, bool allModulesInitialized);

    // Prewave SC-077 event evidence.
    event MigrationStepRegistered(
        bytes32 indexed stepId,
        uint64 version,
        uint64 reinitializerVersion,
        address expectedImplementation,
        bytes32 migrationHash
    );
    event MigrationStepCompleted(
        bytes32 indexed stepId,
        uint64 indexed version,
        uint64 reinitializerVersion,
        address implementation,
        bytes32 migrationHash,
        address executor
    );
    event MigrationStepRolledBack(
        bytes32 indexed stepId,
        uint64 indexed version,
        address guardian,
        string reason
    );
}
