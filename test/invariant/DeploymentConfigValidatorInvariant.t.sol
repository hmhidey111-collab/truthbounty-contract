// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { DeploymentConfigValidatorHandler } from "./DeploymentConfigValidatorHandler.sol";
import { DeploymentConfigValidator } from "../../contracts/deployment/DeploymentConfigValidator.sol";

/// @notice External wrapper so the invariant can observe library reverts across a call boundary.
contract InvariantValidatorProbe {
    function validate(DeploymentConfigValidator.Config memory config) external view {
        DeploymentConfigValidator.validate(config);
    }
}

/**
 * @title DeploymentConfigValidatorInvariant
 * @notice Stateful invariant suite for the canonical V2 deployment validator (SC-068).
 * @dev Invariant: the validator is fail-closed — a configuration that has ever received a
 *      documented unsafe mutation is ALWAYS rejected, while a clean configuration is NEVER
 *      rejected, across arbitrary mutation sequences.
 */
contract DeploymentConfigValidatorInvariant is Test {
    DeploymentConfigValidatorHandler public handler;
    InvariantValidatorProbe public probe;

    function setUp() public {
        handler = new DeploymentConfigValidatorHandler();
        probe = new InvariantValidatorProbe();
        targetContract(address(handler));
    }

    function invariant_FailClosed() public {
        bool reverts = _validateReverts(handler.config());
        if (handler.poisoned()) {
            assertTrue(reverts, "poisoned config was not rejected");
        } else {
            assertFalse(reverts, "clean config was falsely rejected");
        }
    }

    function _validateReverts(DeploymentConfigValidator.Config memory config) internal returns (bool) {
        try probe.validate(config) {
            return false;
        } catch {
            return true;
        }
    }
}
