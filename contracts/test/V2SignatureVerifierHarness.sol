// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {V2SignatureVerifier} from "../v2/libraries/V2SignatureVerifier.sol";

/// @title V2SignatureVerifierHarness
/// @notice Test harness exposing V2SignatureVerifier library for comprehensive verification testing.
contract V2SignatureVerifierHarness {
    function recoverSigner(bytes32 digest, bytes memory signature) external pure returns (address) {
        return V2SignatureVerifier.recoverSigner(digest, signature);
    }

    function verifySignature(address expectedSigner, bytes32 digest, bytes memory signature) external view {
        V2SignatureVerifier.verifySignature(expectedSigner, digest, signature);
    }

    function isValidSignature(address signer, bytes32 digest, bytes memory signature) external view returns (bool) {
        return V2SignatureVerifier.isValidSignature(signer, digest, signature);
    }

    function verifyContractSignature(address signer, bytes32 digest, bytes memory signature) external view {
        V2SignatureVerifier.verifyContractSignature(signer, digest, signature);
    }
}
