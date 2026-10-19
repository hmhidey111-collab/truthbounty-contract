// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IGovernanceAuthorityBoundaries} from "./IGovernanceAuthorityBoundaries.sol";
import {GovernanceAuthorityMatrix} from "./libraries/GovernanceAuthorityMatrix.sol";

/**
 * @title GovernanceAuthorityBoundaries
 * @notice On-chain publication and enforcement of the canonical V2 authority boundaries.
 * @dev The capability matrix is immutable (see {GovernanceAuthorityMatrix}); this contract records
 *      which account is accountable for each authority role. A role can be bound once at a time and
 *      an account can hold at most one role, so overlapping authority cannot be configured. The
 *      bootstrap admin must hand AUTHORITY_ADMIN_ROLE to the timelock after deployment so that
 *      authority configuration is governed and timelocked.
 */
contract GovernanceAuthorityBoundaries is IGovernanceAuthorityBoundaries, AccessControl {
    bytes32 public constant AUTHORITY_ADMIN_ROLE = keccak256("AUTHORITY_ADMIN_ROLE");

    /// @dev Minimum permitted timelock delay (1 hour).
    uint256 internal constant MIN_DELAY = 1 hours;
    /// @dev Maximum permitted timelock delay (30 days).
    uint256 internal constant MAX_DELAY = 30 days;
    /// @dev Minimum scheduling lead time before a delay change can be applied.
    uint256 internal constant DELAY_CHANGE_MIN_LEAD = 2 days;
    /// @dev Grace window after ETA during which a scheduled operation remains executable.
    uint256 internal constant GRACE_PERIOD = 14 days;

    /// @dev Current enforced timelock delay.
    uint256 private _delay;

    /// @dev Must match {GovernanceAuthorityMatrix.ROLE_COUNT}; asserted by the boundary test suite.
    uint256 internal constant ROLE_COUNT = 7;
    /// @dev Must match {GovernanceAuthorityMatrix.CAPABILITY_COUNT}; asserted by the boundary test suite.
    uint256 internal constant CAPABILITY_COUNT = 11;

    address[ROLE_COUNT] private _authorityAccount;
    bool[ROLE_COUNT] private _authorityBound;
    mapping(address => uint256) private _roleIndexPlusOne;

    struct Operation {
        address target;
        uint256 value;
        bytes data;
        uint256 eta;
        bool executed;
        bool cancelled;
    }

    mapping(bytes32 => Operation) private _operations;
    mapping(bytes32 => bool) private _operationScheduled;
    mapping(bytes32 => bool) private _delayChangeScheduled;
    uint256 private _pendingDelay;
    uint256 private _pendingDelayEta;

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAuthorityAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AUTHORITY_ADMIN_ROLE, admin);
    }

    /// @dev Initializes the timelock delay to MIN_DELAY; called once by the bootstrap admin.
    function initializeDelay() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_delay != 0) revert DelayAlreadyInitialized();
        _delay = MIN_DELAY;
        emit DelayInitialized(MIN_DELAY);
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function bindAuthority(AuthorityRole role, address account) external onlyRole(AUTHORITY_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAuthorityAddress();

        uint256 index = uint256(role);
        if (_authorityBound[index]) revert AuthorityAlreadyBound(role, _authorityAccount[index]);

        uint256 existing = _roleIndexPlusOne[account];
        if (existing != 0) {
            revert OverlappingAuthority(account, AuthorityRole(existing - 1), role);
        }

        _authorityBound[index] = true;
        _authorityAccount[index] = account;
        _roleIndexPlusOne[account] = index + 1;

        emit AuthorityBoundaryDeclared(role, account);
    }

    /// @dev Returns the current enforced timelock delay.
    function delay() external view returns (uint256) {
        return _delay;
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function revokeAuthority(AuthorityRole role) external onlyRole(AUTHORITY_ADMIN_ROLE) {
        uint256 index = uint256(role);
        if (!_authorityBound[index]) revert AuthorityNotBound(role);

        address account = _authorityAccount[index];
        _authorityBound[index] = false;
        _authorityAccount[index] = address(0);
        delete _roleIndexPlusOne[account];

        emit AuthorityBoundaryRevoked(role, account);
    }

    /// @dev Computes a collision-safe operation id binding target, value, data, predecessor and salt.
    function hashOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, predecessor, salt));
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function authorityOf(AuthorityRole role) external view returns (address) {
        return _authorityAccount[uint256(role)];
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function isAuthorityBound(AuthorityRole role) external view returns (bool) {
        return _authorityBound[uint256(role)];
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function boundRoleOf(address account) external view returns (AuthorityRole role, bool bound) {
        uint256 stored = _roleIndexPlusOne[account];
        if (stored == 0) {
            return (AuthorityRole.GOVERNOR, false);
        }
        return (AuthorityRole(stored - 1), true);
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function isCapabilityAllowed(AuthorityRole role, Capability capability) external pure returns (bool) {
        return GovernanceAuthorityMatrix.isAllowed(role, capability);
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function isCapabilityExclusive(Capability capability) external pure returns (bool) {
        return GovernanceAuthorityMatrix.isExclusive(capability);
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function soleRoleForCapability(Capability capability) external pure returns (AuthorityRole) {
        return GovernanceAuthorityMatrix.soleRoleFor(capability);
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function rolesForCapability(Capability capability) external pure returns (AuthorityRole[] memory) {
        return GovernanceAuthorityMatrix.rolesFor(capability);
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function capabilitiesOf(AuthorityRole role) external pure returns (Capability[] memory) {
        return GovernanceAuthorityMatrix.capabilitiesFor(role);
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function isAuthorizedFor(address account, Capability capability) external view returns (bool) {
        uint256 stored = _roleIndexPlusOne[account];
        if (stored == 0) {
            return false;
        }
        return GovernanceAuthorityMatrix.isAllowed(AuthorityRole(stored - 1), capability);
    }

    /// @dev Schedules a delay change; the new delay must be within bounds and cannot take effect immediately.
    function scheduleDelayChange(uint256 newDelay) external onlyRole(AUTHORITY_ADMIN_ROLE) {
        if (newDelay < MIN_DELAY || newDelay > MAX_DELAY) revert DelayOutOfBounds(newDelay);
        if (_delayChangeScheduled[keccak256(abi.encode(newDelay))]) revert DelayChangeAlreadyScheduled(newDelay);
        if (newDelay < _delay) revert DelayCannotDecreaseImmediately(_delay, newDelay);

        uint256 eta = block.timestamp + DELAY_CHANGE_MIN_LEAD;
        _pendingDelay = newDelay;
        _pendingDelayEta = eta;
        _delayChangeScheduled[keccak256(abi.encode(newDelay))] = true;

        emit DelayChangeScheduled(newDelay, eta);
    }

    /// @dev Applies a previously scheduled delay change once its lead time has elapsed.
    function applyDelayChange(uint256 newDelay) external onlyRole(AUTHORITY_ADMIN_ROLE) {
        bytes32 key = keccak256(abi.encode(newDelay));
        if (!_delayChangeScheduled[key]) revert DelayChangeNotScheduled(newDelay);
        if (block.timestamp < _pendingDelayEta) revert DelayChangeNotReady(_pendingDelayEta);
        if (newDelay != _pendingDelay) revert DelayChangeMismatch(_pendingDelay, newDelay);

        delete _delayChangeScheduled[key];
        _pendingDelay = 0;
        _pendingDelayEta = 0;
        _delay = newDelay;

        emit DelayChanged(newDelay);
    }

    /// @dev Cancels a pending delay change.
    function cancelDelayChange(uint256 newDelay) external onlyRole(AUTHORITY_ADMIN_ROLE) {
        bytes32 key = keccak256(abi.encode(newDelay));
        if (!_delayChangeScheduled[key]) revert DelayChangeNotScheduled(newDelay);
        delete _delayChangeScheduled[key];
        _pendingDelay = 0;
        _pendingDelayEta = 0;
        emit DelayChangeCancelled(newDelay);
    }

    /// @dev Schedules a timelocked operation with predecessor and salt semantics.
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external onlyRole(AUTHORITY_ADMIN_ROLE) returns (bytes32 id) {
        if (target == address(0)) revert ZeroAuthorityAddress();
        if (_delay == 0) revert DelayNotInitialized();
        if (predecessor != bytes32(0) && !_operations[predecessor].executed) {
            revert PredecessorNotExecuted(predecessor);
        }

        id = hashOperation(target, value, data, predecessor, salt);
        if (_operationScheduled[id]) revert OperationAlreadyScheduled(id);

        uint256 eta = block.timestamp + _delay;
        _operations[id] = Operation({
            target: target,
            value: value,
            data: data,
            eta: eta,
            executed: false,
            cancelled: false
        });
        _operationScheduled[id] = true;

        emit OperationScheduled(id, target, value, data, predecessor, salt, eta);
    }

    /// @dev Executes a scheduled operation if it is ready, not expired, and not cancelled.
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external payable onlyRole(AUTHORITY_ADMIN_ROLE) returns (bytes memory result) {
        bytes32 id = hashOperation(target, value, data, predecessor, salt);
        Operation storage op = _operations[id];

        if (!_operationScheduled[id]) revert OperationNotScheduled(id);
        if (op.cancelled) revert OperationCancelled(id);
        if (op.executed) revert OperationAlreadyExecuted(id);
        if (block.timestamp < op.eta) revert OperationNotReady(op.eta);
        if (block.timestamp > op.eta + GRACE_PERIOD) revert OperationExpired(op.eta);

        op.executed = true;

        (bool ok, bytes memory ret) = op.target.call{value: op.value}(op.data);
        if (!ok) revert OperationCallFailed(id);
        result = ret;

        emit OperationExecuted(id, op.target, op.value, op.data);
    }

    /// @dev Cancels a scheduled operation, preventing execution.
    function cancel(bytes32 id) external onlyRole(AUTHORITY_ADMIN_ROLE) {
        Operation storage op = _operations[id];
        if (!_operationScheduled[id]) revert OperationNotScheduled(id);
        if (op.executed) revert OperationAlreadyExecuted(id);
        if (op.cancelled) revert OperationCancelled(id);
        op.cancelled = true;
        emit OperationCancelled(id);
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function requireCapability(AuthorityRole role, Capability capability) external pure {
        GovernanceAuthorityMatrix.enforce(role, capability);
    }

    /// @inheritdoc IGovernanceAuthorityBoundaries
    function publishAuthorityMatrix() external {
        emit GovernanceAuthorityMatrixPublished(msg.sender, ROLE_COUNT, CAPABILITY_COUNT);
    }

    /// @dev Self-administration guard: only the contract itself may invoke self-calls.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert SelfCallRequired();
        _;
    }
}
