// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {StakeVault} from "../../../contracts/v2/StakeVault.sol";
import {Claims} from "../../../contracts/v2/Claims.sol";
import {FinalRewardAllocator} from "../../../contracts/v2/FinalRewardAllocator.sol";
import {IFinalRewardAllocator} from "../../../contracts/v2/interfaces/IFinalRewardAllocator.sol";
import {PullSettlementLedger} from "../../../contracts/performance/PullSettlementLedger.sol";
import {EmergencyGatekeeper} from "../../../contracts/v2/EmergencyGatekeeper.sol";
import {EmergencyController} from "../../../contracts/governance/EmergencyController.sol";
import {IV2Types} from "../../../contracts/v2/interfaces/IV2Types.sol";
import {PauseLivenessBase} from "../helpers/PauseLivenessBase.sol";
import {LivenessToken} from "../helpers/PauseLivenessHelpers.sol";

/// @title PauseExitLivenessHandler
/// @notice Randomly interleaves scoped pauses, protocol escalation / lift, risk-increasing
///         operations, settlement, exits, repeat and replay attempts, and token failures.
/// @dev Every exit that is *eligible* (value is owned and final, exits are not frozen by SHUTDOWN,
///      and the token / recipient accept the transfer) and still fails is recorded as a liveness
///      violation. Every repeat, replay, or over-withdrawal that succeeds is recorded as a
///      duplication. The invariant contract asserts both counters stay zero.
contract PauseExitLivenessHandler is PauseLivenessBase {
    address[2] internal users;

    // ─── Ghost accounting ───────────────────────────────────────────────────────────────────
    mapping(address => uint256) public ghostVaultClaimable;
    uint256 public ghostVaultIn;
    uint256 public ghostVaultOut;

    mapping(address => uint256) public ghostRewardAllocated;
    mapping(address => uint256) public ghostRewardClaimed;
    uint256 public ghostRewardClaimedTotal;
    bytes32[] internal settlementIds;

    mapping(address => uint256) public ghostCredited;
    mapping(address => uint256) public ghostLedgerWithdrawn;
    mapping(address => bytes32[]) internal userRefs;
    uint256 internal refNonce;

    uint256[] internal claimIds;
    mapping(uint256 => address) internal claimOwner;
    mapping(uint256 => bool) internal claimRefunded;
    uint256 public ghostClaimsEscrow;

    mapping(uint256 => bool) internal claimSettled;

    // ─── Violation counters (must stay zero) ────────────────────────────────────────────────
    uint256 public livenessViolations;
    uint256 public duplications;

    constructor() {
        _deployStack();
        users[0] = alice;
        users[1] = bob;
    }

    // ─── Accessors for the invariant contract ───────────────────────────────────────────────
    function tokenAddr() external view returns (LivenessToken) { return token; }
    function vaultAddr() external view returns (StakeVault) { return vault; }
    function allocatorAddr() external view returns (FinalRewardAllocator) { return allocator; }
    function ledgerAddr() external view returns (PullSettlementLedger) { return ledger; }
    function claimsAddr() external view returns (Claims) { return claims; }
    function gatekeeperAddr() external view returns (EmergencyGatekeeper) { return gatekeeper; }
    function controllerAddr() external view returns (EmergencyController) { return controller; }
    function userAt(uint256 i) external view returns (address) { return users[i]; }
    function scopes() external pure returns (bytes32[8] memory) { return _allScopes(); }

    // ─── Pause controls ─────────────────────────────────────────────────────────────────────
    function pauseScope(uint256 seed) external {
        bytes32 scope = _allScopes()[seed % 8];
        if (gatekeeper.locallyPaused(scope)) return;
        vm.prank(resolver);
        try gatekeeper.pause(scope) {} catch {}
    }

    function unpauseScope(uint256 seed) external {
        bytes32 scope = _allScopes()[seed % 8];
        if (!gatekeeper.locallyPaused(scope)) return;
        vm.prank(resolver);
        try gatekeeper.unpause(scope) {} catch {}
    }

    function escalate(uint256 seed) external {
        uint8 level = uint8(1 + (seed % 3));
        if (level <= controller.currentPauseLevel()) return;
        vm.prank(council);
        try controller.activatePause(level, "invariant", bytes32(0)) {} catch {}
    }

    function lift() external {
        if (controller.currentPauseLevel() == 0) return;
        vm.prank(dao);
        try controller.liftPause(bytes32(0)) {} catch {}
    }

    function setTokenFaults(uint256 modeSeed, uint256 userSeed, bool blockUser) external {
        uint256 m = modeSeed % 6; // biased toward a healthy token
        token.setFailMode(m == 4 ? LivenessToken.FailMode.ReturnFalse : m == 5 ? LivenessToken.FailMode.Revert : LivenessToken.FailMode.None);
        token.setBlocked(_user(userSeed), blockUser && modeSeed % 3 == 0);
    }

    // ─── Risk-increasing operations ─────────────────────────────────────────────────────────
    function deposit(uint256 userSeed, uint256 amount) external {
        address user = _user(userSeed);
        amount = bound(amount, 1, 100 ether);
        vm.prank(user);
        try vault.deposit(address(token), amount) {
            ghostVaultClaimable[user] += amount;
            ghostVaultIn += amount;
        } catch {}
    }

    function stake(uint256 userSeed, uint256 claimSeed, uint256 amount) external {
        address user = _user(userSeed);
        uint256 claimId = _claimFor(userSeed, claimSeed);
        amount = bound(amount, 1 ether, 100 ether);
        vm.prank(user);
        try vault.depositStake(claimId, amount) {
            ghostVaultIn += amount;
        } catch {}
    }

    function settle(uint256 userSeed, uint256 claimSeed, bool refund) external {
        address user = _user(userSeed);
        uint256 claimId = _claimFor(userSeed, claimSeed);
        uint256 locked =
            vault.lockedPrincipal(address(token), user, claimId, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL);
        if (locked == 0) return;
        vm.prank(settlement);
        if (refund) {
            try vault.refundInconclusive(address(token), user, claimId, 0, locked) {
                _recordSettlement(user, claimId, locked);
            } catch {}
        } else {
            try vault.finalUnlock(address(token), user, claimId, 0, locked) {
                _recordSettlement(user, claimId, locked);
            } catch {}
        }
    }

    function finalizeRewards(uint256 amount) external {
        amount = bound(amount, 3, 100 ether);
        bytes32 id = keccak256(abi.encode("sid", settlementIds.length, amount));
        vm.prank(settlement);
        try allocator.fund(address(token), amount, id) {} catch {
            return;
        }
        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 2;
        weights[1] = 1;
        IFinalRewardAllocator.Allocation[] memory allocations = new IFinalRewardAllocator.Allocation[](1);
        allocations[0] = IFinalRewardAllocator.Allocation({
            category: IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
            accounts: accounts,
            effectiveWeights: weights,
            amount: amount,
            remainderRecipient: alice
        });
        vm.prank(settlement);
        try allocator.finalizeRewards(id, address(token), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, allocations) {
            uint256 aliceShare = (amount * 2) / 3;
            uint256 bobShare = amount / 3;
            ghostRewardAllocated[alice] += aliceShare + (amount - aliceShare - bobShare);
            ghostRewardAllocated[bob] += bobShare;
            settlementIds.push(id);
        } catch {}
    }

    function credit(uint256 userSeed, uint256 amount) external {
        address user = _user(userSeed);
        amount = bound(amount, 1, 100 ether);
        bytes32 ref = keccak256(abi.encode("ref", ++refNonce));
        try ledger.credit(user, amount, ref) {
            token.mint(address(ledger), amount);
            ghostCredited[user] += amount;
            userRefs[user].push(ref);
        } catch {}
    }

    function createClaim(uint256 userSeed) external {
        address user = _user(userSeed);
        vm.prank(user);
        try claims.createClaim(keccak256(abi.encode("subject", claimIds.length)), MIN_BOUNTY, "") returns (uint256 id) {
            claimIds.push(id);
            claimOwner[id] = user;
            ghostClaimsEscrow += MIN_BOUNTY;
        } catch {}
    }

    function finalizeClaim(uint256 idSeed) external {
        if (claimIds.length == 0) return;
        uint256 id = claimIds[idSeed % claimIds.length];
        try claims.finalizeClaim(id, IV2Types.ClaimStatus.REJECTED) {} catch {}
    }

    // ─── Exits (must be live whenever eligible) ─────────────────────────────────────────────
    function withdraw(uint256 userSeed, uint256 amount) external {
        address user = _user(userSeed);
        uint256 available = vault.claimableBalance(address(token), user);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        bool eligible = _exitEligible(user);
        vm.prank(user);
        try vault.withdraw(address(token), amount) {
            ghostVaultClaimable[user] -= amount;
            ghostVaultOut += amount;
        } catch {
            if (eligible) livenessViolations++;
        }
    }

    function claimReward(uint256 userSeed, uint256 amount) external {
        address user = _user(userSeed);
        uint256 available = allocator.claimable(address(token), user);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        bool eligible = _exitEligible(user);
        vm.prank(user);
        try allocator.claim(address(token), amount) {
            ghostRewardClaimed[user] += amount;
            ghostRewardClaimedTotal += amount;
        } catch {
            if (eligible) livenessViolations++;
        }
    }

    function ledgerWithdraw(uint256 userSeed, uint256 refSeed, uint256 amount, bool viaRef) external {
        address user = _user(userSeed);
        uint256 aggregate = ledger.availableBalance(user);
        if (aggregate == 0) return;
        bool eligible = _exitEligible(user);
        if (viaRef && userRefs[user].length > 0) {
            bytes32 ref = userRefs[user][refSeed % userRefs[user].length];
            uint256 cap = ledger.availableRefBalance(user, ref);
            if (cap > aggregate) cap = aggregate;
            if (cap == 0) return;
            amount = bound(amount, 1, cap);
            vm.prank(user);
            try ledger.withdrawFromRef(ref, amount) {
                ghostLedgerWithdrawn[user] += amount;
            } catch {
                if (eligible) livenessViolations++;
            }
        } else {
            amount = bound(amount, 1, aggregate);
            vm.prank(user);
            try ledger.withdraw(amount) {
                ghostLedgerWithdrawn[user] += amount;
            } catch {
                if (eligible) livenessViolations++;
            }
        }
    }

    function cancelClaim(uint256 idSeed) external {
        if (claimIds.length == 0) return;
        uint256 id = claimIds[idSeed % claimIds.length];
        address owner = claimOwner[id];
        bool open = claims.getClaim(id).status == IV2Types.ClaimStatus.OPEN;
        bool eligible = open && _exitEligible(owner);
        vm.prank(owner);
        try claims.cancelClaim(id) {
            if (claimRefunded[id]) duplications++;
            claimRefunded[id] = true;
            ghostClaimsEscrow -= MIN_BOUNTY;
        } catch {
            if (eligible) livenessViolations++;
        }
    }

    // ─── Duplication probes (must always fail) ──────────────────────────────────────────────
    function overWithdraw(uint256 userSeed) external {
        address user = _user(userSeed);
        uint256 available = vault.claimableBalance(address(token), user);
        vm.prank(user);
        try vault.withdraw(address(token), available + 1) {
            duplications++;
        } catch {}
    }

    function overClaimReward(uint256 userSeed) external {
        address user = _user(userSeed);
        uint256 available = allocator.claimable(address(token), user);
        vm.prank(user);
        try allocator.claim(address(token), available + 1) {
            duplications++;
        } catch {}
    }

    /// @dev Pulls the full per-ref view when it exceeds the aggregate balance (mixed-path replay).
    function mixedPathLedgerReplay(uint256 userSeed, uint256 refSeed) external {
        address user = _user(userSeed);
        if (userRefs[user].length == 0) return;
        bytes32 ref = userRefs[user][refSeed % userRefs[user].length];
        uint256 perRef = ledger.availableRefBalance(user, ref);
        uint256 aggregate = ledger.availableBalance(user);
        if (perRef <= aggregate || perRef == 0) return;
        vm.prank(user);
        try ledger.withdrawFromRef(ref, perRef) {
            duplications++;
        } catch {}
    }

    function replaySettlement(uint256 userSeed, uint256 claimSeed) external {
        address user = _user(userSeed);
        uint256 claimId = _claimFor(userSeed, claimSeed);
        if (!claimSettled[claimId]) return;
        vm.prank(settlement);
        try vault.finalUnlock(address(token), user, claimId, 0, 1) {
            duplications++;
        } catch {}
    }

    function replayRewards(uint256 idSeed) external {
        if (settlementIds.length == 0) return;
        bytes32 id = settlementIds[idSeed % settlementIds.length];
        vm.prank(settlement);
        try allocator.finalizeRewards(
            id, address(token), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, new IFinalRewardAllocator.Allocation[](0)
        ) {
            duplications++;
        } catch {}
    }

    function replayCredit(uint256 userSeed, uint256 refSeed) external {
        address user = _user(userSeed);
        if (userRefs[user].length == 0) return;
        bytes32 ref = userRefs[user][refSeed % userRefs[user].length];
        try ledger.credit(user, 1, ref) {
            duplications++;
        } catch {}
    }

    // ─── Internals ──────────────────────────────────────────────────────────────────────────
    function _user(uint256 seed) internal view returns (address) {
        return users[seed % 2];
    }

    /// @dev Claim ids are partitioned per user so each (claim, round 0) has exactly one staker.
    function _claimFor(uint256 userSeed, uint256 claimSeed) internal pure returns (uint256) {
        return (userSeed % 2) * 100 + 1 + (claimSeed % 5);
    }

    function _recordSettlement(address user, uint256 claimId, uint256 amount) internal {
        if (claimSettled[claimId]) duplications++;
        claimSettled[claimId] = true;
        ghostVaultClaimable[user] += amount;
    }

    /// @dev An exit is eligible unless the protocol is at SHUTDOWN or the token / recipient rejects.
    function _exitEligible(address user) internal view returns (bool) {
        return !vault.exitsFrozen() && token.failMode() == LivenessToken.FailMode.None && !token.blocked(user);
    }
}

/// @title PauseExitLivenessInvariantTest
/// @notice V2-SC-162 stateful properties: liveness, asset conservation, single-claim,
///         single-settlement, and exact gate classification under arbitrary pause sequences.
contract PauseExitLivenessInvariantTest is StdInvariant, Test {
    PauseExitLivenessHandler internal handler;

    function setUp() public {
        handler = new PauseExitLivenessHandler();
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](22);
        selectors[0] = handler.pauseScope.selector;
        selectors[1] = handler.unpauseScope.selector;
        selectors[2] = handler.escalate.selector;
        selectors[3] = handler.lift.selector;
        selectors[4] = handler.setTokenFaults.selector;
        selectors[5] = handler.deposit.selector;
        selectors[6] = handler.stake.selector;
        selectors[7] = handler.settle.selector;
        selectors[8] = handler.finalizeRewards.selector;
        selectors[9] = handler.credit.selector;
        selectors[10] = handler.createClaim.selector;
        selectors[11] = handler.finalizeClaim.selector;
        selectors[12] = handler.withdraw.selector;
        selectors[13] = handler.claimReward.selector;
        selectors[14] = handler.ledgerWithdraw.selector;
        selectors[15] = handler.cancelClaim.selector;
        selectors[16] = handler.overWithdraw.selector;
        selectors[17] = handler.overClaimReward.selector;
        selectors[18] = handler.mixedPathLedgerReplay.selector;
        selectors[19] = handler.replaySettlement.selector;
        selectors[20] = handler.replayRewards.selector;
        selectors[21] = handler.replayCredit.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Liveness: an eligible exit never fails under any pause / escalation sequence.
    function invariant_eligibleExitsAlwaysLive() public view {
        assertEq(handler.livenessViolations(), 0, "an eligible exit failed while paused");
    }

    /// @notice No repeat, replay, or over-withdrawal ever succeeds.
    function invariant_noDuplication() public view {
        assertEq(handler.duplications(), 0, "tracked value was duplicated");
    }

    /// @notice Exits freeze only at protocol SHUTDOWN.
    function invariant_exitsFreezeOnlyAtShutdown() public view {
        StakeVault vault = handler.vaultAddr();
        bool shutdown = handler.controllerAddr().currentPauseLevel() == 3;
        assertEq(vault.exitsFrozen(), shutdown, "vault exit freeze");
        assertEq(handler.allocatorAddr().exitsFrozen(), shutdown, "allocator exit freeze");
        assertEq(handler.ledgerAddr().exitsFrozen(), shutdown, "ledger exit freeze");
        assertEq(handler.claimsAddr().exitsFrozen(), shutdown, "claims exit freeze");
    }

    /// @notice Every module classifies every scope exactly as the pause authority does.
    function invariant_gatesMatchAuthority() public view {
        bytes32[8] memory scopes = handler.scopes();
        EmergencyGatekeeper gatekeeper = handler.gatekeeperAddr();
        for (uint256 i; i < scopes.length; ++i) {
            bool expected = gatekeeper.paused(scopes[i]);
            assertEq(handler.vaultAddr().isScopePaused(scopes[i]), expected, "vault gate");
            assertEq(handler.claimsAddr().isScopePaused(scopes[i]), expected, "claims gate");
            assertEq(handler.allocatorAddr().isScopePaused(scopes[i]), expected, "allocator gate");
            assertEq(handler.ledgerAddr().isScopePaused(scopes[i]), expected, "ledger gate");
        }
    }

    /// @notice Vault asset conservation: token balance == custody == obligations == ghost net flow.
    function invariant_vaultConservation() public view {
        StakeVault vault = handler.vaultAddr();
        address token = address(handler.tokenAddr());
        (uint256 custody, uint256 obligations) = vault.reconcile(token);
        assertEq(custody, obligations, "obligations == custody");
        assertEq(handler.tokenAddr().balanceOf(address(vault)), custody, "balance == custody");
        assertEq(custody, handler.ghostVaultIn() - handler.ghostVaultOut(), "custody == net tracked flow");
        for (uint256 i; i < 2; ++i) {
            address user = handler.userAt(i);
            assertEq(vault.claimableBalance(token, user), handler.ghostVaultClaimable(user), "per-account claimable");
        }
    }

    /// @notice Single-claim: entitlement + claimed == allocated per account; allocator solvent exactly.
    function invariant_rewardSingleClaim() public view {
        FinalRewardAllocator allocator = handler.allocatorAddr();
        address token = address(handler.tokenAddr());
        for (uint256 i; i < 2; ++i) {
            address user = handler.userAt(i);
            assertEq(
                allocator.claimable(token, user) + handler.ghostRewardClaimed(user),
                handler.ghostRewardAllocated(user),
                "claimable + claimed == allocated"
            );
        }
        assertEq(
            handler.tokenAddr().balanceOf(address(allocator)),
            allocator.funded(token) - handler.ghostRewardClaimedTotal(),
            "allocator balance == funded - claimed"
        );
    }

    /// @notice Pull-ledger conservation and no double withdrawal across both exit paths.
    function invariant_ledgerConservation() public view {
        PullSettlementLedger ledger = handler.ledgerAddr();
        uint256 outstanding;
        for (uint256 i; i < 2; ++i) {
            address user = handler.userAt(i);
            assertEq(ledger.credited(user), handler.ghostCredited(user), "credited tracked");
            assertEq(ledger.withdrawn(user), handler.ghostLedgerWithdrawn(user), "withdrawn tracked");
            assertLe(ledger.withdrawn(user), ledger.credited(user), "withdrawn <= credited");
            outstanding += ledger.credited(user) - ledger.withdrawn(user);
        }
        assertEq(handler.tokenAddr().balanceOf(address(ledger)), outstanding, "ledger balance == outstanding credit");
    }

    /// @notice Claims escrow equals the bounties of all non-cancelled claims.
    function invariant_claimsEscrow() public view {
        Claims claims = handler.claimsAddr();
        assertEq(handler.tokenAddr().balanceOf(address(claims)), handler.ghostClaimsEscrow(), "claims escrow");
    }
}
