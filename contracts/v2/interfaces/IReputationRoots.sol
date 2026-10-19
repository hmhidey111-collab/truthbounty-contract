// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";

/// @notice Versioned reputation root proposal and proof interface.
/// @dev Roots are epoch-scoped commitments to off-chain Merkle data. Proof verification must use the implementation's exact leaf and node encoding and fails closed on malformed proofs.
interface IReputationRoots is IV2Module {
    /// @notice Emitted when a root is proposed for an epoch.
    /// @param epoch Reputation epoch.
    /// @param root Merkle root commitment.
    /// @param proposer Authorized proposer.
    event RootProposed(uint256 indexed epoch, bytes32 indexed root, address indexed proposer);

    /// @notice Emitted when a proposed root is accepted.
    /// @param epoch Reputation epoch.
    /// @param root Accepted Merkle root.
    event RootAccepted(uint256 indexed epoch, bytes32 indexed root);

    /// @notice Proposes a root and its metadata URI for an epoch.
    /// @dev Must be authorized, reject duplicate or superseded roots as configured, and never treat an unaccepted proposal as canonical.
    /// @param epoch Monotonic reputation epoch.
    /// @param root Merkle root commitment.
    /// @param uri Off-chain metadata locator; the EVM does not fetch it.
    function proposeRoot(uint256 epoch, bytes32 root, string calldata uri) external;

    /// @notice Accepts the proposed root for an epoch.
    /// @dev Must be controlled by the configured acceptance authority and must fail closed if no unique proposal exists.
    /// @param epoch Epoch to accept.
    function acceptRoot(uint256 epoch) external;

    /// @notice Reads the root recorded for an epoch.
    /// @param epoch Epoch to inspect.
    /// @return root Recorded root, or zero when absent.
    /// @return accepted True only after the root is accepted.
    function rootAt(uint256 epoch) external view returns (bytes32 root, bool accepted);

    /// @notice Verifies an account score against an accepted Merkle root.
    /// @dev Malformed or inconsistent proofs return false or revert according to implementation policy; this call has no state effects.
    /// @param epoch Epoch whose root must be accepted.
    /// @param account Leaf account.
    /// @param score Score to verify in the root's defined units.
    /// @param proof Ordered Merkle sibling nodes using the implementation's canonical encoding.
    /// @return valid True only when account and score authenticate to the accepted root.
    function verify(uint256 epoch, address account, uint256 score, bytes32[] calldata proof) external view returns (bool valid);
}
