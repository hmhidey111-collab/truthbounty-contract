// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/v2/StakeVault.sol";
import "../../contracts/v2/libraries/V2Errors.sol";
import "../../contracts/mocks/MockModuleRegistry.sol";
import "../../contracts/mocks/FeeOnTransferERC20.sol";
import "../../contracts/MockERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20 as OZSafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Returns false instead of reverting on every transfer.
contract FalseReturnERC20 is MockERC20 {
    constructor() MockERC20("False", "FLS") { }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev USDT-style token whose transfer functions return no data.
contract MissingReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Pausable/blacklisting token (USDC-style admin controls).
contract ControlledERC20 is MockERC20 {
    bool public paused;
    mapping(address => bool) public blacklisted;

    constructor() MockERC20("Ctl", "CTL") { }

    function setPaused(bool p) external {
        paused = p;
    }

    function setBlacklisted(address a, bool b) external {
        blacklisted[a] = b;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!paused, "paused");
        require(!blacklisted[from] && !blacklisted[to], "blacklisted");
        super._update(from, to, amount);
    }
}

/// @dev Rebasing token: balances scale by a global multiplier (percent).
contract RebasingERC20 is MockERC20 {
    uint256 public scale = 100;

    constructor() MockERC20("Rebase", "RBS") { }

    function rebase(uint256 newScale) external {
        scale = newScale;
    }

    function balanceOf(address a) public view override returns (uint256) {
        return (super.balanceOf(a) * scale) / 100;
    }
}

/// @dev ERC777-style token that calls back into the recipient/hook during transferFrom.
contract CallbackERC20 is MockERC20 {
    address public hook;

    constructor() MockERC20("Hook", "HOK") { }

    function setHook(address h) external {
        hook = h;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (hook != address(0)) CallbackAttacker(hook).onTokenTransfer();
        return super.transferFrom(from, to, amount);
    }
}

contract CallbackAttacker {
    StakeVault internal vault;
    address internal asset;
    bytes public lastError;

    constructor(StakeVault v, address a) {
        vault = v;
        asset = a;
    }

    function onTokenTransfer() external {
        try vault.withdraw(asset, 1) { }
        catch (bytes memory err) {
            lastError = err;
            revert("reentered");
        }
    }
}

/// @dev Token with 6 decimals, exercising non-18-decimal native units.
contract SixDecimalERC20 is MockERC20 {
    constructor() MockERC20("Six", "SIX") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice Validates StakeVault against unsupported and adversarial ERC-20 behavior (V2-SC-099).
/// @dev Asset policy: only standard, non-rebasing, non-fee, non-callback ERC-20s may be enabled. The vault
///      must fail closed (revert) or remain fully collateralized for every token below.
contract AdversarialERC20Test is Test {
    MockModuleRegistry internal registry;
    MockERC20 internal primary;
    StakeVault internal vault;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        registry = new MockModuleRegistry();
        primary = new MockERC20("Stake", "STK");
        vault = new StakeVault(address(registry), address(primary), address(this));
    }

    function _enable(address asset) internal {
        vault.setSupportedAsset(asset, true);
    }

    function _assertSolvent(address asset) internal view {
        (uint256 custody, uint256 obligations) = vault.reconcile(asset);
        assertEq(custody, obligations);
        assertGe(IERC20(asset).balanceOf(address(vault)), custody);
    }

    function test_UnsupportedAssetRejected() public {
        MockERC20 t = new MockERC20("X", "X");
        t.mint(alice, 1 ether);
        vm.startPrank(alice);
        t.approve(address(vault), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnsupportedAsset.selector, address(t)));
        vault.deposit(address(t), 1 ether);
        vm.stopPrank();
    }

    function test_FeeOnTransferRejected() public {
        FeeOnTransferERC20 t = new FeeOnTransferERC20("Fee", "FEE", 100);
        _enable(address(t));
        t.mint(alice, 100 ether);
        vm.startPrank(alice);
        t.approve(address(vault), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TransferAmountMismatch.selector, 100 ether, 99 ether));
        vault.deposit(address(t), 100 ether);
        vm.stopPrank();
        assertEq(vault.totalCustody(address(t)), 0);
    }

    function test_FalseReturnRejected() public {
        FalseReturnERC20 t = new FalseReturnERC20();
        _enable(address(t));
        t.mint(alice, 1 ether);
        vm.startPrank(alice);
        t.approve(address(vault), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OZSafeERC20.SafeERC20FailedOperation.selector, address(t)));
        vault.deposit(address(t), 1 ether);
        vm.stopPrank();
        assertEq(vault.claimableBalance(address(t), alice), 0);
    }

    function test_MissingReturnHandledBySafeERC20() public {
        MissingReturnERC20 t = new MissingReturnERC20();
        _enable(address(t));
        t.mint(alice, 10 ether);
        vm.startPrank(alice);
        t.approve(address(vault), 10 ether);
        vault.deposit(address(t), 10 ether);
        vault.withdraw(address(t), 4 ether);
        vm.stopPrank();
        assertEq(t.balanceOf(alice), 4 ether);
        assertEq(vault.claimableBalance(address(t), alice), 6 ether);
        _assertSolvent(address(t));
    }

    function test_PausedAndBlacklistedFailClosed() public {
        ControlledERC20 t = new ControlledERC20();
        _enable(address(t));
        t.mint(alice, 10 ether);
        vm.startPrank(alice);
        t.approve(address(vault), 10 ether);
        vault.deposit(address(t), 10 ether);
        vm.stopPrank();

        t.setPaused(true);
        vm.prank(alice);
        vm.expectRevert("paused");
        vault.withdraw(address(t), 1 ether);
        t.setPaused(false);

        t.setBlacklisted(alice, true);
        vm.prank(alice);
        vm.expectRevert("blacklisted");
        vault.withdraw(address(t), 1 ether);

        // Blacklisting one account never releases or reassigns its balance.
        assertEq(vault.claimableBalance(address(t), alice), 10 ether);
        _assertSolvent(address(t));
    }

    function test_CallbackReentrancyBlocked() public {
        CallbackERC20 t = new CallbackERC20();
        _enable(address(t));
        CallbackAttacker attacker = new CallbackAttacker(vault, address(t));
        t.setHook(address(attacker));
        t.mint(alice, 1 ether);
        vm.startPrank(alice);
        t.approve(address(vault), 1 ether);
        vm.expectRevert("reentered");
        vault.deposit(address(t), 1 ether);
        vm.stopPrank();
        assertEq(vault.totalCustody(address(t)), 0);
    }

    function test_PositiveRebaseAndDonationNotCredited() public {
        RebasingERC20 t = new RebasingERC20();
        _enable(address(t));
        t.mint(alice, 10 ether);
        vm.startPrank(alice);
        t.approve(address(vault), 10 ether);
        vault.deposit(address(t), 10 ether);
        vm.stopPrank();

        t.rebase(150);
        t.mint(address(vault), 1 ether); // supply change / direct donation
        assertEq(vault.claimableBalance(address(t), alice), 10 ether);
        _assertSolvent(address(t));
    }

    function test_NegativeRebaseBreaksCollateralizationSoRebasingIsUnsupported() public {
        RebasingERC20 t = new RebasingERC20();
        _enable(address(t));
        t.mint(alice, 10 ether);
        vm.startPrank(alice);
        t.approve(address(vault), 10 ether);
        vault.deposit(address(t), 10 ether);
        vm.stopPrank();

        t.rebase(50);
        // Accounting is unchanged, but real holdings fall below obligations: rebasing assets must never be enabled.
        (uint256 custody,) = vault.reconcile(address(t));
        assertEq(vault.claimableBalance(address(t), alice), 10 ether);
        assertLt(t.balanceOf(address(vault)), custody);
    }

    function test_SixDecimalAssetUsesNativeUnits() public {
        SixDecimalERC20 t = new SixDecimalERC20();
        _enable(address(t));
        t.mint(alice, 1_000e6);
        vm.startPrank(alice);
        t.approve(address(vault), type(uint256).max);
        vault.deposit(address(t), 1);
        vault.deposit(address(t), 250e6);
        vault.withdraw(address(t), 1);
        vm.stopPrank();
        assertEq(vault.claimableBalance(address(t), alice), 250e6);
        _assertSolvent(address(t));
    }

    function testFuzz_FeeOnTransferNeverCredited(uint96 amount, uint16 feeBps) public {
        amount = uint96(bound(amount, 1e4, type(uint96).max));
        feeBps = uint16(bound(feeBps, 1, 10_000));
        FeeOnTransferERC20 t = new FeeOnTransferERC20("Fee", "FEE", feeBps);
        _enable(address(t));
        t.mint(bob, amount);
        vm.startPrank(bob);
        t.approve(address(vault), amount);
        vm.expectRevert();
        vault.deposit(address(t), amount);
        vm.stopPrank();
        assertEq(vault.totalCustody(address(t)), 0);
    }
}
