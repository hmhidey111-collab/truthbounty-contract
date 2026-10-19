// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploymentNoncePlanner} from "../script/deploy/DeploymentNoncePlanner.sol";

contract NonceDummy {}

contract NonceHarness {
    function create(address d, uint256 n) external pure returns (address) {
        return DeploymentNoncePlanner.computeCreate(d, n);
    }

    function check(uint256 e, uint256 a) external pure {
        DeploymentNoncePlanner.requireNonce(e, a);
    }
}

contract DeploymentNoncePlannerTest is Test {
    NonceHarness internal h = new NonceHarness();

    function test_freshDeployerKnownVectors() public view {
        address d = address(bytes20(hex"6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0"));
        assertEq(h.create(d, 0), address(bytes20(hex"cd234a471b72ba2f1ccf0a70fcaba648a5eecd8d")));
        assertEq(h.create(d, 1), address(bytes20(hex"343c43a37d37dff08ae8c4a11544c718abb4fcf8")));
    }

    function test_plannedMatchesDeployed() public {
        uint256 n = vm.getNonce(address(this));
        address planned = h.create(address(this), n);
        address deployed = address(new NonceDummy());
        assertEq(planned, deployed);
    }

    function test_encodingBoundaries() public {
        uint256[4] memory nonces = [uint256(127), 128, 255, 256];
        for (uint256 i = 0; i < nonces.length; i++) {
            vm.setNonce(address(this), uint64(nonces[i]));
            address planned = h.create(address(this), nonces[i]);
            address deployed = address(new NonceDummy());
            assertEq(planned, deployed);
        }
    }

    function test_redeployUsesNextNonce() public {
        uint256 n = vm.getNonce(address(this));
        address first = address(new NonceDummy());
        address second = address(new NonceDummy());
        assertEq(first, h.create(address(this), n));
        assertEq(second, h.create(address(this), n + 1));
        assertTrue(first != second);
    }

    function test_nonceDriftReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentNoncePlanner.NonceDrift.selector, 5, 6));
        h.check(5, 6);
    }

    function test_nonceTooLargeReverts() public {
        uint256 big = uint256(type(uint32).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(DeploymentNoncePlanner.NonceTooLarge.selector, big));
        h.create(address(this), big);
    }
}
