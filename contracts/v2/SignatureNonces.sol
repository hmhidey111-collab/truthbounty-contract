// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SignatureNonces
/// @notice Bitmap nonce management for V2 protocol signatures: single-use consumption, owner cancellation,
///         and deadline expiry. Nonces are unordered, so independent signatures never block each other.
/// @dev Inheriting modules must call `_useCheckedNonce` before acting on any signed payload that
///      commits to `(owner, nonce, deadline)`.
abstract contract SignatureNonces {
    /// @dev owner => word index => bitmap of used/cancelled nonces.
    mapping(address => mapping(uint256 => uint256)) private _nonceBitmap;

    /// @notice Emitted when a nonce is consumed by a valid signature.
    event NonceConsumed(address indexed owner, uint256 indexed nonce);

    /// @notice Emitted when an owner cancels a nonce before use.
    event NonceCancelled(address indexed owner, uint256 indexed nonce);

    /// @notice Thrown when a nonce has already been consumed or cancelled.
    error NonceAlreadyUsed(address owner, uint256 nonce);

    /// @notice Thrown when a signature deadline has passed.
    error SignatureExpired(uint256 deadline);

    /// @notice Returns whether `nonce` is consumed or cancelled for `owner`.
    function isNonceUsed(address owner, uint256 nonce) public view returns (bool) {
        return _nonceBitmap[owner][nonce >> 8] & (1 << (nonce & 0xff)) != 0;
    }

    /// @notice Cancels an unused nonce so any signature committing to it can never be replayed.
    function cancelNonce(uint256 nonce) external {
        _useNonce(msg.sender, nonce);
        emit NonceCancelled(msg.sender, nonce);
    }

    /// @notice Validates the deadline and consumes the nonce; reverts on expiry or reuse.
    function _useCheckedNonce(address owner, uint256 nonce, uint256 deadline) internal {
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        _useNonce(owner, nonce);
        emit NonceConsumed(owner, nonce);
    }

    function _useNonce(address owner, uint256 nonce) private {
        uint256 bit = 1 << (nonce & 0xff);
        uint256 word = _nonceBitmap[owner][nonce >> 8];
        if (word & bit != 0) revert NonceAlreadyUsed(owner, nonce);
        _nonceBitmap[owner][nonce >> 8] = word | bit;
    }
}
