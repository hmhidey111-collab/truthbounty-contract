// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title EvidenceManager
 * @notice Manages immutable, content-addressed evidence references for TruthBounty claims.
 *
 * @dev Evidence files are stored off-chain using IPFS (or compatible decentralized storage).
 *      This contract stores only the cryptographic Content Identifier (CID) — a hash-derived
 *      reference that binds the on-chain record to the exact off-chain content — together with
 *      a content digest that the CID is bound to.
 *
 *      CID readiness boundary (POST-WAVE-9 audit):
 *      - Accepted CID versions: CIDv0 ("Qm" prefix, base58btc SHA2-256) and CIDv1
 *        multibase prefixes (case-insensitive): base32 (b/B), base58btc (z/Z), base16 (f/F),
 *        base36 (k/K), base64url (u/U), base64 (m/M), base32hexpad (t/T).
 *      - Byte/string normalization: CIDv1 multibase prefix characters are normalized to
 *        lowercase canonical form before hashing or storage, so equivalent CIDs (e.g. "Z…"
 *        vs "z…") resolve to the same canonical identifier.
 *      - Digest binding: each CID is bound to a caller-supplied content digest. A CID may
 *        only be registered with one content digest per claim, and a content digest may only
 *        be bound to one CID per claim. Digest/CID mismatches revert.
 *      - Size policy: CID strings must be between MIN_CID_LENGTH (2) and MAX_CID_LENGTH (512)
 *        bytes inclusive. Empty or zero digests are rejected.
 *      - Duplicate behavior: duplicates are detected on the canonical (normalized) CID string
 *        per claim. The same CID on a different claim is permitted.
 *
 *      Design principles:
 *      - Immutability: once submitted, a CID and its bound digest can never be changed or removed.
 *      - Integrity:    the keccak256 hash of the canonical CID is stored for efficient duplicate
 *                      detection; the bound content digest is stored alongside for integrity.
 *      - Extensibility: the storage layout supports future providers (Arweave, Filecoin, Ceramic).
 *      - No external calls: this contract holds no token balances and makes no outbound calls.
 *
 *      Downstream consumers (Verification Engine, Dispute Resolution, Settlement Engine,
 *      Reputation System, Indexer, Frontend) rely on the events and view functions exposed here.
 *
 * @custom:security-contact security@truthbounty.io
 */
contract EvidenceManager is AccessControl, Pausable {
    // =========================================================================
    // Roles
    // =========================================================================

    /// @notice Role that may pause / unpause the contract.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role held by the protocol's claim registry.
    ///         The registry can signal that a claim is closed and no longer
    ///         accepts new evidence (e.g. after settlement).
    bytes32 public constant CLAIM_REGISTRY_ROLE = keccak256("CLAIM_REGISTRY_ROLE");

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum byte-length of an accepted CID string.
    ///         CIDv1 base58btc encoded SHA2-256 is 46 chars; base32 is 59 chars.
    ///         We allow up to 512 bytes to accommodate future multihash formats.
    uint256 public constant MAX_CID_LENGTH = 512;

    /// @notice Maximum evidence records attachable to a single claim (V2-SC-038 DoS bound).
    uint256 public constant MAX_EVIDENCE_PER_CLAIM = 100;

    /// @notice Minimum byte-length: a real CID is at least 2 chars (e.g. "Qm…").
    uint256 public constant MIN_CID_LENGTH = 2;

    /// @notice Accepted CIDv0 prefix: base58btc-encoded SHA2-256 multihash ("Qm").
    string public constant CID_PREFIX_V0 = "Qm";

    /// @notice Accepted CIDv1 multibase prefix characters (lowercase canonical form).
    ///         Uppercase variants (B, Z, F, K, U, M, T) are accepted on input and
    ///         normalized to their lowercase canonical form before hashing or storage.
    ///         The full set: b (base32), z (base58btc), f (base16), k (base36),
    ///         u (base64url), m (base64), t (base32hexpad).
    string public constant CID_PREFIX_V1_LOWERCASE = "bzfkumt";

    // =========================================================================
    // Data model
    // =========================================================================

    /**
     * @notice Canonical evidence record stored per claim.
     *
     * Field packing:
     *   - id            : uint256 (slot 0)
     *   - claimId       : uint256 (slot 1)
     *   - uploader      : address (slot 2, 20 bytes)
     *   - uploadedAt    : uint64  (slot 2, 8 bytes — shares with uploader via packing)
     *   - cidHash       : bytes32 (slot 3) — keccak256 of the canonical (normalized) CID string
     *   - contentDigest : bytes32 (slot 4) — content digest bound to the CID
     *   - cid           : string  (slot 5+, dynamic) — canonical (normalized) CID string
     *
     * The struct is ordered to minimise storage slots.
     */
    struct Evidence {
        uint256 id;
        uint256 claimId;
        address uploader;
        uint64 uploadedAt;
        bytes32 cidHash;
        bytes32 contentDigest;
        string cid;
    }

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev Next global evidence ID (monotonically incrementing).
    uint256 private _evidenceCounter;

    /// @dev claimId => ordered list of Evidence records attached to the claim.
    mapping(uint256 => Evidence[]) private _claimEvidence;

    /// @dev evidenceId => Evidence record for O(1) retrieval by global ID.
    mapping(uint256 => Evidence) private _evidenceById;

    /// @dev claimId => cidHash => true when a CID has already been attached.
    ///      Used for O(1) duplicate detection without iterating the array.
    mapping(uint256 => mapping(bytes32 => bool)) private _cidRegistered;

    /// @dev claimId => cidHash => contentDigest bound to that CID.
    ///      Enforces one digest per CID per claim (digest/CID consistency).
    mapping(uint256 => mapping(bytes32 => bytes32)) private _cidToDigest;

    /// @dev claimId => contentDigest => cidHash bound to that digest.
    ///      Enforces one CID per digest per claim (digest/CID consistency).
    mapping(uint256 => mapping(bytes32 => bytes32)) private _digestToCid;

    /// @dev claimId => true when the claim has been closed and no longer accepts evidence.
    mapping(uint256 => bool) private _claimClosed;

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Submitted CID is empty or otherwise invalid.
    error InvalidCID();

    /// @notice Submitted CID exceeds MAX_CID_LENGTH.
    error CIDTooLarge();

    /// @notice Submitted CID begins with an unrecognised version prefix.
    error UnsupportedCIDVersion();

    /// @notice Content digest is zero (not permitted).
    error ZeroDigest();

    /// @notice A CID is already bound to a different content digest (or vice versa)
    ///         within the same claim — digest/CID mismatch.
    error ContentDigestMismatch();

    /// @notice Identical CID already attached to this claim.
    error DuplicateEvidence();

    /// @notice The referenced claim does not exist in the registry.
    error ClaimNotFound();

    /// @notice The referenced claim is closed and no longer accepts evidence.
    error ClaimClosed();

    /// @notice Caller supplied an out-of-range index.
    error IndexOutOfBounds();

    /// @notice Evidence with the given global ID does not exist.
    error EvidenceNotFound();

    /// @notice Claim already has the maximum allowed evidence attachments.
    error EvidenceCapacityExceeded(uint256 claimId, uint256 max);

    // =========================================================================
    // Events
    // =========================================================================

    /**
     * @notice Emitted when evidence is successfully attached to a claim.
     *
     * @param claimId     The claim this evidence belongs to.
     * @param evidenceId  The global evidence ID assigned to this record.
     * @param uploader    The address that submitted the evidence.
     * @param cid         The canonical (normalized) content identifier (CID) of the off-chain file.
     * @param cidHash     keccak256 of the canonical CID — the canonical on-chain identifier.
     * @param contentDigest The content digest bound to the CID.
     */
    event EvidenceAdded(
        uint256 indexed claimId,
        uint256 indexed evidenceId,
        address indexed uploader,
        string cid,
        bytes32 indexed cidHash,
        bytes32 contentDigest
    );

    /**
     * @notice Emitted when the CLAIM_REGISTRY_ROLE closes a claim for new evidence.
     *
     * @param claimId The claim that was closed.
     */
    event ClaimClosedForEvidence(uint256 indexed claimId);

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @param initialAdmin Address granted DEFAULT_ADMIN_ROLE, PAUSER_ROLE, and
     *                     CLAIM_REGISTRY_ROLE on deployment.
     */
    constructor(address initialAdmin) {
        require(initialAdmin != address(0), "EvidenceManager: zero admin address");

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
        _grantRole(CLAIM_REGISTRY_ROLE, initialAdmin);
    }

    // =========================================================================
    // Claim lifecycle integration
    // =========================================================================

    /**
     * @notice Mark a claim as closed for new evidence.
     * @dev    Called by the Claim Registry (or an authorised admin) after a claim
     *         transitions to a state that no longer accepts evidence (e.g. settled,
     *         expired, or disputed). Idempotent — closing an already-closed claim
     *         emits no event and does not revert.
     *
     * @param claimId The claim to close.
     */
    function closeClaimForEvidence(uint256 claimId) external onlyRole(CLAIM_REGISTRY_ROLE) {
        if (!_claimClosed[claimId]) {
            _claimClosed[claimId] = true;
            emit ClaimClosedForEvidence(claimId);
        }
    }

    // =========================================================================
    // Core write function
    // =========================================================================

    /**
     * @notice Attach evidence to a claim by submitting an IPFS CID bound to a content digest.
     *
     * @dev Validation sequence (fail-fast order):
     *   1. Contract not paused.
     *   2. CID is non-empty and within length bounds.
     *   3. CID begins with a supported version prefix ("Qm" for CIDv0,
     *      "b", "B", "z", "Z", "F", "f", "k", "K", "u", "U", "m", "M", "t", "T" for CIDv1).
     *   4. CID characters are printable ASCII (0x21–0x7E).
     *   5. CIDv1 multibase prefix is normalized to lowercase canonical form.
     *   6. Content digest is non-zero.
     *   7. The claim is not closed.
     *   8. The claim has not reached MAX_EVIDENCE_PER_CLAIM.
     *   9. Digest/CID consistency: the CID is not already bound to a different digest,
     *      and the digest is not already bound to a different CID (same claim).
     *   10. Duplicate detection: the canonical (normalized) CID has not already been
     *       attached to this claim.
     *
     * @param claimId      The claim to attach evidence to.
     * @param cid          An IPFS (or compatible) Content Identifier string.
     * @param contentDigest Content digest (e.g. multihash digest) bound to the CID.
     */
    function addEvidence(
        uint256 claimId,
        string calldata cid,
        bytes32 contentDigest
    ) external whenNotPaused {
        // ── 1. CID length validation ────────────────────────────────────────
        uint256 cidLen = bytes(cid).length;

        if (cidLen < MIN_CID_LENGTH) revert InvalidCID();
        if (cidLen > MAX_CID_LENGTH) revert CIDTooLarge();

        // ── 2. CID version / multibase prefix validation ─────────────────────
        _validateCIDPrefix(cid);

        // ── 3. Printable ASCII check ─────────────────────────────────────────
        _validateCIDChars(cid);

        // ── 4. Normalize CID to canonical form (lowercase CIDv1 multibase prefix) ─
        string memory canonicalCid = _normalizeCID(cid);

        // ── 5. Content digest must be non-zero ───────────────────────────────
        if (contentDigest == bytes32(0)) revert ZeroDigest();

        // ── 6. Claim state checks ────────────────────────────────────────────
        if (_claimClosed[claimId]) revert ClaimClosed();
        if (_claimEvidence[claimId].length >= MAX_EVIDENCE_PER_CLAIM) {
            revert EvidenceCapacityExceeded(claimId, MAX_EVIDENCE_PER_CLAIM);
        }

        // ── 7. Canonical CID hash ────────────────────────────────────────────
        bytes32 cidHash = keccak256(bytes(canonicalCid));

        // ── 8. Digest/CID consistency (one digest per CID, one CID per digest) ─
        bytes32 existingDigest = _cidToDigest[claimId][cidHash];
        if (existingDigest != bytes32(0) && existingDigest != contentDigest) {
            revert ContentDigestMismatch();
        }

        bytes32 existingCidHash = _digestToCid[claimId][contentDigest];
        if (existingCidHash != bytes32(0) && existingCidHash != cidHash) {
            revert ContentDigestMismatch();
        }

        // ── 9. Duplicate detection ───────────────────────────────────────────
        if (_cidRegistered[claimId][cidHash]) revert DuplicateEvidence();

        // ── 10. Store ────────────────────────────────────────────────────────
        uint256 evidenceId = _evidenceCounter;
        unchecked { _evidenceCounter++; }

        Evidence memory ev = Evidence({
            id: evidenceId,
            claimId: claimId,
            uploader: msg.sender,
            uploadedAt: uint64(block.timestamp),
            cidHash: cidHash,
            contentDigest: contentDigest,
            cid: canonicalCid
        });

        _claimEvidence[claimId].push(ev);
        _evidenceById[evidenceId] = ev;
        _cidRegistered[claimId][cidHash] = true;
        _cidToDigest[claimId][cidHash] = contentDigest;
        _digestToCid[claimId][contentDigest] = cidHash;

        emit EvidenceAdded(claimId, evidenceId, msg.sender, canonicalCid, cidHash, contentDigest);
    }

    // =========================================================================
    // View / retrieval functions
    // =========================================================================

    /**
     * @notice Retrieve a single evidence record by its global ID.
     *
     * @param evidenceId Global evidence ID.
     * @return ev        The Evidence struct.
     */
    function getEvidence(uint256 evidenceId) external view returns (Evidence memory ev) {
        ev = _evidenceById[evidenceId];
        if (ev.uploadedAt == 0) revert EvidenceNotFound();
    }

    /**
     * @notice Retrieve all evidence attached to a specific claim.
     *
     * @param claimId The claim ID.
     * @return        Array of Evidence structs (may be empty).
     */
    function getEvidenceByClaim(uint256 claimId) external view returns (Evidence[] memory) {
        return _claimEvidence[claimId];
    }

    /**
     * @notice Retrieve a single evidence item by its position within a claim's list.
     *
     * @param claimId The claim ID.
     * @param index   Zero-based index into the claim's evidence array.
     * @return        The Evidence struct at that position.
     */
    function getEvidenceAtIndex(
        uint256 claimId,
        uint256 index
    ) external view returns (Evidence memory) {
        Evidence[] storage list = _claimEvidence[claimId];
        if (index >= list.length) revert IndexOutOfBounds();
        return list[index];
    }

    /**
     * @notice Return the number of evidence items attached to a claim.
     *
     * @param claimId The claim ID.
     * @return        Count of attached evidence records.
     */
    function getEvidenceCount(uint256 claimId) external view returns (uint256) {
        return _claimEvidence[claimId].length;
    }

    /**
     * @notice Check whether a claim has at least one evidence item.
     *
     * @param claimId The claim ID.
     * @return        True if the claim has ≥ 1 evidence record.
     */
    function hasEvidence(uint256 claimId) external view returns (bool) {
        return _claimEvidence[claimId].length > 0;
    }

    /**
     * @notice Return the address that uploaded a specific evidence item.
     *
     * @param evidenceId Global evidence ID.
     * @return           Uploader address.
     */
    function getEvidenceUploader(uint256 evidenceId) external view returns (address) {
        Evidence storage ev = _evidenceById[evidenceId];
        if (ev.uploadedAt == 0) revert EvidenceNotFound();
        return ev.uploader;
    }

    /**
     * @notice Return the keccak256 hash of a CID stored for a given evidence record.
     *
     * @param evidenceId Global evidence ID.
     * @return           bytes32 CID hash.
     */
    function getEvidenceCIDHash(uint256 evidenceId) external view returns (bytes32) {
        Evidence storage ev = _evidenceById[evidenceId];
        if (ev.uploadedAt == 0) revert EvidenceNotFound();
        return ev.cidHash;
    }

    /**
     * @notice Check whether a specific CID has already been attached to a claim.
     *
     * @dev The supplied CID is normalized (CIDv1 multibase prefix lowercased)
     *      before lookup so that equivalent CIDs (e.g. "Z…" vs "z…") match.
     *
     * @param claimId The claim ID.
     * @param cid     The CID string to check.
     * @return        True if the CID is already registered for the claim.
     */
    function isCIDRegistered(uint256 claimId, string calldata cid) external view returns (bool) {
        string memory canonicalCid = _normalizeCID(cid);
        bytes32 cidHash = keccak256(bytes(canonicalCid));
        return _cidRegistered[claimId][cidHash];
    }

    /**
     * @notice Return the content digest bound to a CID for a given claim.
     *
     * @param claimId The claim ID.
     * @param cid     The CID string (normalized before lookup).
     * @return        The content digest bound to the CID, or bytes32(0) if unset.
     */
    function getContentDigest(
        uint256 claimId,
        string calldata cid
    ) external view returns (bytes32) {
        string memory canonicalCid = _normalizeCID(cid);
        bytes32 cidHash = keccak256(bytes(canonicalCid));
        return _cidToDigest[claimId][cidHash];
    }

    /**
     * @notice Return whether a claim is currently closed for new evidence submissions.
     *
     * @param claimId The claim ID.
     * @return        True if the claim is closed.
     */
    function isClaimClosed(uint256 claimId) external view returns (bool) {
        return _claimClosed[claimId];
    }

    /**
     * @notice Return the next evidence ID that will be assigned.
     * @return Current evidence counter value.
     */
    function evidenceCounter() external view returns (uint256) {
        return _evidenceCounter;
    }

    // =========================================================================
    // Pausable admin
    // =========================================================================

    /// @notice Pause new evidence submissions.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume evidence submissions.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /**
     * @dev Validate the CID multibase/version prefix.
     *      Reverts with UnsupportedCIDVersion on an unrecognised first character.
     *
     *      Supported prefixes:
     *        "Q"  → CIDv0 (starts "Qm", base58btc SHA2-256)
     *        "b","B" → CIDv1 base32
     *        "z","Z" → CIDv1 base58btc
     *        "f","F" → CIDv1 base16
     *        "k","K" → CIDv1 base36
     *        "u","U" → CIDv1 base64url
     *        "m","M" → CIDv1 base64
     *        "t","T" → CIDv1 base32hexpad
     */
    function _validateCIDPrefix(string calldata cid) internal pure {
        bytes1 prefix = bytes(cid)[0];

        // CIDv0: starts with 'Q' (full "Qm" checked via second byte)
        if (prefix == "Q") {
            if (bytes(cid).length < 2 || bytes(cid)[1] != "m") revert UnsupportedCIDVersion();
            return;
        }

        // CIDv1 multibase prefixes (case-insensitive pairs)
        if (
            prefix == "b" || prefix == "B" || // base32
            prefix == "z" || prefix == "Z" || // base58btc
            prefix == "f" || prefix == "F" || // base16
            prefix == "k" || prefix == "K" || // base36
            prefix == "u" || prefix == "U" || // base64url
            prefix == "m" || prefix == "M" || // base64
            prefix == "t" || prefix == "T"    // base32hexpad
        ) {
            return;
        }

        revert UnsupportedCIDVersion();
    }

    /**
     * @dev Ensure all bytes in the CID string are printable ASCII (0x20–0x7E).
     *      This guards against malformed Unicode or control-character payloads
     *      that could corrupt storage or mislead off-chain consumers.
     *
     *      Note: IPFS CIDs use a strict subset of printable ASCII (alphanumeric
     *      plus a handful of symbols), so this check is safely conservative.
     */
    function _validateCIDChars(string calldata cid) internal pure {
        bytes memory b = bytes(cid);
        uint256 len = b.length;
        for (uint256 i = 0; i < len; ) {
            uint8 c = uint8(b[i]);
            if (c < 0x21 || c > 0x7E) revert InvalidCID();
            unchecked { i++; }
        }
    }

    /**
     * @dev Normalize a CID string to its canonical form.
     *
     * - CIDv0 ("Qm…") is returned unchanged.
     * - CIDv1 multibase prefix characters are lowercased to their canonical form
     *   (e.g. "Z…" → "z…", "B…" → "b…") so that equivalent CIDs produced by
     *   different multibase encodings of the same content resolve to one string.
     *
     *   Accepted uppercase prefix pairs: B/b, Z/z, F/f, K/k, U/u, M/m, T/t.
     *
     * @param cid CID string to normalize (must already pass prefix validation).
     * @return    Canonical (lowercase-prefix) CID string.
     */
    function _normalizeCID(string calldata cid) internal pure returns (string memory) {
        bytes memory b = bytes(cid);
        bytes1 prefix = b[0];

        // CIDv0 ("Qm") is already canonical — no normalization needed.
        if (prefix == "Q") {
            return string(cid);
        }

        // CIDv1: lowercase the first byte if it is an accepted uppercase prefix.
        bytes1 lower;
        if (prefix == "B") lower = "b";
        else if (prefix == "Z") lower = "z";
        else if (prefix == "F") lower = "f";
        else if (prefix == "K") lower = "k";
        else if (prefix == "U") lower = "u";
        else if (prefix == "M") lower = "m";
        else if (prefix == "T") lower = "t";
        else lower = prefix; // already lowercase or non-CIDv1 (rejected by _validateCIDPrefix)

        // Reconstruct: lowercased first byte + the rest of the string unchanged.
        bytes memory normalized = new bytes(b.length);
        normalized[0] = lower;
        for (uint256 i = 1; i < b.length; ) {
            normalized[i] = b[i];
            unchecked { i++; }
        }
        return string(normalized);
    }
}
