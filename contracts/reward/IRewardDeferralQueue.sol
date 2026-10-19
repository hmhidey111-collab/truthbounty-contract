// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IRewardDeferralQueue
 * @notice Interface for the RewardDeferralQueue contract.
 *         The queue allows rewards that cannot be immediately distributed
 *         (due to pool exhaustion) to be enqueued and fulfilled later once
 *         the pool has been refilled.
 */
interface IRewardDeferralQueue {
    // =========================================================================
    // Enums
    // =========================================================================

    /// @notice Lifecycle state of a queued reward entry.
    enum QueueStatus {
        PENDING,    // 0 – waiting to be fulfilled
        FULFILLED,  // 1 – successfully delivered via RewardEngine
        CANCELLED   // 2 – cancelled by admin before fulfillment
    }

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Immutable record of a pending reward in the queue.
    struct PendingReward {
        address recipient;
        uint256 claimId;
        bytes32 settlementId;
        bytes32 calculationId;
        uint256 amount;
        uint256 enqueuedAt;
        QueueStatus status;
    }

    // =========================================================================
    // Events
    // =========================================================================

    /**
     * @notice Emitted when a new reward entry is added to the queue.
     * @param queueId      Unique identifier for this queue entry.
     * @param recipient    Address that will receive the reward.
     * @param claimId      Claim that triggered the reward.
     * @param amount       Token amount to be distributed.
     */
    event RewardEnqueued(
        bytes32 indexed queueId,
        address indexed recipient,
        uint256 indexed claimId,
        uint256 amount
    );

    /**
     * @notice Emitted when a queued reward is successfully fulfilled.
     * @param queueId   The queue entry that was fulfilled.
     * @param recipient Address that received the reward.
     * @param amount    Token amount distributed.
     */
    event RewardFulfilled(
        bytes32 indexed queueId,
        address indexed recipient,
        uint256 amount
    );

    /**
     * @notice Emitted when an admin cancels a queued reward.
     * @param queueId   The queue entry that was cancelled.
     * @param recipient Address whose reward was cancelled.
     * @param amount    Token amount that will not be distributed.
     */
    event RewardCancelled(
        bytes32 indexed queueId,
        address indexed recipient,
        uint256 amount
    );

    /**
     * @notice Emitted when a queued reward could not be delivered because the recipient
     *         rejected the transfer (hostile / reverting / false-returning). The entry is
     *         left PENDING — it remains owed exactly once and can be retried
     *         permissionlessly once the recipient can receive tokens (SC-051).
     * @param queueId   The queue entry that could not be fulfilled.
     * @param recipient Address whose transfer failed.
     * @param amount    Token amount still owed.
     */
    event RewardFulfillmentDeferred(
        bytes32 indexed queueId,
        address indexed recipient,
        uint256 amount
    );

    /**
     * @notice Emitted after a fulfillBatch call completes.
     * @param processed Number of entries successfully fulfilled.
     * @param failed    Number of entries that could not be fulfilled (pool still
     *                  insufficient, or the recipient rejected the transfer).
     */
    event BatchFulfillCompleted(uint256 processed, uint256 failed);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when a queueId does not map to any entry.
    error QueueEntryNotFound(bytes32 queueId);

    /// @notice Thrown when attempting to fulfill an already-fulfilled entry.
    error AlreadyFulfilled(bytes32 queueId);

    /// @notice Thrown when attempting to fulfill or cancel an already-cancelled entry.
    error AlreadyCancelled(bytes32 queueId);

    /// @notice Thrown when the engine pool has insufficient available balance.
    error InsufficientPoolForFulfillment(bytes32 queueId, uint256 required, uint256 available);

    /// @notice Thrown when a zero address is supplied as recipient.
    error ZeroRecipient();

    /// @notice Thrown when a zero amount is supplied.
    error ZeroAmount();

    /// @notice Thrown when fulfillBatch array exceeds MAX_BATCH.
    error BatchTooLarge(uint256 provided, uint256 maximum);

    /// @notice Thrown when caller lacks the required role.
    error Unauthorized(address caller, bytes32 role);

    // =========================================================================
    // Mutating Functions
    // =========================================================================

    /**
     * @notice Enqueue a reward for later fulfillment.
     *         Caller must hold ENQUEUE_ROLE.
     * @param recipient    Address that will receive the reward.
     * @param claimId      Claim that triggered the reward.
     * @param settlementId Settlement record identifier.
     * @param calculationId Reward calculation identifier.
     * @param amount       Token amount to reserve for distribution.
     * @return queueId     Unique identifier for this queue entry.
     */
    function enqueue(
        address recipient,
        uint256 claimId,
        bytes32 settlementId,
        bytes32 calculationId,
        uint256 amount
    ) external returns (bytes32 queueId);

    /**
     * @notice Fulfill a queued reward if the engine pool has sufficient balance.
     *         Anyone may call this once the pool is refilled.
     * @param queueId Identifier of the entry to fulfill.
     */
    function fulfill(bytes32 queueId) external;

    /**
     * @notice Fulfill multiple queued rewards in a single transaction.
     *         Bounded by MAX_BATCH. Entries are processed independently: an entry that
     *         cannot be delivered (insufficient pool balance or a recipient that rejects
     *         the transfer) is left PENDING and does not block the remaining entries.
     * @param queueIds Array of queue entry identifiers to fulfill.
     */
    function fulfillBatch(bytes32[] calldata queueIds) external;

    /**
     * @notice Cancel a queued reward. Only callable by DEFAULT_ADMIN_ROLE.
     * @param queueId Identifier of the entry to cancel.
     */
    function cancelEnqueued(bytes32 queueId) external;

    // =========================================================================
    // View Functions
    // =========================================================================

    /**
     * @notice Return the full data for a queue entry.
     * @param queueId Identifier of the entry.
     * @return entry  The PendingReward struct.
     */
    function pendingEntry(bytes32 queueId) external view returns (PendingReward memory entry);

    /// @notice Total number of entries ever added to the queue.
    function queueLength() external view returns (uint256);

    /**
     * @notice Returns true iff the entry exists and has PENDING status.
     * @param queueId Identifier of the entry.
     */
    function isPending(bytes32 queueId) external view returns (bool);

    /**
     * @notice Returns true iff the entry exists and has FULFILLED status.
     * @param queueId Identifier of the entry.
     */
    function isFulfilled(bytes32 queueId) external view returns (bool);

    /**
     * @notice Returns true iff the entry is PENDING and the engine has enough
     *         available balance to satisfy it right now.
     * @param queueId Identifier of the entry.
     */
    function canFulfill(bytes32 queueId) external view returns (bool);

    /// @notice Cumulative count of entries added.
    function totalEnqueued() external view returns (uint256);

    /// @notice Cumulative count of entries successfully fulfilled.
    function totalFulfilled() external view returns (uint256);

    /// @notice Cumulative count of entries cancelled.
    function totalCancelled() external view returns (uint256);
}
