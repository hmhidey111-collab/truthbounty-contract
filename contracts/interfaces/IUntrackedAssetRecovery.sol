// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IUntrackedAssetRecovery
/// @notice Additive governed recovery extension. address(0) denotes forced native currency.
/// @dev Never changes a stake, bond, reward, withdrawal, deferred claim, insurance or treasury liability.
interface IUntrackedAssetRecovery {
    enum RecoveryStatus {
        NONE,
        QUEUED,
        EXECUTED,
        CANCELLED
    }

    struct RecoveryRequest {
        address asset;
        address recipient;
        uint256 amount;
        uint256 executableAt;
        uint256 status;
    }

    error InvalidRecoveryRequest();
    error RecoveryAlreadyExists(bytes32 operationId);
    error RecoveryNotQueued(bytes32 operationId);
    error RecoveryTimelockActive(uint256 executableAt);
    error RecoveryExceedsUntrackedBalance(address asset, uint256 requested, uint256 available);
    error RecoveryTransferMismatch(address asset);
    error RecoveryNativeTransferFailed();
    error RecoveryReentrancy();
    error RecoveryPaused();
    error RecoveryAuthorityUnavailable();

    event AssetRecoveryQueuedV2(
        bytes32 indexed operationId,
        address indexed asset,
        address indexed recipient,
        uint256 amount,
        address authority,
        uint256 executableAt,
        uint256 availableBalance
    );
    event AssetRecoveryExecutedV2(
        bytes32 indexed operationId,
        address indexed asset,
        address indexed recipient,
        uint256 amount,
        address authority,
        uint256 availableBalance
    );
    event AssetRecoveryCancelledV2(bytes32 indexed operationId, address indexed authority);

    /// @notice Current on-chain balance minus every reserved liability, clamped to zero if insolvent.
    function recoverableBalance(address asset) external view returns (uint256);
    /// @notice Queue an exact request; execution must independently satisfy the live reserve bound.
    function queueAssetRecovery(address asset, address recipient, uint256 amount, bytes32 salt)
        external
        returns (bytes32 operationId);
    /// @notice Execute a queued request after the mandatory delay, with current governance authority.
    function executeAssetRecovery(bytes32 operationId) external;
    /// @notice Cancel a queued request, including while paused. Its operation ID cannot be reused.
    function cancelAssetRecovery(bytes32 operationId) external;
}
