// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UntrackedAssetRecovery} from "../recovery/UntrackedAssetRecovery.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IRewardDeferralQueue.sol";
import "./RewardEngine.sol";

/**
 * @title RewardDeferralQueue
 * @notice Manages a queue of reward distributions that could not be immediately
 *         fulfilled by the RewardEngine because the pool was exhausted.
 *
 * Design principles
 * -----------------
 * - The contract holds *no* tokens itself.  All token movement goes through
 *   RewardEngine.allocateReward(), which this contract calls via its
 *   DISTRIBUTOR_ROLE on the engine.
 * - Each queue entry has a unique queueId that prevents replay.
 * - Fulfillment is permissionless once the pool balance is sufficient.
 * - Only DEFAULT_ADMIN_ROLE may cancel an entry.
 *
 * Roles
 * -----
 * DEFAULT_ADMIN_ROLE  – can cancel entries and grant / revoke all roles.
 * ENQUEUE_ROLE        – can add entries to the queue.
 */
contract RewardDeferralQueue is IRewardDeferralQueue, AccessControl, ReentrancyGuard, UntrackedAssetRecovery {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Role required to enqueue new reward entries.
    bytes32 public constant ENQUEUE_ROLE = keccak256("ENQUEUE_ROLE");

    /// @notice Maximum number of entries that can be fulfilled in a single batch call.
    uint256 public constant MAX_BATCH = 50;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice The attached RewardEngine.  This contract must hold DISTRIBUTOR_ROLE
    ///         on the engine in order to call allocateReward().
    RewardEngine public immutable engine;

    /// @dev Auto-incrementing nonce used to make queueIds unique even when all
    ///      other parameters are identical.
    uint256 private _nonce;

    /// @notice All queued reward data keyed by queueId.
    mapping(bytes32 => PendingReward) private _queue;

    /// @notice Ordered list of all queueIds for enumeration.
    bytes32[] private _pendingQueueIds;

    /// @notice Running total of entries added (equals _pendingQueueIds.length).
    uint256 public override totalEnqueued;

    /// @notice Running total of entries fulfilled.
    uint256 public override totalFulfilled;

    /// @notice Running total of entries cancelled.
    uint256 public override totalCancelled;

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @param _engine      Address of the deployed RewardEngine.
     * @param initialAdmin Address that receives DEFAULT_ADMIN_ROLE and can
     *                     grant ENQUEUE_ROLE to callers.
     */
    constructor(address _engine, address initialAdmin) {
        require(_engine != address(0), "RewardDeferralQueue: zero engine");
        require(initialAdmin != address(0), "RewardDeferralQueue: zero admin");

        engine = RewardEngine(_engine);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    // =========================================================================
    // Mutating: Enqueue
    // =========================================================================

    /**
     * @inheritdoc IRewardDeferralQueue
     */
    function enqueue(
        address recipient,
        uint256 claimId,
        bytes32 settlementId,
        bytes32 calculationId,
        uint256 amount
    ) external override onlyRole(ENQUEUE_ROLE) returns (bytes32 queueId) {
        if (recipient == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroAmount();

        // Derive a unique queueId that incorporates a monotonically increasing
        // nonce so that the same (recipient, claimId, settlementId, calculationId)
        // parameters can legitimately be enqueued multiple times.
        uint256 currentNonce = _nonce;
        unchecked {
            _nonce = currentNonce + 1;
        }

        queueId = keccak256(
            abi.encode(
                recipient,
                claimId,
                settlementId,
                calculationId,
                block.timestamp,
                currentNonce
            )
        );

        _queue[queueId] = PendingReward({
            recipient: recipient,
            claimId: claimId,
            settlementId: settlementId,
            calculationId: calculationId,
            amount: amount,
            enqueuedAt: block.timestamp,
            status: QueueStatus.PENDING
        });

        _pendingQueueIds.push(queueId);

        unchecked {
            totalEnqueued++;
        }

        emit RewardEnqueued(queueId, recipient, claimId, amount);
    }

    // =========================================================================
    // Mutating: Fulfill
    // =========================================================================

    /**
     * @inheritdoc IRewardDeferralQueue
     */
    function fulfill(bytes32 queueId) external override nonReentrant {
        _fulfillEntry(queueId);
    }

    /**
     * @inheritdoc IRewardDeferralQueue
     */
    function fulfillBatch(bytes32[] calldata queueIds) external override nonReentrant {
        uint256 length = queueIds.length;
        if (length > MAX_BATCH) revert BatchTooLarge(length, MAX_BATCH);

        uint256 processed;
        uint256 failed;

        for (uint256 i = 0; i < length; ) {
            // Each entry is fulfilled individually so a single pool-exhaustion
            // does not revert the whole batch – we simply count the failure.
            bytes32 id = queueIds[i];
            PendingReward storage entry = _queue[id];

            // Skip non-existent or already-terminal entries.
            if (entry.enqueuedAt == 0) {
                unchecked {
                    ++failed;
                    ++i;
                }
                continue;
            }
            if (entry.status != QueueStatus.PENDING) {
                unchecked {
                    ++failed;
                    ++i;
                }
                continue;
            }

            // Check pool balance before attempting fulfillment.
            uint256 available = engine.availableRewardBalance();
            if (available < entry.amount) {
                unchecked {
                    ++failed;
                    ++i;
                }
                continue;
            }

            // Perform the actual fulfillment in isolation. A hostile or
            // false-returning recipient must not revert the whole batch and block
            // every other entry (SC-051).
            address recipient = entry.recipient;
            uint256 amount = entry.amount;
            uint256 claimId = entry.claimId;
            bytes32 settlementId = entry.settlementId;
            bytes32 calculationId = entry.calculationId;

            // CEI: mark before the external call so reentrancy cannot double-fulfill.
            entry.status = QueueStatus.FULFILLED;
            unchecked {
                ++totalFulfilled;
            }

            try engine.allocateReward(
                recipient,
                claimId,
                settlementId,
                calculationId,
                amount,
                true
            ) {
                emit RewardFulfilled(id, recipient, amount);
                unchecked {
                    ++processed;
                }
            } catch {
                // Delivery failed. Restore PENDING so the entitlement is preserved
                // (owed exactly once) and can be retried by anyone once the recipient
                // can receive tokens. The engine call is atomic: a reverted attempt
                // leaves no on-chain record, so the retry cannot double-pay.
                entry.status = QueueStatus.PENDING;
                unchecked {
                    --totalFulfilled;
                    ++failed;
                }
                emit RewardFulfillmentDeferred(id, recipient, amount);
            }

            unchecked {
                ++i;
            }
        }

        emit BatchFulfillCompleted(processed, failed);
    }

    // =========================================================================
    // Mutating: Cancel
    // =========================================================================

    /**
     * @inheritdoc IRewardDeferralQueue
     */
    function cancelEnqueued(bytes32 queueId) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingReward storage entry = _queue[queueId];

        if (entry.enqueuedAt == 0) revert QueueEntryNotFound(queueId);
        if (entry.status == QueueStatus.FULFILLED) revert AlreadyFulfilled(queueId);
        if (entry.status == QueueStatus.CANCELLED) revert AlreadyCancelled(queueId);

        entry.status = QueueStatus.CANCELLED;

        unchecked {
            totalCancelled++;
        }

        emit RewardCancelled(queueId, entry.recipient, entry.amount);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /**
     * @inheritdoc IRewardDeferralQueue
     */
    function pendingEntry(bytes32 queueId) external view override returns (PendingReward memory entry) {
        entry = _queue[queueId];
        if (entry.enqueuedAt == 0) revert QueueEntryNotFound(queueId);
    }

    /**
     * @inheritdoc IRewardDeferralQueue
     */
    function queueLength() external view override returns (uint256) {
        return _pendingQueueIds.length;
    }

    /**
     * @inheritdoc IRewardDeferralQueue
     */
    function isPending(bytes32 queueId) external view override returns (bool) {
        PendingReward storage entry = _queue[queueId];
        return entry.enqueuedAt != 0 && entry.status == QueueStatus.PENDING;
    }

    /**
     * @inheritdoc IRewardDeferralQueue
     */
    function isFulfilled(bytes32 queueId) external view override returns (bool) {
        return _queue[queueId].status == QueueStatus.FULFILLED;
    }

    /**
     * @inheritdoc IRewardDeferralQueue
     */
    function canFulfill(bytes32 queueId) external view override returns (bool) {
        PendingReward storage entry = _queue[queueId];
        if (entry.enqueuedAt == 0) return false;
        if (entry.status != QueueStatus.PENDING) return false;
        return engine.availableRewardBalance() >= entry.amount;
    }

    /**
     * @notice Return the queueId at position `index` in the global ordered list.
     * @param index Zero-based index.
     */
    function queueIdAt(uint256 index) external view returns (bytes32) {
        return _pendingQueueIds[index];
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /**
     * @dev Validates and fulfills a single queue entry (called from the
     *      non-batch path).  Reverts on any precondition failure.
     */
    function _fulfillEntry(bytes32 queueId) internal {
        PendingReward storage entry = _queue[queueId];

        if (entry.enqueuedAt == 0) revert QueueEntryNotFound(queueId);
        if (entry.status == QueueStatus.FULFILLED) revert AlreadyFulfilled(queueId);
        if (entry.status == QueueStatus.CANCELLED) revert AlreadyCancelled(queueId);

        uint256 available = engine.availableRewardBalance();
        if (available < entry.amount) {
            revert InsufficientPoolForFulfillment(queueId, entry.amount, available);
        }

        _fulfillStorageEntry(queueId, entry);
    }

    /**
     * @dev Core fulfillment logic: calls RewardEngine.allocateReward() with
     *      `immediate = true` so the token is transferred directly.  Updates
     *      the entry status and emits events.
     *
     *      Note: The queue entry's (settlementId, calculationId) are reused
     *      verbatim.  The RewardEngine's own processedSettlements mapping will
     *      reject any duplicate (recipient, claimId, settlementId, calculationId)
     *      combination, providing a second layer of replay protection.
     */
    function _fulfillStorageEntry(bytes32 queueId, PendingReward storage entry) internal {
        address recipient = entry.recipient;
        uint256 amount = entry.amount;

        // Mark fulfilled before external call to prevent reentrancy.
        entry.status = QueueStatus.FULFILLED;

        unchecked {
            totalFulfilled++;
        }

        // Delegate actual token movement to the engine.
        // The engine requires this contract to hold DISTRIBUTOR_ROLE.
        engine.allocateReward(
            recipient,
            entry.claimId,
            entry.settlementId,
            entry.calculationId,
            amount,
            true  // immediate – transfer tokens directly to recipient
        );

        emit RewardFulfilled(queueId, recipient, amount);
    }

    // V2-SC-154: additive recovery only; existing liability and authority paths remain authoritative.
    function _checkAssetRecoveryAuthority() internal view override {
        if (!engine.hasRole(engine.GOVERNANCE_ROLE(), msg.sender) || !engine.governanceEnabled()) {
            revert RecoveryAuthorityUnavailable();
        }
    }

    function _requireAssetRecoveryAllowed() internal view override {
        if (engine.paused()) revert RecoveryPaused();
    }

    function _reservedAssetBalance(address) internal pure override returns (uint256) {
        // This queue holds metadata only. Every deferred entitlement is reserved at the engine.
        return 0;
    }
}
