// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IGovernanceSnapshot
 * @notice Interface for the canonical governance snapshot registry.
 * @dev Defines the surface for registering and querying proposal-scoped voting-power
 *      freeze timestamps. Every governance proposal has exactly one canonical snapshot
 *      timestamp recorded at proposal creation. That timestamp is the sole authoritative
 *      reference point for all voting-power queries during that proposal's voting window.
 *
 * Security model
 * --------------
 * - The registry is append-only: a snapshot may be registered once per proposalId and
 *   never mutated or deleted.
 * - Only the `SNAPSHOT_REGISTRAR_ROLE` (granted to {TruthBountyGovernor}) may write
 *   new entries, preventing external actors from injecting false snapshots.
 * - Querying a proposalId that has no registered snapshot reverts with
 *   {SnapshotNotFound}, guaranteeing fail-closed behaviour: no silent fallback to
 *   current state.
 */
interface IGovernanceSnapshot {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a canonical snapshot timestamp is recorded for a proposal.
     * @param proposalId The OpenZeppelin governor proposal identifier.
     * @param snapshotTimestamp The `block.timestamp` at proposal creation (uint48).
     * @param registrar The caller that registered the snapshot (the governor).
     */
    event SnapshotRegistered(
        uint256 indexed proposalId, uint48 indexed snapshotTimestamp, address indexed registrar
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Reverts when a snapshot for `proposalId` has already been registered.
    error SnapshotAlreadyRegistered(uint256 proposalId);

    /// @notice Reverts when `proposalId` has no registered snapshot.
    error SnapshotNotFound(uint256 proposalId);

    /// @notice Reverts when a zero proposalId is supplied (cannot be a valid proposal).
    error InvalidProposalId();

    /// @notice Reverts when a zero timestamp would be stored (defensive guard).
    error InvalidSnapshotTimestamp();

    /// @notice Reverts when a snapshot timestamp is in the future relative to the current clock.
    error SnapshotTimestampInFuture(uint48 snapshotTimestamp, uint48 currentTimestamp);

    /// @notice Reverts when a snapshot timestamp is not strictly less than the current clock.
    error SnapshotTimestampNotInPast(uint48 snapshotTimestamp, uint48 currentTimestamp);

    // -------------------------------------------------------------------------
    // Write surface (SNAPSHOT_REGISTRAR_ROLE)
    // -------------------------------------------------------------------------

    /**
     * @notice Register the canonical snapshot timestamp for `proposalId`.
     * @dev MUST be called exactly once per proposal, at or immediately after proposal
     *      creation. Reverts if `proposalId` is zero, if `snapshotTimestamp` is zero,
     *      or if a snapshot is already registered for `proposalId`.
     *
     *      The caller is responsible for passing the timestamp that the governor has
     *      recorded as `proposalSnapshot(proposalId)` — i.e. `clock() + votingDelay()`
     *      at proposal creation time. This ensures the registry mirrors exactly the
     *      value that {GovernorVotes} uses for all `getPastVotes` calls.
     *
     *      Immutability guarantee: once registered, the snapshot timestamp for a
     *      proposalId is frozen forever. Any subsequent transfer, delegation,
     *      redelegation, mint, burn, or self-delegation cannot alter the historical
     *      voting power observed at this timestamp. Implementations MUST NOT expose
     *      any mutation, override, or deletion path for a registered snapshot.
     *
     *      Callers with `SNAPSHOT_REGISTRAR_ROLE` only (i.e., {TruthBountyGovernor}).
     *
     * @param proposalId        The OpenZeppelin governor proposal identifier returned by
     *                          {Governor._propose}.
     * @param snapshotTimestamp The `proposalSnapshot(proposalId)` value from the governor
     *                          (`clock() + votingDelay()` at proposal creation). Must be
     *                          non-zero.
     */
    function registerSnapshot(uint256 proposalId, uint48 snapshotTimestamp) external;

    // -------------------------------------------------------------------------
    // Read surface
    // -------------------------------------------------------------------------

    /**
     * @notice Return the canonical snapshot timestamp for `proposalId`.
     * @dev Reverts with {SnapshotNotFound} if no snapshot has been registered.
     *      Safe to call by any account; no state is mutated.
     *
     *      The returned timestamp is the sole authoritative reference for historical
     *      voting-power queries during the proposal's voting window. Callers MUST use
     *      this value (not the current clock) when invoking `getPastVotes` so that
     *      post-snapshot transfers or delegation changes cannot increase voting power
     *      for the proposal.
     * @param proposalId The OpenZeppelin governor proposal identifier.
     * @return snapshotTimestamp The `uint48` timestamp frozen at proposal creation.
     */
    function getSnapshotTimestamp(uint256 proposalId) external view returns (uint48 snapshotTimestamp);

    /**
     * @notice Return `true` if a canonical snapshot has been registered for `proposalId`.
     * @param proposalId The OpenZeppelin governor proposal identifier.
     * @return registered `true` when a snapshot exists for this proposal.
     */
    function hasSnapshot(uint256 proposalId) external view returns (bool registered);

    /**
     * @notice Return the historical voting power for `account` as of the canonical
     *         snapshot of `proposalId`.
     * @dev Reverts with {SnapshotNotFound} if no snapshot has been registered for
     *      `proposalId`. The returned value MUST be derived exclusively from the
     *      registered snapshot timestamp and MUST NOT be affected by any transfer,
     *      delegation, redelegation, mint, burn, or self-delegation that occurs after
     *      that timestamp. Total voting power across all accounts MUST remain conserved
     *      with respect to the underlying checkpointed token at the snapshot timestamp.
     * @param proposalId The OpenZeppelin governor proposal identifier.
     * @param account    The voter whose historical voting power is queried.
     * @return votingPower The `uint256` voting power frozen at the snapshot timestamp.
     */
    function getVotingPowerAtSnapshot(uint256 proposalId, address account)
        external
        view
        returns (uint256 votingPower);
}
