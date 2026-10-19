// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IInsuranceFund
 * @notice Interface for the Protocol Insurance Fund & Loss Recovery Framework.
 * @dev Defines the public API for funding, claims, payouts, governance,
 *      and reserve accounting.
 *
 * Claim lifecycle:
 *
 * SUBMITTED
 *     |
 *     v
 * INVESTIGATING
 *     |
 *     v
 * REVIEW
 *    / \
 *   v   v
 * APPROVED  REJECTED
 *    |
 *    v
 *   PAID
 *
 * Implementations MUST reject invalid state transitions.
 */
interface IInsuranceFund {
    /// @notice A claim description URI exceeded the 512-byte input limit.
    /// @param actual Supplied URI length in bytes.
    /// @param maximum Maximum accepted URI length in bytes.
    error DescriptionUriTooLong(uint256 actual, uint256 maximum);

    // ============ Enums ============

    enum CoverageCategory {
        SMART_CONTRACT_FAILURE,
        ECONOMIC_ATTACK,
        ORACLE_FAILURE,
        GOVERNANCE_INCIDENT
    }

    enum ClaimState {
        SUBMITTED,
        INVESTIGATING,
        REVIEW,
        APPROVED,
        REJECTED,
        PAID
    }

    enum FundingSource {
        PROTOCOL_FEE,
        SLASHED_STAKE,
        GOVERNANCE,
        TREASURY_TRANSFER,
        EXTERNAL_DONATION
    }

    // =============================================================
    //                           STRUCTS
    // =============================================================

    struct Claim {
        uint256 id;
        address claimant;
        CoverageCategory category;
        uint256 requestedAmount;
        uint256 approvedAmount;
        ClaimState state;
        string descriptionURI;
        string auditRecordURI;
        uint256 submittedAt;
        uint256 resolvedAt;
    }

    struct FundingRecord {
        FundingSource source;
        uint256 amount;
        address funder;
        uint256 timestamp;
    }

    struct ReserveMetrics {
        uint256 currentBalance;
        uint256 totalFunded;
        uint256 totalPaidOut;
        uint256 activeClaims;
        uint256 utilisationBasisPoints;
        uint256 growthRateLast30Days;
    }

    // =============================================================
    //                           ERRORS
    // =============================================================

    error InvalidClaimStateTransition(
        uint256 claimId,
        ClaimState currentState,
        ClaimState newState
    );

    error InvalidAmount();

    error AmountExceedsRequested(
        uint256 requestedAmount,
        uint256 approvedAmount
    );

    error AmountExceedsMaximumPayout(
        uint256 amount,
        uint256 maximum
    );

    error InsufficientReserve(
        uint256 requested,
        uint256 available
    );

    error UtilizationLimitExceeded(
        uint256 currentUtilization,
        uint256 requestedUtilization
    );

    error InvalidBasisPoints(uint256 value);

    // =============================================================
    //                           EVENTS
    // =============================================================

    event InsuranceFunded(
        address indexed funder,
        FundingSource indexed source,
        uint256 amount
    );

    event InsuranceClaimSubmitted(
        uint256 indexed claimId,
        address indexed claimant,
        CoverageCategory indexed category,
        uint256 requestedAmount
    );

    event InsuranceClaimStateUpdated(
        uint256 indexed claimId,
        ClaimState oldState,
        ClaimState newState,
        address indexed updatedBy
    );

    event InsuranceClaimApproved(
        uint256 indexed claimId,
        uint256 amount
    );

    /**
     * @notice Emitted when a claim is rejected.
     * @dev `reason` is intentionally not indexed because it is a dynamic type.
     */
    event InsuranceClaimRejected(
        uint256 indexed claimId,
        string reason,
        address indexed rejectedBy
    );

    event InsurancePayoutExecuted(
        address indexed recipient,
        uint256 amount,
        uint256 indexed claimId
    );

    event InsurancePolicyUpdated(
        bytes32 indexed policyId,
        uint256 oldValue,
        uint256 newValue
    );

    event EmergencyWithdrawal(
        address indexed recipient,
        uint256 amount,
        address indexed authorizedBy
    );

    // =============================================================
    //                       CLAIM FUNCTIONS
    // =============================================================

    /**
     * @notice Submit a new insurance claim.
     * @param category Coverage category being claimed.
     * @param requestedAmount Amount requested from the insurance reserve.
     * @param descriptionURI URI containing supporting claim information.
     * @return claimId Newly created claim identifier.
     */
    function submitClaim(
        CoverageCategory category,
        uint256 requestedAmount,
        string calldata descriptionURI
    ) external returns (uint256 claimId);

    /**
     * @notice Update the state of an existing claim.
     * @dev Implementations MUST enforce valid state transitions.
     */
    function updateClaimState(
        uint256 claimId,
        ClaimState newState
    ) external;

    /**
     * @notice Approve a claim for a specific payout amount.
     * @dev The approved amount MUST NOT exceed the requested amount or
     *      configured maximum payout.
     */
    function reviewAndApproveClaim(
        uint256 claimId,
        uint256 approvedAmount,
        string calldata auditRecordURI
    ) external;

    /**
     * @notice Reject a claim.
     * @dev Rejected claims MUST NOT subsequently become payable.
     */
    function rejectClaim(
        uint256 claimId,
        string calldata reason
    ) external;

    /**
     * @notice Execute an approved claim payout.
     * @dev Implementations MUST enforce the payout timelock,
     *      reserve availability, utilization limits, and
     *      prevent duplicate payouts.
     */
    function executePayout(uint256 claimId) external;

    // =============================================================
    //                       FUNDING FUNCTIONS
    // =============================================================

    /**
     * @notice Fund the insurance reserve.
     * @dev Implementations SHOULD transfer tokens using safeTransferFrom
     *      and account for the actual amount received.
     */
    function fundReserve(
        FundingSource source,
        uint256 amount
    ) external;

    /**
     * @notice Withdraw reserve funds under emergency governance authority.
     * @dev Implementations MUST restrict this function to the designated
     *      emergency/governance authority.
     */
    function emergencyWithdrawal(
        address to,
        uint256 amount
    ) external;

    // =============================================================
    //                     GOVERNANCE CONTROLS
    // =============================================================

    function setMaxPayoutPerClaim(
        uint256 maxPayout
    ) external;

    /**
     * @notice Set the maximum allowed reserve utilization.
     * @param limitBasisPoints Value between 0 and 10,000.
     */
    function setGlobalUtilizationLimit(
        uint256 limitBasisPoints
    ) external;

    /**
     * @notice Set the insurance fund allocation percentage.
     * @param percentage Value expressed in basis points.
     */
    function setAllocationPercentage(
        uint256 percentage
    ) external;

    function setCoverageEnabled(
        CoverageCategory category,
        bool enabled
    ) external;

    /**
     * @notice Set the minimum delay before an approved claim can be paid.
     */
    function setPayoutTimelock(
        uint256 timelock
    ) external;

    // =============================================================
    //                         VIEW FUNCTIONS
    // =============================================================

    function reserveToken()
        external
        view
        returns (IERC20);

    function getReserveBalance()
        external
        view
        returns (uint256);

    /**
     * @notice Returns reserve utilization in basis points.
     * @dev 10,000 = 100%.
     */
    function getUtilizationRatio()
        external
        view
        returns (uint256);

    function getClaim(
        uint256 claimId
    ) external view returns (Claim memory);

    function getClaimCount()
        external
        view
        returns (uint256);

    function getActiveClaims()
        external
        view
        returns (uint256[] memory);

    function getFundingHistory(
        uint256 offset,
        uint256 limit
    ) external view returns (FundingRecord[] memory);

    function getFundingTotalBySource(
        FundingSource source
    ) external view returns (uint256);

    function getReserveMetrics()
        external
        view
        returns (ReserveMetrics memory);

    function isCoverageEnabled(
        CoverageCategory category
    ) external view returns (bool);

    function getMaxPayoutPerClaim()
        external
        view
        returns (uint256);

    function getGlobalUtilizationLimit()
        external
        view
        returns (uint256);

    function getAllocationPercentage()
        external
        view
        returns (uint256);

    function getPayoutTimelock()
        external
        view
        returns (uint256);
}