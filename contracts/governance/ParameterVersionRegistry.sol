// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./GovernanceOwnable.sol";
import "../interfaces/IParameterVersionRegistry.sol";

/**
 * @title ParameterVersionRegistry
 * @notice Registry for versioned economic parameter updates with timelock activation
 * @dev Implements atomic version activation, timelock enforcement, and non-retroactivity
 *      for all protocol economic parameters. Ensures existing claims continue using
 *      their frozen version while new claims use the current active version.
 */
contract ParameterVersionRegistry is 
    IParameterVersionRegistry,
    AccessControl,
    ReentrancyGuard,
    GovernanceOwnable
{
    // ============ Roles ============
    
    bytes32 public constant VERSION_PROPOSER_ROLE = keccak256("VERSION_PROPOSER_ROLE");
    bytes32 public constant VERSION_EXECUTOR_ROLE = keccak256("VERSION_EXECUTOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ============ Errors ============
    error InvalidAllocationBPS(uint256 sum);
    error InvalidEmissionLimit();
    error InvalidFee();
    error InvalidBPS();
    error InvalidStakeAmount();
    error InvalidReputationRange();
    error InvalidSlashBPS();

    // ============ Constants ============
    
    /// @notice Minimum timelock required for any parameter version activation (cannot be shortened)
    uint256 public constant MIN_ECONOMIC_PARAMETER_TIMELOCK = 2 days;
    
    /// @notice Maximum timelock allowed
    uint256 public constant MAX_ECONOMIC_PARAMETER_TIMELOCK = 30 days;
    
    /// @notice Basis points denominator for validation
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ============ Safety Envelopes ============

    /// @notice Minimum safe stake (1e18) to prevent sybil dust attacks
    uint256 public constant MIN_SAFE_STAKE = 1e18;
    /// @notice Maximum safe stake (1_000_000e18) to bound single-actor outsized influence
    uint256 public constant MAX_SAFE_STAKE = 1_000_000 * 1e18;

    /// @notice Minimum safe bond (1e18) to ensure challenges have meaningful economic weight
    uint256 public constant MIN_SAFE_BOND = 1e18;
    /// @notice Maximum safe bond (100_000e18) to ensure challenges remain accessible and not overly punitive
    uint256 public constant MAX_SAFE_BOND = 100_000 * 1e18;

    /// @notice Minimum safe duration (1 hours) to allow sufficient time for network propagation and response
    uint256 public constant MIN_SAFE_DURATION = 1 hours;
    /// @notice Maximum safe duration (30 days) to prevent indefinite lockups of protocol operations
    uint256 public constant MAX_SAFE_DURATION = 30 days;

    /// @notice Minimum safe weight cap BPS (100 = 1%) to prevent zero-weight edge cases
    uint256 public constant MIN_SAFE_WEIGHT_CAP = 100;
    /// @notice Maximum safe weight cap BPS (10000 = 100%)
    uint256 public constant MAX_SAFE_WEIGHT_CAP = 10000;

    /// @notice Minimum participation threshold BPS (100 = 1%) to ensure bare minimum network engagement
    uint256 public constant MIN_SAFE_PARTICIPATION_THRESHOLD = 100;
    /// @notice Maximum participation threshold BPS (10000 = 100%)
    uint256 public constant MAX_SAFE_PARTICIPATION_THRESHOLD = 10000;

    /// @notice Minimum confidence threshold BPS (5100 = 51%) to guarantee simple majority consensus
    uint256 public constant MIN_SAFE_CONFIDENCE_THRESHOLD = 5100;
    /// @notice Maximum confidence threshold BPS (10000 = 100%)
    uint256 public constant MAX_SAFE_CONFIDENCE_THRESHOLD = 10000;

    /// @notice Maximum allocation for any single economic pool (10000 = 100%) to maintain balanced distribution
    uint256 public constant MAX_SAFE_ALLOCATION = 10000;

    /// @notice Minimum reward multiplier (1e18 = 1x) to prevent negative yield scenarios
    uint256 public constant MIN_SAFE_MULTIPLIER = 1e18;
    /// @notice Maximum reward multiplier (10e18 = 10x) to bound hyper-inflationary reward emissions
    uint256 public constant MAX_SAFE_MULTIPLIER = 10 * 1e18;

    /// @notice Minimum appeal multiplier BPS (10000 = 1x) to ensure escalating appeal costs
    uint256 public constant MIN_SAFE_APPEAL_MULTIPLIER = 10000;
    /// @notice Maximum appeal multiplier BPS (50000 = 5x) to bound runaway exponential costs
    uint256 public constant MAX_SAFE_APPEAL_MULTIPLIER = 50000;

    // ============ State Variables ============
    
    /// @notice Current timelock for parameter version activation (never below MIN_ECONOMIC_PARAMETER_TIMELOCK)
    uint256 public parameterTimelock = MIN_ECONOMIC_PARAMETER_TIMELOCK;
    
    /// @notice Counter for version IDs
    uint256 public versionCounter;
    
    /// @notice ID of the currently active version
    uint256 public currentActiveVersionId;
    
    /// @notice ID of the next scheduled version (queued for activation)
    uint256 public scheduledVersionId;
    
    /// @notice All versions mapped by ID
    mapping(uint256 => ParameterVersion) private _versions;
    
    /// @notice Version ID that was active when a claim was created (claimId => versionId)
    mapping(uint256 => uint256) private _claimVersionMap;
    
    /// @notice Whether a version has been superseded
    mapping(uint256 => bool) private _versionSuperseded;

    // ============ Modifiers ============
    
    modifier onlyVersionExecutor() {
        if (!hasRole(VERSION_EXECUTOR_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, VERSION_EXECUTOR_ROLE);
        }
        _;
    }
    
    modifier onlyVersionProposer() {
        if (!hasRole(VERSION_PROPOSER_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, VERSION_PROPOSER_ROLE);
        }
        _;
    }

    // ============ Constructor ============
    
    constructor(address initialAdmin, address governanceController) {
        if (initialAdmin == address(0)) revert ZeroAddress();
        if (governanceController == address(0)) revert ZeroAddress();
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(VERSION_PROPOSER_ROLE, initialAdmin);
        _grantRole(VERSION_EXECUTOR_ROLE, initialAdmin);
        _grantRole(GUARDIAN_ROLE, initialAdmin);
        
        _setRoleAdmin(VERSION_PROPOSER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(VERSION_EXECUTOR_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, DEFAULT_ADMIN_ROLE);
        
        _initializeGovernance(governanceController, initialAdmin, initialAdmin);
        
        // Create genesis version with all default values
        _createGenesisVersion();
    }

    // ============ Internal Initialization ============
    
    function _createGenesisVersion() internal {
        versionCounter = 1;
        
        // Set genesis version as active
        EconomicParameters memory genesisParams = EconomicParameters({
            verifierRewardsBPS: 4000,
            treasuryReserveBPS: 2000,
            ecosystemIncentivesBPS: 1500,
            governanceIncentivesBPS: 1000,
            protocolDevelopmentBPS: 1000,
            emergencyReserveBPS: 500,
            emissionLimit: type(uint256).max,
            rewardMultiplier: 1e18,
            treasuryReserveTargetBPS: 2000,
            claimSubmissionFee: 0.001e18,
            verificationSubmissionFee: 0.001e18,
            disputeInitiationFee: 0.002e18,
            protocolReserveFeeBPS: 50,
            minStakeAmount: MIN_SAFE_STAKE,
            maxStakeAmount: 10_000e18,
            minReputationScore: 0,
            maxReputationScore: 10000,
            defaultReputationScore: 5000,
            slashPercentageBPS: 1000,
            maxSlashPercentageBPS: 5000,
            minBountyAmount: MIN_SAFE_BOND,
            maxBountyAmount: MAX_SAFE_BOND,
            weightCapBPS: 10000,
            challengeDuration: 3 days,
            appealDuration: 7 days,
            pauseCooldown: 1 days,
            participationThresholdBPS: 1000,
            confidenceThresholdBPS: 5100,
            challengeBond: MIN_SAFE_BOND,
            appealMultiplierBPS: 15000,
            roundingPolicyId: 0,
            supportedAssets: new address[](0)
        });

        _validateParameterBounds(genesisParams);

        _versions[versionCounter].parameters = genesisParams;
        _versions[versionCounter].status = VersionStatus.ACTIVE;
        _versions[versionCounter].proposedAt = block.timestamp;
        _versions[versionCounter].activatedAt = block.timestamp;
        _versions[versionCounter].versionId = versionCounter;
        
        currentActiveVersionId = versionCounter;
        
        emit VersionProposed(versionCounter, msg.sender, block.timestamp, 0);
        emit VersionActivated(versionCounter, block.timestamp);
    }

    function _validateParameterBounds(EconomicParameters memory parameters) internal pure {
        // Allocations
        uint256 allocationSum = parameters.verifierRewardsBPS
            + parameters.treasuryReserveBPS
            + parameters.ecosystemIncentivesBPS
            + parameters.governanceIncentivesBPS
            + parameters.protocolDevelopmentBPS
            + parameters.emergencyReserveBPS;
        if (allocationSum != BPS_DENOMINATOR) revert InvalidAllocationBPS(allocationSum);
        if (parameters.verifierRewardsBPS > MAX_SAFE_ALLOCATION || 
            parameters.treasuryReserveBPS > MAX_SAFE_ALLOCATION ||
            parameters.ecosystemIncentivesBPS > MAX_SAFE_ALLOCATION ||
            parameters.governanceIncentivesBPS > MAX_SAFE_ALLOCATION ||
            parameters.protocolDevelopmentBPS > MAX_SAFE_ALLOCATION ||
            parameters.emergencyReserveBPS > MAX_SAFE_ALLOCATION) revert InvalidAllocationBPS(allocationSum);

        // Multipliers
        if (parameters.emissionLimit == 0) revert InvalidEmissionLimit();
        if (parameters.rewardMultiplier < MIN_SAFE_MULTIPLIER || parameters.rewardMultiplier > MAX_SAFE_MULTIPLIER) revert InvalidRewardMultiplier();
        if (parameters.appealMultiplierBPS < MIN_SAFE_APPEAL_MULTIPLIER || parameters.appealMultiplierBPS > MAX_SAFE_APPEAL_MULTIPLIER) revert InvalidAppealMultiplier();

        // Fees
        if (parameters.claimSubmissionFee == 0) revert InvalidFee();
        if (parameters.verificationSubmissionFee == 0) revert InvalidFee();
        if (parameters.disputeInitiationFee == 0) revert InvalidFee();
        if (parameters.protocolReserveFeeBPS > BPS_DENOMINATOR) revert InvalidBPS();

        // Stakes
        if (parameters.minStakeAmount < MIN_SAFE_STAKE || parameters.minStakeAmount > MAX_SAFE_STAKE) revert InvalidStakeBounds();
        if (parameters.maxStakeAmount < MIN_SAFE_STAKE || parameters.maxStakeAmount > MAX_SAFE_STAKE || parameters.minStakeAmount > parameters.maxStakeAmount) revert InvalidStakeBounds();

        // Bonds
        if (parameters.challengeBond < MIN_SAFE_BOND || parameters.challengeBond > MAX_SAFE_BOND) revert InvalidBountyBounds();
        if (parameters.minBountyAmount < MIN_SAFE_BOND || parameters.minBountyAmount > MAX_SAFE_BOND) revert InvalidBountyBounds();
        if (parameters.maxBountyAmount < MIN_SAFE_BOND || parameters.maxBountyAmount > MAX_SAFE_BOND || parameters.minBountyAmount > parameters.maxBountyAmount) revert InvalidBountyBounds();

        // Durations
        if (parameters.challengeDuration < MIN_SAFE_DURATION || parameters.challengeDuration > MAX_SAFE_DURATION) revert NonZeroDurationRequired();
        if (parameters.appealDuration < MIN_SAFE_DURATION || parameters.appealDuration > MAX_SAFE_DURATION) revert NonZeroDurationRequired();
        if (parameters.pauseCooldown > MAX_SAFE_DURATION) revert NonZeroDurationRequired();

        // Caps
        if (parameters.weightCapBPS < MIN_SAFE_WEIGHT_CAP || parameters.weightCapBPS > MAX_SAFE_WEIGHT_CAP) revert InvalidWeightCap();

        // Thresholds
        if (parameters.participationThresholdBPS < MIN_SAFE_PARTICIPATION_THRESHOLD || parameters.participationThresholdBPS > MAX_SAFE_PARTICIPATION_THRESHOLD) revert InvalidParticipationThreshold();
        if (parameters.confidenceThresholdBPS < MIN_SAFE_CONFIDENCE_THRESHOLD || parameters.confidenceThresholdBPS > MAX_SAFE_CONFIDENCE_THRESHOLD) revert InvalidConfidenceThreshold();
        if (parameters.maxStakeAmount != 0 && parameters.minStakeAmount > parameters.maxStakeAmount) {
            revert InvalidStakeAmount();
        }
        // Validate bounty floors used by anti-dust claim creation (V2-SC-105)
        if (parameters.minBountyAmount == 0) revert InvalidBountyBounds();
        if (parameters.maxBountyAmount != 0 && parameters.minBountyAmount > parameters.maxBountyAmount) {
            revert InvalidBountyBounds();
        }

        // Reputation
        if (parameters.minReputationScore > parameters.maxReputationScore) revert InvalidReputationRange();
        if (parameters.defaultReputationScore < parameters.minReputationScore
            || parameters.defaultReputationScore > parameters.maxReputationScore) revert InvalidReputationRange();

        // Slashing
        if (parameters.slashPercentageBPS > parameters.maxSlashPercentageBPS) revert InvalidSlashBPS();
        if (parameters.maxSlashPercentageBPS > BPS_DENOMINATOR) revert InvalidBPS();

        // Treasury
        if (parameters.treasuryReserveTargetBPS > BPS_DENOMINATOR) revert InvalidBPS();
    }

    // ============ External Functions ============
    
    /**
     * @notice Propose a new parameter version
     * @param parameters The complete set of economic parameters for this version
     * @return versionId The ID of the newly proposed version
     */
    function proposeNewVersion(EconomicParameters calldata parameters) 
        external 
        nonReentrant 
        onlyVersionProposer 
        returns (uint256 versionId) 
    {
        // Validate all parameter bounds
        _validateParameterBounds(parameters);
        
        versionCounter++;
        versionId = versionCounter;
        
        uint256 executeAfter = block.timestamp + parameterTimelock;
        
        // Store the new version
        _versions[versionId].versionId = versionId;
        _versions[versionId].parameters = parameters;
        _versions[versionId].status = VersionStatus.PROPOSED;
        _versions[versionId].proposedAt = block.timestamp;
        _versions[versionId].executeAfter = executeAfter;
        _versions[versionId].proposer = msg.sender;
        
        // If there's no scheduled version, queue this one
        if (scheduledVersionId == 0) {
            scheduledVersionId = versionId;
            _versions[versionId].status = VersionStatus.QUEUED;
            emit VersionQueued(versionId, executeAfter);
        }
        
        emit VersionProposed(versionId, msg.sender, block.timestamp, executeAfter);
        
        return versionId;
    }
    
    /**
     * @notice Activate a queued version after timelock has passed
     * @param versionId The ID of the version to activate
     */
    function activateVersion(uint256 versionId) 
        external 
        nonReentrant 
        onlyVersionExecutor 
    {
        ParameterVersion storage version = _versions[versionId];
        
        if (version.versionId == 0) revert VersionNotFound(versionId);
        if (version.status != VersionStatus.QUEUED) revert VersionNotQueued(versionId);
        if (block.timestamp < version.executeAfter) revert TimelockNotExpired(version.executeAfter);
        if (versionId != scheduledVersionId) revert NotScheduledVersion(versionId);
        
        // Mark previous active version as superseded
        if (currentActiveVersionId != 0) {
            _versionSuperseded[currentActiveVersionId] = true;
            emit VersionSuperseded(currentActiveVersionId, versionId);
        }
        
        // Activate the new version
        version.status = VersionStatus.ACTIVE;
        version.activatedAt = block.timestamp;
        currentActiveVersionId = versionId;
        scheduledVersionId = 0;
        
        emit VersionActivated(versionId, block.timestamp);
    }
    
    /**
     * @notice Record that a new claim was created, linking it to the current active version
     * @param claimId The ID of the newly created claim
     */
    function recordClaimCreation(uint256 claimId) external nonReentrant {
        if (claimId == 0) revert InvalidClaimId();
        if (_claimVersionMap[claimId] != 0) revert ClaimAlreadyRegistered(claimId);
        
        // Link this claim to the currently active version
        _claimVersionMap[claimId] = currentActiveVersionId;
        
        emit ClaimLinkedToVersion(claimId, currentActiveVersionId);
    }
    
    /**
     * @notice Update the parameter timelock (can only increase, never decrease below minimum)
     * @param newTimelock The new timelock duration
     */
    function updateParameterTimelock(uint256 newTimelock) external nonReentrant onlyGovernanceOrAdmin {
        if (newTimelock < MIN_ECONOMIC_PARAMETER_TIMELOCK) revert TimelockTooShort(newTimelock, MIN_ECONOMIC_PARAMETER_TIMELOCK);
        if (newTimelock > MAX_ECONOMIC_PARAMETER_TIMELOCK) revert TimelockTooLong(newTimelock, MAX_ECONOMIC_PARAMETER_TIMELOCK);
        
        uint256 oldTimelock = parameterTimelock;
        parameterTimelock = newTimelock;
        
        emit ParameterTimelockUpdated(oldTimelock, newTimelock);
    }

    // ============ View Functions ============
    
    /**
     * @notice Get the parameters that apply to a specific claim (frozen at claim creation)
     * @param claimId The ID of the claim
     * @return The economic parameters active when the claim was created
     */
    function getParametersForClaim(uint256 claimId) external view returns (EconomicParameters memory) {
        uint256 versionId = _claimVersionMap[claimId];
        if (versionId == 0) revert ClaimNotFound(claimId);
        return _versions[versionId].parameters;
    }

    /**
     * @notice Get the parameter version a claim was frozen to at creation
     * @param claimId The ID of the claim
     * @return The linked version ID, or 0 if the claim was never recorded
     */
    function getClaimVersion(uint256 claimId) external view returns (uint256) {
        return _claimVersionMap[claimId];
    }

    /**
     * @notice Get the currently active parameters
     * @return The current economic parameters
     */
    function getCurrentParameters() external view returns (EconomicParameters memory) {
        return _versions[currentActiveVersionId].parameters;
    }
    
    /**
     * @notice Get the scheduled (queued) version if one exists
     * @return The scheduled version details
     */
    function getScheduledVersion() external view returns (ParameterVersion memory) {
        if (scheduledVersionId == 0) revert NoScheduledVersion();
        return _versions[scheduledVersionId];
    }
    
    /**
     * @notice Get a specific version by ID
     * @param versionId The version ID to retrieve
     * @return The version details
     */
    function getVersion(uint256 versionId) external view returns (ParameterVersion memory) {
        if (_versions[versionId].versionId == 0) revert VersionNotFound(versionId);
        return _versions[versionId];
    }
    
    /**
     * @notice Check if a version is still active
     * @param versionId The version ID to check
     * @return True if the version is currently active
     */
    function isVersionActive(uint256 versionId) external view returns (bool) {
        return versionId == currentActiveVersionId;
    }
    
    /**
     * @notice Check if a version has been superseded
     * @param versionId The version ID to check
     * @return True if the version has been superseded by a newer version
     */
    function isVersionSuperseded(uint256 versionId) external view returns (bool) {
        return _versionSuperseded[versionId];
    }

    // ============ Guardian cannot activate or edit versions (security requirement) ===========
    
    /// @notice Guardians can only cancel queued versions, never activate or edit them
    function cancelQueuedVersion(uint256 versionId) external nonReentrant {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, GUARDIAN_ROLE);
        }
        
        ParameterVersion storage version = _versions[versionId];
        if (version.versionId == 0) revert VersionNotFound(versionId);
        if (version.status != VersionStatus.QUEUED) revert VersionNotQueued(versionId);
        if (versionId != scheduledVersionId) revert NotScheduledVersion(versionId);
        
        version.status = VersionStatus.CANCELLED;
        scheduledVersionId = 0;
        
        emit VersionCancelled(versionId, msg.sender);
    }

    // ============ Errors ============
    
    error VersionNotFound(uint256 versionId);
    error VersionNotQueued(uint256 versionId);
    error NotScheduledVersion(uint256 versionId);
    error TimelockNotExpired(uint256 executeAfter);
    error NoScheduledVersion();
    error ClaimNotFound(uint256 claimId);
    error ClaimAlreadyRegistered(uint256 claimId);
    error InvalidClaimId();
    error TimelockTooShort(uint256 provided, uint256 minimum);
    error TimelockTooLong(uint256 provided, uint256 maximum);
    error InvalidRewardMultiplier();
}
