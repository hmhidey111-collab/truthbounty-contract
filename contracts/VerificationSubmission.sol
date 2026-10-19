// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "./libraries/BoundedSafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IVerificationSubmission.sol";
import "./interfaces/IClaimRegistry.sol";

/**
 * @title VerificationSubmission
 * @notice On-chain Verification Submission Engine for TruthBounty V2.
 * @dev Handles verifier submissions, locks stakes, and prevents duplicate votes.
 */
contract VerificationSubmission is IVerificationSubmission, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===================================================================================================================
    // Immutables & State
    // ===================================================================================================================

    IClaimRegistry public immutable claimRegistry;
    IERC20 public immutable stakingToken;
    uint256 public immutable minStakeAmount;

    uint256 private _nextVerificationId = 1;

    // verificationId => Verification
    mapping(uint256 => Verification) private _verifications;
    
    // claimId => array of verificationIds
    mapping(uint256 => uint256[]) private _claimVerifications;
    
    // claimId => verifier => hasVerified
    mapping(uint256 => mapping(address => bool)) private _hasVerified;

    // ==================================================================================================================
    // Constants & Errors
    // ===================================================================================================================

    uint256 public constant MAX_VERIFICATIONS_PER_CLAIM = 100;
    uint256 public constant AGGREGATION_PARAMETER_VERSION = 1;

    error MaxParticipantsExceeded();
    error AggregationNotFrozen();

    // ==================================================================================================================
    // Types
    // ==================================================================================================================

    enum VerificationOutcome { Inconclusive, True, False }

    struct AggregationRecord {
        uint256 claimId;
        uint256 trueWeight;
        uint256 falseWeight;
        uint256 trueCount;
        uint256 falseCount;
        VerificationOutcome outcome;
        uint256 parameterVersion;
    }

    // ==================================================================================================================
    // Constructor
    // ==================================================================================================================

    /**
     * @param _claimRegistry Address of the ClaimRegistry contract.
     * @param _stakingToken Address of the ERC20 token used for staking.
     * @param _minStakeAmount Minimum amount of tokens required to submit a verification.
     */
    constructor(
        address _claimRegistry,
        address _stakingToken,
        uint256 _minStakeAmount
    ) {
        if (_claimRegistry == address(0)) revert ZeroAddress();
        if (_stakingToken == address(0)) revert ZeroAddress();

        claimRegistry = IClaimRegistry(_claimRegistry);
        stakingToken = IERC20(_stakingToken);
        minStakeAmount = _minStakeAmount;
    }

    // ==================================================================================================================
    // Write Functions
    // ==================================================================================================================

    /**
     * @inheritdoc IVerificationSubmission
     */
    function submitVerification(
        uint256 claimId,
        VerificationVerdict verdict,
        uint256 stakeAmount
    ) external override nonReentrant {
        // 1. Validation: Eligibility & Duplicate Prevention
        if (stakeAmount < minStakeAmount) revert InsufficientStake();
        if (_hasVerified[claimId][msg.sender]) revert AlreadyVerified();

        // Check claim exists (getClaim reverts if not)
        IClaimRegistry.Claim memory claim = claimRegistry.getClaim(claimId);

        // Check claim state
        if (claim.status != IClaimRegistry.ClaimStatus.UnderVerification) {
            revert InvalidClaimState();
        }

        // Check verification window
        if (block.timestamp > claim.verificationDeadline) {
            revert VerificationWindowClosed();
        }

        // Enforce maximum participants per claim to prevent DoS from unbounded counts.
        if (_claimVerifications[claimId].length >= MAX_VERIFICATIONS_PER_CLAIM) {
            revert MaxParticipantsExceeded();
        }

        // 2. State Updates
        uint256 verificationId = _nextVerificationId;
        unchecked {
            _nextVerificationId = verificationId + 1;
        }

        _hasVerified[claimId][msg.sender] = true;

        _verifications[verificationId] = Verification({
            id: verificationId,
            claimId: claimId,
            verifier: msg.sender,
            verdict: verdict,
            stake: stakeAmount,
            submittedAt: uint64(block.timestamp)
        });

        _claimVerifications[claimId].push(verificationId);

        // 3. Stake Locking
        stakingToken.safeTransferFrom(msg.sender, address(this), stakeAmount);

        // 4. Event Emission
        emit VerificationSubmitted(claimId, verificationId, msg.sender, verdict, stakeAmount);
    }

    // ==================================================================================================================
    // View Functions
    // ==================================================================================================================

    /**
     * @inheritdoc IVerificationSubmission
     */
    function getVerification(uint256 verificationId) external view override returns (Verification memory) {
        return _verifications[verificationId];
    }

    /**
     * @inheritdoc IVerificationSubmission
     */
    function getClaimVerifications(uint256 claimId) external view override returns (uint256[] memory) {
        return _claimVerifications[claimId];
    }

    /**
     * @inheritdoc IVerificationSubmission
     */
    function getClaimVerificationsPaginated(
        uint256 claimId,
        uint256 offset,
        uint256 limit
    ) external view override returns (uint256[] memory verifications, uint256 total) {
        uint256[] storage allVerifications = _claimVerifications[claimId];
        total = allVerifications.length;

        if (offset >= total || limit == 0) {
            return (new uint256[](0), total);
        }

        uint256 count = total - offset;
        if (count > limit) {
            count = limit;
        }

        verifications = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            verifications[i] = allVerifications[offset + i];
        }

        return (verifications, total);
    }

    /**
     * @inheritdoc IVerificationSubmission
     */
    function getVerificationCount() external view override returns (uint256) {
        unchecked {
            return _nextVerificationId - 1;
        }
    }

    /**
     * @inheritdoc IVerificationSubmission
     */
    function hasVerified(uint256 claimId, address verifier) external view override returns (bool) {
        return _hasVerified[claimId][verifier];
    }

    /**
     * @inheritdoc IVerificationSubmission
     */
    function getVerifierStake(uint256 claimId, address verifier) external view override returns (uint256) {
        if (!_hasVerified[claimId][verifier]) {
            return 0;
        }
        
        uint256[] memory claimVerifications = _claimVerifications[claimId];
        for (uint256 i = 0; i < claimVerifications.length; i++) {
            Verification memory v = _verifications[claimVerifications[i]];
            if (v.verifier == verifier) {
                return v.stake;
            }
        }
        return 0;
    }

    /**
     * @dev Computes the canonical deterministic aggregation result for a frozen claim.
     * @param claimId The claim identifier.
     * @return record The aggregation record with weights, counts, outcome, and parameter version.
     */
    function aggregateClaim(uint256 claimId) public view returns (AggregationRecord memory record) {
        IClaimRegistry.Claim memory claim = claimRegistry.getClaim(claimId);

        // Records are frozen only after the verification deadline has passed.
        if (block.timestamp <= claim.verificationDeadline) {
            revert AggregationNotFrozen();
        }

        uint256 trueWeight;
        uint256 falseWeight;
        uint256 trueCount;
        uint256 falseCount;

        uint256[] memory verificationIds = _claimVerifications[claimId];
        for (uint256 i = 0; i < verificationIds.length; i++) {
            Verification memory v = _verifications[verificationIds[i]];
            if (v.verdict == VerificationVerdict.TRUE) {
                trueWeight += v.stake;
                trueCount++;
            } else if (v.verdict == VerificationVerdict.FALSE) {
                falseWeight += v.stake;
                falseCount++;
            }
        }

        VerificationOutcome outcome;
        if (trueWeight == 0 && falseWeight == 0) {
            outcome = VerificationOutcome.Inconclusive;
        } else if (trueWeight > falseWeight) {
            outcome = VerificationOutcome.True;
        } else if (falseWeight > trueWeight) {
            outcome = VerificationOutcome.False;
        } else {
            outcome = VerificationOutcome.Inconclusive;
        }

        record = AggregationRecord({
            claimId: claimId,
            trueWeight: trueWeight,
            falseWeight: falseWeight,
            trueCount: trueCount,
            falseCount: falseCount,
            outcome: outcome,
            parameterVersion: AGGREGATION_PARAMETER_VERSION
        });
    }
}
