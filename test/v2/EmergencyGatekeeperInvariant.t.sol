// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";

import { EmergencyGatekeeper } from "../../contracts/v2/EmergencyGatekeeper.sol";
import { EmergencyController } from "../../contracts/governance/EmergencyController.sol";
import { EmergencyDrillConsumer } from "../../contracts/mocks/EmergencyDrillConsumer.sol";
import { V2Errors } from "../../contracts/v2/libraries/V2Errors.sol";

uint256 constant NUM_SCOPES = 3;
uint256 constant NUM_CLAIMS = 10;

/// @title EmergencyGatekeeperHandler
/// @notice Stateful actor for the V2-SC-067 invariant campaign. Applies random
///         authorized pause actions, protocol escalations, remediation, and gated
///         consumer mutations, mirroring accepted effects into ghost state.
contract EmergencyGatekeeperHandler is Test {
    EmergencyGatekeeper public gatekeeper;
    EmergencyController public controller;
    EmergencyDrillConsumer public consumer;

    address public admin = makeAddr("admin");
    address public emergencyCouncil = makeAddr("emergencyCouncil");
    address public daoGovernance = makeAddr("daoGovernance");
    address public timelockController = makeAddr("timelockController");
    address public pauseInitiator = makeAddr("pauseInitiator");
    address public pauseResolver = makeAddr("pauseResolver");
    address public user = makeAddr("user");

    bytes32[NUM_SCOPES] public scopes;

    /// @dev Ghost escrow totals per (scope, claimId) for `user`.
    mapping(bytes32 => mapping(uint256 => uint256)) public ghostEscrow;
    /// @dev Ghost mutation counters per scope.
    mapping(bytes32 => uint256) public ghostMutationCount;

    uint256 public ghostPauseCount;
    uint256 public ghostUnpauseCount;
    uint256 public ghostRejectedMutations;

    uint256 internal constant REWIRE_DELAY = 1 hours;

    constructor() {
        scopes[0] = keccak256("INV_SCOPE_A");
        scopes[1] = keccak256("INV_SCOPE_B");
        scopes[2] = keccak256("INV_SCOPE_C");

        controller = new EmergencyController(emergencyCouncil, daoGovernance, timelockController);
        gatekeeper = new EmergencyGatekeeper(admin, pauseInitiator, pauseResolver, REWIRE_DELAY);
        vm.prank(admin);
        gatekeeper.setEmergencyController(address(controller));
        consumer = new EmergencyDrillConsumer(address(gatekeeper));

        vm.startPrank(admin);
        gatekeeper.setScopeMaxPauseLevel(scopes[0], 1);
        gatekeeper.setScopeMaxPauseLevel(scopes[1], 2);
        gatekeeper.setScopeMaxPauseLevel(scopes[2], 3);
        vm.stopPrank();
    }

    function scopeAt(uint256 index) public view returns (bytes32) {
        return scopes[index % NUM_SCOPES];
    }

    // ─── Handler actions (expected-revert calls are asserted) ─────────

    function pauseScope(uint256 scopeSeed, uint256 actorSeed) external {
        bytes32 scope = scopeAt(scopeSeed);
        address actor = actorSeed % 2 == 0 ? pauseInitiator : pauseResolver;

        vm.prank(actor);
        try gatekeeper.pause(scope) {
            ghostPauseCount += 1;
        } catch { }
    }

    function unpauseScope(uint256 scopeSeed, uint256 actorSeed) external {
        bytes32 scope = scopeAt(scopeSeed);
        address actor = actorSeed % 2 == 0 ? pauseResolver : pauseInitiator;

        vm.prank(actor);
        try gatekeeper.unpause(scope) {
            ghostUnpauseCount += 1;
        } catch { }
    }

    function escalateProtocol(uint256 levelSeed) external {
        uint256 level = bound(levelSeed, uint256(controller.LEVEL_HIGH_RISK()), uint256(controller.MAX_PAUSE_LEVEL()));
        vm.prank(emergencyCouncil);
        try controller.activatePause(uint8(level), "invariant", bytes32(0)) {
        // Escalation is monotonic; lower activations are no-ops that revert.
        }
            catch { }
    }

    function liftProtocol() external {
        vm.prank(daoGovernance);
        try controller.liftPause(bytes32(0)) {
        // Lift requires a pause; at normal level it reverts and is swallowed.
        }
            catch { }
    }

    function consumerLock(uint256 scopeSeed, uint256 amountSeed, uint256 claimSeed) external {
        bytes32 scope = scopeAt(scopeSeed);
        uint256 amount = bound(amountSeed, 1, 1_000 ether);
        uint256 claimId = bound(claimSeed, 1, NUM_CLAIMS);

        vm.prank(user);
        if (gatekeeper.paused(scope)) {
            try consumer.lock(scope, user, claimId, amount) {
                revert("mutation accepted while scope paused");
            } catch {
                ghostRejectedMutations += 1;
            }
        } else {
            try consumer.lock(scope, user, claimId, amount) {
                ghostEscrow[scope][claimId] += amount;
                ghostMutationCount[scope] += 1;
            } catch { }
        }
    }

    function consumerRelease(uint256 scopeSeed, uint256 amountSeed, uint256 claimSeed) external {
        bytes32 scope = scopeAt(scopeSeed);
        uint256 claimId = bound(claimSeed, 1, NUM_CLAIMS);
        uint256 held = ghostEscrow[scope][claimId];

        vm.prank(user);
        if (gatekeeper.paused(scope)) {
            try consumer.release(scope, user, claimId, bound(amountSeed, 1, 1_000 ether)) {
                revert("mutation accepted while scope paused");
            } catch {
                ghostRejectedMutations += 1;
            }
        } else {
            if (held == 0) return;
            uint256 amount = bound(amountSeed, 1, held);
            try consumer.release(scope, user, claimId, amount) {
                ghostEscrow[scope][claimId] = held - amount;
                ghostMutationCount[scope] += 1;
            } catch { }
        }
    }

    function warpForward(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 1 days));
    }
}

/// @title EmergencyGatekeeperInvariantTest
/// @notice Invariants for the V2-SC-067 emergency gatekeeper campaign.
contract EmergencyGatekeeperInvariantTest is StdInvariant, Test {
    EmergencyGatekeeperHandler public handler;

    function setUp() public {
        handler = new EmergencyGatekeeperHandler();
        // The handler fully mediates every mutation; the consumer and controller
        // must not be fuzzed directly or their effects escape ghost bookkeeping.
        targetContract(address(handler));
    }

    /// @dev Paused scopes never accept gated mutations: pause is effective.
    function invariant_pausedScopesRejectMutations() public {
        for (uint256 i = 0; i < NUM_SCOPES; i++) {
            bytes32 scope = handler.scopeAt(i);
            if (handler.gatekeeper().paused(scope)) {
                vm.prank(handler.user());
                try handler.consumer().lock(scope, handler.user(), 42, 1 ether) {
                    revert("mutation accepted while scope paused");
                } catch { }
            }
        }
    }

    /// @dev Consumer escrow matches the handler's ghost bookkeeping exactly: the
    ///      gate never lets state drift — mutations happen fully or not at all.
    function invariant_escrowMatchesGhostBookkeeping() public view {
        for (uint256 i = 0; i < NUM_SCOPES; i++) {
            bytes32 scope = handler.scopeAt(i);
            for (uint256 c = 1; c <= NUM_CLAIMS; c++) {
                assertEq(
                    handler.consumer().escrow(scope, handler.user(), c),
                    handler.ghostEscrow(scope, c),
                    "escrow drifted from ghost bookkeeping"
                );
            }
        }
    }

    /// @dev Consumer mutation counters match ghost counters: no gated mutation
    ///      ever executes partially or under a stale pause classification.
    function invariant_mutationCountMatchesGhost() public view {
        for (uint256 i = 0; i < NUM_SCOPES; i++) {
            bytes32 scope = handler.scopeAt(i);
            assertEq(
                handler.consumer().mutationCount(scope),
                handler.ghostMutationCount(scope),
                "mutation counter drifted from ghost bookkeeping"
            );
        }
    }

    /// @dev Successful unpauses can never exceed successful pauses.
    function invariant_localPauseBookkeepingIsExact() public view {
        assertLe(handler.ghostUnpauseCount(), handler.ghostPauseCount());
    }

    /// @dev Escalation containment: with the protocol at shutdown every configured
    ///      scope is paused, regardless of local bookkeeping.
    function invariant_shutdownContainsAllScopes() public view {
        uint8 level = handler.controller().currentPauseLevel();

        if (level == handler.controller().LEVEL_SHUTDOWN()) {
            for (uint256 i = 0; i < NUM_SCOPES; i++) {
                assertTrue(
                    handler.gatekeeper().paused(handler.scopeAt(i)), "shutdown must contain every configured scope"
                );
            }
        }
    }
}
