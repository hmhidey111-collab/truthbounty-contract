// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakeVault} from "../../../contracts/v2/StakeVault.sol";
import {Claims} from "../../../contracts/v2/Claims.sol";
import {EvidenceRegistry} from "../../../contracts/v2/EvidenceRegistry.sol";
import {FinalRewardAllocator} from "../../../contracts/v2/FinalRewardAllocator.sol";
import {IFinalRewardAllocator} from "../../../contracts/v2/interfaces/IFinalRewardAllocator.sol";
import {PullSettlementLedger} from "../../../contracts/performance/PullSettlementLedger.sol";
import {EmergencyGatekeeper} from "../../../contracts/v2/EmergencyGatekeeper.sol";
import {EmergencyController} from "../../../contracts/governance/EmergencyController.sol";
import {PauseMatrix} from "../../../contracts/v2/libraries/PauseMatrix.sol";
import {IClaimRegistry} from "../../../contracts/interfaces/IClaimRegistry.sol";
import {MockModuleRegistry} from "../../../contracts/mocks/MockModuleRegistry.sol";
import {MockEvidenceClaimRegistry} from "../../../contracts/mocks/MockEvidenceClaimRegistry.sol";
import {LivenessToken, NonceHarness, PauseMatrixHarness} from "./PauseLivenessHelpers.sol";

/// @title PauseLivenessBase
/// @notice Shared V2-SC-162 deployment: every canonical value-holding module wired to one
///         `EmergencyGatekeeper`, itself wired to the protocol-level `EmergencyController`.
/// @dev Scope tolerances mirror `EmergencyPauseOrdering`: the HIGH_RISK cohort (claims, staking,
///      verification, evidence) is contained from protocol level 1, everything else from level 2,
///      and every scope at level 3 (shutdown).
abstract contract PauseLivenessBase is Test {
    LivenessToken internal token;
    MockModuleRegistry internal registry;
    EmergencyController internal controller;
    EmergencyGatekeeper internal gatekeeper;
    StakeVault internal vault;
    FinalRewardAllocator internal allocator;
    Claims internal claims;
    PullSettlementLedger internal ledger;
    MockEvidenceClaimRegistry internal claimRegistry;
    EvidenceRegistry internal evidence;
    NonceHarness internal nonces;
    PauseMatrixHarness internal matrix;

    address internal admin;
    address internal council = makeAddr("council");
    address internal dao = makeAddr("dao");
    address internal timelock = makeAddr("timelock");
    address internal gkAdmin = makeAddr("gkAdmin");
    address internal initiator = makeAddr("initiator");
    address internal resolver = makeAddr("resolver");
    address internal settlement = makeAddr("settlement");
    address internal feeSink = makeAddr("feeSink");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant REWIRE_DELAY = 1 hours;
    uint256 internal constant MIN_BOUNTY = 1 ether;
    uint256 internal constant CLAIM_FEE = 0.1 ether;
    uint256 internal constant EV_CLAIM = 77;

    bytes32 internal constant SCOPE_CLAIMS = keccak256("CLAIMS");
    bytes32 internal constant SCOPE_EVIDENCE = keccak256("EVIDENCE");
    bytes32 internal constant SCOPE_STAKING = keccak256("STAKING");
    bytes32 internal constant SCOPE_VERIFICATION = keccak256("VERIFICATION");
    bytes32 internal constant SCOPE_SETTLEMENT = keccak256("SETTLEMENT");
    bytes32 internal constant SCOPE_TREASURY = keccak256("TREASURY");
    bytes32 internal constant SCOPE_DISPUTES = keccak256("DISPUTES");
    bytes32 internal constant SCOPE_GOVERNANCE = keccak256("GOVERNANCE");

    function _deployStack() internal {
        admin = address(this);

        token = new LivenessToken();
        registry = new MockModuleRegistry();
        controller = new EmergencyController(council, dao, timelock);
        gatekeeper = new EmergencyGatekeeper(gkAdmin, initiator, resolver, REWIRE_DELAY);

        vm.startPrank(gkAdmin);
        gatekeeper.setEmergencyController(address(controller));
        gatekeeper.setScopeMaxPauseLevel(SCOPE_CLAIMS, 0);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_EVIDENCE, 0);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_STAKING, 0);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_VERIFICATION, 0);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_SETTLEMENT, 1);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_TREASURY, 1);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_DISPUTES, 1);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_GOVERNANCE, 1);
        vm.stopPrank();

        vault = new StakeVault(address(registry), address(token), admin);
        allocator = new FinalRewardAllocator(address(registry), 10);
        registry.permitModule(vault.MODULE_SETTLEMENT(), settlement);
        registry.permitModule(PauseMatrix.MODULE_EMERGENCY_CONTROLS, address(gatekeeper));

        claims = new Claims(admin, address(token), feeSink, MIN_BOUNTY, CLAIM_FEE);
        claims.setPauseAuthority(address(gatekeeper));

        ledger = new PullSettlementLedger(admin, IERC20(address(token)));
        ledger.setPauseAuthority(address(gatekeeper));

        claimRegistry = new MockEvidenceClaimRegistry();
        claimRegistry.setClaim(EV_CLAIM, admin, uint64(block.timestamp + 52 weeks), IClaimRegistry.ClaimStatus.Pending);
        evidence = new EvidenceRegistry(admin, address(claimRegistry));
        evidence.setPauseAuthority(address(gatekeeper));

        nonces = new NonceHarness();
        matrix = new PauseMatrixHarness();

        token.mint(alice, 10_000 ether);
        token.mint(bob, 10_000 ether);
        token.mint(settlement, 10_000 ether);
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        token.approve(address(claims), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        token.approve(address(claims), type(uint256).max);
        vm.stopPrank();
        vm.prank(settlement);
        token.approve(address(allocator), type(uint256).max);
    }

    // ─── Pause controls ─────────────────────────────────────────────────────────────────────

    function _allScopes() internal pure returns (bytes32[8] memory all) {
        all[0] = SCOPE_CLAIMS;
        all[1] = SCOPE_EVIDENCE;
        all[2] = SCOPE_STAKING;
        all[3] = SCOPE_VERIFICATION;
        all[4] = SCOPE_SETTLEMENT;
        all[5] = SCOPE_TREASURY;
        all[6] = SCOPE_DISPUTES;
        all[7] = SCOPE_GOVERNANCE;
    }

    function _pauseScope(bytes32 scope) internal {
        vm.prank(resolver);
        gatekeeper.pause(scope);
    }

    function _unpauseScope(bytes32 scope) internal {
        vm.prank(resolver);
        gatekeeper.unpause(scope);
    }

    function _escalate(uint8 level) internal {
        vm.prank(council);
        controller.activatePause(level, "V2-SC-162 drill", bytes32(0));
    }

    function _liftEscalation() internal {
        vm.prank(dao);
        controller.liftPause(bytes32(0));
    }

    // ─── Value helpers ──────────────────────────────────────────────────────────────────────

    /// @dev Funds and finalizes a two-recipient reward pool (weights 2:1, remainder to `first`).
    function _finalizeRewards(bytes32 settlementId, address first, address second, uint256 amount) internal {
        vm.startPrank(settlement);
        allocator.fund(address(token), amount, settlementId);
        address[] memory accounts = new address[](2);
        accounts[0] = first;
        accounts[1] = second;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 2;
        weights[1] = 1;
        IFinalRewardAllocator.Allocation[] memory allocations = new IFinalRewardAllocator.Allocation[](1);
        allocations[0] = IFinalRewardAllocator.Allocation({
            category: IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
            accounts: accounts,
            effectiveWeights: weights,
            amount: amount,
            remainderRecipient: first
        });
        allocator.finalizeRewards(
            settlementId, address(token), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, allocations
        );
        vm.stopPrank();
    }

    /// @dev Credits the ledger and mints exactly the credited amount into it (ledger is not a puller).
    function _creditLedger(address beneficiary, uint256 amount, bytes32 ref) internal {
        token.mint(address(ledger), amount);
        ledger.credit(beneficiary, amount, ref);
    }
}
