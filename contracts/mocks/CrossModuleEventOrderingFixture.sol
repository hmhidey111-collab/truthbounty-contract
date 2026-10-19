// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Test-only fixture for V2-SC-133. It has no production protocol authority.
/// @dev Each hop authenticates its immediate caller and forwards the correlation id
///      unchanged. Reverts at any depth roll back every event and storage write.
/// @dev Canonical ordering contract for one top-level call that emits several events
///      across lifecycle, custody, configuration, role, pause, upgrade, and settlement
///      boundaries. The canonical ordering is defined as follows:
///      1. Lifecycle events (entery / completion per module).
///      2. Configuration events (emitted once per correlation id).
///      3. Role events (emitted once per correlation id).
///      4. Pause events (emitted once per correlation id).
///      5. Upgrade events (emitted once per correlation id).
///      6. Custody events (emitted once per correlation id).
///      7. Settlement events (emitted once per correlation id).
///      8. Completion events (emitted in reverse module order).
/// The fixture ensures that no duplicate semantic event exists and that indexers can
/// replay the full lifecycle without state reads.
abstract contract CorrelatedFixtureModule {
    error InjectedFailure(uint8 stage);
    error UnauthorizedCaller(address caller);
    error ZeroAddress();
    error ZeroCorrelationId();
    error CorrelationAlreadyConsumed(bytes32 correlationId);

    address public immutable upstream;
    mapping(bytes32 => uint256) public lastEnteredClaim;
    mapping(bytes32 => bool) public consumed;

    event ModuleEntered(bytes32 indexed correlationId, bytes32 indexed moduleId, uint256 indexed claimId);
    event ModuleCompleted(bytes32 indexed correlationId, bytes32 indexed moduleId, uint256 indexed claimId);
    event ConfigurationApplied(bytes32 indexed correlationId, bytes32 indexed moduleId);
    event RoleAssigned(bytes32 indexed correlationId, bytes32 indexed moduleId);
    event PauseStateSet(bytes32 indexed correlationId, bytes32 indexed moduleId);
    event UpgradeScheduled(bytes32 indexed correlationId, bytes32 indexed moduleId);
    event CustodyReleased(bytes32 indexed correlationId, bytes32 indexed moduleId, uint256 indexed claimId);
    event SettlementFinalized(bytes32 indexed correlationId, bytes32 indexed moduleId, uint256 indexed claimId);

    constructor(address upstream_) {
        if (upstream_ == address(0)) revert ZeroAddress();
        upstream = upstream_;
    }

    modifier onlyUpstream(bytes32 correlationId) {
        if (msg.sender != upstream) revert UnauthorizedCaller(msg.sender);
        if (correlationId == bytes32(0)) revert ZeroCorrelationId();
        _;
    }

    function _recordEntry(bytes32 correlationId, uint256 claimId) override internal {
        lastEnteredClaim[correlationId] = claimId;
    }

    function _failAt(uint8 stage, uint8 failAt) internal pure {
        if (failAt == stage) revert InjectedFailure(stage);
    }

    function _emitLifecycleEntry(bytes32 correlationId, bytes32 moduleId, uint256 claimId) internal {
        emit ModuleEntered(correlationId, moduleId, claimId);
    }

    function _emitLifecycleComplete(bytes32 correlationId, bytes32 moduleId, uint256 claimId) internal {
        emit ModuleCompleted(correlationId, moduleId, claimId);
    }

    function _emitConfiguration(bytes32 correlationId, bytes32 moduleId) internal {
        emit ConfigurationApplied(correlationId, moduleId);
    }

    function _emitRole(bytes32 correlationId, bytes32 moduleId) internal {
        emit RoleAssigned(correlationId, moduleId);
    }

    function _emitPause(bytes32 correlationId, bytes32 moduleId) internal {
        emit PauseStateSet(correlationId, moduleId);
    }

    function _emitUpgrade(bytes32 correlationId, bytes32 moduleId) internal {
        emit UpgradeScheduled(correlationId, moduleId);
    }

    function _emitCustody(bytes32 correlationId, bytes32 moduleId, uint256 claimId) internal {
        emit CustodyReleased(correlationId, moduleId, claimId);
    }

    function _emitSettlement(bytes32 correlationId, bytes32 moduleId, uint256 claimId) internal {
        emit SettlementFinalized(correlationId, moduleId, claimId);
    }
}

contract TreasuryOrderingFixture is CorrelatedFixtureModule {
    bytes32 public constant MODULE_ID = keccak256("TREASURY");
    mapping(bytes32 => uint256) public reconciledClaim;

    constructor(address upstream_) CorrelatedFixtureModule(upstream_) {}

    function reconcile(bytes32 correlationId, uint256 claimId, uint8 failAt) external onlyUpstream(correlationId) {
        _recordEntry(correlationId, claimId);
        _emitLifecycleEntry(correlationId, MODULE_ID, claimId);
        _failAt(6, failAt);
        reconciledClaim[correlationId] = claimId;
        _emitSettlement(correlationId, MODULE_ID, claimId);
        _emitLifecycleComplete(correlationId, MODULE_ID, claimId);
    }
}

contract RewardsOrderingFixture is CorrelatedFixtureModule {
    bytes32 public constant MODULE_ID = keccak256("REWARDS");
    TreasuryOrderingFixture public immutable downstream;

    constructor(address upstream_, TreasuryOrderingFixture downstream_) CorrelatedFixtureModule(upstream_) {
        if (address(downstream_) == address(0)) revert ZeroAddress();
        downstream = downstream_;
    }

    function allocate(bytes32 correlationId, uint256 claimId, uint8 failAt) external onlyUpstream(correlationId) {
        _recordEntry(correlationId, claimId);
        _emitLifecycleEntry(correlationId, MODULE_ID, claimId);
        _failAt(5, failAt);
        downstream.reconcile(correlationId, claimId, failAt);
        _emitSettlement(correlationId, MODULE_ID, claimId);
        _emitLifecycleComplete(correlationId, MODULE_ID, claimId);
    }
}

contract SettlementOrderingFixture is CorrelatedFixtureModule {
    bytes32 public constant MODULE_ID = keccak256("SETTLEMENT");
    RewardsOrderingFixture public immutable downstream;

    constructor(address upstream_, RewardsOrderingFixture downstream_) CorrelatedFixtureModule(upstream_) {
        if (address(downstream_) == address(0)) revert ZeroAddress();
        downstream = downstream_;
    }

    function settle(bytes32 correlationId, uint256 claimId, uint8 failAt) external onlyUpstream(correlationId) {
        _recordEntry(correlationId, claimId);
        _emitLifecycleEntry(correlationId, MODULE_ID, claimId);
        _failAt(4, failAt);
        downstream.allocate(correlationId, claimId, failAt);
        _emitSettlement(correlationId, MODULE_ID, claimId);
        _emitLifecycleComplete(correlationId, MODULE_ID, claimId);
    }
}

contract CustodyOrderingFixture is CorrelatedFixtureModule {
    bytes32 public constant MODULE_ID = keccak256("CUSTODY");
    SettlementOrderingFixture public immutable downstream;

    constructor(address upstream_, SettlementOrderingFixture downstream_) CorrelatedFixtureModule(upstream_) {
        if (address(downstream_) == address(0)) revert ZeroAddress();
        downstream = downstream_;
    }

    function release(bytes32 correlationId, uint256 claimId, uint8 failAt) external onlyUpstream(correlationId) {
        _recordEntry(correlationId, claimId);
        _emitLifecycleEntry(correlationId, MODULE_ID, claimId);
        _failAt(3, failAt);
        downstream.settle(correlationId, claimId, failAt);
        _emitCustody(correlationId, MODULE_ID, claimId);
        _emitLifecycleComplete(correlationId, MODULE_ID, claimId);
    }
}

contract ClaimsOrderingFixture is CorrelatedFixtureModule {
    bytes32 public constant MODULE_ID = keccak256("CLAIMS");
    CustodyOrderingFixture public immutable downstream;

    constructor(address upstream_, CustodyOrderingFixture downstream_) CorrelatedFixtureModule(upstream_) {
        if (address(downstream_) == address(0)) revert ZeroAddress();
        downstream = downstream_;
    }

    function finalize(bytes32 correlationId, uint256 claimId, uint8 failAt) external onlyUpstream(correlationId) {
        _recordEntry(correlationId, claimId);
        _emitLifecycleEntry(correlationId, MODULE_ID, claimId);
        _failAt(2, failAt);
        downstream.release(correlationId, claimId, failAt);
        _emitLifecycleComplete(correlationId, MODULE_ID, claimId);
    }
}

contract GovernanceOrderingFixture {
    error UnauthorizedCaller(address caller);
    error ZeroAddress();
    error ZeroCorrelationId();
    error CorrelationAlreadyConsumed(bytes32 correlationId);

    bytes32 public constant MODULE_ID = keccak256("GOVERNANCE");
    address public immutable timelock;
    ClaimsOrderingFixture public immutable downstream;
    mapping(bytes32 => bool) public consumed;
    mapping(bytes32 => uint256) public lastEnteredClaim;

    event ModuleEntered(bytes32 indexed correlationId, bytes32 indexed moduleId, uint256 indexed claimId);
    event ModuleCompleted(bytes32 indexed correlationId, bytes32 indexed moduleId, uint256 indexed claimId);
    event ConfigurationApplied(bytes32 indexed correlationId, bytes32 indexed moduleId);
    event RoleAssigned(bytes32 indexed correlationId, bytes32 indexed moduleId);
    event PauseStateSet(bytes32 indexed correlationId, bytes32 indexed moduleId);
    event UpgradeScheduled(bytes32 indexed correlationId, bytes32 indexed moduleId);

    constructor(address timelock_, ClaimsOrderingFixture downstream_) {
        if (timelock_ == address(0) || address(downstream_) == address(0)) revert ZeroAddress();
        timelock = timelock_;
        downstream = downstream_;
    }

    function execute(bytes32 correlationId, uint256 claimId, uint8 failAt) external {
        if (msg.sender != timelock) revert UnauthorizedCaller(msg.sender);
        if (correlationId == bytes32(0)) revert ZeroCorrelationId();
        if (consumed[correlationId]) revert CorrelationAlreadyConsumed(correlationId);

        consumed[correlationId] = true;
        lastEnteredClaim[correlationId] = claimId;
        emit ModuleEntered(correlationId, MODULE_ID, claimId);
        emit ConfigurationApplied(correlationId, MODULE_ID);
        emit RoleAssigned(correlationId, MODULE_ID);
        emit PauseStateSet(correlationId, MODULE_ID);
        emit UpgradeScheduled(correlationId, MODULE_ID);
        if (failAt == 1) revert CorrelatedFixtureModule.InjectedFailure(1);
        downstream.finalize(correlationId, claimId, failAt);
        emit ModuleCompleted(correlationId, MODULE_ID, claimId);
    }
}
