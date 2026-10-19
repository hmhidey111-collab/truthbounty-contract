// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeERC20 as OZSafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Claims} from "../../contracts/v2/Claims.sol";
import {FinalRewardAllocator} from "../../contracts/v2/FinalRewardAllocator.sol";
import {IFinalRewardAllocator} from "../../contracts/v2/interfaces/IFinalRewardAllocator.sol";
import {PullSettlementLedger} from "../../contracts/performance/PullSettlementLedger.sol";
import {EmergencyControls} from "../../contracts/v2/EmergencyControls.sol";
import {IV2Types} from "../../contracts/v2/interfaces/IV2Types.sol";
import {V2Errors} from "../../contracts/v2/libraries/V2Errors.sol";
import {PauseMatrix} from "../../contracts/v2/libraries/PauseMatrix.sol";
import {V2PauseGuard, V2WiredPauseGuard} from "../../contracts/v2/libraries/V2PauseGuard.sol";
import {HostilePauseAuthority} from "../../contracts/mocks/HostilePauseAuthority.sol";
import {PauseLivenessBase} from "./helpers/PauseLivenessBase.sol";
import {LivenessToken, HostileExitor, GasBurnerAuthority} from "./helpers/PauseLivenessHelpers.sol";

/// @title PauseExitLivenessTest
/// @notice V2-SC-162 — emergency pause preserves exit liveness.
/// @dev Fixture: one account (alice) holds value in every exit-bearing lifecycle phase at once:
///
///      | Phase                    | Where                      | Eligible exit                       |
///      |--------------------------|----------------------------|-------------------------------------|
///      | claimable deposit (100)  | StakeVault                 | `withdraw`                          |
///      | locked stake (50)        | StakeVault claim 1 round 0 | none until settlement (not matured) |
///      | settled / unlocked (30)  | StakeVault claim 2 round 0 | `withdraw`                          |
///      | final reward (40)        | FinalRewardAllocator       | `claim`                             |
///      | settlement credit (25)   | PullSettlementLedger       | `withdrawFromRef` / `withdraw`      |
///      | open claim bounty (10)   | Claims claim 1             | claimant `cancelClaim` refund       |
///      | finalized claim          | Claims claim 3 (REJECTED)  | none (terminal)                     |
///
///      Every pause configuration (each operation scope alone, all scopes, protocol levels 1-2) is
///      applied to that fixture and then: every eligible exit must succeed exactly once, every
///      repeat must revert without moving value, every risk-increasing operation must fail closed
///      exactly when its scope is paused, and all tracked value must be conserved.
contract PauseExitLivenessTest is PauseLivenessBase {
    uint256 internal constant CLAIM_LOCKED = 1;
    uint256 internal constant CLAIM_SETTLED = 2;
    uint256 internal constant CLAIM_NEW = 9;
    bytes32 internal constant SID_1 = keccak256("settlement-1");
    bytes32 internal constant SID_2 = keccak256("settlement-2");
    bytes32 internal constant REF_1 = keccak256("ref-1");
    bytes32 internal constant REF_2 = keccak256("ref-2");
    bytes32 internal constant REF_3 = keccak256("ref-3");
    bytes32 internal constant CONTENT_A = keccak256("content-a");
    bytes32 internal constant CONTENT_B = keccak256("content-b");

    uint256 internal constant ALICE_CLAIMABLE = 130 ether; // 100 deposit + 30 unlocked
    uint256 internal constant ALICE_LOCKED = 50 ether;
    uint256 internal constant ALICE_REWARD = 40 ether;
    uint256 internal constant BOB_REWARD = 20 ether;
    uint256 internal constant ALICE_CREDIT = 25 ether;
    uint256 internal constant BOB_CREDIT = 10 ether;
    uint256 internal constant BOUNTY = 10 ether;
    uint256 internal constant ALICE_EXIT_TOTAL = ALICE_CLAIMABLE + ALICE_REWARD + ALICE_CREDIT + BOUNTY;

    address internal mutatorCandidate = makeAddr("mutatorCandidate");

    uint256 internal aliceOpenClaim;
    uint256 internal bobOpenClaim;
    uint256 internal aliceFinalizedClaim;
    uint256 internal evidenceId;

    /// @dev Tracked value outside the modules' own accounting, for conservation checks.
    uint256 internal claimsEscrow;
    uint256 internal ledgerSpare;

    function setUp() public {
        _deployStack();

        // Phase: claimable deposit.
        vm.prank(alice);
        vault.deposit(address(token), 100 ether);
        // Phase: locked stake (not matured).
        vm.prank(alice);
        vault.depositStake(CLAIM_LOCKED, ALICE_LOCKED);
        // Phase: settled -> unlocked principal.
        vm.prank(alice);
        vault.depositStake(CLAIM_SETTLED, 30 ether);
        vm.prank(settlement);
        vault.finalUnlock(address(token), alice, CLAIM_SETTLED, 0, 30 ether);

        // Phase: final reward entitlement (alice 40, bob 20).
        _finalizeRewards(SID_1, alice, bob, ALICE_REWARD + BOB_REWARD);

        // Phase: pull-settlement credit, plus 1 ether spare for a later credit attempt.
        _creditLedger(alice, ALICE_CREDIT, REF_1);
        _creditLedger(bob, BOB_CREDIT, REF_2);
        token.mint(address(ledger), 1 ether);
        ledgerSpare = 1 ether;

        // Phase: open claims (refundable) and a finalized claim (terminal).
        vm.prank(alice);
        aliceOpenClaim = claims.createClaim(keccak256("subject-a"), BOUNTY, "");
        vm.prank(bob);
        bobOpenClaim = claims.createClaim(keccak256("subject-b"), BOUNTY, "");
        vm.prank(alice);
        aliceFinalizedClaim = claims.createClaim(keccak256("subject-c"), BOUNTY, "");
        claims.finalizeClaim(aliceFinalizedClaim, IV2Types.ClaimStatus.REJECTED);
        claimsEscrow = 3 * BOUNTY;

        // Evidence already on record (adjudication target).
        vm.prank(alice);
        evidenceId = evidence.submitEvidence(EV_CLAIM, CONTENT_A, bytes("meta-a"));

        _assertConservation();
    }

    // =========================================================================
    // Pause at every lifecycle phase, then every eligible exit
    // =========================================================================

    function test_liveness_underClaimsPause() public {
        _pauseScope(SCOPE_CLAIMS);
        _assertFullLiveness();
    }

    function test_liveness_underEvidencePause() public {
        _pauseScope(SCOPE_EVIDENCE);
        _assertFullLiveness();
    }

    function test_liveness_underStakingPause() public {
        _pauseScope(SCOPE_STAKING);
        _assertFullLiveness();
    }

    function test_liveness_underVerificationPause() public {
        _pauseScope(SCOPE_VERIFICATION);
        _assertFullLiveness();
    }

    function test_liveness_underSettlementPause() public {
        _pauseScope(SCOPE_SETTLEMENT);
        _assertFullLiveness();
    }

    function test_liveness_underTreasuryPause() public {
        _pauseScope(SCOPE_TREASURY);
        _assertFullLiveness();
    }

    function test_liveness_underDisputesPause() public {
        _pauseScope(SCOPE_DISPUTES);
        _assertFullLiveness();
    }

    function test_liveness_underGovernancePause() public {
        _pauseScope(SCOPE_GOVERNANCE);
        _assertFullLiveness();
    }

    function test_liveness_underEveryScopePausedAtOnce() public {
        bytes32[8] memory scopes = _allScopes();
        for (uint256 i; i < scopes.length; ++i) {
            _pauseScope(scopes[i]);
        }
        _assertFullLiveness();
    }

    function test_liveness_underProtocolHighRisk() public {
        _escalate(controller.LEVEL_HIGH_RISK());
        _assertFullLiveness();
    }

    function test_liveness_underProtocolFinancial() public {
        _escalate(controller.LEVEL_FINANCIAL());
        _assertFullLiveness();
    }

    /// @dev Any subset of scoped pauses: exits stay live and gates track the authority exactly.
    function testFuzz_liveness_underAnyScopedPauseSubset(uint8 mask) public {
        bytes32[8] memory scopes = _allScopes();
        for (uint256 i; i < scopes.length; ++i) {
            if (mask & (uint8(1) << i) != 0) _pauseScope(scopes[i]);
        }
        _assertFullLiveness();
    }

    /// @dev SHUTDOWN is the only state that freezes value exits; they resume after DAO lifts it and
    ///      then still pay exactly once.
    function test_shutdown_freezesExitsOnlyUntilGovernanceLifts() public {
        _escalate(controller.LEVEL_SHUTDOWN());
        assertTrue(vault.exitsFrozen(), "shutdown freezes exits");
        assertTrue(claims.exitsFrozen() && allocator.exitsFrozen() && ledger.exitsFrozen(), "consistent across modules");

        uint256 before = token.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(V2PauseGuard.ExitsFrozenByShutdown.selector);
        vault.withdraw(address(token), ALICE_CLAIMABLE);
        vm.expectRevert(V2PauseGuard.ExitsFrozenByShutdown.selector);
        allocator.claim(address(token), ALICE_REWARD);
        vm.expectRevert(V2PauseGuard.ExitsFrozenByShutdown.selector);
        ledger.withdraw(ALICE_CREDIT);
        vm.expectRevert(V2PauseGuard.ExitsFrozenByShutdown.selector);
        ledger.withdrawFromRef(REF_1, ALICE_CREDIT);
        vm.expectRevert(V2PauseGuard.ExitsFrozenByShutdown.selector);
        claims.cancelClaim(aliceOpenClaim);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), before, "no value moved during shutdown");

        // Protective actions stay available at shutdown.
        evidence.pause();
        evidence.unpause();
        vm.prank(alice);
        nonces.cancelNonce(7);
        assertTrue(nonces.isNonceUsed(alice, 7));
        vault.setLockMutator(mutatorCandidate, false);

        // The emergency council cannot lift; only DAO governance can.
        vm.prank(council);
        vm.expectRevert("Only DAO governance can lift pause");
        controller.liftPause(bytes32(0));

        _liftEscalation();
        assertFalse(vault.exitsFrozen(), "exits resume after governance lift");
        _exerciseAllExits();
        _assertRepeatExitsIdempotent();
        _assertConservation();
    }

    // =========================================================================
    // Risk-increasing operations fail closed under their scope (every gated op)
    // =========================================================================

    function test_everyGatedOperationFailsClosedUnderItsScope() public {
        // STAKING
        _pauseScope(SCOPE_STAKING);
        _expectPaused(alice, address(vault), abi.encodeCall(vault.depositStake, (CLAIM_NEW, 1 ether)));
        _expectPaused(alice, address(vault), abi.encodeCall(vault.deposit, (address(token), 1 ether)));
        _expectPaused(
            settlement,
            address(vault),
            abi.encodeCall(vault.lock, (address(token), alice, CLAIM_NEW, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 1 ether))
        );
        _unpauseScope(SCOPE_STAKING);

        // SETTLEMENT
        _pauseScope(SCOPE_SETTLEMENT);
        address t = address(token);
        _expectPaused(settlement, address(vault), abi.encodeCall(vault.releaseStake, (CLAIM_LOCKED, alice, 1 ether)));
        _expectPaused(settlement, address(vault), abi.encodeCall(vault.slashStake, (CLAIM_LOCKED, alice, 1 ether, bytes32("r"))));
        _expectPaused(
            settlement,
            address(vault),
            abi.encodeCall(vault.unlock, (t, alice, CLAIM_LOCKED, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 1 ether))
        );
        _expectPaused(
            settlement,
            address(vault),
            abi.encodeCall(
                vault.allocateLocked, (t, alice, CLAIM_LOCKED, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 1 ether, bytes32("r"))
            )
        );
        _expectPaused(settlement, address(vault), abi.encodeCall(vault.settleConclusive, (t, alice, CLAIM_LOCKED, 0, 1 ether, 0)));
        _expectPaused(settlement, address(vault), abi.encodeCall(vault.refundInconclusive, (t, alice, CLAIM_LOCKED, 0, 1 ether)));
        _expectPaused(settlement, address(vault), abi.encodeCall(vault.carryForwardAppeal, (t, alice, CLAIM_LOCKED, 0, 1, 1 ether)));
        _expectPaused(settlement, address(vault), abi.encodeCall(vault.rolloverRound, (t, alice, CLAIM_LOCKED, 0, 1, 1 ether)));
        _expectPaused(settlement, address(vault), abi.encodeCall(vault.finalUnlock, (t, alice, CLAIM_LOCKED, 0, ALICE_LOCKED)));
        _expectPaused(settlement, address(allocator), abi.encodeCall(allocator.fund, (t, 1 ether, SID_2)));
        _expectPaused(
            settlement,
            address(allocator),
            abi.encodeCall(
                allocator.finalizeRewards,
                (SID_2, t, IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, new IFinalRewardAllocator.Allocation[](0))
            )
        );
        _expectPaused(admin, address(ledger), abi.encodeCall(ledger.credit, (bob, 1 ether, REF_3)));
        _expectPaused(admin, address(ledger), abi.encodeCall(ledger.creditBatch, (new address[](0), new uint256[](0), REF_3)));
        _expectPaused(admin, address(claims), abi.encodeCall(claims.finalizeClaim, (bobOpenClaim, IV2Types.ClaimStatus.SETTLED)));
        _expectPaused(admin, address(claims), abi.encodeCall(claims.cancelClaim, (bobOpenClaim)));
        _unpauseScope(SCOPE_SETTLEMENT);

        // CLAIMS
        _pauseScope(SCOPE_CLAIMS);
        _expectPaused(alice, address(claims), abi.encodeCall(claims.createClaim, (keccak256("subject-d"), BOUNTY, bytes(""))));
        _unpauseScope(SCOPE_CLAIMS);

        // EVIDENCE
        _pauseScope(SCOPE_EVIDENCE);
        _expectPaused(alice, address(evidence), abi.encodeCall(evidence.submitEvidence, (EV_CLAIM, CONTENT_B, bytes("meta-b"))));
        _expectPaused(
            alice,
            address(evidence),
            abi.encodeCall(evidence.commitEvidence, (EV_CLAIM, CONTENT_B, keccak256("meta-b"), evidence.nextContributorNonce(alice)))
        );
        _expectPaused(admin, address(evidence), abi.encodeCall(evidence.setEvidenceStatus, (evidenceId, IV2Types.EvidenceStatus.ACCEPTED)));
        _unpauseScope(SCOPE_EVIDENCE);

        // GOVERNANCE (enabling direction; revocation stays live — see governance test)
        _pauseScope(SCOPE_GOVERNANCE);
        _expectPaused(admin, address(vault), abi.encodeCall(vault.setMinStakeAmount, (2 ether)));
        _expectPaused(admin, address(vault), abi.encodeCall(vault.setSupportedAsset, (makeAddr("newAsset"), true)));
        _expectPaused(admin, address(vault), abi.encodeCall(vault.setLockMutator, (mutatorCandidate, true)));
        _expectPaused(
            admin, address(claims), abi.encodeCall(claims.setAntiGriefParams, (MIN_BOUNTY, CLAIM_FEE, 10, 1 hours, 25, feeSink))
        );
        _unpauseScope(SCOPE_GOVERNANCE);

        // Nothing leaked while every gate was exercised.
        _assertConservation();
        assertEq(uint8(vault.settlementOutcome(CLAIM_LOCKED, 0)), uint8(IV2Types.SettlementOutcome.NONE));
        assertFalse(allocator.finalized(SID_2));
        assertFalse(ledger.isRefProcessed(REF_3));
    }

    // =========================================================================
    // Settlement cannot be bypassed; pause/unpause ordering cannot replay
    // =========================================================================

    function test_settlementPause_lockedStakeCannotExitAroundSettlement() public {
        _pauseScope(SCOPE_SETTLEMENT);

        // The locked (not matured) principal is not an eligible exit.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.InsufficientClaimable.selector, alice, ALICE_CLAIMABLE + ALICE_LOCKED, ALICE_CLAIMABLE
            )
        );
        vault.withdraw(address(token), ALICE_CLAIMABLE + ALICE_LOCKED);

        // The matured part still exits.
        vm.prank(alice);
        vault.withdraw(address(token), ALICE_CLAIMABLE);

        assertEq(
            vault.lockedPrincipal(address(token), alice, CLAIM_LOCKED, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL),
            ALICE_LOCKED,
            "locked stake untouched while settlement is paused"
        );
        assertEq(uint8(vault.settlementOutcome(CLAIM_LOCKED, 0)), uint8(IV2Types.SettlementOutcome.NONE));

        // After resolution, settlement runs exactly once and the principal becomes an exit.
        _unpauseScope(SCOPE_SETTLEMENT);
        vm.prank(settlement);
        vault.finalUnlock(address(token), alice, CLAIM_LOCKED, 0, ALICE_LOCKED);
        vm.prank(alice);
        vault.withdraw(address(token), ALICE_LOCKED);
        _assertConservation();
    }

    function test_pauseUnpauseCycles_cannotReplaySettlementOrExit() public {
        // Cycle 1: pause/unpause settlement, then settle claim 1.
        _pauseScope(SCOPE_SETTLEMENT);
        _unpauseScope(SCOPE_SETTLEMENT);
        vm.prank(settlement);
        vault.finalUnlock(address(token), alice, CLAIM_LOCKED, 0, ALICE_LOCKED);

        // Cycle 2: the recorded outcome survives another pause cycle.
        _pauseScope(SCOPE_SETTLEMENT);
        _unpauseScope(SCOPE_SETTLEMENT);
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SettlementAlreadyFinalized.selector, CLAIM_LOCKED, 0));
        vault.finalUnlock(address(token), alice, CLAIM_LOCKED, 0, ALICE_LOCKED);

        // Single-settlement for rewards and pull credits across pause cycles.
        _pauseScope(SCOPE_SETTLEMENT);
        _unpauseScope(SCOPE_SETTLEMENT);
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(FinalRewardAllocator.SettlementAlreadyFinalized.selector, SID_1));
        allocator.finalizeRewards(
            SID_1, address(token), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, new IFinalRewardAllocator.Allocation[](0)
        );
        vm.expectRevert(abi.encodeWithSelector(PullSettlementLedger.SettlementRefAlreadyProcessed.selector, REF_1));
        ledger.credit(alice, 1 ether, REF_1);

        // Exit while paused, unpause, exit again: the second attempt never pays.
        _pauseScope(SCOPE_STAKING);
        vm.prank(alice);
        vault.withdraw(address(token), ALICE_CLAIMABLE + ALICE_LOCKED);
        _unpauseScope(SCOPE_STAKING);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientClaimable.selector, alice, 1, 0));
        vault.withdraw(address(token), 1);

        _pauseScope(SCOPE_CLAIMS);
        vm.prank(alice);
        allocator.claim(address(token), ALICE_REWARD);
        _unpauseScope(SCOPE_CLAIMS);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FinalRewardAllocator.InsufficientClaimable.selector, 1, 0));
        allocator.claim(address(token), 1);

        _escalate(controller.LEVEL_FINANCIAL());
        vm.prank(alice);
        ledger.withdrawFromRef(REF_1, ALICE_CREDIT);
        _liftEscalation();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PullSettlementLedger.InsufficientCredit.selector, 0, 1));
        ledger.withdraw(1);

        _assertConservation();
    }

    // =========================================================================
    // Nested and partial pauses
    // =========================================================================

    /// @dev EvidenceRegistry has a module-local switch nested under the scoped authority: either one
    ///      blocks, and lifting one never reopens the other.
    function test_nestedPause_localAndScopedEvidenceSwitches() public {
        evidence.pause();
        _pauseScope(SCOPE_EVIDENCE);

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        evidence.submitEvidence(EV_CLAIM, CONTENT_B, bytes("meta-b"));

        evidence.unpause(); // local lifted, scoped still active
        vm.prank(alice);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        evidence.submitEvidence(EV_CLAIM, CONTENT_B, bytes("meta-b"));

        evidence.pause();
        _unpauseScope(SCOPE_EVIDENCE); // scoped lifted, local active again
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        evidence.submitEvidence(EV_CLAIM, CONTENT_B, bytes("meta-b"));

        evidence.unpause();
        vm.prank(alice);
        evidence.submitEvidence(EV_CLAIM, CONTENT_B, bytes("meta-b"));
        assertEq(evidence.evidenceCount(EV_CLAIM), 2);
    }

    /// @dev Scoped pause + protocol escalation: de-escalation never reopens a scoped pause, and exits
    ///      stay live at the deepest nesting.
    function test_nestedPause_scopedPauseSurvivesEscalationAndLift() public {
        _pauseScope(SCOPE_CLAIMS);
        _pauseScope(SCOPE_SETTLEMENT);
        _escalate(controller.LEVEL_FINANCIAL());

        _exerciseAllExits();

        // Resolver cannot resolve a scope while the protocol is escalated beyond its tolerance.
        vm.prank(resolver);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        gatekeeper.unpause(SCOPE_SETTLEMENT);

        _liftEscalation();
        assertTrue(claims.isScopePaused(SCOPE_CLAIMS), "scoped pause survives de-escalation");
        vm.prank(alice);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        claims.createClaim(keccak256("subject-d"), BOUNTY, "");

        _unpauseScope(SCOPE_CLAIMS);
        _unpauseScope(SCOPE_SETTLEMENT);
        vm.prank(alice);
        claims.createClaim(keccak256("subject-d"), BOUNTY, "");
        claimsEscrow += BOUNTY;

        _assertRepeatExitsIdempotent();
        _assertConservation();
    }

    /// @dev Partial pause of staking: new stake is blocked, but settlement-driven refunds continue and
    ///      the refunded principal is withdrawable.
    function test_partialPause_stakingOnly_refundsContinue() public {
        _pauseScope(SCOPE_STAKING);

        vm.prank(alice);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        vault.depositStake(CLAIM_NEW, 1 ether);

        vm.prank(settlement);
        vault.refundInconclusive(address(token), alice, CLAIM_LOCKED, 0, ALICE_LOCKED);
        vm.prank(alice);
        vault.withdraw(address(token), ALICE_CLAIMABLE + ALICE_LOCKED);
        assertEq(vault.claimableBalance(address(token), alice), 0);
        _assertConservation();
    }

    /// @dev Partial pause of settlement: staking continues, outcomes are frozen, exits are live.
    function test_partialPause_settlementOnly_stakingContinues() public {
        _pauseScope(SCOPE_SETTLEMENT);

        vm.prank(alice);
        vault.depositStake(CLAIM_NEW, 1 ether);
        vm.prank(settlement);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        vault.finalUnlock(address(token), alice, CLAIM_NEW, 0, 1 ether);

        vm.prank(alice);
        vault.withdraw(address(token), ALICE_CLAIMABLE);
        _assertConservation();
    }

    /// @dev The same guard works against `EmergencyControls` (global SCOPE_ALL pause).
    function test_globalPause_viaEmergencyControlsAuthority() public {
        EmergencyControls controls = new EmergencyControls(admin, council, dao);
        Claims globalClaims = new Claims(admin, address(token), feeSink, MIN_BOUNTY, CLAIM_FEE);
        globalClaims.setPauseAuthority(address(controls));

        vm.startPrank(alice);
        token.approve(address(globalClaims), type(uint256).max);
        uint256 id = globalClaims.createClaim(keccak256("global"), BOUNTY, "");
        vm.stopPrank();

        vm.prank(council);
        controls.pause(controls.SCOPE_ALL());

        vm.prank(alice);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        globalClaims.createClaim(keccak256("global-2"), BOUNTY, "");

        assertFalse(globalClaims.exitsFrozen(), "EmergencyControls has no shutdown level: exits live");
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        globalClaims.cancelClaim(id);
        assertEq(token.balanceOf(alice) - before, BOUNTY);
    }

    // =========================================================================
    // Hostile recipients, failed transfers, and recovery
    // =========================================================================

    function test_failedTransfer_leavesExitRetryableAndSinglePay() public {
        _pauseScope(SCOPE_SETTLEMENT);

        token.setFailMode(LivenessToken.FailMode.ReturnFalse);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OZSafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.withdraw(address(token), ALICE_CLAIMABLE);

        token.setFailMode(LivenessToken.FailMode.Revert);
        vm.prank(alice);
        vm.expectRevert(bytes("LivenessToken: transfer failed"));
        allocator.claim(address(token), ALICE_REWARD);
        vm.prank(alice);
        vm.expectRevert(bytes("LivenessToken: transfer failed"));
        claims.cancelClaim(aliceOpenClaim);

        // Rejected operations left every balance tracked and the claim still refundable.
        assertEq(vault.claimableBalance(address(token), alice), ALICE_CLAIMABLE);
        assertEq(allocator.claimable(address(token), alice), ALICE_REWARD);
        assertEq(uint8(claims.getClaim(aliceOpenClaim).status), uint8(IV2Types.ClaimStatus.OPEN));
        _assertConservation();

        // Recovery: the token is repaired while the pause is still active; each exit pays once.
        token.setFailMode(LivenessToken.FailMode.None);
        _exerciseAllExits();
        _assertRepeatExitsIdempotent();
        _assertConservation();
    }

    function test_rejectingRecipient_isIsolatedAndRecoverable() public {
        _pauseScope(SCOPE_SETTLEMENT);
        token.setBlocked(alice, true);

        vm.prank(alice);
        vm.expectRevert(bytes("LivenessToken: recipient rejected"));
        ledger.withdrawFromRef(REF_1, ALICE_CREDIT);

        // Failure isolation: another beneficiary is unaffected.
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        ledger.withdrawFromRef(REF_2, BOB_CREDIT);
        assertEq(token.balanceOf(bob) - bobBefore, BOB_CREDIT);
        vm.prank(bob);
        allocator.claim(address(token), BOB_REWARD);

        assertEq(ledger.availableRefBalance(alice, REF_1), ALICE_CREDIT, "rejected exit stays claimable");
        token.setBlocked(alice, false);
        _exerciseAllExits();
        _assertRepeatExitsIdempotent();
        _assertConservation();
    }

    function test_hostileReentrantRecipient_cannotDoubleWithdraw() public {
        HostileExitor exitor = new HostileExitor(vault, allocator, ledger, IERC20(address(token)));
        token.mint(address(exitor), 20 ether);
        exitor.approveVault(type(uint256).max);
        exitor.vaultDeposit(20 ether);
        _finalizeRewards(SID_2, address(exitor), bob, 30 ether); // exitor 20, bob 10
        _creditLedger(address(exitor), 5 ether, REF_3);
        token.setHooked(address(exitor), true);

        // Pause every scope: the hostile exitor still exits, exactly once per balance.
        bytes32[8] memory scopes = _allScopes();
        for (uint256 i; i < scopes.length; ++i) {
            _pauseScope(scopes[i]);
        }

        // Vault: reentry hits the reentrancy guard.
        exitor.configure(HostileExitor.Target.Vault, 20 ether, false);
        exitor.vaultWithdraw(20 ether);
        assertTrue(exitor.reentryAttempted());
        assertFalse(exitor.reentrySucceeded(), "vault reentry must fail");

        // Allocator: balance is debited before the transfer, so reentry finds nothing.
        exitor.configure(HostileExitor.Target.Allocator, 20 ether, false);
        exitor.allocatorClaim(20 ether);
        assertTrue(exitor.reentryAttempted());
        assertFalse(exitor.reentrySucceeded(), "allocator reentry must fail");

        // Ledger: reentry hits the reentrancy guard.
        exitor.configure(HostileExitor.Target.Ledger, 5 ether, false);
        exitor.ledgerWithdraw(5 ether);
        assertTrue(exitor.reentryAttempted());
        assertFalse(exitor.reentrySucceeded(), "ledger reentry must fail");

        assertEq(token.balanceOf(address(exitor)), 20 ether + 20 ether + 5 ether, "each balance paid exactly once");
        assertEq(vault.claimableBalance(address(token), address(exitor)), 0);
        assertEq(allocator.claimable(address(token), address(exitor)), 0);
        assertEq(ledger.availableBalance(address(exitor)), 0);
        _assertConservation();
    }

    function test_hostileRejectingRecipient_thenRecovers() public {
        HostileExitor exitor = new HostileExitor(vault, allocator, ledger, IERC20(address(token)));
        token.mint(address(exitor), 15 ether);
        exitor.approveVault(type(uint256).max);
        exitor.vaultDeposit(15 ether);
        token.setHooked(address(exitor), true);
        _pauseScope(SCOPE_STAKING);

        exitor.configure(HostileExitor.Target.None, 0, true);
        vm.expectRevert(bytes("HostileExitor: payment rejected"));
        exitor.vaultWithdraw(15 ether);
        assertEq(vault.claimableBalance(address(token), address(exitor)), 15 ether, "rejected exit stays tracked");

        exitor.configure(HostileExitor.Target.None, 0, false);
        exitor.vaultWithdraw(15 ether);
        assertEq(token.balanceOf(address(exitor)), 15 ether);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientClaimable.selector, address(exitor), 15 ether, 0));
        exitor.vaultWithdraw(15 ether);
        _assertConservation();
    }

    // =========================================================================
    // Pause-authority failures never trap exits; risk paths fail closed
    // =========================================================================

    function test_dependencyFailure_riskFailsClosed_exitsStayLive() public {
        HostilePauseAuthority hostile = new HostilePauseAuthority(0);
        vm.warp(block.timestamp + REWIRE_DELAY + 1);
        vm.prank(gkAdmin);
        gatekeeper.setEmergencyController(address(hostile));
        hostile.setMode(HostilePauseAuthority.FailureMode.AlwaysRevert);

        assertTrue(vault.isScopePaused(SCOPE_STAKING), "unclassifiable authority reads as paused");
        vm.prank(alice);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        vault.depositStake(CLAIM_NEW, 1 ether);
        vm.prank(alice);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        claims.createClaim(keccak256("subject-d"), BOUNTY, "");

        assertFalse(vault.exitsFrozen(), "a broken dependency never freezes exits");
        _exerciseAllExits();
        _assertRepeatExitsIdempotent();
        _assertConservation();
    }

    function test_registryFailure_riskFailsClosed_exitsStayLive() public {
        vm.mockCallRevert(
            address(registry),
            abi.encodeWithSignature("module(bytes32)", PauseMatrix.MODULE_EMERGENCY_CONTROLS),
            bytes("registry down")
        );
        (bool resolved,) = vault.pauseAuthority();
        assertFalse(resolved);

        vm.prank(alice);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        vault.depositStake(CLAIM_NEW, 1 ether);
        vm.prank(settlement);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        allocator.fund(address(token), 1 ether, SID_2);

        uint256 before = token.balanceOf(alice);
        vm.startPrank(alice);
        vault.withdraw(address(token), ALICE_CLAIMABLE);
        allocator.claim(address(token), ALICE_REWARD);
        vm.stopPrank();
        assertEq(token.balanceOf(alice) - before, ALICE_CLAIMABLE + ALICE_REWARD);
        vm.clearMockedCalls();
        _assertConservation();
    }

    function test_gasBurningAuthority_cannotStarveExits() public {
        GasBurnerAuthority burner = new GasBurnerAuthority();
        Claims burnerClaims = new Claims(admin, address(token), feeSink, MIN_BOUNTY, CLAIM_FEE);
        burnerClaims.setPauseAuthority(address(burner));
        vm.startPrank(alice);
        token.approve(address(burnerClaims), type(uint256).max);
        uint256 id = burnerClaims.createClaim(keccak256("burner"), BOUNTY, "");
        vm.stopPrank();

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        burnerClaims.cancelClaim{gas: 600_000}(id);
        assertEq(token.balanceOf(alice) - before, BOUNTY, "gas-bounded probe leaves enough gas to exit");
    }

    // =========================================================================
    // Timelock / authority: pauses cannot be bypassed from the module side
    // =========================================================================

    function test_wiring_isWriteOnce_soAdminCannotLiftAPause() public {
        _pauseScope(SCOPE_CLAIMS);
        EmergencyControls other = new EmergencyControls(admin, council, dao);

        vm.expectRevert(abi.encodeWithSelector(V2WiredPauseGuard.PauseAuthorityAlreadyWired.selector, address(gatekeeper)));
        claims.setPauseAuthority(address(other));
        vm.expectRevert(abi.encodeWithSelector(V2WiredPauseGuard.PauseAuthorityAlreadyWired.selector, address(gatekeeper)));
        ledger.setPauseAuthority(address(other));
        vm.expectRevert(abi.encodeWithSelector(V2WiredPauseGuard.PauseAuthorityAlreadyWired.selector, address(gatekeeper)));
        evidence.setPauseAuthority(address(other));

        assertTrue(claims.isScopePaused(SCOPE_CLAIMS), "pause still in force");
        (, address authority) = claims.pauseAuthority();
        assertEq(authority, address(gatekeeper));

        Claims fresh = new Claims(admin, address(token), feeSink, MIN_BOUNTY, CLAIM_FEE);
        vm.expectRevert(abi.encodeWithSelector(V2WiredPauseGuard.InvalidPauseAuthority.selector, address(0)));
        fresh.setPauseAuthority(address(0));
        vm.expectRevert(abi.encodeWithSelector(V2WiredPauseGuard.InvalidPauseAuthority.selector, alice));
        fresh.setPauseAuthority(alice); // EOA: no paused(bytes32) surface
        vm.prank(alice);
        vm.expectRevert();
        fresh.setPauseAuthority(address(other)); // not an admin
    }

    function test_governanceMutations_failClosed_revocationsStayLive() public {
        _pauseScope(SCOPE_GOVERNANCE);

        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        vault.setMinStakeAmount(2 ether);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        vault.setLockMutator(mutatorCandidate, true);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        vault.setSupportedAsset(makeAddr("newAsset"), true);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        claims.setAntiGriefParams(MIN_BOUNTY, CLAIM_FEE, 10, 1 hours, 25, feeSink);

        // Protective directions remain available during the incident.
        vault.setLockMutator(mutatorCandidate, false);
        vault.setSupportedAsset(makeAddr("newAsset"), false);
        assertEq(vault.minStakeAmount(), 1 ether, "parameters unchanged");

        _exerciseAllExits();
    }

    function test_managerCancel_isOutcomeDecision_claimantRefundIsExit() public {
        _pauseScope(SCOPE_SETTLEMENT);

        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        claims.cancelClaim(bobOpenClaim); // admin holds CLAIM_MANAGER_ROLE

        uint256 before = token.balanceOf(bob);
        vm.prank(bob);
        claims.cancelClaim(bobOpenClaim);
        assertEq(token.balanceOf(bob) - before, BOUNTY);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidClaimStateTransition.selector, bobOpenClaim));
        claims.cancelClaim(bobOpenClaim);
        claimsEscrow -= BOUNTY;
        _assertConservation();
    }

    // =========================================================================
    // Read paths and the matrix itself
    // =========================================================================

    function test_readPathsNeverGated() public {
        bytes32[8] memory scopes = _allScopes();
        for (uint256 i; i < scopes.length; ++i) {
            _pauseScope(scopes[i]);
        }
        _escalate(controller.LEVEL_SHUTDOWN());
        evidence.pause();

        vault.claimableBalance(address(token), alice);
        vault.reconcile(address(token));
        vault.conservation(address(token));
        vault.settlementOutcome(CLAIM_SETTLED, 0);
        vault.staked(CLAIM_LOCKED, alice);
        allocator.claimable(address(token), alice);
        allocator.finalized(SID_1);
        ledger.availableBalance(alice);
        ledger.availableRefBalance(alice, REF_1);
        claims.getClaim(aliceOpenClaim);
        claims.stateOf(aliceFinalizedClaim);
        evidence.getEvidence(evidenceId);
        evidence.claimEvidence(EV_CLAIM, 0, 10);
        assertTrue(vault.isScopePaused(SCOPE_STAKING));
        assertTrue(vault.exitsFrozen());
        vault.pauseAuthority();
        assertEq(vault.pauseMatrixVersion(), matrix.version());
    }

    /// @dev A view is a snapshot for display, never an execution permit. Status and recovery
    ///      balances remain readable through overlapping pauses, while the corresponding outcome
    ///      mutation rechecks its gate when submitted.
    function test_pauseViewsRemainReadable_butStaleStatusCannotAuthorizeSettlement() public {
        IV2Types.Claim memory beforePause = claims.getClaim(aliceOpenClaim);
        assertEq(uint8(beforePause.status), uint8(IV2Types.ClaimStatus.OPEN));

        _pauseScope(SCOPE_CLAIMS);
        _pauseScope(SCOPE_SETTLEMENT);
        _escalate(controller.LEVEL_FINANCIAL());

        IV2Types.Claim memory duringPause = claims.getClaim(aliceOpenClaim);
        assertEq(uint8(duringPause.status), uint8(IV2Types.ClaimStatus.OPEN));
        assertEq(uint8(claims.stateOf(aliceOpenClaim)), uint8(IV2Types.ClaimState.VerificationOpen));
        assertEq(vault.claimableBalance(address(token), alice), ALICE_CLAIMABLE);
        assertEq(allocator.claimable(address(token), alice), ALICE_REWARD);
        assertEq(ledger.availableBalance(alice), ALICE_CREDIT);

        // The prior OPEN status is useful for display but cannot authorize settlement now.
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        claims.finalizeClaim(aliceOpenClaim, IV2Types.ClaimStatus.REJECTED);

        // Recovery exits remain usable during pause nesting and the reads reflect their effects.
        vm.prank(alice);
        vault.withdraw(address(token), ALICE_CLAIMABLE);
        assertEq(vault.claimableBalance(address(token), alice), 0);
    }

    function test_matrixVersionIsConsistentAcrossModules() public view {
        uint16 v = matrix.version();
        assertEq(v, 1);
        assertEq(vault.pauseMatrixVersion(), v);
        assertEq(claims.pauseMatrixVersion(), v);
        assertEq(allocator.pauseMatrixVersion(), v);
        assertEq(ledger.pauseMatrixVersion(), v);
        assertEq(evidence.pauseMatrixVersion(), v);
    }

    function test_matrixClassifiesEveryOperationConsistently() public view {
        string[37] memory ops = [
            "StakeVault|depositStake(uint256,uint256)",
            "StakeVault|deposit(address,uint256)",
            "StakeVault|lock(address,address,uint256,uint256,IV2Types.LockCategory,uint256)",
            "StakeVault|releaseStake(uint256,address,uint256)",
            "StakeVault|slashStake(uint256,address,uint256,bytes32)",
            "StakeVault|unlock(address,address,uint256,uint256,IV2Types.LockCategory,uint256)",
            "StakeVault|allocateLocked(address,address,uint256,uint256,IV2Types.LockCategory,uint256,bytes32)",
            "StakeVault|settleConclusive(address,address,uint256,uint256,uint256,uint256)",
            "StakeVault|refundInconclusive(address,address,uint256,uint256,uint256)",
            "StakeVault|carryForwardAppeal(address,address,uint256,uint256,uint256,uint256)",
            "StakeVault|rolloverRound(address,address,uint256,uint256,uint256,uint256)",
            "StakeVault|finalUnlock(address,address,uint256,uint256,uint256)",
            "StakeVault|setMinStakeAmount(uint256)",
            "StakeVault|setSupportedAsset(address,bool)",
            "StakeVault|setLockMutator(address,bool)",
            "StakeVault|withdraw(address,uint256)",
            "Claims|createClaim(bytes32,uint256,bytes)",
            "Claims|finalizeClaim(uint256,IV2Types.ClaimStatus)",
            "Claims|setAntiGriefParams(uint256,uint256,uint256,uint64,uint256,address)",
            "Claims|cancelClaim(uint256)",
            "Claims|setPauseAuthority(address)",
            "EvidenceRegistry|submitEvidence(uint256,bytes32,bytes)",
            "EvidenceRegistry|commitEvidence(uint256,bytes32,bytes32,uint256)",
            "EvidenceRegistry|setEvidenceStatus(uint256,IV2Types.EvidenceStatus)",
            "EvidenceRegistry|pause()",
            "EvidenceRegistry|unpause()",
            "EvidenceRegistry|setPauseAuthority(address)",
            "FinalRewardAllocator|fund(address,uint256,bytes32)",
            "FinalRewardAllocator|finalizeRewards(bytes32,address,FinalOutcome,Allocation[])",
            "FinalRewardAllocator|claim(address,uint256)",
            "Aggregation|finalizeAggregation(uint256)",
            "PullSettlementLedger|credit(address,uint256,bytes32)",
            "PullSettlementLedger|creditBatch(address[],uint256[],bytes32)",
            "PullSettlementLedger|withdraw(uint256)",
            "PullSettlementLedger|withdrawFromRef(bytes32,uint256)",
            "PullSettlementLedger|setPauseAuthority(address)",
            "SignatureNonces|cancelNonce(uint256)"
        ];
        bytes32 exitGate = matrix.exitGate();
        bytes32 noGate = matrix.noGate();
        for (uint256 i; i < ops.length; ++i) {
            (string memory moduleName, string memory signature) = _split(ops[i]);
            (PauseMatrix.RiskClass risk, bytes32 a, bytes32 b) = matrix.classify(moduleName, signature);
            if (risk == PauseMatrix.RiskClass.RISK_INCREASING) {
                assertTrue(matrix.isScopeGate(a), "risk-increasing ops fail closed on a scope");
                assertTrue(b == noGate || matrix.isScopeGate(b), "second gate is a scope");
            } else if (risk == PauseMatrix.RiskClass.RISK_REDUCING) {
                assertTrue(a == exitGate || a == noGate, "risk-reducing ops are never unconditionally scope-gated");
            } else {
                assertEq(a, noGate, "neutral ops are ungated");
                assertEq(b, noGate, "neutral ops are ungated");
            }
        }
    }

    function test_matrixRejectsUnclassifiedOperation() public {
        string memory moduleName = "StakeVault";
        string memory signature = "sweep(address)";
        vm.expectRevert(abi.encodeWithSelector(PauseMatrix.UnclassifiedOperation.selector, moduleName, signature));
        matrix.classify(moduleName, signature);
    }

    /// @dev Mixing the aggregate and per-ref exit paths can never pay the same credit twice
    ///      (V2-SC-162 fix in PullSettlementLedger.withdrawFromRef).
    function test_ledgerMixedExitPaths_cannotDoubleWithdraw() public {
        _pauseScope(SCOPE_SETTLEMENT);
        vm.startPrank(alice);
        ledger.withdraw(ALICE_CREDIT); // aggregate path drains REF_1's value
        assertEq(ledger.availableRefBalance(alice, REF_1), ALICE_CREDIT, "per-ref view is not advanced by withdraw");
        vm.expectRevert(abi.encodeWithSelector(PullSettlementLedger.InsufficientCredit.selector, 0, ALICE_CREDIT));
        ledger.withdrawFromRef(REF_1, ALICE_CREDIT);
        vm.stopPrank();
        assertEq(ledger.withdrawn(alice), ledger.credited(alice), "withdrawn never exceeds credited");
        _assertConservation();
    }

    // =========================================================================
    // Shared assertions
    // =========================================================================

    /// @dev Exits first (exact amounts), then repeats, then every risk gate, then conservation.
    function _assertFullLiveness() internal {
        _assertGateConsistency();
        _exerciseAllExits();
        _assertRepeatExitsIdempotent();
        _assertRiskGates();
        _assertConservation();
    }

    /// @dev Every module classifies every scope exactly as the authority does.
    function _assertGateConsistency() internal view {
        bytes32[8] memory scopes = _allScopes();
        for (uint256 i; i < scopes.length; ++i) {
            bool expected = gatekeeper.paused(scopes[i]);
            assertEq(vault.isScopePaused(scopes[i]), expected, "vault gate");
            assertEq(claims.isScopePaused(scopes[i]), expected, "claims gate");
            assertEq(allocator.isScopePaused(scopes[i]), expected, "allocator gate");
            assertEq(ledger.isScopePaused(scopes[i]), expected, "ledger gate");
            assertEq(evidence.isScopePaused(scopes[i]), expected, "evidence gate");
        }
        assertFalse(vault.exitsFrozen(), "exits only freeze at shutdown");
    }

    function _exerciseAllExits() internal {
        uint256 before = token.balanceOf(alice);
        vm.startPrank(alice);
        vault.withdraw(address(token), ALICE_CLAIMABLE);
        allocator.claim(address(token), ALICE_REWARD);
        ledger.withdrawFromRef(REF_1, 10 ether);
        ledger.withdraw(ALICE_CREDIT - 10 ether);
        claims.cancelClaim(aliceOpenClaim);
        nonces.cancelNonce(uint256(keccak256("liveness")));
        vm.stopPrank();
        claimsEscrow -= BOUNTY;

        // Protective and neutral actions are available under every non-shutdown pause.
        evidence.pause();
        evidence.unpause();
        vault.setLockMutator(mutatorCandidate, false);

        assertEq(token.balanceOf(alice) - before, ALICE_EXIT_TOTAL, "every eligible exit paid exactly once");
        assertEq(vault.claimableBalance(address(token), alice), 0);
        assertEq(
            vault.lockedPrincipal(address(token), alice, CLAIM_LOCKED, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL),
            ALICE_LOCKED,
            "unmatured stake is not an exit"
        );
        assertEq(allocator.claimable(address(token), alice), 0);
        assertEq(ledger.availableBalance(alice), 0);
        assertEq(uint8(claims.getClaim(aliceOpenClaim).status), uint8(IV2Types.ClaimStatus.CANCELLED));
    }

    function _assertRepeatExitsIdempotent() internal {
        uint256 before = token.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientClaimable.selector, alice, ALICE_CLAIMABLE, 0));
        vault.withdraw(address(token), ALICE_CLAIMABLE);
        vm.expectRevert(abi.encodeWithSelector(FinalRewardAllocator.InsufficientClaimable.selector, ALICE_REWARD, 0));
        allocator.claim(address(token), ALICE_REWARD);
        vm.expectRevert(abi.encodeWithSelector(PullSettlementLedger.InsufficientCredit.selector, 0, 10 ether));
        ledger.withdrawFromRef(REF_1, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(PullSettlementLedger.InsufficientCredit.selector, 0, ALICE_CREDIT));
        ledger.withdraw(ALICE_CREDIT);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidClaimStateTransition.selector, aliceOpenClaim));
        claims.cancelClaim(aliceOpenClaim);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidClaimStateTransition.selector, aliceFinalizedClaim));
        claims.cancelClaim(aliceFinalizedClaim);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), before, "repeats move no value");
    }

    /// @dev Each risk-increasing representative must fail closed iff the authority pauses its scope.
    function _assertRiskGates() internal {
        address t = address(token);

        // CLAIMS
        if (_attempt(alice, address(claims), abi.encodeCall(claims.createClaim, (keccak256("subject-d"), 1 ether, bytes(""))), SCOPE_CLAIMS)) {
            claimsEscrow += 1 ether;
        }
        // STAKING (before GOVERNANCE, which may raise the stake floor)
        _attempt(alice, address(vault), abi.encodeCall(vault.depositStake, (CLAIM_NEW, 1 ether)), SCOPE_STAKING);
        _attempt(alice, address(vault), abi.encodeCall(vault.deposit, (t, 1 ether)), SCOPE_STAKING);
        // SETTLEMENT
        _attempt(settlement, address(vault), abi.encodeCall(vault.finalUnlock, (t, alice, CLAIM_LOCKED, 0, ALICE_LOCKED)), SCOPE_SETTLEMENT);
        _attempt(settlement, address(allocator), abi.encodeCall(allocator.fund, (t, 1 ether, SID_2)), SCOPE_SETTLEMENT);
        if (_attempt(admin, address(ledger), abi.encodeCall(ledger.credit, (bob, 1 ether, REF_3)), SCOPE_SETTLEMENT)) {
            ledgerSpare -= 1 ether;
        }
        _attempt(admin, address(claims), abi.encodeCall(claims.finalizeClaim, (bobOpenClaim, IV2Types.ClaimStatus.SETTLED)), SCOPE_SETTLEMENT);
        // EVIDENCE
        _attempt(alice, address(evidence), abi.encodeCall(evidence.submitEvidence, (EV_CLAIM, CONTENT_B, bytes("meta-b"))), SCOPE_EVIDENCE);
        _attempt(admin, address(evidence), abi.encodeCall(evidence.setEvidenceStatus, (evidenceId, IV2Types.EvidenceStatus.ACCEPTED)), SCOPE_EVIDENCE);
        // GOVERNANCE
        _attempt(admin, address(vault), abi.encodeCall(vault.setLockMutator, (mutatorCandidate, true)), SCOPE_GOVERNANCE);
        _attempt(
            admin, address(claims), abi.encodeCall(claims.setAntiGriefParams, (MIN_BOUNTY, CLAIM_FEE, 10, 1 hours, 25, feeSink)), SCOPE_GOVERNANCE
        );
        _attempt(admin, address(vault), abi.encodeCall(vault.setMinStakeAmount, (2 ether)), SCOPE_GOVERNANCE);
    }

    /// @dev Calls `target` as `caller`; asserts `ProtocolPaused` iff `scope` is paused. Returns success.
    function _attempt(address caller, address target, bytes memory data, bytes32 scope) internal returns (bool ok) {
        bool paused = gatekeeper.paused(scope);
        bytes memory ret;
        vm.prank(caller);
        (ok, ret) = target.call(data);
        if (paused) {
            assertFalse(ok, "risk-increasing operation must fail closed while its scope is paused");
            assertGe(ret.length, 4);
            assertEq(bytes4(ret), V2Errors.ProtocolPaused.selector, "fails closed with ProtocolPaused");
        } else {
            assertTrue(ok, "risk-increasing operation must work while its scope is live");
        }
    }

    function _expectPaused(address caller, address target, bytes memory data) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(data);
        assertFalse(ok, "gated operation must fail closed");
        assertGe(ret.length, 4);
        assertEq(bytes4(ret), V2Errors.ProtocolPaused.selector, "fails closed with ProtocolPaused");
    }

    /// @dev Asset conservation across every value-holding module in the fixture.
    function _assertConservation() internal view {
        address t = address(token);
        (uint256 custody, uint256 obligations) = vault.reconcile(t);
        assertEq(custody, obligations, "vault obligations == custody");
        assertEq(token.balanceOf(address(vault)), custody, "vault balance == custody");

        uint256 allocatorOwed = allocator.claimable(t, alice) + allocator.claimable(t, bob)
            + (allocator.funded(t) - allocator.allocated(t));
        assertEq(token.balanceOf(address(allocator)), allocatorOwed, "allocator balance == entitlements + unallocated");

        uint256 ledgerOwed = ledger.availableBalance(alice) + ledger.availableBalance(bob);
        assertEq(token.balanceOf(address(ledger)), ledgerOwed + ledgerSpare, "ledger balance == outstanding credit");

        assertEq(token.balanceOf(address(claims)), claimsEscrow, "claims balance == escrow of non-cancelled claims");
    }

    function _split(string memory entry) internal pure returns (string memory left, string memory right) {
        bytes memory raw = bytes(entry);
        uint256 bar;
        while (raw[bar] != "|") ++bar;
        bytes memory l = new bytes(bar);
        bytes memory r = new bytes(raw.length - bar - 1);
        for (uint256 i; i < bar; ++i) l[i] = raw[i];
        for (uint256 i; i < r.length; ++i) r[i] = raw[bar + 1 + i];
        return (string(l), string(r));
    }
}
