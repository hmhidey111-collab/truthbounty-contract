// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "./libraries/BoundedSafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IClaimRegistry.sol";
import "./interfaces/ISTakeVault.sol";
import "./interfaces/IDisputeResolution.sol";
import "./fees/IFeeManager.sol";

/**
 * @title DisputeResolution
 * @notice Dispute Opening & Challenge Bond Custody engine (V2-SC-016).
 *
 * @dev Implements issue #367 against the canonical {IClaimRegistry}:
 *
 *   - Accepted challengeable claims hold a provisional outcome (`VerifiedTrue` /
 *     `VerifiedFalse`) and are contested inside the ChallengeWindow
 *     [verificationDeadline, verificationDeadline + challengeWindowDuration].
 *   - Opening is permissionless but BOND-GATED: the caller must post the
 *     configured bond, which is pulled into the {StakeVault} via
 *     {ISTakeVault.lockBond}. No governance, guardian, or treasury role can
 *     open or waive a dispute without the bond.
 *   - Exactly one dispute may open per claim (`_disputesByClaim`); recursive
 *     reopening is additionally impossible because a `Disputed` claim is not a
 *     challengeable state.
 *   - The dispute record, bond lock, and claim transition are committed
 *     atomically: the claim is only flipped to `Disputed` AFTER the bond lock
 *     succeeds, and every failure path reverts so no partial state can persist.
 *
 * Dependencies:
 *   - {IClaimRegistry}  — the claim store + {Disputed} transition (V2 base).
 *   - {ISTakeVault}     — bond custody (V2-SC-009 stand-in).
 *   - Optional {IFeeManager} — routes the DISPUTE_INITIATION_FEE (V2-SC-028
 *     fee policy). Disabled when the fee manager address is unset.
 *
 * The claim must be challengeable and within its window for a dispute to open.
 * Appeal settlement / rewarding the challenger is OUT of scope (SC-016 non-goal).
 */
contract DisputeResolution is IDisputeResolution, ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    // =========================================================================
    // Constants & Roles
    // =========================================================================

    /// @notice Default admin role — can grant/revoke roles and set parameters.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Pauser role — can halt dispute opening.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Fee type routed through the optional FeeManager (matches its constant).
    bytes32 public constant DISPUTE_INITIATION_FEE = keccak256("DISPUTE_INITIATION_FEE");

    // =========================================================================
    // State
    // =========================================================================

    /// @notice The canonical claim registry.
    IClaimRegistry public immutable claimRegistry;

    /// @notice The bond custody vault (V2-SC-009).
    ISTakeVault public vault;

    /// @notice Optional FeeManager (address(0) disables the fee).
    address public feeManager;

    /// @notice Bond token required to open a dispute.
    address public bondToken;

    /// @notice Bond amount required to open a dispute (in `bondToken` units).
    uint256 public bondAmount;

    /// @notice Duration of the challenge window, measured from the claim's
    ///         verification deadline. The frozen/appeal deadline equals
    ///         verificationDeadline + challengeWindowDuration.
    uint64 public challengeWindowDuration;

    /// @notice Monotonic dispute id source; the first dispute has id 1.
    uint256 private _nextDisputeId = 1;

    /// @notice disputeId => Dispute.
    mapping(uint256 => Dispute) private _disputes;

    /// @notice claimId => disputeId (0 means none).
    mapping(uint256 => uint256) private _disputesByClaim;

    /// @dev Storage gap for upgradeability compatibility.
    uint256[44] private __gap;

    // =========================================================================
    // Events (admin / config)
    // =========================================================================

    /// @notice Emitted when governance updates the challenge window.
    event ChallengeWindowUpdated(uint64 oldValue, uint64 newValue);

    /// @notice Emitted when the vault is re-pointed.
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    /// @notice Emitted when the bond token is updated.
    event BondTokenUpdated(address indexed oldToken, address indexed newToken);

    /// @notice Emitted when the bond amount is updated.
    event BondAmountUpdated(uint256 oldAmount, uint256 newAmount);

    /// @notice Emitted when the fee manager is set.
    event FeeManagerUpdated(address indexed oldManager, address indexed newManager);

    // =========================================================================
    // Errors (local — interface errors inherited via IDisputeResolution)
    // =========================================================================

    /// @notice Thrown when setting an invalid (zero) challenge window.
    error InvalidChallengeWindow();

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @param _claimRegistry Address of the canonical {IClaimRegistry}.
     * @param _vault         Address of the {ISTakeVault} bond vault.
     * @param _bondToken     Bond ERC20 token.
     * @param _bondAmount    Bond amount required to open a dispute.
     * @param _admin         Initial admin.
     * @dev The deploying admin should also grant this contract the
     *      {IClaimRegistry.REGISTRY_UPDATER_ROLE} so it can transition claims, and
     *      grant the vault it manages the corresponding {StakeVault.OPERATOR_ROLE}.
     */
    constructor(
        address _claimRegistry,
        address _vault,
        address _bondToken,
        uint256 _bondAmount,
        uint64 _challengeWindowDuration,
        address _admin
    ) {
        if (_claimRegistry == address(0)) revert ZeroAddress();
        if (_vault == address(0)) revert ZeroAddress();
        if (_bondToken == address(0)) revert ZeroAddress();
        if (_challengeWindowDuration == 0) revert InvalidChallengeWindow();
        if (_admin == address(0)) revert ZeroAddress();

        claimRegistry = IClaimRegistry(_claimRegistry);
        vault = ISTakeVault(_vault);
        bondToken = _bondToken;
        bondAmount = _bondAmount;
        challengeWindowDuration = _challengeWindowDuration;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
    }

    // =========================================================================
    // Write Functions — Dispute Opening (permissionless, bond-gated)
    // =========================================================================

    /**
     * @inheritdoc IDisputeResolution
     *
     * @dev The caller must approve the configured vault for at least
     *      `bondAmount`; the vault is the ERC-20 spender and bond custodian.
     */
    function openDispute(
        uint256 claimId,
        ChallengedOutcome challengedOutcome,
        bytes32 appealRationaleHash
    ) external override nonReentrant whenNotPaused returns (uint256 disputeId) {
        // -- 1. Timing & state validation --------------------------------
        IClaimRegistry.Claim memory claim = claimRegistry.getClaim(claimId);
        if (claim.createdAt == 0) revert ClaimNotFound(claimId);

        // Exactly one appeal path per claim. Check this before status because a
        // successful first dispute transitions the claim to UnderDispute.
        if (_disputesByClaim[claimId] != 0) revert DisputeAlreadyOpen(claimId);

        IClaimRegistry.ClaimStatus status = claim.status;
        if (status != IClaimRegistry.ClaimStatus.VerifiedTrue &&
            status != IClaimRegistry.ClaimStatus.VerifiedFalse) {
            revert ClaimNotChallengeable(status);
        }

        uint256 verificationDeadline = claim.verificationDeadline;
        uint256 frozenDeadline = verificationDeadline + challengeWindowDuration;

        if (block.timestamp <= verificationDeadline) revert ChallengeWindowNotOpen();
        if (block.timestamp > frozenDeadline) revert FrozenDeadlinePassed();

        // -- 2. Bond config ----------------------------------------------
        if (bondAmount == 0 || bondToken == address(0)) revert BondNotConfigured();

        if (IERC20(bondToken).allowance(msg.sender, address(vault)) < bondAmount) {
            revert InsufficientBondAllowance();
        }

        // -- 3. Bond custody FIRST (no dispute without a successful lock) --
        disputeId = _nextDisputeId;
        unchecked {
            _nextDisputeId = disputeId + 1;
        }

        // The challenger authorizes the vault directly; the vault is the ERC-20
        // spender and records the challenger as the bond depositor.
        try vault.lockBond(disputeId, bondToken, msg.sender, bondAmount) {
            // success — proceed
        } catch {
            revert CustodyTransitionFailed();
        }

        // -- 4. Optional fee ---------------------------------------------
        if (feeManager != address(0)) {
            // FeeManager.collectFee pulls from the payer; the module already
            // holds COLLECTOR_ROLE at the FeeManager. The fee is external to the
            // bond ledger and routed to treasury allocations.
            // amount computed by the FeeManager for DISPUTE_INITIATION_FEE.
            _collectDisputeFee(msg.sender);
        }

        // -- 5. Commit dispute record + claim transition (atomic) --------
        _disputes[disputeId] = Dispute({
            id: disputeId,
            claimId: claimId,
            challenger: msg.sender,
            challengedOutcome: challengedOutcome,
            challengedStatus: status,
            bondToken: bondToken,
            bondAmount: bondAmount,
            openedAt: uint64(block.timestamp),
            appealDeadline: uint64(frozenDeadline),
            appealRationaleHash: appealRationaleHash,
            settled: false
        });
        _disputesByClaim[claimId] = disputeId;

        // Flip the claim to Disputed. The registry reverts on invalid transitions,
        // which rolls back the bond lock and dispute record atomically.
        claimRegistry.updateClaimStatus(claimId, IClaimRegistry.ClaimStatus.Disputed);

        emit DisputeOpenedV1(
            claimId,
            disputeId,
            msg.sender,
            challengedOutcome,
            status,
            bondToken,
            bondAmount,
            uint64(frozenDeadline),
            appealRationaleHash,
            uint64(block.timestamp),
            1
        );
    }

    // =========================================================================
    // Internal
    // =========================================================================

    /**
     * @dev Routes the DISPUTE_INITIATION_FEE through the configured FeeManager.
     *      `collectFee` pulls the computed amount from `payer` (the challenger),
     *      so the challenger must also approve the FeeManager for the fee amount
     *      when a fee manager is configured.
     */
    function _collectDisputeFee(address payer) internal {
        uint256 feeAmount = IFeeManager(feeManager).calculateFee(DISPUTE_INITIATION_FEE, bondAmount);
        if (feeAmount == 0) return;
        IFeeManager(feeManager).collectFee(DISPUTE_INITIATION_FEE, payer, feeAmount);
    }

    // =========================================================================
    // Write Functions — Admin / Governance
    // =========================================================================

    /**
     * @notice Re-points the bond custody vault.
     * @param newVault New {ISTakeVault} address.
     */
    function setVault(address newVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newVault == address(0)) revert ZeroAddress();
        emit VaultUpdated(address(vault), newVault);
        vault = ISTakeVault(newVault);
    }

    /**
     * @notice Sets the bond token.
     * @param newToken New bond ERC20.
     */
    function setBondToken(address newToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newToken == address(0)) revert ZeroAddress();
        emit BondTokenUpdated(bondToken, newToken);
        bondToken = newToken;
    }

    /**
     * @notice Sets the bond amount.
     * @param newAmount New bond amount.
     */
    function setBondAmount(uint256 newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit BondAmountUpdated(bondAmount, newAmount);
        bondAmount = newAmount;
    }

    /**
     * @notice Sets the challenge window duration.
     * @param newDuration New window (seconds). Must be non-zero.
     */
    function setChallengeWindowDuration(uint64 newDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDuration == 0) revert InvalidChallengeWindow();
        emit ChallengeWindowUpdated(challengeWindowDuration, newDuration);
        challengeWindowDuration = newDuration;
    }

    /**
     * @notice Sets the fee manager (address(0) disables the DISPUTE_INITIATION_FEE).
     * @param newManager New FeeManager address.
     */
    function setFeeManager(address newManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit FeeManagerUpdated(feeManager, newManager);
        feeManager = newManager;
    }

    /**
     * @notice Pauses dispute opening.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Resumes dispute opening.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /**
     * @inheritdoc IDisputeResolution
     */
    function getDispute(uint256 disputeId) external view override returns (Dispute memory dispute) {
        return _disputes[disputeId];
    }

    /**
     * @inheritdoc IDisputeResolution
     */
    function disputeExists(uint256 disputeId) external view override returns (bool exists) {
        return _disputes[disputeId].id != 0;
    }

    /**
     * @inheritdoc IDisputeResolution
     */
    function getDisputeByClaim(uint256 claimId) external view override returns (uint256 disputeId) {
        return _disputesByClaim[claimId];
    }

    /**
     * @inheritdoc IDisputeResolution
     */
    function totalDisputes() external view override returns (uint256 total) {
        unchecked {
            return _nextDisputeId - 1;
        }
    }

    /**
     * @notice Returns the frozen (appeal) deadline for a claim.
     * @param claimId Claim to query.
     * @return frozen Deadline timestamp after which no dispute can open.
     */
    function frozenDeadline(uint256 claimId) external view returns (uint256 frozen) {
        IClaimRegistry.Claim memory claim = claimRegistry.getClaim(claimId);
        return uint256(claim.verificationDeadline) + challengeWindowDuration;
    }
}
