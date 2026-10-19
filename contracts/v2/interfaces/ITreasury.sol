// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";

/// @notice Protocol treasury bucket accounting interface.
/// @dev The configured implementation owns the asset adapter and withdrawal authority; bucket accounting must be conserved and withdrawals fail closed when underfunded.
/// @dev Custody conservation accounting must reconcile tracked principal, rewards, fees, donations, and unexplained token deltas without double-counting.
interface ITreasury is IV2Module {
    /// @notice Emitted when funds enter a named bucket.
    /// @param from Account supplying funds.
    /// @param amount Amount deposited in asset base units.
    /// @param bucket Stable bucket identifier.
    event FundsDeposited(address indexed from, uint256 amount, bytes32 indexed bucket);

    /// @notice Emitted when funds leave a named bucket.
    /// @param to Account receiving funds.
    /// @param amount Amount withdrawn in asset base units.
    /// @param bucket Stable bucket identifier.
    event FundsWithdrawn(address indexed to, uint256 amount, bytes32 indexed bucket);

    /// @notice Emitted when an unexplained balance delta is detected during reconciliation.
    /// @param expected Expected tracked custody accounting total.
    /// @param actual Actual observed token balance.
    /// @param delta Signed unexplained delta (actual - expected).
    event UnexplainedDeltaDetected(uint256 expected, uint256 actual, int256 delta);

    /// @notice Emitted when an unexplained delta is routed into the governed recovery path.
    /// @param bucket Stable bucket identifier receiving the recovered amount.
    /// @param amount Amount routed into recovery in asset base units.
    event UnexplainedDeltaRecovered(bytes32 indexed bucket, uint256 amount);

    /// @notice Emitted when a bucket is credited from a non-principal accounting component.
    /// @param bucket Stable bucket identifier.
    /// @param component Accounting component key (e.g. rewards, fees, donations).
    /// @param amount Amount credited in asset base units.
    event AccountingComponentCredited(bytes32 indexed bucket, bytes32 indexed component, uint256 amount);

    /// @notice Deposits caller funds into a configured bucket.
    /// @dev Must validate bucket existence, adapter, positive amount, and exact received balance before crediting accounting.
    /// @dev Must credit tracked principal by the exact received delta and must not double-count fee-on-transfer or rebasing effects.
    /// @param bucket Stable bucket identifier.
    /// @param amount Amount to deposit in asset base units.
    function deposit(bytes32 bucket, uint256 amount) external;

    /// @notice Withdraws funds from a bucket under the treasury authority.
    /// @dev Must prevent withdrawal of reserved obligations and revert atomically if the configured external token call fails.
    /// @dev Must debit tracked principal by the exact sent amount and must not create or lose accounted principal.
    /// @param bucket Stable bucket identifier.
    /// @param to Authorized destination.
    /// @param amount Amount to withdraw in asset base units.
    function withdraw(bytes32 bucket, address to, uint256 amount) external;

    /// @notice Reconciles tracked custody against the actual adapter balance.
    /// @dev Must compare the sum of documented accounting components (tracked principal, rewards, fees, donations) to the observed token balance.
    /// @dev Unexplained deltas must either revert with ConservationInvariantViolation or enter the governed recovery path without double-counting.
    /// @return expected Sum of documented accounting components.
    /// @return actual Observed adapter token balance.
    function reconcile() external returns (uint256 expected, uint256 actual);

    /// @notice Routes an unexplained balance delta into the governed recovery path.
    /// @dev Must only be callable under the configured governance authority and must not double-count any tracked component.
    /// @param bucket Stable bucket identifier receiving the recovered amount.
    /// @param amount Amount to route in asset base units.
    function recoverUnexplainedDelta(bytes32 bucket, uint256 amount) external;

    /// @notice Reads the accounted balance of one bucket in the configured treasury asset.
    /// @param bucket Stable bucket identifier.
    /// @return amount Accounted amount in asset base units.
    function balanceOf(bytes32 bucket) external view returns (uint256 amount);

    /// @notice Reads the documented accounting component total for a bucket.
    /// @param bucket Stable bucket identifier.
    /// @return principal Tracked principal component.
    /// @return rewards Tracked rewards component.
    /// @return fees Tracked fees component.
    /// @return donations Tracked donations component.
    function accountingComponents(bytes32 bucket)
        external
        view
        returns (uint256 principal, uint256 rewards, uint256 fees, uint256 donations);
}
