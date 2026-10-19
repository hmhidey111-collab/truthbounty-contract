// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "../libraries/BoundedSafeERC20.sol";
import "../governance/GovernanceOwnable.sol";
import "../governance/GovernanceHooks.sol";
import "../treasury/ITreasuryAccounting.sol";
import "./ITokenomicsEngine.sol";
import "./AllocationPolicies.sol";

/**
 * @title TokenomicsEngine
 * @notice Deterministic Tokenomics & Incentive Distribution Framework (SC-027)
 * @dev Central allocation engine for protocol revenue.
 *
 * Responsibilities:
 *  - Accept revenue from modular sources (protocol fees, treasury allocations, etc.)
 *  - Allocate revenue to governance-defined destinations:
 *      Verifier Rewards, Treasury Reserves, Ecosystem Incentives,
 *      Governance Incentives, Protocol Development, Emergency Reserve
 *  - Validate treasury solvency before every distribution
 *  - Emit auditable events and maintain append-only distribution history
 *  - Expose governance controls for allocation percentages, emission limits,
 *    reward multipliers, and treasury reserve targets
 *
 * Safety constraints:
 *  - ReentrancyGuard on all state-mutating external calls
 *  - Pausable for emergency stops
 *  - No arithmetic overflow (Solidity 0.8.x)
 *  - Treasury overdraft prevention
 *  - Duplicate distribution rejection
 *  - Invariant: total distributed <= total received
 *
 * Design principles:
 *  - New revenue sources add a new enum value + default allocation config
 *    without modifying allocation logic
 *  - Distribution policies live in AllocationPolicies library
 *  - Business modules call distributeRevenue() rather than embedding
 *    tokenomics math
 *  - Treasury integration uses depositToAccount for internal accounting
 */
contract TokenomicsEngine is
    ITokenomicsEngine,
    AccessControl,
    ReentrancyGuard,
    Pausable,
    GovernanceOwnable
{
    using SafeERC20 for IERC20;
    using AllocationPolicies for *;

    // ============ Roles ==========

    bytes32 public constant ADMIN_ROLE       = keccak256("ADMIN_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE      = keccak256("PAUSER_ROLE");

    // ============ Constants ==========

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_BATCH_SIZE  = 50;

    // ============ Treasury Integration ==========

    ITreasuryAccounting public immutable treasuryAccounting;
    IERC20 public immutable protocolToken;

    // ============ State Variables ==========

    mapping(RevenueSource => SourceAllocation) public sourceAllocations;
    DistributionRecord[] public distributionHistory;
    bytes32[] public distributionIds;
    mapping(bytes32 => bool) public processedDistributions;

    uint256 public totalDistributed;
    mapping(RevenueSource => uint256) public totalBySource;

    uint256 public emissionLimit = type(uint256).max;
    uint256 public rewardMultiplier = 1e18;
    uint256 public treasuryReserveTargetBPS = 2000;

    // ============ Errors ==========

    error ZeroAmount();
    error InvalidSource();
    error AllocationConfigInvalid(string reason);
    error DuplicateDistribution(bytes32 distributionId);
    error InsufficientTreasuryBalance(ITreasuryAccounting.TreasuryAccount account, uint256 requested, uint256 available);
    error TreasuryOverdraft();
    error InvalidAllocation();
    error DistributionBatchTooLarge(uint256 provided, uint256 maximum);
    error InvalidBatchLength();
    error EmissionLimitExceeded(uint256 attempted, uint256 limit);
    error InvalidRewardMultiplier();
    error InvalidTreasuryReserveTarget();
    error SourceNotActive(RevenueSource source);

    // ============ Constructor ==========

    /**
     * @param _treasuryAccounting Address of the deployed TreasuryAccounting contract
     * @param _protocolToken Address of the protocol ERC20 token
     * @param initialAdmin Initial admin address
     * @param _governanceController Governance controller address
     */
    constructor(
        address _treasuryAccounting,
        address _protocolToken,
        address initialAdmin,
        address _governanceController
    )
        nonReentrant
    {
        if (_treasuryAccounting == address(0)) revert AllocationConfigInvalid("zero treasury");
        if (_protocolToken == address(0)) revert AllocationConfigInvalid("zero token");
        if (initialAdmin == address(0)) revert AllocationConfigInvalid("zero admin");

        treasuryAccounting = ITreasuryAccounting(_treasuryAccounting);
        protocolToken = IERC20(_protocolToken);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(DISTRIBUTOR_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);

        _setRoleAdmin(DISTRIBUTOR_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);

        _initializeGovernance(_governanceController, initialAdmin, initialAdmin);

        _initDefaultAllocations();
    }

    // ============ Internal Init Helpers ==========

    function _initDefaultAllocations() internal {
        _setSourceAllocationRaw(
            RevenueSource.PROTOCOL_FEES,
            SourceAllocation({
                verifierRewardsBPS: 4000,
                treasuryReserveBPS: 2000,
                ecosystemIncentivesBPS: 1500,
                governanceIncentivesBPS: 1000,
                protocolDevelopmentBPS: 1000,
                emergencyReserveBPS: 500,
                active: true
            })
        );

        _setSourceAllocationRaw(
            RevenueSource.TREASURY_ALLOCATION,
            SourceAllocation({
                verifierRewardsBPS: 6000,
                treasuryReserveBPS: 2000,
                ecosystemIncentivesBPS: 1000,
                governanceIncentivesBPS: 500,
                protocolDevelopmentBPS: 500,
                emergencyReserveBPS: 0,
                active: true
            })
        );

        _setSourceAllocationRaw(
            RevenueSource.GOVERNANCE_INCENTIVE_POOL,
            SourceAllocation({
                verifierRewardsBPS: 3000,
                treasuryReserveBPS: 3000,
                ecosystemIncentivesBPS: 2000,
                governanceIncentivesBPS: 1000,
                protocolDevelopmentBPS: 500,
                emergencyReserveBPS: 500,
                active: true
            })
        );

        _setSourceAllocationRaw(
            RevenueSource.ECOSYSTEM_GRANTS,
            SourceAllocation({
                verifierRewardsBPS: 1000,
                treasuryReserveBPS: 1000,
                ecosystemIncentivesBPS: 6000,
                governanceIncentivesBPS: 1000,
                protocolDevelopmentBPS: 500,
                emergencyReserveBPS: 500,
                active: true
            })
        );

        _setSourceAllocationRaw(
            RevenueSource.STAKING_EMISSIONS,
            SourceAllocation({
                verifierRewardsBPS: 5000,
                treasuryReserveBPS: 2000,
                ecosystemIncentivesBPS: 1000,
                governanceIncentivesBPS: 1000,
                protocolDevelopmentBPS: 500,
                emergencyReserveBPS: 500,
                active: true
            })
        );
    }

    function _setSourceAllocationRaw(RevenueSource source, SourceAllocation memory config) internal {
        sourceAllocations[source] = config;
    }

    // ============ Core Distribution ==========

    function distributeRevenue(RevenueSource source, uint256 amount)
        public
        override
        nonReentrant
        whenNotPaused
        onlyRole(DISTRIBUTOR_ROLE)
        returns (bytes32 distributionId)
    {
        return _distributeRevenue(source, amount);
    }

    function _distributeRevenue(RevenueSource source, uint256 amount)
        internal
        returns (bytes32 distributionId)
    {
        if (amount == 0) revert ZeroAmount();

        SourceAllocation memory config = sourceAllocations[source];
        if (!config.active) revert SourceNotActive(source);

        (bool valid, string memory reason) = AllocationPolicies.validateAllocationConfig(config);
        if (!valid) revert AllocationConfigInvalid(reason);

        if (totalBySource[source] + amount > emissionLimit) {
            revert EmissionLimitExceeded(totalBySource[source] + amount, emissionLimit);
        }

        distributionId = _generateDistributionId(source, amount);

        if (processedDistributions[distributionId]) {
            revert DuplicateDistribution(distributionId);
        }

        _checkTreasurySolvency(amount);

        protocolToken.safeTransferFrom(msg.sender, address(this), amount);

        AllocationShares memory shares = AllocationPolicies.calculateProportionalAllocation(amount, config);

        if (rewardMultiplier != 1e18) {
            shares.verifierRewards = (shares.verifierRewards * rewardMultiplier) / 1e18;
        }

        bytes32 txId = _executeAllocation(source, amount, shares);

        processedDistributions[distributionId] = true;
        totalBySource[source] += amount;
        totalDistributed += amount;

        distributionIds.push(distributionId);
        distributionHistory.push(DistributionRecord({
            distributionId: distributionId,
            source: source,
            totalAmount: amount,
            verifierRewards: shares.verifierRewards,
            treasuryReserve: shares.treasuryReserve,
            ecosystemIncentives: shares.ecosystemIncentives,
            governanceIncentives: shares.governanceIncentives,
            protocolDevelopment: shares.protocolDevelopment,
            emergencyReserve: shares.emergencyReserve,
            timestamp: block.timestamp,
            executed: true
        }));

        emit RevenueReceived(source, amount, msg.sender);
        emit TokenomicsAllocated(distributionId, source, amount);
        emit IncentiveDistributionCompleted(
            distributionId,
            shares.verifierRewards,
            shares.ecosystemIncentives,
            shares.governanceIncentives,
            shares.protocolDevelopment,
            shares.emergencyReserve
        );
        emit ParameterUpdatedByGovernance(
            keccak256(abi.encode("TOKENOMICS_ALLOCATED", source)),
            0,
            amount
        );

        return distributionId;
    }

    function allocateBatch(RevenueSource[] calldata sources, uint256[] calldata amounts)
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(DISTRIBUTOR_ROLE)
        returns (bytes32[] memory resultIds)
    {
        uint256 length = sources.length;

        if (length == 0 || length != amounts.length) revert InvalidBatchLength();
        if (length > MAX_BATCH_SIZE) revert DistributionBatchTooLarge(length, MAX_BATCH_SIZE);

        resultIds = new bytes32[](length);

        for (uint256 i = 0; i < length;) {
            resultIds[i] = _distributeRevenue(sources[i], amounts[i]);

            unchecked {
                ++i;
            }
        }
    }

    // ============ Allocation Execution ==========

    function _executeAllocation(
        RevenueSource source,
        uint256 amount,
        AllocationShares memory shares
    )
        internal
        returns (bytes32 txId)
    {
        uint256 transferred = 0;

        if (shares.verifierRewards > 0) {
            _allocateToTreasury(ITreasuryAccounting.TreasuryAccount.REWARDS_POOL, shares.verifierRewards);
            transferred += shares.verifierRewards;
        }

        if (shares.treasuryReserve > 0) {
            _allocateToTreasury(ITreasuryAccounting.TreasuryAccount.GOVERNANCE_RESERVES, shares.treasuryReserve);
            transferred += shares.treasuryReserve;
        }

        if (shares.ecosystemIncentives > 0) {
            _allocateToTreasury(ITreasuryAccounting.TreasuryAccount.ECOSYSTEM_FUND, shares.ecosystemIncentives);
            transferred += shares.ecosystemIncentives;
        }

        if (shares.governanceIncentives > 0) {
            _allocateToTreasury(ITreasuryAccounting.TreasuryAccount.GOVERNANCE_RESERVES, shares.governanceIncentives);
            transferred += shares.governanceIncentives;
        }

        if (shares.protocolDevelopment > 0) {
            _allocateToTreasury(ITreasuryAccounting.TreasuryAccount.PROTOCOL_FEES, shares.protocolDevelopment);
            transferred += shares.protocolDevelopment;
        }

        if (shares.emergencyReserve > 0) {
            _allocateToTreasury(ITreasuryAccounting.TreasuryAccount.ECOSYSTEM_FUND, shares.emergencyReserve);
            transferred += shares.emergencyReserve;
        }

        if (transferred != amount) {
            revert InvalidAllocation();
        }

        txId = keccak256(abi.encode(source, amount, shares, block.timestamp, msg.sender));
        return txId;
    }

    function _allocateToTreasury(ITreasuryAccounting.TreasuryAccount account, uint256 amount) internal {
        SafeERC20.safeForceApprove(protocolToken, address(treasuryAccounting), amount);
        treasuryAccounting.depositToAccount(account, amount);
    }

    // ============ Treasury Validation ==========

    function _checkTreasurySolvency(uint256 amount) internal view {
        uint256 actualBalance = protocolToken.balanceOf(address(treasuryAccounting));
        uint256 accountedTotal = treasuryAccounting.calculateTotalAssets();

        if (actualBalance < accountedTotal) {
            revert TreasuryOverdraft();
        }
    }

    // ============ Governance Controls ==========

    /**
     * @notice Deprecated in V2. Use ParameterVersionRegistry.proposeNewVersion() for atomic
     *             parameter version updates with proper timelock and validation. This function
     *             will be removed in a future release.
     */
    function setSourceAllocation(RevenueSource source, SourceAllocation calldata config)
        external
        override
        onlyGovernanceOrAdmin
    {
        SourceAllocation storage old = sourceAllocations[source];
        uint256 oldVerifier = old.verifierRewardsBPS;
        uint256 oldTreasury = old.treasuryReserveBPS;
        uint256 oldEcosystem = old.ecosystemIncentivesBPS;
        uint256 oldGovernance = old.governanceIncentivesBPS;
        uint256 oldProtocol = old.protocolDevelopmentBPS;
        uint256 oldEmergency = old.emergencyReserveBPS;

        (bool valid, string memory reason) = AllocationPolicies.validateAllocationConfig(config);
        if (!valid) revert AllocationConfigInvalid(reason);

        sourceAllocations[source] = config;

        emit AllocationUpdated(
            source,
            oldVerifier, oldTreasury, oldEcosystem, oldGovernance, oldProtocol, oldEmergency,
            config.verifierRewardsBPS,
            config.treasuryReserveBPS,
            config.ecosystemIncentivesBPS,
            config.governanceIncentivesBPS,
            config.protocolDevelopmentBPS,
            config.emergencyReserveBPS
        );
    }

    /**
     * @notice Deprecated in V2. Use ParameterVersionRegistry.proposeNewVersion() for atomic
     *             parameter version updates with proper timelock and validation. This function
     *             will be removed in a future release.
     */
    function setEmissionLimit(uint256 _emissionLimit) external override onlyGovernanceOrAdmin {
        uint256 old = emissionLimit;
        emissionLimit = _emissionLimit;
        emit EmissionLimitUpdated(old, _emissionLimit);
    }

    /**
     * @notice Deprecated in V2. Use ParameterVersionRegistry.proposeNewVersion() for atomic
     *             parameter version updates with proper timelock and validation. This function
     *             will be removed in a future release.
     */
    function setRewardMultiplier(uint256 _multiplier) external override onlyGovernanceOrAdmin {
        if (_multiplier == 0) revert InvalidRewardMultiplier();
        uint256 old = rewardMultiplier;
        rewardMultiplier = _multiplier;
        emit RewardMultiplierUpdated(old, _multiplier);
    }

    function setTreasuryReserveTarget(uint256 _targetBPS) external override onlyGovernanceOrAdmin {
        if (_targetBPS > BPS_DENOMINATOR) revert InvalidTreasuryReserveTarget();
        uint256 old = treasuryReserveTargetBPS;
        treasuryReserveTargetBPS = _targetBPS;
        emit TreasuryReserveTargetUpdated(old, _targetBPS);
    }

    // ============ Read Interfaces ==========

    function getAllocationConfig(RevenueSource source)
        external
        override
        view
        returns (SourceAllocation memory)
    {
        return sourceAllocations[source];
    }

    function getDistributionRecord(bytes32 distributionId)
        external
        override
        view
        returns (DistributionRecord memory)
    {
        for (uint256 i = 0; i < distributionIds.length; i++) {
            if (distributionIds[i] == distributionId) {
                return distributionHistory[i];
            }
        }
        revert AllocationConfigInvalid("distribution not found");
    }

    function getEmissionStats()
        external
        override
        view
        returns (EmissionStats memory)
    {
        return EmissionStats({
            totalDistributed: totalDistributed,
            emissionLimit: emissionLimit,
            rewardMultiplier: rewardMultiplier,
            treasuryReserveTargetBPS: treasuryReserveTargetBPS
        });
    }

    function getTotalBySource(RevenueSource source)
        external
        override
        view
        returns (uint256)
    {
        return totalBySource[source];
    }

    function getDistributionHistory(uint256 offset, uint256 limit)
        external
        override
        view
        returns (DistributionRecord[] memory history)
    {
        uint256 total = distributionHistory.length;
        if (offset >= total) return new DistributionRecord[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        history = new DistributionRecord[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            history[i - offset] = distributionHistory[i];
        }
    }

    function getDistributionHistoryLength() external view returns (uint256) {
        return distributionHistory.length;
    }

    function getProcessedDistribution(bytes32 distributionId)
        external
        view
        override
        returns (bool)
    {
        return processedDistributions[distributionId];
    }

    // ============ Internal Helpers ==========

    function _generateDistributionId(RevenueSource source, uint256 amount)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(source, amount, block.timestamp, msg.sender, distributionIds.length));
    }

    // ============ Pause ==========

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ============ Storage Gap ==========

    uint256[50] private __gap;
}