// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IChainConfigRegistry
 * @notice Interface for the canonical per-chain configuration isolation registry.
 *
 * V2-SC-139 — Verify Multi-Chain Configuration Cannot Cross-Contaminate
 *
 * Authoritative behavior
 * ─────────────────────
 * Each EVM chain on which the V2 protocol is deployed MUST register exactly one
 * ChainConfig envelope keyed by the actual block.chainid of that chain.  Chain IDs,
 * deployment salts, manifest content-hashes, treasury/governance authority addresses,
 * accepted asset lists, and finality-period settings are all captured inside a single
 * sealed envelope per chain.  Once an envelope is sealed it is immutable; a new version
 * must be proposed and activated through the timelocked upgrade path.
 *
 * Cross-contamination prevention (enforced at write time)
 * ────────────────────────────────────────────────────────
 * • chainId   — must equal block.chainid of the registering chain.
 * • salt      — must be globally unique across every registered envelope.
 * • governance — must be non-zero and unique across every SEALED envelope.
 *
 * Trust boundaries
 * ────────────────
 * • CHAIN_CONFIG_PROPOSER_ROLE — may draft new envelopes.
 * • CHAIN_CONFIG_EXECUTOR_ROLE — may seal after timelock expires.
 * • CHAIN_CONFIG_GUARDIAN_ROLE — may cancel drafts; cannot activate or edit.
 * • No API/indexer/frontend/deployer/test harness may hold these roles in production.
 *
 * Event / storage model (sufficient for deterministic projection)
 * ──────────────────────────────────────────────────────────────
 * ChainConfigRegistered  — draft created.
 * ChainConfigSealed      — envelope made authoritative.
 * ChainConfigDeprecated  — older sealed version superseded.
 * ChainConfigCancelled   — guardian cancelled a draft.
 *
 * Migration / compatibility
 * ─────────────────────────
 * Active claims link to the configVersion that was SEALED when they were created.
 * Claim parameters are frozen for the claim's lifetime; config upgrades are
 * non-retroactive.  Existing sealed envelopes remain readable indefinitely.
 */
interface IChainConfigRegistry {

    // ─── Lifecycle states ─────────────────────────────────────────────────────

    enum ConfigStatus {
        DRAFT,       // Registered but not yet sealed.
        SEALED,      // Authoritative for its chain.
        DEPRECATED,  // Superseded by a newer sealed version.
        CANCELLED    // Cancelled before sealing; never authoritative.
    }

    // ─── Core data structure ──────────────────────────────────────────────────

    /**
     * @notice Per-chain configuration envelope.
     * @param chainId         EVM chain identifier; must match block.chainid at registration.
     * @param configVersion   Monotonically increasing version per chain; 1-indexed.
     * @param salt            CREATE2 salt unique to this chain+version across all chains.
     * @param manifestHash    keccak256 of the deployment manifest JSON.
     * @param governance      On-chain governance authority for this chain (non-zero, unique among sealed).
     * @param treasury        Protocol treasury for this chain (non-zero).
     * @param acceptedAssets  ERC-20 addresses accepted as bounty assets (non-empty, no zero elements).
     * @param finalityBlocks  Minimum block depth for cross-chain message trust (non-zero).
     * @param finalitySeconds Minimum wall-clock seconds for finality (non-zero).
     * @param status          Lifecycle state.
     * @param proposedAt      block.timestamp when the draft was first written.
     * @param sealedAt        block.timestamp when sealed (0 if not yet sealed).
     * @param executeAfter    Earliest block.timestamp at which sealing is permitted.
     * @param proposer        Account that created the draft.
     */
    struct ChainConfig {
        uint256      chainId;
        uint256      configVersion;
        bytes32      salt;
        bytes32      manifestHash;
        address      governance;
        address      treasury;
        address[]    acceptedAssets;
        uint64       finalityBlocks;
        uint64       finalitySeconds;
        ConfigStatus status;
        uint256      proposedAt;
        uint256      sealedAt;
        uint256      executeAfter;
        address      proposer;
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    /**
     * @notice Emitted when a draft envelope is first registered.
     */
    event ChainConfigRegistered(
        uint256 indexed chainId,
        uint256 indexed configVersion,
        bytes32 indexed salt,
        bytes32  manifestHash,
        address  governance,
        address  proposer,
        uint256  executeAfter
    );

    /**
     * @notice Emitted when a draft is sealed and becomes authoritative.
     */
    event ChainConfigSealed(
        uint256 indexed chainId,
        uint256 indexed configVersion,
        uint256  sealedAt,
        address indexed executor
    );

    /**
     * @notice Emitted when a previously sealed version is superseded.
     */
    event ChainConfigDeprecated(
        uint256 indexed chainId,
        uint256 indexed oldVersion,
        uint256  newVersion
    );

    /**
     * @notice Emitted when a guardian cancels a pending draft.
     */
    event ChainConfigCancelled(
        uint256 indexed chainId,
        uint256 indexed configVersion,
        address indexed canceller
    );

    // ─── Errors ───────────────────────────────────────────────────────────────

    /// chainId in the envelope does not equal block.chainid.
    error ChainIdMismatch(uint256 expected, uint256 provided);

    /// salt has already been used in a previous envelope on any chain.
    error SaltAlreadyUsed(bytes32 salt);

    /// governance is address(0) or already used in a SEALED envelope on another chain.
    error GovernanceAddressConflict(address governance);

    /// manifestHash is zero.
    error ManifestHashRequired();

    /// acceptedAssets list is empty or contains address(0).
    error InvalidAssetList();

    /// finalityBlocks or finalitySeconds is zero.
    error InvalidFinalitySettings();

    /// No envelope exists for (chainId, configVersion).
    error ConfigNotFound(uint256 chainId, uint256 configVersion);

    /// Envelope exists but is not in DRAFT status.
    error ConfigNotDraft(uint256 chainId, uint256 configVersion);

    /// block.timestamp < envelope.executeAfter.
    error TimelockNotExpired(uint256 executeAfter);

    /// treasury address is zero.
    error ZeroTreasury();

    /// No SEALED envelope exists for the requested chain.
    error NoSealedConfig(uint256 chainId);

    // ─── Mutating functions ───────────────────────────────────────────────────

    /**
     * @notice Register a draft chain-configuration envelope.
     *
     * Isolation checks (each reverts if violated):
     *  • chainId == block.chainid                   (ChainIdMismatch)
     *  • salt not previously registered             (SaltAlreadyUsed)
     *  • manifestHash != bytes32(0)                 (ManifestHashRequired)
     *  • governance != address(0) and not in any SEALED envelope (GovernanceAddressConflict)
     *  • treasury != address(0)                     (ZeroTreasury)
     *  • acceptedAssets.length > 0; no zero element (InvalidAssetList)
     *  • finalityBlocks > 0 && finalitySeconds > 0  (InvalidFinalitySettings)
     *
     * @return configVersion  The version number assigned to the new draft (1-indexed per chain).
     */
    function registerChainConfig(
        uint256  chainId,
        bytes32  salt,
        bytes32  manifestHash,
        address  governance,
        address  treasury,
        address[] calldata acceptedAssets,
        uint64   finalityBlocks,
        uint64   finalitySeconds
    ) external returns (uint256 configVersion);

    /**
     * @notice Seal (activate) a draft envelope after its timelock expires.
     *
     * Requirements:
     *  • Envelope must be in DRAFT status.
     *  • block.timestamp >= envelope.executeAfter.
     *  • Caller must hold CHAIN_CONFIG_EXECUTOR_ROLE.
     */
    function sealChainConfig(uint256 chainId, uint256 configVersion) external;

    /**
     * @notice Cancel a pending draft (guardian action).
     *
     * Requirements:
     *  • Envelope must be in DRAFT status.
     *  • Caller must hold CHAIN_CONFIG_GUARDIAN_ROLE.
     */
    function cancelDraft(uint256 chainId, uint256 configVersion) external;

    // ─── View functions ───────────────────────────────────────────────────────

    /// @notice Return the currently SEALED config for a chain.  Reverts with NoSealedConfig if none.
    function getSealedConfig(uint256 chainId) external view returns (ChainConfig memory);

    /// @notice Return any version of a config envelope (any status).
    function getConfig(uint256 chainId, uint256 configVersion) external view returns (ChainConfig memory);

    /// @notice Latest config version number for a chain (0 if none registered).
    function getLatestVersion(uint256 chainId) external view returns (uint256);

    /// @notice True if the salt has been used in any registered envelope.
    function isSaltUsed(bytes32 salt) external view returns (bool);

    /// @notice True if the governance address appears in any SEALED envelope.
    function isGovernanceSealed(address governance) external view returns (bool);

    /// @notice Minimum timelock (seconds) before a draft may be sealed.
    function CONFIG_TIMELOCK() external view returns (uint256);
}
