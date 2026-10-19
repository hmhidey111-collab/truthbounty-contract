// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IV2CommitReveal
 * @notice Canonical interface for TruthBounty V2 Commit-Reveal Privacy, Deadlines,
 *         and Replay Domain verification (PREWAVE-SC-003, #678).
 * @dev Governs the commit-reveal lifecycle for verifier voting:
 *      1. Phase 1 (Commit Phase): Voters publish a cryptographic commitment binding
 *         10 replay dimensions (chain, release, contract, claim, round, voter,
 *         decision, rationale hash, salt, deadline). Decision, salt, and rationale
 *         must remain strictly off-chain and are NEVER emitted or recorded.
 *      2. Phase 2 (Reveal Phase): After commitDeadline and up to revealDeadline,
 *         voters submit their decision, salt, and rationale hash. The contract
 *         recomputes the digest and verifies exact domain equality.
 *      3. Phase 3 (Missed Reveal & Slashing): Voters who failed to reveal by
 *         revealDeadline can be recorded as missed reveals and slashed with full event completeness.
 */
interface IV2CommitReveal {
    // =========================================================================
    // Enums
    // =========================================================================

    /// @notice State of a voter's commitment.
    enum CommitState {
        NONE,
        COMMITTED,
        REVEALED,
        MISSED_REVEAL,
        SLASHED
    }

    /// @notice Commit replacement policy governing whether a voter can update
    ///         their commitment prior to the commit deadline.
    enum ReplacementPolicy {
        FORBIDDEN,
        ALLOWED_BEFORE_DEADLINE
    }

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Persistent record of a voter's commitment.
    struct CommitmentRecord {
        bytes32 commitmentHash;
        uint64 committedAt;
        uint64 commitDeadline;
        uint64 revealDeadline;
        uint256 stakeAmount;
        uint16 replacementCount;
        CommitState state;
    }

    /// @notice Round timing and policy configuration frozen at round open.
    struct RoundTiming {
        uint64 startedAt;
        uint64 commitDeadline;
        uint64 revealDeadline;
        ReplacementPolicy replacementPolicy;
        bool exists;
    }

    // =========================================================================
    // Events
    // =========================================================================

    /**
     * @notice Emitted when a verification round's commit-reveal window is registered.
     */
    event RoundRegistered(
        uint256 indexed claimId,
        uint256 indexed roundId,
        uint64 startedAt,
        uint64 commitDeadline,
        uint64 revealDeadline,
        ReplacementPolicy replacementPolicy
    );

    /**
     * @notice Emitted when a commitment is submitted during the commit phase.
     * @dev MUST NEVER emit decision, salt, or rationale hash. Privacy invariant:
     *      choice and rationale remain strictly off-chain until reveal.
     */
    event CommitSubmitted(
        uint256 indexed claimId,
        uint256 indexed roundId,
        address indexed voter,
        bytes32 commitmentHash,
        uint64 commitDeadline,
        uint64 revealDeadline,
        uint256 stakeAmount,
        uint64 committedAt
    );

    /**
     * @notice Emitted when a commitment is replaced prior to the commit deadline
     *         under the ALLOWED_BEFORE_DEADLINE policy.
     */
    event CommitReplaced(
        uint256 indexed claimId,
        uint256 indexed roundId,
        address indexed voter,
        bytes32 oldCommitmentHash,
        bytes32 newCommitmentHash,
        uint16 replacementCount,
        uint64 replacedAt
    );

    /**
     * @notice Emitted upon successful verification and reveal of a vote.
     */
    event VoteRevealed(
        uint256 indexed claimId,
        uint256 indexed roundId,
        address indexed voter,
        uint8 decision,
        bytes32 rationaleHash,
        uint256 stakeAmount,
        uint64 revealedAt
    );

    /**
     * @notice Emitted when an unrevealed commitment is recorded as missed after revealDeadline.
     */
    event MissedRevealRecorded(
        uint256 indexed claimId,
        uint256 indexed roundId,
        address indexed voter,
        bytes32 commitmentHash,
        uint256 stakeAmount,
        uint64 recordedAt
    );

    /**
     * @notice Emitted when a voter is slashed for failing to reveal before revealDeadline.
     */
    event VoterSlashed(
        uint256 indexed claimId,
        uint256 indexed roundId,
        address indexed voter,
        uint256 slashAmount,
        uint256 remainingStake,
        bytes32 commitmentHash,
        uint64 slashedAt
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error CommitDeadlinePassed(uint64 currentTimestamp, uint64 commitDeadline);
    error CommitDeadlineNotPassed(uint64 currentTimestamp, uint64 commitDeadline);
    error RevealDeadlinePassed(uint64 currentTimestamp, uint64 revealDeadline);
    error RevealDeadlineNotPassed(uint64 currentTimestamp, uint64 revealDeadline);
    error RevealWindowNotOpen(uint64 currentTimestamp, uint64 commitDeadline);
    error CommitmentMismatch(bytes32 expectedCommitment, bytes32 computedCommitment);
    error CommitmentNotFound(uint256 claimId, uint256 roundId, address voter);
    error CommitmentAlreadyRevealed(uint256 claimId, uint256 roundId, address voter);
    error CommitmentAlreadyExists(uint256 claimId, uint256 roundId, address voter);
    error CommitmentAlreadySlashed(uint256 claimId, uint256 roundId, address voter);
    error CommitReplacementForbidden(uint256 claimId, uint256 roundId, address voter);
    error UnauthorizedReveal(address caller, address voter);
    error RoundAlreadyRegistered(uint256 claimId, uint256 roundId);
    error RoundNotFound(uint256 claimId, uint256 roundId);
    error InvalidDeadlines(uint64 startedAt, uint64 commitDeadline, uint64 revealDeadline);
    error ZeroAddress();
    error ZeroCommitment();
    error ZeroSalt();
    error InvalidSlashBps(uint256 slashBps);
    error InvalidDecision(uint8 decision);

    // =========================================================================
    // External Functions
    // =========================================================================

    /**
     * @notice Registers the commit-reveal parameters and deadlines for a claim round.
     */
    function registerRound(
        uint256 claimId,
        uint256 roundId,
        uint64 commitDeadline,
        uint64 revealDeadline,
        ReplacementPolicy policy
    ) external;

    /**
     * @notice Submits or replaces a vote commitment during the commit window.
     */
    function commit(
        uint256 claimId,
        uint256 roundId,
        bytes32 commitmentHash,
        uint256 stakeAmount
    ) external;

    /**
     * @notice Reveals a previously committed vote during the reveal window.
     */
    function reveal(
        uint256 claimId,
        uint256 roundId,
        uint8 decision,
        bytes32 rationaleHash,
        bytes32 salt
    ) external;

    /**
     * @notice Marks an unrevealed vote as missed after the reveal deadline has passed.
     */
    function recordMissedReveal(
        uint256 claimId,
        uint256 roundId,
        address voter
    ) external;

    /**
     * @notice Slashes a voter who missed the reveal deadline.
     */
    function slashMissedReveal(
        uint256 claimId,
        uint256 roundId,
        address voter,
        uint256 slashBps
    ) external returns (uint256 slashAmount);

    /**
     * @notice Reads a voter's commitment record.
     */
    function getCommitment(
        uint256 claimId,
        uint256 roundId,
        address voter
    ) external view returns (CommitmentRecord memory);

    /**
     * @notice Reads the timing parameters for a round.
     */
    function getRound(
        uint256 claimId,
        uint256 roundId
    ) external view returns (RoundTiming memory);
}
