// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {DeploymentPreflight} from "../script/deploy/DeploymentPreflight.sol";

contract DeploymentPreflightTest is Test {
    function testRejectsWrongChain() public {
        vm.chainId(1);

        vm.expectRevert("Wrong chain");
        DeploymentPreflight.requireExpectedChainId(8453);
    }

    function testRejectsWrongDeployer() public {
        vm.expectRevert("Wrong deployer");
        DeploymentPreflight.requireDeployer(address(0xBEEF), address(0xCAFE));
    }

    function testRejectsInsufficientBalance() public {
        address account = address(0x1234);
        vm.deal(account, 0.1 ether);

        vm.expectRevert("Insufficient balance");
        DeploymentPreflight.requireSufficientBalance(account, 0.2 ether);
    }

    function testRejectsZeroAddress() public {
        vm.expectRevert("Zero address");
        DeploymentPreflight.requireNonZeroAddress(address(0), "module");
    }

    function testRejectsMissingTimelock() public {
        vm.expectRevert("Missing timelock");
        DeploymentPreflight.requireTimelock(address(0), "governance");
    }

    function testAllowsCompatibleModules() public {
        address moduleA = address(0x1111);
        address moduleB = address(0x2222);
        address timelock = address(0x3333);

        DeploymentPreflight.requireCompatibleModules(moduleA, moduleB, timelock);
    }
}
