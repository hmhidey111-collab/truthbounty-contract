// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EmergencyPauseOrdering} from "../../contracts/governance/libraries/EmergencyPauseOrdering.sol";
import {EmergencyController} from "../../contracts/governance/EmergencyController.sol";

contract EmergencyPauseOrderingTest is Test {
    address internal council = address(0xC0);
    address internal dao = address(0xDA0);
    address internal timelock = address(0x71);
    EmergencyController internal controller;

    function setUp() public {
        controller = new EmergencyController(council, dao, timelock);
    }

    // ── Library: levels ───────────────────────────────────────────────

    function test_L0_allowsAllCanonicalOps() public pure {
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(0, EmergencyPauseOrdering.OP_CLAIM_CREATION));
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(0, EmergencyPauseOrdering.OP_STAKING));
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(0, EmergencyPauseOrdering.OP_VERIFICATION_SUBMISSION));
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(0, EmergencyPauseOrdering.OP_REWARD_DISTRIBUTION));
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(0, EmergencyPauseOrdering.OP_TREASURY_TRANSFER));
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(0, EmergencyPauseOrdering.OP_WITHDRAWAL));
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(0, EmergencyPauseOrdering.OP_GOVERNANCE_RECOVERY));
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(0, EmergencyPauseOrdering.OP_PULL_SETTLED_CLAIM));
    }

    function test_L1_blocksHighRiskOnly() public pure {
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(1, EmergencyPauseOrdering.OP_CLAIM_CREATION));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(1, EmergencyPauseOrdering.OP_STAKING));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(1, EmergencyPauseOrdering.OP_VERIFICATION_SUBMISSION));

        assertTrue(EmergencyPauseOrdering.isOperationAllowed(1, EmergencyPauseOrdering.OP_REWARD_DISTRIBUTION));
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(1, EmergencyPauseOrdering.OP_TREASURY_TRANSFER));
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(1, EmergencyPauseOrdering.OP_WITHDRAWAL));
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(1, EmergencyPauseOrdering.OP_PULL_SETTLED_CLAIM));
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(1, EmergencyPauseOrdering.OP_GOVERNANCE_RECOVERY));
    }

    function test_L2_blocksHighRiskAndFinancial() public pure {
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(2, EmergencyPauseOrdering.OP_CLAIM_CREATION));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(2, EmergencyPauseOrdering.OP_STAKING));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(2, EmergencyPauseOrdering.OP_VERIFICATION_SUBMISSION));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(2, EmergencyPauseOrdering.OP_REWARD_DISTRIBUTION));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(2, EmergencyPauseOrdering.OP_TREASURY_TRANSFER));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(2, EmergencyPauseOrdering.OP_WITHDRAWAL));

        assertTrue(EmergencyPauseOrdering.isOperationAllowed(2, EmergencyPauseOrdering.OP_PULL_SETTLED_CLAIM));
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(2, EmergencyPauseOrdering.OP_GOVERNANCE_RECOVERY));
    }

    function test_L3_onlyGovernanceRecovery() public pure {
        assertTrue(EmergencyPauseOrdering.isOperationAllowed(3, EmergencyPauseOrdering.OP_GOVERNANCE_RECOVERY));

        assertFalse(EmergencyPauseOrdering.isOperationAllowed(3, EmergencyPauseOrdering.OP_CLAIM_CREATION));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(3, EmergencyPauseOrdering.OP_STAKING));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(3, EmergencyPauseOrdering.OP_VERIFICATION_SUBMISSION));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(3, EmergencyPauseOrdering.OP_REWARD_DISTRIBUTION));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(3, EmergencyPauseOrdering.OP_TREASURY_TRANSFER));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(3, EmergencyPauseOrdering.OP_WITHDRAWAL));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(3, EmergencyPauseOrdering.OP_PULL_SETTLED_CLAIM));
        assertFalse(EmergencyPauseOrdering.isOperationAllowed(3, keccak256("unknown_op")));
    }

    function test_invalidLevelReverts() public {
        vm.expectRevert(abi.encodeWithSelector(EmergencyPauseOrdering.InvalidPauseLevel.selector, uint8(4)));
        this.allowedExternal(4, EmergencyPauseOrdering.OP_STAKING);
    }

    function allowedExternal(uint8 level, bytes32 op) external pure returns (bool) {
        return EmergencyPauseOrdering.isOperationAllowed(level, op);
    }

    function test_opIdHashesMatchLegacyStrings() public pure {
        assertEq(EmergencyPauseOrdering.OP_CLAIM_CREATION, keccak256("claim_creation"));
        assertEq(EmergencyPauseOrdering.OP_STAKING, keccak256("staking"));
        assertEq(EmergencyPauseOrdering.OP_VERIFICATION_SUBMISSION, keccak256("verification_submission"));
        assertEq(EmergencyPauseOrdering.OP_REWARD_DISTRIBUTION, keccak256("reward_distribution"));
        assertEq(EmergencyPauseOrdering.OP_TREASURY_TRANSFER, keccak256("treasury_transfer"));
        assertEq(EmergencyPauseOrdering.OP_WITHDRAWAL, keccak256("withdrawal"));
        assertEq(EmergencyPauseOrdering.OP_GOVERNANCE_RECOVERY, keccak256("governance_recovery"));
    }

    function test_cohorts() public pure {
        bytes32[3] memory hr = EmergencyPauseOrdering.highRiskCohort();
        assertEq(hr[0], EmergencyPauseOrdering.OP_CLAIM_CREATION);
        assertEq(hr[1], EmergencyPauseOrdering.OP_STAKING);
        assertEq(hr[2], EmergencyPauseOrdering.OP_VERIFICATION_SUBMISSION);

        bytes32[3] memory fin = EmergencyPauseOrdering.financialCohort();
        assertEq(fin[0], EmergencyPauseOrdering.OP_REWARD_DISTRIBUTION);
        assertEq(fin[1], EmergencyPauseOrdering.OP_TREASURY_TRANSFER);
        assertEq(fin[2], EmergencyPauseOrdering.OP_WITHDRAWAL);
    }

    function test_recoverySteps() public pure {
        assertEq(
            keccak256(bytes(EmergencyPauseOrdering.recoveryStepLabel(1))),
            keccak256(bytes("inventory_risk_surfaces"))
        );
        assertEq(
            keccak256(bytes(EmergencyPauseOrdering.recoveryStepLabel(2))),
            keccak256(bytes("inventory_financial_surfaces"))
        );
        assertEq(
            keccak256(bytes(EmergencyPauseOrdering.recoveryStepLabel(3))),
            keccak256(bytes("finalise_recovery"))
        );
    }

    function test_recoveryStepInvalidReverts() public {
        vm.expectRevert(abi.encodeWithSelector(EmergencyPauseOrdering.InvalidRecoveryStep.selector, uint8(0)));
        this.requireStepExternal(0);

        vm.expectRevert(abi.encodeWithSelector(EmergencyPauseOrdering.InvalidRecoveryStep.selector, uint8(4)));
        this.requireStepExternal(4);
    }

    function requireStepExternal(uint8 step) external pure {
        EmergencyPauseOrdering.requireValidRecoveryStep(step);
    }

    // ── Controller integration ────────────────────────────────────────

    function test_controller_matchesLibrary_L0() public view {
        assertTrue(controller.isOperationAllowed(EmergencyPauseOrdering.OP_CLAIM_CREATION));
        assertTrue(controller.isOperationAllowed(EmergencyPauseOrdering.OP_WITHDRAWAL));
    }

    function test_controller_L1_blocksHighRisk() public {
        vm.prank(council);
        controller.activatePause(1, "drill", bytes32(0));

        assertFalse(controller.isOperationAllowed(EmergencyPauseOrdering.OP_CLAIM_CREATION));
        assertFalse(controller.isOperationAllowed(EmergencyPauseOrdering.OP_STAKING));
        assertTrue(controller.isOperationAllowed(EmergencyPauseOrdering.OP_WITHDRAWAL));
        assertTrue(controller.isOperationAllowed(EmergencyPauseOrdering.OP_PULL_SETTLED_CLAIM));
    }

    function test_controller_L2_blocksFinancial() public {
        vm.prank(council);
        controller.activatePause(2, "financial", bytes32(0));

        assertFalse(controller.isOperationAllowed(EmergencyPauseOrdering.OP_CLAIM_CREATION));
        assertFalse(controller.isOperationAllowed(EmergencyPauseOrdering.OP_WITHDRAWAL));
        assertTrue(controller.isOperationAllowed(EmergencyPauseOrdering.OP_PULL_SETTLED_CLAIM));
    }

    function test_controller_L3_onlyRecovery() public {
        vm.prank(council);
        controller.activatePause(3, "shutdown", bytes32(0));

        assertTrue(controller.isOperationAllowed(EmergencyPauseOrdering.OP_GOVERNANCE_RECOVERY));
        assertFalse(controller.isOperationAllowed(EmergencyPauseOrdering.OP_PULL_SETTLED_CLAIM));
        assertFalse(controller.isOperationAllowed(EmergencyPauseOrdering.OP_CLAIM_CREATION));
    }

    function test_controller_recoveryStepsOrdered() public {
        vm.prank(council);
        controller.activatePause(1, "drill", bytes32(0));

        vm.prank(dao);
        controller.liftPause(bytes32(uint256(1)));

        vm.prank(dao);
        controller.completeRecoveryStep("inventory_risk_surfaces");
        vm.prank(dao);
        controller.completeRecoveryStep("inventory_financial_surfaces");
        vm.prank(dao);
        controller.completeRecoveryStep("finalise_recovery");

        (bool complete,, bool isPaused,) = controller.getRecoveryStatus();
        assertTrue(complete);
        assertFalse(isPaused);
    }

    function test_auth_councilCannotLift() public {
        vm.prank(council);
        controller.activatePause(1, "drill", bytes32(0));

        vm.prank(council);
        vm.expectRevert();
        controller.liftPause(bytes32(0));
    }

    // ── Fuzz ──────────────────────────────────────────────────────────

    function testFuzz_knownOps_matchMatrix(uint8 levelRaw) public pure {
        uint8 level = levelRaw % 4;
        bytes32[8] memory ops = [
            EmergencyPauseOrdering.OP_CLAIM_CREATION,
            EmergencyPauseOrdering.OP_STAKING,
            EmergencyPauseOrdering.OP_VERIFICATION_SUBMISSION,
            EmergencyPauseOrdering.OP_REWARD_DISTRIBUTION,
            EmergencyPauseOrdering.OP_TREASURY_TRANSFER,
            EmergencyPauseOrdering.OP_WITHDRAWAL,
            EmergencyPauseOrdering.OP_GOVERNANCE_RECOVERY,
            EmergencyPauseOrdering.OP_PULL_SETTLED_CLAIM
        ];
        for (uint256 i = 0; i < ops.length; i++) {
            bool allowed = EmergencyPauseOrdering.isOperationAllowed(level, ops[i]);
            if (level == 0) assertTrue(allowed);
            if (level == 3) {
                assertEq(allowed, ops[i] == EmergencyPauseOrdering.OP_GOVERNANCE_RECOVERY);
            }
        }
    }
}
