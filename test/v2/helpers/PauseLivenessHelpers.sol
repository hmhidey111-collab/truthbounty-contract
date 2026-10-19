// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakeVault} from "../../../contracts/v2/StakeVault.sol";
import {FinalRewardAllocator} from "../../../contracts/v2/FinalRewardAllocator.sol";
import {PullSettlementLedger} from "../../../contracts/performance/PullSettlementLedger.sol";
import {SignatureNonces} from "../../../contracts/v2/SignatureNonces.sol";
import {PauseMatrix} from "../../../contracts/v2/libraries/PauseMatrix.sol";

/// @notice Receiver hook invoked by `LivenessToken` for opted-in recipients.
interface ILivenessTokenHook {
    function onTokenReceived(address from, uint256 amount) external;
}

/// @title LivenessToken
/// @notice Test-only ERC-20 whose *outgoing* transfers can be made to fail (return false / revert),
///         whose recipients can reject, and which can call back opted-in recipients (reentrancy).
/// @dev `transferFrom` (deposits into modules) is never affected, so fixtures can always be funded.
contract LivenessToken is ERC20 {
    enum FailMode {
        None,
        ReturnFalse,
        Revert
    }

    FailMode public failMode;
    mapping(address => bool) public blocked;
    mapping(address => bool) public hooked;

    constructor() ERC20("Liveness", "LIVE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailMode(FailMode mode) external {
        failMode = mode;
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function setHooked(address account, bool isHooked) external {
        hooked[account] = isHooked;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failMode == FailMode.ReturnFalse) return false;
        if (failMode == FailMode.Revert) revert("LivenessToken: transfer failed");
        if (blocked[to]) revert("LivenessToken: recipient rejected");
        bool ok = super.transfer(to, amount);
        if (hooked[to]) ILivenessTokenHook(to).onTokenReceived(msg.sender, amount);
        return ok;
    }
}

/// @title HostileExitor
/// @notice Test-only account contract that exits V2 modules and, on receipt, tries to re-enter the
///         same exit (double-withdrawal attempt) or rejects the payment outright.
contract HostileExitor is ILivenessTokenHook {
    enum Target {
        None,
        Vault,
        Allocator,
        Ledger
    }

    Target public reenterTarget;
    bool public rejectPayments;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    StakeVault public immutable vault;
    FinalRewardAllocator public immutable allocator;
    PullSettlementLedger public immutable ledger;
    IERC20 public immutable asset;
    uint256 public reentryAmount;

    constructor(StakeVault vault_, FinalRewardAllocator allocator_, PullSettlementLedger ledger_, IERC20 asset_) {
        vault = vault_;
        allocator = allocator_;
        ledger = ledger_;
        asset = asset_;
    }

    function configure(Target target, uint256 amount, bool reject) external {
        reenterTarget = target;
        reentryAmount = amount;
        rejectPayments = reject;
        reentryAttempted = false;
        reentrySucceeded = false;
    }

    function approveVault(uint256 amount) external {
        asset.approve(address(vault), amount);
    }

    function vaultDeposit(uint256 amount) external {
        vault.deposit(address(asset), amount);
    }

    function vaultWithdraw(uint256 amount) external {
        vault.withdraw(address(asset), amount);
    }

    function allocatorClaim(uint256 amount) external {
        allocator.claim(address(asset), amount);
    }

    function ledgerWithdraw(uint256 amount) external {
        ledger.withdraw(amount);
    }

    function onTokenReceived(address, uint256) external {
        if (rejectPayments) revert("HostileExitor: payment rejected");
        if (reenterTarget == Target.None || reentryAttempted) return;
        reentryAttempted = true;
        if (reenterTarget == Target.Vault) {
            try vault.withdraw(address(asset), reentryAmount) {
                reentrySucceeded = true;
            } catch {}
        } else if (reenterTarget == Target.Allocator) {
            try allocator.claim(address(asset), reentryAmount) {
                reentrySucceeded = true;
            } catch {}
        } else if (reenterTarget == Target.Ledger) {
            try ledger.withdraw(reentryAmount) {
                reentrySucceeded = true;
            } catch {}
        }
    }
}

/// @title GasBurnerAuthority
/// @notice Test-only pause authority that answers `paused(bytes32)` cheaply but burns all gas when
///         the exit path probes `emergencyController()`. Proves exit probes are gas-bounded.
contract GasBurnerAuthority {
    bool public pausedAll;

    function setPausedAll(bool value) external {
        pausedAll = value;
    }

    function paused(bytes32) external view returns (bool) {
        return pausedAll;
    }

    function emergencyController() external view returns (address) {
        uint256 spin;
        while (gasleft() > 1_000) {
            unchecked {
                ++spin;
            }
        }
        // Returns (the zero address) only after exhausting whatever gas the caller forwarded.
        return spin == type(uint256).max ? address(this) : address(0);
    }
}

/// @title NonceHarness
/// @notice Deployable wrapper around the abstract `SignatureNonces` module.
contract NonceHarness is SignatureNonces {}

/// @title PauseMatrixHarness
/// @notice External wrapper around `PauseMatrix` so tests can assert its reverts.
contract PauseMatrixHarness {
    function classify(string memory moduleName, string memory signature)
        external
        pure
        returns (PauseMatrix.RiskClass risk, bytes32 gateA, bytes32 gateB)
    {
        return PauseMatrix.classify(moduleName, signature);
    }

    function isScopeGate(bytes32 gate) external pure returns (bool) {
        return PauseMatrix.isScopeGate(gate);
    }

    function version() external pure returns (uint16) {
        return PauseMatrix.PAUSE_MATRIX_VERSION;
    }

    function scopes() external pure returns (bytes32[8] memory all) {
        all[0] = PauseMatrix.SCOPE_CLAIMS;
        all[1] = PauseMatrix.SCOPE_EVIDENCE;
        all[2] = PauseMatrix.SCOPE_STAKING;
        all[3] = PauseMatrix.SCOPE_VERIFICATION;
        all[4] = PauseMatrix.SCOPE_SETTLEMENT;
        all[5] = PauseMatrix.SCOPE_TREASURY;
        all[6] = PauseMatrix.SCOPE_DISPUTES;
        all[7] = PauseMatrix.SCOPE_GOVERNANCE;
    }

    function exitGate() external pure returns (bytes32) {
        return PauseMatrix.EXIT_SHUTDOWN_ONLY;
    }

    function noGate() external pure returns (bytes32) {
        return PauseMatrix.NO_GATE;
    }
}
