// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "../../contracts/v2/interfaces/IV2Module.sol";

/// @notice Minimal key -> address lookup surface that StakeVault and FinalRewardAllocator consult
///         (`isRegistered` / `module`). Hand-rolled test registries implement only this subset of
///         `IModuleRegistry` so they can model adversarial lookup behaviour without stubbing the
///         full versioned registration lifecycle.
interface IModuleLookupStub is IV2Module {
    event ModuleRegistered(bytes32 indexed moduleId, address indexed implementation, uint16 major, uint16 minor);
    event ModuleRemoved(bytes32 indexed moduleId, address indexed implementation);

    function registerModule(bytes32 moduleId, address implementation) external;
    function removeModule(bytes32 moduleId) external;
    function module(bytes32 moduleId) external view returns (address implementation, uint16 major, uint16 minor);
    function isRegistered(bytes32 moduleId) external view returns (bool registered);
}
