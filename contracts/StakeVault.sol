// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UntrackedAssetRecovery} from "./recovery/UntrackedAssetRecovery.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "./libraries/BoundedSafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/ISTakeVault.sol";

/**
 * @title StakeVault
 * @notice Minimal bond-custody vault and lock ledger for challenge bonds.
 * @dev Production standing of this contract:
 *
 *      The full V2-SC-009 "Stake Vault Custody and Lock Ledger" module is not yet
 *      present in this repository. This contract is the minimal, self-contained
 *      custody primitive required by V2-SC-016 (dispute opening) so that every
 *      guarantee below holds on-chain today:
 *
 *        - Bond funds are HELD HERE (vaulted custody), not in the module that
 *          initiates a dispute.
 *        - Every lock is recorded on a persistent `BondLock` ledger, enabling the
 *          "bond and dispute records reconcile" acceptance criterion.
 *        - A depositor can never withdraw an active bond directly; only the
 *          authorised operator (the DisputeResolution engine) can release a lock
 *          to its final recipient (refund or slash target).
 *        - No governance, guardian, or treasury role can release an active bond.
 *          They may only pause the vault and the consuming modules.
 *
 *      When the production V2-SC-009 StakeVault is implemented, `DisputeResolution`
 *      is pointed at the new vault via `setVault`; no other caller depends on this
 *      concrete type (they code against {ISTakeVault}).
 *
 * Access control:
 *      - Default admin can grant/revoke roles and change the operator.
 *      - `OPERATOR_ROLE` (the DisputeResolution module in practice) can lock and
 *        release bonds.
 *      - `PAUSER_ROLE` can pause/unpause.
 *
 * Reentrancy: `lockBond` and `releaseBond` are `nonReentrant` and use
 * `SafeERC20`. External calls are: the ERC20 transfer-in on lock, and the ERC20
 * transfer-out on release. The lock ledger is mutated BEFORE any transfer-out on
 * release, so a malicious recipient cannot reenter a stale-locked state.
 */
contract StakeVault is ISTakeVault, ReentrancyGuard, Pausable, AccessControl, UntrackedAssetRecovery {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Roles
    // =========================================================================

    /// @notice Default admin of the vault.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Authorised module that may lock and release bonds.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Authorised account that may pause/unpause the vault.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =========================================================================
    // State
    // =========================================================================

    /// @notice The configured bond ERC20 token, set by the admin/operator.
    address private _bondToken;

    /// @notice Primary lock ledger keyed by lockId (== dispute id in the caller domain).
    mapping(uint256 => BondLock) private _locks;

    /// @notice Aggregate locked amount (decremented only on release).
    uint256 private _totalLocked;

    /// @dev Storage gap for upgradeability compatibility.
    uint256[48] private __gap;

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @param initialAdmin  Address receiving admin roles. Must be non-zero.
     * @param initialToken  Address of the bond ERC20 token. Must be non-zero.
     * @dev Grants DEFAULT_ADMIN_ROLE and ADMIN_ROLE to `initialAdmin`, and wires
     *      role administration:
     *        - OPERATOR_ROLE  is managed by ADMIN_ROLE.
     *        - PAUSER_ROLE    is managed by ADMIN_ROLE.
     */
    constructor(address initialAdmin, address initialToken) {
        if (initialAdmin == address(0)) revert ZeroAddress();
        if (initialToken == address(0)) revert ZeroAddress();

        _bondToken = initialToken;

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);

        _setRoleAdmin(OPERATOR_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
    }

    // =========================================================================
    // Write Functions — Operator
    // =========================================================================

    /**
     * @inheritdoc ISTakeVault
     */
    function lockBond(
        uint256 lockId,
        address token,
        address depositor,
        uint256 amount
    ) external override nonReentrant whenNotPaused onlyRole(OPERATOR_ROLE) {
        // Lock ids must not be reused, or the ledger would be overwritten and the
        // reconciliation invariant broken.
        if (_locks[lockId].lockId != 0) revert LockAlreadyExists(lockId);
        if (token == address(0) || depositor == address(0)) revert ZeroAddress();
        if (amount == 0) revert LockNotFound(lockId);

        // Custody: pull the bond into the vault. If the transfer fails (including
        // a non-reverting ERC20 that returns false), the whole operation reverts
        // and no lock record is written — "no bond lock without custody".
        IERC20(token).safeTransferFrom(depositor, address(this), amount);

        _increaseRecoveryReserve(token, amount);

        _locks[lockId] = BondLock({
            lockId: lockId,
            token: token,
            depositor: depositor,
            amount: amount,
            lockedAt: uint64(block.timestamp),
            released: false,
            releasedTo: address(0)
        });

        unchecked {
            _totalLocked += amount;
        }

        emit BondLocked(lockId, token, depositor, amount, msg.sender);
    }

    /**
     * @inheritdoc ISTakeVault
     */
    function releaseBond(uint256 lockId, address recipient) external override nonReentrant whenNotPaused onlyRole(OPERATOR_ROLE) {
        BondLock storage lock = _locks[lockId];
        if (lock.lockId == 0) revert LockNotFound(lockId);
        if (lock.released) revert LockAlreadyReleased(lockId);
        if (recipient == address(0)) revert ZeroAddress();

        uint256 amount = lock.amount;

        // Mark released BEFORE the external transfer so a reentrancy on a
        // malicious recipient cannot observe an active lock.
        lock.released = true;
        lock.releasedTo = recipient;

        unchecked {
            _totalLocked -= amount;
        }

        _decreaseRecoveryReserve(lock.token, amount);
        IERC20(lock.token).safeTransfer(recipient, amount);

        emit BondReleased(lockId, recipient, amount, msg.sender);
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /**
     * @notice Updates the configured bond token.
     * @param newToken New bond ERC20 address. Must be non-zero.
     * @dev Only affects the reported `bondToken()`; it does not migrate existing
     *      locks (each lock records its own token at lock time).
     */
    function setBondToken(address newToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newToken == address(0)) revert ZeroAddress();
        _bondToken = newToken;
    }

    /**
     * @notice Pauses locking and releasing.
     * @dev Emergency control; does not permit governance/treasury to release bonds,
     *      it only halts active dispute opening.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Resumes locking and releasing.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /**
     * @inheritdoc ISTakeVault
     */
    function bondToken() external view override returns (address token) {
        return _bondToken;
    }

    /**
     * @inheritdoc ISTakeVault
     */
    function getLock(uint256 lockId) external view override returns (BondLock memory lock) {
        return _locks[lockId];
    }

    /**
     * @inheritdoc ISTakeVault
     */
    function totalLocked() external view override returns (uint256 total) {
        return _totalLocked;
    }

    // V2-SC-154: additive recovery only; existing liability and authority paths remain authoritative.
    function _checkAssetRecoveryAuthority() internal view override {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function _requireAssetRecoveryAllowed() internal view override {
        if (paused()) revert RecoveryPaused();
    }

    function _reservedAssetBalance(address asset) internal view override returns (uint256) {
        return _recoveryReserved(asset);
    }
}
