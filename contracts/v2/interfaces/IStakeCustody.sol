// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";
import {IV2Types} from "./IV2Types.sol";

/// @notice Canonical V2 stake custody interface.
/// @dev Primary stake is tracked at round zero. Settlement hooks are restricted to the registered settlement module, and every transition is checked against exact lock accounting and recorded idempotency state.
/// @dev Conservation invariants (enforced by implementation and verified by the stateful Foundry suite):
///   - Accounted balances reconcile after every generated sequence:
///       tokenBŰalance(this) >= sum(locked) + sum(claimable) + protocolAllocation.
///   - No participant can claim or withdraw more than authorized.
///   - Rounding policy is explicit and bounded: all amounts are integer base units, no division is performed in custody, and any remainder stays in protocolAllocation rather than being stranded or duplicated.
///   - Unsupported token behavior (fee-on-transfer, rebasing, non-standard ERC-20) fails safely by reverting on inexact deltas.
interface IStakeCustody is IV2Module {
    /// @notice Emitted when a verifier deposits primary stake.
    /// @param account Account whose balance was credited.
    /// @param claimId Claim receiving the stake.
    /// @param amount Amount in staking-token base units.
    /// @param timestamp Block timestamp the credit was applied.
    /// @param version Event schema version.
    event StakeDeposited(address indexed account, uint256 indexed claimId, uint256 amount, uint64 timestamp, uint16 version);

    /// @notice Emitted when authorized custody logic releases primary stake to claimable balance.
    /// @param account Account receiving claimable credit.
    /// @param claimId Claim whose stake was released.
    /// @param amount Amount in staking-token base units.
    /// @param timestamp Block timestamp the credit was applied.
    /// @param version Event schema version.
    event StakeReleased(address indexed account, uint256 indexed claimId, uint256 amount, uint64 timestamp, uint16 version);

    /// @notice Emitted when authorized custody logic converts locked stake to protocol allocation.
    /// @param account Account whose locked stake was reduced.
    /// @param claimId Claim whose stake was slashed.
    /// @param amount Amount in staking-token base units.
    /// @param reason Stable slash reason code.
    /// @param timestamp Block timestamp the slash was applied.
    /// @param version Event schema version.
    event StakeSlashed(address indexed account, uint256 indexed claimId, uint256 amount, bytes32 indexed reason, uint64 timestamp, uint16 version);

    /// @notice Emitted when a conclusive settlement converts frozen principal into claimable principal and reward.
    /// @param asset ERC-20 asset address.
    /// @param account Account receiving principal and reward credit.
    /// @param claimId Settled claim.
    /// @param round Settlement round.
    /// @param principalAmount Principal unlocked in asset base units.
    /// @param rewardAmount Reward credited in asset base units.
    /// @param timestamp Block timestamp the settlement was applied.
    /// @param version Event schema version.
    event VaultSettledConclusive(address indexed asset, address indexed account, uint256 indexed claimId, uint256 round, uint256 principalAmount, uint256 rewardAmount, uint64 timestamp, uint16 version);

    /// @notice Emitted when an inconclusive round refunds frozen principal back to the account.
    /// @param asset ERC-20 asset address.
    /// @param account Account receiving refundable credit.
    /// @param claimId Refunded claim.
    /// @param round Settlement round.
    /// @param amount Amount in asset base units.
    /// @param timestamp Block timestamp the refund was applied.
    /// @param version Event schema version.
    event VaultRefundedInconclusive(address indexed asset, address indexed account, uint256 indexed claimId, uint256 round, uint256 amount, uint64 timestamp, uint16 version);

    /// @notice Emitted when an appeal carries a lock forward to the next round.
    /// @param asset ERC-20 asset address.
    /// @param account Account retaining the lock.
    /// @param claimId Carried claim.
    /// @param fromRound Source round.
    /// @param toRound Destination round.
    /// @param amount Amount in asset base units.
    /// @param timestamp Block timestamp the carry was applied.
    /// @param version Event schema version.
    event VaultCarriedForward(address indexed asset, address indexed account, uint256 indexed claimId, uint256 fromRound, uint256 toRound, uint256 amount, uint64 timestamp, uint16 version);

    /// @notice Emitted when a round rolls a lock forward without settlement.
    /// @param asset ERC-20 asset address.
    /// @param account Account retaining the lock.
    /// @param claimId Rolled claim.
    /// @param fromRound Source round.
    /// @param toRound Destination round.
    /// @param amount Amount in asset base units.
    /// @param timestamp Block timestamp the rollover was applied.
    /// @param version Event schema version.
    event VaultRolledOver(address indexed asset, address indexed account, uint256 indexed claimId, uint256 fromRound, uint256 toRound, uint256 amount, uint64 timestamp, uint16 version);

    /// @notice Emitted when a lock is finally unlocked to claimable balance.
    /// @param asset ERC-20 asset address.
    /// @param account Account receiving claimable credit.
    /// @param claimId Unlocked claim.
    /// @param round Finalized round.
    /// @param amount Amount in asset base units.
    /// @param timestamp Block timestamp the unlock was applied.
    /// @param version Event schema version.
    event VaultFinalUnlocked(address indexed asset, address indexed account, uint256 indexed claimId, uint256 round, uint256 amount, uint64 timestamp, uint16 version);

    /// @notice Deposits caller funds and locks them as verifier principal for a claim.
    /// @dev Pulls the exact configured staking token amount; fee-on-transfer or otherwise inexact deposits revert. Reverts on unsupported asset, zero amount, or reconciliation failure.
    /// @param claimId Claim receiving the primary stake.
    /// @param amount Amount in staking-token base units.
    function depositStake(uint256 claimId, uint256 amount) external;

    /// @notice Releases authorized verifier principal from custody to claimable balance.
    /// @dev Only the registered slashing, settlement, or verification module (or an explicit governance mutator) may call; never releases another caller's funds.
    /// @param claimId Claim whose stake is released.
    /// @param account Account whose lock is released.
    /// @param amount Amount in staking-token base units.
    function releaseStake(uint256 claimId, address account, uint256 amount) external;

    /// @notice Slashes authorized verifier principal into protocol allocation.
    /// @dev Only the registered slashing, settlement, or verification module (or an explicit governance mutator) may call; the operation is bounded by the account's locked balance and remains fail-closed.
    /// @param claimId Claim whose stake is slashed.
    /// @param account Account whose lock is reduced.
    /// @param amount Amount in staking-token base units.
    /// @param reason Stable slash reason code.
    function slashStake(uint256 claimId, address account, uint256 amount, bytes32 reason) external;

    /// @notice Reads an account's primary verifier stake for a claim.
    /// @param claimId Claim to inspect.
    /// @param account Account to inspect.
    /// @return amount Locked primary stake in staking-token base units.
    function staked(uint256 claimId, address account) external view returns (uint256 amount);

    /// @notice Reads aggregate primary verifier stake for a claim.
    /// @param claimId Claim to inspect.
    /// @return amount Aggregate locked primary stake in staking-token base units.
    function totalStaked(uint256 claimId) external view returns (uint256 amount);

    /// @notice Converts frozen verifier principal into claimable principal and credits protocol-funded reward.
    /// @dev Registered settlement module only. Idempotent per `(claimId, round)`; insufficient protocol allocation or locked principal reverts the entire transition.
    /// @param asset ERC-20 settlement asset.
    /// @param account Account receiving the settlement.
    /// @param claimId Claim being settled.
    /// @param round Settlement round.
    /// @param principalAmount Principal to unlock in asset base units.
    /// @param rewardAmount Reward to credit from protocol allocation in asset base units.
    function settleConclusive(address asset, address account, uint256 claimId, uint256 round, uint256 principalAmount, uint256 rewardAmount) external;

    /// @notice Converts frozen principal back to claimable balance after an inconclusive round.
    /// @dev Registered settlement module only. Idempotent per `(claimId, round)` and cannot overdraw the lock.
    /// @param asset ERC-20 settlement asset.
    /// @param account Account receiving the refund.
    /// @param claimId Claim being refunded.
    /// @param round Settlement round.
    /// @param amount Amount in asset base units.
    function refundInconclusive(address asset, address account, uint256 claimId, uint256 round, uint256 amount) external;

    /// @notice Moves locked principal to a later round for an appeal.
    /// @dev Registered settlement module only. Idempotent per `(claimId, fromRound)`; the destination round must be later than the source and must not have a recorded settlement outcome, while total custody is unchanged.
    /// @param asset ERC-20 settlement asset.
    /// @param account Account retaining the lock.
    /// @param claimId Claim under appeal.
    /// @param fromRound Source round.
    /// @param toRound Destination round.
    /// @param amount Amount in asset base units.
    function carryForwardAppeal(address asset, address account, uint256 claimId, uint256 fromRound, uint256 toRound, uint256 amount) external;

    /// @notice Moves locked principal to the next round without settlement.
    /// @dev Registered settlement module only. Idempotent per `(claimId, fromRound)`; the destination round must be later than the source and must not have a recorded settlement outcome, while total custody and protocol allocation are unchanged.
    /// @param asset ERC-20 settlement asset.
    /// @param account Account retaining the lock.
    /// @param claimId Claim being rolled.
    /// @param fromRound Source round.
    /// @param toRound Destination round.
    /// @param amount Amount in asset base units.
    function rolloverRound(address asset, address account, uint256 claimId, uint256 fromRound, uint256 toRound, uint256 amount) external;

    /// @notice Releases a remaining lock to claimable balance as the final round action.
    /// @dev Registered settlement module only. Idempotent per `(claimId, round)` and cannot overdraw the lock.
    /// @param asset ERC-20 settlement asset.
    /// @param account Account receiving the unlock.
    /// @param claimId Claim being unlocked.
    /// @param round Finalized round.
    /// @param amount Amount in asset base units.
    function finalUnlock(address asset, address account, uint256 claimId, uint256 round, uint256 amount) external;

    /// @notice Returns the recorded settlement outcome for a claim-round.
    /// @param claimId Claim to inspect.
    /// @param round Settlement round.
    /// @return outcome Recorded outcome, or `NONE` if no action has been recorded.
    function settlementOutcome(uint256 claimId, uint256 round) external view returns (IV2Types.SettlementOutcome outcome);
}
