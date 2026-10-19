// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ITreasuryInsolvencyModel } from "../../contracts/treasury/ITreasuryInsolvencyModel.sol";
import { TreasuryInsolvencyModel } from "../../contracts/treasury/TreasuryInsolvencyModel.sol";

/**
 * @title TreasuryInsolvencyHandler
 * @notice Stateful handler for the V2-SC-107 model invariant suite.
 *
 * Each public action builds a structurally-valid input and drives the model.
 * Ghost variables mirror expected state so invariants can compare without
 * assuming anything about storage layout.
 */
contract TreasuryInsolvencyHandler is Test {
    TreasuryInsolvencyModel public model;
    address public modeler;

    // ── Ghost variables ───────────────────────────────────────────────────────

    /// @notice Successful `runModel` invocations.
    uint256 public ghost_runSuccesses;
    /// @notice Successful `reconcile` invocations.
    uint256 public ghost_reconcileSuccesses;
    /// @notice Reverted `reconcile` invocations.
    uint256 public ghost_reconcileFailures;
    /// @notice Set if a second reconciliation of the same base report ever succeeded.
    bool public ghost_replaySucceeded;

    /// @notice Every persisted report id, in insertion order.
    bytes32[] public reportIds;

    /// @notice Reports that still carry deferred obligations.
    bytes32[] internal _candidates;

    constructor(TreasuryInsolvencyModel _model, address _modeler) {
        model = _model;
        modeler = _modeler;
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function reportIdCount() external view returns (uint256) {
        return reportIds.length;
    }

    function candidateCount() external view returns (uint256) {
        return _candidates.length;
    }

    // ── Handler actions ───────────────────────────────────────────────────────

    /// @notice Insufficient-liquidity run under a pro-rata or waterfall policy.
    function runInsolvent(uint96 liquidity, uint96 senior, uint96 junior, bool waterfall) external {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = ITreasuryInsolvencyModel.InsolvencyInput({
            scenario: ITreasuryInsolvencyModel.Scenario.INSUFFICIENT_LIQUIDITY,
            policy: waterfall
                ? ITreasuryInsolvencyModel.AllocationPolicy.PRIORITY_WATERFALL
                : ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            availableByPool: _pool(0, uint256(liquidity)),
            obligations: _pair(uint256(senior) + 1, uint256(junior) + 1),
            allocationCap: 0,
            recoveryInjection: 0,
            paused: false
        });

        _run(input);
    }

    /// @notice Emergency-pause run: allocations frozen.
    function runPaused(uint96 senior, uint96 junior) external {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = ITreasuryInsolvencyModel.InsolvencyInput({
            scenario: ITreasuryInsolvencyModel.Scenario.EMERGENCY_PAUSE,
            policy: ITreasuryInsolvencyModel.AllocationPolicy.PAUSE_THEN_DEFER,
            availableByPool: _pool(0, 0),
            obligations: _pair(uint256(senior) + 1, uint256(junior) + 1),
            allocationCap: 0,
            recoveryInjection: 0,
            paused: true
        });

        _run(input);
    }

    /// @notice Delayed-allocation run: per-epoch cap limits what can be released.
    function runDelayed(uint96 liquidity, uint96 cap, uint96 amount) external {
        ITreasuryInsolvencyModel.Obligation[] memory obs = new ITreasuryInsolvencyModel.Obligation[](1);
        obs[0] = ITreasuryInsolvencyModel.Obligation({
            obligationId: keccak256(abi.encode("delayed", ghost_runSuccesses)),
            obligationClass: ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT,
            amount: uint256(amount) + 1,
            dueAt: 0
        });

        ITreasuryInsolvencyModel.InsolvencyInput memory input = ITreasuryInsolvencyModel.InsolvencyInput({
            scenario: ITreasuryInsolvencyModel.Scenario.DELAYED_ALLOCATION,
            policy: ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            availableByPool: _pool(3, uint256(liquidity)),
            obligations: obs,
            allocationCap: uint256(cap) + 1,
            recoveryInjection: 0,
            paused: false
        });

        _run(input);
    }

    /// @notice Governance-recovery run with injected capital.
    function runRecovery(uint96 liquidity, uint96 injection, uint96 senior, uint96 junior) external {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = ITreasuryInsolvencyModel.InsolvencyInput({
            scenario: ITreasuryInsolvencyModel.Scenario.GOVERNANCE_RECOVERY,
            policy: ITreasuryInsolvencyModel.AllocationPolicy.PRIORITY_WATERFALL,
            availableByPool: _pool(4, uint256(liquidity)),
            obligations: _pair(uint256(senior) + 1, uint256(junior) + 1),
            allocationCap: 0,
            recoveryInjection: uint256(injection) + 1,
            paused: false
        });

        _run(input);
    }

    /// @notice Reconcile a deferred report (once) or attempt a replay.
    function reconcileLatest(uint256 seed, uint96 injection) external {
        uint256 len = _candidates.length;
        if (len == 0) return;

        bytes32 base = _candidates[seed % len];

        if (model.isReconciled(base)) {
            // A second reconciliation must be impossible; record if it is not.
            vm.prank(modeler);
            try model.reconcile(base, 1, ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA) {
                ghost_replaySucceeded = true;
            } catch {
                // expected: write-once replay guard held
            }
            return;
        }

        vm.prank(modeler);
        try model.reconcile(base, uint256(injection) + 1, ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA) returns (
            ITreasuryInsolvencyModel.InsolvencyReport memory report
        ) {
            ghost_reconcileSuccesses++;
            reportIds.push(report.reportId);
        } catch {
            ghost_reconcileFailures++;
        }
    }

    /// @notice Advance modelled time (bounded) to exercise delayed allocation.
    function advanceTime(uint32 secondsJump) external {
        vm.warp(block.timestamp + (uint256(secondsJump) % 30 days) + 1);
    }

    // ── Internals ─────────────────────────────────────────────────────────────

    function _run(ITreasuryInsolvencyModel.InsolvencyInput memory input) internal {
        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.runModel(input);

        ghost_runSuccesses++;
        reportIds.push(report.reportId);
        if (report.totalDeferred > 0) {
            _candidates.push(report.reportId);
        }
    }

    function _pool(uint256 index, uint256 amount) internal pure returns (uint256[7] memory pools) {
        pools[index] = amount;
    }

    function _pair(uint256 senior, uint256 junior)
        internal
        view
        returns (ITreasuryInsolvencyModel.Obligation[] memory obs)
    {
        obs = new ITreasuryInsolvencyModel.Obligation[](2);
        obs[0] = ITreasuryInsolvencyModel.Obligation({
            obligationId: keccak256(abi.encode("senior", ghost_runSuccesses)),
            obligationClass: ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT,
            amount: senior,
            dueAt: 0
        });
        obs[1] = ITreasuryInsolvencyModel.Obligation({
            obligationId: keccak256(abi.encode("junior", ghost_runSuccesses)),
            obligationClass: ITreasuryInsolvencyModel.ObligationClass.REWARDS,
            amount: junior,
            dueAt: 0
        });
    }
}
