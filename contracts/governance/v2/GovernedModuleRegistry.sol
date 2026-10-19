// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IGovernedModuleRegistry} from "./IGovernedModuleRegistry.sol";

/**
 * @title GovernedModuleRegistry
 * @notice Maintains the allowlist of contracts that governance proposals may call.
 * @dev Only the timelock (via governance) or admin may mutate the registry during bootstrap.
 */
contract GovernedModuleRegistry is IGovernedModuleRegistry, AccessControl {
    /// @notice Role permitted to mutate the governed module allowlist.
    bytes32 public constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");

    mapping(address => bool) private _isRegistered;
    mapping(bytes32 => address) private _moduleByKey;
    address[] private _modules;

    /// @param admin Bootstrap administrator receiving the default admin and registry admin roles.
    constructor(address admin) {
        if (admin == address(0)) revert ZeroModuleAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRY_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IGovernedModuleRegistry
    function registerModule(bytes32 moduleKey, address module) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (module == address(0)) revert ZeroModuleAddress();
        if (_isRegistered[module]) revert ModuleAlreadyRegistered(module);

        _isRegistered[module] = true;
        _moduleByKey[moduleKey] = module;
        _modules.push(module);

        emit GovernedModuleRegistered(module, moduleKey);
    }

    /// @inheritdoc IGovernedModuleRegistry
    function removeModule(bytes32 moduleKey) external onlyRole(REGISTRY_ADMIN_ROLE) {
        address module = _moduleByKey[moduleKey];
        if (module == address(0)) revert ModuleNotRegistered(module);
        if (!_isRegistered[module]) revert ModuleNotRegistered(module);

        _isRegistered[module] = false;
        delete _moduleByKey[moduleKey];

        uint256 length = _modules.length;
        for (uint256 i = 0; i < length; ++i) {
            if (_modules[i] == module) {
                _modules[i] = _modules[length - 1];
                _modules.pop();
                break;
            }
        }

        emit GovernedModuleRemoved(module, moduleKey);
    }

    /// @inheritdoc IGovernedModuleRegistry
    function isGovernedModule(address module) external view returns (bool) {
        return _isRegistered[module];
    }

    /// @inheritdoc IGovernedModuleRegistry
    function moduleByKey(bytes32 moduleKey) external view returns (address) {
        return _moduleByKey[moduleKey];
    }

    /// @inheritdoc IGovernedModuleRegistry
    function moduleCount() external view returns (uint256) {
        return _modules.length;
    }

    /// @inheritdoc IGovernedModuleRegistry
    function moduleAt(uint256 index) external view returns (address) {
        return _modules[index];
    }
}
