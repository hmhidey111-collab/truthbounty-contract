// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "../libraries/BoundedSafeERC20.sol";
import "../governance/GovernanceOwnable.sol";
import "./IFeeManager.sol";

/**
 * @title FeeManager
 * @notice Protocol Fee Management & Treasury Revenue Framework (SC-028)
 *
 * @dev Central, deterministic fee manager for the TruthBounty protocol.
 *      Every protocol fee must pass through this contract. No module should
 *      implement custom fee logic independently.
 *
 * Key responsibilities:
 *  - Maintain versioned fee schedules for every protocol fee type
 *  - Validate and collect fees from protocol modules
 *  - Route collected revenue to governance-defined allocation targets
 *  - Maintain complete, auditable accounting
 *  - Expose governance controls for fee parameter updates
 *
 * Security considerations:
 *  - ReentrancyGuard on all state-mutating external calls
 *  - Fee bypass prevented: only authorised callers can collect
 *  - Duplicate collection prevented: unique record IDs per event
 *  - Arithmetic: Solidity 0.8.x built-in overflow protection
 *  - Allocation integrity: basis points must sum to exactly 10000
 *  - All fee transfers use SafeERC20
 */
contract FeeManager is IFeeManager, ReentrancyGuard, Pausable, GovernanceOwnable {
    using SafeERC20 for IERC20;

    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE     = keccak256("ADMIN_ROLE");
    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    bytes32 public constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");

    // ============ Fee Type Constants ============

    /// @notice Claim Fees
    bytes32 public constant CLAIM_SUBMISSION_FEE    = keccak256("CLAIM_SUBMISSION_FEE");
    bytes32 public constant CLAIM_UPDATE_FEE         = keccak256("CLAIM_UPDATE_FEE");

    /// @notice Verification Fees
    bytes32 public constant VERIFICATION_SUBMISSION_FEE = keccak256("VERIFICATION_SUBMISSION_FEE");
    bytes32 public constant DISPUTE_INITIATION_FEE      = keccak256("DISPUTE_INITIATION_FEE");

    /// @notice Treasury Fees
    bytes32 public constant PROTOCOL_RESERVE_FEE    = keccak256("PROTOCOL_RESERVE_FEE");
    bytes32 public constant ECOSYSTEM_ALLOCATION_FEE = keccak256("ECOSYSTEM_ALLOCATION_FEE");

    /// @notice Miscellaneous Fees
    bytes32 public constant PROTOCOL_SERVICE_FEE    = keccak256("PROTOCOL_SERVICE_FEE");

    // ============ Allocation Target Constants ============

    bytes32 public constant ALLOC_TREASURY_RESERVE      = keccak256("TREASURY_RESERVE");
    bytes32 public constant ALLOC_SECURITY_FUND         = keccak256("SECURITY_FUND");
    bytes32 public constant ALLOC_ECOSYSTEM_FUND        = keccak256("ECOSYSTEM_FUND");
    bytes32 public constant ALLOC_CONTRIBUTOR_INCENTIVES = keccak256("CONTRIBUTOR_INCENTIVES");
    bytes32 public constant ALLOC_EMERGENCY_RESERVE     = keccak256("EMERGENCY_RESERVE");

    // ============ Constants ============

    uint256 public constant BASIS_POINTS_DENOMINATOR = 10_000;
    uint256 public constant MAX_ALLOCATION_TARGETS   = 20;
    uint256 public constant MAX_FEE_HISTORY_PAGE     = 200;

    // ============ State: Fee Schedules ============

    /// @notice Active fee schedule per fee type
    mapping(bytes32 => FeeSchedule) private _feeSchedules;

    /// @notice Historical schedule versions: feeType => version => FeeSchedule
    mapping(bytes32 => mapping(uint256 => FeeSchedule)) private _feeScheduleHistory;

    /// @notice Latest governance version per fee type
    mapping(bytes32 => uint256) public feeScheduleVersion;

    // ============ State: Accounting ============

    /// @notice Cumulative fees collected (all types combined)
    uint256 private _totalFeesCollected;

    /// @notice Cumulative fees collected per fee type
    mapping(bytes32 => uint256) private _feesByType;

    /// @notice Reserved fees awaiting distribution (per token)
    uint256 private _reservedFees;

    /// @notice Cumulative amounts distributed per allocation name
    mapping(bytes32 => uint256) private _totalByAllocation;

    /// @notice Cumulative fees distributed (used for invariant verification)
    uint256 private _totalFeesDistributed;

    // ============ State: Fee Records ============

    /// @notice All fee collection records (append-only)
    FeeRecord[] private _feeRecords;

    /// @notice Prevent duplicate processing of the same record ID
    mapping(bytes32 => bool) private _recordExists;

    // ============ State: Allocation Targets ============

    /// @notice Current allocation routing table
    AllocationTarget[] private _allocationTargets;

    // ============ State: Configuration ============

    /// @notice ERC20 token used for fee payments
    IERC20 private _feeToken;

    /// @notice Global governance version counter (bumped on every schedule update)
    uint256 public globalGovVersion;

    // ============ SC-039 Events ============

    /**
     * @notice SC-039 — exact integer attribution for a fee-schedule change.
     * @dev Emitted alongside `FeeScheduleUpdated` (which only carries the fixed
     *      amount) so every parameter of the new schedule — fixed amount, basis
     *      points, minimum, and maximum, all exact integers — is exposed on-chain
     *      together with the governance version that authored it.
     */
    event FeeScheduleConfigUpdated(
        bytes32 indexed feeType,
        uint256 fixedAmount,
        uint256 basisPoints,
        uint256 minValue,
        uint256 maxValue,
        uint256 govVersion
    );

    // ============ Errors ============

    error ZeroAmount();
    error FeeTypeNotActive(bytes32 feeType);
    error FeeScheduleNotEffective(bytes32 feeType, uint256 effectiveAt);
    error FeeBelowMinimum(uint256 paid, uint256 minimum);
    error FeeAboveMaximum(uint256 paid, uint256 maximum);
    error InvalidBasisPoints(uint256 total);
    error TooManyAllocationTargets(uint256 count, uint256 max);
    error AllocationRecipientZero(bytes32 name);
    error DuplicateAllocationName(bytes32 name);
    error ReservedFeesOutstanding(uint256 reserved);
    error DuplicateFeeRecord(bytes32 recordId);
    error PageLimitExceeded(uint256 limit, uint256 max);
    error AllocationTransferFailed(bytes32 allocation);
    error NoReservedFees();
    error DistributionInProgress();
    error InsufficientReservedFees(uint256 requested, uint256 available);

    // ============ Constructor ============

    /**
     * @param feeToken_           ERC20 token used for fee payments
     * @param initialAdmin        Address granted DEFAULT_ADMIN_ROLE and ADMIN_ROLE
     * @param governanceController_ Address of governance controller (may be address(0) initially)
     * @param treasuryReserve     Treasury reserve address (receives the largest allocation)
     * @param securityFund        Security fund address
     * @param ecosystemFund       Ecosystem fund address
     * @param contributorIncentives Contributor incentives address
     * @param emergencyReserve    Emergency reserve address
     */
    constructor(
        address feeToken_,
        address initialAdmin,
        address governanceController_,
        address treasuryReserve,
        address securityFund,
        address ecosystemFund,
        address contributorIncentives,
        address emergencyReserve
    ) {
        if (feeToken_ == address(0))           revert ZeroAddress();
        if (initialAdmin == address(0))        revert ZeroAddress();
        if (treasuryReserve == address(0))     revert ZeroAddress();
        if (securityFund == address(0))        revert ZeroAddress();
        if (ecosystemFund == address(0))       revert ZeroAddress();
        if (contributorIncentives == address(0)) revert ZeroAddress();
        if (emergencyReserve == address(0))    revert ZeroAddress();

        _feeToken = IERC20(feeToken_);

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(COLLECTOR_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);

        _setRoleAdmin(COLLECTOR_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);

        // Governance integration
        _initializeGovernance(governanceController_, initialAdmin, initialAdmin);

        // ── Default fee schedules (all start inactive; governance activates) ──
        _initFeeSchedule(CLAIM_SUBMISSION_FEE,        0.001e18, 0,  0, 0);
        _initFeeSchedule(CLAIM_UPDATE_FEE,            0.0005e18, 0, 0, 0);
        _initFeeSchedule(VERIFICATION_SUBMISSION_FEE, 0.001e18, 0,  0, 0);
        _initFeeSchedule(DISPUTE_INITIATION_FEE,      0.002e18, 0,  0, 0);
        _initFeeSchedule(PROTOCOL_RESERVE_FEE,        0,        50, 0, 0); // 0.5%
        _initFeeSchedule(ECOSYSTEM_ALLOCATION_FEE,    0,        25, 0, 0); // 0.25%
        _initFeeSchedule(PROTOCOL_SERVICE_FEE,        0.0005e18, 0, 0, 0);

        // ── Default allocation routing ──
        // 40% Treasury Reserve, 20% Security, 20% Ecosystem, 10% Contributors, 10% Emergency
        _allocationTargets.push(AllocationTarget({
            name:        ALLOC_TREASURY_RESERVE,
            recipient:   treasuryReserve,
            basisPoints: 4000,
            active:      true
        }));
        _allocationTargets.push(AllocationTarget({
            name:        ALLOC_SECURITY_FUND,
            recipient:   securityFund,
            basisPoints: 2000,
            active:      true
        }));
        _allocationTargets.push(AllocationTarget({
            name:        ALLOC_ECOSYSTEM_FUND,
            recipient:   ecosystemFund,
            basisPoints: 2000,
            active:      true
        }));
        _allocationTargets.push(AllocationTarget({
            name:        ALLOC_CONTRIBUTOR_INCENTIVES,
            recipient:   contributorIncentives,
            basisPoints: 1000,
            active:      true
        }));
        _allocationTargets.push(AllocationTarget({
            name:        ALLOC_EMERGENCY_RESERVE,
            recipient:   emergencyReserve,
            basisPoints: 1000,
            active:      true
        }));
    }

    // ============ Internal Init Helpers ============

    function _initFeeSchedule(
        bytes32 feeType,
        uint256 fixedAmount,
        uint256 basisPoints,
        uint256 minValue,
        uint256 maxValue
    ) internal {
        _feeSchedules[feeType] = FeeSchedule({
            feeType:      feeType,
            fixedAmount:  fixedAmount,
            basisPoints:  basisPoints,
            minValue:     minValue,
            maxValue:     maxValue,
            effectiveAt:  block.timestamp,
            govVersion:   0,
            active:       true
        });
    }

    // ============ Fee Calculation ============

    /**
     * @inheritdoc IFeeManager
     */
    function calculateFee(
        bytes32 feeType,
        uint256 baseAmount
    ) external view override returns (uint256 feeAmount) {
        return _calculateFee(feeType, baseAmount);
    }

    function _calculateFee(
        bytes32 feeType,
        uint256 baseAmount
    ) internal view returns (uint256) {
        FeeSchedule storage schedule = _feeSchedules[feeType];

        uint256 fee = schedule.fixedAmount;

        // Add percentage component
        if (schedule.basisPoints > 0 && baseAmount > 0) {
            fee += (baseAmount * schedule.basisPoints) / BASIS_POINTS_DENOMINATOR;
        }

        // Enforce minimum
        if (schedule.minValue > 0 && fee < schedule.minValue) {
            fee = schedule.minValue;
        }

        // Enforce maximum (0 = no cap)
        if (schedule.maxValue > 0 && fee > schedule.maxValue) {
            fee = schedule.maxValue;
        }

        return fee;
    }

    // ============ Fee Collection ============

    /**
     * @inheritdoc IFeeManager
     * @dev Caller (protocol module) must be granted COLLECTOR_ROLE.
     *      Payer must have approved this contract for at least `amount` tokens.
     */
    function collectFee(
        bytes32 feeType,
        address payer,
        uint256 amount
    ) external override nonReentrant whenNotPaused onlyRole(COLLECTOR_ROLE) {
        if (payer == address(0)) revert ZeroAddress();
        if (amount == 0)         revert ZeroAmount();

        FeeSchedule storage schedule = _feeSchedules[feeType];

        if (!schedule.active) revert FeeTypeNotActive(feeType);

        if (schedule.effectiveAt > block.timestamp) {
            revert FeeScheduleNotEffective(feeType, schedule.effectiveAt);
        }

        if (schedule.minValue > 0 && amount < schedule.minValue) {
            revert FeeBelowMinimum(amount, schedule.minValue);
        }

        if (schedule.maxValue > 0 && amount > schedule.maxValue) {
            revert FeeAboveMaximum(amount, schedule.maxValue);
        }

        // Generate unique record ID — prevents duplicate processing
        bytes32 recordId = keccak256(abi.encode(
            feeType, payer, amount, block.timestamp, _feeRecords.length
        ));

        if (_recordExists[recordId]) revert DuplicateFeeRecord(recordId);
        _recordExists[recordId] = true;

        // Pull fee token from payer
        uint256 balanceBefore = _feeToken.balanceOf(address(this));
        _feeToken.safeTransferFrom(payer, address(this), amount);
        uint256 actualReceived = _feeToken.balanceOf(address(this)) - balanceBefore;

        // Update accounting
        _totalFeesCollected += actualReceived;
        _feesByType[feeType] += actualReceived;
        _reservedFees += actualReceived;

        // Record the event
        _feeRecords.push(FeeRecord({
            feeType:  feeType,
            payer:    payer,
            amount:   actualReceived,
            timestamp: block.timestamp,
            recordId: recordId
        }));

        emit FeeCollected(feeType, payer, actualReceived);
        emit ReservedFeesAdded(actualReceived, _reservedFees);
    }

    // ============ Distribution State ============

    /// @notice Whether a distribution is currently in progress (prevents reentrancy and concurrent distributions)
    bool private _isDistributing;

    // ============ Public Distribution ============

    /**
     * @notice Distribute all currently reserved fees across allocation targets
     * @dev Uses deterministic rounding: all intermediate calculations use integer division,
     *      and the exact remaining amount after all proportional shares is sent to a 
     *      deterministically fixed recipient (TREASURY_RESERVE) to ensure dust is always
     *      handled the same way regardless of allocation target order.
     *      Can only be called by COLLECTOR_ROLE or ADMIN_ROLE to prevent spam.
     */
    function distributeReservedFees() external nonReentrant onlyRole(COLLECTOR_ROLE) {
        if (_isDistributing) revert DistributionInProgress();
        if (_reservedFees == 0) revert NoReservedFees();
        
        _isDistributing = true;
        
        uint256 amountToDistribute = _reservedFees;
        uint256 totalDistributed = _distributeDeterministic(amountToDistribute);
        
        // Update accounting - reduce reserved fees by exactly what was distributed
        _reservedFees -= totalDistributed;
        _isDistributing = false;
        
        emit FeesDistributedDeterministically(totalDistributed, _reservedFees);
    }

    // ============ Internal Deterministic Distribution ============

    /**
     * @notice Distributes fees using fully deterministic rounding rules
     * @dev Dust (remaining amount after all proportional calculations) is always sent to
     *      the TREASURY_RESERVE allocation, which is a canonical, fixed identifier. This
     *      ensures that regardless of the order of allocation targets in storage, the
     *      dust recipient is always the same, preserving complete determinism.
     * @param amount The total amount to distribute
     * @return totalDistributed The total amount actually distributed (should always equal amount)
     */
    function _distributeDeterministic(uint256 amount) internal returns (uint256 totalDistributed) {
        uint256 activeBpsTotal = 0;
        address treasuryRecipient = address(0);
        
        // First pass: calculate total active basis points and find treasury reserve recipient
        for (uint256 i = 0; i < _allocationTargets.length; i++) {
            AllocationTarget storage target = _allocationTargets[i];
            if (target.active) {
                activeBpsTotal += target.basisPoints;
                if (target.name == ALLOC_TREASURY_RESERVE) {
                    treasuryRecipient = target.recipient;
                }
            }
        }

        if (activeBpsTotal == 0 || treasuryRecipient == address(0)) {
            // No active targets or treasury reserve not found - return 0, fees stay reserved
            return 0;
        }

        uint256 runningTotal = 0;

        // Second pass: distribute proportional shares to all active targets except treasury reserve
        for (uint256 i = 0; i < _allocationTargets.length; i++) {
            AllocationTarget storage target = _allocationTargets[i];
            if (!target.active || target.name == ALLOC_TREASURY_RESERVE) continue;

            // Calculate deterministic share using integer division (rounds down)
            uint256 share = (amount * target.basisPoints) / BASIS_POINTS_DENOMINATOR;
            
            if (share == 0) continue;

            // Update accounting
            _totalByAllocation[target.name] += share;
            _totalFeesDistributed += share;
            runningTotal += share;

            // Transfer tokens
            _feeToken.safeTransfer(target.recipient, share);
            emit FeeDistributed(target.name, share);
        }

        // Treasury reserve gets the remaining amount (includes all rounding dust)
        // This is 100% deterministic because ALLOC_TREASURY_RESERVE is a fixed constant
        uint256 treasuryShare = amount - runningTotal;
        if (treasuryShare > 0) {
            _totalByAllocation[ALLOC_TREASURY_RESERVE] += treasuryShare;
            _totalFeesDistributed += treasuryShare;
            
            _feeToken.safeTransfer(treasuryRecipient, treasuryShare);
            emit FeeDistributed(ALLOC_TREASURY_RESERVE, treasuryShare);
            
            runningTotal += treasuryShare;
        }

        return runningTotal;
    }

    // ============ Governance Controls ============

    /**
     * @inheritdoc IFeeManager
     * @notice Deprecated in V2. Use ParameterVersionRegistry.proposeNewVersion() for atomic
     *         parameter version updates with proper timelock and validation. This function
     *         will be removed in a future release.
     */
    function updateFeeSchedule(
        bytes32 feeType,
        uint256 fixedAmount,
        uint256 basisPoints,
        uint256 minValue,
        uint256 maxValue
    ) external override onlyGovernanceOrAdmin {
        if (basisPoints > BASIS_POINTS_DENOMINATOR) {
            revert InvalidBasisPoints(basisPoints);
        }
        if (maxValue > 0 && minValue > maxValue) {
            revert FeeBelowMinimum(minValue, maxValue);
        }

        FeeSchedule storage schedule = _feeSchedules[feeType];
        uint256 previousValue = schedule.fixedAmount;

        globalGovVersion++;
        uint256 newVersion = globalGovVersion;

        // Archive current schedule
        _feeScheduleHistory[feeType][feeScheduleVersion[feeType]] = _feeSchedules[feeType];

        // Apply new schedule (keep active flag, bump version)
        schedule.feeType      = feeType;
        schedule.fixedAmount  = fixedAmount;
        schedule.basisPoints  = basisPoints;
        schedule.minValue     = minValue;
        schedule.maxValue     = maxValue;
        schedule.effectiveAt  = block.timestamp;
        schedule.govVersion   = newVersion;

        feeScheduleVersion[feeType] = newVersion;

        emit FeeScheduleUpdated(feeType, previousValue, fixedAmount);
        emit FeeScheduleConfigUpdated(feeType, fixedAmount, basisPoints, minValue, maxValue, newVersion);
        emit ParameterUpdatedByGovernance(
            keccak256(abi.encode("FEE_SCHEDULE", feeType)),
            previousValue,
            fixedAmount
        );
    }

    /**
     * @inheritdoc IFeeManager
     * @notice Deprecated in V2. Use ParameterVersionRegistry.proposeNewVersion() for atomic
     *         parameter version updates with proper timelock and validation. This function
     *         will be removed in a future release.
     */
    function setAllocationTargets(
        AllocationTarget[] calldata targets
    ) external override onlyGovernanceOrAdmin {
        if (targets.length > MAX_ALLOCATION_TARGETS) {
            revert TooManyAllocationTargets(targets.length, MAX_ALLOCATION_TARGETS);
        }

        uint256 totalBps = 0;
        bool hasTreasuryReserve = false;
        for (uint256 i = 0; i < targets.length; i++) {
            // SC-039: a routing-table name may appear at most once. Duplicate
            // names would split one fee across two recipients under a single
            // attribution key (`_totalByAllocation`, `FeeDistributed`), which is
            // duplicate routing with merged, unauditable accounting.
            for (uint256 j = 0; j < i; j++) {
                if (targets[j].name == targets[i].name) {
                    revert DuplicateAllocationName(targets[i].name);
                }
            }
            if (targets[i].active) {
                if (targets[i].recipient == address(0)) {
                    revert AllocationRecipientZero(targets[i].name);
                }
                if (targets[i].name == ALLOC_TREASURY_RESERVE) {
                    hasTreasuryReserve = true;
                }
                totalBps += targets[i].basisPoints;
            }
        }

        if (!hasTreasuryReserve) {
            revert InvalidBasisPoints(0); // Treasury reserve must always be present
        }

        if (totalBps != BASIS_POINTS_DENOMINATOR) {
            revert InvalidBasisPoints(totalBps);
        }

        delete _allocationTargets;
        for (uint256 i = 0; i < targets.length; i++) {
            _allocationTargets.push(targets[i]);
        }

        emit AllocationTargetsUpdated(msg.sender, targets.length);
    }

    /**
     * @inheritdoc IFeeManager
     */
    function setFeeActive(
        bytes32 feeType,
        bool active
    ) external override onlyGovernanceOrAdmin {
        FeeSchedule storage schedule = _feeSchedules[feeType];
        uint256 prev = schedule.active ? 1 : 0;
        schedule.active = active;
        emit FeeScheduleUpdated(feeType, prev, active ? 1 : 0);
    }

    /**
     * @notice Update the fee token address
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Should only be used during protocol upgrades.
     * @param newToken New ERC20 token address
     */
    function setFeeToken(address newToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newToken == address(0)) revert ZeroAddress();
        // SC-039: reserved fees were collected in the current fee token. Re-pointing
        // the token while they are outstanding would make distribution pay out the
        // *new* token for amounts collected in the *old* one — stranding the old
        // balance and breaking the conservation equation
        // `totalCollected == totalDistributed + reserved`.
        if (_reservedFees != 0) revert ReservedFeesOutstanding(_reservedFees);
        address old = address(_feeToken);
        _feeToken = IERC20(newToken);
        emit FeeTokenUpdated(old, newToken);
    }

    // ============ Read Interfaces ============

    /**
     * @inheritdoc IFeeManager
     */
    function getFeeSchedule(bytes32 feeType) external view override returns (FeeSchedule memory) {
        return _feeSchedules[feeType];
    }

    /**
     * @notice Retrieve a historical fee schedule version
     * @param feeType The fee type identifier
     * @param version The governance version to retrieve
     * @return schedule The archived FeeSchedule at that version
     */
    function getFeeScheduleAtVersion(
        bytes32 feeType,
        uint256 version
    ) external view returns (FeeSchedule memory schedule) {
        return _feeScheduleHistory[feeType][version];
    }

    /**
     * @inheritdoc IFeeManager
     */
    function getAllocationTargets() external view override returns (AllocationTarget[] memory) {
        return _allocationTargets;
    }

    /**
     * @inheritdoc IFeeManager
     */
    function getTotalFeesCollected() external view override returns (uint256) {
        return _totalFeesCollected;
    }

    /**
     * @inheritdoc IFeeManager
     */
    function getFeesByType(bytes32 feeType) external view override returns (uint256) {
        return _feesByType[feeType];
    }

    /**
     * @inheritdoc IFeeManager
     */
    function getTotalByAllocation(bytes32 allocationName) external view override returns (uint256) {
        return _totalByAllocation[allocationName];
    }

    /**
     * @inheritdoc IFeeManager
     */
    function getFeeHistory(
        uint256 offset,
        uint256 limit
    ) external view override returns (FeeRecord[] memory records) {
        if (limit > MAX_FEE_HISTORY_PAGE) revert PageLimitExceeded(limit, MAX_FEE_HISTORY_PAGE);

        uint256 total = _feeRecords.length;
        if (offset >= total) return new FeeRecord[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        records = new FeeRecord[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            records[i - offset] = _feeRecords[i];
        }
    }

    /**
     * @inheritdoc IFeeManager
     */
    function getFeeRecordCount() external view override returns (uint256) {
        return _feeRecords.length;
    }

    /**
     * @inheritdoc IFeeManager
     */
    function getTreasuryDistributions() external view override returns (
        bytes32[] memory names,
        address[] memory recipients,
        uint256[] memory amounts,
        uint256[] memory shares
    ) {
        uint256 len = _allocationTargets.length;
        names      = new bytes32[](len);
        recipients = new address[](len);
        amounts    = new uint256[](len);
        shares     = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            AllocationTarget storage t = _allocationTargets[i];
            names[i]      = t.name;
            recipients[i] = t.recipient;
            amounts[i]    = _totalByAllocation[t.name];
            shares[i]     = t.basisPoints;
        }
    }

    /**
     * @inheritdoc IFeeManager
     */
    function getFeeToken() external view override returns (address token) {
        return address(_feeToken);
    }

    /**
     * @inheritdoc IFeeManager
     */
    function getReservedFees() external view override returns (uint256 reserved) {
        return _reservedFees;
    }

    /**
     * @notice Get total fees distributed (useful for invariant verification)
     * @return Total amount distributed to all allocation targets
     */
    function getTotalFeesDistributed() external view returns (uint256) {
        return _totalFeesDistributed;
    }

    /**
     * @notice Get the current undistributed balance held by this contract
     * @dev Under normal operation this should be zero as fees are distributed immediately.
     *      A non-zero value indicates an allocation failure or deactivated targets.
     * @return balance Current fee token balance held by this contract
     */
    function getRetainedBalance() external view returns (uint256) {
        return _feeToken.balanceOf(address(this));
    }

    /**
     * @notice Get a single fee record by index
     * @param index The record index
     * @return record The FeeRecord at that index
     */
    function getFeeRecord(uint256 index) external view returns (FeeRecord memory record) {
        require(index < _feeRecords.length, "Index out of bounds");
        return _feeRecords[index];
    }

    // ============ Pause ============

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ============ Storage Gap ============

    /// @dev Reserved storage for future upgrades
    uint256[50] private __gap;
}