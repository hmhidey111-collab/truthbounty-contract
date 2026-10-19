// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UntrackedAssetRecovery} from "../recovery/UntrackedAssetRecovery.sol";

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "../libraries/BoundedSafeERC20.sol";
import {ProtocolExecutionBounds} from "./ProtocolExecutionBounds.sol";
import {PauseMatrix} from "../v2/libraries/PauseMatrix.sol";
import {V2WiredPauseGuard} from "../v2/libraries/V2PauseGuard.sol";

/**
 * @title PullSettlementLedger
 * @notice Pull-based settlement credits — recipient behavior cannot block other users (V2-SC-038,
 *         V2-SC-062).
 *
 * @dev Pull-payment isolation invariants (V2-SC-062):
 *
 *  1. **Replay prevention** — every `settlementRef` may be applied at most once.
 *     A second call with the same ref reverts with `SettlementRefAlreadyProcessed`.
 *
 *  2. **Failure isolation** — credits are tracked per (account, settlementRef).
 *     A reverted or hostile withdrawal on one ref does not touch any other ref's
 *     balance.  A beneficiary that cannot receive tokens for ref A can still
 *     withdraw ref B independently.
 *
 *  3. **Balance update before interaction** — the per-ref withdrawn amount is
 *     incremented before the `safeTransfer` call (Checks-Effects-Interactions).
 *
 *  4. **Recoverable failures remain claimable** — a transient revert during
 *     `withdrawFromRef` leaves the per-ref balance intact; the caller may retry.
 *
 * Treasury grants CREDITOR_ROLE and calls `credit` / `creditBatch`.
 * Each beneficiary independently calls `withdraw` (aggregate) or
 * `withdrawFromRef` (per-settlement) to pull their tokens.
 *
 * Pause matrix (V2-SC-162, `PauseMatrix` v1): issuing new credit is settlement
 * and fails closed under `SCOPE_SETTLEMENT` of the wired V2 pause authority.
 * Both withdrawal paths are RISK_REDUCING exits of already-credited value: they
 * are never scope-gated and freeze only at protocol SHUTDOWN.
 */
contract PullSettlementLedger is AccessControl, ReentrancyGuard, V2WiredPauseGuard, UntrackedAssetRecovery {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    bytes32 public constant CREDITOR_ROLE = keccak256("CREDITOR_ROLE");

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    IERC20 public immutable token;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Aggregate credits accumulated per account across all settlement refs.
    mapping(address => uint256) public credited;

    /// @notice Aggregate amount already withdrawn per account.
    mapping(address => uint256) public withdrawn;

    /// @dev Per-(account, settlementRef) credit sub-balance.
    ///      Enables per-ref withdrawal and isolates failures between refs.
    mapping(address => mapping(bytes32 => uint256)) private _refCredited;

    /// @dev Per-(account, settlementRef) amount already withdrawn.
    mapping(address => mapping(bytes32 => uint256)) private _refWithdrawn;

    /// @dev Guards against replaying a settlementRef across any beneficiary.
    ///      A ref is "processed" once the first credit for it is recorded.
    mapping(bytes32 => bool) private _processedRefs;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a credit is recorded.
    event SettlementCredited(address indexed beneficiary, uint256 amount, bytes32 indexed settlementRef);

    /// @notice Emitted when a beneficiary pulls their aggregate balance.
    event SettlementWithdrawn(address indexed beneficiary, uint256 amount);

    /// @notice Emitted when a beneficiary pulls a single-ref balance.
    event SettlementRefWithdrawn(address indexed beneficiary, bytes32 indexed settlementRef, uint256 amount);

    /// @notice Emitted when a credit attempt for an already-processed ref is rejected.
    ///         Surfaced as an event (not only a revert) so off-chain monitors can detect
    ///         erroneous double-credit attempts without needing to parse revert data.
    event SettlementRefRejected(bytes32 indexed settlementRef, address indexed attemptedBy);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientCredit(uint256 available, uint256 requested);
    error BatchTooLarge(uint256 length, uint256 max);
    error LengthMismatch(uint256 a, uint256 b);
    /// @notice The supplied settlementRef has already been applied; replay is forbidden.
    error SettlementRefAlreadyProcessed(bytes32 settlementRef);
    /// @notice A zero-value settlementRef is not permitted (prevents accidental unguarded calls).
    error ZeroSettlementRef();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address admin, IERC20 token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        if (admin == address(0)) revert ZeroAddress();
        token = token_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CREDITOR_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Credit functions (CREDITOR_ROLE)
    // -------------------------------------------------------------------------

    /**
     * @notice Record a settlement credit for `beneficiary`.
     * @dev V2-SC-062 replay guard: `settlementRef` must be unique across all calls.
     *      The ref is marked processed on the first credit regardless of how many
     *      beneficiaries it covers (single-beneficiary case here).
     *
     * @param beneficiary  Recipient of the credit.
     * @param amount       Token amount being credited.
     * @param settlementRef  Unique opaque identifier for this settlement action.
     */
    function credit(address beneficiary, uint256 amount, bytes32 settlementRef)
        external
        onlyRole(CREDITOR_ROLE)
    {
        _requireScopeNotPaused(PauseMatrix.SCOPE_SETTLEMENT);
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (settlementRef == bytes32(0)) revert ZeroSettlementRef();
        _assertRefNotProcessed(settlementRef);

        // Mark ref as consumed before writing any balance (fail-closed on invalid config).
        _processedRefs[settlementRef] = true;

        _increaseRecoveryReserve(address(token), amount);
        credited[beneficiary] += amount;
        _refCredited[beneficiary][settlementRef] += amount;

        emit SettlementCredited(beneficiary, amount, settlementRef);
    }

    /**
     * @notice Batch-credit multiple beneficiaries under a single settlement ref.
     * @dev The entire batch shares one `settlementRef`; it is consumed atomically.
     *      Partial batch replays are therefore impossible.
     *
     * @param beneficiaries  Array of recipient addresses.
     * @param amounts        Parallel array of credit amounts.
     * @param settlementRef  Unique opaque identifier for this batch settlement.
     */
    function creditBatch(
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        bytes32 settlementRef
    ) external onlyRole(CREDITOR_ROLE) {
        _requireScopeNotPaused(PauseMatrix.SCOPE_SETTLEMENT);
        uint256 length = beneficiaries.length;
        if (length != amounts.length) revert LengthMismatch(length, amounts.length);
        if (length > ProtocolExecutionBounds.MAX_SETTLEMENT_BATCH_SIZE) {
            revert BatchTooLarge(length, ProtocolExecutionBounds.MAX_SETTLEMENT_BATCH_SIZE);
        }
        if (settlementRef == bytes32(0)) revert ZeroSettlementRef();
        _assertRefNotProcessed(settlementRef);

        // Mark consumed before any state mutation — fail-closed.
        _processedRefs[settlementRef] = true;

        for (uint256 i = 0; i < length; ++i) {
            address beneficiary = beneficiaries[i];
            uint256 amount = amounts[i];
            if (beneficiary == address(0)) revert ZeroAddress();
            if (amount == 0) revert ZeroAmount();

            _increaseRecoveryReserve(address(token), amount);
            credited[beneficiary] += amount;
            _refCredited[beneficiary][settlementRef] += amount;

            emit SettlementCredited(beneficiary, amount, settlementRef);
        }
    }

    // -------------------------------------------------------------------------
    // Withdrawal functions (pull by beneficiary)
    // -------------------------------------------------------------------------

    /**
     * @notice Pull the caller's entire available aggregate balance.
     * @dev CEI: aggregate `withdrawn` counter is incremented BEFORE the token
     *      transfer so a reverting or reentering token cannot double-withdraw.
     *      ReentrancyGuard provides a second layer of defense.
     *
     *      Failure isolation: this path drains the aggregate balance.  If a
     *      recipient prefers finer isolation, they should use `withdrawFromRef`.
     *
     * @param amount  Amount to withdraw (must be ≤ available balance).
     */
    function withdraw(uint256 amount) external nonReentrant {
        _requireExitsNotShutdown();
        if (amount == 0) revert ZeroAmount();
        uint256 available = credited[msg.sender] - withdrawn[msg.sender];
        if (amount > available) revert InsufficientCredit(available, amount);

        // CEI — update state before external call.
        withdrawn[msg.sender] += amount;
        _decreaseRecoveryReserve(address(token), amount);

        token.safeTransfer(msg.sender, amount);
        emit SettlementWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Pull the caller's available balance for a specific settlement ref.
     * @dev Failure isolation (V2-SC-062): a revert here only affects this ref's
     *      sub-balance.  Other refs are completely unaffected.
     *
     *      CEI: the per-ref `_refWithdrawn` counter is incremented BEFORE the
     *      transfer; the aggregate `withdrawn` counter is updated in the same
     *      step so both views remain consistent.
     *
     * @param settlementRef  The ref whose credited balance should be pulled.
     * @param amount         Amount to withdraw (must be ≤ ref's available balance).
     */
    function withdrawFromRef(bytes32 settlementRef, uint256 amount) external nonReentrant {
        _requireExitsNotShutdown();
        if (amount == 0) revert ZeroAmount();
        if (settlementRef == bytes32(0)) revert ZeroSettlementRef();

        uint256 refAvailable = _refCredited[msg.sender][settlementRef]
            - _refWithdrawn[msg.sender][settlementRef];
        if (amount > refAvailable) revert InsufficientCredit(refAvailable, amount);

        // V2-SC-162: the aggregate `withdraw` path does not advance per-ref counters, so the
        // per-ref view alone would let value already pulled through `withdraw` be pulled a
        // second time here. Bounding by the aggregate balance keeps
        // `withdrawn[account] <= credited[account]` across any mix of both exit paths.
        uint256 aggregateAvailable = credited[msg.sender] - withdrawn[msg.sender];
        if (amount > aggregateAvailable) revert InsufficientCredit(aggregateAvailable, amount);

        // CEI — update BOTH counters before external call.
        _refWithdrawn[msg.sender][settlementRef] += amount;
        withdrawn[msg.sender] += amount;
        _decreaseRecoveryReserve(address(token), amount);

        token.safeTransfer(msg.sender, amount);
        emit SettlementRefWithdrawn(msg.sender, settlementRef, amount);
    }

    // -------------------------------------------------------------------------
    // Emergency wiring (V2-SC-162)
    // -------------------------------------------------------------------------

    /**
     * @notice Wire the V2 pause authority exactly once.
     * @dev NEUTRAL: wiring only tightens control and can never be replaced or
     *      removed, so it cannot be used to lift an active settlement pause.
     * @param authority `IEmergencyControls` implementation (e.g. `EmergencyGatekeeper`).
     */
    function setPauseAuthority(address authority) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _wirePauseAuthority(authority);
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /**
     * @notice Available (unclaimed) aggregate balance for `account`.
     */
    function availableBalance(address account) external view returns (uint256) {
        return credited[account] - withdrawn[account];
    }

    /**
     * @notice Available balance for `account` restricted to a specific `settlementRef`.
     */
    function availableRefBalance(address account, bytes32 settlementRef) external view returns (uint256) {
        return _refCredited[account][settlementRef] - _refWithdrawn[account][settlementRef];
    }

    /**
     * @notice Returns true when `settlementRef` has already been applied.
     *         Callers (e.g. off-chain routers) can pre-check before submitting.
     */
    function isRefProcessed(bytes32 settlementRef) external view returns (bool) {
        return _processedRefs[settlementRef];
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /**
     * @dev Revert if `settlementRef` has already been consumed.
     *      Also emits a rejection event so monitoring infra can detect erroneous
     *      duplicate calls without relying solely on revert trace decoding.
     */
    function _assertRefNotProcessed(bytes32 settlementRef) internal {
        if (_processedRefs[settlementRef]) {
            emit SettlementRefRejected(settlementRef, msg.sender);
            revert SettlementRefAlreadyProcessed(settlementRef);
        }
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

    function _reservedAssetBalance(address asset) internal view override returns (uint256) {
        return asset == address(token) ? _recoveryReserved(asset) : 0;
    }
}
