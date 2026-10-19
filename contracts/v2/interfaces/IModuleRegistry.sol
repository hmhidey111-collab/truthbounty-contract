// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";

/// @title IModuleRegistry
/// @notice Version-aware canonical module registry for the TruthBounty V2 protocol.
/// @dev Every canonical module is resolvable by a stable keccak256 key, records its
///      versioned registration (interface ID, proxy/implementation metadata, active
///      status), and can only be replaced through a timelocked governance path.
///      Implementations MUST reject EOA proxies, self-registration, duplicate proxies
///      across keys (circular authority), and forbidden legacy addresses.
interface IModuleRegistry is IV2Module {
    /// @notice Status of a module registration within the registry.
    enum ModuleStatus {
        NONE,
        REGISTERED,
        ACTIVE,
        DEPRECATED
    }

    /// @notice Full metadata record for a registered module.
    struct ModuleInfo {
        bytes32 versionId;
        address proxy;
        address implementation;
        uint16 major;
        uint16 minor;
        bytes4 interfaceId;
        ModuleStatus status;
        uint64 activatedAt;
        uint64 changedAt;
    }

    /// @notice Input describing a module to register or activate.
    struct ModuleRegistration {
        bytes32 moduleId;
        bytes4 interfaceId;
        address proxy;
        address implementation;
        uint16 major;
        uint16 minor;
    }

    /// @notice One edgeset of the canonical dependency graph with live satisfaction state.
    struct Dependency {
        bytes32 moduleId;
        bytes32 requiredModuleId;
        uint16 minMajor;
        uint16 minMinor;
        bool satisfied;
    }

    /// @notice Non-reverting outcome of a preflight check used by deployment and tooling.
    struct PreflightResult {
        bool ok;
        bytes32 versionId;
        bytes4 canonicalInterfaceId;
        bytes32 errorCode;
        string reason;
    }

    event ModuleRegistered(
        bytes32 indexed moduleId,
        bytes32 indexed versionId,
        address indexed proxy,
        address implementation,
        uint16 major,
        uint16 minor,
        bytes4 interfaceId
    );
    event ModuleActivated(bytes32 indexed moduleId, bytes32 indexed versionId, address indexed proxy);
    event ModuleRemoved(bytes32 indexed moduleId, bytes32 indexed versionId, address indexed proxy);
    event ModuleReplacementProposed(
        bytes32 indexed moduleId, bytes32 indexed newVersionId, address indexed newProxy, uint256 readyAt
    );
    event ModuleReplacementCancelled(bytes32 indexed moduleId);
    event ModuleReplacementActivated(
        bytes32 indexed moduleId, bytes32 indexed oldVersionId, bytes32 indexed newVersionId, address newProxy
    );
    event ModuleDeprecated(bytes32 indexed moduleId, bytes32 indexed versionId, address indexed proxy);
    event ModuleForbidden(address indexed implementation);
    event ModuleUnforbidden(address indexed implementation);

    /// @notice Registers a single module version in an inactive state.
    /// @dev Restricted to the deployment role. Fails atomically on any validation error.
    function registerModule(ModuleRegistration calldata registration) external returns (bytes32 versionId);

    /// @notice Registers several module versions atomically (all or revert).
    function registerModules(ModuleRegistration[] calldata registrations) external returns (bytes32[] memory versionIds);

    /// @notice Activates a previously registered module after dependencies are satisfied.
    /// @dev Restricted to the deployment role.
    function activateModule(bytes32 moduleId) external;

    /// @notice Activates several modules atomically (all or revert) with intra-batch dependency resolution.
    function activateModules(bytes32[] calldata moduleIds) external;

    /// @notice Proposes replacing an active module, starting the timelocked governance delay.
    /// @dev Restricted to the governance role. Takes effect only via activateModuleReplacement after the delay.
    function proposeModuleReplacement(ModuleRegistration calldata registration) external returns (bytes32 newVersionId);

    /// @notice Cancels a pending replacement before it becomes ready.
    /// @dev Restricted to the governance role.
    function cancelModuleReplacement(bytes32 moduleId) external;

    /// @notice Activates a pending replacement once the timelock delay has elapsed.
    /// @dev Permissionless so a ready replacement cannot be censored by a stale authority.
    function activateModuleReplacement(bytes32 moduleId) external;

    /// @notice Marks a module key as permanently deprecated; it can never be (re)activated.
    /// @dev Restricted to the governance role.
    function deprecateModule(bytes32 moduleId) external;

    /// @notice Removes a module record entirely.
    /// @dev Restricted to the governance role.
    function removeModule(bytes32 moduleId) external;

    /// @notice Permanently forbids an address from ever being used as a module proxy/implementation.
    /// @dev Restricted to the governance role; used to quarantine legacy or unsafe contracts.
    function forbidModule(address implementation) external;

    /// @notice Clears a prior prohibition.
    /// @dev Restricted to the governance role.
    function unforbidModule(address implementation) external;

    /// @notice Backwards-compatible lookup: active proxy as implementation plus protocol version.
    function module(bytes32 moduleId) external view returns (address implementation, uint16 major, uint16 minor);

    /// @notice True only when the module key has an ACTIVE registration.
    function isRegistered(bytes32 moduleId) external view returns (bool);

    /// @notice Returns the full metadata record for a module key.
    function getModule(bytes32 moduleId) external view returns (ModuleInfo memory info);

    /// @notice Current status of a module key.
    function moduleStatus(bytes32 moduleId) external view returns (ModuleStatus status);

    /// @notice Convenience wrapper: true when the module key is ACTIVE.
    function isActive(bytes32 moduleId) external view returns (bool);

    /// @notice Convenience wrapper: true when the module key has been deprecated.
    function isDeprecated(bytes32 moduleId) external view returns (bool);

    /// @notice True if an address is on the forbidden list.
    function isForbidden(address implementation) external view returns (bool);

    /// @notice Deterministic version ID for a module registration.
    function versionIdOf(ModuleRegistration memory registration) external pure returns (bytes32 versionId);

    /// @notice Current version/versionId recorded for a module key.
    function versionOf(bytes32 moduleId)
        external
        view
        returns (bytes32 versionId, uint16 major, uint16 minor);

    /// @notice Interface ID recorded for a module key.
    function interfaceIdOf(bytes32 moduleId) external view returns (bytes4 interfaceId);

    /// @notice All non-empty module keys currently tracked by the registry.
    function getRegisteredKeys() external view returns (bytes32[] memory moduleIds);

    /// @notice Number of non-empty module keys currently tracked by the registry.
    function moduleCount() external view returns (uint256 count);

    /// @notice The 14 stable canonical module keys of the V2 suite.
    function canonicalModuleIds() external pure returns (bytes32[] memory moduleIds);

    /// @notice The canonical interface ID the V2 manifest expects for a given key.
    function canonicalInterfaceOf(bytes32 moduleId) external pure returns (bytes4 interfaceId);

    /// @notice The canonical dependency edgeset. Used by deployment tooling.
    function canonicalDependencies() external pure returns (Dependency[] memory dependencies);

    /// @notice Live dependency satisfaction for a set of module keys.
    function checkDependencies(bytes32[] calldata moduleIds) external view returns (Dependency[] memory dependencies);

    /// @notice Preflight a registration without changing state. Never reverts on validation failure.
    function preflightRegistration(ModuleRegistration calldata registration)
        external
        view
        returns (PreflightResult memory result);

    /// @notice Preflight an activation without changing state. Never reverts on validation failure.
    function preflightActivation(bytes32 moduleId) external view returns (PreflightResult memory result);

    /// @notice Preflight full canonical-suite readiness. Never reverts on validation failure.
    function validateCanonicalSuite() external view returns (PreflightResult memory result);

    /// @notice Current metadata records for every canonical key.
    function canonicalModules() external view returns (ModuleInfo[] memory infos);

    /// @notice Unix timestamp when a pending replacement becomes ready (0 if none pending).
    function replacementReadyAt(bytes32 moduleId) external view returns (uint256 readyAt);
}
