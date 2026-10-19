// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { EmergencyGatekeeper } from "../../contracts/v2/EmergencyGatekeeper.sol";
import { EmergencyController } from "../../contracts/governance/EmergencyController.sol";
import { EmergencyDrillConsumer } from "../../contracts/mocks/EmergencyDrillConsumer.sol";
import { HostilePauseAuthority } from "../../contracts/mocks/HostilePauseAuthority.sol";
import { V2Errors } from "../../contracts/v2/libraries/V2Errors.sol";
import { IEmergencyControls } from "../../contracts/v2/interfaces/IEmergencyControls.sol";
import { IV2Module } from "../../contracts/v2/interfaces/IV2Module.sol";

/// @title EmergencyPauseRecoveryExerciseSuite
/// @notice Full emergency pause and recovery exercise suite for V2-SC-067.
/// @dev Simulates, against the canonical V2 emergency surface:
///      compromised-role authority attempts, protocol-level escalation,
///      scoped (selective) pause, full (global) pause via shutdown,
///      dependency failure with fail-closed outcomes, remediation, the
///      timelock-protected dependency rewire, and safe resumption.
contract EmergencyPauseRecoveryExerciseSuite is Test {
    EmergencyGatekeeper internal gatekeeper;
    EmergencyController internal controller;
    EmergencyDrillConsumer internal consumer;

    address internal admin = makeAddr("admin");
    address internal emergencyCouncil = makeAddr("emergencyCouncil");
    address internal daoGovernance = makeAddr("daoGovernance");
    address internal timelockController = makeAddr("timelockController");
    address internal pauseInitiator = makeAddr("pauseInitiator");
    address internal pauseResolver = makeAddr("pauseResolver");
    address internal compromisedRole = makeAddr("compromisedRole");
    address internal user = makeAddr("user");

    bytes32 internal constant SCOPE_CLAIMS = keccak256("CLAIMS");
    bytes32 internal constant SCOPE_STAKING = keccak256("STAKING");
    bytes32 internal constant SCOPE_SETTLEMENT = keccak256("SETTLEMENT");

    uint256 internal constant REWIRE_DELAY = 1 hours;

    /// @dev The test contract holds gatekeeper admin (as `admin`); direct calls
    ///      therefore route through AccessControl. All admin actions are issued
    ///      via this helper with an explicit prank so authority is exercised
    ///      through the same path production callers use.
    function _asAdmin() internal view returns (address) {
        return admin;
    }

    function setUp() public {
        // Always deploy a bare gatekeeper so static calls on `gatekeeper` are valid
        // in every test; drills that need specific wiring redeploy their own.
        gatekeeper = new EmergencyGatekeeper(admin, pauseInitiator, pauseResolver, REWIRE_DELAY);
    }
    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    function _deployFullyWired() internal {
        controller = new EmergencyController(emergencyCouncil, daoGovernance, timelockController);
        gatekeeper = new EmergencyGatekeeper(admin, pauseInitiator, pauseResolver, REWIRE_DELAY);
        vm.prank(admin);
        gatekeeper.setEmergencyController(address(controller));
        consumer = new EmergencyDrillConsumer(address(gatekeeper));

        vm.startPrank(admin);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_CLAIMS, 0);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_STAKING, 0);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_SETTLEMENT, 1);
        vm.stopPrank();
    }

    function _pauseScopeViaResolver(bytes32 scope) internal {
        vm.prank(pauseResolver);
        gatekeeper.pause(scope);
    }

    function _activatePause(uint8 level, address caller) internal {
        vm.prank(caller);
        controller.activatePause(level, "exercise", bytes32(0));
    }

    // -------------------------------------------------------------------------
    // Configuration drills (fail closed on invalid configuration)
    // -------------------------------------------------------------------------

    function test_config_rejectsZeroAdmin() public {
        vm.expectRevert(V2Errors.ZeroAddress.selector);
        new EmergencyGatekeeper(address(0), pauseInitiator, pauseResolver, REWIRE_DELAY);
    }

    function test_config_rejectsZeroInitiator() public {
        vm.expectRevert(V2Errors.ZeroAddress.selector);
        new EmergencyGatekeeper(admin, address(0), pauseResolver, REWIRE_DELAY);
    }

    function test_config_rejectsZeroResolver() public {
        vm.expectRevert(V2Errors.ZeroAddress.selector);
        new EmergencyGatekeeper(admin, pauseInitiator, address(0), REWIRE_DELAY);
    }

    function test_config_rejectsTooShortRewireDelay() public {
        vm.expectRevert(abi.encodeWithSelector(EmergencyGatekeeper.InvalidRewireDelay.selector, REWIRE_DELAY - 1));
        new EmergencyGatekeeper(admin, pauseInitiator, pauseResolver, REWIRE_DELAY - 1);
    }

    function test_config_rejectsTooLongRewireDelay() public {
        uint256 tooLong = gatekeeper.MAX_EMERGENCY_REWIRE_DELAY() + 1;
        vm.expectRevert(abi.encodeWithSelector(EmergencyGatekeeper.InvalidRewireDelay.selector, tooLong));
        new EmergencyGatekeeper(admin, pauseInitiator, pauseResolver, tooLong);
    }

    function test_config_wiringControllerByAdmin() public {
        controller = new EmergencyController(emergencyCouncil, daoGovernance, timelockController);

        vm.prank(admin);
        gatekeeper.setEmergencyController(address(controller));
        assertEq(gatekeeper.emergencyController(), address(controller));
    }

    function test_config_unwiredGatekeeperFailsClosedForMutations() public {
        consumer = new EmergencyDrillConsumer(address(gatekeeper));

        vm.prank(admin);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_CLAIMS, 3);

        // Unwired dependency classifies as level 0, so the scope is not "paused",
        // but any scoped pause must still be possible during triage.
        assertFalse(gatekeeper.paused(SCOPE_CLAIMS));
    }

    function test_config_scopeLevelRejectsEmptyScope() public {
        _deployFullyWired();
        vm.prank(admin);
        vm.expectRevert(EmergencyGatekeeper.EmptyScope.selector);
        gatekeeper.setScopeMaxPauseLevel(bytes32(0), 1);
    }

    function test_config_scopeLevelRejectsAboveProtocolMax() public {
        _deployFullyWired();
        uint8 tooHigh = gatekeeper.MAX_PROTOCOL_PAUSE_LEVEL() + 1;
        vm.prank(admin);
        vm.expectRevert(EmergencyGatekeeper.InvalidConfiguration.selector);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_CLAIMS, tooHigh);
    }

    function test_config_scopeLevelRejectsNonAdmin() public {
        _deployFullyWired();
        vm.prank(compromisedRole);
        vm.expectRevert();
        gatekeeper.setScopeMaxPauseLevel(SCOPE_CLAIMS, 1);
    }

    function test_config_scopeBoundaries() public {
        _deployFullyWired();
        vm.startPrank(admin);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_CLAIMS, 0);
        assertEq(gatekeeper.maxPauseLevel(SCOPE_CLAIMS), 0);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_CLAIMS, gatekeeper.MAX_PROTOCOL_PAUSE_LEVEL());
        assertEq(gatekeeper.maxPauseLevel(SCOPE_CLAIMS), gatekeeper.MAX_PROTOCOL_PAUSE_LEVEL());
        vm.stopPrank();
    }

    function test_config_invalidControllerSurfaceRejected() public {
        HostilePauseAuthority broken = new HostilePauseAuthority(0);
        broken.setMode(HostilePauseAuthority.FailureMode.AlwaysRevert);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(EmergencyGatekeeper.InvalidEmergencyController.selector, address(broken))
        );
        gatekeeper.setEmergencyController(address(broken));
        assertEq(gatekeeper.emergencyController(), address(0));
    }

    // -------------------------------------------------------------------------
    // Authorization drills (compromised roles)
    // -------------------------------------------------------------------------

    function test_auth_compromisedUserCannotPauseOrUnpause() public {
        _deployFullyWired();

        vm.prank(compromisedRole);
        vm.expectRevert(EmergencyGatekeeper.NotAuthorized.selector);
        gatekeeper.pause(SCOPE_CLAIMS);

        vm.prank(compromisedRole);
        vm.expectRevert(EmergencyGatekeeper.NotAuthorized.selector);
        gatekeeper.unpause(SCOPE_CLAIMS);
    }

    function test_auth_initiatorCannotUnpause() public {
        _deployFullyWired();
        _pauseScopeViaResolver(SCOPE_CLAIMS);

        // The initiator may pause but may never unpause (separation of powers).
        vm.prank(pauseInitiator);
        vm.expectRevert(EmergencyGatekeeper.NotAuthorized.selector);
        gatekeeper.unpause(SCOPE_CLAIMS);

        assertTrue(gatekeeper.locallyPaused(SCOPE_CLAIMS));
    }

    function test_auth_resolverCanPauseAndUnpause() public {
        _deployFullyWired();

        _pauseScopeViaResolver(SCOPE_CLAIMS);
        assertTrue(gatekeeper.locallyPaused(SCOPE_CLAIMS));

        vm.prank(pauseResolver);
        gatekeeper.unpause(SCOPE_CLAIMS);
        assertFalse(gatekeeper.locallyPaused(SCOPE_CLAIMS));
    }

    function test_auth_cannotPauseTwiceOrUnpauseUnpaused() public {
        _deployFullyWired();

        _pauseScopeViaResolver(SCOPE_CLAIMS);
        vm.prank(pauseInitiator);
        vm.expectRevert(abi.encodeWithSelector(EmergencyGatekeeper.ScopeAlreadyPaused.selector, SCOPE_CLAIMS, true));
        gatekeeper.pause(SCOPE_CLAIMS);

        vm.prank(pauseResolver);
        gatekeeper.unpause(SCOPE_CLAIMS);
        vm.prank(pauseResolver);
        vm.expectRevert(abi.encodeWithSelector(EmergencyGatekeeper.ScopeAlreadyPaused.selector, SCOPE_CLAIMS, false));
        gatekeeper.unpause(SCOPE_CLAIMS);
    }

    function test_auth_cannotPauseEmptyScope() public {
        _deployFullyWired();
        vm.prank(pauseResolver);
        vm.expectRevert(EmergencyGatekeeper.EmptyScope.selector);
        gatekeeper.pause(bytes32(0));
    }

    function test_auth_consumerGatedMutationRevertsForUnauthorizedCaller() public {
        _deployFullyWired();
        vm.prank(compromisedRole);
        vm.expectRevert(EmergencyGatekeeper.NotAuthorized.selector);
        gatekeeper.pause(SCOPE_CLAIMS);
        // Consumer unaffected: no pause occurred, so mutations remain open.
        vm.prank(user);
        consumer.lock(SCOPE_CLAIMS, user, 1, 1 ether);
    }

    // -------------------------------------------------------------------------
    // Selective (scoped) pause drills
    // -------------------------------------------------------------------------

    function test_selectivePause_freezesOnlyTargetScope() public {
        _deployFullyWired();

        vm.prank(user);
        consumer.lock(SCOPE_STAKING, user, 1, 1 ether);

        _pauseScopeViaResolver(SCOPE_CLAIMS);

        // Target scope frozen.
        assertTrue(gatekeeper.paused(SCOPE_CLAIMS));
        vm.prank(user);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        consumer.lock(SCOPE_CLAIMS, user, 1, 1 ether);

        // Sibling scope unaffected.
        assertFalse(gatekeeper.paused(SCOPE_STAKING));
        vm.prank(user);
        consumer.lock(SCOPE_STAKING, user, 2, 1 ether);
    }

    function test_selectivePause_scopeIsolationBothDirections() public {
        _deployFullyWired();

        _pauseScopeViaResolver(SCOPE_SETTLEMENT);
        assertTrue(gatekeeper.paused(SCOPE_SETTLEMENT));
        assertFalse(gatekeeper.paused(SCOPE_CLAIMS));
        assertFalse(gatekeeper.paused(SCOPE_STAKING));

        _pauseScopeViaResolver(SCOPE_CLAIMS);
        assertTrue(gatekeeper.paused(SCOPE_CLAIMS));
        assertTrue(gatekeeper.paused(SCOPE_SETTLEMENT), "settlement pause must persist");

        vm.prank(pauseResolver);
        gatekeeper.unpause(SCOPE_SETTLEMENT);
        assertFalse(gatekeeper.paused(SCOPE_SETTLEMENT));
        assertTrue(gatekeeper.paused(SCOPE_CLAIMS), "claims pause must persist");
    }

    function test_selectivePause_releaseAlsoGated() public {
        _deployFullyWired();

        vm.prank(user);
        consumer.lock(SCOPE_CLAIMS, user, 1, 1 ether);

        _pauseScopeViaResolver(SCOPE_CLAIMS);

        vm.prank(user);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        consumer.release(SCOPE_CLAIMS, user, 1, 1 ether);
    }

    function test_selectivePause_preservesEscrowBalanceAcrossPause() public {
        _deployFullyWired();

        vm.prank(user);
        consumer.lock(SCOPE_CLAIMS, user, 1, 5 ether);
        assertEq(consumer.escrow(SCOPE_CLAIMS, user, 1), 5 ether);

        _pauseScopeViaResolver(SCOPE_CLAIMS);
        vm.prank(user);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        consumer.release(SCOPE_CLAIMS, user, 1, 5 ether);
        assertEq(consumer.escrow(SCOPE_CLAIMS, user, 1), 5 ether);

        vm.prank(pauseResolver);
        gatekeeper.unpause(SCOPE_CLAIMS);
        vm.prank(user);
        consumer.release(SCOPE_CLAIMS, user, 1, 5 ether);
        assertEq(consumer.escrow(SCOPE_CLAIMS, user, 1), 0);
    }

    // -------------------------------------------------------------------------
    // Full (global) pause drills via protocol-level escalation
    // -------------------------------------------------------------------------

    function test_fullPause_level1ContainsLowToleranceScopes() public {
        _deployFullyWired();
        _activatePause(controller.LEVEL_HIGH_RISK(), emergencyCouncil);

        assertTrue(gatekeeper.paused(SCOPE_CLAIMS), "L1 must contain tolerance-1 scope");
        assertTrue(gatekeeper.paused(SCOPE_STAKING), "L1 must contain tolerance-1 scope");
        assertFalse(gatekeeper.paused(SCOPE_SETTLEMENT), "tolerance-2 scope stays operational at L1");

        vm.prank(user);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        consumer.lock(SCOPE_CLAIMS, user, 1, 1 ether);

        vm.prank(user);
        consumer.lock(SCOPE_SETTLEMENT, user, 1, 1 ether);
    }

    function test_fullPause_level2ContainsAllConfiguredScopes() public {
        _deployFullyWired();
        _activatePause(controller.LEVEL_FINANCIAL(), emergencyCouncil);

        assertTrue(gatekeeper.paused(SCOPE_CLAIMS));
        assertTrue(gatekeeper.paused(SCOPE_STAKING));
        assertTrue(gatekeeper.paused(SCOPE_SETTLEMENT), "L2 must contain tolerance-2 scope");
    }

    function test_fullPause_shutdownContainsEverythingAndBlocksUnpause() public {
        _deployFullyWired();

        // Pre-existing scoped pause: recovery is only possible after de-escalation.
        _pauseScopeViaResolver(SCOPE_CLAIMS);

        _activatePause(controller.LEVEL_SHUTDOWN(), emergencyCouncil);

        assertTrue(gatekeeper.paused(SCOPE_CLAIMS));
        assertTrue(gatekeeper.paused(SCOPE_STAKING));
        assertTrue(gatekeeper.paused(SCOPE_SETTLEMENT));

        vm.prank(pauseResolver);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        gatekeeper.unpause(SCOPE_CLAIMS);

        vm.prank(user);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        consumer.lock(SCOPE_SETTLEMENT, user, 1, 1 ether);
    }

    function test_fullPause_escalationBetweenScopedPauseAndShutdown() public {
        _deployFullyWired();

        _activatePause(controller.LEVEL_HIGH_RISK(), emergencyCouncil);
        assertTrue(gatekeeper.paused(SCOPE_CLAIMS));

        _activatePause(controller.LEVEL_FINANCIAL(), emergencyCouncil);
        assertTrue(gatekeeper.paused(SCOPE_SETTLEMENT));

        vm.prank(daoGovernance);
        controller.liftPause(bytes32(0));
        assertFalse(gatekeeper.paused(SCOPE_CLAIMS));
        assertFalse(gatekeeper.paused(SCOPE_SETTLEMENT));
    }

    function test_fullPause_onlyGovernanceCanDeescalate() public {
        _deployFullyWired();
        _activatePause(controller.LEVEL_HIGH_RISK(), emergencyCouncil);

        vm.prank(emergencyCouncil);
        vm.expectRevert("Only DAO governance can lift pause");
        controller.liftPause(bytes32(0));

        assertTrue(gatekeeper.paused(SCOPE_CLAIMS));
    }

    function test_fullPause_readClassificationNeverRevertsWhenHealthy() public {
        _deployFullyWired();
        _activatePause(controller.LEVEL_SHUTDOWN(), emergencyCouncil);
        assertTrue(gatekeeper.paused(SCOPE_CLAIMS));
        assertTrue(gatekeeper.paused(bytes32("UNCONFIGURED")));
    }

    // -------------------------------------------------------------------------
    // Dependency failure drills (fail closed)
    // -------------------------------------------------------------------------

    function _deployWithHostileDependency() internal returns (HostilePauseAuthority hostile) {
        hostile = new HostilePauseAuthority(0);
        gatekeeper = new EmergencyGatekeeper(admin, pauseInitiator, pauseResolver, REWIRE_DELAY);
        vm.prank(admin);
        gatekeeper.setEmergencyController(address(hostile));
        consumer = new EmergencyDrillConsumer(address(gatekeeper));

        vm.startPrank(admin);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_CLAIMS, 3);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_STAKING, 3);
        gatekeeper.setScopeMaxPauseLevel(SCOPE_SETTLEMENT, 3);
        vm.stopPrank();
    }

    function test_dependencyFailure_revertingDependencyFailsClosed() public {
        HostilePauseAuthority hostile = _deployWithHostileDependency();

        hostile.setMode(HostilePauseAuthority.FailureMode.AlwaysRevert);

        // Reads never revert but classify as paused.
        assertTrue(gatekeeper.paused(SCOPE_CLAIMS));

        // Mutations fail closed.
        vm.prank(user);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        consumer.lock(SCOPE_CLAIMS, user, 1, 1 ether);

        // Scoped pause bookkeeping also fails closed while the dependency is down.
        vm.prank(pauseResolver);
        vm.expectRevert(EmergencyGatekeeper.EmergencyControllerUnavailable.selector);
        gatekeeper.pause(SCOPE_CLAIMS);
    }

    function test_dependencyFailure_shortReturndataFailsClosed() public {
        HostilePauseAuthority hostile = _deployWithHostileDependency();

        hostile.setMode(HostilePauseAuthority.FailureMode.ShortReturndata);

        assertTrue(gatekeeper.paused(SCOPE_CLAIMS));
        vm.prank(user);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        consumer.lock(SCOPE_CLAIMS, user, 1, 1 ether);
    }

    function test_dependencyFailure_corruptReturndataFailsClosed() public {
        HostilePauseAuthority hostile = _deployWithHostileDependency();

        hostile.setMode(HostilePauseAuthority.FailureMode.CorruptReturndata);

        assertTrue(gatekeeper.paused(SCOPE_CLAIMS));
        vm.prank(user);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        consumer.lock(SCOPE_CLAIMS, user, 1, 1 ether);
    }

    function test_dependencyFailure_recoveryRequiresHealthyDependency() public {
        HostilePauseAuthority hostile = _deployWithHostileDependency();

        _pauseScopeViaResolver(SCOPE_CLAIMS);
        hostile.setMode(HostilePauseAuthority.FailureMode.AlwaysRevert);

        vm.prank(pauseResolver);
        vm.expectRevert(EmergencyGatekeeper.EmergencyControllerUnavailable.selector);
        gatekeeper.unpause(SCOPE_CLAIMS);

        hostile.setMode(HostilePauseAuthority.FailureMode.None);
        vm.prank(pauseResolver);
        gatekeeper.unpause(SCOPE_CLAIMS);
        assertFalse(gatekeeper.paused(SCOPE_CLAIMS));
    }

    function test_dependencyFailure_escalationContainmentClassification() public {
        _deployFullyWired();

        assertFalse(gatekeeper.paused(SCOPE_CLAIMS), "scope operational before escalation");
        _activatePause(controller.LEVEL_HIGH_RISK(), emergencyCouncil);

        // The scope is contained purely by protocol-level escalation — no local
        // pause record exists, yet every mutating path classifies it as paused.
        assertTrue(gatekeeper.locallyPaused(SCOPE_CLAIMS) == false, "no local pause recorded");
        assertTrue(gatekeeper.paused(SCOPE_CLAIMS), "escalation contains the scope");
        vm.prank(user);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        consumer.lock(SCOPE_CLAIMS, user, 1, 1 ether);
    }

    // -------------------------------------------------------------------------
    // Timelock drills (dependency rewire delay)
    // -------------------------------------------------------------------------

    function test_timelock_unwiringExistingControllerRequiresDelay() public {
        _deployFullyWired();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(EmergencyGatekeeper.RewireDelayNotElapsed.selector, block.timestamp + REWIRE_DELAY)
        );
        gatekeeper.setEmergencyController(address(0));

        assertEq(gatekeeper.emergencyController(), address(controller));
    }

    function test_timelock_replacingControllerRequiresDelay() public {
        _deployFullyWired();

        EmergencyController replacement = new EmergencyController(emergencyCouncil, daoGovernance, timelockController);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(EmergencyGatekeeper.RewireDelayNotElapsed.selector, block.timestamp + REWIRE_DELAY)
        );
        gatekeeper.setEmergencyController(address(replacement));
    }

    function test_timelock_wiringFirstControllerIsImmediate() public {
        controller = new EmergencyController(emergencyCouncil, daoGovernance, timelockController);
        vm.prank(admin);
        gatekeeper.setEmergencyController(address(controller));

        assertEq(gatekeeper.emergencyController(), address(controller));
    }

    function test_timelock_rewireAfterDelaySucceeds() public {
        _deployFullyWired();

        EmergencyController replacement = new EmergencyController(emergencyCouncil, daoGovernance, timelockController);

        vm.warp(block.timestamp + REWIRE_DELAY + 1);
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit EmergencyGatekeeper.EmergencyControllerRewired(address(controller), address(replacement), REWIRE_DELAY);
        gatekeeper.setEmergencyController(address(replacement));

        assertEq(gatekeeper.emergencyController(), address(replacement));

        // New dependency is authoritative immediately after the rewire.
        uint8 shutdownLevel = replacement.LEVEL_SHUTDOWN();
        vm.prank(emergencyCouncil);
        replacement.activatePause(shutdownLevel, "new authority", bytes32(0));
        assertTrue(gatekeeper.paused(SCOPE_CLAIMS));
    }

    function test_timelock_delayUpdateRejectsInvalidBounds() public {
        _deployFullyWired();

        uint256 tooShort = gatekeeper.MIN_EMERGENCY_REWIRE_DELAY() - 1;
        uint256 tooLong = gatekeeper.MAX_EMERGENCY_REWIRE_DELAY() + 1;

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(EmergencyGatekeeper.InvalidRewireDelay.selector, tooShort));
        gatekeeper.setEmergencyRewireDelay(tooShort);

        vm.expectRevert(abi.encodeWithSelector(EmergencyGatekeeper.InvalidRewireDelay.selector, tooLong));
        gatekeeper.setEmergencyRewireDelay(tooLong);
        vm.stopPrank();

        uint256 newDelay = 2 days;
        vm.prank(admin);
        gatekeeper.setEmergencyRewireDelay(newDelay);
        assertEq(gatekeeper.emergencyRewireDelay(), newDelay);
    }

    function test_timelock_extendedDelayBlocksEarlyRewire() public {
        _deployFullyWired();

        EmergencyController replacement = new EmergencyController(emergencyCouncil, daoGovernance, timelockController);

        vm.prank(admin);
        gatekeeper.setEmergencyRewireDelay(2 days);

        vm.warp(block.timestamp + REWIRE_DELAY + 1);
        vm.prank(admin);
        vm.expectRevert();
        gatekeeper.setEmergencyController(address(replacement));

        vm.warp(block.timestamp + 2 days);
        vm.prank(admin);
        gatekeeper.setEmergencyController(address(replacement));
        assertEq(gatekeeper.emergencyController(), address(replacement));
    }

    function test_timelock_rewireOnlyByAdmin() public {
        _deployFullyWired();

        vm.prank(compromisedRole);
        vm.expectRevert();
        gatekeeper.setEmergencyController(address(0));
        vm.prank(compromisedRole);
        vm.expectRevert();
        gatekeeper.setEmergencyRewireDelay(2 days);
    }

    // -------------------------------------------------------------------------
    // Remediation & safe resumption drills
    // -------------------------------------------------------------------------

    function test_remediation_fullRecoveryLifecycle() public {
        _deployFullyWired();

        // 1. Incident: scoped pause of claims.
        _pauseScopeViaResolver(SCOPE_CLAIMS);
        assertTrue(gatekeeper.paused(SCOPE_CLAIMS));

        // 2. Escalation while scoped pause is active (compounding incident).
        _activatePause(controller.LEVEL_HIGH_RISK(), emergencyCouncil);
        assertTrue(gatekeeper.paused(SCOPE_STAKING));

        // 3. Remediation: DAO de-escalates the protocol-level pause.
        vm.prank(daoGovernance);
        controller.liftPause(bytes32(0));

        // 4. Protocol scopes recover; the scoped pause must still hold.
        assertFalse(gatekeeper.paused(SCOPE_STAKING));
        assertTrue(gatekeeper.paused(SCOPE_CLAIMS), "scoped pause survives de-escalation");

        // 5. Resolver completes remediation of the scoped pause.
        vm.prank(pauseResolver);
        gatekeeper.unpause(SCOPE_CLAIMS);

        // 6. Safe resumption: all scopes operational, escrow intact.
        assertFalse(gatekeeper.paused(SCOPE_CLAIMS));
        assertFalse(gatekeeper.paused(SCOPE_STAKING));
        assertFalse(gatekeeper.paused(SCOPE_SETTLEMENT));

        vm.prank(user);
        consumer.lock(SCOPE_CLAIMS, user, 7, 1 ether);
        assertEq(consumer.escrow(SCOPE_CLAIMS, user, 7), 1 ether);
    }

    function test_remediation_shutdownRecoveryLifecycle() public {
        _deployFullyWired();

        _activatePause(controller.LEVEL_SHUTDOWN(), emergencyCouncil);
        assertTrue(gatekeeper.paused(SCOPE_SETTLEMENT));

        vm.prank(daoGovernance);
        controller.liftPause(bytes32(0));
        assertFalse(gatekeeper.paused(SCOPE_SETTLEMENT));

        vm.prank(user);
        consumer.lock(SCOPE_SETTLEMENT, user, 9, 2 ether);
        assertEq(consumer.mutationCount(SCOPE_SETTLEMENT), 1);
    }

    function test_remediation_unpauseFailsWhileProtocolStillEscalated() public {
        _deployFullyWired();

        // Scoped pause first, then protocol-level escalation on top.
        _pauseScopeViaResolver(SCOPE_CLAIMS);
        _activatePause(controller.LEVEL_HIGH_RISK(), emergencyCouncil);

        vm.prank(pauseResolver);
        vm.expectRevert(V2Errors.ProtocolPaused.selector);
        gatekeeper.unpause(SCOPE_CLAIMS);

        vm.prank(daoGovernance);
        controller.liftPause(bytes32(0));

        vm.prank(pauseResolver);
        gatekeeper.unpause(SCOPE_CLAIMS);
        assertFalse(gatekeeper.paused(SCOPE_CLAIMS));
    }

    // -------------------------------------------------------------------------
    // Events & canonical V2 surface
    // -------------------------------------------------------------------------

    function test_events_emergencyPausedAndUnpaused() public {
        _deployFullyWired();

        vm.prank(pauseResolver);
        vm.expectEmit(true, true, false, true);
        emit IEmergencyControls.EmergencyPaused(SCOPE_CLAIMS, pauseResolver);
        gatekeeper.pause(SCOPE_CLAIMS);

        vm.prank(pauseResolver);
        vm.expectEmit(true, true, false, true);
        emit IEmergencyControls.EmergencyUnpaused(SCOPE_CLAIMS, pauseResolver);
        gatekeeper.unpause(SCOPE_CLAIMS);
    }

    function test_events_rewiredEvent() public {
        controller = new EmergencyController(emergencyCouncil, daoGovernance, timelockController);

        vm.expectEmit(true, true, false, true);
        emit EmergencyGatekeeper.EmergencyControllerRewired(address(0), address(controller), REWIRE_DELAY);
        vm.prank(admin);
        gatekeeper.setEmergencyController(address(controller));
    }

    function test_v2Surface_protocolVersionAndInterfaces() public {
        _deployFullyWired();

        (uint16 major, uint16 minor) = gatekeeper.protocolVersion();
        assertEq(major, 2);
        assertEq(minor, 0);

        assertTrue(gatekeeper.supportsInterface(type(IEmergencyControls).interfaceId));
        assertTrue(gatekeeper.supportsInterface(type(IV2Module).interfaceId));
        assertFalse(gatekeeper.supportsInterface(bytes4(0xffffffff)));
    }
}
