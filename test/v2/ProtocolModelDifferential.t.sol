// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/v2/interfaces/IV2Types.sol";
import "../../contracts/v2/libraries/V2Lifecycle.sol";
import "../../contracts/v2/libraries/ProtocolModel.sol";
import "../../contracts/VerificationAggregator.sol";

contract ProtocolModelVerificationSource is IVerificationSource {
    struct Vote {
        bool voted;
        bool support;
        uint256 effectiveStake;
    }

    mapping(uint256 => address[]) internal voters;
    mapping(uint256 => mapping(address => Vote)) internal votes;

    function addVote(uint256 claimId, address verifier, bool voted, bool support, uint256 effectiveStake) external {
        voters[claimId].push(verifier);
        votes[claimId][verifier] = Vote(voted, support, effectiveStake);
    }

    function getClaimVoterCount(uint256 claimId) external view returns (uint256) {
        return voters[claimId].length;
    }

    function getClaimVoterAt(uint256 claimId, uint256 index) external view returns (address) {
        return voters[claimId][index];
    }

    function getVoteData(uint256 claimId, address verifier)
        external
        view
        returns (bool voted, bool support, uint256 effectiveStake)
    {
        Vote memory vote = votes[claimId][verifier];
        return (vote.voted, vote.support, vote.effectiveStake);
    }
}

contract ProtocolModelHarness {
    function splitInvalid(uint8 roundingPolicy) external pure returns (uint256) {
        return ProtocolModel.splitAmount(100, 5000, roundingPolicy);
    }
}

contract ProtocolModelDifferentialTest is Test {
    ProtocolModelHarness internal harness;

    function setUp() public {
        harness = new ProtocolModelHarness();
    }

    function test_claimLifecycle_matches_reference_model() public {
        for (uint256 i = 0; i <= uint256(type(IV2Types.ClaimState).max); ++i) {
            IV2Types.ClaimState current = IV2Types.ClaimState(i);
            for (uint256 j = 0; j <= uint256(type(IV2Types.ClaimState).max); ++j) {
                IV2Types.ClaimState next = IV2Types.ClaimState(j);
                bool model = ProtocolModel.isValidClaimTransition(current, next);
                bool actual = V2Lifecycle.isValidClaimTransition(current, next);
                assertEq(actual, model, "claim lifecycle mismatch");
            }
        }
    }

    function test_evidenceLifecycle_matches_reference_model() public {
        for (uint256 i = 0; i <= uint256(type(IV2Types.EvidenceStatus).max); ++i) {
            IV2Types.EvidenceStatus current = IV2Types.EvidenceStatus(i);
            for (uint256 j = 0; j <= uint256(type(IV2Types.EvidenceStatus).max); ++j) {
                IV2Types.EvidenceStatus next = IV2Types.EvidenceStatus(j);
                bool model = ProtocolModel.isValidEvidenceTransition(current, next);
                bool actual = V2Lifecycle.isValidEvidenceTransition(current, next);
                assertEq(actual, model, "evidence lifecycle mismatch");
            }
        }
    }

    function test_disputeLifecycle_matches_reference_model() public {
        for (uint256 i = 0; i <= uint256(type(IV2Types.DisputeStatus).max); ++i) {
            IV2Types.DisputeStatus current = IV2Types.DisputeStatus(i);
            for (uint256 j = 0; j <= uint256(type(IV2Types.DisputeStatus).max); ++j) {
                IV2Types.DisputeStatus next = IV2Types.DisputeStatus(j);
                bool model = ProtocolModel.isValidDisputeTransition(current, next);
                bool actual = V2Lifecycle.isValidDisputeTransition(current, next);
                assertEq(actual, model, "dispute lifecycle mismatch");
            }
        }
    }

    function test_settlementLifecycle_matches_reference_model() public {
        for (uint256 i = 0; i <= uint256(type(IV2Types.SettlementStatus).max); ++i) {
            IV2Types.SettlementStatus current = IV2Types.SettlementStatus(i);
            for (uint256 j = 0; j <= uint256(type(IV2Types.SettlementStatus).max); ++j) {
                IV2Types.SettlementStatus next = IV2Types.SettlementStatus(j);
                bool model = ProtocolModel.isValidSettlementTransition(current, next);
                bool actual = V2Lifecycle.isValidSettlementTransition(current, next);
                assertEq(actual, model, "settlement lifecycle mismatch");
            }
        }
    }

    function test_roundingAndRewardSplits_match_reference_model() public {
        assertEq(ProtocolModel.splitAmount(10, 3333, 0), 3, "floor rounding mismatch");
        assertEq(ProtocolModel.splitAmount(10, 3333, 1), 4, "ceil rounding mismatch");
        assertEq(ProtocolModel.splitAmount(10, 3333, 2), 3, "half-up rounding mismatch");

        (uint256 verifierReward, uint256 treasuryCut) = ProtocolModel.rewardSplit(1_000, 8000, 0);
        assertEq(verifierReward, 800, "reward split mismatch");
        assertEq(treasuryCut, 200, "treasury split mismatch");

        for (uint256 i = 0; i <= uint256(type(IV2Types.ClaimState).max); ++i) {
            IV2Types.ClaimState state = IV2Types.ClaimState(i);
            assertEq(
                V2Lifecycle.isClaimOpen(state),
                ProtocolModel.isClaimOpen(state),
                "claim open predicate mismatch"
            );
            assertEq(
                V2Lifecycle.isClaimVerified(state),
                ProtocolModel.isClaimVerified(state),
                "claim verified predicate mismatch"
            );
            assertEq(
                V2Lifecycle.isClaimDisputed(state),
                ProtocolModel.isClaimDisputed(state),
                "claim disputed predicate mismatch"
            );
        }

        for (uint256 i = 0; i <= uint256(type(IV2Types.SettlementStatus).max); ++i) {
            IV2Types.SettlementStatus status = IV2Types.SettlementStatus(i);
            assertEq(
                V2Lifecycle.isTerminalSettlementStatus(status),
                ProtocolModel.isTerminalSettlementStatus(status),
                "terminal settlement predicate mismatch"
            );
        }
    }

    function test_aggregateClaim_matches_reference_model() public {
        ProtocolModelVerificationSource source = new ProtocolModelVerificationSource();
        source.addVote(1, address(1), true, true, 300);
        source.addVote(1, address(2), false, false, 900);
        source.addVote(1, address(3), true, false, 200);

        bool[] memory voted = new bool[](3);
        bool[] memory support = new bool[](3);
        uint256[] memory effectiveStake = new uint256[](3);
        voted[0] = true;
        voted[1] = false;
        voted[2] = true;
        support[0] = true;
        support[1] = false;
        support[2] = false;
        effectiveStake[0] = 300;
        effectiveStake[1] = 900;
        effectiveStake[2] = 200;

        (uint256 trueWeight, uint256 falseWeight, uint256 count) =
            ProtocolModel.calculateWeights(voted, support, effectiveStake);
        (ProtocolModel.ClaimOutcome outcome, uint256 confidence) =
            ProtocolModel.resolveOutcome(trueWeight, falseWeight, trueWeight + falseWeight);

        VerificationAggregator aggregator = new VerificationAggregator(address(source), address(this), 0, 0, 0);
        aggregator.aggregateClaim(1);
        VerificationAggregator.AggregationResult memory result = aggregator.getAggregation(1);

        assertEq(result.trueWeight, trueWeight);
        assertEq(result.falseWeight, falseWeight);
        assertEq(result.totalWeight, trueWeight + falseWeight);
        assertEq(result.confidence, confidence);
        assertEq(uint256(result.outcome), uint256(outcome));
        assertEq(count, 2);
    }

    function test_aggregateClaim_zeroAndTie_match_reference_model() public {
        ProtocolModelVerificationSource source = new ProtocolModelVerificationSource();
        source.addVote(1, address(1), true, true, 100);
        source.addVote(1, address(2), true, false, 100);

        bool[] memory voted = new bool[](2);
        bool[] memory support = new bool[](2);
        uint256[] memory effectiveStake = new uint256[](2);
        voted[0] = true;
        voted[1] = true;
        support[0] = true;
        support[1] = false;
        effectiveStake[0] = 100;
        effectiveStake[1] = 100;

        (uint256 trueWeight, uint256 falseWeight, ) = ProtocolModel.calculateWeights(voted, support, effectiveStake);
        (ProtocolModel.ClaimOutcome outcome, uint256 confidence) =
            ProtocolModel.resolveOutcome(trueWeight, falseWeight, trueWeight + falseWeight);

        VerificationAggregator aggregator = new VerificationAggregator(address(source), address(this), 0, 0, 0);
        aggregator.aggregateClaim(1);
        VerificationAggregator.AggregationResult memory result = aggregator.getAggregation(1);

        assertEq(result.confidence, confidence);
        assertEq(uint256(result.outcome), uint256(outcome));
    }

    function test_aggregateClaim_zeroWeight_matches_reference_model() public {
        ProtocolModelVerificationSource source = new ProtocolModelVerificationSource();
        bool[] memory voted = new bool[](0);
        bool[] memory support = new bool[](0);
        uint256[] memory effectiveStake = new uint256[](0);

        (uint256 trueWeight, uint256 falseWeight, ) = ProtocolModel.calculateWeights(voted, support, effectiveStake);
        (ProtocolModel.ClaimOutcome outcome, uint256 confidence) =
            ProtocolModel.resolveOutcome(trueWeight, falseWeight, trueWeight + falseWeight);

        VerificationAggregator aggregator = new VerificationAggregator(address(source), address(this), 0, 0, 0);
        aggregator.aggregateClaim(1);
        VerificationAggregator.AggregationResult memory result = aggregator.getAggregation(1);

        assertEq(result.totalWeight, 0);
        assertEq(result.confidence, confidence);
        assertEq(uint256(result.outcome), uint256(outcome));
    }

    function test_invalid_rounding_policy_and_terminal_transitions_revert() public {
        vm.expectRevert(abi.encodeWithSelector(ProtocolModel.InvalidRoundingPolicy.selector, 3));
        harness.splitInvalid(3);

        assertFalse(ProtocolModel.isValidClaimTransition(IV2Types.ClaimState.Finalized, IV2Types.ClaimState.VerificationOpen));
        assertFalse(ProtocolModel.isValidEvidenceTransition(IV2Types.EvidenceStatus.REJECTED, IV2Types.EvidenceStatus.SUBMITTED));
        assertFalse(ProtocolModel.isValidDisputeTransition(IV2Types.DisputeStatus.RESOLVED, IV2Types.DisputeStatus.OPEN));
        assertFalse(ProtocolModel.isValidSettlementTransition(IV2Types.SettlementStatus.EXECUTED, IV2Types.SettlementStatus.PENDING));
    }

    function test_v2Lifecycle_matches_reference_model_for_all_state_pairs() public {
        for (uint256 i = 0; i <= uint256(type(IV2Types.ClaimState).max); ++i) {
            IV2Types.ClaimState current = IV2Types.ClaimState(i);
            for (uint256 j = 0; j <= uint256(type(IV2Types.ClaimState).max); ++j) {
                IV2Types.ClaimState next = IV2Types.ClaimState(j);
                assertEq(
                    V2Lifecycle.isValidClaimTransition(current, next),
                    ProtocolModel.isValidClaimTransition(current, next),
                    "reference-vs-implementation mismatch"
                );
            }
        }
    }
}
