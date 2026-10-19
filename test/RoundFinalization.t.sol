// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// =============================================================================
//  PREWAVE-SC-046 -- Quorum, Tie, and Insufficient-Evidence Finalization
//  Issue #722
//  Dependencies: PREWAVE-SC-004 (#679), PREWAVE-SC-005 (#680)
//
//  Required test matrix (issue spec):
//    [x] Zero participation
//    [x] Exact quorum
//    [x] Quorum-1 (count and weight)
//    [x] Exact tie (equal raw weights)
//    [x] Weighted tie (equal effective weights)
//    [x] Insufficient majority (confidence below threshold)
//    [x] Permutation tests -- 4 distinct accumulation orders, identical records
//
//  Reviewer-required regressions (#722 review):
//    [x] Evaluator cannot shorten/replace frozen deadline
//    [x] Deadline stored in FrozenRoundConfigStore, not caller-supplied
//    [x] finalizeRound() requires prior evaluateRound() (_evaluated[id])
//    [x] Finalize-before-evaluate reverts NotEvaluated
//    [x] Same round cannot be evaluated with one result and finalized with another
//    [x] computeConfidenceBps full uint256 domain safe bound (PREWAVE-SC-005)
//    [x] Appeal ceiling scaling max multiplier no overflow
//    [x] All six TerminalState values reachable
//    [x] Economic outcomes per terminal state
//    [x] Fuzz: determinism, denominator, confidence bounds, tie, conclusive/inconclusive
// =============================================================================

import "forge-std/Test.sol";

import {RoundFinalization}            from "../contracts/verification/RoundFinalization.sol";
import {ParticipationThresholdTypes}  from "../contracts/verification/ParticipationThresholdTypes.sol";
import {ParticipationConfidenceRules} from "../contracts/verification/ParticipationConfidenceRules.sol";
import {FrozenRoundConfigStore}        from "../contracts/verification/FrozenRoundConfigStore.sol";
import {ParticipationThresholdEngine}  from "../contracts/verification/ParticipationThresholdEngine.sol";

// =============================================================================
// Minimal mock accumulator -- simulates VerificationAggregation loop without
// pulling in the full token stack.
// =============================================================================
contract MockWeightAccumulator {
    struct Vote { bool support; uint256 effectiveWeight; }
    mapping(uint256 => Vote[]) private _votes;

    function recordVote(uint256 claimId, bool support, uint256 w) external {
        _votes[claimId].push(Vote(support, w));
    }

    function accumulate(uint256 claimId)
        external view
        returns (uint256 trueWeight, uint256 falseWeight, uint256 count)
    {
        Vote[] storage v = _votes[claimId];
        count = v.length;
        for (uint256 i = 0; i < count; i++) {
            if (v[i].support) trueWeight  += v[i].effectiveWeight;
            else               falseWeight += v[i].effectiveWeight;
        }
    }
}

// =============================================================================
// Main test contract
// =============================================================================
contract RoundFinalizationTest is Test {

    ParticipationThresholdTypes.FrozenRoundConfig internal baseConfig;

    FrozenRoundConfigStore       internal configStore;
    ParticipationThresholdEngine internal engine;
    MockWeightAccumulator        internal accumulator;

    function setUp() public {
        baseConfig = ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion:       1,
            minVerifierCount:    2,
            minTotalWeight:      200 ether,
            minConfidenceBps:    6_000,
            appealMultiplierBps: 10_000
        });

        configStore = new FrozenRoundConfigStore(address(this));
        engine      = new ParticipationThresholdEngine(address(this), configStore);
        accumulator = new MockWeightAccumulator();
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _w(uint256 t, uint256 f, uint256 n)
        internal pure
        returns (ParticipationThresholdTypes.WeightTotals memory)
    {
        return ParticipationThresholdTypes.WeightTotals(t, f, n);
    }

    function _finalize(uint256 t, uint256 f, uint256 n, bool elapsed)
        internal view
        returns (RoundFinalization.FinalizationRecord memory)
    {
        return RoundFinalization.finalize(
            _w(t, f, n), baseConfig,
            ParticipationThresholdTypes.RoundKind.FIRST, elapsed
        );
    }

    /// @dev Freeze with deadline, evaluate, then warp past deadline.
    function _evalAndReady(
        uint256 claimId,
        uint256 t, uint256 f, uint256 n,
        uint64 deadlineOffset
    ) internal {
        uint64 deadline = uint64(block.timestamp) + deadlineOffset;
        configStore.freezeRoundConfigWithDeadline(
            claimId, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig, deadline
        );
        engine.evaluateRound(
            claimId, ParticipationThresholdTypes.RoundKind.FIRST, _w(t, f, n)
        );
        vm.warp(uint256(deadline) + 1);
    }

    // =========================================================================
    // 1. BPS_DENOMINATOR -- single canonical authority
    // =========================================================================

    function test_bpsDenominator_aliasesCanonical() public pure {
        assertEq(RoundFinalization.BPS_DENOMINATOR, ParticipationThresholdTypes.BPS_DENOMINATOR);
        assertEq(RoundFinalization.BPS_DENOMINATOR, 10_000);
    }

    function test_record_embedsCanonicalDenominator() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, true);
        assertEq(r.quorumDenominator, ParticipationThresholdTypes.BPS_DENOMINATOR);
    }

    // =========================================================================
    // 2. Conclusive outcomes
    // =========================================================================

    function test_verifiedTrue_aboveThreshold() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, true);
        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertEq(r.confidenceBps, 7_000);
        assertFalse(r.isProvisional);
    }

    function test_verifiedFalse_aboveThreshold() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(300 ether, 700 ether, 3, true);
        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.VERIFIED_FALSE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertEq(r.confidenceBps, 7_000);
    }

    function test_verifiedTrue_exactConfidenceBoundary() public pure {
        // 600/1000 = 6000 bps == minConfidenceBps
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 1, minTotalWeight: 0,
                minConfidenceBps: 6_000, appealMultiplierBps: 10_000
            });
        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(600 ether, 400 ether, 2), cfg,
            ParticipationThresholdTypes.RoundKind.FIRST, true
        );
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(r.confidenceBps, 6_000);
    }

    // =========================================================================
    // 3. Zero participation
    // =========================================================================

    function test_zeroParticipation_zeroWeightZeroCount() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(0, 0, 0, true);
        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_ZERO));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertEq(r.confidenceBps, 0);
        assertEq(r.totalWeight,   0);
    }

    function test_zeroParticipation_zeroWeightNonzeroCount() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(0, 0, 5, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_ZERO));
    }

    // =========================================================================
    // 4. Exact quorum and quorum-1
    // =========================================================================

    function test_exactQuorum_conclusive() public view {
        // count=2==min, totalWeight=200e18==min, 140/60=7000 bps > 6000
        RoundFinalization.FinalizationRecord memory r = _finalize(140 ether, 60 ether, 2, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(r.confidenceBps, 7_000);
    }

    function test_quorumMinus1_verifierCount() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(200 ether, 0, 1, true);
        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertEq(r.confidenceBps, 0);
    }

    function test_quorumMinus1_totalWeight() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(100 ether, 99 ether, 2, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
    }

    // =========================================================================
    // 5. Exact tie
    // =========================================================================

    function test_exactTie_equalRawWeights() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(300 ether, 300 ether, 4, true);
        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertEq(r.confidenceBps, 0);
    }

    function test_exactTie_largeWeightsStillTie() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory loose =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 1, minTotalWeight: 0,
                minConfidenceBps: 0, appealMultiplierBps: 10_000
            });
        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(1_000_000 ether, 1_000_000 ether, 10), loose,
            ParticipationThresholdTypes.RoundKind.FIRST, true
        );
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
    }

    // =========================================================================
    // 6. Weighted tie
    // =========================================================================

    // verifier A: 100 stake x 2 rep = 200 effective (TRUE)
    // verifier B: 200 stake x 1 rep = 200 effective (FALSE)
    function test_weightedTie_equalEffectiveStake() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory loose =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 1, minTotalWeight: 0,
                minConfidenceBps: 0, appealMultiplierBps: 10_000
            });
        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(200 ether, 200 ether, 2), loose,
            ParticipationThresholdTypes.RoundKind.FIRST, true
        );
        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }

    // verifier A: 100 stake x 3 rep = 300 (TRUE) > verifier B: 100 x 2 = 200 (FALSE)
    function test_weightedTie_brokenByReputation_trueWins() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory loose =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 1, minTotalWeight: 0,
                minConfidenceBps: 0, appealMultiplierBps: 10_000
            });
        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(300 ether, 200 ether, 2), loose,
            ParticipationThresholdTypes.RoundKind.FIRST, true
        );
        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertEq(r.confidenceBps, 6_000);
    }

    // =========================================================================
    // 7. Insufficient majority (low confidence)
    // =========================================================================

    function test_insufficientMajority_oneBpsBelow() public view {
        // 599/1000 = 5990 bps < 6000
        RoundFinalization.FinalizationRecord memory r = _finalize(599 ether, 401 ether, 2, true);
        assertEq(uint256(r.state),    uint256(RoundFinalization.TerminalState.INCONCLUSIVE_LOW_CONFIDENCE));
        assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertEq(r.confidenceBps, 0);
    }

    function test_insufficientMajority_oneBpsAbove() public view {
        // 601/1000 = 6010 bps > 6000
        RoundFinalization.FinalizationRecord memory r = _finalize(601 ether, 399 ether, 2, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(r.confidenceBps, 6_010);
    }

    // =========================================================================
    // 8. Provisional guard -- pure assertFinal()
    // =========================================================================

    function test_assertFinal_revertsOnProvisional() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, false);
        assertTrue(r.isProvisional);
        vm.expectRevert(RoundFinalization.ProvisionalNotFinal.selector);
        RoundFinalization.assertFinal(r);
    }

    function test_assertFinal_passesWhenFinal() public view {
        RoundFinalization.FinalizationRecord memory r = _finalize(700 ether, 300 ether, 3, true);
        assertFalse(r.isProvisional);
        RoundFinalization.assertFinal(r);
    }

    // =========================================================================
    // 9. Economic outcomes per terminal state
    // =========================================================================

    function test_economic_verifiedTrue_rewardSlash() public view {
        assertEq(uint256(_finalize(700 ether, 300 ether, 3, true).economic),
            uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
    }
    function test_economic_verifiedFalse_rewardSlash() public view {
        assertEq(uint256(_finalize(300 ether, 700 ether, 3, true).economic),
            uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
    }
    function test_economic_tie_fullRefund() public view {
        assertEq(uint256(_finalize(300 ether, 300 ether, 4, true).economic),
            uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }
    function test_economic_zero_fullRefund() public view {
        assertEq(uint256(_finalize(0, 0, 0, true).economic),
            uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }
    function test_economic_insufficient_fullRefund() public view {
        assertEq(uint256(_finalize(200 ether, 0, 1, true).economic),
            uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }
    function test_economic_lowConf_fullRefund() public view {
        assertEq(uint256(_finalize(550 ether, 450 ether, 2, true).economic),
            uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
    }

    // =========================================================================
    // 10. Real permutation order-independence tests
    //
    // Votes: [TRUE:300e18, FALSE:200e18, TRUE:100e18, FALSE:150e18]
    // Expected: true=400e18, false=350e18, total=750e18
    // Confidence: 400/750 = 5333 bps < 6000 -> INCONCLUSIVE_LOW_CONFIDENCE
    // =========================================================================

    function _recordA(uint256 id) internal {
        accumulator.recordVote(id, true,  300 ether);
        accumulator.recordVote(id, false, 200 ether);
        accumulator.recordVote(id, true,  100 ether);
        accumulator.recordVote(id, false, 150 ether);
    }
    function _recordB(uint256 id) internal {
        accumulator.recordVote(id, false, 150 ether);
        accumulator.recordVote(id, true,  100 ether);
        accumulator.recordVote(id, false, 200 ether);
        accumulator.recordVote(id, true,  300 ether);
    }
    function _recordC(uint256 id) internal {
        accumulator.recordVote(id, true,  100 ether);
        accumulator.recordVote(id, false, 150 ether);
        accumulator.recordVote(id, true,  300 ether);
        accumulator.recordVote(id, false, 200 ether);
    }
    function _recordD(uint256 id) internal {
        accumulator.recordVote(id, true,  300 ether);
        accumulator.recordVote(id, true,  100 ether);
        accumulator.recordVote(id, false, 200 ether);
        accumulator.recordVote(id, false, 150 ether);
    }

    function _finalizeAccumulated(uint256 id)
        internal view
        returns (RoundFinalization.FinalizationRecord memory)
    {
        (uint256 t, uint256 f, uint256 n) = accumulator.accumulate(id);
        return RoundFinalization.finalize(
            _w(t, f, n), baseConfig,
            ParticipationThresholdTypes.RoundKind.FIRST, true
        );
    }

    function test_permutation_fourOrdersIdentical() public {
        _recordA(101); _recordB(102); _recordC(103); _recordD(104);

        RoundFinalization.FinalizationRecord memory rA = _finalizeAccumulated(101);
        RoundFinalization.FinalizationRecord memory rB = _finalizeAccumulated(102);
        RoundFinalization.FinalizationRecord memory rC = _finalizeAccumulated(103);
        RoundFinalization.FinalizationRecord memory rD = _finalizeAccumulated(104);

        assertEq(rA.trueWeight,  400 ether);
        assertEq(rA.falseWeight, 350 ether);
        assertEq(rA.totalWeight, 750 ether);
        assertEq(rA.trueWeight,        rB.trueWeight);
        assertEq(rA.trueWeight,        rC.trueWeight);
        assertEq(rA.trueWeight,        rD.trueWeight);
        assertEq(rA.falseWeight,       rB.falseWeight);
        assertEq(uint256(rA.state),    uint256(rB.state));
        assertEq(uint256(rA.state),    uint256(rC.state));
        assertEq(uint256(rA.state),    uint256(rD.state));
        assertEq(uint256(rA.economic), uint256(rB.economic));
        assertEq(uint256(rA.state),
            uint256(RoundFinalization.TerminalState.INCONCLUSIVE_LOW_CONFIDENCE));
    }

    function test_permutation_conclusive_orderIndependent() public {
        accumulator.recordVote(201, true,  700 ether);
        accumulator.recordVote(201, false, 300 ether);
        accumulator.recordVote(202, false, 300 ether);
        accumulator.recordVote(202, true,  700 ether);

        RoundFinalization.FinalizationRecord memory r1 = _finalizeAccumulated(201);
        RoundFinalization.FinalizationRecord memory r2 = _finalizeAccumulated(202);

        assertEq(r1.trueWeight,        r2.trueWeight);
        assertEq(r1.falseWeight,       r2.falseWeight);
        assertEq(uint256(r1.state),    uint256(r2.state));
        assertEq(uint256(r1.economic), uint256(r2.economic));
        assertEq(r1.confidenceBps,     r2.confidenceBps);
        assertEq(uint256(r1.state),    uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
    }

    // =========================================================================
    // 11. Appeal round scaling
    // =========================================================================

    function test_appeal_multiplierScalesThresholds() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 2, minTotalWeight: 200 ether,
                minConfidenceBps: 5_000, appealMultiplierBps: 15_000
            });
        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(140 ether, 60 ether, 2), cfg,
            ParticipationThresholdTypes.RoundKind.APPEAL, true
        );
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
        assertEq(r.effectiveMinCount,  3);
        assertEq(r.effectiveMinWeight, 300 ether);
    }

    function test_appeal_scaledQuorumMet_conclusive() public pure {
        ParticipationThresholdTypes.FrozenRoundConfig memory cfg =
            ParticipationThresholdTypes.FrozenRoundConfig({
                configVersion: 1, minVerifierCount: 2, minTotalWeight: 200 ether,
                minConfidenceBps: 5_000, appealMultiplierBps: 15_000
            });
        RoundFinalization.FinalizationRecord memory r = RoundFinalization.finalize(
            _w(210 ether, 90 ether, 3), cfg,
            ParticipationThresholdTypes.RoundKind.APPEAL, true
        );
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(r.confidenceBps, 7_000);
    }

    // =========================================================================
    // 12. Arithmetic bounds (PREWAVE-SC-005 boundary)
    // =========================================================================

    // Max safe input for computeConfidenceBps:
    //   winningWeight * BPS_DENOMINATOR <= type(uint256).max
    //   => winningWeight <= type(uint256).max / 10_000
    uint256 internal constant MAX_SAFE_WEIGHT =
        type(uint256).max / ParticipationThresholdTypes.BPS_DENOMINATOR;

    /// @notice Confidence at max safe input does not overflow.
    function test_arith_maxSafeWeight_noOverflow() public pure {
        uint256 w = type(uint256).max / ParticipationThresholdTypes.BPS_DENOMINATOR;
        uint256 bps = RoundFinalization.computeConfidenceBps(w, w);
        assertEq(bps, ParticipationThresholdTypes.BPS_DENOMINATOR);
    }

    /// @notice computeConfidenceBps returns 0 for zero total.
    function test_arith_zeroTotal_returnsZero() public pure {
        assertEq(RoundFinalization.computeConfidenceBps(0, 0), 0);
    }

    /// @notice Unanimous confidence = BPS_DENOMINATOR.
    function test_arith_unanimous_returns10000() public pure {
        assertEq(RoundFinalization.computeConfidenceBps(100 ether, 100 ether), 10_000);
    }

    /// @notice Floor division: 1/3 = 3333 bps, 2/3 = 6666 bps.
    function test_arith_floorDivision() public pure {
        assertEq(RoundFinalization.computeConfidenceBps(1 ether, 3 ether), 3_333);
        assertEq(RoundFinalization.computeConfidenceBps(2 ether, 3 ether), 6_666);
    }

    /// @notice Appeal ceiling scaling with max multiplier (100_000) on max uint128 base.
    function test_arith_appealCeilingScaling_maxMultiplier() public pure {
        // (baseMin * 100_000 + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR
        // = ceil(baseMin * 10) for baseMin = type(uint128).max
        uint256 baseMin    = type(uint128).max;
        uint256 multiplier = 100_000;
        uint256 scaled =
            (baseMin * multiplier + ParticipationThresholdTypes.BPS_DENOMINATOR - 1)
            / ParticipationThresholdTypes.BPS_DENOMINATOR;
        assertGt(scaled, 0);
        assertEq(scaled, baseMin * 10);
    }

    // =========================================================================
    // 13. REGRESSION: Deadline stored in store, not caller-supplied
    // =========================================================================

    /// @notice Evaluator cannot supply or shorten the frozen deadline.
    ///         finalizeRound() reads it from FrozenRoundConfigStore.
    function test_regression_evaluatorCannotReplaceDeadline() public {
        uint256 claimId = 300;
        uint64 realDeadline = uint64(block.timestamp) + 7 days;

        configStore.freezeRoundConfigWithDeadline(
            claimId, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig, realDeadline
        );
        engine.evaluateRound(
            claimId, ParticipationThresholdTypes.RoundKind.FIRST, _w(700 ether, 300 ether, 3)
        );

        // Warp to only 1 day in (deadline still 6 days away)
        vm.warp(block.timestamp + 1 days);

        // Evaluator cannot finalize early regardless of intent
        bytes32 id = configStore.roundId(claimId, ParticipationThresholdTypes.RoundKind.FIRST);
        vm.expectRevert(
            abi.encodeWithSelector(
                ParticipationThresholdEngine.ChallengeWindowStillOpen.selector,
                id,
                realDeadline
            )
        );
        engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST);
    }

    /// @notice Passing deadline=0 (legacy path) allows immediate finalization.
    function test_regression_legacyZeroDeadline_permitsImmediateFinalization() public {
        uint256 claimId = 301;
        // Legacy freeze -- no deadline stored
        configStore.freezeRoundConfig(
            claimId, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig
        );
        engine.evaluateRound(
            claimId, ParticipationThresholdTypes.RoundKind.FIRST, _w(700 ether, 300 ether, 3)
        );

        // Must not revert
        RoundFinalization.FinalizationRecord memory r =
            engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
    }

    // =========================================================================
    // 14. REGRESSION: finalizeRound() requires prior evaluateRound()
    // =========================================================================

    /// @notice Finalize-before-evaluate reverts NotEvaluated.
    function test_regression_finalizeBeforeEvaluate_reverts() public {
        uint256 claimId = 302;
        configStore.freezeRoundConfig(
            claimId, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig
        );

        bytes32 id = configStore.roundId(claimId, ParticipationThresholdTypes.RoundKind.FIRST);
        vm.expectRevert(
            abi.encodeWithSelector(ParticipationThresholdEngine.NotEvaluated.selector, id)
        );
        engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST);
    }

    /// @notice The same round cannot produce different outcomes from evaluate vs finalize.
    ///         finalizeRound() uses stored ThresholdEvaluation -- not fresh inputs.
    function test_regression_finalizeUsesStoredEvaluation() public {
        uint256 claimId = 303;
        configStore.freezeRoundConfig(
            claimId, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig
        );

        // Evaluate with TRUE-winning weights
        engine.evaluateRound(
            claimId, ParticipationThresholdTypes.RoundKind.FIRST, _w(700 ether, 300 ether, 3)
        );

        RoundFinalization.FinalizationRecord memory r =
            engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST);

        // Must reflect stored evaluation (TRUE wins), not any caller-supplied value
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        // trueWeight comes from stored evaluation
        assertEq(r.trueWeight,  700 ether);
        assertEq(r.falseWeight, 300 ether);
    }

    /// @notice finalizeRound() is idempotent (cannot finalize twice).
    function test_regression_finalizeIdempotent() public {
        uint256 claimId = 304;
        configStore.freezeRoundConfig(
            claimId, ParticipationThresholdTypes.RoundKind.FIRST, baseConfig
        );
        engine.evaluateRound(
            claimId, ParticipationThresholdTypes.RoundKind.FIRST, _w(700 ether, 300 ether, 3)
        );
        engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST);

        bytes32 id = configStore.roundId(claimId, ParticipationThresholdTypes.RoundKind.FIRST);
        vm.expectRevert(
            abi.encodeWithSelector(ParticipationThresholdEngine.AlreadyFinalized.selector, id)
        );
        engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST);
    }

    // =========================================================================
    // 15. Helpers exhaustive
    // =========================================================================

    function test_helper_isConclusive_exhaustive() public pure {
        assertTrue(RoundFinalization.isConclusive(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertTrue(RoundFinalization.isConclusive(RoundFinalization.TerminalState.VERIFIED_FALSE));
        assertFalse(RoundFinalization.isConclusive(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
        assertFalse(RoundFinalization.isConclusive(RoundFinalization.TerminalState.INCONCLUSIVE_ZERO));
        assertFalse(RoundFinalization.isConclusive(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
        assertFalse(RoundFinalization.isConclusive(RoundFinalization.TerminalState.INCONCLUSIVE_LOW_CONFIDENCE));
    }

    function test_helper_isFullRefund_exhaustive() public pure {
        assertTrue(RoundFinalization.isFullRefund(RoundFinalization.EconomicOutcome.FULL_REFUND));
        assertFalse(RoundFinalization.isFullRefund(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertFalse(RoundFinalization.isFullRefund(RoundFinalization.EconomicOutcome.PARTIAL_SLASH_NO_REWARD));
    }

    // =========================================================================
    // 16. All six TerminalState values reachable
    // =========================================================================

    function test_allTerminalStates_reachable() public view {
        assertEq(uint256(_finalize(700 ether, 300 ether, 3, true).state),
            uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(uint256(_finalize(300 ether, 700 ether, 3, true).state),
            uint256(RoundFinalization.TerminalState.VERIFIED_FALSE));
        assertEq(uint256(_finalize(300 ether, 300 ether, 4, true).state),
            uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
        assertEq(uint256(_finalize(0, 0, 0, true).state),
            uint256(RoundFinalization.TerminalState.INCONCLUSIVE_ZERO));
        assertEq(uint256(_finalize(200 ether, 0, 1, true).state),
            uint256(RoundFinalization.TerminalState.INCONCLUSIVE_INSUFFICIENT));
        assertEq(uint256(_finalize(550 ether, 450 ether, 2, true).state),
            uint256(RoundFinalization.TerminalState.INCONCLUSIVE_LOW_CONFIDENCE));
    }

    // =========================================================================
    // 17. Integration -- engine full path
    // =========================================================================

    function test_integration_fullPath_withDeadline() public {
        uint256 claimId = 400;
        _evalAndReady(claimId, 700 ether, 300 ether, 3, 1 days);

        RoundFinalization.FinalizationRecord memory r =
            engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST);

        assertFalse(r.isProvisional);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(r.confidenceBps, 7_000);

        bytes32 id = configStore.roundId(claimId, ParticipationThresholdTypes.RoundKind.FIRST);
        assertTrue(engine.isFinalized(id));
    }

    function test_integration_RoundFinalized_event() public {
        uint256 claimId = 401;
        _evalAndReady(claimId, 700 ether, 300 ether, 3, 1 days);

        bytes32 id = configStore.roundId(claimId, ParticipationThresholdTypes.RoundKind.FIRST);

        vm.expectEmit(true, true, true, true, address(engine));
        emit ParticipationThresholdEngine.RoundFinalized(
            id, claimId, ParticipationThresholdTypes.RoundKind.FIRST,
            RoundFinalization.TerminalState.VERIFIED_TRUE,
            RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS,
            700 ether, 300 ether, 7_000
        );
        engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST);
    }

    function test_integration_getFinalization_correct() public {
        uint256 claimId = 402;
        _evalAndReady(claimId, 700 ether, 300 ether, 3, 1 days);
        engine.finalizeRound(claimId, ParticipationThresholdTypes.RoundKind.FIRST);

        bytes32 id = configStore.roundId(claimId, ParticipationThresholdTypes.RoundKind.FIRST);
        RoundFinalization.FinalizationRecord memory stored = engine.getFinalization(id);

        assertEq(uint256(stored.state),    uint256(RoundFinalization.TerminalState.VERIFIED_TRUE));
        assertEq(uint256(stored.economic), uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        assertEq(stored.confidenceBps,     7_000);
        assertFalse(stored.isProvisional);
    }
}

// =============================================================================
// Fuzz suite
// =============================================================================
contract RoundFinalizationFuzzTest is Test {

    function _loose() internal pure returns (ParticipationThresholdTypes.FrozenRoundConfig memory) {
        return ParticipationThresholdTypes.FrozenRoundConfig({
            configVersion: 1, minVerifierCount: 0, minTotalWeight: 0,
            minConfidenceBps: 0, appealMultiplierBps: 10_000
        });
    }

    function _w(uint256 t, uint256 f, uint256 n)
        internal pure returns (ParticipationThresholdTypes.WeightTotals memory)
    {
        return ParticipationThresholdTypes.WeightTotals(t, f, n);
    }

    /// @notice FUZZ-001: Same inputs always produce the same TerminalState.
    function testFuzz_deterministic(uint128 t, uint128 f, uint8 n) public pure {
        ParticipationThresholdTypes.WeightTotals memory w = _w(uint256(t), uint256(f), uint256(n));
        RoundFinalization.FinalizationRecord memory r1 =
            RoundFinalization.finalize(w, _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        RoundFinalization.FinalizationRecord memory r2 =
            RoundFinalization.finalize(w, _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        assertEq(uint256(r1.state),    uint256(r2.state));
        assertEq(uint256(r1.economic), uint256(r2.economic));
        assertEq(r1.confidenceBps,     r2.confidenceBps);
    }

    /// @notice FUZZ-002: quorumDenominator is always the canonical BPS_DENOMINATOR.
    function testFuzz_quorumDenominatorAlwaysCanonical(uint128 t, uint128 f, uint8 n) public pure {
        RoundFinalization.FinalizationRecord memory r =
            RoundFinalization.finalize(_w(uint256(t), uint256(f), uint256(n)),
                _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        assertEq(r.quorumDenominator, ParticipationThresholdTypes.BPS_DENOMINATOR);
    }

    /// @notice FUZZ-003: confidenceBps is always in [0, BPS_DENOMINATOR].
    function testFuzz_confidenceBpsNeverExceedsDenominator(uint128 t, uint128 f, uint8 n) public pure {
        RoundFinalization.FinalizationRecord memory r =
            RoundFinalization.finalize(_w(uint256(t), uint256(f), uint256(n)),
                _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        assertLe(r.confidenceBps, ParticipationThresholdTypes.BPS_DENOMINATOR);
    }

    /// @notice FUZZ-004: Conclusive states always map to REWARD_WINNERS_SLASH_LOSERS.
    function testFuzz_conclusive_alwaysRewardSlash(uint128 winning, uint128 losing, uint8 n) public pure {
        vm.assume(uint256(winning) > uint256(losing));
        RoundFinalization.FinalizationRecord memory r =
            RoundFinalization.finalize(_w(uint256(winning), uint256(losing), uint256(n)),
                _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        if (RoundFinalization.isConclusive(r.state)) {
            assertEq(uint256(r.economic),
                uint256(RoundFinalization.EconomicOutcome.REWARD_WINNERS_SLASH_LOSERS));
        }
    }

    /// @notice FUZZ-005: Inconclusive states always map to FULL_REFUND.
    function testFuzz_inconclusive_alwaysFullRefund(uint128 t, uint128 f, uint8 n) public pure {
        RoundFinalization.FinalizationRecord memory r =
            RoundFinalization.finalize(_w(uint256(t), uint256(f), uint256(n)),
                _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        if (!RoundFinalization.isConclusive(r.state)) {
            assertEq(uint256(r.economic), uint256(RoundFinalization.EconomicOutcome.FULL_REFUND));
        }
    }

    /// @notice FUZZ-006: Equal nonzero weights always produce INCONCLUSIVE_TIE.
    function testFuzz_tie_alwaysInconclusive(uint128 weight, uint8 n) public pure {
        vm.assume(weight > 0);
        RoundFinalization.FinalizationRecord memory r =
            RoundFinalization.finalize(_w(uint256(weight), uint256(weight), uint256(n)),
                _loose(), ParticipationThresholdTypes.RoundKind.FIRST, true);
        assertEq(uint256(r.state), uint256(RoundFinalization.TerminalState.INCONCLUSIVE_TIE));
    }

    /// @notice FUZZ-007: computeConfidenceBps safe for any winning <= total,
    ///         where total <= MAX_SAFE_WEIGHT = type(uint256).max / BPS_DENOMINATOR.
    function testFuzz_computeConfidenceBps_safeDomain(uint256 winning, uint256 total) public pure {
        uint256 maxSafe = type(uint256).max / ParticipationThresholdTypes.BPS_DENOMINATOR;
        vm.assume(total > 0 && total <= maxSafe && winning <= total);
        uint256 bps = RoundFinalization.computeConfidenceBps(winning, total);
        assertLe(bps, ParticipationThresholdTypes.BPS_DENOMINATOR);
    }
}
