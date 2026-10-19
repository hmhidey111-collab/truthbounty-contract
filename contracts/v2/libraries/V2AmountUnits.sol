// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { BoundedStaticCall } from "../../libraries/BoundedStaticCall.sol";

/// @title V2AmountUnits
/// @notice Explicit conversion between an asset's native base units and 18-decimal normalized units.
/// @dev All custody accounting stays in native asset units; normalized units are only used for
///      cross-asset comparison and reporting. Conversions round down (toward the protocol) deterministically.
/// @dev Rounding policy (explicit and bounded):
///      - `toNormalize`: floors the native amount into WAD. Any remainder is discarded from the
///        reported normalized value and NEVER is used for custody accounting.
///      - `fromNormalize`: floors the WAD amount into native units. Callers must treat the
///        result as a upper bound on the native amount that can be funded by a given normalized
///        amount; the difference remains in the protocol's favor and is not created or destroyed.
///      - Both functions are pure and deterministic for a given (amount, decimals) pair, so
///        repeated calls cannot change the result and cannot create or destroy value.
///      - Conversions are only defined for decimals <= `MAX_ASSET_DECIMALS`; out-of-range decimals
///        fail closed via `DecimalsOutOfRange`.
/// @dev Token compatibility (excluded tokens):
///      - This library only performs pure arithmetic and a bounded `decimals()` read. It does NOT
///        attempt to detect or support fee-on-transfer, rebasing, or other non-standard tokens.
///        Those tokens are explicitly out of scope for this library and must be rejected by
///        the consuming custody contracts via balance-delta checks before any credit is recorded.
///      - Assets whose `decimals()` is missing, malformed, or outside [0, 36] fail closed via
///        `UnsupportedDecimals`.
///      - Assets with no code (NAT/EOD) fail closed via `UnsupportedDecimals`.
library V2AmountUnits {
    /// @notice Decimals used for normalized (WAD) amounts.
    uint8 internal constant NORMALIZED_DECIMALS = 18;

    /// @notice Largest supported asset decimals.
    uint8 internal constant MAX_ASSET_DECIMALS = 36;

    /// @notice Thrown when an asset reports unsupported or unreadable decimals.
    error UnsupportedDecimals(address asset);

    /// @notice Thrown when a decimals value exceeds `MAX_ASSET_DECIMALS`.
    error DecimalsOutOfRange(uint8 decimals);

    /// @notice Thrown when a normalized-to-native conversion would overflow uint256.
    error NormalizedAmountOverflow(uint256 normalized, uint8 decimals);

    /// @notice Reads an asset's decimals, failing closed on missing, malformed, or out-of-range values.
    function decimalsOf(address asset) internal view returns (uint8) {
        if (asset.code.length == 0) revert UnsupportedDecimals(asset);
        (bool ok, uint256 raw, uint256 returnSize) = BoundedStaticCall.staticcallWord(
            asset,
            abi.encodeCall(IERC20Metadata.decimals, ())
        );
        if (!ok || returnSize != 32) revert UnsupportedDecimals(asset);
        if (raw > MAX_ASSET_DECIMALS) revert UnsupportedDecimals(asset);
        return uint8(raw);
    }

    /// @notice Converts a native-unit amount into 18-decimal normalized units (rounds down).
    /// @dev Rounding is floor and lossless for custody: the native amount is never altered.
    function toNormalized(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals > MAX_ASSET_DECIMALS) revert DecimalsOutOfRange(decimals);
        if (decimals == NORMALIZED_DECIMALS) return amount;
        if (decimals < NORMALIZED_DECIMALS) {
            // Scaling up by at most 10^18 cannot overflow for any uint256 amount only if amount
            // is sufficiently small; Solidity 0.8 checked arithmetic reverts on overflow,
            // which is the desired fail-closed behavior for unrepresentable amounts.
            return amount * 10 ** (NORMALIZED_DECIMALS - decimals);
        }
        return amount / 10 ** (decimals - NORMALIZED_DECIMALS);
    }

    /// @notice Converts an 18-decimal normalized amount into native units (rounds down).
    /// @dev Rounding is floor and the result is an upper bound on the fundable native amount.
    ///      Scaling up is guarded against overflow and fails closed via `NormalizedAmountOverflow`.
    function fromNormalized(uint256 normalized, uint8 decimals) internal pure returns (uint256) {
        if (decimals > MAX_ASSET_DECIMALS) revert DecimalsOutOfRange(decimals);
        if (decimals == NORMALIZED_DECIMALS) return normalized;
        if (decimals < NORMALIZED_DECIMALS) {
            return normalized / 10 ** (NORMALIZED_DECIMALS - decimals);
        }
        uint256 scale = 10 ** (decimals - NORMALIZED_DECIMALS);
        // Explicit overflow guard so the failure is deterministic and auditable.
        if (normalized > type(uint256).max / scale) revert NormalizedAmountOverflow(normalized, decimals);
        return normalized * scale;
    }

    /// @notice Returns true if the decimals value is within the supported range.
    /// @dev Pure helper for callers that want to validate configuration without reverting.
    function isSupportedDecimals(uint8 decimals) internal pure returns (bool) {
        return decimals <= MAX_ASSET_DECIMALS;
    }
}
