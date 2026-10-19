// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IVersionRegistry
 * @notice Interface for the canonical protocol version registry
 */
interface IVersionRegistry {
    enum MigrationStatus {
        NONE,
        PENDING,
        IN_PROGRESS,
        COMPLETED,
        FAILED,
        ROLLED_BACK
    }

    struct MigrationStep {
        uint256 reinitializerVersion;
        string fromVersion;
        string toVersion;
        bytes32 prerequisiteHash;
        bytes32 stepHash;
        bool atomic;
        bool resumable;
        bool rollbackable;
    }

    struct MigrationRecord {
        uint256 reinitializerVersion;
        string fromVersion;
        string toVersion;
        bytes32 stepHash;
        bytes32 evidenceHash;
        uint256 executedAt;
        MigrationStatus status;
    }

    enum VersionStatus {
        ACTIVE,
        DEPRECATED,
        ROLLED_BACK
    }

    struct VersionEntry {
        string contractName;
        address implementation;
        address proxy;
        string semanticVersion;
        uint256 deployedAt;
        bytes32 governanceProposalId;
        bytes32 upgradeHash;
        VersionStatus status;
    }

    event MigrationStepDefined(
        uint256 indexed reinitializerVersion,
        string indexed fromVersion,
        string indexed toVersion,
        bytes32 stepHash
    );

    event MigrationExecuted(
        uint256 indexed reinitializerVersion,
        string indexed fromVersion,
        string indexed toVersion,
        bytes32 stepHash,
        bytes32 evidenceHash
    );

    event MigrationFailed(
        uint256 indexed reinitializerVersion,
        string indexed fromVersion,
        string indexed toVersion,
        bytes32 stepHash,
        bytes32 reasonHash
    );

    event VersionRegistered(
        string indexed contractName,
        string indexed semanticVersion,
        address implementation
    );

    event VersionStatusUpdated(
        string indexed contractName,
        string indexed semanticVersion,
        VersionStatus newStatus
    );

    event MigrationRolledBack(
        uint256 indexed reinitializerVersion,
        string indexed fromVersion,
        string indexed toVersion,
        bytes32 stepHash
    );

    event MigrationManifestUpdated(
        string indexed contractName,
        uint256 indexed reinitializerVersion,
        bytes32 manifestHash
    );

    function registerVersion(
        string calldata contractName,
        address implementation,
        address proxy,
        string calldata semanticVersion,
        bytes32 governanceProposalId,
        bytes32 upgradeHash
    ) external returns (uint256 index);

    function updateVersionStatus(
        string calldata contractName,
        string calldata semanticVersion,
        VersionStatus newStatus
    ) external;

    function getLatestVersion(string calldata contractName) external view returns (VersionEntry memory);
    function getVersion(string calldata contractName, string calldata semanticVersion) external view returns (VersionEntry memory);
    function getVersionAtIndex(string calldata contractName, uint256 index) external view returns (VersionEntry memory);
    function getVersionCount(string calldata contractName) external view returns (uint256);
    function getActiveVersion(string calldata contractName) external view returns (VersionEntry memory);
    function isVersionActive(string calldata contractName, string calldata semanticVersion) external view returns (bool);

    function defineMigrationStep(
        uint256 reinitializerVersion,
        string calldata fromVersion,
        string calldata toVersion,
        bytes32 prerequisiteHash,
        bytes32 stepHash,
        bool atomic,
        bool resumable,
        bool rollbackable
    ) external;

    function executeMigrationStep(
        uint256 reinitializerVersion,
        bytes32 stepHash,
        bytes32 evidenceHash
    ) external;

    function rollbackMigrationStep(
        uint256 reinitializerVersion,
        bytes32 stepHash
    ) external;

    function getMigrationStep(uint256 reinitializerVersion) external view returns (MigrationStep memory);
    function getMigrationRecord(uint256 reinitializerVersion) external view returns (MigrationRecord memory);
    function isMigrationCompleted(uint256 reinitializerVersion) external view returns (bool);
    function isMigrationPrerequisiteSatisfied(uint256 reinitializerVersion) external view returns (bool);
    function getCompletedMigrationCount() external view returns (uint256);
    function getMigrationManifestHash(string calldata contractName) external view returns (bytes32);
    function verifyMigrationOrdering(uint256[] calldata reinitializerVersions) external view returns (bool);
}
