// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TruthBountyClaimsV2SC062 — V2-SC-062 regression + hardening tests
 *
 * Coverage:
 *  - settleClaim: success, replay prevention, authorization, zero id guard
 *  - settleClaimsBatch: success, replay prevention, failure isolation
 *    (hostile beneficiary skipped, others succeed), authorization
 *  - isSettlementExecuted view
 *  - Prior unsafe behavior regression: same id could previously execute twice
 */

import "forge-std/Test.sol";
import "../../contracts/TruthBountyClaims.sol";
import "../../contracts/MockERC20.sol";

// ---------------------------------------------------------------------------
// Hostile beneficiary — reverts on token receive to test failure isolation.
// ---------------------------------------------------------------------------

contract HostileBeneficiary {
    bool public doRevert = true;

    function setRevert(bool r) external { doRevert = r; }

    // SafeERC20 calls transfer() which calls this contract's fallback if it's a
    // contract. But since we are testing ERC20 transfer, not ETH, we need the
    // token to call us. To simulate a hostile ERC20 that reverts on transfer TO
    // this beneficiary we rely on HostileRecipientERC20 below.
}

/// @dev ERC20 that reverts when transferring to a designated hostile address.
contract HostileRecipientERC20 is MockERC20 {
    address public hostile;

    constructor() MockERC20("H", "H") {}

    function setHostile(address h) external { hostile = h; }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == hostile) {
            assembly {
                mstore(0, 0x12345678)
                revert(0, 0x10000)
            }
        }
        return super.transfer(to, amount);
    }
}

// ---------------------------------------------------------------------------
// Main test contract
// ---------------------------------------------------------------------------

contract TruthBountyClaimsV2SC062Test is Test {
    TruthBountyClaims internal claims;
    MockERC20 internal token;

    address internal admin   = address(this);
    address internal alice   = address(0xA11CE);
    address internal bob     = address(0xB0B);
    address internal charlie = address(0xC11A);

    bytes32 internal constant ID_A = keccak256("settlement-A");
    bytes32 internal constant ID_B = keccak256("settlement-B");
    bytes32 internal constant ID_C = keccak256("settlement-C");

    uint256 internal constant AMOUNT = 500 ether;

    function setUp() public {
        token  = new MockERC20("TT", "TT");
        claims = new TruthBountyClaims(address(token), admin);
        token.mint(address(claims), 100_000 ether);
    }

    // =========================================================================
    // § 1  settleClaim — success
    // =========================================================================

    function test_settleClaim_transfersTokens() public {
        uint256 before = token.balanceOf(alice);
        claims.settleClaim(alice, AMOUNT, ID_A);
        assertEq(token.balanceOf(alice), before + AMOUNT);
    }

    function test_settleClaim_marksIdExecuted() public {
        claims.settleClaim(alice, AMOUNT, ID_A);
        assertTrue(claims.isSettlementExecuted(ID_A));
    }

    function test_settleClaim_idBRemainsAvailable() public {
        claims.settleClaim(alice, AMOUNT, ID_A);
        assertFalse(claims.isSettlementExecuted(ID_B));
    }

    // =========================================================================
    // § 2  settleClaim — replay prevention (V2-SC-062 core)
    // =========================================================================

    function test_settleClaim_replayReverts() public {
        claims.settleClaim(alice, AMOUNT, ID_A);

        vm.expectRevert(
            abi.encodeWithSelector(TruthBountyClaims.SettlementAlreadyExecuted.selector, ID_A)
        );
        claims.settleClaim(bob, AMOUNT, ID_A);

        // Bob must have received nothing.
        assertEq(token.balanceOf(bob), 0, "replay executed - fix broken");
    }

    function test_settleClaim_zeroIdReverts() public {
        vm.expectRevert(TruthBountyClaims.ZeroSettlementId.selector);
        claims.settleClaim(alice, AMOUNT, bytes32(0));
    }

    // =========================================================================
    // § 3  settleClaim — authorization
    // =========================================================================

    function test_settleClaim_unauthorizedReverts() public {
        vm.prank(alice);
        vm.expectRevert(); // AccessControl
        claims.settleClaim(alice, AMOUNT, ID_A);
    }

    // =========================================================================
    // § 4  settleClaimsBatch — success
    // =========================================================================

    function test_settleClaimsBatch_transfersAll() public {
        address[] memory bens = new address[](2);
        bens[0] = alice; bens[1] = bob;
        uint256[] memory amts = new uint256[](2);
        amts[0] = AMOUNT; amts[1] = AMOUNT * 2;

        claims.settleClaimsBatch(bens, amts, ID_A);

        assertEq(token.balanceOf(alice), AMOUNT);
        assertEq(token.balanceOf(bob),   AMOUNT * 2);
        assertTrue(claims.isSettlementExecuted(ID_A));
    }

    // =========================================================================
    // § 5  settleClaimsBatch — replay prevention
    // =========================================================================

    function test_settleClaimsBatch_replayReverts() public {
        address[] memory bens = new address[](1);
        bens[0] = alice;
        uint256[] memory amts = new uint256[](1);
        amts[0] = AMOUNT;

        claims.settleClaimsBatch(bens, amts, ID_A);

        // Same id, different beneficiary — must revert.
        bens[0] = bob;
        vm.expectRevert(
            abi.encodeWithSelector(TruthBountyClaims.SettlementAlreadyExecuted.selector, ID_A)
        );
        claims.settleClaimsBatch(bens, amts, ID_A);

        assertEq(token.balanceOf(bob), 0, "replay executed on batch - fix broken");
    }

    function test_settleClaimsBatch_zeroIdReverts() public {
        address[] memory bens = new address[](1);
        bens[0] = alice;
        uint256[] memory amts = new uint256[](1);
        amts[0] = AMOUNT;

        vm.expectRevert(TruthBountyClaims.ZeroSettlementId.selector);
        claims.settleClaimsBatch(bens, amts, bytes32(0));
    }

    // =========================================================================
    // § 6  settleClaimsBatch — failure isolation (V2-SC-062)
    //
    // A hostile beneficiary that causes the ERC20 transfer to revert must NOT
    // block other beneficiaries in the same batch from being paid.
    // =========================================================================

    function test_settleClaimsBatch_hostileBeneficiarySkipped() public {
        // Deploy a token that reverts on transfer to `charlie`.
        HostileRecipientERC20 hostileToken = new HostileRecipientERC20();
        TruthBountyClaims hostileClaims = new TruthBountyClaims(address(hostileToken), admin);
        hostileToken.mint(address(hostileClaims), 100_000 ether);

        hostileToken.setHostile(charlie);

        address[] memory bens = new address[](3);
        bens[0] = alice; bens[1] = charlie; bens[2] = bob;
        uint256[] memory amts = new uint256[](3);
        amts[0] = AMOUNT; amts[1] = AMOUNT; amts[2] = AMOUNT;

        // Should NOT revert — charlie is skipped, alice and bob succeed.
        hostileClaims.settleClaimsBatch(bens, amts, ID_A);

        assertEq(hostileToken.balanceOf(alice),   AMOUNT, "alice not paid");
        assertEq(hostileToken.balanceOf(bob),     AMOUNT, "bob not paid");
        assertEq(hostileToken.balanceOf(charlie), 0,      "charlie should have been skipped");

        // The batch id is still consumed — charlie's row can be resubmitted under a new id.
        assertTrue(hostileClaims.isSettlementExecuted(ID_A));
    }

    function test_settleClaimsBatch_zeroAddressRowSkipped() public {
        address[] memory bens = new address[](3);
        bens[0] = alice; bens[1] = address(0); bens[2] = bob;
        uint256[] memory amts = new uint256[](3);
        amts[0] = AMOUNT; amts[1] = AMOUNT; amts[2] = AMOUNT;

        // Must not revert; zero-address row is skipped.
        claims.settleClaimsBatch(bens, amts, ID_A);

        assertEq(token.balanceOf(alice), AMOUNT);
        assertEq(token.balanceOf(bob),   AMOUNT);
    }

    function test_settleClaimsBatch_zeroAmountRowSkipped() public {
        address[] memory bens = new address[](3);
        bens[0] = alice; bens[1] = bob; bens[2] = charlie;
        uint256[] memory amts = new uint256[](3);
        amts[0] = AMOUNT; amts[1] = 0; amts[2] = AMOUNT;

        claims.settleClaimsBatch(bens, amts, ID_A);

        assertEq(token.balanceOf(alice),   AMOUNT);
        assertEq(token.balanceOf(bob),     0,      "zero-amount row should have been skipped");
        assertEq(token.balanceOf(charlie), AMOUNT);
    }

    // =========================================================================
    // § 7  settleClaimsBatch — validation guards
    // =========================================================================

    function test_settleClaimsBatch_lengthMismatchReverts() public {
        address[] memory bens = new address[](2);
        bens[0] = alice; bens[1] = bob;
        uint256[] memory amts = new uint256[](1);
        amts[0] = AMOUNT;

        vm.expectRevert("Arrays length mismatch");
        claims.settleClaimsBatch(bens, amts, ID_A);
    }

    function test_settleClaimsBatch_emptyArrayReverts() public {
        address[] memory bens = new address[](0);
        uint256[] memory amts = new uint256[](0);

        vm.expectRevert("No claims to settle");
        claims.settleClaimsBatch(bens, amts, ID_A);
    }

    function test_settleClaimsBatch_oversizedReverts() public {
        uint256 max = claims.MAX_BATCH_SIZE();
        address[] memory bens = new address[](max + 1);
        uint256[] memory amts = new uint256[](max + 1);
        for (uint256 i = 0; i <= max; i++) {
            bens[i] = address(uint160(i + 1));
            amts[i] = 1 ether;
        }

        vm.expectRevert("Batch size too large");
        claims.settleClaimsBatch(bens, amts, ID_A);
    }

    function test_settleClaimsBatch_unauthorizedReverts() public {
        address[] memory bens = new address[](1);
        bens[0] = alice;
        uint256[] memory amts = new uint256[](1);
        amts[0] = AMOUNT;

        vm.prank(alice);
        vm.expectRevert();
        claims.settleClaimsBatch(bens, amts, ID_A);
    }

    // =========================================================================
    // § 8  Regression: prior unsafe behaviour is blocked
    //
    // Before V2-SC-062: calling settleClaim(alice, AMOUNT) twice with no id
    // tracking would transfer AMOUNT twice, doubling spend.
    // After fix: the second call with the same id reverts, amount stays put.
    // =========================================================================

    function test_regression_doubleSpendBlocked() public {
        claims.settleClaim(alice, AMOUNT, ID_A);
        uint256 balanceAfterFirst = token.balanceOf(alice);

        vm.expectRevert(
            abi.encodeWithSelector(TruthBountyClaims.SettlementAlreadyExecuted.selector, ID_A)
        );
        claims.settleClaim(alice, AMOUNT, ID_A);

        assertEq(
            token.balanceOf(alice),
            balanceAfterFirst,
            "double-spend succeeded - V2-SC-062 fix is missing"
        );
    }

    // =========================================================================
    // § 9  _tryTransfer onlySelf guard
    // =========================================================================

    function test_tryTransfer_externalCallReverts() public {
        vm.expectRevert("Only self");
        claims._tryTransfer(alice, AMOUNT);
    }

    // =========================================================================
    // § 10  Independent ids do not interfere
    // =========================================================================

    function test_independentIdsSucceed() public {
        claims.settleClaim(alice, AMOUNT,     ID_A);
        claims.settleClaim(alice, AMOUNT * 2, ID_B);
        claims.settleClaim(bob,   AMOUNT * 3, ID_C);

        assertEq(token.balanceOf(alice), AMOUNT + AMOUNT * 2);
        assertEq(token.balanceOf(bob),   AMOUNT * 3);

        assertTrue(claims.isSettlementExecuted(ID_A));
        assertTrue(claims.isSettlementExecuted(ID_B));
        assertTrue(claims.isSettlementExecuted(ID_C));
    }
}
