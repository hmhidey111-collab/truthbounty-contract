// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";
import {IV2Types} from "./IV2Types.sol";

/// @notice Content-addressed evidence commitment and status interface.
/// @dev The contract stores digests, not raw evidence. Content availability and
///      cryptographic interpretation are external assumptions. Fail-closed on
///      zero digests, duplicates, invalid nonces, closed windows, finalized
///      claims, invalid status transitions, and failed external lookups.
///
///      Pagination is keyset-based rather than offset-based: each evidence
///      record is assigned a monotonically increasing per-claim sequence number
///      (the order key) at append time. Cursors are opaque commitments that
///      bind the claim id, release id, and last-returned order key, so a
///      concurrent append between pages cannot cause an item to be skipped or
///      returned twice. Full traversal returns each evidence item exactly
///      once and terminates deterministically.
interface IEvidence is IV2Module {
    /// @notice Metadata exceeded the 1 KiB calldata limit.
    /// @param actual Supplied metadata size in bytes.
    /// @param maximum Maximum accepted metadata size in bytes.
    error MetadataTooLarge(uint256 actual, uint256 maximum);

    /// @notice The requested page limit is zero or exceeds the implementation bound.
    /// @param limit Supplied page limit.
    /// @param minimum Minimum accepted limit (always 1).
    /// @param maximum Maximum accepted limit.
    error InvalidPageLimit(uint256 limit, uint256 minimum, uint256 maximum);

    /// @notice The cursor does not bind to the requested claim, release, or
    ///         order key, or it otherwise fails integrity validation.
    /// @param claimId Claim id bound by the cursor.
    /// @param releaseId Release id bound by the cursor.
    /// @param afterOrderKey Last-returned order key bound by the cursor.
    error InvalidCursor(uint256 claimId, uint256 releaseId, uint256 afterOrderKey);

    /// @notice An evidence commitment with the same content digest already exists
    ///         for the claim.
    /// @param claimId Claim the duplicate was submitted against.
    /// @param contentHash Duplicate content digest.
    /// @param existingEvidenceId Id of the already-stored commitment.
    error DuplicateEvidence(uint256 claimId, bytes32 contentHash, uint256 existingEvidenceId);

    /// @notice The claim has been finalized and no longer accepts evidence.
    /// @param claimId Finalized claim.
    error ClaimFinalized(uint256 claimId);

    /// @notice Emitted when an evidence commitment is accepted.
    /// @param evidenceId Deterministically derived evidence identifier.
    /// @param claimId Claim receiving the evidence.
    /// @param releaseId Release the claim belongs to.
    /// @param orderKey Monotonically increasing per-claim order key.
    /// @param submitter Account that supplied the commitment.
    /// @param contentHash Digest of off-chain content.
    event EvidenceSubmitted(
        uint256 indexed evidenceId,
        uint256 indexed claimId,
        uint256 indexed releaseId,
        uint256 orderKey,
        address indexed submitter,
        bytes32 contentHash
    );

    /// @param evidenceId Evidence whose status changed.
    /// @param previousStatus Status before the change.
    /// @param newStatus Status after the change.
    /// @param actor Authorized administrator.
    event EvidenceStatusChanged(uint256 indexed evidenceId, IV2Types.EvidenceStatus previousStatus, IV2Types.EvidenceStatus newStatus, address indexed actor);

    /// @notice Submits an evidence commitment for an active claim.
    /// @dev Wraps commitEvidence, deriving the metadata digest and contributor nonce automatically.
    ///      Assigns the next per-claim order key at append time. Fails closed on
    ///      duplicate content digests for the same claim and on finalized claims.
    /// @param claimId Existing claim receiving evidence.
    /// @param contentHash Digest of off-chain content.
    /// @param metadata Opaque metadata bytes; its keccak256 digest is stored on-chain.
    /// @return evidenceId Deterministically derived identifier.
    function submitEvidence(uint256 claimId, bytes32 contentHash, bytes caldata metadata) external returns (uint256 evidenceId);

    /// @notice Sets the evidence acceptance status under the evidence administrator authority.
    /// @dev Enforces a bounded state-transition matrix: NONE is unreachable as a
    ///      destination, SUBMITTED may transition anywhere except NONE, and a
    ///      terminal status (ACCEPTED / REJECTED / REVOKED) is sticky.
    /// @param evidenceId Evidence to update.
    /// @param status New evidence status.
    function setEvidenceStatus(uint256 evidenceId, IV2Types.EvidenceStatus status) external;

    /// @notice Reads the public evidence record.
    /// @param evidenceId Evidence to read.
    /// @return evidence Public evidence fields; the metadata digest is excluded.
    function getEvidence(uint256 evidenceId) external view returns (IV2Types.Evidence memory evidence);

    /// @notice Returns a keyset-paginated slice of evidence IDs for a claim.
    /// @dev Ordering is by the monotonically increasing per-claim order key assigned
    ///      at append time. The cursor is an opaque commitment binding the claim id,
    ///      release id, and the last-returned order key; it is therefore not a
    ///      positional offset and cannot drift when new evidence is appended between
    ///      pages. A zero cursor starts from the beginning of the claim's sequence.
    ///      An exhausted or terminal cursor returns an empty page with an
    ///      unchanged next cursor. Invalid limits and cursors that do not bind to
    ///      the requested claim fail closed with canonical errors.
    /// @param claimId Claim whose evidence IDs are read.
    /// @param cursor Opaque cursor from a prior page; zero starts at the beginning.
    /// @param limit Maximum number of IDs to return; must be within the implementation bound.
    /// @return evidenceIds Ordered page of evidence identifiers.
    /// @return nextCursor Opaque cursor for the next page; equals the terminal
    ///       cursor when the claim's sequence is exhausted.
    function claimEvidence(uint256 claimId, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory evidenceIds, uint256 nextCursor);

    /// @notice Computes the deterministic identifier for a commitment without storing it.
    /// @dev Domain-separated by chain id, contract address, claim id, contributor, digests, and nonce.
    /// @return evidenceId Deterministic identifier; not an existence proof.
    function computeEvidenceId(uint256 claimId, address contributor, bytes32 contentDigest, bytes32 metadataDigest, uint256 nonce) external view returns (uint256 evidenceId);

    /// @notice Verifies that a caller-supplied commitment tuple matches the stored record
    ///         and that the stored evidenceId matches the domain-separated derivation.
    /// @dev Fails closed unless every field matches and the deterministic ID check passes.
    /// @return ok True only if the record exists and all fields match the derivation.
    function verifyEvidenceCommitment(uint256 evidenceId, uint256 claimId, address contributor, bytes32 contentDigest, bytes32 metadataDigest, uint256 nonce) external view returns (bool ok);

    /// @notice Returns the next required nonce for a contributor.
    function nextContributorNonce(address contributor) external view returns (uint256 nonce);

    /// @notice Returns the number of evidence commitments associated with a claim.
    function evidenceCount(uint256 claimId) external view returns (uint256 count);

    /// @notice Returns the order key assigned to an evidence record.
    /// @dev Reverts if the evidence does not exist.
    /// @param evidenceId Evidence to query.
    /// @return orderKey Monotonically increasing per-claim order key.
    function evidenceOrderKey(uint256 evidenceId) external view returns (uint256 orderKey);

    /// @notice Returns the terminal cursor for a claim's evidence sequence.
    /// @dev Passing this cursor to claimEvidence returns an empty page.
    /// @param claimId Claim whose terminal cursor is requested.
    /// @return cursor Terminal opaque cursor.
    function claimEvidenceTerminalCursor(uint256 claimId) external view returns (uint256 cursor);
}
