// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title V2SignatureVerifier
/// @notice Canonical signature verification and non-malleability enforcement for TruthBounty V2.
/// @dev Enforces low-s, valid v, nonzero signer, exact digest, EOA recovery, and bounded ERC-1271 validation (PREWAVE-SC-092).
library V2SignatureVerifier {
    /// @notice Order n of the secp256k1 curve.
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @notice Half-order of secp256k1 (n / 2) defining the maximum allowed low-s value.
    uint256 internal constant SECP256K1_N_DIV_2 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @notice Canonical ERC-1271 magic value for isValidSignature(bytes32,bytes).
    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;

    /// @notice Upper bound on gas passed to ERC-1271 staticcall to prevent gas-griefing attacks.
    uint256 internal constant ERC1271_GAS_LIMIT = 50_000;

    /// @notice Expected length of a standard 65-byte ECDSA signature (r, s, v).
    uint256 internal constant STANDARD_SIGNATURE_LENGTH = 65;

    // =========================================================================
    // Custom Errors
    // =========================================================================

    /// @notice Thrown when the target or recovered signer is the zero address.
    error SignatureZeroSigner();

    /// @notice Thrown when the signed digest is bytes32(0).
    error SignatureZeroDigest();

    /// @notice Thrown when an EOA signature is not exactly 65 bytes.
    error SignatureInvalidLength(uint256 length);

    /// @notice Thrown when the s value is in the upper half of the curve order (malleable).
    error SignatureMalleableS(bytes32 s);

    /// @notice Thrown when the s value is zero.
    error SignatureInvalidS(bytes32 s);

    /// @notice Thrown when the r value is zero or >= secp256k1 curve order n.
    error SignatureInvalidR(bytes32 r);

    /// @notice Thrown when the v value is neither 27 nor 28.
    error SignatureInvalidV(uint8 v);

    /// @notice Thrown when the recovered EOA signer does not match the expected signer.
    error SignatureSignerMismatch(address expected, address actual);

    /// @notice Thrown when an ERC-1271 call attempts to reenter the validating contract.
    error SignatureContractRecursive(address signer);

    /// @notice Thrown when an ERC-1271 staticcall reverts or fails (e.g. out of gas).
    error SignatureContractReverted(address signer);

    /// @notice Thrown when an ERC-1271 call returns an invalid magic value or malformed return data.
    error SignatureContractInvalid(address signer);

    /// @notice Thrown when ecrecover returns address(0) despite passing structural checks.
    error SignatureRecoveryFailed();

    // =========================================================================
    // EOA Recovery
    // =========================================================================

    /// @notice Recovers the signer address from an ECDSA signature, strictly rejecting malleability.
    /// @param digest The 32-byte digest that was signed.
    /// @param signature Exactly 65 bytes: r (32) || s (32) || v (1).
    /// @return recovered The non-zero recovered address.
    function recoverSigner(bytes32 digest, bytes memory signature) internal pure returns (address recovered) {
        if (digest == bytes32(0)) revert SignatureZeroDigest();
        if (signature.length != STANDARD_SIGNATURE_LENGTH) revert SignatureInvalidLength(signature.length);

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        _validateParameters(r, s, v);

        recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0)) revert SignatureRecoveryFailed();
    }

    // =========================================================================
    // Comprehensive Verification (EOA + ERC-1271)
    // =========================================================================

    /// @notice Verifies a signature against expectedSigner, supporting both EOAs and ERC-1271 contract wallets.
    /// @dev Reverts with a specific canonical error if verification fails.
    /// @param expectedSigner The address expected to have signed the digest (non-zero).
    /// @param digest The 32-byte signed digest (non-zero).
    /// @param signature The signature bytes (65 bytes for EOA, bounded for ERC-1271).
    function verifySignature(address expectedSigner, bytes32 digest, bytes memory signature) internal view {
        if (expectedSigner == address(0)) revert SignatureZeroSigner();
        if (digest == bytes32(0)) revert SignatureZeroDigest();

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(expectedSigner)
        }

        if (codeSize > 0) {
            verifyContractSignature(expectedSigner, digest, signature);
        } else {
            address recovered = recoverSigner(digest, signature);
            if (recovered != expectedSigner) {
                revert SignatureSignerMismatch(expectedSigner, recovered);
            }
        }
    }

    /// @notice Returns true if signature is valid for signer and digest; false if it would revert.
    function isValidSignature(address signer, bytes32 digest, bytes memory signature) internal view returns (bool) {
        if (signer == address(0) || digest == bytes32(0)) return false;

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(signer)
        }

        if (codeSize > 0) {
            if (signer == address(this)) return false;
            bytes memory callData = abi.encodeWithSelector(ERC1271_MAGICVALUE, digest, signature);
            bool success;
            bytes32 returnWord;
            assembly {
                success := staticcall(ERC1271_GAS_LIMIT, signer, add(callData, 0x20), mload(callData), 0, 0)
                if and(success, eq(returndatasize(), 32)) {
                    returndatacopy(0, 0, 32)
                    returnWord := mload(0)
                }
            }
            if (!success) return false;
            return bytes4(returnWord) == ERC1271_MAGICVALUE;
        } else {
            if (signature.length != STANDARD_SIGNATURE_LENGTH) return false;
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            if (uint256(r) == 0 || uint256(r) >= SECP256K1_N) return false;
            if (uint256(s) == 0 || uint256(s) > SECP256K1_N_DIV_2) return false;
            if (v != 27 && v != 28) return false;
            return ecrecover(digest, v, r, s) == signer;
        }
    }

    // =========================================================================
    // ERC-1271 Validation
    // =========================================================================

    /// @notice Validates an ERC-1271 contract wallet signature with bounded gas and strict fail-closed behavior.
    function verifyContractSignature(address signer, bytes32 digest, bytes memory signature) internal view {
        if (signer == address(this)) revert SignatureContractRecursive(signer);

        bytes memory callData = abi.encodeWithSelector(ERC1271_MAGICVALUE, digest, signature);
        bool success;
        uint256 retSize;
        bytes32 returnWord;

        assembly {
            success := staticcall(ERC1271_GAS_LIMIT, signer, add(callData, 0x20), mload(callData), 0, 0)
            retSize := returndatasize()
            if and(success, eq(retSize, 32)) {
                returndatacopy(0, 0, 32)
                returnWord := mload(0)
            }
        }

        if (!success) revert SignatureContractReverted(signer);
        if (retSize != 32) revert SignatureContractInvalid(signer);
        if (bytes4(returnWord) != ERC1271_MAGICVALUE) revert SignatureContractInvalid(signer);
    }

    // =========================================================================
    // Internal Parameter Validation
    // =========================================================================

    function _validateParameters(bytes32 r, bytes32 s, uint8 v) private pure {
        if (uint256(r) == 0 || uint256(r) >= SECP256K1_N) {
            revert SignatureInvalidR(r);
        }
        if (uint256(s) == 0) {
            revert SignatureInvalidS(s);
        }
        if (uint256(s) > SECP256K1_N_DIV_2) {
            revert SignatureMalleableS(s);
        }
        if (v != 27 && v != 28) {
            revert SignatureInvalidV(v);
        }
    }
}
