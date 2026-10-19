// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";

/// @notice Versioned protocol configuration and parameter publication interface.
/// @dev Only the configured governance authority may publish; all other readers are permissionless.
interface IConfiguration is IV2Module {
    /// @notice Immutable configuration snapshot. Durations are seconds, thresholds and allocations are basis points (10,000 = 100%), and amounts use asset base units.
    struct ParameterSet {
        /// @dev Asset addresses accepted by the configuration.
        address[] supportedAssets;
        /// @dev Inclusive minimum bounty in base units.
        uint256 minBounty;
        /// @dev Inclusive maximum bounty in base units.
        uint256 maxBounty;
        /// @dev Inclusive minimum stake in base units.
        uint256 minStake;
        /// @dev Inclusive maximum stake in base units.
        uint256 maxStake;
        /// @dev Maximum aggregate verifier weight, in the implementation's weight unit.
        uint256 weightCap;
        /// @dev Challenge window duration in seconds.
        uint256 challengeDuration;
        /// @dev Appeal window duration in seconds.
        uint256 appealDuration;
        /// @dev Minimum participation in basis points.
        uint256 participationThreshold;
        /// @dev Confidence threshold in basis points.
        uint256 confidenceThreshold;
        /// @dev Required challenge bond in base units.
        uint256 challengeBond;
        /// @dev Appeal multiplier in basis points.
        uint256 appealMultiplier;
        /// @dev Allocation components in basis points; the implementation validates the total.
        uint256[] allocationBasisPoints;
        /// @dev Inclusive minimum reputation score.
        uint256 minReputation;
        /// @dev Inclusive maximum reputation score.
        uint256 maxReputation;
        /// @dev Emergency pause cooldown in seconds.
        uint256 pauseCooldown;
    }

    /// @notice Emitted when a validated parameter snapshot is permanently published.
    /// @param versionId Monotonic identifier of the published version.
    /// @param actor Governance authority that published the version.
    event ParameterSetPublished(uint256 indexed versionId, address indexed actor);

    /// @notice Indicates that a parameter set failed validation or publication authority checks.
    /// @param reason ABI-encoded or stable reason code describing the failed invariant.
    error InvalidParameterSet(bytes32 reason);

    /// @notice Publishes a new immutable parameter set after validation.
    /// @dev Must revert unless called by the authorized governance authority. The operation is fail-closed and cannot overwrite a version.
    /// @param params Candidate parameter set using the units documented on `ParameterSet`.
    /// @return versionId Identifier assigned to the published snapshot.
    function publish(ParameterSet calldata params) external returns (uint256 versionId);

    /// @notice Reads a published parameter snapshot.
    /// @dev Reverts when `versionId` is not published; reads never mutate protocol state.
    /// @param versionId Version to read.
    /// @return params The stored immutable snapshot.
    function getParameterSet(uint256 versionId) external view returns (ParameterSet memory params);

    /// @notice Returns the most recently published version.
    /// @return versionId Latest version identifier, or zero when no version exists if supported by the implementation.
    function getLatestVersion() external view returns (uint256 versionId);

    /// @notice Returns the number of published versions.
    /// @return count Number of immutable snapshots.
    function getVersionCount() external view returns (uint256 count);
}
