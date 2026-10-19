// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ICreate2AddressPlanner
 * @notice Plans collision-safe deterministic CREATE2 addresses for V2 modules/implementations
 *         and gates registration on reviewed salts plus bytecode verification.
 */
interface ICreate2AddressPlanner {
    /// @notice Full plan record for a module key.
    struct Plan {
        bytes32 moduleId;
        bytes32 reviewedSalt;
        bytes32 derivedSalt;
        bytes32 initCodeHash;
        bytes32 runtimeCodeHash;
        address deployer;
        address predicted;
        bool reserved;
        bool bytecodeVerified;
        bool deploymentConfirmed;
    }

    /// @notice Emitted when a module address is reserved via CREATE2 planning.
    event AddressPlanned(
        bytes32 indexed moduleId,
        address indexed predicted,
        address indexed deployer,
        bytes32 derivedSalt,
        bytes32 initCodeHash
    );

    /// @notice Emitted when planned runtime bytecode is verified against the expected hash.
    event BytecodeVerified(bytes32 indexed moduleId, address indexed predicted, bytes32 runtimeCodeHash);

    /// @notice Emitted when on-chain code at the predicted address matches the verified hash.
    event DeploymentConfirmed(bytes32 indexed moduleId, address indexed predicted);

    /// @notice Emitted when a reserved plan is cleared by an admin.
    event PlanCleared(bytes32 indexed moduleId, address indexed predicted);

    error ZeroModuleId();
    error ZeroSalt();
    error ZeroInitCodeHash();
    error ZeroDeployer();
    error ZeroAddress();
    error PlanAlreadyExists(bytes32 moduleId);
    error PlanNotFound(bytes32 moduleId);
    error SaltAlreadyUsed(bytes32 derivedSalt);
    error AddressCollision(address predicted, bytes32 existingModuleId);
    error TargetAlreadyHasCode(address predicted);
    error BytecodeHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice Runtime bytecode exceeds the EIP-170 maximum code size.
    error RuntimeBytecodeTooLarge(uint256 actual, uint256 maximum);
    error BytecodeNotVerified(bytes32 moduleId);
    error DeploymentCodeMissing(address predicted);
    error NotReadyForRegistration(bytes32 moduleId);

    /**
     * @notice Pure CREATE2 address prediction.
     * @param deployer CREATE2 factory / deployer address.
     * @param salt Domain-separated salt.
     * @param initCodeHash keccak-256 of creation (init) bytecode.
     */
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash)
        external
        pure
        returns (address predicted);

    /**
     * @notice Domain-separates a reviewed salt with the module id for collision safety.
     */
    function deriveSalt(bytes32 moduleId, bytes32 reviewedSalt) external pure returns (bytes32);

    /**
     * @notice Reserves a deterministic address for `moduleId` from a reviewed salt.
     * @dev Reverts on zero inputs, salt reuse, address collision, or existing code at target.
     */
    function planAddress(
        bytes32 moduleId,
        bytes32 reviewedSalt,
        bytes32 initCodeHash,
        address deployer
    ) external returns (address predicted);

    /**
     * @notice Verifies runtime bytecode against the hash recorded (or set) for the plan.
     * @dev Accepts at most 24,576 bytes, the EIP-170 runtime-code limit.
     * @dev If the plan has no runtime hash yet, the provided bytecode hash becomes the expected hash.
     *      If an expected hash is already set, the bytecode must match it.
     */
    function verifyBytecode(bytes32 moduleId, bytes calldata runtimeBytecode) external;

    /**
     * @notice Sets the expected runtime code hash before bytecode is supplied.
     */
    function setExpectedRuntimeCodeHash(bytes32 moduleId, bytes32 runtimeCodeHash) external;

    /**
     * @notice Confirms that code at the predicted address matches the verified runtime hash.
     */
    function confirmDeployment(bytes32 moduleId) external returns (bool);

    /**
     * @notice Returns true only when the plan is reserved, bytecode-set, and deployment-confirmed.
     */
    function isReadyForRegistration(bytes32 moduleId) external view returns (bool);

    /**
     * @notice Returns the plan for `moduleId` (empty / zeroed if unset).
     */
    function getPlan(bytes32 moduleId) external view returns (Plan memory);

    /**
     * @notice Clears a plan. Admin only. Fails closed if ready-for-registration unless forced via role.
     */
    function clearPlan(bytes32 moduleId) external;

    // -----------------------------------------------------------------------------
    // Deployment configuration binding (PREWAVE-SC-028)
    // -----------------------------------------------------------------------------

    /// @notice Complete deployment configuration binding record.
    /// @dev Binds the exact environment (chain + release), configuration digest,
    ///      authorized broadcaster, deterministic nonce plan, and expiry window.
    ///      A configuration is consumed once and cannot be replayed across chain/release.
    struct DeploymentConfig {
        uint256 chainId;
        bytes32 releaseId;
        bytes32 configChecksum;
        address broadcaster;
        uint64 nonceStart;
        uint64 nonceCount;
        uint64 expiry;
    }

    /// @notice Emitted when a deployment configuration is bound for a release.
    event DeploymentConfigBound(
        bytes32 indexed releaseId,
        uint256 indexed chainId,
        bytes32 configChecksum,
        address indexed broadcaster,
        uint64 nonceStart,
        uint64 nonceCount,
        uint64 expiry
    );

    /// @notice Emitted when a deployment configuration is consumed for broadcast.
    event DeploymentConfigConsumed(
        bytes32 indexed releaseId,
        uint256 indexed chainId,
        address indexed broadcaster,
        uint64 nonceStart,
        uint64 nonceCount
    );

    /// @notice Emitted when a bound deployment configuration is revoked by an admin.
    event DeploymentConfigRevoked(
        bytes32 indexed releaseId,
        uint256 indexed chainId,
        bytes32 configChecksum
    );

    error ZeroChainId();
    error ZeroReleaseId();
    error ZeroConfigChecksum();
    error ZeroBroadcaster();
    error InvalidNoncePlan(uint64 nonceStart, uint64 nonceCount);
    error InvalidExpiry(uint64 expiry);
    error WrongChainId(uint256 expected, uint256 actual);
    error StaleRelease(bytes32 releaseId);
    error UnauthorizedBroadcaster(address actual, address expected);
    error ConfigExpired(uint64 expiry, uint64 now);
    error ConfigChecksumMismatch(bytes32 expected, bytes32 actual);
    error DeploymentConfigAlreadyBound(bytes32 releaseId, uint256 chainId);
    error DeploymentConfigNotFound(bytes32 releaseId, uint256 chainId);
    error DeploymentConfigAlreadyConsumed(bytes32 releaseId, uint256 chainId);
    error ForkedChainDetected(uint256 expected, uint256 actual);
    error NoncePlanExhausted(uint64 nonceStart, uint64 nonceCount, uint64 currentNonce);

    /**
     * @notice Binds a deployment configuration to a chain + release before the first transaction.
     * @dev Reverts on zero inputs, invalid nonce plan, expired expiry, or duplicate binding.
     * @dev The config checksum is a domain-separated digest of the full configuration.
     */
    function bindDeploymentConfig(DeploymentConfig calldata config) external;

    /**
     * @notice Validates a bound deployment configuration against the live environment
     *         and the caller before the first transaction is broadcast.
     * @dev Reverts on wrong chain, stale release, unauthorized broadcaster, expired config,
     *      checksum mutation, forked chain, or nonce plan exhaustion.
     * @dev Errors reveal only public configuration metadata; no secret material is ever emitted.
     */
    function validateDeploymentConfig(bytes32 releaseId, uint256 chainId) external view;

    /**
     * @notice Marks a bound deployment configuration as consumed and returns the nonce plan.
     * @dev Validates the configuration first, then consumes it so it cannot be replayed.
     * @dev Reverts if the config is already consumed or the nonce plan is exhausted.
     */
    function consumeDeploymentConfig(bytes32 releaseId, uint256 chainId)
        external
        returns (uint64 nonceStart, uint64 nonceCount);

    /**
     * @notice Revokes a bound deployment configuration. Admin only.
     * @dev Fails closed if the configuration has already been consumed.
     */
    function revokeDeploymentConfig(bytes32 releaseId, uint256 chainId) external;

    /**
     * @notice Returns the bound deployment configuration for a release + chain.
     */
    function getDeploymentConfig(bytes32 releaseId, uint256 chainId)
        external
        view
        returns (DeploymentConfig memory);

    /**
     * @notice Returns true if the deployment configuration is bound and not yet consumed.
     */
    function isDeploymentConfigActive(bytes32 releaseId, uint256 chainId)
        external
        view
        returns (bool);

    /**
     * @notice Returns the domain-separated checksum for a deployment configuration.
     * @dev Pure helper so off-chain tooling can reproduce the exact digest.
     */
    function computeConfigChecksum(DeploymentConfig calldata config)
        external
        pure
        returns (bytes32 checksum);
}