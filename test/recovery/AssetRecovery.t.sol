// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ForcedNativeValueAttacker } from "../../contracts/mocks/ForcedNativeValueAttacker.sol";

import { Test } from "forge-std/Test.sol";
import { StakeVault } from "../../contracts/v2/StakeVault.sol";
import { StakeVault as BondVault } from "../../contracts/StakeVault.sol";
import { Claims } from "../../contracts/v2/Claims.sol";
import { FinalRewardAllocator } from "../../contracts/v2/FinalRewardAllocator.sol";
import { PullSettlementLedger } from "../../contracts/performance/PullSettlementLedger.sol";
import { TreasuryManagement } from "../../contracts/treasury/TreasuryManagement.sol";
import { TreasuryAccounting } from "../../contracts/treasury/TreasuryAccounting.sol";
import { InsuranceFund } from "../../contracts/insurance/InsuranceFund.sol";
import { RewardEngine } from "../../contracts/reward/RewardEngine.sol";
import { RewardDeferralQueue } from "../../contracts/reward/RewardDeferralQueue.sol";
import { IUntrackedAssetRecovery } from "../../contracts/interfaces/IUntrackedAssetRecovery.sol";
import { UntrackedAssetRecovery } from "../../contracts/recovery/UntrackedAssetRecovery.sol";
import { MockModuleRegistry } from "../../contracts/mocks/MockModuleRegistry.sol";
import { MockERC20 } from "../../contracts/MockERC20.sol";
import { IV2Types } from "../../contracts/v2/interfaces/IV2Types.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ITreasuryManagement } from "../../contracts/treasury/ITreasuryManagement.sol";
import { IInsuranceFund } from "../../contracts/insurance/IInsuranceFund.sol";
import { IFinalRewardAllocator } from "../../contracts/v2/interfaces/IFinalRewardAllocator.sol";
import { BoundedSafeERC20 } from "../../contracts/libraries/BoundedSafeERC20.sol";

contract RecoveryPause {
    mapping(bytes32 => bool) public paused;

    function set(bytes32 scope, bool value) external {
        paused[scope] = value;
    }
}

contract RecoveryRegistry is MockModuleRegistry {
    address public governance;

    constructor(address authority) {
        governance = authority;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == keccak256("GOVERNANCE_ROLE") && account == governance;
    }
}

contract RecoveryHostileToken is ERC20 {
    uint256 public mode;
    IUntrackedAssetRecovery public target;
    bytes32 public operation;
    bool public reentrancyBlocked;
    constructor() ERC20("Recovery adversary", "BAD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(uint256 value, IUntrackedAssetRecovery host, bytes32 id) external {
        mode = value;
        target = host;
        operation = id;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == 3) return false;
        if (mode == 4) revert("hostile transfer");
        if (mode == 1) {
            _transfer(msg.sender, to, amount - 1);
            _burn(msg.sender, 1);
        } else {
            _transfer(msg.sender, to, amount);
            if (mode == 2) _burn(msg.sender, 1);
        }
        if (mode == 5) {
            (bool ok, bytes memory data) =
                address(target).call(abi.encodeCall(target.executeAssetRecovery, (operation)));
            reentrancyBlocked = !ok && bytes4(data) == IUntrackedAssetRecovery.RecoveryReentrancy.selector;
        }
        return true;
    }
}

contract RecoveryNoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract RecoveryNativeRecipient {
    IUntrackedAssetRecovery public target;
    bytes32 public operation;
    bool public reject;
    bool public reentrancyBlocked;

    function configure(IUntrackedAssetRecovery host, bytes32 id, bool value) external {
        target = host;
        operation = id;
        reject = value;
    }

    receive() external payable {
        require(!reject, "reject native");
        (bool ok, bytes memory data) = address(target).call(abi.encodeCall(target.executeAssetRecovery, (operation)));
        reentrancyBlocked = !ok && bytes4(data) == IUntrackedAssetRecovery.RecoveryReentrancy.selector;
    }
}

contract AssetRecoveryTest is Test {
    StakeVault internal vault;
    BondVault internal bonds;
    Claims internal claims;
    FinalRewardAllocator internal allocator;
    PullSettlementLedger internal ledger;
    TreasuryManagement internal treasury;
    TreasuryAccounting internal accounting;
    InsuranceFund internal insurance;
    RewardEngine internal engine;
    RewardDeferralQueue internal queue;
    RecoveryPause internal pause;
    RecoveryRegistry internal registry;
    MockERC20 internal token;
    MockERC20 internal foreign;
    address internal recipient = address(0xBEEF);
    address internal user = address(0xCAFE);
    IUntrackedAssetRecovery[] internal holders;

    function setUp() public {
        token = new MockERC20("Protocol", "PRO");
        foreign = new MockERC20("Untracked", "EXT");
        pause = new RecoveryPause();
        registry = new RecoveryRegistry(address(this));
        registry.permitModule(keccak256("EMERGENCY_CONTROLS"), address(pause));
        registry.permitModule(keccak256("SETTLEMENT"), address(this));
        registry.permitModule(keccak256("SLASHING"), address(this));
        vault = new StakeVault(address(registry), address(token), address(this));
        vault.setEmergencyControls(address(pause));
        bonds = new BondVault(address(this), address(token));
        bonds.grantRole(bonds.OPERATOR_ROLE(), address(this));
        bonds.grantRole(bonds.PAUSER_ROLE(), address(this));
        claims = new Claims(address(this), address(token), recipient, 1, 0);
        claims.setPauseAuthority(address(pause));
        allocator = new FinalRewardAllocator(address(registry), 8);
        ledger = new PullSettlementLedger(address(this), IERC20(address(token)));
        ledger.setPauseAuthority(address(pause));
        treasury = new TreasuryManagement(address(token), address(this), address(this), address(this));
        accounting = new TreasuryAccounting(address(token), address(this), address(this));
        insurance = new InsuranceFund(address(token), address(this), address(this));
        engine = new RewardEngine(address(registry), address(this), address(this));
        engine.setRewardToken(address(token));
        queue = new RewardDeferralQueue(address(engine), address(this));
        queue.grantRole(queue.ENQUEUE_ROLE(), address(this));
        holders.push(vault);
        holders.push(bonds);
        holders.push(claims);
        holders.push(allocator);
        holders.push(ledger);
        holders.push(treasury);
        holders.push(accounting);
        holders.push(insurance);
        holders.push(engine);
        holders.push(queue);
        token.mint(address(this), 1_000_000 ether);
        for (uint256 i; i < holders.length; ++i) {
            token.approve(address(holders[i]), type(uint256).max);
        }
    }

    function _queue(IUntrackedAssetRecovery host, address asset, uint256 amount) internal returns (bytes32) {
        return host.queueAssetRecovery(asset, recipient, amount, bytes32(0));
    }

    function _exceeds(IUntrackedAssetRecovery host, address asset, uint256 amount, uint256 available) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IUntrackedAssetRecovery.RecoveryExceedsUntrackedBalance.selector, asset, amount, available
            )
        );
        _queue(host, asset, amount);
    }

    function test_recoverForeignTokensAtEveryV2Holder() public {
        bytes32[] memory ids = new bytes32[](holders.length);
        for (uint256 i; i < holders.length; ++i) {
            foreign.mint(address(holders[i]), 100);
            assertEq(holders[i].recoverableBalance(address(foreign)), 100);
            ids[i] = _queue(holders[i], address(foreign), 40);
        }
        vm.warp(block.timestamp + 2 days);
        for (uint256 i; i < holders.length; ++i) {
            holders[i].executeAssetRecovery(ids[i]);
            assertEq(holders[i].recoverableBalance(address(foreign)), 60);
        }
        assertEq(foreign.balanceOf(recipient), 400);
    }

    function test_timelockAuthorityCancellationAndReplay() public {
        foreign.mint(address(vault), 100);
        vm.prank(user);
        vm.expectRevert();
        _queue(vault, address(foreign), 40);
        bytes32 id = _queue(vault, address(foreign), 40);
        uint256 executableAt = vm.getBlockTimestamp() + 2 days;
        assertEq(executableAt, block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSelector(IUntrackedAssetRecovery.RecoveryTimelockActive.selector, executableAt));
        vault.executeAssetRecovery(id);
        vm.warp(executableAt - 1);
        vm.expectRevert();
        vault.executeAssetRecovery(id);
        pause.set(keccak256("TREASURY"), true);
        vault.cancelAssetRecovery(id);
        vm.warp(executableAt);
        vm.expectRevert();
        vault.executeAssetRecovery(id);
        pause.set(keccak256("TREASURY"), false);
        vm.expectRevert(abi.encodeWithSelector(IUntrackedAssetRecovery.RecoveryAlreadyExists.selector, id));
        _queue(vault, address(foreign), 40);
        bytes32 next = vault.queueAssetRecovery(address(foreign), recipient, 40, bytes32(uint256(1)));
        uint256 nextExecutableAt = vm.getBlockTimestamp() + 2 days;
        vm.warp(nextExecutableAt);
        vm.prank(user);
        vm.expectRevert();
        vault.executeAssetRecovery(next);
        vault.executeAssetRecovery(next);
        vm.expectRevert(abi.encodeWithSelector(IUntrackedAssetRecovery.RecoveryNotQueued.selector, next));
        vault.executeAssetRecovery(next);
    }

    function test_reservesEveryCustodyBucketAndDisabledAssets() public {
        vault.deposit(address(token), 100 ether);
        vault.lock(address(token), address(this), 1, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 20 ether);
        vault.lock(address(token), address(this), 2, 0, IV2Types.LockCategory.CHALLENGE_BOND, 20 ether);
        vault.lock(address(token), address(this), 3, 0, IV2Types.LockCategory.BOUNTY_ESCROW, 20 ether);
        vault.lock(address(token), address(this), 4, 0, IV2Types.LockCategory.SETTLEMENT_ALLOCATION, 20 ether);
        token.mint(address(vault), 10);
        assertEq(vault.recoverableBalance(address(token)), 10);
        _exceeds(vault, address(token), 11, 10);
        vault.setSupportedAsset(address(token), false);
        assertEq(vault.recoverableBalance(address(token)), 10);
        _exceeds(vault, address(token), 11, 10);
        bytes32 id = _queue(vault, address(token), 10);
        vm.warp(block.timestamp + 2 days);
        vault.executeAssetRecovery(id);
        assertEq(token.balanceOf(address(vault)), 100 ether);
        (uint256 custody, uint256 obligations,) = vault.conservation(address(token));
        assertEq(custody, obligations);
    }

    function test_slashedProtocolAllocationAndPendingWithdrawalStayReserved() public {
        vault.depositStake(10, 100 ether);
        vault.slashStake(10, address(this), 25 ether, keccak256("reason"));
        vault.releaseStake(10, address(this), 75 ether);
        assertEq(vault.protocolAllocation(address(token)), 25 ether);
        assertEq(vault.claimableBalance(address(token), address(this)), 75 ether);
        _exceeds(vault, address(token), 1, 0);
        vault.withdraw(address(token), 75 ether);
        _exceeds(vault, address(token), 1, 0);
    }

    function test_bondLiabilitiesSurviveTokenRotationAndRelease() public {
        bonds.lockBond(1, address(token), address(this), 100);
        bonds.setBondToken(address(foreign));
        _exceeds(bonds, address(token), 1, 0);
        token.mint(address(bonds), 10);
        assertEq(bonds.recoverableBalance(address(token)), 10);
        bonds.releaseBond(1, user);
        assertEq(bonds.recoverableBalance(address(token)), 10);
    }

    function test_bountiesRemainReservedAfterTerminalStatus() public {
        uint256 id = claims.createClaim(keccak256("bounty"), 100, "");
        _exceeds(claims, address(token), 1, 0);
        claims.finalizeClaim(id, IV2Types.ClaimStatus.SETTLED);
        _exceeds(claims, address(token), 1, 0);
        uint256 cancelled = claims.createClaim(keccak256("cancel"), 50, "");
        claims.cancelClaim(cancelled);
        token.mint(address(claims), 10);
        assertEq(claims.recoverableBalance(address(token)), 10);
    }

    function test_rewardFundingAllocationsAndClaimsStayReservedWithoutDoubleCounting() public {
        bytes32 settlement = keccak256("reward");
        allocator.fund(address(token), 100, settlement);
        _exceeds(allocator, address(token), 1, 0);
        IFinalRewardAllocator.Allocation[] memory allocations = new IFinalRewardAllocator.Allocation[](1);
        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        allocations[0] = IFinalRewardAllocator.Allocation({
            category: IFinalRewardAllocator.RewardCategory(0),
            accounts: accounts,
            effectiveWeights: weights,
            amount: 60,
            remainderRecipient: address(this)
        });
        allocator.finalizeRewards(settlement, address(token), IFinalRewardAllocator.FinalOutcome(0), allocations);
        token.mint(address(allocator), 10);
        assertEq(allocator.recoverableBalance(address(token)), 10);
        allocator.claim(address(token), 40);
        assertEq(allocator.recoverableBalance(address(token)), 10);
        _exceeds(allocator, address(token), 11, 10);
    }

    function test_withdrawalAggregateBatchAndBothExitPathsStayReserved() public {
        token.mint(address(ledger), 100);
        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = address(this);
        beneficiaries[1] = user;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 40;
        amounts[1] = 60;
        ledger.creditBatch(beneficiaries, amounts, keccak256("batch"));
        _exceeds(ledger, address(token), 1, 0);
        ledger.withdraw(20);
        ledger.withdrawFromRef(keccak256("batch"), 20);
        token.mint(address(ledger), 10);
        assertEq(ledger.recoverableBalance(address(token)), 10);
        _exceeds(ledger, address(token), 11, 10);
    }

    function test_liveReserveRecheckRejectsRequestsThatBecameTracked() public {
        token.mint(address(ledger), 100);
        bytes32 id = _queue(ledger, address(token), 100);
        ledger.credit(user, 100, keccak256("new liability"));
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUntrackedAssetRecovery.RecoveryExceedsUntrackedBalance.selector, address(token), 100, 0
            )
        );
        ledger.executeAssetRecovery(id);
        token.mint(address(ledger), 100);
        ledger.executeAssetRecovery(id);
        assertEq(token.balanceOf(address(ledger)), 100);
        assertEq(ledger.availableBalance(user), 100);
    }

    function test_everyTreasuryPoolAndAccountStaysReserved() public {
        treasury.grantRole(treasury.STAKING_MODULE_ROLE(), address(this));
        token.mint(address(treasury), 100);
        treasury.recordStakeDeposit(address(this), 100);
        _exceeds(treasury, address(token), 1, 0);
        for (uint256 i = 1; i < 7; ++i) {
            treasury.depositToPool(ITreasuryManagement.TreasuryPool(i), 100);
            _exceeds(treasury, address(token), 1, 0);
        }
        for (uint256 i; i < 6; ++i) {
            accounting.depositToAccount(TreasuryAccounting.TreasuryAccount(i), 100);
            _exceeds(accounting, address(token), 1, 0);
        }
        token.mint(address(treasury), 10);
        token.mint(address(accounting), 10);
        assertEq(treasury.recoverableBalance(address(token)), 10);
        assertEq(accounting.recoverableBalance(address(token)), 10);
        _exceeds(treasury, address(token), 11, 10);
        _exceeds(accounting, address(token), 11, 10);
    }

    function test_insuranceAndRewardPoolsIncludingDeferredClaimsAreEntirelyReserved() public {
        insurance.fundReserve(IInsuranceFund.FundingSource(0), 100);
        token.mint(address(insurance), 10);
        _exceeds(insurance, address(token), 1, 0);
        engine.fundRewardPool(100);
        engine.allocateReward(user, 1, keccak256("allocated"), keccak256("calculation"), 40, false);
        queue.enqueue(user, 2, keccak256("deferred"), keccak256("calculation2"), 1000);
        assertEq(engine.totalReserved(), 40);
        assertEq(queue.totalEnqueued(), 1);
        _exceeds(engine, address(token), 1, 0);
        engine.setRewardToken(address(foreign));
        _exceeds(engine, address(token), 1, 0);
    }

    function test_feeOnTransferSenderTaxRevertAndFalseReturnAreAtomic() public {
        RecoveryHostileToken bad = new RecoveryHostileToken();
        bad.mint(address(vault), 100);
        bytes32 id = _queue(vault, address(bad), 40);
        vm.warp(block.timestamp + 2 days);
        for (uint256 mode = 1; mode <= 4; ++mode) {
            bad.configure(mode, vault, id);
            vm.expectRevert();
            vault.executeAssetRecovery(id);
            assertEq(bad.balanceOf(address(vault)), 100);
            assertEq(bad.balanceOf(recipient), 0);
        }
        bad.configure(0, vault, id);
        vault.executeAssetRecovery(id);
        assertEq(bad.balanceOf(recipient), 40);
    }

    function test_reentrantTokenCannotExecuteAnotherRecovery() public {
        RecoveryHostileToken bad = new RecoveryHostileToken();
        bad.mint(address(vault), 100);
        bytes32 id = _queue(vault, address(bad), 40);
        bad.configure(5, vault, id);
        vm.warp(block.timestamp + 2 days);
        vault.executeAssetRecovery(id);
        assertTrue(bad.reentrancyBlocked());
        assertEq(bad.balanceOf(address(vault)), 60);
    }

    function test_noReturnTokenCanBeRecoveredExactly() public {
        RecoveryNoReturnToken noReturn = new RecoveryNoReturnToken();
        noReturn.mint(address(vault), 100);
        bytes32 id = _queue(vault, address(noReturn), 100);
        vm.warp(block.timestamp + 2 days);
        vault.executeAssetRecovery(id);
        assertEq(noReturn.balanceOf(recipient), 100);
    }

    function test_forcedNativeRecoveryRejectsAttachedValueAndReentrancy() public {
        vm.deal(address(this), 100);
        new ForcedNativeValueAttacker().forceNativeValue{ value: 100 }(payable(address(vault)));
        _exceeds(vault, address(0), 101, 100);
        RecoveryNativeRecipient receiver = new RecoveryNativeRecipient();
        bytes32 id = vault.queueAssetRecovery(address(0), address(receiver), 40, bytes32(0));
        receiver.configure(vault, id, true);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(IUntrackedAssetRecovery.RecoveryNativeTransferFailed.selector);
        vault.executeAssetRecovery(id);
        receiver.configure(vault, id, false);
        vm.deal(address(this), 1);
        (bool attached,) = address(vault).call{ value: 1 }(abi.encodeCall(vault.executeAssetRecovery, (id)));
        assertFalse(attached);
        vault.executeAssetRecovery(id);
        assertTrue(receiver.reentrancyBlocked());
        assertEq(address(vault).balance, 60);
        assertEq(address(receiver).balance, 40);
        (uint256 custody, uint256 obligations,) = vault.conservation(address(token));
        assertEq(custody, 0);
        assertEq(obligations, 0);
    }

    function test_pauseBlocksQueueAndExecutionButAllowsCancellation() public {
        foreign.mint(address(vault), 100);
        bytes32 id = _queue(vault, address(foreign), 40);
        vm.warp(block.timestamp + 2 days);
        for (uint256 i; i < 2; ++i) {
            bytes32 scope = i == 0 ? keccak256("TREASURY") : keccak256("GOVERNANCE");
            pause.set(scope, true);
            vm.expectRevert();
            _queue(vault, address(foreign), 20);
            vm.expectRevert();
            vault.executeAssetRecovery(id);
            pause.set(scope, false);
        }
        pause.set(keccak256("TREASURY"), true);
        vault.cancelAssetRecovery(id);
    }

    function test_eventsContainAssetAmountRecipientAuthorityAndResultingBalance() public {
        foreign.mint(address(vault), 100);
        bytes32 expected =
            keccak256(abi.encode(address(vault), block.chainid, address(foreign), recipient, uint256(40), bytes32(0)));
        vm.expectEmit(true, true, true, true, address(vault));
        emit IUntrackedAssetRecovery.AssetRecoveryQueuedV2(
            expected, address(foreign), recipient, 40, address(this), block.timestamp + 2 days, 100
        );
        bytes32 id = _queue(vault, address(foreign), 40);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IUntrackedAssetRecovery.AssetRecoveryExecutedV2(id, address(foreign), recipient, 40, address(this), 60);
        vault.executeAssetRecovery(id);
    }

    function testFuzz_recoveryNeverTouchesCustody(uint128 deposit, uint128 donation, uint128 recovery) public {
        deposit = uint128(bound(deposit, 1, 1e24));
        donation = uint128(bound(donation, 1, 1e24));
        recovery = uint128(bound(recovery, 1, donation));
        vault.deposit(address(token), deposit);
        token.mint(address(vault), donation);
        bytes32 id = _queue(vault, address(token), recovery);
        vm.warp(block.timestamp + 2 days);
        vault.executeAssetRecovery(id);
        assertEq(token.balanceOf(address(vault)), uint256(deposit) + donation - recovery);
        assertEq(vault.totalCustody(address(token)), deposit);
    }

    function test_invalidAssetRecipientAmountAndDeficitFailClosed() public {
        vm.expectRevert();
        _queue(vault, address(0x1234), 1);
        foreign.mint(address(vault), 100);
        vm.expectRevert(IUntrackedAssetRecovery.InvalidRecoveryRequest.selector);
        vault.queueAssetRecovery(address(foreign), address(0), 1, bytes32(0));
        vm.expectRevert(IUntrackedAssetRecovery.InvalidRecoveryRequest.selector);
        _queue(vault, address(foreign), 0);
        ledger.credit(user, 100, keccak256("underfunded"));
        token.mint(address(ledger), 99);
        assertEq(ledger.recoverableBalance(address(token)), 0);
        _exceeds(ledger, address(token), 1, 0);
    }

    function test_unwiredPauseAuthorityCannotRecoverEvenForcedNative() public {
        StakeVault unwired = new StakeVault(address(new RecoveryRegistry(address(this))), address(token), address(this));
        vm.deal(address(unwired), 100);
        assertEq(unwired.recoverableBalance(address(0)), 100);
        vm.expectRevert(IUntrackedAssetRecovery.RecoveryAuthorityUnavailable.selector);
        _queue(unwired, address(0), 1);
    }

    function test_localPauseAndCurrentGovernanceAreRechecked() public {
        foreign.mint(address(engine), 100);
        bytes32 id = _queue(engine, address(foreign), 40);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        engine.emergencyPause();
        vm.expectRevert(IUntrackedAssetRecovery.RecoveryPaused.selector);
        engine.executeAssetRecovery(id);
        engine.cancelAssetRecovery(id);
        engine.emergencyUnpause();
        id = engine.queueAssetRecovery(address(foreign), recipient, 40, bytes32(uint256(2)));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        engine.setGovernanceEnabled(false);
        vm.expectRevert(IUntrackedAssetRecovery.RecoveryAuthorityUnavailable.selector);
        engine.executeAssetRecovery(id);
        engine.setGovernanceEnabled(true);
        engine.revokeRole(engine.GOVERNANCE_ROLE(), address(this));
        vm.expectRevert(IUntrackedAssetRecovery.RecoveryAuthorityUnavailable.selector);
        engine.executeAssetRecovery(id);
        // The caller still has DEFAULT_ADMIN_ROLE and ADMIN_ROLE; neither bypasses governance.
        assertTrue(engine.hasRole(engine.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(engine.hasRole(engine.ADMIN_ROLE(), address(this)));
    }

    function test_recoveryPauseDoesNotFreezeAlreadyClaimableWithdrawals() public {
        vault.depositStake(1, 100 ether);
        vault.releaseStake(1, address(this), 100 ether);
        pause.set(keccak256("TREASURY"), true);
        vault.withdraw(address(token), 100 ether);
        assertEq(vault.totalCustody(address(token)), 0);
    }
}
