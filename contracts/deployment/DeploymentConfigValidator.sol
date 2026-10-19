// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title DeploymentConfigValidator
/// @notice Canonical V2 deployment-configuration validation library.
/// @dev Validates the complete deployment configuration of the TruthBounty V2 suite before any
///      broadcast transaction is created. Deployment scripts MUST invoke {validate} before the
///      first `vm.startBroadcast()` / transaction so that malformed, dangerous, or placeholder
///      configuration is rejected off-chain and never reaches the network.
///
///      The validator is split into two stages:
///      - {validateStatic}: zero, duplicate, placeholder, wrong-chain, numeric-range, and
///        broadcaster-authorization checks. This stage never performs external calls.
///      - {validateRuntime}: legacy-denylist, EOA (code-size), and wrong-interface checks that
///        inspect on-chain state for pre-wired module addresses.
///
///      Validation fails closed: any invalid field reverts with a granular custom error naming
///      the offending field and value. Fields marked optional use the zero address as a
///      "deploy fresh" sentinel and are only subject to runtime checks when non-zero.
///
///      Security properties enforced:
///      - Zero     : identity-critical fields (deployer/admin/guardian) must be non-zero.
///      - Duplicate: every configured non-zero address must be distinct.
///      - EOA      : pre-wired module addresses must carry contract code.
///      - Wrong-chain: the configured chain id must equal the executing chain id.
///      - Wrong-interface: pre-wired module addresses must answer their canonical selector probe.
///      - Legacy   : configured addresses must not appear in the supplied legacy denylist.
///      - Placeholder: no well-known burn/placeholder address is accepted.
library DeploymentConfigValidator {
    // =====================================================================
    // Configuration model
    // =====================================================================

    /// @notice Complete canonical V2 deployment configuration.
    /// @dev Address fields marked "optional" accept address(0) as a deploy-fresh sentinel.
    ///      Numeric fields accept zero as an "use framework default" sentinel; any non-zero value
    ///      is validated against protocol bounds and internal consistency rules.
    struct Config {
        // -----------------------------------------------------------------
        // Identity / authorization (required)
        // -----------------------------------------------------------------
        /// @dev Expected broadcasting account. Zero disables the sender-authorization check
        ///      (intended for local/dev flows); when non-zero it MUST equal `msg.sender`.
        address deployer;
        /// @dev Canonical protocol admin (DEFAULT_ADMIN_ROLE holder). MUST be non-zero.
        address admin;
        /// @dev Governance guardian address. MUST be non-zero.
        address guardian;
        // -----------------------------------------------------------------
        // Optional pre-wired module addresses (zero = deploy fresh)
        // -----------------------------------------------------------------
        address governanceController;
        address governanceToken;
        address timelock;
        address governor;
        address moduleRegistry;
        address governanceGuardian;
        address reputationOracle;
        address token;
        // -----------------------------------------------------------------
        // Chain binding
        // -----------------------------------------------------------------
        /// @dev The chain id the operator intends to deploy on. MUST equal `block.chainid`.
        uint256 expectedChainId;
        // -----------------------------------------------------------------
        // Economic parameters (zero = framework default)
        // -----------------------------------------------------------------
        uint256 minStakeAmount;
        uint256 settlementThresholdPercent;
        uint256 rewardPercent;
        uint256 slashPercent;
        uint256 confirmationDelay;
        uint256 minReputationScore;
        uint256 maxReputationScore;
        uint256 defaultReputationScore;
        uint256 stakingLockDuration;
        // -----------------------------------------------------------------
        // Governance parameters (zero = framework default)
        // -----------------------------------------------------------------
        uint256 votingDelay;
        uint256 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumNumerator;
        uint256 timelockMinDelay;
        uint256 tokenSupply;
        // -----------------------------------------------------------------
        // Canonical verification parameters (zero = framework default)
        // -----------------------------------------------------------------
        uint256 minVerificationCount;
        uint256 minConfidenceBps;
        uint256 challengeWindowDuration;
        uint256 appealDuration;
        uint256 minAppealStake;
        uint256 appealMultiplierBps;
        uint256 maxWeightCap;
        // -----------------------------------------------------------------
        // Legacy / security denylist
        // -----------------------------------------------------------------
        /// @dev Addresses of known legacy V1 contracts that must never be wired as canonical
        ///      modules. Any configured module address present here is rejected.
        address[] legacyDenylist;
    }

    // =====================================================================
    // Errors
    // =====================================================================

    /// @notice A required identity field was set to the zero address.
    error ZeroAddress(string field);

    /// @notice Two configured fields resolve to the same address.
    error DuplicateAddress(string fieldA, string fieldB, address value);

    /// @notice An address is a well-known burn/placeholder address.
    error PlaceholderAddress(string field, address value);

    /// @notice A pre-wired module address has no contract code (plain EOA).
    error EOAAddress(string field, address value);

    /// @notice A pre-wired module address does not answer the required interface probe.
    error WrongInterface(string field, address value, bytes4 selector);

    /// @notice A configured address appears in the legacy V1 denylist.
    error LegacyAddress(string field, address value);

    /// @notice The configured chain id does not match the executing chain id.
    error WrongChainId(uint256 expectedChainId, uint256 actualChainId);

    /// @notice The expected broadcasting account does not match `msg.sender`.
    error UnauthorizedDeployer(address expectedDeployer, address actualSender);

    /// @notice A configured parameter is outside its safe bounds.
    error InvalidParameterRange(string field, uint256 value, uint256 min, uint256 max);

    // =====================================================================
    // Constants
    // =====================================================================

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant QUORUM_DENOMINATOR = 100;
    uint256 internal constant MAX_TIMELOCK_MIN_DELAY = 365 days;
    uint256 internal constant MAX_LOCK_DURATION = 365 days;
    uint256 internal constant MAX_TIMING_DURATION = 365 days;

    // =====================================================================
    // Public surface
    // =====================================================================

    /// @notice Validates a full deployment configuration, failing closed on any invalid field.
    /// @param config The deployment configuration to validate.
    /// @dev Runs every static and runtime check. Must be invoked before the first broadcast
    ///      transaction is created. Any non-zero optional module address must resolve to a
    ///      contract on the executing chain answering its canonical interface probe.
    function validate(Config memory config) internal view {
        validateStatic(config);
        validateRuntime(config);
    }

    /// @notice Validates configuration that requires no external state (zero, duplicate,
    ///         placeholder, wrong-chain, numeric bounds, broadcaster authorization).
    /// @param config The deployment configuration to validate.
    function validateStatic(Config memory config) internal view {
        _validateIdentity(config);
        _validatePlaceholders(config);
        _validateDuplicates(config);
        _validateChain(config);
        _validateParameters(config);
    }

    /// @notice Validates configuration that inspects on-chain state for pre-wired module
    ///         addresses (legacy denylist, EOA detection, interface probes).
    /// @param config The deployment configuration to validate.
    function validateRuntime(Config memory config) internal view {
        _validateLegacy(config);
        _validateModuleAddresses(config);
    }

    // =====================================================================
    // Static checks
    // =====================================================================

    function _validateIdentity(Config memory config) private view {
        if (config.admin == address(0)) revert ZeroAddress("admin");
        if (config.guardian == address(0)) revert ZeroAddress("guardian");
        if (config.deployer != address(0) && config.deployer != msg.sender) {
            revert UnauthorizedDeployer(config.deployer, msg.sender);
        }
    }

    function _validatePlaceholders(Config memory config) private pure {
        _checkNotPlaceholder("admin", config.admin);
        _checkNotPlaceholder("guardian", config.guardian);
        _checkNotPlaceholder("governanceController", config.governanceController);
        _checkNotPlaceholder("governanceToken", config.governanceToken);
        _checkNotPlaceholder("timelock", config.timelock);
        _checkNotPlaceholder("governor", config.governor);
        _checkNotPlaceholder("moduleRegistry", config.moduleRegistry);
        _checkNotPlaceholder("governanceGuardian", config.governanceGuardian);
        _checkNotPlaceholder("reputationOracle", config.reputationOracle);
        _checkNotPlaceholder("token", config.token);
    }

    function _validateDuplicates(Config memory config) private pure {
        _requireDistinct(config.admin, "admin", config.guardian, "guardian");
        _requireDistinctOptional(config.admin, "admin", config.governanceController, "governanceController");
        _requireDistinctOptional(config.admin, "admin", config.governanceToken, "governanceToken");
        _requireDistinctOptional(config.admin, "admin", config.timelock, "timelock");
        _requireDistinctOptional(config.admin, "admin", config.governor, "governor");
        _requireDistinctOptional(config.admin, "admin", config.moduleRegistry, "moduleRegistry");
        _requireDistinctOptional(config.admin, "admin", config.governanceGuardian, "governanceGuardian");
        _requireDistinctOptional(config.admin, "admin", config.reputationOracle, "reputationOracle");
        _requireDistinctOptional(config.admin, "admin", config.token, "token");

        _requireDistinct(config.guardian, "guardian", config.admin, "admin");
        _requireDistinctOptional(config.guardian, "guardian", config.governanceController, "governanceController");
        _requireDistinctOptional(config.guardian, "guardian", config.governanceToken, "governanceToken");
        _requireDistinctOptional(config.guardian, "guardian", config.timelock, "timelock");
        _requireDistinctOptional(config.guardian, "guardian", config.governor, "governor");
        _requireDistinctOptional(config.guardian, "guardian", config.moduleRegistry, "moduleRegistry");
        _requireDistinctOptional(config.guardian, "guardian", config.governanceGuardian, "governanceGuardian");
        _requireDistinctOptional(config.guardian, "guardian", config.reputationOracle, "reputationOracle");
        _requireDistinctOptional(config.guardian, "guardian", config.token, "token");

        _requireDistinctOptional(
            config.governanceController, "governanceController", config.governanceToken, "governanceToken"
        );
        _requireDistinctOptional(config.governanceController, "governanceController", config.timelock, "timelock");
        _requireDistinctOptional(config.governanceController, "governanceController", config.governor, "governor");
        _requireDistinctOptional(
            config.governanceController, "governanceController", config.moduleRegistry, "moduleRegistry"
        );
        _requireDistinctOptional(
            config.governanceController, "governanceController", config.governanceGuardian, "governanceGuardian"
        );
        _requireDistinctOptional(
            config.governanceController, "governanceController", config.reputationOracle, "reputationOracle"
        );
        _requireDistinctOptional(config.governanceController, "governanceController", config.token, "token");

        _requireDistinctOptional(config.governanceToken, "governanceToken", config.timelock, "timelock");
        _requireDistinctOptional(config.governanceToken, "governanceToken", config.governor, "governor");
        _requireDistinctOptional(config.governanceToken, "governanceToken", config.moduleRegistry, "moduleRegistry");
        _requireDistinctOptional(
            config.governanceToken, "governanceToken", config.governanceGuardian, "governanceGuardian"
        );
        _requireDistinctOptional(config.governanceToken, "governanceToken", config.reputationOracle, "reputationOracle");
        _requireDistinctOptional(config.governanceToken, "governanceToken", config.token, "token");

        _requireDistinctOptional(config.timelock, "timelock", config.governor, "governor");
        _requireDistinctOptional(config.timelock, "timelock", config.moduleRegistry, "moduleRegistry");
        _requireDistinctOptional(config.timelock, "timelock", config.governanceGuardian, "governanceGuardian");
        _requireDistinctOptional(config.timelock, "timelock", config.reputationOracle, "reputationOracle");
        _requireDistinctOptional(config.timelock, "timelock", config.token, "token");

        _requireDistinctOptional(config.governor, "governor", config.moduleRegistry, "moduleRegistry");
        _requireDistinctOptional(config.governor, "governor", config.governanceGuardian, "governanceGuardian");
        _requireDistinctOptional(config.governor, "governor", config.reputationOracle, "reputationOracle");
        _requireDistinctOptional(config.governor, "governor", config.token, "token");

        _requireDistinctOptional(
            config.moduleRegistry, "moduleRegistry", config.governanceGuardian, "governanceGuardian"
        );
        _requireDistinctOptional(config.moduleRegistry, "moduleRegistry", config.reputationOracle, "reputationOracle");
        _requireDistinctOptional(config.moduleRegistry, "moduleRegistry", config.token, "token");

        _requireDistinctOptional(
            config.governanceGuardian, "governanceGuardian", config.reputationOracle, "reputationOracle"
        );
        _requireDistinctOptional(config.governanceGuardian, "governanceGuardian", config.token, "token");

        _requireDistinctOptional(config.reputationOracle, "reputationOracle", config.token, "token");
    }

    function _validateChain(Config memory config) private view {
        if (config.expectedChainId == 0) revert InvalidParameterRange("expectedChainId", 0, 1, type(uint256).max);
        if (config.expectedChainId != block.chainid) {
            revert WrongChainId(config.expectedChainId, block.chainid);
        }
    }

    function _validateParameters(Config memory config) private pure {
        // Economic allocations
        _requireRange("minStakeAmount", config.minStakeAmount, 0, type(uint256).max, true);
        _requireRange("settlementThresholdPercent", config.settlementThresholdPercent, 1, 100, true);
        _requireRange("rewardPercent", config.rewardPercent, 1, 100, true);
        _requireRange("slashPercent", config.slashPercent, 1, 100, true);
        if (config.rewardPercent != 0 || config.slashPercent != 0) {
            uint256 totalAllocation = config.rewardPercent + config.slashPercent;
            if (totalAllocation > 100) {
                revert InvalidParameterRange("rewardPercent+slashPercent", totalAllocation, 1, 100);
            }
        }
        _requireRange("confirmationDelay", config.confirmationDelay, 1, MAX_TIMING_DURATION, true);
        _requireRange("stakingLockDuration", config.stakingLockDuration, 1, MAX_LOCK_DURATION, true);

        // Reputation bounds
        if (
            config.minReputationScore != 0 && config.maxReputationScore != 0
                && config.minReputationScore > config.maxReputationScore
        ) {
            revert InvalidParameterRange("minReputationScore", config.minReputationScore, 1, config.maxReputationScore);
        }
        if (config.defaultReputationScore != 0) {
            uint256 minScore =
                config.minReputationScore == 0 ? config.defaultReputationScore : config.minReputationScore;
            uint256 maxScore =
                config.maxReputationScore == 0 ? config.defaultReputationScore : config.maxReputationScore;
            if (config.defaultReputationScore < minScore || config.defaultReputationScore > maxScore) {
                revert InvalidParameterRange(
                    "defaultReputationScore", config.defaultReputationScore, minScore, maxScore
                );
            }
        }

        // Governance bounds (GovernorSettings uses uint48 delay, uint32 period)
        _requireRange("votingDelay", config.votingDelay, 0, type(uint48).max, true);
        _requireRange("votingPeriod", config.votingPeriod, 1, type(uint32).max, false);
        if (config.votingPeriod != 0 && config.votingDelay >= config.votingPeriod) {
            revert InvalidParameterRange("votingDelay", config.votingDelay, 0, config.votingPeriod - 1);
        }
        _requireRange("proposalThreshold", config.proposalThreshold, 0, type(uint256).max, true);
        _requireRange("quorumNumerator", config.quorumNumerator, 1, QUORUM_DENOMINATOR - 1, false);
        _requireRange("timelockMinDelay", config.timelockMinDelay, 0, MAX_TIMELOCK_MIN_DELAY, true);
        _requireRange("tokenSupply", config.tokenSupply, 1, type(uint256).max, false);

        // Canonical verification bounds
        _requireRange("minVerificationCount", config.minVerificationCount, 1, type(uint256).max, false);
        _requireRange("minConfidenceBps", config.minConfidenceBps, 0, MAX_BPS, true);
        _requireRange("challengeWindowDuration", config.challengeWindowDuration, 1, MAX_TIMING_DURATION, true);
        _requireRange("appealDuration", config.appealDuration, 1, MAX_TIMING_DURATION, true);
        _requireRange("minAppealStake", config.minAppealStake, 1, type(uint256).max, true);
        _requireRange("appealMultiplierBps", config.appealMultiplierBps, 1, MAX_BPS * 10, true);
        _requireRange("maxWeightCap", config.maxWeightCap, 1, type(uint256).max, true);
    }

    // =====================================================================
    // Runtime checks
    // =====================================================================

    function _validateLegacy(Config memory config) private pure {
        uint256 denylistLength = config.legacyDenylist.length;
        if (denylistLength == 0) return;
        for (uint256 i = 0; i < denylistLength; ++i) {
            address legacy = config.legacyDenylist[i];
            _checkNotLegacy("governanceController", config.governanceController, legacy);
            _checkNotLegacy("governanceToken", config.governanceToken, legacy);
            _checkNotLegacy("timelock", config.timelock, legacy);
            _checkNotLegacy("governor", config.governor, legacy);
            _checkNotLegacy("moduleRegistry", config.moduleRegistry, legacy);
            _checkNotLegacy("governanceGuardian", config.governanceGuardian, legacy);
            _checkNotLegacy("reputationOracle", config.reputationOracle, legacy);
            _checkNotLegacy("token", config.token, legacy);
        }
    }

    function _validateModuleAddresses(Config memory config) private view {
        _requireModule(config.governanceController, "governanceController", bytes4(0x54fd4d50)); // version()
        _requireModule(config.governanceToken, "governanceToken", bytes4(0x18160ddd)); // totalSupply()
        _requireModule(config.timelock, "timelock", bytes4(0xf27a0c92)); // getMinDelay()
        _requireModule(config.governor, "governor", bytes4(0xb58131b0)); // proposalThreshold()
        _requireModule(config.moduleRegistry, "moduleRegistry", bytes4(0x334f7ac5)); // moduleCount()
        _requireModule(config.governanceGuardian, "governanceGuardian", bytes4(0x0c340a24)); // governor()
        _requireModule(config.reputationOracle, "reputationOracle", bytes4(0x22f3e2d4)); // isActive()
        _requireModule(config.token, "token", bytes4(0x18160ddd)); // totalSupply()
    }

    // =====================================================================
    // Internal helpers
    // =====================================================================

    function _checkNotPlaceholder(string memory field, address value) private pure {
        if (value == address(0)) return; // sentinel handled by callers
        // Leading "1".."9" sentinels and canonical burn/placeholder addresses.
        if (
            value == address(uint160(1)) || value == address(uint160(2)) || value == address(uint160(3))
                || value == address(uint160(4)) || value == address(uint160(5)) || value == address(uint160(6))
                || value == address(uint160(7)) || value == address(uint160(8)) || value == address(uint160(9))
        ) {
            revert PlaceholderAddress(field, value);
        }
        if (value == address(uint160(0xDEAD))) revert PlaceholderAddress(field, value);
        if (value == address(uint160(0xdEADBEeF00000000000000000000000000000000))) {
            revert PlaceholderAddress(field, value);
        }
        if (value == address(uint160(0x1111111111111111111111111111111111111111))) {
            revert PlaceholderAddress(field, value);
        }
        if (value == address(uint160(0x2222222222222222222222222222222222222222))) {
            revert PlaceholderAddress(field, value);
        }
        if (value == address(uint160(0x3333333333333333333333333333333333333333))) {
            revert PlaceholderAddress(field, value);
        }
        if (value == address(uint160(0x4444444444444444444444444444444444444444))) {
            revert PlaceholderAddress(field, value);
        }
        if (value == address(uint160(0x5555555555555555555555555555555555555555))) {
            revert PlaceholderAddress(field, value);
        }
        if (value == address(uint160(type(uint160).max))) {
            revert PlaceholderAddress(field, value);
        }
    }

    function _requireDistinct(address a, string memory fieldA, address b, string memory fieldB) private pure {
        if (a == b) revert DuplicateAddress(fieldA, fieldB, a);
        _requireDistinctOptional(a, fieldA, b, fieldB);
    }

    function _requireDistinctOptional(address a, string memory fieldA, address b, string memory fieldB) private pure {
        if (a != address(0) && a == b) revert DuplicateAddress(fieldA, fieldB, a);
    }

    function _requireRange(string memory field, uint256 value, uint256 min, uint256 max, bool allowZero) private pure {
        if (value == 0 && allowZero) return; // zero sentinel permitted
        if (value < min || value > max) revert InvalidParameterRange(field, value, min, max);
    }

    function _checkNotLegacy(string memory field, address value, address legacy) private pure {
        if (value != address(0) && value == legacy) revert LegacyAddress(field, value);
    }

    function _requireModule(address target, string memory field, bytes4 selector) private view {
        if (target == address(0)) return; // deploy-fresh sentinel
        if (target.code.length == 0) revert EOAAddress(field, target);
        (bool ok, bytes memory returndata) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || returndata.length < 32) revert WrongInterface(field, target, selector);
    }
}
