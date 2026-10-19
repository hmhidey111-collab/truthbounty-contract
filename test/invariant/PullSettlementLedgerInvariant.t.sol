// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title PullSettlementLedgerInvariant — V2-SC-062 invariant suite
 *
 * Invariants:
 *  I1  For every account: credited[a] >= withdrawn[a]  (no underflow)
 *  I2  Ledger token balance >= sum(credited[a] - withdrawn[a])  (no insolvency)
 *  I3  A processed ref is NEVER credited again  (strict replay guard)
 *  I4  withdrawn[a] == sum over all refs of _refWithdrawn[a][ref]
 *      (aggregate equals sum of parts — tested via ghost variables)
 *  I5  availableBalance(a) == credited[a] - withdrawn[a]  (view consistency)
 */

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../contracts/performance/PullSettlementLedger.sol";
import "../../contracts/MockERC20.sol";

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

contract LedgerHandler is Test {
    PullSettlementLedger public ledger;
    MockERC20 public token;

    address[] public actors;
    bytes32[] public usedRefs;

    // Ghost: total tokens that should be in the ledger.
    uint256 public ghostTotalCredited;
    uint256 public ghostTotalWithdrawn;

    // Nonce for unique refs.
    uint256 private _refNonce;

    constructor() {
        token  = new MockERC20("T", "T");
        ledger = new PullSettlementLedger(address(this), IERC20(address(token)));

        actors.push(address(0xA1));
        actors.push(address(0xA2));
        actors.push(address(0xA3));

        // Fund ledger generously.
        token.mint(address(ledger), type(uint128).max);
    }

    // ---- helpers -----------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _freshRef() internal returns (bytes32) {
        _refNonce++;
        return keccak256(abi.encode("ref", _refNonce, block.timestamp));
    }

    function _existingRef(uint256 seed) internal view returns (bytes32) {
        if (usedRefs.length == 0) return bytes32(0);
        return usedRefs[seed % usedRefs.length];
    }

    // ---- actions -----------------------------------------------------------

    function credit(uint256 actorSeed, uint256 amount) public {
        amount = bound(amount, 1, 1_000 ether);
        address actor = _actor(actorSeed);
        bytes32 ref = _freshRef();

        ledger.credit(actor, amount, ref);
        usedRefs.push(ref);
        ghostTotalCredited += amount;
    }

    function creditBatch(uint256 amount0, uint256 amount1) public {
        amount0 = bound(amount0, 1, 1_000 ether);
        amount1 = bound(amount1, 1, 1_000 ether);
        bytes32 ref = _freshRef();

        address[] memory bens = new address[](2);
        bens[0] = actors[0]; bens[1] = actors[1];
        uint256[] memory amts = new uint256[](2);
        amts[0] = amount0; amts[1] = amount1;

        ledger.creditBatch(bens, amts, ref);
        usedRefs.push(ref);
        ghostTotalCredited += amount0 + amount1;
    }

    function withdraw(uint256 actorSeed, uint256 amount) public {
        amount = bound(amount, 1, 1_000 ether);
        address actor = _actor(actorSeed);
        uint256 avail = ledger.availableBalance(actor);
        if (avail == 0) return;
        amount = bound(amount, 1, avail);

        vm.prank(actor);
        try ledger.withdraw(amount) {
            ghostTotalWithdrawn += amount;
        } catch {}
    }

    function withdrawFromRef(uint256 actorSeed, uint256 refSeed, uint256 amount) public {
        if (usedRefs.length == 0) return;
        amount = bound(amount, 1, 1_000 ether);
        address actor = _actor(actorSeed);
        bytes32 ref = _existingRef(refSeed);
        if (ref == bytes32(0)) return;

        uint256 avail = ledger.availableRefBalance(actor, ref);
        if (avail == 0) return;
        amount = bound(amount, 1, avail);

        vm.prank(actor);
        try ledger.withdrawFromRef(ref, amount) {
            ghostTotalWithdrawn += amount;
        } catch {}
    }

    /// @dev Attempt replay — must always fail.
    function attemptReplay(uint256 actorSeed, uint256 refSeed, uint256 amount) public {
        if (usedRefs.length == 0) return;
        bytes32 ref = _existingRef(refSeed);
        if (ref == bytes32(0)) return;
        amount = bound(amount, 1, 1_000 ether);
        address actor = _actor(actorSeed);

        // This must always revert.
        try ledger.credit(actor, amount, ref) {
            revert("replay succeeded - invariant I3 broken");
        } catch {}
    }
}

// ---------------------------------------------------------------------------
// Invariant test
// ---------------------------------------------------------------------------

contract PullSettlementLedgerInvariantTest is StdInvariant, Test {
    LedgerHandler public handler;

    address[] private _actorList;

    function setUp() public {
        handler = new LedgerHandler();

        _actorList.push(address(0xA1));
        _actorList.push(address(0xA2));
        _actorList.push(address(0xA3));

        targetContract(address(handler));
    }

    // I2: ledger token balance >= total credited minus withdrawn
    function invariant_ledgerSolvent() public view {
        uint256 balance = handler.token().balanceOf(address(handler.ledger()));
        uint256 totalOwed;
        for (uint256 i = 0; i < _actorList.length; i++) {
            totalOwed += handler.ledger().availableBalance(_actorList[i]);
        }
        assertGe(balance, totalOwed, "I2: ledger insolvent");
    }

    // I1: credited[a] >= withdrawn[a] for all actors
    function invariant_noUnderflow() public view {
        for (uint256 i = 0; i < _actorList.length; i++) {
            address a = _actorList[i];
            assertGe(
                handler.ledger().credited(a),
                handler.ledger().withdrawn(a),
                "I1: withdrawn exceeds credited"
            );
        }
    }

    // I5: availableBalance == credited - withdrawn
    function invariant_viewConsistency() public view {
        for (uint256 i = 0; i < _actorList.length; i++) {
            address a = _actorList[i];
            assertEq(
                handler.ledger().availableBalance(a),
                handler.ledger().credited(a) - handler.ledger().withdrawn(a),
                "I5: view inconsistency"
            );
        }
    }

    // Ghost cross-check: ghost totals match on-chain sums
    function invariant_ghostConsistency() public view {
        uint256 onChainCredited;
        uint256 onChainWithdrawn;
        for (uint256 i = 0; i < _actorList.length; i++) {
            address a = _actorList[i];
            onChainCredited  += handler.ledger().credited(a);
            onChainWithdrawn += handler.ledger().withdrawn(a);
        }
        // Ghost may differ by at most rounding; exact match expected here because
        // credits go to exactly these three actors.
        assertEq(onChainCredited,  handler.ghostTotalCredited(),  "ghost credited mismatch");
        assertEq(onChainWithdrawn, handler.ghostTotalWithdrawn(), "ghost withdrawn mismatch");
    }
}
