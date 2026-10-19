// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Executes fixed-word metadata probes without copying attacker-sized returndata.
library BoundedStaticCall {
    /// @notice Maximum gas forwarded to fixed-shape metadata and authority probes.
    uint256 internal constant STATICCALL_GAS_LIMIT = 50_000;

    /// @notice Calls a getter with a 32-byte output buffer and reports the full returndata length.
    /// @dev The callee cannot force memory expansion through oversized returndata; callers must
    ///      validate `returnSize` and the decoded word before trusting the result.
    function staticcallWord(address target, bytes memory input)
        internal
        view
        returns (bool success, uint256 word, uint256 returnSize)
    {
        assembly {
            let output := mload(0x40)
            mstore(0x40, add(output, 0x20))
            success := staticcall(
                STATICCALL_GAS_LIMIT,
                target,
                add(input, 0x20),
                mload(input),
                output,
                0x20
            )
            returnSize := returndatasize()
            word := mload(output)
        }
    }
}
