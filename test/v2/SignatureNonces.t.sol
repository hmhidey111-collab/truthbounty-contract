// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/v2/SignatureNonces.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract SignatureNoncesHarness is SignatureNonces {
    function consume(address owner, uint256 nonce, uint256 deadline) external {
        _useCheckedNonce(owner, nonce, deadline);
    }
}

/// @dev Representative EIP-712 signed protocol action protected by `SignatureNonces`.
contract SignedActionHarness is EIP712, SignatureNonces {
    bytes32 public constant ACTION_TYPEHASH =
        keccak256("Action(address owner,bytes32 action,uint256 nonce,uint256 deadline)");

    mapping(address => uint256) public executed;

    error InvalidSigner();

    constructor() EIP712("TruthBounty", "2") { }

    function digest(address owner, bytes32 action, uint256 nonce, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ACTION_TYPEHASH, owner, action, nonce, deadline)));
    }

    function execute(address owner, bytes32 action, uint256 nonce, uint256 deadline, bytes calldata sig) external {
        if (ECDSA.recover(digest(owner, action, nonce, deadline), sig) != owner) revert InvalidSigner();
        _useCheckedNonce(owner, nonce, deadline);
        executed[owner]++;
    }
}

/// @dev Prior unsafe pattern: signature checked, nonce never consumed.
contract UnsafeSignedActionHarness is EIP712 {
    bytes32 public constant ACTION_TYPEHASH =
        keccak256("Action(address owner,bytes32 action,uint256 nonce,uint256 deadline)");

    mapping(address => uint256) public executed;

    constructor() EIP712("TruthBounty", "2") { }

    function digest(address owner, bytes32 action, uint256 nonce, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ACTION_TYPEHASH, owner, action, nonce, deadline)));
    }

    function execute(address owner, bytes32 action, uint256 nonce, uint256 deadline, bytes calldata sig) external {
        require(ECDSA.recover(digest(owner, action, nonce, deadline), sig) == owner, "signer");
        executed[owner]++;
    }
}

contract SignatureNoncesTest is Test {
    SignatureNoncesHarness internal n;
    address internal owner = address(0xA11CE);

    function setUp() public {
        n = new SignatureNoncesHarness();
    }

    function test_ConsumesOnceAndRejectsReplay() public {
        vm.expectEmit(true, true, false, false);
        emit SignatureNonces.NonceConsumed(owner, 7);
        n.consume(owner, 7, block.timestamp);
        assertTrue(n.isNonceUsed(owner, 7));

        vm.expectRevert(abi.encodeWithSelector(SignatureNonces.NonceAlreadyUsed.selector, owner, 7));
        n.consume(owner, 7, block.timestamp);
    }

    function test_NoncesAreUnorderedAndPerOwner() public {
        n.consume(owner, 300, block.timestamp);
        n.consume(owner, 1, block.timestamp);
        assertFalse(n.isNonceUsed(owner, 2));
        assertFalse(n.isNonceUsed(address(0xB0B), 300));
        n.consume(address(0xB0B), 300, block.timestamp);
    }

    function test_RejectsExpiredSignature() public {
        vm.warp(1000);
        vm.expectRevert(abi.encodeWithSelector(SignatureNonces.SignatureExpired.selector, 999));
        n.consume(owner, 1, 999);
        assertFalse(n.isNonceUsed(owner, 1));
    }

    function test_CancelBlocksLaterUse() public {
        vm.prank(owner);
        n.cancelNonce(5);
        vm.expectRevert(abi.encodeWithSelector(SignatureNonces.NonceAlreadyUsed.selector, owner, 5));
        n.consume(owner, 5, block.timestamp);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SignatureNonces.NonceAlreadyUsed.selector, owner, 5));
        n.cancelNonce(5);
    }

    function test_CancelOnlyAffectsCaller() public {
        vm.prank(address(0xB0B));
        n.cancelNonce(5);
        n.consume(owner, 5, block.timestamp);
    }

    function testFuzz_SingleUse(uint256 nonce, uint256 other) public {
        vm.assume(nonce != other);
        n.consume(owner, nonce, type(uint256).max);
        assertTrue(n.isNonceUsed(owner, nonce));
        assertFalse(n.isNonceUsed(owner, other));
        vm.expectRevert(abi.encodeWithSelector(SignatureNonces.NonceAlreadyUsed.selector, owner, nonce));
        n.consume(owner, nonce, type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // End-to-end EIP-712 signed path
    // -------------------------------------------------------------------------

    uint256 internal constant SIGNER_KEY = 0xA11CE;
    bytes32 internal constant ACTION = keccak256("verify");

    function _sign(SignedActionHarness target, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SIGNER_KEY, target.digest(vm.addr(SIGNER_KEY), ACTION, nonce, deadline));
        return abi.encodePacked(r, s, v);
    }

    function test_SignedPath_ExecutesOnceThenRejectsReplay() public {
        SignedActionHarness target = new SignedActionHarness();
        address signer = vm.addr(SIGNER_KEY);
        bytes memory sig = _sign(target, 1, block.timestamp);

        target.execute(signer, ACTION, 1, block.timestamp, sig);
        assertEq(target.executed(signer), 1);

        vm.expectRevert(abi.encodeWithSelector(SignatureNonces.NonceAlreadyUsed.selector, signer, 1));
        target.execute(signer, ACTION, 1, block.timestamp, sig);
        assertEq(target.executed(signer), 1);
    }

    function test_SignedPath_CancelledBeforeSubmission() public {
        SignedActionHarness target = new SignedActionHarness();
        address signer = vm.addr(SIGNER_KEY);
        bytes memory sig = _sign(target, 9, block.timestamp);

        vm.prank(signer);
        target.cancelNonce(9);
        vm.expectRevert(abi.encodeWithSelector(SignatureNonces.NonceAlreadyUsed.selector, signer, 9));
        target.execute(signer, ACTION, 9, block.timestamp, sig);
    }

    function test_SignedPath_ExpiredRejected() public {
        SignedActionHarness target = new SignedActionHarness();
        address signer = vm.addr(SIGNER_KEY);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(target, 2, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(SignatureNonces.SignatureExpired.selector, deadline));
        target.execute(signer, ACTION, 2, deadline, sig);
    }

    function test_SignedPath_TamperedOrForeignSignatureRejected() public {
        SignedActionHarness target = new SignedActionHarness();
        SignedActionHarness other = new SignedActionHarness();
        address signer = vm.addr(SIGNER_KEY);
        bytes memory sig = _sign(target, 3, block.timestamp);

        // Different nonce than signed.
        vm.expectRevert(SignedActionHarness.InvalidSigner.selector);
        target.execute(signer, ACTION, 4, block.timestamp, sig);

        // Same payload replayed on another deployment (domain separation).
        vm.expectRevert(SignedActionHarness.InvalidSigner.selector);
        other.execute(signer, ACTION, 3, block.timestamp, sig);

        // Claimed for a different owner.
        vm.expectRevert(SignedActionHarness.InvalidSigner.selector);
        target.execute(address(0xB0B), ACTION, 3, block.timestamp, sig);

        assertFalse(target.isNonceUsed(signer, 3));
    }

    /// @notice Regression: without nonce consumption the same signature executes repeatedly.
    function test_Regression_UnsafePathIsReplayable() public {
        UnsafeSignedActionHarness unsafeTarget = new UnsafeSignedActionHarness();
        address signer = vm.addr(SIGNER_KEY);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, unsafeTarget.digest(signer, ACTION, 1, block.timestamp));
        bytes memory sig = abi.encodePacked(r, s, v);

        unsafeTarget.execute(signer, ACTION, 1, block.timestamp, sig);
        unsafeTarget.execute(signer, ACTION, 1, block.timestamp, sig);
        assertEq(unsafeTarget.executed(signer), 2);
    }
}
