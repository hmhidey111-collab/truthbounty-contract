// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IVerificationRoundEvents
 * @notice Canonical event surface for the Verification Round Manager.
 * @dev Events are public protocol APIs. Off-chain indexers must consume these
 *      events to reconstruct round and participation state without additional
 *      storage queries. All identifiers needed for deterministic aggregation
 *      are present as indexed or value fields.
 *
 *      Schema version: 1
 */
interface IVerificationRoundEvents {
    // =========================================================================
    // Round lifecycle events
    // =========================================================================

    /**
     * @notice Emitted when a new verification round is opened for a claim.
     * @param claimId           The claim this round belongs to.
     * @param roundId           Globally unique, monotonically increasing round identifier.
     * @param roundType         0 = FIRST, 1 = APPEAL.
     * @param startedAt         Block timestamp at which the round was opened.
     * @param deadline          Block timestamp after which no further submissions are accepted.
     * @param minStake          Minimum stake (in token base units) required to participate.
     * @param maxStake          Maximum stake (in token base units) allowed per participant.
     * @param weightCap         Maximum weight units any single participant may contribute.
     * @param passingThreshold  Fraction (in basis points, 0–10 000) of weighted votes
     *                          required for a TRUE outcome.
     * @param paramVersion      Configuration registry version snapshot frozen at open time.
     */
    event RoundOpened(
        uint256 indexed claimId,
        uint256 indexed roundId,
        uint8            roundType,
        uint64           startedAt,
        uint64           deadline,
        uint256          minStake,
        uint256          maxStake,
        uint256          weightCap,
        uint16           passingThreshold,
        uint32           paramVersion
    , uint64 timestamp, uint16 version);

    /**
     * @notice Emitted when a verification round is closed (permissionlessly after
     *         the deadline has passed).
     * @param claimId     The claim this round belongs to.
     * @param roundId     The round being closed.
     * @param closedAt    Block timestamp of the close transaction.
     * @param totalVotes  Total number of participant submissions recorded in the round.
     */
    event RoundClosed(
        uint256 indexed claimId,
        uint256 indexed roundId,
        uint64           closedAt,
        uint256          totalVotes
    , uint64 timestamp, uint16 version);
}
