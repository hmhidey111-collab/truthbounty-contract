// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/StakeVault.sol";
import "../contracts/MockERC20.sol";
import "../contracts/mocks/MockFailingBondERC20.sol";

/**
 * @title StakeVaultTest
 * @notice Foundry tests for the minimal StakeVault bond-custody + lock ledger.
 * @dev Covers the SC-016 custody invariants that underpin dispute opening:
 *      - lock records a bond and vaults the ERC20,
 *      - no lock record without a successful token transfer,
 *      - only the authorised operator can lock/release,
 *      - a release is idempotent and cannot double-spend,
 *      - the aggregate `totalLocked` ledger reconciles with per-lock records.
 */
contract StakeVaultTest is Test {
    StakeVault public vault;
    MockERC20 public token;

    address public admin = address(0xAAA);
    address public operator = address(0xBBB);
    address public depositor = address(0xCCC);
    address public recipient = address(0xDDD);

    function setUp() public {
        token = new MockERC20("Bounty", "BOUNTY");
        vault = new StakeVault(admin, address(token));

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.prank(admin);
        vault.grantRole(operatorRole, operator);

        token.mint(depositor, 1000e18);
    }

    function _approveOperator() internal {
        vm.prank(depositor);
        token.approve(address(vault), type(uint256).max);
    }

    function test_LockBond_VaultsTokensAndRecords() public {
        _approveOperator();
        uint256 vaultBefore = token.balanceOf(address(vault));

        vm.prank(operator);
        vault.lockBond(1, address(token), depositor, 100e18);

        assertEq(token.balanceOf(address(vault)), vaultBefore + 100e18);
        ISTakeVault.BondLock memory lock = vault.getLock(1);
        assertEq(lock.lockId, 1);
        assertEq(lock.token, address(token));
        assertEq(lock.depositor, depositor);
        assertEq(lock.amount, 100e18);
        assertEq(lock.released, false);
        assertEq(vault.totalLocked(), 100e18);
    }

    function test_LockBond_RevertsNonOperator() public {
        _approveOperator();
        vm.expectRevert();
        vault.lockBond(1, address(token), depositor, 100e18);
    }

    function test_LockBond_RevertsDuplicateLockId() public {
        _approveOperator();
        vm.prank(operator);
        vault.lockBond(1, address(token), depositor, 100e18);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISTakeVault.LockAlreadyExists.selector, uint256(1)));
        vault.lockBond(1, address(token), depositor, 100e18);
    }

    function test_LockBond_WithFailingToken_RevertsAndRecordsNothing() public {
        // transferFrom returns false, so SafeERC20 reverts before any ledger write.
        MockFailingBondERC20 failing = new MockFailingBondERC20();
        vm.prank(admin);
        vault.setBondToken(address(failing));
        failing.mint(depositor, 1e18);
        vm.prank(depositor);
        failing.approve(address(vault), type(uint256).max);

        vm.prank(operator);
        vm.expectRevert();
        vault.lockBond(2, address(failing), depositor, 1e18);

        // Atomic: no partial lock record.
        assertEq(vault.getLock(2).lockId, 0);
    }

    function test_ReleaseBond_ReleasesToRecipientAndRemovesLedger() public {
        _approveOperator();
        vm.prank(operator);
        vault.lockBond(1, address(token), depositor, 100e18);

        uint256 recipientBefore = token.balanceOf(recipient);

        vm.prank(operator);
        vault.releaseBond(1, recipient);

        assertEq(token.balanceOf(recipient), recipientBefore + 100e18);
        assertEq(vault.getLock(1).released, true);
        assertEq(vault.getLock(1).releasedTo, recipient);
        assertEq(vault.totalLocked(), 0);
    }

    function test_ReleaseBond_RevertsIfAlreadyReleased() public {
        _approveOperator();
        vm.prank(operator);
        vault.lockBond(1, address(token), depositor, 100e18);

        vm.prank(operator);
        vault.releaseBond(1, recipient);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISTakeVault.LockAlreadyReleased.selector, uint256(1)));
        vault.releaseBond(1, recipient);
    }

    function test_ReleaseBond_RevertsNonOperator() public {
        _approveOperator();
        vm.prank(operator);
        vault.lockBond(1, address(token), depositor, 100e18);

        vm.expectRevert();
        vault.releaseBond(1, recipient);
    }

    function test_GetLock_UnknownIdIsEmpty() public {
        ISTakeVault.BondLock memory lock = vault.getLock(99);
        assertEq(lock.lockId, 0);
        assertEq(lock.amount, 0);
    }

    function test_TotalLocked_ReconcilesAcrossManyLocks() public {
        _approveOperator();
        for (uint256 i = 1; i <= 5; i++) {
            vm.prank(operator);
            vault.lockBond(i, address(token), depositor, 10e18);
        }
        assertEq(vault.totalLocked(), 50e18);

        vm.prank(operator);
        vault.releaseBond(2, recipient);
        assertEq(vault.totalLocked(), 40e18);
    }
}
