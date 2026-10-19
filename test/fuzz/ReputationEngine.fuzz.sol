// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/reputation/ReputationEngine.sol";
import "../../contracts/mocks/MockGovernanceController.sol";

contract ReputationEngineFuzzTest is Test {
    ReputationEngine reputationEngine;
    MockGovernanceController mockGovernance;
    
    address admin;
    address updateRole;
    address pauser;
    
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant UPDATE_ROLE = keccak256("UPDATE_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    uint256 constant BASE_MULTIPLIER = 1e18;
    uint256 constant DEFAULT_INITIAL_SCORE = 1e18;
    uint256 constant MIN_REPUTATION_SCORE = 1e17;
    uint256 constant MAX_REPUTATION_SCORE = 10e18;

    function setUp() public {
        admin = address(this);
        updateRole = address(0x1);
        pauser = address(0x2);
        
        mockGovernance = new MockGovernanceController(admin);
        reputationEngine = new ReputationEngine(admin, address(mockGovernance));
        
        reputationEngine.grantRole(UPDATE_ROLE, updateRole);
        reputationEngine.grantRole(PAUSER_ROLE, pauser);
    }

    // ============ Fuzz: Reputation Initialization ============

    function testFuzz_InitializeReputation(address verifier) public {
        vm.assume(verifier != address(0));
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        ReputationEngine.Reputation memory rep = reputationEngine.getReputation(verifier);
        assertEq(rep.score, DEFAULT_INITIAL_SCORE);
        assertEq(rep.successfulVerifications, 0);
        assertEq(rep.failedVerifications, 0);
        assertEq(rep.disputedVerifications, 0);
        assertEq(rep.totalStake, 0);
        assertEq(rep.lastUpdated, block.timestamp);
        assertTrue(rep.exists);
    }

    function testFuzz_InitializeReputationWithCustomScore(address verifier, uint256 score) public {
        vm.assume(verifier != address(0));
        vm.assume(score >= MIN_REPUTATION_SCORE && score <= MAX_REPUTATION_SCORE);
        
        vm.prank(updateRole);
        reputationEngine.initializeReputationWithScore(verifier, score);
        
        uint256 actualScore = reputationEngine.getReputationScore(verifier);
        assertEq(actualScore, score);
    }

    function testFuzz_DuplicateInitializationReverts(address verifier) public {
        vm.assume(verifier != address(0));
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(ReputationEngine.VerifierAlreadyExists.selector, verifier));
        reputationEngine.initializeReputation(verifier);
    }

    function testFuzz_ZeroAddressInitializationReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ReputationEngine.InvalidZeroAddress.selector));
        reputationEngine.initializeReputation(address(0));
    }

    // ============ Fuzz: Reputation Score Updates ============

    function testFuzz_UpdateReputationScore(address verifier, uint256 newScore) public {
        vm.assume(verifier != address(0));
        
        // Initialize reputation
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        vm.assume(newScore >= MIN_REPUTATION_SCORE && newScore <= MAX_REPUTATION_SCORE);
        
        vm.prank(updateRole);
        reputationEngine.updateReputationScore(verifier, newScore);
        
        uint256 actualScore = reputationEngine.getReputationScore(verifier);
        assertEq(actualScore, newScore);
    }

    function testFuzz_UpdateScoreBelowBoundsReverts(address verifier, uint256 newScore) public {
        vm.assume(verifier != address(0));
        vm.assume(newScore < MIN_REPUTATION_SCORE);
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        vm.prank(updateRole);
        vm.expectRevert(abi.encodeWithSelector(ReputationEngine.InvalidReputationScore.selector, newScore));
        reputationEngine.updateReputationScore(verifier, newScore);
    }

    function testFuzz_UpdateScoreAboveBoundsReverts(address verifier, uint256 newScore) public {
        vm.assume(verifier != address(0));
        vm.assume(newScore > MAX_REPUTATION_SCORE);
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        vm.prank(updateRole);
        vm.expectRevert(abi.encodeWithSelector(ReputationEngine.InvalidReputationScore.selector, newScore));
        reputationEngine.updateReputationScore(verifier, newScore);
    }

    // ============ Fuzz: Reputation Multiplier Calculation ============

    function testFuzz_CalculateReputationMultiplier(address verifier, uint256 score) public {
        vm.assume(verifier != address(0));
        vm.assume(score >= MIN_REPUTATION_SCORE && score <= MAX_REPUTATION_SCORE);
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        vm.prank(updateRole);
        reputationEngine.updateReputationScore(verifier, score);
        
        uint256 multiplier = reputationEngine.calculateReputationMultiplier(verifier);
        uint256 expectedMultiplier = score;
        
        // Cap at 10x
        if (expectedMultiplier > 10e18) {
            expectedMultiplier = 10e18;
        }
        
        assertEq(multiplier, expectedMultiplier);
    }

    function testFuzz_CalculateWeight(address verifier, uint256 stakeAmount, uint256 score) public {
        vm.assume(verifier != address(0));
        vm.assume(stakeAmount > 0 && stakeAmount <= 1e30);
        vm.assume(score >= MIN_REPUTATION_SCORE && score <= MAX_REPUTATION_SCORE);
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        vm.prank(updateRole);
        reputationEngine.updateReputationScore(verifier, score);
        
        uint256 weight = reputationEngine.calculateWeight(stakeAmount, verifier);
        uint256 multiplier = reputationEngine.calculateReputationMultiplier(verifier);
        uint256 expectedWeight = (stakeAmount * multiplier) / BASE_MULTIPLIER;
        
        assertEq(weight, expectedWeight);
    }

    // ============ Fuzz: Verification Statistics ============

    function testFuzz_RecordSuccessfulVerification(address verifier, uint256 stakeAmount) public {
        vm.assume(verifier != address(0));
        vm.assume(stakeAmount > 0 && stakeAmount <= 1e30);
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        uint256 successfulBefore = reputationEngine.getReputation(verifier).successfulVerifications;
        
        vm.prank(updateRole);
        reputationEngine.recordSuccessfulVerification(verifier, stakeAmount);
        
        ReputationEngine.Reputation memory rep = reputationEngine.getReputation(verifier);
        uint256 successfulAfter = rep.successfulVerifications;
        uint256 totalStakeAfter = rep.totalStake;
        
        assertEq(successfulAfter, successfulBefore + 1);
        assertEq(totalStakeAfter, stakeAmount);
    }

    function testFuzz_RecordFailedVerification(address verifier, uint256 stakeAmount) public {
        vm.assume(verifier != address(0));
        vm.assume(stakeAmount > 0 && stakeAmount <= 1e30);
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        uint256 failedBefore = reputationEngine.getReputation(verifier).failedVerifications;
        
        vm.prank(updateRole);
        reputationEngine.recordFailedVerification(verifier, stakeAmount);
        
        ReputationEngine.Reputation memory rep = reputationEngine.getReputation(verifier);
        uint256 failedAfter = rep.failedVerifications;
        uint256 totalStakeAfter = rep.totalStake;
        
        assertEq(failedAfter, failedBefore + 1);
        assertEq(totalStakeAfter, stakeAmount);
    }

    function testFuzz_RecordDisputedClaim(address verifier, uint256 stakeAmount) public {
        vm.assume(verifier != address(0));
        vm.assume(stakeAmount > 0 && stakeAmount <= 1e30);
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        uint256 disputedBefore = reputationEngine.getReputation(verifier).disputedVerifications;
        
        vm.prank(updateRole);
        reputationEngine.recordDisputedClaim(verifier, stakeAmount);
        
        ReputationEngine.Reputation memory rep = reputationEngine.getReputation(verifier);
        uint256 disputedAfter = rep.disputedVerifications;
        uint256 totalStakeAfter = rep.totalStake;
        
        assertEq(disputedAfter, disputedBefore + 1);
        assertEq(totalStakeAfter, stakeAmount);
    }

    // ============ Fuzz: Batch Updates ============

    function testFuzz_BatchUpdateVerificationStats(
        address[] calldata verifiers,
        uint256 successSeed,
        uint256 failSeed,
        uint256 disputeSeed
    ) public {
        vm.assume(verifiers.length > 0 && verifiers.length <= 10);
        
        // Collect unique non-zero verifiers and initialize them
        uint256 uniqueCount = 0;
        address[] memory uniqueVerifiers = new address[](verifiers.length);
        for (uint256 i = 0; i < verifiers.length; i++) {
            if (verifiers[i] == address(0)) continue;
            bool isDuplicate = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniqueVerifiers[j] == verifiers[i]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                uniqueVerifiers[uniqueCount++] = verifiers[i];
                vm.prank(verifiers[i]);
                reputationEngine.initializeReputation(verifiers[i]);
            }
        }
        vm.assume(uniqueCount > 0);
        
        address[] memory batchVerifiers = new address[](uniqueCount);
        uint256[] memory successCount = new uint256[](uniqueCount);
        uint256[] memory failCount = new uint256[](uniqueCount);
        uint256[] memory disputeCount = new uint256[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            batchVerifiers[i] = uniqueVerifiers[i];
            successCount[i] = bound(successSeed, 0, 1e6);
            failCount[i] = bound(failSeed, 0, 1e6);
            disputeCount[i] = bound(disputeSeed, 0, 1e6);
        }
        
        vm.prank(updateRole);
        reputationEngine.batchUpdateVerificationStats(batchVerifiers, successCount, failCount, disputeCount);
        
        // Verify updates
        for (uint256 i = 0; i < uniqueCount; i++) {
            ReputationEngine.Reputation memory rep = reputationEngine.getReputation(batchVerifiers[i]);
            assertEq(rep.successfulVerifications, successCount[i]);
            assertEq(rep.failedVerifications, failCount[i]);
            assertEq(rep.disputedVerifications, disputeCount[i]);
        }
    }

    function testFuzz_BatchUpdateArrayLengthMismatch(address[] calldata verifiers) public {
        vm.assume(verifiers.length > 0);
        
        uint256[] memory wrongLength = new uint256[](verifiers.length + 1);
        
        vm.prank(updateRole);
        vm.expectRevert("Array length mismatch");
        reputationEngine.batchUpdateVerificationStats(verifiers, wrongLength, wrongLength, wrongLength);
    }

    // ============ Fuzz: Reputation Bounds ============

    function testFuzz_SetReputationBounds(uint256 minScore, uint256 maxScore) public {
        vm.assume(minScore > 0);
        vm.assume(minScore < maxScore);
        vm.assume(maxScore <= 100e18);
        
        reputationEngine.setReputationBounds(minScore, maxScore);
        
        assertEq(reputationEngine.minReputationScore(), minScore);
        assertEq(reputationEngine.maxReputationScore(), maxScore);
    }

    function testFuzz_SetInvalidReputationBounds(uint256 minScore, uint256 maxScore) public {
        vm.assume(minScore >= maxScore || minScore == 0);
        
        vm.expectRevert(abi.encodeWithSelector(ReputationEngine.InvalidReputationBounds.selector, minScore, maxScore));
        reputationEngine.setReputationBounds(minScore, maxScore);
    }

    function testFuzz_SetDefaultInitialScore(uint256 score) public {
        vm.assume(score > 0);
        vm.assume(score <= 100e18);
        
        reputationEngine.setDefaultInitialScore(score);
        
        assertEq(reputationEngine.defaultInitialScore(), score);
    }

    // ============ Fuzz: Deterministic Results ============

    function testFuzz_ReputationLookupIsDeterministic(address verifier) public {
        vm.assume(verifier != address(0));
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        uint256 score1 = reputationEngine.getReputationScore(verifier);
        uint256 score2 = reputationEngine.getReputationScore(verifier);
        
        assertEq(score1, score2);
    }

    function testFuzz_MultiplierCalculationIsDeterministic(address verifier, uint256 stakeAmount) public {
        vm.assume(verifier != address(0));
        vm.assume(stakeAmount > 0 && stakeAmount <= 1e30);
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        uint256 weight1 = reputationEngine.calculateWeight(stakeAmount, verifier);
        uint256 weight2 = reputationEngine.calculateWeight(stakeAmount, verifier);
        
        assertEq(weight1, weight2);
    }

    // ============ Fuzz: Protocol Statistics ============

    function testFuzz_ProtocolStatisticsAccumulate(address verifier1, address verifier2) public {
        vm.assume(verifier1 != address(0) && verifier2 != address(0));
        vm.assume(verifier1 != verifier2);
        
        vm.prank(verifier1);
        reputationEngine.initializeReputation(verifier1);
        
        vm.prank(verifier2);
        reputationEngine.initializeReputation(verifier2);
        
        uint256 totalVerifiers = reputationEngine.getStatistics().totalVerifiers;
        assertEq(totalVerifiers, 2);
        
        vm.prank(updateRole);
        reputationEngine.recordSuccessfulVerification(verifier1, 1000e18);
        
        vm.prank(updateRole);
        reputationEngine.recordFailedVerification(verifier2, 500e18);
        
        ReputationEngine.ProtocolStatistics memory stats = reputationEngine.getStatistics();
        assertEq(stats.totalSuccessfulVerifications, 1);
        assertEq(stats.totalFailedVerifications, 1);
    }

    // ============ Fuzz: Edge Cases ============

    function testFuzz_MaxReputationScore(address verifier) public {
        vm.assume(verifier != address(0));
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        vm.prank(updateRole);
        reputationEngine.updateReputationScore(verifier, MAX_REPUTATION_SCORE);
        
        uint256 multiplier = reputationEngine.calculateReputationMultiplier(verifier);
        assertEq(multiplier, 10e18); // Capped at 10x
    }

    function testFuzz_MinReputationScore(address verifier) public {
        vm.assume(verifier != address(0));
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        vm.prank(updateRole);
        reputationEngine.updateReputationScore(verifier, MIN_REPUTATION_SCORE);
        
        uint256 multiplier = reputationEngine.calculateReputationMultiplier(verifier);
        assertEq(multiplier, MIN_REPUTATION_SCORE);
    }

    function testFuzz_LargeStakeAmount(address verifier, uint256 stakeAmount) public {
        vm.assume(verifier != address(0));
        vm.assume(stakeAmount >= 1e18 && stakeAmount <= 1e30);
        
        vm.prank(verifier);
        reputationEngine.initializeReputation(verifier);
        
        vm.prank(updateRole);
        reputationEngine.recordSuccessfulVerification(verifier, stakeAmount);
        
        uint256 totalStake = reputationEngine.getReputation(verifier).totalStake;
        assertEq(totalStake, stakeAmount);
    }

    // ============ Fuzz: Multiple Verifiers ============

    function testFuzz_MultipleVerifiersInitialization(address[] calldata verifiers) public {
        vm.assume(verifiers.length > 0 && verifiers.length <= 20);
        
        uint256 count = 0;
        for (uint256 i = 0; i < verifiers.length; i++) {
            if (verifiers[i] == address(0)) continue;
            bool isDuplicate = false;
            for (uint256 j = 0; j < i; j++) {
                if (verifiers[j] != address(0) && verifiers[i] == verifiers[j]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (isDuplicate) continue;
            vm.prank(verifiers[i]);
            reputationEngine.initializeReputation(verifiers[i]);
            count++;
        }
        
        uint256 totalVerifiers = reputationEngine.getStatistics().totalVerifiers;
        assertEq(totalVerifiers, count);
    }

    function testFuzz_VerifierExistenceCheck(address[] calldata verifiers, address checkAddress) public {
        vm.assume(verifiers.length > 0 && verifiers.length <= 20);
        
        for (uint256 i = 0; i < verifiers.length; i++) {
            if (verifiers[i] == address(0)) continue;
            bool isDuplicate = false;
            for (uint256 j = 0; j < i; j++) {
                if (verifiers[j] != address(0) && verifiers[i] == verifiers[j]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (isDuplicate) continue;
            vm.prank(verifiers[i]);
            reputationEngine.initializeReputation(verifiers[i]);
        }
        
        bool exists = reputationEngine.reputationExists(checkAddress);
        bool shouldExist = false;
        
        // address(0) can never be initialized (skipped above), so presence in the input
        // array must not imply existence for the zero address.
        if (checkAddress != address(0)) {
            for (uint256 i = 0; i < verifiers.length; i++) {
                if (verifiers[i] == checkAddress) {
                    shouldExist = true;
                    break;
                }
            }
        }
        
        assertEq(exists, shouldExist);
    }
}
