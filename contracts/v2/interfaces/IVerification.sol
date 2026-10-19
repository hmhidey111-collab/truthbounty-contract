// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";
import {IV2Types} from "./IV2Types.sol";


/// @notice Verification submission and weighted verdict interface.
/// @dev Verification authority, stake custody, duplicate rules, and pagination bounds are protocol invariants enforced by the implementation.
interface IVerification is IV2Module {
    /// @notice Emitted when a verifier submits a verification.
    /// @param verificationId Newly assigned verification identifier.
    /// @param claimId Claim being verified.
    /// @param verifier Verifier account.
    /// @param supportsClaim True when the verifier supports the claim, false when opposing it.
    /// @param stake Stake weight committed in asset base units.
    event VerificationSubmitted(uint256 indexed verificationId, uint256 indexed claimId, address indexed verifier, bool supportsClaim, uint256 stake);

    /// @notice Submits a verifier verdict for an open claim.
    /// @dev Must authorize the verifier, require sufficient stake, prevent duplicate verdicts where configured, and delegate custody to the canonical stake module before emitting the event.
    /// @param claimId Claim being verified.
    /// @param supportsClaim Verdict in support of the claim when true.
    /// @param rationale Opaque off-chain explanation or commitment; it is not parsed by the EVM.
    /// @return verificationId Newly assigned verification identifier.
    function submitVerification(uint256 claimId, bool supportsClaim, bytes calldata rationale) external returns (uint256 verificationId);

    /// @notice Reads a verification record.
    /// @param verificationId Verification to read.
    /// @return verification Stored verification fields.
    function getVerification(uint256 verificationId) external view returns (IV2Types.Verification memory verification);

    /// @notice Returns a bounded page of verification IDs for a claim.
    /// @dev IDs are returned in canonical insertion order; implementations must reject invalid limits and handle exhausted cursors without state changes.
    /// @param claimId Claim whose verification IDs are read.
    /// @param cursor Zero-based starting index.
    /// @param limit Maximum number of IDs to return.
    /// @return ids Ordered page of verification identifiers.
    /// @return nextCursor Cursor for the next page, or the total count when exhausted.
    function claimVerifications(uint256 claimId, uint256 cursor, uint256 limit) external view returns (uint256[] memory ids, uint256 nextCursor);
}
