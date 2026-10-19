// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BoundedStaticCall} from "./BoundedStaticCall.sol";

/**
 * @title AmountUnits
 * @notice Explicit conversion between raw token units and the protocol's canonical 18-decimal units.
 * @dev Raw amounts are denominated in the asset's own smallest unit (e.g. 6 decimals for USDC).
 *      Canonical amounts are always scaled to `CANONICAL_DECIMALS`. All conversions fail closed:
 *      unsupported decimals, unreadable token metadata, overflow, and lossy down-scaling revert.
 */
library AmountUnits {
    /// @notice Decimal precision of canonical protocol amounts.
    uint8 internal constant CANONICAL_DECIMALS = 18;

    /// @notice Highest asset decimal precision the protocol accepts.
    uint8 internal constant MAX_DECIMALS = 36;

    /// @notice Thrown when an asset reports more than `MAX_DECIMALS` decimals.
    error UnsupportedDecimals(uint8 decimals);

    /// @notice Thrown when a token's `decimals()` cannot be read or returns malformed data.
    error DecimalsUnavailable(address token);

    /// @notice Thrown when converting `amount` from `fromDecimals` to `toDecimals` would drop non-zero precision.
    error PrecisionLoss(uint256 amount, uint8 fromDecimals, uint8 toDecimals);

    /**
     * @notice Reads and validates an ERC20 token's decimals.
     * @param token ERC20 token address.
     * @return decimals The token's decimal precision.
     */
    function tokenDecimals(address token) internal view returns (uint8 decimals) {
        if (token.code.length == 0) revert DecimalsUnavailable(token);
        (bool ok, uint256 raw, uint256 returnSize) = BoundedStaticCall.staticcallWord(
            token,
            abi.encodeWithSignature("decimals()")
        );
        if (!ok || returnSize != 32) revert DecimalsUnavailable(token);
        if (raw > MAX_DECIMALS) revert UnsupportedDecimals(raw > type(uint8).max ? type(uint8).max : uint8(raw));
        decimals = uint8(raw);
    }

    /**
     * @notice Converts `amount` between decimal precisions, reverting on any precision loss.
     * @param amount Amount denominated in `fromDecimals`.
     * @param fromDecimals Source precision.
     * @param toDecimals Target precision.
     * @return converted Amount denominated in `toDecimals`.
     */
    function convert(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256 converted) {
        if (fromDecimals > MAX_DECIMALS) revert UnsupportedDecimals(fromDecimals);
        if (toDecimals > MAX_DECIMALS) revert UnsupportedDecimals(toDecimals);
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals < toDecimals) return amount * 10 ** (toDecimals - fromDecimals);
        uint256 factor = 10 ** (fromDecimals - toDecimals);
        if (amount % factor != 0) revert PrecisionLoss(amount, fromDecimals, toDecimals);
        converted = amount / factor;
    }

    /**
     * @notice Converts a raw token amount into canonical 18-decimal units.
     * @param rawAmount Amount in the asset's own units.
     * @param decimals Asset decimal precision.
     * @return canonical Amount in canonical units.
     */
    function toCanonical(uint256 rawAmount, uint8 decimals) internal pure returns (uint256 canonical) {
        canonical = convert(rawAmount, decimals, CANONICAL_DECIMALS);
    }

    /**
     * @notice Converts a canonical amount into raw token units, reverting if it is not exactly representable.
     * @param canonical Amount in canonical units.
     * @param decimals Asset decimal precision.
     * @return rawAmount Amount in the asset's own units.
     */
    function fromCanonical(uint256 canonical, uint8 decimals) internal pure returns (uint256 rawAmount) {
        rawAmount = convert(canonical, CANONICAL_DECIMALS, decimals);
    }
}
