// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/crosschain/CrossChainEndpoint.sol";
import "../contracts/crosschain/ICrossChainEndpoint.sol";
import "../contracts/crosschain/ICrossChainReceiver.sol";

contract HostileCrossChainReceiver is ICrossChainReceiver {
    enum Mode {
        Accept,
        ReturnLarge,
        RevertLarge,
        BurnGas
    }

    Mode public mode;
    uint256 public receivedPayloadLength;
    bytes32 public constant REVERT_REASON = bytes32(uint256(0x12345678));

    function setMode(Mode newMode) external {
        mode = newMode;
    }

    function handleCrossChainMessage(uint256, address, bytes calldata payload) external override {
        receivedPayloadLength = payload.length;
        if (mode == Mode.ReturnLarge) {
            assembly {
                return(0, 0x10000)
            }
        }
        if (mode == Mode.RevertLarge) {
            bytes32 reason = REVERT_REASON;
            assembly {
                mstore(0, reason)
                revert(0, 0x10000)
            }
        }
        if (mode == Mode.BurnGas) {
            assembly {
                for { } gt(gas(), 0x400) { } { }
            }
        }
    }
}

contract CrossChainEndpointTest is Test {
    CrossChainEndpoint internal endpoint;
    HostileCrossChainReceiver internal receiver;
    address internal constant RELAYER = address(0xA11CE);
    address internal constant MESSAGE_SENDER = address(0xB0B);

    function setUp() public {
        endpoint = new CrossChainEndpoint();
        receiver = new HostileCrossChainReceiver();
        endpoint.setSupportedChain(block.chainid, true);
        endpoint.setAuthorizedRelayer(RELAYER, true);
    }

    function test_sendMessageRejectsEmptyAndOversizedPayloads() public {
        vm.expectRevert(ICrossChainEndpoint.EmptyPayload.selector);
        endpoint.sendMessage(block.chainid, address(receiver), bytes(""));

        uint256 maximum = endpoint.MAX_MESSAGE_PAYLOAD_BYTES();
        bytes memory oversized = new bytes(maximum + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ICrossChainEndpoint.MessagePayloadTooLarge.selector, maximum + 1, maximum)
        );
        endpoint.sendMessage(block.chainid, address(receiver), oversized);
    }

    function test_processMessageRejectsPayloadAboveLimitBeforeHashingOrStorage() public {
        uint256 maximum = endpoint.MAX_MESSAGE_PAYLOAD_BYTES();
        ICrossChainEndpoint.CrossChainMessage memory message = _message(new bytes(maximum + 1), 1);

        vm.expectRevert(
            abi.encodeWithSelector(ICrossChainEndpoint.MessagePayloadTooLarge.selector, maximum + 1, maximum)
        );
        vm.prank(RELAYER);
        endpoint.processMessage(message);

        assertFalse(endpoint.isMessageProcessed(message.messageId));
    }

    function test_processMessageAcceptsPayloadAtMaximumBoundary() public {
        uint256 maximum = endpoint.MAX_MESSAGE_PAYLOAD_BYTES();
        ICrossChainEndpoint.CrossChainMessage memory message = _message(new bytes(maximum), 2);

        vm.prank(RELAYER);
        endpoint.processMessage(message);

        assertEq(receiver.receivedPayloadLength(), maximum);
        assertTrue(endpoint.isMessageProcessed(message.messageId));
    }

    function test_largeSuccessfulReturndataDoesNotExpandEndpointMemory() public {
        receiver.setMode(HostileCrossChainReceiver.Mode.ReturnLarge);
        ICrossChainEndpoint.CrossChainMessage memory message = _message(bytes("ok"), 3);

        uint256 gasBefore = gasleft();
        vm.prank(RELAYER);
        endpoint.processMessage(message);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 1_000_000);
        assertTrue(endpoint.isMessageProcessed(message.messageId));
    }

    function test_largeRevertDataCopiesOnlyReasonPrefix() public {
        receiver.setMode(HostileCrossChainReceiver.Mode.RevertLarge);
        ICrossChainEndpoint.CrossChainMessage memory message = _message(bytes("ok"), 4);

        vm.expectEmit(true, false, false, true, address(endpoint));
        emit ICrossChainEndpoint.CrossChainMessageRejected(message.messageId, receiver.REVERT_REASON());

        uint256 gasBefore = gasleft();
        vm.prank(RELAYER);
        endpoint.processMessage(message);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 1_000_000);
        assertTrue(endpoint.isMessageProcessed(message.messageId));
    }

    function test_hostileReceiverCannotConsumeUnboundedCallerGas() public {
        receiver.setMode(HostileCrossChainReceiver.Mode.BurnGas);
        ICrossChainEndpoint.CrossChainMessage memory message = _message(bytes("bounded"), 9);

        assertEq(endpoint.RECEIVER_CALL_GAS_LIMIT(), 500_000);
        uint256 gasBefore = gasleft();
        vm.prank(RELAYER);
        endpoint.processMessage(message);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 900_000);
        assertTrue(endpoint.isMessageProcessed(message.messageId));
    }

    function test_processMessageRejectsEmptyPayload() public {
        ICrossChainEndpoint.CrossChainMessage memory message = _message(bytes(""), 5);

        vm.expectRevert(ICrossChainEndpoint.EmptyPayload.selector);
        vm.prank(RELAYER);
        endpoint.processMessage(message);
    }

    function _message(bytes memory payload, uint256 nonce)
        internal
        view
        returns (ICrossChainEndpoint.CrossChainMessage memory message)
    {
        message = ICrossChainEndpoint.CrossChainMessage({
            messageId: bytes32(0),
            sourceChainId: block.chainid,
            destinationChainId: block.chainid,
            sender: MESSAGE_SENDER,
            target: address(receiver),
            payload: payload,
            nonce: nonce,
            status: ICrossChainEndpoint.MessageStatus.Pending
        });
        message.messageId = keccak256(
            abi.encodePacked(
                message.sourceChainId,
                message.destinationChainId,
                message.sender,
                message.target,
                message.payload,
                message.nonce
            )
        );
    }
}
