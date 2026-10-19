// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library DeploymentNoncePlanner {
    error NonceDrift(uint256 expected, uint256 actual);
    error NonceTooLarge(uint256 nonce);

    function computeCreate(address deployer, uint256 nonce) internal pure returns (address) {
        bytes memory data;
        if (nonce == 0x00) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80));
        } else if (nonce <= 0x7f) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce));
        } else if (nonce <= 0xff) {
            data = abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), uint8(nonce));
        } else if (nonce <= 0xffff) {
            data = abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), uint16(nonce));
        } else if (nonce <= 0xffffff) {
            data = abi.encodePacked(bytes1(0xd9), bytes1(0x94), deployer, bytes1(0x83), uint24(nonce));
        } else if (nonce <= type(uint32).max) {
            data = abi.encodePacked(bytes1(0xda), bytes1(0x94), deployer, bytes1(0x84), uint32(nonce));
        } else {
            revert NonceTooLarge(nonce);
        }
        return address(uint160(uint256(keccak256(data))));
    }

    function requireNonce(uint256 expected, uint256 actual) internal pure {
        if (expected != actual) revert NonceDrift(expected, actual);
    }
}
