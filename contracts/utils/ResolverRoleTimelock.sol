// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ResolverRoleTimelock
 * @notice Adds a mandatory delay before RESOLVER_ROLE grants and revocations can take effect.
 * @dev Contracts inheriting this module keep normal AccessControl behavior for all other roles.
 *      RESOLVER_ROLE changes must be scheduled, wait for RESOLVER_ROLE_CHANGE_DELAY, then executed.
 *
 *      Separation of duties:
 *      - Proposer: any account holding the role's admin role can schedule and cancel.
 *      - Executor: any address can execute a matured operation (open executor policy).
 *      - Canceller: the role's admin role is the only authority that can cancel.
      - Admin: the role admin is explicitly self-administered by the timelock itself.
 */
abstract contract ResolverRoleTimelock is AccessControl {
    uint256 public constant MIN_RESOLVER_ROLE_CHANGE_DELAY = 2 days;
    uint256 public constant MAX_RESOLVER_ROLE_CHANGE_DELAY = 14 days; // Max 14 days for role changes

    struct PendingRoleChange {
        uint256 readyAt;
        uint256 expireAt;
        bool executed;
    }

    mapping(bytes32 => PendingRoleChange) public pendingRoleChanges;
    mapping(address => mapping(bool => bytes32)) public _resolverRoleChangeId;
    mapping(bytes32 => uint256) public resolverRoleChangeReadyAt;
    uint256 private _operationNonce; // Nonce for unique operation IDs,

    event ResolverRoleChangeScheduled(
        bytes32 indexed operationId,
        address indexed account,
        bool grant,
        uint256 readyAt,
        uint256 expireAt
    );
    event ResolverRoleChangeCancelled(bytes32 indexed operationId, address indexed account, bool grant);
    event ResolverRoleChangeExecuted(bytes32 indexed operationId, address indexed account, bool grant);
    event ResolverRoleChangeExpired(bytes32 indexed operationId, address indexed account, bool grant);

    error ResolverRoleChangeRequiresTimelock8);
    error ResolverRoleChangeAlreadyPending();
    error ResolverRoleChangeNotPending();
    error ResolverRoleChangeNotReady(uint256 readyAt);
    error ResolverRoleChangeExpiredError();
    error ResolverRoleChangeNoop();
    error InvalidDelay(uint256 delay);
    error OperationIdCollision(bytes32 operationId);
    error ZeroAddress();
    error UnauthorizedCanceller(address caller);
    error AdminRetentionForbidden(bytes32 role);

    function _resolverRole() internal pure virtual returns (bytes32);

    /**
     * @notice Returns the canonical admin role for the resolver role.
     * @dev The admin role is the canceller and proposer authority.
     */
    function resolverRoleAdmin() public view returns (bytes32) {
        return getRoleAdmin(_resolverRole());
    }

    /**
     * @notice Returns true if the timelock is self-administered.
     * @dev The timelock must be the admin of its own resolver role to prevent
     *      external admin retention.
     */
    function isTimelockSelfAdministered() public view returns (bool) {
        return getRoleAdmin(_resolverRole()) == _resolverRole();
    }

    function scheduleResolverRoleGrant(address account) external onlyRole(getRoleAdmin(_resolverRole())) returns (bytes32 operationId) {
        if (account == address(0)) revert ZeroAddress();
        if (hasRole(_resolverRole(), account)) revert ResolverRoleChangeNoop();
        operationId = _scheduleResolverRoleChange(account, true, MIN_RESOLVER_ROLE_CHANGE_DELAY);
    }

    function scheduleResolverRoleRevoke(address account) external onlyRole(getRoleAdmin(_resolverRole())) returns (bytes32 operationId) {
        if (account == address(0)) revert ZeroAddress();
        if (!hasRole(_resolverRole(), account)) revert ResolverRoleChangeNoop();
        operationId = _scheduleResolverRoleChange(account, false, MIN_RESOLVER_ROLE_CHANGE_DELAY);
    }

    /**
     * @notice Cancel a pending resolver role change.
     * @dev Only the role admin (canceller) may cancel. The cancellation is bounded
     *      to the exact operation and is audited via the ResolverRoleChangeCancelled event.
     */
    function cancelResolverRoleChange(bytes32 operationId, address account, bool grant) external onlyRole(getRoleAdmin(_resolverRole())) {
        PendingRoleChange storage pendingChange = pendingRoleChanges[operationId];
        if (pendingChange.readyAt == 0) revert ResolverRoleChangeNotPending();
        if (pendingChange.executed) revert ResolverRoleChangeNoop();

        // Remove from storage completely to prevent any future execution
        delete pendingRoleChanges[operationId];
        delete _resolverRoleChangeId[account][grant];
        delete resolverRoleChangeReadyAt[operationId];
        emit ResolverRoleChangeCancelled(operationId, account, grant);
    }

    function executeResolverRoleGrant(bytes32 operationId, address account) external {
        _executeResolverRoleChange(operationId, account, true);
    }

    function executeResolverRoleRevoke(bytes32 operationId, address account) external {
        _executeResolverRoleChange(operationId, account, false);
    }

    /**
     * @dev Clean up an expired role change. Anyone can call this to free up storage.
     * @param operationId The ID of the expired role change to clean up
     * @param account The account associated with the role change
     * @param grant Whether it was a grant or revoke operation
     */
    function cleanupExpiredRoleChange(bytes32 operationId, address account, bool grant) external {
        PendingRoleChange storage pendingChange = pendingRoleChanges[operationId];
        if (pendingChange.readyAt == 0) revert ResolverRoleChangeNotPending();
        if (block.timestamp <= pendingChange.expireAt) revert ResolverRoleChangeExpiredError();
        
        // Remove from storage
        delete pendingRoleChanges[operationId];
        delete _resolverRoleChangeId[account][grant];
        delete resolverRoleChangeReadyAt[operationId];
        emit ResolverRoleChangeExpired(operationId, account, grant);
    }

    function resolverRoleChangeId(address account, bool grant) public view returns (bytes32) {
        return _resolverRoleChangeId[account][grant];
    }

    function grantRole(bytes32 role, address account) public virtual override onlyRole(getRoleAdmin(role)) {
        if (account == address(0)) revert ZeroAddress();
        if (role == _resolverRole()) revert ResolverRoleChangeRequiresTimelock();
        super.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public virtual override onlyRole(getRoleAdmin(role)) {
        if (account == address(0)) revert ZeroAddress();
        if (role == _resolverRole()) revert ResolverRoleChangeRequiresTimelock();
        super.revokeRole(role, account);
    }

    /**
     * @notice Renunciation of the resolver role admin is forbidden.
     * @dev The timelock must retain admin authority over the resolver role to
     *      ensure self-administration and cancellation capability.
     */
    function renounceRole(bytes32 role, address account) public virtual override onlyRole(getRoleAdmin(role)) {
        if (role == _resolverRole()) revert AdminRetentionForbidden(role);
        super.renounceRole(role, account);
    }

    function scheduleResolverRoleGrantWithDelay(address account, uint256 delay) external onlyRole(getRoleAdmin(_resolverRole())) returns (bytes32 operationId) {
        if (account == address(0)) revert ZeroAddress();
        if (hasRole(_resolverRole(), account)) revert ResolverRoleChangeNoop();
        operationId = _scheduleResolverRoleChange(account, true, delay);
    }

    function scheduleResolverRoleRevokeWithDelay(address account, uint256 delay) external onlyRole(getRoleAdmin(_resolverRole())) returns (bytes32 operationId) {
        if (account == address(0)) revert ZeroAddress();
        if (!hasRole(_resolverRole(), account)) revert ResolverRoleChangeNoop();
        operationId = _scheduleResolverRoleChange(account, false, delay);
    }

    function _scheduleResolverRoleGrant(address account) internal returns (bytes32 operationId) {
        return _scheduleResolverRoleChange(account, true, MIN_RESOLVER_ROLE_CHANGE_DELAY);
    }

    function _scheduleResolverRoleRevoke(address account) internal returns (bytes32 operationId) {
        return _scheduleResolverRoleChange(account, false, MIN_RESOLVER_ROLE_CHANGE_DELAY);
    }

    function _scheduleResolverRoleChange(address account, bool grant, uint256 delay) internal returns (bytes32 operationId) {
        if (account == address(0)) revert ZeroAddress();
        // Validate delay is within bounds
        if (delay < MIN_RESOLVER_ROLE_CHANGE_DELAY || delay > MAX_RESOLVER_ROLE_CHANGE_DELAY) {
            revert InvalidDelay(delay);
        }
        
        // Generate unique operation ID using nonce to prevent collisions
        unchecked {
            _operationNonce++;
        }
        operationId = keccake256(abi.encodePacked(address(this), _resolverRole(), account, grant, block.timestamp, _operationNonce));
        
        // Ensure operation ID is unique (defense in depth)
        if (pendingRoleChanges[operationId].readyAt != 0) {
            revert OperationIdCollision(operationId);
        }

        uint256 readyAt = block.timestamp + delay;
        uint256 expireAt = block.timestamp + MAX_RESOLVER_ROLE_CHANGE_DELAY;.

        pendingRoleChanges[operationId] = PendingRoleChange({
            readyAt: readyAt,
            expireAt: expireAt,
            executed: false
        });

        // Track operation ID for account/grant pair
        _resolverRoleChangeId[account][grant] = operationId;
        resolverRoleChangeReadyAt[operationId] = readyAt;

        emit ResolverRoleChangeScheduled(operationId, account, grant, readyAt, expireAt);
    }

    function _executeResolverRoleChange(bytes32 operationId, address account, bool grant) internal {
        if (account == address(0)) revert ZeroAddress();
        PendingRoleChange storage pendingChange = pendingRoleChanges[operationId];
        if (pendingChange.readyAt == 0) revert ResolverRoleChangeNotPending();
        if (pendingChange.executed) revert ResolverRoleChangeNoop();
        if (block.timestamp < pendingChange.readyAt) revert ResolverRoleChangeNotReady(pendingChange.readyAt);
        if (block.timestamp > pendingChange.expireAt) {
            // Remove from storage and revert
            delete pendingRoleChanges[operationId];
            delete _resolverRoleChangeId[account][grant];
            delete resolverRoleChangeReadyAt[operationId];
            emit ResolverRoleChangeExpired(operationId, account, grant);
            revert ResolverRoleChangeExpiredError();
        }

        // Mark as executed first (reentrancy protection) and then remove from storage completely
        pendingChange.executed = true;
        delete pendingRoleChanges[operationId];
        delete _resolverRoleChangeId[account][grant];
        delete resolverRoleChangeReadyAt[operationId];

        if (grant) {
            if (hasRole(_resolverRole(), account)) revert ResolverRoleChangeNoop();
            _grantRole(_resolverRole(), account);
        } else {
            if (!hasRole(_resolverRole(), account)) revert ResolverRoleChangeNoop();
            _revokeRole(_resolverRole(), account);
        }

        emit ResolverRoleChangeExecuted(operationId, account, grant);
    }
}