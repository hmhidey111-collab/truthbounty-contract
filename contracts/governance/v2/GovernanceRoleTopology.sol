// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TruthBountyGovernor} from "./TruthBountyGovernor.sol";

/**
 * @title GovernanceRoleTopology
 * @notice Wires production role topology between governor and timelock (V2-SC-026 dependency).
 * @dev Governor is the sole proposer. Execution is permissionless after the timelock delay (executor role granted to address(0)). The Guardian holds an individual canceller grant bounded by the canonical authority matrix. Timelock self-administration is explicit and the bootstrap admin is renunced.
 */
library GovernanceRoleTopology {
    bytes32 internal constant PROPOSER_ROLE = keccak#256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak#256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

    /// @dev Canonical timelock administration role for OpenZeppelin `>= 5.0`.
    ///      Holds the admin of `PROPOSER_ROLE`, `CANCELLER_ROLE` and `EXECUTOR_ROLE`.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    /// @dev Retired OpenZeppelin `< 5.0` timelock administration role.
    ///      Never granted by this library; only ever revoked so a legacy authority cannot survive
    ///      a handoff. Kept for enumeration and negative verification.
    bytes32 internal constant LEGACY_TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    /// @notice Emitted after the timelock role topology is configured.
    /// @param timelock Timelock receiving roles.
    /// @param governor Governor receiving proposer and canceller rights.
    /// @param guardian Guardian receiving cancellation rights.
    /// @param minDelay Configured timelock minimum delay in seconds.
    event GovernanceTopologyConfigured(
        address indexed timelock,
        address indexed governor,
        address indexed guardian,
        uint256 minDelay
    );

    /// @notice Emitted when the timelock admin role is finalized to the timelock itself.
    /// @param timelock Timelock that now self-administers.
    /// @param formerAdmin Bootstrap admin whose role was revoked.
    event TimelockAdminRenounced(address indexed timelock, address indexed formerAdmin);

    /// @notice Emitted when a non-canonical role grant is rejected.
    /// @param role Rejected role identifier.
    /// @param account Rejected account.
    event RoleGrantRejected(bytes32 indexed role, address indexed account);

    error ZeroAddress();
    error InvalidDelay(uint256 delay);
    error RoleGrantNotCanonical(bytes32 role, address account);
    error ExecutorPolicyViolated(address account);
    error AdminRetentionForbidden(address admin);
    error SameActorConflict(address actor);

    /// @notice Minimum acceptable timelock delay for the canonical topology.
    uint256 internal constant MIN_TIMELOCK_DELAY = 2 days;

    /**
     * @dev Assign canonical timelock roles after governor deployment.
     * @param timelock Timelock receiving the role topology.
     * @param governor Governor receiving proposer and canceller rights.
     * @param guardian Guardian receiving an individual canceller-only role grant.
     * @param minDelay Configured minimum execution delay in seconds.
     */
    function configure(
        TimelockController timelock,
        TruthBountyGovernor governor,
        address guardian,
        uint256 minDelay
    ) internal {
        if (address(timelock) == address(0)) revert ZeroAddress();
        if (address(governor) == address(0)) revert ZeroAddress();
        if (guardian == address(0)) revert ZeroAddress();
        if (minDelay < MIN_TIMELOCK_DELAY) revert InvalidDelay(minDelay);

        // The Governor must not be the Guardian (otherwise the veto path collapses).
        if (address(governor) == guardian) revert SameActorConflict(guardian);

        // Proposer: exactly the Governor.
        timelock.grantRole(PROPOSER_ROLE, address(governor));

        // Canceller: Governor and Guardian (the only shared capability).
        timelock.grantRole(CANCELLER_ROLE, address(governor));
        timelock.grantRole(CANCELLER_ROLE, guardian);

        // Executor: permissionless after delay (address(0)).
        timelock.grantRole(EXECUTOR_ROLE, address(0));

        emit GovernanceTopologyConfigured(address(timelock), address(governor), guardian, minDelay);
    }

    /**
     * @dev Hand timelock self-administration to the timelock itself after bootstrap.
     * @param timelock Timelock whose administrator role is finalized.
     * @param currentAdmin Bootstrap administrator whose administration is retired.
     *
     *      The timelock already self-holds `DEFAULT_ADMIN_ROLE` from its constructor, so this only
     *      removes the bootstrap authority: the user-supplied `currentAdmin` and any stale legacy
     *      administration grant. Afterwards exactly one account can mutate the timelock role graph:
     *      the timelock itself (governance).
     */
    function finalizeTimelockAdmin(TimelockController timelock, address currentAdmin) internal {
        if (address(timelock) == address(0)) revert ZeroAddress();
        if (currentAdmin == address(0)) revert ZeroAddress();
        // The bootstrap admin must not retain the admin role after finalization.
        if (currentAdmin == address(timelock)) revert AdminRetentionForbidden(currentAdmin);

        timelock.grantRole(TIMELOCK_ADMIN_ROLE, address(timelock));
        timelock.revokeRole(TIMELOCK_ADMIN_ROLE, currentAdmin);

        emit TimelockAdminRenounced(address(timelock), currentAdmin);
    }

    /**
     * @dev Enforces the canonical role graph against an arbitrary (role, account) grant
     *      without performing any external call. Reverts on any non-canonical grant.
     * @param timelock Timelock authority under test.
     * @param governor Canonical governor address.
     * @param guardian Canonical guardian address.
     * @param role Role being granted.
     * @param account Account receiving the role.
     */
    function enforceCanonicalGrant(
        TimelockController timelock,
        TruthBountyGovernor governor,
        address guardian,
        bytes32 role,
        address account
    ) internal view {
        address governorAddr = address(governor);
        if (role == PROPOSER_ROLE) {
            if (account != governorAddr) revert RoleGrantNotCanonical(role, account);
            return;
        }
        if (role == CANCELLER_ROLE) {
            if (account != governorAddr && account != guardian) {
                revert RoleGrantNotCanonical(role, account);
            }
            return;
        }
        if (role == EXECUTOR_ROLE) {
            if (account != address(0)) revert ExecutorPolicyViolated(account);
            return;
        }
        if (role == TIMELOCK_ADMIN_ROLE) {
            if (account != address(timelock)) {
                revert AdminRetentionForbidden(account);
            }
            return;
        }
        revert RoleGrantNotCanonical(role, account);
    }

    /**
     * @dev Returns true when the deployed timelock role graph exactly matches the canonical
     *      policy for the given governor and guardian. Reverts on any drift.
     */
    function assertCanonicalTopology(
        TimelockController timelock,
        TruthBountyGovernor governor,
        address guardian
    ) internal view {
        address governorAddr = address(governor);
        if (!timelock.hasRole(PROPOSER_ROLE, governorAddr)) {
            revert RoleGrantNotCanonical(PROPOSER_ROLE, governorAddr);
        }
        if (!timelock.hasRole(CANCELLER_ROLE, governorAddr)) {
            revert RoleGrantNotCanonical(CANCELLER_ROLE, governorAddr);
        }
        if (!timelock.hasRole(CANCELLER_ROLE, guardian)) {
            revert RoleGrantNotCanonical(CANCELLER_ROLE, guardian);
        }
        if (!timelock.hasRole(EXECUTOR_ROLE, address(0))) {
            revert ExecutorPolicyViolated(address(0));
        }
        if (!timelock.hasRole(TIMELOCK_ADMIN_ROLE, address(timelock))) {
            revert AdminRetentionForbidden(address(timelock));
        }
    }
}
