// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IGovernanceAuthorityBoundaries
 * @notice Declarative authority taxonomy and capability matrix surface for the V2 governance topology.
 * @dev Authorities (Governor, Timelock, Guardian, Registry, Configuration, Treasury, Operations) have
 *      disjoint domains. Every capability is granted to exactly one authority except
 *      `CANCEL_PROPOSAL`, which Governor and Guardian intentionally share as a veto path.
 *      No authority may propose, execute, settle, or release value outside its declared capabilities.
 */
interface IGovernanceAuthorityBoundaries {
    /// @notice Governance authorities with non-overlapping operational domains.
    enum AuthorityRole {
        GOVERNOR,
        TIMELOCK,
        GUARDIAN,
        REGISTRY,
        CONFIGURATION,
        TREASURY,
        OPERATIONS
    }

    /// @notice Canonical protocol powers, each owned by exactly one authority (except CANCEL_PROPOSAL).
    enum Capability {
        PROPOSE_PROPOSAL,
        QUEUE_PROPOSAL,
        EXECUTE_PROPOSAL,
        CANCEL_PROPOSAL,
        SET_TIMELOCK_ROLES,
        UPGRADE_IMPLEMENTATION,
        REGISTER_GOVERNED_MODULE,
        SET_PROTOCOL_PARAMETER,
        RELEASE_TREASURY_FUNDS,
        PAUSE_PROTOCOL,
        ROTATE_OPERATIONAL_ROLE
    }

    event AuthorityBoundaryDeclared(AuthorityRole indexed role, address indexed account);
    event AuthorityBoundaryRevoked(AuthorityRole indexed role, address indexed account);
    event GovernanceAuthorityMatrixPublished(address indexed publisher, uint256 roleCount, uint256 capabilityCount);

    error ZeroAuthorityAddress();
    error AuthorityAlreadyBound(AuthorityRole role, address account);
    error AuthorityNotBound(AuthorityRole role);
    error OverlappingAuthority(address account, AuthorityRole existingRole, AuthorityRole requestedRole);
    error CapabilityNotGranted(AuthorityRole role, Capability capability);
    error SharedCapability(Capability capability);
    error NoRoleForCapability(Capability capability);

    /**
     * @notice Bind an authority role to its accountable account.
     * @dev Rejects the zero address, a role that is already bound, and any account already bound to a
     *      different role, so overlapping authority cannot be configured.
     */
    function bindAuthority(AuthorityRole role, address account) external;

    /// @notice Revoke the account currently bound to an authority role.
    function revokeAuthority(AuthorityRole role) external;

    /// @notice The account bound to `role`, or the zero address when unbound.
    function authorityOf(AuthorityRole role) external view returns (address);

    /// @notice True when `role` has a bound account.
    function isAuthorityBound(AuthorityRole role) external view returns (bool);

    /// @notice The role bound to `account` and whether any binding exists.
    function boundRoleOf(address account) external view returns (AuthorityRole role, bool bound);

    /// @notice True when `role` is canonically allowed to exercise `capability`.
    function isCapabilityAllowed(AuthorityRole role, Capability capability) external view returns (bool);

    /// @notice True when `capability` must be held by exactly one authority.
    function isCapabilityExclusive(Capability capability) external view returns (bool);

    /// @notice The single authority that owns an exclusive `capability`; reverts if the capability is shared.
    function soleRoleForCapability(Capability capability) external view returns (AuthorityRole role);

    /// @notice Every authority canonically allowed to exercise `capability`, in enum order.
    function rolesForCapability(Capability capability) external view returns (AuthorityRole[] memory roles);

    /// @notice Every capability canonically granted to `role`, in enum order.
    function capabilitiesOf(AuthorityRole role) external view returns (Capability[] memory capabilities);

    /// @notice True when `account` is bound and its role may exercise `capability`.
    function isAuthorizedFor(address account, Capability capability) external view returns (bool);

    /// @notice Reverts with {CapabilityNotGranted} unless `role` may exercise `capability`.
    function requireCapability(AuthorityRole role, Capability capability) external view;

    /// @notice Emit the canonical matrix dimensions for indexers and deployment reconciliation.
    function publishAuthorityMatrix() external;
}
