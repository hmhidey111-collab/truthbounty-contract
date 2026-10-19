// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BoundedSafeERC20 } from "../libraries/BoundedSafeERC20.sol";
import { IUntrackedAssetRecovery } from "../interfaces/IUntrackedAssetRecovery.sol";

/// @title UntrackedAssetRecovery
/// @notice Exact, delayed recovery of provably untracked ERC-20 or forced native balances.
/// @dev Storage-free linear inheritance: all recovery state lives in an ERC-7201 namespace.
///      Existing governance roles authorize requests; even bootstrap administrators cannot skip
///      the immutable two-day delay. Execution rechecks current authority, pauses and liabilities.
///      Hosts must include ALL asset obligations, including disabled assets, unallocated reward
///      funding, deferred rewards, final withdrawals and protocol-owned reserves. Unknown or
///      unprovable reserves must be protected in full. This extension has no arbitrary-call path.
///      Supplemental aggregates are initialized by normal funding flows on new deployments.
///      Existing custody instances require a separately reviewed historical reconciliation and
///      migration before this extension can be used; preserving linear slots alone is insufficient.
abstract contract UntrackedAssetRecovery is IUntrackedAssetRecovery {
    using BoundedSafeERC20 for IERC20;

    uint256 internal constant ASSET_RECOVERY_DELAY = 2 days;

    /// @custom:storage-location erc7201:truthbounty.storage.UntrackedAssetRecovery
    struct RecoveryStorage {
        mapping(bytes32 => RecoveryRequest) requests;
        uint256 entered;
        mapping(address => uint256) liabilities;
        mapping(address => bool) protectedAssets;
    }

    bytes32 private constant RECOVERY_STORAGE_LOCATION =
        0x8abeb0ad347321658a4d7cc2487ac49bf93a4796020f063a988a3b2e73a14900;

    modifier recoveryNonReentrant() {
        RecoveryStorage storage state = _recoveryStorage();
        if (state.entered != 0) revert RecoveryReentrancy();
        state.entered = 1;
        _;
        state.entered = 0;
    }

    function recoverableBalance(address asset) public view returns (uint256) {
        uint256 balance = _recoveryBalance(asset);
        uint256 reserved = asset == address(0) ? 0 : _reservedAssetBalance(asset);
        // The comparison proves subtraction cannot underflow.
        unchecked {
            return balance > reserved ? balance - reserved : 0;
        }
    }

    function queueAssetRecovery(address asset, address recipient, uint256 amount, bytes32 salt)
        external
        returns (bytes32 operationId)
    {
        _checkAssetRecoveryAuthority();
        _requireAssetRecoveryAllowed();
        if (recipient == address(0) || recipient == address(this) || amount == 0) revert InvalidRecoveryRequest();
        uint256 available = recoverableBalance(asset);
        if (amount > available) revert RecoveryExceedsUntrackedBalance(asset, amount, available);
        operationId = keccak256(abi.encode(address(this), block.chainid, asset, recipient, amount, salt));
        RecoveryRequest storage request = _recoveryStorage().requests[operationId];
        if (request.status != uint256(RecoveryStatus.NONE)) revert RecoveryAlreadyExists(operationId);
        uint256 executableAt = block.timestamp + ASSET_RECOVERY_DELAY;
        request.asset = asset;
        request.recipient = recipient;
        request.amount = amount;
        request.executableAt = executableAt;
        request.status = uint256(RecoveryStatus.QUEUED);
        emit AssetRecoveryQueuedV2(operationId, asset, recipient, amount, msg.sender, executableAt, available);
    }

    function executeAssetRecovery(bytes32 operationId) external recoveryNonReentrant {
        _checkAssetRecoveryAuthority();
        _requireAssetRecoveryAllowed();
        RecoveryRequest storage request = _recoveryStorage().requests[operationId];
        if (request.status != uint256(RecoveryStatus.QUEUED)) revert RecoveryNotQueued(operationId);
        if (block.timestamp < request.executableAt) revert RecoveryTimelockActive(request.executableAt);
        address asset = request.asset;
        address recipient = request.recipient;
        uint256 amount = request.amount;
        uint256 beforeBalance = _recoveryBalance(asset);
        uint256 reserved = asset == address(0) ? 0 : _reservedAssetBalance(asset);
        uint256 available = beforeBalance > reserved ? beforeBalance - reserved : 0;
        if (amount > available) revert RecoveryExceedsUntrackedBalance(asset, amount, available);
        request.status = uint256(RecoveryStatus.EXECUTED);
        if (asset == address(0)) {
            (bool success,) = recipient.call{ value: amount }("");
            if (!success) revert RecoveryNativeTransferFailed();
        } else {
            uint256 recipientBefore = IERC20(asset).balanceOf(recipient);
            IERC20(asset).safeTransfer(recipient, amount);
            uint256 recipientAfter = IERC20(asset).balanceOf(recipient);
            if (recipientAfter != recipientBefore + amount || _reservedAssetBalance(asset) != reserved) {
                revert RecoveryTransferMismatch(asset);
            }
        }
        // Reject sender-tax/rebase tokens and callbacks that move this asset or alter its liabilities.
        // Any failed transfer/check rolls back the status, all token effects and all callback effects.
        uint256 afterBalance = _recoveryBalance(asset);
        // amount <= available <= beforeBalance was established before the interaction.
        unchecked {
            if (afterBalance != beforeBalance - amount || afterBalance < reserved) {
                revert RecoveryTransferMismatch(asset);
            }
            emit AssetRecoveryExecutedV2(operationId, asset, recipient, amount, msg.sender, afterBalance - reserved);
        }
    }

    function cancelAssetRecovery(bytes32 operationId) external {
        _checkAssetRecoveryAuthority();
        RecoveryRequest storage request = _recoveryStorage().requests[operationId];
        if (request.status != uint256(RecoveryStatus.QUEUED)) revert RecoveryNotQueued(operationId);
        request.status = uint256(RecoveryStatus.CANCELLED);
        emit AssetRecoveryCancelledV2(operationId, msg.sender);
    }

    function _recoveryBalance(address asset) private view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        // A non-token or missing contract cannot return a decodable IERC20 balance and fails closed.
        return IERC20(asset).balanceOf(address(this));
    }

    function _recoveryStorage() private pure returns (RecoveryStorage storage state) {
        bytes32 slot = RECOVERY_STORAGE_LOCATION;
        assembly ("memory-safe") { state.slot := slot }
    }

    function _recoveryReserved(address asset) internal view returns (uint256) {
        return _recoveryStorage().liabilities[asset];
    }

    function _increaseRecoveryReserve(address asset, uint256 amount) internal {
        _recoveryStorage().liabilities[asset] += amount;
    }

    function _decreaseRecoveryReserve(address asset, uint256 amount) internal {
        _recoveryStorage().liabilities[asset] -= amount;
    }

    function _protectRecoveryAsset(address asset) internal {
        _recoveryStorage().protectedAssets[asset] = true;
    }

    function _isProtectedRecoveryAsset(address asset) internal view returns (bool) {
        return _recoveryStorage().protectedAssets[asset];
    }

    function _checkAssetRecoveryAuthority() internal view virtual;
    function _requireAssetRecoveryAllowed() internal view virtual;
    function _reservedAssetBalance(address asset) internal view virtual returns (uint256);
}
