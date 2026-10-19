// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ICreate2AddressPlanner} from "./ICreate2AddressPlanner.sol";

/**
 * @title Create2AddressPlanner
 * @notice Deterministic CREATE2 address planning for TruthBounty V2 modules/implementations.
 * @dev Collision-safe: domain-separates reviewed salts by module id, rejects salt reuse,
 *      address reuse, and targets that already contain code. Registration is gated on
 *      bytecode verification and on-chain deployment confirmation. Optimism/EVM only —
 *      no Stellar/Soroban/Freighter dependencies; fail-closed on invalid inputs.
 *
 * Additionally binds deployment configuration to chain ID, release ID, configuration
 * checksum, broadcaster, nonce plan, and expiry before broadcast. Rejects reused or
 * wrong-environment configuration.
 */
contract Create2AddressPlanner is ICreate2AddressPlanner, AccessControl {
    /// @notice EIP-170 runtime-code ceiling; oversized verification input is rejected before hashing.
    uint256 public constant MAX_RUNTIME_BYTECODE_BYTES = 24_576;
    /// @notice Role permitted to plan addresses and verify bytecode.
    bytes32 public constant PLANNER_ROLE = keccak256("PLANNER_ROLE");
    /// @notice Role permitted to authorize broadcasters and configuration bindings.
    bytes32 public constant CONFIGURATION_ROLE = keccak256("CONFIGURATION_ROLE");
    /// @notice Maximum acceptable configuration lifetime to bound expiry skew.
    uint256 public constant MAX_CONFIG_LIFETIME = 30_000;

    mapping(bytes32 => Plan) private _plans;
    mapping(address => bytes32) private _moduleByPredicted;
    mapping(bytes32 => bool) private _saltUsed;

    /// @notice Chain ID bound at construction time; all configuration must match.
    uint256 public immutable boundChainId;
    /// @notice Release ID bound at construction time; prevents cross-release replay.
    bytes32 public immutable boundReleaseId;
    /// @notice Authorized broadcaster address bound at construction time.
    address public immutable boundBroadcaster;

    /// @notice Configuration bindings per module, set before broadcast.
    mapping(bytes32 => ConfigBinding) private _configBindings;
    /// @notice Checksum replay guard: checksum => consumed.
    mapping(bytes32 => bool) private _checksumUsed;
    /// @notice Nonce plan replay guard: nonce key => consumed.
    mapping(bytes32 => bool) private _nonceKeyUsed;

    /**
     * @param admin Account granted DEFAULT_ADMIN_ROLE, PLANNER_ROLE, and CONFIGURATION_ROLE.
     * @param chainId Chain ID this planner is bound to.
     * @param releaseId Release ID this planner is bound to.
     * @param broadcaster Authorized broadcaster address.
     */
    constructor(address admin, uint256 chainId, bytes32 releaseId, address broadcaster) {
        if (admin == address(0)) revert ZeroAddress();
        if (chainId == 0) revert ZeroChainId();
        if (releaseId == bytes32(0)) revert ZeroReleaseId();
        if (broadcaster == address(0)) revert ZeroBroadcaster();

        boundChainId = chainId;
        boundReleaseId = releaseId;
        boundBroadcaster = broadcaster;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PLANNER_ROLE, admin);
        _grantRole(CONFIGURATION_ROLE, admin);
    }

    /// @inheritdoc ICreate2AddressPlanner
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash)
        public
        pure
        returns (address predicted)
    {
        bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash));
        predicted = address(uint160(uint256(digest)));
    }

    /// @inheritdoc ICreate2AddressPlanner
    function deriveSalt(bytes32 moduleId, bytes32 reviewedSalt) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(moduleId, reviewedSalt));
    }

    /**
     * @notice Bind deployment configuration to chain, release, checksum, broadcaster,
     *         nonce plan, and expiry. Must be called before broadcast.
     * @param moduleId Module identifier.
     * @param chainId Chain ID of the deployment environment.
     * @param releaseId Release ID of the deployment.
     * @param configChecksum Deterministic checksum of the configuration artifact.
     * @param broadcaster Address authorized to broadcast the deployment.
     * @param nonce Explicit nonce for the deployment transaction.
     * @param expiry Unix timestamp after which the configuration is invalid.
     */
    function bindConfiguration(
        bytes32 moduleId,
        uint256 chainId,
        bytes32 releaseId,
        bytes32 configChecksum,
        address broadcaster,
        uint256 nonce,
        uint256 expiry
    ) external onlyRole(CONFIGURATION_ROLE) {
        if (moduleId == bytes32(0)) revert ZeroModuleId();
        if (chainId != boundChainId) revert WrongChainId(boundChainId, chainId);
        if (releaseId != boundReleaseId) revert StaleReleaseId(boundReleaseId, releaseId);
        if (configChecksum == bytes32(0)) revert ZeroConfigChecksum();
        if (broadcaster == address(0)) revert ZeroBroadcaster();
        if (broadcaster != boundBroadcaster) revert UnauthorizedBroadcaster(boundBroadcaster, broadcaster);
        if (expiry <= block.timestamp) revert ConfigExpired(expiry, block.timestamp);
        if (expiry - block.timestamp > MAX_CONFIG_LIFETIME) {
            revert ConfigLifetimeTooLong(mxpiry - block.timestamp, MAX_CONFIG_LIFETIME);
        }

        // Reject reused configuration across chain/release.
        bytes32 configKey = keccak256(abi.encodePacked(chainId, releaseId, configChecksum));
        if (_checksumUsed[configKey]) revert ConfigChecksumReused(configChecksum);

        // Explicit nonce plan replay guard.
        bytes32 nonceKey = keccak256(abi.encodePacked(chainId, releaseId, broadcaster, nonce));
        if (_nonceKeyUsed[nonceKey]) revert NoncePlanAlreadyUsed(nonceKey);

        ConfigBinding storage binding = _configBindings[moduleId];
        if (binding.bound) revert ConfigAlreadyBound(moduleId);

        _checksumUsed[configKey] = true;
        _nonceKeyUsed[nonceKey] = true;

        _configBindings[moduleId] = ConfigBinding({
            chainId: chainId,
            releaseId: releaseId,
            configChecksum: configChecksum,
            broadcaster: broadcaster,
            nonce: nonce,
            expiry: expiry,
            bound: true
        });

        emit ConfigBound(moduleId, chainId, releaseId, configChecksum, broadcaster, nonce, expiry);
    }

    /// @inheritdoc ICreate2AddressPlanner
    function planAddress(
        bytes32 moduleId,
        bytes32 reviewedSalt,
        bytes32 initCodeHash,
        address deployer
    ) external onlyRole(PLANNER_ROLE) returns (address predicted) {
        if (moduleId == bytes32(0)) revert ZeroModuleId();
        if (reviewedSalt == bytes32(0)) revert ZeroSalt();
        if (initCodeHash == bytes32(0)) revert ZeroInitCodeHash();
        if (deployer == address(0)) revert ZeroDeployer();

        // Enforce configuration binding before any planning/broadcast can occur.
        ConfigBinding storage binding = _configBindings[moduleId];
        if (!binding.bound) revert ConfigNotBound(moduleId);
        if (binding.expiry <= block.timestamp) revert ConfigExpired(binding.expiry, block.timestamp);
        if (binding.chainId != boundChainId) revert WrongChainId(boundChainId, binding.chainId);
        if (binding.releaseId != boundReleaseId) revert StaleReleaseId(boundReleaseId, binding.releaseId);
        if (binding.broadcaster != boundBroadcaster) {
            revert UnauthorizedBroadcaster(boundBroadcaster, binding.broadcaster);
        }

        Plan storage existing = _plans[moduleId];
        if (existing.reserved) revert PlanAlreadyExists(moduleId);

        bytes32 salt = deriveSalt(moduleId, reviewedSalt);
        if (_saltUsed[salt]) revert SaltAlreadyUsed(salt);

        predicted = computeAddress(deployer, salt, initCodeHash);
        if (predicted == address(0)) revert ZeroAddress();

        bytes32 occupant = _moduleByPredicted[predicted];
        if (occupant != bytes32(0)) revert AddressCollision(predicted, occupant);

        if (predicted.code.length > 0) revert TargetAlreadyHasCode(predicted);

        _saltUsed[salt] = true;
        _moduleByPredicted[predicted] = moduleId;

        _plans[moduleId] = Plan({
            moduleId: moduleId,
            reviewedSalt: reviewedSalt,
            derivedSalt: salt,
            initCodeHash: initCodeHash,
            runtimeCodeHash: bytes32(0),
            deployer: deployer,
            predicted: predicted,
            reserved: true,
            bytecodeVerified: false,
            deploymentConfirmed: false
        });

        emit AddressPlanned(moduleId, predicted, deployer, salt, initCodeHash);
    }

    /// @inheritdoc ICreate2AddressPlanner
    function setExpectedRuntimeCodeHash(bytes32 moduleId, bytes32 runtimeCodeHash)
        external
        onlyRole(PLANNER_ROLE)
    {
        if (runtimeCodeHash == bytes32(0)) revert ZeroInitCodeHash();
        Plan storage plan = _requirePlan(moduleId);
        if (plan.bytecodeVerified && plan.runtimeCodeHash != runtimeCodeHash) {
            revert BytecodeHashMismatch(plan.runtimeCodeHash, runtimeCodeHash);
        }
        plan.runtimeCodeHash = runtimeCodeHash;
        plan.bytecodeVerified = false;
        plan.deploymentConfirmed = false;
    }

    /// @inheritdoc ICreate2AddressPlanner
    function verifyBytecode(bytes32 moduleId, bytes calldata runtimeBytecode)
        external
        onlyRole(PLANNER_ROLE)
    {
        if (runtimeBytecode.length > MAX_RUNTIME_BYTECODE_BYTES) {
            revert RuntimeBytecodeTooLarge(runtimeBytecode.length, MAX_RUNTIME_BYTECODE_BYTES);
        }
        if (runtimeBytecode.length == 0) revert BytecodeHashMismatch(bytes32(0), bytes32(0));

        Plan storage plan = _requirePlan(moduleId);
        bytes32 actual = keccak256(runtimeBytecode);

        if (plan.runtimeCodeHash == bytes32(0)) {
            plan.runtimeCodeHash = actual;
        } else if (plan.runtimeCodeHash != actual) {
            revert BytecodeHashMismatch(plan.runtimeCodeHash, actual);
        }

        plan.bytecodeVerified = true;
        plan.deploymentConfirmed = false;

        emit BytecodeVerified(moduleId, plan.predicted, actual);
    }

    /// @inheritdoc ICreate2AddressPlanner
    function confirmDeployment(bytes32 moduleId) external returns (bool) {
        Plan storage plan = _requirePlan(moduleId);
        if (!plan.bytecodeVerified) revert BytecodeNotVerified(moduleId);

        address predicted = plan.predicted;
        bytes32 liveHash;
        assembly ("memory-safe") {
            liveHash := extcodehash(predicted)
        }
        if (liveHash == bytes32(0) || liveHash == keccak256("")) {
            revert DeploymentCodeMissing(predicted);
        }
        if (liveHash != plan.runtimeCodeHash) {
            revert BytecodeHashMismatch(plan.runtimeCodeHash, liveHash);
        }

        plan.deploymentConfirmed = true;
        emit DeploymentConfirmed(moduleId, predicted);
        return true;
    }

    /// @inheritdoc ICreate2AddressPlanner
    function isReadyForRegistration(bytes32 moduleId) external view returns (bool) {
        Plan storage plan = _plans[moduleId];
        ConfigBinding storage binding = _configBindings[moduleId];
        return binding.bound
            && binding.expiry > block.timestamp
            && binding.chainId == boundChainId
            && binding.releaseId == boundReleaseId
            && binding.broadcaster == boundBroadcaster
            && plan.reserved
            && plan.bytecodeVerified
            && plan.deploymentConfirmed;
    }

    /// @inheritdoc ICreate2AddressPlanner
    function getPlan(bytes32 moduleId) external view returns (Plan memory) {
        return _plans[moduleId];
    }

    /// @inheritdoc ICreate2AddressPlanner
    function getConfigBinding(bytes32 moduleId) external view returns (ConfigBinding memory) {
        return _configBindings[moduleId];
    }

    /// @inheritdoc ICreate2AddressPlanner
    function clearPlan(bytes32 moduleId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Plan storage plan = _requirePlan(moduleId);
        address predicted = plan.predicted;
        bytes32 salt = plan.derivedSalt;

        delete _moduleByPredicted[predicted];
        delete _saltUsed[salt];
        delete _plans[moduleId];

        emit PlanCleared(moduleId, predicted);
    }

    function _requirePlan(bytes32 moduleId) private returns (Plan storage plan) {
        plan = _plans[moduleId];
        if (!plan.reserved) revert PlanNotFound(moduleId);
    }
}