// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IGovernanceSnapshot} from "./IGovernanceSnapshot.sol";

/**
 * @title GovernanceSnapshot
 * @notice Canonical, append-only registry that freezes one voting-power reference
 *         timestamp per governance proposal at the moment of proposal creation.
 *
 * @dev ## Purpose
 *
 *      OpenZeppelin's {GovernorVotes} already records `proposalSnapshot(proposalId)` —
 *      the `clock()` value at proposal creation — inside the proposal struct and uses it
 *      as the `timepoint` argument to `token.getPastVotes(account, timepoint)` during
 *      voting. Because {TruthBountyGovernanceToken} uses `mode=timestamp`, this timepoint
 *      is a `block.timestamp` value.
 *
 *      The `GovernanceSnapshot` contract acts as the *canonical, externally-auditable*
 *      source of truth for that timestamp. Without it, off-chain systems (indexers,
 *      multisig tooling, auditors) have no single authoritative record they can verify
 *      independently from governor proposal state. Additionally, future token or staking
 *      extensions that need to prove "voting power at snapshot X" can query this registry
 *      directly rather than re-deriving the timepoint from governor proposal metadata.
 *
 * ## Security Properties
 *
 *      1. **Append-only** — `registerSnapshot` may be called once per `proposalId`.
 *         Attempting to overwrite an existing entry reverts with {SnapshotAlreadyRegistered}.
 *      2. **Fail-closed** — `getSnapshotTimestamp` reverts with {SnapshotNotFound} for
 *         unknown `proposalId`s; no silent fallback to current time.
 *      3. **Access-gated write** — only accounts with `SNAPSHOT_REGISTRAR_ROLE` may call
 *         `registerSnapshot`. At deploy time this role is granted exclusively to the
 *         {TruthBountyGovernor} contract.
 *      4. **Input validation** — zero `proposalId` and zero `block.timestamp` both revert
 *         defensively.
 *
 * ## Integration
 *
 *      {TruthBountyGovernor} overrides `_propose` to call `registerSnapshot(proposalId)`
 *      immediately after the base `_propose` returns. This ensures every valid proposal
 *      has a canonical snapshot entry before it reaches the `Pending` state.
 *
 * @custom:security-contact security@truthbounty.xyz
 */
contract GovernanceSnapshot is AccessControl, IGovernanceSnapshot {
    // ---------------------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------------------

    /**
     * @notice Role required to call {registerSnapshot}.
     * @dev Granted at construction to the {TruthBountyGovernor} address and can later
     *      be granted to a successor governor by the `DEFAULT_ADMIN_ROLE` Holder
     *      (typically a timelock).
     */
    bytes32 public constant SNAPSHOT_REGISTRAR_ROLE = keccak256("SNAPSHOT_REGISTRAR_ROLE");

    // ---------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------

    /**
     * @dev Mapping from proposalId to the frozen `block.timestamp` at proposal creation.
     *      Zero value indicates no snapshot has been registered.
     *      `uint48` matches {TruthBountyGovernanceToken.clock()} return type.
     */
    mapping(uint256 => uint48) private _snapshots;

    // ---------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------

    /**
     * @param admin           Address granted `DEFAULT_ADMIN_ROLE` (typically a timelock or
     *                         deployer multisig). Cannot be `address(0)`.
     * @param snapshotRegistrar Address granted `SNAPSHOT_REGISTRAR_ROLE` at construction.
     *                        Must be the {TruthBountyGovernor} contract. Cannot be
     *                        `address(0)`.
     */
    constructor(address admin, address snapshotRegistrar) {
        if (admin == address(0)) revert InvalidSnapshotTimestamp(); // re-use defensive zero guard
        if (snapshotRegistrar == address(0)) revert InvalidSnapshotTimestamp();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SNAPSHOT_REGISTRAR_ROLE, snapshotRegistrar);
    }

    // ---------------------------------------------------------------------------
    // IGovernanceSnapshot — write surface
    // ---------------------------------------------------------------------------

    /**
     * @inheritdoc {IGovernanceSnapshot}
     *
     * @dev Stores the caller-supplied `snapshotTimestamp` as the canonical voting-power
     *      reference timestamp for `proposalId`. Called by {TruthBountyGovernor._propose}
     *      with `proposalSnapshot(proposalId)` immediately after the base proposal is
     *      registered. This ensures the registry mirrors exactly the value used by
     *      {GovernorVotes._getVotes} for all vote-power queries.
     *
     *      Reverts if:
     *        - `msg.sender` does not hold `SNAPSHOT_REGISTRAR_ROLE`
     *        - `proposalId` is zero
     *        - `snapshotTimestamp` is zero
     *        - A snapshot has already been registered for `proposalId`
     */
    function registerSnapshot(uint256 proposalId, uint48 snapshotTimestamp)
        external
        onlyRole(SNAPSHOT_REGISTRAR_ROLE)
    {
        if (proposalId == 0) revert InvalidProposalId();
        if (snapshotTimestamp == 0) revert InvalidSnapshotTimestamp();
        if (_snapshots[proposalId] != 0) revert SnapshotAlreadyRegistered(proposalId);

        _snapshots[proposalId] = snapshotTimestamp;
        emit SnapshotRegistered(proposalId, snapshotTimestamp, msg.sender);
    }

    // ---------------------------------------------------------------------------
    // IGovernanceSnapshot — read surface
    // ---------------------------------------------------------------------------

    /**
     * @inheritdoc {IGovernanceSnapshot}
     *
     * @dev Reverts with {SnapshotNotFound} rather than returning zero so callers cannot
     *      silently receive a stale or default timestamp. This is the fail-closed
     *      property required by the security model.
     */
    function getSnapshotTimestamp(uint256 proposalId) external view returns (uint48 snapshotTimestamp) {
        snapshotTimestamp = _snapshots[proposalId];
        if (snapshotTimestamp == 0) revert SnapshotNotFound(proposalId);
    }

    /**
     * @inheritdoc {IGovernanceSnapshot}
     */
    function hasSnapshot(uint256 proposalId) external view returns (bool registered) {
        registered = _snapshots[proposalId] != 0;
    }
}
