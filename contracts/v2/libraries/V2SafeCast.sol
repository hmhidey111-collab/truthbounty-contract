// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {V2Errors} from "./V2Errors.sol";

/// @title V2SafeCast
/// @notice Bounded integer narrowing for canonical V2 storage and event fields (V2-SC-161).
/// @dev Solidity's explicit `uintN(x)` conversion silently keeps the low N bits of `x`; it never
///      reverts. Every canonical V2 site that narrows a value whose range is not already proven by
///      a prior check or a constant MUST go through this library instead, so an out-of-range value
///      fails closed with a deterministic, field-identifying custom error rather than being
///      truncated into storage or an event.
///
///      Error contract (stable ABI, see `docs/v2/safe-cast-integer-boundaries.md`):
///      - `V2Errors.SafeCastOverflow(field, value, max)` — `value > max` for the target width, where
///        `max == type(uintN).max` of the destination and `field` names the stored/emitted field.
///      - `V2Errors.SafeCastNegative(field, value)` — a negative signed value was converted to an
///        unsigned field.
///
///      Field identifiers are left-aligned ASCII `bytes32` literals (`"<Module>.<field>"`) so the
///      revert data is self-describing off-chain and stable across releases. They are published
///      here as constants so modules, tests, and tooling share one spelling.
///
///      The raw conversions inside this library are the only unconditional narrowing casts the
///      static gate (`scripts/check-safe-casts.mjs`) accepts as `guarded`: each one is preceded by
///      the exact `value > type(uintN).max` bound check for its width.
library V2SafeCast {
    // =========================================================================
    // Field identifiers (units in NatSpec; all timestamps are Unix seconds)
    // =========================================================================

    /// @notice `IV2Types.Claim.createdAt` written by `Claims.createClaim` (Unix seconds, uint64).
    bytes32 internal constant FIELD_CLAIM_CREATED_AT = "Claims.createdAt";
    /// @notice Timestamp emitted by `Claims` lifecycle events (Unix seconds, uint64).
    bytes32 internal constant FIELD_CLAIM_EVENT_TIMESTAMP = "Claims.eventTimestamp";
    /// @notice `EvidenceRegistry.EvidenceCommitment.committedAt` (Unix seconds, uint64).
    bytes32 internal constant FIELD_EVIDENCE_COMMITTED_AT = "Evidence.committedAt";
    /// @notice `IModuleRegistry.ModuleInfo.changedAt` (Unix seconds, uint64).
    bytes32 internal constant FIELD_MODULE_CHANGED_AT = "ModuleRegistry.changedAt";
    /// @notice `IModuleRegistry.ModuleInfo.activatedAt` (Unix seconds, uint64).
    bytes32 internal constant FIELD_MODULE_ACTIVATED_AT = "ModuleRegistry.activatedAt";
    /// @notice Timestamp emitted by `StakeVault` custody events (Unix seconds, uint64).
    bytes32 internal constant FIELD_VAULT_EVENT_TIMESTAMP = "StakeVault.eventTimestamp";
    /// @notice Timestamp emitted by `EmergencyControls` pause events (Unix seconds, uint64).
    bytes32 internal constant FIELD_EMERGENCY_EVENT_TIMESTAMP = "EmergencyControls.eventTs";
    /// @notice `ClaimRegistry.Claim.createdAt` (Unix seconds, uint64).
    bytes32 internal constant FIELD_REGISTRY_CREATED_AT = "ClaimRegistry.createdAt";
    /// @notice `ClaimRegistry.CanonicalClaim.createdAt` (Unix seconds, uint64).
    bytes32 internal constant FIELD_REGISTRY_CANONICAL_CREATED_AT = "ClaimRegistry.canonicalCreatedAt";
    /// @notice Immutable `CHAIN_ID` of `ConsumerGuaranteesAnchor` (EIP-155 chain id, uint64).
    bytes32 internal constant FIELD_GUARANTEES_CHAIN_ID = "ConsumerGuarantees.chainId";
    /// @notice Immutable `CHAIN_ID` of `SupplyChainAttestationAnchor` (EIP-155 chain id, uint64).
    bytes32 internal constant FIELD_ATTESTATION_CHAIN_ID = "SupplyChainAttestation.chainId";
    /// @notice ERC-6372 `clock()` of `TruthBountyGovernanceToken` (Unix seconds, uint48).
    bytes32 internal constant FIELD_GOVERNANCE_CLOCK = "GovernanceToken.clock";
    /// @notice `CanonicalEventLibrary.currentTimestamp()` (Unix seconds, uint64).
    bytes32 internal constant FIELD_CANONICAL_EVENT_TIMESTAMP = "CanonicalEvent.timestamp";
    /// @notice Timestamp written by the V2 conformance fixtures (Unix seconds, uint64).
    bytes32 internal constant FIELD_FIXTURE_TIMESTAMP = "V2Fixture.timestamp";

    // =========================================================================
    // Unsigned narrowing
    // =========================================================================

    /// @notice Narrows `value` to uint8, reverting when it exceeds `type(uint8).max`.
    function toUint8(uint256 value, bytes32 field) internal pure returns (uint8) {
        if (value > type(uint8).max) revert V2Errors.SafeCastOverflow(field, value, type(uint8).max);
        return uint8(value);
    }

    /// @notice Narrows `value` to uint16, reverting when it exceeds `type(uint16).max`.
    function toUint16(uint256 value, bytes32 field) internal pure returns (uint16) {
        if (value > type(uint16).max) revert V2Errors.SafeCastOverflow(field, value, type(uint16).max);
        return uint16(value);
    }

    /// @notice Narrows `value` to uint24, reverting when it exceeds `type(uint24).max`.
    function toUint24(uint256 value, bytes32 field) internal pure returns (uint24) {
        if (value > type(uint24).max) revert V2Errors.SafeCastOverflow(field, value, type(uint24).max);
        return uint24(value);
    }

    /// @notice Narrows `value` to uint32, reverting when it exceeds `type(uint32).max`.
    function toUint32(uint256 value, bytes32 field) internal pure returns (uint32) {
        if (value > type(uint32).max) revert V2Errors.SafeCastOverflow(field, value, type(uint32).max);
        return uint32(value);
    }

    /// @notice Narrows `value` to uint48, reverting when it exceeds `type(uint48).max`.
    function toUint48(uint256 value, bytes32 field) internal pure returns (uint48) {
        if (value > type(uint48).max) revert V2Errors.SafeCastOverflow(field, value, type(uint48).max);
        return uint48(value);
    }

    /// @notice Narrows `value` to uint64, reverting when it exceeds `type(uint64).max`.
    function toUint64(uint256 value, bytes32 field) internal pure returns (uint64) {
        if (value > type(uint64).max) revert V2Errors.SafeCastOverflow(field, value, type(uint64).max);
        return uint64(value);
    }

    /// @notice Narrows `value` to uint96, reverting when it exceeds `type(uint96).max`.
    function toUint96(uint256 value, bytes32 field) internal pure returns (uint96) {
        if (value > type(uint96).max) revert V2Errors.SafeCastOverflow(field, value, type(uint96).max);
        return uint96(value);
    }

    /// @notice Narrows `value` to uint128, reverting when it exceeds `type(uint128).max`.
    function toUint128(uint256 value, bytes32 field) internal pure returns (uint128) {
        if (value > type(uint128).max) revert V2Errors.SafeCastOverflow(field, value, type(uint128).max);
        return uint128(value);
    }

    // =========================================================================
    // Signed -> unsigned
    // =========================================================================

    /// @notice Converts a signed value to uint256, reverting on any negative input.
    /// @dev `uint256(int256(-1))` would otherwise silently become `type(uint256).max`.
    function toUint256(int256 value, bytes32 field) internal pure returns (uint256) {
        if (value < 0) revert V2Errors.SafeCastNegative(field, value);
        return uint256(value);
    }

    // =========================================================================
    // Clock helpers
    // =========================================================================

    /// @notice `block.timestamp` narrowed to uint64 Unix seconds, failing closed past `type(uint64).max`.
    function timestamp64(bytes32 field) internal view returns (uint64) {
        return toUint64(block.timestamp, field);
    }

    /// @notice `block.timestamp` narrowed to uint48 Unix seconds, failing closed past `type(uint48).max`.
    function timestamp48(bytes32 field) internal view returns (uint48) {
        return toUint48(block.timestamp, field);
    }
}
