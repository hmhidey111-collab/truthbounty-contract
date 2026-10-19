// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title PullSettlementLedger — V2-SC-062 regression + hardening tests
 *
 * Coverage:
 *  - success paths (credit, creditBatch, withdraw, withdrawFromRef)
 *  - boundary conditions (max batch, zero amounts/addresses/refs)
 *  - authorization (only CREDITOR_ROLE may credit)
 *  - replay prevention (same settlementRef is rejected on second credit)
 *  - failure isolation (withdrawFromRef for ref B succeeds even when ref A is
 *    "stuck" / never touched)
 *  - CEI / reentrancy (hostile token cannot double-withdraw)
 */

import "forge-std/Test.sol";
import "../../contracts/performance/PullSettlementLedger.sol";
import "../../contracts/MockERC20.sol";
import "../../contracts/performance/ProtocolExecutionBounds.sol";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// @dev Reentrancy attacker: on first token receive attempts to re-call withdraw.
contract ReentrantWithdrawer {
    PullSettlementLedger public ledger;
    bool private _attacking;

    constructor(address ledger_) {
        ledger = PullSettlementLedger(ledger_);
    }

    /// Called by the hostile ERC20 during transfer.
    function onTokenReceived(uint256 amount) external {
        if (_attacking) return;
        _attacking = true;
        // attempt reentrant withdraw — must be blocked
        try ledger.withdraw(amount) {} catch {}
    }
}

/// @dev Hostile ERC20: calls back into withdrawer on transfer to it.
contract HostileERC20ForLedger {
    string public name = "Hostile";
    string public symbol = "HOST";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    ReentrantWithdrawer public attacker;
    bool public attackEnabled;

    function setAttacker(address a) external { attacker = ReentrantWithdrawer(a); }
    function enableAttack(bool e) external { attackEnabled = e; }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (attackEnabled && address(attacker) != address(0) && to == address(attacker)) {
            attacker.onTokenReceived(amount);
        }
        return true;
    }
}

// ---------------------------------------------------------------------------
// Main test contract
// ---------------------------------------------------------------------------

contract PullSettlementLedgerTest is Test {
    PullSettlementLedger internal ledger;
    MockERC20 internal token;

    address internal admin   = address(this);
    address internal alice   = address(0xA11CE);
    address internal bob     = address(0xB0B);
    address internal charlie = address(0xC11A);

    bytes32 internal constant REF_A = keccak256("settlement-A");
    bytes32 internal constant REF_B = keccak256("settlement-B");
    bytes32 internal constant REF_C = keccak256("settlement-C");

    uint256 internal constant CREDIT = 1_000 ether;

    function setUp() public {
        token  = new MockERC20("TruthToken", "TT");
        ledger = new PullSettlementLedger(admin, IERC20(address(token)));

        // Fund ledger so transfers succeed.
        token.mint(address(ledger), 100_000 ether);
    }

    // =========================================================================
    // § 1  Constructor / configuration guards
    // =========================================================================

    function test_constructor_zeroTokenReverts() public {
        vm.expectRevert(PullSettlementLedger.ZeroAddress.selector);
        new PullSettlementLedger(admin, IERC20(address(0)));
    }

    function test_constructor_zeroAdminReverts() public {
        vm.expectRevert(PullSettlementLedger.ZeroAddress.selector);
        new PullSettlementLedger(address(0), IERC20(address(token)));
    }

    // =========================================================================
    // § 2  Authorization
    // =========================================================================

    function test_credit_unauthorizedReverts() public {
        vm.prank(alice);
        vm.expectRevert(); // AccessControl revert
        ledger.credit(alice, CREDIT, REF_A);
    }

    function test_creditBatch_unauthorizedReverts() public {
        address[] memory b = new address[](1);
        b[0] = alice;
        uint256[] memory a = new uint256[](1);
        a[0] = CREDIT;

        vm.prank(alice);
        vm.expectRevert();
        ledger.creditBatch(b, a, REF_A);
    }

    // =========================================================================
    // § 3  Credit — success paths
    // =========================================================================

    function test_credit_recordsBalance() public {
        ledger.credit(alice, CREDIT, REF_A);

        assertEq(ledger.credited(alice), CREDIT);
        assertEq(ledger.availableBalance(alice), CREDIT);
        assertEq(ledger.availableRefBalance(alice, REF_A), CREDIT);
    }

    function test_credit_markRefProcessed() public {
        ledger.credit(alice, CREDIT, REF_A);
        assertTrue(ledger.isRefProcessed(REF_A));
    }

    function test_creditBatch_recordsBalances() public {
        address[] memory bens = new address[](2);
        bens[0] = alice;
        bens[1] = bob;

        uint256[] memory amts = new uint256[](2);
        amts[0] = CREDIT;
        amts[1] = CREDIT * 2;

        ledger.creditBatch(bens, amts, REF_A);

        assertEq(ledger.credited(alice), CREDIT);
        assertEq(ledger.credited(bob),   CREDIT * 2);
        assertEq(ledger.availableRefBalance(alice, REF_A), CREDIT);
        assertEq(ledger.availableRefBalance(bob,   REF_A), CREDIT * 2);
    }

    // =========================================================================
    // § 4  Credit — boundary / validation guards
    // =========================================================================

    function test_credit_zeroBeneficiaryReverts() public {
        vm.expectRevert(PullSettlementLedger.ZeroAddress.selector);
        ledger.credit(address(0), CREDIT, REF_A);
    }

    function test_credit_zeroAmountReverts() public {
        vm.expectRevert(PullSettlementLedger.ZeroAmount.selector);
        ledger.credit(alice, 0, REF_A);
    }

    function test_credit_zeroRefReverts() public {
        vm.expectRevert(PullSettlementLedger.ZeroSettlementRef.selector);
        ledger.credit(alice, CREDIT, bytes32(0));
    }

    function test_creditBatch_zeroRefReverts() public {
        address[] memory b = new address[](1);
        b[0] = alice;
        uint256[] memory a = new uint256[](1);
        a[0] = CREDIT;

        vm.expectRevert(PullSettlementLedger.ZeroSettlementRef.selector);
        ledger.creditBatch(b, a, bytes32(0));
    }

    function test_creditBatch_lengthMismatchReverts() public {
        address[] memory b = new address[](2);
        b[0] = alice; b[1] = bob;
        uint256[] memory a = new uint256[](1);
        a[0] = CREDIT;

        vm.expectRevert(abi.encodeWithSelector(PullSettlementLedger.LengthMismatch.selector, 2, 1));
        ledger.creditBatch(b, a, REF_A);
    }

    function test_creditBatch_oversizeBatchReverts() public {
        uint256 max = ProtocolExecutionBounds.MAX_SETTLEMENT_BATCH_SIZE;
        address[] memory b = new address[](max + 1);
        uint256[] memory a = new uint256[](max + 1);
        for (uint256 i = 0; i <= max; i++) {
            b[i] = address(uint160(i + 1));
            a[i] = 1 ether;
        }

        vm.expectRevert(
            abi.encodeWithSelector(PullSettlementLedger.BatchTooLarge.selector, max + 1, max)
        );
        ledger.creditBatch(b, a, REF_A);
    }

    function test_creditBatch_zeroAddressInBatchReverts() public {
        address[] memory b = new address[](2);
        b[0] = alice; b[1] = address(0);
        uint256[] memory a = new uint256[](2);
        a[0] = CREDIT; a[1] = CREDIT;

        vm.expectRevert(PullSettlementLedger.ZeroAddress.selector);
        ledger.creditBatch(b, a, REF_A);
    }

    function test_creditBatch_zeroAmountInBatchReverts() public {
        address[] memory b = new address[](2);
        b[0] = alice; b[1] = bob;
        uint256[] memory a = new uint256[](2);
        a[0] = CREDIT; a[1] = 0;

        vm.expectRevert(PullSettlementLedger.ZeroAmount.selector);
        ledger.creditBatch(b, a, REF_A);
    }

    // =========================================================================
    // § 5  Replay prevention (V2-SC-062 core requirement)
    // =========================================================================

    function test_credit_sameRefRevertsOnSecondCall() public {
        ledger.credit(alice, CREDIT, REF_A);

        vm.expectRevert(
            abi.encodeWithSelector(PullSettlementLedger.SettlementRefAlreadyProcessed.selector, REF_A)
        );
        ledger.credit(bob, CREDIT, REF_A);

        // Bob's balance must be untouched.
        assertEq(ledger.credited(bob), 0);
    }

    function test_creditBatch_sameRefRevertsOnSecondCall() public {
        address[] memory b = new address[](1);
        b[0] = alice;
        uint256[] memory a = new uint256[](1);
        a[0] = CREDIT;

        ledger.creditBatch(b, a, REF_A);

        b[0] = bob;
        vm.expectRevert(
            abi.encodeWithSelector(PullSettlementLedger.SettlementRefAlreadyProcessed.selector, REF_A)
        );
        ledger.creditBatch(b, a, REF_A);

        assertEq(ledger.credited(bob), 0, "bob balance must be zero after rejected replay");
    }

    function test_credit_differentRefsAreIndependent() public {
        ledger.credit(alice, CREDIT,     REF_A);
        ledger.credit(alice, CREDIT * 2, REF_B);

        assertEq(ledger.credited(alice), CREDIT * 3);
        assertEq(ledger.availableRefBalance(alice, REF_A), CREDIT);
        assertEq(ledger.availableRefBalance(alice, REF_B), CREDIT * 2);
        assertTrue(ledger.isRefProcessed(REF_A));
        assertTrue(ledger.isRefProcessed(REF_B));
        assertFalse(ledger.isRefProcessed(REF_C));
    }

    /// @dev Demonstrates the exact prior-unsafe behavior: before the fix, a second
    ///      credit with the same ref would silently inflate the balance.
    ///      This test asserts the fix prevents that.
    function test_regression_priorUnsafeBehaviorIsNowBlocked() public {
        ledger.credit(alice, CREDIT, REF_A);
        uint256 balanceBefore = ledger.credited(alice);

        // Attempt duplicate credit — must revert.
        vm.expectRevert(
            abi.encodeWithSelector(PullSettlementLedger.SettlementRefAlreadyProcessed.selector, REF_A)
        );
        ledger.credit(alice, CREDIT, REF_A);

        // Balance must not have changed.
        assertEq(ledger.credited(alice), balanceBefore, "balance inflated by replay - fix missing");
    }

    // =========================================================================
    // § 6  Withdrawal — aggregate path
    // =========================================================================

    function test_withdraw_transfersTokens() public {
        ledger.credit(alice, CREDIT, REF_A);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        ledger.withdraw(CREDIT);

        assertEq(token.balanceOf(alice), before + CREDIT);
        assertEq(ledger.availableBalance(alice), 0);
    }

    function test_withdraw_partialAmount() public {
        ledger.credit(alice, CREDIT, REF_A);

        vm.prank(alice);
        ledger.withdraw(CREDIT / 4);

        assertEq(ledger.availableBalance(alice), CREDIT * 3 / 4);
    }

    function test_withdraw_zeroAmountReverts() public {
        ledger.credit(alice, CREDIT, REF_A);

        vm.prank(alice);
        vm.expectRevert(PullSettlementLedger.ZeroAmount.selector);
        ledger.withdraw(0);
    }

    function test_withdraw_exceedsAvailableReverts() public {
        ledger.credit(alice, CREDIT, REF_A);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PullSettlementLedger.InsufficientCredit.selector, CREDIT, CREDIT + 1)
        );
        ledger.withdraw(CREDIT + 1);
    }

    function test_withdraw_cannotWithdrawTwice() public {
        ledger.credit(alice, CREDIT, REF_A);

        vm.startPrank(alice);
        ledger.withdraw(CREDIT);

        vm.expectRevert(
            abi.encodeWithSelector(PullSettlementLedger.InsufficientCredit.selector, 0, 1)
        );
        ledger.withdraw(1);
        vm.stopPrank();
    }

    function test_withdraw_doesNotAffectOtherAccount() public {
        ledger.credit(alice, CREDIT, REF_A);
        ledger.credit(bob,   CREDIT, REF_B);

        vm.prank(alice);
        ledger.withdraw(CREDIT);

        // Bob's balance must be intact.
        assertEq(ledger.availableBalance(bob), CREDIT);
    }

    // =========================================================================
    // § 7  Withdrawal — per-ref path (failure isolation core)
    // =========================================================================

    function test_withdrawFromRef_transfersCorrectAmount() public {
        ledger.credit(alice, CREDIT, REF_A);
        ledger.credit(alice, CREDIT * 2, REF_B);

        vm.prank(alice);
        ledger.withdrawFromRef(REF_A, CREDIT);

        assertEq(ledger.availableRefBalance(alice, REF_A), 0);
        assertEq(ledger.availableRefBalance(alice, REF_B), CREDIT * 2);
        // Aggregate counters consistent.
        assertEq(ledger.withdrawn(alice), CREDIT);
        assertEq(ledger.availableBalance(alice), CREDIT * 2);
    }

    function test_withdrawFromRef_partialAmount() public {
        ledger.credit(alice, CREDIT, REF_A);

        vm.prank(alice);
        ledger.withdrawFromRef(REF_A, CREDIT / 2);

        assertEq(ledger.availableRefBalance(alice, REF_A), CREDIT / 2);
    }

    function test_withdrawFromRef_zeroAmountReverts() public {
        ledger.credit(alice, CREDIT, REF_A);

        vm.prank(alice);
        vm.expectRevert(PullSettlementLedger.ZeroAmount.selector);
        ledger.withdrawFromRef(REF_A, 0);
    }

    function test_withdrawFromRef_zeroRefReverts() public {
        vm.prank(alice);
        vm.expectRevert(PullSettlementLedger.ZeroSettlementRef.selector);
        ledger.withdrawFromRef(bytes32(0), 1 ether);
    }

    function test_withdrawFromRef_exceedsRefBalanceReverts() public {
        ledger.credit(alice, CREDIT, REF_A);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PullSettlementLedger.InsufficientCredit.selector, CREDIT, CREDIT + 1)
        );
        ledger.withdrawFromRef(REF_A, CREDIT + 1);
    }

    /**
     * @dev Core failure-isolation test (V2-SC-062):
     *      Alice has credits on REF_A and REF_B.  Even if we simulate REF_A
     *      being permanently inaccessible (already fully spent), REF_B is
     *      completely independent and succeeds.
     */
    function test_failureIsolation_refBIsIndependentOfRefA() public {
        // Give alice credits on two different refs.
        ledger.credit(alice, CREDIT,     REF_A);
        ledger.credit(alice, CREDIT * 3, REF_B);

        // Alice drains REF_A.
        vm.prank(alice);
        ledger.withdrawFromRef(REF_A, CREDIT);

        // REF_A is now exhausted.
        assertEq(ledger.availableRefBalance(alice, REF_A), 0);

        // REF_B must still be fully available.
        assertEq(ledger.availableRefBalance(alice, REF_B), CREDIT * 3);

        // Alice can withdraw from REF_B without any issue.
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        ledger.withdrawFromRef(REF_B, CREDIT * 3);

        assertEq(token.balanceOf(alice), before + CREDIT * 3);
        assertEq(ledger.availableRefBalance(alice, REF_B), 0);
    }

    /**
     * @dev Demonstrates that a recipient who is blocked from withdrawing one ref
     *      (e.g. a reverting ERC20 hook specific to that transfer, or a blacklisted
     *      amount) still has a recoverable failure: the balance remains in the ref
     *      and can be retried later.
     */
    function test_failureIsolation_recoverableFailureRemainsClaimable() public {
        ledger.credit(alice, CREDIT, REF_A);
        ledger.credit(alice, CREDIT, REF_B);

        // Drain REF_A successfully.
        vm.prank(alice);
        ledger.withdrawFromRef(REF_A, CREDIT);

        // Simulate a failed withdrawal from REF_B by attempting over-draw (revert).
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PullSettlementLedger.InsufficientCredit.selector, CREDIT, CREDIT + 1)
        );
        ledger.withdrawFromRef(REF_B, CREDIT + 1);

        // REF_B balance is still intact — recoverable.
        assertEq(ledger.availableRefBalance(alice, REF_B), CREDIT, "REF_B should still be claimable after failure");
    }

    // =========================================================================
    // § 8  Mixed withdraw paths — aggregate and ref stay consistent
    // =========================================================================

    function test_mixedWithdrawPaths_aggregateConsistency() public {
        ledger.credit(alice, CREDIT,     REF_A);
        ledger.credit(alice, CREDIT * 2, REF_B);

        // Withdraw half via ref-specific path.
        vm.prank(alice);
        ledger.withdrawFromRef(REF_A, CREDIT / 2);

        // Withdraw another portion via aggregate path.
        vm.prank(alice);
        ledger.withdraw(CREDIT / 2);

        uint256 expectedWithdrawn = CREDIT / 2 + CREDIT / 2;
        assertEq(ledger.withdrawn(alice), expectedWithdrawn);
        assertEq(ledger.availableBalance(alice), CREDIT * 3 - expectedWithdrawn);
    }

    // =========================================================================
    // § 9  Reentrancy protection
    // =========================================================================

    function test_withdraw_reentrancyBlocked() public {
        HostileERC20ForLedger hostileToken = new HostileERC20ForLedger();
        PullSettlementLedger hostileLedger = new PullSettlementLedger(
            admin,
            IERC20(address(hostileToken))
        );

        ReentrantWithdrawer attacker = new ReentrantWithdrawer(address(hostileLedger));
        hostileToken.setAttacker(address(attacker));
        hostileToken.enableAttack(true);
        hostileToken.mint(address(hostileLedger), CREDIT * 2);

        // Credit the attacker.
        hostileLedger.credit(address(attacker), CREDIT, REF_A);

        // The attacker calls withdraw; the hostile token will attempt reentrancy.
        // ReentrancyGuard must block the second call.
        vm.prank(address(attacker));
        hostileLedger.withdraw(CREDIT);

        // Attacker should only have received CREDIT, not CREDIT * 2.
        assertEq(hostileToken.balanceOf(address(attacker)), CREDIT);
        assertEq(hostileLedger.availableBalance(address(attacker)), 0);
    }

    // =========================================================================
    // § 10  Event emissions
    // =========================================================================

    function test_credit_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit PullSettlementLedger.SettlementCredited(alice, CREDIT, REF_A);
        ledger.credit(alice, CREDIT, REF_A);
    }

    function test_withdraw_emitsEvent() public {
        ledger.credit(alice, CREDIT, REF_A);

        vm.expectEmit(true, false, false, true);
        emit PullSettlementLedger.SettlementWithdrawn(alice, CREDIT);
        vm.prank(alice);
        ledger.withdraw(CREDIT);
    }

    function test_withdrawFromRef_emitsEvent() public {
        ledger.credit(alice, CREDIT, REF_A);

        vm.expectEmit(true, true, false, true);
        emit PullSettlementLedger.SettlementRefWithdrawn(alice, REF_A, CREDIT);
        vm.prank(alice);
        ledger.withdrawFromRef(REF_A, CREDIT);
    }

    function test_credit_replay_emitsRejectionEvent() public {
        ledger.credit(alice, CREDIT, REF_A);

        vm.expectEmit(true, true, false, false);
        emit PullSettlementLedger.SettlementRefRejected(REF_A, admin);
        vm.expectRevert(
            abi.encodeWithSelector(PullSettlementLedger.SettlementRefAlreadyProcessed.selector, REF_A)
        );
        ledger.credit(bob, CREDIT, REF_A);
    }
}
