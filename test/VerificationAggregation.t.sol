// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/VerificationAggregation.sol";
import "../contracts/TruthBountyWeighted.sol";
import "../contracts/MockERC20.sol";
import "../test/mocks/MockReputationOracle.sol";

contract VerificationAggregationTest is Test {
    TruthBountyWeighted public truthBounty;
    VerificationAggregation public aggregator;
    MockERC20 public token;
    MockReputationOracle public oracle;

    address public admin = address(0x1);
    address public submitter = address(0x2);
    address public verifier1 = address(0x3);
    address public verifier2 = address(0x4);
    address public verifier3 = address(0x5);
    address public verifier4 = address(0x6);
    address public verifier5 = address(0x7);

    uint256 constant MIN_STAKE = 100 ether;
    uint256 constant VERIFICATION_WINDOW = 7 days;
    uint256 constant CONFIRMATION_DELAY = 1 hours;

    function setUp() public {
        token = new MockERC20("Test", "TST");
        oracle = new MockReputationOracle();

        // Mint tokens to everyone
        token.mint(admin, 1000000 ether);
        token.mint(submitter, 1000000 ether);
        token.mint(verifier1, 1000000 ether);
        token.mint(verifier2, 1000000 ether);
        token.mint(verifier3, 1000000 ether);
        token.mint(verifier4, 1000000 ether);
        token.mint(verifier5, 1000000 ether);

        // Deploy TruthBountyWeighted
        vm.prank(admin);
        truthBounty = new TruthBountyWeighted(
            address(token),
            address(oracle),
            admin,
            admin
        );

        // Fund the bounty contract with tokens for rewards
        vm.prank(admin);
        token.transfer(address(truthBounty), 100000 ether);

        // Deploy aggregator
        aggregator = new VerificationAggregation(address(truthBounty));

        // Allow small votes (10 ether) in the stress/gas tests
        vm.prank(admin);
        truthBounty.setMinStakeAmount(1);
    }

    function _approveAndStake(address verifier, uint256 amount) internal {
        vm.prank(verifier, verifier);
        token.approve(address(truthBounty), type(uint256).max);
        vm.prank(verifier, verifier);
        truthBounty.stake(amount);
    }

    function _createClaim() internal returns (uint256) {
        vm.prank(submitter);
        uint256 claimId = truthBounty.createClaim("QmTestHash");
        return claimId;
    }

    function _vote(uint256 claimId, address verifier, bool support, uint256 stakeAmount) internal {
        vm.prank(verifier);
        truthBounty.vote(claimId, support, stakeAmount);
    }

    function _fastForwardWindow() internal {
        vm.warp(block.timestamp + VERIFICATION_WINDOW + CONFIRMATION_DELAY + 1);
    }

    // ============ Successful Cases ============

    function testUnanimousTrue() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);

        _vote(claimId, verifier1, true, 100 ether);
        _vote(claimId, verifier2, true, 100 ether);

        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.VERIFIED_TRUE));
        assertEq(result.trueWeight, 200 ether);
        assertEq(result.falseWeight, 0);
        assertEq(result.totalWeight, 200 ether);
        assertEq(result.confidence, 10000);
    }

    function testUnanimousFalse() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);

        _vote(claimId, verifier1, false, 100 ether);
        _vote(claimId, verifier2, false, 100 ether);

        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.VERIFIED_FALSE));
        assertEq(result.trueWeight, 0);
        assertEq(result.falseWeight, 200 ether);
        assertEq(result.totalWeight, 200 ether);
        assertEq(result.confidence, 10000);
    }

    function testMixedVerifications() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);
        _approveAndStake(verifier3, 1000 ether);

        _vote(claimId, verifier1, true, 100 ether);
        _vote(claimId, verifier2, true, 100 ether);
        _vote(claimId, verifier3, false, 100 ether);

        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.VERIFIED_TRUE));
        assertEq(result.trueWeight, 200 ether);
        assertEq(result.falseWeight, 100 ether);
        assertEq(result.totalWeight, 300 ether);
        assertEq(result.confidence, 6666);
    }

    function testWeightedTrueMajority() public {
        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);
        _approveAndStake(verifier3, 1000 ether);

        oracle.setReputationScore(verifier1, 2 ether);
        oracle.setReputationScore(verifier2, 0.5 ether);
        oracle.setReputationScore(verifier3, 0.5 ether);

        // Reputation updates must fall outside the grace period around claim creation
        vm.warp(block.timestamp + 3 days);
        uint256 claimId = _createClaim();

        _vote(claimId, verifier1, true, 100 ether);
        _vote(claimId, verifier2, false, 100 ether);
        _vote(claimId, verifier3, false, 100 ether);

        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.VERIFIED_TRUE));
        assertEq(result.trueWeight, 200 ether);
        assertEq(result.falseWeight, 100 ether);
        assertEq(result.totalWeight, 300 ether);
        assertEq(result.confidence, 6666);
    }

    function testWeightedFalseMajority() public {
        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);
        _approveAndStake(verifier3, 1000 ether);

        oracle.setReputationScore(verifier1, 0.5 ether);
        oracle.setReputationScore(verifier2, 2 ether);
        oracle.setReputationScore(verifier3, 2 ether);

        // Reputation updates must fall outside the grace period around claim creation
        vm.warp(block.timestamp + 3 days);
        uint256 claimId = _createClaim();

        _vote(claimId, verifier1, true, 100 ether);
        _vote(claimId, verifier2, false, 100 ether);
        _vote(claimId, verifier3, false, 100 ether);

        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.VERIFIED_FALSE));
        assertEq(result.trueWeight, 50 ether);
        assertEq(result.falseWeight, 400 ether);
        assertEq(result.totalWeight, 450 ether);
        assertEq(result.confidence, 8888);
    }

    function testLargeVerificationSet() public {
        uint256 claimId = _createClaim();

        address[10] memory voters = [
            address(0x10), address(0x11), address(0x12), address(0x13), address(0x14),
            address(0x15), address(0x16), address(0x17), address(0x18), address(0x19)
        ];

        for (uint256 i = 0; i < 10; i++) {
            token.mint(voters[i], 1000 ether);
            _approveAndStake(voters[i], 500 ether);
            _vote(claimId, voters[i], i < 6, 50 ether);
        }

        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.VERIFIED_TRUE));
        assertEq(result.trueWeight, 300 ether);
        assertEq(result.falseWeight, 200 ether);
        assertEq(result.totalWeight, 500 ether);
        assertEq(result.confidence, 6000);
    }

    function testConfidenceCalculation() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);

        _vote(claimId, verifier1, true, 100 ether);
        _vote(claimId, verifier2, false, 100 ether);

        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.INCONCLUSIVE));
        assertEq(result.trueWeight, 100 ether);
        assertEq(result.falseWeight, 100 ether);
        assertEq(result.totalWeight, 200 ether);
        assertEq(result.confidence, 5000);
    }

    // ============ Tie Cases ============

    function testEqualWeightTie() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);

        _vote(claimId, verifier1, true, 100 ether);
        _vote(claimId, verifier2, false, 100 ether);

        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.INCONCLUSIVE));
        assertEq(result.trueWeight, 100 ether);
        assertEq(result.falseWeight, 100 ether);
        assertEq(result.confidence, 5000);
    }

    function testEqualWeightWithThresholds() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);

        _vote(claimId, verifier1, true, 100 ether);
        _vote(claimId, verifier2, false, 100 ether);

        _fastForwardWindow();

        aggregator.setThresholds(1, 0, 0);
        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.INCONCLUSIVE));
    }

    function testEqualStakeEqualConfidence() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);

        oracle.setReputationScore(verifier1, 1 ether);
        oracle.setReputationScore(verifier2, 1 ether);

        _vote(claimId, verifier1, true, 100 ether);
        _vote(claimId, verifier2, false, 100 ether);

        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.INCONCLUSIVE));
        assertEq(result.trueWeight, 100 ether);
        assertEq(result.falseWeight, 100 ether);
        assertEq(result.totalWeight, 200 ether);
        assertEq(result.confidence, 5000);
    }

    function testInsufficientParticipation() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _vote(claimId, verifier1, true, 100 ether);

        _fastForwardWindow();

        aggregator.setThresholds(2, 0, 0);
        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.INCONCLUSIVE));
    }

    function testInsufficientTotalStake() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _vote(claimId, verifier1, true, 100 ether);

        _fastForwardWindow();

        aggregator.setThresholds(1, 500 ether, 0);
        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.INCONCLUSIVE));
    }

    function testConfidenceBelowThreshold() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);
        _approveAndStake(verifier3, 1000 ether);

        _vote(claimId, verifier1, true, 100 ether);
        _vote(claimId, verifier2, true, 100 ether);
        _vote(claimId, verifier3, false, 100 ether);

        _fastForwardWindow();

        aggregator.setThresholds(1, 0, 7000);
        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.INCONCLUSIVE));
        assertEq(result.confidence, 6666);
    }

    // ============ Determinism Tests ============

    function testDeterministicReaggregation() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);
        _approveAndStake(verifier3, 1000 ether);

        _vote(claimId, verifier1, true, 100 ether);
        _vote(claimId, verifier2, false, 100 ether);
        _vote(claimId, verifier3, true, 100 ether);

        _fastForwardWindow();

        AggregationResult memory first = aggregator.aggregateClaim(claimId);

        // Verify aggregation is stored
        AggregationResult memory stored = aggregator.getAggregation(claimId);
        assertEq(uint256(first.outcome), uint256(stored.outcome));
        assertEq(first.trueWeight, stored.trueWeight);
        assertEq(first.falseWeight, stored.falseWeight);
        assertEq(first.totalWeight, stored.totalWeight);
        assertEq(first.confidence, stored.confidence);
    }

    function testDeterministicOrderIndependence() public view {
        uint256 trueWeight1 = 300 ether;
        uint256 falseWeight1 = 100 ether;

        uint256 trueWeight2 = 100 ether;
        uint256 falseWeight2 = 300 ether;

        // Order of weights shouldn't affect confidence calculation
        uint256 confidence1 = aggregator.calculateConfidence(trueWeight1, falseWeight1);
        uint256 confidence2 = aggregator.calculateConfidence(trueWeight2, falseWeight2);
        assertEq(confidence1, confidence2);
    }

    function testPermutationOrderIndependence() public {
        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);
        _approveAndStake(verifier3, 1000 ether);
        _approveAndStake(verifier4, 1000 ether);

        oracle.setReputationScore(verifier1, 2 ether);
        oracle.setReputationScore(verifier2, 1 ether);
        oracle.setReputationScore(verifier3, 3 ether);
        oracle.setReputationScore(verifier4, 1 ether);

        vm.warp(block.timestamp + 3 days);

        uint256 claimA = _createClaim();
        uint256 claimB = _createClaim();

        _vote(claimA, verifier1, true, 10 ether);
        _vote(claimA, verifier2, false, 20 ether);
        _vote(claimA, verifier3, true, 30 ether);
        _vote(claimA, verifier4, false, 40 ether);

        _vote(claimB, verifier4, false, 40 ether);
        _vote(claimB, verifier3, true, 30 ether);
        _vote(claimB, verifier2, false, 20 ether);
        _vote(claimB, verifier1, true, 10 ether);

        _fastForwardWindow();

        AggregationResult memory resultA = aggregator.aggregateClaim(claimA);
        AggregationResult memory resultB = aggregator.aggregateClaim(claimB);

        assertEq(resultA.trueWeight, resultB.trueWeight);
        assertEq(resultA.falseWeight, resultB.falseWeight);
        assertEq(resultA.totalWeight, resultB.totalWeight);
        assertEq(uint256(resultA.outcome), uint256(resultB.outcome));
        assertEq(resultA.confidence, resultB.confidence);
    }

    function testFuzzStakeDistribution(uint256 seed) public {
        address[4] memory voters = [verifier1, verifier2, verifier3, verifier4];
        uint256[4] memory st;
        uint256[4] memory rep;
        bool[4] memory support;

        for (uint256 i = 0; i < 4; i++) {
            st[i] = bound(uint256(keccak256(abi.encode(seed, i, 0))), 1 ether, 10_000 ether);
            rep[i] = bound(uint256(keccak256(abi.encode(seed, i, 1))), 0.1 ether, 5 ether);
            support[i] = uint256(keccak256(abi.encode(seed, i, 2))) % 2 == 0;
            oracle.setReputationScore(voters[i], rep[i]);
        }

        vm.warp(block.timestamp + 3 days);
        uint256 claimId = _createClaim();

        uint256 expectedTrue;
        uint256 expectedFalse;

        for (uint256 i = 0; i < 4; i++) {
            _approveAndStake(voters[i], st[i]);
            if (support[i]) {
                _vote(claimId, voters[i], true, st[i]);
                expectedTrue += st[i] * rep[i] / 1 ether;
            } else {
                _vote(claimId, voters[i], false, st[i]);
                expectedFalse += st[i] * rep[i] / 1 ether;
            }
        }

        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(result.trueWeight, expectedTrue);
        assertEq(result.falseWeight, expectedFalse);
        assertEq(result.totalWeight, expectedTrue + expectedFalse);

        // Confidence is reported for the WINNING side (max(true, false) / total).
        uint256 expectedConfidence = expectedTrue + expectedFalse == 0
            ? 0
            : (expectedTrue > expectedFalse ? expectedTrue : expectedFalse) * 10000 /
                (expectedTrue + expectedFalse);
        assertEq(result.confidence, expectedConfidence);

        if (expectedTrue > expectedFalse) {
            assertEq(uint256(result.outcome), uint256(ClaimOutcome.VERIFIED_TRUE));
        } else if (expectedFalse > expectedTrue) {
            assertEq(uint256(result.outcome), uint256(ClaimOutcome.VERIFIED_FALSE));
        } else {
            assertEq(uint256(result.outcome), uint256(ClaimOutcome.INCONCLUSIVE));
        }
    }

    function testFuzzConfidenceNumericBounds(uint256 trueWeight, uint256 falseWeight) public {
        vm.assume(trueWeight > 0 || falseWeight > 0);

        // The aggregator scales the winning weight by 10_000, so extreme inputs may
        // overflow and must fail closed (revert). Whatever happens, confidence is bounded:
        // success => confidence in [0, 10000]; overflow => revert (no wrapped value).
        try aggregator.calculateConfidence(trueWeight, falseWeight) returns (uint256 confidence) {
            assertLe(confidence, 10000);
        } catch {}
    }

    // ============ Stress Tests ============

    function testMaxParticipation() public {
        uint256 voterCount = 50;
        address[] memory voters = new address[](voterCount);

        uint256 claimId = _createClaim();

        for (uint256 i = 0; i < voterCount; i++) {
            address voter = address(uint160(0x100 + i));
            voters[i] = voter;
            token.mint(voter, 1000 ether);
            _approveAndStake(voter, 500 ether);
            _vote(claimId, voter, i < 30, 10 ether);
        }

        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);

        assertEq(uint256(result.outcome), uint256(ClaimOutcome.VERIFIED_TRUE));
        assertEq(result.totalWeight, voterCount * 10 ether);
        assertEq(result.trueWeight, 30 * 10 ether);
        assertEq(result.falseWeight, 20 * 10 ether);
        assertEq(result.confidence, 6000);
    }

    function testRepeatedAggregation() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _vote(claimId, verifier1, true, 100 ether);

        _fastForwardWindow();
        aggregator.aggregateClaim(claimId);

        vm.expectRevert();
        aggregator.aggregateClaim(claimId);
    }

    // ============ Gas Benchmarks ============

    function testGasAggregationSingle() public {
        uint256 claimId = _createClaim();
        _approveAndStake(verifier1, 1000 ether);
        _vote(claimId, verifier1, true, 100 ether);
        _fastForwardWindow();

        aggregator.aggregateClaim(claimId);
    }

    function testGasAggregationTen() public {
        uint256 claimId = _createClaim();

        for (uint256 i = 0; i < 10; i++) {
            address voter = address(uint160(0x100 + i));
            token.mint(voter, 1000 ether);
            _approveAndStake(voter, 500 ether);
            _vote(claimId, voter, i % 2 == 0, 10 ether);
        }

        _fastForwardWindow();
        aggregator.aggregateClaim(claimId);
    }

    function testGasAggregationFifty() public {
        uint256 claimId = _createClaim();

        for (uint256 i = 0; i < 50; i++) {
            address voter = address(uint160(0x100 + i));
            token.mint(voter, 1000 ether);
            _approveAndStake(voter, 500 ether);
            _vote(claimId, voter, i % 2 == 0, 10 ether);
        }

        _fastForwardWindow();
        aggregator.aggregateClaim(claimId);
    }

    // ============ Edge Cases ============

    function testZeroVotes() public {
        uint256 claimId = _createClaim();
        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.INCONCLUSIVE));
        assertEq(result.trueWeight, 0);
        assertEq(result.falseWeight, 0);
        assertEq(result.totalWeight, 0);
        assertEq(result.confidence, 0);
    }

    function testAlreadyAggregatedReverts() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _vote(claimId, verifier1, true, 100 ether);

        _fastForwardWindow();
        aggregator.aggregateClaim(claimId);

        vm.expectRevert();
        aggregator.aggregateClaim(claimId);
    }

    function testNotAggregatedReverts() public {
        uint256 claimId = _createClaim();
        vm.expectRevert();
        aggregator.getAggregation(claimId);
    }

    function testIsAggregated() public {
        uint256 claimId = _createClaim();

        assertFalse(aggregator.isAggregated(claimId));

        _approveAndStake(verifier1, 1000 ether);
        _vote(claimId, verifier1, true, 100 ether);

        _fastForwardWindow();
        aggregator.aggregateClaim(claimId);

        assertTrue(aggregator.isAggregated(claimId));
    }

    function testHighConfidenceThreshold() public {
        _approveAndStake(verifier1, 1000 ether);
        _approveAndStake(verifier2, 1000 ether);
        _approveAndStake(verifier3, 1000 ether);

        oracle.setReputationScore(verifier1, 10 ether);
        oracle.setReputationScore(verifier2, 10 ether);
        oracle.setReputationScore(verifier3, 1 ether);

        // Reputation updates must fall outside the grace period around claim creation
        vm.warp(block.timestamp + 3 days);
        uint256 claimId = _createClaim();

        _vote(claimId, verifier1, true, 100 ether);
        _vote(claimId, verifier2, true, 100 ether);
        _vote(claimId, verifier3, false, 100 ether);

        _fastForwardWindow();

        AggregationResult memory result = aggregator.aggregateClaim(claimId);
        assertEq(uint256(result.outcome), uint256(ClaimOutcome.VERIFIED_TRUE));
        assertEq(result.trueWeight, 2000 ether);
        assertEq(result.falseWeight, 100 ether);
        assertEq(result.totalWeight, 2100 ether);
        assertEq(result.confidence, 9523);
    }

    // ============ Event Tests ============

    function testClaimAggregatedEvent() public {
        uint256 claimId = _createClaim();

        _approveAndStake(verifier1, 1000 ether);
        _vote(claimId, verifier1, true, 100 ether);

        _fastForwardWindow();

        vm.expectEmit(true, true, true, true);
        emit VerificationAggregation.ClaimAggregated(claimId, ClaimOutcome.VERIFIED_TRUE, 10000);
        aggregator.aggregateClaim(claimId);
    }

    function testThresholdsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit VerificationAggregation.ThresholdsUpdated(5, 1000 ether, 6000);
        aggregator.setThresholds(5, 1000 ether, 6000);
    }
}
