// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {V2SignatureVerifier} from "../../contracts/v2/libraries/V2SignatureVerifier.sol";
import {V2SignatureVerifierHarness} from "../../contracts/test/V2SignatureVerifierHarness.sol";

contract MockERC1271Wallet {
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;
    bytes4 internal constant INVALID_MAGIC = 0xffffffff;

    enum Behavior {
        Valid,
        InvalidMagic,
        Revert,
        InfiniteLoop,
        ReturnBomb
    }

    Behavior public behavior;

    constructor(Behavior _behavior) {
        behavior = _behavior;
    }

    function setBehavior(Behavior _behavior) external {
        behavior = _behavior;
    }

    function isValidSignature(bytes32, bytes memory) external view returns (bytes4) {
        if (behavior == Behavior.Valid) {
            return MAGICVALUE;
        } else if (behavior == Behavior.InvalidMagic) {
            return INVALID_MAGIC;
        } else if (behavior == Behavior.Revert) {
            revert("MockWallet: revert");
        } else if (behavior == Behavior.InfiniteLoop) {
            // Burn gas beyond bounded 50,000 limit
            uint256 x = 0;
            while (true) {
                x++;
            }
            return MAGICVALUE;
        } else if (behavior == Behavior.ReturnBomb) {
            // Return oversized data
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, MAGICVALUE)
                // Return 5000 bytes
                return(ptr, 5000)
            }
        }
        return INVALID_MAGIC;
    }
}

contract V2SignatureVerifierTest is Test {
    V2SignatureVerifierHarness internal harness;

    uint256 internal signerPrivateKey = 0xA11CE;
    address internal signerAddress;

    // secp256k1 order n
    uint256 internal constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant SECP256K1_HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    function setUp() public {
        harness = new V2SignatureVerifierHarness();
        signerAddress = vm.addr(signerPrivateKey);
    }

    function _sign(bytes32 digest, uint256 privateKey)
        internal
        pure
        returns (uint8 v, bytes32 r, bytes32 s, bytes memory sig)
    {
        (v, r, s) = vm.sign(privateKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // --- Happy Path EOA ---

    function test_verifyValidEOASignature() public view {
        bytes32 digest = keccak256("test message");
        (, , , bytes memory sig) = _sign(digest, signerPrivateKey);

        harness.verifySignature(signerAddress, digest, sig);
        assertTrue(harness.isValidSignature(signerAddress, digest, sig));

        address recovered = harness.recoverSigner(digest, sig);
        assertEq(recovered, signerAddress);
    }

    // --- Zero Inputs ---

    function test_revertZeroSigner() public {
        bytes32 digest = keccak256("test message");
        (, , , bytes memory sig) = _sign(digest, signerPrivateKey);

        vm.expectRevert(V2SignatureVerifier.SignatureZeroSigner.selector);
        harness.verifySignature(address(0), digest, sig);
    }

    function test_revertZeroDigest() public {
        bytes32 digest = bytes32(0);
        bytes memory sig = new bytes(65);

        vm.expectRevert(V2SignatureVerifier.SignatureZeroDigest.selector);
        harness.recoverSigner(digest, sig);

        vm.expectRevert(V2SignatureVerifier.SignatureZeroDigest.selector);
        harness.verifySignature(signerAddress, digest, sig);
    }

    // --- Invalid Signature Length ---

    function test_revertInvalidLength() public {
        bytes32 digest = keccak256("test message");
        bytes memory shortSig = new bytes(64);
        bytes memory longSig = new bytes(66);

        vm.expectRevert(abi.encodeWithSelector(V2SignatureVerifier.SignatureInvalidLength.selector, 64));
        harness.recoverSigner(digest, shortSig);

        vm.expectRevert(abi.encodeWithSelector(V2SignatureVerifier.SignatureInvalidLength.selector, 66));
        harness.recoverSigner(digest, longSig);
    }

    // --- High-s (Malleability) ---

    function test_revertHighS() public {
        bytes32 digest = keccak256("test message");
        (uint8 v, bytes32 r, bytes32 s, ) = _sign(digest, signerPrivateKey);

        // Compute high-s: malleableS = n - s
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory malleableSig = abi.encodePacked(r, highS, flippedV);

        vm.expectRevert(abi.encodeWithSelector(V2SignatureVerifier.SignatureMalleableS.selector, highS));
        harness.recoverSigner(digest, malleableSig);

        vm.expectRevert(abi.encodeWithSelector(V2SignatureVerifier.SignatureMalleableS.selector, highS));
        harness.verifySignature(signerAddress, digest, malleableSig);
    }

    // --- Invalid v / r / s ---

    function test_revertInvalidV() public {
        bytes32 digest = keccak256("test message");
        (, bytes32 r, bytes32 s, ) = _sign(digest, signerPrivateKey);

        // v = 0
        bytes memory badSig0 = abi.encodePacked(r, s, uint8(0));
        vm.expectRevert(abi.encodeWithSelector(V2SignatureVerifier.SignatureInvalidV.selector, 0));
        harness.recoverSigner(digest, badSig0);

        // v = 29
        bytes memory badSig29 = abi.encodePacked(r, s, uint8(29));
        vm.expectRevert(abi.encodeWithSelector(V2SignatureVerifier.SignatureInvalidV.selector, 29));
        harness.recoverSigner(digest, badSig29);
    }

    function test_revertZeroR() public {
        bytes32 digest = keccak256("test message");
        (, , bytes32 s, ) = _sign(digest, signerPrivateKey);

        bytes memory badSig = abi.encodePacked(bytes32(0), s, uint8(27));
        vm.expectRevert(abi.encodeWithSelector(V2SignatureVerifier.SignatureInvalidR.selector, bytes32(0)));
        harness.recoverSigner(digest, badSig);
    }

    function test_revertRGreaterThanOrEqualN() public {
        bytes32 digest = keccak256("test message");
        (, , bytes32 s, ) = _sign(digest, signerPrivateKey);

        bytes32 badR = bytes32(SECP256K1_N);
        bytes memory badSig = abi.encodePacked(badR, s, uint8(27));
        vm.expectRevert(abi.encodeWithSelector(V2SignatureVerifier.SignatureInvalidR.selector, badR));
        harness.recoverSigner(digest, badSig);
    }

    function test_revertZeroS() public {
        bytes32 digest = keccak256("test message");
        (, bytes32 r, , ) = _sign(digest, signerPrivateKey);

        bytes memory badSig = abi.encodePacked(r, bytes32(0), uint8(27));
        vm.expectRevert(abi.encodeWithSelector(V2SignatureVerifier.SignatureInvalidS.selector, bytes32(0)));
        harness.recoverSigner(digest, badSig);
    }

    // --- Signer Mismatch / Wrong Digest ---

    function test_revertSignerMismatchWrongDigest() public {
        bytes32 digest1 = keccak256("correct message");
        bytes32 digest2 = keccak256("wrong message");
        (, , , bytes memory sig) = _sign(digest1, signerPrivateKey);

        // Verifying digest2 with signature from digest1 will recover a different address
        address recoveredWrong = harness.recoverSigner(digest2, sig);
        assertTrue(recoveredWrong != signerAddress);

        vm.expectRevert(
            abi.encodeWithSelector(
                V2SignatureVerifier.SignatureSignerMismatch.selector,
                signerAddress,
                recoveredWrong
            )
        );
        harness.verifySignature(signerAddress, digest2, sig);
    }

    // --- ERC-1271 Contract Wallet Tests ---

    function test_erc1271ValidSignature() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(MockERC1271Wallet.Behavior.Valid);
        bytes32 digest = keccak256("contract wallet message");
        bytes memory sig = hex"123456";

        harness.verifySignature(address(wallet), digest, sig);

        bool isVal = harness.isValidSignature(address(wallet), digest, sig);
        assertTrue(isVal);
    }

    function test_erc1271InvalidMagicValueReverts() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(MockERC1271Wallet.Behavior.InvalidMagic);
        bytes32 digest = keccak256("contract wallet message");
        bytes memory sig = hex"123456";

        vm.expectRevert(
            abi.encodeWithSelector(
                V2SignatureVerifier.SignatureContractInvalid.selector,
                address(wallet)
            )
        );
        harness.verifySignature(address(wallet), digest, sig);

        bool isVal = harness.isValidSignature(address(wallet), digest, sig);
        assertFalse(isVal);
    }

    function test_erc1271RevertingContractWalletReverts() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(MockERC1271Wallet.Behavior.Revert);
        bytes32 digest = keccak256("contract wallet message");
        bytes memory sig = hex"123456";

        vm.expectRevert(
            abi.encodeWithSelector(
                V2SignatureVerifier.SignatureContractReverted.selector,
                address(wallet)
            )
        );
        harness.verifySignature(address(wallet), digest, sig);

        bool isVal = harness.isValidSignature(address(wallet), digest, sig);
        assertFalse(isVal);
    }

    function test_erc1271GasGriefIsBoundedAndReverts() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(MockERC1271Wallet.Behavior.InfiniteLoop);
        bytes32 digest = keccak256("gas grief message");
        bytes memory sig = hex"123456";

        // Must fail-closed without consuming caller's entire gas budget beyond 50,000 gas
        vm.expectRevert(
            abi.encodeWithSelector(
                V2SignatureVerifier.SignatureContractReverted.selector,
                address(wallet)
            )
        );
        harness.verifySignature{gas: 200_000}(address(wallet), digest, sig);

        bool isVal = harness.isValidSignature{gas: 200_000}(address(wallet), digest, sig);
        assertFalse(isVal);
    }

    function test_erc1271ReturnBombSafelyHandled() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(MockERC1271Wallet.Behavior.ReturnBomb);
        bytes32 digest = keccak256("return bomb message");
        bytes memory sig = hex"123456";

        // Return bomb returns 5000 bytes instead of 32 bytes -> returndatasize != 32, so fails cleanly
        vm.expectRevert(
            abi.encodeWithSelector(
                V2SignatureVerifier.SignatureContractInvalid.selector,
                address(wallet)
            )
        );
        harness.verifySignature(address(wallet), digest, sig);

        bool isVal = harness.isValidSignature(address(wallet), digest, sig);
        assertFalse(isVal);
    }

    // --- Replay Protection with Domain Binding ---

    function test_replayProtectionWithDomainBinding() public view {
        bytes32 domainSeparator = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 intentHash1 = keccak256("Action1(uint256 nonce)");
        bytes32 intentHash2 = keccak256("Action2(uint256 nonce)");

        bytes32 digest1 = keccak256(abi.encodePacked("\x19\x01", domainSeparator, intentHash1));
        bytes32 digest2 = keccak256(abi.encodePacked("\x19\x01", domainSeparator, intentHash2));

        (, , , bytes memory sig1) = _sign(digest1, signerPrivateKey);

        // sig1 verifies for digest1
        harness.verifySignature(signerAddress, digest1, sig1);
        assertTrue(harness.isValidSignature(signerAddress, digest1, sig1));

        // sig1 cannot be replayed for digest2
        assertFalse(harness.isValidSignature(signerAddress, digest2, sig1));
    }
}
