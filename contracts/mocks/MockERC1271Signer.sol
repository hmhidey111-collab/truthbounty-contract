// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockERC1271Signer {
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    bytes32 public expectedDigest;
    uint8 public mode;

    function configure(bytes32 digest, uint8 mode_) external {
        expectedDigest = digest;
        mode = mode_;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        if (mode == 1) revert("rejected");
        if (mode == 2) return 0xffffffff;
        if (mode == 3) {
            assembly {
                mstore(0, 0x1626ba7e)
                mstore(32, 1)
                return(0, 64)
            }
        }
        if (mode == 4) {
            while (true) { }
        }
        return digest == expectedDigest ? MAGICVALUE : bytes4(0xffffffff);
    }
}