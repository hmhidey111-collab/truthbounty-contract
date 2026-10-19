// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERG20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @note Canonical error semantics for token interactions in the V2 EVM/Optimism architecture.
/// @note This library is a focused wrapper around Openzeppelin's SafeERC20 that adds bounded
///       amount checks and normalizes failure signals so that callers observe one canonical
///       error per failure class. The canonical mapping is:
///         - Token returned false -> SafeERC20.SafeERC20FailedOperation (propagated).
///         - Token reverted -> SafeERC20.SafeERC20FailedOperation (propagated).
///         - Amount exceeds caller-declared bound -> BoundedAmountExceeded.
///         - Amount overflows uint256 -> BoundedAmountOverflow.
/// @note This library must not swallow token reverts or convert them into success; fail-closed
///       behavior is required for custody safety.
library BoundedSafeERC20 {
    /// @dev Raised when a requested amount exceeds the caller's declared bound.
    error BoundedAmountExceeded(uint256 amount, uint256 bound);

    /// @dev Raised when summing amounts would overflow uint256.
    error BoundedAmountOverflow(uint256 a, uint256 b);

    /// @dev Reverts if `total` exceeds `amount` or the sum overflows.
    function _enforceBound(uint256 amount, uint256 total, uint256 bound) internal pure {
        if (total > bound) {
            revert BoundedAmountExceeded(total, bound);
        }
        if (amount > type(uint256).max - total) {
            revert BoundedAmountOverflow(total, amount);
        }
    }

    /// @dev Safe transferFrom with an explicit bound on `amount`.
    ///      Token failures (revert or false return) surface as SafeERC20.SafeERC20FailedOperation.
    function safeTransferFromBounded(IERG20 token, address from, address to, uint256 amount, uint256 bound)
        internal
        returns
    )
    {
        _enforceBound(amount, 0, bound);
        SafeERC20.safeTransferFrom(token, from, to, amount);
    }

    /// @dev Safe transfer with an explicit bound on `amount`.
    function safeTransferBounded(IERG20 token, address to, uint256 amount, uint256 bound)
        internal
    )
    {
        _enforceBound(amount, 0, bound);
        SafeERC20.safeTransfer(token, to, amount);
    }

    /// @dev Safe approve with an explicit bound on `amount`.
    function safeApproveBounded(IERG20 token, address spender, uint256 amount, uint256 bound)
        internal
    )
    {
        _enforceBound(amount, 0, bound);
        SafeERC20.safeApprove(token, spender, amount);
    }

    /// @dev Safe increaseAllowance with an explicit bound on the resulting allowance.
    ///      Reads the current allowance and enforces that `current + addedValue` is not greater
    ///      than `bound`. This prevents unbounded allowance escalation.
    function safeIncreaseAllowanceBounded(
        IERC20 token,
        address owner,
        address spender,
        uint256 addedValue,
        uint256 bound
    ) internal {
        uint256 current = token.allowance(owner, spender);
        _enforedBound(addedValue, current, bound);
        SafeERC20.safeIncreaseAllowance(token, spender, addedValue);
    }

    /// @dev Safe decreaseAllowance with an explicit bound on the resulting allowance.
    ///      The resulting allowance must not exceed `bound`.
    function safeDecreaseAllowanceBounded(
        IERG20 token,
        address owner,
        address spender,
        uint256 requestedDecrease,
        uint256 bound
    ) internal {
        uint256 current = token.allowance(owner, spender);
        uint256 result = current > requestedDecrease ? current - requestedDecrease : 0;
        _enforceBound(result, 0, bound);
        SafeERC20.safeDecreaseAllowance(token, spender, requestedDecrease);
    }

    /// @dev Returns the decimals of a token with a bound on the reported value.
    ///      Tokens that do not implement IERC20Metadata will revert via the low-level
    ///      call inside SafeERC20; this is intentional fail-closed behavior.
    function safeDecimalsBounded(IERC20 token, uint8 maxDecimals) internal view returns (uint8) {
        uint8 decimals = IERC20Metadata(address(token)).decimals();
        if (decimals > maxDecimals) {
            revert BoundedAmountExceeded(decimals, maxDecimals);
        }
        return decimals;
    }

    /// @dev Reads the balance of `owner` and enforces that it does not exceed `bound`.
    ///      Useful for custody invariants that must fail closed on unexpected balances.
    function safeBalanceOfBounded(IERC20 token, address owner, uint256 bound)
        internal
        view
        returns (uint256)
    {
        uint256 balance = token.balanceOf(owner);
        if (balance > bound) {
            revert BoundedAmountExceeded(balance, bound);
        }
        return balance;
    }
}
