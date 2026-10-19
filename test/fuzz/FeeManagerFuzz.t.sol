// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/fees/FeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title FeeManagerFuzz
 * @notice Foundry fuzz tests for the FeeManager contract (SC-028)
 *
 * Fuzz vectors:
 *   - Random fee amounts
 *   - Random basis-point percentages
 *   - Random transaction volume
 *   - Random governance updates
 *
 * All fuzz runs verify deterministic, consistent accounting.
 */
contract FeeManagerFuzz is Test {
    // ── Contracts ──────────────────────────────────────────────────────────────

    FeeManager  public feeManager;
    MockFeeToken public feeToken;

    // ── Actors ────────────────────────────────────────────────────────────────

    address public admin        = address(0xAD01);
    address public collector    = address(0xC011);
    address public payer        = address(0xAB01);
    address public treasury     = address(0xF001);
    address public security     = address(0xF002);
    address public ecosystem    = address(0xF003);
    address public contributors = address(0xF004);
    address public emergency    = address(0xF005);

    // ── Constants ─────────────────────────────────────────────────────────────

    bytes32 public constant CLAIM_SUBMISSION_FEE = keccak256("CLAIM_SUBMISSION_FEE");
    bytes32 public constant CLAIM_UPDATE_FEE      = keccak256("CLAIM_UPDATE_FEE");
    bytes32 public constant VERIFICATION_FEE      = keccak256("VERIFICATION_SUBMISSION_FEE");
    bytes32 public constant PROTOCOL_RESERVE_FEE  = keccak256("PROTOCOL_RESERVE_FEE");

    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    bytes32 public constant ADMIN_ROLE     = keccak256("ADMIN_ROLE");

    uint256 public constant TOKEN_SUPPLY = 1_000_000_000e18;

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(admin);

        feeToken = new MockFeeToken();
        feeToken.mint(payer, TOKEN_SUPPLY);

        feeManager = new FeeManager(
            address(feeToken),
            admin,
            address(0),
            treasury,
            security,
            ecosystem,
            contributors,
            emergency
        );

        feeManager.grantRole(COLLECTOR_ROLE, collector);

        vm.stopPrank();

        vm.prank(payer);
        feeToken.approve(address(feeManager), TOKEN_SUPPLY);
    }

    // ── Fuzz: Fee Collection ───────────────────────────────────────────────────

    /**
     * @notice Any fee amount within schedule bounds should be collected
     *         without reverting and the accounting must remain consistent.
     */
    function testFuzz_CollectFee_AccountingConsistency(uint256 amount) public {
        // Bound to a reasonable range that satisfies default schedule (no min/max set)
        amount = bound(amount, 1, 10_000e18);

        uint256 payerBefore  = feeToken.balanceOf(payer);
        uint256 totalBefore  = feeManager.getTotalFeesCollected();

        vm.prank(collector);
        feeManager.collectFee(CLAIM_SUBMISSION_FEE, payer, amount);

        uint256 payerAfter  = feeToken.balanceOf(payer);
        uint256 totalAfter  = feeManager.getTotalFeesCollected();

        // Payer lost exactly `amount`
        assertEq(payerBefore - payerAfter, amount, "Payer balance delta mismatch");

        // Total fees collected increased by `amount`
        assertEq(totalAfter - totalBefore, amount, "Total collected delta mismatch");

        // Type-specific accounting also updated
        assertGe(feeManager.getFeesByType(CLAIM_SUBMISSION_FEE), amount, "Type accounting underflow");
    }

    /**
     * @notice Multiple consecutive collections must all be reflected in totals
     *         and a single fee record must be created per call.
     */
    function testFuzz_MultipleCollections_RecordCount(uint8 numCalls, uint256 baseAmount) public {
        numCalls   = uint8(bound(numCalls,   1,  20));
        baseAmount = bound(baseAmount, 1e15, 100e18);

        vm.startPrank(collector);
        for (uint256 i = 0; i < numCalls; i++) {
            feeManager.collectFee(CLAIM_SUBMISSION_FEE, payer, baseAmount);
        }
        vm.stopPrank();

        assertEq(feeManager.getFeeRecordCount(), numCalls, "Record count mismatch");
        assertEq(
            feeManager.getTotalFeesCollected(),
            baseAmount * numCalls,
            "Total collected mismatch"
        );
    }

    /**
     * @notice Collected fees must equal distributed fees plus retained balance
     *         (core invariant: no funds are lost or created).
     */
    function testFuzz_Invariant_CollectedEqualsDistributedPlusRetained(
        uint256 amount1,
        uint256 amount2,
        uint256 amount3
    ) public {
        amount1 = bound(amount1, 1e15, 5_000e18);
        amount2 = bound(amount2, 1e15, 5_000e18);
        amount3 = bound(amount3, 1e15, 5_000e18);

        vm.startPrank(collector);
        feeManager.collectFee(CLAIM_SUBMISSION_FEE, payer, amount1);
        feeManager.collectFee(CLAIM_UPDATE_FEE,     payer, amount2);
        feeManager.collectFee(VERIFICATION_FEE,     payer, amount3);
        vm.stopPrank();

        uint256 totalCollected  = feeManager.getTotalFeesCollected();
        uint256 totalDistributed = feeManager.getTotalFeesDistributed();
        uint256 retained        = feeManager.getRetainedBalance();

        assertEq(
            totalCollected,
            totalDistributed + retained,
            "Accounting invariant violated"
        );
    }

    /**
     * @notice Distribution routing: sum of all allocation amounts received
     *         must equal the fee collected.
     */
    function testFuzz_Distribution_SumEqualsCollected(uint256 amount) public {
        amount = bound(amount, 10_000, 1_000_000e18); // Large enough to avoid rounding gaps

        uint256 tBefore = feeToken.balanceOf(treasury);
        uint256 sBefore = feeToken.balanceOf(security);
        uint256 eBefore = feeToken.balanceOf(ecosystem);
        uint256 cBefore = feeToken.balanceOf(contributors);
        uint256 emBefore = feeToken.balanceOf(emergency);

        vm.startPrank(collector);
        feeManager.collectFee(CLAIM_SUBMISSION_FEE, payer, amount);
        // Fees are reserved on collection; COLLECTOR_ROLE routes them in one batch.
        feeManager.distributeReservedFees();
        vm.stopPrank();

        uint256 received =
            (feeToken.balanceOf(treasury)     - tBefore)  +
            (feeToken.balanceOf(security)     - sBefore)  +
            (feeToken.balanceOf(ecosystem)    - eBefore)  +
            (feeToken.balanceOf(contributors) - cBefore)  +
            (feeToken.balanceOf(emergency)    - emBefore);

        // The canonical TREASURY_RESERVE allocation absorbs integer-division dust,
        // so the routed sum is exactly the collected amount — never more, never less.
        assertEq(received, amount, "Conservation violated: sum of shares != collected");
    }

    /**
     * @notice Fee calculation must respect the fee schedule bounds at all times.
     */
    function testFuzz_CalculateFee_RespectsBounds(
        uint256 baseAmount,
        uint256 bps,
        uint256 minVal,
        uint256 maxVal
    ) public {
        bps     = bound(bps,    0, 10000);
        minVal  = bound(minVal, 0, 1_000e18);
        maxVal  = bound(maxVal, minVal > 0 ? minVal : 0, 10_000e18);
        if (maxVal == 0) maxVal = 10_000e18; // treat 0 as uncapped in assertion
        baseAmount = bound(baseAmount, 0, 100_000e18);

        vm.prank(admin);
        feeManager.updateFeeSchedule(CLAIM_SUBMISSION_FEE, 0, bps, minVal, maxVal == 10_000e18 ? 0 : maxVal);

        uint256 fee = feeManager.calculateFee(CLAIM_SUBMISSION_FEE, baseAmount);

        if (minVal > 0) {
            assertGe(fee, minVal, "Fee below minimum");
        }
        if (maxVal < 10_000e18) {
            assertLe(fee, maxVal, "Fee above maximum");
        }
    }

    /**
     * @notice Governance version must increment monotonically with each update.
     */
    function testFuzz_GovernanceVersion_MonotonicallyIncreases(uint8 numUpdates) public {
        numUpdates = uint8(bound(numUpdates, 1, 20));

        uint256 vBefore = feeManager.globalGovVersion();

        vm.startPrank(admin);
        for (uint256 i = 0; i < numUpdates; i++) {
            feeManager.updateFeeSchedule(CLAIM_SUBMISSION_FEE, i * 1e15, 0, 0, 0);
        }
        vm.stopPrank();

        uint256 vAfter = feeManager.globalGovVersion();
        assertEq(vAfter, vBefore + numUpdates, "Governance version not monotonic");
    }

    /**
     * @notice Fee schedule update must archive the previous schedule correctly.
     */
    function testFuzz_FeeScheduleArchival_PreservesOldValue(uint256 newFixed) public {
        newFixed = bound(newFixed, 1, 1_000e18);

        IFeeManager.FeeSchedule memory before = feeManager.getFeeSchedule(CLAIM_SUBMISSION_FEE);
        uint256 vBefore = feeManager.feeScheduleVersion(CLAIM_SUBMISSION_FEE);

        vm.prank(admin);
        feeManager.updateFeeSchedule(CLAIM_SUBMISSION_FEE, newFixed, 0, 0, 0);

        IFeeManager.FeeSchedule memory archived = feeManager.getFeeScheduleAtVersion(
            CLAIM_SUBMISSION_FEE,
            vBefore
        );

        assertEq(archived.fixedAmount, before.fixedAmount, "Archived schedule mismatch");
    }

    /**
     * @notice Zero-amount collections must revert — never silently succeed.
     */
    function testFuzz_ZeroAmount_AlwaysReverts(bytes32 feeType) public {
        vm.prank(collector);
        vm.expectRevert();
        feeManager.collectFee(feeType, payer, 0);
    }

    /**
     * @notice Inactive fee types must reject collections regardless of amount.
     */
    function testFuzz_InactiveFeeType_AlwaysReverts(uint256 amount) public {
        amount = bound(amount, 1, 1_000e18);

        vm.prank(admin);
        feeManager.setFeeActive(CLAIM_SUBMISSION_FEE, false);

        vm.prank(collector);
        vm.expectRevert();
        feeManager.collectFee(CLAIM_SUBMISSION_FEE, payer, amount);
    }
}

// ── Mock ERC20 ────────────────────────────────────────────────────────────────

contract MockFeeToken is ERC20 {
    constructor() ERC20("MockFeeToken", "MFT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
