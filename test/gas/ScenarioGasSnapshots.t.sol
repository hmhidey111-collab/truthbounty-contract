// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {GasBudgetRegistry} from "../../contracts/performance/GasBudgetRegistry.sol";
import {ProtocolExecutionBounds} from "../../contracts/performance/ProtocolExecutionBounds.sol";
import {ICriticalPathGasBudgets} from "../../contracts/performance/ICriticalPathGasBudgets.sol";
import {PullSettlementLedger} from "../../contracts/performance/PullSettlementLedger.sol";
import {MockERC20} from "../../contracts/MockERC20.sol";
import {GovernanceController} from "../../contracts/governance/GovernanceController.sol";
import {ProtocolUpgradeManager} from "../../contracts/upgrade/ProtocolUpgradeManager.sol";

contract ScenarioGasSnapshotsTest is Test {
    GasBudgetRegistry internal budgets;
    PullSettlementLedger internal ledger;
    ProtocolUpgradeManager internal upgradeManager;
    MockERC20 internal currentImplementation;
    MockERC20 internal candidateImplementation;

    function setUp() public {
        budgets = new GasBudgetRegistry(address(this));
        MockERC20 token = new MockERC20("Scenario Token", "SGT");
        ledger = new PullSettlementLedger(address(this), token);
        token.mint(address(ledger), 1_000_000 ether);

        GovernanceController governance = new GovernanceController(address(this));
        upgradeManager = new ProtocolUpgradeManager(address(this), address(governance));
        currentImplementation = new MockERC20("Current", "CUR");
        candidateImplementation = new MockERC20("Candidate", "CAN");
    }

    function test_gas_registryReadCold() public view {
        budgets.getBudget(ICriticalPathGasBudgets.Operation.REWARD_CLAIM);
    }

    function test_gas_registryReadWarm() public view {
        budgets.getBudget(ICriticalPathGasBudgets.Operation.REWARD_CLAIM);
        budgets.getBudget(ICriticalPathGasBudgets.Operation.REWARD_CLAIM);
    }

    function test_gas_registryUpdateFirst() public {
        budgets.updateBudget(
            ICriticalPathGasBudgets.Operation.REWARD_CLAIM,
            450_000,
            "SC-064 scenario baseline"
        );
    }

    function test_gas_registryUpdateRepeat() public {
        budgets.updateBudget(
            ICriticalPathGasBudgets.Operation.REWARD_CLAIM,
            450_000,
            "SC-064 scenario baseline"
        );
        budgets.updateBudget(
            ICriticalPathGasBudgets.Operation.REWARD_CLAIM,
            450_000,
            "SC-064 scenario baseline"
        );
    }

    function test_gas_settlementBatchAtMaximumBound() public {
        uint256 length = ProtocolExecutionBounds.MAX_SETTLEMENT_BATCH_SIZE;
        address[] memory beneficiaries = new address[](length);
        uint256[] memory amounts = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            beneficiaries[i] = address(uint160(0x1000 + i));
            amounts[i] = 1 ether;
        }

        ledger.creditBatch(beneficiaries, amounts, keccak256("SC064 max batch"));
        assertEq(ledger.availableBalance(beneficiaries[0]), 1 ether);
    }

    function test_gas_settlementBatchOverMaximumReverts() public {
        uint256 length = ProtocolExecutionBounds.MAX_SETTLEMENT_BATCH_SIZE + 1;
        address[] memory beneficiaries = new address[](length);
        uint256[] memory amounts = new uint256[](length);

        vm.expectRevert(
            abi.encodeWithSelector(
                PullSettlementLedger.BatchTooLarge.selector,
                length,
                ProtocolExecutionBounds.MAX_SETTLEMENT_BATCH_SIZE
            )
        );
        ledger.creditBatch(beneficiaries, amounts, keccak256("SC064 oversized batch"));
    }

    function test_gas_upgradeProposal() public {
        bytes32 moduleId = keccak256("SC064_MODULE");
        bytes32 layoutHash = keccak256("SC064_LAYOUT");

        upgradeManager.registerModule(
            moduleId,
            address(currentImplementation),
            ProtocolUpgradeManager.Version(1, 0, 0),
            layoutHash
        );
        uint256 proposalId = upgradeManager.proposeUpgrade(
            moduleId,
            address(candidateImplementation),
            ProtocolUpgradeManager.Version(1, 1, 0),
            layoutHash,
            bytes32(0),
            "SC-064 gas scenario"
        );
        assertEq(proposalId, 1);
    }
}
