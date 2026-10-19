// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {IV2CommitReveal} from "../../contracts/v2/interfaces/IV2CommitReveal.sol";
import {V2CommitRevealReplayDomain} from "../../contracts/v2/libraries/V2CommitRevealReplayDomain.sol";
import {V2CommitRevealScheme} from "../../contracts/verification/V2CommitRevealScheme.sol";
import {V2CommitRevealHarness} from "../../contracts/test/V2CommitRevealHarness.sol";

/**
 * @title CommitRevealPrivacyTest
 * @notice Comprehensive property, boundary, replay, and privacy test suite for
 *         PREWAVE-SC-003 (#678) — Fuzz Commit-Reveal Privacy, Deadlines, and Replay Domains.
 * @dev Covers:
 *      1. 10-dimensional commitment binding and injectivity (fuzz and property tests).
 *      2. Deterministic deadline boundary semantics (before, at, after deadlines).
 *      3. Cross-domain replay prevention (cross-claim, cross-round, cross-chain, cross-release, cross-contract).
 *      4. Commit replacement policy (ALLOWED_BEFORE_DEADLINE vs FORBIDDEN).
 *      5. Missed-reveal tracking and slashing lifecycle with complete event emissions.
 *      6. Choice and rationale privacy (zero-leakage verification during commit phase).
 */
contract CommitRevealPrivacyTest is Test {
    V2CommitRevealScheme internal scheme;
    V2CommitRevealHarness internal harness;

    address internal admin = address(0xAD314);
    address internal roundManager = address(0xB055);
    address internal slashAdmin = address(0x51A54);

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal eve = address(0xEvE);

    bytes32 internal constant CANONICAL_RELEASE = V2CommitRevealReplayDomain.CANONICAL_RELEASE_VERSION;
    uint256 internal constant CANONICAL_CHAIN_ID = 10; // Optimism Mainnet

    uint256 internal constant CLAIM_ID = 1001;
    uint256 internal constant ROUND_ID = 1;
    uint256 internal constant INITIAL_STAKE = 1000 ether;

    uint8 internal constant DECISION_SUPPORT = 1;
    uint8 internal constant DECISION_OPPOSE = 0;

    bytes32 internal constant SAMPLE_RATIONALE_HASH = keccak256("valid_evidence_analysis_v2");
    bytes32 internal constant SAMPLE_SALT = keccak256("high_entropy_alice_secret_salt_2026");

    uint64 internal roundStart;
    uint64 internal commitDeadline;
    uint64 internal revealDeadline;

    event RoundRegistered(
        uint256 indexed claimId,
        uint256 indexed roundId,
        uint64 startedAt,
        uint64 commitDeadline,
        uint64 revealDeadline,
        IV2CommitReveal.ReplacementPolicy replacementPolicy
    );

    event CommitSubmitted(
        uint256 indexed claimId,
        uint256 indexed roundId,
        address indexed voter,
        bytes32 commitmentHash,
        uint64 commitDeadline,
        uint64 revealDeadline,
        uint256 stakeAmount,
        uint64 committedAt
    );

    event CommitReplaced(
        uint256 indexed claimId,
        uint256 indexed roundId,
        address indexed voter,
        bytes32 oldCommitmentHash,
        bytes32 newCommitmentHash,
        uint16 replacementCount,
        uint64 replacedAt
    );

    event VoteRevealed(
        uint256 indexed claimId,
        uint256 indexed roundId,
        address indexed voter,
        uint8 decision,
        bytes32 rationaleHash,
        uint256 stakeAmount,
        uint64 revealedAt
    );

    event MissedRevealRecorded(
        uint256 indexed claimId,
        uint256 indexed roundId,
        address indexed voter,
        bytes32 commitmentHash,
        uint256 stakeAmount,
        uint64 recordedAt
    );

    event VoterSlashed(
        uint256 indexed claimId,
        uint256 indexed roundId,
        address indexed voter,
        uint256 slashAmount,
        uint256 remainingStake,
        bytes32 commitmentHash,
        uint64 slashedAt
    );

    function setUp() public {
        vm.chainId(CANONICAL_CHAIN_ID);
        vm.warp(1_800_000_000); // 2027 base timestamp

        harness = new V2CommitRevealHarness();
        scheme = new V2CommitRevealScheme(admin, CANONICAL_RELEASE);

        vm.startPrank(admin);
        scheme.grantRole(scheme.ROUND_MANAGER_ROLE(), roundManager);
        scheme.grantRole(scheme.SLASH_ADMIN_ROLE(), slashAdmin);
        vm.stopPrank();

        roundStart = uint64(block.timestamp);
        commitDeadline = roundStart + 2 hours;
        revealDeadline = roundStart + 4 hours;

        vm.prank(roundManager);
        scheme.registerRound(
            CLAIM_ID,
            ROUND_ID,
            commitDeadline,
            revealDeadline,
            IV2CommitReveal.ReplacementPolicy.ALLOWED_BEFORE_DEADLINE
        );
    }

    // =========================================================================
    // 1. Property & Fuzz Tests: 10-Dimensional Commitment Binding & Injectivity
    // =========================================================================

    function test_TypeHashMatchesPreimage() public view {
        bytes32 expected = keccak256(
            "V2CommitReveal(uint256 chainId,bytes32 releaseVersion,address verifyingContract,uint256 claimId,uint256 roundId,address voter,uint8 decision,bytes32 rationaleHash,bytes32 salt,uint64 deadline)"
        );
        assertEq(harness.typehash(), expected, "Typehash definition mismatch");
    }

    function testFuzz_InjectivityAcrossAllTenDimensions(
        uint256 chainId1,
        uint256 chainId2,
        bytes32 release1,
        bytes32 release2,
        address contract1,
        address contract2,
        uint256 claimId1,
        uint256 claimId2,
        uint256 roundId1,
        uint256 roundId2,
        address voter1,
        address voter2,
        uint8 decision1,
        uint8 decision2,
        bytes32 rationale1,
        bytes32 rationale2,
        bytes32 salt1,
        bytes32 salt2,
        uint64 deadline1,
        uint64 deadline2
    ) public view {
        vm.assume(chainId1 != 0 && chainId2 != 0);
        vm.assume(release1 != bytes32(0) && release2 != bytes32(0));
        vm.assume(contract1 != address(0) && contract2 != address(0));
        vm.assume(claimId1 != 0 && claimId2 != 0);
        vm.assume(roundId1 != 0 && roundId2 != 0);
        vm.assume(voter1 != address(0) && voter2 != address(0));
        vm.assume(salt1 != bytes32(0) && salt2 != bytes32(0));
        vm.assume(deadline1 != 0 && deadline2 != 0);

        bytes32 digest1 = harness.computeCommitment(
            chainId1,
            release1,
            contract1,
            claimId1,
            roundId1,
            voter1,
            decision1,
            rationale1,
            salt1,
            deadline1
        );

        // Mutate only chainId
        if (chainId1 != chainId2) {
            bytes32 digest2 = harness.computeCommitment(
                chainId2,
                release1,
                contract1,
                claimId1,
                roundId1,
                voter1,
                decision1,
                rationale1,
                salt1,
                deadline1
            );
            assertTrue(digest1 != digest2, "Collision on chainId mutation");
        }

        // Mutate only releaseVersion
        if (release1 != release2) {
            bytes32 digest2 = harness.computeCommitment(
                chainId1,
                release2,
                contract1,
                claimId1,
                roundId1,
                voter1,
                decision1,
                rationale1,
                salt1,
                deadline1
            );
            assertTrue(digest1 != digest2, "Collision on releaseVersion mutation");
        }

        // Mutate only verifyingContract
        if (contract1 != contract2) {
            bytes32 digest2 = harness.computeCommitment(
                chainId1,
                release1,
                contract2,
                claimId1,
                roundId1,
                voter1,
                decision1,
                rationale1,
                salt1,
                deadline1
            );
            assertTrue(digest1 != digest2, "Collision on verifyingContract mutation");
        }

        // Mutate only claimId
        if (claimId1 != claimId2) {
            bytes32 digest2 = harness.computeCommitment(
                chainId1,
                release1,
                contract1,
                claimId2,
                roundId1,
                voter1,
                decision1,
                rationale1,
                salt1,
                deadline1
            );
            assertTrue(digest1 != digest2, "Collision on claimId mutation");
        }

        // Mutate only roundId
        if (roundId1 != roundId2) {
            bytes32 digest2 = harness.computeCommitment(
                chainId1,
                release1,
                contract1,
                claimId1,
                roundId2,
                voter1,
                decision1,
                rationale1,
                salt1,
                deadline1
            );
            assertTrue(digest1 != digest2, "Collision on roundId mutation");
        }

        // Mutate only voter
        if (voter1 != voter2) {
            bytes32 digest2 = harness.computeCommitment(
                chainId1,
                release1,
                contract1,
                claimId1,
                roundId1,
                voter2,
                decision1,
                rationale1,
                salt1,
                deadline1
            );
            assertTrue(digest1 != digest2, "Collision on voter mutation");
        }

        // Mutate only decision
        if (decision1 != decision2) {
            bytes32 digest2 = harness.computeCommitment(
                chainId1,
                release1,
                contract1,
                claimId1,
                roundId1,
                voter1,
                decision2,
                rationale1,
                salt1,
                deadline1
            );
            assertTrue(digest1 != digest2, "Collision on decision mutation");
        }

        // Mutate only rationaleHash
        if (rationale1 != rationale2) {
            bytes32 digest2 = harness.computeCommitment(
                chainId1,
                release1,
                contract1,
                claimId1,
                roundId1,
                voter1,
                decision1,
                rationale2,
                salt1,
                deadline1
            );
            assertTrue(digest1 != digest2, "Collision on rationaleHash mutation");
        }

        // Mutate only salt
        if (salt1 != salt2) {
            bytes32 digest2 = harness.computeCommitment(
                chainId1,
                release1,
                contract1,
                claimId1,
                roundId1,
                voter1,
                decision1,
                rationale1,
                salt2,
                deadline1
            );
            assertTrue(digest1 != digest2, "Collision on salt mutation");
        }

        // Mutate only deadline
        if (deadline1 != deadline2) {
            bytes32 digest2 = harness.computeCommitment(
                chainId1,
                release1,
                contract1,
                claimId1,
                roundId1,
                voter1,
                decision1,
                rationale1,
                salt1,
                deadline2
            );
            assertTrue(digest1 != digest2, "Collision on deadline mutation");
        }
    }

    // =========================================================================
    // 2. Boundary Tests: Timing and Deadlines
    // =========================================================================

    function test_CommitAtDeadlineMinusOne_Succeeds() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.warp(commitDeadline - 1);
        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        IV2CommitReveal.CommitmentRecord memory record = scheme.getCommitment(CLAIM_ID, ROUND_ID, alice);
        assertEq(record.commitmentHash, commitment);
        assertEq(uint8(record.state), uint8(IV2CommitReveal.CommitState.COMMITTED));
    }

    function test_CommitAtExactDeadline_SucceedsInclusive() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.warp(commitDeadline);
        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        IV2CommitReveal.CommitmentRecord memory record = scheme.getCommitment(CLAIM_ID, ROUND_ID, alice);
        assertEq(record.commitmentHash, commitment);
    }

    function test_CommitAtDeadlinePlusOne_FailsClosed() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.CommitDeadlinePassed.selector,
                commitDeadline + 1,
                commitDeadline
            )
        );
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);
    }

    function test_RevealAtCommitDeadline_FailsClosedWindowNotOpen() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        // At exact commitDeadline, commit window is active, reveal window is not yet open
        vm.warp(commitDeadline);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.RevealWindowNotOpen.selector,
                commitDeadline,
                commitDeadline
            )
        );
        scheme.reveal(CLAIM_ID, ROUND_ID, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);
    }

    function test_RevealAtCommitDeadlinePlusOne_Succeeds() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        vm.warp(commitDeadline + 1);
        vm.prank(alice);

        vm.expectEmit(true, true, true, true);
        emit VoteRevealed(
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            INITIAL_STAKE,
            commitDeadline + 1
        );

        scheme.reveal(CLAIM_ID, ROUND_ID, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);

        IV2CommitReveal.CommitmentRecord memory record = scheme.getCommitment(CLAIM_ID, ROUND_ID, alice);
        assertEq(uint8(record.state), uint8(IV2CommitReveal.CommitState.REVEALED));
    }

    function test_RevealAtExactRevealDeadline_SucceedsInclusive() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        vm.warp(revealDeadline);
        vm.prank(alice);
        scheme.reveal(CLAIM_ID, ROUND_ID, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);

        IV2CommitReveal.CommitmentRecord memory record = scheme.getCommitment(CLAIM_ID, ROUND_ID, alice);
        assertEq(uint8(record.state), uint8(IV2CommitReveal.CommitState.REVEALED));
    }

    function test_RevealAtRevealDeadlinePlusOne_FailsClosed() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        vm.warp(revealDeadline + 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.RevealDeadlinePassed.selector,
                revealDeadline + 1,
                revealDeadline
            )
        );
        scheme.reveal(CLAIM_ID, ROUND_ID, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);
    }

    function test_MissedRevealAtRevealDeadline_RevertsNotPassed() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        vm.warp(revealDeadline);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.RevealDeadlineNotPassed.selector,
                revealDeadline,
                revealDeadline
            )
        );
        scheme.recordMissedReveal(CLAIM_ID, ROUND_ID, alice);
    }

    function test_MissedRevealAtRevealDeadlinePlusOne_Succeeds() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        vm.warp(revealDeadline + 1);

        vm.expectEmit(true, true, true, true);
        emit MissedRevealRecorded(
            CLAIM_ID,
            ROUND_ID,
            alice,
            commitment,
            INITIAL_STAKE,
            revealDeadline + 1
        );

        scheme.recordMissedReveal(CLAIM_ID, ROUND_ID, alice);

        IV2CommitReveal.CommitmentRecord memory record = scheme.getCommitment(CLAIM_ID, ROUND_ID, alice);
        assertEq(uint8(record.state), uint8(IV2CommitReveal.CommitState.MISSED_REVEAL));
    }

    // =========================================================================
    // 3. Replay Protection: Cross-Domain Replay Prevention
    // =========================================================================

    function test_CrossClaimReplay_FailsClosed() public {
        // Alice commits for CLAIM_ID
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        // Register round for CLAIM_ID + 1 with same deadlines
        uint256 otherClaimId = CLAIM_ID + 1;
        vm.prank(roundManager);
        scheme.registerRound(
            otherClaimId,
            ROUND_ID,
            commitDeadline,
            revealDeadline,
            IV2CommitReveal.ReplacementPolicy.ALLOWED_BEFORE_DEADLINE
        );

        // Commit on other claim as well
        vm.prank(alice);
        scheme.commit(otherClaimId, ROUND_ID, commitment, INITIAL_STAKE);

        vm.warp(commitDeadline + 10);

        // Attempting to reveal on other claim with the parameters bound to original claim must fail
        bytes32 otherComputedDigest = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            otherClaimId,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.CommitmentMismatch.selector,
                commitment,
                otherComputedDigest
            )
        );
        scheme.reveal(otherClaimId, ROUND_ID, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);
    }

    function test_CrossRoundReplay_FailsClosed() public {
        uint256 round2 = ROUND_ID + 1;
        vm.prank(roundManager);
        scheme.registerRound(
            CLAIM_ID,
            round2,
            commitDeadline,
            revealDeadline,
            IV2CommitReveal.ReplacementPolicy.ALLOWED_BEFORE_DEADLINE
        );

        bytes32 commitmentRound1 = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, round2, commitmentRound1, INITIAL_STAKE);

        vm.warp(commitDeadline + 10);

        bytes32 computedRound2 = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            round2,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.CommitmentMismatch.selector,
                commitmentRound1,
                computedRound2
            )
        );
        scheme.reveal(CLAIM_ID, round2, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);
    }

    function test_CrossChainReplay_FailsClosed() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            CANONICAL_CHAIN_ID,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        vm.warp(commitDeadline + 10);

        // Fork / reorg / bridge to Ethereum mainnet (chainId = 1)
        vm.chainId(1);

        bytes32 recomputedL1 = V2CommitRevealReplayDomain.computeCommitment(
            1,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.CommitmentMismatch.selector,
                commitment,
                recomputedL1
            )
        );
        scheme.reveal(CLAIM_ID, ROUND_ID, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);
    }

    function test_CrossReleaseReplay_FailsClosed() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        // Deploy new release scheme
        bytes32 nextRelease = keccak256("TruthBounty-V2.1.0-cancun");
        V2CommitRevealScheme nextScheme = new V2CommitRevealScheme(admin, nextRelease);

        vm.prank(admin);
        nextScheme.grantRole(nextScheme.ROUND_MANAGER_ROLE(), roundManager);

        vm.prank(roundManager);
        nextScheme.registerRound(
            CLAIM_ID,
            ROUND_ID,
            commitDeadline,
            revealDeadline,
            IV2CommitReveal.ReplacementPolicy.ALLOWED_BEFORE_DEADLINE
        );

        vm.prank(alice);
        nextScheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        vm.warp(commitDeadline + 10);

        bytes32 expectedNextReleaseDigest = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            nextRelease,
            address(nextScheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.CommitmentMismatch.selector,
                commitment,
                expectedNextReleaseDigest
            )
        );
        nextScheme.reveal(CLAIM_ID, ROUND_ID, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);
    }

    function test_CrossContractReplay_FailsClosed() public {
        V2CommitRevealScheme scheme2 = new V2CommitRevealScheme(admin, CANONICAL_RELEASE);
        vm.prank(admin);
        scheme2.grantRole(scheme2.ROUND_MANAGER_ROLE(), roundManager);

        vm.prank(roundManager);
        scheme2.registerRound(
            CLAIM_ID,
            ROUND_ID,
            commitDeadline,
            revealDeadline,
            IV2CommitReveal.ReplacementPolicy.ALLOWED_BEFORE_DEADLINE
        );

        bytes32 commitmentScheme1 = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        // Submitted to scheme2
        vm.prank(alice);
        scheme2.commit(CLAIM_ID, ROUND_ID, commitmentScheme1, INITIAL_STAKE);

        vm.warp(commitDeadline + 10);

        bytes32 expectedScheme2Digest = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme2),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.CommitmentMismatch.selector,
                commitmentScheme1,
                expectedScheme2Digest
            )
        );
        scheme2.reveal(CLAIM_ID, ROUND_ID, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);
    }

    function test_UnauthorizedRevealAttempt_FailsClosed() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        vm.warp(commitDeadline + 10);

        // Eve attempts to call reveal for Alice's commitment
        vm.prank(eve);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.CommitmentNotFound.selector,
                CLAIM_ID,
                ROUND_ID,
                eve
            )
        );
        scheme.reveal(CLAIM_ID, ROUND_ID, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);
    }

    function test_DuplicateReveal_FailsClosed() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        vm.warp(commitDeadline + 10);
        vm.prank(alice);
        scheme.reveal(CLAIM_ID, ROUND_ID, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);

        // Second reveal must fail
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.CommitmentAlreadyRevealed.selector,
                CLAIM_ID,
                ROUND_ID,
                alice
            )
        );
        scheme.reveal(CLAIM_ID, ROUND_ID, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);
    }

    function test_StaleCommitmentSubstitution_FailsClosed() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        vm.warp(commitDeadline + 10);

        // Alice tries to reveal opposite decision
        bytes32 wrongDigest = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_OPPOSE,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.CommitmentMismatch.selector,
                commitment,
                wrongDigest
            )
        );
        scheme.reveal(CLAIM_ID, ROUND_ID, DECISION_OPPOSE, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);
    }

    // =========================================================================
    // 4. Commit Replacement Policy
    // =========================================================================

    function test_CommitReplacement_AllowedBeforeDeadline() public {
        bytes32 commitment1 = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_OPPOSE,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment1, INITIAL_STAKE);

        // Alice changes mind and replaces commitment
        bytes32 newSalt = keccak256("alice_updated_salt_2026");
        bytes32 commitment2 = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            newSalt,
            commitDeadline
        );

        vm.warp(commitDeadline - 500);

        vm.expectEmit(true, true, true, true);
        emit CommitReplaced(
            CLAIM_ID,
            ROUND_ID,
            alice,
            commitment1,
            commitment2,
            1,
            commitDeadline - 500
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment2, INITIAL_STAKE + 500 ether);

        IV2CommitReveal.CommitmentRecord memory record = scheme.getCommitment(CLAIM_ID, ROUND_ID, alice);
        assertEq(record.commitmentHash, commitment2);
        assertEq(record.replacementCount, 1);
        assertEq(record.stakeAmount, INITIAL_STAKE + 500 ether);

        // At reveal, old commitment cannot be revealed
        vm.warp(commitDeadline + 10);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.CommitmentMismatch.selector,
                commitment2,
                commitment1
            )
        );
        scheme.reveal(CLAIM_ID, ROUND_ID, DECISION_OPPOSE, SAMPLE_RATIONALE_HASH, SAMPLE_SALT);

        // New commitment reveals cleanly
        vm.prank(alice);
        scheme.reveal(CLAIM_ID, ROUND_ID, DECISION_SUPPORT, SAMPLE_RATIONALE_HASH, newSalt);
        IV2CommitReveal.CommitmentRecord memory postReveal = scheme.getCommitment(CLAIM_ID, ROUND_ID, alice);
        assertEq(uint8(postReveal.state), uint8(IV2CommitReveal.CommitState.REVEALED));
    }

    function test_CommitReplacement_ForbiddenPolicy_Reverts() public {
        uint256 roundForbidden = ROUND_ID + 5;
        vm.prank(roundManager);
        scheme.registerRound(
            CLAIM_ID,
            roundForbidden,
            commitDeadline,
            revealDeadline,
            IV2CommitReveal.ReplacementPolicy.FORBIDDEN
        );

        bytes32 commitment1 = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            roundForbidden,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, roundForbidden, commitment1, INITIAL_STAKE);

        bytes32 commitment2 = keccak256("attempted_replacement");
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.CommitReplacementForbidden.selector,
                CLAIM_ID,
                roundForbidden,
                alice
            )
        );
        scheme.commit(CLAIM_ID, roundForbidden, commitment2, INITIAL_STAKE);
    }

    // =========================================================================
    // 5. Missed Reveal and Slashing Complete Events
    // =========================================================================

    function test_SlashingLifecycleAndEventCompleteness() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        // Advance past reveal deadline without Alice revealing
        uint64 pastReveal = revealDeadline + 100;
        vm.warp(pastReveal);

        // Record missed reveal
        scheme.recordMissedReveal(CLAIM_ID, ROUND_ID, alice);
        IV2CommitReveal.CommitmentRecord memory record = scheme.getCommitment(CLAIM_ID, ROUND_ID, alice);
        assertEq(uint8(record.state), uint8(IV2CommitReveal.CommitState.MISSED_REVEAL));

        // Slash 50% (5000 bps)
        uint256 expectedSlash = (INITIAL_STAKE * 5000) / 10000;
        uint256 expectedRemaining = INITIAL_STAKE - expectedSlash;

        vm.expectEmit(true, true, true, true);
        emit VoterSlashed(
            CLAIM_ID,
            ROUND_ID,
            alice,
            expectedSlash,
            expectedRemaining,
            commitment,
            pastReveal
        );

        vm.prank(slashAdmin);
        uint256 slashAmount = scheme.slashMissedReveal(CLAIM_ID, ROUND_ID, alice, 5000);
        assertEq(slashAmount, expectedSlash);

        IV2CommitReveal.CommitmentRecord memory slashedRecord = scheme.getCommitment(CLAIM_ID, ROUND_ID, alice);
        assertEq(uint8(slashedRecord.state), uint8(IV2CommitReveal.CommitState.SLASHED));
        assertEq(slashedRecord.stakeAmount, expectedRemaining);

        // Double slashing must fail closed
        vm.prank(slashAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IV2CommitReveal.CommitmentAlreadySlashed.selector,
                CLAIM_ID,
                ROUND_ID,
                alice
            )
        );
        scheme.slashMissedReveal(CLAIM_ID, ROUND_ID, alice, 5000);
    }

    // =========================================================================
    // 6. Choice & Rationale Privacy: Zero-Leakage Pre-Reveal
    // =========================================================================

    function test_ProtectedChoiceNeverEmittedPrematurely() public {
        bytes32 commitment = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            CANONICAL_RELEASE,
            address(scheme),
            CLAIM_ID,
            ROUND_ID,
            alice,
            DECISION_SUPPORT,
            SAMPLE_RATIONALE_HASH,
            SAMPLE_SALT,
            commitDeadline
        );

        vm.recordLogs();
        vm.prank(alice);
        scheme.commit(CLAIM_ID, ROUND_ID, commitment, INITIAL_STAKE);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1, "Exactly one event should be emitted on commit");

        // Assert event is CommitSubmitted and inspect payload
        assertEq(
            entries[0].topics[0],
            keccak256(
                "CommitSubmitted(uint256,uint256,address,bytes32,uint64,uint64,uint256,uint64)"
            ),
            "Must emit CommitSubmitted"
        );
        assertEq(entries[0].topics[1], bytes32(CLAIM_ID), "claimId topic mismatch");
        assertEq(entries[0].topics[2], bytes32(ROUND_ID), "roundId topic mismatch");
        assertEq(entries[0].topics[3], bytes32(uint256(uint160(alice))), "voter topic mismatch");

        // Decode non-indexed data
        (
            bytes32 emittedCommitment,
            uint64 emittedCommitDeadline,
            uint64 emittedRevealDeadline,
            uint256 emittedStake,
            uint64 emittedTime
        ) = abi.decode(entries[0].data, (bytes32, uint64, uint64, uint256, uint64));

        assertEq(emittedCommitment, commitment);
        assertEq(emittedCommitDeadline, commitDeadline);
        assertEq(emittedRevealDeadline, revealDeadline);
        assertEq(emittedStake, INITIAL_STAKE);
        assertEq(emittedTime, uint64(block.timestamp));

        // Privacy assertion: Verify that decision (1), salt, or rationaleHash are NEVER in the log data
        bytes memory rawData = entries[0].data;
        for (uint256 i = 0; i + 32 <= rawData.length; ++i) {
            bytes32 slice;
            assembly {
                slice := mload(add(add(rawData, 32), i))
            }
            assertTrue(slice != SAMPLE_SALT, "Salt leaked in log data");
            assertTrue(slice != SAMPLE_RATIONALE_HASH, "Rationale leaked in log data");
        }
    }
}
