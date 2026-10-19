// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ICrossChainEndpoint.sol";
import "./ICrossChainReceiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CrossChainEndpoint is ICrossChainEndpoint, Ownable {
    /// @notice Maximum encoded cross-chain payload stored or executed by this endpoint.
    /// @dev 4 KiB bounds storage expansion to 128 data slots per message.
    uint256 public constant MAX_MESSAGE_PAYLOAD_BYTES = 4_096;
    /// @notice Maximum gas forwarded to an untrusted cross-chain receiver callback.
    uint256 public constant RECEIVER_CALL_GAS_LIMIT = 500_000;

    // Registry of supported chain IDs
    mapping(uint256 => bool) public supportedChains;
    
    // Nonce for outbound messages to ensure uniqueness
    uint256 public outboundNonce;

    // Registry of processed messages to prevent replay attacks
    mapping(bytes32 => bool) private _processedMessages;
    
    // Registry of all messages (could be stored entirely or just status)
    mapping(bytes32 => CrossChainMessage) private _messages;

    // Relayer address that is authorized to process incoming messages (simplified for this architecture)
    mapping(address => bool) public authorizedRelayers;

    constructor() Ownable(msg.sender) {}

    modifier onlySupportedChain(uint256 chainId) {
        require(supportedChains[chainId], "Unsupported chain");
        _;
    }

    modifier onlyAuthorizedRelayer() {
        require(authorizedRelayers[msg.sender], "Unauthorized relayer");
        _;
    }

    function setSupportedChain(uint256 chainId, bool supported) external onlyOwner {
        supportedChains[chainId] = supported;
    }

    function setAuthorizedRelayer(address relayer, bool authorized) external onlyOwner {
        authorizedRelayers[relayer] = authorized;
    }

    function sendMessage(
        uint256 destinationChainId,
        address target,
        bytes calldata payload
    ) external onlySupportedChain(destinationChainId) returns (bytes32 messageId) {
        require(target != address(0), "Invalid target");
        if (payload.length == 0) revert EmptyPayload();
        if (payload.length > MAX_MESSAGE_PAYLOAD_BYTES) {
            revert MessagePayloadTooLarge(payload.length, MAX_MESSAGE_PAYLOAD_BYTES);
        }

        uint256 nonce = outboundNonce++;
        
        messageId = keccak256(
            abi.encodePacked(
                block.chainid,
                destinationChainId,
                msg.sender,
                target,
                payload,
                nonce
            )
        );

        CrossChainMessage memory message = CrossChainMessage({
            messageId: messageId,
            sourceChainId: block.chainid,
            destinationChainId: destinationChainId,
            sender: msg.sender,
            target: target,
            payload: payload,
            nonce: nonce,
            status: MessageStatus.Pending
        });

        _messages[messageId] = message;

        emit CrossChainMessageCreated(messageId, destinationChainId);
        
        return messageId;
    }

    function processMessage(CrossChainMessage calldata message) external onlyAuthorizedRelayer {
        require(message.destinationChainId == block.chainid, "Invalid destination chain");
        require(supportedChains[message.sourceChainId], "Unsupported source chain");
        require(!_processedMessages[message.messageId], "Message already processed");
        if (message.payload.length == 0) revert EmptyPayload();
        if (message.payload.length > MAX_MESSAGE_PAYLOAD_BYTES) {
            revert MessagePayloadTooLarge(message.payload.length, MAX_MESSAGE_PAYLOAD_BYTES);
        }
        
        // Verify message ID matches payload
        bytes32 expectedMessageId = keccak256(
            abi.encodePacked(
                message.sourceChainId,
                message.destinationChainId,
                message.sender,
                message.target,
                message.payload,
                message.nonce
            )
        );
        require(message.messageId == expectedMessageId, "Invalid message ID");

        _processedMessages[message.messageId] = true;
        _messages[message.messageId] = message; // Store received message for record

        // The receiver has no return value; retain only the first revert word for the event.
        bytes memory callData = abi.encodeWithSelector(
            ICrossChainReceiver.handleCrossChainMessage.selector,
            message.sourceChainId,
            message.sender,
            message.payload
        );
        (bool success, bytes32 reason) = _callReceiver(message.target, callData);

        if (success) {
            _messages[message.messageId].status = MessageStatus.Processed;
            emit CrossChainMessageProcessed(message.messageId);
        } else {
            _messages[message.messageId].status = MessageStatus.Rejected;
            emit CrossChainMessageRejected(message.messageId, reason);
        }
    }

    function _callReceiver(address target, bytes memory callData) private returns (bool success, bytes32 reason) {
        assembly {
            let freePointer := mload(0x40)
            mstore(0x40, add(freePointer, 0x20))
            success := call(RECEIVER_CALL_GAS_LIMIT, target, 0, add(callData, 0x20), mload(callData), 0, 0)

            if iszero(success) {
                let returnSize := returndatasize()
                if iszero(returnSize) {
                    reason := "Execution failed"
                }
                if returnSize {
                    let copySize := returnSize
                    if gt(copySize, 0x20) { copySize := 0x20 }
                    returndatacopy(freePointer, 0, copySize)
                    reason := mload(freePointer)
                }
            }
        }
    }

    function isMessageProcessed(bytes32 messageId) external view returns (bool) {
        return _processedMessages[messageId];
    }
    
    function getMessage(bytes32 messageId) external view returns (CrossChainMessage memory) {
        return _messages[messageId];
    }
}
