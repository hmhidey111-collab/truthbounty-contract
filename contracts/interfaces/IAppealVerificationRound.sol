// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../VerificationAggregator.sol";
import "./ISTakeVault.sol";

/**
 * @title IAppealVerificationRound
 * @notice Interface for the TruthBounty V2 Appeal Verification Round Manager (SC-017).
 * @dev Manages the opening, voting, custody, isolation, closing, and irreversible
 *      finalization of the bounded appeal-round ladder for disputed claims
 *      (V2-SC-059 bound appeal rounds and prevent griefing).
 *
 * Security properties:
 *   - The appeal ladder is STRICTLY BOUNDED: at most `maxAppealRounds` rounds per
 *     claim (default 1, matching the V2-SC-018 single-appeal rule), after which the
 *     path is irreversibly terminal (`AppealPathFinalized`). No account — including
 *     governance — can extend or reopen a finalized path.
 *   - Every appeal round is BOND-GATED: the opener must post an escalating bond in
 *     vaulted custody ({ISTakeVault.lockBond}). The bond amount is computed by the
 *     module (the caller cannot under-bond) and is strictly capped by `maxAppealBond`.
 *   - Processing is BOUNDED: a round admits at most `maxVotersPerRound` voters so
 *     downstream aggregation is O(n) with n capped.
 *   - Terminality: once an appeal path is finalized via {finalizeAppealRound} (or the
 *     final round is closed), it can never be reopened. Claim-state finalization is
 *     V2-SC-018's responsibility; this module only emits the terminal signal and
 *     records the vault lock for SC-018 bond disposition.
 */
interface IAppealVerificationRound is IVerificationSource {

    // =========================================================================
    // Enums & Structs
    // =========================================================================

    enum AppealRoundStatus {
        NONE,
        OPEN,
        CLOSED,
        RESOLVED
    }

    struct AppealVote {
        bool voted;
        bool support;
        uint256 stakeAmount;
        uint256 effectiveStake;
        uint256 timestamp;
    }

    struct AppealRoundConfig {
        uint256 roundDuration;            // e.g. 3 days
        uint256 minStakeAmount;           // higher minimum stake for appeal
        uint256 stakeMultiplierBps;       // e.g. 15000 = 1.5x
        uint256 maxWeightCap;             // maximum weight cap per verifier
        uint256 parameterVersion;
        uint256 maxAppealRounds;          // ladder cap (1..MAX_APPEAL_ROUNDS), default 1
        uint256 appealBond;               // base bond posted by the opener of round 1
        uint256 appealBondEscalationBps;  // per-round escalation (10000..MAX, e.g. 15000 = +50%/round)
        uint256 maxAppealBond;            // hard cap on any single round bond
        uint256 maxVotersPerRound;        // bounded-processing cap (1..MAX_VOTERS_PER_ROUND)
    }

    struct BoundAppealParams {
        uint256 claimId;
        uint256 parentDisputeId;
        uint8 parentOutcome;
        uint256 roundIndex;
        address appellant;
        address bondPayer;
        address bondBeneficiary;
    }

    struct AppealRound {
        uint256 claimId;
        AppealRoundStatus status;
        uint256 openedAt;
        uint256 deadline;
        uint256 minStakeAmount;
        uint256 stakeMultiplierBps;
        uint256 maxWeightCap;
        uint256 totalTrueStake;
        uint256 totalFalseStake;
        uint256 totalTrueWeight;
        uint256 totalFalseWeight;
        uint256 verifierCount;
        uint256 roundIndex;      // 1-based position within the per-claim ladder
        uint256 maxRounds;       // ladder cap frozen at open
        uint256 requiredBond;    // bond posted by the opener (vaulted)
        uint256 bondLockId;      // unique {ISTakeVault} lock id for this round
        uint256 maxVoters;       // voter cap frozen at open
        uint256 parentDisputeId; // bound parent dispute ID (0 if unbounded legacy open)
        uint8 parentOutcome;     // bound parent dispute outcome
        address appellant;       // authorized appellant
        address bondPayer;       // party supplying the bond
        address bondBeneficiary; // recipient upon refund/disposition
    }

    // =========================================================================
    // Events
    // =========================================================================

    event AppealRoundOpened(
        uint256 indexed claimId,
        uint256 deadline,
        uint256 minStake,
        uint256 multiplierBps,
        address indexed openedBy,
        uint256 roundIndex,
        uint256 maxRounds,
        uint256 requiredBond,
        uint256 bondLockId
    );

    event AppealVoteSubmitted(
        uint256 indexed claimId,
        address indexed verifier,
        bool support,
        uint256 stakeAmount,
        uint256 effectiveWeight
    );

    event AppealRoundClosed(
        uint256 indexed claimId,
        uint256 totalTrueWeight,
        uint256 totalFalseWeight,
        uint256 verifierCount,
        address indexed closedBy,
        uint256 roundIndex
    );

    /// @notice Emitted when a claim's appeal path becomes irreversibly terminal.
    event AppealPathFinalized(
        uint256 indexed claimId,
        uint256 roundIndex,
        uint256 totalTrueWeight,
        uint256 totalFalseWeight,
        uint256 verifierCount
    );

    event DefaultAppealConfigUpdated(
        uint256 duration,
        uint256 minStake,
        uint256 multiplierBps,
        uint256 maxWeightCap,
        uint256 maxAppealRounds,
        uint256 appealBond,
        uint256 appealBondEscalationBps,
        uint256 maxAppealBond,
        uint256 maxVotersPerRound
    );

    /// @notice Emitted when the bond custody vault is re-pointed (governance/admin only).
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    event BoundAppealRoundOpened(
        uint256 indexed claimId,
        uint256 indexed parentDisputeId,
        uint8 parentOutcome,
        uint256 indexed roundIndex,
        address appellant,
        address bondPayer,
        address bondBeneficiary,
        uint256 requiredBond,
        uint256 bondLockId
    );

    event AppealBondRefunded(
        uint256 indexed claimId,
        uint256 indexed bondLockId,
        address indexed beneficiary,
        uint256 amount
    );

    event AppealBondSlashed(
        uint256 indexed claimId,
        uint256 indexed bondLockId,
        address indexed recipient,
        uint256 amount
    );

    event DisputeResolutionUpdated(address indexed oldDisputeResolution, address indexed newDisputeResolution);

    // =========================================================================
    // Custom Errors
    // =========================================================================

    /// @notice Thrown when appellant is not authorized for the parent dispute or claim.
    error UnauthorizedAppellant(address appellant);

    /// @notice Thrown when the parent dispute ID does not match the claim or does not exist.
    error WrongParentDispute(uint256 claimId, uint256 parentDisputeId);

    /// @notice Thrown when the parent outcome contested does not match the parent dispute.
    error InvalidParentOutcome(uint8 provided, uint8 expected);

    /// @notice Thrown when the provided round index does not strictly increment the previous round.
    error WrongRound(uint256 provided, uint256 expected);

    /// @notice Thrown when an appeal for the parent dispute and round has already been opened.
    error DuplicateAppeal(uint256 parentDisputeId, uint256 roundIndex);

    /// @notice Thrown when the appeal is submitted after the parent dispute appeal deadline.
    error AppealWindowExpired(uint256 claimId, uint256 timestamp, uint256 deadline);

    /// @notice Thrown when the bond source addresses (payer or beneficiary) are zero.
    error InvalidBondSource(address payer, address beneficiary);

    /// @notice Thrown when bond disposition is attempted on an active round.
    error BondDispositionNotAllowed(uint256 claimId);

    /// @notice Thrown when a claim's appeal path has already been finalized.
    error AppealPathTerminal(uint256 claimId);

    /// @notice Thrown when a terminal path is finalized a second time.
    error AppealPathAlreadyFinalized(uint256 claimId);

    /// @notice Thrown when opening a round beyond the configured ladder cap.
    error MaxAppealRoundsExceeded(uint256 claimId, uint256 attemptedRound, uint256 maxRounds);

    /// @notice Thrown when there is no CLOSED/RESOLVED round to finalize.
    error AppealRoundNotClosed(uint256 claimId);

    /// @notice Thrown when the voter cap for a round is reached.
    error VoterLimitExceeded(uint256 claimId, uint256 maxVoters);

    /// @notice Thrown when an action is attempted at or after the round deadline.
    /// @dev Deadline semantics are EXCLUSIVE: an action is valid only while
    ///      `block.timestamp < deadline`. The exact-deadline timestamp is expired.
    error AppealDeadlineExpired(uint256 claimId, uint256 timestamp, uint256 deadline);

    /// @notice Thrown when a rollover input (round index or stake) is out of bounds.
    error InvalidRolloverInput(uint256 claimId, uint256 roundIndex, uint256 stakeAmount);

    /// @notice Thrown when no bond vault or bond amount is configured (fail closed).
    error BondNotConfigured();

    /// @notice Thrown when the opener has not approved the vault for the required bond.
    error InsufficientBondAllowance();

    /// @notice Thrown when the vault rejects the bond lock (external call failure).
    error CustodyTransitionFailed();

    /// @notice Thrown when the configured ladder cap is outside [1, MAX_APPEAL_ROUNDS].
    error InvalidMaxAppealRounds(uint256 maxAppealRounds);

    /// @notice Thrown when the base appeal bond is zero.
    error InvalidAppealBond(uint256 appealBond);

    /// @notice Thrown when the escalation basis points are outside the valid range.
    error InvalidBondEscalation(uint256 escalationBps);

    /// @notice Thrown when the bond ceiling is zero or below the base bond.
    error InvalidMaxAppealBond(uint256 maxAppealBond, uint256 appealBond);

    /// @notice Thrown when the voter cap is outside [1, MAX_VOTERS_PER_ROUND].
    error InvalidMaxVotersPerRound(uint256 maxVotersPerRound);

    /// @notice Thrown when the computed bond would overflow or exceed the hard cap.
    error AppealBondOverflow(uint256 roundIndex, uint256 computedBond, uint256 maxAppealBond);

    /// @notice Thrown when the appeal round deadline has not yet passed.
    error AppealRoundNotExpired(uint256 claimId, uint256 timestamp, uint256 deadline);

    /// @notice Thrown when a vote is submitted after the round deadline.
    error AppealRoundExpired(uint256 claimId, uint256 timestamp, uint256 deadline);

    /// @notice Thrown when a vote is submitted for a round that is not open.
    error AppealRoundNotOpen(uint256 claimId);

    /// @notice Thrown when a verifier attempts to vote twice in the same round.
    error AlreadyVoted(uint256 claimId, address verifier);

    /// @notice Thrown when the stake amount is below the round minimum.
    error InsufficientStake(uint256 provided, uint256 minimum);

    /// @notice Thrown when the round has no votes and cannot be resolved.
    error NoVotesCast(uint256 claimId);

    /// @notice Thrown when a tie occurs and cannot be resolved deterministically.
    error AppealTie(uint256 claimId, uint256 trueWeight, uint256 falseWeight);

    /// @notice Thrown when the terminal fallback cannot conserve funds.
    error TerminalFallbackFailed(uint256 claimId, uint256 expected, uint256 actual);

    // =========================================================================
    // Functions
    // =========================================================================

    /**
     * @notice Opens the next appeal round for `claimId` (bond-gated, bounded ladder).
     * @dev Permissionless, but the opener MUST post the module-computed escalating
     *      bond (via {ISTakeVault.lockBond}). Reverts if the claim's path is
     *      terminal, the ladder cap is reached, or the vault rejects the lock.
     * @custom:emits AppealRoundOpened
     */
    function openAppealRound(uint256 claimId) external;

    /**
     * @notice Computes the exact required bond for a given round index.
     * @dev Uses exact integer arithmetic with overflow protection and hard cap.
     * @param roundIndex 1-based round index within the ladder.
     * @return requiredBond The exact bond required for the round.
     */
    function computeRequiredBond(uint256 roundIndex) external view returns (uint256 requiredBond);

    /**
     * @notice Returns the current appeal round index for a claim (0 if none).
     * @param claimId Claim ID.
     * @return roundIndex The current 1-based round index, or 0 if no round opened.
     */
    function currentAppealRound(uint256 claimId) external view returns (uint256 roundIndex);

    /**
     * @notice Returns whether a claim's appeal path is terminal.
     * @param claimId Claim ID.
     * @return terminal True if the path is irreversibly finalized.
     */
    function isAppealPathTerminal(uint256 claimId) external view returns (bool terminal);

    /**
     * @notice Opens the next appeal round bound to an authorized appellant, parent dispute, and bond source.
     * @param params Bound appeal opening parameters.
     * @custom:emits BoundAppealRoundOpened
     */
    function openBoundAppealRound(BoundAppealParams calldata params) external;

    /**
     * @notice Refunds the appeal bond of a closed/resolved appeal round to the recorded bondBeneficiary.
     * @param claimId Claim ID whose appeal bond is being refunded.
     * @custom:emits AppealBondRefunded
     */
    function refundAppealBond(uint256 claimId) external;

    /**
     * @notice Slashes the appeal bond of a closed/resolved appeal round to the designated slashRecipient.
     * @param claimId Claim ID whose appeal bond is being slashed.
     * @param slashRecipient Recipient of the slashed bond funds.
     * @custom:emits AppealBondSlashed
     */
    function slashAppealBond(uint256 claimId, address slashRecipient) external;

    function setDisputeResolution(address newDisputeResolution) external;

    function disputeResolution() external view returns (address);

    function submitAppealVote(uint256 claimId, bool support, uint256 stakeAmount) external;

    /**
     * @notice Closes an expired appeal round. When the closed round is the final
     *         round in the ladder, the claim's appeal path becomes terminal.
     * @custom:emits AppealRoundClosed
     * @custom:emits AppealPathFinalized
     */
    function closeAppealRound(uint256 claimId) external;

    /**
     * @notice Deterministically finalizes a claim's appeal path (permissionless).
     * @dev Idempotency guard: reverts if the path is already terminal. An OPEN-but-
     *      expired round is closed within the same transaction before the terminal
     *      signal is emitted, so a single call always terminates the ladder. Bond
     *      disposition and claim-status finalization are V2-SC-018's responsibility.
     * @custom:emits AppealPathFinalized
     */
    function finalizeAppealRound(uint256 claimId) external;

    /**
     * @notice Returns the required appeal bond for a given 1-based round index
     *         under the current default config (escalation-capped).
     */
    function requiredAppealBond(uint256 roundIndex) external view returns (uint256);

    /**
     * @notice Returns whether a claim's appeal path is irreversibly terminal.
     */
    function isAppealPathTerminal(uint256 claimId) external view returns (bool);

    /**
     * @notice Returns the {ISTakeVault} lock ledger record for a claim's current
     *         appeal round (for SC-018 bond disposition).
     */
    function getAppealBondLock(uint256 claimId) external view returns (ISTakeVault.BondLock memory);

    function getAppealRound(uint256 claimId) external view returns (AppealRound memory);

    function getAppealVote(uint256 claimId, address verifier) external view returns (AppealVote memory);

    function isAppealOpen(uint256 claimId) external view returns (bool);

    /**
     * @notice Returns whether the appeal round for `claimId` is still open for
     *         voting at `timestamp`.
     * @dev Deadline semantics are EXCLUSIVE: returns true iff the round status is
     *      OPEN and `timestamp < deadline`. At exactly `deadline` this returns
     *      false, so one-second-before is open and exact-deadline is closed.
     */
    function isAppealOpenAt(uint256 claimId, uint256 timestamp) external view returns (bool);

    /**
     * @notice Returns the exclusive deadline for the current appeal round of `claimId`.
     * @dev Actions are valid strictly before the returned timestamp; the timestamp
     *      itself is expired. Reverts if no round has been opened.
     */
    function appealDeadline(uint256 claimId) external view returns (uint256);
}
