// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploymentAddressPlanner} from "../script/deploy/DeploymentAddressPlanner.sol";

contract PlannerDummy {
    uint256 public value;

    constructor(uint256 v) {
        value = v;
    }
}

contract PlannerHarness {
    function noCollision(address a) external view {
        DeploymentAddressPlanner.requireNoCollision(a);
    }

    function matches(address e, address a) external pure {
        DeploymentAddressPlanner.requireMatchesPlan(e, a);
    }
}

contract DeploymentAddressPlannerTest is Test {
    PlannerHarness internal h = new PlannerHarness();
    bytes32 internal constant SALT = bytes32(uint256(1));

    function _initCode(uint256 v) internal pure returns (bytes memory) {
        return abi.encodePacked(type(PlannerDummy).creationCode, abi.encode(v));
    }

    function test_plannedMatchesDeployed() public {
        address planned = DeploymentAddressPlanner.computeCreate2(address(this), SALT, _initCode(7));
        address deployed = address(new PlannerDummy{salt: SALT}(7));
        assertEq(planned, deployed);
    }

    function test_constructorChangeChangesAddress() public view {
        address a = DeploymentAddressPlanner.computeCreate2(address(this), SALT, _initCode(7));
        address b = DeploymentAddressPlanner.computeCreate2(address(this), SALT, _initCode(8));
        assertTrue(a != b);
    }

    function test_freshAddressPasses() public view {
        h.noCollision(address(0xBEEF));
    }

    function test_collisionReverts() public {
        address deployed = address(new PlannerDummy{salt: SALT}(7));
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentAddressPlanner.AddressCollision.selector, deployed)
        );
        h.noCollision(deployed);
    }

    function test_driftReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentAddressPlanner.PlanDrift.selector, address(1), address(2))
        );
        h.matches(address(1), address(2));
    }
}
