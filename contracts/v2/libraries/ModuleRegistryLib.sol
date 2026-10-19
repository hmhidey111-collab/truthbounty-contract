// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IModuleRegistry} from "../interfaces/IModuleRegistry.sol";
import {IConfiguration} from "../interfaces/IConfiguration.sol";
import {IClaims} from "../interfaces/IClaims.sol";
import {IEvidence} from "../interfaces/IEvidence.sol";
import {IStakeCustody} from "../interfaces/IStakeCustody.sol";
import {IVerification} from "../interfaces/IVerification.sol";
import {IAggregation} from "../interfaces/IAggregation.sol";
import {ISettlement} from "../interfaces/ISettlement.sol";
import {IDisputes} from "../interfaces/IDisputes.sol";
import {IRewards} from "../interfaces/IRewards.sol";
import {ISlashing} from "../interfaces/ISlashing.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";
import {IReputationRoots} from "../interfaces/IReputationRoots.sol";
import {IGovernanceHooks} from "../interfaces/IGovernanceHooks.sol";
import {IEmergencyControls} from "../interfaces/IEmergencyControls.sol";

/// @title ModuleRegistryLib
/// @notice Canonical manifest and validation helpers for the V2 module registry.
/// @dev Holds the 14 stable module keys, their canonical ERC-165 interface IDs, the
///      dependency edgeset, and the deterministic version-ID scheme. Pure/library so it
///      is reusable by deployment tooling, preflight views, and consumer manifests.
library ModuleRegistryLib {
    /// @notice Protocol major version every registrable module must implement.
    uint16 public constant REQUIRED_PROTOCOL_MAJOR = 2;

    /// @notice Mandatory delay between proposing and activating a module replacement.
    uint256 public constant REPLACEMENT_DELAY = 2 days;

    bytes32 public constant MODULE_CONFIGURATION = keccak256("CONFIGURATION");
    bytes32 public constant MODULE_CLAIMS = keccak256("CLAIMS");
    bytes32 public constant MODULE_EVIDENCE = keccak256("EVIDENCE");
    bytes32 public constant MODULE_STAKE_CUSTODY = keccak256("STAKE_CUSTODY");
    bytes32 public constant MODULE_VERIFICATION = keccak256("VERIFICATION");
    bytes32 public constant MODULE_AGGREGATION = keccak256("AGGREGATION");
    bytes32 public constant MODULE_SETTLEMENT = keccak256("SETTLEMENT");
    bytes32 public constant MODULE_DISPUTES = keccak256("DISPUTES");
    bytes32 public constant MODULE_REWARDS = keccak256("REWARDS");
    bytes32 public constant MODULE_SLASHING = keccak256("SLASHING");
    bytes32 public constant MODULE_TREASURY = keccak256("TREASURY");
    bytes32 public constant MODULE_REPUTATION_ROOTS = keccak256("REPUTATION_ROOTS");
    bytes32 public constant MODULE_GOVERNANCE_HOOKS = keccak256("GOVERNANCE_HOOKS");
    bytes32 public constant MODULE_EMERGENCY_CONTROLS = keccak256("EMERGENCY_CONTROLS");

    uint8 internal constant CANONICAL_MODULE_COUNT = 14;

    // Derive each ERC-165 ID from its canonical interface so selector changes
    // cannot leave the registry accepting a stale hand-copied value.
    bytes4 internal constant INTERFACE_CONFIGURATION = type(IConfiguration).interfaceId;
    bytes4 internal constant INTERFACE_CLAIMS = type(IClaims).interfaceId;
    bytes4 internal constant INTERFACE_EVIDENCE = type(IEvidence).interfaceId;
    bytes4 internal constant INTERFACE_STAKE_CUSTODY = type(IStakeCustody).interfaceId;
    bytes4 internal constant INTERFACE_VERIFICATION = type(IVerification).interfaceId;
    bytes4 internal constant INTERFACE_AGGREGATION = type(IAggregation).interfaceId;
    bytes4 internal constant INTERFACE_SETTLEMENT = type(ISettlement).interfaceId;
    bytes4 internal constant INTERFACE_DISPUTES = type(IDisputes).interfaceId;
    bytes4 internal constant INTERFACE_REWARDS = type(IRewards).interfaceId;
    bytes4 internal constant INTERFACE_SLASHING = type(ISlashing).interfaceId;
    bytes4 internal constant INTERFACE_TREASURY = type(ITreasury).interfaceId;
    bytes4 internal constant INTERFACE_REPUTATION_ROOTS = type(IReputationRoots).interfaceId;
    bytes4 internal constant INTERFACE_GOVERNANCE_HOOKS = type(IGovernanceHooks).interfaceId;
    bytes4 internal constant INTERFACE_EMERGENCY_CONTROLS = type(IEmergencyControls).interfaceId;

    uint256 internal constant DEPENDENCY_EDGE_COUNT = 11;
    uint16 internal constant MIN_MAJOR = 2;
    uint16 internal constant MIN_MINOR = 0;

    /// @notice Returns the 14 stable canonical module keys in manifest order.
    function canonicalModuleIds() internal pure returns (bytes32[14] memory ids) {
        ids[0] = MODULE_CONFIGURATION;
        ids[1] = MODULE_CLAIMS;
        ids[2] = MODULE_EVIDENCE;
        ids[3] = MODULE_STAKE_CUSTODY;
        ids[4] = MODULE_VERIFICATION;
        ids[5] = MODULE_AGGREGATION;
        ids[6] = MODULE_SETTLEMENT;
        ids[7] = MODULE_DISPUTES;
        ids[8] = MODULE_REWARDS;
        ids[9] = MODULE_SLASHING;
        ids[10] = MODULE_TREASURY;
        ids[11] = MODULE_REPUTATION_ROOTS;
        ids[12] = MODULE_GOVERNANCE_HOOKS;
        ids[13] = MODULE_EMERGENCY_CONTROLS;
    }

    /// @notice True when the key is part of the canonical manifest.
    function isCanonicalKey(bytes32 moduleId) internal pure returns (bool) {
        bytes32[14] memory ids = canonicalModuleIds();
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] == moduleId) return true;
        }
        return false;
    }

    /// @notice The canonical interface ID expected for a module key (0 if unknown).
    function canonicalInterfaceOf(bytes32 moduleId) internal pure returns (bytes4 interfaceId) {
        if (moduleId == MODULE_CONFIGURATION) return INTERFACE_CONFIGURATION;
        if (moduleId == MODULE_CLAIMS) return INTERFACE_CLAIMS;
        if (moduleId == MODULE_EVIDENCE) return INTERFACE_EVIDENCE;
        if (moduleId == MODULE_STAKE_CUSTODY) return INTERFACE_STAKE_CUSTODY;
        if (moduleId == MODULE_VERIFICATION) return INTERFACE_VERIFICATION;
        if (moduleId == MODULE_AGGREGATION) return INTERFACE_AGGREGATION;
        if (moduleId == MODULE_SETTLEMENT) return INTERFACE_SETTLEMENT;
        if (moduleId == MODULE_DISPUTES) return INTERFACE_DISPUTES;
        if (moduleId == MODULE_REWARDS) return INTERFACE_REWARDS;
        if (moduleId == MODULE_SLASHING) return INTERFACE_SLASHING;
        if (moduleId == MODULE_TREASURY) return INTERFACE_TREASURY;
        if (moduleId == MODULE_REPUTATION_ROOTS) return INTERFACE_REPUTATION_ROOTS;
        if (moduleId == MODULE_GOVERNANCE_HOOKS) return INTERFACE_GOVERNANCE_HOOKS;
        if (moduleId == MODULE_EMERGENCY_CONTROLS) return INTERFACE_EMERGENCY_CONTROLS;
        return bytes4(0);
    }

    /// @notice Canonical dependency edgeset. `satisfied` is populated by the caller.
    function canonicalDependencies()
        internal
        pure
        returns (IModuleRegistry.Dependency[11] memory dependencies)
    {
        dependencies[0] = _dep(MODULE_EVIDENCE, MODULE_CLAIMS);
        dependencies[1] = _dep(MODULE_VERIFICATION, MODULE_CLAIMS);
        dependencies[2] = _dep(MODULE_VERIFICATION, MODULE_EVIDENCE);
        dependencies[3] = _dep(MODULE_VERIFICATION, MODULE_STAKE_CUSTODY);
        dependencies[4] = _dep(MODULE_AGGREGATION, MODULE_VERIFICATION);
        dependencies[5] = _dep(MODULE_SETTLEMENT, MODULE_AGGREGATION);
        dependencies[6] = _dep(MODULE_SETTLEMENT, MODULE_STAKE_CUSTODY);
        dependencies[7] = _dep(MODULE_DISPUTES, MODULE_CLAIMS);
        dependencies[8] = _dep(MODULE_DISPUTES, MODULE_VERIFICATION);
        dependencies[9] = _dep(MODULE_REWARDS, MODULE_SETTLEMENT);
        dependencies[10] = _dep(MODULE_REWARDS, MODULE_TREASURY);
    }

    /// @notice The minimum protocol version a required dependency must satisfy.
    function dependencyRequirement(bytes32 moduleId, bytes32 requiredModuleId)
        internal
        pure
        returns (uint16 minMajor, uint16 minMinor, bool exists)
    {
        IModuleRegistry.Dependency[11] memory edges = canonicalDependencies();
        for (uint256 i = 0; i < edges.length; ++i) {
            if (edges[i].moduleId == moduleId && edges[i].requiredModuleId == requiredModuleId) {
                return (edges[i].minMajor, edges[i].minMinor, true);
            }
        }
        return (0, 0, false);
    }

    /// @notice Deterministic version ID for a module registration.
    function versionIdOf(
        bytes32 moduleId,
        bytes4 interfaceId,
        address proxy,
        address implementation,
        uint16 major,
        uint16 minor
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(moduleId, interfaceId, proxy, implementation, major, minor));
    }

    /// @notice True when the supplied registration version is the canonical release major.
    function isReleaseCompatible(uint16 major) internal pure returns (bool) {
        return major == 2;
    }

    function _dep(bytes32 moduleId, bytes32 requiredModuleId)
        private
        pure
        returns (IModuleRegistry.Dependency memory)
    {
        return IModuleRegistry.Dependency({
            moduleId: moduleId,
            requiredModuleId: requiredModuleId,
            minMajor: MIN_MAJOR,
            minMinor: MIN_MINOR,
            satisfied: false
        });
    }
}
