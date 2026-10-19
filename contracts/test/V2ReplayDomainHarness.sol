// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { V2ReplayDomain } from "../v2/libraries/V2ReplayDomain.sol";

/// @title V2ReplayDomainHarness
/// @notice Test-only surface that exposes the internal `V2ReplayDomain` helpers to external
///         callers so the digest, the live chain-id binding, and the fail-closed validations can
///         be driven from both Foundry and Hardhat tests.
/// @dev This contract carries no protocol authority and is never part of a canonical V2 deployment
///      manifest; it exists solely to make a pure library externally callable.
contract V2ReplayDomainHarness {
    /// @notice Returns the canonical domain version implemented by the library.
    function domainVersion() external pure returns (uint16) {
        return V2ReplayDomain.REPLAY_DOMAIN_VERSION;
    }

    /// @notice Returns the canonical signed-operation type hash.
    function typehash() external pure returns (bytes32) {
        return V2ReplayDomain.SIGNED_OPERATION_TYPEHASH;
    }

    /// @notice Computes the explicit-chain-id digest via the library.
    function digest(
        bytes32 actionType,
        address verifyingContract,
        uint256 chainId,
        uint16 version,
        address signer,
        uint256 entityId,
        uint256 nonce,
        uint256 deadline
    ) external pure returns (bytes32) {
        return V2ReplayDomain.digest(actionType, verifyingContract, chainId, version, signer, entityId, nonce, deadline);
    }

    /// @notice Computes the digest bound to this contract and the live `block.chainid`.
    function liveDigest(
        bytes32 actionType,
        address signer,
        uint256 entityId,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return V2ReplayDomain.liveDigest(actionType, address(this), signer, entityId, nonce, deadline);
    }

    /// @notice Reverts through `requireNotExpired` so the expiry guard is externally observable.
    function requireNotExpired(uint256 deadline, uint256 nowTs) external pure {
        V2ReplayDomain.requireNotExpired(deadline, nowTs);
    }

    /// @notice Reverts through `requireVersion` so the version guard is externally observable.
    function requireVersion(uint16 version) external pure {
        V2ReplayDomain.requireVersion(version);
    }
}
