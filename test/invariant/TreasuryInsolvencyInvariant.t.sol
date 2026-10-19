// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { ITreasuryInsolvencyModel } from "../../contracts/treasury/ITreasuryInsolvencyModel.sol";
import { TreasuryInsolvencyModel } from "../../contracts/treasury/TreasuryInsolvencyModel.sol";
import { TreasuryInsolvencyHandler } from "./TreasuryInsolvencyHandler.sol";

/**
 * @title TreasuryInsolvencyInvariantTest
 * @notice Stateful invariant coverage for V2-SC-107.
 *
 * Properties under test:
 *  1. Conservation — paid + deferred == owed, globally and per class.
 *  2. Liquidity bound — no run ever allocates more than available liquidity.
 *  3. Bounded haircut/coverage — no metric escapes [0, 10000] bps.
 *  4. Append-only reports — ids are monotonic and never rewritten.
 *  5. Write-once reconciliation — a base report is reconciled at most once.
 *  6. Pause fidelity — a paused report allocates nothing.
 *  7. No custody — the model never holds value or gains protocol authority.
 */
contract TreasuryInsolvencyInvariantTest is StdInvariant, Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_SCAN = 50;

    TreasuryInsolvencyModel internal model;
    TreasuryInsolvencyHandler internal handler;

    address internal admin = address(0xAD);
    address internal modeler = address(0xB0B);

    function setUp() public {
        model = new TreasuryInsolvencyModel(admin);
        handler = new TreasuryInsolvencyHandler(model, modeler);

        bytes32 modelerRole = model.MODELER_ROLE();
        vm.prank(admin);
        model.grantRole(modelerRole, modeler);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = TreasuryInsolvencyHandler.runInsolvent.selector;
        selectors[1] = TreasuryInsolvencyHandler.runPaused.selector;
        selectors[2] = TreasuryInsolvencyHandler.runDelayed.selector;
        selectors[3] = TreasuryInsolvencyHandler.runRecovery.selector;
        selectors[4] = TreasuryInsolvencyHandler.reconcileLatest.selector;
        selectors[5] = TreasuryInsolvencyHandler.advanceTime.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    // =========================================================================
    // 1–3. Conservation, liquidity bound, bounded metrics
    // =========================================================================

    function invariant_ReportConservationAndBounds() public view {
        uint256 n = handler.reportIdCount();
        uint256 scanned = n < MAX_SCAN ? n : MAX_SCAN;

        for (uint256 i = 0; i < scanned; i++) {
            ITreasuryInsolvencyModel.InsolvencyReport memory report = model.getReport(handler.reportIds(i));

            assertEq(report.totalPaid + report.totalDeferred, report.totalObligations, "conservation");
            assertLe(report.totalPaid, report.totalLiquidity, "paid exceeds liquidity");
            assertLe(report.totalDeferred, report.totalObligations, "deferred exceeds owed");
            assertLe(report.haircutBps, BPS, "haircut out of range");
            assertLe(report.coverageBps, BPS, "coverage out of range");

            uint256 sumOwed;
            uint256 sumPaid;
            uint256 sumDeferred;

            for (uint256 c = 0; c < 6; c++) {
                ITreasuryInsolvencyModel.ClassAllocation memory bucket = report.classAllocations[c];
                assertEq(bucket.paid + bucket.deferred, bucket.owed, "class conservation");
                assertLe(bucket.haircutBps, BPS, "class haircut out of range");
                sumOwed += bucket.owed;
                sumPaid += bucket.paid;
                sumDeferred += bucket.deferred;
            }

            assertEq(sumOwed, report.totalObligations, "class owed total");
            assertEq(sumPaid, report.totalPaid, "class paid total");
            assertEq(sumDeferred, report.totalDeferred, "class deferred total");

            if (report.totalDeferred == 0) {
                assertTrue(report.fullyCovered, "zero deferral must be fully covered");
            }
            if (report.fullyCovered) {
                assertEq(report.totalDeferred, 0, "fully covered must have zero deferral");
            }
        }
    }

    // =========================================================================
    // 4. Append-only report ledger
    // =========================================================================

    function invariant_ReportsAreAppendOnly() public view {
        uint256 n = handler.reportIdCount();
        assertEq(model.getReportCount(), n, "report count drift");
        if (n == 0) return;

        uint256 scanned = n < MAX_SCAN ? n : MAX_SCAN;
        bytes32[] memory ids = model.getReportsPaginated(0, scanned);
        assertEq(ids.length, scanned, "pagination length");

        for (uint256 i = 0; i < scanned; i++) {
            assertEq(ids[i], handler.reportIds(i), "report id order drift");
        }
    }

    /// @notice Ghost accounting mirrors the persisted ledger exactly.
    function invariant_GhostAccountingMatchesLedger() public view {
        assertEq(
            model.getReportCount(),
            handler.ghost_runSuccesses() + handler.ghost_reconcileSuccesses(),
            "ghost run/reconcile accounting"
        );
    }

    // =========================================================================
    // 5. Write-once reconciliation / replay guard
    // =========================================================================

    function invariant_ReconciliationIsWriteOnce() public view {
        assertFalse(handler.ghost_replaySucceeded(), "double reconciliation was allowed");

        uint256 n = handler.reportIdCount();
        uint256 scanned = n < MAX_SCAN ? n : MAX_SCAN;

        for (uint256 i = 0; i < scanned; i++) {
            bytes32 id = handler.reportIds(i);
            if (!model.isReconciled(id)) continue;
            if (model.getReport(id).totalDeferred == 0) continue; // fully-covered reports are never base reports

            bytes32 recoveryId = model.getRecoveryReportId(id);
            assertTrue(recoveryId != bytes32(0), "reconciled without recovery report");

            ITreasuryInsolvencyModel.InsolvencyReport memory recovery = model.getReport(recoveryId);
            assertEq(
                uint256(recovery.scenario),
                uint256(ITreasuryInsolvencyModel.Scenario.POST_RECOVERY_RECONCILIATION),
                "wrong recovery scenario"
            );
        }
    }

    // =========================================================================
    // 6. Pause fidelity
    // =========================================================================

    function invariant_PausedReportsAllocateNothing() public view {
        uint256 n = handler.reportIdCount();
        uint256 scanned = n < MAX_SCAN ? n : MAX_SCAN;

        for (uint256 i = 0; i < scanned; i++) {
            ITreasuryInsolvencyModel.InsolvencyReport memory report = model.getReport(handler.reportIds(i));
            if (report.paused) {
                assertEq(report.totalPaid, 0, "paused report allocated value");
            }
        }
    }

    // =========================================================================
    // 7. No custody / no value authority
    // =========================================================================

    function invariant_ModelHoldsNoValue() public view {
        // The advisory model must never custody ETH or tokens; it has no
        // transfer surface and no value can accumulate in it.
        assertEq(address(model).balance, 0, "model custodies ETH");
        assertEq(address(handler).balance, 0, "handler custodies ETH");
    }

    // =========================================================================
    // Plain property tests
    // =========================================================================

    function test_PreviewIsDeterministicAcrossCalls() public view {
        ITreasuryInsolvencyModel.Obligation[] memory obs = new ITreasuryInsolvencyModel.Obligation[](2);
        obs[0] = ITreasuryInsolvencyModel.Obligation(
            keccak256("a"), ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 400e18, 0
        );
        obs[1] = ITreasuryInsolvencyModel.Obligation(
            keccak256("b"), ITreasuryInsolvencyModel.ObligationClass.REWARDS, 200e18, 0
        );

        uint256[7] memory pools;
        pools[0] = 500e18;

        ITreasuryInsolvencyModel.InsolvencyInput memory input = ITreasuryInsolvencyModel.InsolvencyInput({
            scenario: ITreasuryInsolvencyModel.Scenario.INSUFFICIENT_LIQUIDITY,
            policy: ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            availableByPool: pools,
            obligations: obs,
            allocationCap: 0,
            recoveryInjection: 0,
            paused: false
        });

        ITreasuryInsolvencyModel.InsolvencyReport memory a = model.previewModel(input);
        ITreasuryInsolvencyModel.InsolvencyReport memory b = model.previewModel(input);

        assertEq(a.totalPaid, b.totalPaid);
        assertEq(a.totalDeferred, b.totalDeferred);
        assertEq(a.haircutBps, b.haircutBps);
        assertEq(a.coverageBps, b.coverageBps);
        assertEq(a.classAllocations[0].paid, b.classAllocations[0].paid);
    }
}
