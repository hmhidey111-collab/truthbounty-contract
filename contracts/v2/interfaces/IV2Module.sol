// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Common discovery surface for every TruthBounty V2 module.
/// @dev Implementations MUST return true for `type(IV2Module).interfaceId` and their concrete module interface ID. The version identifies the module ABI, not an on-chain governance parameter set.
interface IV2Module is IERC165 {
    /// @notice Returns the immutable ABI version implemented by this module.
    /// @dev Declared `view` (not `pure`) so implementations can read version-bearing immutables;
    ///      the function selector and IV2Module interface ID are unaffected by mutability.
    ///      The pair is a compatibility tuple: consumers must reject unsupported major versions and may permit compatible minor versions according to deployment policy.
    /// @return major ABI major version.
    /// @return minor ABI minor version.
    function protocolVersion() external view returns (uint16 major, uint16 minor);
}
