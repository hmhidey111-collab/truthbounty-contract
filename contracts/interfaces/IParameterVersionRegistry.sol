// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

interface IParameterVersionRegistry {
    enum VersionStatus { PROPOSED, QUEUED,ACTIVE, SUPERSEDED, CANCELLED }

    error InvalidAllocationBIS();
    error NonZeroDurationRequired();
    error UnsupportedAsset();
    error InvalidBountyBounds();
    error InvalidStakeBounds();
    error InvalidWeightCap();
    error InvalidParticipationThreshold();
    error InvalidConfidenceThreshold();
    error InvalidAppealMultiplier();
    error InvalidReputationBounds();
    error InvalidNumericRange();
    error VersionImmutable();
    error InvalidVersionStatus();

    struct EconomicParameters {
        uint256 verifierRewardsBPS;
        uint256 treasuryReserveBPS;
        uint256 ecosystemIncentivesBPS;
        uint256 governanceIncentivesBPS;
        uint256 protocolDevelopmentBPS;
        uint256 emergencyReserveBPS;
        uint256 emissionLimit;
        uint256 rewardMultiplier;
        uint256 treasuryReserveTargetBPS;
        uint256 claimSubmissionFee;
        uint256 verificationSubmissionFee;
        uint256 disputeInitiationFee;
        uint256 protocolReserveFeeBPS;
        uint256 minStakeAmount;
        uint256 maxStakeAmount;
        uint256 minReputationScore;
        uint256 maxReputationScore;
        uint256 defaultReputationScore;
        uint256 slashPercentageBPS;
        uint256 maxSlashPercentageBPS;
        uint256 minBountyAmount;
        uint256 maxBountyAmount;
        uint256 weightCapBPS;
        uint256 challengeDuration;
        uint256 appealDuration;
        uint256 pauseCooldown;
        uint256 participationThresholdBPS;
        uint256 confidenceThresholdBPS;
        uint256 challengeBond;
        uint256 appealMultiplierBPS;
        uint256 roundingPolicyId;
        address[] supportedAssets;
    }

    struct ParameterVersion {
        uint256 versionId;
        EconomicParameters parameters;
        VersionStatus status;
        address proposer;
        uint256 proposedAt;
        uint256 executeAfter;
        uint256 activatedAt;
    }

    event VersionProposed(uint256 indexed versionId, address indexed proposer, uint256 proposedAt, uint256 executeAfter);
    event VersionQueued(uint256 indexed versionId, uint256 executeAfter);
    event VersionActivated(uint256 indexed versionId, uint256 activatedAt);
    event VersionSuperseded(uint256 indexed oldVersionId, uint256 indexed newVersionId);
    event VersionCancelled(uint256 indexed versionId, address indexed canceller);
    event ClaimLinkedToVersion(uint256 indexed claimId, uint256 indexed versionId);
    event ParameterTimelockUpdated(uint256 oldTimelock, uint256 newTimelock);

    function proposeNewVersion(EconomicParameters calldata parameters) external returns (uint256 versionId);
    function activateVersion(uint256 versionId) external;
    function recordClaimCreation(uint256 claimId) external;
    function updateParameterTimelock(uint256 newTimelock) external;
    function cancelQueuedVersion(uint256 versionId) external;

    function getParametersForClaim(uint256 claimId) external view returns (EconomicParameters memory);
    function getCurrentParameters() external view returns (EconomicParameters memory);
    function getScheduledVersion() external view returns (ParameterVersion memory);
    function getVersion(uint256 versionId) external view returns (ParameterVersion memory);
    function isVersionActive(uint256 versionId) external view returns (bool);
    function isVersionSuperseded(uint256 versionId) external view returns (bool);
    function MIN_ECONOMIC_PARAMETER_TIMELOCK() external view returns (uint256);
    function currentActiveVersionId() external view returns (uint256);
    function scheduledVersionId() external view returns (uint256);
    function parameterTimelock() external view returns (uint256);

    function MIN_SAFE_STAKE() external view returns (uint256);
    function MAX_SAFE_STAKE() external view returns (uint256);
    function MIN_SAFE_BOND() external view returns (uint256);
    function MAX_SAFE_BOND() external view returns (uint256);
    function MIN_SAFE_DURATION() external view returns (uint256);
    function MAX_SAFE_DURATION() external view returns (uint256);
    function MIN_SAFE_WEIGHT_CAP() external view returns (uint256);
    function MAX_SAFE_WEIGHT_CAP() external view returns (uint256);
    function MIN_SAFE_PARTICIPATION_THRESHOLD() external view returns (uint256);
    function MAX_SAFE_PARTICIPATION_THRESHOLD() external view returns (uint256);
    function MIN_SAFE_CONFIDENCE_THRESHOLD() external view returns (uint256);
    function MAX_SAFE_CONFIDENCE_THRESHOLD() external view returns (uint256);
    function MAX_SAFE_ALLOCATION() external view returns (uint256);
    function MIN_SAFE_MULTIPLIER() external view returns (uint256);
    function MAX_SAFE_MULTIPLIER() external view returns (uint256);
    function MIN_SAFE_APPEAL_MULTIPLIER() external view returns (uint256);
    function MAX_SAFE_APPEAL_MULTIPLIER() external view returns (uint256);
}
