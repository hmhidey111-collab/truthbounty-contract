
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DeploymentAttestationRegistry
 * @notice Append-only, on-chain release metadata for the canonical protocol.
 *
 * @dev The governance authority records an exact artifact and module-address
 *      manifest. Once recorded, a release can never be overwritten or deleted.
 *
 *      The registry allows indexers and other contracts to independently
 *      verify deployment metadata without trusting an off-chain API or
 *      deployer database.
 *
 *      V2 safety boundary: deployment configuration is bound to chain ID,
 *      release ID, configuration checksum, broadcaster, nonce plan, and
 *      expiry. Reused or wrong-environment configuration is rejected before
 *      the first transaction is broadcast. Errors reveal no secret material.
 */
contract DeploymentAttestationRegistry {
    uint256 public constant MAX_MODULES = 32;

    struct Attestation {
        bytes32 releaseId;
        uint256 chainId;
        bytes32 artifactDigest;
        uint64 configurationVersion;
        bytes32 configurationChecksum;
        address broadcaster;
        uint64 noncePlan;
        uint64 expiresAt;
        bytes32[] moduleIds;
        address[] moduleAddresses;
        uint64 recordedAt;
    }

    /// @notice Address authorized to publish deployment attestations.
    address public immutable governanceAuthority;

    /// @notice Number of attestations successfully recorded.
    uint256 public attestationCount;

    /// @notice Tracks consumed configuration checksums to prevent replay.
    mapping(bytes32 => bool) public consumedConfigurationChecksum;

    mapping(bytes32 => Attestation) private _attestations;
    mapping(bytes32 => bool) public hasAttestation;

    error ZeroGovernanceAuthority();
    error Unauthorized(address caller);
    error InvalidReleaseId();
    error InvalidArtifactDigest();
    error InvalidChainId(uint256 expected, uint256 supplied);
    error InvalidConfigurationVersion();
    error InvalidConfigurationChecksum();
    error InvalidBroadcaster();
    error InvalidNoncePlan();
    error ConfigurationExpired(uint64 expiresAt, uint64 currentTime);
    error ConfigurationChecksumReused(bytes32 configurationChecksum);
    error BroadcasterMismatch(address expected, address supplied);
    error NoncePlanMismatch(uint64 expected, uint64 supplied);
    error ModuleArrayLengthMismatch();
    error TooManyModules(uint256 supplied, uint256 maximum);
    error ZeroModuleId(uint256 index);
    error ZeroModuleAddress(uint256 index);
    error DuplicateModuleId(bytes32 moduleId);
    error AttestationAlreadyExists(bytes32 releaseId);
    error ModuleIndexOutOfBounds(
        bytes32 releaseId,
        uint256 index,
        uint256 length
    );

    event DeploymentAttested(
        bytes32 indexed releaseId,
        uint256 indexed chainId,
        bytes32 indexed artifactDigest,
        uint64 configurationVersion,
        bytes32 configurationChecksum,
        address indexed broadcaster,
        uint64 noncePlan,
        uint64 expiresAt,
        bytes32[] moduleIds,
        address[] moduleAddresses,
        address governanceAuthority,
        uint64 recordedAt
    );

    constructor(address governanceAuthority_) {
        if (governanceAuthority_ == address(0)) {
            revert ZeroGovernanceAuthority();
        }

        governanceAuthority = governanceAuthority_;
    }

    /**
     * @notice Publish an immutable deployment manifest for this chain.
     *
     * @dev Only the configured governance authority may attest.
     *
     *      The supplied chain ID must match the execution chain.
     *      Every module ID and address must be non-zero.
     *      Module IDs must be unique within the release.
     *      A release ID can never be replaced.
     */
    function attestDeployment(
        bytes32 releaseId,
        uint256 chainId,
        bytes32 artifactDigest,
        uint64 configurationVersion,
        bytes32 configurationChecksum,
        address broadcaster,
        uint64 noncePlan,
        uint64 expiresAt,
        bytes32[] calldata moduleIds,
        address[] calldata moduleAddresses
    ) external {
        if (msg.sender != governanceAuthority) {
            revert Unauthorized(msg.sender);
        }

        if (releaseId == bytes32(0)) {
            revert InvalidReleaseId();
        }

        if (artifactDigest == bytes32(0)) {
            revert InvalidArtifactDigest();
        }

        if (chainId != block.chainid) {
            revert InvalidChainId(block.chainid, chainId);
        }

        if (configurationVersion == 0) {
            revert InvalidConfigurationVersion();
        }

        if (configurationChecksum == bytes32(0)) {
            revert InvalidConfigurationChecksum();
        }

        if (broadcaster == address(0)) {
            revert InvalidBroadcaster();
        }

        if (noncePlan == 0) {
            revert InvalidNoncePlan();
        }

        if (expiresAt <= uint64(block.timestamp)) {
            revert ConfigurationExpired(expiresAt, uint64(block.timestamp));
        }

        if (consumedConfigurationChecksum[configurationChecksum]) {
            revert ConfigurationChecksumReused(configurationChecksum);
        }

        if (moduleIds.length != moduleAddresses.length) {
            revert ModuleArrayLengthMismatch();
        }

        if (moduleIds.length > MAX_MODULES) {
            revert TooManyModules(moduleIds.length, MAX_MODULES);
        }

        if (hasAttestation[releaseId]) {
            revert AttestationAlreadyExists(releaseId);
        }

        uint256 length = moduleIds.length;

        for (uint256 i; i < length; ++i) {
            bytes32 moduleId = moduleIds[i];

            if (moduleId == bytes32(0)) {
                revert ZeroModuleId(i);
            }

            if (moduleAddresses[i] == address(0)) {
                revert ZeroModuleAddress(i);
            }

            // Prevent duplicate module IDs within the same deployment.
            for (uint256 j; j < i; ++j) {
                if (moduleIds[j] == moduleId) {
                    revert DuplicateModuleId(moduleId);
                }
            }
        }

        Attestation storage attestation = _attestations[releaseId];

        attestation.releaseId = releaseId;
        attestation.chainId = chainId;
        attestation.artifactDigest = artifactDigest;
        attestation.configurationVersion = configurationVersion;
        attestation.configurationChecksum = configurationChecksum;
        attestation.broadcaster = broadcaster;
        attestation.noncePlan = noncePlan;
        attestation.expiresAt = expiresAt;
        attestation.recordedAt = uint64(block.timestamp);

        for (uint256 i; i < length; ++i) {
            attestation.moduleIds.push(moduleIds[i]);
            attestation.moduleAddresses.push(moduleAddresses[i]);
        }

        hasAttestation[releaseId] = true;
        consumedConfigurationChecksum[configurationChecksum] = true;
        ++attestationCount;

        emit DeploymentAttested(
            releaseId,
            chainId,
            artifactDigest,
            configurationVersion,
            configurationChecksum,
            broadcaster,
            noncePlan,
            expiresAt,
            moduleIds,
            moduleAddresses,
            governanceAuthority,
            attestation.recordedAt
        );
    }

    /**
     * @notice Returns the complete attestation for a release.
     */
    function getAttestation(
        bytes32 releaseId
    ) external view returns (Attestation memory) {
        _requireAttestation(releaseId);
        return _attestations[releaseId];
    }

    /**
     * @notice Returns whether a release has been attested.
     */
    function attestationExists(
        bytes32 releaseId
    ) external view returns (bool) {
        return hasAttestation[releaseId];
    }

    /**
     * @notice Returns the number of modules registered for a release.
     */
    function getModuleCount(
        bytes32 releaseId
    ) external view returns (uint256) {
        _requireAttestation(releaseId);
        return _attestations[releaseId].moduleIds.length;
    }

    /**
     * @notice Returns a module ID and address at a specific index.
     */
    function getModule(
        bytes32 releaseId,
        uint256 index
    ) external view returns (bytes32 moduleId, address moduleAddress) {
        _requireAttestation(releaseId);

        Attestation storage attestation = _attestations[releaseId];

        uint256 length = attestation.moduleIds.length;

        if (index >= length) {
            revert ModuleIndexOutOfBounds(releaseId, index, length);
        }

        return (
            attestation.moduleIds[index],
            attestation.moduleAddresses[index]
        );
    }

    /**
     * @notice Returns the configured governance authority.
     */
    function getGovernanceAuthority() external view returns (address) {
        return governanceAuthority;
    }

    /**
     * @notice Returns the configuration binding for a release.
     */
    function getConfigurationBinding(
        bytes32 releaseId
    )
        external
        view
        returns (
            uint256 chainId,
            bytes32 configurationChecksum,
            address broadcaster,
            uint64 noncePlan,
            uint64 expiresAt
        )
    {
        _requireAttestation(releaseId);

        Attestation storage attestation = _attestations[releaseId];

        return (
            attestation.chainId,
            attestation.configurationChecksum,
            attestation.broadcaster,
            attestation.noncePlan,
            attestation.expiresAt
        );
    }

    /**
     * @dev Reverts when the requested release does not exist.
     */
    function _requireAttestation(bytes32 releaseId) internal view {
        if (!hasAttestation[releaseId]) {
            revert InvalidReleaseId();
        }
    }
}