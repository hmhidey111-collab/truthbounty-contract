// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UntrackedAssetRecovery} from "../recovery/UntrackedAssetRecovery.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "../libraries/BoundedSafeERC20.sol";
import "../governance/GovernanceOwnable.sol";
import "../governance/GovernanceHooks.sol";
import "../interfaces/ITruthBountyEvents.sol";
import "../IReputationOracle.sol";
import "../treasury/ITreasuryAccounting.sol";

contract RewardEngine is ReentrancyGuard, Pausable, GovernanceOwnable, ITruthBountyEvents, UntrackedAssetRecovery {
    using SafeERC20 for IERC20;
    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant REWARD_ENGINE_ROLE = keccak256("REWARD_ENGINE_ROLE");

    // ============ Constants ============

    uint256 public constant BASE_MULTIPLIER = 1e18;
    uint16 public constant EVENT_SCHEMA_VERSION = 1;
    uint256 public constant PERCENT_DENOMINATOR = 100;
    uint256 public constant MAX_MULTIPLIER = 10e18;
    uint256 public constant MIN_MULTIPLIER = 0;

    // ============ Claim Category ============

    enum ClaimCategory {
        TRIVIAL,
        STANDARD,
        COMPLEX,
        EXPERT
    }

    // ============ Structs ============

    struct RewardCalculation {
        address verifier;
        uint256 baseAmount;
        uint256 reputationMultiplier;
        uint256 difficultyMultiplier;
        uint256 stakeMultiplier;
        uint256 governanceMultiplier;
        uint256 finalAmount;
        uint256 reputationScore;
        uint256 activeStake;
        ClaimCategory category;
        uint256 timestamp;
        bytes32 calculationId;
    }

    enum DistributionStatus {
        NONE,
        CLAIMABLE,
        DISTRIBUTED
    }

    struct RewardDistribution {
        address recipient;
        uint256 claimId;
        bytes32 settlementId;
        bytes32 calculationId;
        uint256 amount;
        uint256 timestamp;
        DistributionStatus status;
        bytes32 distributionId;
    }

    struct MultiplierConfig {
        uint256 minReputationMultiplier;
        uint256 maxReputationMultiplier;
        uint256 minDifficultyMultiplier;
        uint256 maxDifficultyMultiplier;
        uint256 minStakeMultiplier;
        uint256 maxStakeMultiplier;
        uint256 minGovernanceMultiplier;
        uint256 maxGovernanceMultiplier;
    }

    // ============ State Variables ============

    IReputationOracle public reputationOracle;
    
    // Treasury accounting contract for protocol-wide financial tracking
    ITreasuryAccounting public treasuryAccounting;

    /// @notice ERC20 token used for protocol rewards.
    IERC20 public rewardToken;

    /// @notice Total rewards funded into the engine.
    uint256 public totalFunded;

    /// @notice Total rewards allocated to participants.
    uint256 public totalAllocated;

    /// @notice Total rewards successfully transferred.
    uint256 public totalDistributed;

    /// @notice Total claimable rewards currently reserved.
    uint256 public totalReserved;

    /// @notice Maximum records processed in one batch.
    uint256 public constant MAX_DISTRIBUTION_BATCH_SIZE = 100;

    mapping(bytes32 => RewardDistribution) public rewardDistributions;
    mapping(address => bytes32[]) private recipientDistributionIds;
    mapping(address => uint256) public claimableRewards;
    mapping(bytes32 => bool) public processedSettlements;


    uint256 public baseRewardRate = 0.01e18;
    uint256 public minReward = 0;
    uint256 public maxReward = type(uint256).max;
    uint256 public dailyEmissionLimit = type(uint256).max;
    uint256 public antiWhaleLimit = type(uint256).max;

    uint256 public minReputationScore = 1e17;
    uint256 public maxReputationScore = 10e18;
    uint256 public defaultReputationScore = 1e18;

    uint256 public minReputationMultiplier = 0.5e18;
    uint256 public maxReputationMultiplier = 2.0e18;
    uint256 public minDifficultyMultiplier = 1.0e18;
    uint256 public maxDifficultyMultiplier = 3.0e18;
    uint256 public minStakeMultiplier = 1.0e18;
    uint256 public maxStakeMultiplier = 1.5e18;
    uint256 public governanceMultiplier = 1.0e18;

    uint256 public lowStakeThreshold = 1000e18;
    uint256 public highStakeThreshold = 10000e18;

    mapping(ClaimCategory => uint256) public categoryMultipliers;
    mapping(bytes32 => RewardCalculation) public calculations;
    mapping(uint256 => uint256) public dailyEmission;
    mapping(uint256 => mapping(address => uint256)) public dailyVerifierRewards;

    bytes32[] public calculationIds;

    uint256 public calculationCount;

    // ============ Events ============

    event RewardCalculated(
        address indexed verifier,
        uint256 amount,
        bytes32 indexed calculationId
    );

    event RewardTokenUpdated(
        address indexed oldToken,
        address indexed newToken
    );

    event RewardPoolFunded(
        address indexed funder,
        uint256 amount,
        uint256 newBalance
    );

    event RewardAllocated(
        address indexed recipient,
        uint256 indexed claimId,
        bytes32 indexed settlementId,
        bytes32 distributionId,
        uint256 amount,
        bool immediatelyDistributed
    );

    event RewardDistributed(
        address indexed recipient,
        uint256 indexed claimId,
        bytes32 indexed settlementId,
        uint256 amount
    );

    event RewardClaimed(
        address indexed recipient,
        bytes32 indexed distributionId,
        uint256 amount
    );

    event BatchRewardAllocationCompleted(uint256 count);
    event BatchRewardClaimCompleted(address indexed recipient, uint256 count, uint256 amount);

    /// @notice Emitted when an immediate payout inside `allocateRewardsBatch` could not be
    ///         delivered to a hostile, reverting or false-returning recipient and was
    ///         therefore recorded as a pull (claimable) credit instead. The reward remains
    ///         owed exactly once and the recipient can claim it later; the failure is
    ///         isolated and never blocks the other rows of the batch (SC-051).
    event RewardAllocationDeferred(
        address indexed recipient,
        bytes32 indexed distributionId,
        uint256 amount
    );

    event RewardMultiplierUpdated(
        bytes32 indexed multiplier,
        uint256 oldValue,
        uint256 newValue
    );

    event RewardCapReached(
        address indexed participant,
        uint256 attemptedReward,
        string capType
    );

    event CategoryMultiplierUpdated(
        ClaimCategory indexed category,
        uint256 oldMultiplier,
        uint256 newMultiplier
    );

    event BaseRewardRateUpdated(
        uint256 oldRate,
        uint256 newRate
    );

    event ReputationOracleUpdated(
        address indexed oldOracle,
        address indexed newOracle
    );

    event ReputationBoundsUpdated(
        uint256 oldMin,
        uint256 oldMax,
        uint256 newMin,
        uint256 newMax
    );

    event StakeThresholdsUpdated(
        uint256 oldLow,
        uint256 oldHigh,
        uint256 newLow,
        uint256 newHigh
    );

    event TreasuryAccountingUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    // ============ Errors ============

    error InvalidMultiplierConfig();
    error InvalidRewardBounds();
    error InvalidReputationOracle();
    error DailyEmissionExceeded();
    error AntiWhaleLimitExceeded();
    error CalculationNotFound(bytes32 calculationId);
    error ZeroVerifier();
    error ZeroStake();
    error RewardTokenNotConfigured();
    error InvalidRecipient();
    error InvalidRewardAmount();
    error DuplicateRewardSettlement();
    error InsufficientRewardPool();
    error RewardNotClaimable();
    error UnauthorizedRewardClaim();
    error InvalidDistributionBatch();
    error DistributionBatchTooLarge(uint256 provided, uint256 maximum);
    /// @notice Only self-calls may reach the batch isolation trampoline.
    error SelfCallOnly();

    // ============ Constructor ============

    constructor(
        address _reputationOracle,
        address initialAdmin,
        address _governanceController
    ) {
        require(_reputationOracle != address(0), "Invalid oracle address");
        require(initialAdmin != address(0), "Invalid admin address");

        reputationOracle = IReputationOracle(_reputationOracle);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
        _grantRole(DISTRIBUTOR_ROLE, initialAdmin);

        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(DISTRIBUTOR_ROLE, ADMIN_ROLE);

        categoryMultipliers[ClaimCategory.TRIVIAL] = 1.0e18;
        categoryMultipliers[ClaimCategory.STANDARD] = 1.2e18;
        categoryMultipliers[ClaimCategory.COMPLEX] = 1.5e18;
        categoryMultipliers[ClaimCategory.EXPERT] = 2.0e18;

        _initializeGovernance(_governanceController, initialAdmin, initialAdmin);
    }

    // ============ Core Calculation ============

    function calculateReward(
        address verifier,
        uint256 effectiveStake,
        uint256 activeStake,
        ClaimCategory category
    ) external nonReentrant whenNotPaused returns (uint256 rewardAmount, bytes32 calculationId) {
        if (verifier == address(0)) revert ZeroVerifier();
        if (effectiveStake == 0) revert ZeroStake();

        // CEI: INTERACTION first — the oracle call is external and wrapped in
        // try/catch.  All pure arithmetic is performed on the returned values.
        // State is only mutated after every external call is complete.
        uint256 reputationScore = _getReputationScore(verifier); // external call (try/catch)

        uint256 reputationMultiplier = _calculateReputationMultiplier(reputationScore);
        uint256 difficultyMultiplier = _getCategoryMultiplier(category);
        uint256 stakeMultiplier = _calculateStakeMultiplier(activeStake);
        uint256 govMultiplier = governanceMultiplier;

        uint256 baseAmount = (effectiveStake * baseRewardRate) / BASE_MULTIPLIER;

        uint256 finalAmount = baseAmount;
        finalAmount = (finalAmount * reputationMultiplier) / BASE_MULTIPLIER;
        finalAmount = (finalAmount * difficultyMultiplier) / BASE_MULTIPLIER;
        finalAmount = (finalAmount * stakeMultiplier) / BASE_MULTIPLIER;
        finalAmount = (finalAmount * govMultiplier) / BASE_MULTIPLIER;

        if (finalAmount < minReward) finalAmount = minReward;
        if (finalAmount > maxReward) finalAmount = maxReward;

        // CHECKS: enforce emission caps before any state write.
        _enforceEmissionCaps(verifier, finalAmount);

        // EFFECTS: all state writes occur after the external oracle call and all checks.
        calculationId = keccak256(abi.encode(
            verifier, effectiveStake, activeStake, category, block.timestamp, calculationCount
        ));

        calculations[calculationId] = RewardCalculation({
            verifier: verifier,
            baseAmount: baseAmount,
            reputationMultiplier: reputationMultiplier,
            difficultyMultiplier: difficultyMultiplier,
            stakeMultiplier: stakeMultiplier,
            governanceMultiplier: govMultiplier,
            finalAmount: finalAmount,
            reputationScore: reputationScore,
            activeStake: activeStake,
            category: category,
            timestamp: block.timestamp,
            calculationId: calculationId
        });

        calculationIds.push(calculationId);
        calculationCount++;

        uint256 dayKey = block.timestamp / 1 days;
        dailyEmission[dayKey] += finalAmount;
        dailyVerifierRewards[dayKey][verifier] += finalAmount;

        emit RewardCalculated(verifier, finalAmount, calculationId);
        emit RewardCalculatedV1(
            calculationId,
            verifier,
            finalAmount,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );

        return (finalAmount, calculationId);
    }

    function previewReward(
        address verifier,
        uint256 effectiveStake,
        uint256 activeStake,
        ClaimCategory category
    ) external view returns (
        uint256 previewAmount,
        uint256 reputationScore,
        uint256 reputationMultiplier,
        uint256 difficultyMultiplier,
        uint256 stakeMultiplier,
        uint256 govMultiplier
    ) {
        if (verifier == address(0) || effectiveStake == 0) return (0, 0, 0, 0, 0, 0);

        reputationScore = _getReputationScore(verifier);
        reputationMultiplier = _calculateReputationMultiplier(reputationScore);
        difficultyMultiplier = _getCategoryMultiplier(category);
        stakeMultiplier = _calculateStakeMultiplier(activeStake);
        govMultiplier = governanceMultiplier;

        uint256 baseAmount = (effectiveStake * baseRewardRate) / BASE_MULTIPLIER;

        uint256 amount = baseAmount;
        amount = (amount * reputationMultiplier) / BASE_MULTIPLIER;
        amount = (amount * difficultyMultiplier) / BASE_MULTIPLIER;
        amount = (amount * stakeMultiplier) / BASE_MULTIPLIER;
        amount = (amount * govMultiplier) / BASE_MULTIPLIER;

        if (amount < minReward) amount = minReward;
        if (amount > maxReward) amount = maxReward;

        previewAmount = amount;
    }

    function getCalculation(bytes32 calculationId) external view returns (RewardCalculation memory) {
        if (calculations[calculationId].timestamp == 0) revert CalculationNotFound(calculationId);
        return calculations[calculationId];
    }

    function getCalculationCount() external view returns (uint256) {
        return calculationCount;
    }

    function getCalculationsPaginated(
        uint256 offset,
        uint256 limit
    ) external view returns (RewardCalculation[] memory results) {
        uint256 end = offset + limit;
        if (end > calculationCount) end = calculationCount;
        if (offset >= end) return new RewardCalculation[](0);

        results = new RewardCalculation[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            results[i - offset] = calculations[calculationIds[i]];
        }
    }

    function getDailyEmission(uint256 dayKey) external view returns (uint256) {
        return dailyEmission[dayKey];
    }

    function getVerifierDailyRewards(uint256 dayKey, address verifier) external view returns (uint256) {
        return dailyVerifierRewards[dayKey][verifier];
    }

    function getMultiplierConfig() external view returns (MultiplierConfig memory) {
        return MultiplierConfig({
            minReputationMultiplier: minReputationMultiplier,
            maxReputationMultiplier: maxReputationMultiplier,
            minDifficultyMultiplier: minDifficultyMultiplier,
            maxDifficultyMultiplier: maxDifficultyMultiplier,
            minStakeMultiplier: minStakeMultiplier,
            maxStakeMultiplier: maxStakeMultiplier,
            minGovernanceMultiplier: governanceMultiplier,
            maxGovernanceMultiplier: governanceMultiplier
        });
    }

    // ============ Internal Helpers ============

    function _getReputationScore(address user) internal view returns (uint256 score) {
        try reputationOracle.isActive() returns (bool active) {
            if (!active) return defaultReputationScore;
        } catch {
            return defaultReputationScore;
        }

        try reputationOracle.getReputationScore(user) returns (uint256 reputationScore) {
            if (reputationScore == 0) return defaultReputationScore;

            if (reputationScore < minReputationScore) return minReputationScore;
            if (reputationScore > maxReputationScore) return maxReputationScore;
            return reputationScore;
        } catch {
            return defaultReputationScore;
        }
    }

    function _calculateReputationMultiplier(uint256 reputationScore) internal view returns (uint256) {
        if (reputationScore == 0) return minReputationMultiplier;
        if (reputationScore >= maxReputationScore) return maxReputationMultiplier;

        uint256 range = maxReputationScore - minReputationScore;
        if (range == 0) return minReputationMultiplier;

        uint256 multiplierRange = maxReputationMultiplier - minReputationMultiplier;
        uint256 position = reputationScore - minReputationScore;

        return minReputationMultiplier + (position * multiplierRange) / range;
    }

    function _getCategoryMultiplier(ClaimCategory category) internal view returns (uint256) {
        uint256 m = categoryMultipliers[category];
        if (m == 0) return BASE_MULTIPLIER;
        return m;
    }

    function _calculateStakeMultiplier(uint256 activeStake) internal view returns (uint256) {
        if (activeStake <= lowStakeThreshold) return minStakeMultiplier;
        if (activeStake >= highStakeThreshold) return maxStakeMultiplier;

        uint256 range = highStakeThreshold - lowStakeThreshold;
        if (range == 0) return minStakeMultiplier;

        uint256 multiplierRange = maxStakeMultiplier - minStakeMultiplier;
        uint256 position = activeStake - lowStakeThreshold;

        return minStakeMultiplier + (position * multiplierRange) / range;
    }

    function _enforceEmissionCaps(address verifier, uint256 amount) internal view {
        uint256 dayKey = block.timestamp / 1 days;

        if (dailyEmission[dayKey] + amount > dailyEmissionLimit) {
            revert DailyEmissionExceeded();
        }

        if (dailyVerifierRewards[dayKey][verifier] + amount > antiWhaleLimit) {
            revert AntiWhaleLimitExceeded();
        }
    }


    // ============ Reward Distribution ============

    /// @notice Configure the ERC20 token used for reward payouts.
    function setRewardToken(address newToken)
        external
        onlyGovernanceOrAdmin
    {
        if (newToken == address(0)) revert RewardTokenNotConfigured();

        address oldToken = address(rewardToken);
        if (oldToken != address(0)) _protectRecoveryAsset(oldToken);
        rewardToken = IERC20(newToken);

        emit RewardTokenUpdated(oldToken, newToken);
    }

    /// @notice Fund the reward pool.
    function fundRewardPool(uint256 amount)
        external
        nonReentrant
    {
        if (address(rewardToken) == address(0)) {
            revert RewardTokenNotConfigured();
        }
        if (amount == 0) revert InvalidRewardAmount();

        // CEI: EFFECT before INTERACTION — credit the ledger first so any
        // callback through the inbound transferFrom observes the already-updated
        // totalFunded and cannot create a double-fund anomaly.
        totalFunded += amount;

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        emit RewardPoolFunded(
            msg.sender,
            amount,
            rewardToken.balanceOf(address(this))
        );
    }

    /// @notice Allocate a reward produced by a successful settlement.
    /// @param immediate When true, the reward is transferred immediately.
    ///                  Otherwise it becomes claimable by the recipient.
    function allocateReward(
        address recipient,
        uint256 claimId,
        bytes32 settlementId,
        bytes32 calculationId,
        uint256 amount,
        bool immediate
    )
        external
        onlyRole(DISTRIBUTOR_ROLE)
        nonReentrant
        whenNotPaused
        returns (bytes32 distributionId)
    {
        distributionId = _allocateReward(
            recipient,
            claimId,
            settlementId,
            calculationId,
            amount,
            immediate
        );
    }

    /// @notice Allocate multiple settlement rewards atomically.
    function allocateRewardsBatch(
        address[] calldata recipients,
        uint256[] calldata claimIds,
        bytes32[] calldata settlementIds,
        bytes32[] calldata calculationIds_,
        uint256[] calldata amounts,
        bool[] calldata immediate
    )
        external
        onlyRole(DISTRIBUTOR_ROLE)
        nonReentrant
        whenNotPaused
    {
        uint256 length = recipients.length;

        if (
            length == 0 ||
            length != claimIds.length ||
            length != settlementIds.length ||
            length != calculationIds_.length ||
            length != amounts.length ||
            length != immediate.length
        ) {
            revert InvalidDistributionBatch();
        }

        if (length > MAX_DISTRIBUTION_BATCH_SIZE) {
            revert DistributionBatchTooLarge(
                length,
                MAX_DISTRIBUTION_BATCH_SIZE
            );
        }

        for (uint256 i = 0; i < length;) {
            address recipient = recipients[i];
            uint256 claimId = claimIds[i];
            bytes32 settlementId = settlementIds[i];
            bytes32 calculationId = calculationIds_[i];
            uint256 amount = amounts[i];

            if (immediate[i]) {
                // SC-051: isolate immediate payouts. A hostile, reverting or
                // false-returning recipient must never block the other rows of the
                // batch. We route the per-row allocation through an external
                // trampoline so a failed token transfer can be caught.
                try this._allocateRewardExternal(
                    recipient,
                    claimId,
                    settlementId,
                    calculationId,
                    amount,
                    true
                ) {
                    // Row recorded and paid immediately.
                } catch {
                    // The immediate transfer failed. Fall back to a pull credit so the
                    // reward remains owed exactly once and the recipient can claim it
                    // later once the failure is resolved. Deterministic input errors
                    // (duplicate settlement, insufficient pool, zero amount) also fail
                    // this fallback and therefore still revert the batch fail-closed.
                    _allocateReward(
                        recipient,
                        claimId,
                        settlementId,
                        calculationId,
                        amount,
                        false
                    );

                    emit RewardAllocationDeferred(
                        recipient,
                        keccak256(
                            abi.encode(
                                recipient,
                                claimId,
                                settlementId,
                                calculationId
                            )
                        ),
                        amount
                    );
                }
            } else {
                _allocateReward(
                    recipient,
                    claimId,
                    settlementId,
                    calculationId,
                    amount,
                    false
                );
            }

            unchecked {
                ++i;
            }
        }

        emit BatchRewardAllocationCompleted(length);
    }

    /// @notice Claim one previously allocated reward.
    function claimReward(bytes32 distributionId)
        external
        nonReentrant
        whenNotPaused
    {
        RewardDistribution storage distribution =
            rewardDistributions[distributionId];

        if (distribution.recipient != msg.sender) {
            revert UnauthorizedRewardClaim();
        }

        if (distribution.status != DistributionStatus.CLAIMABLE) {
            revert RewardNotClaimable();
        }

        uint256 amount = distribution.amount;

        distribution.status = DistributionStatus.DISTRIBUTED;
        claimableRewards[msg.sender] -= amount;
        totalReserved -= amount;
        totalDistributed += amount;

        rewardToken.safeTransfer(msg.sender, amount);

        emit RewardClaimed(msg.sender, distributionId, amount);
        emit RewardDistributed(
            msg.sender,
            distribution.claimId,
            distribution.settlementId,
            amount
        );
    }

    /// @notice Claim multiple allocated rewards with one token transfer.
    function claimRewardsBatch(bytes32[] calldata distributionIds)
        external
        nonReentrant
        whenNotPaused
    {
        uint256 length = distributionIds.length;

        if (length == 0) revert InvalidDistributionBatch();
        if (length > MAX_DISTRIBUTION_BATCH_SIZE) {
            revert DistributionBatchTooLarge(
                length,
                MAX_DISTRIBUTION_BATCH_SIZE
            );
        }

        uint256 totalAmount;

        for (uint256 i = 0; i < length;) {
            RewardDistribution storage distribution =
                rewardDistributions[distributionIds[i]];

            if (distribution.recipient != msg.sender) {
                revert UnauthorizedRewardClaim();
            }

            if (distribution.status != DistributionStatus.CLAIMABLE) {
                revert RewardNotClaimable();
            }

            distribution.status = DistributionStatus.DISTRIBUTED;
            totalAmount += distribution.amount;

            emit RewardClaimed(
                msg.sender,
                distributionIds[i],
                distribution.amount
            );

            emit RewardDistributed(
                msg.sender,
                distribution.claimId,
                distribution.settlementId,
                distribution.amount
            );

            unchecked {
                ++i;
            }
        }

        claimableRewards[msg.sender] -= totalAmount;
        totalReserved -= totalAmount;
        totalDistributed += totalAmount;

        rewardToken.safeTransfer(msg.sender, totalAmount);

        emit BatchRewardClaimCompleted(
            msg.sender,
            length,
            totalAmount
        );
    }

    function _allocateReward(
        address recipient,
        uint256 claimId,
        bytes32 settlementId,
        bytes32 calculationId,
        uint256 amount,
        bool immediate
    )
        internal
        returns (bytes32 distributionId)
    {
        if (address(rewardToken) == address(0)) {
            revert RewardTokenNotConfigured();
        }
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidRewardAmount();

        distributionId = keccak256(
            abi.encode(
                recipient,
                claimId,
                settlementId,
                calculationId
            )
        );

        if (
            processedSettlements[distributionId] ||
            rewardDistributions[distributionId].status !=
                DistributionStatus.NONE
        ) {
            revert DuplicateRewardSettlement();
        }

        uint256 currentBalance =
            rewardToken.balanceOf(address(this));

        if (currentBalance < totalReserved + amount) {
            revert InsufficientRewardPool();
        }

        processedSettlements[distributionId] = true;
        totalAllocated += amount;

        DistributionStatus status = immediate
            ? DistributionStatus.DISTRIBUTED
            : DistributionStatus.CLAIMABLE;

        rewardDistributions[distributionId] = RewardDistribution({
            recipient: recipient,
            claimId: claimId,
            settlementId: settlementId,
            calculationId: calculationId,
            amount: amount,
            timestamp: block.timestamp,
            status: status,
            distributionId: distributionId
        });

        recipientDistributionIds[recipient].push(distributionId);

        if (immediate) {
            totalDistributed += amount;
            rewardToken.safeTransfer(recipient, amount);

            emit RewardDistributed(
                recipient,
                claimId,
                settlementId,
                amount
            );
        } else {
            claimableRewards[recipient] += amount;
            totalReserved += amount;
        }

        emit RewardAllocated(
            recipient,
            claimId,
            settlementId,
            distributionId,
            amount,
            immediate
        );
    }

    /**
     * @dev External trampoline around `_allocateReward` used by `allocateRewardsBatch`
     *      so that a reverting or false-returning recipient can be isolated with
     *      `try/catch`. Guarded to self-calls so it cannot be invoked externally.
     */
    function _allocateRewardExternal(
        address recipient,
        uint256 claimId,
        bytes32 settlementId,
        bytes32 calculationId,
        uint256 amount,
        bool immediate
    ) external returns (bytes32 distributionId) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        distributionId = _allocateReward(
            recipient,
            claimId,
            settlementId,
            calculationId,
            amount,
            immediate
        );
    }

    function getRecipientDistributionCount(address recipient)
        external
        view
        returns (uint256)
    {
        return recipientDistributionIds[recipient].length;
    }

    function getRecipientDistributions(
        address recipient,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (RewardDistribution[] memory results)
    {
        bytes32[] storage ids = recipientDistributionIds[recipient];
        uint256 total = ids.length;

        if (offset >= total || limit == 0) {
            return new RewardDistribution[](0);
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        results = new RewardDistribution[](end - offset);

        for (uint256 i = offset; i < end;) {
            results[i - offset] = rewardDistributions[ids[i]];

            unchecked {
                ++i;
            }
        }
    }

    function availableRewardBalance()
        external
        view
        returns (uint256)
    {
        if (address(rewardToken) == address(0)) return 0;

        uint256 balance = rewardToken.balanceOf(address(this));

        if (balance <= totalReserved) return 0;
        return balance - totalReserved;
    }

    // ============ Admin/Gov Setter Functions ============

    function setBaseRewardRate(uint256 _newRate) external onlyGovernanceOrAdmin {
        require(_newRate > 0, "Rate must be > 0");
        uint256 old = baseRewardRate;
        baseRewardRate = _newRate;
        emit BaseRewardRateUpdated(old, _newRate);
        emit ParameterUpdatedByGovernance(
            keccak256("BASE_REWARD_RATE"), old, _newRate
        );
    }

    function setRewardBounds(uint256 _min, uint256 _max) external onlyGovernanceOrAdmin {
        if (_min > _max) revert InvalidRewardBounds();
        uint256 oldMin = minReward;
        uint256 oldMax = maxReward;
        minReward = _min;
        maxReward = _max;
        emit ParameterUpdatedByGovernance(keccak256("MIN_REWARD_AMOUNT"), oldMin, _min);
        emit ParameterUpdatedByGovernance(keccak256("MAX_REWARD_AMOUNT"), oldMax, _max);
    }

    function setDailyEmissionLimit(uint256 _limit) external onlyGovernanceOrAdmin {
        uint256 old = dailyEmissionLimit;
        dailyEmissionLimit = _limit;
        emit ParameterUpdatedByGovernance(keccak256("DAILY_EMISSION_LIMIT"), old, _limit);
    }

    function setAntiWhaleLimit(uint256 _limit) external onlyGovernanceOrAdmin {
        uint256 old = antiWhaleLimit;
        antiWhaleLimit = _limit;
        emit ParameterUpdatedByGovernance(keccak256("ANTI_WHALE_LIMIT"), old, _limit);
    }

    function setReputationMultiplierBounds(uint256 _min, uint256 _max) external onlyGovernanceOrAdmin {
        if (_min < MIN_MULTIPLIER || _max > MAX_MULTIPLIER || _min > _max) revert InvalidMultiplierConfig();
        uint256 oldMin = minReputationMultiplier;
        uint256 oldMax = maxReputationMultiplier;
        minReputationMultiplier = _min;
        maxReputationMultiplier = _max;
        emit RewardMultiplierUpdated(keccak256("REPUTATION_MULTIPLIER"), oldMin, _min);
        emit RewardMultiplierUpdated(keccak256("REPUTATION_MULTIPLIER"), oldMax, _max);
    }

    function setDifficultyMultiplierBounds(uint256 _min, uint256 _max) external onlyGovernanceOrAdmin {
        if (_min < MIN_MULTIPLIER || _max > MAX_MULTIPLIER || _min > _max) revert InvalidMultiplierConfig();
        uint256 oldMin = minDifficultyMultiplier;
        uint256 oldMax = maxDifficultyMultiplier;
        minDifficultyMultiplier = _min;
        maxDifficultyMultiplier = _max;
        emit RewardMultiplierUpdated(keccak256("DIFFICULTY_MULTIPLIER"), oldMin, _min);
        emit RewardMultiplierUpdated(keccak256("DIFFICULTY_MULTIPLIER"), oldMax, _max);
    }

    function setStakeMultiplierBounds(uint256 _min, uint256 _max) external onlyGovernanceOrAdmin {
        if (_min < MIN_MULTIPLIER || _max > MAX_MULTIPLIER || _min > _max) revert InvalidMultiplierConfig();
        uint256 oldMin = minStakeMultiplier;
        uint256 oldMax = maxStakeMultiplier;
        minStakeMultiplier = _min;
        maxStakeMultiplier = _max;
        emit RewardMultiplierUpdated(keccak256("STAKE_MULTIPLIER"), oldMin, _min);
        emit RewardMultiplierUpdated(keccak256("STAKE_MULTIPLIER"), oldMax, _max);
    }

    function setGovernanceMultiplier(uint256 _multiplier) external onlyGovernanceOrAdmin {
        if (_multiplier < MIN_MULTIPLIER || _multiplier > MAX_MULTIPLIER) revert InvalidMultiplierConfig();
        uint256 old = governanceMultiplier;
        governanceMultiplier = _multiplier;
        emit RewardMultiplierUpdated(keccak256("GOVERNANCE_MULTIPLIER"), old, _multiplier);
        emit ParameterUpdatedByGovernance(keccak256("GOVERNANCE_MULTIPLIER"), old, _multiplier);
    }

    function setCategoryMultiplier(ClaimCategory category, uint256 multiplier) external onlyGovernanceOrAdmin {
        if (multiplier < MIN_MULTIPLIER || multiplier > MAX_MULTIPLIER) revert InvalidMultiplierConfig();
        uint256 old = categoryMultipliers[category];
        categoryMultipliers[category] = multiplier;
        emit CategoryMultiplierUpdated(category, old, multiplier);
    }

    function setReputationBounds(uint256 _min, uint256 _max) external onlyGovernanceOrAdmin {
        if (_min == 0 || _min >= _max) revert InvalidMultiplierConfig();
        uint256 oldMin = minReputationScore;
        uint256 oldMax = maxReputationScore;
        minReputationScore = _min;
        maxReputationScore = _max;
        emit ReputationBoundsUpdated(oldMin, oldMax, _min, _max);
    }

    function setDefaultReputationScore(uint256 _score) external onlyGovernanceOrAdmin {
        require(_score > 0, "Invalid score");
        uint256 old = defaultReputationScore;
        defaultReputationScore = _score;
        emit ParameterUpdatedByGovernance(keccak256("DEFAULT_REPUTATION_SCORE"), old, _score);
    }

    function setStakeThresholds(uint256 _low, uint256 _high) external onlyGovernanceOrAdmin {
        if (_low >= _high) revert InvalidMultiplierConfig();
        uint256 oldLow = lowStakeThreshold;
        uint256 oldHigh = highStakeThreshold;
        lowStakeThreshold = _low;
        highStakeThreshold = _high;
        emit StakeThresholdsUpdated(oldLow, oldHigh, _low, _high);
    }

    function setReputationOracle(address _newOracle) external onlyRole(ADMIN_ROLE) {
        if (_newOracle == address(0)) revert InvalidReputationOracle();
        address oldOracle = address(reputationOracle);
        reputationOracle = IReputationOracle(_newOracle);
        emit ReputationOracleUpdated(oldOracle, _newOracle);
    }

    /**
     * @dev Set the treasury accounting contract (admin only)
     * @param _treasuryAccounting Address of the deployed TreasuryAccounting contract
     */
    function setTreasuryAccounting(address _treasuryAccounting) external onlyRole(ADMIN_ROLE) {
        require(_treasuryAccounting != address(0), "Invalid treasury address");
        address oldTreasury = address(treasuryAccounting);
        treasuryAccounting = ITreasuryAccounting(_treasuryAccounting);
        emit TreasuryAccountingUpdated(oldTreasury, _treasuryAccounting);
    }

    /**
     * @dev Distribute a calculated reward to a verifier, recording it in treasury accounting
     * @param recipient Address to receive the reward
     * @param amount Amount of reward to distribute
     */
    function distributeReward(address recipient, uint256 amount) external onlyRole(DISTRIBUTOR_ROLE) whenNotPaused {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Cannot distribute 0");
        require(address(treasuryAccounting) != address(0), "Treasury not configured");
        
        // Record the reward distribution in treasury accounting
        treasuryAccounting.recordRewardDistribution(recipient, amount);
    }

    // ============ Pause ============

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
        emit EmergencyPauseActivatedV1(

            msg.sender,

            keccak256("MANUAL_PAUSE"),

            uint64(block.timestamp),

            EVENT_SCHEMA_VERSION

        );
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
        emit EmergencyPauseRecoveredV1(

            msg.sender,

            uint64(block.timestamp),

            EVENT_SCHEMA_VERSION

        );
    }

    // V2-SC-154: additive recovery only; existing liability and authority paths remain authoritative.
    function _checkAssetRecoveryAuthority() internal view override {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender) || !governanceEnabled) revert RecoveryAuthorityUnavailable();
    }

    function _requireAssetRecoveryAllowed() internal view override {
        if (paused()) revert RecoveryPaused();
    }

    function _reservedAssetBalance(address asset) internal view override returns (uint256) {
        // The balance-backed funding pool includes unallocated and deferred rewards.
        // Historical reward assets remain protected after token configuration changes.
        return asset == address(rewardToken) || _isProtectedRecoveryAsset(asset) ? IERC20(asset).balanceOf(address(this)) : 0;
    }
}
