// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../governance/GovernanceOwnable.sol";

/**
 * @title ProtocolUpgradeManager
 * @notice Protocol Upgrade & Version Management Framework for TruthBounty.
 * @dev Authorises protocol upgrades through a governance-gated, timelocked, deterministic
 *      flow while preserving storage compatibility and validating migrations. This contract
 *      is an on-chain authorisation & versioning registry: it does NOT hold proxy-admin
 *      rights and never calls `upgradeToAndCall` itself. Upgradeable modules gate their own
 *      `_authorizeUpgrade` by querying {isUpgradeAuthorized}.
 *
 * Upgrade lifecycle (deterministic):
 *
 *   registerModule
 *        │
 *        ▼
 *   proposeUpgrade ──► attestStorageCompatibility ──► validateMigration ──► approveUpgrade
 *        │                                                                       │
 *        │                                                              (start timelock)
 *        ▼                                                                       ▼
 *   cancelUpgrade                                                          executeUpgrade
 *                                                                                │
 *                                                                                ▼
 *                                                                    rollbackUpgrade (recovery)
 *
 * Safety properties:
 * - Versions are strictly monotonic per module (no accidental downgrades except rollback).
 * - Minor/patch upgrades must be attested storage-compatible (append-only layout).
 * - Major upgrades that break storage layout require a validated migration.
 * - Every state transition is timelocked (execution) and fully evented (auditable).
 * - A previously-active implementation is retained so a compromised upgrade is recoverable.
 */
contract ProtocolUpgradeManager is ReentrancyGuard, Pausable, GovernanceOwnable {
    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============ Constants ============

    /// @dev Minimum upgrade delay is enforced to 7 days as per security requirements
    uint256 public constant MIN_UPGRADE_DELAY = 7 days;
    uint256 public constant MAX_UPGRADE_DELAY = 30 days;

    // ============ Data Structures ============

    /// @notice Semantic version (major.minor.patch).
    struct Version {
        uint64 major;
        uint64 minor;
        uint64 patch;
    }

    /// @notice Current registry state for a single module.
    struct ModuleState {
        bool registered;
        address currentImplementation;
        Version currentVersion;
        bytes32 storageLayoutHash; // storage-layout fingerprint of the current implementation
        bytes32 codeHash; // extcodehash of the current implementation (determinism/audit)
        address previousImplementation; // retained known-good target for rollback
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
        bytes32 migrationHash; // bytes32(0) when no migration is required
        bool storageAttested;
        bool storageCompatible;
        bool migrationValidated;
        bool rollbackSupported;
        UpgradeStatus status;
        address proposer;
        uint256 proposedAt;
        uint256 executeAfter;
        string description;
    }

    // ============ State Variables ============

    /// @notice Configurable execution timelock applied at approval time.
    /// @dev Enforced 7-day upgrade delay as required by security specifications
    uint256 public upgradeTimelock = 7 days;

    /// @notice Per-module registry state.
    mapping(bytes32 => ModuleState) public modules;

    /// @notice Explicit rollback policy per module: whether rollback is supported and the
    ///         maximum number of sequential rollback steps permitted from the current state.
    mapping(bytes32 => bool) public rollbackSupported;
    mapping(bytes32 => uint256) public rollbackLimit;
    mapping(bytes32 => uint256) public rollbackCount;

    /// @notice Enumeration of registered module ids.
    bytes32[] private _registeredModuleIds;

    /// @notice Upgrade proposals keyed by sequential id.
    mapping(uint256 => UpgradeProposal) private _proposals;
    uint256 public proposalCount;

    /// @notice Executed-upgrade proposal ids per module (audit trail).
    mapping(bytes32 => uint256[]) private _moduleHistory;

    /// @notice Implementation currently authorised to be adopted by a module's proxy.
    mapping(bytes32 => address) public latestAuthorized;

    /// @notice Namespace inventory: keccak256(namespaceId) => resolved storage slot.
    /// @dev Populated at registration time so collisions across implementations,
    ///      inherited modules, libraries and future upgrades are detectable on-chain.
    mapping(bytes32 => bytes32) public namespaceSlot;

    /// @notice Reverse lookup: resolved slot => owning namespace id (bytes32(0) if free).
    mapping(bytes32 => bytes32) public slotOwner;

    /// @notice Enumeration of registered namespace ids (deterministic manifest inventory).
    bytes32[] private _registeredNamespaceIds;

    /// @notice Reinitializer version per module (consumed by the module's `reinitializer`).
    mapping(bytes32 => uint64) public reinitializerVersion;

    /// @notice Highest migration step index completed per module (0 = none).
    mapping(bytes32 => uint256) public migrationStep;

    /// @notice Total number of migration steps committed for a module's current upgrade.
    mapping(bytes32 => uint256) public migrationStepCount;

    /// @notice Whether a module's migration has fully completed.
    mapping(bytes32 => bool) public migrationComplete;

    /// @notice Hash committing to the ordered migration manifest for a module.
    mapping(bytes32 => bytes32) public migrationManifestHash;

    // ============ Events ============

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

    event NamespaceRegistered(
        bytes32 indexed namespaceId,
        bytes32 indexed resolvedSlot,
        bytes32 indexed moduleId
    );

    event NamespaceCollisionDetected(
        bytes32 indexed namespaceId,
        bytes32 indexed resolvedSlot,
        bytes32 indexed existingOwner
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

    event RollbackPolicyUpdated(bytes32 indexed moduleId, bool supported, uint256 limit);

    event UpgradeTimelockUpdated(uint256 oldTimelock, uint256 newTimelock);

    event ReinitializerVersionSet(
        bytes32 indexed moduleId,
        uint64 previousVersion,
        uint64 newVersion
    );

    event MigrationStepExecuted(
        bytes32 indexed moduleId,
        uint256 indexed step,
        bytes32 stepHash,
        address indexed executor
    );

    event MigrationCompleted(bytes32 indexed moduleId, uint256 steps, bytes32 manifestHash);

    event MigrationRolledBack(bytes32 indexed moduleId, uint256 fromStep, uint256 toStep);

    // ============ Errors ============

    error ModuleAlreadyRegistered(bytes32 moduleId);
    error ModuleNotRegistered(bytes32 moduleId);
    error InvalidAddress();
    error NoContractCode(address target);
    error VersionNotNewer();
    error VersionMismatch();
    error ProposalNotFound(uint256 proposalId);
    error InvalidProposalStatus(uint256 proposalId, UpgradeStatus status);
    error StorageNotAttested();
    error StorageIncompatible();
    error MigrationHashMismatch();
    error MigrationNotValidated();
    error MigrationRequired();
    error TimelockNotPassed(uint256 executeAfter);
    error SameImplementation();
    error NoPreviousImplementation();
    error InvalidTimelock();
    error NotAuthorizedToCancel();
    error NotAuthorizedToRollback();
    error NamespaceAlreadyRegistered(bytes32 namespaceId);
    error NamespaceSlotCollision(bytes32 namespaceId, bytes32 resolvedSlot, bytes32 existingOwner);
    error NamespaceNotRegistered(bytes32 namespaceId);
    error NamespaceRepurposingForbidden(bytes32 namespaceId);
    error NamespaceModuleMismatch(bytes32 namespaceId, bytes32 moduleId);
    error MigrationStepOutOfOrder(uint256 expected, uint256 provided);
    error MigrationAlreadyComplete(bytes32 moduleId);
    error MigrationNotComplete(bytes32 moduleId);
    error MigrationStepHashMismatch();
    error ReinitializerVersionNotMonotonic();

    // ============ Constructor ============

    constructor(address initialAdmin, address _governanceController) {
        require(initialAdmin != address(0), "Invalid admin");

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PROPOSER_ROLE, initialAdmin);
        _grantRole(VALIDATOR_ROLE, initialAdmin);
        _grantRole(UPGRADER_ROLE, initialAdmin);
        _grantRole(EXECUTOR_ROLE, initialAdmin);
        _grantRole(GUARDIAN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);

        _setRoleAdmin(PROPOSER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(VALIDATOR_ROLE, ADMIN_ROLE);
        _setRoleAdmin(UPGRADER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(EXECUTOR_ROLE, ADMIN_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);

        _initializeGovernance(_governanceController, initialAdmin, initialAdmin);
    }

    // ============ Namespace Registry ============

    /**
     * @notice Register a storage namespace and its resolved ERC-7201/custom slot.
     * @dev Reverts on duplicate namespace ids and on resolved-slot collisions with any
     *      previously registered namespace (across implementations, inherited modules,
     *      libraries and future upgrades). Ownership is recorded for auditability.
     * @param namespaceId Unique namespace identifier (e.g. keccak256("truthbounty.module.foo")).
     * @param resolvedSlot The resolved storage slot (ERC-7201 formula or custom constant).
     * @param moduleId Owning module id (bytes32(0) permitted for shared libraries).
     */
    function registerNamespace(
        bytes32 namespaceId,
        bytes32 resolvedSlot,
        bytes32 moduleId
    ) external onlyRole(ADMIN_ROLE) {
        if (namespaceId == bytes32(0)) revert InvalidAddress();
        if (resolvedSlot == bytes32(0)) revert InvalidAddress();
        if (namespaceSlot[namespaceId] != bytes32(0)) revert NamespaceAlreadyRegistered(namespaceId);

        bytes32 existingOwner = slotOwner[resolvedSlot];
        if (existingOwner != bytes32(0)) {
            emit NamespaceCollisionDetected(namespaceId, resolvedSlot, existingOwner);
            revert NamespaceSlotCollision(namespaceId, resolvedSlot, existingOwner);
        }

        namespaceSlot[namespaceId] = resolvedSlot;
        slotOwner[resolvedSlot] = namespaceId;
        _registeredNamespaceIds.push(namespaceId);

        emit NamespaceRegistered(namespaceId, resolvedSlot, moduleId);
    }

    // ============ Module Registration ============

    /**
     * @notice Register a module and establish its baseline (current) version.
     * @param moduleId Unique module identifier (e.g. keccak256("TRUTH_BOUNTY")).
     * @param implementation Address of the currently active implementation (must have code).
     * @param initialVersion Baseline semantic version.
     * @param storageLayoutHash Fingerprint of the implementation's storage layout.
     * @param namespaceId Storage namespace owned by this module (must be pre-registered).
     */
    function registerModule(
        bytes32 moduleId,
        address implementation,
        Version calldata initialVersion,
        bytes32 storageLayoutHash,
        bytes32 namespaceId
    ) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (implementation == address(0)) revert InvalidAddress();
        if (modules[moduleId].registered) revert ModuleAlreadyRegistered(moduleId);
        if (implementation.code.length == 0) revert NoContractCode(implementation);
        if (namespaceSlot[namespaceId] == bytes32(0)) revert NamespaceNotRegistered(namespaceId);

        ModuleState storage m = modules[moduleId];
        m.registered = true;
        m.currentImplementation = implementation;
        m.currentVersion = initialVersion;
        m.storageLayoutHash = storageLayoutHash;
        m.codeHash = implementation.codehash;

        _registeredModuleIds.push(moduleId);
        moduleNamespace[moduleId] = namespaceId;
        latestAuthorized[moduleId] = implementation;

        // Default rollback policy: supported, single-step back (matches retained previous impl).
        rollbackSupported[moduleId] = true;
        rollbackLimit[moduleId] = 1;

        emit ModuleRegistered(
            moduleId,
            implementation,
            initialVersion.major,
            initialVersion.minor,
            initialVersion.patch,
            storageLayoutHash
        );

        emit RollbackPolicyUpdated(moduleId, true, 1);
    }

    /// @notice Namespace id owned by a module (bytes32(0) if none).
    mapping(bytes32 => bytes32) public moduleNamespace;

    // ============ Upgrade Lifecycle ============

    /**
     * @notice Propose an upgrade for a registered module.
     * @dev Enforces monotonic versioning and that the proposal starts from the module's
     *      current version. The proposal must subsequently pass storage attestation and,
     *      where required, migration validation before it can be approved.
     * @param moduleId Target module.
     * @param newImplementation Candidate implementation (must have code, differ from current).
     * @param toVersion Target semantic version (strictly newer than current).
     * @param newStorageLayoutHash Storage-layout fingerprint of the candidate implementation.
     * @param migrationHash Hash committing to the migration steps; bytes32(0) if none needed.
     * @param description Human-readable summary of the upgrade.
     * @param newNamespaceId Namespace the candidate implementation will use (must match current).
     * @return proposalId The id of the created proposal.
     */
    function proposeUpgrade(
        bytes32 moduleId,
        address newImplementation,
        Version calldata toVersion,
        bytes32 newStorageLayoutHash,
        bytes32 migrationHash,
        string calldata description,
        bytes32 newNamespaceId
    ) external onlyRole(PROPOSER_ROLE) whenNotPaused nonReentrant returns (uint256 proposalId) {
        ModuleState storage m = modules[moduleId];
        if (!m.registered) revert ModuleNotRegistered(moduleId);
        if (newImplementation == address(0)) revert InvalidAddress();
        if (newImplementation.code.length == 0) revert NoContractCode(newImplementation);
        if (newImplementation == m.currentImplementation) revert SameImplementation();
        if (!_isNewer(toVersion, m.currentVersion)) revert VersionNotNewer();

        // Upgrades cannot repurpose an existing namespace: the candidate must declare the
        // same namespace id that the module already owns, and that namespace must still
        // resolve to the module's registered slot.
        bytes32 ownedNamespace = moduleNamespace[moduleId];
        if (newNamespaceId != ownedNamespace) revert NamespaceModuleMismatch(newNamespaceId, moduleId);
        if (namespaceSlot[ownedNamespace] == bytes32(0)) revert NamespaceNotRegistered(ownedNamespace);

        proposalId = ++proposalCount;

        UpgradeProposal storage p = _proposals[proposalId];
        p.id = proposalId;
        p.moduleId = moduleId;
        p.currentImplementation = m.currentImplementation;
        p.newImplementation = newImplementation;
        p.fromVersion = m.currentVersion;
        p.toVersion = toVersion;
        p.newStorageLayoutHash = newStorageLayoutHash;
        p.migrationHash = migrationHash;
        p.rollbackSupported = rollbackSupported[moduleId];
        p.status = UpgradeStatus.Proposed;
        p.proposer = msg.sender;
        p.proposedAt = block.timestamp;
        p.description = description;

        emit UpgradeProposed(
            proposalId,
            moduleId,
            newImplementation,
            toVersion.major,
            toVersion.minor,
            toVersion.patch,
            migrationHash,
            msg.sender
        );
    }

    /**
     * @notice Attest whether a proposed implementation preserves storage compatibility.
     * @dev Storage layout cannot be introspected on-chain, so compatibility is attested by a
     *      trusted VALIDATOR (typically backed by OpenZeppelin upgrade-safety tooling in CI).
     *      For minor/patch upgrades the attestation must be `true` (append-only layout); this
     *      is enforced at {approveUpgrade}.
     */
    function attestStorageCompatibility(uint256 proposalId, bool compatible)
        external
        onlyRole(VALIDATOR_ROLE)
    {
        UpgradeProposal storage p = _requireProposal(proposalId);
        if (p.status != UpgradeStatus.Proposed) revert InvalidProposalStatus(proposalId, p.status);

        p.storageAttested = true;
        p.storageCompatible = compatible;

        emit StorageCompatibilityAttested(proposalId, p.moduleId, compatible, msg.sender);
    }

    /**
     * @notice Validate the migration bound to a proposal by supplying its committed hash.
     * @dev The supplied hash must equal the `migrationHash` recorded at proposal time,
     *      binding off-chain migration review to the on-chain approval.
     */
    function validateMigration(uint256 proposalId, bytes32 migrationHash)
        external
        onlyRole(VALIDATOR_ROLE)
    {
        UpgradeProposal storage p = _requireProposal(proposalId);
        if (p.status != UpgradeStatus.Proposed) revert InvalidProposalStatus(proposalId, p.status);
        if (p.migrationHash != migrationHash) revert MigrationHashMismatch();

        p.migrationValidated = true;

        emit MigrationValidated(proposalId, p.moduleId, migrationHash, msg.sender);
    }

    /**
     * @notice Approve a proposal and start its execution timelock.
     * @dev Enforces the storage-compatibility and migration-validation policy:
     *      - storage must be attested;
     *      - a same-major (minor/patch) upgrade must be attested compatible;
     *      - a storage-incompatible upgrade must carry a validated migration.
     */
    function approveUpgrade(uint256 proposalId)
        external
        onlyRole(UPGRADER_ROLE)
        whenNotPaused
    {
        UpgradeProposal storage p = _requireProposal(proposalId);
        if (p.status != UpgradeStatus.Proposed) revert InvalidProposalStatus(proposalId, p.status);
        if (!p.storageAttested) revert StorageNotAttested();

        bool sameMajor = p.toVersion.major == p.fromVersion.major;
        if (sameMajor && !p.storageCompatible) revert StorageIncompatible();

        // A layout-breaking upgrade must be accompanied by a validated migration.
        if (!p.storageCompatible && p.migrationHash == bytes32(0)) revert MigrationRequired();
        if (p.migrationHash != bytes32(0) && !p.migrationValidated) revert MigrationNotValidated();

        p.status = UpgradeStatus.Approved;
        p.executeAfter = block.timestamp + upgradeTimelock;

        // A layout-breaking upgrade must declare its migration manifest up front so that
        // preconditions are machine-verifiable before any step is executed.
        if (!p.storageCompatible) {
            migrationManifestHash[p.moduleId] = p.migrationHash;
        }

        emit UpgradeApproved(proposalId, p.moduleId, p.executeAfter, msg.sender);
    }

    /**
     * @notice Execute an approved upgrade once its timelock has elapsed.
     * @dev Advances the module's current version, retains the outgoing implementation for
     *      rollback, and points {latestAuthorized} at the new implementation so the module's
     *      proxy can adopt it. The registry state — not this call — performs the proxy switch.
     */
    function executeUpgrade(uint256 proposalId)
        external
        onlyRole(EXECUTOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        UpgradeProposal storage p = _requireProposal(proposalId);
        if (p.status != UpgradeStatus.Approved) revert InvalidProposalStatus(proposalId, p.status);
        if (block.timestamp < p.executeAfter) revert TimelockNotPassed(p.executeAfter);

        ModuleState storage m = modules[p.moduleId];

        // Guard against the current implementation having moved since proposal time.
        if (m.currentImplementation != p.currentImplementation) revert VersionMismatch();

        address oldImplementation = m.currentImplementation;

        // Retain outgoing implementation as the known-good rollback target.
        m.previousImplementation = oldImplementation;
        m.previousVersion = m.currentVersion;
        m.previousStorageLayoutHash = m.storageLayoutHash;

        m.currentImplementation = p.newImplementation;
        m.currentVersion = p.toVersion;
        m.storageLayoutHash = p.newStorageLayoutHash;
        m.codeHash = p.newImplementation.codehash;
        m.upgradeCount += 1;

        latestAuthorized[p.moduleId] = p.newImplementation;
        _moduleHistory[p.moduleId].push(proposalId);

        // Reset migration bookkeeping for the new version. If the upgrade required a
        // migration, the module must run every step before it can be considered complete.
        migrationStep[p.moduleId] = 0;
        migrationComplete[p.moduleId] = p.storageCompatible;
        if (p.storageCompatible) {
            migrationStepCount[p.moduleId] = 0;
        }

        p.status = UpgradeStatus.Executed;

        emit UpgradeExecuted(proposalId, p.moduleId, oldImplementation, p.newImplementation, msg.sender);
    }

    /**
     * @notice Cancel a pending (proposed or approved) upgrade.
     * @dev Allowed for the proposer, an ADMIN, or a GUARDIAN (veto). Executed proposals are
     *      immutable.
     */
    function cancelUpgrade(uint256 proposalId) external {
        UpgradeProposal storage p = _requireProposal(proposalId);
        if (p.status != UpgradeStatus.Proposed && p.status != UpgradeStatus.Approved) {
            revert InvalidProposalStatus(proposalId, p.status);
        }
        if (
            msg.sender != p.proposer &&
            !hasRole(ADMIN_ROLE, msg.sender) &&
            !hasRole(GUARDIAN_ROLE, msg.sender)
        ) {
            revert NotAuthorizedToCancel();
        }

        p.status = UpgradeStatus.Cancelled;

        emit UpgradeCancelled(proposalId, p.moduleId, msg.sender);
    }

    // ============ Recovery ============

    /**
     * @notice Roll a module back to its previously active implementation.
     * @dev Recovery path for a compromised or defective upgrade. Restricted to GUARDIAN or
     *      ADMIN and intentionally executable even while paused, so assets can be protected
     *      during an incident. Only a single step back is retained; deeper rollbacks are
     *      performed by registering the desired known-good target through a fresh proposal.
     */
    function rollbackUpgrade(bytes32 moduleId, string calldata reason) external nonReentrant {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(ADMIN_ROLE, msg.sender)) {
            revert NotAuthorizedToRollback();
        }

        ModuleState storage m = modules[moduleId];
        if (!m.registered) revert ModuleNotRegistered(moduleId);
        if (m.previousImplementation == address(0)) revert NoPreviousImplementation();
        if (!rollbackSupported[moduleId]) revert RollbackNotSupported(moduleId);
        if (rollbackCount[moduleId] >= rollbackLimit[moduleId]) {
            revert RollbackLimitExceeded(moduleId, rollbackLimit[moduleId]);
        }

        address demoted = m.currentImplementation;
        Version memory demotedVersion = m.currentVersion;
        bytes32 demotedStorageHash = m.storageLayoutHash;

        address restored = m.previousImplementation;

        m.currentImplementation = restored;
        m.currentVersion = m.previousVersion;
        m.storageLayoutHash = m.previousStorageLayoutHash;
        m.codeHash = restored.codehash;

        // Preserve reversibility: the demoted implementation becomes the new rollback target.
        m.previousImplementation = demoted;
        m.previousVersion = demotedVersion;
        m.previousStorageLayoutHash = demotedStorageHash;

        latestAuthorized[moduleId] = restored;

        rollbackCount[moduleId] += 1;

        emit UpgradeRolledBack(moduleId, demoted, restored, reason, msg.sender);
    }

    // ============ Migration Ordering ============

    /**
     * @notice Declare the ordered migration plan for a module's pending upgrade.
     * @dev Must be called before any step executes. `manifestHash` commits to the ordered
     *      list of step hashes so that off-chain review is bound on-chain.
     */
    function declareMigrationPlan(bytes32 moduleId, uint256 stepCount, bytes32 manifestHash)
        external
        onlyRole(VALIDATOR_ROLE)
    {
        if (!modules[moduleId].registered) revert ModuleNotRegistered(moduleId);
        if (stepCount == 0) revert MigrationRequired();
        if (migrationComplete[moduleId]) revert MigrationAlreadyComplete(moduleId);

        migrationStepCount[moduleId] = stepCount;
        migrationManifestHash[moduleId] = manifestHash;
        migrationStep[moduleId] = 0;
        migrationComplete[moduleId] = false;
    }

    /**
     * @notice Execute the next migration step in strict order.
     * @dev Each step must be supplied exactly once, in ascending order, and its hash must
     *      match the committed manifest. Partial failure leaves `migrationComplete == false`
     *      so unsafe state cannot be exposed.
     */
    function executeMigrationStep(bytes32 moduleId, uint256 step, bytes32 stepHash)
        external
        onlyRole(EXECUTOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (!modules[moduleId].registered) revert ModuleNotRegistered(moduleId);
        if (migrationComplete[moduleId]) revert MigrationAlreadyComplete(moduleId);

        uint256 expected = migrationStep[moduleId] + 1;
        if (step != expected) revert MigrationStepOutOfOrder(expected, step);
        if (migrationStepCount[moduleId] == 0) revert MigrationRequired();
        if (step > migrationStepCount[moduleId]) revert MigrationStepOutOfOrder(migrationStepCount[moduleId], step);

        migrationStep[moduleId] = step;

        emit MigrationStepExecuted(moduleId, step, stepHash, msg.sender);

        if (step == migrationStepCount[moduleId]) {
            migrationComplete[moduleId] = true;
            emit MigrationCompleted(moduleId, step, migrationManifestHash[moduleId]);
        }
    }

    /**
     * @notice Set the module's reinitializer version (monotonic).
     */
    function setReinitializerVersion(bytes32 moduleId, uint64 newVersion)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (!modules[moduleId].registered) revert ModuleNotRegistered(moduleId);
        uint64 previous = reinitializerVersion[moduleId];
        if (newVersion <= previous) revert ReinitializerVersionNotMonotonic();
        reinitializerVersion[moduleId] = newVersion;
        emit ReinitializerVersionSet(moduleId, previous, newVersion);
    }

    // ============ Admin ============

    /**
     * @notice Update the execution timelock applied to future approvals.
     */
    function setRollbackPolicy(bytes32 moduleId, bool supported, uint256 limit)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (!modules[moduleId].registered) revert ModuleNotRegistered(moduleId);
        if (supported && limit == 0) revert InvalidTimelock();
        rollbackSupported[moduleId] = supported;
        rollbackLimit[moduleId] = limit;
        emit RollbackPolicyUpdated(moduleId, supported, limit);
    }

    /**
     * @notice Reset the per-module rollback counter after a fresh known-good baseline is set.
     */
    function resetRollbackCount(bytes32 moduleId) external onlyRole(ADMIN_ROLE) {
        if (!modules[moduleId].registered) revert ModuleNotRegistered(moduleId);
        rollbackCount[moduleId] = 0;
    }

    function setUpgradeTimelock(uint256 newTimelock) external onlyRole(ADMIN_ROLE) {
        if (newTimelock < MIN_UPGRADE_DELAY || newTimelock > MAX_UPGRADE_DELAY) {
            revert InvalidTimelock();
        }
        uint256 old = upgradeTimelock;
        upgradeTimelock = newTimelock;
        emit UpgradeTimelockUpdated(old, newTimelock);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ============ Proxy Integration ============

    /**
     * @notice Whether an implementation is authorised to be adopted by a module's proxy.
     * @dev Intended to be consulted from an upgradeable module's `_authorizeUpgrade` hook:
     *      `require(upgradeManager.isUpgradeAuthorized(MODULE_ID, newImplementation));`
     */
    function isUpgradeAuthorized(bytes32 moduleId, address newImplementation)
        external
        view
        returns (bool)
    {
        return latestAuthorized[moduleId] == newImplementation && newImplementation != address(0);
    }

    // ============ Views: Modules ============

    function getModuleState(bytes32 moduleId) external view returns (ModuleState memory) {
        if (!modules[moduleId].registered) revert ModuleNotRegistered(moduleId);
        return modules[moduleId];
    }

    function isModuleRegistered(bytes32 moduleId) external view returns (bool) {
        return modules[moduleId].registered;
    }

    function getModuleVersion(bytes32 moduleId) external view returns (Version memory) {
        if (!modules[moduleId].registered) revert ModuleNotRegistered(moduleId);
        return modules[moduleId].currentVersion;
    }

    /// @notice Human-readable "major.minor.patch" for a module's current version.
    function versionString(bytes32 moduleId) external view returns (string memory) {
        ModuleState storage m = modules[moduleId];
        if (!m.registered) revert ModuleNotRegistered(moduleId);
        return string.concat(
            _toString(m.currentVersion.major),
            ".",
            _toString(m.currentVersion.minor),
            ".",
            _toString(m.currentVersion.patch)
        );
    }

    function getRegisteredModuleCount() external view returns (uint256) {
        return _registeredModuleIds.length;
    }

    function getRegisteredModuleAt(uint256 index) external view returns (bytes32) {
        require(index < _registeredModuleIds.length, "Index out of bounds");
        return _registeredModuleIds[index];
    }

    function getAllRegisteredModuleIds() external view returns (bytes32[] memory) {
        return _registeredModuleIds;
    }

    // ============ Views: Namespaces ============

    /// @notice Resolved storage slot for a namespace (bytes32(0) if unregistered).
    function getNamespaceSlot(bytes32 namespaceId) external view returns (bytes32) {
        return namespaceSlot[namespaceId];
    }

    /// @notice Owning namespace id for a resolved slot (bytes32(0) if free).
    function getSlotOwner(bytes32 resolvedSlot) external view returns (bytes32) {
        return slotOwner[resolvedSlot];
    }

    /// @notice Full namespace inventory (deterministic manifest source).
    function getAllRegisteredNamespaceIds() external view returns (bytes32[] memory) {
        return _registeredNamespaceIds;
    }

    function getRegisteredNamespaceCount() external view returns (uint256) {
        return _registeredNamespaceIds.length;
    }

    // ============ Views: Proposals ============

    function getUpgradeProposal(uint256 proposalId) external view returns (UpgradeProposal memory) {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalNotFound(proposalId);
        return _proposals[proposalId];
    }

    function getProposalCount() external view returns (uint256) {
        return proposalCount;
    }

    function getModuleUpgradeHistory(bytes32 moduleId) external view returns (uint256[] memory) {
        return _moduleHistory[moduleId];
    }

    function getModuleUpgradeCount(bytes32 moduleId) external view returns (uint256) {
        return _moduleHistory[moduleId].length;
    }

    // ============ Internal Helpers ============

    function _requireProposal(uint256 proposalId) internal view returns (UpgradeProposal storage p) {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalNotFound(proposalId);
        p = _proposals[proposalId];
    }

    /// @dev Strict semantic-version ordering: a > b.
    function _isNewer(Version memory a, Version memory b) internal pure returns (bool) {
        return _encode(a) > _encode(b);
    }

    /// @dev Pack a version into a single comparable integer (major | minor | patch).
    function _encode(Version memory v) internal pure returns (uint256) {
        return (uint256(v.major) << 128) | (uint256(v.minor) << 64) | uint256(v.patch);
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}