// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IModuleRegistry} from "../v2/interfaces/IModuleRegistry.sol";
import {IV2Module} from "../v2/interfaces/IV2Module.sol";
import {ModuleRegistryLib} from "../v2/libraries/ModuleRegistryLib.sol";

/// @dev Test helper implementing the module registry surface for StakeVault authorization tests.
///      Permissive by design: it performs no ERC-165/version/address validation and activates
///      every registration immediately.
contract MockModuleRegistry is ERC165, IModuleRegistry {
    struct Entry {
        ModuleInfo info;
        bool deprecated;
        uint256 readyAt;
    }

    mapping(bytes32 => Entry) internal _entries;
    bytes32[] internal _keys;

    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IModuleRegistry).interfaceId || interfaceId == type(IV2Module).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function permitModule(bytes32 moduleId, address implementation) external returns (bytes32 versionId) {
        ModuleRegistration memory registration = ModuleRegistration({
            moduleId: moduleId,
            interfaceId: bytes4(0),
            proxy: implementation,
            implementation: address(0),
            major: 2,
            minor: 0
        });
        return _register(registration);
    }

    function registerModule(ModuleRegistration calldata registration) external override returns (bytes32) {
        return _register(registration);
    }

    function _register(ModuleRegistration memory registration) private returns (bytes32 versionId) {
        versionId = ModuleRegistryLib.versionIdOf(
            registration.moduleId,
            registration.interfaceId,
            registration.proxy,
            registration.implementation,
            registration.major,
            registration.minor
        );
        Entry storage entry = _entries[registration.moduleId];
        if (entry.info.status == ModuleStatus.NONE) {
            _keys.push(registration.moduleId);
        }
        entry.info = ModuleInfo({
            versionId: versionId,
            proxy: registration.proxy,
            implementation: registration.implementation,
            major: registration.major,
            minor: registration.minor,
            interfaceId: registration.interfaceId,
            status: ModuleStatus.ACTIVE,
            activatedAt: uint64(block.timestamp),
            changedAt: uint64(block.timestamp)
        });
        emit ModuleRegistered(
            registration.moduleId,
            versionId,
            registration.proxy,
            registration.implementation,
            registration.major,
            registration.minor,
            registration.interfaceId
        );
        emit ModuleActivated(registration.moduleId, versionId, registration.proxy);
    }

    function registerModules(ModuleRegistration[] calldata registrations)
        external
        override
        returns (bytes32[] memory)
    {
        bytes32[] memory versionIds = new bytes32[](registrations.length);
        for (uint256 i = 0; i < registrations.length; ++i) {
            versionIds[i] = _register(registrations[i]);
        }
        return versionIds;
    }

    function activateModule(bytes32 moduleId) external override {
        _activate(moduleId);
    }

    function _activate(bytes32 moduleId) private {
        _entries[moduleId].info.status = ModuleStatus.ACTIVE;
        emit ModuleActivated(moduleId, _entries[moduleId].info.versionId, _entries[moduleId].info.proxy);
    }

    function activateModules(bytes32[] calldata moduleIds) external override {
        for (uint256 i = 0; i < moduleIds.length; ++i) {
            _activate(moduleIds[i]);
        }
    }

    function proposeModuleReplacement(ModuleRegistration calldata registration)
        external
        override
        returns (bytes32)
    {
        bytes32 versionId = ModuleRegistryLib.versionIdOf(
            registration.moduleId,
            registration.interfaceId,
            registration.proxy,
            registration.implementation,
            registration.major,
            registration.minor
        );
        Entry storage entry = _entries[registration.moduleId];
        entry.info.versionId = versionId;
        entry.info.proxy = registration.proxy;
        entry.info.implementation = registration.implementation;
        entry.info.major = registration.major;
        entry.info.minor = registration.minor;
        entry.info.interfaceId = registration.interfaceId;
        entry.info.changedAt = uint64(block.timestamp);
        entry.readyAt = block.timestamp + ModuleRegistryLib.REPLACEMENT_DELAY;
        emit ModuleReplacementProposed(registration.moduleId, versionId, registration.proxy, entry.readyAt);
        return versionId;
    }

    function cancelModuleReplacement(bytes32 moduleId) external override {
        _entries[moduleId].readyAt = 0;
        emit ModuleReplacementCancelled(moduleId);
    }

    function activateModuleReplacement(bytes32 moduleId) external override {
        Entry storage entry = _entries[moduleId];
        emit ModuleReplacementActivated(moduleId, entry.info.versionId, entry.info.versionId, entry.info.proxy);
        entry.readyAt = 0;
    }

    function deprecateModule(bytes32 moduleId) external override {
        Entry storage entry = _entries[moduleId];
        entry.deprecated = true;
        entry.info.status = ModuleStatus.DEPRECATED;
        entry.info.changedAt = uint64(block.timestamp);
        emit ModuleDeprecated(moduleId, entry.info.versionId, entry.info.proxy);
    }

    function removeModule(bytes32 moduleId) external override {
        Entry memory entry = _entries[moduleId];
        delete _entries[moduleId];
        for (uint256 i = 0; i < _keys.length; ++i) {
            if (_keys[i] == moduleId) {
                _keys[i] = _keys[_keys.length - 1];
                _keys.pop();
                break;
            }
        }
        emit ModuleRemoved(moduleId, entry.info.versionId, entry.info.proxy);
    }

    function forbidModule(address implementation) external override {
        emit ModuleForbidden(implementation);
    }

    function unforbidModule(address implementation) external override {
        emit ModuleUnforbidden(implementation);
    }

    function module(bytes32 moduleId)
        external
        view
        override
        returns (address implementation, uint16 major, uint16 minor)
    {
        ModuleInfo memory info = _entries[moduleId].info;
        return (info.proxy, info.major, info.minor);
    }

    function isRegistered(bytes32 moduleId) external view override returns (bool) {
        return _entries[moduleId].info.status == ModuleStatus.ACTIVE;
    }

    function getModule(bytes32 moduleId) external view override returns (ModuleInfo memory info) {
        return _entries[moduleId].info;
    }

    function moduleStatus(bytes32 moduleId) external view override returns (ModuleStatus) {
        return _entries[moduleId].info.status;
    }

    function isActive(bytes32 moduleId) external view override returns (bool) {
        return _entries[moduleId].info.status == ModuleStatus.ACTIVE;
    }

    function isDeprecated(bytes32 moduleId) external view override returns (bool) {
        return _entries[moduleId].deprecated;
    }

    function isForbidden(address) external view override returns (bool) {
        return false;
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
        ModuleInfo memory info = _entries[moduleId].info;
        return (info.versionId, info.major, info.minor);
    }

    function interfaceIdOf(bytes32 moduleId) external view override returns (bytes4) {
        return _entries[moduleId].info.interfaceId;
    }

    function getRegisteredKeys() external view override returns (bytes32[] memory) {
        return _keys;
    }

    function moduleCount() external view override returns (uint256) {
        return _keys.length;
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
        Dependency[11] memory edges = ModuleRegistryLib.canonicalDependencies();
        dependencies = new Dependency[](edges.length);
        uint256 written;
        for (uint256 i = 0; i < edges.length; ++i) {
            for (uint256 j = 0; j < moduleIds.length; ++j) {
                if (edges[i].moduleId == moduleIds[j]) {
                    Dependency memory edge = edges[i];
                    edge.satisfied = _entries[edge.requiredModuleId].info.status == ModuleStatus.ACTIVE;
                    dependencies[written++] = edge;
                    break;
                }
            }
        }
        return dependencies;
    }

    function preflightRegistration(ModuleRegistration calldata registration)
        external
        view
        override
        returns (PreflightResult memory result)
    {
        result.ok = true;
        result.versionId = ModuleRegistryLib.versionIdOf(
            registration.moduleId,
            registration.interfaceId,
            registration.proxy,
            registration.implementation,
            registration.major,
            registration.minor
        );
        result.canonicalInterfaceId = ModuleRegistryLib.canonicalInterfaceOf(registration.moduleId);
        result.errorCode = 0;
        result.reason = "permissive mock always accepts";
    }

    function preflightActivation(bytes32 moduleId) external view override returns (PreflightResult memory result) {
        result.ok = _entries[moduleId].info.status == ModuleStatus.REGISTERED
            || _entries[moduleId].info.status == ModuleStatus.ACTIVE;
        result.errorCode = 0;
        result.reason = "permissive mock always accepts";
    }

    function validateCanonicalSuite() external view override returns (PreflightResult memory result) {
        result.ok = true;
        result.errorCode = 0;
        result.reason = "permissive mock reports a complete suite";
    }

    function canonicalModules() external view override returns (ModuleInfo[] memory infos) {
        infos = new ModuleInfo[](_keys.length);
        for (uint256 i = 0; i < _keys.length; ++i) {
            infos[i] = _entries[_keys[i]].info;
        }
    }

    function replacementReadyAt(bytes32 moduleId) external view override returns (uint256) {
        return _entries[moduleId].readyAt;
    }
}