// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IGovernedModuleRegistry
 * @notice Canonical registry of module addresses that governance may target.
 * @dev The registry is an allowlist, not an execution grant: the timelock remains the only governance execution path.
 */
interface IGovernedModuleRegistry {
    /// @notice Emitted when a module is added to the governance allowlist.
    /// @param module Module address added.
    /// @param moduleKey Module key; keys may be reused and are not guaranteed unique.
    event GovernedModuleRegistered(address indexed module, bytes32 indexed moduleKey);

    /// @notice Emitted when a module is removed from the governance allowlist.
    /// @param module Module address removed.
    /// @param moduleKey Module key; keys may be reused and are not guaranteed unique.
    event GovernedModuleRemoved(address indexed module, bytes32 indexed moduleKey);

    /// @notice Module key is not registered.
    /// @param module Address requested for removal.
    error ModuleNotRegistered(address module);

    /// @notice Module address is already registered.
    /// @param module Duplicate module address.
    error ModuleAlreadyRegistered(address module);

    /// @notice Module address must not be zero.
    error ZeroModuleAddress();

    /// @notice Adds a module to the governance target allowlist under the registry administrator.
    /// @dev Must reject zero and duplicate addresses; registration does not grant execution authority. Module keys may be reused and are not guaranteed unique; re-registering a key can leave the prior address allowlisted.
    /// @param moduleKey Module key; keys may be reused and are not guaranteed unique.
    /// @param module Non-zero module address.
    function registerModule(bytes32 moduleKey, address module) external;

    /// @notice Removes a module from the governance target allowlist under the registry administrator.
    /// @dev Removal uses an O(n) internal scan and reverts for unknown keys without mutating unrelated entries. Removing a key does not necessarily remove the prior address from the allowlist if the key was reused.
    /// @param moduleKey Module key to remove; keys may be reused and are not guaranteed unique.
    function removeModule(bytes32 moduleKey) external;

    /// @notice Reports whether an address is currently an allowed governance target.
    /// @param module Module address to check.
    /// @return registered True when currently allowlisted.
    function isGovernedModule(address module) external view returns (bool registered);

    /// @notice Reads a module by key.
    /// @param moduleKey Module key; keys may be reused and are not guaranteed unique.
    /// @return module Registered address, or zero when absent.
    function moduleByKey(bytes32 moduleKey) external view returns (address module);

    /// @notice Returns the number of active governed modules.
    /// @return count Active module count.
    function moduleCount() external view returns (uint256 count);

    /// @notice Reads an active governed module by enumeration index.
    /// @dev Reverts through the array bounds check when `index` is out of range.
    /// @param index Zero-based index in the active module array.
    /// @return module Module address at `index`.
    function moduleAt(uint256 index) external view returns (address module);
}
