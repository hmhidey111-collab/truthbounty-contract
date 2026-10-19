// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IClaimRegistry
 * @notice Interface for the TruthBounty V2 On-Chain Claim Registry.
 * @dev The registry supports both the legacy sequential claim flow and the
 *      deterministic V2 creation flow. All downstream modules should treat
 *      the canonical deterministic path as the source of truth whenever a
 *      claim is created by a user-signed transaction.
 */
interface IClaimRegistry {
    // =========================================================================
    // Enums
    // =========================================================================

    enum ClaimStatus {
        Pending,
        UnderVerification,
        VerifiedTrue,
        VerifiedFalse,
        Disputed,
        Cancelled
    }

    // =========================================================================
    // Structs
    // =========================================================================

    struct Claim {
        uint256 id;
        address creator;
        string statement;
        string evidenceCID;
        ClaimStatus status;
        uint64 createdAt;
        uint64 verificationDeadline;
    }

    struct CanonicalClaim {
        bytes32 id;
        address submitter;
        address recipient;
        address asset;
        uint256 bounty;
        bytes32 metadataDigest;
        bytes32 evidenceDigest;
        uint256 nonce;
        uint256 parameterVersion;
        uint64 createdAt;
        bytes32 custodyRef;
        bool exists;
    }

    // =========================================================================
    // Events
    // =========================================================================

    event ClaimCreated(
        uint256 indexed claimId,
        address indexed creator,
        string evidenceCID
    );

    event ClaimCreated(
        bytes32 indexed claimId,
        address indexed submitter,
        address indexed recipient,
        address asset,
        uint256 bounty,
        bytes32 metadataDigest,
        bytes32 evidenceDigest,
        uint256 nonce,
        uint256 parameterVersion,
        bytes32 custodyRef
    );

    event ClaimStatusUpdated(
        uint256 indexed claimId,
        ClaimStatus indexed oldStatus,
        ClaimStatus indexed newStatus
    );

    // =========================================================================
    // Custom Errors
    // =========================================================================

    error InvalidStatement();
    error InvalidCID();
    error InvalidDeadline();
    error ClaimNotFound(uint256 claimId);
    error CanonicalClaimNotFound(bytes32 claimId);
    error UnauthorisedStatusTransition();
    error InvalidStatusTransition(ClaimStatus current, ClaimStatus requested);
    error ZeroAddress();
    error ZeroDigest();
    error ZeroRecipient();
    error DuplicateClaimId(bytes32 claimId);
    error UnsupportedAsset(address asset);
    error InvalidBounty(uint256 bounty);
    error InvalidNonce(uint256 expectedNonce, uint256 providedNonce);
    error InvalidParameterVersion(uint256 expectedVersion, uint256 providedVersion);
    error TransferFailed();
    error ClaimSpamRateExceeded(address account, uint256 count, uint256 limit);
    error TooManyOpenClaims(address account, uint256 count, uint256 limit);

    // =========================================================================
    // Legacy write functions
    // =========================================================================

    function createClaim(
        string calldata statement,
        string calldata evidenceCID,
        uint64 verificationDeadline
    ) external returns (uint256 claimId);

    function updateClaimStatus(uint256 claimId, ClaimStatus newStatus) external;

    // =========================================================================
    // Canonical deterministic flow
    // =========================================================================

    function createCanonicalClaim(
        address recipient,
        address asset,
        uint256 bounty,
        bytes32 metadataDigest,
        bytes32 evidenceDigest,
        uint256 nonce
    ) external returns (bytes32 claimId);

    function createCanonicalClaim(
        address recipient,
        address asset,
        uint256 bounty,
        bytes32 metadataDigest,
        bytes32 evidenceDigest,
        uint256 nonce,
        uint256 parameterVersion
    ) external returns (bytes32 claimId);

    function currentConfigVersion() external view returns (uint256 version);

    function setSupportedAsset(
        address asset,
        bool supported,
        uint256 minBounty,
        uint256 maxBounty
    ) external;

    function isSupportedAsset(address asset) external view returns (bool supported);

    function getAssetBounds(address asset) external view returns (uint256 minBounty, uint256 maxBounty);

    function computeClaimId(address submitter, uint256 submitterNonce, bytes32 metadataDigest)
        external
        view
        returns (bytes32 claimId);

    function claimIdFor(address submitter, uint256 submitterNonce, bytes32 metadataDigest)
        external
        view
        returns (bytes32 claimId);

    function getCanonicalClaim(bytes32 claimId) external view returns (CanonicalClaim memory claim);

    function claimExists(bytes32 claimId) external view returns (bool exists);

    // =========================================================================
    // Legacy view functions
    // =========================================================================

    function getClaim(uint256 claimId) external view returns (Claim memory claim);
    function claimExists(uint256 claimId) external view returns (bool exists);
    function totalClaims() external view returns (uint256 total);
    function getClaimCreator(uint256 claimId) external view returns (address creator);
    function getClaimStatus(uint256 claimId) external view returns (ClaimStatus status);
}
