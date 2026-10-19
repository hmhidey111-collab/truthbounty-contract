// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/v2/StakeVault.sol";
import "../../contracts/v2/EmergencyControls.sol";
import "../../contracts/v2/libraries/V2Errors.sol";
import "../../contracts/v2/interfaces/IStakeCustody.sol";
import "../../contracts/v2/interfaces/IV2Module.sol";
import "../../contracts/v2/interfaces/IV2Types.sol";
import "../../contracts/mocks/MockModuleRegistry.sol";
import "../../contracts/mocks/FeeOnTransferERC20.sol";
import "../../contracts/mocks/ReentrancyAttacker.sol";
import "../../contracts/MockERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StakeVaultTest is Test {
    StakeVault internal vault;
    EmergencyControls internal emergency;
    MockModuleRegistry internal registry;
    MockERC20 internal token;
    MockERC20 internal tokenB;

    address internal admin = address(this);
    address internal verifier = address(0xBEEF);
    address internal verifier2 = address(0xCAFE);
    address internal settlement = address(0xA001);
    address internal slashing = address(0xA002);

    uint256 internal constant CLAIM_A = 1;
    uint256 internal constant CLAIM_B = 2;
    uint256 internal constant STAKE = 100 ether;

    function setUp() public {
        registry = new MockModuleRegistry();
        token = new MockERC20("Stake", "STK");
        tokenB = new MockERC20("Alt", "ALT");
        emergency = new EmergencyControls(admin, admin, admin);
        vault = new StakeVault(address(registry), address(token), admin);

        // The vault is fail-closed: no mutation is reachable until the control plane is wired.
        vault.setEmergencyControls(address(emergency));

        vault.setSupportedAsset(address(tokenB), true);

        registry.permitModule(vault.MODULE_SETTLEMENT(), settlement);
        registry.permitModule(vault.MODULE_SLASHING(), slashing);

        token.mint(verifier, 1_000 ether);
        token.mint(verifier2, 1_000 ether);
        tokenB.mint(verifier, 1_000 ether);
        tokenB.mint(verifier2, 1_000 ether);

        vm.prank(verifier);
        token.approve(address(vault), type(uint256).max);
        vm.prank(verifier2);
        token.approve(address(vault), type(uint256).max);
        vm.prank(verifier);
        tokenB.approve(address(vault), type(uint256).max);
        vm.prank(verifier2);
        tokenB.approve(address(vault), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Deposit / lock / unlock / withdraw
    // -------------------------------------------------------------------------

    function test_depositStake_locksVerifierPrincipal() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        assertEq(vault.staked(CLAIM_A, verifier), STAKE);
        assertEq(vault.totalStaked(CLAIM_A), STAKE);
        assertEq(
            vault.lockedPrincipal(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL),
            STAKE
        );
        assertEq(vault.claimableBalance(address(token), verifier), 0);
        assertEq(vault.totalCustody(address(token)), STAKE);
    }

    function test_releaseStake_unlocksToClaimable() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.releaseStake(CLAIM_A, verifier, STAKE);

        assertEq(vault.staked(CLAIM_A, verifier), 0);
        assertEq(vault.claimableBalance(address(token), verifier), STAKE);
    }

    function test_withdraw_pullsClaimableBalance() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.releaseStake(CLAIM_A, verifier, STAKE);

        uint256 before = token.balanceOf(verifier);
        vm.prank(verifier);
        vault.withdraw(address(token), STAKE);

        assertEq(token.balanceOf(verifier), before + STAKE);
        assertEq(vault.totalCustody(address(token)), 0);
    }

    function test_slashStake_movesToProtocolAllocation() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        bytes32 reason = keccak256("misbehavior");
        vm.prank(slashing);
        vault.slashStake(CLAIM_A, verifier, STAKE, reason);

        assertEq(vault.staked(CLAIM_A, verifier), 0);
        assertEq(vault.protocolAllocation(address(token)), STAKE);
        assertEq(vault.claimableBalance(address(token), verifier), 0);
    }

    function test_deposit_lock_unlock_allocate_flow() public {
        vm.prank(verifier);
        vault.deposit(address(token), STAKE);

        vm.prank(settlement);
        vault.lock(address(token), verifier, CLAIM_A, 1, IV2Types.LockCategory.CHALLENGE_BOND, STAKE / 2);

        assertEq(
            vault.lockedPrincipal(address(token), verifier, CLAIM_A, 1, IV2Types.LockCategory.CHALLENGE_BOND),
            STAKE / 2
        );

        vm.prank(settlement);
        vault.unlock(address(token), verifier, CLAIM_A, 1, IV2Types.LockCategory.CHALLENGE_BOND, STAKE / 4);

        vm.prank(slashing);
        vault.allocateLocked(
            address(token), verifier, CLAIM_A, 1, IV2Types.LockCategory.CHALLENGE_BOND, STAKE / 4, bytes32("slash")
        );

        assertEq(vault.protocolAllocation(address(token)), STAKE / 4);
        // Net effect: the allocated quarter left custody, the rest stays claimable
        // (lock 50 then unlock 25 nets claimable = STAKE - STAKE/4).
        assertEq(vault.claimableBalance(address(token), verifier), STAKE - STAKE / 4);
    }

    // -------------------------------------------------------------------------
    // Authorization
    // -------------------------------------------------------------------------

    function test_unauthorizedLockReverts() public {
        vm.prank(verifier);
        vault.deposit(address(token), STAKE);

        vm.prank(verifier2);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, verifier2));
        vault.lock(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.BOUNTY_ESCROW, STAKE);
    }

    function test_explicitLockMutatorAuthorized() public {
        vm.prank(verifier);
        vault.deposit(address(token), STAKE);

        vault.setLockMutator(verifier2, true);

        vm.prank(verifier2);
        vault.lock(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.SETTLEMENT_ALLOCATION, STAKE);
        assertEq(
            vault.lockedPrincipal(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.SETTLEMENT_ALLOCATION),
            STAKE
        );
    }

    // -------------------------------------------------------------------------
    // Multi-asset and multi-claim isolation
    // -------------------------------------------------------------------------

    function test_multiAssetIsolation() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(verifier);
        vault.deposit(address(tokenB), STAKE);

        vm.prank(settlement);
        vault.lock(address(tokenB), verifier, CLAIM_A, 0, IV2Types.LockCategory.BOUNTY_ESCROW, STAKE);

        assertEq(vault.totalCustody(address(token)), STAKE);
        assertEq(vault.totalCustody(address(tokenB)), STAKE);
        assertEq(vault.claimableBalance(address(token), verifier), 0);
        assertEq(vault.claimableBalance(address(tokenB), verifier), 0);
    }

    function test_multiClaimIsolation() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(verifier);
        vault.depositStake(CLAIM_B, STAKE * 2);

        assertEq(vault.staked(CLAIM_A, verifier), STAKE);
        assertEq(vault.staked(CLAIM_B, verifier), STAKE * 2);
        assertEq(vault.totalStaked(CLAIM_A), STAKE);
        assertEq(vault.totalStaked(CLAIM_B), STAKE * 2);

        vm.prank(settlement);
        vault.releaseStake(CLAIM_A, verifier, STAKE);

        assertEq(vault.staked(CLAIM_B, verifier), STAKE * 2);
        assertEq(vault.claimableBalance(address(token), verifier), STAKE);
    }

    function test_withdrawCannotAffectOtherAccount() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.releaseStake(CLAIM_A, verifier, STAKE);

        vm.prank(verifier2);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientClaimable.selector, verifier2, STAKE, 0));
        vault.withdraw(address(token), STAKE);
    }

    // -------------------------------------------------------------------------
    // Reconciliation
    // -------------------------------------------------------------------------

    function test_reconcileMatchesBuckets() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        (uint256 custody, uint256 obligations) = vault.reconcile(address(token));
        assertEq(custody, STAKE);
        assertEq(obligations, STAKE);
        assertEq(custody, obligations);
    }

    function test_unexplainedBalanceDeltaReverts() public {
        vm.prank(verifier);
        token.transfer(address(vault), STAKE);

        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.ConservationInvariantViolation.selector,
                address(token),
                0,
                0,
                STAKE
            )
        );
        vault.depositStake(CLAIM_A, STAKE);
    }

    function test_invariant_obligationsNeverExceedCustody() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.releaseStake(CLAIM_A, verifier, STAKE / 2);

        (uint256 custody, uint256 obligations) = vault.reconcile(address(token));
        assertLe(obligations, custody);
    }

    // -------------------------------------------------------------------------
    // Malicious ERC-20 and exact-balance checks
    // -------------------------------------------------------------------------

    function test_feeOnTransferTokenRejected() public {
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20("Fee", "FEE", 100);
        feeToken.mint(verifier, STAKE);
        vault.setSupportedAsset(address(feeToken), true);

        vm.startPrank(verifier);
        feeToken.approve(address(vault), STAKE);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TransferAmountMismatch.selector, STAKE, STAKE * 99 / 100));
        vault.deposit(address(feeToken), STAKE);
        vm.stopPrank();
    }

    function test_failingTransferRejected() public {
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20("Fee", "FEE", 10_000);
        feeToken.mint(verifier, STAKE);
        vault.setSupportedAsset(address(feeToken), true);

        vm.startPrank(verifier);
        feeToken.approve(address(vault), STAKE);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TransferAmountMismatch.selector, STAKE, 0));
        vault.deposit(address(feeToken), STAKE);
        vm.stopPrank();
    }

    function test_zeroAmountReverts() public {
        vm.prank(verifier);
        vm.expectRevert(V2Errors.ZeroAmount.selector);
        vault.depositStake(CLAIM_A, 0);
    }

    function test_zeroStakeMutationsUseCanonicalZeroAmountError() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vm.expectRevert(V2Errors.ZeroAmount.selector);
        vault.releaseStake(CLAIM_A, verifier, 0);

        vm.prank(slashing);
        vm.expectRevert(V2Errors.ZeroAmount.selector);
        vault.slashStake(CLAIM_A, verifier, 0, keccak256("zero-slash"));

        vm.prank(settlement);
        vm.expectRevert(V2Errors.ZeroAmount.selector);
        vault.carryForwardAppeal(address(token), verifier, CLAIM_A, 0, 1, 0);

        assertEq(vault.staked(CLAIM_A, verifier), STAKE, "failed zero mutations changed stake");
        (uint256 custody, uint256 obligations) = vault.reconcile(address(token));
        assertEq(custody, obligations, "zero mutations broke reconciliation");
    }

    function test_depositStake_enforcesMinimumBoundary() public {
        uint256 minimum = vault.minStakeAmount();
        uint256 custodyBefore = vault.totalCustody(address(token));

        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.DustStake.selector, minimum - 1, minimum));
        vault.depositStake(CLAIM_A, minimum - 1);
        assertEq(vault.totalCustody(address(token)), custodyBefore, "rejected dust deposit changed custody");
        assertEq(vault.staked(CLAIM_A, verifier), 0, "rejected dust deposit changed stake");

        vm.prank(verifier);
        vault.depositStake(CLAIM_A, minimum);
        assertEq(vault.staked(CLAIM_A, verifier), minimum);

        vm.prank(verifier2);
        vault.depositStake(CLAIM_B, minimum + 1);
        assertEq(vault.staked(CLAIM_B, verifier2), minimum + 1);
    }

    function test_unsupportedAssetReverts() public {
        MockERC20 unsupported = new MockERC20("X", "X");
        unsupported.mint(verifier, STAKE);

        vm.startPrank(verifier);
        unsupported.approve(address(vault), STAKE);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnsupportedAsset.selector, address(unsupported)));
        vault.deposit(address(unsupported), STAKE);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Reentrancy
    // -------------------------------------------------------------------------

    function test_withdrawReentrancyBlocked() public {
        MaliciousERC20 malicious = new MaliciousERC20(0);
        StakeVaultReentrancyAttacker attacker = new StakeVaultReentrancyAttacker(address(vault), address(malicious));
        malicious.mint(address(attacker), STAKE);
        vault.setSupportedAsset(address(malicious), true);
        malicious.setAttacker(address(attacker));
        malicious.enableAttack(true);

        vm.prank(address(attacker));
        malicious.approve(address(vault), STAKE);
        vm.prank(address(attacker));
        vault.deposit(address(malicious), STAKE);

        vm.prank(settlement);
        vault.lock(address(malicious), address(attacker), CLAIM_A, 0, IV2Types.LockCategory.BOUNTY_ESCROW, STAKE);

        vm.prank(settlement);
        vault.unlock(address(malicious), address(attacker), CLAIM_A, 0, IV2Types.LockCategory.BOUNTY_ESCROW, STAKE);

        // The malicious token fires its callback mid-transfer to reenter `withdraw`.
        // The reentrancy guard plus the emptied claimable balance must swallow the
        // inner attempt, so the outer withdrawal settles exactly once.
        vm.expectEmit(false, false, false, true, address(malicious));
        emit MaliciousERC20.AttackAttempted(address(attacker), STAKE);
        vm.prank(address(attacker));
        attacker.withdraw(STAKE);

        assertEq(malicious.balanceOf(address(attacker)), STAKE);
        assertEq(malicious.balanceOf(address(vault)), 0);
        assertEq(vault.claimableBalance(address(malicious), address(attacker)), 0);
        assertEq(vault.totalCustody(address(malicious)), 0);

        // Nothing left to drain: a replayed withdrawal (as the reentrancy attempted) reverts.
        vm.prank(address(attacker));
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.InsufficientClaimable.selector, address(attacker), STAKE, 0)
        );
        attacker.withdraw(STAKE);
    }

    // -------------------------------------------------------------------------
    // ERC-165 / module version
    // -------------------------------------------------------------------------

    function test_supportsIStakeCustodyInterface() public view {
        assertTrue(vault.supportsInterface(type(IStakeCustody).interfaceId));
        assertTrue(vault.supportsInterface(type(IV2Module).interfaceId));
    }

    function test_protocolVersion() public view {
        (uint16 major, uint16 minor) = vault.protocolVersion();
        assertEq(major, 2);
        assertEq(minor, 0);
    }

    // -------------------------------------------------------------------------
    // Typed settlement hooks (V2-SC-012)
    // -------------------------------------------------------------------------

    function _depositAndLock(uint256 claimId, uint256 round, uint256 amount) internal {
        vm.prank(verifier);
        vault.depositStake(claimId, amount);
        if (round > 0) {
            vm.prank(settlement);
            vault.rolloverRound(address(token), verifier, claimId, 0, round, amount);
        }
    }

    function test_settleConclusive_unlocksPrincipalAndCreditsReward() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        // Fund protocol allocation for the reward without touching the principal lock:
        // deposit extra custody, lock it as a challenge bond, then move it to allocation.
        vm.prank(verifier);
        vault.deposit(address(token), STAKE);

        vm.prank(settlement);
        vault.lock(address(token), verifier, CLAIM_A, 1, IV2Types.LockCategory.CHALLENGE_BOND, STAKE);

        vm.prank(slashing);
        vault.allocateLocked(
            address(token), verifier, CLAIM_A, 1, IV2Types.LockCategory.CHALLENGE_BOND, STAKE, keccak256("reward-fund")
        );

        vm.prank(settlement);
        vault.settleConclusive(address(token), verifier, CLAIM_A, 0, STAKE, STAKE / 2);

        // Principal returned to claimable plus reward credited from protocol allocation.
        assertEq(vault.claimableBalance(address(token), verifier), STAKE + STAKE / 2);
        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL), 0);
        assertEq(uint256(vault.settlementOutcome(CLAIM_A, 0)), uint256(IV2Types.SettlementOutcome.CONCLUDED));
    }

    function test_settleConclusive_unauthorizedReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, verifier));
        vault.settleConclusive(address(token), verifier, CLAIM_A, 0, STAKE, 0);
    }

    function test_settleConclusive_duplicateReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.settleConclusive(address(token), verifier, CLAIM_A, 0, STAKE, 0);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SettlementAlreadyFinalized.selector, CLAIM_A, 0));
        vault.settleConclusive(address(token), verifier, CLAIM_A, 0, STAKE, 0);
    }

    function test_settleConclusive_conflictingOutcomeReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.refundInconclusive(address(token), verifier, CLAIM_A, 0, STAKE);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SettlementAlreadyFinalized.selector, CLAIM_A, 0));
        vault.settleConclusive(address(token), verifier, CLAIM_A, 0, STAKE, 0);
    }

    function test_allAlternateEntryPointsRevertAfterSettlement() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.settleConclusive(address(token), verifier, CLAIM_A, 0, STAKE, 0);

        uint256 verifierBalanceBefore = token.balanceOf(verifier);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SettlementAlreadyFinalized.selector, CLAIM_A, 0));
        vault.depositStake(CLAIM_A, STAKE);
        assertEq(token.balanceOf(verifier), verifierBalanceBefore);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SettlementAlreadyFinalized.selector, CLAIM_A, 0));
        vault.unlock(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, STAKE);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SettlementAlreadyFinalized.selector, CLAIM_A, 0));
        vault.releaseStake(CLAIM_A, verifier, STAKE);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SettlementAlreadyFinalized.selector, CLAIM_A, 0));
        vault.slashStake(CLAIM_A, verifier, STAKE, keccak256("replay"));

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SettlementAlreadyFinalized.selector, CLAIM_A, 0));
        vault.lock(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.BOUNTY_ESCROW, 1);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SettlementAlreadyFinalized.selector, CLAIM_A, 0));
        vault.allocateLocked(
            address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 1, keccak256("replay")
        );
    }

    function test_settleConclusive_overAllocationReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientLocked.selector, STAKE + 1, STAKE));
        vault.settleConclusive(address(token), verifier, CLAIM_A, 0, STAKE + 1, 0);
    }

    function test_settleConclusive_wrongAssetReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientLocked.selector, STAKE, 0));
        vault.settleConclusive(address(tokenB), verifier, CLAIM_A, 0, STAKE, 0);
    }

    function test_settleConclusive_wrongRoundReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientLocked.selector, STAKE, 0));
        vault.settleConclusive(address(token), verifier, CLAIM_A, 1, STAKE, 0);
    }

    function test_refundInconclusive_unlocksPrincipal() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.refundInconclusive(address(token), verifier, CLAIM_A, 0, STAKE);

        assertEq(vault.claimableBalance(address(token), verifier), STAKE);
        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL), 0);
        assertEq(uint256(vault.settlementOutcome(CLAIM_A, 0)), uint256(IV2Types.SettlementOutcome.REFUNDED));
    }

    function test_refundInconclusive_unauthorizedReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, verifier));
        vault.refundInconclusive(address(token), verifier, CLAIM_A, 0, STAKE);
    }

    function test_refundInconclusive_duplicateReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.refundInconclusive(address(token), verifier, CLAIM_A, 0, STAKE);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SettlementAlreadyFinalized.selector, CLAIM_A, 0));
        vault.refundInconclusive(address(token), verifier, CLAIM_A, 0, STAKE);
    }

    function test_carryForwardAppeal_movesLockToNextRound() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.carryForwardAppeal(address(token), verifier, CLAIM_A, 0, 1, STAKE);

        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL), 0);
        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 1, IV2Types.LockCategory.VERIFIER_PRINCIPAL), STAKE);
        assertEq(uint256(vault.settlementOutcome(CLAIM_A, 0)), uint256(IV2Types.SettlementOutcome.CARRIED_FORWARD));
        assertEq(vault.totalCustody(address(token)), STAKE);
    }

    function test_carryForwardAppeal_unauthorizedReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, verifier));
        vault.carryForwardAppeal(address(token), verifier, CLAIM_A, 0, 1, STAKE);
    }

    function test_carryForwardAppeal_duplicateReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.carryForwardAppeal(address(token), verifier, CLAIM_A, 0, 1, STAKE);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SettlementAlreadyFinalized.selector, CLAIM_A, 0));
        vault.carryForwardAppeal(address(token), verifier, CLAIM_A, 0, 2, STAKE);
    }

    function test_carryForwardAppeal_sameRoundReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidRoundTransfer.selector, uint256(0), uint256(0)));
        vault.carryForwardAppeal(address(token), verifier, CLAIM_A, 0, 0, STAKE);
    }

    function test_carryForwardAppeal_priorRoundRevertsWithoutMovingLock() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidArgument.selector, "destination round must be later"));
        vault.carryForwardAppeal(address(token), verifier, CLAIM_A, 1, 0, STAKE);

        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL), STAKE);
        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 1, IV2Types.LockCategory.VERIFIER_PRINCIPAL), 0);
        assertEq(vault.totalCustody(address(token)), STAKE);
    }

    function test_carryForwardAppeal_canMoveToLaterRound() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.carryForwardAppeal(address(token), verifier, CLAIM_A, 0, 2, STAKE);

        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL), 0);
        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 2, IV2Types.LockCategory.VERIFIER_PRINCIPAL), STAKE);
        assertEq(vault.totalCustody(address(token)), STAKE);
    }

    function test_rolloverRound_movesLockToNextRound() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.rolloverRound(address(token), verifier, CLAIM_A, 0, 1, STAKE);

        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL), 0);
        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 1, IV2Types.LockCategory.VERIFIER_PRINCIPAL), STAKE);
        assertEq(uint256(vault.settlementOutcome(CLAIM_A, 0)), uint256(IV2Types.SettlementOutcome.ROLLED_OVER));
    }

    function test_rolloverRound_unauthorizedReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, verifier));
        vault.rolloverRound(address(token), verifier, CLAIM_A, 0, 1, STAKE);
    }

    function test_finalUnlock_releasesLockToClaimable() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.finalUnlock(address(token), verifier, CLAIM_A, 0, STAKE);

        assertEq(vault.claimableBalance(address(token), verifier), STAKE);
        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL), 0);
        assertEq(uint256(vault.settlementOutcome(CLAIM_A, 0)), uint256(IV2Types.SettlementOutcome.UNLOCKED));
    }

    function test_finalUnlock_unauthorizedReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, verifier));
        vault.finalUnlock(address(token), verifier, CLAIM_A, 0, STAKE);
    }

    function test_timestampJumpCannotBypassSettlementAuthorizationOrCustody() public {
        uint256 verifierBalanceBefore = token.balanceOf(verifier);
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, verifier));
        vm.prank(verifier);
        vault.finalUnlock(address(token), verifier, CLAIM_A, 0, STAKE);

        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL), STAKE);
        assertEq(vault.totalCustody(address(token)), STAKE);
        assertEq(token.balanceOf(address(vault)), STAKE);

        vm.prank(settlement);
        vault.finalUnlock(address(token), verifier, CLAIM_A, 0, STAKE);
        vm.prank(verifier);
        vault.withdraw(address(token), STAKE);

        assertEq(token.balanceOf(verifier), verifierBalanceBefore);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.totalCustody(address(token)), 0);
    }

    function test_finalUnlock_duplicateReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.finalUnlock(address(token), verifier, CLAIM_A, 0, STAKE);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SettlementAlreadyFinalized.selector, CLAIM_A, 0));
        vault.finalUnlock(address(token), verifier, CLAIM_A, 0, STAKE);
    }

    function test_settlementOutcome_initialNone() public view {
        assertEq(uint256(vault.settlementOutcome(CLAIM_A, 0)), uint256(IV2Types.SettlementOutcome.NONE));
    }

    function test_settleConclusive_partialUnlock() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vault.settleConclusive(address(token), verifier, CLAIM_A, 0, STAKE / 2, 0);

        assertEq(vault.claimableBalance(address(token), verifier), STAKE / 2);
        assertEq(vault.lockedPrincipal(address(token), verifier, CLAIM_A, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL), STAKE / 2);
    }

    function test_settleConclusive_rewardExceedsAllocationReverts() public {
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientProtocolAllocation.selector, STAKE, 0));
        vault.settleConclusive(address(token), verifier, CLAIM_A, 0, 0, STAKE);
    }
}

/// @dev Attempts to reenter `withdraw` during token transfer.
contract StakeVaultReentrancyAttacker {
    StakeVault public vault;
    IERC20 public token;
    bool internal _entered;

    constructor(address vault_, address token_) {
        vault = StakeVault(vault_);
        token = IERC20(token_);
    }

    function withdraw(uint256 amount) external {
        vault.withdraw(address(token), amount);
    }

    function onERC20Received(address, uint256 amount) external {
        if (_entered) return;
        _entered = true;
        vault.withdraw(address(token), amount);
    }
}
