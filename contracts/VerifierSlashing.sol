// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./utils/ResolverRoleTimelock.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./governance/GovernanceOwnable.sol";
import "./governance/GovernanceHooks.sol";
import "./interfaces/ITruthBountyEvents.sol";
import "./treasury/ITreasuryAccounting.sol";
import "./IReputationOracle.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IReputationPenaltyReceiver.sol";

/// @dev Minimal appeal-manager surface consumed by VerifierSlashing.
///      The full interface lives in IAppealVerificationRound.sol; we declare
///      only the one function we need here to avoid a circular import and to
///      keep the slashing module's dependency surface minimal.
interface IAppealManager {
    /// @notice Returns true when the appeal round for `claimId` is open.
    function isAppealOpen(uint256 claimId) external view returns (bool);
}

/**
 * @title VerifierSlashing
 * @notice Slashing module for TruthBounty protocol verifiers.
 *
 * @dev PREWAVE-SC-082 — Bound Slashing Amounts and Authority.
 *
 *      Security properties (post-Wave-9 hardening):
 *
 *      1. **Canonical exposure cap** — every slash path reads the current lock
 *         from the staking contract and reverts with `SlashAmountExceedsExposure`
 *         before calling `forceSlash` when the computed amount would exceed the
 *         current stake.  A percentage × stake formula already guarantees this
 *         arithmetically, but the explicit guard makes the boundary a hard revert
 *         rather than an implicit truncation, so it is auditable at the call site.
 *
 *      2. **One offence, one slash** — `slashVerifier` keys duplicate protection
 *         on `(claimId, roundId, verifier, reasonHash)`.  A second call with the
 *         same tuple reverts with `DuplicateSlash`.  `executePenalty` keys on
 *         `(verifier, offenceId, claimId, roundId)`.  `slash` and `criticalSlash`
 *         carry `claimId = 0` and `roundId = 0` by convention (un-routed) and are
 *         not deduplicated at the contract level; callers are responsible for
 *         single-dispatch from their own state machine.
 *
 *      3. **Event-complete records** — every slash emits `reason` (or `reasonHash`),
 *         `claimId`, `roundId`, `executor`, `slashAmount`, and `settlementEpoch`.
 *         The `SlashRecord` struct is extended with `roundId`.
 *
 *      4. **Appeal / finality gate** — when the optional `appealManager` is wired,
 *         `slashVerifier` and `executePenalty` refuse to slash while the appeal round
 *         for the target claim is open, reverting with `AppealPending`.  This
 *         prevents slashing a verifier whose outcome may still be reversed by the
 *         appeal layer.  The gate is enforced only when `appealManager != address(0)`
 *         and only for calls that carry a nonzero `claimId`.
 *
 *      5. **Authorized caller** — every write path requires `RESOLVER_ROLE` (standard
 *         slashing) or `CRITICAL_SLASHER_ROLE` (critical/100 % slash), both
 *         governed through `ResolverRoleTimelock`.  Governance and admin paths are
 *         protected by `onlyGovernanceOrAdmin`.
 */

// Interface for the staking contract
interface IStaking {
    function stakes(address user) external view returns (uint256 amount, uint256 unlockTime);
    function forceSlash(address user, uint256 amount) external;
    function stakingToken() external view returns (address);
    function treasury() external view returns (address);
}

contract VerifierSlashing is ResolverRoleTimelock, ReentrancyGuard, Pausable, GovernanceOwnable, ITruthBountyEvents {
    
    // Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant CRITICAL_SLASHER_ROLE = keccak256("CRITICAL_SLASHER_ROLE");
    
    // Legacy mapping for backward compatibility
    bytes32 public constant SETTLEMENT_ROLE = RESOLVER_ROLE;
    
    // Maximum slashing percentage (100%)
    uint256 public constant MAX_SLASH_PERCENTAGE = 100;

    // Maximum number of verifiers that can be slashed in a single batch.
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint16 public constant EVENT_SCHEMA_VERSION = 1;
    
    // Default maximum slashing percentage per incident
    uint256 public maxSlashPercentage = 50; // 50% max per slash
    
    // Minimum time between slashes for the same verifier (anti-spam)
    uint256 public slashCooldown = 1 hours;
    
    // Governance parameter IDs
    bytes32 public constant GOVERNANCE_PARAM_MAX_SLASH = keccak256("MAX_SLASH_PERCENTAGE");
    bytes32 public constant GOVERNANCE_PARAM_COOLDOWN = keccak256("SLASH_COOLDOWN");
    
    IStaking public stakingContract;

    // Treasury accounting contract for protocol-wide financial tracking
    ITreasuryAccounting public treasuryAccounting;
    IReputationOracle public reputationOracle;
    
    // Slashing tracking
    struct SlashRecord {
        uint256 timestamp;
        uint256 amount;
        uint256 percentage;
        string reason;
        address slashedBy;
        uint256 claimId;
        uint256 roundId;        // V2-SC-082: verification round reference (0 = un-routed)
        uint256 settlementEpoch;
        bytes32 offenceId;
        bytes32 reasonHash;
    }
    
    // Verifier address => array of slash records
    mapping(address => SlashRecord[]) public slashHistory;
    
    // Verifier address => last slash timestamp
    mapping(address => uint256) public lastSlashTime;

    // Verifier address => last slash block number (prevents same-block bypass)
    mapping(address => uint256) public lastSlashBlock;
    
    // Total amount slashed per verifier
    mapping(address => uint256) public totalSlashed;

    // === Economic Enforcement / Offences State ===

    struct OffenceConfig {
        uint256 slashPercentage;      // 0 to 100
        uint256 reputationPenalty;    // percentage of score to deduct (0 to 100)
        uint256 suspensionDuration;   // duration in seconds verifier is suspended
        bool permanentBan;            // if true, verifier is banned permanently
        bool active;                  // if the offence is currently active
    }

    struct PenaltyRecord {
        address verifier;
        bytes32 offenceId;
        uint256 slashAmount;
        uint256 reputationPenalty;
        uint256 suspensionDuration;
        bool permanentBan;
        uint256 timestamp;
        string reason;
        address executedBy;
    }

    // Standard Offence constants
    bytes32 public constant OFFENCE_VERIFICATION_FRAUD = keccak256("VERIFICATION_FRAUD");
    bytes32 public constant OFFENCE_VERIFICATION_INACCURACY = keccak256("VERIFICATION_INACCURACY");
    bytes32 public constant OFFENCE_VERIFICATION_COLLUSION = keccak256("VERIFICATION_COLLUSION");
    bytes32 public constant OFFENCE_VERIFICATION_DOUBLE = keccak256("VERIFICATION_DOUBLE");
    bytes32 public constant OFFENCE_VERIFICATION_SPAM = keccak256("VERIFICATION_SPAM");
    
    bytes32 public constant OFFENCE_CLAIM_FRAUD = keccak256("CLAIM_FRAUD");
    bytes32 public constant OFFENCE_CLAIM_MALICIOUS = keccak256("CLAIM_MALICIOUS");
    bytes32 public constant OFFENCE_CLAIM_ABUSE = keccak256("CLAIM_ABUSE");
    
    bytes32 public constant OFFENCE_GOVERNANCE_SPAM = keccak256("GOVERNANCE_SPAM");
    bytes32 public constant OFFENCE_PROPOSAL_ABUSE = keccak256("PROPOSAL_ABUSE");
    bytes32 public constant OFFENCE_GOVERNANCE_ATTACK = keccak256("GOVERNANCE_ATTACK");
    
    bytes32 public constant OFFENCE_PROTOCOL_MANIPULATION = keccak256("PROTOCOL_MANIPULATION");
    bytes32 public constant OFFENCE_REPLAY_ATTEMPT = keccak256("REPLAY_ATTEMPT");
    bytes32 public constant OFFENCE_EMERGENCY_ABUSE = keccak256("EMERGENCY_ABUSE");

    // Mapping of Offence ID to configurations
    mapping(bytes32 => OffenceConfig) public offenceConfigs;

    // Mapping of verifiers to suspension end timestamp
    mapping(address => uint256) public suspensionEndTime;

    // Mapping of verifiers to permanent ban status
    mapping(address => bool) public permanentBanned;

    // Mapping of unique penalty ID to detailed records
    mapping(bytes32 => PenaltyRecord) public penaltyRecords;

    // Mapping of verifier address to list of penalty IDs
    mapping(address => bytes32[]) public verifierPenaltyIds;

    // Accumulated reputation penalty points/percentages tracked locally per verifier
    mapping(address => uint256) public reputationPenaltyScores;

    // === Treasury Destination Routing ===
    address public treasuryReserve;
    address public securityFund;
    address public protocolInsurance;
    address public burnAddress;

    uint256 public pctTreasuryReserve;
    uint256 public pctSecurityFund;
    uint256 public pctProtocolInsurance;
    uint256 public pctBurn;
    /// @notice Optional reputation penalty adapter.
    IReputationPenaltyReceiver public reputationPenaltyReceiver;

    /// @notice Duration used to derive deterministic settlement epochs.
    uint256 public settlementEpochDuration = 7 days;

    /// @notice claimId + verifier + reasonHash => already processed.
    mapping(bytes32 => bool) public processedOffences;

    // =========================================================================
    // V2-SC-082: Appeal gate and penalty dedup state
    // =========================================================================

    /// @notice Optional appeal-manager adapter.  When set, `slashVerifier` and
    ///         `executePenalty` refuse to proceed while the appeal round for the
    ///         target claim is open.  Set to `address(0)` to disable the gate.
    IAppealManager public appealManager;

    /// @notice Dedup key for `executePenalty`: (verifier, offenceId, claimId, roundId).
    /// @dev Prevents the same penalty (same offence on the same verifier for the same
    ///      claim and round) from being executed twice.
    mapping(bytes32 => bool) public processedPenaltyOffences;
    
    // Events
    event Slashed(
        address indexed verifier,
        uint256 amount,
        uint256 percentage,
        uint256 remainingStake,
        string reason,
        address indexed slashedBy
    );
    
    event SlashingConfigUpdated(
        uint256 newMaxPercentage,
        uint256 newCooldown
    );
    
    event StakingContractUpdated(address newStakingContract);
    event TreasuryAccountingUpdated(address newTreasuryAccounting);
    
    event ReputationPenaltyReceiverUpdated(
        address indexed oldReceiver,
        address indexed newReceiver
    );
    event SettlementEpochDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event VerifierSlashed(
        address indexed verifier,
        uint256 indexed claimId,
        uint256 amount,
        uint256 percentage,
        bytes32 indexed reasonHash,
        uint256 settlementEpoch,
        address executor
    );
    event CriticalSlashed(
        address indexed verifier,
        uint256 amount,
        uint256 percentage,
        string reason,
        address indexed slashedBy
    );

    // Enforcement Events
    event StakeSlashed(
        address indexed participant,
        uint256 amount,
        bytes32 indexed offence
    );

    // Reputation penalized event
    event ReputationPenalized(
        address indexed participant,
        uint256 previousScore,
        uint256 newScore
    );

    event PenaltyExecuted(
        bytes32 indexed penaltyId
    );

    event OffenceConfigUpdated(
        bytes32 indexed offenceId,
        uint256 slashPercentage,
        uint256 reputationPenalty,
        uint256 suspensionDuration,
        bool permanentBan,
        bool active
    );

    event TreasuryRoutingUpdated(
        address treasuryReserve,
        address securityFund,
        address protocolInsurance,
        address burnAddress,
        uint256 pctTreasuryReserve,
        uint256 pctSecurityFund,
        uint256 pctProtocolInsurance,
        uint256 pctBurn
    );

    event ReputationOracleUpdated(address newOracle);
    /// @notice Emitted when the appeal-manager adapter is updated.
    event AppealManagerUpdated(address indexed oldManager, address indexed newManager);
    
    // Custom errors for gas efficiency
    error UnauthorizedSlashing();
    error InvalidPercentage();
    error NoStakeToSlash();
    error SlashingTooFrequent();
    error InvalidStakingContract();
    error SlashAmountTooHigh();
    error SlashSameBlock();
    error CriticalSlashUnauthorized();
    error EmptyBatch();
    error BatchSizeExceeded(uint256 provided, uint256 maxAllowed);
    error BatchLengthMismatch();
    error InvalidTreasuryAddress();
    error InvalidOffence();
    error VerifierSuspended();
    error VerifierBanned();
    error DuplicateSlash();
    error InvalidEpochDuration();
    /// @notice The computed slash amount exceeds the verifier's canonical locked principal.
    error SlashAmountExceedsExposure(uint256 requested, uint256 currentStake);
    /// @notice Slashing is blocked while the appeal round for the target claim is open.
    error AppealPending(uint256 claimId);
    
    /**
     * @dev Constructor sets up roles and initial configuration
     * @param _stakingContract Address of the staking contract
     * @param _admin Address that will have admin privileges
     */
    constructor(address _stakingContract, address _admin, address _governanceController) {
        if (_stakingContract == address(0) || _admin == address(0)) {
            revert InvalidStakingContract();
        }
        
        stakingContract = IStaking(_stakingContract);
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        
        // Admin can grant/revoke resolver role
        _setRoleAdmin(RESOLVER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
        
        // Initialize governance
        _initializeGovernance(_governanceController, _admin, _admin);

        // Configure default offences
        _initializeDefaultOffences();

        // Default treasury allocation (100% to dead address / burn by default if not set)
        pctBurn = 100;
        burnAddress = address(0x000000000000000000000000000000000000dEaD);
    }
    
    function _resolverRole() internal pure override returns (bytes32) {
        return RESOLVER_ROLE;
    }

    function grantRole(bytes32 role, address account) public override(AccessControl, ResolverRoleTimelock) {
        ResolverRoleTimelock.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override(AccessControl, ResolverRoleTimelock) {
        ResolverRoleTimelock.revokeRole(role, account);
    }

    function _initializeDefaultOffences() internal {
        // Verification Misconduct (base 20% slash, 10% rep, 1 day suspension)
        offenceConfigs[OFFENCE_VERIFICATION_FRAUD] = OffenceConfig(50, 30, 7 days, false, true);
        offenceConfigs[OFFENCE_VERIFICATION_INACCURACY] = OffenceConfig(10, 5, 1 hours, false, true);
        offenceConfigs[OFFENCE_VERIFICATION_COLLUSION] = OffenceConfig(100, 100, 30 days, true, true);
        offenceConfigs[OFFENCE_VERIFICATION_DOUBLE] = OffenceConfig(20, 10, 1 days, false, true);
        offenceConfigs[OFFENCE_VERIFICATION_SPAM] = OffenceConfig(5, 2, 6 hours, false, true);

        // Claim Misconduct
        offenceConfigs[OFFENCE_CLAIM_FRAUD] = OffenceConfig(40, 20, 3 days, false, true);
        offenceConfigs[OFFENCE_CLAIM_MALICIOUS] = OffenceConfig(60, 40, 7 days, false, true);
        offenceConfigs[OFFENCE_CLAIM_ABUSE] = OffenceConfig(20, 10, 1 days, false, true);

        // Governance Misconduct
        offenceConfigs[OFFENCE_GOVERNANCE_SPAM] = OffenceConfig(10, 10, 2 days, false, true);
        offenceConfigs[OFFENCE_PROPOSAL_ABUSE] = OffenceConfig(30, 20, 5 days, false, true);
        offenceConfigs[OFFENCE_GOVERNANCE_ATTACK] = OffenceConfig(100, 100, 365 days, true, true);

        // Operational Violations
        offenceConfigs[OFFENCE_PROTOCOL_MANIPULATION] = OffenceConfig(80, 50, 14 days, false, true);
        offenceConfigs[OFFENCE_REPLAY_ATTEMPT] = OffenceConfig(15, 10, 1 days, false, true);
        offenceConfigs[OFFENCE_EMERGENCY_ABUSE] = OffenceConfig(50, 30, 7 days, false, true);
    }

    /**
     * @notice Execute penalty for a registered offence (un-routed path, claimId = 0).
     * @dev Un-routed penalties are NOT deduplicated by claim/round; the caller's
     *      state machine must prevent double-dispatch.  The appeal gate is not applied
     *      when claimId is 0.  For claim-scoped enforcement use {executePenaltyForClaim}.
     * @param verifier  Verifier address to penalize
     * @param offenceId Offence identifier hash
     * @param reason    Description of the event/offence
     */
    function executePenalty(
        address verifier,
        bytes32 offenceId,
        string calldata reason
    ) external nonReentrant whenNotPaused {
        _executePenaltyInternal(verifier, offenceId, reason, 0, 0);
    }

    /**
     * @notice Execute a claim-scoped penalty for a registered offence.
     * @dev V2-SC-082 hardening:
     *      - Deduplication key is `(verifier, offenceId, claimId, roundId)`.
     *      - Appeal gate: reverts with `AppealPending` when `claimId != 0` and the
     *        optional `appealManager` reports the claim's appeal round is open.
     *      - Conservation cap: reverts with `SlashAmountExceedsExposure` when the
     *        computed slash amount would exceed current stake.
     * @param verifier  Verifier address to penalize
     * @param offenceId Offence identifier hash
     * @param claimId   Claim the offence is linked to
     * @param roundId   Verification round within the claim (0 = pre-round or unknown)
     * @param reason    Description of the event/offence
     */
    function executePenaltyForClaim(
        address verifier,
        bytes32 offenceId,
        uint256 claimId,
        uint256 roundId,
        string calldata reason
    ) external nonReentrant whenNotPaused {
        _executePenaltyInternal(verifier, offenceId, reason, claimId, roundId);
    }

    /// @dev Shared implementation for both executePenalty entry points.
    function _executePenaltyInternal(
        address verifier,
        bytes32 offenceId,
        string calldata reason,
        uint256 claimId,
        uint256 roundId
    ) internal {
        if (!hasRole(RESOLVER_ROLE, msg.sender)) {
            revert UnauthorizedSlashing();
        }

        OffenceConfig memory config = offenceConfigs[offenceId];
        if (!config.active) {
            revert InvalidOffence();
        }

        if (verifier == address(0)) {
            revert NoStakeToSlash();
        }

        if (permanentBanned[verifier]) {
            revert VerifierBanned();
        }

        // Prevent multiple slashes in same block
        if (lastSlashBlock[verifier] == block.number) {
            revert SlashSameBlock();
        }

        // V2-SC-082: dedup for claim-scoped penalties
        if (claimId != 0) {
            bytes32 penaltyDedupKey = keccak256(abi.encode(verifier, offenceId, claimId, roundId));
            if (processedPenaltyOffences[penaltyDedupKey]) {
                revert DuplicateSlash();
            }
            processedPenaltyOffences[penaltyDedupKey] = true;

            // V2-SC-082: appeal gate — block slashing while appeal is open
            if (address(appealManager) != address(0)) {
                if (appealManager.isAppealOpen(claimId)) {
                    revert AppealPending(claimId);
                }
            }
        }

        // Fetch current stake
        (uint256 currentStake,) = stakingContract.stakes(verifier);

        uint256 slashAmount = 0;
        if (currentStake > 0 && config.slashPercentage > 0) {
            slashAmount = (currentStake * config.slashPercentage) / 100;
            // V2-SC-082: conservation cap — must not exceed locked principal
            if (slashAmount > currentStake) {
                revert SlashAmountExceedsExposure(slashAmount, currentStake);
            }
        }

        lastSlashTime[verifier] = block.timestamp;
        lastSlashBlock[verifier] = block.number;

        if (slashAmount > 0) {
            totalSlashed[verifier] += slashAmount;

            // Execute slash (this transfers tokens to this contract)
            stakingContract.forceSlash(verifier, slashAmount);

            // Route the slashed tokens to treasury split destinations
            _routeSlashedTokens(slashAmount);
        }

        // Process suspension
        if (config.suspensionDuration > 0) {
            uint256 newSuspensionEnd = block.timestamp + config.suspensionDuration;
            if (newSuspensionEnd > suspensionEndTime[verifier]) {
                suspensionEndTime[verifier] = newSuspensionEnd;
            }
        }

        // Process permanent ban
        if (config.permanentBan) {
            permanentBanned[verifier] = true;
        }

        // Reputation oracle penalty calculation
        uint256 previousScore = 0;
        uint256 newScore = 0;
        if (address(reputationOracle) != address(0)) {
            try reputationOracle.getReputationScore(verifier) returns (uint256 score) {
                previousScore = score;
                uint256 reduction = (score * config.reputationPenalty) / 100;
                newScore = reduction > score ? 0 : score - reduction;
            } catch {}
        }
        reputationPenaltyScores[verifier] += config.reputationPenalty;

        // Record execution record (penaltyId includes claimId and roundId for uniqueness)
        bytes32 penaltyId = keccak256(abi.encodePacked(verifier, offenceId, claimId, roundId, block.timestamp, slashAmount));
        penaltyRecords[penaltyId] = PenaltyRecord({
            verifier: verifier,
            offenceId: offenceId,
            slashAmount: slashAmount,
            reputationPenalty: config.reputationPenalty,
            suspensionDuration: config.suspensionDuration,
            permanentBan: config.permanentBan,
            timestamp: block.timestamp,
            reason: reason,
            executedBy: msg.sender
        });
        verifierPenaltyIds[verifier].push(penaltyId);

        // V2-SC-082: event-complete slash record including claimId and roundId
        slashHistory[verifier].push(SlashRecord({
            timestamp: block.timestamp,
            amount: slashAmount,
            percentage: config.slashPercentage,
            reason: reason,
            slashedBy: msg.sender,
            claimId: claimId,
            roundId: roundId,
            settlementEpoch: block.timestamp / settlementEpochDuration,
            offenceId: offenceId,
            reasonHash: keccak256(bytes(reason))
        }));

        if (slashAmount > 0) {
            emit StakeSlashed(verifier, slashAmount, offenceId);

            uint256 remainingStake = currentStake > slashAmount ? currentStake - slashAmount : 0;
            emit Slashed(verifier, slashAmount, config.slashPercentage, remainingStake, reason, msg.sender);
        }
        emit ReputationPenalized(verifier, previousScore, newScore);
        emit PenaltyExecuted(penaltyId);
    }

    /**
     * @dev Slash a verifier's stake for incorrect verification
     * @param verifier Address of the verifier to slash
     * @param percentage Percentage of stake to slash (1-100)
     * @param reason Human-readable reason for slashing
     */
    function slash(
        address verifier,
        uint256 percentage,
        string calldata reason
    ) external nonReentrant whenNotPaused {
        if (!hasRole(RESOLVER_ROLE, msg.sender)) {
            revert UnauthorizedSlashing();
        }
        
        if (percentage == 0 || percentage > maxSlashPercentage) {
            revert InvalidPercentage();
        }
        
        if (verifier == address(0)) {
            revert NoStakeToSlash();
        }

        if (permanentBanned[verifier]) {
            revert VerifierBanned();
        }
        
        if (block.timestamp < lastSlashTime[verifier] + slashCooldown) {
            revert SlashingTooFrequent();
        }

        if (lastSlashBlock[verifier] == block.number) {
            revert SlashSameBlock();
        }
        
        (uint256 currentStake,) = stakingContract.stakes(verifier);
        
        if (currentStake == 0) {
            revert NoStakeToSlash();
        }
        
        uint256 slashAmount = (currentStake * percentage) / 100;
        
        if (slashAmount == 0) {
            revert SlashAmountTooHigh();
        }

        // V2-SC-082: conservation cap
        if (slashAmount > currentStake) {
            revert SlashAmountExceedsExposure(slashAmount, currentStake);
        }
        
        lastSlashTime[verifier] = block.timestamp;
        lastSlashBlock[verifier] = block.number;
        totalSlashed[verifier] += slashAmount;
        
        slashHistory[verifier].push(SlashRecord({
            timestamp: block.timestamp,
            amount: slashAmount,
            percentage: percentage,
            reason: reason,
            slashedBy: msg.sender,
            claimId: 0,
            roundId: 0,
            settlementEpoch: block.timestamp / settlementEpochDuration,
            offenceId: bytes32(0),
            reasonHash: keccak256(bytes(reason))
        }));
        
        stakingContract.forceSlash(verifier, slashAmount);
        _routeSlashedTokens(slashAmount);
        
        uint256 remainingStake = currentStake - slashAmount;
        
        emit Slashed(
            verifier,
            slashAmount,
            percentage,
            remainingStake,
            reason,
            msg.sender
        );
        emit SlashExecutedV1(
            0,
            verifier,
            keccak256(bytes(reason)),
            slashAmount,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );

        emit StakeSlashed(verifier, slashAmount, bytes32(0));
    }
    
    // Internal fallback for cooldown check bypass in require/custom errors
    function o() internal view returns (bool) {
        revert SlashingTooFrequent();
    }

    /**
     * @notice Slash a verifier for a unique claim offence.
     * @dev V2-SC-082:
     *      - Duplicate key is `(claimId, roundId, verifier, reasonHash)`.
     *      - Appeal gate: reverts with `AppealPending` while the appeal round is open.
     *      - Conservation cap: reverts with `SlashAmountExceedsExposure` when slash
     *        would exceed current stake.
     * @param verifier  Address of the verifier to slash
     * @param claimId   Claim the offence is linked to
     * @param roundId   Verification round within the claim (0 = pre-round or unknown)
     * @param percentage Percentage of stake to slash (1..maxSlashPercentage)
     * @param reason    Human-readable reason for slashing
     */
    function slashVerifier(
        address verifier,
        uint256 claimId,
        uint256 roundId,
        uint256 percentage,
        string calldata reason
    ) external nonReentrant whenNotPaused {
        if (!hasRole(RESOLVER_ROLE, msg.sender)) {
            revert UnauthorizedSlashing();
        }

        bytes32 reasonHash = keccak256(bytes(reason));
        // V2-SC-082: dedup key includes roundId
        bytes32 offenceId = keccak256(
            abi.encode(claimId, roundId, verifier, reasonHash)
        );

        if (processedOffences[offenceId]) {
            revert DuplicateSlash();
        }

        if (percentage == 0 || percentage > maxSlashPercentage) {
            revert InvalidPercentage();
        }

        if (verifier == address(0)) {
            revert NoStakeToSlash();
        }

        // V2-SC-082: appeal gate — block slashing while appeal is open
        if (address(appealManager) != address(0)) {
            if (appealManager.isAppealOpen(claimId)) {
                revert AppealPending(claimId);
            }
        }

        (uint256 currentStake,) = stakingContract.stakes(verifier);
        if (currentStake == 0) {
            revert NoStakeToSlash();
        }

        uint256 slashAmount = (currentStake * percentage) / 100;
        if (slashAmount == 0) {
            revert SlashAmountTooHigh();
        }

        // V2-SC-082: conservation cap
        if (slashAmount > currentStake) {
            revert SlashAmountExceedsExposure(slashAmount, currentStake);
        }

        uint256 epoch = block.timestamp / settlementEpochDuration;

        processedOffences[offenceId] = true;
        lastSlashTime[verifier] = block.timestamp;
        lastSlashBlock[verifier] = block.number;
        totalSlashed[verifier] += slashAmount;

        // V2-SC-082: event-complete record with roundId
        slashHistory[verifier].push(SlashRecord({
            timestamp: block.timestamp,
            amount: slashAmount,
            percentage: percentage,
            reason: reason,
            slashedBy: msg.sender,
            claimId: claimId,
            roundId: roundId,
            settlementEpoch: epoch,
            offenceId: offenceId,
            reasonHash: reasonHash
        }));

        stakingContract.forceSlash(verifier, slashAmount);

        address treasury = stakingContract.treasury();
        if (treasury != address(0)) {
            IERC20(stakingContract.stakingToken()).transfer(treasury, slashAmount);
        }

        address receiver = address(reputationPenaltyReceiver);
        if (receiver != address(0)) {
            reputationPenaltyReceiver.notifySlash(
                verifier,
                claimId,
                slashAmount,
                percentage,
                reasonHash
            );
        }

        emit VerifierSlashed(
            verifier,
            claimId,
            slashAmount,
            percentage,
            reasonHash,
            epoch,
            msg.sender
        );
    }

    /**
     * @dev Batch slash multiple verifiers (gas efficient for multiple violations)
     */
    function batchSlash(
        address[] calldata verifiers,
        uint256[] calldata percentages,
        string[] calldata reasons
    ) external nonReentrant whenNotPaused {
        if (!hasRole(RESOLVER_ROLE, msg.sender)) {
            revert UnauthorizedSlashing();
        }
        
        uint256 length = verifiers.length;
        if (length != percentages.length || length != reasons.length) {
            revert BatchLengthMismatch();
        }
        if (length == 0) {
            revert EmptyBatch();
        }
        if (length > MAX_BATCH_SIZE) {
            revert BatchSizeExceeded(length, MAX_BATCH_SIZE);
        }
        
        for (uint256 i = 0; i < length;) {
            _slashInternal(verifiers[i], percentages[i], reasons[i]);
            
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Critical slash — allows up to 100% slash for critical failures (#186)
     */
    function criticalSlash(
        address verifier,
        uint256 percentage,
        string calldata reason
    ) external nonReentrant whenNotPaused {
        if (!hasRole(CRITICAL_SLASHER_ROLE, msg.sender)) {
            revert CriticalSlashUnauthorized();
        }

        if (percentage == 0 || percentage > MAX_SLASH_PERCENTAGE) {
            revert InvalidPercentage();
        }

        if (verifier == address(0)) {
            revert NoStakeToSlash();
        }

        if (permanentBanned[verifier]) {
            revert VerifierBanned();
        }

        if (lastSlashBlock[verifier] == block.number) {
            revert SlashSameBlock();
        }

        (uint256 currentStake,) = stakingContract.stakes(verifier);
        if (currentStake == 0) {
            revert NoStakeToSlash();
        }

        uint256 slashAmount = (currentStake * percentage) / 100;
        if (slashAmount == 0) {
            revert SlashAmountTooHigh();
        }

        // V2-SC-082: conservation cap
        if (slashAmount > currentStake) {
            revert SlashAmountExceedsExposure(slashAmount, currentStake);
        }

        lastSlashTime[verifier] = block.timestamp;
        lastSlashBlock[verifier] = block.number;
        totalSlashed[verifier] += slashAmount;

        slashHistory[verifier].push(SlashRecord({
            timestamp: block.timestamp,
            amount: slashAmount,
            percentage: percentage,
            reason: reason,
            slashedBy: msg.sender,
            claimId: 0,
            roundId: 0,
            settlementEpoch: block.timestamp / settlementEpochDuration,
            offenceId: bytes32(0),
            reasonHash: keccak256(bytes(reason))
        }));

        stakingContract.forceSlash(verifier, slashAmount);
        _routeSlashedTokens(slashAmount);

        emit CriticalSlashed(verifier, slashAmount, percentage, reason, msg.sender);
        emit SlashExecutedV1(
            0,
            verifier,
            keccak256(bytes(reason)),
            slashAmount,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );

        emit StakeSlashed(
            verifier,
            slashAmount,
            keccak256("CRITICAL_OFFENCE")
        );
    }
    
    /**
     * @dev Internal slash function for batch operations
     */
    function _slashInternal(
        address verifier,
        uint256 percentage,
        string calldata reason
    ) internal {
        if (percentage == 0 || percentage > maxSlashPercentage) {
            revert InvalidPercentage();
        }
        
        if (verifier == address(0)) {
            revert NoStakeToSlash();
        }

        if (permanentBanned[verifier]) {
            revert VerifierBanned();
        }
        
        if (block.timestamp < lastSlashTime[verifier] + slashCooldown) {
            revert SlashingTooFrequent();
        }

        if (lastSlashBlock[verifier] == block.number) {
            revert SlashSameBlock();
        }
        
        (uint256 currentStake,) = stakingContract.stakes(verifier);
        
        if (currentStake == 0) {
            revert NoStakeToSlash();
        }
        
        uint256 slashAmount = (currentStake * percentage) / 100;
        
        if (slashAmount == 0) {
            revert SlashAmountTooHigh();
        }
        
        lastSlashTime[verifier] = block.timestamp;
        lastSlashBlock[verifier] = block.number;
        totalSlashed[verifier] += slashAmount;
        
        slashHistory[verifier].push(SlashRecord({
            timestamp: block.timestamp,
            amount: slashAmount,
            percentage: percentage,
            reason: reason,
            slashedBy: msg.sender,
            claimId: 0,
            roundId: 0,
            settlementEpoch: block.timestamp / settlementEpochDuration,
            offenceId: bytes32(0),
            reasonHash: keccak256(bytes(reason))
        }));
        
        stakingContract.forceSlash(verifier, slashAmount);
        _routeSlashedTokens(slashAmount);
        
        uint256 remainingStake = currentStake - slashAmount;
        
        emit Slashed(
            verifier,
            slashAmount,
            percentage,
            remainingStake,
            reason,
            msg.sender
        );
        emit SlashExecutedV1(
            0,
            verifier,
            keccak256(bytes(reason)),
            slashAmount,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );

        emit StakeSlashed(verifier, slashAmount, bytes32(0));
    }

    /**
     * @dev Routes slashed tokens according to configured percentages
     */
    function _routeSlashedTokens(uint256 amount) internal {
        if (amount == 0) return;

        address tokenAddress = stakingContract.stakingToken();
        if (tokenAddress == address(0)) return;

        IERC20 token = IERC20(tokenAddress);

        uint256 toTreasury = (amount * pctTreasuryReserve) / 100;
        uint256 toSecurity = (amount * pctSecurityFund) / 100;
        uint256 toInsurance = (amount * pctProtocolInsurance) / 100;
        uint256 toBurn = amount - toTreasury - toSecurity - toInsurance;

        if (toTreasury > 0 && treasuryReserve != address(0)) {
            token.transfer(treasuryReserve, toTreasury);
        }
        if (toSecurity > 0 && securityFund != address(0)) {
            token.transfer(securityFund, toSecurity);
        }
        if (toInsurance > 0 && protocolInsurance != address(0)) {
            token.transfer(protocolInsurance, toInsurance);
        }
        if (toBurn > 0 && burnAddress != address(0)) {
            token.transfer(burnAddress, toBurn);
        }
    }
    
    // === VIEW & READ INTERFACES ===
    
    function getSlashHistory(
        address verifier,
        uint256 offset,
        uint256 limit
    ) external view returns (SlashRecord[] memory) {
        SlashRecord[] storage history = slashHistory[verifier];
        uint256 total = history.length;

        if (offset >= total || limit == 0) {
            return new SlashRecord[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        SlashRecord[] memory page = new SlashRecord[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = history[i];
        }

        return page;
    }
    
    function getSlashCount(address verifier) external view returns (uint256) {
        return slashHistory[verifier].length;
    }
    
    function canSlash(address verifier) external view returns (bool) {
        if (permanentBanned[verifier]) return false;
        return block.timestamp >= lastSlashTime[verifier] + slashCooldown;
    }
    
    function getSlashCooldownRemaining(address verifier) external view returns (uint256) {
        uint256 nextSlashTime = lastSlashTime[verifier] + slashCooldown;
        if (block.timestamp >= nextSlashTime) {
            return 0;
        }
        return nextSlashTime - block.timestamp;
    }

    function isSuspended(address verifier) external view returns (bool) {
        return block.timestamp < suspensionEndTime[verifier];
    }

    function isBanned(address verifier) external view returns (bool) {
        return permanentBanned[verifier];
    }

    function getVerifierPenaltyRecords(address verifier) external view returns (bytes32[] memory) {
        return verifierPenaltyIds[verifier];
    }

    function getTreasuryRouting() external view returns (
        address _treasuryReserve,
        address _securityFund,
        address _protocolInsurance,
        address _burnAddress,
        uint256 _pctTreasuryReserve,
        uint256 _pctSecurityFund,
        uint256 _pctProtocolInsurance,
        uint256 _pctBurn
    ) {
        return (
            treasuryReserve,
            securityFund,
            protocolInsurance,
            burnAddress,
            pctTreasuryReserve,
            pctSecurityFund,
            pctProtocolInsurance,
            pctBurn
        );
    }
    
    // === GOVERNANCE & ADMIN FUNCTIONS ===
    
    /**
     * @dev Configure an offence definition
     */
    function setOffenceConfig(
        bytes32 offenceId,
        uint256 slashPercentage,
        uint256 reputationPenalty,
        uint256 suspensionDuration,
        bool permanentBan,
        bool active
    ) external onlyGovernanceOrAdmin {
        require(slashPercentage <= MAX_SLASH_PERCENTAGE, "Percentage too high");
        offenceConfigs[offenceId] = OffenceConfig({
            slashPercentage: slashPercentage,
            reputationPenalty: reputationPenalty,
            suspensionDuration: suspensionDuration,
            permanentBan: permanentBan,
            active: active
        });
        emit OffenceConfigUpdated(offenceId, slashPercentage, reputationPenalty, suspensionDuration, permanentBan, active);
    }

    /**
     * @dev Update treasury routing split
     */
    function setTreasuryRouting(
        address _treasuryReserve,
        address _securityFund,
        address _protocolInsurance,
        address _burnAddress,
        uint256 _pctTreasuryReserve,
        uint256 _pctSecurityFund,
        uint256 _pctProtocolInsurance,
        uint256 _pctBurn
    ) external onlyGovernanceOrAdmin {
        require(_pctTreasuryReserve + _pctSecurityFund + _pctProtocolInsurance + _pctBurn == 100, "Percentages must total 100");
        treasuryReserve = _treasuryReserve;
        securityFund = _securityFund;
        protocolInsurance = _protocolInsurance;
        burnAddress = _burnAddress;

        pctTreasuryReserve = _pctTreasuryReserve;
        pctSecurityFund = _pctSecurityFund;
        pctProtocolInsurance = _pctProtocolInsurance;
        pctBurn = _pctBurn;

        emit TreasuryRoutingUpdated(
            _treasuryReserve,
            _securityFund,
            _protocolInsurance,
            _burnAddress,
            _pctTreasuryReserve,
            _pctSecurityFund,
            _pctProtocolInsurance,
            _pctBurn
        );
    }

    /**
     * @dev Set reputation oracle
     */
    function setReputationOracle(address _oracle) external onlyGovernanceOrAdmin {
        reputationOracle = IReputationOracle(_oracle);
        emit ReputationOracleUpdated(_oracle);
    }

    function updateSlashingConfig(
        uint256 _maxSlashPercentage,
        uint256 _slashCooldown
    ) external onlyGovernanceOrAdmin {
        require(_maxSlashPercentage <= MAX_SLASH_PERCENTAGE, "Percentage too high");
        require(_slashCooldown <= 7 days, "Cooldown too long");
        
        maxSlashPercentage = _maxSlashPercentage;
        slashCooldown = _slashCooldown;
        
        emit SlashingConfigUpdated(_maxSlashPercentage, _slashCooldown);
    }
    
    /// @notice Configure the optional reputation penalty adapter.
    function setReputationPenaltyReceiver(
        address newReceiver
    ) external onlyGovernanceOrAdmin {
        address oldReceiver = address(reputationPenaltyReceiver);
        reputationPenaltyReceiver =
            IReputationPenaltyReceiver(newReceiver);

        emit ReputationPenaltyReceiverUpdated(oldReceiver, newReceiver);
    }

    /// @notice Configure the optional appeal-manager adapter.
    /// @dev Governance-gated. Setting `address(0)` disables the appeal gate.
    function setAppealManager(address newManager) external onlyGovernanceOrAdmin {
        address oldManager = address(appealManager);
        appealManager = IAppealManager(newManager);
        emit AppealManagerUpdated(oldManager, newManager);
    }

    /// @notice Configure settlement epoch duration.
    function setSettlementEpochDuration(
        uint256 newDuration
    ) external onlyGovernanceOrAdmin {
        if (newDuration == 0 || newDuration > 365 days) {
            revert InvalidEpochDuration();
        }

        uint256 oldDuration = settlementEpochDuration;
        settlementEpochDuration = newDuration;

        emit SettlementEpochDurationUpdated(oldDuration, newDuration);
    }

    /**
     * @dev Update the staking contract address
     * @param _stakingContract New staking contract address
     */
    function updateStakingContract(address _stakingContract) external onlyGovernanceOrAdmin {
        if (_stakingContract == address(0)) {
            revert InvalidStakingContract();
        }
        
        stakingContract = IStaking(_stakingContract);
        emit StakingContractUpdated(_stakingContract);
    }
    
    /**
     * @dev Set the treasury accounting contract
     * @param _treasuryAccounting Address of the deployed TreasuryAccounting contract
     */
    function setTreasuryAccounting(address _treasuryAccounting) external onlyGovernanceOrAdmin {
        if (_treasuryAccounting == address(0)) {
            revert InvalidTreasuryAddress();
        }
        treasuryAccounting = ITreasuryAccounting(_treasuryAccounting);
        emit TreasuryAccountingUpdated(_treasuryAccounting);
    }
    
    /**
     * @dev Grant resolver role to an address (typically the settlement contract)
     * @param account Address to grant the role to
     */
    function grantResolverRole(address account) external onlyGovernanceOrAdmin {
        if (hasRole(RESOLVER_ROLE, account)) revert ResolverRoleChangeNoop();
        _scheduleResolverRoleGrant(account);
    }
    
    function revokeResolverRole(address account) external onlyGovernanceOrAdmin {
        if (!hasRole(RESOLVER_ROLE, account)) revert ResolverRoleChangeNoop();
        _scheduleResolverRoleRevoke(account);
    }

    function grantSettlementRole(address account) external onlyGovernanceOrAdmin {
        if (hasRole(SETTLEMENT_ROLE, account)) revert ResolverRoleChangeNoop();
        _scheduleResolverRoleGrant(account);
    }
    
    function revokeSettlementRole(address account) external onlyGovernanceOrAdmin {
        if (!hasRole(SETTLEMENT_ROLE, account)) revert ResolverRoleChangeNoop();
        _scheduleResolverRoleRevoke(account);
    }

    function grantCriticalSlasherRole(address account) external onlyGovernanceOrAdmin {
        _grantRole(CRITICAL_SLASHER_ROLE, account);
    }

    function revokeCriticalSlasherRole(address account) external onlyGovernanceOrAdmin {
        _revokeRole(CRITICAL_SLASHER_ROLE, account);
    }
    
    // ============ Governance Parameter Updates ============
    
    function setMaxSlashPercentage(uint256 newPercentage) external onlyGovernanceOrAdmin {
        require(newPercentage <= MAX_SLASH_PERCENTAGE, "Percentage too high");
        
        uint256 old = maxSlashPercentage;
        maxSlashPercentage = newPercentage;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_MAX_SLASH, old, newPercentage);
    }
    
    function setSlashCooldown(uint256 newCooldown) external onlyGovernanceOrAdmin {
        require(newCooldown <= 7 days, "Cooldown too long");
        
        uint256 old = slashCooldown;
        slashCooldown = newCooldown;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_COOLDOWN, old, newCooldown);
    }
    
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
}
