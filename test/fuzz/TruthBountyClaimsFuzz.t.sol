// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TruthBountyClaimsFuzz — V2-SC-062 fuzz coverage for TruthBountyClaims
 *
 * Properties:
 *  F1  A settlementId can be executed at most once.
 *  F2  After execution, isSettlementExecuted(id) == true for all inputs.
 *  F3  A non-executed id is never reported as executed.
 *  F4  Beneficiary balance increases by exactly `amount` on success.
 */

import "forge-std/Test.sol";
import "../../contracts/TruthBountyClaims.sol";
import "../../contracts/MockERC20.sol";

contract TruthBountyClaimsFuzzTest is Test {
    TruthBountyClaims internal claims;
    MockERC20 internal token;
    address internal admin = address(this);

    function setUp() public {
        token  = new MockERC20("T", "T");
        claims = new TruthBountyClaims(address(token), admin);
        token.mint(address(claims), type(uint128).max);
    }

    // F1 + F2: id executed once, marked, replay reverts.
    function testFuzz_singleExecution(
        address beneficiary,
        uint256 amount,
        bytes32 id
    ) public {
        vm.assume(beneficiary != address(0));
        vm.assume(amount > 0 && amount <= 1_000_000 ether);
        vm.assume(id != bytes32(0));

        assertFalse(claims.isSettlementExecuted(id));

        claims.settleClaim(beneficiary, amount, id);
        assertTrue(claims.isSettlementExecuted(id), "F2: id not marked after execution");

        vm.expectRevert(
            abi.encodeWithSelector(TruthBountyClaims.SettlementAlreadyExecuted.selector, id)
        );
        claims.settleClaim(beneficiary, amount, id);
    }

    // F3: a never-used id is never reported as executed.
    function testFuzz_unusedIdIsNotExecuted(bytes32 id) public view {
        vm.assume(id != bytes32(0));
        assertFalse(claims.isSettlementExecuted(id), "F3: unused id reported as executed");
    }

    // F4: beneficiary balance delta == amount.
    function testFuzz_exactAmountTransferred(
        address beneficiary,
        uint256 amount,
        bytes32 id
    ) public {
        vm.assume(beneficiary != address(0));
        vm.assume(beneficiary != address(claims)); // avoid self-transfer edge case
        vm.assume(amount > 0 && amount <= 1_000_000 ether);
        vm.assume(id != bytes32(0));

        uint256 before = token.balanceOf(beneficiary);
        claims.settleClaim(beneficiary, amount, id);
        assertEq(token.balanceOf(beneficiary), before + amount, "F4: wrong amount transferred");
    }

    // Batch: same properties hold for settleClaimsBatch.
    function testFuzz_batchSingleExecution(
        address beneficiary,
        uint256 amount,
        bytes32 id
    ) public {
        vm.assume(beneficiary != address(0));
        vm.assume(amount > 0 && amount <= 1_000_000 ether);
        vm.assume(id != bytes32(0));

        address[] memory bens = new address[](1);
        bens[0] = beneficiary;
        uint256[] memory amts = new uint256[](1);
        amts[0] = amount;

        claims.settleClaimsBatch(bens, amts, id);
        assertTrue(claims.isSettlementExecuted(id));

        vm.expectRevert(
            abi.encodeWithSelector(TruthBountyClaims.SettlementAlreadyExecuted.selector, id)
        );
        claims.settleClaimsBatch(bens, amts, id);
    }
}
