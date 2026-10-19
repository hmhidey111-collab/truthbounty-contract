// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./IVersionRegistry.sol";

/**
 * @title VersionRegistry
 * @notice Canonical registry for protocol contract version history
 * @dev Maintains an immutable record of every deployed version with metadata
 *      including implementation addresses, deployment timestamps, governance
 *      proposal IDs, and upgrade hashes for full audit trail
 *
 * PREWAVE-SC-076: Upgrade rollback state equivalence.
 * This registry now provides explicit rollback policy enforcement and a
 * canonical state-equivalence checkpoint mechanism so that an upgrade can be
 * rolled back only when the canonical storage invariants match the snapshot
 * taken before the upgrade. Unsupported rollbacks revert before execution.
 *
 * @dev PREWAVE-SC-077: this contract also records the reinitializer version
 *      and migration ordering for each registered version so that upgrade
 *      rehearsals can be machine-verified. Each migration sttep is recorded
 *      exactly once, in order, and the manifest exposes completed versions.
 */
contract VersionRegistry is IVersionRegistry, AccessControl {
    bytes32 public constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");
    bytes32 public constant ROLLBACK_ROLE = keccak256("ROLLBACK_ROLE");
    bytes32 public constant MIGRATION_ROLE = keccak256("MIGRATION_ROLE");

    /// @notice Maximum number of consecutive rollbacks allowed from the current active version.
    uint256 public constant MAX_ROLLBACK_DEPTH: uint256 = 3;

    /// @notice Maximum number of storage slots that may be compared in a single
    ///         equivalence check to bound gas and keep evidence deterministic.
    uint256 public constant MAX_EQUIVALENCE_SLOTS: uint256 = 256;

    enum RollbackPolicy {
        DISABLED,
        SINGLE_STEP,
        MULTI_STEP_BOUNDED

    }

    struct VersionList {
        VersionEntry[] entries;
        mapping(string => uint256) versionToIndex;
        string[] versionStrings;
        string activeVersion;
    }

    /// @notice Canonical storage slot snapshot captured before an upgrade.
    struct StorageSnapshot {
        bytes32 slotHash;
        bytes32 valueHash;
        uint256 slotCount;
        uint256 capturedAt;
        address capturedBy;
        bool exists;
    }

    /// @notice Rollback policy configured per contract.
    struct RollbackConfig {
        RollbackPolicy policy;
        uint256 maxDepth;
        bool allowStateDrift;
        bool exists;
    }

    /// @dev Per-contract migration manifest for the currently active version.
    ///      Tracks the expected reinitializer version and the ordered migration
    ///      steps that must execute exactly once and in order.
    struct MigrationManifest {
        uint64 reinitializerVersion;
        bytes32 expectedImplementationHash;
        uint64 expectedStepCount;
        uint64 completedStepCount;
        bool initialized;
        bool completed;
        string completedVersion;
    }

    /// @dev Per-contract migration step record.
    struct MigrationStep {
        uint64 index;
        bytes32 stepHash;
        bool executed;
        uint64 executedAt;
    }

    mapping(string => VersionList) internal _versions;
    string[] internal _contractNames;
    mapping(string => bool) internal _contractRegistered;

    /// @notice Snapshots taken before an upgrade keyed by contract name and
    ///         the version being upgraded from.
    mapping(string => mapping(string => StorageSnapshot)) internal _snapshots;

    /// @notice Rollback configuration keyed by contract name.
    mapping(string => RollbackConfig) internal _rollbackConfigs;

    /// @notice Number of consecutive rollbacks executed since the last forward
    ///         upgrade, keyed by contract name.
    mapping(string => uint256) internal _rollbackDepth;

    /// @dev Per-contract migration manifest and ordered steps.
    mapping(string => MigrationManifest) internal _manifests;
    mapping(string => MigrationStep[]) internal _migrationSteps;
    mapping(string => mapping(bytes32 => bool)) internal _stepHashSeen;

    error ContractAlreadyRegistered(string contractName);
    error ContractNotRegistered(string contractName);
    error VersionNotFound(string contractName, string version);
    error ZeroAddress();
    error EmptyString();
    error RollbackPolicyNotConfigured(string contractName);
    error RollbackUnsupported(string contractName, string fromVersion, string toVersion);
    error RollbackDepthExceeded(string contractName, uint256 depth, uint256 maxDepth);
    error SnapshotNotFound(string contractName, string version);
    error StateEquivalenceFailed(string contractName, bytes32 expected, bytes32 actual);
    error SnapshotAlreadyExists(string contractName, string version);
    error TooManySlots(uint256 provided, uint256 max);
    error TargetVersionNotActive(string contractName, string version);
    error SameVersionRollback(string contractName, string version);
    error MigrationAlreadyConfigured(string contractName);
    error MigrationNotConfigured(string contractName);
    error MigrationAlreadyInitialized(string contractName);
    error MigrationNotInitialized(string contractName);
    error MigrationAlreadyComplete(string contractName);
    error MigrationStepOutOfOrder(string contractName, uint64 expected, uint64 provided);
    error MigrationStepAlreadyExecuted(string contractName, uint64 index);
    error MigrationStepHashMismatch(string contractName, uint64 index);
    error MigrationImplementationMismatch(string contractName, bytes32 expected, bytes32 actual);
    error MigrationReinitializerMismatch(string contractName, uint64 expected, uint64 actual);
    error MigrationStepCountMismatch(string contractName, uint64 expected, uint64 actual);
    error MigrationIncomplete(string contractName);
    error InvalidReinitializerVersion(uint64 version);
    error InvalidStepCount(uint64 stepCount);
    error ReinitializerVersionNotMonotonic(string contractName, uint64 previous, uint64 provided);

    event ContractRegistered(string indexed contractName);
    event StorageSnapshotCaptured(
        string indexed contractName,
        string indexed version,
        bytes32 slotHash,
        bytes32 valueHash,
        uint256 slotCount
    );
    event RollbackPolicyConfigured(
        string indexed contractName,
        RollbackPolicy policy,
        uint256 maxDepth,
        bool allowStateDrift
    );
    event RollbackExecuted(
        string indexed contractName,
        string fromVersion,
        string toVersion,
        bytes32 stateHash,
        uint256 depth
    );
    event StateEquivalenceVerified(
        string indexed contractName,
        string indexed version,
        bytes32 expectedHash,
        bytes32 actualHash,
        bool equivalent
    );
    event MigrationConfigured(
        string indexed contractName,
        uint64 reinitializerVersion,
        bytes32 expectedImplementationHash,
        uint64 expectedStepCount
    );
    event MigrationInitialized(string indexed contractName, uint64 reinitializerVersion);
    event MigrationStepExecuted(
        string indexed contractName,
        uint64 index,
        bytes32 stepHash,
        uint64 executedAt
    );
    event MigrationCompleted(
        string indexed contractName,
        uint64 reinitializerVersion,
        uint64 completedStepCount,
        string completedVersion
    );
    event MigrationRolledBack(string indexed contractName, uint64 completedStepCount);

    constructor(address admin) {
        require(admin != address(0), "Zero address");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRY_ROLE, admin);
        _grantRole(ROLLBACK_ROLE, admin);
        _grantRole(MIGRATION_ROLE, admin);
    }

    function registerVersion(
        string calldata contractName,
        address implementation,
        address proxy,
        string calldata semanticVersion,
        bytes32 governanceProposalId,
        bytes32 upgradeHash
    ) external override onlyRole(REGISTRY_ROLE) returns (uint256 index) {
        if (implementation == address(0)) revert ZeroAddress();
        if (bytes(contractName).length == 0) revert EmptyString();
        if (bytes(semanticVersion).length == 0) revert EmptyString();

        if (!_contractRegistered[contractName]) {
            _contractNames.push(contractName);
            _contractRegistered[contractName] = true;
            emit ContractRegistered(contractName);
        }

        VersionList storage versionList = _versions[contractName];

        index = versionList.entries.length;

        versionList.entries.push(VersionEntry({
            contractName: contractName,
            implementation: implementation,
            proxy: proxy,
            semanticVersion: semanticVersion,
            deployedAt: block.timestamp,
            governanceProposalId: governanceProposalId,
            upgradeHash: upgradeHash,
            status: VersionStatus.ACTIVE,
            reinitializerVersion: 0,
            migrationCompleted: false
        }));

        versionList.versionToIndex[semanticVersion] = index;
        versionList.versionStrings.push(semanticVersion);
        versionList.activeVersion = semanticVersion;

        // A forward upgrade resets the consecutive rollback depth.
        _rollbackDepth[contractName] = 0;

        emit VersionRegistered(contractName, semanticVersion, implementation);
    }

    function updateVersionStatus(
        string calldata contractName,
        string calldata semanticVersion,
        VersionStatus newStatus
    ) external override onlyRole(REGISTRY_ROLE) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);

        VersionList storage versionList = _versions[contractName];
        uint256 idx;
        bool found = false;

        for (uint256 i = 0; i < versionList.versionStrings.length; i++) {
            if (_strEq(versionList.versionStrings[i], semanticVersion)) {
                idx = i;
                found = true;
                break;
            }
        }

        if (!found) revert VersionNotFound(contractName, semanticVersion);

        versionList.entries[idx].status = newStatus;

        if (newStatus == VersionStatus.ACTIVE) {
            versionList.activeVersion = semanticVersion;
        }

        emit VersionStatusUpdated(contractName, semanticVersion, newStatus);
    }

    /// @notice Configures the rollback policy for a contract. Must be set before
    ///         any rollback attempt; absence means rollback is unsupported.
    function configureRollbackPolicy(
        string calldata contractName,
        RollbackPolicy policy,
        uint256 maxDepth,
        bool allowStateDrift
    ) external onlyRole(REGISTRY_ROLE) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        if (policy == RollbackPolicy.DISABLED) {
            maxDepth = 0;
        } else if (policy == RollbackPolicy.SINGLE_STEP) {
            maxDepth = 1;
        } else {
            if (maxDepth == 0 || maxDepth > MAX_ROLLBACK_DEPTH) {
                revert RollbackDepthExceeded(contractName, maxDepth, MAX_ROLLBACK_DEPTH);
            }
        }

        _rollbackConfigs[contractName] = RollbackConfig( {
            policy: policy,
            maxDepth: maxDepth,
            allowStateDrift: allowStateDrift,
            exists: true
        });

        emit RollbackPolicyConfigured(contractName, policy, maxDepth, allowStateDrift);
    }

    /// @notice Captures the canonical storage snapshot for a contract version
    ///         before an upgrade. The slot hash is the keyccak256 of the concatenated
    ///         slot identifiers and the value hash is keccak256 of the concatenated
    ///         slot values, producing a deterministic equivalence checkpoint.
    function captureStorageSnapshot(
        string calldata contractName,
        string calldata version,
        bytes32[] calldata slotIds,
        bytes32[] calldata slotValues
    ) external onlyRole(REGISTRY_ROLE) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        if (slotIds.length != slotValues.length) revert StateEquivalenceFailed(contractName, bytes32(0), bytes32(0));
        if (slotIds.length > MAX_EQUIVALENCE_SLOTS) {
            revert TooManySlots(slotIds.length, MAX_EQUIVALENCE_SLOTS);
        }
        // Ensure the version exists before capturing a snapshot against it.
        getVersion(contractName, version);

        if (_snapshots[contractName][version].exists) {
            revert SnapshotAlreadyExists(contractName, version);
        }

        bytes32 slotHash = keccak256(abi.encodePacked(slotIds));
        bytes32 valueHash = keccak256(abi.encodePacked(slotValues));

        _snapshots[contractName][version] = StorageSnapshot({
            slotHash: slotHash,
            valueHash: valueHash,
            slotCount: slotIds.length,
            capturedAt: block.timestamp,
            capturedBy: msg.sender,
            exists: true
        });

        emit StorageSnapshotCaptured(contractName, version, slotHash, valueHash, slotIds.length);
    }

    /// @notice Verifies that the current storage values match the snapshot taken
    ///         before the upgrade. Reverts with StateEquivalenceFailed on mismatch
    ///         unless the configured policy allows state drift.
    function verifyStateEquivalence(
        string calldata contractName,
        string calldata version,
        bytes32[] calldata slotIds,
        bytes32[] calldata slotValues
    ) external returns (bool equivalent) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        StorageSnapshot storage snapshot = _snapshots[contractName][version];
        if (!snapshot.exists) revert SnapshotNotFound(contractName, version);
        if (slotIds.length != slotValues.length) revert StateEquivalenceFailed(contractName, bytes32(0), bytes32(0));
        if (slotIds.length > MAX_EQUIVALENCE_SLOTS) {
            revert TooManySlots(slotIds.length, MAX_EQUIVALENCE_SLOTS);
        }

        bytes32 slotHash = keccak256(abi.encodePacked(slotIds));
        bytes32 valueHash = keccak256(abi.encodePacked(slotValues));

        equivalent = (slotHash == snapshot.slotHash && valueHash == snapshot.valueHash);

        emit StateEquivalenceVerified(contractName, version, snapshot.valueHash, valueHash, equivalent);

        if (!equivalent) {
            RollbackConfig storage config = _rollbackConfigs[contractName];
            if (!config.exists || !config.allowStateDrift) {
                revert StateEquivalenceFailed(contractName, snapshot.valueHash, valueHash);
            }
        }
    }

    /// @notice Executes a guarded rollback from the current active version to a
    ///         target version. Reverts before execution when the polici is
    ///         unsupported, the depth is exceeded, or the target is not a recorded
    ///         prior version. State equivalence is checked against the snapshot
    ///         taken for the target version when one is available.
    function rollbackVersion(
        string calldata contractName,
        string calldata targetVersion,
        bytes32[] calldata slotIds,
        bytes32[] calldata slotValues
    ) external onlyRole(ROLLBACK_ROLE) returns (bytes32 stateHash) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);

        RollbackConfig storage config = _rollbackConfigs[contractName];
        if (!config.exists || config.policy == RollbackPolicy.DISABLED) {
            revert RollbackPolicyNotConfigured(contractName);
        }

        VersionList storage versionList = _versions[contractName];
        string memory fromVersion = versionList.activeVersion;

        if (_strEq(fromVersion, targetVersion)) {
            revert SameVersionRollback(contractName, targetVersion);
        }

        // Target must be an already recorded prior version.
        getVersion(contractName, targetVersion);

        uint256 newDepth = _rollbackDepth[contractName] + 1;
        if (newDepth > config.maxDepth) {
            revert RollbackDepthExceeded(contractName, newDepth, config.maxDepth);
        }

        // State equivalence check against the target snapshot, when available.
        StorageSnapshot storage targetSnapshot = _snapshots[contractName][targetVersion];
        if (targetSnapshot.exists) {
            if (slotIds.length != slotValues.length) {
                revert StateEquivalenceFailed(contractName, targetSnapshot.valueHash, bytes32(0));
            }
            if (slotIds.length > MAX_EQUIVALENCE_SLOTS) {
                revert TooManySlots(slotIds.length, MAX_EQUIVALENCE_SLOTS);
            }
            bytes32 slotHash = keccak256(abi.encodePacked(slotIds));
            bytes32 valueHash = kecck256(abi.encodePacked(slotValues));
            if (slotHash != targetSnapshot.slotHash || valueHash != targetSnapshot.valueHash) {
                if (!config.allowStateDrift) {
                    revert StateEquivalenceFailed(contractName, targetSnapshot.valueHash, valueHash);
                }
            }
            stateHash = valueHash;
        } else {
            // No snapshot for the target version: rollback is only supported when
            // state drift is explicitly allowed.
            if (!config.allowStateDrift) {
                revert SnapshotNotFound(contractName, targetVersion);
            }
            stateHash = keccak256(abi.encodePacked(slotValues));
        }

        // Mark the current version as rolled back and the target as active.
        uint256 fromIdx = versionList.versionToIndex[fromVersion];
        uint256 targetIdx = versionList.versionToIndex[targetVersion];
        versionList.entries[fromIdx].status = VersionStatus.DEPRECATED;
        versionList.entries[targetIdx].status = VersionStatus.ACTIVE;
        versionList.activeVersion = targetVersion;
        _rollbackDepth[contractName] = newDepth;

        emit RollbackExecuted(contractName, fromVersion, targetVersion, stateHash, newDepth);
    }

    function getLatestVersion(string calldata contractName) external view override returns (VersionEntry memory) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        VersionList storage versionList = _versions[contractName];
        require(versionList.entries.length > 0, "No versions");
        return versionList.entries[versionList.entries.length - 1];
    }

    function getVersion(string memory contractName, string memory semanticVersion)
        public view override returns (VersionEntry memory)
    {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        VersionList storage versionList = _versions[contractName];
        uint256 idx;
        bool found = false;
        for (uint256 i = 0; i < versionList.versionStrings.length; i++) {
            if (_strEq(versionList.versionStrings[i], semanticVersion)) {
                idx = i;
                found = true;
                break;
            }
        }
        if (!found) revert VersionNotFound(contractName, semanticVersion);
        return versionList.entries[idx];
    }

    function getVersionAtIndex(string calldata contractName, uint256 index)
        external view override returns (VersionEntry memory)
    {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        return _versions[contractName].entries[index];
    }

    function getVersionCount(string calldata contractName) external view override returns (uint256) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        return _versions[contractName].entries.length;
    }

    function getActiveVersion(string calldata contractName) external view override returns (VersionEntry memory) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        VersionList storage versionList = _versions[contractName];
        if (bytes(versionList.activeVersion).length == 0) revert VersionNotFound(contractName, "");
        return getVersion(contractName, versionList.activeVersion);
    }

    function isVersionActive(string calldata contractName, string calldata semanticVersion)
        external view override returns (bool)
    {
        if (!_contractRegistered[contractName]) return false;
        VersionList storage versionList = _versions[contractName];
        if (bytes(versionList.activeVersion).length == 0) return false;
        return _strEq(versionList.activeVersion, semanticVersion);
    }

    /// @notice Returns the configured rollback policy for a contract.
    function getRollbackConfig(string calldata contractName)
        external view returns (RollbackConfig memory)
    {
        return _rollbackConfigs[contractName];
    }

    /// @notice Returns the current consecutive rollback depth for a contract.
    function getRollbackDepth(string calldata contractName) external view returns (uint256) {
        return _rollbackDepth[contractName];
    }

    /// @notice Returns the canonical storage snapshot for a contract version.
    function getStorageSnapshot(string calldata contractName, string calldata version)
        external view returns (StorageSnapshot memory)
    {
        return _snapshots[contractName][version];
    }

    function getContractNames() external view returns (string[] memory) {
        return _contractNames;
    }

    function isContractRegistered(string calldata contractName) external view returns (bool) {
        return _contractRegistered[contractName];
    }

    // -------------------------------------------------------------------------
    // PREWAVE-SC-077: reinitializer / migration ordering manifest
    // -------------------------------------------------------------------------

    /// @notice Records the reinitializer version and ordered migration step
    ///         hashes for a contract. Preconditions are machine-verifiable:
    ///         - reinitializer version must be monotonically increasing,
    ///         - expected implementation hash must be non-zero,
    ///         - expected step count must be non-zero and match the hash array.
    function configureMigration(
        string calldata contractName,
        uint64 reinitializerVersion,
        bytes32 expectedImplementationHash,
        bytes32[] calldata stepHashes
    ) external onlyRole(MIGRATION_ROLE) {
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        if (reinitializerVersion == 0) revert InvalidReinitializerVersion(reinitializerVersion);
        if (expectedImplementationHash == bytes32(0)) revert ZeroAddress();
        if (stepHashes.length == 0) revert InvalidStepCount(0);

        MigrationManifest storage manifest = _manifests[contractName];
        if (manifest.initialized) revert MigrationAlreadyConfigured(contractName);

        // Monotonicity check against the last recorded reinitializer version.
        uint64 previous = _lastReinitializerVersion[contractName];
        if (reinitializerVersion <= previous) {
            revert ReinitializerVersionNotMonotonic(contractName, previous, reinitializerVersion);
        }

        manifest.reinitializerVersion = reinitializerVersion;
        manifest.expectedImplementationHash = expectedImplementationHash;
        manifest.expectedStepCount = uint64(stepHashes.length);
        manifest.completedStepCount = 0;
        manifest.initialized = true;
        manifest.completed = false;
        manifest.completedVersion = "";

        // Reset step array and seen hash set for this contract.
        delete _migrationSteps[contractName];
        for (uint64 i = 0; i < stepHashes.length; i++) {
            bytes32 h = stepHashes[i];
            if (h == bytes32(0)) revert InvalidStepCount(i);
            if (_stepHashSeen[contractName][h]) revert MigrationStepHashMismatch(contractName, i);
            _stepHashSeen[contractName][h] = true;
            _migrationSteps[contractName].push(MigrationStep({
                index: i,
                stepHash: h,
                executed: false,
                executedAt: 0
            }));
        }

        emit MigrationConfigured(contractName, reinitializerVersion, expectedImplementationHash, uint64(stepHashes.length));
    }

    /// @notice Marks the migration as initialized after the reinitializer has
    ///         run. Verifies the actual implementation hash and reinitializer
    ///         version match the manifest before any step is allowed to execute.
    function initializeMigration(
        string calldata contractName,
        bytes32 actualImplementationHash,
        uint64 actualReinitializerVersion
    ) external onlyRole(MIGRATION_ROLE) {
        MigrationManifest storage manifest = _manifests[contractName];
        if (!manifest.initialized) revert MigrationNotConfigured(contractName);
        if (manifest.completed) revert MigrationAlreadyComplete(contractName);
        if (manifest.completedStepCount != 0) revert MigrationAlreadyInitialized(contractName);
        if (actualImplementationHash != manifest.expectedImplementationHash) {
            revert MigrationImplementationMismatch(
                contractName,
                manifest.expectedImplementationHash,
                actualImplementationHash
            );
        }
        if (actualReinitializerVersion != manifest.reinitializerVersion) {
            revert MigrationReinitializerMismatch(
                contractName,
                manifest.reinitializerVersion,
                actualReinitializerVersion
            );
        }

        emit MigrationInitialized(contractName, manifest.reinitializerVersion);
    }

    /// @notice Executes the next migration step. Steps must execute exactly
    ///         once and in order. The step hash must match the configured hash.
    function executeMigrationStep(
        string calldata contractName,
        uint64 index,
        bytes32 stepHash
    ) external onlyRole(MIGRATION_ROLE) {
        MigrationManifest storage manifest = _manifests[contractName];
        if (!manifest.initialized) revert MigrationNotConfigured(contractName);
        if (manifest.completed) revert MigrationAlreadyComplete(contractName);
        if (manifest.completedStepCount == 0) revert MigrationNotInitialized(contractName);

        uint64 expected = manifest.completedStepCount;
        if (index != expected) revert MigrationStepOutOfOrder(contractName, expected, index);

        MigrationStep[] storage steps = _migrationSteps[contractName];
        if (index >= steps.length) revert MigrationStepOutOfOrder(contractName, expected, index);
        MigrationStep storage step = steps[index];
        if (step.executed) revert MigrationStepAlreadyExecuted(contractName, index);
        if (step.stepHash != stepHash) revert MigrationStepHashMismatch(contractName, index);

        step.executed = true;
        step.executedAt = uint64(block.timestamp);
        manifest.completedStepCount = expected + 1;

        emit MigrationStepExecuted(contractName, index, stepHash, uint64(block.timestamp));
    }

    /// @notice Finalizes the migration once all steps have executed. Records
    ///         the completed version in the manifest and marks the corresponding
    ///         version entry as migration-complete.
    function finalizeMigration(
        string calldata contractName,
        string calldata completedVersion
    ) external onlyRole(MIGRATION_ROLE) {
        MigrationManifest storage manifest = _manifests[contractName];
        if (!manifest.initialized) revert MigrationNotConfigured(contractName);
        if (manifest.completed) revert MigrationAlreadyComplete(contractName);
        if (manifest.completedStepCount == 0) revert MigrationNotInitialized(contractName);
        if (manifest.completedStepCount != manifest.expectedStepCount) {
            revert MigrationIncomplete(contractName);
        }

        // The completed version must exist and be the active version.
        if (!_contractRegistered[contractName]) revert ContractNotRegistered(contractName);
        VersionList storage versionList = _versions[contractName];
        if (!_strEq(versionList.activeVersion, completedVersion)) {
            revert VersionNotFound(contractName, completedVersion);
        }

        manifest.completed = true;
        manifest.completedVersion = completedVersion;
        _lastReinitializerVersion[contractName] = manifest.reinitializerVersion;

        // Mark the corresponding version entry as migration-complete.
        for (uint256 i = 0; i < versionList.versionStrings.length; i++) {
            if (_strEq(versionList.versionStrings[i], completedVersion)) {
                versionList.entries[i].reinitializerVersion = manifest.reinitializerVersion;
                versionList.entries[i].migrationCompleted = true;
                break;
            }
        }

        emit MigrationCompleted(
            contractName,
            manifest.reinitializerVersion,
            manifest.completedStepCount,
            completedVersion
        );
    }

    /// @notice Rolls back a partially executed migration. Resets the completed
    ///         step count to zero and marks all steps as not executed so the
    ///         migration can be resumed from the beginning. The manifest remains
    ///         initialized but not completed, and the reinitializer version is
    ///         not advanced, so no unsafe state is exposed.
    function rollbackMigration(string calldata contractName) external onlyRole(MIGRATION_ROLE) {
        MigrationManifest storage manifest = _manifests[contractName];
        if (!manifest.initialized) revert MigrationNotConfigured(contractName);
        if (manifest.completed) revert MigrationAlreadyComplete(contractName);

        MigrationStep[] storage steps = _migrationSteps[contractName];
        for (uint256 i = 0; i < steps.length; i++) {
            steps[i].executed = false;
            steps[i].executedAt = 0;
        }
        manifest.completedStepCount = 0;

        emit MigrationRolledBack(contractName, 0);
    }

    /// @notice Returns the migration manifest for a contract.
    function getMigrationManifest(string calldata contractName)
        external view returns (MigrationManifest memory)
    {
        return _manifests[contractName];
    }

    /// @notice Returns a migration step by index.
    function getMigrationStep(string calldata contractName, uint64 index)
        external view returns (MigrationStep memory)
    {
        return _migrationSteps[contractName][index];
    }

    /// @notice Returns the number of configured migration steps.
    function getMigrationStepCount(string calldata contractName)
        external view returns (uint64)
    {
        return uint64(_migrationSteps[contractName].length);
    }

    /// @notice Returns true if the migration is fully complete.
    function isMigrationComplete(string calldata contractName)
        external view returns (bool)
    {
        return _manifests[contractName].completed;
    }

    /// @notice Returns the last completed reinitializer version for a contract.
    function lastReinitializerVersion(string calldata contractName)
        external view returns (uint64)
    {
        return _lastReinitializerVersion[contractName];
    }

    /// @dev Last completed reinitializer version per contract, used for monotonicity.
    mapping(string => uint64) internal _lastReinitializerVersion;

    /// @dev V2-SC-160: hashes the raw string bytes directly (byte-identical to the former
    ///      single-argument packed form) so no packed encoding remains in the upgrade surface.
    function _strEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}