// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/disputes/AppealVerificationRound.sol";
import "../../contracts/interfaces/IAppealVerificationRound.sol";
import "../../contracts/interfaces/IDisputeResolution.sol";
import "../../contracts/interfaces/ISTakeVault.sol";
import "../../contracts/StakeVault.sol";
import "../../contracts/ClaimRegistry.sol";
import "../../contracts/MockReputationOracle.sol";
import "../../contracts/MockERC20.sol";
import "../../contracts/governance/GovernanceController.sol";
import "../../contracts/governance/ParameterVersionRegistry.sol";

contract MockDisputeResolution is IDisputeResolution {
    mapping(uint256 => Dispute) public disputes;

    function setDispute(
        uint256 disputeId,
        uint256 claimId,
        address challenger,
        ChallengedOutcome outcome,
        uint256 appealDeadline
    ) external {
        disputes[disputeId] = Dispute({
            id: disputeId,
            claimId: claimId,
            challenger: challenger,
            challengedOutcome: outcome,
            challengedStatus: IClaimRegistry.ClaimStatus.VerifiedTrue,
            bondToken: address(0),
            bondAmount: 0,
            openedAt: uint64(block.timestamp),
            appealDeadline: uint64(appealDeadline),
            appealRationaleHash: bytes32(0),
            settled: false
        });
    }

    function getDispute(uint256 disputeId) external view override returns (Dispute memory) {
        return disputes[disputeId];
    }

    function disputeExists(uint256 disputeId) external view override returns (bool) {
        return disputes[disputeId].id != 0;
    }

    function getDisputeByClaim(uint256 claimId) external view override returns (uint256) {
        return 0;
    }

    function openDispute(uint256 claimId, ChallengedOutcome outcome, bytes32 rationaleHash) external override returns (uint256) {
        return 0;
    }

    function totalDisputes() external view override returns (uint256) {
        return 0;
    }
}

contract AppealBindingTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant CLAIM_CREATOR = address(0xC1A13);
    address internal constant CHALLENGER = address(0xDE901);
    address internal constant UNAUTHORIZED = address(0xBADC0DE);
    address internal constant DELEGATED_PAYER = address(0xFA11);
    address internal constant BENEFICIARY = address(0x8EEF);
    address internal constant SLASH_RECIPIENT = address(0x51A54);

    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    string internal constant SAMPLE_CID = "Qm1234567890abcdef1234567890abcdef1234567890abcd";

    MockERC20 internal token;
    MockReputationOracle internal oracle;
    GovernanceController internal govController;
    ClaimRegistry internal claimRegistry;
    StakeVault internal vault;
    AppealVerificationRound internal appeal;
    MockDisputeResolution internal mockDisputeResolution;

    uint256 internal claimId;
    uint256 internal parentDisputeId = 42;
    uint256 internal appealDeadline;

    function setUp() public {
        vm.startPrank(ADMIN);

        token = new MockERC20("Reward", "RWD");
        oracle = new MockReputationOracle();
        govController = new GovernanceController(ADMIN);
        ParameterVersionRegistry paramReg = new ParameterVersionRegistry(ADMIN, ADMIN);
        claimRegistry = new ClaimRegistry(ADMIN, address(paramReg));
        vault = new StakeVault(ADMIN, address(token));
        mockDisputeResolution = new MockDisputeResolution();

        IAppealVerificationRound.AppealRoundConfig memory cfg = IAppealVerificationRound.AppealRoundConfig({
            roundDuration: 3 days,
            minStakeAmount: 100e18,
            stakeMultiplierBps: 15_000,
            maxWeightCap: 1_000e18,
            parameterVersion: 1,
            maxAppealRounds: 2,
            appealBond: 1_000e18,
            appealBondEscalationBps: 15_000,
            maxAppealBond: 5_000e18,
            maxVotersPerRound: 100
        });

        appeal = new AppealVerificationRound(
            address(token),
            address(claimRegistry),
            address(oracle),
            address(vault),
            cfg,
            address(govController),
            ADMIN
        );

        vault.grantRole(OPERATOR_ROLE, address(appeal));
        appeal.setDisputeResolution(address(mockDisputeResolution));

        claimId = claimRegistry.createClaim("Appeal claim", SAMPLE_CID, uint64(block.timestamp + 10 days));

        appealDeadline = block.timestamp + 2 days;
        mockDisputeResolution.setDispute(
            parentDisputeId,
            claimId,
            CHALLENGER,
            IDisputeResolution.ChallengedOutcome.TRUE,
            appealDeadline
        );

        vm.stopPrank();

        // Fund accounts
        token.mint(CHALLENGER, 10_000e18);
        token.mint(DELEGATED_PAYER, 10_000e18);
        token.mint(UNAUTHORIZED, 10_000e18);

        vm.prank(CHALLENGER);
        token.approve(address(vault), type(uint256).max);

        vm.prank(DELEGATED_PAYER);
        token.approve(address(vault), type(uint256).max);

        vm.prank(UNAUTHORIZED);
        token.approve(address(vault), type(uint256).max);
    }

    // --- Happy Path with Delegated Payer ---

    function test_openBoundAppealRoundWithDelegatedPayer() public {
        IAppealVerificationRound.BoundAppealParams memory params = IAppealVerificationRound.BoundAppealParams({
            claimId: claimId,
            parentDisputeId: parentDisputeId,
            parentOutcome: uint8(IDisputeResolution.ChallengedOutcome.TRUE),
            roundIndex: 1,
            appellant: CHALLENGER,
            bondPayer: DELEGATED_PAYER,
            bondBeneficiary: BENEFICIARY
        });

        uint256 payerBalBefore = token.balanceOf(DELEGATED_PAYER);
        uint256 vaultBalBefore = token.balanceOf(address(vault));

        vm.prank(DELEGATED_PAYER);
        appeal.openBoundAppealRound(params);

        assertEq(token.balanceOf(DELEGATED_PAYER), payerBalBefore - 1_000e18, "Bond pulled from delegated payer");
        assertEq(token.balanceOf(address(vault)), vaultBalBefore + 1_000e18, "Bond custody in vault");

        IAppealVerificationRound.AppealRound memory round = appeal.getAppealRound(claimId);
        assertEq(round.status == IAppealVerificationRound.AppealRoundStatus.OPEN, true);
        assertEq(round.parentDisputeId, parentDisputeId);
        assertEq(round.parentOutcome, uint8(IDisputeResolution.ChallengedOutcome.TRUE));
        assertEq(round.appellant, CHALLENGER);
        assertEq(round.bondPayer, DELEGATED_PAYER);
        assertEq(round.bondBeneficiary, BENEFICIARY);
    }

    // --- Rejection: Unauthorized Appellant ---

    function test_revertUnauthorizedAppellant() public {
        IAppealVerificationRound.BoundAppealParams memory params = IAppealVerificationRound.BoundAppealParams({
            claimId: claimId,
            parentDisputeId: parentDisputeId,
            parentOutcome: uint8(IDisputeResolution.ChallengedOutcome.TRUE),
            roundIndex: 1,
            appellant: UNAUTHORIZED,
            bondPayer: UNAUTHORIZED,
            bondBeneficiary: UNAUTHORIZED
        });

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(abi.encodeWithSelector(IAppealVerificationRound.UnauthorizedAppellant.selector, UNAUTHORIZED));
        appeal.openBoundAppealRound(params);
    }

    // --- Rejection: Wrong Parent Dispute ---

    function test_revertWrongParentDispute() public {
        uint256 wrongDisputeId = 999;
        IAppealVerificationRound.BoundAppealParams memory params = IAppealVerificationRound.BoundAppealParams({
            claimId: claimId,
            parentDisputeId: wrongDisputeId,
            parentOutcome: uint8(IDisputeResolution.ChallengedOutcome.TRUE),
            roundIndex: 1,
            appellant: CHALLENGER,
            bondPayer: CHALLENGER,
            bondBeneficiary: BENEFICIARY
        });

        vm.prank(CHALLENGER);
        vm.expectRevert(
            abi.encodeWithSelector(IAppealVerificationRound.WrongParentDispute.selector, claimId, wrongDisputeId)
        );
        appeal.openBoundAppealRound(params);
    }

    // --- Rejection: Invalid Parent Outcome ---

    function test_revertInvalidParentOutcome() public {
        uint8 wrongOutcome = uint8(IDisputeResolution.ChallengedOutcome.FALSE);
        uint8 expectedOutcome = uint8(IDisputeResolution.ChallengedOutcome.TRUE);

        IAppealVerificationRound.BoundAppealParams memory params = IAppealVerificationRound.BoundAppealParams({
            claimId: claimId,
            parentDisputeId: parentDisputeId,
            parentOutcome: wrongOutcome,
            roundIndex: 1,
            appellant: CHALLENGER,
            bondPayer: CHALLENGER,
            bondBeneficiary: BENEFICIARY
        });

        vm.prank(CHALLENGER);
        vm.expectRevert(
            abi.encodeWithSelector(IAppealVerificationRound.InvalidParentOutcome.selector, wrongOutcome, expectedOutcome)
        );
        appeal.openBoundAppealRound(params);
    }

    // --- Rejection: Wrong Round Index ---

    function test_revertWrongRoundIndex() public {
        IAppealVerificationRound.BoundAppealParams memory params = IAppealVerificationRound.BoundAppealParams({
            claimId: claimId,
            parentDisputeId: parentDisputeId,
            parentOutcome: uint8(IDisputeResolution.ChallengedOutcome.TRUE),
            roundIndex: 2, // Should be 1
            appellant: CHALLENGER,
            bondPayer: CHALLENGER,
            bondBeneficiary: BENEFICIARY
        });

        vm.prank(CHALLENGER);
        vm.expectRevert(abi.encodeWithSelector(IAppealVerificationRound.WrongRound.selector, 2, 1));
        appeal.openBoundAppealRound(params);
    }

    // --- Replay Protection: Duplicate Appeal Rejection ---

    function test_revertDuplicateAppeal() public {
        IAppealVerificationRound.BoundAppealParams memory params = IAppealVerificationRound.BoundAppealParams({
            claimId: claimId,
            parentDisputeId: parentDisputeId,
            parentOutcome: uint8(IDisputeResolution.ChallengedOutcome.TRUE),
            roundIndex: 1,
            appellant: CHALLENGER,
            bondPayer: CHALLENGER,
            bondBeneficiary: BENEFICIARY
        });

        vm.prank(CHALLENGER);
        appeal.openBoundAppealRound(params);

        // Close round after expiration so claim is not currently OPEN
        vm.warp(block.timestamp + 4 days);
        appeal.closeAppealRound(claimId);

        // Attempting to open round 1 again for same parent dispute reverts
        vm.prank(CHALLENGER);
        vm.expectRevert(abi.encodeWithSelector(IAppealVerificationRound.DuplicateAppeal.selector, parentDisputeId, 1));
        appeal.openBoundAppealRound(params);
    }

    // --- Rejection: Expired Appeal Window ---

    function test_revertExpiredAppealWindow() public {
        vm.warp(appealDeadline + 1);

        IAppealVerificationRound.BoundAppealParams memory params = IAppealVerificationRound.BoundAppealParams({
            claimId: claimId,
            parentDisputeId: parentDisputeId,
            parentOutcome: uint8(IDisputeResolution.ChallengedOutcome.TRUE),
            roundIndex: 1,
            appellant: CHALLENGER,
            bondPayer: CHALLENGER,
            bondBeneficiary: BENEFICIARY
        });

        vm.prank(CHALLENGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAppealVerificationRound.AppealWindowExpired.selector,
                claimId,
                block.timestamp,
                appealDeadline
            )
        );
        appeal.openBoundAppealRound(params);
    }

    // --- Bond Disposition: Refund Routes Exact Bond to Beneficiary ---

    function test_refundAppealBondRoutesToBeneficiary() public {
        IAppealVerificationRound.BoundAppealParams memory params = IAppealVerificationRound.BoundAppealParams({
            claimId: claimId,
            parentDisputeId: parentDisputeId,
            parentOutcome: uint8(IDisputeResolution.ChallengedOutcome.TRUE),
            roundIndex: 1,
            appellant: CHALLENGER,
            bondPayer: DELEGATED_PAYER,
            bondBeneficiary: BENEFICIARY
        });

        vm.prank(DELEGATED_PAYER);
        appeal.openBoundAppealRound(params);

        vm.warp(block.timestamp + 4 days);
        appeal.closeAppealRound(claimId);

        uint256 beneficiaryBalBefore = token.balanceOf(BENEFICIARY);

        vm.prank(ADMIN);
        appeal.refundAppealBond(claimId);

        assertEq(token.balanceOf(BENEFICIARY), beneficiaryBalBefore + 1_000e18, "Exact bond refunded to beneficiary");
    }

    // --- Bond Disposition: Slash Routes Exact Bond to Slash Recipient ---

    function test_slashAppealBondRoutesToRecipient() public {
        IAppealVerificationRound.BoundAppealParams memory params = IAppealVerificationRound.BoundAppealParams({
            claimId: claimId,
            parentDisputeId: parentDisputeId,
            parentOutcome: uint8(IDisputeResolution.ChallengedOutcome.TRUE),
            roundIndex: 1,
            appellant: CHALLENGER,
            bondPayer: DELEGATED_PAYER,
            bondBeneficiary: BENEFICIARY
        });

        vm.prank(DELEGATED_PAYER);
        appeal.openBoundAppealRound(params);

        vm.warp(block.timestamp + 4 days);
        appeal.closeAppealRound(claimId);

        uint256 recipientBalBefore = token.balanceOf(SLASH_RECIPIENT);

        vm.prank(ADMIN);
        appeal.slashAppealBond(claimId, SLASH_RECIPIENT);

        assertEq(token.balanceOf(SLASH_RECIPIENT), recipientBalBefore + 1_000e18, "Exact bond slashed to recipient");
    }
}
