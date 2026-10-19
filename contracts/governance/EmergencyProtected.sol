 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
interface IEmergencyController {
    function isOperationAllowed(
        bytes32 operationType
    ) external view returns (bool);
}

/**
 * @title EmergencyProtected
 * @notice Provides operation-level emergency pause protection.
 *
 * @dev Protocol modules inherit this contract and apply
 *      `whenNotPaused(operationType)` to restricted functions.
 *
 *      The EmergencyController can only be configured once.
 *      Controller failures fail closed, meaning the protected
 *      operation is blocked if the controller cannot be queried.
 */
abstract contract EmergencyProtected {
    /// @notice EmergencyController responsible for pause state.
    address public emergencyController;

    error EmergencyControllerNotSet();
    error EmergencyControllerAlreadySet();
    error ZeroEmergencyController();
    error OperationPaused(bytes32 operationType, uint8 pauseLevel);
    error EmergencyControllerQueryFailed(bytes32 operationType);

    /**
     * @notice Initialise the emergency controller.
     *
     * @dev Can only be called once by the inheriting contract.
     *
     * @param controller Address of the deployed EmergencyController.
     */
    function _setEmergencyController(
        address controller
    ) internal {
        if (controller == address(0)) {
            revert ZeroEmergencyController();
        }

        if (emergencyController != address(0)) {
            revert EmergencyControllerAlreadySet();
        }

        emergencyController = controller;
    }

    /**
     * @notice Reverts if the specified operation is paused.
     *
     * @param operationType Operation identifier, e.g.
     *        keccak256("claim_creation").
     */
    modifier whenNotPaused(
        bytes32 operationType
    ) {
        address controller = emergencyController;

        if (controller == address(0)) {
            revert EmergencyControllerNotSet();
        }

        (bool success, bytes memory data) = controller.staticcall(
            abi.encodeCall(
                IEmergencyController.isOperationAllowed,
                (operationType)
            )
        );

        if (!success || data.length != 32) {
            revert EmergencyControllerQueryFailed(operationType);
        }

        bool allowed = abi.decode(data, (bool));

        if (!allowed) {
            revert OperationPaused(operationType, 0);
        }

        _;
    }
}
