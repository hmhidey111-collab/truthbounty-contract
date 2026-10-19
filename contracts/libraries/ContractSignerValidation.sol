// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ContractSignerValidation
/// @notice Bounded ERC-1271 validation for typed-operation signers.
library ContractSignerValidation {
    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;
    uint256 internal constant ERC1271_GAS_LIMIT = 50_000;

    function isValidContractSignature(address signer, bytes32 digest, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        if (signer == address(this)) return false;

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(signer)
        }
        if (codeSize == 0) return false;

        (bool success, bytes memory result) = signer.staticcall{gas: ERC1271_GAS_LIMIT}(
            abi.encodeWithSelector(ERC1271_MAGICVALUE, digest, signature)
        );
        return success && keccak256(result) == keccak256(abi.encode(ERC1271_MAGICVALUE));
    }
}