// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/v2/StakeVault.sol";
import "../../contracts/v2/FinalRewardAllocator.sol";
import "../../contracts/v2/interfaces/IFinalRewardAllocator.sol";
import "../../contracts/v2/interfaces/IModuleRegistry.sol";
import {IModuleLookupStub} from "./ModuleLookupStub.sol";
import "../../contracts/v2/interfaces/IV2Module.sol";
import "../../contracts/v2/interfaces/IV2Types.sol";
import "../../contracts/mocks/MockModuleRegistry.sol";
import "../../contracts/MockERC20.sol";

interface IV2VaultReentry {
    function deposit(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function lock(address asset, address account, uint256 claimId, uint256 round, IV2Types.LockCategory category, uint256 amount) external;
    function settleConclusive(address asset, address account, uint256 claimId, uint256 round, uint256 principalAmount, uint256 rewardAmount) external;
}

/// @dev Attempts user, lock-mutator, and settlement paths while a vault token operation is active.
contract V2SC098CallbackModule {
    IV2VaultReentry internal immutable vault;
    address internal immutable asset;
    uint256 internal constant CLAIM_ID = 1;

    bool public depositSucceeded;
    bool public withdrawalSucceeded;
    bool public lockSucceeded;
    bool public settlementSucceeded;

    constructor(address vault_, address asset_) {
        vault = IV2VaultReentry(vault_);
        asset = asset_;
    }

    function onTokenCallback() external {
        (depositSucceeded,) = address(vault).call(abi.encodeCall(vault.deposit, (asset, 1)));
        (withdrawalSucceeded,) = address(vault).call(abi.encodeCall(vault.withdraw, (asset, 1)));
        (lockSucceeded,) = address(vault).call(
            abi.encodeCall(vault.lock, (asset, address(this), CLAIM_ID, 0, IV2Types.LockCategory.CHALLENGE_BOND, 1))
        );
        (settlementSucceeded,) = address(vault).call(
            abi.encodeCall(vault.settleConclusive, (asset, address(this), CLAIM_ID, 0, 0, 0))
        );
    }
}

/// @dev ERC-20 with an opt-in callback on both inbound and outbound token transfers.
contract V2SC098CallbackToken is MockERC20 {
    address public callback;
    bool public callbackEnabled;

    constructor() MockERC20("Callback", "CALL") { }

    function setCallback(address callback_) external {
        callback = callback_;
    }

    function enableCallback(bool enabled) external {
        callbackEnabled = enabled;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _callback();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _callback();
        return super.transferFrom(from, to, amount);
    }

    function _callback() private {
        if (!callbackEnabled) return;
        callbackEnabled = false;
        V2SC098CallbackModule(callback).onTokenCallback();
    }
}

/// @dev A view-only registry attempts a state-changing vault callback from its authorization query.
contract V2SC098ReentrantRegistry is IModuleLookupStub {
    bytes32 internal constant SETTLEMENT = keccak256("SETTLEMENT");

    IV2VaultReentry internal vault;
    address internal asset;

    function configure(address vault_, address asset_) external {
        vault = IV2VaultReentry(vault_);
        asset = asset_;
    }

    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IModuleRegistry).interfaceId || interfaceId == type(IV2Module).interfaceId;
    }

    function registerModule(bytes32, address) external pure override { }
    function removeModule(bytes32) external pure override { }

    function module(bytes32 moduleId) external view override returns (address implementation, uint16 major, uint16 minor) {
        if (moduleId == SETTLEMENT) return (address(this), 2, 0);
        return (address(0), 0, 0);
    }

    function isRegistered(bytes32 moduleId) external view override returns (bool) {
        if (moduleId != SETTLEMENT) return false;
        (bool callbackSucceeded,) = address(vault).staticcall(
            abi.encodeCall(vault.withdraw, (asset, 1))
        );
        return !callbackSucceeded;
    }
}

/// @dev A reward recipient retries its own entitlement from the ERC-20 transfer callback.
contract V2SC098RewardClaimant {
    FinalRewardAllocator internal immutable allocator;
    address internal immutable asset;
    bool public reentrantClaimSucceeded;

    constructor(address allocator_, address asset_) {
        allocator = FinalRewardAllocator(allocator_);
        asset = asset_;
    }

    function claim(uint256 amount) external {
        allocator.claim(asset, amount);
    }

    function onTokenCallback() external {
        (reentrantClaimSucceeded,) = address(allocator).call(
            abi.encodeCall(allocator.claim, (asset, 1))
        );
    }
}

contract V2SC098ReentrancyTest is Test {
    MockModuleRegistry internal registry;
    V2SC098CallbackToken internal token;
    StakeVault internal vault;
    V2SC098CallbackModule internal callbackModule;
    address internal user = address(0xA11CE);

    function setUp() public {
        registry = new MockModuleRegistry();
        token = new V2SC098CallbackToken();
        vault = new StakeVault(address(registry), address(token), address(this));
        callbackModule = new V2SC098CallbackModule(address(vault), address(token));
        token.setCallback(address(callbackModule));
        registry.permitModule(vault.MODULE_SETTLEMENT(), address(callbackModule));

        token.mint(user, 20);
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
    }

    function test_tokenCallbackCannotCrossReenterVaultFunctionsDuringDeposit() public {
        token.enableCallback(true);
        vm.prank(user);
        vault.deposit(address(token), 10);

        _assertEveryCallbackRejected();
        assertEq(vault.claimableBalance(address(token), user), 10);
        assertEq(vault.totalCustody(address(token)), 10);
        _assertConserved();
    }

    function test_tokenCallbackCannotWithdrawOrSettleDuringWithdrawal() public {
        vm.prank(user);
        vault.deposit(address(token), 10);

        token.enableCallback(true);
        vm.prank(user);
        vault.withdraw(address(token), 10);

        _assertEveryCallbackRejected();
        assertEq(vault.claimableBalance(address(token), user), 0);
        assertEq(vault.totalCustody(address(token)), 0);
        _assertConserved();
    }

    function test_registryCallbackCannotReenterVaultDuringAuthorization() public {
        V2SC098ReentrantRegistry callbackRegistry = new V2SC098ReentrantRegistry();
        MockERC20 plainToken = new MockERC20("Plain", "PLN");
        StakeVault callbackVault = new StakeVault(address(callbackRegistry), address(plainToken), address(this));
        callbackRegistry.configure(address(callbackVault), address(plainToken));

        plainToken.mint(user, 5);
        vm.prank(user);
        plainToken.approve(address(callbackVault), 5);
        vm.prank(user);
        callbackVault.depositStake(9, 5);

        callbackVault.releaseStake(9, user, 5);

        assertEq(callbackVault.claimableBalance(address(plainToken), user), 5);
        assertEq(uint256(callbackVault.settlementOutcome(9, 0)), uint256(IV2Types.SettlementOutcome.NONE));
        (uint256 custody, uint256 obligations, uint256 actualBalance) = callbackVault.conservation(address(plainToken));
        assertEq(custody, obligations);
        assertEq(custody, actualBalance);
    }

    function test_rewardClaimCallbackCannotClaimTheSameEntitlementTwice() public {
        MockModuleRegistry rewardRegistry = new MockModuleRegistry();
        V2SC098CallbackToken rewardToken = new V2SC098CallbackToken();
        FinalRewardAllocator allocator = new FinalRewardAllocator(address(rewardRegistry), 1);
        rewardRegistry.permitModule(allocator.MODULE_SETTLEMENT(), address(this));
        V2SC098RewardClaimant claimant = new V2SC098RewardClaimant(address(allocator), address(rewardToken));

        bytes32 settlementId = keccak256("callback-reward");
        rewardToken.mint(address(this), 1);
        rewardToken.approve(address(allocator), 1);
        allocator.fund(address(rewardToken), 1, settlementId);

        IFinalRewardAllocator.Allocation[] memory allocations = new IFinalRewardAllocator.Allocation[](1);
        address[] memory recipients = new address[](1);
        recipients[0] = address(claimant);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        allocations[0] = IFinalRewardAllocator.Allocation({
            category: IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
            accounts: recipients,
            effectiveWeights: weights,
            amount: 1,
            remainderRecipient: address(claimant)
        });
        allocator.finalizeRewards(
            settlementId,
            address(rewardToken),
            IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE,
            allocations
        );

        rewardToken.setCallback(address(claimant));
        rewardToken.enableCallback(true);
        claimant.claim(1);

        assertFalse(claimant.reentrantClaimSucceeded(), "reward callback claimed the entitlement twice");
        assertEq(rewardToken.balanceOf(address(claimant)), 1);
        assertEq(allocator.claimable(address(rewardToken), address(claimant)), 0);
    }

    function _assertEveryCallbackRejected() internal view {
        assertFalse(callbackModule.depositSucceeded(), "nested deposit succeeded");
        assertFalse(callbackModule.withdrawalSucceeded(), "nested withdrawal succeeded");
        assertFalse(callbackModule.lockSucceeded(), "nested lock succeeded");
        assertFalse(callbackModule.settlementSucceeded(), "nested settlement succeeded");
    }

    function _assertConserved() internal view {
        (uint256 custody, uint256 obligations, uint256 actualBalance) = vault.conservation(address(token));
        assertEq(custody, obligations);
        assertEq(custody, actualBalance);
    }
}