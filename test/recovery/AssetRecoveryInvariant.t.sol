// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { AssetRecoveryTest, RecoveryPause, RecoveryRegistry } from "./AssetRecovery.t.sol";
import { StakeVault } from "../../contracts/v2/StakeVault.sol";
import { MockERC20 } from "../../contracts/MockERC20.sol";
import { IV2Types } from "../../contracts/v2/interfaces/IV2Types.sol";

contract RecoveryConservationHandler is Test {
    StakeVault public vault;
    MockERC20 public token;
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public donated;
    uint256 public recovered;
    uint256 public denied;

    constructor() {
        token = new MockERC20("Invariant", "INV");
        RecoveryPause pause = new RecoveryPause();
        RecoveryRegistry registry = new RecoveryRegistry(address(this));
        registry.permitModule(keccak256("EMERGENCY_CONTROLS"), address(pause));
        registry.permitModule(keccak256("SETTLEMENT"), address(this));
        registry.permitModule(keccak256("SLASHING"), address(this));
        vault = new StakeVault(address(registry), address(token), address(this));
        vault.setEmergencyControls(address(pause));
        token.approve(address(vault), type(uint256).max);
    }

    function deposit(uint96 seed) external {
        uint256 amount = bound(seed, 1, 1e20);
        token.mint(address(this), amount);
        vault.deposit(address(token), amount);
        deposited += amount;
    }

    function settle(uint96 seed, bool slash) external {
        uint256 available = vault.claimableBalance(address(token), address(this));
        if (available == 0) return;
        uint256 amount = bound(seed, 1, available);
        vault.lock(address(token), address(this), 1, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount);
        if (slash) {
            vault.allocateLocked(
                address(token),
                address(this),
                1,
                0,
                IV2Types.LockCategory.VERIFIER_PRINCIPAL,
                amount,
                keccak256("invariant allocation")
            );
        } else {
            vault.unlock(address(token), address(this), 1, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount);
        }
    }

    function withdraw(uint96 seed) external {
        uint256 available = vault.claimableBalance(address(token), address(this));
        if (available == 0) return;
        uint256 amount = bound(seed, 1, available);
        vault.withdraw(address(token), amount);
        withdrawn += amount;
    }

    function donate(uint96 seed) external {
        uint256 amount = bound(seed, 1, 1e20);
        token.mint(address(vault), amount);
        donated += amount;
    }

    function recover(bool excessive) external {
        uint256 available = vault.recoverableBalance(address(token));
        uint256 amount = excessive ? available + 1 : available;
        if (amount == 0) return;
        bytes32 salt = bytes32(donated + recovered + denied);
        if (excessive) {
            try vault.queueAssetRecovery(address(token), address(0xBEEF), amount, salt) returns (bytes32) {
                fail("tracked funds were accepted for recovery");
            } catch {
                ++denied;
            }
        } else {
            bytes32 id = vault.queueAssetRecovery(address(token), address(0xBEEF), amount, salt);
            vm.warp(block.timestamp + 2 days);
            vault.executeAssetRecovery(id);
            recovered += amount;
        }
    }
}

contract AssetRecoveryInvariant is StdInvariant, Test {
    RecoveryConservationHandler internal handler;

    function setUp() public {
        handler = new RecoveryConservationHandler();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.settle.selector;
        selectors[2] = handler.withdraw.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.recover.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariant_liabilitiesAndActualSupplyAreConserved() public view {
        StakeVault vault = handler.vault();
        address asset = address(handler.token());
        (uint256 custody, uint256 obligations, uint256 actual) = vault.conservation(asset);
        assertEq(custody, obligations);
        assertEq(custody, handler.deposited() - handler.withdrawn());
        assertEq(actual, custody + handler.donated() - handler.recovered());
        assertEq(vault.recoverableBalance(asset), handler.donated() - handler.recovered());
        assertEq(handler.token().balanceOf(address(0xBEEF)), handler.recovered());
    }

    function test_statefulDepositSettlementRecoveryAndWithdrawal() public {
        handler.deposit(100 ether);
        handler.settle(20 ether, true);
        handler.settle(20 ether, false);
        handler.donate(10 ether);
        handler.recover(true);
        handler.recover(false);
        handler.withdraw(30 ether);
        invariant_liabilitiesAndActualSupplyAreConserved();
        assertEq(handler.denied(), 1);
        assertEq(handler.recovered(), 10 ether);
        assertEq(handler.withdrawn(), 30 ether);
    }
}
