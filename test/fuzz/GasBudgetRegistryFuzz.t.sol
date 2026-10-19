// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ProtocolExecutionBounds} from "../../contracts/performance/ProtocolExecutionBounds.sol";
import {GasBudgetRegistry} from "../../contracts/performance/GasBudgetRegistry.sol";
import {ICriticalPathGasBudgets} from "../../contracts/performance/ICriticalPathGasBudgets.sol";

/// @dev Fuzz coverage for per-operation gas budget configuration (V2-SC-072).
contract GasBudgetRegistryFuzzTest is Test {
    event GasBudgetUpdated(
        ICriticalPathGasBudgets.Operation indexed operation, uint256 maxGasAtMaxConfig, string boundDescription
    );

    GasBudgetRegistry internal budgets;
    uint256 internal constant OPERATION_COUNT = 12;

    function setUp() public {
        budgets = new GasBudgetRegistry(address(this));
    }

    function _op(uint256 seed) internal pure returns (ICriticalPathGasBudgets.Operation) {
        return ICriticalPathGasBudgets.Operation(seed % OPERATION_COUNT);
    }

    function testFuzz_AdminUpdateWithinCeilingIsStored(uint256 opSeed, uint256 maxGas) public {
        ICriticalPathGasBudgets.Operation operation = _op(opSeed);
        maxGas = bound(maxGas, 1, ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING);

        vm.expectEmit(true, false, false, true, address(budgets));
        emit GasBudgetUpdated(operation, maxGas, "fuzzed benchmark");
        budgets.updateBudget(operation, maxGas, "fuzzed benchmark");

        (uint256 stored, string memory description) = budgets.getBudget(operation);
        assertEq(stored, maxGas);
        assertEq(description, "fuzzed benchmark");
    }

    function testFuzz_UpdateOnlyTouchesTargetOperation(uint256 opSeed, uint256 maxGas) public {
        ICriticalPathGasBudgets.Operation operation = _op(opSeed);
        maxGas = bound(maxGas, 1, ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING);

        uint256[OPERATION_COUNT] memory before;
        for (uint256 i = 0; i < OPERATION_COUNT; ++i) {
            (before[i],) = budgets.getBudget(ICriticalPathGasBudgets.Operation(i));
        }

        budgets.updateBudget(operation, maxGas, "isolated");

        for (uint256 i = 0; i < OPERATION_COUNT; ++i) {
            if (i == uint256(operation)) continue;
            (uint256 current,) = budgets.getBudget(ICriticalPathGasBudgets.Operation(i));
            assertEq(current, before[i]);
        }
    }

    function testFuzz_AboveCeilingFailsClosed(uint256 opSeed, uint256 maxGas) public {
        ICriticalPathGasBudgets.Operation operation = _op(opSeed);
        maxGas = bound(maxGas, ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING + 1, type(uint256).max);
        (uint256 before,) = budgets.getBudget(operation);

        vm.expectRevert(
            abi.encodeWithSelector(
                GasBudgetRegistry.GasBudgetExceedsTransactionCeiling.selector,
                maxGas,
                ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING
            )
        );
        budgets.updateBudget(operation, maxGas, "over ceiling");

        (uint256 current,) = budgets.getBudget(operation);
        assertEq(current, before);
    }

    function testFuzz_ZeroBudgetFailsClosed(uint256 opSeed) public {
        ICriticalPathGasBudgets.Operation operation = _op(opSeed);

        vm.expectRevert(abi.encodeWithSelector(GasBudgetRegistry.ZeroGasBudget.selector, operation));
        budgets.updateBudget(operation, 0, "zero");
    }

    function testFuzz_NonAdminCannotUpdate(address caller, uint256 opSeed, uint256 maxGas) public {
        bytes32 role = budgets.BUDGET_ADMIN_ROLE();
        vm.assume(!budgets.hasRole(role, caller));
        ICriticalPathGasBudgets.Operation operation = _op(opSeed);
        maxGas = bound(maxGas, 1, ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING);
        (uint256 before,) = budgets.getBudget(operation);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role)
        );
        vm.prank(caller);
        budgets.updateBudget(operation, maxGas, "unauthorized");

        (uint256 current,) = budgets.getBudget(operation);
        assertEq(current, before);
    }

    function testFuzz_UnknownOperationIdentifierReverts(uint256 rawOperation) public {
        rawOperation = bound(rawOperation, OPERATION_COUNT, type(uint256).max);

        (bool ok,) = address(budgets).staticcall(
            abi.encodeWithSelector(ICriticalPathGasBudgets.getBudget.selector, rawOperation)
        );
        assertFalse(ok);

        (ok,) = address(budgets).call(
            abi.encodeWithSelector(GasBudgetRegistry.updateBudget.selector, rawOperation, uint256(1), "unknown")
        );
        assertFalse(ok);
    }
}
