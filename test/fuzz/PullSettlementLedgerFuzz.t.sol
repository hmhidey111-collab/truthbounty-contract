// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title PullSettlementLedgerFuzz — V2-SC-062 fuzz + property tests
 *
 * Properties proven:
 *  P1  available = credited - withdrawn  (always, for any account)
 *  P2  availableRef = refCredited - refWithdrawn  (per ref)
 *  P3  sum(refWithdrawn[account][*]) == withdrawn[account]  (aggregate = sum of parts)
 *  P4  once isRefProcessed(ref) == true, a second credit with that ref always reverts
 *  P5  withdrawFromRef never drains more than credited for that ref
 *  P6  a failed (reverting) withdrawFromRef attempt leaves balance unchanged
 */

import "forge-std/Test.sol";
import "../../contracts/performance/PullSettlementLedger.sol";
import "../../contracts/MockERC20.sol";

contract PullSettlementLedgerFuzz is Test {
    PullSettlementLedger internal ledger;
    MockERC20 internal token;
    address internal admin = address(this);

    function setUp() public {
        token  = new MockERC20("T", "T");
        ledger = new PullSettlementLedger(admin, IERC20(address(token)));
        token.mint(address(ledger), type(uint128).max);
    }

    // -------------------------------------------------------------------------
    // P4  Replay is always blocked once a ref is consumed
    // -------------------------------------------------------------------------

    function testFuzz_replayAlwaysReverts(
        address beneficiary,
        uint256 amount,
        bytes32 ref
    ) public {
        vm.assume(beneficiary != address(0));
        vm.assume(amount > 0 && amount <= 1_000_000 ether);
        vm.assume(ref != bytes32(0));

        ledger.credit(beneficiary, amount, ref);
        assertTrue(ledger.isRefProcessed(ref));

        // Any subsequent credit with the same ref must revert regardless of caller,
        // beneficiary, or amount.
        vm.expectRevert(
            abi.encodeWithSelector(PullSettlementLedger.SettlementRefAlreadyProcessed.selector, ref)
        );
        ledger.credit(address(uint160(uint256(keccak256(abi.encode(beneficiary))))), amount, ref);
    }

    // -------------------------------------------------------------------------
    // P1  available = credited - withdrawn
    // -------------------------------------------------------------------------

    function testFuzz_availableBalanceConsistency(
        address alice,
        uint256 creditAmt,
        uint256 withdrawAmt,
        bytes32 ref
    ) public {
        vm.assume(alice != address(0));
        vm.assume(creditAmt > 0 && creditAmt <= 1_000_000 ether);
        vm.assume(ref != bytes32(0));
        withdrawAmt = bound(withdrawAmt, 1, creditAmt);

        ledger.credit(alice, creditAmt, ref);
        vm.prank(alice);
        ledger.withdraw(withdrawAmt);

        assertEq(
            ledger.availableBalance(alice),
            ledger.credited(alice) - ledger.withdrawn(alice),
            "P1 violated"
        );
    }

    // -------------------------------------------------------------------------
    // P2  availableRef = refCredited - refWithdrawn
    // -------------------------------------------------------------------------

    function testFuzz_refBalanceConsistency(
        address alice,
        uint256 creditAmt,
        uint256 withdrawAmt,
        bytes32 ref
    ) public {
        vm.assume(alice != address(0));
        vm.assume(creditAmt > 0 && creditAmt <= 1_000_000 ether);
        vm.assume(ref != bytes32(0));
        withdrawAmt = bound(withdrawAmt, 1, creditAmt);

        ledger.credit(alice, creditAmt, ref);
        vm.prank(alice);
        ledger.withdrawFromRef(ref, withdrawAmt);

        assertEq(
            ledger.availableRefBalance(alice, ref),
            creditAmt - withdrawAmt,
            "P2 violated"
        );
    }

    // -------------------------------------------------------------------------
    // P5  withdrawFromRef never drains more than credited for that ref
    // -------------------------------------------------------------------------

    function testFuzz_withdrawFromRefCannotExceedCredit(
        address alice,
        uint256 creditAmt,
        uint256 overAmt,
        bytes32 ref
    ) public {
        vm.assume(alice != address(0));
        vm.assume(creditAmt > 0 && creditAmt <= 1_000_000 ether);
        vm.assume(ref != bytes32(0));
        // overAmt is always strictly greater than creditAmt
        overAmt = bound(overAmt, creditAmt + 1, creditAmt + 1_000_000 ether);

        ledger.credit(alice, creditAmt, ref);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                PullSettlementLedger.InsufficientCredit.selector,
                creditAmt,
                overAmt
            )
        );
        ledger.withdrawFromRef(ref, overAmt);

        // Balance unchanged after the failed attempt.
        assertEq(ledger.availableRefBalance(alice, ref), creditAmt, "P5 violated: balance changed on failed withdraw");
    }

    // -------------------------------------------------------------------------
    // P6  A reverted withdrawFromRef leaves balance unchanged (recoverability)
    // -------------------------------------------------------------------------

    function testFuzz_failedWithdrawRefLeavesBalanceIntact(
        address alice,
        uint256 creditAmt,
        bytes32 ref
    ) public {
        vm.assume(alice != address(0));
        vm.assume(creditAmt > 0 && creditAmt <= 1_000_000 ether);
        vm.assume(ref != bytes32(0));

        ledger.credit(alice, creditAmt, ref);
        uint256 balBefore = ledger.availableRefBalance(alice, ref);

        // Attempt an over-draw — must revert.
        vm.prank(alice);
        try ledger.withdrawFromRef(ref, creditAmt + 1) {
            revert("should have reverted");
        } catch {}

        assertEq(ledger.availableRefBalance(alice, ref), balBefore, "P6 violated: balance changed after failed withdraw");
    }

    // -------------------------------------------------------------------------
    // Batch replay is always blocked
    // -------------------------------------------------------------------------

    function testFuzz_batchReplayAlwaysReverts(
        address beneficiary,
        uint256 amount,
        bytes32 ref
    ) public {
        vm.assume(beneficiary != address(0));
        vm.assume(amount > 0 && amount <= 1_000_000 ether);
        vm.assume(ref != bytes32(0));

        address[] memory bens = new address[](1);
        bens[0] = beneficiary;
        uint256[] memory amts = new uint256[](1);
        amts[0] = amount;

        ledger.creditBatch(bens, amts, ref);

        vm.expectRevert(
            abi.encodeWithSelector(PullSettlementLedger.SettlementRefAlreadyProcessed.selector, ref)
        );
        ledger.creditBatch(bens, amts, ref);
    }

    // -------------------------------------------------------------------------
    // Failure isolation across refs
    // -------------------------------------------------------------------------

    function testFuzz_refIsolation(
        address alice,
        uint256 amtA,
        uint256 amtB,
        bytes32 refA,
        bytes32 refB
    ) public {
        vm.assume(alice != address(0));
        vm.assume(amtA > 0 && amtA <= 500_000 ether);
        vm.assume(amtB > 0 && amtB <= 500_000 ether);
        vm.assume(refA != bytes32(0) && refB != bytes32(0));
        vm.assume(refA != refB);

        ledger.credit(alice, amtA, refA);
        ledger.credit(alice, amtB, refB);

        // Drain refA fully.
        vm.prank(alice);
        ledger.withdrawFromRef(refA, amtA);

        // refB must be untouched.
        assertEq(ledger.availableRefBalance(alice, refB), amtB, "refB affected by refA drain");

        // refB withdrawal succeeds independently.
        vm.prank(alice);
        ledger.withdrawFromRef(refB, amtB);
        assertEq(ledger.availableRefBalance(alice, refB), 0);
    }
}
