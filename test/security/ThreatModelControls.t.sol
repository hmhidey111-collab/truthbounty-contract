// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/TruthBounty.sol";
import "../../contracts/MockERC20.sol";
import "../../contracts/utils/ResolverRoleTimelock.sol";
import "../../contracts/StakeVault.sol";
import "../../contracts/interfaces/ISTakeVault.sol";

/**
 * @title ThreatModelControls
 * @notice Executable proofs that the controls documented in docs/THREAT_MODEL.md
 *         are enforced by the canonical V2 contract suite.
 *
 * Each test function name mirrors the threat model section and attack tree node
 * it covers so CI output is a human-readable attestation of the control inventory.
 *
 * Sections tested:
 *   §5.1  Treasury drain — role escalation blocked by ResolverRoleTimelock
 *   §5.3  Stake drain — StakeVault bond custody, operator-only lock/release
 *   §5.2  Double-settlement prevention — settlement role gate
 *   §6    Abuse cases — operation-id replay prevention, pause ≠ upgrade
 *   §11   Protocol invariants — RESOLVER_ROLE delay, no untrusted holder, totalLocked
 */
contract ThreatModelControls is Test {
    // =========================================================================
    // Fixtures
    // =========================================================================

    TruthBountyToken internal token;
    StakeVault       internal vault;
    MockERC20        internal mockToken;

    address internal admin    = address(0xAD);
    address internal attacker = address(0xBAD);
    address internal operator = address(0x0E);
    address internal user     = address(0xAB);
    address internal settler  = address(0x5E);

    uint256 constant BOND_AMOUNT = 50 ether;
    uint256 constant LOCK_ID     = 42;

    function setUp() public {
        vm.startPrank(admin);
        token     = new TruthBountyToken(admin);
        mockToken = new MockERC20("Mock", "MCK");
        vault     = new StakeVault(admin, address(mockToken));
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        mockToken.mint(user, 1_000 ether);
        vm.prank(user);
        mockToken.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // §5.1 — A3.1: Direct RESOLVER_ROLE grant is blocked by timelock
    // =========================================================================

    /// @notice Attack A3.1 — admin calls grantRole(RESOLVER_ROLE) directly; must revert.
    function test_threatA3_directResolverRoleGrant_reverts() public {
        vm.prank(admin);
        vm.expectRevert(ResolverRoleTimelock.ResolverRoleChangeRequiresTimelock.selector);
        token.grantRole(token.RESOLVER_ROLE(), attacker);
    }

    /// @notice Even the role-admin of RESOLVER_ROLE cannot bypass the timelock.
    function test_threatA3_adminCannotBypassTimelockForResolverRole() public {
        bytes32 roleAdmin = token.getRoleAdmin(token.RESOLVER_ROLE());
        assertTrue(token.hasRole(roleAdmin, admin), "admin must hold the role-admin role");

        vm.prank(admin);
        vm.expectRevert(ResolverRoleTimelock.ResolverRoleChangeRequiresTimelock.selector);
        token.grantRole(token.RESOLVER_ROLE(), settler);
    }

    /// @notice revokeRole(RESOLVER_ROLE) is also timelocked.
    function test_threatA3_revokeResolverRoleAlsoRequiresTimelock() public {
        vm.prank(admin);
        vm.expectRevert(ResolverRoleTimelock.ResolverRoleChangeRequiresTimelock.selector);
        token.revokeRole(token.RESOLVER_ROLE(), admin);
    }

    // =========================================================================
    // §5.1 — A3: Scheduled grant enforces the 2-day delay
    // =========================================================================

    /// @notice Executing a scheduled grant before the delay elapses reverts.
    function test_threatA3_scheduledResolverGrantEnforcesDelay() public {
        vm.prank(admin);
        bytes32 opId    = token.scheduleResolverRoleGrant(settler);
        uint256 readyAt = token.resolverRoleChangeReadyAt(opId);

        assertGt(readyAt, block.timestamp, "readyAt must be in the future");

        vm.expectRevert(
            abi.encodeWithSelector(ResolverRoleTimelock.ResolverRoleChangeNotReady.selector, readyAt)
        );
        token.executeResolverRoleGrant(opId, settler);
    }

    /// @notice After the delay, the grant succeeds.
    function test_threatA3_resolverRoleGrantSucceedsAfterDelay() public {
        vm.prank(admin);
        bytes32 opId    = token.scheduleResolverRoleGrant(settler);
        uint256 readyAt = token.resolverRoleChangeReadyAt(opId);

        vm.warp(readyAt + 1);
        token.executeResolverRoleGrant(opId, settler);

        assertTrue(token.hasRole(token.RESOLVER_ROLE(), settler), "settler must hold RESOLVER_ROLE");
    }

    /// @notice Scheduling the same grant twice reverts.
    function test_threatA3_duplicateScheduleReverts() public {
        vm.startPrank(admin);
        token.scheduleResolverRoleGrant(settler);

        vm.expectRevert(ResolverRoleTimelock.ResolverRoleChangeAlreadyPending.selector);
        token.scheduleResolverRoleGrant(settler);
        vm.stopPrank();
    }

    // =========================================================================
    // §5.3 — C1: StakeVault bond custody — only OPERATOR_ROLE can lock/release
    // =========================================================================

    /// @notice Operator locks a bond for a user; ledger records it correctly.
    function test_threatC1_operatorCanLockBond() public {
        vm.prank(operator);
        vault.lockBond(LOCK_ID, address(mockToken), user, BOND_AMOUNT);

        ISTakeVault.BondLock memory lock = vault.getLock(LOCK_ID);
        assertEq(lock.depositor, user,        "depositor must be user");
        assertEq(lock.amount,    BOND_AMOUNT, "amount must match");
        assertFalse(lock.released,            "bond must not be released yet");
    }

    /// @notice Non-operator (attacker) cannot lock a bond.
    function test_threatC1_nonOperatorCannotLockBond() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.lockBond(LOCK_ID + 1, address(mockToken), user, BOND_AMOUNT);
    }

    /// @notice Non-operator cannot release a locked bond.
    function test_threatC1_nonOperatorCannotReleaseBond() public {
        vm.prank(operator);
        vault.lockBond(LOCK_ID, address(mockToken), user, BOND_AMOUNT);

        vm.prank(attacker);
        vm.expectRevert();
        vault.releaseBond(LOCK_ID, attacker);
    }

    /// @notice Operator can release a bond to an authorised recipient.
    function test_threatC1_operatorCanReleaseBond() public {
        vm.prank(operator);
        vault.lockBond(LOCK_ID, address(mockToken), user, BOND_AMOUNT);

        uint256 before = mockToken.balanceOf(settler);
        vm.prank(operator);
        vault.releaseBond(LOCK_ID, settler);

        assertEq(mockToken.balanceOf(settler) - before, BOND_AMOUNT, "settler must receive bond");
    }

    /// @notice Double-release reverts — no double-payout from the same lock.
    function test_threatC1_doubleReleaseBondReverts() public {
        vm.prank(operator);
        vault.lockBond(LOCK_ID, address(mockToken), user, BOND_AMOUNT);

        vm.prank(operator);
        vault.releaseBond(LOCK_ID, settler);

        vm.prank(operator);
        vm.expectRevert(); // lock already released
        vault.releaseBond(LOCK_ID, settler);
    }

    /// @notice Lock ID reuse is rejected — prevents ledger overwrite.
    function test_threatC1_lockIdReuseReverts() public {
        vm.prank(operator);
        vault.lockBond(LOCK_ID, address(mockToken), user, BOND_AMOUNT);

        vm.prank(operator);
        vm.expectRevert(); // LockAlreadyExists
        vault.lockBond(LOCK_ID, address(mockToken), user, BOND_AMOUNT);
    }

    // =========================================================================
    // §5.2 — B: Settlement requires RESOLVER_ROLE
    // =========================================================================

    /// @notice slashVerifier is gated by RESOLVER_ROLE; attacker is rejected.
    function test_threatB_settlementRequiresResolverRole() public {
        vm.prank(attacker);
        vm.expectRevert();
        token.slashVerifier(user, "unauthorized slash attempt");
    }

    // =========================================================================
    // §6 — AB-05: Operation ID cannot be replayed after execution
    // =========================================================================

    /// @notice Once an operation is executed, replaying it reverts (NotPending).
    function test_abuseAB05_executedOperationCannotBeReplayed() public {
        vm.prank(admin);
        bytes32 opId    = token.scheduleResolverRoleGrant(settler);
        uint256 readyAt = token.resolverRoleChangeReadyAt(opId);

        vm.warp(readyAt + 1);
        token.executeResolverRoleGrant(opId, settler);

        vm.expectRevert(ResolverRoleTimelock.ResolverRoleChangeNotPending.selector);
        token.executeResolverRoleGrant(opId, settler);
    }

    // =========================================================================
    // §11 — Protocol invariants
    // =========================================================================

    /// @notice RESOLVER_ROLE_CHANGE_DELAY must be exactly 2 days.
    function test_invariant_resolverRoleChangeDelayIs2Days() public view {
        assertEq(token.MIN_RESOLVER_ROLE_CHANGE_DELAY(), 2 days, "delay must be 2 days per section 5.1");
    }

    /// @notice No untrusted address holds RESOLVER_ROLE at deploy time.
    function test_invariant_noUntrustedAddressHoldsResolverRoleAtDeploy() public view {
        bytes32 role = token.RESOLVER_ROLE();
        assertFalse(token.hasRole(role, attacker),   "attacker must not hold RESOLVER_ROLE");
        assertFalse(token.hasRole(role, address(0)), "zero address must not hold RESOLVER_ROLE");
        assertFalse(token.hasRole(role, user),       "untrusted user must not hold RESOLVER_ROLE");
    }

    /// @notice Cancelling a scheduled change clears readyAt (no ghost state).
    function test_invariant_cancelledOperationLeavesNoGhostState() public {
        vm.startPrank(admin);
        bytes32 opId = token.scheduleResolverRoleGrant(settler);
        assertGt(token.resolverRoleChangeReadyAt(opId), 0, "must be pending before cancel");

        token.cancelResolverRoleChange(opId, settler, true);
        assertEq(token.resolverRoleChangeReadyAt(opId), 0, "readyAt must be zero after cancel");
        vm.stopPrank();
    }

    /// @notice totalLocked tracks cumulative locked amounts across multiple bonds.
    function test_invariant_totalLockedAccountsForAllActiveBonds() public {
        vm.prank(operator);
        vault.lockBond(LOCK_ID, address(mockToken), user, BOND_AMOUNT);
        assertEq(vault.totalLocked(), BOND_AMOUNT, "totalLocked must equal BOND_AMOUNT after first lock");

        vm.prank(operator);
        vault.lockBond(LOCK_ID + 1, address(mockToken), user, BOND_AMOUNT);
        assertEq(vault.totalLocked(), BOND_AMOUNT * 2, "totalLocked must be 2x after second lock");
    }
}
