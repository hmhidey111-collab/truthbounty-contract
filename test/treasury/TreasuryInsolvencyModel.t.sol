// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ITreasuryInsolvencyModel } from "../../contracts/treasury/ITreasuryInsolvencyModel.sol";
import { TreasuryInsolvencyModel } from "../../contracts/treasury/TreasuryInsolvencyModel.sol";

/**
 * @title TreasuryInsolvencyModelTest
 * @notice Unit, boundary, authorization, replay, and failure-path tests for
 *         V2-SC-107 (Treasury Insolvency & Recovery Model).
 */
contract TreasuryInsolvencyModelTest is Test {
    TreasuryInsolvencyModel internal model;

    address internal admin = address(0xA11CE);
    address internal modeler = address(0xB0B);
    address internal attacker = address(0xBAD);

    uint256 internal constant BPS = 10_000;

    function setUp() public {
        model = new TreasuryInsolvencyModel(admin);
        bytes32 modelerRole = model.MODELER_ROLE();
        vm.prank(admin);
        model.grantRole(modelerRole, modeler);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _pool(uint256 index, uint256 amount) internal pure returns (uint256[7] memory pools) {
        pools[index] = amount;
    }

    function _ob(bytes32 id, ITreasuryInsolvencyModel.ObligationClass c, uint256 amount, uint256 dueAt)
        internal
        pure
        returns (ITreasuryInsolvencyModel.Obligation memory)
    {
        return
            ITreasuryInsolvencyModel.Obligation({ obligationId: id, obligationClass: c, amount: amount, dueAt: dueAt });
    }

    function _input(
        ITreasuryInsolvencyModel.Scenario scenario,
        ITreasuryInsolvencyModel.AllocationPolicy policy,
        uint256[7] memory pools,
        ITreasuryInsolvencyModel.Obligation[] memory obs,
        uint256 cap,
        uint256 injection,
        bool paused
    ) internal pure returns (ITreasuryInsolvencyModel.InsolvencyInput memory) {
        return ITreasuryInsolvencyModel.InsolvencyInput({
            scenario: scenario,
            policy: policy,
            availableByPool: pools,
            obligations: obs,
            allocationCap: cap,
            recoveryInjection: injection,
            paused: paused
        });
    }

    /// @dev Two-class ledger: senior SETTLEMENT + junior REWARDS, one each.
    function _seniorJunior(uint256 senior, uint256 junior)
        internal
        pure
        returns (ITreasuryInsolvencyModel.Obligation[] memory obs)
    {
        obs = new ITreasuryInsolvencyModel.Obligation[](2);
        obs[0] = _ob(keccak256("senior"), ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, senior, 0);
        obs[1] = _ob(keccak256("junior"), ITreasuryInsolvencyModel.ObligationClass.REWARDS, junior, 0);
    }

    /// @dev Single well-formed obligation.
    function _single(ITreasuryInsolvencyModel.ObligationClass c, uint256 amount)
        internal
        pure
        returns (ITreasuryInsolvencyModel.Obligation[] memory obs)
    {
        obs = new ITreasuryInsolvencyModel.Obligation[](1);
        obs[0] = _ob(keccak256("solo"), c, amount, 0);
    }

    // =========================================================================
    // Constructor / roles
    // =========================================================================

    function test_ConstructorWiresRolesAndDefaults() public view {
        assertTrue(model.hasRole(model.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(model.hasRole(model.ADMIN_ROLE(), admin));
        assertTrue(model.hasRole(model.MODELER_ROLE(), admin));
        assertTrue(model.hasRole(model.PAUSER_ROLE(), admin));
        assertEq(model.getReportCount(), 0);
        assertEq(model.thresholds(model.METRIC_TREASURY_COVERAGE()), BPS);
        assertEq(model.thresholds(model.METRIC_MAX_HAIRCUT()), 5_000);
        assertEq(model.getMaxObligations(), 500);
        assertEq(model.POOL_COUNT(), 7);
    }

    function test_RevertWhen_ConstructorZeroAdmin() public {
        vm.expectRevert(ITreasuryInsolvencyModel.ZeroAddress.selector);
        new TreasuryInsolvencyModel(address(0));
    }

    // =========================================================================
    // Scenario: SOLVENT_BASELINE
    // =========================================================================

    function test_SolventBaselineFullyCovers() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
            ITreasuryInsolvencyModel.AllocationPolicy.PRIORITY_WATERFALL,
            _pool(uint256(0), 1_000e18),
            _seniorJunior(400e18, 200e18),
            0,
            0,
            false
        );

        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.runModel(input);

        assertTrue(report.solvent);
        assertTrue(report.fullyCovered);
        assertEq(report.totalPaid, 600e18);
        assertEq(report.totalDeferred, 0);
        assertEq(report.haircutBps, 0);
        assertEq(report.coverageBps, BPS);
        assertEq(report.reportId, model.getReportsPaginated(0, 1)[0]);
    }

    // =========================================================================
    // Scenario: INSUFFICIENT_LIQUIDITY
    // =========================================================================

    function test_InsufficientLiquidityProRataIsDeterministic() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.INSUFFICIENT_LIQUIDITY,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), 500e18),
            _seniorJunior(400e18, 200e18),
            0,
            0,
            false
        );

        ITreasuryInsolvencyModel.InsolvencyReport memory preview = model.previewModel(input);
        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.runModel(input);

        // floor(500 * 400 / 600) and floor(500 * 200 / 600); residual retained.
        // Computed from runtime variables so this matches the on-chain integer math.
        uint256 liquidity = 500e18;
        uint256 senior = 400e18;
        uint256 junior = 200e18;
        uint256 expectedPaid = (liquidity * senior) / (senior + junior) + (liquidity * junior) / (senior + junior);
        assertEq(report.totalPaid, expectedPaid);
        assertEq(report.totalDeferred, 600e18 - expectedPaid);
        assertEq(report.totalLiquidity, 500e18);
        assertTrue(report.totalPaid <= report.totalLiquidity, "residual retained");
        assertFalse(report.solvent);
        assertEq(report.haircutBps, (report.totalDeferred * BPS) / report.totalObligations);

        // Per-class buckets conserve exactly.
        for (uint256 c = 0; c < 6; c++) {
            assertEq(preview.classAllocations[c].owed, report.classAllocations[c].owed);
            assertEq(preview.classAllocations[c].paid, report.classAllocations[c].paid);
            assertEq(preview.classAllocations[c].deferred, report.classAllocations[c].deferred);
            assertEq(
                report.classAllocations[c].paid + report.classAllocations[c].deferred, report.classAllocations[c].owed
            );
        }
    }

    function test_WaterfallFundsSeniorFirst() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.INSUFFICIENT_LIQUIDITY,
            ITreasuryInsolvencyModel.AllocationPolicy.PRIORITY_WATERFALL,
            _pool(uint256(0), 300e18),
            _seniorJunior(400e18, 200e18),
            0,
            0,
            false
        );

        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.previewModel(input);

        // SETTLEMENT (senior) is underfunded; REWARDS (junior) gets nothing.
        assertEq(report.classAllocations[0].paid, 300e18);
        assertEq(report.classAllocations[0].deferred, 100e18);
        assertEq(report.classAllocations[uint256(ITreasuryInsolvencyModel.ObligationClass.REWARDS)].paid, 0);
        assertEq(report.totalPaid, 300e18);
        assertEq(report.totalDeferred, 300e18);
    }

    function test_WaterfallFullSeniorThenPartialMarginal() public {
        // 2 due classes: SETTLEMENT 100 owed, STAKING_PRINCIPAL 100 owed; liquidity 150.
        ITreasuryInsolvencyModel.Obligation[] memory obs = new ITreasuryInsolvencyModel.Obligation[](2);
        obs[0] = _ob(keccak256("a"), ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 100e18, 0);
        obs[1] = _ob(keccak256("b"), ITreasuryInsolvencyModel.ObligationClass.STAKING_PRINCIPAL, 100e18, 0);

        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.INSUFFICIENT_LIQUIDITY,
            ITreasuryInsolvencyModel.AllocationPolicy.PRIORITY_WATERFALL,
            _pool(uint256(0), 150e18),
            obs,
            0,
            0,
            false
        );

        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.previewModel(input);
        assertEq(report.classAllocations[0].paid, 100e18);
        assertEq(report.classAllocations[1].paid, 50e18);
        assertEq(report.classAllocations[1].deferred, 50e18);
        assertEq(report.totalPaid, 150e18);
    }

    // =========================================================================
    // Scenario: DELAYED_ALLOCATION
    // =========================================================================

    function test_DelayedAllocationCapAndFutureDue() public {
        vm.warp(1_000_000);
        uint256[7] memory pools = _pool(uint256(3), 1_000e18);

        ITreasuryInsolvencyModel.Obligation[] memory obs = new ITreasuryInsolvencyModel.Obligation[](2);
        obs[0] = _ob(keccak256("due"), ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 100e18, 0);
        obs[1] =
            _ob(keccak256("future"), ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 100e18, block.timestamp + 1);

        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.DELAYED_ALLOCATION,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            pools,
            obs,
            100e18, // per-epoch cap
            0,
            false
        );

        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.previewModel(input);

        // Only the due obligation is eligible, and the cap equals it.
        assertEq(report.totalPaid, 100e18);
        assertEq(report.totalDeferred, 100e18);
        assertEq(report.totalLiquidity, 1_000e18);
        assertFalse(report.fullyCovered);
        assertTrue(report.solvent, "snapshot covers the ledger even though allocation is delayed");
    }

    function test_DelayedAllocationWithNoDueObligationsDefersAll() public {
        vm.warp(1_000_000);
        ITreasuryInsolvencyModel.Obligation[] memory obs = new ITreasuryInsolvencyModel.Obligation[](1);
        obs[0] = _ob(
            keccak256("future"), ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 100e18, block.timestamp + 1 days
        );

        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.DELAYED_ALLOCATION,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), 1_000e18),
            obs,
            500e18,
            0,
            false
        );

        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.previewModel(input);
        assertEq(report.totalPaid, 0);
        assertEq(report.totalDeferred, 100e18);
    }

    // =========================================================================
    // Scenario: PARTIAL_OBLIGATION
    // =========================================================================

    function test_PartialObligationDefersRemainder() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.PARTIAL_OBLIGATION,
            ITreasuryInsolvencyModel.AllocationPolicy.PRIORITY_WATERFALL,
            _pool(uint256(0), 250e18),
            _single(ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 1_000e18),
            0,
            0,
            false
        );

        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.previewModel(input);
        assertEq(report.totalPaid, 250e18);
        assertEq(report.totalDeferred, 750e18);
        assertEq(report.classAllocations[0].haircutBps, 7_500); // 750/1000
    }

    // =========================================================================
    // Scenario: EMERGENCY_PAUSE
    // =========================================================================

    function test_EmergencyPauseDefersEverything() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.EMERGENCY_PAUSE,
            ITreasuryInsolvencyModel.AllocationPolicy.PAUSE_THEN_DEFER,
            _pool(uint256(0), 1_000e18),
            _seniorJunior(400e18, 200e18),
            0,
            0,
            true
        );

        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.runModel(input);

        assertTrue(report.paused);
        assertEq(report.totalPaid, 0);
        assertEq(report.totalDeferred, 600e18);
        assertEq(report.haircutBps, BPS);
        assertFalse(report.fullyCovered);
    }

    // =========================================================================
    // Scenario: GOVERNANCE_RECOVERY
    // =========================================================================

    function test_GovernanceRecoveryRestoresCoverage() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.GOVERNANCE_RECOVERY,
            ITreasuryInsolvencyModel.AllocationPolicy.PRIORITY_WATERFALL,
            _pool(uint256(0), 400e18),
            _seniorJunior(400e18, 200e18),
            0,
            300e18, // governance injection
            false
        );

        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.previewModel(input);
        assertEq(report.injectedCapital, 300e18);
        assertEq(report.totalLiquidity, 700e18);
        assertTrue(report.solvent);
        assertTrue(report.fullyCovered);
        assertEq(report.totalPaid, 600e18);
    }

    // =========================================================================
    // Scenario: POST_RECOVERY_RECONCILIATION (reconcile)
    // =========================================================================

    function test_ReconcileSettlesDeferredLedgerOnce() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.EMERGENCY_PAUSE,
            ITreasuryInsolvencyModel.AllocationPolicy.PAUSE_THEN_DEFER,
            _pool(uint256(0), 0),
            _seniorJunior(400e18, 200e18),
            0,
            0,
            true
        );

        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory base = model.runModel(input);
        assertEq(base.totalDeferred, 600e18);

        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory rec =
            model.reconcile(base.reportId, 600e18, ITreasuryInsolvencyModel.AllocationPolicy.PRIORITY_WATERFALL);

        assertEq(uint256(rec.scenario), uint256(ITreasuryInsolvencyModel.Scenario.POST_RECOVERY_RECONCILIATION));
        assertEq(rec.totalObligations, 600e18);
        assertEq(rec.totalPaid, 600e18);
        assertEq(rec.totalDeferred, 0);
        assertTrue(rec.fullyCovered);
        assertTrue(model.isReconciled(base.reportId));
        assertEq(model.getRecoveryReportId(base.reportId), rec.reportId);
    }

    function test_ReconcileProRataPartial() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.INSUFFICIENT_LIQUIDITY,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), 0),
            _seniorJunior(400e18, 200e18),
            0,
            0,
            false
        );
        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory base = model.runModel(input);

        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory rec =
            model.reconcile(base.reportId, 300e18, ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA);
        assertEq(rec.totalPaid, 300e18);
        assertEq(rec.totalDeferred, 300e18);
    }

    // =========================================================================
    // Determinism, isolation, events
    // =========================================================================

    function test_PreviewIsDeterministicAndDoesNotMutateState() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.INSUFFICIENT_LIQUIDITY,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), 500e18),
            _seniorJunior(400e18, 200e18),
            0,
            0,
            false
        );

        ITreasuryInsolvencyModel.InsolvencyReport memory a = model.previewModel(input);
        ITreasuryInsolvencyModel.InsolvencyReport memory b = model.previewModel(input);
        assertEq(a.totalPaid, b.totalPaid);
        assertEq(a.totalDeferred, b.totalDeferred);
        assertEq(a.coverageBps, b.coverageBps);
        assertEq(a.haircutBps, b.haircutBps);
        assertEq(model.getReportCount(), 0, "preview must not persist");
    }

    function test_ReportGeneratedAndInsolvencyEvents() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.INSUFFICIENT_LIQUIDITY,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), 500e18),
            _seniorJunior(400e18, 200e18),
            0,
            0,
            false
        );

        bytes32 expectedId = keccak256(
            abi.encode(
                input.scenario,
                input.policy,
                input.availableByPool,
                input.obligations,
                input.allocationCap,
                input.recoveryInjection,
                input.paused,
                uint256(0)
            )
        );

        uint256 liquidity = 500e18;
        uint256 senior = 400e18;
        uint256 junior = 200e18;
        uint256 expectedPaid = (liquidity * senior) / (senior + junior) + (liquidity * junior) / (senior + junior);
        uint256 expectedDeferred = (senior + junior) - expectedPaid;
        uint256 expectedHaircut = (expectedDeferred * BPS) / (senior + junior);

        vm.expectEmit(true, true, true, true, address(model));
        emit ITreasuryInsolvencyModel.ReportGenerated(
            expectedId,
            ITreasuryInsolvencyModel.Scenario.INSUFFICIENT_LIQUIDITY,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            500e18,
            600e18,
            expectedPaid,
            expectedDeferred,
            expectedHaircut,
            false
        );
        vm.prank(modeler);
        model.runModel(input);
    }

    // =========================================================================
    // Pagination / views
    // =========================================================================

    function test_PaginationAndReportLookup() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), 1_000e18),
            _seniorJunior(100e18, 100e18),
            0,
            0,
            false
        );

        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory first = model.runModel(input);

        // Different run context (counter) yields a distinct id even for identical input.
        vm.roll(block.number + 1);
        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory second = model.runModel(input);
        assertTrue(first.reportId != second.reportId, "replay: ids must be unique");

        assertEq(model.getReportCount(), 2);
        bytes32[] memory ids = model.getReportsPaginated(0, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], first.reportId);
        assertEq(model.getReport(second.reportId).reportId, second.reportId);

        bytes32[] memory none = model.getReportsPaginated(5, 10);
        assertEq(none.length, 0);
    }

    function test_RevertWhen_ReportNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(ITreasuryInsolvencyModel.ReportNotFound.selector, bytes32(uint256(1))));
        model.getReport(bytes32(uint256(1)));
    }

    function test_ScenarioAndPolicyMetadata() public {
        ITreasuryInsolvencyModel.Scenario[] memory scenarios = model.getAvailableScenarios();
        assertEq(scenarios.length, 7);
        assertEq(model.getScenarioName(scenarios[1]), "Insufficient Liquidity");
        assertEq(model.getScenarioName(scenarios[4]), "Emergency Pause");
        assertEq(
            model.getPolicyName(ITreasuryInsolvencyModel.AllocationPolicy.PRIORITY_WATERFALL), "Priority Waterfall"
        );
        assertTrue(bytes(model.getScenarioDescription(scenarios[6])).length > 0);
    }

    // =========================================================================
    // Validation: negative / boundary
    // =========================================================================

    function test_ValidateRejectsEmptyLedger() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), 1e18),
            new ITreasuryInsolvencyModel.Obligation[](0),
            0,
            0,
            false
        );
        _assertInvalid(input, "NO_OBLIGATIONS");
    }

    function test_ValidateRejectsZeroIdAndZeroAmount() public {
        ITreasuryInsolvencyModel.Obligation[] memory zeroId = new ITreasuryInsolvencyModel.Obligation[](1);
        zeroId[0] = _ob(bytes32(0), ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 1e18, 0);
        _assertInvalid(
            _input(
                ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
                ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
                _pool(uint256(0), 1e18),
                zeroId,
                0,
                0,
                false
            ),
            "ZERO_OBLIGATION_ID"
        );

        ITreasuryInsolvencyModel.Obligation[] memory zeroAmount = new ITreasuryInsolvencyModel.Obligation[](1);
        zeroAmount[0] = _ob(keccak256("x"), ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 0, 0);
        _assertInvalid(
            _input(
                ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
                ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
                _pool(uint256(0), 1e18),
                zeroAmount,
                0,
                0,
                false
            ),
            "ZERO_OBLIGATION_AMOUNT"
        );
    }

    function test_ValidateRejectsPauseMismatches() public {
        _assertInvalid(
            _input(
                ITreasuryInsolvencyModel.Scenario.EMERGENCY_PAUSE,
                ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
                _pool(uint256(0), 1e18),
                _single(ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 1e18),
                0,
                0,
                false
            ),
            "EMERGENCY_SCENARIO_REQUIRES_PAUSE"
        );

        _assertInvalid(
            _input(
                ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
                ITreasuryInsolvencyModel.AllocationPolicy.PAUSE_THEN_DEFER,
                _pool(uint256(0), 1e18),
                _single(ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 1e18),
                0,
                0,
                false
            ),
            "PAUSE_POLICY_MISMATCH"
        );
    }

    function test_ValidateRejectsRecoveryAndCapMismatches() public {
        _assertInvalid(
            _input(
                ITreasuryInsolvencyModel.Scenario.GOVERNANCE_RECOVERY,
                ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
                _pool(uint256(0), 1e18),
                _single(ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 1e18),
                0,
                0, // missing injection
                false
            ),
            "RECOVERY_REQUIRES_INJECTION"
        );

        _assertInvalid(
            _input(
                ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
                ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
                _pool(uint256(0), 1e18),
                _single(ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 1e18),
                0,
                5e17, // injection not allowed here
                false
            ),
            "INJECTION_NOT_ALLOWED"
        );

        _assertInvalid(
            _input(
                ITreasuryInsolvencyModel.Scenario.DELAYED_ALLOCATION,
                ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
                _pool(uint256(0), 1e18),
                _single(ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 1e18),
                0, // missing cap
                0,
                false
            ),
            "DELAYED_ALLOCATION_REQUIRES_CAP"
        );

        _assertInvalid(
            _input(
                ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
                ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
                _pool(uint256(0), 1e18),
                _single(ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 1e18),
                1e18, // cap not allowed here
                0,
                false
            ),
            "UNEXPECTED_ALLOCATION_CAP"
        );
    }

    function test_RevertWhen_RunModelInvalidInput() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), 1e18),
            new ITreasuryInsolvencyModel.Obligation[](0),
            0,
            0,
            false
        );

        vm.expectRevert(abi.encodeWithSelector(ITreasuryInsolvencyModel.InvalidInput.selector, "NO_OBLIGATIONS"));
        vm.prank(modeler);
        model.runModel(input);
    }

    function test_BoundaryMaxObligations() public {
        uint256 max = model.getMaxObligations();

        ITreasuryInsolvencyModel.Obligation[] memory tooMany = new ITreasuryInsolvencyModel.Obligation[](max + 1);
        for (uint256 i = 0; i < tooMany.length; i++) {
            tooMany[i] = _ob(bytes32(i + 1), ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 1e18, 0);
        }
        (, bool safe) = model.validateInput(
            _input(
                ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
                ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
                _pool(uint256(0), 1e30),
                tooMany,
                0,
                0,
                false
            )
        );
        assertFalse(safe);

        ITreasuryInsolvencyModel.Obligation[] memory atMax = new ITreasuryInsolvencyModel.Obligation[](max);
        for (uint256 i = 0; i < max; i++) {
            atMax[i] = _ob(bytes32(i + 1), ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 1e18, 0);
        }
        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.previewModel(
            _input(
                ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
                ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
                _pool(uint256(0), 1e30),
                atMax,
                0,
                0,
                false
            )
        );
        assertEq(report.totalPaid, max * 1e18);
    }

    // =========================================================================
    // Authorization & replay
    // =========================================================================

    function test_RevertWhen_UnauthorizedRunAndReconcile() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), 1e18),
            _single(ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 1e18),
            0,
            0,
            false
        );

        vm.prank(attacker);
        vm.expectRevert();
        model.runModel(input);

        vm.prank(attacker);
        vm.expectRevert();
        model.reconcile(bytes32(uint256(1)), 1e18, ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA);
    }

    function test_RevertWhen_NonAdminSetsThreshold() public {
        bytes32 metric = model.METRIC_MAX_HAIRCUT();
        vm.prank(attacker);
        vm.expectRevert();
        model.setThreshold(metric, 1);
    }

    function test_ReconcileReplayIsBlocked() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.INSUFFICIENT_LIQUIDITY,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), 100e18),
            _seniorJunior(400e18, 200e18),
            0,
            0,
            false
        );
        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory base = model.runModel(input);

        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory rec =
            model.reconcile(base.reportId, 100e18, ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA);

        // Second reconciliation of the same base report must revert (replay path closed).
        vm.prank(modeler);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITreasuryInsolvencyModel.ReportAlreadyReconciled.selector, base.reportId, rec.reportId
            )
        );
        model.reconcile(base.reportId, 100e18, ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA);
    }

    function test_ReconcileFailurePaths() public {
        // Unknown base report.
        vm.prank(modeler);
        vm.expectRevert(abi.encodeWithSelector(ITreasuryInsolvencyModel.ReportNotFound.selector, bytes32(0)));
        model.reconcile(bytes32(0), 1e18, ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA);

        // Fully covered base report has nothing to reconcile.
        ITreasuryInsolvencyModel.InsolvencyInput memory solvent = _input(
            ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), 1_000e18),
            _seniorJunior(100e18, 100e18),
            0,
            0,
            false
        );
        vm.prank(modeler);
        ITreasuryInsolvencyModel.InsolvencyReport memory base = model.runModel(solvent);
        vm.prank(modeler);
        vm.expectRevert(abi.encodeWithSelector(ITreasuryInsolvencyModel.NothingToReconcile.selector, base.reportId));
        model.reconcile(base.reportId, 1e18, ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA);

        // Zero injection.
        vm.prank(modeler);
        vm.expectRevert(ITreasuryInsolvencyModel.ZeroAmount.selector);
        model.reconcile(base.reportId, 0, ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA);

        // Defer policies are not valid recovery policies.
        vm.prank(modeler);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITreasuryInsolvencyModel.InvalidRecoveryPolicy.selector, ITreasuryInsolvencyModel.AllocationPolicy.DEFER
            )
        );
        model.reconcile(base.reportId, 1e18, ITreasuryInsolvencyModel.AllocationPolicy.DEFER);
    }

    function test_ModelPauseBlocksRuns() public {
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.SOLVENT_BASELINE,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), 1e18),
            _single(ITreasuryInsolvencyModel.ObligationClass.SETTLEMENT, 1e18),
            0,
            0,
            false
        );

        vm.prank(admin);
        model.pause();

        vm.prank(modeler);
        vm.expectRevert();
        model.runModel(input);

        vm.prank(admin);
        model.unpause();

        vm.prank(modeler);
        model.runModel(input);
        assertEq(model.getReportCount(), 1);
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function testFuzz_ProRataNeverExceedsLiquidity(uint96 liquidity, uint96 amountA, uint96 amountB) public {
        vm.assume(liquidity > 0);
        vm.assume(amountA > 0 && amountB > 0);

        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.INSUFFICIENT_LIQUIDITY,
            ITreasuryInsolvencyModel.AllocationPolicy.PRO_RATA,
            _pool(uint256(0), liquidity),
            _seniorJunior(amountA, amountB),
            0,
            0,
            false
        );

        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.previewModel(input);

        assertLe(report.totalPaid, report.totalLiquidity, "paid must not exceed liquidity");
        assertEq(report.totalPaid + report.totalDeferred, report.totalObligations, "conservation");
        assertLe(report.haircutBps, BPS);
        assertLe(report.coverageBps, BPS);
    }

    function testFuzz_WaterfallNeverPaysJuniorBeforeSenior(uint96 liquidity) public {
        uint256 liq = uint256(liquidity);
        ITreasuryInsolvencyModel.InsolvencyInput memory input = _input(
            ITreasuryInsolvencyModel.Scenario.INSUFFICIENT_LIQUIDITY,
            ITreasuryInsolvencyModel.AllocationPolicy.PRIORITY_WATERFALL,
            _pool(uint256(0), liq),
            _seniorJunior(400e18, 200e18),
            0,
            0,
            false
        );

        ITreasuryInsolvencyModel.InsolvencyReport memory report = model.previewModel(input);
        uint256 rewardsPaid = report.classAllocations[uint256(ITreasuryInsolvencyModel.ObligationClass.REWARDS)].paid;
        uint256 settlementPaid = report.classAllocations[0].paid;

        if (rewardsPaid > 0) {
            assertEq(settlementPaid, 400e18, "junior only funded after senior is whole");
        }
        assertEq(report.totalPaid + report.totalDeferred, report.totalObligations, "conservation");
    }

    // =========================================================================
    // Internal assertions
    // =========================================================================

    function _assertInvalid(ITreasuryInsolvencyModel.InsolvencyInput memory input, string memory reason) internal view {
        (string[] memory warnings, bool safe) = model.validateInput(input);
        assertFalse(safe, reason);
        assertGt(warnings.length, 0);
        assertEq(warnings[0], reason);
    }
}
