// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Types} from "../interfaces/IV2Types.sol";
import {IV2Types} from "../interfaces/IV2Types.sol";
import {V2Errors} from "./V2Errors.sol";
import {ProtocolExecutionBounds} from "../../performance/ProtocolExecutionBounds.sol";

/// @title V2Lifecycle
/// @notice Shared lifecycle and state machine logic for the TruthBounty V2 protocol.
/// @dev Provides reusable utilities for managing entity state transitions and lifecycle events.
library V2Lifecycle {
    // =========================================================================
    // Versioned Protocol Configuration Registry
    // =========================================================================

    /// @notice Canonical economic and timing parameter set snapshot.
    struct ParameterSet {
        /// @dev Approved asset addresses.
        address[] supportedAssets;
        /// @dev Minimum bounty in asset base units.
        uint128 minBounty;
        /// @dev Maximum bounty in asset base units.
        uint128 maxBounty;
        /// @dev Minimum stake in asset base units.
        uint128 minStake;
        /// @dev Maximum stake in asset base units.
        uint128 maxStake;
        /// @dev Challenge bond in asset base units.
        uint128 challengeBond;
        /// @dev Maximum weight cap in basis points.
        uint16 weightCapBps;
        /// @dev Claim lifetime in seconds.
        uint48 claimDuration;
        /// @dev Verification window in seconds.
        uint48 verificationDuration;
        /// @dev Dispute window in seconds.
        uint48 disputeDuration;
        /// @dev Appeal window in seconds.
        uint48 appealDuration;
        /// @dev Minimum participation in basis points.
        uint24 minParticipationBps;
        /// @dev Maximum participation in basis points.
        uint24 maxParticipationBps;
        /// @dev Confidence threshold in basis points.
        uint16 confidenceThresholdBps;
        /// @dev Appeal multiplier in basis points.
        uint24 appealMultiplierBps;
        /// @dev Bounty allocation in basis points.
        uint16 bountyAllocationBps;
        /// @dev Stake allocation in basis points.
        uint16 stakeAllocationBps;
        /// @dev Protocol allocation in basis points; all allocations must sum to 10,000.
        uint16 protocolAllocationBps;
        /// @dev Minimum reputation in basis points.
        uint16 minReputationBps;
        /// @dev Maximum reputation in basis points.
        uint16 maxReputationBps;
        /// @dev Pause cooldown in seconds.
        uint48 pauseCooldown;
        /// @dev Unpause cooldown in seconds.
        uint48 unpauseCooldown;
        /// @dev Configured rounding policy identifier; values greater than 2 are rejected.
        uint8 roundingPolicy;
    }

    /// @notice Storage layout for published immutable parameter versions.
    struct VersionedConfigRegistry {
        /// @dev Authority allowed to publish and configure assets.
        address governance;
        /// @dev Published immutable snapshots by version ID.
        mapping(bytes32 => ParameterSet) versions;
        /// @dev Existence guard preventing duplicate publication.
        mapping(bytes32 => bool) versionExists;
        /// @dev Publication order for version enumeration.
        bytes32[] versionIds;
        /// @dev Approved adapter for each asset.
        mapping(address => address) assetAdapters;
    }

    /// @notice Sender is not the configured governance authority.
    /// @param sender Address that attempted governance-only mutation.
    error NotGovernance(address sender);
    /// @notice Governance address is zero or the registry was already initialized.
    /// @param governance Supplied governance address.
    error InvalidGovernance(address governance);
    /// @dev Asset is zero or lacks an approved adapter.
    /// @param asset Unsupported asset address.
    error UnsupportedAsset(address asset);
    /// @notice Supported asset list is empty.
    /// @param assetCount Number of supplied assets.
    error InvalidSupportedAssets(uint256 assetCount);
    /// @notice Bounty bounds are reversed.
    /// @param minBounty Configured minimum.
    /// @param maxBounty Configured maximum.
    error InvalidBountyRange(uint128 minBounty, uint128 maxBounty);
    /// @notice Stake bounds are reversed.
    /// @param minStake Configured minimum.
    /// @param maxStake Configured maximum.
    error InvalidStakeRange(uint128 minStake, uint128 maxStake);
    /// @notice A required duration is zero.
    /// @param field Duration field identifier.
    error InvalidDuration(uint8 field);
    /// @notice Allocation basis points do not total 10,000.
    /// @param totalBps Sum of allocation fields.
    error InvalidBasisPointsTotal(uint256 totalBps);
    /// @notice Allocation field exceeds 10,000 basis points.
    /// @param bps Invalid allocation value.
    error InvalidAllocationBps(uint16 bps);
    /// @notice Weight cap exceeds 10,000 basis points.
    /// @param weightCapBps Invalid weight cap.
    error InvalidWeightCap(uint16 weightCapBps);
    /// @notice Participation bounds are invalid.
    /// @param thresholdBps Supplied maximum participation bound; an invalid minimum participation bound can also cause the revert.
    error InvalidParticipationThreshold(uint24 thresholdBps);
    /// @notice Confidence threshold exceeds 10,000 basis points.
    /// @param confidenceBps Invalid confidence threshold.
    error InvalidConfidenceThreshold(uint16 confidenceBps);
    /// @notice Appeal multiplier is zero.
    /// @param multiplierBps Invalid appeal multiplier.
    error InvalidAppealMultiplier(uint24 multiplierBps);
    /// @notice Reputation bounds are reversed or exceed 10,000 basis points.
    /// @param minBps Configured minimum.
    /// @param maxBps Configured maximum.
    error InvalidReputationBounds(uint16 minBps, uint16 maxBps);
    /// @notice Pause or unpause cooldown is zero.
    /// @param cooldown Invalid cooldown in seconds.
    error InvalidPauseCooldown(uint48 cooldown);
    /// @notice Rounding policy identifier is unsupported.
    /// @param roundingPolicy Unsupported policy.
    error InvalidRoundingPolicy(uint8 roundingPolicy);
    /// @notice A parameter snapshot with this hash already exists.
    /// @param versionId Existing version identifier.
    error ParameterSetAlreadyExists(bytes32 versionId);
    /// @notice Parameter snapshot does not exist.
    /// @param versionId Missing version identifier.
    error ParameterSetNotFound(bytes32 versionId);
    /// @notice Asset adapter was already configured.
    /// @param asset Asset whose adapter is immutable.
    error AssetAdapterAlreadySet(address asset);

    uint16 internal constant MAX_BPS = 10_000;
    uint16 internal constant TOTAL_ALLOCATION_BPS = 10_000;

    /// @notice Hashes a parameter set to produce its immutable version ID.
    /// @param params Parameter snapshot to hash with ABI field ordering.
    /// @return versionId Deterministic version identifier.
    function parameterSetId(ParameterSet memory params) internal pure returns (bytes32 versionId) {
        return keccak256(abi.encode(params));
    }

    /// @notice Validates every configured bound and invariant for a parameter set.
    /// @dev Validation is fail-closed: the first invalid bound or allocation causes a revert and no publication occurs.
    /// @param params Parameter snapshot to validate.
    function validateParameterSet(ParameterSet memory params) internal pure {
        if (params.supportedAssets.length == 0) revert V2Errors.InvalidSupportedAssets(0);
        if (params.supportedAssets.length > ProtocolExecutionBounds.MAX_SUPPORTED_ASSETS) {
            revert V2Errors.SupportedAssetLimitExceeded(
                params.supportedAssets.length,
                ProtocolExecutionBounds.MAX_SUPPORTED_ASSETS
            );
        }
        for (uint256 i = 0; i < params.supportedAssets.length; ++i) {
            if (params.supportedAssets[i] == address(0)) {
                revert V2Errors.UnsupportedAsset(params.supportedAssets[i]);
            }
        }
        if (params.minBounty > params.maxBounty) {
            revert V2Errors.InvalidBountyRange(params.minBounty, params.maxBounty);
        }
        if (params.minStake > params.maxStake) {
            revert V2Errors.InvalidStakeRange(params.minStake, params.maxStake);
        }
        if (params.claimDuration == 0) revert V2Errors.InvalidDuration(1);
        if (params.verificationDuration == 0) revert V2Errors.InvalidDuration(2);
        if (params.disputeDuration == 0) revert V2Errors.InvalidDuration(3);
        if (params.appealDuration == 0) revert V2Errors.InvalidDuration(4);
        if (params.pauseCooldown == 0) revert V2Errors.InvalidPauseCooldown(params.pauseCooldown);
        if (params.unpauseCooldown == 0) revert V2Errors.InvalidPauseCooldown(params.unpauseCooldown);

        if (params.weightCapBps > MAX_BPS) revert V2Errors.InvalidWeightCap(params.weightCapBps);
        if (params.minParticipationBps > MAX_BPS ||
            params.maxParticipationBps > MAX_BPS ||
            params.minParticipationBps > params.maxParticipationBps) {
            revert V2Errors.InvalidParticipationThreshold(params.maxParticipationBps);
        }
        if (params.confidenceThresholdBps > MAX_BPS) {
            revert V2Errors.InvalidConfidenceThreshold(params.confidenceThresholdBps);
        }
        if (params.appealMultiplierBps == 0) {
            revert V2Errors.InvalidAppealMultiplier(params.appealMultiplierBps);
        }
        if (params.minReputationBps > params.maxReputationBps || params.maxReputationBps > MAX_BPS) {
            revert V2Errors.InvalidReputationBounds(params.minReputationBps, params.maxReputationBps);
        }
        if (params.roundingPolicy > 2) revert V2Errors.InvalidRoundingPolicy(params.roundingPolicy);

        uint256 totalAllocationBps = uint256(params.bountyAllocationBps)
            + uint256(params.stakeAllocationBps)
            + uint256(params.protocolAllocationBps);
        if (params.bountyAllocationBps > MAX_BPS) revert V2Errors.InvalidAllocationBps(params.bountyAllocationBps);
        if (params.stakeAllocationBps > MAX_BPS) revert V2Errors.InvalidAllocationBps(params.stakeAllocationBps);
        if (params.protocolAllocationBps > MAX_BPS) revert V2Errors.InvalidAllocationBps(params.protocolAllocationBps);
        if (totalAllocationBps != TOTAL_ALLOCATION_BPS) {
            revert V2Errors.InvalidBasisPointsTotal(totalAllocationBps);
        }
    }

    /// @notice Initializes the registry governance address.
    /// @dev Initialization is one-time; a second initialization or zero governance address fails closed.
    /// @param self Registry storage to initialize.
    /// @param governance Non-zero authority allowed to publish and configure assets.
    function initializeConfigRegistry(VersionedConfigRegistry storage self, address governance) internal {
        if (self.governance != address(0) || governance == address(0)) {
            revert V2Errors.InvalidGovernance(governance);
        }
        self.governance = governance;
    }

    /// @notice Approves an adapter for an asset before it can be included in a parameter set.
    /// @dev Governance-only, one-time-per-asset operation; an adapter is never changed after approval.
    /// @param self Registry storage to mutate.
    /// @param asset Asset address requiring an adapter.
    /// @param adapter Non-zero approved adapter.
    function setAssetAdapter(VersionedConfigRegistry storage self, address asset, address adapter) internal {
        if (msg.sender != self.governance) revert V2Errors.NotGovernance(msg.sender);
        if (asset == address(0) || adapter == address(0)) revert V2Errors.UnsupportedAsset(asset);
        if (self.assetAdapters[asset] != address(0)) revert V2Errors.AssetAdapterAlreadySet(asset);
        self.assetAdapters[asset] = adapter;
    }

    /// @notice Publishes a new immutable parameter set version through the timelocked governance hook.
    /// @dev Governance-only, validates all bounds and approved adapters, and rejects duplicate hashes before storing the snapshot.
    /// @param self Registry storage to mutate.
    /// @param params Candidate parameter snapshot.
    /// @return versionId Hash identifying the published snapshot.
    function publishParameterSet(VersionedConfigRegistry storage self, ParameterSet memory params)
        internal
        returns (bytes32 versionId)
    {
        if (msg.sender != self.governance) revert V2Errors.NotGovernance(msg.sender);
        validateParameterSet(params);
        for (uint256 i = 0; i < params.supportedAssets.length; ++i) {
            if (self.assetAdapters[params.supportedAssets[i]] == address(0)) {
                revert V2Errors.UnsupportedAsset(params.supportedAssets[i]);
            }
        }
        versionId = parameterSetId(params);
        if (self.versionExists[versionId]) revert V2Errors.ParameterSetAlreadyExists(versionId);
        self.versions[versionId] = params;
        self.versionExists[versionId] = true;
        self.versionIds.push(versionId);
    }

    /// @notice Returns a parameter set snapshot by version ID.
    /// @dev Unknown IDs revert; published snapshots are never silently substituted.
    /// @param self Registry storage to read.
    /// @param versionId Version identifier to read.
    /// @return params Stored parameter snapshot.
    function getParameterSet(VersionedConfigRegistry storage self, bytes32 versionId)
        internal
        view
        returns (ParameterSet memory params)
    {
        if (!self.versionExists[versionId]) revert V2Errors.ParameterSetNotFound(versionId);
        return self.versions[versionId];
    }

    /// @notice Returns whether a parameter set version is published.
    /// @param self Registry storage to read.
    /// @param versionId Version identifier to inspect.
    /// @return published True only when the immutable snapshot exists.
    function isParameterSetPublished(VersionedConfigRegistry storage self, bytes32 versionId)
        internal
        view
        returns (bool)
    {
        return self.versionExists[versionId];
    }

    /// @notice Returns the number of published parameter sets.
    /// @param self Registry storage to read.
    /// @return count Number of immutable snapshots in publication order.
    function versionCount(VersionedConfigRegistry storage self) internal view returns (uint256 count) {
        return self.versionIds.length;
    }

    // =========================================================================
    // Claim Lifecycle Utilities
    // =========================================================================

    /// @notice Validates a claim state transition according to the protocol state machine.
    /// @param currentState The current claim status.
    /// @param nextState The target claim status.
    /// @return true if the transition is valid, false otherwise.
    function isValidClaimTransition(
        IV2Types.ClaimState currentState,
        IV2Types.ClaimState nextState
    ) internal pure returns (bool) {
        if (currentState == IV2Types.ClaimState.None) {
            return nextState == IV2Types.ClaimState.VerificationOpen;
        }
        if (currentState == IV2Types.ClaimState.VerificationOpen) {
            return nextState == IV2Types.ClaimState.ChallengeWindow ||
                   nextState == IV2Types.ClaimState.AwaitingSettlement;
        }
        if (currentState == IV2Types.ClaimState.ChallengeWindow) {
            return nextState == IV2Types.ClaimState.Disputed ||
                   nextState == IV2Types.ClaimState.AwaitingSettlement ||
                   nextState == IV2Types.ClaimState.Finalized;
        }
        if (currentState == IV2Types.ClaimState.AwaitingSettlement) {
            return nextState == IV2Types.ClaimState.Finalized;
        }
        if (currentState == IV2Types.ClaimState.Disputed) {
            return nextState == IV2Types.ClaimState.Finalized;
        }
        if (currentState == IV2Types.ClaimState.Finalized) {
            return false;
        }
        return false;
    }

    /// @notice Enforces a claim state transition, reverting if invalid.
    /// @dev The shared library uses claim ID zero for the generic transition error; calling modules should surface the claim ID in their own contextual error where possible.
    /// @param currentState The current claim status.
    /// @param nextState The target claim status.
    function enforceValidClaimTransition(
        IV2Types.ClaimState currentState,
        IV2Types.ClaimState nextState
    ) internal pure {
        if (!isValidClaimTransition(currentState, nextState)) {
            revert V2Errors.InvalidClaimStateTransition(0); // claimId would be passed by caller
        }
    }

    /// @notice Checks if a claim is in a terminal state.
    /// @param state The claim status to check.
    /// @return true if the status is terminal (Finalized).
    function isTerminalClaimState(IV2Types.ClaimState state) internal pure returns (bool) {
        return state == IV2Types.ClaimState.Finalized;
    }

    /// @notice Checks if a claim is still under active consideration (not terminal).
    /// @param state The claim status to check.
    /// @return true if the claim can still transition to other states.
    function isActiveClaimState(IV2Types.ClaimState state) internal pure returns (bool) {
        return !isTerminalClaimState(state);
    }

    // =========================================================================
    // Evidence Lifecycle Utilities
    // =========================================================================

    /// @notice Validates an evidence state transition.
    /// @dev Implements the evidence lifecycle:
    ///      NONE -> SUBMITTED -> [ACCEPTED | REJECTED | REVOKED]
    /// @param currentStatus The current evidence status.
    /// @param nextStatus The target evidence status.
    /// @return true if the transition is valid, false otherwise.
    function isValidEvidenceTransition(
        IV2Types.EvidenceStatus currentStatus,
        IV2Types.EvidenceStatus nextStatus
    ) internal pure returns (bool) {
        // Transition from NONE (initial state)
        if (currentStatus == IV2Types.EvidenceStatus.NONE) {
            return nextStatus == IV2Types.EvidenceStatus.SUBMITTED;
        }

        // Transition from SUBMITTED
        if (currentStatus == IV2Types.EvidenceStatus.SUBMITTED) {
            return nextStatus == IV2Types.EvidenceStatus.ACCEPTED ||
                   nextStatus == IV2Types.EvidenceStatus.REJECTED ||
                   nextStatus == IV2Types.EvidenceStatus.REVOKED;
        }

        // Transition from ACCEPTED
        if (currentStatus == IV2Types.EvidenceStatus.ACCEPTED) {
            return nextStatus == IV2Types.EvidenceStatus.REVOKED;
        }

        // Transitions from terminal states
        if (currentStatus == IV2Types.EvidenceStatus.REJECTED ||
            currentStatus == IV2Types.EvidenceStatus.REVOKED) {
            return false;
        }

        return false;
    }

    // =========================================================================
    // Dispute Lifecycle Utilities
    // =========================================================================

    /// @notice Validates a dispute state transition.
    /// @dev Implements the dispute lifecycle:
    ///      NONE -> OPEN -> [RESOLVED | ESCALATED | CANCELLED]
    /// @param currentStatus The current dispute status.
    /// @param nextStatus The target dispute status.
    /// @return true if the transition is valid, false otherwise.
    function isValidDisputeTransition(
        IV2Types.DisputeStatus currentStatus,
        IV2Types.DisputeStatus nextStatus
    ) internal pure returns (bool) {
        // Transition from NONE (initial state)
        if (currentStatus == IV2Types.DisputeStatus.NONE) {
            return nextStatus == IV2Types.DisputeStatus.OPEN;
        }

        // Transition from OPEN
        if (currentStatus == IV2Types.DisputeStatus.OPEN) {
            return nextStatus == IV2Types.DisputeStatus.RESOLVED ||
                   nextStatus == IV2Types.DisputeStatus.ESCALATED ||
                   nextStatus == IV2Types.DisputeStatus.CANCELLED;
        }

        // Transitions from terminal states
        if (currentStatus == IV2Types.DisputeStatus.RESOLVED ||
            currentStatus == IV2Types.DisputeStatus.ESCALATED ||
            currentStatus == IV2Types.DisputeStatus.CANCELLED) {
            return false;
        }

        return false;
    }

    // =========================================================================
    // Settlement Lifecycle Utilities
    // =========================================================================

    /// @notice Validates a settlement state transition.
    /// @dev Implements the settlement lifecycle:
    ///      NONE -> PENDING -> [EXECUTED | BLOCKED | REFUNDED]
    /// @param currentStatus The current settlement status.
    /// @param nextStatus The target settlement status.
    /// @return true if the transition is valid, false otherwise.
    function isValidSettlementTransition(
        IV2Types.SettlementStatus currentStatus,
        IV2Types.SettlementStatus nextStatus
    ) internal pure returns (bool) {
        // Transition from NONE (initial state)
        if (currentStatus == IV2Types.SettlementStatus.NONE) {
            return nextStatus == IV2Types.SettlementStatus.PENDING;
        }

        // Transition from PENDING
        if (currentStatus == IV2Types.SettlementStatus.PENDING) {
            return nextStatus == IV2Types.SettlementStatus.EXECUTED ||
                   nextStatus == IV2Types.SettlementStatus.BLOCKED ||
                   nextStatus == IV2Types.SettlementStatus.REFUNDED;
        }

        // Transitions from terminal states
        if (currentStatus == IV2Types.SettlementStatus.EXECUTED ||
            currentStatus == IV2Types.SettlementStatus.BLOCKED ||
            currentStatus == IV2Types.SettlementStatus.REFUNDED) {
            return false;
        }

        return false;
    }

    /// @notice Checks if a settlement is in a terminal state.
    /// @param status The settlement status to check.
    /// @return true if the status is terminal (EXECUTED, BLOCKED, or REFUNDED).
    function isTerminalSettlementStatus(IV2Types.SettlementStatus status) internal pure returns (bool) {
        return status == IV2Types.SettlementStatus.EXECUTED ||
               status == IV2Types.SettlementStatus.BLOCKED ||
               status == IV2Types.SettlementStatus.REFUNDED;
    }

    /// @notice Canonical terminal settlement outcomes for idempotent settlement.
    /// @dev Every round/outcome must settle at most once; markers precede unsafe calls.
    enum TerminalOutcome {
        None,
        Accepted,
        Rejected,
        Tie,
        Refund,
        Slash,
        Expired,
        Appealed
    }

    /// @notice Settlement marker storage keyed by round and outcome.
    struct SettlementMarker {
        /// @dev Whether the round/outcome has been marked as settled.
        mapping(bytes32 => bool) settled;
        /// @dev Monotonic sequence for exact replay ordering.
        mapping(bytes32 => uint64) sequence;
        /// @dev Global settlement counter for deterministic replay.
        uint64 nextSequence;
    }

    /// @notice Computes the deterministic settlement key for a round/outcome pair.
    /// @param roundId Round identifier.
    /// @param outcome Terminal outcome being settled.
    /// @return key Deterministic settlement marker key.
    function settlementKey(bytes32 roundId, TerminalOutcome outcome) internal pure returns (bytes32 key) {
        return keccak256(abi.encode(roundId, outcome));
    }

    /// @notice Marks a round/outcome as settled before any unsafe external call.
    /// @dev Reverts if already settled, enforcing at-most-once semantics per round/outcome.
    /// @param self Settlement marker storage.
    /// @param roundId Round identifier.
    /// @param outcome Terminal outcome being settled.
    /// @return sequence Assigned monotonic sequence for replay.
    function markSettled(
        SettlementMarker storage self,
        bytes32 roundId,
        TerminalOutcome outcome
    ) internal returns (uint64 sequence) {
        bytes32 key = settlementKey(roundId, outcome);
        if (self.settled[key]) revert V2Errors.SettlementAlreadyExecuted(roundId);
        self.settled[key] = true;
        sequence = self.nextSequence;
        self.sequence[key] = sequence;
        unchecked {
            self.nextSequence = sequence + 1;
        }
    }

    /// @notice Returns whether a round/outcome has already been settled.
    /// @param self Settlement marker storage.
    /// @param roundId Round identifier.
    /// @param outcome Terminal outcome being queried.
    /// @return settled True when the marker exists.
    function isSettled(
        SettlementMarker storage self,
        bytes32 roundId,
        TerminalOutcome outcome
    ) internal view returns (bool settled) {
        return self.settled[settlementKey(roundId, outcome)];
    }

    // =========================================================================
    // Status Query Utilities
    // =========================================================================

    /// @notice Checks if a claim is open and accepting verifications.
    /// @param state The claim status.
    /// @return true if the claim is open.
    function isClaimOpen(IV2Types.ClaimState state) internal pure returns (bool) {
        return state == IV2Types.ClaimState.VerificationOpen;
    }

    /// @notice Checks if a claim has been verified.
    /// @param state The claim status.
    /// @return true if the claim has been verified (ChallengeWindow or AwaitingSettlement).
    function isClaimVerified(IV2Types.ClaimState state) internal pure returns (bool) {
        return state == IV2Types.ClaimState.ChallengeWindow || state == IV2Types.ClaimState.AwaitingSettlement;
    }

    /// @notice Checks if a claim is under dispute.
    /// @param state The claim status.
    /// @return true if the claim is disputed.
    function isClaimDisputed(IV2Types.ClaimState state) internal pure returns (bool) {
        return state == IV2Types.ClaimState.Disputed;
    }

    /// @notice Checks if a settlement can be executed.
    /// @param status The settlement status.
    /// @param currentTime The current block timestamp.
    /// @param executeAfter The settlement execution time.
    /// @return true if the settlement is pending and the timelock has expired.
    function canExecuteSettlement(
        IV2Types.SettlementStatus status,
        uint256 currentTime,
        uint64 executeAfter
    ) internal pure returns (bool) {
        return status == IV2Types.SettlementStatus.PENDING && currentTime >= executeAfter;
    }

    // =========================================================================
    // Time-Based Validation Utilities
    // =========================================================================

    /// @notice Validates that a deadline has not passed.
    /// @param deadline The deadline timestamp.
    /// @return true if the deadline has not passed.
    function isDeadlineValid(uint64 deadline) internal view returns (bool) {
        return block.timestamp < deadline;
    }

    /// @notice Validates that a deadline has passed.
    /// @param deadline The deadline timestamp.
    /// @return true if the deadline has passed.
    function isDeadlineExpired(uint64 deadline) internal view returns (bool) {
        return block.timestamp >= deadline;
    }

    /// @notice Computes the remaining time until a deadline.
    /// @param deadline The deadline timestamp.
    /// @return remaining The remaining time in seconds, or 0 if deadline has passed.
    function timeUntilDeadline(uint64 deadline) internal view returns (uint256 remaining) {
        if (block.timestamp >= deadline) {
            return 0;
        }
        unchecked {
            return deadline - block.timestamp;
        }
    }
}
