// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ICriticalPathGasBudgets} from "./ICriticalPathGasBudgets.sol";
import {ProtocolExecutionBounds} from "./ProtocolExecutionBounds.sol";

/**
 * @title GasBudgetRegistry
 * @notice Published gas budgets for critical-path operations at maximum configuration.
 * @dev Budgets are conservative upper bounds used by CI regression checks. Values include
 *      headroom above measured baselines documented in docs/gas-bounded-execution-v2-sc-038.md.
 */
contract GasBudgetRegistry is ICriticalPathGasBudgets, AccessControl {
    bytes32 public constant BUDGET_ADMIN_ROLE = keccak256("BUDGET_ADMIN_ROLE");

    mapping(Operation => GasBudget) private _budgets;

    event GasBudgetUpdated(Operation indexed operation, uint256 maxGasAtMaxConfig, string boundDescription);

    error UnknownOperation(Operation operation);
    error ZeroAdmin();
    /// @notice Thrown when a budget of zero gas is configured for an operation.
    error ZeroGasBudget(Operation operation);
    error EmptyBudgetDescription();
    error GasBudgetExceedsTransactionCeiling(uint256 budget, uint256 ceiling);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAdmin();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BUDGET_ADMIN_ROLE, admin);
        _seedDefaults();
    }

    function _seedDefaults() internal {
        _set(
            Operation.CLAIM_CREATION,
            350_000,
            "ClaimRegistry.createClaim at max statement/CID bounds"
        );
        _set(
            Operation.EVIDENCE_ATTACHMENT,
            180_000,
            "EvidenceManager.addEvidence at MAX_CID_LENGTH"
        );
        _set(
            Operation.VERIFICATION_VOTE,
            350_000,
            "TruthBountyWeighted.vote with reputation snapshot"
        );
        _set(
            Operation.AGGREGATION,
            600_000,
            "VerificationAggregation.aggregateClaim at MAX_VERIFIERS_PER_CLAIM"
        );
        _set(
            Operation.PROVISIONAL_SETTLEMENT,
            250_000,
            "PullSettlementLedger.credit single beneficiary"
        );
        _set(
            Operation.CHALLENGE_OPEN,
            120_000,
            "ClaimLifecycle dispute open transition"
        );
        _set(
            Operation.APPEAL_SETTLEMENT,
            650_000,
            "Appeal-round aggregation + threshold evaluation"
        );
        _set(
            Operation.FINALIZATION,
            200_000,
            "Claim finalization status transition"
        );
        _set(
            Operation.WITHDRAWAL,
            120_000,
            "PullSettlementLedger.withdraw pull payout"
        );
        _set(
            Operation.REWARD_CLAIM,
            450_000,
            "RewardEngine.claimReward with ERC20 payout"
        );
        _set(
            Operation.GOVERNANCE_CONFIGURATION,
            120_000,
            "GasBudgetRegistry.updateBudget role-gated configuration"
        );
        _set(
            Operation.EMERGENCY_PAUSE,
            180_000,
            "EmergencyController.activatePause with audit record"
        );
    }

    function _set(Operation operation, uint256 maxGas, string memory description) internal {
        if (maxGas == 0) revert ZeroGasBudget(operation);
        if (maxGas >ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING) {
            revert GasBudgetExceedsTransactionCeiling(maxGas, ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING);
        }
        if (bytes(description).length == 0) revert EmptyBudgetDescription();
        _budgets[operation] = GasBudget({operation: operation, maxGasAtMaxConfig: maxGas, boundDescription: description});
        emit GasBudgetUpdated(operation, maxGas, description);
    }

    /// @inheritdoc ICriticalPathGasBudgets
    function getBudget(Operation operation)
        external
        view
        returns (uint256 maxGasAtMaxConfig, string memory boundDescription)
    {
        GasBudget storage budget = _budgets[operation];
        if (bytes(budget.boundDescription).length == 0) revert UnknownOperation(operation);
        return (budget.maxGasAtMaxConfig, budget.boundDescription);
    }

    /// @inheritdoc ICriticalPathGasBudgets
    function budgetCount() external pure returns (uint256) {
        return 12;
    }

    /**
     * @notice Updates the ceiling and maximum-configuration description for a critical path.
     * @param operation The operation whose enforced budget is being updated.
     * @param maxGasAtMaxConfig Maximum permitted gas under the documented maximum configuration.
     * @param boundDescription Description of the configuration used for the benchmark.
     * @dev Only the budget administrator may change a budget. Zero or over-ceiling budgets and
     *      blank descriptions revert so CI cannot silently accept an incomplete configuration.
     */
    function updateBudget(
        Operation operation,
        uint256 maxGasAtMaxConfig,
        string calldata boundDescription
    ) external onlyRole(BUDGET_ADMIN_ROLE) {
        _set(operation, maxGasAtMaxConfig, boundDescription);
    }
}
