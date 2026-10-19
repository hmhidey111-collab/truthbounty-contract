// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../contracts/v2/StakeVault.sol";
import "../../contracts/v2/interfaces/IV2Types.sol";
import "../../contracts/mocks/MockModuleRegistry.sol";
import "../../contracts/mocks/FeeOnTransferERC20.sol";
import "../../contracts/MockERC20.sol";
import {
    FalseReturnERC20,
    MissingReturnERC20,
    ControlledERC20,
    CallbackERC20,
    CallbackAttacker,
    SixDecimalERC20
} from "../v2/AdversarialERC20.t.sol";

/// @dev Drives StakeVault with a mix of standard and adversarial ERC-20s (V2-SC-099).
contract AdversarialERC20Handler is Test {
    StakeVault public vault;
    MockModuleRegistry public registry;
    address public settlement = address(0x5E77);

    address[] public assets;
    address[] public actors;

    FeeOnTransferERC20 public feeToken;
    FalseReturnERC20 public falseToken;
    ControlledERC20 public controlled;
    CallbackERC20 public callbackToken;

    /// @dev asset => actor => expected claimable; asset => expected locked (single claim/round cell per actor).
    mapping(address => mapping(address => uint256)) public ghostClaimable;
    mapping(address => mapping(address => uint256)) public ghostLocked;

    constructor() {
        registry = new MockModuleRegistry();
        MockERC20 primary = new MockERC20("Stake", "STK");
        vault = new StakeVault(address(registry), address(primary), address(this));
        registry.permitModule(vault.MODULE_SETTLEMENT(), settlement);

        feeToken = new FeeOnTransferERC20("Fee", "FEE", 100);
        falseToken = new FalseReturnERC20();
        controlled = new ControlledERC20();
        callbackToken = new CallbackERC20();
        MissingReturnERC20 missing = new MissingReturnERC20();
        SixDecimalERC20 six = new SixDecimalERC20();

        assets.push(address(primary));
        assets.push(address(feeToken));
        assets.push(address(falseToken));
        assets.push(address(missing));
        assets.push(address(controlled));
        assets.push(address(callbackToken));
        assets.push(address(six));

        callbackToken.setHook(address(new CallbackAttacker(vault, address(callbackToken))));

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xC4A5));

        for (uint256 i = 0; i < assets.length; i++) {
            vault.setSupportedAsset(assets[i], true);
            for (uint256 j = 0; j < actors.length; j++) {
                _mint(assets[i], actors[j], type(uint96).max);
                vm.prank(actors[j]);
                (bool ok,) = assets[i].call(
                    abi.encodeWithSignature("approve(address,uint256)", address(vault), type(uint256).max)
                );
                require(ok, "approve");
            }
        }
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _mint(address asset, address to, uint256 amount) internal {
        (bool ok,) = asset.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        require(ok, "mint");
    }

    function deposit(uint256 assetSeed, uint256 actorSeed, uint256 amount) external {
        address asset = assets[assetSeed % assets.length];
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1e30);
        vm.prank(actor);
        try vault.deposit(asset, amount) {
            ghostClaimable[asset][actor] += amount;
        } catch { }
    }

    function withdraw(uint256 assetSeed, uint256 actorSeed, uint256 amount) external {
        address asset = assets[assetSeed % assets.length];
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1e30);
        vm.prank(actor);
        try vault.withdraw(asset, amount) {
            ghostClaimable[asset][actor] -= amount;
        } catch { }
    }

    function lock(uint256 assetSeed, uint256 actorSeed, uint256 amount) external {
        address asset = assets[assetSeed % assets.length];
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1e30);
        vm.prank(settlement);
        try vault.lock(asset, actor, 1, 0, IV2Types.LockCategory.BOUNTY_ESCROW, amount) {
            ghostClaimable[asset][actor] -= amount;
            ghostLocked[asset][actor] += amount;
        } catch { }
    }

    function unlock(uint256 assetSeed, uint256 actorSeed, uint256 amount) external {
        address asset = assets[assetSeed % assets.length];
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1e30);
        vm.prank(settlement);
        try vault.unlock(asset, actor, 1, 0, IV2Types.LockCategory.BOUNTY_ESCROW, amount) {
            ghostLocked[asset][actor] -= amount;
            ghostClaimable[asset][actor] += amount;
        } catch { }
    }

    /// @dev Supply-changing donation straight to the vault; must never be credited.
    function donate(uint256 assetSeed, uint256 amount) external {
        _mint(assets[assetSeed % assets.length], address(vault), bound(amount, 1, 1e30));
    }

    function togglePause(bool paused) external {
        controlled.setPaused(paused);
    }

    function toggleBlacklist(uint256 actorSeed, bool listed) external {
        controlled.setBlacklisted(actors[actorSeed % actors.length], listed);
    }
}

/// @notice Stateful properties for StakeVault under adversarial ERC-20 behavior (V2-SC-099).
contract AdversarialERC20InvariantTest is StdInvariant, Test {
    AdversarialERC20Handler internal handler;
    StakeVault internal vault;

    function setUp() public {
        handler = new AdversarialERC20Handler();
        vault = handler.vault();
        targetContract(address(handler));
    }

    /// @notice Accounting always reconciles and real holdings always cover obligations.
    function invariant_AssetConservation() public view {
        for (uint256 i = 0; i < handler.assetCount(); i++) {
            address asset = handler.assets(i);
            (uint256 custody, uint256 obligations) = vault.reconcile(asset);
            assertEq(custody, obligations);
            assertGe(IERC20(asset).balanceOf(address(vault)), custody);
        }
    }

    /// @notice Per-account balances match the ghost model: no cross-account leakage, donation, or double credit.
    function invariant_PerAccountAccounting() public view {
        for (uint256 i = 0; i < handler.assetCount(); i++) {
            address asset = handler.assets(i);
            uint256 sum;
            for (uint256 j = 0; j < handler.actorCount(); j++) {
                address actor = handler.actors(j);
                uint256 claimable = handler.ghostClaimable(asset, actor);
                uint256 locked = handler.ghostLocked(asset, actor);
                assertEq(vault.claimableBalance(asset, actor), claimable);
                assertEq(vault.lockedPrincipal(asset, actor, 1, 0, IV2Types.LockCategory.BOUNTY_ESCROW), locked);
                sum += claimable + locked;
            }
            assertEq(vault.totalCustody(asset), sum);
        }
    }

    /// @notice False-return and reentrant-callback tokens can never enter custody.
    /// @dev Fee-on-transfer dust whose fee rounds to zero arrives in full and is legitimately credited; the
    ///      conservation invariant proves no fee-bearing transfer is ever over-credited.
    function invariant_UnsafeTokensNeverCredited() public view {
        assertEq(vault.totalCustody(address(handler.falseToken())), 0);
        assertEq(vault.totalCustody(address(handler.callbackToken())), 0);
    }
}
