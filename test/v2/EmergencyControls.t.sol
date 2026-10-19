// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {FailClosedEmergencyControls as EmergencyControls} from "./helpers/FailClosedEmergencyControls.sol";
import "../../contracts/v2/interfaces/IEmergencyControls.sol";
import "../../contracts/v2/interfaces/IV2Module.sol";
import "../../contracts/v2/libraries/V2Errors.sol";
import "../../contracts/v2/libraries/V2Scopes.sol";

/// @title EmergencyControlsTest
/// @notice V2-SC-042 — fail-closed emergency control plane.
/// @dev Covers the four required test groups:
///      1. unknown operation identifiers revert,
///      2. each protected operation pauses independently,
///      3. recovery prerequisites, timelock, and role authorization,
///      4. auditability of the pause/recovery trail.
contract EmergencyControlsTest is Test {
    EmergencyControls internal controls;

    address internal governance = makeAddr("governance");
    address internal responder = makeAddr("responder");
    address internal recoveryExecutor = makeAddr("recoveryExecutor");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant RECOVERY_DELAY = 2 hours;
    bytes32 internal constant CONDITION_ONE = keccak256("recovery.condition.one");
    bytes32 internal constant CONDITION_TWO = keccak256("recovery.condition.two");
    bytes32 internal constant UNKNOWN_SCOPE = keccak256("not.a.canonical.scope");

    function setUp() public {
        controls = new EmergencyControls(address(this), RECOVERY_DELAY);
        controls.grantRole(controls.EMERGENCY_ROLE(), responder);
        controls.grantRole(controls.RECOVERY_ROLE(), recoveryExecutor);
        controls.grantRole(controls.SCOPE_ADMIN_ROLE(), governance);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _pause(bytes32 scope) internal {
        vm.prank(responder);
        controls.pause(scope);
    }

    function _document(bytes32 scope, bytes32 conditionId) internal {
        vm.prank(governance);
        controls.declareRecoveryCondition(scope, conditionId, "documented precondition");
    }

    function _satisfy(bytes32 scope, bytes32 conditionId) internal {
        vm.prank(recoveryExecutor);
        controls.satisfyRecoveryCondition(scope, conditionId, "recovery evidence");
    }

    function _advancePastTimelock(bytes32 scope) internal {
        vm.warp(controls.recoveryReadyAt(scope));
    }

    /// @dev Documents, satisfies, and reopens a scope through the full happy path.
    function _reopen(bytes32 scope) internal {
        _document(scope, CONDITION_ONE);
        _satisfy(scope, CONDITION_ONE);
        _advancePastTimelock(scope);
        vm.prank(governance);
        controls.unpause(scope);
    }

    // =========================================================================
    // Group 1 — unknown operation identifiers fail closed
    // =========================================================================

    function test_pause_revertsForUnknownScope() public {
        vm.prank(responder);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownOperation.selector, UNKNOWN_SCOPE));
        controls.pause(UNKNOWN_SCOPE);
    }

    function test_pauseWithReason_revertsForUnknownScope() public {
        vm.prank(responder);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownOperation.selector, UNKNOWN_SCOPE));
        controls.pauseWithReason(UNKNOWN_SCOPE, "typo in scope constant");
    }

    function test_unpause_revertsForUnknownScope() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownOperation.selector, UNKNOWN_SCOPE));
        controls.unpause(UNKNOWN_SCOPE);
    }

    function test_paused_revertsForUnknownScope() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownOperation.selector, UNKNOWN_SCOPE));
        controls.paused(UNKNOWN_SCOPE);
    }

    function test_requireOperationAllowed_revertsForUnknownScope() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownOperation.selector, UNKNOWN_SCOPE));
        controls.requireOperationAllowed(UNKNOWN_SCOPE);
    }

    function test_isOperationAllowed_isFalseForUnknownScope() public view {
        assertFalse(controls.isOperationAllowed(UNKNOWN_SCOPE));
        assertFalse(controls.isKnownScope(UNKNOWN_SCOPE));
    }

    function test_recoveryReadyAt_revertsForUnknownScope() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownOperation.selector, UNKNOWN_SCOPE));
        controls.recoveryReadyAt(UNKNOWN_SCOPE);
    }

    function test_scopeUnpausedAt_revertsForUnknownScope() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownOperation.selector, UNKNOWN_SCOPE));
        controls.scopeUnpausedAt(UNKNOWN_SCOPE);
    }

    function test_recoveryStatus_revertsForUnknownScope() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownOperation.selector, UNKNOWN_SCOPE));
        controls.recoveryStatus(UNKNOWN_SCOPE);
    }

    function test_recoveryConditionCount_revertsForUnknownScope() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownOperation.selector, UNKNOWN_SCOPE));
        controls.recoveryConditionCount(UNKNOWN_SCOPE);
    }

    function test_declareRecoveryCondition_revertsForUnknownScope() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownOperation.selector, UNKNOWN_SCOPE));
        controls.declareRecoveryCondition(UNKNOWN_SCOPE, CONDITION_ONE, "documented precondition");
    }

    /// @dev The manifest is the only source of known scopes; nothing outside it is ever operable.
    function test_manifestScopesAreTheCompleteKnownSet() public view {
        bytes32[] memory scopes = V2Scopes.canonicalScopes();
        assertEq(scopes.length, V2Scopes.CANONICAL_SCOPE_COUNT);
        assertEq(controls.scopeCount(), scopes.length);

        for (uint256 i = 0; i < scopes.length; ++i) {
            assertTrue(controls.isKnownScope(scopes[i]), "manifest scope missing from known set");
            assertTrue(controls.isScopeCanonical(scopes[i]), "manifest scope not canonical");
            assertGt(bytes(V2Scopes.description(scopes[i])).length, 0, "scope is undocumented");
            assertEq(controls.scopeAt(i), scopes[i], "known-scope order diverged from manifest");
            for (uint256 j = i + 1; j < scopes.length; ++j) {
                assertTrue(scopes[i] != scopes[j], "duplicate scope in manifest");
            }
        }
    }

    // =========================================================================
    // Group 2 — each protected operation pauses independently
    // =========================================================================

    function test_eachCanonicalScopePausesIndependently() public {
        bytes32[] memory scopes = V2Scopes.canonicalScopes();

        for (uint256 i = 0; i < scopes.length; ++i) {
            bytes32 target = scopes[i];
            // `global` cascades by design and is asserted separately; `governance_recovery`
            // is exempt from the cascade and is asserted separately.
            if (target == V2Scopes.GLOBAL || target == V2Scopes.GOVERNANCE_RECOVERY) continue;

            _pause(target);
            assertTrue(controls.paused(target), "target scope did not pause");
            assertFalse(controls.isOperationAllowed(target), "target scope still operable");

            for (uint256 j = 0; j < scopes.length; ++j) {
                bytes32 other = scopes[j];
                if (other == target) continue;
                assertFalse(controls.paused(other), "pausing one scope paused an unrelated scope");
                assertTrue(controls.isOperationAllowed(other), "unrelated scope became inoperable");
            }

            _reopen(target);
            assertFalse(controls.paused(target), "scope did not reopen");
            assertTrue(controls.isOperationAllowed(target), "scope not operable after reopen");
        }
    }

    function test_globalScopeCascadesToEveryOperationalScope() public {
        _pause(V2Scopes.GLOBAL);
        bytes32[] memory scopes = V2Scopes.canonicalScopes();

        for (uint256 i = 0; i < scopes.length; ++i) {
            bytes32 scope = scopes[i];
            if (scope == V2Scopes.GLOBAL) {
                assertTrue(controls.paused(scope));
                continue;
            }
            if (scope == V2Scopes.GOVERNANCE_RECOVERY) {
                // The kill switch must never suppress the path that lifts it.
                assertFalse(controls.paused(scope));
                assertTrue(controls.isOperationAllowed(scope));
                continue;
            }
            assertTrue(controls.paused(scope), "global pause did not cascade");
            assertFalse(controls.isOperationAllowed(scope), "scope operable under global pause");
        }
    }

    function test_globalPauseIsIndependentOfScopedPause() public {
        _pause(V2Scopes.STAKING);

        assertTrue(controls.paused(V2Scopes.STAKING));
        assertFalse(controls.paused(V2Scopes.GLOBAL));
        assertTrue(controls.isOperationAllowed(V2Scopes.CLAIM_CREATION));
    }

    function test_globalKillSwitchIsReopenable() public {
        _pause(V2Scopes.GLOBAL);
        _reopen(V2Scopes.GLOBAL);

        bytes32[] memory scopes = V2Scopes.canonicalScopes();
        for (uint256 i = 0; i < scopes.length; ++i) {
            assertTrue(controls.isOperationAllowed(scopes[i]), "scope stuck closed after global recovery");
        }
    }

    // =========================================================================
    // Group 3 — recovery prerequisites, timelock, and roles
    // =========================================================================

    function test_unpause_revertsUntilTimelockElapses() public {
        _pause(V2Scopes.WITHDRAWAL);
        _document(V2Scopes.WITHDRAWAL, CONDITION_ONE);
        _satisfy(V2Scopes.WITHDRAWAL, CONDITION_ONE);

        uint256 readyAt = controls.recoveryReadyAt(V2Scopes.WITHDRAWAL);
        assertEq(readyAt, block.timestamp + RECOVERY_DELAY);

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.RecoveryTimelockActive.selector, V2Scopes.WITHDRAWAL, readyAt)
        );
        controls.unpause(V2Scopes.WITHDRAWAL);

        vm.warp(readyAt - 1);
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.RecoveryTimelockActive.selector, V2Scopes.WITHDRAWAL, readyAt)
        );
        controls.unpause(V2Scopes.WITHDRAWAL);

        vm.warp(readyAt);
        vm.prank(governance);
        controls.unpause(V2Scopes.WITHDRAWAL);
        assertFalse(controls.paused(V2Scopes.WITHDRAWAL));
    }

    function test_unpause_revertsWithoutDocumentedRecoveryConditions() public {
        _pause(V2Scopes.WITHDRAWAL);
        _advancePastTimelock(V2Scopes.WITHDRAWAL);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.NoRecoveryConditionsDeclared.selector, V2Scopes.WITHDRAWAL));
        controls.unpause(V2Scopes.WITHDRAWAL);
    }

    function test_unpause_revertsWhileConditionOutstanding() public {
        _pause(V2Scopes.WITHDRAWAL);
        _document(V2Scopes.WITHDRAWAL, CONDITION_ONE);
        _advancePastTimelock(V2Scopes.WITHDRAWAL);

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.RecoveryPrerequisitesUnmet.selector, V2Scopes.WITHDRAWAL, CONDITION_ONE)
        );
        controls.unpause(V2Scopes.WITHDRAWAL);
    }

    function test_unpause_revertsWhenOnlySomeConditionsAreMet() public {
        _pause(V2Scopes.WITHDRAWAL);
        _document(V2Scopes.WITHDRAWAL, CONDITION_ONE);
        _document(V2Scopes.WITHDRAWAL, CONDITION_TWO);
        _satisfy(V2Scopes.WITHDRAWAL, CONDITION_ONE);
        _advancePastTimelock(V2Scopes.WITHDRAWAL);

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.RecoveryPrerequisitesUnmet.selector, V2Scopes.WITHDRAWAL, CONDITION_TWO)
        );
        controls.unpause(V2Scopes.WITHDRAWAL);

        _satisfy(V2Scopes.WITHDRAWAL, CONDITION_TWO);
        vm.prank(governance);
        controls.unpause(V2Scopes.WITHDRAWAL);
        assertFalse(controls.paused(V2Scopes.WITHDRAWAL));
    }

    /// @dev A satisfied condition cannot be replayed to authorise a later reopening.
    function test_staleSatisfactionCannotAuthoriseReopening() public {
        _pause(V2Scopes.WITHDRAWAL);
        _reopen(V2Scopes.WITHDRAWAL);
        assertEq(controls.recoveryConditionCount(V2Scopes.WITHDRAWAL), 0, "conditions survived reopening");

        _pause(V2Scopes.WITHDRAWAL);
        assertEq(controls.recoveryConditionCount(V2Scopes.WITHDRAWAL), 0, "conditions survived a new pause");
        _advancePastTimelock(V2Scopes.WITHDRAWAL);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.NoRecoveryConditionsDeclared.selector, V2Scopes.WITHDRAWAL));
        controls.unpause(V2Scopes.WITHDRAWAL);
    }

    function test_waivedConditionPermitsReopening() public {
        _pause(V2Scopes.WITHDRAWAL);
        _document(V2Scopes.WITHDRAWAL, CONDITION_ONE);

        vm.prank(governance);
        controls.waiveRecoveryCondition(V2Scopes.WITHDRAWAL, CONDITION_ONE, "compensating control verified");

        _advancePastTimelock(V2Scopes.WITHDRAWAL);
        vm.prank(governance);
        controls.unpause(V2Scopes.WITHDRAWAL);
        assertFalse(controls.paused(V2Scopes.WITHDRAWAL));
    }

    function test_waiveRequiresJustification() public {
        _pause(V2Scopes.WITHDRAWAL);
        _document(V2Scopes.WITHDRAWAL, CONDITION_ONE);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidArgument.selector, "justification required"));
        controls.waiveRecoveryCondition(V2Scopes.WITHDRAWAL, CONDITION_ONE, "");
    }

    function test_waiveRequiresGovernanceRole() public {
        _pause(V2Scopes.WITHDRAWAL);
        _document(V2Scopes.WITHDRAWAL, CONDITION_ONE);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedEmergencyCaller.selector, outsider));
        controls.waiveRecoveryCondition(V2Scopes.WITHDRAWAL, CONDITION_ONE, "unauthorised waiver");
    }

    function test_emergencyRoleCannotReopenScope() public {
        _pause(V2Scopes.STAKING);
        _document(V2Scopes.STAKING, CONDITION_ONE);
        _satisfy(V2Scopes.STAKING, CONDITION_ONE);
        _advancePastTimelock(V2Scopes.STAKING);

        vm.prank(responder);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedEmergencyCaller.selector, responder));
        controls.unpause(V2Scopes.STAKING);
        assertTrue(controls.paused(V2Scopes.STAKING), "responder lifted its own pause");
    }

    function test_outsiderCannotPauseScope() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedEmergencyCaller.selector, outsider));
        controls.pause(V2Scopes.STAKING);
    }

    function test_recoveryRoleCannotDeclareConditions() public {
        _pause(V2Scopes.STAKING);
        vm.prank(recoveryExecutor);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedEmergencyCaller.selector, recoveryExecutor));
        controls.declareRecoveryCondition(V2Scopes.STAKING, CONDITION_ONE, "self-declared precondition");
    }

    function test_emergencyRoleCannotSatisfyConditions() public {
        _pause(V2Scopes.STAKING);
        _document(V2Scopes.STAKING, CONDITION_ONE);

        vm.prank(responder);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedEmergencyCaller.selector, responder));
        controls.satisfyRecoveryCondition(V2Scopes.STAKING, CONDITION_ONE, "self-certified evidence");
    }

    function test_conditionsCannotBeDeclaredOutsideAPause() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ScopeNotPaused.selector, V2Scopes.STAKING));
        controls.declareRecoveryCondition(V2Scopes.STAKING, CONDITION_ONE, "documented precondition");
    }

    function test_conditionCannotBeDeclaredTwice() public {
        _pause(V2Scopes.STAKING);
        _document(V2Scopes.STAKING, CONDITION_ONE);

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.RecoveryConditionAlreadyDeclared.selector, V2Scopes.STAKING, CONDITION_ONE)
        );
        controls.declareRecoveryCondition(V2Scopes.STAKING, CONDITION_ONE, "duplicate precondition");
    }

    function test_conditionCannotBeSatisfiedTwice() public {
        _pause(V2Scopes.STAKING);
        _document(V2Scopes.STAKING, CONDITION_ONE);
        _satisfy(V2Scopes.STAKING, CONDITION_ONE);

        vm.prank(recoveryExecutor);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.RecoveryConditionAlreadyResolved.selector, V2Scopes.STAKING, CONDITION_ONE)
        );
        controls.satisfyRecoveryCondition(V2Scopes.STAKING, CONDITION_ONE, "replayed evidence");
    }

    function test_undeclaredConditionCannotBeSatisfied() public {
        _pause(V2Scopes.STAKING);
        vm.prank(recoveryExecutor);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.RecoveryConditionNotFound.selector, V2Scopes.STAKING, CONDITION_ONE)
        );
        controls.satisfyRecoveryCondition(V2Scopes.STAKING, CONDITION_ONE, "evidence for nothing");
    }

    function test_pauseRevertsWhenAlreadyPaused() public {
        _pause(V2Scopes.STAKING);
        vm.prank(responder);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ScopeAlreadyPaused.selector, V2Scopes.STAKING));
        controls.pause(V2Scopes.STAKING);
    }

    function test_unpauseRevertsWhenScopeNotPaused() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ScopeNotPaused.selector, V2Scopes.STAKING));
        controls.unpause(V2Scopes.STAKING);
    }

    function test_recoveryStatusReportsOutstandingConditions() public {
        _pause(V2Scopes.WITHDRAWAL);
        _document(V2Scopes.WITHDRAWAL, CONDITION_ONE);
        _document(V2Scopes.WITHDRAWAL, CONDITION_TWO);
        _satisfy(V2Scopes.WITHDRAWAL, CONDITION_ONE);

        (bool isPaused, uint256 readyAt, uint256 declared, uint256 outstanding) =
            controls.recoveryStatus(V2Scopes.WITHDRAWAL);

        assertTrue(isPaused);
        assertEq(readyAt, block.timestamp + RECOVERY_DELAY);
        assertEq(declared, 2);
        assertEq(outstanding, 1);
        assertEq(controls.recoveryConditionCount(V2Scopes.WITHDRAWAL), 2);
        assertEq(controls.recoveryConditionAt(V2Scopes.WITHDRAWAL, 0), CONDITION_ONE);

        (bool declaredFlag, bool satisfied, bool waived,, address decidedBy,) =
            controls.recoveryCondition(V2Scopes.WITHDRAWAL, CONDITION_ONE);
        assertTrue(declaredFlag);
        assertTrue(satisfied);
        assertFalse(waived);
        assertEq(decidedBy, recoveryExecutor);
    }

    function test_recoveryDelayBoundsAreEnforced() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidArgument.selector, "recovery delay out of bounds"));
        controls.setRecoveryDelay(0);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidArgument.selector, "recovery delay out of bounds"));
        controls.setRecoveryDelay(31 days);

        vm.prank(governance);
        controls.setRecoveryDelay(6 hours);
        assertEq(controls.recoveryDelay(), 6 hours);
    }

    function test_newRecoveryDelayAppliesToSubsequentPauses() public {
        vm.prank(governance);
        controls.setRecoveryDelay(6 hours);

        _pause(V2Scopes.STAKING);
        assertEq(controls.recoveryReadyAt(V2Scopes.STAKING), block.timestamp + 6 hours);
    }

    function test_registerScopeExtendsKnownSetWithDocumentation() public {
        bytes32 futureScope = keccak256("future_module_mutation");

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidArgument.selector, "scope description required"));
        controls.registerScope(futureScope, "");

        vm.prank(governance);
        controls.registerScope(futureScope, "Future module mutation");

        assertTrue(controls.isKnownScope(futureScope));
        assertEq(controls.scopeCount(), V2Scopes.CANONICAL_SCOPE_COUNT + 1);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ScopeAlreadyRegistered.selector, futureScope));
        controls.registerScope(futureScope, "Future module mutation");
    }

    function test_outsiderCannotRegisterScope() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedEmergencyCaller.selector, outsider));
        controls.registerScope(keccak256("future_module_mutation"), "Future module mutation");
    }

    // =========================================================================
    // Group 4 — pause/recovery auditability
    // =========================================================================

    function test_pauseEmitsCompleteAuditTrail() public {
        bytes32 scope = V2Scopes.WITHDRAWAL;

        vm.prank(responder);
        vm.expectEmit(true, true, true, true);
        emit IEmergencyControls.EmergencyPaused(scope, responder);
        vm.expectEmit(true, true, true, true);
        emit EmergencyControls.ScopePauseRecorded(
            scope, responder, 1, block.timestamp + RECOVERY_DELAY, "oracle incident"
        );
        controls.pauseWithReason(scope, "oracle incident");

        assertEq(controls.emergencySequence(), 1);
    }

    function test_recoveryAndReopeningEmitCompleteAuditTrail() public {
        bytes32 scope = V2Scopes.WITHDRAWAL;
        _pause(scope);

        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit EmergencyControls.RecoveryConditionDeclared(scope, CONDITION_ONE, "documented precondition");
        controls.declareRecoveryCondition(scope, CONDITION_ONE, "documented precondition");

        vm.prank(recoveryExecutor);
        vm.expectEmit(true, true, true, true);
        emit EmergencyControls.RecoveryConditionSatisfied(scope, CONDITION_ONE, recoveryExecutor, "recovery evidence");
        controls.satisfyRecoveryCondition(scope, CONDITION_ONE, "recovery evidence");

        uint256 pausedAt = block.timestamp;
        _advancePastTimelock(scope);

        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit IEmergencyControls.EmergencyUnpaused(scope, governance);
        vm.expectEmit(true, true, true, true);
        emit EmergencyControls.ScopeUnpauseRecorded(
            scope, governance, 2, bytes32("proposal-42"), RECOVERY_DELAY
        );
        controls.unpauseWithReference(scope, bytes32("proposal-42"));

        assertEq(controls.emergencySequence(), 2);
        assertEq(controls.scopeUnpausedAt(scope), block.timestamp);
    }

    function test_waiverEmitsAuditTrail() public {
        bytes32 scope = V2Scopes.WITHDRAWAL;
        _pause(scope);
        _document(scope, CONDITION_ONE);

        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit EmergencyControls.RecoveryConditionWaived(
            scope, CONDITION_ONE, governance, "compensating control verified"
        );
        controls.waiveRecoveryCondition(scope, CONDITION_ONE, "compensating control verified");
    }

    function test_scopeRegistrationAndDelayChangesEmitAuditTrail() public {
        bytes32 futureScope = keccak256("future_module_mutation");

        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit EmergencyControls.ScopeRegistered(futureScope, "Future module mutation");
        controls.registerScope(futureScope, "Future module mutation");

        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit EmergencyControls.RecoveryDelayUpdated(RECOVERY_DELAY, 8 hours);
        controls.setRecoveryDelay(8 hours);
    }

    function test_checkSequenceAdvancesOnlyOnPauseAndReopen() public {
        assertEq(controls.emergencySequence(), 0);

        _pause(V2Scopes.STAKING);
        assertEq(controls.emergencySequence(), 1);

        _document(V2Scopes.STAKING, CONDITION_ONE);
        _satisfy(V2Scopes.STAKING, CONDITION_ONE);
        assertEq(controls.emergencySequence(), 1, "condition handling must not consume a sequence");

        _advancePastTimelock(V2Scopes.STAKING);
        vm.prank(governance);
        controls.unpause(V2Scopes.STAKING);
        assertEq(controls.emergencySequence(), 2);
    }

    // =========================================================================
    // Module surface
    // =========================================================================

    function test_moduleSurfaceIsAdvertised() public view {
        assertTrue(controls.supportsInterface(type(IEmergencyControls).interfaceId));
        assertTrue(controls.supportsInterface(type(IV2Module).interfaceId));

        (uint16 major, uint16 minor) = controls.protocolVersion();
        assertEq(major, 2);
        assertEq(minor, 0);
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(V2Errors.ZeroAddress.selector);
        new EmergencyControls(address(0), RECOVERY_DELAY);
    }

    function test_constructorRejectsOutOfBoundsDelay() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidArgument.selector, "recovery delay out of bounds"));
        new EmergencyControls(address(this), 0);
    }

    function test_canonicalScopesAreDistinctFromUnclassifiedIdentifiers() public view {
        assertTrue(V2Scopes.isCanonical(V2Scopes.STAKING));
        assertFalse(V2Scopes.isCanonical(UNKNOWN_SCOPE));
    }
}
