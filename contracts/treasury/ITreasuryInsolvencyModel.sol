// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ITreasuryInsolvencyModel
 * @notice Interface for the Treasury Insolvency & Recovery Model (V2-SC-107).
 * @dev The model is an *advisory*, isolated simulation surface. It holds no
 *      protocol tokens, exposes no transfer path, and can never mutate live
 *      treasury balances. It exists so that insufficient liquidity, delayed
 *      allocation, partial obligations, emergency pause, governance recovery,
 *      and post-recovery reconciliation can be projected deterministically and
 *      reconciled against the canonical `TreasuryManagement` pool ledger.
 *
 *      Liquidity snapshots are expressed as a fixed seven-slot array indexed by
 *      `ITreasuryManagement.TreasuryPool`:
 *
 *      | index | pool                |
 *      |-------|---------------------|
 *      |   0   | STAKING_RESERVE     |
 *      |   1   | REWARDS_POOL        |
 *      |   2   | SLASHING_RESERVE    |
 *      |   3   | PROTOCOL_FEES       |
 *      |   4   | GOVERNANCE_RESERVE  |
 *      |   5   | ECOSYSTEM_FUND      |
 *      |   6   | EMERGENCY_RESERVE   |
 *
 *      The model never authorises value movement. Production settlement remains
 *      pull-based and authoritative in the Optimism/EVM protocol contracts.
 */
interface ITreasuryInsolvencyModel {
    // =========================================================================
    // Enums
    // =========================================================================

    /**
     * @notice Priority class of an obligation, ordered senior → junior.
     * @dev The numeric order is the canonical waterfall order. SENIOR classes
     *      (SETTLEMENT, STAKING_PRINCIPAL, INSURANCE) are user-facing principal
     *      and loss-recovery obligations; JUNIOR classes (REWARDS, OPERATIONAL,
     *      DISCRETIONARY) are protocol-funded and absorb shortfall first.
     */
    enum ObligationClass {
        SETTLEMENT, // 0 — claim settlement payouts (highest priority)
        STAKING_PRINCIPAL, // 1 — staker principal withdrawals
        INSURANCE, // 2 — insurance fund claim payouts
        REWARDS, // 3 — verifier reward distributions
        OPERATIONAL, // 4 — ecosystem / operational spend
        DISCRETIONARY // 5 — governance discretionary spend (lowest priority)
    }

    /**
     * @notice Deterministic shortfall (haircut) policy applied by the model.
     * @dev The policy fully determines who is paid and by how much, so no
     *      haircut ambiguity can remain:
     *      - PRO_RATA: every due obligation receives `floor(liquidity * amount / dueTotal)`.
     *        Rounding residual is retained (protocol-favouring rounding) and never
     *        over-pays an obligation.
     *      - PRIORITY_WATERFALL: senior classes are funded in full, the first
     *        underfunded class is paid pro-rata, all junior classes are deferred.
     *      - DEFER: nothing is allocated this run; every obligation is deferred.
     *      - PAUSE_THEN_DEFER: emergency freeze; identical to DEFER but records
     *        that allocations were halted by an emergency pause.
     */
    enum AllocationPolicy {
        PRO_RATA,
        PRIORITY_WATERFALL,
        DEFER,
        PAUSE_THEN_DEFER
    }

    /**
     * @notice Predefined stress scenarios modelled by V2-SC-107.
     */
    enum Scenario {
        SOLVENT_BASELINE, // control: full coverage, no injection
        INSUFFICIENT_LIQUIDITY, // assets < obligations, single-shot haircut
        DELAYED_ALLOCATION, // obligations not yet due / per-epoch budget cap
        PARTIAL_OBLIGATION, // a single obligation only partially funded
        EMERGENCY_PAUSE, // allocations frozen, everything deferred
        GOVERNANCE_RECOVERY, // governance injection restores coverage
        POST_RECOVERY_RECONCILIATION // deferred ledger settled from injected capital
    }

    // =========================================================================
    // Structs
    // =========================================================================

    /**
     * @notice A single modelled obligation against the treasury.
     * @param obligationId Stable caller-supplied identifier used for off-chain projection.
     * @param obligationClass Priority class (see {ObligationClass}).
     * @param amount Amount owed, in token units.
     * @param dueAt Timestamp at which the obligation becomes allocatable. Obligations
     *              whose `dueAt` is in the future are deferred for this run and model
     *              delayed allocation. `0` means already due.
     */
    struct Obligation {
        bytes32 obligationId;
        ObligationClass obligationClass;
        uint256 amount;
        uint256 dueAt;
    }

    /**
     * @notice Input to a model run.
     * @param scenario The stress scenario being modelled.
     * @param policy The deterministic shortfall policy to apply.
     * @param availableByPool Liquidity snapshot indexed by `ITreasuryManagement.TreasuryPool`.
     * @param obligations The obligation ledger to allocate against.
     * @param allocationCap Maximum total allocatable this run (0 = uncapped). Models
     *                      per-epoch release budgets / governance timelocks.
     * @param recoveryInjection Governance recovery capital, only for GOVERNANCE_RECOVERY.
     * @param paused Whether an emergency pause is in force (only for EMERGENCY_PAUSE).
     */
    struct InsolvencyInput {
        Scenario scenario;
        AllocationPolicy policy;
        uint256[7] availableByPool;
        Obligation[] obligations;
        uint256 allocationCap;
        uint256 recoveryInjection;
        bool paused;
    }

    /**
     * @notice Per-class projection bucket.
     * @param obligationClass Priority class.
     * @param owed Total owed in this class.
     * @param paid Total allocated to this class.
     * @param deferred Total left outstanding in this class.
     * @param haircutBps `deferred / owed` in basis points (0 when `owed == 0`).
     * @param obligationCount Number of obligations observed in this class.
     */
    struct ClassAllocation {
        ObligationClass obligationClass;
        uint256 owed;
        uint256 paid;
        uint256 deferred;
        uint256 haircutBps;
        uint256 obligationCount;
    }

    /**
     * @notice Immutable, machine-readable output of a model run.
     * @param reportId Content-addressed id of this run (unique per run).
     * @param scenario The modelled scenario.
     * @param policy The policy applied.
     * @param totalLiquidity Total available liquidity including any injection.
     * @param totalObligations Total owed across all obligations.
     * @param totalPaid Total allocated this run.
     * @param totalDeferred Total left outstanding (`totalObligations - totalPaid`).
     * @param coverageBps `min(totalLiquidity, totalObligations) / totalObligations` in BPS.
     * @param haircutBps `totalDeferred / totalObligations` in BPS.
     * @param injectedCapital Recovery capital injected for this run.
     * @param solvent Whether liquidity covers all obligations.
     * @param paused Whether an emergency pause was in force.
     * @param fullyCovered Whether every obligation was fully allocated.
     * @param classAllocations Per-class breakdown (always six entries, senior → junior).
     * @param timestamp Block timestamp of the run.
     * @param blockNumber Block number of the run.
     */
    struct InsolvencyReport {
        bytes32 reportId;
        Scenario scenario;
        AllocationPolicy policy;
        uint256 totalLiquidity;
        uint256 totalObligations;
        uint256 totalPaid;
        uint256 totalDeferred;
        uint256 coverageBps;
        uint256 haircutBps;
        uint256 injectedCapital;
        bool solvent;
        bool paused;
        bool fullyCovered;
        ClassAllocation[] classAllocations;
        uint256 timestamp;
        uint256 blockNumber;
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a model run is persisted.
    event ReportGenerated(
        bytes32 indexed reportId,
        Scenario indexed scenario,
        AllocationPolicy indexed policy,
        uint256 totalLiquidity,
        uint256 totalObligations,
        uint256 totalPaid,
        uint256 totalDeferred,
        uint256 haircutBps,
        bool solvent
    );

    /// @notice Emitted when modelled liquidity does not cover obligations.
    event InsolvencyDetected(bytes32 indexed reportId, uint256 shortfall);

    /// @notice Emitted when a base report is reconciled with recovery capital.
    event RecoveryReconciled(
        bytes32 indexed baseReportId,
        bytes32 indexed recoveryReportId,
        uint256 injectedCapital,
        uint256 totalPaid,
        uint256 totalDeferred
    );

    /// @notice Emitted when a configured threshold is breached by a run.
    event ModelThresholdExceeded(bytes32 indexed metricId, uint256 value);

    /// @notice Emitted when an admin threshold is updated.
    event ThresholdUpdated(bytes32 indexed metricId, uint256 oldValue, uint256 newValue);

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroAddress();
    error ZeroAmount();
    error NoObligations();
    error TooManyObligations(uint256 provided, uint256 maximum);
    error InvalidInput(string reason);
    error ReportNotFound(bytes32 reportId);
    error ReportAlreadyReconciled(bytes32 baseReportId, bytes32 existingRecoveryReportId);
    error NothingToReconcile(bytes32 baseReportId);
    error InvalidRecoveryPolicy(AllocationPolicy policy);
    error InvariantViolation(string reason, uint256 expected, uint256 actual);

    // =========================================================================
    // Core Functions
    // =========================================================================

    /**
     * @notice Validate and persist a model run. Stores an append-only report.
     * @param input The model input.
     * @return report The persisted report.
     */
    function runModel(InsolvencyInput calldata input) external returns (InsolvencyReport memory report);

    /**
     * @notice Compute a model run without persisting state.
     * @param input The model input.
     * @return report The computed report (with `reportId == bytes32(0)`).
     */
    function previewModel(InsolvencyInput calldata input) external view returns (InsolvencyReport memory report);

    /**
     * @notice Reconcile a previously deferred base report with recovery capital.
     * @dev Write-once per base report: a base report can be reconciled at most once,
     *      which is the replay guard for governance recovery.
     * @param baseReportId The report whose deferred ledger is being recovered.
     * @param recoveryInjection Recovery capital available for allocation.
     * @param recoveryPolicy Allocation policy applied to the deferred ledger. Must allocate.
     * @return report The persisted reconciliation report.
     */
    function reconcile(bytes32 baseReportId, uint256 recoveryInjection, AllocationPolicy recoveryPolicy)
        external
        returns (InsolvencyReport memory report);

    // =========================================================================
    // View Functions
    // =========================================================================

    /**
     * @notice Validate an input and return machine-readable reasons if unsafe.
     * @return warnings Human-readable/machine-parsable warning strings (empty when safe).
     * @return safe True when the input satisfies every structural rule.
     */
    function validateInput(InsolvencyInput calldata input) external view returns (string[] memory warnings, bool safe);

    /// @notice Get a stored report by id.
    function getReport(bytes32 reportId) external view returns (InsolvencyReport memory report);

    /// @notice Get the number of persisted reports.
    function getReportCount() external view returns (uint256);

    /// @notice Get page of report ids in insertion order.
    function getReportsPaginated(uint256 offset, uint256 limit) external view returns (bytes32[] memory ids);

    /// @notice Whether a base report has been reconciled.
    function isReconciled(bytes32 baseReportId) external view returns (bool);

    /// @notice Recovery report id for a reconciled base report, or `bytes32(0)`.
    function getRecoveryReportId(bytes32 baseReportId) external view returns (bytes32);

    /// @notice Get every available scenario.
    function getAvailableScenarios() external pure returns (Scenario[] memory scenarios);

    /// @notice Human-readable scenario name.
    function getScenarioName(Scenario scenario) external pure returns (string memory name);

    /// @notice Human-readable scenario description.
    function getScenarioDescription(Scenario scenario) external pure returns (string memory description);

    /// @notice Human-readable allocation policy name.
    function getPolicyName(AllocationPolicy policy) external pure returns (string memory name);

    /// @notice Maximum obligations accepted by a single run.
    function getMaxObligations() external pure returns (uint256);

    /**
     * @notice Set a warning threshold for a metric.
     * @param metricId keccak256 identifier of the metric.
     * @param threshold Value that triggers a warning when breached.
     */
    function setThreshold(bytes32 metricId, uint256 threshold) external;
}
