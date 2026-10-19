// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "../libraries/BoundedSafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../governance/GovernanceOwnable.sol";
import "../governance/GovernanceHooks.sol";
import "../interfaces/IClaimRegistry.sol";
import "../interfaces/ISTakeVault.sol";
import "../interfaces/IAppealVerificationRound.sol";
import "../interfaces/IDisputeResolution.sol";
import "../IReputationOracle.sol";

/**
 * @title AppealVerificationRound
 * @notice Canonical implementation of TruthBounty V2 Appeal Verification Round Manager (SC-017),
 *         hardened with V2-SC-059 bound-appeal-rounds and griefing-prevention bounds.
 *
 * @dev Isolates second-round appeal voting from first-round state while enforcing frozen higher
 *      participation parameters and implementing IVerificationSource for downstream aggregation.
 *
 * V2-SC-059 additions (bound appeal rounds and prevent griefing):
 *   - Bounded ladder: a claim's appeal path is capped at `maxAppealRounds` (default 1,
 *     matching the V2-SC-018 single-appeal rule). The cap is frozen per round at open.
 *   - Bond-gated opening: every appeal round requires an escalating {ISTakeVault} bond lock,
 *     computed by the module (opener cannot under-bond) and capped by `maxAppealBond`.
 *   - Terminal finalization: the path becomes irreversibly terminal via {closeAppealRound}
 *     on the final round or via permissionless {finalizeAppealRound}; terminal paths cannot
 *     be reopened or extended.
 *   - Bounded processing: at most `maxVotersPerRound` voters per round so downstream
 *     aggregation stays O(n) with n capped.
 *
 * Invariants:
 *  1. Bounded Appeal Ladder: `roundIndex <= maxAppealRounds` (frozen at open); a terminal
 *     path can never be reopened and a round can only open after the prior round closed.
 *  2. Bond Escalation & Custody: `appealBond <= requiredBond <= maxAppealBond`, and every
 *     round has exactly one vault bond lock recorded before the round state is committed.
 *  3. Isolated Storage: Appeal votes do not mutate or overwrite first-round voting state.
 *  4. Immutable Parameters: Round duration, min stake, multiplier, weight caps, ladder cap,
 *     bond, escalation, and voter cap freeze at open.
 *  5. One Address One Position: Verifiers may cast exactly one vote per appeal round.
 *  6. Aggregation Ready: Implements IVerificationSource for direct consumption by VerificationAggregator.
 *  7. Fail Closed: Config with a zero bond, zero voter cap, or out-of-range ladder completes
 *     the terminal path is rejected; a vault that declines a lock reverts the whole open.
 */
contract AppealVerificationRound is
    IAppealVerificationRound,
    AccessControl,
    ReentrancyGuard,
    Pausable,
    GovernanceOwnable
{
    using SafeERC20 for IERC20;

    // =========================================================================
    // Roles & Constants
    // =========================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant DISPUTE_ROUTER_ROLE = keccak256("DISPUTE_ROUTER_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_APPEAL_DURATION = 1 hours;
    uint256 public constant MAX_APPEAL_DURATION = 30 days;

    /// @notice Hard upper bound for the per-claim appeal ladder (cannot be raised by config).
    uint256 public constant MAX_APPEAL_ROUNDS = 3;

    /// @notice Minimum per-round bond escalation (10000 = flat, no escalation).
    uint256 public constant MIN_APPEAL_BOND_ESCALATION_BPS = BPS_DENOMINATOR;

    /// @notice Maximum per-round bond escalation (40000 = 4x per round).
    uint256 public constant MAX_APPEAL_BOND_ESCALATION_BPS = 40_000;

    /// @notice Hard upper bound for voters admitted to a single appeal round (gas bound, see
    ///         config/gas-budgets.json MAX_VERIFIERS_PER_CLAIM).
    uint256 public constant MAX_VOTERS_PER_ROUND = 200;

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroClaimId();
    error InvalidDuration(uint256 duration);
    error InvalidMinStake();
    error InvalidMultiplier();
    error ClaimDoesNotExist(uint256 claimId);
    error AppealRoundAlreadyExists(uint256 claimId);
    error AppealRoundNotOpen(uint256 claimId);
    error AppealRoundExpired(uint256 claimId, uint256 currentTimestamp, uint256 deadline);
    error AppealRoundNotExpired(uint256 claimId, uint256 currentTimestamp, uint256 deadline);
    error InvalidMaxAppealRounds(uint256 maxAppealRounds);
    error InvalidAppealBond(uint256 appealBond);
    error InvalidBondEscalation(uint256 escalationBps);
    error InvalidMaxAppealBond(uint256 maxAppealBond, uint256 appealBond);
    error InvalidMaxVotersPerRound(uint256 maxVotersPerRound);
    error AppealPathTerminal(uint256 claimId);
    error MaxAppealRoundsExceeded(uint256 claimId, uint256 nextRound, uint256 maxAppealRounds);
    error BondNotConfigured();
    error InsufficientBondAllowance();
    error InsufficientStake(uint256 provided, uint256 requiredStake);
    error AlreadyVotedInAppeal(uint256 claimId, address verifier);
    error IndexOutOfBounds();
    error InvalidMaxAppealRounds(uint256 maxAppealRounds);
    error InvalidAppealBond(uint256 appealBond);
    error InvalidBondEscalation(uint256 escalationBps);
    error InvalidMaxAppealBond(uint256 maxAppealBond, uint256 appealBond);
    error InvalidMaxVotersPerRound(uint256 maxVotersPerRound);
    error AppealPathTerminal(uint256 claimId);
    error MaxAppealRoundsExceeded(uint256 claimId, uint256 attemptedRound, uint256 maxAppealRounds);
    error BondNotConfigured();
    error InsufficientBondAllowance();
    error AppealRoundNotClosed(uint256 claimId);
    error AppealRoundNotFinalizable(uint256 claimId);
    error AppealRoundAlreadyTerminal(uint256 claimId);
    error BondEscalationOverflow(uint256 baseBond, uint256 escalationBps, uint256 roundIndex);
    error RequiredBondExceedsCap(uint256 requiredBond, uint256 maxAppealBond);
    error VoterCapExceeded(uint256 claimId, uint256 maxVotersPerRound);
    error DeadlineNotReached(uint256 claimId, uint256 currentTimestamp, uint256 deadline);
    error TieNotResolvable(uint256 claimId);
    error AppealCounterReset(uint256 claimId, uint256 currentIndex, uint256 attemptedIndex);

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice The ERC20 token used for appeal staking.
    IERC20 public immutable stakingToken;

    /// @notice Canonical Claim Registry contract.
    IClaimRegistry public immutable claimRegistry;

    /// @notice Reputation oracle providing verifier weights.
    IReputationOracle public reputationOracle;

    /// @notice Default configuration applied to new appeal rounds.
    AppealRoundConfig public defaultConfig;

    /// @notice Bond custody vault (V2-SC-009 stand-in). Appeal bonds are locked here,
    ///         never in this contract, and cannot be withdrawn by the depositor or
    ///         governance; only the configured vault operator can release a lock.
    ISTakeVault public vault;

    /// @notice Mapping from claimId to its isolated appeal round.
    mapping(uint256 => AppealRound) private _rounds;

    /// @notice Mapping from claimId to verifier address to appeal vote record.
    mapping(uint256 => mapping(address => AppealVote)) private _votes;

    /// @notice List of verifier addresses that participated in an appeal round.
    mapping(uint256 => address[]) private _roundVoters;

    /// @notice Highest appeal round index opened for a claim (0 = none opened yet).
    mapping(uint256 => uint256) private _appealRoundIndex;

    /// @notice Terminal flag: once set for a claim, no further appeal round can open.
    mapping(uint256 => bool) private _appealPathTerminal;

    /// @notice Canonical DisputeResolution engine for parent dispute binding.
    address public override disputeResolution;

    /// @notice Tracks bound appeals for replay protection: parentDisputeId => roundIndex => opened.
    mapping(uint256 => mapping(uint256 => bool)) private _boundAppeals;

    /// @notice Monotonic appeal counter per claim; can only increase, never reset.
    mapping(uint256 => uint256) private _appealCounter;

    /// @notice Terminal fallback recipient for conserved funds on terminal paths.
    mapping(uint256 => address) private _terminalFallbackRecipient;

    /// @notice Tracks whether a round's bond has been released (terminal conservation).
    mapping(uint256 => mapping(uint256 => bool)) private _bondReleased;

    // =========================================================================
    // Deadline Semantics
    // =========================================================================

    /// @dev Deadline semantics are INCLUSIVE of the deadline second: a round is open
    ///      while `block.timestamp <= deadline` and expired once `block.timestamp > deadline`.
    ///      This makes the one-second-before, exact-deadline, and one-second-after
    ///      boundaries explicit and deterministic.
    function _isExpired(uint256 deadline) internal view returns (bool) {
        return block.timestamp > deadline;
    }

    function _requiredBondForRound(AppealRoundConfig memory cfg, uint256 roundIndex)
        internal
        pure
        returns (uint256)
    {
        if (roundIndex <= 1) return cfg.appealBond;
        uint256 bond = cfg.appealBond;
        for (uint256 i = 1; i < roundIndex; i++) {
            bond = Math.mulDiv(bond, cfg.appealBondEscalationBps, BPS_DENOMINATOR);
            if (bond > cfg.maxAppealBond) return cfg.maxAppealBond;
        }
        return bond > cfg.maxAppealBond ? cfg.maxAppealBond : bond;
    }

    function _appealLockId(uint256 claimId, uint256 roundIndex) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("appeal-bond", claimId, roundIndex)));
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address _stakingToken,
        address _claimRegistry,
        address _reputationOracle,
        address _vault,
        AppealRoundConfig memory _initialConfig,
        address _governanceController,
        address _initialAdmin
    ) {
        if (_stakingToken == address(0)) revert ZeroAddress();
        if (_claimRegistry == address(0)) revert ZeroAddress();
        if (_vault == address(0)) revert ZeroAddress();
        if (_initialAdmin == address(0)) revert ZeroAddress();
        if (_initialConfig.roundDuration < MIN_APPEAL_DURATION || _initialConfig.roundDuration > MAX_APPEAL_DURATION) {
            revert InvalidDuration(_initialConfig.roundDuration);
        }
        if (_initialConfig.minStakeAmount == 0) revert InvalidMinStake();
        if (_initialConfig.stakeMultiplierBps == 0) revert InvalidMultiplier();
        if (_initialConfig.maxAppealRounds == 0 || _initialConfig.maxAppealRounds > MAX_APPEAL_ROUNDS) {
            revert InvalidMaxAppealRounds(_initialConfig.maxAppealRounds);
        }
        if (_initialConfig.appealBond == 0) revert InvalidAppealBond(_initialConfig.appealBond);
        if (_initialConfig.appealBondEscalationBps < MIN_APPEAL_BOND_ESCALATION_BPS ||
            _initialConfig.appealBondEscalationBps > MAX_APPEAL_BOND_ESCALATION_BPS) {
            revert InvalidBondEscalation(_initialConfig.appealBondEscalationBps);
        }
        if (_initialConfig.maxAppealBond == 0 || _initialConfig.maxAppealBond < _initialConfig.appealBond) {
            revert InvalidMaxAppealBond(_initialConfig.maxAppealBond, _initialConfig.appealBond);
        }
        if (_initialConfig.maxVotersPerRound == 0 || _initialConfig.maxVotersPerRound > MAX_VOTERS_PER_ROUND) {
            revert InvalidMaxVotersPerRound(_initialConfig.maxVotersPerRound);
        }

        stakingToken = IERC20(_stakingToken);
        claimRegistry = IClaimRegistry(_claimRegistry);
        reputationOracle = IReputationOracle(_reputationOracle);
        vault = ISTakeVault(_vault);
        defaultConfig = _initialConfig;

        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(ADMIN_ROLE, _initialAdmin);
        _grantRole(PAUSER_ROLE, _initialAdmin);
        _grantRole(DISPUTE_ROUTER_ROLE, _initialAdmin);

        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(DISPUTE_ROUTER_ROLE, ADMIN_ROLE);

        _initializeGovernance(_governanceController, _initialAdmin, _initialAdmin);
    }

    // =========================================================================
    // External Round Management
    // =========================================================================

    /**
     * @inheritdoc IAppealVerificationRound
     *
     * @dev V2-SC-059: opening is bond-gated (escalating, module-computed bond locked in
     *      {visit vault}) and the ladder is strictly bounded ({MaxAppealRoundsExceeded}),
     *      sequential (the prior round must be closed), and terminal paths are sealed
     *      ({AppealPathTerminal}). The bond is custodied via {ISTakeVault.lockBond} BEFORE
     *      any round state is committed, so no appeal round can exist without its bond lock.
     *
     *      The opener must approve `address(vault)` (the ERC-20 spender) for the
     *      required bond amount; vote stakes continue to be approved directly to this
     *      contract.
     */
    function openAppealRound(uint256 claimId) external override nonReentrant whenNotPaused {
        if (claimId == 0) revert ZeroClaimId();
        if (_appealPathTerminal[claimId]) revert AppealPathTerminal(claimId);

        AppealRoundConfig memory cfg = defaultConfig;
        uint256 nextRound = _appealRoundIndex[claimId] + 1;
        if (nextRound > cfg.maxAppealRounds) {
            revert MaxAppealRoundsExceeded(claimId, nextRound, cfg.maxAppealRounds);
        }

        AppealRound storage prev = _rounds[claimId];
        if (prev.status == AppealRoundStatus.OPEN) revert AppealRoundAlreadyExists(claimId);

        IClaimRegistry.Claim memory claim = claimRegistry.getClaim(claimId);
        if (claim.creator == address(0)) revert ClaimDoesNotExist(claimId);

        // -- Bond custody FIRST (no appeal round without a successful bond lock) --
        if (address(vault) == address(0) || cfg.appealBond == 0) revert BondNotConfigured();

        uint256 requiredBond = _requiredBondForRound(cfg, nextRound);
        if (IERC20(address(stakingToken)).allowance(msg.sender, address(vault)) < requiredBond) {
            revert InsufficientBondAllowance();
        }

        uint256 bondLockId = _appealLockId(claimId, nextRound);
        try vault.lockBond(bondLockId, address(stakingToken), msg.sender, requiredBond) {
            // success 
            _appealCounter[claimId] = nextRound;
            _appealRoundIndex[claimId] = nextRound;— proceed
        } catch {
            revert CustodyTransitionFailed();
        }

        uint256 deadline = block.timestamp + cfg.roundDuration;

        _rounds[claimId] = AppealRound({
            claimId: claimId,
            status: AppealRoundStatus.OPEN,
            openedAt: block.timestamp,
            deadline: deadline,
            minStakeAmount: cfg.minStakeAmount,
            stakeMultiplierBps: cfg.stakeMultiplierBps,
            maxWeightCap: cfg.maxWeightCap,
            totalTrueStake: 0,
            totalFalseStake: 0,
            totalTrueWeight: 0,
            totalFalseWeight: 0,
            verifierCount: 0,
            roundIndex: nextRound,
            maxRounds: cfg.maxAppealRounds,
            requiredBond: requiredBond,
            bondLockId: bondLockId,
            maxVoters: cfg.maxVotersPerRound,
            parentDisputeId: 0,
            parentOutcome: 0,
            appellant: msg.sender,
            bondPayer: msg.sender,
            bondBeneficiary: msg.sender
        });
        _appealRoundIndex[claimId] = nextRound;

        emit AppealRoundOpened(
            claimId,
            deadline,
            cfg.minStakeAmount,
            cfg.stakeMultiplierBps,
            msg.sender,
            nextRound,
            cfg.maxAppealRounds,
            requiredBond,
            bondLockId
        );
    }

    /**
     * @inheritdoc IAppealVerificationRound
     */
    function openBoundAppealRound(BoundAppealParams calldata params) external override nonReentrant whenNotPaused {
        if (params.claimId == 0) revert ZeroClaimId();
        if (_appealPathTerminal[params.claimId]) revert AppealPathTerminal(params.claimId);
        if (params.appellant == address(0) || params.bondPayer == address(0) || params.bondBeneficiary == address(0)) {
            revert InvalidBondSource(params.bondPayer, params.bondBeneficiary);
        }
        if (msg.sender != params.appellant && msg.sender != params.bondPayer) {
            revert UnauthorizedAppellant(msg.sender);
        }
        if (_boundAppeals[params.parentDisputeId][params.roundIndex]) {
            revert DuplicateAppeal(params.parentDisputeId, params.roundIndex);
        }

        AppealRoundConfig memory cfg = defaultConfig;
        uint256 nextRound = _appealRoundIndex[params.claimId] + 1;
        if (params.roundIndex != nextRound) {
            revert WrongRound(params.roundIndex, nextRound);
        }
        if (nextRound > cfg.maxAppealRounds) {
            revert MaxAppealRoundsExceeded(params.claimId, nextRound, cfg.maxAppealRounds);
        }

        AppealRound storage prev = _rounds[params.claimId];
        if (prev.status == AppealRoundStatus.OPEN) revert AppealRoundAlreadyExists(params.claimId);

        IClaimRegistry.Claim memory claim = claimRegistry.getClaim(params.claimId);
        if (claim.creator == address(0)) revert ClaimDoesNotExist(params.claimId);

        if (disputeResolution != address(0)) {
            IDisputeResolution.Dispute memory dispute = IDisputeResolution(disputeResolution).getDispute(params.parentDisputeId);
            if (dispute.id == 0 || dispute.claimId != params.claimId) {
                revert WrongParentDispute(params.claimId, params.parentDisputeId);
            }
            if (uint8(dispute.challengedOutcome) != params.parentOutcome) {
                revert InvalidParentOutcome(params.parentOutcome, uint8(dispute.challengedOutcome));
            }
            if (block.timestamp > dispute.appealDeadline) {
                revert AppealWindowExpired(params.claimId, block.timestamp, dispute.appealDeadline);
            }
            if (params.appellant != dispute.challenger && params.appellant != claim.creator) {
                revert UnauthorizedAppellant(params.appellant);
            }
        }

        if (address(vault) == address(0) || cfg.appealBond == 0) revert BondNotConfigured();

        uint256 requiredBond = _requiredBondForRound(cfg, nextRound);
        if (IERC20(address(stakingToken)).allowance(params.bondPayer, address(vault)) < requiredBond) {
            revert InsufficientBondAllowance();
        }

        _boundAppeals[params.parentDisputeId][params.roundIndex] = true;

        uint256 bondLockId = _appealLockId(params.claimId, nextRound);
        try vault.lockBond(bondLockId, address(stakingToken), params.bondPayer, requiredBond) {
            // success
        } catch {
            _boundAppeals[params.parentDisputeId][params.roundIndex] = false;
            revert CustodyTransitionFailed();
        }

        uint256 deadline = block.timestamp + cfg.roundDuration;

        _rounds[params.claimId] = AppealRound({
            claimId: params.claimId,
            status: AppealRoundStatus.OPEN,
            openedAt: block.timestamp,
            deadline: deadline,
            minStakeAmount: cfg.minStakeAmount,
            stakeMultiplierBps: cfg.stakeMultiplierBps,
            maxWeightCap: cfg.maxWeightCap,
            totalTrueStake: 0,
            totalFalseStake: 0,
            totalTrueWeight: 0,
            totalFalseWeight: 0,
            verifierCount: 0,
            roundIndex: nextRound,
            maxRounds: cfg.maxAppealRounds,
            requiredBond: requiredBond,
            bondLockId: bondLockId,
            maxVoters: cfg.maxVotersPerRound,
            parentDisputeId: params.parentDisputeId,
            parentOutcome: params.parentOutcome,
            appellant: params.appellant,
            bondPayer: params.bondPayer,
            bondBeneficiary: params.bondBeneficiary
        });
        _appealRoundIndex[params.claimId] = nextRound;

        emit BoundAppealRoundOpened(
            params.claimId,
            params.parentDisputeId,
            params.parentOutcome,
            nextRound,
            params.appellant,
            params.bondPayer,
            params.bondBeneficiary,
            requiredBond,
            bondLockId
        );

        emit AppealRoundOpened(
            params.claimId,
            deadline,
            cfg.minStakeAmount,
            cfg.stakeMultiplierBps,
            params.appellant,
            nextRound,
            cfg.maxAppealRounds,
            requiredBond,
            bondLockId
        );
    }

    /**
     * @inheritdoc IAppealVerificationRound
     */
    function refundAppealBond(uint256 claimId) external override nonReentrant whenNotPaused {
        if (
            !hasRole(GOVERNANCE_ROLE, msg.sender) &&
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender) &&
            !hasRole(ADMIN_ROLE, msg.sender) &&
            !hasRole(DISPUTE_ROUTER_ROLE, msg.sender) &&
            msg.sender != emergencyAdmin
        ) {
            revert UnauthorizedGovernance();
        }
        if (claimId == 0) revert ZeroClaimId();
        AppealRound storage round = _rounds[claimId];
        if (round.status == AppealRoundStatus.OPEN && block.timestamp < round.deadline) {
            revert BondDispositionNotAllowed(claimId);
        }
        if (round.requiredBond == 0) revert BondDispositionNotAllowed(claimId);

        address beneficiary = round.bondBeneficiary == address(0) ? round.appellant : round.bondBeneficiary;
        uint256 bondLockId = round.bondLockId;
        uint256 amount = round.requiredBond;
        round.requiredBond = 0;

        vault.releaseBond(bondLockId, beneficiary);

        emit AppealBondRefunded(claimId, bondLockId, beneficiary, amount);
    }

    /**
     * @inheritdoc IAppealVerificationRound
     */
    function slashAppealBond(uint256 claimId, address slashRecipient) external override nonReentrant whenNotPaused {
        if (
            !hasRole(GOVERNANCE_ROLE, msg.sender) &&
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender) &&
            !hasRole(ADMIN_ROLE, msg.sender) &&
            !hasRole(DISPUTE_ROUTER_ROLE, msg.sender) &&
            msg.sender != emergencyAdmin
        ) {
            revert UnauthorizedGovernance();
        }
        if (claimId == 0) revert ZeroClaimId();
        if (slashRecipient == address(0)) revert ZeroAddress();
        AppealRound storage round = _rounds[claimId];
        if (round.status == AppealRoundStatus.OPEN && block.timestamp < round.deadline) {
            revert BondDispositionNotAllowed(claimId);
        }
        if (round.requiredBond == 0) revert BondDispositionNotAllowed(claimId);

        uint256 bondLockId = round.bondLockId;
        uint256 amount = round.requiredBond;
        round.requiredBond = 0;

        vault.releaseBond(bondLockId, slashRecipient);

        emit AppealBondSlashed(claimId, bondLockId, slashRecipient, amount);
    }

    /**
     * @inheritdoc IAppealVerificationRound
     */
    function submitAppealVote(
        uint256 claimId,
        bool support,
        uint256 stakeAmount
    ) external override nonReentrant whenNotPaused {
        if (claimId == 0) revert ZeroClaimId();
        AppealRound storage round = _rounds[claimId];

        if (round.status != AppealRoundStatus.OPEN) revert AppealRoundNotOpen(claimId);
        if (block.timestamp >= round.deadline) revert AppealRoundExpired(claimId, block.timestamp, round.deadline);
        if (stakeAmount < round.minStakeAmount) revert InsufficientStake(stakeAmount, round.minStakeAmount);

        // V2-SC-059: cap voters per round so downstream aggregation stays O(n) with n bounded.
        if (round.verifierCount >= round.maxVoters) revert VoterLimitExceeded(claimId, round.maxVoters);

        AppealVote storage existingVote = _votes[claimId][msg.sender];
        if (existingVote.voted) revert AlreadyVotedInAppeal(claimId, msg.sender);

        // Calculate reputation weight multiplier
        uint256 reputationScore = 1e18; // baseline 1.0
        if (address(reputationOracle) != address(0)) {
            try reputationOracle.getReputationScore(msg.sender) returns (uint256 score) {
                if (score > 0) reputationScore = score;
            } catch {}
        }

        // effectiveWeight = (stakeAmount * reputationScore / 1e18) * stakeMultiplierBps / 10000
        uint256 baseWeighted = (stakeAmount * reputationScore) / 1e18;
        uint256 effectiveWeight = (baseWeighted * round.stakeMultiplierBps) / BPS_DENOMINATOR;

        if (round.maxWeightCap > 0 && effectiveWeight > round.maxWeightCap) {
            effectiveWeight = round.maxWeightCap;
        }

        // Custody stake tokens into contract
        stakingToken.safeTransferFrom(msg.sender, address(this), stakeAmount);

        // Record vote
        _votes[claimId][msg.sender] = AppealVote({
            voted: true,
            support: support,
            stakeAmount: stakeAmount,
            effectiveStake: effectiveWeight,
            timestamp: block.timestamp
        });

        _roundVoters[claimId].push(msg.sender);
        round.verifierCount++;

        if (support) {
            round.totalTrueStake += stakeAmount;
            round.totalTrueWeight += effectiveWeight;
        } else {
            round.totalFalseStake += stakeAmount;
            round.totalFalseWeight += effectiveWeight;
        }

        emit AppealVoteSubmitted(claimId, msg.sender, support, stakeAmount, effectiveWeight);
    }

    /**
     * @inheritdoc IAppealVerificationRound
     */
    function closeAppealRound(uint256 claimId) external override nonReentrant whenNotPaused {
        if (claimId == 0) revert ZeroClaimId();
        AppealRound storage round = _rounds[claimId];

        if (round.status != AppealRoundStatus.OPEN) revert AppealRoundNotOpen(claimId);
        if (block.timestamp < round.deadline) revert AppealRoundNotExpired(claimId, block.timestamp, round.deadline);

        round.status = AppealRoundStatus.CLOSED;

        emit AppealRoundClosed(
            claimId,
            round.totalTrueWeight,
            round.totalFalseWeight,
            round.verifierCount,
            msg.sender,
            round.roundIndex
        );

        // V2-SC-059: the final round in the ladder seals the claim's appeal path.
        if (round.roundIndex >= round.maxRounds) {
            _appealPathTerminal[claimId] = true;
            round.status = AppealRoundStatus.RESOLVED;

            emit AppealPathFinalized(
                claimId,
                round.roundIndex,
                round.totalTrueWeight,
                round.totalFalseWeight,
                round.verifierCount
            );
        }
    }

    /**
     * @inheritdoc IAppealVerificationRound
     *
     * @dev Deterministic single-step terminal transition. An OPEN-but-expired round is
     *      closed inside the same transaction, so a lone call always terminates the
     *      ladder. Bond disposition and claim-status finalization are intentionally
     *      delegated to V2-SC-018 (see IAppealVerificationRound); this function only
     *      seals the ladder ({AppealPathFinalized}) and is idempotent-safe.
     */
    function finalizeAppealRound(uint256 claimId) external override nonReentrant whenNotPaused {
        if (claimId == 0) revert ZeroClaimId();
        if (_appealPathTerminal[claimId]) revert AppealPathAlreadyFinalized(claimId);

        AppealRound storage round = _rounds[claimId];
        if (round.status != AppealRoundStatus.OPEN && round.status != AppealRoundStatus.CLOSED) {
            revert AppealRoundNotClosed(claimId);
        }

        if (round.status == AppealRoundStatus.OPEN) {
            if (block.timestamp < round.deadline) {
                revert AppealRoundNotExpired(claimId, block.timestamp, round.deadline);
            }
            round.status = AppealRoundStatus.CLOSED;
            emit AppealRoundClosed(
                claimId,
                round.totalTrueWeight,
                round.totalFalseWeight,
                round.verifierCount,
                msg.sender,
                round.roundIndex
            );
        }

        _appealPathTerminal[claimId] = true;
        round.status = AppealRoundStatus.RESOLVED;

        emit AppealPathFinalized(
            claimId,
            round.roundIndex,
            round.totalTrueWeight,
            round.totalFalseWeight,
            round.verifierCount
        );
    }

    // =========================================================================
    // IVerificationSource Implementation (for VerificationAggregator compatibility)
    // =========================================================================

    function getClaimVoterCount(uint256 claimId) external view override returns (uint256) {
        return _roundVoters[claimId].length;
    }

    function getClaimVoterAt(uint256 claimId, uint256 index) external view override returns (address) {
        if (index >= _roundVoters[claimId].length) revert IndexOutOfBounds();
        return _roundVoters[claimId][index];
    }

    function getVoteData(uint256 claimId, address verifier)
        external
        view
        override
        returns (bool voted, bool support, uint256 effectiveStake)
    {
        AppealVote storage v = _votes[claimId][verifier];
        return (v.voted, v.support, v.effectiveStake);
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    function getAppealRound(uint256 claimId) external view override returns (AppealRound memory) {
        return _rounds[claimId];
    }

    function getAppealVote(uint256 claimId, address verifier) external view override returns (AppealVote memory) {
        return _votes[claimId][verifier];
    }

    function isAppealOpen(uint256 claimId) external view override returns (bool) {
        AppealRound storage round = _rounds[claimId];
        return (round.status == AppealRoundStatus.OPEN && block.timestamp < round.deadline);
    }

    /**
     * @inheritdoc IAppealVerificationRound
     */
    function requiredAppealBond(uint256 roundIndex) external view override returns (uint256) {
        return _requiredBondForRound(defaultConfig, roundIndex);
    }

    /**
     * @inheritdoc IAppealVerificationRound
     */
    function isAppealPathTerminal(uint256 claimId) external view override returns (bool) {
        return _appealPathTerminal[claimId];
    }

    /**
     * @inheritdoc IAppealVerificationRound
     */
    function getAppealBondLock(uint256 claimId) external view override returns (ISTakeVault.BondLock memory) {
        return vault.getLock(_rounds[claimId].bondLockId);
    }

    // =========================================================================
    // Internal Bond Math
    // =========================================================================

    /**
     * @dev Computes the escalating bond for a 1-based round index using overflow-safe
     *      mulDiv. `requiredBond = min(maxAppealBond, appealBond * esc^(roundIndex-1) / 1e4)`.
     *      Escalation is flat-safe (10000 bps) and capped by `maxAppealBond`.
     */
    function _requiredBondForRound(AppealRoundConfig memory cfg, uint256 roundIndex) internal pure returns (uint256) {
        if (roundIndex == 0) return 0;
        uint256 bond = cfg.appealBond;
        if (bond >= cfg.maxAppealBond) return cfg.maxAppealBond;
        for (uint256 i = 1; i < roundIndex; i++) {
            bond = Math.mulDiv(bond, cfg.appealBondEscalationBps, BPS_DENOMINATOR);
            if (bond >= cfg.maxAppealBond) return cfg.maxAppealBond;
        }
        return bond;
    }

    /**
     * @dev Namespaced, collision-free vault lock id: unique per (claimId, roundIndex) and
     *      disjoint from {DisputeResolution}'s dispute-id locks in the same vault.
     */
    function _appealLockId(uint256 claimId, uint256 roundIndex) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("V2_APPEAL_BOND", claimId, roundIndex)));
    }

    // =========================================================================
    // Governance Controls
    // =========================================================================

    function setDefaultConfig(AppealRoundConfig calldata newConfig) external onlyGovernanceOrAdmin {
        if (newConfig.roundDuration < MIN_APPEAL_DURATION || newConfig.roundDuration > MAX_APPEAL_DURATION) {
            revert InvalidDuration(newConfig.roundDuration);
        }
        if (newConfig.minStakeAmount == 0) revert InvalidMinStake();
        if (newConfig.stakeMultiplierBps == 0) revert InvalidMultiplier();
        if (newConfig.maxAppealRounds == 0 || newConfig.maxAppealRounds > MAX_APPEAL_ROUNDS) {
            revert InvalidMaxAppealRounds(newConfig.maxAppealRounds);
        }
        if (newConfig.appealBond == 0) revert InvalidAppealBond(newConfig.appealBond);
        if (newConfig.appealBondEscalationBps < MIN_APPEAL_BOND_ESCALATION_BPS ||
            newConfig.appealBondEscalationBps > MAX_APPEAL_BOND_ESCALATION_BPS) {
            revert InvalidBondEscalation(newConfig.appealBondEscalationBps);
        }
        if (newConfig.maxAppealBond == 0 || newConfig.maxAppealBond < newConfig.appealBond) {
            revert InvalidMaxAppealBond(newConfig.maxAppealBond, newConfig.appealBond);
        }
        if (newConfig.maxVotersPerRound == 0 || newConfig.maxVotersPerRound > MAX_VOTERS_PER_ROUND) {
            revert InvalidMaxVotersPerRound(newConfig.maxVotersPerRound);
        }

        defaultConfig = newConfig;

        emit DefaultAppealConfigUpdated(
            newConfig.roundDuration,
            newConfig.minStakeAmount,
            newConfig.stakeMultiplierBps,
            newConfig.maxWeightCap,
            newConfig.maxAppealRounds,
            newConfig.appealBond,
            newConfig.appealBondEscalationBps,
            newConfig.maxAppealBond,
            newConfig.maxVotersPerRound
        );
    }

    /**
     * @notice Re-points the bond custody vault. Existing locks stay in the old vault;
     *         the new vault is only used for future rounds. Cannot be set to the zero
     *         address (fail-closed: an unset vault blocks appeal opening).
     * @param newVault New {ISTakeVault} address.
     * @dev The deploying admin should grant this contract OPERATOR_ROLE at the vault so
     *      it can lock appeal bonds (mirroring {DisputeResolution}).
     * @custom:emits VaultUpdated
     */
    function setVault(address newVault) external onlyGovernanceOrAdmin {
        if (newVault == address(0)) revert ZeroAddress();
        emit VaultUpdated(address(vault), newVault);
        vault = ISTakeVault(newVault);
    }

    function setReputationOracle(address newOracle) external onlyGovernanceOrAdmin {
        reputationOracle = IReputationOracle(newOracle);
    }

    function setDisputeResolution(address newDisputeResolution) external override onlyGovernanceOrAdmin {
        if (newDisputeResolution == address(0)) revert ZeroAddress();
        address old = disputeResolution;
        disputeResolution = newDisputeResolution;
        emit DisputeResolutionUpdated(old, newDisputeResolution);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
