// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProtocolExecutionBounds} from "../contracts/performance/ProtocolExecutionBounds.sol";
import {GasBudgetRegistry} from "../contracts/performance/GasBudgetRegistry.sol";
import {PullSettlementLedger} from "../contracts/performance/PullSettlementLedger.sol";
import {LoopBoundsCatalog} from "../contracts/performance/LoopBoundsCatalog.sol";
import {ICriticalPathGasBudgets} from "../contracts/performance/ICriticalPathGasBudgets.sol";
import {MockERC20} from "../contracts/MockERC20.sol";
import {HostileTokenRecipient, HostileERC20} from "../contracts/mocks/HostileTokenRecipient.sol";
import {EmergencyController} from "../contracts/governance/EmergencyController.sol";

contract GasBoundedExecutionTest is Test {
    GasBudgetRegistry internal budgets;
    PullSettlementLedger internal ledger;
    MockERC20 internal token;
    LoopBoundsCatalog internal catalog;

    address internal userA = address(0xA);
    address internal userB = address(0xB);

    function setUp() public {
        budgets = new GasBudgetRegistry(address(this));
        token = new MockERC20("Test", "TST");
        ledger = new PullSettlementLedger(address(this), token);
        catalog = new LoopBoundsCatalog();
        token.mint(address(ledger), 1_000_000 ether);
    }

    function test_MaxSettlementBatchBoundEnforced() public {
        address[] memory beneficiaries = new address[](ProtocolExecutionBounds.MAX_SETTLEMENT_BATCH_SIZE + 1);
        uint256[] memory amounts = new uint256[](ProtocolExecutionBounds.MAX_SETTLEMENT_BATCH_SIZE + 1);
        for (uint256 i = 0; i < beneficiaries.length; ++i) {
            beneficiaries[i] = address(uint160(0x1000 + i));
            amounts[i] = 1 ether;
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                PullSettlementLedger.BatchTooLarge.selector,
                beneficiaries.length,
                ProtocolExecutionBounds.MAX_SETTLEMENT_BATCH_SIZE
            )
        );
        ledger.creditBatch(beneficiaries, amounts, bytes32("batch"));
    }

    function test_HostileRecipientDoesNotBlockOtherWithdrawals() public {
        HostileERC20 hostileToken = new HostileERC20();
        PullSettlementLedger hostileLedger = new PullSettlementLedger(address(this), IERC20(address(hostileToken)));
        hostileToken.mint(address(hostileLedger), 100 ether);

        HostileTokenRecipient hostile = new HostileTokenRecipient();
        hostileLedger.credit(address(hostile), 5 ether, bytes32("h"));
        hostileLedger.credit(userB, 5 ether, bytes32("u"));

        vm.prank(userB);
        hostileLedger.withdraw(5 ether);
        assertEq(hostileToken.balanceOf(userB), 5 ether);

        vm.prank(address(hostile));
        vm.expectRevert();
        hostileLedger.withdraw(5 ether);
    }

    function test_PullCreditDoesNotTransferTokens() public {
        ledger.credit(userA, 25 ether, bytes32("ref"));
        assertEq(token.balanceOf(address(ledger)), 1_000_000 ether);
        assertEq(ledger.availableBalance(userA), 25 ether);
    }

    function test_GasBudgetsSeededForAllCriticalPaths() public view {
        assertEq(budgets.budgetCount(), 12);
        for (uint256 i = 0; i < 12; ++i) {
            (uint256 maxGas,) = budgets.getBudget(ICriticalPathGasBudgets.Operation(i));
            assertGt(maxGas, 0);
            assertLe(maxGas, ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING);
        }
    }

    function test_LoopCatalogDocumentsBounds() public view {
        assertEq(catalog.catalogSize(), 14);
        LoopBoundsCatalog.LoopBound memory first = catalog.getLoopBound(0);
        assertEq(first.maxIterations, ProtocolExecutionBounds.MAX_VERIFIERS_PER_CLAIM);
    }

    function test_WithdrawalGasWithinBudget() public {
        ledger.credit(userA, 1 ether, bytes32("gas"));
        (uint256 budget,) = budgets.getBudget(ICriticalPathGasBudgets.Operation.WITHDRAWAL);

        vm.prank(userA);
        uint256 gasBefore = gasleft();
        ledger.withdraw(1 ether);
        uint256 gasUsed = gasBefore - gasleft();
        assertLe(gasUsed, budget);
    }

    function test_GovernanceConfigurationGasWithinBudget() public {
        (uint256 budget,) = budgets.getBudget(ICriticalPathGasBudgets.Operation.GOVERNANCE_CONFIGURATION);

        uint256 gasBefore = gasleft();
        budgets.updateBudget(
            ICriticalPathGasBudgets.Operation.GOVERNANCE_CONFIGURATION,
            budget,
            "GasBudgetRegistry.updateBudget role-gated configuration"
        );
        assertLe(gasBefore - gasleft(), budget);
    }

    function test_EmergencyPauseGasWithinBudget() public {
        EmergencyController controller = new EmergencyController(userA, address(this), userB);
        (uint256 budget,) = budgets.getBudget(ICriticalPathGasBudgets.Operation.EMERGENCY_PAUSE);

        vm.prank(userA);
        uint256 gasBefore = gasleft();
        controller.activatePause(controller.LEVEL_HIGH_RISK(), "gas-budget", bytes32("gas"));
        assertLe(gasBefore - gasleft(), budget);
    }

    function test_UpdateBudgetRejectsUnauthorizedCaller() public {
        vm.prank(userA);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                userA,
                budgets.BUDGET_ADMIN_ROLE()
            )
        );
        budgets.updateBudget(
            ICriticalPathGasBudgets.Operation.REWARD_CLAIM,
            1,
            "unauthorized"
        );
    }

    function test_UpdateBudgetRejectsCeilingAndEmptyDescription() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                GasBudgetRegistry.GasBudgetExceedsTransactionCeiling.selector,
                ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING + 1,
                ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING
            )
        );
        budgets.updateBudget(
            ICriticalPathGasBudgets.Operation.REWARD_CLAIM,
            ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING + 1,
            "over ceiling"
        );

        vm.expectRevert(GasBudgetRegistry.EmptyBudgetDescription.selector);
        budgets.updateBudget(ICriticalPathGasBudgets.Operation.REWARD_CLAIM, 1, "");
    }

    function test_UpdateBudgetRejectsZeroBudget() public {
        (uint256 before,) = budgets.getBudget(ICriticalPathGasBudgets.Operation.REWARD_CLAIM);

        vm.expectRevert(
            abi.encodeWithSelector(
                GasBudgetRegistry.ZeroGasBudget.selector,
                ICriticalPathGasBudgets.Operation.REWARD_CLAIM
            )
        );
        budgets.updateBudget(ICriticalPathGasBudgets.Operation.REWARD_CLAIM, 0, "zero budget");

        (uint256 afterUpdate,) = budgets.getBudget(ICriticalPathGasBudgets.Operation.REWARD_CLAIM);
        assertEq(afterUpdate, before);
    }

    function test_UpdateBudgetAcceptsCeilingBoundary() public {
        budgets.updateBudget(
            ICriticalPathGasBudgets.Operation.APPEAL_SETTLEMENT,
            ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING,
            "ceiling boundary"
        );
        (uint256 maxGas,) = budgets.getBudget(ICriticalPathGasBudgets.Operation.APPEAL_SETTLEMENT);
        assertEq(maxGas, ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING);
    }

    function test_ZeroAdminDeploymentFailsClosed() public {
        vm.expectRevert(GasBudgetRegistry.ZeroAdmin.selector);
        new GasBudgetRegistry(address(0));
    }

    function test_CreditBatchAtMaxBoundSucceeds() public {
        uint256 max = ProtocolExecutionBounds.MAX_SETTLEMENT_BATCH_SIZE;
        address[] memory beneficiaries = new address[](max);
        uint256[] memory amounts = new uint256[](max);
        for (uint256 i = 0; i < max; ++i) {
            beneficiaries[i] = address(uint160(0x2000 + i));
            amounts[i] = 1;
        }
        ledger.creditBatch(beneficiaries, amounts, bytes32("max"));
        assertEq(ledger.availableBalance(beneficiaries[0]), 1);
    }
}
