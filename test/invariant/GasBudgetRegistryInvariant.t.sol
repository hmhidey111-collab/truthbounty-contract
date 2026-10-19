// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import {ProtocolExecutionBounds} from "../../contracts/performance/ProtocolExecutionBounds.sol";
import {GasBudgetRegistry} from "../../contracts/performance/GasBudgetRegistry.sol";
import {ICriticalPathGasBudgets} from "../../contracts/performance/ICriticalPathGasBudgets.sol";

/// @dev Drives GasBudgetRegistry with valid, invalid, and unauthorized configuration (V2-SC-072).
contract GasBudgetRegistryHandler is Test {
    uint256 internal constant OPERATION_COUNT = 12;

    GasBudgetRegistry public budgets;
    address public admin;

    /// @dev Expected on-chain budget per operation index; only moved by accepted admin updates.
    uint256[OPERATION_COUNT] public ghostBudget;
    uint256 public acceptedUpdates;
    uint256 public invalidAccepted;
    uint256 public unauthorizedAccepted;

    constructor(GasBudgetRegistry budgets_, address admin_) {
        budgets = budgets_;
        admin = admin_;
        for (uint256 i = 0; i < OPERATION_COUNT; ++i) {
            (ghostBudget[i],) = budgets.getBudget(ICriticalPathGasBudgets.Operation(i));
        }
    }

    function updateValid(uint256 opSeed, uint256 maxGas) external {
        uint256 op = opSeed % OPERATION_COUNT;
        maxGas = bound(maxGas, 1, ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING);

        vm.prank(admin);
        budgets.updateBudget(ICriticalPathGasBudgets.Operation(op), maxGas, "handler benchmark");
        ghostBudget[op] = maxGas;
        acceptedUpdates++;
    }

    function updateInvalid(uint256 opSeed, uint256 maxGas, uint8 mode) external {
        uint256 op = opSeed % OPERATION_COUNT;
        string memory description = "invalid";
        mode = mode % 3;
        if (mode == 0) {
            maxGas = 0;
        } else if (mode == 1) {
            maxGas = bound(maxGas, ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING + 1, type(uint256).max);
        } else {
            maxGas = bound(maxGas, 1, ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING);
            description = "";
        }

        vm.prank(admin);
        try budgets.updateBudget(ICriticalPathGasBudgets.Operation(op), maxGas, description) {
            invalidAccepted++;
        } catch {}
    }

    function updateUnauthorized(address caller, uint256 opSeed, uint256 maxGas) external {
        if (budgets.hasRole(budgets.BUDGET_ADMIN_ROLE(), caller)) return;
        uint256 op = opSeed % OPERATION_COUNT;
        maxGas = bound(maxGas, 1, ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING);

        vm.prank(caller);
        try budgets.updateBudget(ICriticalPathGasBudgets.Operation(op), maxGas, "unauthorized") {
            unauthorizedAccepted++;
        } catch {}
    }
}

contract GasBudgetRegistryInvariantTest is StdInvariant, Test {
    uint256 internal constant OPERATION_COUNT = 12;

    GasBudgetRegistry internal budgets;
    GasBudgetRegistryHandler internal handler;
    address internal admin = address(0xAD);

    function setUp() public {
        budgets = new GasBudgetRegistry(admin);
        handler = new GasBudgetRegistryHandler(budgets, admin);
        targetContract(address(handler));
    }

    /// @notice Every operation keeps a non-zero budget within the shared transaction ceiling.
    function invariant_everyBudgetWithinBounds() public view {
        assertEq(budgets.budgetCount(), OPERATION_COUNT);
        for (uint256 i = 0; i < OPERATION_COUNT; ++i) {
            (uint256 maxGas, string memory description) = budgets.getBudget(ICriticalPathGasBudgets.Operation(i));
            assertGt(maxGas, 0);
            assertLe(maxGas, ProtocolExecutionBounds.RECOMMENDED_TX_GAS_CEILING);
            assertGt(bytes(description).length, 0);
        }
    }

    /// @notice On-chain budgets only move through accepted admin updates.
    function invariant_budgetsMatchAcceptedAdminUpdates() public view {
        for (uint256 i = 0; i < OPERATION_COUNT; ++i) {
            (uint256 maxGas,) = budgets.getBudget(ICriticalPathGasBudgets.Operation(i));
            assertEq(maxGas, handler.ghostBudget(i));
        }
    }

    /// @notice Invalid configuration and unauthorized callers never succeed.
    function invariant_invalidAndUnauthorizedUpdatesFailClosed() public view {
        assertEq(handler.invalidAccepted(), 0);
        assertEq(handler.unauthorizedAccepted(), 0);
    }

    /// @notice The budget administrator set never changes through configuration traffic.
    function invariant_adminRoleUnchanged() public view {
        assertTrue(budgets.hasRole(budgets.BUDGET_ADMIN_ROLE(), admin));
        assertTrue(budgets.hasRole(budgets.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(budgets.hasRole(budgets.BUDGET_ADMIN_ROLE(), address(handler)));
    }
}
