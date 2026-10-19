// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {ParticipationThresholdTypes} from "../contracts/verification/ParticipationThresholdTypes.sol";
import {ParticipationConfidenceRules} from "../contracts/verification/ParticipationConfidenceRules.sol";
import {FrozenRoundConfigStore} from "../contracts/verification/FrozenRoundConfigStore.sol";
import {ParticipationThresholdEngine} from "../contracts/verification/ParticipationThresholdEngine.sol";

contract ParticipationConfidenceRulesTest is Test {
    FrozenRoundConfigStore internal configStore;
    ParticipationThresholdEngine internal engine;

    ParticipationThresholdTypes.FrozenRoundConfig internal baseConfig;

    function setUp() public {
        configStore = new FrozenRoundConfigStore(address(this));
        engine = new ParticipationThresholdEngine(address(this), configStore);

        baseConfig = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion: 1,
            minVerifierCount: 2,
            minTotalWeight: 200 ether,
            minConfidenceBps: 6000,
            appealMultiplierBps: 10_000
        });
    }

    function _weights(uint256 trueW, uint256 falseW, uint256 count)
        internal
        pure
        returns (ParticipationThresholdTypes.WeightTotals memory)
    {
        return ParticipationThresholdTypes.WeightTotals({
            trueWeight: trueW,
            falseWeight: falseW,
            verifierCount: count
        });
    }

    function test_ConclusiveTrueAtThresholdBoundary() public pure {
        ParticipationThresholdTypes.ThresholdEvaluation memory result = ParticipationConfidenceRules.evaluate(
            ParticipationThresholdTypes.WeightTotals({trueWeight: 600 ether, falseWeight: 400 ether, verifierCount: 2}),
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1,
                minVerifierCount: 2,
                minTotalWeight: 1000 ether,
                minConfidenceBps: 6000,
                appealMultiplierBps: 10_000
            }),
            ParticipationThresholdTypes.RoundKind.FIRST
        );

        assertEq(uint256(result.outcome), uint256(ParticipationThresholdTypes.ClaimOutcome.VERIFIED_TRUE));
        assertEq(uint256(result.reason), uint256(ParticipationThresholdTypes.InconclusiveReason.NONE));
        assertEq(result.confidenceBps, 6000);
    }

    function test_ConfidenceFormula() public pure {
        uint256 confidence = ParticipationConfidenceRules.confidenceBps(200 ether, 300 ether);
        assertEq(confidence, 6666);
    }

    function test_ZeroParticipationReasonAndZeroConfidence() public view {
        ParticipationThresholdTypes.ThresholdEvaluation memory result = ParticipationConfidenceRules.evaluate(
            _weights(0, 0, 0),
            baseConfig,
            ParticipationThresholdTypes.RoundKind.FIRST
        );

        assertEq(uint256(result.outcome), uint256(ParticipationThresholdTypes.ClaimOutcome.INCONCLUSIVE));
        assertEq(uint256(result.reason), uint256(ParticipationThresholdTypes.InconclusiveReason.ZERO_PARTICIPATION));
        assertEq(result.confidenceBps, 0);
    }

    function test_InsufficientCountImmediatelyBelow() public view {
        ParticipationThresholdTypes.ThresholdEvaluation memory below = ParticipationConfidenceRules.evaluate(
            _weights(100 ether, 0, 1),
            baseConfig,
            ParticipationThresholdTypes.RoundKind.FIRST
        );
        assertEq(uint256(below.reason), uint256(ParticipationThresholdTypes.InconclusiveReason.INSUFFICIENT_VERIFIER_COUNT));

        ParticipationThresholdTypes.ThresholdEvaluation memory tie = ParticipationConfidenceRules.evaluate(
            _weights(100 ether, 100 ether, 2),
            baseConfig,
            ParticipationThresholdTypes.RoundKind.FIRST
        );
        assertEq(uint256(tie.reason), uint256(ParticipationThresholdTypes.InconclusiveReason.TIE));
    }

    function test_InsufficientWeightImmediatelyBelow() public view {
        ParticipationThresholdTypes.ThresholdEvaluation memory below = ParticipationConfidenceRules.evaluate(
            _weights(50 ether, 50 ether, 3),
            baseConfig,
            ParticipationThresholdTypes.RoundKind.FIRST
        );
        assertEq(uint256(below.reason), uint256(ParticipationThresholdTypes.InconclusiveReason.INSUFFICIENT_TOTAL_WEIGHT));
    }

    function test_InsufficientConfidenceImmediatelyBelow() public view {
        ParticipationThresholdTypes.ThresholdEvaluation memory below = ParticipationConfidenceRules.evaluate(
            _weights(550 ether, 450 ether, 3),
            baseConfig,
            ParticipationThresholdTypes.RoundKind.FIRST
        );
        assertEq(uint256(below.reason), uint256(ParticipationThresholdTypes.InconclusiveReason.INSUFFICIENT_CONFIDENCE));
        assertEq(below.confidenceBps, 0);
    }

    function test_TieReason() public pure {
        ParticipationThresholdTypes.ThresholdEvaluation memory result = ParticipationConfidenceRules.evaluate(
            _weights(500 ether, 500 ether, 4),
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1,
                minVerifierCount: 1,
                minTotalWeight: 0,
                minConfidenceBps: 0,
                appealMultiplierBps: 10_000
            }),
            ParticipationThresholdTypes.RoundKind.FIRST
        );
        assertEq(uint256(result.reason), uint256(ParticipationThresholdTypes.InconclusiveReason.TIE));
        assertEq(result.confidenceBps, 0);
    }

    function test_AppealMultiplierScalesMinimums() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory appealConfig = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion: 1,
            minVerifierCount: 2,
            minTotalWeight: 200 ether,
            minConfidenceBps: 6000,
            appealMultiplierBps: 15_000
        });

        ParticipationThresholdTypes.ThresholdEvaluation memory first = ParticipationConfidenceRules.evaluate(
            _weights(700 ether, 300 ether, 2),
            appealConfig,
            ParticipationThresholdTypes.RoundKind.FIRST
        );
        assertTrue(first.effectiveMinVerifierCount == 2);
        assertTrue(first.effectiveMinTotalWeight == 200 ether);

        ParticipationThresholdTypes.ThresholdEvaluation memory appeal = ParticipationConfidenceRules.evaluate(
            _weights(700 ether, 300 ether, 2),
            appealConfig,
            ParticipationThresholdTypes.RoundKind.APPEAL
        );
        assertEq(appeal.effectiveMinVerifierCount, 3);
        assertEq(appeal.effectiveMinTotalWeight, 300 ether);
        assertEq(uint256(appeal.reason), uint256(ParticipationThresholdTypes.InconclusiveReason.INSUFFICIENT_VERIFIER_COUNT));
    }

    function test_FrozenConfigUsedByEngine() public {
        configStore.freezeRoundConfig(1, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig);

        ParticipationThresholdTypes.ThresholdEvaluation memory evaluation = engine.evaluateRound(
            1,
            ParticipationThresholdTypes.RoundKind.FIRST,
            _weights(700 ether, 300 ether, 3)
        );

        assertEq(uint256(evaluation.outcome), uint256(ParticipationThresholdTypes.ClaimOutcome.VERIFIED_TRUE));
        assertEq(evaluation.confidenceBps, 7000);
        assertTrue(engine.isEvaluated(configStore.roundId(1, ParticipationThresholdTypes.RoundKind.FIRST)));
    }

    function test_CannotRefreezeRound() public {
        configStore.freezeRoundConfig(7, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig);
        vm.expectRevert(abi.encodeWithSelector(FrozenRoundConfigStore.RoundAlreadyFrozen.selector, configStore.roundId(7, ParticipationThresholdTypes.RoundKind.FIRST)));
        configStore.freezeRoundConfig(7, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig);
    }

    function test_InvalidConfidenceBpsReverts() public {
        ParticipationThresholdTypes.FrozenRoundConfig memory bad = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion: 1,
            minVerifierCount: 1,
            minTotalWeight: 0,
            minConfidenceBps: 10_001,
            appealMultiplierBps: 10_000
        });

        vm.expectRevert(abi.encodeWithSelector(ParticipationConfidenceRules.InvalidConfidenceBps.selector, 10_001));
        configStore.freezeRoundConfig(2, ParticipationThresholdTypes.RoundKind.FIRST, bad);
    }
}
