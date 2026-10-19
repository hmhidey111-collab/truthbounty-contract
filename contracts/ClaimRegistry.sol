// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "./libraries/BoundedSafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IClaimRegistry.sol";
import "./interfaces/IParameterVersionRegistry.sol";
import "./performance/ProtocolExecutionBounds.sol";
import "./v2/libraries/AntiGriefing.sol";
import {V2SafeCast} from "./v2/libraries/V2SafeCast.sol";

/**
 * @title ClaimRegistry
 * @notice Legacy sequential registry plus the V2 deterministic claim creation flow.
 * @dev This contract preserves the existing API used by the repo while also
 *      supporting the canonical user-owned creation flow required by V2.
 */
contract ClaimRegistry is AccessControl, IClaimRegistry, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REGISTRY_UPDATER_ROLE =
        keccak256("REGISTRY_UPDATER_ROLE");

    /// @notice ParameterVersionRegistry instance that tracks versioned economic parameters
    IParameterVersionRegistry public parameterVersionRegistry;

    // =========================================================================
    // Constants — Input Validation
    // =========================================================================

    /// @notice Minimum byte length for a valid claim statement.
    uint256 public constant STATEMENT_MIN_LENGTH = 10;
    uint256 public constant STATEMENT_MAX_LENGTH = 2000;
    uint256 public constant CID_MIN_LENGTH = 46;
    uint256 public constant CID_MAX_LENGTH = 128;
    uint64 public constant MAX_DEADLINE_HORIZON = 365 days;

    uint256 private _nextClaimId;
    mapping(uint256 => Claim) private _claims;

    uint256 private _configVersion;
    mapping(address => bool) private _supportedAssets;
    mapping(address => uint256) private _assetMinBounty;
    mapping(address => uint256) private _assetMaxBounty;
    mapping(address => uint256) private _submitterNonce;
    mapping(bytes32 => CanonicalClaim) private _canonicalClaims;
    mapping(bytes32 => bool) private _canonicalClaimExists;

    /// @dev V2-SC-105 claim spam controls (legacy sequential createClaim path).
    mapping(address => uint64) private _claimWindowStart;
    mapping(address => uint256) private _claimsInWindow;
    mapping(address => uint256) private _openClaimCount;

    /**
     * @param initialAdmin Address that receives DEFAULT_ADMIN_ROLE and ADMIN_ROLE.
     *                     Must be non-zero.
     * @param parameterVersionRegistry_ Address of the deployed ParameterVersionRegistry
     * @dev Sets _nextClaimId = 1 so the first created claim has ID = 1.
     */
    constructor(
        address initialAdmin,
        address parameterVersionRegistry_
    ) {
        require(
            initialAdmin != address(0),
            "ClaimRegistry: zero admin address"
        );
        require(
            parameterVersionRegistry_ != address(0),
            "ClaimRegistry: zero registry address"
        );

        _nextClaimId = 1;
        _configVersion = 1;

        parameterVersionRegistry =
            IParameterVersionRegistry(parameterVersionRegistry_);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _setRoleAdmin(REGISTRY_UPDATER_ROLE, ADMIN_ROLE);
    }

    // =========================================================================
    // Legacy Claim Creation
    // =========================================================================

    function createClaim(
        string calldata statement,
        string calldata evidenceCID,
        uint64 verificationDeadline
    ) external override returns (uint256 claimId) {
        uint256 statLen = bytes(statement).length;

        if (
            statLen < STATEMENT_MIN_LENGTH ||
            statLen > STATEMENT_MAX_LENGTH
        ) {
            revert InvalidStatement();
        }

        uint256 cidLen = bytes(evidenceCID).length;

        if (cidLen < CID_MIN_LENGTH || cidLen > CID_MAX_LENGTH) {
            revert InvalidCID();
        }

        // V2-SC-161: `createdAt` / `verificationDeadline` are uint64; never truncate the clock.
        uint64 now_ = V2SafeCast.timestamp64(V2SafeCast.FIELD_REGISTRY_CREATED_AT);

        if (
            verificationDeadline <= now_ ||
            uint256(verificationDeadline) > uint256(now_) + uint256(MAX_DEADLINE_HORIZON)
        ) {
            revert InvalidDeadline();
        }

        // V2-SC-105: reject claim spam before allocating storage.
        AntiGriefing.requireOpenClaimCapacity(
            msg.sender,
            _openClaimCount[msg.sender],
            ProtocolExecutionBounds.MAX_OPEN_CLAIMS_PER_CREATOR
        );
        (uint64 newStart, uint256 newCount) = AntiGriefing.nextClaimWindow(
            msg.sender,
            now_,
            _claimWindowStart[msg.sender],
            _claimsInWindow[msg.sender],
            ProtocolExecutionBounds.MAX_CLAIMS_PER_ACCOUNT_WINDOW,
            uint64(ProtocolExecutionBounds.CLAIM_SPAM_WINDOW_SECONDS)
        );
        _claimWindowStart[msg.sender] = newStart;
        _claimsInWindow[msg.sender] = newCount;

        claimId = _nextClaimId;

        unchecked {
            _nextClaimId = claimId + 1;
        }

        Claim storage c = _claims[claimId];

        c.id = claimId;
        c.creator = msg.sender;
        c.statement = statement;
        c.evidenceCID = evidenceCID;
        c.createdAt = now_;
        c.verificationDeadline = verificationDeadline;

        emit ClaimCreated(
            claimId,
            msg.sender,
            evidenceCID
        );
    }

    // =========================================================================
    // Parameter Registry
    // =========================================================================

    /**
     * @notice Update the ParameterVersionRegistry address.
     * @param newRegistry The new ParameterVersionRegistry address.
     */
    function setParameterVersionRegistry(
        address newRegistry
    ) external onlyRole(ADMIN_ROLE) {
        if (newRegistry == address(0)) {
            revert("ClaimRegistry: zero address");
        }

        parameterVersionRegistry =
            IParameterVersionRegistry(newRegistry);
    }

    // =========================================================================
    // Legacy Claim Status
    // =========================================================================

    /**
     * @inheritdoc IClaimRegistry
     *
     * @dev Only accounts holding REGISTRY_UPDATER_ROLE may call this function.
     */
    function updateClaimStatus(
        uint256 claimId,
        ClaimStatus newStatus
    ) external override onlyRole(REGISTRY_UPDATER_ROLE) {
        if (_claims[claimId].createdAt == 0) {
            revert ClaimNotFound(claimId);
        }

        ClaimStatus current = _claims[claimId].status;

        if (current == newStatus) {
            revert InvalidStatusTransition(
                current,
                newStatus
            );
        }

        _claims[claimId].status = newStatus;

        emit ClaimStatusUpdated(
            claimId,
            current,
            newStatus
        );
    }

    // =========================================================================
    // Canonical V2 Claim Creation
    // =========================================================================

    /**
     * @notice Create a canonical claim using the currently active parameter
     *         version from ParameterVersionRegistry.
     */
    function createCanonicalClaim(
        address recipient,
        address asset,
        uint256 bounty,
        bytes32 metadataDigest,
        bytes32 evidenceDigest,
        uint256 nonce
    )
        external
        override
        nonReentrant
        returns (bytes32 claimId)
    {
        uint256 activeVersion =
            parameterVersionRegistry.currentActiveVersionId();

        return _createCanonicalClaim(
            recipient,
            asset,
            bounty,
            metadataDigest,
            evidenceDigest,
            nonce,
            activeVersion
        );
    }

    /**
     * @notice Create a canonical claim using an explicitly supplied parameter
     *         version.
     *
     * @dev The supplied parameter version must equal the currently active
     *      version. This prevents callers from creating new claims against
     *      stale parameter versions.
     */
    function createCanonicalClaim(
        address recipient,
        address asset,
        uint256 bounty,
        bytes32 metadataDigest,
        bytes32 evidenceDigest,
        uint256 nonce,
        uint256 parameterVersion
    )
        external
        override
        nonReentrant
        returns (bytes32 claimId)
    {
        return _createCanonicalClaim(
            recipient,
            asset,
            bounty,
            metadataDigest,
            evidenceDigest,
            nonce,
            parameterVersion
        );
    }

    function currentConfigVersion()
        external
        view
        override
        returns (uint256 version)
    {
        return _configVersion;
    }

    // =========================================================================
    // Supported Assets
    // =========================================================================

    function setSupportedAsset(
        address asset,
        bool supported,
        uint256 minBounty,
        uint256 maxBounty
    )
        external
        override
        onlyRole(ADMIN_ROLE)
    {
        if (asset == address(0)) {
            revert ZeroAddress();
        }

        if (supported) {
            IParameterVersionRegistry.EconomicParameters memory params =
                parameterVersionRegistry.getCurrentParameters();

            uint256 safeMin = params.minBountyAmount;
            uint256 safeMax = params.maxBountyAmount;

            if (
                minBounty < safeMin ||
                maxBounty > safeMax ||
                minBounty > maxBounty
            ) {
                revert InvalidBounty(minBounty);
            }

            _supportedAssets[asset] = true;
            _assetMinBounty[asset] = minBounty;
            _assetMaxBounty[asset] = maxBounty;
        } else {
            _supportedAssets[asset] = false;
            _assetMinBounty[asset] = 0;
            _assetMaxBounty[asset] = 0;
        }
    }

    function isSupportedAsset(
        address asset
    )
        external
        view
        override
        returns (bool supported)
    {
        return _supportedAssets[asset];
    }

    function getAssetBounds(
        address asset
    )
        external
        view
        override
        returns (
            uint256 minBounty,
            uint256 maxBounty
        )
    {
        return (
            _assetMinBounty[asset],
            _assetMaxBounty[asset]
        );
    }

    // =========================================================================
    // Claim ID
    // =========================================================================

    function computeClaimId(
        address submitter,
        uint256 submitterNonce,
        bytes32 metadataDigest
    )
        public
        view
        override
        returns (bytes32 claimId)
    {
        if (submitter == address(0)) {
            revert ZeroAddress();
        }

        if (metadataDigest == 0) {
            revert ZeroDigest();
        }

        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                submitter,
                submitterNonce,
                metadataDigest
            )
        );
    }

    function claimIdFor(
        address submitter,
        uint256 submitterNonce,
        bytes32 metadataDigest
    )
        external
        view
        override
        returns (bytes32 claimId)
    {
        return computeClaimId(
            submitter,
            submitterNonce,
            metadataDigest
        );
    }

    // =========================================================================
    // Canonical Claim Views
    // =========================================================================

    function getCanonicalClaim(
        bytes32 claimId
    )
        external
        view
        override
        returns (CanonicalClaim memory claim)
    {
        if (!_canonicalClaimExists[claimId]) {
            revert CanonicalClaimNotFound(claimId);
        }

        return _canonicalClaims[claimId];
    }

    function claimExists(
        bytes32 claimId
    )
        external
        view
        override
        returns (bool exists)
    {
        return _canonicalClaimExists[claimId];
    }

    // =========================================================================
    // Legacy Claim Views
    // =========================================================================

    function getClaim(
        uint256 claimId
    )
        external
        view
        override
        returns (Claim memory claim)
    {
        if (_claims[claimId].createdAt == 0) {
            revert ClaimNotFound(claimId);
        }

        return _claims[claimId];
    }

    function claimExists(
        uint256 claimId
    )
        external
        view
        override
        returns (bool exists)
    {
        return _claims[claimId].createdAt != 0;
    }

    function totalClaims()
        external
        view
        override
        returns (uint256 total)
    {
        unchecked {
            return _nextClaimId - 1;
        }
    }

    function getClaimCreator(
        uint256 claimId
    )
        external
        view
        override
        returns (address creator)
    {
        if (_claims[claimId].createdAt == 0) {
            revert ClaimNotFound(claimId);
        }

        return _claims[claimId].creator;
    }

    function getClaimStatus(
        uint256 claimId
    )
        external
        view
        override
        returns (ClaimStatus status)
    {
        if (_claims[claimId].createdAt == 0) {
            revert ClaimNotFound(claimId);
        }

        return _claims[claimId].status;
    }

    // =========================================================================
    // Internal Canonical Claim Creation
    // =========================================================================

    function _createCanonicalClaim(
        address recipient,
        address asset,
        uint256 bounty,
        bytes32 metadataDigest,
        bytes32 evidenceDigest,
        uint256 nonce,
        uint256 parameterVersion
    )
        internal
        returns (bytes32 claimId)
    {
        if (msg.sender == address(0)) {
            revert ZeroAddress();
        }

        if (recipient == address(0)) {
            revert ZeroRecipient();
        }

        if (asset == address(0)) {
            revert UnsupportedAsset(asset);
        }

        if (!_supportedAssets[asset]) {
            revert UnsupportedAsset(asset);
        }

        if (
            metadataDigest == 0 ||
            evidenceDigest == 0
        ) {
            revert ZeroDigest();
        }

        // Always compare the supplied version against the registry's
        // currently active version.
        uint256 activeVersion =
            parameterVersionRegistry.currentActiveVersionId();

        if (
            parameterVersion == 0 ||
            parameterVersion != activeVersion
        ) {
            revert InvalidParameterVersion(
                activeVersion,
                parameterVersion
            );
        }

        IParameterVersionRegistry.EconomicParameters memory params =
            parameterVersionRegistry.getCurrentParameters();

        uint256 safeMin = params.minBountyAmount;
        uint256 safeMax = params.maxBountyAmount;

        if (
            bounty < safeMin ||
            bounty > safeMax
        ) {
            revert InvalidBounty(bounty);
        }

        uint256 minBounty =
            _assetMinBounty[asset];

        uint256 maxBounty =
            _assetMaxBounty[asset];

        if (
            bounty == 0 ||
            bounty < minBounty ||
            bounty > maxBounty
        ) {
            revert InvalidBounty(bounty);
        }

        uint256 expectedNonce =
            _submitterNonce[msg.sender];

        if (nonce != expectedNonce) {
            revert InvalidNonce(
                expectedNonce,
                nonce
            );
        }

        claimId = computeClaimId(
            msg.sender,
            nonce,
            metadataDigest
        );

        if (_canonicalClaimExists[claimId]) {
            revert DuplicateClaimId(claimId);
        }

        IERC20(asset).safeTransferFrom(
            msg.sender,
            address(this),
            bounty
        );

        _submitterNonce[msg.sender] =
            nonce + 1;

        bytes32 custodyRef =
            keccak256(
                abi.encode(
                    asset,
                    recipient,
                    bounty,
                    claimId,
                    block.timestamp
                )
            );

        CanonicalClaim storage claim =
            _canonicalClaims[claimId];

        claim.id = claimId;
        claim.submitter = msg.sender;
        claim.recipient = recipient;
        claim.asset = asset;
        claim.bounty = bounty;
        claim.metadataDigest = metadataDigest;
        claim.evidenceDigest = evidenceDigest;
        claim.nonce = nonce;

        // Snapshot the parameter version at creation time.
        claim.parameterVersion =
            parameterVersion;

        claim.createdAt =
            V2SafeCast.timestamp64(V2SafeCast.FIELD_REGISTRY_CANONICAL_CREATED_AT);

        claim.custodyRef =
            custodyRef;

        claim.exists = true;

        _canonicalClaimExists[claimId] =
            true;

        emit ClaimCreated(
            claimId,
            msg.sender,
            recipient,
            asset,
            bounty,
            metadataDigest,
            evidenceDigest,
            nonce,
            parameterVersion,
            custodyRef
        );
    }
}

// =========================================================================
// Deterministic Aggregation Engine
// =========================================================================

struct FrozenVerificationRecord {
    bool decision;
    uint256 effectiveWeight;
}

interface IVerificationRoundManager {
    /// @notice Returns the number of frozen verification records for a round/claim.
    function frozenRecordCount(
        uint256 roundId,
        uint256 claimId
    )
        external
        view
        returns (uint256 count);

    /// @notice Returns one frozen verification record by index.
    function frozenRecordAt(
        uint256 roundId,
        uint256 claimId,
        uint256 index
    )
        external
        view
        returns (
            FrozenVerificationRecord memory record
        );

    /// @notice Returns true when the threshold module signals threshold failure.
    function thresholdFailure(
        uint256 roundId,
        uint256 claimId
    )
        external
        view
        returns (bool failed);

    /// @notice Returns the protocol parameter version for a round.
    function parameterVersion(
        uint256 roundId
    )
        external
        view
        returns (uint256 version);
}

/**
 * @title DeterministicAggregationEngine
 * @author TruthBounty Protocol
 * @notice Integer-only, order-independent aggregation engine for frozen
 *         verification records.
 * @dev This contract consumes frozen participation snapshots from an
 *      immutable round manager.
 */
contract DeterministicAggregationEngine {
    enum AggregationOutcome {
        Inconclusive,
        True,
        False
    }

    struct AggregationRecord {
        uint256 roundId;
        uint256 claimId;
        uint256 trueEffectiveWeight;
        uint256 falseEffectiveWeight;
        uint256 trueCount;
        uint256 falseCount;
        AggregationOutcome outcome;
        uint256 parameterVersion;
    }

    error InvalidRoundManager();
    error TooManyParticipants(uint256 count);

    event AggregationComputed(
        uint256 indexed roundId,
        uint256 indexed claimId,
        AggregationOutcome outcome,
        uint256 trueEffectiveWeight,
        uint256 falseEffectiveWeight,
        uint256 parameterVersion
    );

    /// @notice Maximum number of frozen records aggregated in a single call.
    uint256 public constant MAX_PARTICIPANTS = 256;

    /// @notice Immutable round manager used to get frozen records.
    IVerificationRoundManager public immutable roundManager;

    mapping(
        uint256 => mapping(uint256 => AggregationRecord)
    )
        private _aggregationRecords;

    mapping(
        uint256 => mapping(uint256 => bool)
    )
        private _aggregated;

    constructor(
        IVerificationRoundManager roundManager_
    ) {
        if (address(roundManager_) == address(0)) {
            revert InvalidRoundManager();
        }

        roundManager = roundManager_;
    }

    /**
     * @notice Aggregates frozen verification records for a round/claim pair.
     */
    function aggregate(
        uint256 roundId,
        uint256 claimId
    )
        external
        returns (AggregationRecord memory record)
    {
        if (_aggregated[roundId][claimId]) {
            return _aggregationRecords[roundId][claimId];
        }

        uint256 count =
            roundManager.frozenRecordCount(
                roundId,
                claimId
            );

        if (count > MAX_PARTICIPANTS) {
            revert TooManyParticipants(count);
        }

        uint256 trueEffectiveWeight;
        uint256 falseEffectiveWeight;
        uint256 trueCount;
        uint256 falseCount;

        bool thresholdFailed =
            roundManager.thresholdFailure(
                roundId,
                claimId
            );

        for (uint256 i; i < count; ++i) {
            FrozenVerificationRecord memory frozen =
                roundManager.frozenRecordAt(
                    roundId,
                    claimId,
                    i
                );

            if (frozen.decision) {
                trueEffectiveWeight +=
                    frozen.effectiveWeight;

                unchecked {
                    ++trueCount;
                }
            } else {
                falseEffectiveWeight +=
                    frozen.effectiveWeight;

                unchecked {
                    ++falseCount;
                }
            }
        }

        AggregationOutcome outcome =
            AggregationOutcome.Inconclusive;

        if (
            !thresholdFailed &&
            trueEffectiveWeight !=
            falseEffectiveWeight
        ) {
            outcome =
                trueEffectiveWeight >
                falseEffectiveWeight
                    ? AggregationOutcome.True
                    : AggregationOutcome.False;
        }

        uint256 parameterVersion =
            roundManager.parameterVersion(
                roundId
            );

        record = AggregationRecord({
            roundId: roundId,
            claimId: claimId,
            trueEffectiveWeight:
                trueEffectiveWeight,
            falseEffectiveWeight:
                falseEffectiveWeight,
            trueCount: trueCount,
            falseCount: falseCount,
            outcome: outcome,
            parameterVersion:
                parameterVersion
        });

        _aggregated[roundId][claimId] =
            true;

        _aggregationRecords[roundId][claimId] =
            record;

        emit AggregationComputed(
            roundId,
            claimId,
            outcome,
            trueEffectiveWeight,
            falseEffectiveWeight,
            parameterVersion
        );
    }

    /**
     * @notice Returns the stored aggregation record, or an empty record if
     *         not aggregated yet.
     */
    function getAggregationRecord(
        uint256 roundId,
        uint256 claimId
    )
        external
        view
        returns (
            AggregationRecord memory record
        )
    {
        return _aggregationRecords[
            roundId
        ][claimId];
    }
}
