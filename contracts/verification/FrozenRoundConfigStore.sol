// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ParticipationThresholdTypes} from "./ParticipationThresholdTypes.sol";
import {ParticipationConfidenceRules} from "./ParticipationConfidenceRules.sol";

/**
 * @title FrozenRoundConfigStore
 * @notice Stores immutable threshold configuration and challenge deadline per
 *         claim round (V2-SC-004 consumer).
 *
 * @dev Once frozen, governance updates cannot affect an open round's thresholds.
 *
 *      PREWAVE-SC-046 (#722): challengeDeadline is stored here at freeze time
 *      alongside the threshold config. ParticipationThresholdEngine.finalizeRound()
 *      reads it from this store -- the deadline is never accepted from the caller,
 *      eliminating the attack surface where passing 0 allowed immediate finalization.
 */
contract FrozenRoundConfigStore is AccessControl {
    bytes32 public constant CONFIG_ADMIN_ROLE = keccak256("CONFIG_ADMIN_ROLE");

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    mapping(bytes32 => ParticipationThresholdTypes.FrozenRoundConfig) private _configs;
    mapping(bytes32 => bool)     private _frozen;
    /// @notice Frozen challenge deadline per roundId. Set once at freeze time.
    mapping(bytes32 => uint64)   private _challengeDeadlines;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event RoundConfigFrozen(
        bytes32 indexed roundId,
        uint256 indexed claimId,
        ParticipationThresholdTypes.RoundKind roundKind,
        uint256 configVersion,
        uint256 minVerifierCount,
        uint256 minTotalWeight,
        uint256 minConfidenceBps,
        uint256 appealMultiplierBps
    );

    /// @notice Emitted when a round config is frozen including its challenge deadline.
    event RoundConfigFrozenWithDeadline(
        bytes32 indexed roundId,
        uint256 indexed claimId,
        ParticipationThresholdTypes.RoundKind roundKind,
        uint64 challengeDeadline
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error RoundAlreadyFrozen(bytes32 roundId);
    error RoundNotFrozen(bytes32 roundId);
    error InvalidChallengeDeadline(uint64 deadline);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ADMIN_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Core functions
    // -------------------------------------------------------------------------

    function roundId(uint256 claimId, ParticipationThresholdTypes.RoundKind roundKind)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(claimId, roundKind));
    }

    /**
     * @notice Freeze threshold config (legacy path -- deadline defaults to 0).
     * @dev Preserved for backward compatibility with existing consumers.
     *      New callers should use freezeRoundConfigWithDeadline().
     */
    function freezeRoundConfig(
        uint256 claimId,
        ParticipationThresholdTypes.RoundKind roundKind,
        ParticipationThresholdTypes.FrozenRoundConfig calldata config
    ) external onlyRole(CONFIG_ADMIN_ROLE) {
        _freeze(claimId, roundKind, config, 0);
    }

    /**
     * @notice Freeze threshold config with an authoritative challenge deadline.
     * @dev The deadline is stored on-chain and read by finalizeRound() --
     *      the caller of finalizeRound() cannot supply or shorten it.
     * @param claimId            The claim this round belongs to.
     * @param roundKind          FIRST or APPEAL.
     * @param config             Threshold config to freeze.
     * @param challengeDeadline  Unix timestamp after which the challenge window
     *                           is considered elapsed. Must be > block.timestamp.
     */
    function freezeRoundConfigWithDeadline(
        uint256 claimId,
        ParticipationThresholdTypes.RoundKind roundKind,
        ParticipationThresholdTypes.FrozenRoundConfig calldata config,
        uint64 challengeDeadline
    ) external onlyRole(CONFIG_ADMIN_ROLE) {
        if (challengeDeadline <= uint64(block.timestamp)) {
            revert InvalidChallengeDeadline(challengeDeadline);
        }
        _freeze(claimId, roundKind, config, challengeDeadline);
    }

    function _freeze(
        uint256 claimId,
        ParticipationThresholdTypes.RoundKind roundKind,
        ParticipationThresholdTypes.FrozenRoundConfig calldata config,
        uint64 challengeDeadline
    ) internal {
        ParticipationConfidenceRules.validateConfig(config);

        bytes32 id = roundId(claimId, roundKind);
        if (_frozen[id]) revert RoundAlreadyFrozen(id);

        _configs[id] = config;
        _frozen[id] = true;
        _challengeDeadlines[id] = challengeDeadline;

        emit RoundConfigFrozen(
            id, claimId, roundKind,
            config.configVersion,
            config.minVerifierCount,
            config.minTotalWeight,
            config.minConfidenceBps,
            config.appealMultiplierBps
        );

        if (challengeDeadline > 0) {
            emit RoundConfigFrozenWithDeadline(id, claimId, roundKind, challengeDeadline);
        }
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    function getFrozenConfig(bytes32 id)
        external
        view
        returns (ParticipationThresholdTypes.FrozenRoundConfig memory)
    {
        if (!_frozen[id]) revert RoundNotFrozen(id);
        return _configs[id];
    }

    /**
     * @notice Return the frozen challenge deadline for a round.
     * @dev Returns 0 for rounds frozen via the legacy freezeRoundConfig() path.
     *      ParticipationThresholdEngine treats deadline==0 as "no deadline set,
     *      finalization permitted immediately".
     */
    function getChallengeDeadline(bytes32 id) external view returns (uint64) {
        if (!_frozen[id]) revert RoundNotFrozen(id);
        return _challengeDeadlines[id];
    }

    function isRoundFrozen(bytes32 id) external view returns (bool) {
        return _frozen[id];
    }
}
