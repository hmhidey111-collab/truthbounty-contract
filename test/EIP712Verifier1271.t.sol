// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/EIP712Verifier.sol";
import "../contracts/mocks/MockERC1271Signer.sol";

contract EIP712Verifier1271Test is Test {
    EIP712Verifier internal verifier;
    MockERC1271Signer internal wallet;
    uint256 internal constant EOA_KEY = 0xA11CE;
    bytes32 internal constant CONTENT = keccak256("content");

    function setUp() public {
        verifier = new EIP712Verifier();
        wallet = new MockERC1271Signer();
    }

    function _digest(address claimant, uint256 nonce, uint256 deadline) internal view returns (bytes32) {
        return verifier.getClaimSubmissionHash(claimant, 7, CONTENT, nonce, deadline);
    }

    function _verify(address claimant, uint256 deadline, bytes memory signature) internal {
        verifier.verifyClaimSubmission(claimant, 7, CONTENT, deadline, signature);
    }

    function test_EOAPathRemainsValid() public {
        address signer = vm.addr(EOA_KEY);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(signer, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_KEY, digest);

        _verify(signer, deadline, abi.encodePacked(r, s, v));
        assertEq(verifier.getNonce(signer), 1);
    }

    function test_ContractSignerPathAcceptsCanonicalMagic() public {
        uint256 deadline = block.timestamp + 1 hours;
        wallet.configure(_digest(address(wallet), 0, deadline), 0);

        _verify(address(wallet), deadline, hex"01");
        assertEq(verifier.getNonce(address(wallet)), 1);
    }

    function test_RejectsWrongMagicRevertAndMalformedReturn() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(address(wallet), 0, deadline);

        wallet.configure(digest, 2);
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        _verify(address(wallet), deadline, hex"01");

        wallet.configure(digest, 1);
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        _verify(address(wallet), deadline, hex"01");

        wallet.configure(digest, 3);
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        _verify(address(wallet), deadline, hex"01");
    }

    function test_ReplayAndExpiryRemainProtected() public {
        uint256 deadline = block.timestamp + 1 hours;
        wallet.configure(_digest(address(wallet), 0, deadline), 0);
        _verify(address(wallet), deadline, hex"01");

        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        _verify(address(wallet), deadline, hex"01");

        uint256 expiredDeadline = block.timestamp;
        vm.warp(expiredDeadline + 1);
        wallet.configure(_digest(address(wallet), 1, expiredDeadline), 0);
        vm.expectRevert(EIP712Verifier.SignatureExpired.selector);
        _verify(address(wallet), expiredDeadline, hex"01");
    }

    function test_RejectsRemovedCodeAndRecursiveSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        wallet.configure(_digest(address(wallet), 0, deadline), 0);
        vm.etch(address(wallet), bytes(""));
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        _verify(address(wallet), deadline, hex"01");

        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        _verify(address(verifier), deadline, hex"01");
    }

    function test_GasBoundedHostileSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        wallet.configure(_digest(address(wallet), 0, deadline), 4);
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        _verify(address(wallet), deadline, hex"01");
    }
}