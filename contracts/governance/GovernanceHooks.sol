// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GovernanceHooks
 * @notice Interface for DAO governance control over protocol parameters
 * @dev Legacy per-parameter surface only. Canonical V2 immutable parameter sets are
 *      owned by ParameterVersionRegistry and intentionally excluded from this interface.
 */
interface GovernanceHooks {
    // ============= Parameter Update Types =============
    
    enum ParameterType {
        // TruthBounty parameters (0-9)
        SLASH_PERCENTAGE,
        MIN_STAKE_AMOUNT,
        SETTLEMENT_THRESHOLD_PERCENT,
        REWARD_PERCENT,
        SLASH_PERCENT,
        VERIFICATION_WINDOW_DURATION,
        // WeightedStaking parameters (10-19)
        MIN_REPUTATION_SCORE,
        MAX_REPUTATION_SCORE,
        DEFAULT_REPUTATION_SCORE,
        WEIGHTED_STAKING_ENABLED,
        REPUTATION_ORACLE,
        // VerifierSlashing parameters (20-29)
        MAX_SLASH_PERCENTAGE,
        SLASH_COOLDOWN,
        STAKING_CONTRACT,
        // Role management (30-39)
        RESOLVER_ROLE,
        TREASURY_ROLE,
        PAUSER_ROLE,
        // Upgrade authorization (40+)
        UPGRADE_AUTHORIZATION,
        // RewardEngine parameters (50+)
        BASE_REWARD_RATE,
        MIN_REWARD_AMOUNT,
        MAX_REWARD_AMOUNT,
        DAILY_EMISSION_LIMIT,
        ANTI_WHALE_LIMIT,
        MIN_REPUTATION_MULTIPLIER,
        MAX_REPUTATION_MULTIPLIER,
        MIN_DIFFICULTY_MULTIPLIER,
        MAX_DIFFICULTY_MULTIPLIER,
        MIN_STAKE_MULTIPLIER,
        MAX_STAKE_MULTIPLIER,
        MIN_GOVERNANCE_MULTIPLIER,
        MAX_GOVERNANCE_MULTIPLIER,
        // TokenomicsEngine parameters (60+)
        VERIFIER_REWARD_ALLOCATION_BPS,
        TREASURY_RESERVE_ALLOCATION_BPS,
        ECOSYSTEM_INCENTIVE_ALLOCATION_BPS,
        GOVERNANCE_INCENTIVE_ALLOCATION_BPS,
        PROTOCOL_DEVELOPMENT_ALLOCATION_BPS,
        EMERGENCY_RESERVE_ALLOCATION_BPS,
        EMISSION_LIMIT,
        REWARD_MULTIPLIER,
        TREASURY_RESERVE_TARGET_BPS,
        PROTOCOL_FEE_ALLOCATION_BPS
    }

    // ============= Events =============

    event ParameterUpdateRequested(
        ParameterType indexed paramType,
        bytes32 indexed proposalId,
        uint256 oldValue,
        uint256 newValue,
        address indexed requester
    );

    event ParameterUpdateExecuted(
        ParameterType indexed paramType,
        bytes32 indexed proposalId,
        uint256 oldValue,
        uint256 newValue
    );

    event ParameterUpdateCancelled(
        ParameterType indexed paramType,
        bytes32 indexed proposalId
    );

    event RoleAssignmentRequested(
        bytes32 indexed proposalId,
        address indexed account,
        bytes32 role,
        bool indexed grant,
        address requester
    );

    event UpgradeAuthorized(
        bytes32 indexed proposalId,
        address indexed newImplementation,
        address indexed authorizer
    );

    event UpgradeExecuted(
        bytes32 indexed proposalId,
        address newImplementation
    );

    // ============= Parameter Update Functions =============

    /**
     * @notice Request a parameter update (requires governance approval)
     * @param paramType The parameter type to update
     * @param newValue The new value for the parameter
     * @return proposalId The ID of the created proposal
     */
    function requestParameterUpdate(
        ParameterType paramType,
        uint256 newValue
    ) external returns (bytes32 proposalId);

    /**
     * @notice Request an address parameter update
     * @param paramType The parameter type to update
     * @param newAddress The new address value
     * @return proposalId The ID of the created proposal
     */
    function requestAddressParameterUpdate(
        ParameterType paramType,
        address newAddress
    ) external returns (bytes32 proposalId);

    /**
     * @notice Execute an approved parameter update
     * @param proposalId The ID of the proposal to execute
     */
    function executeParameterUpdate(bytes32 proposalId) external;

    /**
     * @notice Cancel a pending parameter update
     * @param proposalId The ID of the proposal to cancel
     */
    function cancelParameterUpdate(bytes32 proposalId) external;

    // ============= Role Management Functions =============

    /**
     * @notice Request a role assignment change
     * @param account The account to grant/revoke role
     * @param role The role to assign
     * @param grant True to grant, false to revoke
     * @return proposalId The ID of the created proposal
     */
    function requestRoleAssignment(
        address account,
        bytes32 role,
        bool grant
    ) external returns (bytes32 proposalId);

    // ============= Upgrade Authorization Functions =============

    /**
     * @notice Request authorization for a contract upgrade
     * @param newImplementation The address of the new implementation
     * @return proposalId The ID of the created proposal
     */
    function requestUpgradeAuthorization(
        address newImplementation
    ) external returns (bytes32 proposalId);

    /**
     * @notice Execute an approved upgrade
     * @param proposalId The ID of the proposal to execute
     */
    function executeUpgrade(bytes32 proposalId) external;

    // ============= View Functions =============

    /**
     * @notice Get the current value of a parameter
     * @param paramType The parameter type to query
     * @return The current value
     */
    function getParameterValue(ParameterType paramType) external view returns (uint256);

    /**
     * @notice Get the current address of a parameter
     * @param paramType The parameter type to query
     * @return The current address value
     */
    function getParameterAddress(ParameterType paramType) external view returns (address);

    /**
     * @notice Check if a proposal exists and is pending
     * @param proposalId The proposal ID to check
     * @return True if the proposal exists and is pending
     */
    function isProposalPending(bytes32 proposalId) external view returns (bool);

    /**
     * @notice Get proposal details
     * @param proposalId The proposal ID to query
     * @return paramType The proposal parameter type
     * @return oldValue The old value before the proposal
     * @return newValue The proposed new value
     * @return newAddress The proposed new address value
     * @return status The proposal status code
     * @return proposer The account that created the proposal
     */
    function getProposalDetails(bytes32 proposalId) external view returns (
        ParameterType paramType,
        uint256 oldValue,
        uint256 newValue,
        address newAddress,
        uint8 status,
        address proposer
    );

}
