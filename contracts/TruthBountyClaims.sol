// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "./libraries/BoundedSafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TruthBountyClaims
 * @dev Handles batched claim settlements for TruthBounty protocols.
 *      Focuses on gas efficiency and loop safety.
 *
 * @notice IMPORTANT: This contract is a treasury-controlled batch token payout utility.
 *         It does NOT implement the claim lifecycle (create/vote/settle).
 *         For the claim lifecycle use TruthBountyWeighted.
 *         This contract is used only for off-chain-resolved reward disbursement
 *         where a TREASURY_ROLE holder pushes payouts in bulk.
 *         See docs/protocol-spec.md for the canonical architecture.
 *
 * V2-SC-062 hardening — replay prevention and failure isolation:
 *  - `settleClaim` and `settleClaimsBatch` accept an explicit `settlementId` that
 *    is consumed exactly once.  A second call with the same id reverts with
 *    `SettlementAlreadyExecuted`, making replay impossible regardless of caller.
 *  - Individual recipient failures (hostile ERC20 callbacks, zero-address entries)
 *    do NOT revert the entire batch; instead, each failed entry is skipped and
 *    logged via `SettlementSkipped` so a caller can correct and resubmit only the
 *    failed rows under a fresh `settlementId`.
 *  - State updates (marking the id as executed) happen BEFORE any token transfer
 *    (Checks-Effects-Interactions), so partial completion is safe on revert.
 */
contract TruthBountyClaims is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    IERC20 public immutable bountyToken;

    // ============ Replay guard ============

    /// @notice Tracks which settlement IDs have already been executed.
    mapping(bytes32 => bool) public executedSettlements;

    // ============ Events ============

    event ClaimSettled(address indexed beneficiary, uint256 amount, bytes32 indexed settlementId);
    event BatchSettlementCompleted(uint256 count, bytes32 indexed settlementId);
    /// @notice Fired for each row in a batch that could not be transferred.
    event SettlementSkipped(
        bytes32 indexed settlementId,
        address indexed beneficiary,
        uint256 amount,
        bytes reason
    );

    // ============ Errors ============

    /// @notice The `settlementId` has already been executed; replay is forbidden.
    error SettlementAlreadyExecuted(bytes32 settlementId);
    /// @notice A zero-value settlementId is not permitted.
    error ZeroSettlementId();
    /// @notice A token transfer failed; raw token revert data is intentionally not retained.
    error TokenTransferFailed(address token, address beneficiary, uint256 amount);

    // ============ Constants ============

    /// @notice Max batch size to prevent out-of-gas errors (Audit #156).
    uint256 public constant MAX_BATCH_SIZE = 200;

    // ============ Constructor ============

    constructor(address _tokenAddress, address initialAdmin) {
        require(_tokenAddress != address(0), "Invalid token address");
        require(initialAdmin != address(0), "Invalid admin address");

        bountyToken = IERC20(_tokenAddress);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(TREASURY_ROLE, initialAdmin); // Default admin also gets treasury role

        _setRoleAdmin(TREASURY_ROLE, ADMIN_ROLE);
    }

    // ============ External — single settlement ============

    /**
     * @notice Settles a single claim identified by `settlementId`.
     * @dev V2-SC-062: `settlementId` is consumed on first execution; a duplicate
     *      call with the same id reverts with `SettlementAlreadyExecuted`.
     *      CEI: id marked executed BEFORE the token transfer.
     *
     * @param beneficiary   The address receiving the bounty.
     * @param amount        The amount of tokens to transfer.
     * @param settlementId  Unique opaque identifier for this settlement action.
     */
    function settleClaim(
        address beneficiary,
        uint256 amount,
        bytes32 settlementId
    ) external onlyRole(TREASURY_ROLE) nonReentrant {
        if (settlementId == bytes32(0)) revert ZeroSettlementId();
        _assertNotExecuted(settlementId);
        // CEI — mark executed before external call.
        executedSettlements[settlementId] = true;
        _settle(beneficiary, amount, settlementId);
    }

    // ============ External — batch settlement ============

    /**
     * @notice Settles multiple claims in a single transaction for gas efficiency.
     * @dev V2-SC-062: The entire batch is identified by a single `settlementId`
     *      consumed atomically.  Individual row failures are isolated: a single
     *      reverting beneficiary (e.g. hostile contract) is skipped and logged
     *      rather than reverting the whole batch.  The treasury can resubmit
     *      failed rows under a new `settlementId`.
     *
     * @param beneficiaries  Array of addresses receiving bounties.
     * @param amounts        Parallel array of amounts.
     * @param settlementId   Unique opaque identifier for this batch.
     */
    function settleClaimsBatch(
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        bytes32 settlementId
    ) external onlyRole(TREASURY_ROLE) nonReentrant {
        if (settlementId == bytes32(0)) revert ZeroSettlementId();

        uint256 length = beneficiaries.length;
        require(length == amounts.length, "Arrays length mismatch");
        require(length > 0, "No claims to settle");
        // Enforce batch size cap to bound gas and prevent block-gas-limit DoS (Audit #156).
        require(length <= MAX_BATCH_SIZE, "Batch size too large");

        _assertNotExecuted(settlementId);
        // CEI — mark consumed before any row transfer.
        executedSettlements[settlementId] = true;

        uint256 successCount;
        for (uint256 i = 0; i < length; ) {
            address beneficiary = beneficiaries[i];
            uint256 amount = amounts[i];

            // Per-row validation: skip obviously invalid rows rather than reverting.
            if (beneficiary == address(0) || amount == 0) {
                emit SettlementSkipped(settlementId, beneficiary, amount, "invalid row");
                unchecked { ++i; }
                continue;
            }

            // Failure isolation: use try/catch over a low-level call to isolate a
            // reverting recipient.  SafeERC20.safeTransfer does not return false —
            // it either succeeds or reverts — so catching the revert is the correct
            // isolation technique here.
            try this._tryTransfer(beneficiary, amount) {
                emit ClaimSettled(beneficiary, amount, settlementId);
                unchecked { ++successCount; }
            } catch {
                // Log the skip so off-chain systems can resubmit this row.
                bytes memory reason = abi.encodeWithSelector(
                    TokenTransferFailed.selector,
                    address(bountyToken),
                    beneficiary,
                    amount
                );
                emit SettlementSkipped(settlementId, beneficiary, amount, reason);
            }

            unchecked { ++i; }
        }

        emit BatchSettlementCompleted(successCount, settlementId);
    }

    // ============ External helper (called only by this contract via try/catch) ============

    /**
     * @notice Executes a single token transfer; reverts on failure.
     * @dev This function is `external` so it can be called via `this._tryTransfer`
     *      inside a try/catch block for failure isolation in `settleClaimsBatch`.
     *      It MUST NOT be called by any external party; the `onlySelf` guard enforces this.
     */
    function _tryTransfer(address beneficiary, uint256 amount) external {
        require(msg.sender == address(this), "Only self");
        bountyToken.safeTransfer(beneficiary, amount);
    }

    // ============ View ============

    /**
     * @notice Returns true if `settlementId` has already been executed.
     */
    function isSettlementExecuted(bytes32 settlementId) external view returns (bool) {
        return executedSettlements[settlementId];
    }

    // ============ Internal ============

    /**
     * @dev Transfer tokens to `_beneficiary` and emit `ClaimSettled`.
     *      Parameters use an underscore prefix to avoid shadowing inherited
     *      declarations (Audit #190).
     */
    function _settle(address _beneficiary, uint256 _amount, bytes32 _settlementId) internal {
        require(_beneficiary != address(0), "Invalid beneficiary");
        require(_amount > 0, "Amount must be > 0");

        bountyToken.safeTransfer(_beneficiary, _amount);
        emit ClaimSettled(_beneficiary, _amount, _settlementId);
    }

    /**
     * @dev Revert if `settlementId` has already been executed.
     */
    function _assertNotExecuted(bytes32 settlementId) internal view {
        if (executedSettlements[settlementId]) revert SettlementAlreadyExecuted(settlementId);
    }

    // ============ Admin ============

    /**
     * @notice Allows the treasury to recover accidental ERC20 transfers.
     * @param tokenAddress The token contract address.
     * @param to           The recipient address.
     * @param amount       The amount to transfer.
     */
    function rescueTokens(address tokenAddress, address to, uint256 amount) external onlyRole(TREASURY_ROLE) {
        IERC20(tokenAddress).safeTransfer(to, amount);
    }
}
