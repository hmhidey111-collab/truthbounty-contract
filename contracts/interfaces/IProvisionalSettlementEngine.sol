// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./IClaimRegistry.sol";
import "../VerificationAggregator.sol";

/**
 * @title IProvisionalSettlementEngine
 * @notice Interface for the TruthBounty V2 Provisional Settlement Engine (SC-015).
 * @dev Manages permissionless post-verification consensus aggregation, provisional outcome
 *      recording, challenge window initiation, and fund lock enforcement.
 */
interface IProvisionalSettlementEngine {

    // =========================================================================
    // Enums & Structs
    // =========================================================================

    enum Outcome {
        UNRESOLVED,
        VERIFIED_TRUE,
        VERIFIED_FALSE,
        INCONCLUSIVE
    }

    /**
     * @notice Terminal settlement states for a claim round.
     * @dev Every round settles at most once; the terminal marker is written before any
     *      external payout/refund/slash call so retries cannot repeat state effects.
     */
    enum TerminalOutcome {
        NONE,
        ACCEPTED,
        REJECTED,
        TIE,
        REFUND,
        SLASHED,
        EXPIRED,
        APPEALED
    }

    struct ProvisionalOutcome {
        Outcome outcome;
        uint256 confidence;         // in basis points (0 - 10000)
        uint256 trueWeight;
        uint256 falseWeight;
        uint256 totalWeight;
        uint256 verifierCount;
        uint256 challengeDeadline;  // block.timestamp + challengeWindowDuration
        uint256 settledAt;          // timestamp when provisional settlement occurred
        uint256 parameterVersion;   // governance parameter version active at settlement
        bool settled;
    }

    /**
     * @notice Idempotent settlement marker for a claim round.
     * @dev `terminalOutcome` is set (marker precedes unsafe calls) before any external
     *      payout/refund/slash. `effectsApplied` gates state effects; `payoutSettled`
     *      gates the external transfer so a failed payout stays retryable without
     *      repeating state effects.
     */
    struct SettlementMarker {
        TerminalOutcome terminalOutcome;
        uint256 settledAt;
        uint256 parameterVersion;
        bool effectsApplied;
        bool payoutSettled;
        bytes32 effectHash;
    }

    // =========================================================================
    // Events
    // =========================================================================

    event RoundAggregated(
        uint256 indexed claimId,
        Outcome outcome,
        uint256 confidence,
        uint256 trueWeight,
        uint256 falseWeight,
        uint256 totalWeight,
        uint256 verifierCount
    );

    event ProvisionalOutcomeCreated(
        uint256 indexed claimId,
        Outcome outcome,
        uint256 challengeDeadline,
        uint256 confidence,
        address indexed triggeredBy
    );

    event ChallengeWindowDurationUpdated(
        uint256 oldDuration,
        uint256 newDuration
    );

    event AggregatorUpdated(
        address indexed oldAggregator,
        address indexed newAggregator
    );

    event ParameterVersionUpdated(
        uint256 oldVersion,
        uint256 newVersion
    );

    event SettlementMarked(
        uint256 indexed claimId,
        TerminalOutcome terminalOutcome,
        bytes32 effectHash,
        uint256 parameterVersion,
        address indexed triggeredBy
    );

    event SettlementEffectsApplied(
        uint256 indexed claimId,
        TerminalOutcome terminalOutcome,
        bytes32 effectHash
    );

    event SettlementPayoutCompleted(
        uint256 indexed claimId,
        TerminalOutcome terminalOutcome,
        address indexed recipient,
        uint256 amount
    );

    event SettlementPayoutFailed(
        uint256 indexed claimId,
        TerminalOutcome terminalOutcome,
        address indexed recipient,
        uint256 amount
    );

    event SettlementRetried(
        uint256 indexed claimId,
        TerminalOutcome terminalOutcome,
        address indexed caller
    );

    // =========================================================================
    // External Functions
    // =========================================================================

    /**
     * @notice Permissionlessly execute provisional settlement for an expired verification round.
     * @param claimId The unique ID of the claim to settle.
     * @return outcome The stored provisional outcome record.
     */
    function provisionalSettle(uint256 claimId) external returns (ProvisionalOutcome memory outcome);

    /**
     * @notice Read the provisional outcome for a given claim.
     * @param claimId The unique ID of the claim.
     */
    function getProvisionalOutcome(uint256 claimId) external view returns (ProvisionalOutcome memory);

    /**
     * @notice Check whether a claim has already undergone provisional settlement.
     * @param claimId The unique ID of the claim.
     */
    function isProvisionalSettled(uint256 claimId) external view returns (bool);

    /**
     * @notice Check whether the dispute challenge window is currently active for a claim.
     * @param claimId The unique ID of the claim.
     */
    function isChallengeWindowOpen(uint256 claimId) external view returns (bool);

    /**
     * @notice Permissionlessly settle a claim round into a terminal outcome.
     * @dev Idempotent: reverts if the round already has a terminal marker. The marker
     *      is written before any external payout/refund/slash call.
     * @param claimId The unique ID of the claim to settle.
     * @param terminalOutcome The terminal outcome to record.
     * @return marker The stored settlement marker.
     */
    function settleTerminal(uint256 claimId, TerminalOutcome terminalOutcome)
        external
        returns (SettlementMarker memory marker);

    /**
     * @notice Retry a failed external payout without repeating state effects.
     * @dev Requires an existing terminal marker with effects applied but payout not settled.
     * @param claimId The unique ID of the claim to retry.
     */
    function retrySettlementPayout(uint256 claimId) external;

    /**
     * @notice Read the settlement marker for a given claim.
     * @param claimId The unique ID of the claim.
     */
    function getSettlementMarker(uint256 claimId) external view returns (SettlementMarker memory);

    /**
     * @notice Check whether a claim round has a terminal settlement marker.
     * @param claimId The unique ID of the claim.
     */
    function isTerminallySettled(uint256 claimId) external view returns (bool);

    /**
     * @notice Check whether a claim round's external payout has completed.
     * @param claimId The unique ID of the claim.
     */
    function isPayoutSettled(uint256 claimId) external view returns (bool);

    /**
     * @notice Deterministic effect hash for exact replay of a settlement.
     * @param claimId The unique ID of the claim.
     */
    function settlementEffectHash(uint256 claimId) external view returns (bytes32);

    /**
     * @notice Current challenge window duration in seconds.
     */
    function challengeWindowDuration() external view returns (uint256);

    /**
     * @notice Active governance parameter version.
     */
    function parameterVersion() external view returns (uint256);
}
