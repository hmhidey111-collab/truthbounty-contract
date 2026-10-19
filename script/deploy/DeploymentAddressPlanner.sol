// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library DeploymentAddressPlanner {
    error AddressCollision(address plannedAddress);
    error PlanDrift(address expected, address actual);

    function computeCreate2(
        address deployer,
        bytes32 salt,
        bytes memory initCode
    ) internal pure returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(initCode))
        );
        return address(uint160(uint256(hash)));
    }

    function requireNoCollision(address planned) internal view {
        if (planned.code.length != 0) revert AddressCollision(planned);
    }

    function requireMatchesPlan(address expected, address actual) internal pure {
        if (expected != actual) revert PlanDrift(expected, actual);
    }
}
