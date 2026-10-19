// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IModuleRegistry} from "./interfaces/IModuleRegistry.sol";
import {IV2Module} from "./interfaces/IV2Module.sol";
import {ModuleRegistryLib} from "./libraries/ModuleRegistryLib.sol";
import {V2Errors} from "./libraries/V2Errors.sol";
import {V2SafeCast} from "./libraries/V2SafeCast.sol";

/// @title ModuleRegistry
/// @notice Canonical, version-aware module registry for the TruthBounty V2 protocol.
/// @dev Registration and activation are restricted to the deployment role; replacements
///      require the governance role and a two-day timelock. The guardian role is
///      explicitly excluded from every mutation. Batch activation is atomic: every
///      element is validated (including intra-batch dependencies) before any write, so
///      a failed activation cannot partially change the suite.
contract ModuleRegistry is ERC165, AccessControl, IModuleRegistry {
    using ERC165Checker for address;

    /// @notice Maximum number of module records retained by this registry.
    uint256 public constant MAX_REGISTERED_MODULES = 256;
    /// @notice Maximum items accepted by registration, activation, and dependency batches.
    uint256 public constant MAX_REGISTRY_BATCH_SIZE = 32;

    bytes32 public constant DEPLOYMENT_ROLE = keccak256("DEPLOYMENT_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    mapping(bytes32 => ModuleInfo) private _modules;
    mapping(bytes32 => ModuleRegistration) private _pendingReplacement;
    mapping(bytes32 => uint256) private _replacementReadyAt;
    mapping(bytes32 => bool) private _deprecated;
    mapping(address => bool) public override isForbidden;
    bytes32[] private _moduleIds;

    /// @param admin Holder of the default admin and deployment roles.
    /// @param governance Holder of the governance role (typically the V2 governor timelock).
    /// @param guardian Explicitly excluded from registry mutations.
    constructor(address admin, address governance, address guardian) {
        if (admin == address(0) || governance == address(0) || guardian == address(0)) {
            revert V2Errors.ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DEPLOYMENT_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, governance);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, AccessControl, IERC165)
        returns (bool)
    {
        return interfaceId == type(IModuleRegistry).interfaceId || interfaceId == type(IV2Module).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function registerModule(ModuleRegistration calldata registration)
        public
        override
        onlyRole(DEPLOYMENT_ROLE)
        returns (bytes32)
    {
        _rejectGuardian();
        if (_deprecated[registration.moduleId]) revert V2Errors.DeprecatedModule(registration.moduleId);
        if (_modules[registration.moduleId].status != ModuleStatus.NONE) {
            revert V2Errors.DuplicateModule(registration.moduleId);
        }
        if (_moduleIds.length >= MAX_REGISTERED_MODULES) {
            revert V2Errors.RegisteredModuleLimitExceeded(_moduleIds.length + 1, MAX_REGISTERED_MODULES);
        }
        bytes32 versionId = _validateRegistration(registration, bytes32(0));
        ModuleInfo storage info = _modules[registration.moduleId];
        info.versionId = versionId;
        info.proxy = registration.proxy;
        info.implementation = registration.implementation;
        info.major = registration.major;
        info.minor = registration.minor;
        info.interfaceId = registration.interfaceId;
        info.status = ModuleStatus.REGISTERED;
        info.changedAt = V2SafeCast.timestamp64(V2SafeCast.FIELD_MODULE_CHANGED_AT);
        _moduleIds.push(registration.moduleId);
        emit ModuleRegistered(
            registration.moduleId,
            versionId,
            registration.proxy,
            registration.implementation,
            registration.major,
            registration.minor,
            registration.interfaceId
        );
        return versionId;
    }

    function registerModules(ModuleRegistration[] calldata registrations)
        external
        override
        onlyRole(DEPLOYMENT_ROLE)
        returns (bytes32[] memory)
    {
        _rejectGuardian();
        uint256 batchLength = registrations.length;
        if (batchLength > MAX_REGISTRY_BATCH_SIZE) {
            revert V2Errors.RegistryBatchTooLarge(batchLength, MAX_REGISTRY_BATCH_SIZE);
        }
        if (batchLength > MAX_REGISTERED_MODULES - _moduleIds.length) {
            revert V2Errors.RegisteredModuleLimitExceeded(_moduleIds.length + batchLength, MAX_REGISTERED_MODULES);
        }
        bytes32[] memory versionIds = new bytes32[](registrations.length);
        for (uint256 i = 0; i < registrations.length; ++i) {
            versionIds[i] = registerModule(registrations[i]);
        }
        return versionIds;
    }

    function activateModule(bytes32 moduleId) external override onlyRole(DEPLOYMENT_ROLE) {
        _rejectGuardian();
        _assertActivationEligible(moduleId);
        _requireDependenciesSatisfied(moduleId, new bytes32[](0));
        _writeActivation(moduleId);
    }

    function activateModules(bytes32[] calldata moduleIds) external override onlyRole(DEPLOYMENT_ROLE) {
        _rejectGuardian();
        if (moduleIds.length > MAX_REGISTRY_BATCH_SIZE) {
            revert V2Errors.RegistryBatchTooLarge(moduleIds.length, MAX_REGISTRY_BATCH_SIZE);
        }
        bytes32[] memory batch = new bytes32[](moduleIds.length);
        for (uint256 i = 0; i < moduleIds.length; ++i) {
            _assertActivationEligible(moduleIds[i]);
            batch[i] = moduleIds[i];
        }
        for (uint256 i = 0; i < batch.length; ++i) {
            _requireDependenciesSatisfied(batch[i], batch);
        }
        for (uint256 i = 0; i < batch.length; ++i) {
            _writeActivation(batch[i]);
        }
    }

    function proposeModuleReplacement(ModuleRegistration calldata registration)
        external
        override
        onlyRole(GOVERNANCE_ROLE)
        returns (bytes32)
    {
        _rejectGuardian();
        bytes32 moduleId = registration.moduleId;
        if (_modules[moduleId].status != ModuleStatus.ACTIVE) revert V2Errors.ModuleNotActive(moduleId);
        bytes32 newVersionId = _validateRegistration(registration, moduleId);
        if (newVersionId == _modules[moduleId].versionId) revert V2Errors.ReplacementNoop(moduleId);

        uint256 readyAt = block.timestamp + ModuleRegistryLib.REPLACEMENT_DELAY;
        _pendingReplacement[moduleId] = registration;
        _replacementReadyAt[moduleId] = readyAt;
        emit ModuleReplacementProposed(moduleId, newVersionId, registration.proxy, readyAt);
        return newVersionId;
    }

    function cancelModuleReplacement(bytes32 moduleId) external override onlyRole(GOVERNANCE_ROLE) {
        _rejectGuardian();
        if (_replacementReadyAt[moduleId] == 0) revert V2Errors.ReplacementNotPending(moduleId);
        delete _pendingReplacement[moduleId];
        delete _replacementReadyAt[moduleId];
        emit ModuleReplacementCancelled(moduleId);
    }

    function activateModuleReplacement(bytes32 moduleId) external override {
        uint256 readyAt = _replacementReadyAt[moduleId];
        if (readyAt == 0) revert V2Errors.ReplacementNotPending(moduleId);
        if (block.timestamp < readyAt) revert V2Errors.ReplacementNotReady(moduleId, readyAt);
        if (_modules[moduleId].status != ModuleStatus.ACTIVE) revert V2Errors.ModuleNotActive(moduleId);
        if (_deprecated[moduleId]) revert V2Errors.DeprecatedModule(moduleId);

        ModuleRegistration memory registration = _pendingReplacement[moduleId];
        bytes32 newVersionId = _validateRegistration(registration, moduleId);
        bytes32 oldVersionId = _modules[moduleId].versionId;

        ModuleInfo storage info = _modules[moduleId];
        info.versionId = newVersionId;
        info.proxy = registration.proxy;
        info.implementation = registration.implementation;
        info.major = registration.major;
        info.minor = registration.minor;
        info.interfaceId = registration.interfaceId;
        info.changedAt = V2SafeCast.timestamp64(V2SafeCast.FIELD_MODULE_CHANGED_AT);

        delete _pendingReplacement[moduleId];
        delete _replacementReadyAt[moduleId];
        emit ModuleReplacementActivated(moduleId, oldVersionId, newVersionId, registration.proxy);
    }

    function deprecateModule(bytes32 moduleId) external override onlyRole(GOVERNANCE_ROLE) {
        _rejectGuardian();
        ModuleInfo storage info = _modules[moduleId];
        if (info.status == ModuleStatus.NONE) revert V2Errors.ModuleNotFound(moduleId);
        if (_deprecated[moduleId]) revert V2Errors.DeprecatedModule(moduleId);
        _deprecated[moduleId] = true;
        info.status = ModuleStatus.DEPRECATED;
        info.changedAt = V2SafeCast.timestamp64(V2SafeCast.FIELD_MODULE_CHANGED_AT);
        delete _pendingReplacement[moduleId];
        delete _replacementReadyAt[moduleId];
        emit ModuleDeprecated(moduleId, info.versionId, info.proxy);
    }

    function removeModule(bytes32 moduleId) external override onlyRole(GOVERNANCE_ROLE) {
        _rejectGuardian();
        ModuleInfo memory info = _modules[moduleId];
        if (info.status == ModuleStatus.NONE) revert V2Errors.ModuleNotFound(moduleId);
        delete _modules[moduleId];
        delete _pendingReplacement[moduleId];
        delete _replacementReadyAt[moduleId];
        for (uint256 i = 0; i < _moduleIds.length; ++i) {
            if (_moduleIds[i] == moduleId) {
                _moduleIds[i] = _moduleIds[_moduleIds.length - 1];
                _moduleIds.pop();
                break;
            }
        }
        emit ModuleRemoved(moduleId, info.versionId, info.proxy);
    }

    function forbidModule(address implementation) external override onlyRole(GOVERNANCE_ROLE) {
        _rejectGuardian();
        if (implementation == address(0)) revert V2Errors.ZeroAddress();
        if (!isForbidden[implementation]) {
            isForbidden[implementation] = true;
            emit ModuleForbidden(implementation);
        }
    }

    function unforbidModule(address implementation) external override onlyRole(GOVERNANCE_ROLE) {
        _rejectGuardian();
        if (isForbidden[implementation]) {
            isForbidden[implementation] = false;
            emit ModuleUnforbidden(implementation);
        }
    }

    function module(bytes32 moduleId)
        external
        view
        override
        returns (address implementation, uint16 major, uint16 minor)
    {
        ModuleInfo storage info = _modules[moduleId];
        return (info.proxy, info.major, info.minor);
    }

    function isRegistered(bytes32 moduleId) external view override returns (bool) {
        return _modules[moduleId].status == ModuleStatus.ACTIVE;
    }

    function getModule(bytes32 moduleId) external view override returns (ModuleInfo memory info) {
        return _modules[moduleId];
    }

    function moduleStatus(bytes32 moduleId) external view override returns (ModuleStatus) {
        return _modules[moduleId].status;
    }

    function isActive(bytes32 moduleId) external view override returns (bool) {
        return _modules[moduleId].status == ModuleStatus.ACTIVE;
    }

    function isDeprecated(bytes32 moduleId) external view override returns (bool) {
        return _deprecated[moduleId];
    }

    function versionIdOf(ModuleRegistration memory registration) external pure override returns (bytes32) {
        return ModuleRegistryLib.versionIdOf(
            registration.moduleId,
            registration.interfaceId,
            registration.proxy,
            registration.implementation,
            registration.major,
            registration.minor
        );
    }

    function versionOf(bytes32 moduleId)
        external
        view
        override
        returns (bytes32 versionId, uint16 major, uint16 minor)
    {
        ModuleInfo storage info = _modules[moduleId];
        return (info.versionId, info.major, info.minor);
    }

    function interfaceIdOf(bytes32 moduleId) external view override returns (bytes4) {
        return _modules[moduleId].interfaceId;
    }

    function getRegisteredKeys() external view override returns (bytes32[] memory) {
        return _moduleIds;
    }

    function moduleCount() external view override returns (uint256) {
        return _moduleIds.length;
    }

    function canonicalModuleIds() external pure override returns (bytes32[] memory moduleIds) {
        bytes32[14] memory ids = ModuleRegistryLib.canonicalModuleIds();
        moduleIds = new bytes32[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            moduleIds[i] = ids[i];
        }
    }

    function canonicalInterfaceOf(bytes32 moduleId) external pure override returns (bytes4) {
        return ModuleRegistryLib.canonicalInterfaceOf(moduleId);
    }

    function canonicalDependencies() external pure override returns (Dependency[] memory dependencies) {
        Dependency[11] memory edges = ModuleRegistryLib.canonicalDependencies();
        dependencies = new Dependency[](edges.length);
        for (uint256 i = 0; i < edges.length; ++i) {
            dependencies[i] = edges[i];
        }
    }

    function checkDependencies(bytes32[] calldata moduleIds)
        external
        view
        override
        returns (Dependency[] memory dependencies)
    {
        if (moduleIds.length > MAX_REGISTRY_BATCH_SIZE) {
            revert V2Errors.RegistryBatchTooLarge(moduleIds.length, MAX_REGISTRY_BATCH_SIZE);
        }
        Dependency[11] memory edges = ModuleRegistryLib.canonicalDependencies();
        uint256 count;
        for (uint256 i = 0; i < edges.length; ++i) {
            for (uint256 j = 0; j < moduleIds.length; ++j) {
                if (edges[i].moduleId == moduleIds[j]) {
                    count++;
                    break;
                }
            }
        }
        dependencies = new Dependency[](count);
        uint256 written;
        for (uint256 i = 0; i < edges.length; ++i) {
            bool scoped;
            for (uint256 j = 0; j < moduleIds.length; ++j) {
                if (edges[i].moduleId == moduleIds[j]) {
                    scoped = true;
                    break;
                }
            }
            if (!scoped) continue;
            Dependency memory edge = edges[i];
            edge.satisfied = _modules[edge.requiredModuleId].status == ModuleStatus.ACTIVE;
            dependencies[written++] = edge;
        }
    }

    function preflightRegistration(ModuleRegistration calldata registration)
        external
        view
        override
        returns (PreflightResult memory result)
    {
        bytes32 moduleId = registration.moduleId;
        result.canonicalInterfaceId = ModuleRegistryLib.canonicalInterfaceOf(moduleId);
        result.versionId = ModuleRegistryLib.versionIdOf(
            moduleId,
            registration.interfaceId,
            registration.proxy,
            registration.implementation,
            registration.major,
            registration.minor
        );

        if (!ModuleRegistryLib.isCanonicalKey(moduleId)) {
            return _fail(result, "UNKNOWN_KEY", "module key is not canonical");
        }
        if (registration.interfaceId == bytes4(0)) {
            return _fail(result, "INVALID_INTERFACE_ID", "interface id is zero");
        }
        if (_modules[moduleId].status != ModuleStatus.NONE) {
            return _fail(result, "DUPLICATE_MODULE", "module key already registered");
        }
        if (_deprecated[moduleId]) {
            return _fail(result, "DEPRECATED_KEY", "module key is deprecated");
        }
        if (registration.proxy == address(0)) {
            return _fail(result, "NOT_A_CONTRACT", "proxy address is zero");
        }
        if (registration.proxy == address(this)) {
            return _fail(result, "SELF_REGISTRATION", "proxy is the registry itself");
        }
        if (registration.implementation != address(0) && registration.implementation == address(this)) {
            return _fail(result, "SELF_REGISTRATION", "implementation is the registry itself");
        }
        if (_isEOA(registration.proxy)
            || (registration.implementation != address(0) && _isEOA(registration.implementation))) {
            return _fail(result, "NOT_A_CONTRACT", "proxy or implementation is an EOA");
        }
        if (isForbidden[registration.proxy] || isForbidden[registration.implementation]) {
            return _fail(result, "FORBIDDEN", "address is on the forbidden list");
        }
        if (_proxyInUse(registration.proxy, bytes32(0))) {
            return _fail(result, "DUPLICATE_PROXY", "proxy already bound to another module");
        }
        if (ModuleRegistryLib.canonicalInterfaceOf(moduleId) != registration.interfaceId) {
            return _fail(result, "INTERFACE_MISMATCH", "interface differs from the canonical manifest");
        }
        if (!registration.proxy.supportsInterface(type(IV2Module).interfaceId)
            || !registration.proxy.supportsInterface(registration.interfaceId)) {
            return _fail(result, "INTERFACE_MISMATCH", "proxy does not implement the claimed interface");
        }
        (uint16 actualMajor, uint16 actualMinor, bool isModule) = _probeProtocolVersion(registration.proxy);
        if (!isModule) {
            return _fail(result, "INTERFACE_MISMATCH", "protocolVersion() is not a V2 module");
        }
        if (!ModuleRegistryLib.isReleaseCompatible(actualMajor)) {
            return _fail(result, "VERSION_MAJOR", "protocol major is not release compatible");
        }
        if (registration.major != actualMajor || registration.minor != actualMinor) {
            return _fail(result, "DECLARED_VERSION", "declared version differs from the module");
        }
        result.ok = true;
        result.errorCode = 0;
        result.reason = "registration is valid";
    }

    function preflightActivation(bytes32 moduleId) external view override returns (PreflightResult memory result) {
        ModuleStatus status = _modules[moduleId].status;
        if (status == ModuleStatus.NONE) {
            return _fail(result, "NOT_FOUND", "module not registered");
        }
        if (_deprecated[moduleId]) {
            return _fail(result, "DEPRECATED_KEY", "module key is deprecated");
        }
        if (status == ModuleStatus.ACTIVE) {
            return _fail(result, "ALREADY_ACTIVE", "module already active");
        }
        if (status != ModuleStatus.REGISTERED) {
            return _fail(result, "INVALID_STATUS", "module is not registrable");
        }
        if (!_dependenciesSatisfied(moduleId, new bytes32[](0))) {
            return _fail(result, "DEPENDENCY", "a canonical dependency is not active");
        }
        result.ok = true;
        result.versionId = _modules[moduleId].versionId;
        result.errorCode = 0;
        result.reason = "module can be activated";
    }

    function validateCanonicalSuite() external view override returns (PreflightResult memory result) {
        bytes32[14] memory ids = ModuleRegistryLib.canonicalModuleIds();
        for (uint256 i = 0; i < ids.length; ++i) {
            if (_modules[ids[i]].status != ModuleStatus.ACTIVE) {
                result.errorCode = "INCOMPLETE_SUITE";
                result.reason = "module missing from active suite";
                return result;
            }
        }
        result.ok = true;
        result.errorCode = 0;
        result.reason = "canonical suite is complete and active";
    }

    function canonicalModules() external view override returns (ModuleInfo[] memory infos) {
        bytes32[] memory ids = _moduleIds;
        uint256 count;
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ModuleRegistryLib.isCanonicalKey(ids[i])) count++;
        }
        infos = new ModuleInfo[](count);
        uint256 written;
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ModuleRegistryLib.isCanonicalKey(ids[i])) {
                infos[written++] = _modules[ids[i]];
            }
        }
    }

    function replacementReadyAt(bytes32 moduleId) external view override returns (uint256) {
        return _replacementReadyAt[moduleId];
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    function _rejectGuardian() internal view {
        if (hasRole(GUARDIAN_ROLE, msg.sender)) revert V2Errors.GuardianCannotReplaceModule(msg.sender);
    }

    function _isEOA(address target) internal view returns (bool) {
        return target.code.length == 0;
    }

    function _probeProtocolVersion(address target)
        internal
        view
        returns (uint16 major, uint16 minor, bool isModule)
    {
        try IV2Module(target).protocolVersion() returns (uint16 vMajor, uint16 vMinor) {
            return (vMajor, vMinor, true);
        } catch {
            return (0, 0, false);
        }
    }

    function _proxyInUse(address proxy, bytes32 exceptModuleId) internal view returns (bool) {
        for (uint256 i = 0; i < _moduleIds.length; ++i) {
            bytes32 moduleId = _moduleIds[i];
            if (moduleId == exceptModuleId) continue;
            if (_modules[moduleId].proxy == proxy) return true;
        }
        return false;
    }

    /// @notice Validates a registration strictly (reverts on any invalid input) and returns its version ID.
    function _validateRegistration(ModuleRegistration memory registration, bytes32 exceptModuleId)
        internal
        view
        returns (bytes32)
    {
        bytes32 moduleId = registration.moduleId;
        if (!ModuleRegistryLib.isCanonicalKey(moduleId)) revert V2Errors.UnknownModuleId(moduleId);
        if (registration.interfaceId == bytes4(0)) revert V2Errors.InvalidInterfaceId(registration.interfaceId);
        if (_deprecated[moduleId]) revert V2Errors.DeprecatedModule(moduleId);
        if (registration.proxy == address(0)) revert V2Errors.ModuleNotAContract(address(0));
        if (registration.proxy == address(this)) revert V2Errors.SelfRegistration();
        if (registration.implementation != address(0) && registration.implementation == address(this)) {
            revert V2Errors.SelfRegistration();
        }
        if (_isEOA(registration.proxy)
            || (registration.implementation != address(0) && _isEOA(registration.implementation))) {
            revert V2Errors.ModuleNotAContract(registration.proxy);
        }
        if (isForbidden[registration.proxy] || isForbidden[registration.implementation]) {
            revert V2Errors.ForbiddenModule(registration.proxy);
        }
        if (_proxyInUse(registration.proxy, exceptModuleId)) {
            revert V2Errors.DuplicateProxy(registration.proxy);
        }
        if (ModuleRegistryLib.canonicalInterfaceOf(moduleId) != registration.interfaceId) {
            revert V2Errors.ModuleInterfaceMismatch(
                ModuleRegistryLib.canonicalInterfaceOf(moduleId), registration.interfaceId
            );
        }
        if (!registration.proxy.supportsInterface(type(IV2Module).interfaceId)
            || !registration.proxy.supportsInterface(registration.interfaceId)) {
            revert V2Errors.ModuleInterfaceMismatch(registration.interfaceId, bytes4(0));
        }
        (uint16 actualMajor, uint16 actualMinor, bool isModule) = _probeProtocolVersion(registration.proxy);
        if (!isModule) {
            revert V2Errors.ModuleInterfaceMismatch(registration.interfaceId, bytes4(0));
        }
        if (!ModuleRegistryLib.isReleaseCompatible(actualMajor)) {
            revert V2Errors.ModuleVersionMismatch(actualMajor, ModuleRegistryLib.REQUIRED_PROTOCOL_MAJOR);
        }
        if (registration.major != actualMajor || registration.minor != actualMinor) {
            revert V2Errors.DeclaredVersionMismatch(
                registration.major, registration.minor, actualMajor, actualMinor
            );
        }
        return ModuleRegistryLib.versionIdOf(
            moduleId,
            registration.interfaceId,
            registration.proxy,
            registration.implementation,
            registration.major,
            registration.minor
        );
    }

    function _assertActivationEligible(bytes32 moduleId) internal view {
        if (_deprecated[moduleId]) revert V2Errors.DeprecatedModule(moduleId);
        ModuleStatus status = _modules[moduleId].status;
        if (status == ModuleStatus.NONE) revert V2Errors.ModuleNotFound(moduleId);
        if (status == ModuleStatus.ACTIVE) revert V2Errors.AlreadyActive(moduleId);
        if (status != ModuleStatus.REGISTERED) revert V2Errors.ModuleNotActive(moduleId);
    }

    function _dependenciesSatisfied(bytes32 moduleId, bytes32[] memory batch) internal view returns (bool) {
        Dependency[11] memory edges = ModuleRegistryLib.canonicalDependencies();
        for (uint256 i = 0; i < edges.length; ++i) {
            if (edges[i].moduleId != moduleId) continue;
            bytes32 requiredId = edges[i].requiredModuleId;
            if (!_isActiveOrBatch(requiredId, batch)) return false;
            (uint16 minMajor, uint16 minMinor,) = ModuleRegistryLib.dependencyRequirement(moduleId, requiredId);
            ModuleInfo storage required = _modules[requiredId];
            if (required.major < minMajor || (required.major == minMajor && required.minor < minMinor)) return false;
        }
        return true;
    }

    function _isActiveOrBatch(bytes32 moduleId, bytes32[] memory batch) internal view returns (bool) {
        if (_modules[moduleId].status == ModuleStatus.ACTIVE) return true;
        for (uint256 i = 0; i < batch.length; ++i) {
            if (batch[i] == moduleId) return true;
        }
        return false;
    }

    function _requireDependenciesSatisfied(bytes32 moduleId, bytes32[] memory batch) internal view {
        if (!_dependenciesSatisfied(moduleId, batch)) {
            revert V2Errors.DependencyUnsatisfied(moduleId, _firstUnsatisfiedDependency(moduleId, batch));
        }
    }

    function _firstUnsatisfiedDependency(bytes32 moduleId, bytes32[] memory batch)
        internal
        view
        returns (bytes32)
    {
        Dependency[11] memory edges = ModuleRegistryLib.canonicalDependencies();
        for (uint256 i = 0; i < edges.length; ++i) {
            if (edges[i].moduleId == moduleId && !_isActiveOrBatch(edges[i].requiredModuleId, batch)) {
                return edges[i].requiredModuleId;
            }
        }
        return bytes32(0);
    }

    function _writeActivation(bytes32 moduleId) internal {
        ModuleInfo storage info = _modules[moduleId];
        info.status = ModuleStatus.ACTIVE;
        // V2-SC-161: one guarded read keeps activatedAt == changedAt and fails closed past uint64.
        uint64 nowTs = V2SafeCast.timestamp64(V2SafeCast.FIELD_MODULE_ACTIVATED_AT);
        info.activatedAt = nowTs;
        info.changedAt = nowTs;
        emit ModuleActivated(moduleId, info.versionId, info.proxy);
    }

    function _fail(PreflightResult memory result, bytes32 errorCode, string memory reason)
        internal
        pure
        returns (PreflightResult memory)
    {
        result.ok = false;
        result.errorCode = errorCode;
        result.reason = reason;
        return result;
    }
}
