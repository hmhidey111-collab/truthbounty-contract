// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGovernanceAuthorityBoundaries as IAuthority} from "../IGovernanceAuthorityBoundaries.sol";

/**
 * @title GovernanceAuthorityMatrix
 * @notice Canonical, immutable authority matrix for the TruthBounty V2 governance topology (V2-SC-111).
 * @dev Encodes the exact (role, capability) grants of the protocol. Every capability is owned by a
 *      single authority except `CANCEL_PROPOSAL`, which Governor and Guardian intentionally share as a
 *      veto path. Because the matrix is pure, a deployment cannot drift into overlapping or
 *      fail-open authority and no unbounded storage reads are required for authorization checks.
 *
 * @dev Timelock role graph (PREWAVE-SC-033):
 *      - PROPOSER_ROLE: proposes and queues operations. May not execute or cancel.
 *      - EXECUTOR_ROLE: executes queued operations after the delay. May not propose or cancel.
 *      - CANCELLER_ROLE: cancels queued operations. May not propose or execute.
 *      - ADMIN_ROLE: self administration of timelock roles and implementation upgrades.
 *      The four timelock roles are mutually disjoint: no actor may hold two of them at once,
 *      which prevents a single actor from proposing and bypassing the delay alone.
 */
library GovernanceAuthorityMatrix {
    uint256 internal constant ROLE_COUNT = 7;
    uint256 internal constant CAPABILITY_COUNT = 11;

    uint256 internal constant MIN_TIMELOCK_DELAY = 1 days;
    uint256 internal constant MAX_TIMELOCK_DELAY = 30 days;
    uint256 internal constant TIMELOCK_GRACE_PERIOD = 14 days;

    /**
     * @dev Timelock role graph identifiers. These are the canonical timelock roles that must be
     *      distinct actors in a conformant deployment. The graph is closed: no extra timelock
     *      role may be granted and no role may be omitted.
     */
    uint256 internal constant TIMELOCK_ROLE_COUNT = 4;
    uint256 internal constant TIMELOCK_PROPOSER_ROLE = 0;
    uint256 internal constant TIMELOCK_EXECUTOR_ROLE = 1;
    uint256 internal constant TIMELOCK_CANCELLER_ROLE = 2;
    uint256 internal constant TIMELOCK_ADMIN_ROLE = 3;

    /**
     * @dev Returns true when `role` is canonically allowed to exercise `capability`.
     *      Bounded, branch-only evaluation with no external calls or loops over unbounded input.
     */
    function isAllowed(IAuthority.AuthorityRole role, IAuthority.Capability capability)
        internal
        pure
        returns (bool)
    {
        if (role == IAuthority.AuthorityRole.GOVERNOR) {
            return capability == IAuthority.Capability.PROPOSE_PROPOSAL
                || capability == IAuthority.Capability.QUEUE_PROPOSAL
                || capability == IAuthority.Capability.CANCEL_PROPOSAL;
        }
        if (role == IAuthority.AuthorityRole.TIMELOCK) {
            return capability == IAuthority.Capability.EXECUTE_PROPOSAL
                || capability == IAuthority.Capability.SET_TIMELOCK_ROLES
                || capability == IAuthority.Capability.UPGRADE_IMPLEMENTATION;
        }
        if (role == IAuthority.AuthorityRole.GUARDIAN) {
            return capability == IAuthority.Capability.CANCEL_PROPOSAL
                || capability == IAuthority.Capability.PAUSE_PROTOCOL;
        }
        if (role == IAuthority.AuthorityRole.REGISTRY) {
            return capability == IAuthority.Capability.REGISTER_GOVERNED_MODULE;
        }
        if (role == IAuthority.AuthorityRole.CONFIGURATION) {
            return capability == IAuthority.Capability.SET_PROTOCOL_PARAMETER;
        }
        if (role == IAuthority.AuthorityRole.TREASURY) {
            return capability == IAuthority.Capability.RELEASE_TREASURY_FUNDS;
        }
        return capability == IAuthority.Capability.ROTATE_OPERATIONAL_ROLE;
    }

    /**
     * @dev Returns true when `capability` must be held by exactly one authority.
     *      `CANCEL_PROPOSAL` is the single intentionally shared capability.
     */
    function isExclusive(IAuthority.Capability capability) internal pure returns (bool) {
        return capability != IAuthority.Capability.CANCEL_PROPOSAL;
    }

    /**
     * @dev Returns true when `capability` is a timelock role capability that must be bound to
     *      exactly one of the four distinct timelock roles. This is the closed executor policy:
     *      the timelock graph is four roles, no more and no fewer.
     */
    function isTimelockRole(uint256 roleId) internal pure returns (bool) {
        return roleId < TIMELOCK_ROLE_COUNT;
    }

    /**
     * @dev Returns the canonical timelock role for a given capability, or reverts if the
     *      capability is not a timelock capability. The mapping is closed and exclusive.
     */
    function timelockRoleFor(IAuthority.Capability capability)
        internal
        pure
        returns (uint256)
    {
        if (capability == IAuthority.Capability.PROPOSE_PROPOSAL
            || capability == IAuthority.Capability.QUEUE_PROPOSAL)
        {
            return TIMELOCK_PROPOSER_ROLE;
        }
        if (capability == IAuthority.Capability.EXECUTE_PROPOSAL) {
            return TIMELOCK_EXECUTOR_ROLE;
        }
        if (capability == IAuthority.Capability.CANCEL_PROPOSAL) {
            return TIMELOCK_CANCELLER_ROLE;
        }
        if (capability == IAuthority.Capability.SET_TIMELOCK_ROLES
            || capability == IAuthority.Capability.UPGRADE_IMPLEMENTATION)
        {
            return TIMELOCK_ADMIN_ROLE;
        }
        revert IAuthority.NoRoleForCapability(capability);
    }

    /**
     * @dev Returns true when the timelock role graph is closed and complete: every timelock
     *      capability has exactly one distinct timelock role, and the four roles are mutually
     *      disjoint. This is the machine-checkable invariant for PREWAVE-SC-033.
     */
    function isTimelockGraphClosed() internal pure returns (bool) {
        bool[] memory seen;
        for (uint256 i = 0; i < CAPABILITY_COUNT; ++i) {
            IAuthority.Capability capability = IAuthority.Capability(i);
            if (!isAllowed(IAuthority.AuthorityRole.TIMELOCK, capability)) {
                continue;
            }
            uint256 roleId = timelockRoleFor(capability);
            if (roleId >= TIMELOCK_ROLE_COUNT) {
                return false;
            }
            if (seen[roleId]) {
                return false;
            }
            seen[roleId] = true;
        }
        for (uint256 i = 0; i < TIMELOCK_ROLE_COUNT; ++i) {
            if (!seen[i]) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Returns true when the canonical timelock role graph is complete and every timelock
     *      role is distinct. Reverts with {TimelockGraphInvalid} otherwise. This is the
     *      machine-checkable deployment conformance guard for PREWAVE-SC-033.
     */
    function enforceTimelockGraph() pure {
        if (!isTimelockGraphClosed()) {
            revert IAuthority.TimelockGraphInvalid();
        }
    }

    /**
     * @dev Returns true when `role` is a canonical timelock role.
     */
    function isTimelockAuthorityRole(IAuthority.AuthorityRole role) internal pure returns (bool) {
        return role == IAuthority.AuthorityRole.TIMELOCK;
    }

    /**
     * @dev Returns every authority canonically allowed to exercise `capability`, in enum order.
     *      The result is bounded by {ROLE_COUNT}.
     */
    function rolesFor(IAuthority.Capability capability)
        internal
        pure
        returns (IAuthority.AuthorityRole[] memory roles)
    {
        roles = new IAuthority.AuthorityRole[](ROLE_COUNT);
        uint256 count;
        for (uint256 i = 0; i < ROLE_COUNT; ++i) {
            IAuthority.AuthorityRole role = IAuthority.AuthorityRole(i);
            if (isAllowed(role, capability)) {
                roles[count] = role;
                ++count;
            }
        }
        assembly {
            mstore(roles, count)
        }
    }

    /**
     * @dev Returns every capability canonically granted to `role`, in enum order.
     *      The result is bounded by {CAPABILITY_COUNT}.
     */
    function capabilitiesFor(IAuthority.AuthorityRole role)
        internal
        pure
        returns (IAuthority.Capability[] memory capabilities)
    {
        capabilities = new IAuthority.Capability[](CAPABILITY_COUNT);
        uint256 count;
        for (uint256 i = 0; i < CAPABILITY_COUNT; ++i) {
            IAuthority.Capability capability = IAuthority.Capability(i);
            if (isAllowed(role, capability)) {
                capabilities[count] = capability;
                ++count;
            }
        }
        assembly {
            mstore(capabilities, count)
        }
    }

    /**
     * @dev Returns the single authority owning an exclusive `capability`.
     *      Reverts with {SharedCapability} for the shared veto capability and with
     *      {NoRoleForCapability} if the matrix has no owner (guards against drift).
     */
    function soleRoleFor(IAuthority.Capability capability) internal pure returns (IAuthority.AuthorityRole) {
        if (!isExclusive(capability)) {
            revert IAuthority.SharedCapability(capability);
        }
        for (uint256 i = 0; i < ROLE_COUNT; ++i) {
            IAuthority.AuthorityRole role = IAuthority.AuthorityRole(i);
            if (isAllowed(role, capability)) {
                return role;
            }
        }
        revert IAuthority.NoRoleForCapability(capability);
    }

    /**
     * @dev Reverts with {CapabilityNotGranted} unless `role` may exercise `capability`.
     *      Rejects fail-open authorization by defaulting to a revert.
     */
    function enforce(IAuthority.AuthorityRole role, IAuthority.Capability capability) internal pure {
        if (!isAllowed(role, capability)) {
            revert IAuthority.CapabilityNotGranted(role, capability);
        }
    }

    /**
     * @dev Reverts with {TimelockRoleConflict} when a single actor attempts to hold more than
     *      one timelock role. This enforces the proposer/executor/canceller/admin separation
     *      required by PREWAVE-SC-033 and prevents a single actor from proposing and
     *      bypassing the delay alone.
     */
    function enforceDistinctTimelockActors(address[] calldata actors) internal pure {
        if (actors.length != TIMELOCK_ROLE_COUNT) {
            revert IAuthority.TimelockRoleConflict(address(0), address(0));
        }
        for (uint256 i = 0; i < actors.length; ++i) {
            for (uint256 j = i + 1; j < actors.length; ++j) {
                if (actors[i] == address(0) || actors[i] == actors[j]) {
                    revert IAuthority.TimelockRoleConflict(actors[i], actors[j]);
                }
            }
        }
    }

    /**
     * @dev Reverts unless `newDelay` is within the canonical [MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY] band.
     *      Prevents both immediate (zero/negligible) delays and unbounded lockups.
     */
    function enforceTimelockDelayBounds(uint256 newDelay) internal pure {
        if (newDelay < MIN_TIMELOCK_DELAY || newDelay > MAX_TIMELOCK_DELAY) {
            revert IAuthority.TimelockDelayOutOfBounds(newDelay, MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY);
        }
    }

    /**
     * @dev Reverts unless a delay change is scheduled through the timelock itself (self-call),
     *      so the delay cannot be mutated by an external authority or bypassed via a direct write.
     */
    function enforceTimelockSelfCall(address caller, address timelock) internal pure {
        if (caller != timelock) {
            revert IAuthority.TimelockSelfCallRequired(caller, timelock);
        }
    }

    /**
     * @dev Reverts unless the operation is still within its grace window after `eta`.
     *      Expired operations must not execute.
     */
    function enforceNotExpired(uint256 eta, uint256 timestamp) internal pure {
        if (timestamp > eta + TIMELOCK_GRACE_PERIOD) {
            revert IAuthority.OperationExpired(eta, timestamp);
        }
    }

    /**
     * @dev Reverts unless `predecessor` has been executed, enforcing predecessor semantics
     *      so dependent operations cannot be replayed out of order.
     */
    function enforcePredecessorExecuted(bytes32 predecessor, bool executed) internal pure {
        if (predecessor != bytes32(0) && !executed) {
            revert IAuthority.PredecessorNotExecuted(predecessor);
        }
    }
}