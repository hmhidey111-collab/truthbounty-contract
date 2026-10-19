// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";

/// @notice Governance authorization hook for one-shot module actions.
/// @dev Authorization is bound to action, target, selector, and calldata hash. Consumption must be atomic and one-shot unless the implementation explicitly models reuse.
interface IGovernanceHooks is IV2Module {
    /// @notice Emitted when governance authorizes an action.
    /// @param actionId Stable action identifier.
    /// @param target Contract the action may call.
    /// @param selector Function selector, or zero for a target-wide authorization as defined by implementation.
    event GovernanceActionAuthorized(bytes32 indexed actionId, address indexed target, bytes4 indexed selector);

    /// @notice Emitted when an authorization is consumed.
    /// @param actionId Stable action identifier.
    /// @param target Contract called.
    /// @param selector Function selector consumed.
    event GovernanceActionConsumed(bytes32 indexed actionId, address indexed target, bytes4 indexed selector);

    /// @notice Authorizes a precisely bound governance action.
    /// @dev Must be called by the configured governance authority and must reject zero target, expired actions, or conflicting data hashes.
    /// @param actionId Stable action identifier.
    /// @param target Exact target contract.
    /// @param selector Exact function selector.
    /// @param dataHash Hash of the complete calldata or policy-defined payload.
    function authorize(bytes32 actionId, address target, bytes4 selector, bytes32 dataHash) external;

    /// @notice Consumes an authorization immediately before the authorized call.
    /// @dev Must verify every bound field and prevent replay; the entire transaction must revert if the subsequent target call fails.
    /// @param actionId Stable action identifier.
    /// @param target Exact target contract.
    /// @param selector Exact function selector.
    /// @param dataHash Hash of the complete calldata or policy-defined payload.
    function consume(bytes32 actionId, address target, bytes4 selector, bytes32 dataHash) external;

    /// @notice Reports whether an action is currently authorized.
    /// @param actionId Stable action identifier.
    /// @param target Exact target contract.
    /// @param selector Exact function selector.
    /// @param dataHash Exact payload hash.
    /// @return authorized True only when all fields match an unconsumed authorization.
    function isAuthorized(bytes32 actionId, address target, bytes4 selector, bytes32 dataHash) external view returns (bool authorized);
}
