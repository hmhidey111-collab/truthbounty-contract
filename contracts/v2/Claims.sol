// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UntrackedAssetRecovery} from "../recovery/UntrackedAssetRecovery.sol";

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {BoundedSafeERC20 as SafeERC20} from "../libraries/BoundedSafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IClaims} from "./interfaces/IClaims.sol";
import {IV2Module} from "./interfaces/IV2Module.sol";
import {IV2Types} from "./interfaces/IV2Types.sol";
import {AntiGriefing} from "./libraries/AntiGriefing.sol";
import {V2Errors} from "./libraries/V2Errors.sol";
import {V2SafeCast} from "./libraries/V2SafeCast.sol";
import {V2WiredPauseGuard} from "./libraries/V2PauseGuard.sol";
import {PauseMatrix} from "./libraries/PauseMatrix.sol";
import {ProtocolExecutionBounds} from "../performance/ProtocolExecutionBounds.sol";

/// @title Claims
/// @notice Canonical V2 claim lifecycle with dust-bounty and claim-spam griefing controls (V2-SC-105).
/// @dev Claim creation escrows the bounty into this module, charges a submission fee to `feeRecipient`,
///      and enforces per-account rate limits / open-claim caps before any storage write.
///
///      Pause matrix (V2-SC-162, `PauseMatrix` v1): `createClaim` fails closed under `SCOPE_CLAIMS`,
///      `finalizeClaim` under `SCOPE_SETTLEMENT`, and `setAntiGriefParams` under `SCOPE_GOVERNANCE`.
///      A claimant's own `cancelClaim` refund is a RISK_REDUCING exit that stays available under every
///      scoped pause (frozen only at protocol SHUTDOWN); a manager-initiated cancel is an outcome
///      decision and additionally fails closed under `SCOPE_SETTLEMENT`.
contract Claims is ERC165, AccessControl, ReentrancyGuard, IClaims, V2WiredPauseGuard, UntrackedAssetRecovery {
    /// @notice Maximum optional metadata accepted with a claim creation request.
    uint256 public constant MAX_CLAIM_METADATA_BYTES = 1_024;

    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CLAIM_MANAGER_ROLE = keccak256("CLAIM_MANAGER_ROLE");

    IERC20 public immutable bountyToken;
    address public feeRecipient;
    uint256 public minBounty;
    uint256 public claimSubmissionFee;
    uint256 public maxClaimsPerWindow;
    uint64 public claimSpamWindow;
    uint256 public maxOpenClaimsPerCreator;

    uint256 private _nextClaimId = 1;
    mapping(uint256 => IV2Types.Claim) private _claims;
    mapping(address => uint64) private _claimWindowStart;
    mapping(address => uint256) private _claimsInWindow;
    mapping(address => uint256) private _openClaimCount;

    event AntiGriefParamsUpdated(
        uint256 minBounty,
        uint256 claimSubmissionFee,
        uint256 maxClaimsPerWindow,
        uint64 claimSpamWindow,
        uint256 maxOpenClaimsPerCreator,
        address feeRecipient
    );

    /// @notice V2-SC-039: exact integer attribution for one submission-fee routing.
    /// @dev Emitted exactly once per paid `createClaim`. The fee is charged on top of
    ///      (never from) the escrowed bounty, so the escrowed reward is never reduced
    ///      by fee arithmetic and the fee can never be routed twice for one claim.
    event ClaimFeeCharged(uint256 indexed claimId, address indexed payer, address indexed feeRecipient, uint256 amount);

    /// @param admin Governance / deployment authority.
    /// @param bountyToken_ ERC-20 used for claim bounties and submission fees.
    /// @param feeRecipient_ Pull destination for claim submission fees (non-zero).
    /// @param minBounty_ Economic floor for claim rewards (dust rejection).
    /// @param claimSubmissionFee_ Flat fee charged on every createClaim.
    constructor(
        address admin,
        address bountyToken_,
        address feeRecipient_,
        uint256 minBounty_,
        uint256 claimSubmissionFee_
    ) {
        if (admin == address(0) || bountyToken_ == address(0) || feeRecipient_ == address(0)) {
            revert V2Errors.ZeroAddress();
        }
        if (minBounty_ == 0) revert V2Errors.ZeroAmount();

        bountyToken = IERC20(bountyToken_);
        feeRecipient = feeRecipient_;
        minBounty = minBounty_;
        claimSubmissionFee = claimSubmissionFee_;
        maxClaimsPerWindow = ProtocolExecutionBounds.MAX_CLAIMS_PER_ACCOUNT_WINDOW;
        claimSpamWindow = uint64(ProtocolExecutionBounds.CLAIM_SPAM_WINDOW_SECONDS);
        maxOpenClaimsPerCreator = ProtocolExecutionBounds.MAX_OPEN_CLAIMS_PER_CREATOR;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(CLAIM_MANAGER_ROLE, admin);
    }

    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl, ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(IClaims).interfaceId || interfaceId == type(IV2Module).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Publish anti-grief thresholds. Governance only; never lowers floors to zero.
    function setAntiGriefParams(
        uint256 minBounty_,
        uint256 claimSubmissionFee_,
        uint256 maxClaimsPerWindow_,
        uint64 claimSpamWindow_,
        uint256 maxOpenClaimsPerCreator_,
        address feeRecipient_
    ) external onlyRole(ADMIN_ROLE) {
        _requireScopeNotPaused(PauseMatrix.SCOPE_GOVERNANCE);
        if (feeRecipient_ == address(0)) revert V2Errors.ZeroAddress();
        if (minBounty_ == 0) revert V2Errors.ZeroAmount();
        if (maxClaimsPerWindow_ == 0 || maxOpenClaimsPerCreator_ == 0 || claimSpamWindow_ == 0) {
            revert V2Errors.InvalidArgument("zero anti-grief bound");
        }

        minBounty = minBounty_;
        claimSubmissionFee = claimSubmissionFee_;
        maxClaimsPerWindow = maxClaimsPerWindow_;
        claimSpamWindow = claimSpamWindow_;
        maxOpenClaimsPerCreator = maxOpenClaimsPerCreator_;
        feeRecipient = feeRecipient_;

        emit AntiGriefParamsUpdated(
            minBounty_,
            claimSubmissionFee_,
            maxClaimsPerWindow_,
            claimSpamWindow_,
            maxOpenClaimsPerCreator_,
            feeRecipient_
        );
    }

    /// @notice Wires the V2 pause authority exactly once (V2-SC-162).
    /// @dev NEUTRAL: wiring only tightens control and can never be replaced or removed, so it cannot be
    ///      used to lift an active pause. Admin only.
    /// @param authority `IEmergencyControls` implementation (e.g. `EmergencyGatekeeper`).
    function setPauseAuthority(address authority) external onlyRole(ADMIN_ROLE) {
        _wirePauseAuthority(authority);
    }

    /// @inheritdoc IClaims
    function createClaim(bytes32 subject, uint256 reward, bytes calldata metadata)
        external
        override
        nonReentrant
        returns (uint256 claimId)
    {
        if (metadata.length > MAX_CLAIM_METADATA_BYTES) {
            revert V2Errors.ClaimMetadataTooLarge(metadata.length, MAX_CLAIM_METADATA_BYTES);
        }
        _requireScopeNotPaused(PauseMatrix.SCOPE_CLAIMS);
        if (subject == bytes32(0)) revert V2Errors.InvalidClaimSubject();
        AntiGriefing.requireMinAmount(reward, minBounty);

        address claimant = msg.sender;
        AntiGriefing.requireOpenClaimCapacity(claimant, _openClaimCount[claimant], maxOpenClaimsPerCreator);

        // V2-SC-161: fail closed instead of truncating the stored `createdAt` and window start.
        uint64 nowTs = V2SafeCast.timestamp64(V2SafeCast.FIELD_CLAIM_CREATED_AT);
        (uint64 newStart, uint256 newCount) = AntiGriefing.nextClaimWindow(
            claimant,
            nowTs,
            _claimWindowStart[claimant],
            _claimsInWindow[claimant],
            maxClaimsPerWindow,
            claimSpamWindow
        );
        _claimWindowStart[claimant] = newStart;
        _claimsInWindow[claimant] = newCount;

        uint256 fee = claimSubmissionFee;
        uint256 pull = reward + fee;
        uint256 balanceBefore = bountyToken.balanceOf(address(this));
        bountyToken.safeTransferFrom(claimant, address(this), pull);
        uint256 received = bountyToken.balanceOf(address(this)) - balanceBefore;
        if (received != pull) revert V2Errors.TransferAmountMismatch(pull, received);

        if (fee != 0) {
            bountyToken.safeTransfer(feeRecipient, fee);
        }

        claimId = _nextClaimId;
        unchecked {
            _nextClaimId = claimId + 1;
        }

        if (fee != 0) {
            emit ClaimFeeCharged(claimId, claimant, feeRecipient, fee);
        }

        IV2Types.Claim storage c = _claims[claimId];
        c.id = claimId;
        c.claimant = claimant;
        c.subject = subject;
        c.reward = reward;
        _increaseRecoveryReserve(address(bountyToken), reward);
        c.createdAt = nowTs;
        c.status = IV2Types.ClaimStatus.OPEN;

        _openClaimCount[claimant] += 1;

        emit ClaimCreated(claimId, claimant, subject, reward);
        emit ClaimStateChanged(
            claimId,
            IV2Types.ClaimState.None,
            IV2Types.ClaimState.VerificationOpen,
            claimant,
            nowTs,
            bytes32(0)
        );
    }

    /// @inheritdoc IClaims
    /// @dev V2-SC-162: the claimant's own cancellation is a RISK_REDUCING refund exit that stays available
    ///      under every scoped pause and freezes only at protocol SHUTDOWN. A CLAIM_MANAGER_ROLE cancellation
    ///      of someone else's claim is an outcome decision and also fails closed under `SCOPE_SETTLEMENT`.
    ///      Idempotent: a second cancellation reverts with `InvalidClaimStateTransition` and refunds nothing.
    function cancelClaim(uint256 claimId) external override nonReentrant {
        _requireExitsNotShutdown();
        IV2Types.Claim storage c = _claims[claimId];
        if (c.id == 0) revert V2Errors.ClaimNotFound(claimId);
        if (c.claimant != msg.sender) {
            if (!hasRole(CLAIM_MANAGER_ROLE, msg.sender)) revert V2Errors.Unauthorized();
            _requireScopeNotPaused(PauseMatrix.SCOPE_SETTLEMENT);
        }
        if (c.status != IV2Types.ClaimStatus.OPEN) revert V2Errors.InvalidClaimStateTransition(claimId);

        c.status = IV2Types.ClaimStatus.CANCELLED;
        _openClaimCount[c.claimant] -= 1;

        uint256 refund = c.reward;
        _decreaseRecoveryReserve(address(bountyToken), refund);
        bountyToken.safeTransfer(c.claimant, refund);

        emit ClaimStateChanged(
            claimId,
            IV2Types.ClaimState.VerificationOpen,
            IV2Types.ClaimState.Finalized,
            msg.sender,
            V2SafeCast.timestamp64(V2SafeCast.FIELD_CLAIM_EVENT_TIMESTAMP),
            keccak256("CANCELLED")
        );
    }

    /// @notice Marks a claim terminal after settlement / rejection; frees open-claim capacity.
    function finalizeClaim(uint256 claimId, IV2Types.ClaimStatus terminalStatus)
        external
        onlyRole(CLAIM_MANAGER_ROLE)
        nonReentrant
    {
        _requireScopeNotPaused(PauseMatrix.SCOPE_SETTLEMENT);
        IV2Types.Claim storage c = _claims[claimId];
        if (c.id == 0) revert V2Errors.ClaimNotFound(claimId);
        if (c.status != IV2Types.ClaimStatus.OPEN && c.status != IV2Types.ClaimStatus.VERIFIED) {
            revert V2Errors.InvalidClaimStateTransition(claimId);
        }
        if (
            terminalStatus != IV2Types.ClaimStatus.SETTLED && terminalStatus != IV2Types.ClaimStatus.REJECTED
                && terminalStatus != IV2Types.ClaimStatus.CANCELLED
        ) {
            revert V2Errors.InvalidArgument("non-terminal status");
        }

        c.status = terminalStatus;
        if (_openClaimCount[c.claimant] > 0) {
            _openClaimCount[c.claimant] -= 1;
        }

        emit ClaimStateChanged(
            claimId,
            IV2Types.ClaimState.VerificationOpen,
            IV2Types.ClaimState.Finalized,
            msg.sender,
            V2SafeCast.timestamp64(V2SafeCast.FIELD_CLAIM_EVENT_TIMESTAMP),
            bytes32(uint256(uint8(terminalStatus)))
        );
    }

    /// @inheritdoc IClaims
    function getClaim(uint256 claimId) external view override returns (IV2Types.Claim memory) {
        if (_claims[claimId].id == 0) revert V2Errors.ClaimNotFound(claimId);
        return _claims[claimId];
    }

    /// @inheritdoc IClaims
    function stateOf(uint256 claimId) external view override returns (IV2Types.ClaimState) {
        IV2Types.Claim storage c = _claims[claimId];
        if (c.id == 0) revert V2Errors.ClaimNotFound(claimId);
        if (c.status == IV2Types.ClaimStatus.OPEN) return IV2Types.ClaimState.VerificationOpen;
        if (c.status == IV2Types.ClaimStatus.VERIFIED) return IV2Types.ClaimState.AwaitingSettlement;
        if (c.status == IV2Types.ClaimStatus.DISPUTED) return IV2Types.ClaimState.Disputed;
        return IV2Types.ClaimState.Finalized;
    }

    function openClaimCount(address account) external view returns (uint256) {
        return _openClaimCount[account];
    }

    function claimsInWindow(address account) external view returns (uint64 windowStart, uint256 count) {
        return (_claimWindowStart[account], _claimsInWindow[account]);
    }

    // V2-SC-154: additive recovery only; existing liability and authority paths remain authoritative.
    function _checkAssetRecoveryAuthority() internal view override {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function _requireAssetRecoveryAllowed() internal view override {
        (bool resolved, address authority) = _pauseAuthority();
        if (!resolved || authority == address(0)) revert RecoveryAuthorityUnavailable();
        _requireScopeNotPaused(PauseMatrix.SCOPE_GOVERNANCE);
        _requireScopeNotPaused(PauseMatrix.SCOPE_TREASURY);
        _requireExitsNotShutdown();
    }

    // Terminal status alone does not release custody: finalized bounties stay reserved.
    function _reservedAssetBalance(address asset) internal view override returns (uint256) {
        return asset == address(bountyToken) ? _recoveryReserved(asset) : 0;
    }
}
