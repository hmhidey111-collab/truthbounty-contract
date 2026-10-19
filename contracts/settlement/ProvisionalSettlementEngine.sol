// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../governance/GovernanceOwnable.sol";
import "../governance/GovernanceHooks.sol";
import "../interfaces/IClaimRegistry.sol";
import "../interfaces/IProvisionalSettlementEngine.sol";
import "../VerificationAggregator.sol";

/**
 * @title ProvisionalSettlementEngine
 * @notice Canonical implementation of the TruthBounty V2 Provisional Settlement Engine (SC-015).
 * @dev Transitions claims from closed verification to a deterministic, challengeable provisional state
 *      without caller-supplied data or early fund disbursement.
 *
 * Invariants:
 *  1. Zero Caller Data: Aggregation outcome is computed strictly on-chain via the canonical aggregator.
 *  2. Time Lock: Settlement cannot be triggered before `verificationDeadline`.
 *  3. Single Transition: A claim can enter the provisional challenge window exactly once.
 *  4. Custody Lock: No tokens, rewards, or slashes are disbursed during provisional settlement.
 */
contract ProvisionalSettlementEngine is
    IProvisionalSettlementEngine,
    AccessControl,
    ReentrancyGuard,
    Pausable,
    GovernanceOwnable
{
    // =========================================================================
    // Roles & Constants
    // =========================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 public constant MIN_CHALLENGE_WINDOW = 1 hours;
    uint256 public constant MAX_CHALLENGE_WINDOW = 30 days;

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroClaimId();
    error InvalidClaimRegistryAddress();
    error InvalidAggregatorAddress();
    error InvalidAdminAddress();
    error InvalidChallengeWindowDuration(uint256 duration);
    error ClaimDoesNotExist(uint256 claimId);
    error ClaimNotEligibleForSettlement(uint256 claimId, IClaimRegistry.ClaimStatus status);
    error VerificationWindowStillOpen(uint256 claimId, uint256 currentTimestamp, uint256 deadline);
    error AlreadyProvisionallySettled(uint256 claimId);
    error SettlementAlreadyFinalized(uint256 claimId);
    error InvalidTerminalOutcome(uint256 claimId, Outcome outcome);

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Canonical Claim Registry contract.
    IClaimRegistry public immutable claimRegistry;

    /// @notice Canonical Verification Aggregator contract.
    VerificationAggregator public aggregator;

    /// @notice Duration of the challenge window once provisional settlement begins.
    uint256 public override challengeWindowDuration;

    /// @notice Active governance parameter version.
    uint256 public override parameterVersion;

    /// @notice Mapping from claimId to stored provisional outcome.
    mapping(uint256 => ProvisionalOutcome) private _provisionalOutcomes;

    /// @notice Mapping from claimId to terminal settlement marker.
    mapping(uint256 => bool) private _terminalSettled;

    /// @notice Mapping from claimId to terminal outcome.
    mapping(uint256 => Outcome) private _terminalOutcome;

    /// @notice Mapping from claimId to terminal settlement timestamp.
    mapping(uint256 => uint256) private _terminalSettledAt;

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address _claimRegistry,
        address _aggregator,
        uint256 _challengeWindowDuration,
        address _governanceController,
        address _initialAdmin
    ) {
        if (_claimRegistry == address(0)) revert InvalidClaimRegistryAddress();
        if (_aggregator == address(0)) revert InvalidAggregatorAddress();
        if (_challengeWindowDuration < MIN_CHALLENGE_WINDOW || _challengeWindowDuration > MAX_CHALLENGE_WINDOW) {
            revert InvalidChallengeWindowDuration(_challengeWindowDuration);
        }
        if (_initialAdmin == address(0)) revert InvalidAdminAddress();

        claimRegistry = IClaimRegistry(_claimRegistry);
        aggregator = VerificationAggregator(_aggregator);
        challengeWindowDuration = _challengeWindowDuration;
        parameterVersion = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(ADMIN_ROLE, _initialAdmin);
        _grantRole(PAUSER_ROLE, _initialAdmin);

        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);

        _initializeGovernance(_governanceController, _initialAdmin, _initialAdmin);
    }

    // =========================================================================
    // External Core Logic
    // =========================================================================

    /**
     * @inheritdoc IProvisionalSettlementEngine
     */
    function provisionalSettle(uint256 claimId)
        external
        override
        nonReentrant
        whenNotPaused
        returns (ProvisionalOutcome memory outcome)
    {
        if (claimId == 0) revert ZeroClaimId();
        if (_provisionalOutcomes[claimId].settled) revert AlreadyProvisionallySettled(claimId);

        // Fetch claim record from registry
        IClaimRegistry.Claim memory claim = claimRegistry.getClaim(claimId);
        if (claim.creator == address(0)) revert ClaimDoesNotExist(claimId);

        // Validate lifecycle state and deadline
        if (
            claim.status != IClaimRegistry.ClaimStatus.UnderVerification &&
            claim.status != IClaimRegistry.ClaimStatus.Pending
        ) {
            revert ClaimNotEligibleForSettlement(claimId, claim.status);
        }

        if (block.timestamp < claim.verificationDeadline) {
            revert VerificationWindowStillOpen(claimId, block.timestamp, claim.verificationDeadline);
        }

        // Trigger deterministic aggregation on canonical aggregator
        VerificationAggregator.AggregationResult memory aggResult;
        try aggregator.getAggregation(claimId) returns (VerificationAggregator.AggregationResult memory res) {
            aggResult = res;
        } catch {
            aggregator.aggregateClaim(claimId);
            aggResult = aggregator.getAggregation(claimId);
        }

        // Map outcome
        Outcome mappedOutcome;
        if (aggResult.outcome == VerificationAggregator.ClaimOutcome.VERIFIED_TRUE) {
            mappedOutcome = Outcome.VERIFIED_TRUE;
        } else if (aggResult.outcome == VerificationAggregator.ClaimOutcome.VERIFIED_FALSE) {
            mappedOutcome = Outcome.VERIFIED_FALSE;
        } else {
            mappedOutcome = Outcome.INCONCLUSIVE;
        }

        uint256 count = 0;
        IVerificationSource source = aggregator.verificationSource();
        if (address(source) != address(0)) {
            count = source.getClaimVoterCount(claimId);
        }

        uint256 challengeDeadline = block.timestamp + challengeWindowDuration;

        outcome = ProvisionalOutcome({
            outcome: mappedOutcome,
            confidence: aggResult.confidence,
            trueWeight: aggResult.trueWeight,
            falseWeight: aggResult.falseWeight,
            totalWeight: aggResult.totalWeight,
            verifierCount: count,
            challengeDeadline: challengeDeadline,
            settledAt: block.timestamp,
            parameterVersion: parameterVersion,
            settled: true
        });

        _provisionalOutcomes[claimId] = outcome;

        // Terminal marker precedes any unsafe external calls.
        _terminalSettled[claimId] = true;
        _terminalOutcome[claimId] = mappedOutcome;
        _terminalSettledAt[claimId] = block.timestamp;

        emit RoundAggregated(
            claimId,
            mappedOutcome,
            aggResult.confidence,
            aggResult.trueWeight,
            aggResult.falseWeight,
            aggResult.totalWeight,
            count
        );

        emit ProvisionalOutcomeCreated(
            claimId,
            mappedOutcome,
            challengeDeadline,
            aggResult.confidence,
            msg.sender
        );

        return outcome;
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /**
     * @inheritdoc IProvisionalSettlementEngine
     */
    function getProvisionalOutcome(uint256 claimId)
        external
        view
        override
        returns (ProvisionalOutcome memory)
    {
        return _provisionalOutcomes[claimId];
    }

    /**
     * @inheritdoc IProvisionalSettlementEngine
     */
    function isProvisionalSettled(uint256 claimId) external view override returns (bool) {
        return _provisionalOutcomes[claimId].settled;
    }

    /**
     * @inheritdoc IProvisionalSettlementEngine
     */
    function isChallengeWindowOpen(uint256 claimId) external view override returns (bool) {
        ProvisionalOutcome storage p = _provisionalOutcomes[claimId];
        if (!p.settled) return false;
        return block.timestamp < p.challengeDeadline;
    }

    /**
     * @notice Returns whether a claim has reached a terminal settlement state.
     */
    function isTerminalSettled(uint256 claimId) external view returns (bool) {
        return _terminalSettled[claimId];
    }

    /**
     * @notice Returns the terminal outcome for a claim, if settled.
     */
    function getTerminalOutcome(uint256 claimId) external view returns (Outcome) {
        return _terminalOutcome[claimId];
    }

    /**
     * @notice Returns the terminal settlement timestamp for a claim.
     */
    function getTerminalSettledAt(uint256 claimId) external view returns (uint256) {
        return _terminalSettledAt[claimId];
    }

    // =========================================================================
    // Governance Administration
    // =========================================================================

    function setChallengeWindowDuration(uint256 newDuration) external onlyGovernanceOrAdmin {
        if (newDuration < MIN_CHALLENGE_WINDOW || newDuration > MAX_CHALLENGE_WINDOW) {
            revert InvalidChallengeWindowDuration(newDuration);
        }
        uint256 old = challengeWindowDuration;
        challengeWindowDuration = newDuration;
        emit ChallengeWindowDurationUpdated(old, newDuration);
    }

    function setAggregator(address newAggregator) external onlyGovernanceOrAdmin {
        if (newAggregator == address(0)) revert InvalidAggregatorAddress();
        address old = address(aggregator);
        aggregator = VerificationAggregator(newAggregator);
        emit AggregatorUpdated(old, newAggregator);
    }

    function setParameterVersion(uint256 newVersion) external onlyGovernanceOrAdmin {
        uint256 old = parameterVersion;
        parameterVersion = newVersion;
        emit ParameterVersionUpdated(old, newVersion);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
