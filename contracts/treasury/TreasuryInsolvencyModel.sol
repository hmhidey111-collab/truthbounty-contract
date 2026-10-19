// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ITreasuryManagement } from "./ITreasuryManagement.sol";
import { ITreasuryInsolvencyModel } from "./ITreasuryInsolvencyModel.sol";

/**
 * @title TreasuryInsolvencyModel
 * @notice Treasury Insolvency & Recovery Model for TruthBounty V2 (V2-SC-107).
 *
 * @dev The model is deliberately *advisory and isolated*:
 *  - It holds no tokens and exposes no path that can move protocol value.
 *  - It cannot mutate `TreasuryManagement`, `InsuranceFund`, `FeeManager`, or any
 *    other canonical module. It only stores append-only projection reports.
 *  - No API, indexer, frontend, guardian, deployer, or test harness gains
 *    settlement or treasury authority through this contract.
 *
 *      The model turns a liquidity snapshot plus an obligation ledger into a
 *      deterministic allocation/reconciliation report. Every scenario named in
 *      V2-SC-107 is expressible and every shortfall is resolved by an explicit,
 *      documented policy — there is no haircut ambiguity:
 *
 *      - INSUFFICIENT_LIQUIDITY → PRO_RATA or PRIORITY_WATERFALL haircut
 *      - DELAYED_ALLOCATION     → future-dated obligations and/or `allocationCap`
 *      - PARTIAL_OBLIGATION     → partial class funding, remainder deferred
 *      - EMERGENCY_PAUSE        → PAUSE_THEN_DEFER, everything deferred
 *      - GOVERNANCE_RECOVERY    → `recoveryInjection` restores coverage
 *      - POST_RECOVERY_RECONCILIATION → {reconcile}, write-once per base report
 *
 *      Determinism: given identical `(input, block.timestamp, block.number)` the
 *      engine returns byte-identical metrics and per-class buckets. The engine
 *      never reads ambient randomness and never sorts caller data.
 *
 *      Rounding: all divisions floor (protocol-favouring). The rounding residual
 *      is retained rather than distributed, so no obligation is ever over-paid and
 *      `totalPaid <= effectiveLiquidity` always holds.
 *
 * @custom:security-contact security@truthbounty.io
 */
contract TreasuryInsolvencyModel is ITreasuryInsolvencyModel, AccessControl, ReentrancyGuard, Pausable {
    // =========================================================================
    // Roles
    // =========================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MODELER_ROLE = keccak256("MODELER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Basis points denominator (100%).
    uint256 public constant BPS = 10_000;

    /// @notice Canonical treasury pool count (mirrors `ITreasuryManagement.TreasuryPool`).
    uint256 public constant POOL_COUNT = 7;

    /// @notice Number of priority classes (mirrors `ObligationClass`).
    uint256 public constant OBLIGATION_CLASS_COUNT = 6;

    /// @notice Hard bound on obligations per run — keeps every loop gas-bounded.
    uint256 public constant MAX_OBLIGATIONS = 500;

    /// @notice Hard bound on reports returned by a single page query.
    uint256 public constant MAX_REPORTS_PER_QUERY = 500;

    /// @dev Internal cap on validation warnings collected per input.
    uint256 private constant MAX_WARNINGS = 16;

    // =========================================================================
    // Metric identifiers
    // =========================================================================

    bytes32 public constant METRIC_TREASURY_COVERAGE = keccak256("TREASURY_COVERAGE");
    bytes32 public constant METRIC_MAX_HAIRCUT = keccak256("MAX_HAIRCUT");
    bytes32 public constant METRIC_MAX_SHORTFALL = keccak256("MAX_SHORTFALL");

    // =========================================================================
    // State
    // =========================================================================

    /// @notice reportId => append-only report.
    mapping(bytes32 => InsolvencyReport) private _reports;

    /// @notice Ordered report ids for sequential queries.
    bytes32[] private _reportIds;

    /// @notice Monotonic run counter, part of every report id.
    uint256 private _reportCounter;

    /// @notice baseReportId => recovery report id (write-once replay guard).
    mapping(bytes32 => bytes32) private _reconciledBy;

    /// @notice Configurable warning thresholds per metric id.
    mapping(bytes32 => uint256) public thresholds;

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @param initialAdmin Admin/modeler/pauser bootstrap address. Must be non-zero.
     */
    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert ZeroAddress();

        // Compile-time alignment guard: the seven-slot liquidity snapshot must stay
        // in the exact order of the canonical treasury pool enum.
        assert(uint256(ITreasuryManagement.TreasuryPool.EMERGENCY_RESERVE) + 1 == POOL_COUNT);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(MODELER_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);

        _setRoleAdmin(MODELER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);

        // Warn below full coverage, above a 50% haircut, and on any uncovered shortfall.
        thresholds[METRIC_TREASURY_COVERAGE] = BPS;
        thresholds[METRIC_MAX_HAIRCUT] = 5_000;
        thresholds[METRIC_MAX_SHORTFALL] = 0;
    }

    // =========================================================================
    // Core Functions
    // =========================================================================

    /// @inheritdoc ITreasuryInsolvencyModel
    function runModel(InsolvencyInput calldata input)
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(MODELER_ROLE)
        returns (InsolvencyReport memory report)
    {
        (string[] memory warnings, bool safe) = _validate(input);
        if (!safe) revert InvalidInput(warnings[0]);

        report = _run(input);

        bytes32 reportId = _computeReportId(input, _reportCounter);
        report.reportId = reportId;

        _reports[reportId] = report;
        _reportIds.push(reportId);
        _reportCounter++;

        emit ReportGenerated(
            reportId,
            report.scenario,
            report.policy,
            report.totalLiquidity,
            report.totalObligations,
            report.totalPaid,
            report.totalDeferred,
            report.haircutBps,
            report.solvent
        );

        if (report.coverageBps < thresholds[METRIC_TREASURY_COVERAGE]) {
            emit ModelThresholdExceeded(METRIC_TREASURY_COVERAGE, report.coverageBps);
        }
        if (report.haircutBps > thresholds[METRIC_MAX_HAIRCUT]) {
            emit ModelThresholdExceeded(METRIC_MAX_HAIRCUT, report.haircutBps);
        }

        uint256 shortfall =
            report.totalObligations > report.totalLiquidity ? report.totalObligations - report.totalLiquidity : 0;
        if (shortfall > thresholds[METRIC_MAX_SHORTFALL]) {
            emit InsolvencyDetected(reportId, shortfall);
        }

        return report;
    }

    /// @inheritdoc ITreasuryInsolvencyModel
    function previewModel(InsolvencyInput calldata input)
        external
        view
        override
        returns (InsolvencyReport memory report)
    {
        return _run(input);
    }

    /// @inheritdoc ITreasuryInsolvencyModel
    function reconcile(bytes32 baseReportId, uint256 recoveryInjection, AllocationPolicy recoveryPolicy)
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(MODELER_ROLE)
        returns (InsolvencyReport memory report)
    {
        if (recoveryInjection == 0) revert ZeroAmount();
        if (recoveryPolicy != AllocationPolicy.PRO_RATA && recoveryPolicy != AllocationPolicy.PRIORITY_WATERFALL) {
            revert InvalidRecoveryPolicy(recoveryPolicy);
        }

        InsolvencyReport storage baseReport = _reports[baseReportId];
        if (baseReport.timestamp == 0) revert ReportNotFound(baseReportId);

        bytes32 existing = _reconciledBy[baseReportId];
        if (existing != bytes32(0)) revert ReportAlreadyReconciled(baseReportId, existing);

        if (baseReport.totalDeferred == 0) revert NothingToReconcile(baseReportId);

        InsolvencyInput memory input;
        input.scenario = Scenario.POST_RECOVERY_RECONCILIATION;
        input.policy = recoveryPolicy;
        input.recoveryInjection = recoveryInjection;
        input.obligations = _deferredObligations(baseReportId, baseReport);

        report = _run(input);

        bytes32 reportId = _computeReportId(input, _reportCounter);
        report.reportId = reportId;

        _reports[reportId] = report;
        _reportIds.push(reportId);
        _reportCounter++;

        // Write-once replay guard: a base report can be reconciled exactly once.
        _reconciledBy[baseReportId] = reportId;

        emit ReportGenerated(
            reportId,
            report.scenario,
            report.policy,
            report.totalLiquidity,
            report.totalObligations,
            report.totalPaid,
            report.totalDeferred,
            report.haircutBps,
            report.solvent
        );

        emit RecoveryReconciled(baseReportId, reportId, recoveryInjection, report.totalPaid, report.totalDeferred);

        return report;
    }

    // =========================================================================
    // Deterministic Engine
    // =========================================================================

    /**
     * @dev Core deterministic engine. Pure with respect to protocol state; reads
     *      only `block.timestamp` (obligation eligibility) and `block.number`.
     *      Never reverts for structurally-valid inputs and never divides by zero.
     */
    function _run(InsolvencyInput memory input) internal view returns (InsolvencyReport memory report) {
        uint256 n = input.obligations.length;
        uint256 nowTs = block.timestamp;

        uint256 totalObligations = 0;
        for (uint256 i = 0; i < n; i++) {
            totalObligations += input.obligations[i].amount;
        }

        uint256 liquidity = input.recoveryInjection;
        for (uint256 p = 0; p < POOL_COUNT; p++) {
            liquidity += input.availableByPool[p];
        }

        uint256 effective = liquidity;
        if (input.allocationCap > 0 && input.allocationCap < effective) {
            effective = input.allocationCap;
        }
        if (input.paused) {
            effective = 0;
        }

        uint256[] memory paid = new uint256[](n);

        if (effective > 0 && totalObligations > 0) {
            if (input.policy == AllocationPolicy.PRO_RATA) {
                _allocateProRata(input.obligations, paid, effective, nowTs);
            } else if (input.policy == AllocationPolicy.PRIORITY_WATERFALL) {
                _allocateWaterfall(input.obligations, paid, effective, nowTs);
            }
            // DEFER / PAUSE_THEN_DEFER intentionally leave `paid` at zero.
        }

        ClassAllocation[] memory classes = new ClassAllocation[](OBLIGATION_CLASS_COUNT);
        for (uint256 c = 0; c < OBLIGATION_CLASS_COUNT; c++) {
            classes[c].obligationClass = ObligationClass(c);
        }

        uint256 totalPaid = 0;
        for (uint256 i = 0; i < n; i++) {
            Obligation memory obligation = input.obligations[i];
            uint256 amount = obligation.amount;
            uint256 allocated = paid[i];
            uint256 deferred = amount - allocated;

            uint256 c = uint256(obligation.obligationClass);
            classes[c].owed += amount;
            classes[c].paid += allocated;
            classes[c].deferred += deferred;
            classes[c].obligationCount += 1;

            totalPaid += allocated;
        }

        uint256 totalDeferred = totalObligations - totalPaid;

        for (uint256 c = 0; c < OBLIGATION_CLASS_COUNT; c++) {
            if (classes[c].owed > 0) {
                classes[c].haircutBps = (classes[c].deferred * BPS) / classes[c].owed;
            }
        }

        // Fail-closed conservation and liquidity bounds.
        if (totalPaid + totalDeferred != totalObligations) {
            revert InvariantViolation("conservation", totalObligations, totalPaid + totalDeferred);
        }
        if (totalPaid > effective) {
            revert InvariantViolation("paid exceeds effective liquidity", effective, totalPaid);
        }

        report = InsolvencyReport({
            reportId: bytes32(0),
            scenario: input.scenario,
            policy: input.policy,
            totalLiquidity: liquidity,
            totalObligations: totalObligations,
            totalPaid: totalPaid,
            totalDeferred: totalDeferred,
            coverageBps: _coverageBps(liquidity, totalObligations),
            haircutBps: totalObligations == 0 ? 0 : (totalDeferred * BPS) / totalObligations,
            injectedCapital: input.recoveryInjection,
            solvent: liquidity >= totalObligations,
            paused: input.paused,
            fullyCovered: totalDeferred == 0,
            classAllocations: classes,
            timestamp: nowTs,
            blockNumber: block.number
        });

        return report;
    }

    /// @dev Coverage ratio in basis points, capped at `BPS`. Plain checked
    ///      arithmetic: absurd inputs that would overflow revert fail-closed.
    function _coverageBps(uint256 liquidity, uint256 totalObligations) internal pure returns (uint256) {
        if (totalObligations == 0) return BPS;
        uint256 coverage = (liquidity * BPS) / totalObligations;
        return coverage > BPS ? BPS : coverage;
    }

    /**
     * @dev Pro-rata allocation across every obligation that is due this run.
     *      `paid_i = floor(liquidity * amount_i / dueTotal)`, capped at `amount_i`.
     *      The residual (`liquidity - sum(paid)`) is retained, never distributed.
     */
    function _allocateProRata(Obligation[] memory obligations, uint256[] memory paid, uint256 liquidity, uint256 nowTs)
        internal
        pure
    {
        uint256 dueTotal = 0;
        uint256 n = obligations.length;
        for (uint256 i = 0; i < n; i++) {
            if (obligations[i].dueAt <= nowTs) {
                dueTotal += obligations[i].amount;
            }
        }
        if (dueTotal == 0) return;

        for (uint256 i = 0; i < n; i++) {
            Obligation memory obligation = obligations[i];
            if (obligation.dueAt > nowTs) continue;

            uint256 allocated = (liquidity * obligation.amount) / dueTotal;
            if (allocated > obligation.amount) {
                allocated = obligation.amount;
            }
            paid[i] = allocated;
        }
    }

    /**
     * @dev Senior-first waterfall. Fully funds each due class while liquidity
     *      allows; the first underfunded class is paid pro-rata; every junior
     *      class is deferred with zero allocation.
     */
    function _allocateWaterfall(
        Obligation[] memory obligations,
        uint256[] memory paid,
        uint256 liquidity,
        uint256 nowTs
    ) internal pure {
        uint256 remaining = liquidity;
        uint256 n = obligations.length;

        for (uint256 c = 0; c < OBLIGATION_CLASS_COUNT; c++) {
            if (remaining == 0) return;

            uint256 dueOwed = 0;
            for (uint256 i = 0; i < n; i++) {
                if (uint256(obligations[i].obligationClass) == c && obligations[i].dueAt <= nowTs) {
                    dueOwed += obligations[i].amount;
                }
            }
            if (dueOwed == 0) continue;

            if (remaining >= dueOwed) {
                for (uint256 i = 0; i < n; i++) {
                    if (uint256(obligations[i].obligationClass) == c && obligations[i].dueAt <= nowTs) {
                        paid[i] = obligations[i].amount;
                    }
                }
                remaining -= dueOwed;
            } else {
                for (uint256 i = 0; i < n; i++) {
                    if (uint256(obligations[i].obligationClass) == c && obligations[i].dueAt <= nowTs) {
                        paid[i] = (remaining * obligations[i].amount) / dueOwed;
                    }
                }
                return;
            }
        }
    }

    /**
     * @dev Build a one-entry-per-class obligation ledger from a base report's
     *      deferred buckets. Bounded by `OBLIGATION_CLASS_COUNT`.
     */
    function _deferredObligations(bytes32 baseReportId, InsolvencyReport storage baseReport)
        internal
        view
        returns (Obligation[] memory obligations)
    {
        Obligation[] memory scratch = new Obligation[](OBLIGATION_CLASS_COUNT);
        uint256 count = 0;

        for (uint256 c = 0; c < OBLIGATION_CLASS_COUNT; c++) {
            uint256 deferred = baseReport.classAllocations[c].deferred;
            if (deferred == 0) continue;
            scratch[count] = Obligation({
                obligationId: keccak256(abi.encode(baseReportId, c, "deferred")),
                obligationClass: ObligationClass(c),
                amount: deferred,
                dueAt: baseReport.timestamp
            });
            count++;
        }

        obligations = new Obligation[](count);
        for (uint256 i = 0; i < count; i++) {
            obligations[i] = scratch[i];
        }
    }

    /**
     * @dev Content-addressed, replay-resistant report id.
     *
     *      This is deliberately NOT a randomness source: it is an equality /
     *      dedup key whose uniqueness is guaranteed by the monotonic
     *      `_reportCounter` (block context is stored in the report itself, not
     *      mixed into the key). Nothing in the protocol relies on this value
     *      being unpredictable.
     */
    function _computeReportId(InsolvencyInput memory input, uint256 counter) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                input.scenario,
                input.policy,
                input.availableByPool,
                input.obligations,
                input.allocationCap,
                input.recoveryInjection,
                input.paused,
                counter
            )
        );
    }

    // =========================================================================
    // Validation
    // =========================================================================

    /// @inheritdoc ITreasuryInsolvencyModel
    function validateInput(InsolvencyInput calldata input)
        external
        pure
        override
        returns (string[] memory warnings, bool safe)
    {
        return _validate(input);
    }

    /**
     * @dev Structural validation. Every rule is fail-closed and returns a
     *      machine-readable reason rather than silently accepting ambiguity.
     */
    function _validate(InsolvencyInput memory input) internal pure returns (string[] memory warnings, bool safe) {
        string[] memory scratch = new string[](MAX_WARNINGS);
        uint256 w = 0;

        uint256 n = input.obligations.length;
        if (n == 0) {
            scratch[w++] = "NO_OBLIGATIONS";
        } else if (n > MAX_OBLIGATIONS) {
            scratch[w++] = "TOO_MANY_OBLIGATIONS";
        }

        for (uint256 i = 0; i < n && w < MAX_WARNINGS; i++) {
            if (input.obligations[i].obligationId == bytes32(0)) {
                scratch[w++] = "ZERO_OBLIGATION_ID";
                break;
            }
        }
        for (uint256 i = 0; i < n && w < MAX_WARNINGS; i++) {
            if (input.obligations[i].amount == 0) {
                scratch[w++] = "ZERO_OBLIGATION_AMOUNT";
                break;
            }
        }

        // Pause / policy consistency.
        if (input.paused != (input.policy == AllocationPolicy.PAUSE_THEN_DEFER)) {
            if (w < MAX_WARNINGS) scratch[w++] = "PAUSE_POLICY_MISMATCH";
        }
        if (input.paused && input.scenario != Scenario.EMERGENCY_PAUSE) {
            if (w < MAX_WARNINGS) scratch[w++] = "PAUSE_REQUIRES_EMERGENCY_SCENARIO";
        }
        if (input.scenario == Scenario.EMERGENCY_PAUSE && !input.paused) {
            if (w < MAX_WARNINGS) scratch[w++] = "EMERGENCY_SCENARIO_REQUIRES_PAUSE";
        }

        // Recovery-injection scoping.
        if (input.scenario == Scenario.GOVERNANCE_RECOVERY) {
            if (input.recoveryInjection == 0 && w < MAX_WARNINGS) scratch[w++] = "RECOVERY_REQUIRES_INJECTION";
        } else if (input.recoveryInjection != 0) {
            if (w < MAX_WARNINGS) scratch[w++] = "INJECTION_NOT_ALLOWED";
        }

        // Allocation-cap scoping.
        if (input.scenario == Scenario.DELAYED_ALLOCATION) {
            if (input.allocationCap == 0 && w < MAX_WARNINGS) scratch[w++] = "DELAYED_ALLOCATION_REQUIRES_CAP";
        } else if (input.allocationCap != 0) {
            if (w < MAX_WARNINGS) scratch[w++] = "UNEXPECTED_ALLOCATION_CAP";
        }

        // A paused run must not also defer explicitly (that is the pause policy).
        if (input.paused && input.policy != AllocationPolicy.PAUSE_THEN_DEFER) {
            if (w < MAX_WARNINGS) scratch[w++] = "PAUSED_REQUIRES_PAUSE_POLICY";
        }

        warnings = new string[](w);
        for (uint256 i = 0; i < w; i++) {
            warnings[i] = scratch[i];
        }
        safe = w == 0;
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @inheritdoc ITreasuryInsolvencyModel
    function getReport(bytes32 reportId) external view override returns (InsolvencyReport memory report) {
        report = _reports[reportId];
        if (report.timestamp == 0) revert ReportNotFound(reportId);
    }

    /// @inheritdoc ITreasuryInsolvencyModel
    function getReportCount() external view override returns (uint256) {
        return _reportIds.length;
    }

    /// @inheritdoc ITreasuryInsolvencyModel
    function getReportsPaginated(uint256 offset, uint256 limit) external view override returns (bytes32[] memory ids) {
        if (limit > MAX_REPORTS_PER_QUERY) limit = MAX_REPORTS_PER_QUERY;

        uint256 total = _reportIds.length;
        if (offset >= total) return new bytes32[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        ids = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = _reportIds[i];
        }
    }

    /// @inheritdoc ITreasuryInsolvencyModel
    function isReconciled(bytes32 baseReportId) external view override returns (bool) {
        return _reconciledBy[baseReportId] != bytes32(0);
    }

    /// @inheritdoc ITreasuryInsolvencyModel
    function getRecoveryReportId(bytes32 baseReportId) external view override returns (bytes32) {
        return _reconciledBy[baseReportId];
    }

    /// @inheritdoc ITreasuryInsolvencyModel
    function getAvailableScenarios() external pure override returns (Scenario[] memory scenarios) {
        scenarios = new Scenario[](7);
        scenarios[0] = Scenario.SOLVENT_BASELINE;
        scenarios[1] = Scenario.INSUFFICIENT_LIQUIDITY;
        scenarios[2] = Scenario.DELAYED_ALLOCATION;
        scenarios[3] = Scenario.PARTIAL_OBLIGATION;
        scenarios[4] = Scenario.EMERGENCY_PAUSE;
        scenarios[5] = Scenario.GOVERNANCE_RECOVERY;
        scenarios[6] = Scenario.POST_RECOVERY_RECONCILIATION;
    }

    /// @inheritdoc ITreasuryInsolvencyModel
    function getScenarioName(Scenario scenario) external pure override returns (string memory name) {
        if (scenario == Scenario.SOLVENT_BASELINE) return "Solvent Baseline";
        if (scenario == Scenario.INSUFFICIENT_LIQUIDITY) return "Insufficient Liquidity";
        if (scenario == Scenario.DELAYED_ALLOCATION) return "Delayed Allocation";
        if (scenario == Scenario.PARTIAL_OBLIGATION) return "Partial Obligation";
        if (scenario == Scenario.EMERGENCY_PAUSE) return "Emergency Pause";
        if (scenario == Scenario.GOVERNANCE_RECOVERY) return "Governance Recovery";
        if (scenario == Scenario.POST_RECOVERY_RECONCILIATION) return "Post-Recovery Reconciliation";
        return "Unknown";
    }

    /// @inheritdoc ITreasuryInsolvencyModel
    function getScenarioDescription(Scenario scenario) external pure override returns (string memory description) {
        if (scenario == Scenario.SOLVENT_BASELINE) {
            return "Control run: liquidity fully covers obligations, zero haircut, zero deferral.";
        }
        if (scenario == Scenario.INSUFFICIENT_LIQUIDITY) {
            return "Assets fall below obligations; a single deterministic haircut is applied.";
        }
        if (scenario == Scenario.DELAYED_ALLOCATION) {
            return "Not-yet-due obligations and a per-epoch allocation cap defer part of the ledger.";
        }
        if (scenario == Scenario.PARTIAL_OBLIGATION) {
            return "Liquidity funds the marginal class only in part; the remainder is deferred.";
        }
        if (scenario == Scenario.EMERGENCY_PAUSE) {
            return "Allocations are frozen; every obligation is deferred pending recovery.";
        }
        if (scenario == Scenario.GOVERNANCE_RECOVERY) {
            return "Governance injects recovery capital, restoring coverage for the ledger.";
        }
        if (scenario == Scenario.POST_RECOVERY_RECONCILIATION) {
            return "Deferred buckets are settled from injected capital exactly once and reconciled.";
        }
        return "";
    }

    /// @inheritdoc ITreasuryInsolvencyModel
    function getPolicyName(AllocationPolicy policy) external pure override returns (string memory name) {
        if (policy == AllocationPolicy.PRO_RATA) return "Pro-Rata Haircut";
        if (policy == AllocationPolicy.PRIORITY_WATERFALL) return "Priority Waterfall";
        if (policy == AllocationPolicy.DEFER) return "Defer All";
        if (policy == AllocationPolicy.PAUSE_THEN_DEFER) return "Pause Then Defer";
        return "Unknown";
    }

    /// @inheritdoc ITreasuryInsolvencyModel
    function getMaxObligations() external pure override returns (uint256) {
        return MAX_OBLIGATIONS;
    }

    // =========================================================================
    // Administration
    // =========================================================================

    /// @inheritdoc ITreasuryInsolvencyModel
    function setThreshold(bytes32 metricId, uint256 threshold) external override onlyRole(ADMIN_ROLE) {
        uint256 old = thresholds[metricId];
        thresholds[metricId] = threshold;
        emit ThresholdUpdated(metricId, old, threshold);
    }

    /// @notice Pause the model surface (does not affect protocol contracts).
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause the model surface.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
