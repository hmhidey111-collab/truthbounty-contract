// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/v2/StakeVault.sol";
import "../../contracts/v2/interfaces/IV2Types.sol";
import "../../contracts/mocks/MockModuleRegistry.sol";
import "../../contracts/MockERC20.sol";

contract V2SC095BondConservationFuzzTest is Test {
    address internal challenger = address(0xB0B);
    uint256 internal constant CLAIM_ID = 17;

    function testFuzz_challengeBondConservedAcrossOperationSequences(
        uint8[] calldata actions,
        uint96[] calldata rawAmounts
    ) public {
        if (actions.length == 0 || rawAmounts.length == 0) return;

        (StakeVault vault, MockERC20 token) = _deployVault();
        uint256 claimable;
        uint256 locked;
        uint256 protocolAllocation;
        uint256 custody;
        uint256 count = actions.length > 64 ? 64 : actions.length;

        for (uint256 i; i < count; ++i) {
            uint256 amount = bound(uint256(rawAmounts[i % rawAmounts.length]), 1, 1e24);
            uint8 action = actions[i] % 5;

            if (action == 0) {
                vm.prank(challenger);
                vault.deposit(address(token), amount);
                claimable += amount;
                custody += amount;
            } else if (action == 1 && claimable != 0) {
                if (amount > claimable) amount = claimable;
                vm.prank(address(this));
                vault.lock(address(token), challenger, CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND, amount);
                claimable -= amount;
                locked += amount;
            } else if (action == 2 && locked != 0) {
                if (amount > locked) amount = locked;
                vault.unlock(address(token), challenger, CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND, amount);
                locked -= amount;
                claimable += amount;
            } else if (action == 3 && locked != 0) {
                if (amount > locked) amount = locked;
                vault.allocateLocked(
                    address(token), challenger, CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND, amount, keccak256("slash")
                );
                locked -= amount;
                protocolAllocation += amount;
            } else if (action == 4 && claimable != 0) {
                if (amount > claimable) amount = claimable;
                vm.prank(challenger);
                vault.withdraw(address(token), amount);
                claimable -= amount;
                custody -= amount;
            }

            _assertAccounting(vault, token, claimable, locked, protocolAllocation, custody);
        }
    }

    function testFuzz_refundAndSlashCannotBothConsumeTheSameBond(uint96 rawAmount, bool refundFirst) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1e24);
        (StakeVault vault, MockERC20 token) = _deployVault();

        vm.prank(challenger);
        vault.deposit(address(token), amount);
        vault.lock(address(token), challenger, CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND, amount);

        if (refundFirst) {
            vault.unlock(address(token), challenger, CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND, amount);
            (bool success,) = address(vault).call(
                abi.encodeCall(
                    vault.allocateLocked,
                    (address(token), challenger, CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND, amount, keccak256("slash"))
                )
            );
            assertFalse(success);
            assertEq(vault.claimableBalance(address(token), challenger), amount);
            assertEq(vault.protocolAllocation(address(token)), 0);
        } else {
            vault.allocateLocked(
                address(token), challenger, CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND, amount, keccak256("slash")
            );
            (bool success,) = address(vault).call(
                abi.encodeCall(
                    vault.unlock,
                    (address(token), challenger, CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND, amount)
                )
            );
            assertFalse(success);
            assertEq(vault.claimableBalance(address(token), challenger), 0);
            assertEq(vault.protocolAllocation(address(token)), amount);
        }

        assertEq(vault.lockedPrincipal(address(token), challenger, CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND), 0);
        _assertAccounting(
            vault,
            token,
            refundFirst ? amount : 0,
            0,
            refundFirst ? 0 : amount,
            amount
        );
    }

    function test_bondLockCannotBeReleasedToAnotherAccount() public {
        address other = address(0xCAFE);
        uint256 amount = 3 ether;
        (StakeVault vault, MockERC20 token) = _deployVault();

        vm.prank(challenger);
        vault.deposit(address(token), amount);
        vault.lock(address(token), challenger, CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND, amount);

        (bool releasedToOther,) = address(vault).call(
            abi.encodeCall(
                vault.unlock,
                (address(token), other, CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND, amount)
            )
        );
        assertFalse(releasedToOther);
        assertEq(
            vault.lockedPrincipal(address(token), challenger, CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND),
            amount
        );
        assertEq(vault.claimableBalance(address(token), other), 0);
        _assertAccounting(vault, token, 0, amount, 0, amount);
    }

    function testFuzz_appealRolloverPreservesPrincipalAndCustody(uint96 rawAmount, uint8 rawRound) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1e24);
        uint256 nextRound = bound(uint256(rawRound), 1, 5);
        (StakeVault vault, MockERC20 token) = _deployVault();

        vm.prank(challenger);
        vault.depositStake(CLAIM_ID, amount);
        vault.carryForwardAppeal(address(token), challenger, CLAIM_ID, 0, nextRound, amount);

        assertEq(
            vault.lockedPrincipal(address(token), challenger, CLAIM_ID, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL),
            0
        );
        assertEq(
            vault.lockedPrincipal(address(token), challenger, CLAIM_ID, nextRound, IV2Types.LockCategory.VERIFIER_PRINCIPAL),
            amount
        );
        assertEq(uint256(vault.settlementOutcome(CLAIM_ID, 0)), uint256(IV2Types.SettlementOutcome.CARRIED_FORWARD));
        _assertAccounting(vault, token, 0, amount, 0, amount);
    }

    function _deployVault() internal returns (StakeVault vault, MockERC20 token) {
        MockModuleRegistry registry = new MockModuleRegistry();
        token = new MockERC20("Bond", "BOND");
        vault = new StakeVault(address(registry), address(token), address(this));
        registry.permitModule(vault.MODULE_SETTLEMENT(), address(this));

        token.mint(challenger, type(uint128).max);
        vm.prank(challenger);
        token.approve(address(vault), type(uint256).max);
    }

    function _assertAccounting(
        StakeVault vault,
        MockERC20 token,
        uint256 claimable,
        uint256 locked,
        uint256 protocolAllocation,
        uint256 custody
    ) internal view {
        (uint256 actualCustody, uint256 obligations, uint256 actualBalance) = vault.conservation(address(token));
        assertEq(actualCustody, custody);
        assertEq(obligations, claimable + locked + protocolAllocation);
        assertEq(actualCustody, obligations);
        assertEq(actualBalance, actualCustody);
        assertEq(vault.claimableBalance(address(token), challenger), claimable);
        assertEq(vault.protocolAllocation(address(token)), protocolAllocation);
    }
}