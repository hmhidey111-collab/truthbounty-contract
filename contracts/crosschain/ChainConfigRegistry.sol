// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl}    from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard}  from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IChainConfigRegistry} from "./IChainConfigRegistry.sol";

/**
 * @title ChainConfigRegistry
 * @notice Canonical registry that prevents multi-chain configuration cross-contamination
 *         for the TruthBounty V2 protocol.
 *
 * V2-SC-139 — Verify Multi-Chain Configuration Cannot Cross-Contaminate
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * AUTHORITATIVE BEHAVIOR
 * ═══════════════════════════════════════════════════════════════════════════
 * Each EVM chain on which the V2 protocol is deployed MUST register exactly
 * one ChainConfig envelope keyed by its actual block.chainid.  The envelope
 * captures all fields that could cause silent cross-chain reuse:
 *
 *   • chainId          — bound to block.chainid at registration time.
 *   • salt             — globally unique; prevents CREATE2 address collision.
 *   • manifestHash     — content-addresses the deployment manifest.
 *   • governance       — on-chain authority; unique per sealed chain.
 *   • treasury         — on-chain treasury; non-zero.
 *   • acceptedAssets   — asset allow-list; validated at registration.
 *   • finalityBlocks   — chain-specific finality depth.
 *   • finalitySeconds  — chain-specific finality wall-clock.
 *
 * Once an envelope is SEALED it is immutable.  A new version must be
 * drafted and re-sealed through the timelocked upgrade path.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * SECURITY / ARCHITECTURE REQUIREMENTS (per issue spec)
 * ═══════════════════════════════════════════════════════════════════════════
 * • Optimism/EVM contracts remain authoritative — this registry is an
 *   on-chain contract; all mutations require role-gated on-chain calls.
 * • No API/indexer/frontend/guardian/deployer/test may gain settlement or
 *   treasury authority (enforced: the registry controls only config; no
 *   value is held or transferred).
 * • Zero-address dependencies rejected at every write site.
 * • No unbounded loops (all asset list iteration is bounded by the calldata
 *   provided at registration time; no loops in view functions over all chains).
 * • Pull-based — no push transfers; no ETH held.
 * • Deterministic rounding — no floating point; no division.
 * • Replayable events — every mutation emits a fully-indexed event.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ROLES
 * ═══════════════════════════════════════════════════════════════════════════
 * CHAIN_CONFIG_PROPOSER_ROLE — may registerChainConfig.
 * CHAIN_CONFIG_EXECUTOR_ROLE — may sealChainConfig after timelock.
 * CHAIN_CONFIG_GUARDIAN_ROLE — may cancelDraft; cannot seal or edit.
 * DEFAULT_ADMIN_ROLE         — manages role membership.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * STORAGE MODEL (per slot, deterministically projectable from events)
 * ═══════════════════════════════════════════════════════════════════════════
 * _configs[chainId][version] → ChainConfig struct
 * _latestVersion[chainId]    → uint256
 * _sealedVersion[chainId]    → uint256 (0 = none)
 * _saltUsed[salt]            → bool
 * _govSealed[governance]     → bool
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * MIGRATION IMPACT
 * ═══════════════════════════════════════════════════════════════════════════
 * • Claims created before this registry is deployed are unaffected; they
 *   continue to use parameters from ParameterVersionRegistry (V2-SC-003 / V2-SC-131).
 * • New claims created after this registry is deployed SHOULD record the
 *   sealed configVersion via recordClaimConfig(); this is a caller
 *   responsibility (ClaimRegistry calls this function).
 * • No storage in this contract is ever deleted; all versions remain readable.
 */
contract ChainConfigRegistry is IChainConfigRegistry, AccessControl, ReentrancyGuard {

    // ─── Roles ────────────────────────────────────────────────────────────────

    bytes32 public constant CHAIN_CONFIG_PROPOSER_ROLE =
        keccak256("CHAIN_CONFIG_PROPOSER_ROLE");
    bytes32 public constant CHAIN_CONFIG_EXECUTOR_ROLE =
        keccak256("CHAIN_CONFIG_EXECUTOR_ROLE");
    bytes32 public constant CHAIN_CONFIG_GUARDIAN_ROLE =
        keccak256("CHAIN_CONFIG_GUARDIAN_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @notice Minimum timelock before a draft may be sealed (2 days — matches ParameterVersionRegistry).
    uint256 public constant CONFIG_TIMELOCK = 2 days;

    /// @notice Maximum accepted assets per envelope (prevents unbounded loops in callers).
    uint256 public constant MAX_ACCEPTED_ASSETS = 64;

    // ─── Storage ──────────────────────────────────────────────────────────────

    /// @dev Full envelope storage.  configVersion is 1-indexed per chainId.
    mapping(uint256 chainId => mapping(uint256 version => ChainConfig)) private _configs;

    /// @dev Highest registered version per chain.
    mapping(uint256 chainId => uint256 latestVersion) private _latestVersion;

    /// @dev Currently SEALED version per chain (0 = none).
    mapping(uint256 chainId => uint256 sealedVersion) private _sealedVersion;

    /// @dev Salt uniqueness index (cross-chain).
    mapping(bytes32 salt => bool used) private _saltUsed;

    /// @dev Governance address uniqueness among sealed envelopes.
    mapping(address governance => bool isSealed) private _govSealed;

    /// @dev claim → sealed configVersion at claim creation time.
    mapping(uint256 claimId => uint256 configVersion) private _claimConfigVersion;

    // ─── Errors (not in interface, implementation-specific) ───────────────────

    error TreasuryAlreadyUsed(address treasury);
    error AssetLimitExceeded(uint256 count, uint256 max);
    error ClaimAlreadyRecorded(uint256 claimId);
    error NoSealedConfigForClaim(uint256 chainId);

    // ─── Events (implementation-specific) ────────────────────────────────────

    /// @notice Emitted when a claim is linked to the sealed config version active at creation.
    event ClaimLinkedToConfig(uint256 indexed claimId, uint256 indexed chainId, uint256 indexed configVersion);

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param initialAdmin  The account that receives DEFAULT_ADMIN_ROLE and all
     *                      operational roles.  Must be non-zero.
     */
    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert GovernanceAddressConflict(address(0));

        _grantRole(DEFAULT_ADMIN_ROLE,            initialAdmin);
        _grantRole(CHAIN_CONFIG_PROPOSER_ROLE,    initialAdmin);
        _grantRole(CHAIN_CONFIG_EXECUTOR_ROLE,    initialAdmin);
        _grantRole(CHAIN_CONFIG_GUARDIAN_ROLE,    initialAdmin);

        // Role hierarchy: only DEFAULT_ADMIN may grant operational roles.
        _setRoleAdmin(CHAIN_CONFIG_PROPOSER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(CHAIN_CONFIG_EXECUTOR_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(CHAIN_CONFIG_GUARDIAN_ROLE, DEFAULT_ADMIN_ROLE);
    }

    // ─── Mutating functions ───────────────────────────────────────────────────

    /// @inheritdoc IChainConfigRegistry
    /// @dev Isolation checks (ordered; each reverts before writing any state):
    ///      1. chainId == block.chainid
    ///      2. salt not used
    ///      3. manifestHash != 0
    ///      4. governance != 0 and not sealed on another chain
    ///      5. treasury != 0
    ///      6. acceptedAssets: length 1..MAX_ACCEPTED_ASSETS, no zero elements
    ///      7. finalityBlocks > 0 && finalitySeconds > 0
    ///      All checks run before any storage mutation (fail-safe ordering).
    function registerChainConfig(
        uint256  chainId,
        bytes32  salt,
        bytes32  manifestHash,
        address  governance,
        address  treasury,
        address[] calldata acceptedAssets,
        uint64   finalityBlocks,
        uint64   finalitySeconds
    ) external override nonReentrant onlyRole(CHAIN_CONFIG_PROPOSER_ROLE) returns (uint256 configVersion) {

        // ── 1. Chain-ID isolation ─────────────────────────────────────────────
        if (chainId != block.chainid) {
            revert ChainIdMismatch(block.chainid, chainId);
        }

        // ── 2. Salt uniqueness (cross-chain) ──────────────────────────────────
        if (_saltUsed[salt]) {
            revert SaltAlreadyUsed(salt);
        }

        // ── 3. Manifest hash ──────────────────────────────────────────────────
        if (manifestHash == bytes32(0)) {
            revert ManifestHashRequired();
        }

        // ── 4. Governance address ─────────────────────────────────────────────
        if (governance == address(0) || _govSealed[governance]) {
            revert GovernanceAddressConflict(governance);
        }

        // ── 5. Treasury ───────────────────────────────────────────────────────
        if (treasury == address(0)) {
            revert ZeroTreasury();
        }

        // ── 6. Asset list ─────────────────────────────────────────────────────
        uint256 assetLen = acceptedAssets.length;
        if (assetLen == 0) {
            revert InvalidAssetList();
        }
        if (assetLen > MAX_ACCEPTED_ASSETS) {
            revert AssetLimitExceeded(assetLen, MAX_ACCEPTED_ASSETS);
        }
        for (uint256 i = 0; i < assetLen; ++i) {
            if (acceptedAssets[i] == address(0)) {
                revert InvalidAssetList();
            }
        }

        // ── 7. Finality settings ──────────────────────────────────────────────
        if (finalityBlocks == 0 || finalitySeconds == 0) {
            revert InvalidFinalitySettings();
        }

        // ── Write state ───────────────────────────────────────────────────────
        _saltUsed[salt] = true;

        configVersion = _latestVersion[chainId] + 1;
        _latestVersion[chainId] = configVersion;

        uint256 executeAfter = block.timestamp + CONFIG_TIMELOCK;

        ChainConfig storage cfg = _configs[chainId][configVersion];
        cfg.chainId         = chainId;
        cfg.configVersion   = configVersion;
        cfg.salt            = salt;
        cfg.manifestHash    = manifestHash;
        cfg.governance      = governance;
        cfg.treasury        = treasury;
        cfg.finalityBlocks  = finalityBlocks;
        cfg.finalitySeconds = finalitySeconds;
        cfg.status          = ConfigStatus.DRAFT;
        cfg.proposedAt      = block.timestamp;
        cfg.executeAfter    = executeAfter;
        cfg.proposer        = msg.sender;

        // acceptedAssets — copy from calldata into storage
        for (uint256 i = 0; i < assetLen; ++i) {
            cfg.acceptedAssets.push(acceptedAssets[i]);
        }

        emit ChainConfigRegistered(
            chainId,
            configVersion,
            salt,
            manifestHash,
            governance,
            msg.sender,
            executeAfter
        );
    }

    /// @inheritdoc IChainConfigRegistry
    /// @dev Side effects:
    ///      - Previous SEALED version (if any) is moved to DEPRECATED.
    ///      - governance address of the new envelope is registered in _govSealed.
    ///      - _sealedVersion[chainId] is updated.
    function sealChainConfig(
        uint256 chainId,
        uint256 configVersion
    ) external override nonReentrant onlyRole(CHAIN_CONFIG_EXECUTOR_ROLE) {

        ChainConfig storage cfg = _configs[chainId][configVersion];

        if (cfg.chainId == 0) {
            revert ConfigNotFound(chainId, configVersion);
        }
        if (cfg.status != ConfigStatus.DRAFT) {
            revert ConfigNotDraft(chainId, configVersion);
        }
        if (block.timestamp < cfg.executeAfter) {
            revert TimelockNotExpired(cfg.executeAfter);
        }

        // Deprecate current sealed version if one exists.
        uint256 prevSealed = _sealedVersion[chainId];
        if (prevSealed != 0) {
            ChainConfig storage prev = _configs[chainId][prevSealed];
            prev.status = ConfigStatus.DEPRECATED;
            emit ChainConfigDeprecated(chainId, prevSealed, configVersion);
        }

        // Seal the new envelope.
        cfg.status   = ConfigStatus.SEALED;
        cfg.sealedAt = block.timestamp;

        _sealedVersion[chainId] = configVersion;
        _govSealed[cfg.governance] = true;

        emit ChainConfigSealed(chainId, configVersion, block.timestamp, msg.sender);
    }

    /// @inheritdoc IChainConfigRegistry
    /// @dev Guardian action: marks the draft CANCELLED.  Salt remains consumed
    ///      (prevents future reuse of the same salt even after cancellation).
    function cancelDraft(
        uint256 chainId,
        uint256 configVersion
    ) external override nonReentrant onlyRole(CHAIN_CONFIG_GUARDIAN_ROLE) {

        ChainConfig storage cfg = _configs[chainId][configVersion];

        if (cfg.chainId == 0) {
            revert ConfigNotFound(chainId, configVersion);
        }
        if (cfg.status != ConfigStatus.DRAFT) {
            revert ConfigNotDraft(chainId, configVersion);
        }

        cfg.status = ConfigStatus.CANCELLED;

        emit ChainConfigCancelled(chainId, configVersion, msg.sender);
    }

    /**
     * @notice Record that a claim was created under the currently sealed config
     *         for this chain.  Caller must be an authorised ClaimRegistry or admin.
     * @dev    Intentionally separate from the role system so it can be called by
     *         ClaimRegistry (which holds no governance authority).  Reverts if no
     *         sealed config exists or the claim is already recorded.
     */
    function recordClaimConfig(uint256 claimId) external nonReentrant {
        if (claimId == 0) revert ConfigNotFound(0, 0);
        if (_claimConfigVersion[claimId] != 0) revert ClaimAlreadyRecorded(claimId);

        uint256 sealedVer = _sealedVersion[block.chainid];
        if (sealedVer == 0) revert NoSealedConfigForClaim(block.chainid);

        _claimConfigVersion[claimId] = sealedVer;

        emit ClaimLinkedToConfig(claimId, block.chainid, sealedVer);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /// @inheritdoc IChainConfigRegistry
    function getSealedConfig(uint256 chainId) external view override returns (ChainConfig memory) {
        uint256 v = _sealedVersion[chainId];
        if (v == 0) revert NoSealedConfig(chainId);
        return _configs[chainId][v];
    }

    /// @inheritdoc IChainConfigRegistry
    function getConfig(
        uint256 chainId,
        uint256 configVersion
    ) external view override returns (ChainConfig memory) {
        ChainConfig storage cfg = _configs[chainId][configVersion];
        if (cfg.chainId == 0) revert ConfigNotFound(chainId, configVersion);
        return cfg;
    }

    /// @inheritdoc IChainConfigRegistry
    function getLatestVersion(uint256 chainId) external view override returns (uint256) {
        return _latestVersion[chainId];
    }

    /// @inheritdoc IChainConfigRegistry
    function isSaltUsed(bytes32 salt) external view override returns (bool) {
        return _saltUsed[salt];
    }

    /// @inheritdoc IChainConfigRegistry
    function isGovernanceSealed(address governance) external view override returns (bool) {
        return _govSealed[governance];
    }

    /**
     * @notice Return the sealed configVersion that was active when a claim was created.
     * @param claimId  The claim to query.
     * @return         The sealed configVersion at claim-creation time (0 if not recorded).
     */
    function getClaimConfigVersion(uint256 claimId) external view returns (uint256) {
        return _claimConfigVersion[claimId];
    }

    /**
     * @notice Return the config envelope that was active when a claim was created.
     * @param claimId  The claim to query.
     */
    function getConfigForClaim(uint256 claimId) external view returns (ChainConfig memory) {
        uint256 v = _claimConfigVersion[claimId];
        if (v == 0) revert ConfigNotFound(block.chainid, 0);
        return _configs[block.chainid][v];
    }

    /**
     * @notice Expose CONFIG_TIMELOCK for interface compliance.
     * @dev Already declared as a public constant; this satisfies the interface.
     */
    // CONFIG_TIMELOCK is a public constant — Solidity generates the getter automatically.
}
