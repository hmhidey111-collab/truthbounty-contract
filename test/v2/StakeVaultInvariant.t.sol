// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../contracts/v2/StakeVault.sol";
import "../../contracts/v2/EmergencyControls.sol";
import "../../contracts/v2/interfaces/IV2Types.sol";
import "../../contracts/mocks/MockModuleRegistry.sol";
import "../../contracts/MockERC20.sol";

contract StakeVaultInvariantHandler is Test {
    StakeVault public vault;
    EmergencyControls public emergency;
    MockERC20 public token;
    MockModuleRegistry public registry;

    address public settlement;
    address public userA;
    address public userB;

    uint256 public ghostCustody;
    uint256 public ghostLocked;
    uint256 public ghostClaimable;
    uint256 public ghostProtocol;

    constructor() {
        registry = new MockModuleRegistry();
        token = new MockERC20("Stake", "STK");
        emergency = new EmergencyControls(address(this), address(this), address(this));
        vault = new StakeVault(address(registry), address(token), address(this));
        vault.setEmergencyControls(address(emergency));

        settlement = makeAddr("settlement");
        userA = address(0xA);
        userB = address(0xB);

        registry.permitModule(vault.MODULE_SETTLEMENT(), settlement);

        token.mint(userA, type(uint128).max / 2);
        token.mint(userB, type(uint128).max / 2);

        vm.prank(userA);
        token.approve(address(vault), type(uint256).max);
        vm.prank(userB);
        token.approve(address(vault), type(uint256).max);
    }

    function depositStake(uint256 claimId, uint256 amount, uint256 actorSeed) public {
        amount = bound(amount, 1, 1_000 ether);
        claimId = bound(claimId, 1, 100);
        address user = actorSeed % 2 == 0 ? userA : userB;

        vm.prank(user);
        try vault.depositStake(claimId, amount) {
            ghostCustody += amount;
            ghostLocked += amount;
        } catch {}
    }

    function releaseStake(uint256 claimId, uint256 amount, uint256 actorSeed) public {
        amount = bound(amount, 1, 1_000 ether);
        claimId = bound(claimId, 1, 100);
        address user = actorSeed % 2 == 0 ? userA : userB;

        vm.prank(settlement);
        try vault.releaseStake(claimId, user, amount) {
            ghostLocked -= amount;
            ghostClaimable += amount;
        } catch {}
    }

    function withdraw(uint256 amount, uint256 actorSeed) public {
        amount = bound(amount, 1, 1_000 ether);
        address user = actorSeed % 2 == 0 ? userA : userB;

        vm.prank(user);
        try vault.withdraw(address(token), amount) {
            ghostClaimable -= amount;
            ghostCustody -= amount;
        } catch {}
    }

    function settleConclusive(uint256 claimId, uint256 round, uint256 amount, uint256 actorSeed) public {
        amount = bound(amount, 1, 1_000 ether);
        claimId = bound(claimId, 1, 100);
        round = bound(round, 0, 5);
        address user = actorSeed % 2 == 0 ? userA : userB;

        vm.prank(settlement);
        try vault.settleConclusive(address(token), user, claimId, round, amount, 0) {
            ghostLocked -= amount;
            ghostClaimable += amount;
        } catch {}
    }

    function refundInconclusive(uint256 claimId, uint256 round, uint256 amount, uint256 actorSeed) public {
        amount = bound(amount, 1, 1_000 ether);
        claimId = bound(claimId, 1, 100);
        round = bound(round, 0, 5);
        address user = actorSeed % 2 == 0 ? userA : userB;

        vm.prank(settlement);
        try vault.refundInconclusive(address(token), user, claimId, round, amount) {
            ghostLocked -= amount;
            ghostClaimable += amount;
        } catch {}
    }

    function carryForwardAppeal(uint256 claimId, uint256 fromRound, uint256 toRound, uint256 amount, uint256 actorSeed) public {
        amount = bound(amount, 1, 1_000 ether);
        claimId = bound(claimId, 1, 100);
        fromRound = bound(fromRound, 0, 4);
        toRound = bound(toRound, fromRound + 1, 5);
        address user = actorSeed % 2 == 0 ? userA : userB;

        vm.prank(settlement);
        try vault.carryForwardAppeal(address(token), user, claimId, fromRound, toRound, amount) {} catch {}
    }

    function rolloverRound(uint256 claimId, uint256 fromRound, uint256 toRound, uint256 amount, uint256 actorSeed) public {
        amount = bound(amount, 1, 1_000 ether);
        claimId = bound(claimId, 1, 100);
        fromRound = bound(fromRound, 0, 4);
        toRound = bound(toRound, fromRound + 1, 5);
        address user = actorSeed % 2 == 0 ? userA : userB;

        vm.prank(settlement);
        try vault.rolloverRound(address(token), user, claimId, fromRound, toRound, amount) {} catch {}
    }

    function finalUnlock(uint256 claimId, uint256 round, uint256 amount, uint256 actorSeed) public {
        amount = bound(amount, 1, 1_000 ether);
        claimId = bound(claimId, 1, 100);
        round = bound(round, 0, 5);
        address user = actorSeed % 2 == 0 ? userA : userB;

        vm.prank(settlement);
        try vault.finalUnlock(address(token), user, claimId, round, amount) {
            ghostLocked -= amount;
            ghostClaimable += amount;
        } catch {}
    }
}

contract StakeVaultInvariantTest is StdInvariant, Test {
    StakeVaultInvariantHandler public handler;

    function setUp() public {
        handler = new StakeVaultInvariantHandler();
        // The fuzz target must be the handler, not the vault. Targeting the vault
        // had the fuzzer call it directly from random senders with random
        // arguments, so every authorized path failed `_onlyAuthorizedMutator`,
        // the handler below never ran, and the invariants held vacuously against
        // an empty vault. See test/v2/invariant/StakeVaultSlashingInvariant.t.sol
        // (V2-SC-097) for the slashing-specific successor to this suite.
        targetContract(address(handler));
    }

    function invariant_obligationsNeverExceedCustody() public view {
        (uint256 custody, uint256 obligations) = handler.vault().reconcile(address(handler.token()));
        assertLe(obligations, custody);
    }

    function invariant_custodyMatchesTokenBalance() public view {
        uint256 balance = handler.token().balanceOf(address(handler.vault()));
        assertEq(handler.vault().totalCustody(address(handler.token())), balance);
    }

    function invariant_reconcileEquality() public view {
        address asset = address(handler.token());
        (uint256 custody, uint256 obligations) = handler.vault().reconcile(asset);
        uint256 actualBalance = handler.token().balanceOf(address(handler.vault()));

        assertEq(custody, obligations);
        assertEq(custody, actualBalance);
    }
    /// @notice The handler's ghost accounting matches the vault's own totals.
    /// @dev These four ghosts existed but were never asserted against anything.
    ///      No handler path in this suite slashes, so protocol allocation stays
    ///      zero and obligations reduce to locked plus claimable.
    function invariant_ghostAccountingMatchesVault() public view {
        address asset = address(handler.token());
        (uint256 custody, uint256 obligations,) = handler.vault().conservation(asset);

        assertEq(handler.vault().protocolAllocation(asset), 0, "this suite never slashes");
        assertEq(custody, handler.ghostCustody(), "ghost custody diverged");
        assertEq(obligations, handler.ghostLocked() + handler.ghostClaimable(), "ghost obligations diverged");
    }
}
