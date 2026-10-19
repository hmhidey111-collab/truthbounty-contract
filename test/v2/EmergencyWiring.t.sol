// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {FailClosedEmergencyControls as EmergencyControls} from "./helpers/FailClosedEmergencyControls.sol";
import "../../contracts/v2/EmergencyGuarded.sol";
import "../../contracts/v2/EvidenceRegistry.sol";
import "../../contracts/v2/StakeVault.sol";
import "../../contracts/v2/interfaces/IEmergencyControls.sol";
import "../../contracts/v2/interfaces/IEvidence.sol";
import "../../contracts/v2/interfaces/IStakeCustody.sol";
import "../../contracts/v2/interfaces/IV2Types.sol";
import "../../contracts/v2/libraries/V2Errors.sol";
import "../../contracts/v2/libraries/V2Scopes.sol";
import "../../contracts/interfaces/IClaimRegistry.sol";
import "../../contracts/mocks/MockEvidenceClaimRegistry.sol";
import "../../contracts/mocks/MockModuleRegistry.sol";
import "../../contracts/MockERC20.sol";

/// @dev Control-plane stub that rejects every scope. Proves the guard propagates a controller's
///      own rejection instead of falling open when the controller is unhelpful.
contract RejectingEmergencyControls {
    function requireOperationAllowed(bytes32 scope) external pure {
        revert V2Errors.UnknownOperation(scope);
    }

    function paused(bytes32 scope) external pure returns (bool) {
        revert V2Errors.UnknownOperation(scope);
    }
}

/// @title EmergencyWiringTest
/// @notice V2-SC-042 required test group 4 — cross-module invariants and bypass resistance.
/// @dev Drives the real `StakeVault` and `EvidenceRegistry` implementations against the canonical
///      `EmergencyControls` plane and asserts that no mutation is reachable while its scope is
///      paused, that scopes do not leak into one another, and that an unwired module is frozen.
contract EmergencyWiringTest is Test {
    EmergencyControls internal controls;
    StakeVault internal vault;
    EvidenceRegistry internal evidence;
    MockEvidenceClaimRegistry internal claimRegistry;
    MockModuleRegistry internal moduleRegistry;
    MockERC20 internal token;
    MockERC20 internal tokenB;

    address internal governance = makeAddr("governance");
    address internal responder = makeAddr("responder");
    address internal recoveryExecutor = makeAddr("recoveryExecutor");
    address internal outsider = makeAddr("outsider");
    address internal user = makeAddr("user");
    address internal settlementModule = makeAddr("settlementModule");

    uint256 internal constant CLAIM_ID = 1;
    uint256 internal constant RECOVERY_DELAY = 2 hours;
    bytes32 internal constant CONDITION = keccak256("recovery.condition");
    bytes32 internal constant CONTENT_DIGEST = keccak256("content-digest");
    bytes32 internal constant METADATA_DIGEST = keccak256("metadata-digest");

    function setUp() public {
        moduleRegistry = new MockModuleRegistry();
        claimRegistry = new MockEvidenceClaimRegistry();
        token = new MockERC20("Stake", "STK");
        tokenB = new MockERC20("Alt", "ALT");

        controls = new EmergencyControls(address(this), RECOVERY_DELAY);

        // The test contract keeps every administrative role on the modules so it can wire and
        // drive them directly. Emergency powers are split across distinct actors.
        controls.grantRole(controls.EMERGENCY_ROLE(), responder);
        controls.grantRole(controls.RECOVERY_ROLE(), recoveryExecutor);
        controls.grantRole(controls.SCOPE_ADMIN_ROLE(), governance);

        vault = new StakeVault(address(moduleRegistry), address(token), address(this));
        evidence = new EvidenceRegistry(address(this), address(claimRegistry));

        vault.setEmergencyControls(address(controls));
        evidence.setEmergencyControls(address(controls));

        moduleRegistry.permitModule(vault.MODULE_SETTLEMENT(), settlementModule);
        vault.setLockMutator(settlementModule, true);

        claimRegistry.setClaim(CLAIM_ID, user, uint64(block.timestamp + 7 days), IClaimRegistry.ClaimStatus.Pending);

        token.mint(user, 1_000 ether);
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _pause(bytes32 scope) internal {
        vm.prank(responder);
        controls.pause(scope);
    }

    function _expectScopePaused(bytes32 scope) internal {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ScopePaused.selector, scope));
    }

    /// @dev Reopens a paused scope through the full recovery procedure.
    function _reopen(bytes32 scope) internal {
        vm.prank(governance);
        controls.declareRecoveryCondition(scope, CONDITION, "documented recovery precondition");
        vm.prank(recoveryExecutor);
        controls.satisfyRecoveryCondition(scope, CONDITION, "recovery evidence");
        vm.warp(controls.recoveryReadyAt(scope));
        vm.prank(governance);
        controls.unpause(scope);
    }

    // =========================================================================
    // Every guarded mutation fails closed
    // =========================================================================

    function test_stakingScopeGatesEveryStakingMutation() public {
        _pause(V2Scopes.STAKING);

        _expectScopePaused(V2Scopes.STAKING);
        vault.depositStake(CLAIM_ID, 1 ether);

        _expectScopePaused(V2Scopes.STAKING);
        vault.deposit(address(token), 1 ether);

        _expectScopePaused(V2Scopes.STAKING);
        vault.lock(address(token), user, CLAIM_ID, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 1 ether);
    }

    function test_stakeReleaseScopeGatesEveryReleaseMutation() public {
        _pause(V2Scopes.STAKE_RELEASE);

        _expectScopePaused(V2Scopes.STAKE_RELEASE);
        vault.releaseStake(CLAIM_ID, user, 1 ether);

        _expectScopePaused(V2Scopes.STAKE_RELEASE);
        vault.unlock(address(token), user, CLAIM_ID, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 1 ether);
    }

    function test_slashScopeGatesEverySlashMutation() public {
        _pause(V2Scopes.SLASH_EXECUTION);

        _expectScopePaused(V2Scopes.SLASH_EXECUTION);
        vault.slashStake(CLAIM_ID, user, 1 ether, bytes32("fraud"));

        _expectScopePaused(V2Scopes.SLASH_EXECUTION);
        vault.allocateLocked(
            address(token), user, CLAIM_ID, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 1 ether, bytes32("fraud")
        );
    }

    function test_settlementExecutionScopeGatesEverySettlementMutation() public {
        _pause(V2Scopes.SETTLEMENT_EXECUTION);

        _expectScopePaused(V2Scopes.SETTLEMENT_EXECUTION);
        vault.settleConclusive(address(token), user, CLAIM_ID, 0, 1 ether, 0);

        _expectScopePaused(V2Scopes.SETTLEMENT_EXECUTION);
        vault.refundInconclusive(address(token), user, CLAIM_ID, 0, 1 ether);

        _expectScopePaused(V2Scopes.SETTLEMENT_EXECUTION);
        vault.carryForwardAppeal(address(token), user, CLAIM_ID, 0, 1, 1 ether);

        _expectScopePaused(V2Scopes.SETTLEMENT_EXECUTION);
        vault.rolloverRound(address(token), user, CLAIM_ID, 0, 1, 1 ether);

        _expectScopePaused(V2Scopes.SETTLEMENT_EXECUTION);
        vault.finalUnlock(address(token), user, CLAIM_ID, 0, 1 ether);
    }

    function test_withdrawalScopeGatesWithdrawals() public {
        _pause(V2Scopes.WITHDRAWAL);

        _expectScopePaused(V2Scopes.WITHDRAWAL);
        vault.withdraw(address(token), 1 ether);
    }

    function test_configurationScopeGatesVaultAdministration() public {
        _pause(V2Scopes.CONFIGURATION_PUBLISH);

        _expectScopePaused(V2Scopes.CONFIGURATION_PUBLISH);
        vault.setSupportedAsset(address(tokenB), true);

        _expectScopePaused(V2Scopes.CONFIGURATION_PUBLISH);
        vault.setLockMutator(outsider, true);
    }

    function test_evidenceScopesGateEvidenceMutations() public {
        _pause(V2Scopes.EVIDENCE_SUBMISSION);
        _expectScopePaused(V2Scopes.EVIDENCE_SUBMISSION);
        evidence.commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0);

        _reopen(V2Scopes.EVIDENCE_SUBMISSION);

        _pause(V2Scopes.EVIDENCE_STATUS);
        _expectScopePaused(V2Scopes.EVIDENCE_STATUS);
        evidence.setEvidenceStatus(1, IV2Types.EvidenceStatus.ACCEPTED);

        // The two evidence scopes are independent: pausing status changes did not fence submissions.
        vm.prank(user);
        evidence.commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0);
        assertEq(evidence.evidenceCount(CLAIM_ID), 1);
    }

    /// @dev Cross-module kill switch: engaging `global` freezes every guarded mutation in every
    ///      module. This is the invariant the issue requires — no canonical mutation bypasses the
    ///      emergency control plane.
    function test_globalPauseFreezesEveryModuleMutation() public {
        _pause(V2Scopes.GLOBAL);

        _expectScopePaused(V2Scopes.STAKING);
        vault.depositStake(CLAIM_ID, 1 ether);

        _expectScopePaused(V2Scopes.STAKE_RELEASE);
        vault.releaseStake(CLAIM_ID, user, 1 ether);

        _expectScopePaused(V2Scopes.SLASH_EXECUTION);
        vault.slashStake(CLAIM_ID, user, 1 ether, bytes32("fraud"));

        _expectScopePaused(V2Scopes.SETTLEMENT_EXECUTION);
        vault.finalUnlock(address(token), user, CLAIM_ID, 0, 1 ether);

        _expectScopePaused(V2Scopes.WITHDRAWAL);
        vault.withdraw(address(token), 1 ether);

        _expectScopePaused(V2Scopes.CONFIGURATION_PUBLISH);
        vault.setSupportedAsset(address(tokenB), true);

        _expectScopePaused(V2Scopes.EVIDENCE_SUBMISSION);
        evidence.commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0);

        _expectScopePaused(V2Scopes.EVIDENCE_STATUS);
        evidence.setEvidenceStatus(1, IV2Types.EvidenceStatus.ACCEPTED);

        // Read surfaces stay available throughout: a pause is not a data blackout.
        assertEq(vault.totalCustody(address(token)), 0);
        assertEq(vault.staked(CLAIM_ID, user), 0);
        assertEq(evidence.evidenceCount(CLAIM_ID), 0);
        assertEq(evidence.nextContributorNonce(user), 0);
    }

    /// @dev A paused kill switch must not fence the path that lifts it.
    function test_globalPauseLeavesRecoveryScopeOperable() public {
        _pause(V2Scopes.GLOBAL);

        assertTrue(controls.isOperationAllowed(V2Scopes.GOVERNANCE_RECOVERY));

        vm.prank(governance);
        controls.declareRecoveryCondition(V2Scopes.GLOBAL, CONDITION, "root cause identified and remediated");
        vm.prank(recoveryExecutor);
        controls.satisfyRecoveryCondition(V2Scopes.GLOBAL, CONDITION, "remediation report");
        vm.warp(controls.recoveryReadyAt(V2Scopes.GLOBAL));

        vm.prank(governance);
        controls.unpause(V2Scopes.GLOBAL);

        assertTrue(controls.isOperationAllowed(V2Scopes.STAKING));
    }

    // =========================================================================
    // Bypass resistance
    // =========================================================================

    function test_pausingOneScopeDoesNotFenceUnrelatedOperations() public {
        _pause(V2Scopes.WITHDRAWAL);

        // Configuration and evidence submission are untouched by a withdrawal pause.
        vault.setSupportedAsset(address(tokenB), true);
        assertTrue(vault.supportedAssets(address(tokenB)));

        vm.prank(user);
        evidence.commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0);
        assertEq(evidence.evidenceCount(CLAIM_ID), 1);

        // Staking still works end to end.
        vm.prank(user);
        vault.depositStake(CLAIM_ID, 2 ether);
        assertEq(vault.staked(CLAIM_ID, user), 2 ether);

        // ...but withdrawal itself is still fenced.
        _expectScopePaused(V2Scopes.WITHDRAWAL);
        vault.withdraw(address(token), 1 ether);
    }

    function test_pausingEvidenceSubmissionDoesNotFenceStaking() public {
        _pause(V2Scopes.EVIDENCE_SUBMISSION);

        _expectScopePaused(V2Scopes.EVIDENCE_SUBMISSION);
        evidence.commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0);

        vm.prank(user);
        vault.depositStake(CLAIM_ID, 1 ether);
        assertEq(vault.staked(CLAIM_ID, user), 1 ether);
    }

    function test_reopenedScopeRestoresItsMutations() public {
        _pause(V2Scopes.STAKING);

        _expectScopePaused(V2Scopes.STAKING);
        vm.prank(user);
        vault.depositStake(CLAIM_ID, 1 ether);

        _reopen(V2Scopes.STAKING);

        vm.prank(user);
        vault.depositStake(CLAIM_ID, 1 ether);
        assertEq(vault.staked(CLAIM_ID, user), 1 ether);

        // Reopening one scope does not silently reopen another.
        assertFalse(controls.paused(V2Scopes.WITHDRAWAL));
        assertTrue(controls.isOperationAllowed(V2Scopes.WITHDRAWAL));
    }

    function test_unwiredStakeVaultIsFrozen() public {
        StakeVault fresh = new StakeVault(address(moduleRegistry), address(token), address(this));

        vm.expectRevert(V2Errors.EmergencyControlsNotConfigured.selector);
        fresh.depositStake(CLAIM_ID, 1 ether);

        vm.expectRevert(V2Errors.EmergencyControlsNotConfigured.selector);
        fresh.deposit(address(token), 1 ether);

        vm.expectRevert(V2Errors.EmergencyControlsNotConfigured.selector);
        fresh.setSupportedAsset(address(tokenB), true);

        vm.expectRevert(V2Errors.EmergencyControlsNotConfigured.selector);
        fresh.withdraw(address(token), 1 ether);
    }

    function test_unwiredEvidenceRegistryIsFrozen() public {
        EvidenceRegistry fresh = new EvidenceRegistry(address(this), address(claimRegistry));

        vm.expectRevert(V2Errors.EmergencyControlsNotConfigured.selector);
        fresh.commitEvidence(CLAIM_ID, CONTENT_DIGEST, METADATA_DIGEST, 0);

        vm.expectRevert(V2Errors.EmergencyControlsNotConfigured.selector);
        fresh.setEvidenceStatus(1, IV2Types.EvidenceStatus.ACCEPTED);
    }

    /// @dev A controller that rejects the scope must fence the module, never fall open.
    function test_hostileControlPlaneCannotBeBypassed() public {
        RejectingEmergencyControls rejecting = new RejectingEmergencyControls();
        vault.setEmergencyControls(address(rejecting));

        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownOperation.selector, V2Scopes.STAKING));
        vault.depositStake(CLAIM_ID, 1 ether);
    }

    /// @dev A controller that does not recognise the scope freezes the module rather than
    ///      permitting the mutation — the exact fail-open defect this issue closes.
    function test_scopeMustBeCanonicalOnTheControlPlane() public {
        assertFalse(controls.isKnownScope(keccak256("not.a.canonical.scope")));
        assertFalse(controls.isOperationAllowed(keccak256("not.a.canonical.scope")));

        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.UnknownOperation.selector, keccak256("not.a.canonical.scope"))
        );
        controls.requireOperationAllowed(keccak256("not.a.canonical.scope"));

        // Every scope the modules actually gate on is part of the canonical manifest, so a typo in
        // a module constant would be caught here rather than in production.
        assertTrue(controls.isKnownScope(V2Scopes.STAKING));
        assertTrue(controls.isKnownScope(V2Scopes.STAKE_RELEASE));
        assertTrue(controls.isKnownScope(V2Scopes.SLASH_EXECUTION));
        assertTrue(controls.isKnownScope(V2Scopes.SETTLEMENT_EXECUTION));
        assertTrue(controls.isKnownScope(V2Scopes.WITHDRAWAL));
        assertTrue(controls.isKnownScope(V2Scopes.CONFIGURATION_PUBLISH));
        assertTrue(controls.isKnownScope(V2Scopes.EVIDENCE_SUBMISSION));
        assertTrue(controls.isKnownScope(V2Scopes.EVIDENCE_STATUS));
    }

    // =========================================================================
    // Wiring lifecycle
    // =========================================================================

    function test_wiringEmitsConfigurationEvent() public {
        StakeVault fresh = new StakeVault(address(moduleRegistry), address(token), address(this));

        vm.expectEmit(true, true, true, true);
        emit EmergencyGuarded.EmergencyControlsConfigured(address(0), address(controls));
        fresh.setEmergencyControls(address(controls));
    }

    function test_wiringRejectsZeroAddress() public {
        vm.expectRevert(V2Errors.ZeroAddress.selector);
        vault.setEmergencyControls(address(0));

        vm.expectRevert(V2Errors.ZeroAddress.selector);
        evidence.setEmergencyControls(address(0));
    }

    function test_wiringRequiresModuleAdminRole() public {
        bytes32 vaultAdminRole = vault.ADMIN_ROLE();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, vaultAdminRole
            )
        );
        vault.setEmergencyControls(address(controls));

        bytes32 evidenceAdminRole = evidence.DEFAULT_ADMIN_ROLE();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, evidenceAdminRole
            )
        );
        evidence.setEmergencyControls(address(controls));
    }

    /// @dev The wiring setter is deliberately outside the guard so a superseded or broken control
    ///      plane can be repaired while the protocol is frozen. Without this, a mis-wired pause
    ///      would be unrecoverable.
    function test_wiringIsRepairableWhileFrozen() public {
        _pause(V2Scopes.GLOBAL);

        _expectScopePaused(V2Scopes.STAKING);
        vault.depositStake(CLAIM_ID, 1 ether);

        EmergencyControls replacement = new EmergencyControls(address(this), RECOVERY_DELAY);

        vault.setEmergencyControls(address(replacement));
        evidence.setEmergencyControls(address(replacement));

        assertEq(address(vault.emergencyControls()), address(replacement));
        assertEq(address(evidence.emergencyControls()), address(replacement));

        assertTrue(replacement.isOperationAllowed(V2Scopes.STAKING));
        vm.prank(user);
        vault.depositStake(CLAIM_ID, 1 ether);
        assertEq(vault.staked(CLAIM_ID, user), 1 ether);
    }

    function test_modulesAdvertiseTheControlPlaneIntegration() public view {
        assertTrue(vault.supportsInterface(type(IStakeCustody).interfaceId));
        assertTrue(evidence.supportsInterface(type(IEvidence).interfaceId));

        // Neither module exposes a module-local circuit breaker any more: the only pause surface is
        // the canonical control plane.
        assertEq(address(vault.emergencyControls()), address(controls));
        assertEq(address(evidence.emergencyControls()), address(controls));
    }
}
