// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedStaticCall} from "./BoundedStaticCall.sol";

/// @notice Safe ERC20 operations that never copy unbounded token returndata.
library BoundedSafeERC20 {
    /// @notice Maximum gas forwarded to each ERC20 operation.
    /// @dev Generous for standard tokens while limiting hostile-token gas griefing.
    uint256 internal constant ERC20_CALL_GAS_LIMIT = 250_000;
    /// @notice The token reverted, returned malformed data, or reported failure.
    /// @dev Selector matches OpenZeppelin SafeERC20FailedOperation(address).
    error SafeERC20FailedOperation(address token);

    /// @notice A no-return token call targeted an address without code.
    /// @dev Selector matches OpenZeppelin AddressEmptyCode(address).
    error AddressEmptyCode(address target);

    /// @notice Calls `transfer` and validates only the bounded optional return word.
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20.transfer, (to, value)));
    }

    /// @notice Calls `transferFrom` and validates only the bounded optional return word.
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20.transferFrom, (from, to, value)));
    }

    /// @notice Increases an allowance while bounding token return-data copying.
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        (bool success, uint256 currentAllowance, uint256 returnSize) = BoundedStaticCall.staticcallWord(
            address(token),
            abi.encodeCall(IERC20.allowance, (address(this), spender))
        );
        if (!success || returnSize != 32) revert SafeERC20FailedOperation(address(token));
        uint256 newAllowance = currentAllowance + value;
        _callOptionalReturn(token, abi.encodeCall(IERC20.approve, (spender, newAllowance)));
    }

    /// @notice Decreases an allowance while bounding token return-data copying.
    /// @dev Mirrors OpenZeppelin SafeERC20.safeDecreaseAllowance semantics: the
    ///      allowance is reduced by `value` and the call reverts if `value`
    ///      exceeds the current allowance, instead of underflowing.
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        (bool success, uint256 currentAllowance, uint256 returnSize) = BoundedStaticCall.staticcallWord(
            address(token),
            abi.encodeCall(IERC20.allowance, (address(this), spender))
        );
        if (!success || returnSize != 32) revert SafeERC20FailedOperation(address(token));
        if (value > currentAllowance) revert SafeERC20FailedOperation(address(token));
        uint256 newAllowance = currentAllowance - value;
        _callOptionalReturn(token, abi.encodeCall(IERC20.approve, (spender, newAllowance)));
    }

    function _callOptionalReturn(IERC20 token, bytes memory callData) private {
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        address tokenAddress = address(token);

        assembly {
            let output := mload(0x40)
            mstore(0x40, add(output, 0x20))
            success := call(ERC20_CALL_GAS_LIMIT, tokenAddress, 0, add(callData, 0x20), mload(callData), output, 0x20)
            returnSize := returndatasize()
            returnValue := mload(output)
        }

        if (!success) revert SafeERC20FailedOperation(tokenAddress);
        if (returnSize == 0) {
            if (tokenAddress.code.length == 0) revert AddressEmptyCode(tokenAddress);
            return;
        }
        if (returnSize < 32 || returnValue != 1) revert SafeERC20FailedOperation(tokenAddress);
    }

    /// @notice Approves a spender while bounding token return-data copying.
    /// @dev Reverts if the returned value is not a single word equal to 1.
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20.approve, (spender, value)));
    }

    /// @notice Resets allowance to zero and then sets to new value for spender rotation.
    /// @dev Used to safely update allowances on tokens that require allowance to be zero before non-zero change.
    function safeResetAllowance(IERC20 token, address spender) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20.approve, (spender, 0)));
    }

    /// @notice Force approves a spender, handling tokens that require zero-reset before non-zero approval.
    /// @dev First resets to zero, then approves the new value. This handles tokens like USDT.
    function safeForceApprove(IERC20 token, address spender, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20.approve, (spender, 0)));
        _callOptionalReturn(token, abi.encodeCall(IERC20.approve, (spender, value)));
    }

    /// @notice Revoke allowance by setting to zero.
    function safeRevokeAllowance(IERC20 token, address spender) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20.approve, (spender, 0)));
    }

}
