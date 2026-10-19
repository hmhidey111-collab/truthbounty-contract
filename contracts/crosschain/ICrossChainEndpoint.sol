// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICrossChainEndpoint
 * @dev Standard interface for TruthBounty cross-chain messaging
 */
interface ICrossChainEndpoint {
    enum MessageStatus {
        None,
        Pending,
        Processed,
        Rejected
    }

    struct CrossChainMessage {
        bytes32 messageId;
        uint256 sourceChainId;
        uint256 destinationChainId;
        address sender;
        address target;
        bytes payload;
        uint256 nonce;
        MessageStatus status;
    }

    event CrossChainMessageCreated(
        bytes32 indexed messageId,
        uint256 indexed destinationChain
    );

    event CrossChainMessageProcessed(
        bytes32 indexed messageId
    );

    event CrossChainMessageRejected(
        bytes32 indexed messageId,
        bytes32 reason
    );

    /// @notice The endpoint does not accept an empty payload.
    error EmptyPayload();

    /// @notice The payload exceeds the endpoint's documented 4 KiB limit.
    /// @param actual Payload length in bytes.
    /// @param maximum Maximum accepted payload length in bytes.
    error MessagePayloadTooLarge(uint256 actual, uint256 maximum);

    /**
     * @dev Sends a cross-chain message to a target on a destination chain.
     * @param destinationChainId The ID of the target chain.
     * @param target The address of the target contract.
    * @param payload The non-empty message payload, at most 4,096 bytes.
     * @return messageId The unique identifier of the created message.
     */
    function sendMessage(
        uint256 destinationChainId,
        address target,
        bytes calldata payload
    ) external returns (bytes32 messageId);

    /**
     * @dev Processes an incoming cross-chain message.
     * @param message The cross chain message.
     */
    function processMessage(CrossChainMessage calldata message) external;

    /**
     * @dev Checks if a specific message ID has been processed to protect against replays.
     * @param messageId The message ID.
     */
    function isMessageProcessed(bytes32 messageId) external view returns (bool);
    
    /**
     * @dev Retrieves a message by ID.
     */
    function getMessage(bytes32 messageId) external view returns (CrossChainMessage memory);
}
