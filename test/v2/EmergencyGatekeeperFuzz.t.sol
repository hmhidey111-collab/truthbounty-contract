// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { EmergencyGatekeeper } from "../../contracts/v2/EmergencyGatekeeper.sol";
import { EmergencyController } from "../../contracts/governance/EmergencyController.sol";
import { EmergencyDrillConsumer } from "../../contracts/mocks/EmergencyDrillConsumer.sol";
import { V2Errors } from "../../contracts/v2/libraries/V2Errors.sol";

/// @title EmergencyGatekeeperFuzzSuite
/// @notice Fuzz coverage for the V2-SC-067 emergency gatekeeper.
/// @dev Exercises pause state, escalation containment, authorization, and consumer
///      gating across randomized scopes, pause levels, and callers.
contract EmergencyGatekeeperFuzzSuite is Test {
    EmergencyGatekeeper internal gatekeeper;
    EmergencyController internal controller;
    EmergencyDrillConsumer internal consumer;

    address internal admin = makeAddr("admin");
    address internal emergencyCouncil = makeAddr("emergencyCouncil");
    address internal daoGovernance = makeAddr("daoGovernance");
    address internal timelockController = makeAddr("timelockController");
    address internal pauseInitiator = makeAddr("pauseInitiator");
    address internal pauseResolver = makeAddr("pauseResolver");
    address internal user = makeAddr("user");

    bytes32 internal constant SCOPE_A = keccak256("FUZZ_SCOPE_A");
    bytes32 internal constant SCOPE_B = keccak256("FUZZ_SCOPE_B");

    uint256 internal constant REWIRE_DELAY = 1 hours;

    function setUp() public {
        controller = new EmergencyController(emergencyCouncil, daoGovernance, timelockController);
        gatekeeper = new EmergencyGatekeeper(admin, pauseInitiator, pauseResolver, REWIRE_DELAY);
        vm.prank(admin);
        gatekeeper.setEmergencyController(address(controller));
        consumer = new EmergencyDrillConsumer(address(gatekeeper));

        vm.startPrank(admin);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_A, 1);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_B, 3);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Fuzz: scoped pause state is exact for arbitrary scopes
    // -------------------------------------------------------------------------

    /// @dev Only the configured scopes may be locally paused; random scopes never are.
    function testFuzz_scopedPauseExactForArbitraryScopes(bytes32 randomScope, uint8 actorSeed) public {
        vm.assume(randomScope != bytes32(0) && randomScope != SCOPE_A && randomScope != SCOPE_B);
        assertFalse(gatekeeper.locallyPaused(randomScope));

        address actor = actorSeed % 2 == 0 ? pauseInitiator : pauseResolver;
        vm.prank(actor);
        gatekeeper.pause(randomScope);
        assertTrue(gatekeeper.locallyPaused(randomScope));

        vm.prank(pauseResolver);
        gatekeeper.unpause(randomScope);
        assertFalse(gatekeeper.locallyPaused(randomScope));
    }

    /// @dev Pausing SCOPE_A must never change SCOPE_B or an arbitrary third scope.
    function testFuzz_scopeIsolation(bytes32 otherScope, uint256 seed) public {
        vm.assume(otherScope != SCOPE_A);
        vm.assume(otherScope != bytes32(0));

        vm.prank(seed % 2 == 0 ? pauseInitiator : pauseResolver);
        gatekeeper.pause(SCOPE_A);
        assertTrue(gatekeeper.locallyPaused(SCOPE_A));
        assertFalse(gatekeeper.locallyPaused(SCOPE_B));
        assertFalse(gatekeeper.locallyPaused(otherScope));
    }

    // -------------------------------------------------------------------------
    // Fuzz: escalation containment strictly greater-than (never equality)
    // -------------------------------------------------------------------------

    /// @dev SCOPE_A tolerates L1, so it is paused exactly when protocol level > 1.
    function testFuzz_escalationContainmentBoundary(uint8 fuzzLevel) public {
        uint8 level = uint8(bound(fuzzLevel, uint8(controller.LEVEL_NORMAL()), controller.MAX_PAUSE_LEVEL()));

        if (level > controller.LEVEL_NORMAL()) {
            vm.prank(emergencyCouncil);
            controller.activatePause(level, "fuzz", bytes32(0));
        }

        bool expectedPaused = level > gatekeeper.effectiveScopeTolerance(SCOPE_A);
        assertEq(gatekeeper.paused(SCOPE_A), expectedPaused);

        // SCOPE_B tolerates everything except global shutdown, which contains it.
        assertEq(gatekeeper.paused(SCOPE_B), level >= gatekeeper.MAX_PROTOCOL_PAUSE_LEVEL());
    }

    /// @dev After lifting any pause, all scopes return to operational.
    function testFuzz_deEscalationRestoresAllScopes(uint8 fuzzLevel) public {
        uint8 level = uint8(bound(fuzzLevel, uint8(controller.LEVEL_HIGH_RISK()), controller.MAX_PAUSE_LEVEL()));

        vm.prank(emergencyCouncil);
        controller.activatePause(level, "fuzz", bytes32(0));
        // SCOPE_A tolerates L1: contained exactly when level exceeds its tolerance.
        assertEq(gatekeeper.paused(SCOPE_A), level > gatekeeper.maxPauseLevel(SCOPE_A));

        vm.prank(daoGovernance);
        controller.liftPause(bytes32(0));
        assertFalse(gatekeeper.paused(SCOPE_A));
        assertFalse(gatekeeper.paused(SCOPE_B));
    }

    // -------------------------------------------------------------------------
    // Fuzz: authorization holds for arbitrary callers
    // -------------------------------------------------------------------------

    /// @dev Arbitrary unprivileged addresses can never pause or unpause.
    function testFuzz_unprivilegedCallerCannotMutatePauseState(address caller, uint256 seed) public {
        vm.assume(caller != address(0));
        vm.assume(caller != pauseInitiator && caller != pauseResolver && caller != admin);
        vm.assume(caller != emergencyCouncil && caller != daoGovernance && caller != timelockController);
        vm.assume(caller != address(controller) && caller != address(gatekeeper) && caller != address(consumer));
        vm.assume(caller != address(this));

        bytes32 scope = seed % 2 == 0 ? SCOPE_A : SCOPE_B;

        vm.prank(caller);
        vm.expectRevert(EmergencyGatekeeper.NotAuthorized.selector);
        gatekeeper.pause(scope);

        vm.prank(caller);
        vm.expectRevert(EmergencyGatekeeper.NotAuthorized.selector);
        gatekeeper.unpause(scope);

        // Unpausing an unpaused scope reverts for the (authorized) resolver.
        vm.prank(pauseResolver);
        vm.expectRevert(abi.encodeWithSelector(EmergencyGatekeeper.ScopeAlreadyPaused.selector, scope, false));
        gatekeeper.unpause(scope);
    }

    /// @dev The initiator can pause but never unpause, for any scope.
    function testFuzz_initiatorNeverUnpauses(bytes32 scope, uint256 seed) public {
        vm.assume(scope != bytes32(0));

        vm.prank(pauseInitiator);
        gatekeeper.pause(scope);
        assertTrue(gatekeeper.locallyPaused(scope));

        vm.prank(pauseInitiator);
        vm.expectRevert(EmergencyGatekeeper.NotAuthorized.selector);
        gatekeeper.unpause(scope);

        vm.prank(pauseResolver);
        gatekeeper.unpause(scope);
        assertFalse(gatekeeper.locallyPaused(scope));
    }

    // -------------------------------------------------------------------------
    // Fuzz: consumer gating and escrow integrity
    // -------------------------------------------------------------------------

    /// @dev Consumer mutations succeed exactly when the scope is operational, and
    ///      escrow balances change only through successful mutations.
    function testFuzz_consumerGatingTracksPauseState(uint256 amount, uint256 claimId, uint8 fuzzLevel) public {
        amount = bound(amount, 1, 1_000 ether);
        claimId = bound(claimId, 1, type(uint64).max);

        vm.prank(user);
        consumer.lock(SCOPE_B, user, claimId, amount);
        assertEq(consumer.escrow(SCOPE_B, user, claimId), amount);

        uint8 level = uint8(bound(fuzzLevel, uint8(controller.LEVEL_NORMAL()), controller.MAX_PAUSE_LEVEL()));
        // SCOPE_B tolerates L3, so only a shutdown escalation contains it.
        if (level > gatekeeper.maxPauseLevel(SCOPE_B)) {
            vm.prank(emergencyCouncil);
            controller.activatePause(level, "fuzz", bytes32(0));
        }

        bool scopePaused = gatekeeper.paused(SCOPE_B);
        if (scopePaused) {
            vm.prank(user);
            vm.expectRevert(V2Errors.ProtocolPaused.selector);
            consumer.lock(SCOPE_B, user, claimId + 1, amount);
            vm.prank(user);
            vm.expectRevert(V2Errors.ProtocolPaused.selector);
            consumer.release(SCOPE_B, user, claimId, amount);
            assertEq(consumer.escrow(SCOPE_B, user, claimId), amount, "escrow frozen while paused");
        } else {
            vm.prank(user);
            consumer.release(SCOPE_B, user, claimId, amount);
            assertEq(consumer.escrow(SCOPE_B, user, claimId), 0);
        }

        // De-escalation restores operation for every tolerance configuration.
        if (scopePaused) {
            vm.prank(daoGovernance);
            controller.liftPause(bytes32(0));
            assertFalse(gatekeeper.paused(SCOPE_B), "de-escalation must restore the scope");
        }
    }

    // -------------------------------------------------------------------------
    // Fuzz: rewire delay math
    // -------------------------------------------------------------------------

    /// @dev Replacing an existing controller must wait out the full delay, whatever it is.
    function testFuzz_rewireDelayEnforced(uint256 fuzzDelay, uint256 warpSeconds) public {
        uint256 delay =
            bound(fuzzDelay, gatekeeper.MIN_EMERGENCY_REWIRE_DELAY(), gatekeeper.MAX_EMERGENCY_REWIRE_DELAY());
        vm.prank(admin);
        gatekeeper.setEmergencyRewireDelay(delay);

        EmergencyController replacement = new EmergencyController(emergencyCouncil, daoGovernance, timelockController);

        uint256 warp = bound(warpSeconds, 0, delay - 1);
        vm.warp(block.timestamp + warp);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(EmergencyGatekeeper.RewireDelayNotElapsed.selector, block.timestamp + delay - warp)
        );
        gatekeeper.setEmergencyController(address(replacement));

        assertEq(gatekeeper.emergencyController(), address(controller), "dependency unchanged on early rewire");
    }
}
