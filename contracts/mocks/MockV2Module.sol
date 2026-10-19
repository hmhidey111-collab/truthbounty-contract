// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IV2Module} from "../v2/interfaces/IV2Module.sol";

/// @dev Test double implementing the minimal V2 module discovery surface with configurable
///      version and a single arbitrary interface ID it claims to support.
contract MockV2Module is ERC165, IV2Module {
    uint16 private immutable _major;
    uint16 private immutable _minor;
    bytes4 private immutable _interfaceId;

    constructor(uint16 major, uint16 minor, bytes4 interfaceId) {
        _major = major;
        _minor = minor;
        _interfaceId = interfaceId;
    }

    function protocolVersion() external view override returns (uint16 major, uint16 minor) {
        return (_major, _minor);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IV2Module).interfaceId || interfaceId == _interfaceId
            || super.supportsInterface(interfaceId);
    }
}