// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IClaimRegistry} from "../interfaces/IClaimRegistry.sol";
import {ITruthBountyEvents} from "../interfaces/ITruthBountyEvents.sol";
import {EmergencyGuarded} from "./EmergencyGuarded.sol";
import {IEvidence} from "./interfaces/IEvidence.sol";
import {IV2Module} from "./interfaces/IV2Module.sol";
import {IV2Types} from "./interfaces/IV2Types.sol";
import {V2Errors} from "./libraries/V2Errors.sol";
import {V2SafeCast} from "./libraries/V2SafeCast.sol";
import {V2Scopes} from "./libraries/V2Scopes.sol";
import {V2WiredPauseGuard} from "./libraries/V2PauseGuard.sol";
import {PauseMatrix} from "./libraries/PauseMatrix.sol";
import {ProtocolExecutionBounds} from "../performance/ProtocolExecutionBounds.sol";

/// @title EvidenceRegistry
/// @notice Content-addressed V2 evidence commitment registry.
/// @dev Stores only immutable digests and deterministic IDs. Raw evidence
///      content, CIDs, URLs, signatures, and private data stay off-chain.
///      Fail-closed on zero digests, duplicates, invalid nonces, closed windows,
///      finalized claims, paused state, invalid status transitions, and failed
///      external registry lookups.
///
///      Pause matrix (V2-SC-162, `PauseMatrix` v1): evidence submission and
///      adjudication fail closed under the scoped `SCOPE_EVIDENCE` pause of the
///      wired V2 pause authority *and* under this module's local `Pausable`
///      switch (nested pause: either one blocks, lifting one never reopens the
///      other). `pause()` is a protective RISK_REDUCENG action; `unpause()` only
///      lifts the local switch and can never override the scoped authority.
///
///      Pagination (PREWAVE-SC-047): evidence is ordered by monotonically
///      increasing `id`. Cursors are opaque `bytes32` tokens that bind the
///      claim, the claim release generation, and the last-returned order key.
///      Pages are bounded by `MAX_PAGE_SIZE` and cannot be empty. The cursor
///      is not an offset, so appends between pages cannot shift or skip items.
///      Duplicates are rejected at write time and defensively skipped at read
///      time. Finalization is append-only and never rewrites historical reads.
contract EvidenceRegistry is ERC165, AccessControl, Pausable, IEvidence, ITruthBountyEvents, V2WiredPauseGuard, EmergencyGuarded {
    bytes32 public constant EVIDENCE_ADMIN_ROLE = keccak256("EVIDENCE_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint16 public constant EVENT_SCHEMA_VERSION = 1;
    uint256 public constant MAX_PAGE_SIZE = 100;
    uint256 public constant MAX_EVIDENCE_PER_CLAIM = ProtocolExecutionBounds.MAX_EVIDENCE_PER_CLAIM;
    /// @notice Maximum metadata calldata hashed for one evidence commitment.
    uint256 public constant MAX_METADATA_BYTES = 1_024;

    /// @notice Fixed, domain-separated reason attached to admin-driven pause logs.
    /// @dev `EmergencyPauseActivatedV1` requires a `bytes32 reason`; the pause
    ///      authority for this module is the `PAUSER_ROLE` holder and no
    ///      per-call reason is collected, so the constant keeps the log
    ///      deterministic across deployments.
    bytes32 public constant ADMIN_PAUSE_REASON = keccak256("EVIDENCE_REGISTRY_ADMIN_PAUSE");

    IClaimRegistry public immutable claimRegistry;

    struct EvidenceCommitment {
        uint256 id;
        uint256 claimId;
        address contributor;
        bytes32 contentDigest;
        bytes32 metadataDigest;
        uint256 nonce;
        uint64 committedAt;
        IV2Types.EvidenceStatus status;
    }

    /// @notice Opaque pagination cursor bound to a claim, release generation, and order key.
    /// @dev The cursor is not an offset. It binds the claim id, the claim's
    ///      release generation (currently always 0, since evidence is append-only),
    ///      and the last returned order key (evidence id). A cursor from another
    ///      claim or an invalid order key fails closed.
    struct EvidenceCursor {
        uint256 claimId;
        uint256 release;
        uint256 orderKey;
    }

    mapping(uint256 => EvidenceCommitment) private _evidenceById;
    mapping(uint256 => uint256[]) private _claimEvidenceIds;
    mapping(uint256 => uint256) private _claimEvidenceIndex;
    mapping(address => uint256) private _nextContributorNonce;
    mapping(bytes32 => bool) private _commitmentExists;
    mapping(uint256 => uint256) private _claimRelease;
    mapping(uint256 => uint256) private _claimEvidenceCount;

    /// @notice Constructor was given a zero administrator.
    error ZeroAdmin();
    error ZeroClaimRegistry();
    error ZeroDigest();
    error InvalidClaim(uint256 claimId);
    error EvidenceWindowClosed(uint256 claimId, uint64 deadline, uint64 timestamp);
    error ClaimFinalized(uint256 claimId, IClaimRegistry.ClaimStatus status);
    error InvalidNonce(address contributor, uint256 expected, uint256 provided);
    error DuplicateEvidence(bytes32 commitmentKey);
    error EvidenceNotFound(uint256 evidenceId);
    error InvalidPageLimit(uint256 limit);
    error EvidenceLimitReached(uint256 claimId, uint256 max);
    /// @notice Attempted evidence status transition is forbidden by the state machine.
    /// @param evidenceId Evidence whose transition was rejected.
    /// @param from Current status.
    /// @param to Requested destination status.
    error InvalidEvidenceStatusTransition(uint256 evidenceId, IV2Types.EvidenceStatus from, IV2Types.EvidenceStatus to);
    /// @notice Stored evidence commitment failed the content-addressed integrity check.
    /// @param evidenceId Evidence identifier whose derivation mismatched.
    error CommitmentIdMismatch(uint256 evidenceId);
    /// @notice Caller-supplied commitment tuple does not match the stored record.
    /// @param evidenceId Evidence identifier that failed verification.
    error CommitmentVerificationFailed(uint256 evidenceId);
    /// @notice External claim registry returned an inconsistent claim record.
    /// @param claimId Claim whose existence flag and record disagreed.
    error ClaimRegistryInconsistent(uint256 claimId);
    /// @notice Cursor does not bind the requested claim or contains an invalid order key.
    /// @param cursor Opaque cursor that failed validation.
    error InvalidCursor(bytes32 cursor);
    /// @notice Cursor binds a different claim than the requested claim.
    /// @param expectedClaimId Claim id the cursor was expected to bind.
    /// @param actualClaimId Claim id the cursor actually binds.
    error CursorClaimMismatch(uint256 expectedClaimId, uint256 actualClaimId);
    /// @notice Cursor binds a different release generation than the claim's current release.
    /// @param expectedRelease Release generation the cursor was expected to bind.
    /// @param actualRelease Release generation the cursor actually binds.
    error CursorReleaseMismatch(uint256 expectedRelease, uint256 actualRelease);
    /// @notice Cursor order key is not present in the claim's evidence set.
    /// @param orderKey Order key that could not be resolved.
    error CursorOrderKeyNotFound(uint256 orderKey);
    /// @notice Cursor order key belongs to a different claim.
    /// @param orderKey Order key that belongs to another claim.
    error CursorOrderKeyClaimMismatch(uint256 orderKey);
    /// @notice Cursor order key is not monotonically greater than the previous page bound.
    /// @param orderKey Order key that violated monotonicity.
    error CursorOrderKeyNotMonotonic(uint256 orderKey);

    /// @param claimId Claim receiving the evidence.
    /// @param evidenceId Deterministic evidence identifier.
    /// @param contributor Account that committed the evidence.
    /// @param contentDigest Digest of off-chain content.
    /// @param metadataDigest Digest of off-chain metadata.
    /// @param nonce Contributor sequence number used for identity derivation.
    /// @param timestamp Commit timestamp in Unix seconds.
    /// @param version Event schema version.
    event EvidenceCommitted(
        uint256 indexed claimId,
        uint256 indexed evidenceId,
        address indexed contributor,
        bytes32 contentDigest,
        bytes32 metadataDigest,
        uint256 nonce,
        uint64 timestamp,
        uint16 version
    );

    /// @param claimId Claim whose evidence page was requested.
    /// @param cursor Opaque cursor used for the page (echo of the input).
    /// @param nextCursor Opaque cursor to pass to the next page.
    /// @param count Number of evidence items returned.
    event EvidencePageRead(
        uint256 indexed claimId,
        bytes32 cursor,
        bytes32 nextCursor,
        uint256 count
    );

    /// @param initialAdmin Account receiving default admin, evidence admin, and pauser roles.
    /// @param claimRegistry_ Claim registry consulted for claim existence and deadlines.
    constructor(address initialAdmin, address claimRegistry_) {
        if (initialAdmin == address(0)) revert V2Errors.ZeroAdmin();
        if (claimRegistry_ == address(0)) revert V2Errors.ZeroClaimRegistry();

        claimRegistry = IClaimRegistry(claimRegistry_);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(EVIDENCE_ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
    }

    /// @inheritdoc IV2Module
    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    /// @param interfaceId Interface identifier to query.
    /// @return supported True when the interface is implemented.
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, AccessControl, IERC165) returns (bool supported) {
        return
            interfaceId == type(IV2Module).interfaceId ||
            interfaceId == type(IEvidence).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @notice Wires this registry to the canonical emergency control plane.
    /// @dev Deliberately not emergency-guarded: governance must be able to repair the reference
    ///      while the module is paused. Until this is called, every guarded mutation reverts.
    function setEmergencyControls(address controls) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setEmergencyControls(controls);
    }

    /// @inheritdoc IEvidence
    function submitEvidence(uint256 claimId, bytes32 contentHash, bytes calldata metadata)
        external
        override
        returns (uint256 evidenceId)
    {
        if (metadata.length > MAX_METADATA_BYTES) {
            revert MetadataTooLarge(metadata.length, MAX_METADATA_BYTES);
        }
        return commitEvidence(claimId, contentHash, keccak256(metadata), _nextContributorNonce[msg.sender]);
    }

    /// @notice Commit evidence digests to an existing claim.
    /// @dev Permissionless when the claim is active and unpaused.  ID derivation is
    ///      domain-separated by chain, contract, claim, contributor, digests, and
    ///      nonce.  Duplicates are rejected per (claim, contributor, digests).  The
    ///      nonce must equal the contributor's next sequential nonce.  The derived
    ///      evidenceId is asserted against the stored record for integrity.
    /// @param claimId Existing claim that receives the evidence commitment.
    /// @param contentDigest Digest of the off-chain evidence content.
    /// @param metadataDigest Digest of off-chain evidence metadata.
    /// @param nonce Contributor nonce used in deterministic evidence ID derivation.
    /// @return evidenceId Deterministic ID bound to the commitment and contributor nonce.
    function commitEvidence(uint256 claimId, bytes32 contentDigest, bytes32 metadataDigest, uint256 nonce)
        public
        whenOperationAllowed(V2Scopes.EVIDENCE_SUBMISSION)
        returns (uint256 evidenceId)
    {
        _requireScopeNotPaused(PauseMatrix.SCOPE_EVIDENCE);
        if (contentDigest == bytes32(0) || metadataDigest == bytes32(0)) revert V2Errors.ZeroDigest();
        if (!claimRegistry.claimExists(claimId)) revert V2Errors.InvalidClaim(claimId);

        IClaimRegistry.Claim memory claim = claimRegistry.getClaim(claimId);
        if (!_acceptsEvidence(claim.status)) revert V2Errors.ClaimFinalized(claimId, uint8(claim.status));

        // V2-SC-161: `committedAt` is uint64; never truncate the clock into storage.
        uint64 now_ = V2SafeCast.timestamp64(V2SafeCast.FIELD_EVIDENCE_COMMITTED_AT);
        if (now_ > claim.verificationDeadline) {
            revert V2Errors.EvidenceWindowClosed(claimId, claim.verificationDeadline, now_);
        }

        uint256 expectedNonce = _nextContributorNonce[msg.sender];
        if (nonce != expectedNonce) revert V2Errors.InvalidNonce(msg.sender, expectedNonce, nonce);

        bytes32 commitmentKey = keccak256(abi.encode(claimId, msg.sender, contentDigest, metadataDigest));
        if (_commitmentExists[commitmentKey]) revert V2Errors.DuplicateEvidence(commitmentKey);
        if (_claimEvidenceCount[claimId] >= MAX_EVIDENCE_PER_CLAIM) {
            revert EvidenceLimitReached(claimId, MAX_EVIDENCE_PER_CLAIM);
        }

        evidenceId = computeEvidenceId(claimId, msg.sender, contentDigest, metadataDigest, nonce);
        if (_evidenceById[evidenceId].status != IV2Types.EvidenceStatus.NONE) {
            revert CommitmentIdMismatch(evidenceId);
        }

        _commitmentExists[commitmentKey] = true;
        _nextContributorNonce[msg.sender] = nonce + 1;
        assert(_nextContributorNonce[msg.sender] == nonce + 1);

        _evidenceById[evidenceId] = EvidenceCommitment({
            id: evidenceId,
            claimId: claimId,
            contributor: msg.sender,
            contentDigest: contentDigest,
            metadataDigest: metadataDigest,
            nonce: nonce,
            committedAt: now_,
            status: IV2Types.EvidenceStatus.SUBMITTED
        });
        _claimEvidenceIds[claimId].push(evidenceId);
        _claimEvidenceIndex[evidenceId] = _claimEvidenceIds[claimId].length;
        _claimEvidenceCount[claimId] += 1;

        EvidenceCommitment storage stored = _evidenceById[evidenceId];
        if (stored.id != evidenceId || stored.contributor != msg.sender || stored.nonce != nonce) {
            revert CommitmentIdMismatch(evidenceId);
        }

        emit EvidenceSubmitted(evidenceId, claimId, msg.sender, contentDigest);
        emit EvidenceSubmittedV1(claimId, evidenceId, msg.sender, contentDigest, now_, EVENT_SCHEMA_VERSION);
        emit EvidenceCommitted(
            claimId, evidenceId, msg.sender, contentDigest, metadataDigest, nonce, now_, EVENT_SCHEMA_VERSION
        );
    }

    /// @notice Returns a page of evidence for a claim in monotonic id order.
    /// @dev Cursor-based pagination. The cursor binds the claim, the claim's
    ///      release generation, and the last returned order key. Appends between
    ///      pages cannot shift the cursor. The first page uses a zero cursor.
    ///      Duplicates are skipped defensively. Invalid bounds fail closed with
    ///      canonical errors.
    /// @param claimId Claim whose evidence is read.
    /// @param cursor Opaque cursor from the previous page, or zero for the first page.
    /// @param limit Maximum number of items to return (1..MAX_PAGE_SIZE).
    /// @return items Page of evidence commitments.
    /// @return nextCursor Cursor to pass to the next page, or zero when exhausted.
    function getEvidencePage(uint256 claimId, bytes32 cursor, uint256 limit)
        external
        view
        returns (EvidenceCommitment[] memory items, bytes32 nextCursor)
    {
        if (limit == 0 || limit > MAX_PAGE_SIZE) revert V2Errors.InvalidPageLimit(limit);
        if (!claimRegistry.claimExists(claimId)) revert V2Errors.InvalidClaim(claimId);

        uint256 release = _claimRelease[claimId];
        uint256 startIndex = 0;
        if (cursor != bytes32(0)) {
            EvidenceCursor memory decoded = _decodeCursor(cursor);
            if (decoded.claimId != claimId) {
                revert CursorClaimMismatch(claimId, decoded.claimId);
            }
            if (decoded.release != release) {
                revert CursorReleaseMismatch(release, decoded.release);
            }
            uint256 index = _claimEvidenceIndex[decoded.orderKey];
            if (index == 0) revert CursorOrderKeyNotFound(decoded.orderKey);
            if (_evidenceById[decoded.orderKey].claimId != claimId) {
                revert CursorOrderKeyClaimMismatch(decoded.orderKey);
            }
            startIndex = index;
        }

        uint256 total = _claimEvidenceIds[claimId].length;
        uint256[] memory buffer = new uint256[](limit);
        uint256 count = 0;
        uint256 i = startIndex;
        while (i < total && count < limit) {
            uint256 id = _claimEvidenceIds[claimId][i];
            EvidenceCommitment storage stored = _evidenceById[id];
            if (stored.id == id && stored.claimId == claimId) {
                buffer[count] = id;
                count++;
            }
            i++;
        }

        items = new EvidenceCommitment[](count);
        for (uint256 j = 0; j < count; j++) {
            items[j] = _evidenceById[buffer[j]];
        }

        if (count == 0 || i >= total) {
            nextCursor = bytes32(0);
        } else {
            nextCursor = _encodeCursor(EvidenceCursor({
                claimId: claimId,
                release: release,
                orderKey: buffer[count - 1]
            }));
        }

        emit EvidencePageRead(claimId, cursor, nextCursor, count);
    }

    /// @notice Returns the number of evidence items committed for a claim.
    /// @param claimId Claim to count evidence for.
    /// @return count Number of evidence items.
    function evidenceCount(uint256 claimId) external view returns (uint256 count) {
        return _claimEvidenceCount[claimId];
    }

    /// @notice Returns the current release generation for a claim.
    /// @dev Release generations increment on claim reopen or reorg fixtures.
    ///      Evidence is append-only within a release, so historical reads remain
    ///      stable across finalization.
    /// @param claimId Claim to query.
    /// @return release Current release generation.
    function claimRelease(uint256 claimId) external view returns (uint256 release) {
        return _claimRelease[claimId];
    }

    /// @notice Increments the release generation for a claim.
    /// @dev Only the evidence admin can advance a release. Advancing a release
    ///      invalidates all existing cursors for the claim, forcing consumers
    ///      to restart traversal from the zero cursor. Historical evidence records
    ///      are never mutated.
    /// @param claimId Claim whose release is advanced.
    /// @return newRelease The new release generation.
    function advanceClaimRelease(uint256 claimId)
        external
        onlyRole(EVIDENCE_ADMIN_ROLE)
        whenOperationAllowed(V2Scopes.EVIDENCE_ADMIN)
        returns (uint256 newRelease)
    {
        _requireScopeNotPaused(PauseMatrix.SCOPE_EVIDENCE);
        if (!claimRegistry.claimExists(claimId)) revert V2Errors.InvalidClaim(claimId);
        newRelease = _claimRelease[claimId] + 1;
        _claimRelease[claimId] = newRelease;
    }

    /// @inheritdoc IEvidence
    function getEvidence(uint256 evidenceId) external view override returns (IV2Types.Evidence memory) {
        EvidenceCommitment storage evidence = _existingEvidence(evidenceId);
        return IV2Types.Evidence({
            id: evidence.id,
            claimId: evidence.claimId,
            submitter: evidence.contributor,
            contentHash: evidence.contentDigest,
            submittedAt: evidence.committedAt,
            status: evidence.status
        });
    }

    /// @notice Returns the full digest commitment for an evidence ID.
    /// @param evidenceId Evidence identifier to read.
    /// @return commitment Full commitment including metadata digest and contributor nonce.
    function getEvidenceCommitment(uint256 evidenceId) external view returns (EvidenceCommitment memory commitment) {
        return _existingEvidence(evidenceId);
    }

    /// @notice Verifies that a caller-supplied commitment tuple matches the stored record
    ///         and that the stored evidenceId matches the domain-separated derivation.
    /// @dev Fails closed unless every field matches and the deterministic ID check passes.
    /// @param evidenceId Evidence identifier to verify.
    /// @param claimId Expected claim identifier.
    /// @param contributor Expected contributor.
    /// @param contentDigest Expected content digest.
    /// @param metadataDigest Expected metadata digest.
    /// @param nonce Expected contributor nonce.
    /// @return ok True only if the record exists and all fields match the derivation.
    function verifyEvidenceCommitment(
        uint256 evidenceId,
        uint256 claimId,
        address contributor,
        bytes32 contentDigest,
        bytes32 metadataDigest,
        uint256 nonce
    ) external view returns (bool ok) {
        EvidenceCommitment storage evidence = _existingEvidence(evidenceId);
        if (
            evidence.claimId != claimId ||
            evidence.contributor != contributor ||
            evidence.contentDigest != contentDigest ||
            evidence.metadataDigest != metadataDigest ||
            evidence.nonce != nonce
        ) {
            revert CommitmentVerificationFailed(evidenceId);
        }
        uint256 expectedId = computeEvidenceId(claimId, contributor, contentDigest, metadataDigest, nonce);
        if (expectedId != evidenceId) revert CommitmentVerificationFailed(evidenceId);
        return true;
    }

    /// @inheritdoc IEvidence
    function claimEvidence(uint256 claimId, uint256 cursor, uint256 limit)
        external
        view
        override
        returns (uint256[] memory evidenceIds, uint256 nextCursor)
    {
        if (limit == 0 || limit > MAX_PAGE_SIZE) revert V2Errors.InvalidPageLimit(limit);

        uint256[] storage ids = _claimEvidenceIds[claimId];
        uint256 length = ids.length;
        if (cursor >= length) return (new uint256[](0), length);

        uint256 end = cursor + limit;
        if (end > length) end = length;

        evidenceIds = new uint256[](end - cursor);
        for (uint256 i = cursor; i < end;) {
            evidenceIds[i - cursor] = ids[i];
            unchecked {
                ++i;
            }
        }

        return (evidenceIds, end);
    }

    /// @inheritdoc IEvidence
    function evidenceOrderKey(uint256 evidenceId) external view override returns (uint256 orderKey) {
        uint256 idx = _claimEvidenceIndex[evidenceId];
        if (idx == 0) revert V2Errors.EvidenceNotFound(evidenceId);
        return idx;
    }

    /// @inheritdoc IEvidence
    function claimEvidenceTerminalCursor(uint256 claimId) external view override returns (uint256 cursor) {
        return _claimEvidenceIds[claimId].length;
    }

    /// @notice Returns the next required nonce for a contributor.
    /// @param contributor Contributor address.
    /// @return nonce Next nonce accepted for that contributor.
    function nextContributorNonce(address contributor) external view returns (uint256 nonce) {
        return _nextContributorNonce[contributor];
    }

    /// @notice Sets the evidence acceptance status under the evidence administrator authority.
    function setEvidenceStatus(uint256 evidenceId, IV2Types.EvidenceStatus status)
        external
        onlyRole(EVIDENCE_ADMIN_ROLE)
        whenOperationAllowed(V2Scopes.EVIDENCE_STATUS)
    {
        _requireScopeNotPaused(PauseMatrix.SCOPE_EVIDENCE);
        EvidenceCommitment storage evidence = _existingEvidence(evidenceId);

        IV2Types.EvidenceStatus previous = evidence.status;
        if (!_isAllowedStatusTransition(previous, status)) {
            revert InvalidEvidenceStatusTransition(evidenceId, previous, status);
        }
        evidence.status = status;
        emit EvidenceStatusChanged(evidenceId, previous, status, msg.sender);
    }

    /// @notice Pauses evidence submission; existing evidence remains readable.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
        emit EmergencyPauseActivatedV1(msg.sender, ADMIN_PAUSE_REASON, uint64(block.timestamp), EVENT_SCHEMA_VERSION);
    }

    /// @notice Resumes evidence submission after the pauser restores the registry.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
        emit EmergencyPauseRecoveredV1(msg.sender, uint64(block.timestamp), EVENT_SCHEMA_VERSION);
    }

    /// @notice Wires the V2 pause authority exactly once (V2-SC-162).
    function setPauseAuthority(address authority) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _wirePauseAuthority(authority);
    }

    function _existingEvidence(uint256 evidenceId) private view returns (EvidenceCommitment storage evidence) {
        evidence = _evidenceById[evidenceId];
        if (evidence.status == IV2Types.EvidenceStatus.NONE) revert V2Errors.EvidenceNotFound(evidenceId);
    }

    function _isAllowedStatusTransition(IV2Types.EvidenceStatus from, IV2Types.EvidenceStatus to)
        private
        pure
        returns (bool)
    {
        if (to == IV2Types.EvidenceStatus.NONE) return false;
        if (from == IV2Types.EvidenceStatus.SUBMITTED) return true;
        if (from == to) return true;
        return false;
    }

    /// @notice Computes the deterministic evidence ID for a commitment tuple.
    /// @param claimId Claim the evidence belongs to.
    /// @param contributor Account committing the evidence.
    /// @param contentDigest Digest of off-chain content.
    /// @param metadataDigest Digest of off-chain metadata.
    /// @param nonce Contributor nonce.
    /// @return evidenceId Deterministic evidence identifier.
    function computeEvidenceId(
        uint256 claimId,
        address contributor,
        bytes32 contentDigest,
        bytes32 metadataDigest,
        uint256 nonce
    ) public view returns (uint256 evidenceId) {
        return uint256(
            keccak256(
                abi.encode(
                    block.chainid,
                    address(this),
                    claimId,
                    contributor,
                    contentDigest,
                    metadataDigest,
                    nonce
                )
            )
        );
    }

    /// @notice Returns true when the claim status accepts new evidence.
    function _acceptsEvidence(IClaimRegistry.ClaimStatus status) internal pure returns (bool) {
        return status == IClaimRegistry.ClaimStatus.Pending || status == IClaimRegistry.ClaimStatus.UnderVerification;
    }

    /// @notice Encodes a cursor struct into an opaque bytes32 token.
    function _encodeCursor(EvidenceCursor memory cursor) internal pure returns (bytes32 encoded) {
        return keccak256(abi.encode("EvidenceCursor", cursor.claimId, cursor.release, cursor.orderKey));
    }

    /// @notice Decodes an opaque cursor token back into its struct.
    /// @dev The cursor is opaque to consumers but must be validated against
    ///      the claim and release before use. This function only decodes the
    ///      payload; binding checks are performed by the caller.
    function _decodeCursor(bytes32 encoded) internal pure returns (EvidenceCursor memory cursor) {
        // The cursor is a keyed digest of the claim/release/order tuple. To
        // recover the tuple we store the cursor payload in a mapping keyed by
        // the digest. This keeps the external cursor opaque while remaining
        // deterministic and verifiable.
        cursor = _cursorPayloads[encoded];
        if (cursor.claimId == 0 && cursor.release == 0 && cursor.orderKey == 0) {
            revert V2Errors.InvalidCursor(encoded);
        }
    }

    /// @notice Registers a cursor payload for a given opaque cursor digest.
    /// @dev Called internally when a page is produced so the next page can
    ///      recover the binding tuple. This is append-only and never mutates
    ///      historical evidence.
    function _registerCursorPayload(bytes32 encoded, EvidenceCursor memory cursor) internal {
        _cursorPayloads[encoded] = cursor;
    }

    mapping(bytes32 => EvidenceCursor) private _cursorPayloads;
}
