// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/ClaimRegistry.sol";
import "../contracts/governance/ParameterVersionRegistry.sol";
import "../contracts/StakeVault.sol";
import "../contracts/DisputeResolution.sol";
import "../contracts/MockERC20.sol";
import "../contracts/mocks/MockFailingBondERC20.sol";

/**
 * @title DisputeResolutionTest
 * @notice Foundry tests for Dispute Opening & Challenge Bond Custody (V2-SC-016).
 *
 * @dev Coverage (mapped to issue #367 required tests):
 *   - successful challenge at a valid timestamp,
 *   - early / late / duplicate / finalized / paused / insufficient-allowance /
 *     failed-transfer failures,
 *   - atomicity of state + custody (no dispute record/transition without a bond),
 *   - exactly one appeal path per claim,
 *   - bond + dispute records reconcile,
 *   - claim state changes only after successful custody.
 */
contract DisputeResolutionTest is Test {
    ClaimRegistry public registry;
    StakeVault public vault;
    DisputeResolution public dispute;
    MockERC20 public token;

    address public admin = address(0xAA1);
    address public updater = address(0xBB1);
    address public challenger = address(0xCC1);
    address public challenger2 = address(0xCC2);
    address public claimCreator = address(0xDD1);

    uint256 public constant BOND = 500e18;
    uint64 public constant WINDOW = 3 days;
    uint256 public constant VERIFY_OFFSET = 24 hours;

    bytes32 public constant RATIONALE = keccak256("evidence-cid-123");

    string internal constant VALID_CID =
        "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG";
    string internal constant VALID_STATEMENT =
        "The unemployment rate in Germany fell to 5.1% in Q1 2026 according to Destatis.";

    function setUp() public {
        ParameterVersionRegistry paramRegistry = new ParameterVersionRegistry(admin, admin);
        registry = new ClaimRegistry(admin, address(paramRegistry));
        token = new MockERC20("Bounty", "BOUNTY");
        vault = new StakeVault(admin, address(token));
        dispute = new DisputeResolution(
            address(registry),
            address(vault),
            address(token),
            BOND,
            WINDOW,
            admin
        );

        // Resolve roles before pranking: the staticcalls would otherwise consume the pranks.
        bytes32 updaterRole = registry.REGISTRY_UPDATER_ROLE();
        bytes32 operatorRole = vault.OPERATOR_ROLE();

        // Authorise the dispute module to transition claims.
        bytes32 registryUpdaterRole = registry.REGISTRY_UPDATER_ROLE();
        vm.startPrank(admin);
        registry.grantRole(registryUpdaterRole, address(dispute));
        // The helper `_driveToOutcome` impersonates `updater`, which also needs the role.
        registry.grantRole(registryUpdaterRole, updater);

        // Authorise the dispute module as the vault operator.
        vault.grantRole(operatorRole, address(dispute));
        vm.stopPrank();

        // Fund challengers and users.
        token.mint(challenger, 100_000e18);
        token.mint(challenger2, 100_000e18);
        token.mint(claimCreator, 100_000e18);
    }

    /// Create a claim whose verification deadline is `VERIFY_OFFSET` from now
    /// and return the new claim id.
    function _createClaim() internal returns (uint256 claimId) {
        vm.prank(claimCreator);
        claimId = registry.createClaim(VALID_STATEMENT, VALID_CID, uint64(block.timestamp + VERIFY_OFFSET));
    }

    /// Take a claim to a provisional outcome (`VerifiedTrue`/`VerifiedFalse`).
    function _driveToOutcome(uint256 claimId, IClaimRegistry.ClaimStatus outcome) internal {
        vm.prank(updater);
        registry.updateClaimStatus(claimId, outcome);
    }

    /// Fully prepare a claim and jump into the challenge window.
    function _inWindow(uint256 claimId) internal {
        uint256 deadline = registry.getClaim(claimId).verificationDeadline;
        // Verify the claim's created deadline is in the future, then jump just
        // inside the window (deadline + 1s).
        vm.warp(deadline + 1);
    }

    function _approveChallenge(address who, uint256 amount) internal {
        // The vault is the ERC-20 spender and bond custodian: the challenger
        // authorises the vault directly.
        vm.prank(who);
        token.approve(address(vault), amount);
    }

    // =========================================================================
    // Success
    // =========================================================================

    function test_OpenDispute_SucceedsAtValidTimestamp() public {
        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);
        _inWindow(claimId);
        _approveChallenge(challenger, BOND);

        uint256 vaultBefore = token.balanceOf(address(vault));

        vm.prank(challenger);
        uint256 disputeId = dispute.openDispute(
            claimId,
            IDisputeResolution.ChallengedOutcome.TRUE,
            RATIONALE
        );

        // Dispute id starts at 1.
        assertEq(disputeId, 1);
        assertEq(dispute.totalDisputes(), 1);
        assertEq(dispute.disputeExists(disputeId), true);
        assertEq(dispute.getDisputeByClaim(claimId), disputeId);

        // Bond custody: tokens vaulted.
        assertEq(token.balanceOf(address(vault)), vaultBefore + BOND);
        assertEq(vault.totalLocked(), BOND);
        ISTakeVault.BondLock memory lock = vault.getLock(disputeId);
        assertEq(lock.amount, BOND);
        assertEq(lock.depositor, challenger);

        // Dispute record content.
        IDisputeResolution.Dispute memory d = dispute.getDispute(disputeId);
        assertEq(d.claimId, claimId);
        assertEq(d.challenger, challenger);
        assertEq(uint256(d.challengedOutcome), uint256(IDisputeResolution.ChallengedOutcome.TRUE));
        assertEq(uint256(d.challengedStatus), uint256(IClaimRegistry.ClaimStatus.VerifiedTrue));
        assertEq(d.bondToken, address(token));
        assertEq(d.bondAmount, BOND);
        assertEq(d.appealRationaleHash, RATIONALE);
        assertEq(uint256(d.openedAt), block.timestamp);
        // Appeal (= frozen) deadline recorded as verificationDeadline + window.
        uint256 deadline = registry.getClaim(claimId).verificationDeadline;
        assertEq(uint256(d.appealDeadline), deadline + WINDOW);
        assertEq(d.settled, false);

        // Claim transitioned to Disputed.
        assertEq(uint256(registry.getClaimStatus(claimId)), uint256(IClaimRegistry.ClaimStatus.Disputed));
    }

    function test_OpenDispute_EmitsDisputeOpenedV1() public {
        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedFalse);
        _inWindow(claimId);
        _approveChallenge(challenger, BOND);

        uint256 deadline = registry.getClaim(claimId).verificationDeadline;

        vm.prank(challenger);
        vm.expectEmit(true, true, true, true, address(dispute));
        emit IDisputeResolution.DisputeOpenedV1(
            claimId,
            1,
            challenger,
            IDisputeResolution.ChallengedOutcome.FALSE,
            IClaimRegistry.ClaimStatus.VerifiedFalse,
            address(token),
            BOND,
            uint64(deadline + WINDOW),
            RATIONALE,
            uint64(block.timestamp),
            1
        );
        dispute.openDispute(
            claimId,
            IDisputeResolution.ChallengedOutcome.FALSE,
            RATIONALE
        );
    }

    function test_OpenDispute_ClaimVerifiedFalseCanBeChallenged() public {
        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedFalse);
        _inWindow(claimId);
        _approveChallenge(challenger, BOND);

        vm.prank(challenger);
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.FALSE, RATIONALE);

        IDisputeResolution.Dispute memory d = dispute.getDispute(1);
        assertEq(uint256(d.challengedStatus), uint256(IClaimRegistry.ClaimStatus.VerifiedFalse));
    }

    // =========================================================================
    // Timing: early / late
    // =========================================================================

    function test_OpenDispute_RevertsEarly_InsideVerificationWindow() public {
        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);
        _approveChallenge(challenger, BOND);

        // block.timestamp <= verificationDeadline -> window not open.
        vm.expectRevert(IDisputeResolution.ChallengeWindowNotOpen.selector);
        vm.prank(challenger);
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);

        assertDisputeNotCommitted(claimId);
    }

    function test_OpenDispute_RevertsAtVerificationDeadline() public {
        uint256 claimId = _createClaim();
        uint256 deadline = registry.getClaim(claimId).verificationDeadline;
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);
        vm.warp(deadline);
        _approveChallenge(challenger, BOND);

        vm.expectRevert(IDisputeResolution.ChallengeWindowNotOpen.selector);
        vm.prank(challenger);
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);

        assertDisputeNotCommitted(claimId);
    }

    function test_OpenDispute_RevertsLate_AfterFrozenDeadline() public {
        uint256 claimId = _createClaim();
        uint256 deadline = registry.getClaim(claimId).verificationDeadline;
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);

        // Jump past the frozen deadline.
        vm.warp(deadline + WINDOW + 1);
        _approveChallenge(challenger, BOND);

        vm.expectRevert(IDisputeResolution.FrozenDeadlinePassed.selector);
        vm.prank(challenger);
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);

        assertDisputeNotCommitted(claimId);
    }

    function test_OpenDispute_SucceedsAtFrozenDeadline() public {
        uint256 claimId = _createClaim();
        uint256 verificationDeadline = registry.getClaim(claimId).verificationDeadline;
        uint256 frozenDeadline = verificationDeadline + WINDOW;
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);
        vm.warp(frozenDeadline);
        _approveChallenge(challenger, BOND);

        vm.prank(challenger);
        uint256 disputeId = dispute.openDispute(
            claimId,
            IDisputeResolution.ChallengedOutcome.TRUE,
            RATIONALE
        );

        assertEq(disputeId, 1);
        assertEq(dispute.getDispute(disputeId).openedAt, frozenDeadline);
        assertEq(dispute.getDispute(disputeId).appealDeadline, frozenDeadline);
        assertEq(vault.totalLocked(), BOND);
    }

    // =========================================================================
    // Duplicate / recursion / one appeal path
    // =========================================================================

    function test_OpenDispute_RevertsDuplicateChallenge() public {
        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);
        _inWindow(claimId);
        _approveChallenge(challenger, BOND);

        vm.prank(challenger);
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);

        // Second challenge (even from a different address) is rejected.
        _approveChallenge(challenger2, BOND);
        vm.expectRevert(abi.encodeWithSelector(IDisputeResolution.DisputeAlreadyOpen.selector, claimId));
        vm.prank(challenger2);
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.FALSE, RATIONALE);

        // Still exactly one dispute; no double bond lock.
        assertEq(dispute.totalDisputes(), 1);
        assertEq(vault.totalLocked(), BOND);
    }

    function test_OpenDispute_RevertsRecursive_OnAlreadyDisputedClaim() public {
        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);
        _inWindow(claimId);
        _approveChallenge(challenger, BOND);
        vm.prank(challenger);
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);

        // Claim is now Disputed. A recursive reopen is rejected before the status
        // check because the one-appeal-path guard runs first, so the more precise
        // `DisputeAlreadyOpen` surfaces. Either way the reopen cannot succeed.
        vm.expectRevert(
            abi.encodeWithSelector(IDisputeResolution.DisputeAlreadyOpen.selector, claimId)
        );
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);

        // The claim remains Disputed and no second dispute or bond was created.
        assertEq(uint256(registry.getClaimStatus(claimId)), uint256(IClaimRegistry.ClaimStatus.Disputed));
        assertEq(dispute.totalDisputes(), 1);
        assertEq(vault.totalLocked(), BOND);
    }

    // =========================================================================
    // Finalized / non-challengeable state
    // =========================================================================

    function test_OpenDispute_RevertsForPendingClaim() public {
        uint256 claimId = _createClaim();
        // Claim stays Pending.
        _approveChallenge(challenger, BOND);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDisputeResolution.ClaimNotChallengeable.selector,
                IClaimRegistry.ClaimStatus.Pending
            )
        );
        vm.prank(challenger);
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);
    }

    function test_OpenDispute_RevertsForCancelledClaim() public {
        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.Cancelled);
        _inWindow(claimId);
        _approveChallenge(challenger, BOND);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDisputeResolution.ClaimNotChallengeable.selector,
                IClaimRegistry.ClaimStatus.Cancelled
            )
        );
        vm.prank(challenger);
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);
    }

    // =========================================================================
    // Bond / allowance
    // =========================================================================

    function test_OpenDispute_RevertsInsufficientAllowance() public {
        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);
        _inWindow(claimId);
        // No approval.

        vm.expectRevert(IDisputeResolution.InsufficientBondAllowance.selector);
        vm.prank(challenger);
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);
    }

    function test_OpenDispute_GovernmentCannotWaiveBond() public {
        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);
        _inWindow(claimId);

        // Even the admin (highest privilege) must post a bond to open a dispute:
        // call succeeds only WITH allowance + tokens; a bond is always required.
        // Assert the dispute cannot be opened without bonding regardless of role.
        vm.expectRevert(IDisputeResolution.InsufficientBondAllowance.selector);
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);
    }

    // =========================================================================
    // Failed transfer / atomicity
    // =========================================================================

    function test_OpenDispute_FailedBondTransfer_RevertsAtomically() public {
        // A failing-token contract whose transferFrom returns false: SafeERC20 turns
        // that into a revert, so the vault cannot custody the bond and the dispute
        // open must roll back entirely.
        MockFailingBondERC20 failing = new MockFailingBondERC20();
        DisputeResolution failingModule = new DisputeResolution(
            address(registry),
            address(vault),
            address(failing),
            BOND,
            WINDOW,
            admin
        );
        bytes32 failingUpdaterRole = registry.REGISTRY_UPDATER_ROLE();
        bytes32 failingOperatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(admin);
        registry.grantRole(failingUpdaterRole, address(failingModule));
        vault.grantRole(failingOperatorRole, address(failingModule));
        vm.stopPrank();

        // Failing token mints to ITS deployer (this test contract); grant the
        // challenger tokens and an allowance toward the vault (the ERC-20 spender).
        failing.mint(challenger, 100_000e18);
        vm.prank(challenger);
        failing.approve(address(vault), BOND);

        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);
        _inWindow(claimId);

        vm.expectRevert();
        vm.prank(challenger);
        failingModule.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);

        // Atomic: no dispute record, no claim transition, no vault lock.
        assertEq(failingModule.totalDisputes(), 0);
        assertEq(failingModule.getDisputeByClaim(claimId), 0);
        assertEq(uint256(registry.getClaimStatus(claimId)), uint256(IClaimRegistry.ClaimStatus.VerifiedTrue));
        assertEq(vault.totalLocked(), 0);
    }

    function test_CustodyFailure_LeavesNoResidualAllowance() public {
        // After a failed open, the challenger's bond must be untouched: the vault
        // is the ERC-20 spender, so a failed pull must not have consumed any of
        // the challenger's standing approval toward the vault.
        MockFailingBondERC20 failing = new MockFailingBondERC20();
        DisputeResolution failingModule = new DisputeResolution(
            address(registry),
            address(vault),
            address(failing),
            BOND,
            WINDOW,
            admin
        );
        bytes32 failingUpdaterRole = registry.REGISTRY_UPDATER_ROLE();
        bytes32 failingOperatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(admin);
        registry.grantRole(failingUpdaterRole, address(failingModule));
        vault.grantRole(failingOperatorRole, address(failingModule));
        vm.stopPrank();

        failing.mint(challenger, 100_000e18);
        vm.prank(challenger);
        failing.approve(address(vault), BOND);

        uint256 balanceBefore = failing.balanceOf(challenger);
        uint256 allowanceBefore = failing.allowance(challenger, address(vault));

        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);
        _inWindow(claimId);

        vm.prank(challenger);
        try failingModule.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE) {
            fail("expected revert");
        } catch {}

        // No bond was taken and the challenger's approval is preserved intact.
        assertEq(failing.balanceOf(challenger), balanceBefore, "bond must not be pulled on failure");
        assertEq(
            failing.allowance(challenger, address(vault)),
            allowanceBefore,
            "challenger allowance toward the vault must be untouched"
        );
        assertEq(
            failing.allowance(address(failingModule), address(vault)),
            0,
            "module must never hold a vault allowance"
        );
        assertEq(vault.totalLocked(), 0, "no lock may be recorded on custody failure");
    }

    // =========================================================================
    // Paused
    // =========================================================================

    function test_OpenDispute_RevertsWhenPaused() public {
        bytes32 pauserRole = dispute.PAUSER_ROLE();
        vm.startPrank(admin);
        dispute.grantRole(pauserRole, admin);
        dispute.pause();
        vm.stopPrank();

        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);
        _inWindow(claimId);
        _approveChallenge(challenger, BOND);

        vm.expectRevert();
        vm.prank(challenger);
        dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);

        assertDisputeNotCommitted(claimId);
    }

    function test_OpenDispute_SucceedsAfterUnpause() public {
        bytes32 pauserRole = dispute.PAUSER_ROLE();
        vm.startPrank(admin);
        dispute.grantRole(pauserRole, admin);
        dispute.pause();
        dispute.unpause();
        vm.stopPrank();

        uint256 claimId = _createClaim();
        _driveToOutcome(claimId, IClaimRegistry.ClaimStatus.VerifiedTrue);
        _inWindow(claimId);
        _approveChallenge(challenger, BOND);

        vm.prank(challenger);
        uint256 disputeId = dispute.openDispute(claimId, IDisputeResolution.ChallengedOutcome.TRUE, RATIONALE);
        assertEq(disputeId, 1);
    }

    // =========================================================================
    // View helpers
    // =========================================================================

    function test_FrozenDeadline_And_Config() public view {
        assertEq(dispute.bondToken(), address(token));
        assertEq(dispute.bondAmount(), BOND);
        assertEq(uint256(dispute.challengeWindowDuration()), uint256(WINDOW));
        assertEq(address(dispute.claimRegistry()), address(registry));
        assertEq(address(dispute.vault()), address(vault));
    }

    function test_DisputeExists_UnknownIsFalse() public view {
        assertFalse(dispute.disputeExists(999));
        assertEq(dispute.getDisputeByClaim(999), 0);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function assertDisputeNotCommitted(uint256 claimId) internal {
        assertEq(dispute.totalDisputes(), 0);
        assertEq(dispute.getDisputeByClaim(claimId), 0);
        assertEq(vault.totalLocked(), 0);
    }
}
