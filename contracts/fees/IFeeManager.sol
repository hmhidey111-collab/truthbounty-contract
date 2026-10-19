// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IFeeManager
 * @notice Interface for the TruthBounty Protocol Fee Management & Treasury Revenue Framework
 * @dev Every protocol module requests fee calculations from this interface.
 *      No module should implement custom fee logic independently.
 */
interface IFeeManager {
    // ============ Structs ============

    /**
     * @notice Versioned fee schedule for a single fee type
     * @param feeType     Identifier (keccak256 of fee name)
     * @param fixedAmount Fixed fee amount in token units (0 if percentage-only)
     * @param basisPoints Percentage fee in basis points (0–10000); 0 if fixed-only
     * @param minValue    Minimum fee enforced after calculation
     * @param maxValue    Maximum fee enforced after calculation (0 = no cap)
     * @param effectiveAt Timestamp at which the schedule becomes active
     * @param govVersion  Governance proposal version that set this schedule
     * @param active      Whether this fee type is currently active
     */
    struct FeeSchedule {
        bytes32 feeType;
        uint256 fixedAmount;
        uint256 basisPoints;
        uint256 minValue;
        uint256 maxValue;
        uint256 effectiveAt;
        uint256 govVersion;
        bool active;
    }

    /**
     * @notice Allocation target within the treasury routing
     * @param name        Identifier (keccak256 of allocation name)
     * @param recipient   Address that receives the allocated amount
     * @param basisPoints Share of total fee (all active targets must sum to 10000)
     * @param active      Whether this allocation is currently active
     */
    struct AllocationTarget {
        bytes32 name;
        address recipient;
        uint256 basisPoints;
        bool active;
    }

    /**
     * @notice Immutable record of a single fee collection event
     */
    struct FeeRecord {
        bytes32 feeType;
        address payer;
        uint256 amount;
        uint256 timestamp;
        bytes32 recordId;
    }

    // ============ Events (spec-required) ============

    event FeeCollected(
        bytes32 indexed feeType,
        address indexed payer,
        uint256 amount
    );

    event FeeDistributed(
        bytes32 indexed allocation,
        uint256 amount
    );

    event FeeScheduleUpdated(
        bytes32 indexed feeType,
        uint256 previousValue,
        uint256 newValue
    );

    // ============ Additional Events ============

    event AllocationTargetsUpdated(
        address indexed updater,
        uint256 targetCount
    );

    event FeeTokenUpdated(
        address indexed oldToken,
        address indexed newToken
    );

    event ReservedFeesAdded(
        uint256 amount,
        uint256 newTotalReserved
    );

    event FeesDistributedDeterministically(
        uint256 totalDistributed,
        uint256 remainingReserved
    );

    // ============ Fee Calculation & Collection ============

    /**
     * @notice Calculate the fee owed for a given fee type and base amount
     * @param feeType    The fee type identifier
     * @param baseAmount The base amount (used for percentage fee calculation)
     * @return feeAmount The calculated fee amount to be paid
     */
    function calculateFee(
        bytes32 feeType,
        uint256 baseAmount
    ) external view returns (uint256 feeAmount);

    /**
     * @notice Collect a protocol fee from a payer
     * @dev Transfers `amount` of fee token from `payer` to this contract,
     *      validates against fee schedule, records the event, and distributes
     *      according to current allocation targets.
     *      Caller must ensure `payer` has approved this contract for at least `amount`.
     * @param feeType The fee type identifier
     * @param payer   The address paying the fee
     * @param amount  The fee amount being paid
     */
    function collectFee(
        bytes32 feeType,
        address payer,
        uint256 amount
    ) external;

    // ============ Governance Controls ============

    /**
     * @notice Update the fee schedule for a given fee type
     * @param feeType     The fee type identifier
     * @param fixedAmount New fixed fee amount
     * @param basisPoints New percentage in basis points
     * @param minValue    New minimum fee
     * @param maxValue    New maximum fee (0 = no cap)
     */
    function updateFeeSchedule(
        bytes32 feeType,
        uint256 fixedAmount,
        uint256 basisPoints,
        uint256 minValue,
        uint256 maxValue
    ) external;

    /**
     * @notice Replace allocation targets (governance-controlled)
     * @dev All active target basisPoints must sum to exactly 10000
     * @param targets New set of allocation targets
     */
    function setAllocationTargets(AllocationTarget[] calldata targets) external;

    /**
     * @notice Activate or deactivate a fee type
     * @param feeType The fee type identifier
     * @param active  Whether the fee type should be active
     */
    function setFeeActive(bytes32 feeType, bool active) external;

    // ============ Read Interfaces ============

    /**
     * @notice Retrieve the active fee schedule for a fee type
     * @param feeType The fee type identifier
     * @return schedule The current FeeSchedule
     */
    function getFeeSchedule(bytes32 feeType) external view returns (FeeSchedule memory schedule);

    /**
     * @notice Retrieve all configured allocation targets
     * @return targets Array of AllocationTarget structs
     */
    function getAllocationTargets() external view returns (AllocationTarget[] memory targets);

    /**
     * @notice Get the total fees collected across all types
     * @return total Cumulative fee amount collected
     */
    function getTotalFeesCollected() external view returns (uint256 total);

    /**
     * @notice Get total fees collected for a specific fee type
     * @param feeType The fee type identifier
     * @return amount Cumulative fee amount for that type
     */
    function getFeesByType(bytes32 feeType) external view returns (uint256 amount);

    /**
     * @notice Get total amount distributed to a specific allocation target
     * @param allocationName The allocation name identifier
     * @return amount Cumulative amount distributed to the target
     */
    function getTotalByAllocation(bytes32 allocationName) external view returns (uint256 amount);

    /**
     * @notice Retrieve paginated fee history
     * @param offset Start index
     * @param limit  Maximum records to return
     * @return records Array of FeeRecord
     */
    function getFeeHistory(
        uint256 offset,
        uint256 limit
    ) external view returns (FeeRecord[] memory records);

    /**
     * @notice Get the total count of fee collection records
     * @return count Total number of fee collection events
     */
    function getFeeRecordCount() external view returns (uint256 count);

    /**
     * @notice Get treasury distribution statistics
     * @return names      Allocation target names
     * @return recipients Allocation recipient addresses
     * @return amounts    Total distributed to each target
     * @return shares     Basis points allocated to each target
     */
    function getTreasuryDistributions() external view returns (
        bytes32[] memory names,
        address[] memory recipients,
        uint256[] memory amounts,
        uint256[] memory shares
    );

    /**
     * @notice Get the configured fee token address
     * @return token The ERC20 token used for fee payments
     */
    function getFeeToken() external view returns (address token);

    /**
     * @notice Get the current amount of reserved fees awaiting distribution
     * @return reserved The total amount of fees currently reserved
     */
    function getReservedFees() external view returns (uint256 reserved);

    /**
     * @notice Distribute all currently reserved fees across allocation targets
     * @dev Can only be called by an address with COLLECTOR_ROLE
     */
    function distributeReservedFees() external;
}