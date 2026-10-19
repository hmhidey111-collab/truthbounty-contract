// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../../contracts/v2/StakeVault.sol";
import "../../../contracts/v2/interfaces/IV2Types.sol";
import "../../../contracts/mocks/MockModuleRegistry.sol";
import "../../../contracts/MockERC20.sol";

/// @title SlashingBoundHandler
/// @notice Stateful handler for V2-SC-097 — cumulative slashing versus locked principal.
///
/// @dev The claim under proof is about a *cell*: the tuple
///      `(asset, account, claimId, round, category)` that `StakeVault._lockKey`
///      hashes. Slashing must never take more out of a cell than was put into
///      it, however many separate calls arrive and through whichever module
///      surface — verifier slashing, dispute penalties, appeal carry-forward, or
///      round retries.
///
///      To prove that, the handler keeps double-entry ghost accounting per cell:
///      every inflow (`lockedIn`, `movedIn`) and every outflow (`slashedOut`,
///      `unlockedOut`, `movedOut`) is recorded, and only ever on the success
///      branch of a `try`. A reverted call must leave the ghosts untouched, or
///      the invariant would be checked against a history that never happened.
///
///      The cell space is deliberately tiny — 3 accounts x 2 claims x 3 rounds.
///      Slashing bounds are only interesting when many operations land on the
///      *same* cell, and a wide key space means the fuzzer almost never collides.
contract SlashingBoundHandler is Test {
    StakeVault public vault;
    MockERC20 public token;
    MockModuleRegistry public registry;

    address public settlement = makeAddr("settlementModule");
    address public slashing = makeAddr("slashingModule");
    address public verification = makeAddr("verificationModule");

    uint256 public constant ACTOR_COUNT = 3;
    uint256 public constant CLAIM_COUNT = 2;
    uint256 public constant ROUND_COUNT = 3;

    address[3] public actors;

    // ---- ghost accounting, per cell -----------------------------------------
    mapping(bytes32 => uint256) public lockedIn;
    mapping(bytes32 => uint256) public movedIn;
    mapping(bytes32 => uint256) public slashedOut;
    mapping(bytes32 => uint256) public unlockedOut;
    mapping(bytes32 => uint256) public movedOut;

    // ---- ghost accounting, global -------------------------------------------
    uint256 public totalSlashed;
    uint256 public totalRewardCredited;
    uint256 public callsSlash;
    uint256 public callsLock;
    uint256 public callsCarryForward;
    uint256 public callsSettle;

    constructor() {
        registry = new MockModuleRegistry();
        token = new MockERC20("Stake", "STK");
        vault = new StakeVault(address(registry), address(token), address(this));

        registry.permitModule(vault.MODULE_SETTLEMENT(), settlement);
        registry.permitModule(vault.MODULE_SLASHING(), slashing);
        registry.permitModule(vault.MODULE_VERIFICATION(), verification);

        actors[0] = makeAddr("actorA");
        actors[1] = makeAddr("actorB");
        actors[2] = makeAddr("actorC");

        for (uint256 i; i < ACTOR_COUNT; ++i) {
            token.mint(actors[i], 1_000_000_000 ether);
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    // =========================================================================
    // Key + bounding helpers
    // =========================================================================

    function cellKey(address account, uint256 claimId, uint256 round) public pure returns (bytes32) {
        return keccak256(abi.encode(account, claimId, round));
    }

    function actorAt(uint256 seed) public view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _claim(uint256 seed) internal pure returns (uint256) {
        return (seed % CLAIM_COUNT) + 1;
    }

    function _round(uint256 seed) internal pure returns (uint256) {
        return seed % ROUND_COUNT;
    }

    function _amount(uint256 raw) internal pure returns (uint256) {
        return bound(raw, 1, 1_000 ether);
    }

    // =========================================================================
    // Inflows
    // =========================================================================

    /// @dev Deposit then lock, so the lock path is actually reachable rather
    ///      than starved of claimable balance.
    function fundAndLockPrincipal(uint256 actorSeed, uint256 claimSeed, uint256 roundSeed, uint256 rawAmount)
        public
    {
        address actor = actorAt(actorSeed);
        uint256 claimId = _claim(claimSeed);
        uint256 round = _round(roundSeed);
        uint256 amount = _amount(rawAmount);

        vm.prank(actor);
        try vault.deposit(address(token), amount) {} catch { return; }

        vm.prank(slashing);
        try vault.lock(
            address(token), actor, claimId, round, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount
        ) {
            lockedIn[cellKey(actor, claimId, round)] += amount;
            callsLock++;
        } catch {}
    }

    /// @dev The canonical verifier entry point: deposits and locks at round 0 in
    ///      a single call, so it cannot be starved.
    function depositStake(uint256 actorSeed, uint256 claimSeed, uint256 rawAmount) public {
        address actor = actorAt(actorSeed);
        uint256 claimId = _claim(claimSeed);
        uint256 amount = _amount(rawAmount);

        vm.prank(actor);
        try vault.depositStake(claimId, amount) {
            lockedIn[cellKey(actor, claimId, 0)] += amount;
            callsLock++;
        } catch {}
    }

    // =========================================================================
    // Slashing outflows — every surface that can reduce a lock to protocol funds
    // =========================================================================

    /// @dev Dispute/penalty surface: the SLASHING module allocates locked
    ///      principal to the protocol at an arbitrary round.
    function slashViaAllocateLocked(uint256 actorSeed, uint256 claimSeed, uint256 roundSeed, uint256 rawAmount)
        public
    {
        address actor = actorAt(actorSeed);
        uint256 claimId = _claim(claimSeed);
        uint256 round = _round(roundSeed);
        uint256 amount = _amount(rawAmount);

        vm.prank(slashing);
        try vault.allocateLocked(
            address(token), actor, claimId, round, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount, bytes32("penalty")
        ) {
            slashedOut[cellKey(actor, claimId, round)] += amount;
            totalSlashed += amount;
            callsSlash++;
        } catch {}
    }

    /// @dev Verification surface: `slashStake` is fixed to round 0.
    function slashViaStakeSurface(uint256 actorSeed, uint256 claimSeed, uint256 rawAmount) public {
        address actor = actorAt(actorSeed);
        uint256 claimId = _claim(claimSeed);
        uint256 amount = _amount(rawAmount);

        vm.prank(verification);
        try vault.slashStake(claimId, actor, amount, bytes32("verification")) {
            slashedOut[cellKey(actor, claimId, 0)] += amount;
            totalSlashed += amount;
            callsSlash++;
        } catch {}
    }

    // =========================================================================
    // Non-slashing outflows — must be accounted or the bound is meaningless
    // =========================================================================

    function unlockPrincipal(uint256 actorSeed, uint256 claimSeed, uint256 roundSeed, uint256 rawAmount) public {
        address actor = actorAt(actorSeed);
        uint256 claimId = _claim(claimSeed);
        uint256 round = _round(roundSeed);
        uint256 amount = _amount(rawAmount);

        vm.prank(slashing);
        try vault.unlock(
            address(token), actor, claimId, round, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount
        ) {
            unlockedOut[cellKey(actor, claimId, round)] += amount;
        } catch {}
    }

    /// @dev Appeal path. A carry-forward moves principal between rounds, so the
    ///      destination round gains slashable principal that was never deposited
    ///      into it directly. If this were not tracked, slashing at the
    ///      destination would look like it exceeded the cell's principal.
    function carryForwardAppeal(uint256 actorSeed, uint256 claimSeed, uint256 fromSeed, uint256 rawAmount) public {
        address actor = actorAt(actorSeed);
        uint256 claimId = _claim(claimSeed);
        uint256 fromRound = bound(fromSeed, 0, ROUND_COUNT - 2);
        uint256 toRound = fromRound + 1;
        uint256 amount = _amount(rawAmount);

        vm.prank(settlement);
        try vault.carryForwardAppeal(address(token), actor, claimId, fromRound, toRound, amount) {
            movedOut[cellKey(actor, claimId, fromRound)] += amount;
            movedIn[cellKey(actor, claimId, toRound)] += amount;
            callsCarryForward++;
        } catch {}
    }

    /// @dev Retry path. Same accounting shape as an appeal.
    function rolloverRound(uint256 actorSeed, uint256 claimSeed, uint256 fromSeed, uint256 rawAmount) public {
        address actor = actorAt(actorSeed);
        uint256 claimId = _claim(claimSeed);
        uint256 fromRound = bound(fromSeed, 0, ROUND_COUNT - 2);
        uint256 toRound = fromRound + 1;
        uint256 amount = _amount(rawAmount);

        vm.prank(settlement);
        try vault.rolloverRound(address(token), actor, claimId, fromRound, toRound, amount) {
            movedOut[cellKey(actor, claimId, fromRound)] += amount;
            movedIn[cellKey(actor, claimId, toRound)] += amount;
        } catch {}
    }

    function settleConclusive(
        uint256 actorSeed,
        uint256 claimSeed,
        uint256 roundSeed,
        uint256 rawPrincipal,
        uint256 rawReward
    ) public {
        address actor = actorAt(actorSeed);
        uint256 claimId = _claim(claimSeed);
        uint256 round = _round(roundSeed);
        uint256 principal = _amount(rawPrincipal);
        uint256 reward = bound(rawReward, 0, 10 ether);

        vm.prank(settlement);
        try vault.settleConclusive(address(token), actor, claimId, round, principal, reward) {
            unlockedOut[cellKey(actor, claimId, round)] += principal;
            totalRewardCredited += reward;
            callsSettle++;
        } catch {}
    }

    function refundInconclusive(uint256 actorSeed, uint256 claimSeed, uint256 roundSeed, uint256 rawAmount) public {
        address actor = actorAt(actorSeed);
        uint256 claimId = _claim(claimSeed);
        uint256 round = _round(roundSeed);
        uint256 amount = _amount(rawAmount);

        vm.prank(settlement);
        try vault.refundInconclusive(address(token), actor, claimId, round, amount) {
            unlockedOut[cellKey(actor, claimId, round)] += amount;
        } catch {}
    }

    function finalUnlock(uint256 actorSeed, uint256 claimSeed, uint256 roundSeed, uint256 rawAmount) public {
        address actor = actorAt(actorSeed);
        uint256 claimId = _claim(claimSeed);
        uint256 round = _round(roundSeed);
        uint256 amount = _amount(rawAmount);

        vm.prank(settlement);
        try vault.finalUnlock(address(token), actor, claimId, round, amount) {
            unlockedOut[cellKey(actor, claimId, round)] += amount;
        } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 rawAmount) public {
        address actor = actorAt(actorSeed);
        uint256 amount = _amount(rawAmount);

        vm.prank(actor);
        try vault.withdraw(address(token), amount) {} catch {}
    }
}

/// @title StakeVaultSlashingInvariantTest
/// @notice V2-SC-097 — proves cumulative slashing never exceeds locked principal.
contract StakeVaultSlashingInvariantTest is StdInvariant, Test {
    SlashingBoundHandler internal handler;

    function setUp() public {
        handler = new SlashingBoundHandler();
        // The handler is the fuzz target, not the vault. Targeting the vault
        // directly would have the fuzzer call it from random senders with random
        // arguments; every authorized path would fail `_onlyAuthorizedMutator`
        // and the run would prove nothing.
        targetContract(address(handler));
    }

    // =========================================================================
    // The V2-SC-097 claim
    // =========================================================================

    /// @notice Cumulative slashing from a cell never exceeds the principal that
    ///         entered it.
    /// @dev This is the issue's claim stated exactly: for an actor and a round,
    ///      everything ever slashed is bounded by everything ever locked into
    ///      that round, counting principal carried in from an earlier round.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_cumulativeSlashingNeverExceedsPrincipalIn() public view {
        for (uint256 a; a < handler.ACTOR_COUNT(); ++a) {
            address actor = handler.actorAt(a);
            for (uint256 c = 1; c <= handler.CLAIM_COUNT(); ++c) {
                for (uint256 r; r < handler.ROUND_COUNT(); ++r) {
                    bytes32 key = handler.cellKey(actor, c, r);
                    assertLe(
                        handler.slashedOut(key),
                        handler.lockedIn(key) + handler.movedIn(key),
                        "slashed more than was ever locked in"
                    );
                }
            }
        }
    }

    /// @notice Exact per-cell flow conservation.
    /// @dev Strictly stronger than the bound above: every base unit that entered
    ///      a cell is either still locked, slashed, unlocked, or moved to another
    ///      round. Nothing is created and nothing evaporates, so the slashing
    ///      bound cannot be satisfied by losing principal somewhere else.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_cellFlowsBalanceExactly() public view {
        StakeVault vault = handler.vault();
        address asset = address(handler.token());

        for (uint256 a; a < handler.ACTOR_COUNT(); ++a) {
            address actor = handler.actorAt(a);
            for (uint256 c = 1; c <= handler.CLAIM_COUNT(); ++c) {
                for (uint256 r; r < handler.ROUND_COUNT(); ++r) {
                    bytes32 key = handler.cellKey(actor, c, r);

                    uint256 inflow = handler.lockedIn(key) + handler.movedIn(key);
                    uint256 outflow =
                        handler.slashedOut(key) + handler.unlockedOut(key) + handler.movedOut(key);

                    assertEq(
                        vault.lockedPrincipal(asset, actor, c, r, IV2Types.LockCategory.VERIFIER_PRINCIPAL),
                        inflow - outflow,
                        "live lock does not equal inflow minus outflow"
                    );
                }
            }
        }
    }

    /// @notice A cell's live lock can never exceed what entered it.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_liveLockNeverExceedsPrincipalIn() public view {
        StakeVault vault = handler.vault();
        address asset = address(handler.token());

        for (uint256 a; a < handler.ACTOR_COUNT(); ++a) {
            address actor = handler.actorAt(a);
            for (uint256 c = 1; c <= handler.CLAIM_COUNT(); ++c) {
                for (uint256 r; r < handler.ROUND_COUNT(); ++r) {
                    bytes32 key = handler.cellKey(actor, c, r);
                    assertLe(
                        vault.lockedPrincipal(asset, actor, c, r, IV2Types.LockCategory.VERIFIER_PRINCIPAL),
                        handler.lockedIn(key) + handler.movedIn(key),
                        "live lock exceeds principal in"
                    );
                }
            }
        }
    }

    // =========================================================================
    // Slashed value is reclassified, never minted
    // =========================================================================

    /// @notice Protocol allocation is exactly what was slashed minus what was
    ///         paid back out as reward.
    /// @dev Rewards are funded from slashed principal (`_creditReward` draws down
    ///      `_protocolAllocation`), so the protocol can never pay a reward it did
    ///      not first take.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_protocolAllocationIsSlashedMinusRewarded() public view {
        assertEq(
            handler.vault().protocolAllocation(address(handler.token())),
            handler.totalSlashed() - handler.totalRewardCredited(),
            "protocol allocation diverged from slashed-minus-rewarded"
        );
    }

    /// @notice Rewards paid can never exceed principal slashed.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_rewardsNeverExceedSlashed() public view {
        assertLe(handler.totalRewardCredited(), handler.totalSlashed(), "rewarded more than slashed");
    }

    // =========================================================================
    // Custody conservation, which the bound rests on
    // =========================================================================

    /// @notice Accounted custody, obligations, and the real token balance agree.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_custodyObligationsAndBalanceAgree() public view {
        address asset = address(handler.token());
        (uint256 custody, uint256 obligations, uint256 actualBalance) = handler.vault().conservation(asset);

        assertEq(custody, obligations, "custody does not equal obligations");
        assertEq(custody, actualBalance, "custody does not equal token balance");
    }

    /// @notice Total slashed can never exceed everything ever deposited.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_totalSlashedBoundedByCustody() public view {
        address asset = address(handler.token());
        assertLe(
            handler.vault().protocolAllocation(asset),
            handler.vault().totalCustody(asset),
            "protocol allocation exceeds custody"
        );
    }

    // =========================================================================
    // Coverage guard
    // =========================================================================

    /// @notice Proves the handler can actually reach every surface it models.
    /// @dev A coverage guard is necessary: if every handler call reverted, all the
    ///      invariants above would hold vacuously. That is exactly the gap in the
    ///      pre-existing `test/v2/StakeVaultInvariant.t.sol`, whose handler is
    ///      never targeted and therefore never runs.
    ///
    ///      This is a deterministic test rather than an `afterInvariant` hook,
    ///      because the hook runs per sequence and an early sequence legitimately
    ///      may not have locked anything yet. Driving the handler directly proves
    ///      reachability without depending on fuzzer luck.
    function test_handlerReachesLockSlashAppealAndSettlement() public {
        // Lock principal for actor 0, claim 1, round 0.
        handler.fundAndLockPrincipal(0, 0, 0, 100 ether);
        assertGt(handler.callsLock(), 0, "lock path unreachable");

        bytes32 cell = handler.cellKey(handler.actorAt(0), 1, 0);
        assertEq(handler.lockedIn(cell), 100 ether, "ghost did not record the lock");

        // Slash part of it through the dispute/penalty surface.
        handler.slashViaAllocateLocked(0, 0, 0, 30 ether);
        assertGt(handler.callsSlash(), 0, "slash path unreachable");
        assertEq(handler.slashedOut(cell), 30 ether, "ghost did not record the slash");

        // Slash again through the verification surface, same cell.
        handler.slashViaStakeSurface(0, 0, 20 ether);
        assertEq(handler.slashedOut(cell), 50 ether, "cumulative slashing not accumulating");

        // The bound still holds after two slashes from two different surfaces.
        assertLe(
            handler.slashedOut(cell),
            handler.lockedIn(cell) + handler.movedIn(cell),
            "cumulative slashing exceeded principal in"
        );

        // Carry the remainder forward to round 1, then slash there.
        handler.carryForwardAppeal(0, 0, 0, 50 ether);
        assertGt(handler.callsCarryForward(), 0, "appeal path unreachable");

        bytes32 next = handler.cellKey(handler.actorAt(0), 1, 1);
        assertEq(handler.movedIn(next), 50 ether, "carry-forward not recorded as an inflow");

        handler.slashViaAllocateLocked(0, 0, 1, 50 ether);
        assertEq(handler.slashedOut(next), 50 ether, "carried principal is slashable");
        assertLe(
            handler.slashedOut(next),
            handler.lockedIn(next) + handler.movedIn(next),
            "slashing carried principal broke the bound"
        );

        // Nothing was ever locked directly into round 1: every unit slashed there
        // arrived by appeal. This is the case a per-round bound that ignored
        // carry-forward would report as a violation.
        assertEq(handler.lockedIn(next), 0, "round 1 had no direct deposits");

        // Settlement remains reachable on an untouched cell.
        handler.fundAndLockPrincipal(1, 1, 2, 10 ether);
        handler.settleConclusive(1, 1, 2, 10 ether, 0);
        assertGt(handler.callsSettle(), 0, "settlement path unreachable");
    }

    /// @notice Slashing more than a cell holds reverts rather than underflowing.
    function test_overSlashingRevertsAndLeavesStateIntact() public {
        handler.fundAndLockPrincipal(0, 0, 0, 100 ether);

        bytes32 cell = handler.cellKey(handler.actorAt(0), 1, 0);
        uint256 slashedBefore = handler.slashedOut(cell);

        // The handler swallows the revert, so the ghost must not move.
        handler.slashViaAllocateLocked(0, 0, 0, 101 ether);

        assertEq(handler.slashedOut(cell), slashedBefore, "a reverted slash must not be recorded");
        assertEq(
            handler.vault().lockedPrincipal(
                address(handler.token()), handler.actorAt(0), 1, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL
            ),
            100 ether,
            "over-slash must leave the lock intact"
        );
    }
}
