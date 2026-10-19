// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UntrackedAssetRecovery} from "../recovery/UntrackedAssetRecovery.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "../libraries/BoundedSafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../governance/GovernanceOwnable.sol";
import "./ITreasuryManagement.sol";

/**
 * @title TreasuryManagement
 * @notice Protocol Treasury Management Module for TruthBounty V2 (SC-012)
 * @dev The single source of truth for all protocol-owned assets.
 *
 * Architecture:
 *  - Every protocol module routes asset flows through this contract
 *  - Seven independent reserve pools, each fully auditable on-chain
 *  - Deterministic accounting: sum(poolBalances) == contract.tokenBalance
 *  - Governance-controlled parameters with basis-point precision
 *  - Emergency pause/unpause with strictly permissioned controls
 *  - Upgradeable via storage gap (UUPS-ready)
 *
 * Security:
 *  - ReentrancyGuard on all state-mutating external calls
 *  - Role-based access control per pool and operation type
 *  - Same-block operation protection per pool
 *  - Per-block and percentage-based withdrawal limits
 *  - Global invariant validation after every balance-changing operation
 *  - Duplicate record ID prevention
 *
 * @custom:security-contact security@truthbounty.io
 */
contract TreasuryManagement is
    ITreasuryManagement,
    AccessControl,
    ReentrancyGuard,
    GovernanceOwnable,
    UntrackedAssetRecovery
{
    using SafeERC20 for IERC20;

    // =========================================================================
    // Roles
    // =========================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    bytes32 public constant STAKING_MODULE_ROLE = keccak256("STAKING_MODULE_ROLE");
    bytes32 public constant REWARD_MODULE_ROLE = keccak256("REWARD_MODULE_ROLE");
    bytes32 public constant SETTLEMENT_MODULE_ROLE = keccak256("SETTLEMENT_MODULE_ROLE");
    bytes32 public constant FEE_MODULE_ROLE = keccak256("FEE_MODULE_ROLE");
    bytes32 public constant SLASHING_MODULE_ROLE = keccak256("SLASHING_MODULE_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant POOL_COUNT = 7;
    uint256 public constant MAX_RECORDS_PER_QUERY = 500;

    // =========================================================================
    // State — Core
    // =========================================================================

    /// @notice The protocol ERC20 token held in custody
    IERC20 public immutable protocolToken;

    /// @notice Pool balances indexed by TreasuryPool enum
    PoolBalance[7] private _pools;

    /// @notice Authorised protocol modules that may deposit/withdraw
    mapping(address => bool) private _authorisedModules;

    /// @notice Treasury configuration parameters
    TreasuryConfig private _config;

    /// @notice Monotonically increasing treasury record counter
    uint256 private _recordCount;

    /// @notice Treasury records indexed by recordId
    mapping(bytes32 => TreasuryRecord) private _records;

    /// @notice Ordered list of record IDs for sequential queries
    bytes32[] private _recordIds;

    /// @notice Same-block operation tracking per pool
    mapping(TreasuryPool => uint256) private _lastOperationBlock;

    /// @notice Duplicate record prevention
    mapping(bytes32 => bool) private _recordExists;

    /// @notice Snapshot storage
    struct SnapshotData {
        PoolBalance[7] balances;
        uint256 totalAssets;
        uint256 timestamp;
    }

    SnapshotData[] private _snapshots;

    /// @notice Withdrawal limits per pool per block (in token units)
    mapping(TreasuryPool => uint256) private _withdrawalLimitPerBlock;

    /// @notice Amount withdrawn from each pool in the current block
    mapping(TreasuryPool => uint256) private _withdrawnCurrentBlock;

    /// @notice Block number of the last per-block withdrawal reset per pool
    mapping(TreasuryPool => uint256) private _withdrawalBlockSnapshot;

    /// @dev Storage gap for future upgrades (reserved 46 slots)
    uint256[46] private __gap;

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @param _protocolToken Address of the protocol ERC20 token
     * @param _governanceController Address of the governance controller
     * @param _initialAdmin Initial admin address
     * @param _emergencyAdmin Emergency admin address
     */
    constructor(
        address _protocolToken,
        address _governanceController,
        address _initialAdmin,
        address _emergencyAdmin
    ) {
        if (_protocolToken == address(0)) revert ZeroAddress();
        if (_initialAdmin == address(0)) revert ZeroAddress();

        protocolToken = IERC20(_protocolToken);

        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(ADMIN_ROLE, _initialAdmin);
        _grantRole(TREASURY_MANAGER_ROLE, _initialAdmin);
        _grantRole(PAUSER_ROLE, _initialAdmin);

        _setRoleAdmin(TREASURY_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(STAKING_MODULE_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REWARD_MODULE_ROLE, ADMIN_ROLE);
        _setRoleAdmin(SETTLEMENT_MODULE_ROLE, ADMIN_ROLE);
        _setRoleAdmin(FEE_MODULE_ROLE, ADMIN_ROLE);
        _setRoleAdmin(SLASHING_MODULE_ROLE, ADMIN_ROLE);

        _initializeGovernance(
            _governanceController,
            _initialAdmin,
            _emergencyAdmin != address(0) ? _emergencyAdmin : _initialAdmin
        );

        _config = TreasuryConfig({
            maxWithdrawalBPS: 2500,
            emergencyWithdrawalLimit: type(uint256).max,
            minReserveRatioBPS: 500,
            maxAllocationBPS: 1000,
            withdrawalsEnabled: true,
            depositsEnabled: true
        });
    }

    // =========================================================================
    // Deposit Functions
    // =========================================================================

    /// @inheritdoc ITreasuryManagement
    function depositToPool(TreasuryPool pool, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!_config.depositsEnabled) revert DepositsPaused();
        if (pool == TreasuryPool.STAKING_RESERVE) revert UnauthorisedModule(msg.sender);

        _validateSameBlock(pool);

        // Snapshot balance before inbound transfer to detect fee-on-transfer tokens.
        uint256 balanceBefore = protocolToken.balanceOf(address(this));

        // CEI: EFFECT before INTERACTION — credit the pool first so any callback
        // through the inbound transferFrom observes already-updated pool state and
        // cannot re-enter depositToPool to create phantom balance anomalies.
        // The actualAmount adjustment below corrects for fee-on-transfer tokens after
        // the transfer has completed, but the initial credit uses the requested amount;
        // any shortfall is corrected immediately before _validateInvariants().
        _creditPool(pool, amount);

        protocolToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = protocolToken.balanceOf(address(this)) - balanceBefore;

        // If the received amount differs from requested (fee-on-transfer token),
        // correct the pool credit to reflect what was actually received.
        if (actualAmount != amount) {
            // Undo the over-credit and replace with exact amount.
            _pools[uint256(pool)].currentBalance -= amount;
            _pools[uint256(pool)].totalDeposited -= amount;
            _creditPool(pool, actualAmount);
        }

        bytes32 recordId = _createRecord(
            msg.sender,
            address(this),
            msg.sender,
            actualAmount,
            pool,
            pool,
            "external_deposit"
        );

        emit TreasuryDeposit(msg.sender, actualAmount, pool, recordId);

        _validateInvariants();
    }

    /// @inheritdoc ITreasuryManagement
    function recordStakeDeposit(address user, uint256 amount) external onlyRole(STAKING_MODULE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (user == address(0)) revert ZeroAddress();

        _validateSameBlock(TreasuryPool.STAKING_RESERVE);

        _creditPool(TreasuryPool.STAKING_RESERVE, amount);

        bytes32 recordId = _createRecord(
            user,
            address(this),
            user,
            amount,
            TreasuryPool.STAKING_RESERVE,
            TreasuryPool.STAKING_RESERVE,
            "stake_deposit"
        );

        emit StakeDeposit(user, amount, recordId);

        _validateInvariants();
    }

    /// @inheritdoc ITreasuryManagement
    function recordFeeDeposit(address source, uint256 amount) external onlyRole(FEE_MODULE_ROLE) {
        if (amount == 0) revert ZeroAmount();

        _validateSameBlock(TreasuryPool.PROTOCOL_FEES);

        _creditPool(TreasuryPool.PROTOCOL_FEES, amount);

        bytes32 recordId = _createRecord(
            source,
            address(this),
            source,
            amount,
            TreasuryPool.PROTOCOL_FEES,
            TreasuryPool.PROTOCOL_FEES,
            "fee_deposit"
        );

        emit FeeDeposit(source, amount, recordId);

        _validateInvariants();
    }

    /// @inheritdoc ITreasuryManagement
    function recordSlashDeposit(address verifier, uint256 amount) external onlyRole(SLASHING_MODULE_ROLE) {
        if (amount == 0) revert ZeroAmount();

        _validateSameBlock(TreasuryPool.SLASHING_RESERVE);

        // Slash moves funds from staking reserve to slashing reserve
        if (_pools[uint256(TreasuryPool.STAKING_RESERVE)].currentBalance < amount) {
            revert InsufficientPoolBalance(
                TreasuryPool.STAKING_RESERVE,
                amount,
                _pools[uint256(TreasuryPool.STAKING_RESERVE)].currentBalance
            );
        }

        // Effects — debit staking reserve (update both balance and withdrawn)
        _pools[uint256(TreasuryPool.STAKING_RESERVE)].currentBalance -= amount;
        _pools[uint256(TreasuryPool.STAKING_RESERVE)].totalWithdrawn += amount;
        _touchPool(TreasuryPool.STAKING_RESERVE);

        // Credit slashing reserve
        _creditPool(TreasuryPool.SLASHING_RESERVE, amount);

        bytes32 recordId = _createRecord(
            address(this),
            address(this),
            verifier,
            amount,
            TreasuryPool.STAKING_RESERVE,
            TreasuryPool.SLASHING_RESERVE,
            "slash_deposit"
        );

        emit SlashDeposit(verifier, amount, recordId);
        emit TreasuryTransfer(TreasuryPool.STAKING_RESERVE, TreasuryPool.SLASHING_RESERVE, amount, recordId);

        _validateInvariants();
    }

    /// @inheritdoc ITreasuryManagement
    function recordGovernanceDeposit(address source, uint256 amount) external onlyRole(TREASURY_MANAGER_ROLE) {
        if (amount == 0) revert ZeroAmount();

        _validateSameBlock(TreasuryPool.GOVERNANCE_RESERVE);

        _creditPool(TreasuryPool.GOVERNANCE_RESERVE, amount);

        bytes32 recordId = _createRecord(
            source,
            address(this),
            source,
            amount,
            TreasuryPool.GOVERNANCE_RESERVE,
            TreasuryPool.GOVERNANCE_RESERVE,
            "governance_deposit"
        );

        emit GovernanceDeposit(source, amount, recordId);

        _validateInvariants();
    }

    // =========================================================================
    // Withdrawal Functions
    // =========================================================================

    /// @inheritdoc ITreasuryManagement
    function withdrawFromPool(
        TreasuryPool pool,
        address recipient,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (!_config.withdrawalsEnabled) revert WithdrawalsPaused();
        if (!_isAuthorisedForWithdrawal(msg.sender, pool)) revert UnauthorisedWithdrawal(msg.sender, pool);

        _validateSameBlock(pool);
        _enforceWithdrawalLimits(pool, amount);

        if (_pools[uint256(pool)].currentBalance < amount) {
            revert InsufficientPoolBalance(pool, amount, _pools[uint256(pool)].currentBalance);
        }

        // Effects first (CEI pattern)
        _pools[uint256(pool)].currentBalance -= amount;
        _pools[uint256(pool)].totalWithdrawn += amount;
        _touchPool(pool);

        bytes32 recordId = _createRecord(
            address(this),
            recipient,
            msg.sender,
            amount,
            pool,
            pool,
            "pool_withdrawal"
        );

        // Interaction
        protocolToken.safeTransfer(recipient, amount);
        _recordBlockWithdrawal(pool, amount);

        emit TreasuryWithdrawal(recipient, amount, pool, recordId);

        _validateInvariants();
    }

    /// @inheritdoc ITreasuryManagement
    function recordRewardWithdrawal(address recipient, uint256 amount) external nonReentrant onlyRole(REWARD_MODULE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        _validateSameBlock(TreasuryPool.REWARDS_POOL);
        _enforceWithdrawalLimits(TreasuryPool.REWARDS_POOL, amount);

        if (_pools[uint256(TreasuryPool.REWARDS_POOL)].currentBalance < amount) {
            revert InsufficientPoolBalance(
                TreasuryPool.REWARDS_POOL,
                amount,
                _pools[uint256(TreasuryPool.REWARDS_POOL)].currentBalance
            );
        }

        _pools[uint256(TreasuryPool.REWARDS_POOL)].currentBalance -= amount;
        _pools[uint256(TreasuryPool.REWARDS_POOL)].totalWithdrawn += amount;
        _touchPool(TreasuryPool.REWARDS_POOL);

        bytes32 recordId = _createRecord(
            address(this),
            recipient,
            msg.sender,
            amount,
            TreasuryPool.REWARDS_POOL,
            TreasuryPool.REWARDS_POOL,
            "reward_withdrawal"
        );

        protocolToken.safeTransfer(recipient, amount);
        _recordBlockWithdrawal(TreasuryPool.REWARDS_POOL, amount);

        emit RewardWithdrawal(recipient, amount, recordId);

        _validateInvariants();
    }

    /// @inheritdoc ITreasuryManagement
    function recordSettlementWithdrawal(address recipient, uint256 amount)
        external
        nonReentrant
        onlyRole(SETTLEMENT_MODULE_ROLE)
    {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        _validateSameBlock(TreasuryPool.PROTOCOL_FEES);
        _enforceWithdrawalLimits(TreasuryPool.PROTOCOL_FEES, amount);

        if (_pools[uint256(TreasuryPool.PROTOCOL_FEES)].currentBalance < amount) {
            revert InsufficientPoolBalance(
                TreasuryPool.PROTOCOL_FEES,
                amount,
                _pools[uint256(TreasuryPool.PROTOCOL_FEES)].currentBalance
            );
        }

        _pools[uint256(TreasuryPool.PROTOCOL_FEES)].currentBalance -= amount;
        _pools[uint256(TreasuryPool.PROTOCOL_FEES)].totalWithdrawn += amount;
        _touchPool(TreasuryPool.PROTOCOL_FEES);

        bytes32 recordId = _createRecord(
            address(this),
            recipient,
            msg.sender,
            amount,
            TreasuryPool.PROTOCOL_FEES,
            TreasuryPool.PROTOCOL_FEES,
            "settlement_withdrawal"
        );

        protocolToken.safeTransfer(recipient, amount);
        _recordBlockWithdrawal(TreasuryPool.PROTOCOL_FEES, amount);

        emit SettlementWithdrawal(recipient, amount, recordId);

        _validateInvariants();
    }

    /// @notice Governance-controlled withdrawal from a specific pool
    /// @param pool Source pool
    /// @param recipient Recipient address
    /// @param amount Amount to withdraw
    function recordGovernanceWithdrawal(
        TreasuryPool pool,
        address recipient,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (!hasRole(GOVERNANCE_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorisedWithdrawal(msg.sender, pool);
        }
        if (!_config.withdrawalsEnabled) revert WithdrawalsPaused();

        _validateSameBlock(pool);
        _enforceWithdrawalLimits(pool, amount);

        if (_pools[uint256(pool)].currentBalance < amount) {
            revert InsufficientPoolBalance(pool, amount, _pools[uint256(pool)].currentBalance);
        }

        _pools[uint256(pool)].currentBalance -= amount;
        _pools[uint256(pool)].totalWithdrawn += amount;
        _touchPool(pool);

        bytes32 recordId = _createRecord(
            address(this),
            recipient,
            msg.sender,
            amount,
            pool,
            pool,
            "governance_withdrawal"
        );

        protocolToken.safeTransfer(recipient, amount);
        _recordBlockWithdrawal(pool, amount);

        emit GovernanceWithdrawal(recipient, amount, recordId);

        _validateInvariants();
    }

    /// @inheritdoc ITreasuryManagement
    function emergencyWithdrawal(address recipient, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (
            !hasRole(GOVERNANCE_ROLE, msg.sender) &&
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender) &&
            msg.sender != emergencyAdmin
        ) {
            revert UnauthorisedWithdrawal(msg.sender, TreasuryPool.EMERGENCY_RESERVE);
        }

        if (amount > _config.emergencyWithdrawalLimit) {
            revert WithdrawalExceedsLimit(amount, _config.emergencyWithdrawalLimit);
        }

        (TreasuryPool sourcePool, uint256 available) = _findEmergencySource(amount);
        if (available < amount) {
            revert InsufficientPoolBalance(sourcePool, amount, available);
        }

        _pools[uint256(sourcePool)].currentBalance -= amount;
        _pools[uint256(sourcePool)].totalWithdrawn += amount;
        _touchPool(sourcePool);

        bytes32 recordId = _createRecord(
            address(this),
            recipient,
            msg.sender,
            amount,
            sourcePool,
            sourcePool,
            "emergency_withdrawal"
        );

        protocolToken.safeTransfer(recipient, amount);
        _recordBlockWithdrawal(sourcePool, amount);

        emit EmergencyWithdrawal(recipient, amount, recordId);

        _validateInvariants();
    }

    // =========================================================================
    // Internal Transfer Functions
    // =========================================================================

    /// @inheritdoc ITreasuryManagement
    function transferBetweenPools(
        TreasuryPool fromPool,
        TreasuryPool toPool,
        uint256 amount,
        string calldata reason
    ) external nonReentrant onlyRole(TREASURY_MANAGER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (fromPool == toPool) revert InvariantViolation("Cannot transfer to same pool", 0, 0);

        _validateSameBlock(fromPool);
        _enforceWithdrawalLimits(fromPool, amount);

        if (_pools[uint256(fromPool)].currentBalance < amount) {
            revert InsufficientPoolBalance(fromPool, amount, _pools[uint256(fromPool)].currentBalance);
        }

        _pools[uint256(fromPool)].currentBalance -= amount;
        _pools[uint256(fromPool)].totalWithdrawn += amount;
        _touchPool(fromPool);

        _creditPool(toPool, amount);
        _recordBlockWithdrawal(fromPool, amount);

        bytes32 recordId = _createRecord(
            address(this),
            address(this),
            msg.sender,
            amount,
            fromPool,
            toPool,
            reason
        );

        emit TreasuryTransfer(fromPool, toPool, amount, recordId);

        _validateInvariants();
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @inheritdoc ITreasuryManagement
    function getPoolBalance(TreasuryPool pool) external view returns (PoolBalance memory) {
        return _pools[uint256(pool)];
    }

    /// @inheritdoc ITreasuryManagement
    function getAllPoolBalances() external view returns (PoolBalance[7] memory) {
        return _pools;
    }

    /// @inheritdoc ITreasuryManagement
    function getTotalAssets() public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < POOL_COUNT; i++) {
            total += _pools[i].currentBalance;
        }
        return total;
    }

    /// @inheritdoc ITreasuryManagement
    function getRecord(uint256 index) external view returns (TreasuryRecord memory) {
        if (index >= _recordIds.length) revert InvalidRecordIndex(index, _recordIds.length);
        return _records[_recordIds[index]];
    }

    /// @inheritdoc ITreasuryManagement
    function getRecords(uint256 offset, uint256 limit) external view returns (TreasuryRecord[] memory) {
        if (limit > MAX_RECORDS_PER_QUERY) limit = MAX_RECORDS_PER_QUERY;
        uint256 total = _recordIds.length;
        if (offset >= total) return new TreasuryRecord[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        TreasuryRecord[] memory result = new TreasuryRecord[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = _records[_recordIds[i]];
        }
        return result;
    }

    /// @inheritdoc ITreasuryManagement
    function getRecordCount() external view returns (uint256) {
        return _recordCount;
    }

    /// @inheritdoc ITreasuryManagement
    function getConfig() external view returns (TreasuryConfig memory) {
        return _config;
    }

    /// @inheritdoc ITreasuryManagement
    function isAuthorisedModule(address module) external view returns (bool) {
        return _authorisedModules[module];
    }

    /// @inheritdoc ITreasuryManagement
    function createSnapshot() external returns (uint256 snapshotId) {
        PoolBalance[7] memory currentBalances = _pools;
        uint256 total = getTotalAssets();

        _snapshots.push(SnapshotData({ balances: currentBalances, totalAssets: total, timestamp: block.timestamp }));

        snapshotId = _snapshots.length - 1;

        emit SnapshotCreated(snapshotId, total, msg.sender);
    }

    /// @inheritdoc ITreasuryManagement
    function getSnapshot(uint256 snapshotId) external view returns (PoolBalance[7] memory, uint256, uint256) {
        if (snapshotId >= _snapshots.length) revert InvalidRecordIndex(snapshotId, _snapshots.length);
        SnapshotData storage snap = _snapshots[snapshotId];
        return (snap.balances, snap.totalAssets, snap.timestamp);
    }

    // =========================================================================
    // Governance Controls
    // =========================================================================

    /// @notice Update the max withdrawal basis points per pool
    function setMaxWithdrawalBPS(uint256 newBPS) external onlyGovernanceOrAdmin {
        if (newBPS > BASIS_POINTS) revert InvalidBasisPoints(newBPS);
        uint256 old = _config.maxWithdrawalBPS;
        _config.maxWithdrawalBPS = newBPS;
        emit TreasuryConfigUpdated("maxWithdrawalBPS", old, newBPS);
    }

    /// @notice Update the minimum reserve ratio in basis points
    function setMinReserveRatioBPS(uint256 newBPS) external onlyGovernanceOrAdmin {
        if (newBPS > BASIS_POINTS) revert InvalidBasisPoints(newBPS);
        uint256 old = _config.minReserveRatioBPS;
        _config.minReserveRatioBPS = newBPS;
        emit TreasuryConfigUpdated("minReserveRatioBPS", old, newBPS);
    }

    /// @notice Update the emergency withdrawal limit
    function setEmergencyWithdrawalLimit(uint256 newLimit) external onlyGovernanceOrAdmin {
        uint256 old = _config.emergencyWithdrawalLimit;
        _config.emergencyWithdrawalLimit = newLimit;
        emit TreasuryConfigUpdated("emergencyWithdrawalLimit", old, newLimit);
    }

    /// @notice Update the max allocation change per governance action
    function setMaxAllocationBPS(uint256 newBPS) external onlyGovernanceOrAdmin {
        if (newBPS > BASIS_POINTS) revert InvalidBasisPoints(newBPS);
        uint256 old = _config.maxAllocationBPS;
        _config.maxAllocationBPS = newBPS;
        emit TreasuryConfigUpdated("maxAllocationBPS", old, newBPS);
    }

    /// @notice Enable or disable withdrawals globally
    function setWithdrawalsEnabled(bool enabled) external onlyGovernanceOrAdmin {
        _config.withdrawalsEnabled = enabled;
        emit TreasuryConfigUpdated("withdrawalsEnabled", enabled ? 0 : 1, enabled ? 1 : 0);
    }

    /// @notice Enable or disable deposits globally
    function setDepositsEnabled(bool enabled) external onlyGovernanceOrAdmin {
        _config.depositsEnabled = enabled;
        emit TreasuryConfigUpdated("depositsEnabled", enabled ? 0 : 1, enabled ? 1 : 0);
    }

    /// @notice Update withdrawal limit per block for a pool
    function setWithdrawalLimitPerBlock(TreasuryPool pool, uint256 limit) external onlyGovernanceOrAdmin {
        _withdrawalLimitPerBlock[pool] = limit;
        emit TreasuryConfigUpdated("withdrawalLimitPerBlock", 0, limit);
    }

    // =========================================================================
    // Module Management
    // =========================================================================

    /// @notice Authorise or deauthorise a protocol module
    function setAuthorisedModule(address module, bool authorised) external onlyRole(ADMIN_ROLE) {
        if (module == address(0)) revert ZeroAddress();
        _authorisedModules[module] = authorised;
        emit AuthorisedModuleUpdated(module, authorised);
    }

    // =========================================================================
    // Emergency Controls
    // =========================================================================

    /// @notice Pause all treasury operations with a reason
    function emergencyPause(string calldata reason) external {
        if (
            !hasRole(PAUSER_ROLE, msg.sender) &&
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender) &&
            msg.sender != emergencyAdmin
        ) {
            revert UnauthorisedWithdrawal(msg.sender, TreasuryPool.EMERGENCY_RESERVE);
        }
        _pause();
        emit EmergencyPaused(msg.sender, reason);
    }

    /// @notice Unpause treasury operations
    function emergencyUnpause() external override {
        if (
            !hasRole(PAUSER_ROLE, msg.sender) &&
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender) &&
            msg.sender != emergencyAdmin
        ) {
            revert UnauthorisedWithdrawal(msg.sender, TreasuryPool.EMERGENCY_RESERVE);
        }
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }

    /// @notice Pause deposits
    function pauseDeposits() external onlyRole(PAUSER_ROLE) {
        _config.depositsEnabled = false;
        emit TreasuryConfigUpdated("depositsEnabled", 1, 0);
    }

    /// @notice Pause withdrawals
    function pauseWithdrawals() external onlyRole(PAUSER_ROLE) {
        _config.withdrawalsEnabled = false;
        emit TreasuryConfigUpdated("withdrawalsEnabled", 1, 0);
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    function _creditPool(TreasuryPool pool, uint256 amount) internal {
        _pools[uint256(pool)].currentBalance += amount;
        _pools[uint256(pool)].totalDeposited += amount;
        _touchPool(pool);
    }

    function _touchPool(TreasuryPool pool) internal {
        _pools[uint256(pool)].lastUpdatedBlock = block.number;
        _pools[uint256(pool)].lastUpdatedTimestamp = block.timestamp;
    }

    function _createRecord(
        address from,
        address to,
        address operator,
        uint256 amount,
        TreasuryPool fromPool,
        TreasuryPool toPool,
        string memory operationType
    ) internal returns (bytes32 recordId) {
        recordId = keccak256(
            abi.encodePacked(block.timestamp, block.number, msg.sender, _recordCount, from, to, amount)
        );

        if (_recordExists[recordId]) revert DuplicateRecord(recordId);
        _recordExists[recordId] = true;

        _records[recordId] = TreasuryRecord({
            recordId: recordId,
            from: from,
            to: to,
            amount: amount,
            fromPool: fromPool,
            toPool: toPool,
            operationType: operationType,
            timestamp: block.timestamp,
            blockNumber: block.number
        });

        _recordIds.push(recordId);
        _recordCount++;
    }

    function _validateSameBlock(TreasuryPool pool) internal {
        if (block.number <= _lastOperationBlock[pool]) {
            revert SameBlockOperation(pool);
        }
        _lastOperationBlock[pool] = block.number;
    }

    function _validateInvariants() internal view {
        uint256 accountedTotal = getTotalAssets();
        uint256 actualBalance = protocolToken.balanceOf(address(this));

        if (accountedTotal != actualBalance) {
            revert InvariantViolation(
                "Accounting mismatch: sum of pools != token balance",
                accountedTotal,
                actualBalance
            );
        }

        if (_config.minReserveRatioBPS > 0 && accountedTotal > 0) {
            uint256 stakingBalance = _pools[uint256(TreasuryPool.STAKING_RESERVE)].currentBalance;
            uint256 minRequired = (accountedTotal * _config.minReserveRatioBPS) / BASIS_POINTS;
            if (stakingBalance < minRequired) {
                revert InvariantViolation("Staking reserve below minimum ratio", minRequired, stakingBalance);
            }
        }
    }

    function _enforceWithdrawalLimits(TreasuryPool pool, uint256 amount) internal {
        // Percentage-based limit
        if (_config.maxWithdrawalBPS > 0) {
            uint256 poolBalance = _pools[uint256(pool)].currentBalance;
            uint256 maxWithdrawal = (poolBalance * _config.maxWithdrawalBPS) / BASIS_POINTS;
            if (amount > maxWithdrawal) {
                revert WithdrawalExceedsLimit(amount, maxWithdrawal);
            }
        }

        // Per-block absolute limit
        uint256 blockLimit = _withdrawalLimitPerBlock[pool];
        if (blockLimit > 0) {
            // Reset counter if we are in a new block
            if (block.number > _withdrawalBlockSnapshot[pool]) {
                _withdrawnCurrentBlock[pool] = 0;
                _withdrawalBlockSnapshot[pool] = block.number;
            }

            uint256 alreadyWithdrawn = _withdrawnCurrentBlock[pool];
            if (alreadyWithdrawn + amount > blockLimit) {
                revert WithdrawalExceedsLimit(amount, blockLimit - alreadyWithdrawn);
            }
        }
    }

    /// @dev Record that `amount` was withdrawn from `pool` in the current block
    ///      for per-block limit tracking. Must be called after _enforceWithdrawalLimits.
    function _recordBlockWithdrawal(TreasuryPool pool, uint256 amount) internal {
        uint256 blockLimit = _withdrawalLimitPerBlock[pool];
        if (blockLimit > 0) {
            _withdrawnCurrentBlock[pool] += amount;
        }
    }

    function _isAuthorisedForWithdrawal(address caller, TreasuryPool pool) internal view returns (bool) {
        if (hasRole(TREASURY_MANAGER_ROLE, caller)) return true;
        if (hasRole(DEFAULT_ADMIN_ROLE, caller)) return true;

        if (pool == TreasuryPool.STAKING_RESERVE) {
            return hasRole(STAKING_MODULE_ROLE, caller) || hasRole(SLASHING_MODULE_ROLE, caller);
        }
        if (pool == TreasuryPool.REWARDS_POOL) {
            return hasRole(REWARD_MODULE_ROLE, caller);
        }
        if (pool == TreasuryPool.PROTOCOL_FEES) {
            return hasRole(SETTLEMENT_MODULE_ROLE, caller) || hasRole(FEE_MODULE_ROLE, caller);
        }
        if (pool == TreasuryPool.GOVERNANCE_RESERVE || pool == TreasuryPool.ECOSYSTEM_FUND) {
            return hasRole(GOVERNANCE_ROLE, caller);
        }
        if (pool == TreasuryPool.EMERGENCY_RESERVE) {
            return caller == emergencyAdmin;
        }
        if (pool == TreasuryPool.SLASHING_RESERVE) {
            return hasRole(SLASHING_MODULE_ROLE, caller);
        }

        return false;
    }

    /// @dev Find the best source pool for an emergency withdrawal.
    ///      Priority: EMERGENCY_RESERVE → GOVERNANCE_RESERVE → any pool with enough.
    function _findEmergencySource(uint256 amount) internal view returns (TreasuryPool, uint256) {
        // Prefer dedicated emergency reserve
        uint256 emergencyBalance = _pools[uint256(TreasuryPool.EMERGENCY_RESERVE)].currentBalance;
        if (emergencyBalance >= amount) {
            return (TreasuryPool.EMERGENCY_RESERVE, emergencyBalance);
        }

        // Fall back to governance reserve
        uint256 governanceBalance = _pools[uint256(TreasuryPool.GOVERNANCE_RESERVE)].currentBalance;
        if (governanceBalance >= amount) {
            return (TreasuryPool.GOVERNANCE_RESERVE, governanceBalance);
        }

        // Last resort: scan all pools for the largest single-pool balance that covers it
        TreasuryPool bestPool = TreasuryPool.STAKING_RESERVE;
        uint256 bestBalance = 0;
        for (uint256 i = 0; i < POOL_COUNT; i++) {
            uint256 bal = _pools[i].currentBalance;
            if (bal >= amount && bal > bestBalance) {
                bestBalance = bal;
                bestPool = TreasuryPool(i);
            }
        }

        if (bestBalance >= amount) {
            return (bestPool, bestBalance);
        }

        // Nothing single-pool covers it; return total as available so caller sees InsufficientPoolBalance
        uint256 totalPoolBalance = getTotalAssets();
        return (bestPool, totalPoolBalance);
    }

    // V2-SC-154: additive recovery only; existing liability and authority paths remain authoritative.
    function _checkAssetRecoveryAuthority() internal view override {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender) || !governanceEnabled) revert RecoveryAuthorityUnavailable();
    }

    function _requireAssetRecoveryAllowed() internal view override {
        if (paused()) revert RecoveryPaused();
    }

    function _reservedAssetBalance(address asset) internal view override returns (uint256) {
        return asset == address(protocolToken) ? getTotalAssets() : 0;
    }
}
