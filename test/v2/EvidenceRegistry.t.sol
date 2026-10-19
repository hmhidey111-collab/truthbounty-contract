// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../contracts/v2/EvidenceRegistry.sol";
import "../../contracts/v2/interfaces/IEvidence.sol";
import "../../contracts/v2/interfaces/IV2Types.sol";
import "../../contracts/mocks/MockEvidenceClaimRegistry.sol";

/// @title EvidenceRegistryHandler
/// @notice Stateful invariant handler for EvidenceRegistry (PREWAVE-SC-015).
/// @dev Mediates stateful operations during invariant campaigns. Reverted operations
///      are caught and excluded from ghost accounting, preserving invariant consistency.
contract EvidenceRegistryHandler is Test {
    EvidenceRegistry public registry;
    MockEvidenceClaimRegistry public claimRegistry;

    address public admin;
    address public contributor;
    address public contributor2;

    uint256 public ghostContributorSubmissions;
    uint256 public ghostContributor2Submissions;
    uint256 public ghostTotalSuccessfulSubmissions;
    uint256 public ghostRevertedSubmissions;

    uint256[] internal _committedIds;

    constructor(
        EvidenceRegistry _registry,
        MockEvidenceClaimRegistry _claimRegistry,
        address _admin,
        address _contributor,
        address _contributor2
    ) {
        registry = _registry;
        claimRegistry = _claimRegistry;
        admin = _admin;
        contributor = _contributor;
        contributor2 = _contributor2;
    }

    function committedIds() external view returns (uint256[] memory) {
        return _committedIds;
    }

    function commitEvidence(uint256 claimSeed, uint256 actorSeed, uint256 salt) external {
        address actor = (actorSeed % 2 == 0) ? contributor : contributor2;
        uint256 claimId = bound(claimSeed, 1, 4);
        uint256 nonce = registry.nextContributorNonce(actor);
        bytes32 content = keccak256(abi.encode(actor, nonce, salt, block.timestamp));
        bytes32 meta = keccak256(abi.encode("meta", actor, nonce, salt));

        vm.prank(actor);
        try registry.commitEvidence(claimId, content, meta, nonce) returns (uint256 eid) {
            if (actor == contributor) {
                ghostContributorSubmissions++;
            } else {
                ghostContributor2Submissions++;
            }
            ghostTotalSuccessfulSubmissions++;
            _committedIds.push(eid);
        } catch {
            ghostRevertedSubmissions++;
        }
    }

    function pause() external {
        vm.prank(admin);
        try registry.pause() {} catch {}
    }

    function unpause() external {
        vm.prank(admin);
        try registry.unpause() {} catch {}
    }

    function warpForward(uint256 secondsSeed) external {
        uint256 delta = bound(secondsSeed, 1, 1 days);
        vm.warp(block.timestamp + delta);
    }
}

contract EvidenceRegistryTest is StdInvariant, Test {
    EvidenceRegistry internal registry;
    MockEvidenceClaimRegistry internal claimRegistry;
    EvidenceRegistryHandler internal handler;

    address internal admin = address(this);
    address internal contributor = address(0xBEEF);
    address internal contributor2 = address(0xCAFE);
    address internal stranger = address(0xDEAD);

    uint256 internal constant CLAIM_A = 1;
    uint256 internal constant CLAIM_B = 2;
    uint256 internal constant CLAIM_CLOSED = 3;
    uint256 internal constant CLAIM_FINALIZED = 4;

    bytes32 internal constant CONTENT_A = keccak256("content-a");
    bytes32 internal constant CONTENT_B = keccak256("content-b");
    bytes32 internal constant CONTENT_C = keccak256("content-c");
    bytes internal constant META_A = "meta-a";
    bytes internal constant META_B = "meta-b";

    uint64 internal FAR_FUTURE;

    function setUp() public {
        FAR_FUTURE = uint64(block.timestamp + 52 weeks);
        claimRegistry = new MockEvidenceClaimRegistry();
        registry = new EvidenceRegistry(admin, address(claimRegistry));

        claimRegistry.setClaim(CLAIM_A, admin, FAR_FUTURE, IClaimRegistry.ClaimStatus.Pending);
        claimRegistry.setClaim(CLAIM_B, admin, FAR_FUTURE, IClaimRegistry.ClaimStatus.UnderVerification);
        claimRegistry.setClaim(CLAIM_CLOSED, admin, uint64(block.timestamp - 1), IClaimRegistry.ClaimStatus.UnderVerification);
        claimRegistry.setClaim(CLAIM_FINALIZED, admin, FAR_FUTURE, IClaimRegistry.ClaimStatus.VerifiedTrue);

        vm.label(address(registry), "EvidenceRegistry");
        vm.label(address(claimRegistry), "ClaimRegistry");
        vm.label(contributor, "contributor");
        vm.label(contributor2, "contributor2");

        handler = new EvidenceRegistryHandler(registry, claimRegistry, admin, contributor, contributor2);
        targetContract(address(handler));
    }

    // =============================================================
    // SUCCESS PATHS
    // =============================================================

    function test_submitEvidence_happyPath() public {
        vm.prank(contributor);
        uint256 eid = registry.submitEvidence(CLAIM_A, CONTENT_A, META_A);

        assertTrue(eid != 0);
        assertEq(registry.evidenceCount(CLAIM_A), 1);
        assertEq(registry.nextContributorNonce(contributor), 1);

        IV2Types.Evidence memory e = registry.getEvidence(eid);
        assertEq(e.id, eid);
        assertEq(e.claimId, CLAIM_A);
        assertEq(e.submitter, contributor);
        assertEq(e.contentHash, CONTENT_A);
        assertEq(uint256(e.status), uint256(IV2Types.EvidenceStatus.SUBMITTED));
    }

    function test_submitEvidence_emitsCanonicalEvents() public {
        bytes32 metaDigest = keccak256(META_A);
        uint256 expectedId = registry.computeEvidenceId(CLAIM_A, contributor, CONTENT_A, metaDigest, 0);

        vm.prank(contributor);
        vm.expectEmit(true, true, true, true);
        emit IEvidence.EvidenceSubmitted(expectedId, CLAIM_A, contributor, CONTENT_A);
        vm.expectEmit(true, true, true, true);
        emit ITruthBountyEvents.EvidenceSubmittedV1(CLAIM_A, expectedId, contributor, CONTENT_A, uint64(block.timestamp), 1);
        vm.expectEmit(true, true, true, false);
        emit EvidenceRegistry.EvidenceCommitted(CLAIM_A, expectedId, contributor, CONTENT_A, metaDigest, 0, uint64(block.timestamp), 1);
        registry.submitEvidence(CLAIM_A, CONTENT_A, META_A);
    }

    function test_commitEvidence_nonceSequencing() public {
        bytes32 mdA = keccak256(META_A);
        bytes32 mdB = keccak256(META_B);

        vm.prank(contributor);
        uint256 id0 = registry.commitEvidence(CLAIM_A, CONTENT_A, mdA, 0);

        vm.prank(contributor);
        uint256 id1 = registry.commitEvidence(CLAIM_A, CONTENT_B, mdB, 1);

        assertTrue(id0 != id1);
        assertEq(registry.nextContributorNonce(contributor), 2);
        assertEq(registry.evidenceCount(CLAIM_A), 2);

        (uint256[] memory page, ) = registry.claimEvidence(CLAIM_A, 0, 10);
        assertEq(page[0], id0);
        assertEq(page[1], id1);
    }

    function test_verifyEvidenceCommitment_roundTrip() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(CLAIM_B, CONTENT_A, md, 0);

        bool ok = registry.verifyEvidenceCommitment(eid, CLAIM_B, contributor, CONTENT_A, md, 0);
        assertTrue(ok);
    }

    function test_getEvidenceCommitment_exposesImmutableDigests() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);

        EvidenceRegistry.EvidenceCommitment memory c = registry.getEvidenceCommitment(eid);
        assertEq(c.contentDigest, CONTENT_A);
        assertEq(c.metadataDigest, md);
        assertEq(c.contributor, contributor);
        assertEq(c.nonce, 0);
        assertEq(c.claimId, CLAIM_A);
    }

    function test_setEvidenceStatus_validTransitions() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);

        registry.setEvidenceStatus(eid, IV2Types.EvidenceStatus.ACCEPTED);
        assertEq(uint256(registry.getEvidence(eid).status), uint256(IV2Types.EvidenceStatus.ACCEPTED));

        registry.setEvidenceStatus(eid, IV2Types.EvidenceStatus.ACCEPTED);
        assertEq(uint256(registry.getEvidence(eid).status), uint256(IV2Types.EvidenceStatus.ACCEPTED));
    }

    function test_setEvidenceStatus_emitsEvent() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);

        vm.expectEmit(true, false, false, true);
        emit IEvidence.EvidenceStatusChanged(eid, IV2Types.EvidenceStatus.SUBMITTED, IV2Types.EvidenceStatus.REJECTED, admin);
        registry.setEvidenceStatus(eid, IV2Types.EvidenceStatus.REJECTED);
    }

    function test_pause_thenUnpause() public {
        registry.pause();
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        vm.expectRevert();
        registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);

        registry.unpause();
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);
        assertTrue(eid != 0);
    }

    function test_claimEvidence_pagination() public {
        bytes32 md = keccak256(META_A);
        uint256[] memory ids = new uint256[](3);
        for (uint256 i = 0; i < 3; ) {
            vm.prank(contributor);
            ids[i] = registry.commitEvidence(CLAIM_A, bytes32(uint256(CONTENT_A) + i), md, i);
            unchecked { ++i; }
        }

        (uint256[] memory page0, uint256 c1) = registry.claimEvidence(CLAIM_A, 0, 2);
        assertEq(page0.length, 2);
        assertEq(page0[0], ids[0]);
        assertEq(c1, 2);

        (uint256[] memory page1, uint256 c2) = registry.claimEvidence(CLAIM_A, 2, 2);
        assertEq(page1.length, 1);
        assertEq(page1[0], ids[2]);
        assertEq(c2, 3);

        (uint256[] memory past, uint256 c3) = registry.claimEvidence(CLAIM_A, 5, 2);
        assertEq(past.length, 0);
        assertEq(c3, 3);
    }

    function test_differentContributors_sameContentAllowed() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        uint256 id1 = registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);

        vm.prank(contributor2);
        uint256 id2 = registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);

        assertTrue(id1 != id2);
        assertEq(registry.evidenceCount(CLAIM_A), 2);
    }

    // =============================================================
    // FAILURE PATHS
    // =============================================================

    function test_revert_zeroContentDigest() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        vm.expectRevert(EvidenceRegistry.ZeroDigest.selector);
        registry.commitEvidence(CLAIM_A, bytes32(0), md, 0);
    }

    function test_revert_zeroMetadataDigest() public {
        vm.prank(contributor);
        vm.expectRevert(EvidenceRegistry.ZeroDigest.selector);
        registry.commitEvidence(CLAIM_A, CONTENT_A, bytes32(0), 0);
    }

    function test_revert_invalidClaim() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.InvalidClaim.selector, 9999));
        registry.commitEvidence(9999, CONTENT_A, md, 0);
    }

    function test_revert_claimFinalized() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        vm.expectRevert(abi.encodeWithSelector(
            EvidenceRegistry.ClaimFinalized.selector,
            CLAIM_FINALIZED,
            IClaimRegistry.ClaimStatus.VerifiedTrue
        ));
        registry.commitEvidence(CLAIM_FINALIZED, CONTENT_A, md, 0);
    }

    function test_revert_evidenceWindowClosed() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        vm.expectRevert(EvidenceRegistry.EvidenceWindowClosed.selector);
        registry.commitEvidence(CLAIM_CLOSED, CONTENT_A, md, 0);
    }

    function test_revert_invalidNonce_tooHigh() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        vm.expectRevert(abi.encodeWithSelector(
            EvidenceRegistry.InvalidNonce.selector, contributor, 0, 5
        ));
        registry.commitEvidence(CLAIM_A, CONTENT_A, md, 5);
    }

    function test_revert_invalidNonce_reuse() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);

        bytes32 mdB = keccak256(META_B);
        vm.prank(contributor);
        vm.expectRevert(abi.encodeWithSelector(
            EvidenceRegistry.InvalidNonce.selector, contributor, 1, 0
        ));
        registry.commitEvidence(CLAIM_A, CONTENT_B, mdB, 0);
    }

    function test_revert_duplicateEvidence() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);

        bytes32 key = keccak256(abi.encode(CLAIM_A, contributor, CONTENT_A, md));
        vm.prank(contributor);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.DuplicateEvidence.selector, key));
        registry.commitEvidence(CLAIM_A, CONTENT_A, md, 1);
    }

    function test_revert_evidenceLimit() public {
        bytes32 md = keccak256(META_A);
        uint256 max = registry.MAX_EVIDENCE_PER_CLAIM();
        for (uint256 i = 0; i < max; ) {
            vm.prank(contributor);
            registry.commitEvidence(CLAIM_A, bytes32(uint256(CONTENT_A) + i), md, i);
            unchecked { ++i; }
        }
        vm.prank(contributor);
        vm.expectRevert(abi.encodeWithSelector(
            EvidenceRegistry.EvidenceLimitReached.selector, CLAIM_A, max
        ));
        registry.commitEvidence(CLAIM_A, CONTENT_C, md, max);
    }

    function test_revert_setEvidenceStatus_unauthorized() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);

        vm.prank(stranger);
        vm.expectRevert();
        registry.setEvidenceStatus(eid, IV2Types.EvidenceStatus.ACCEPTED);
    }

    function test_revert_setEvidenceStatus_notFound() public {
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.EvidenceNotFound.selector, 0xBAD));
        registry.setEvidenceStatus(0xBAD, IV2Types.EvidenceStatus.ACCEPTED);
    }

    function test_revert_setEvidenceStatus_noneDestination() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);

        vm.expectRevert(abi.encodeWithSelector(
            EvidenceRegistry.InvalidEvidenceStatusTransition.selector,
            eid,
            IV2Types.EvidenceStatus.SUBMITTED,
            IV2Types.EvidenceStatus.NONE
        ));
        registry.setEvidenceStatus(eid, IV2Types.EvidenceStatus.NONE);
    }

    function test_revert_setEvidenceStatus_terminalTransition() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);
        registry.setEvidenceStatus(eid, IV2Types.EvidenceStatus.ACCEPTED);

        vm.expectRevert(abi.encodeWithSelector(
            EvidenceRegistry.InvalidEvidenceStatusTransition.selector,
            eid,
            IV2Types.EvidenceStatus.ACCEPTED,
            IV2Types.EvidenceStatus.REJECTED
        ));
        registry.setEvidenceStatus(eid, IV2Types.EvidenceStatus.REJECTED);
    }

    function test_revert_verifyCommitment_wrongNonce() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);

        vm.expectRevert(abi.encodeWithSelector(
            EvidenceRegistry.CommitmentVerificationFailed.selector, eid
        ));
        registry.verifyEvidenceCommitment(eid, CLAIM_A, contributor, CONTENT_A, md, 1);
    }

    function test_revert_verifyCommitment_wrongContributor() public {
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);

        vm.expectRevert(abi.encodeWithSelector(
            EvidenceRegistry.CommitmentVerificationFailed.selector, eid
        ));
        registry.verifyEvidenceCommitment(eid, CLAIM_A, contributor2, CONTENT_A, md, 0);
    }

    function test_revert_getEvidence_notFound() public {
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.EvidenceNotFound.selector, 0xBAD));
        registry.getEvidence(0xBAD);
    }

    function test_revert_claimEvidence_invalidLimit() public {
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.InvalidPageLimit.selector, 0));
        registry.claimEvidence(CLAIM_A, 0, 0);

        uint256 tooBig = registry.MAX_PAGE_SIZE() + 1;
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.InvalidPageLimit.selector, tooBig));
        registry.claimEvidence(CLAIM_A, 0, tooBig);
    }

    function test_revert_constructor_zeroAdmin() public {
        vm.expectRevert(EvidenceRegistry.ZeroAdmin.selector);
        new EvidenceRegistry(address(0), address(claimRegistry));
    }

    function test_revert_constructor_zeroClaimRegistry() public {
        vm.expectRevert(EvidenceRegistry.ZeroClaimRegistry.selector);
        new EvidenceRegistry(admin, address(0));
    }

    function test_pause_unauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.pause();
    }

    function test_unpause_unauthorized() public {
        registry.pause();
        vm.prank(stranger);
        vm.expectRevert();
        registry.unpause();
    }

    // =============================================================
    // BOUNDARY / EDGE CASES
    // =============================================================

    function test_boundary_deadlineExact_passes() public {
        uint64 exact = uint64(block.timestamp + 1);
        claimRegistry.setClaim(42, admin, exact, IClaimRegistry.ClaimStatus.Pending);
        vm.warp(exact);
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(42, CONTENT_A, md, 0);
        assertTrue(eid != 0);
    }

    function test_boundary_deadlineAfterOneSecond_reverts() public {
        uint64 deadline = uint64(block.timestamp + 10);
        claimRegistry.setClaim(77, admin, deadline, IClaimRegistry.ClaimStatus.Pending);
        vm.warp(deadline + 1);
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        vm.expectRevert(EvidenceRegistry.EvidenceWindowClosed.selector);
        registry.commitEvidence(77, CONTENT_A, md, 0);
    }

    function test_boundary_emptyMetadata_hasNonZeroDigest() public {
        bytes32 md = keccak256("");
        assertTrue(md != bytes32(0));
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(CLAIM_A, CONTENT_A, md, 0);
        assertTrue(eid != 0);
        assertTrue(registry.verifyEvidenceCommitment(eid, CLAIM_A, contributor, CONTENT_A, md, 0));
    }

    // =============================================================
    // INVARIANTS
    // =============================================================

    function invariant_nonceEqualsContributorSubmissions() public view {
        uint256 expected = 0;
        uint256 totalClaims = 5;
        uint256 maxPage = registry.MAX_PAGE_SIZE();
        for (uint256 cid = 1; cid <= totalClaims; ) {
            if (!claimRegistry.claimExists(cid)) {
                unchecked { ++cid; }
                continue;
            }
            uint256 cnt = registry.evidenceCount(cid);
            if (cnt == 0) {
                unchecked { ++cid; }
                continue;
            }
            uint256 cursor = 0;
            uint256 read = 0;
            while (read < cnt) {
                uint256 limit = cnt - read;
                if (limit > maxPage) limit = maxPage;
                (uint256[] memory ids, uint256 nextCursor) = registry.claimEvidence(cid, cursor, limit);
                for (uint256 j = 0; j < ids.length; ) {
                    EvidenceRegistry.EvidenceCommitment memory ec = registry.getEvidenceCommitment(ids[j]);
                    if (ec.contributor == contributor) expected++;
                    unchecked { ++j; }
                }
                read += ids.length;
                if (nextCursor == cursor || ids.length == 0) break;
                cursor = nextCursor;
            }
            unchecked { ++cid; }
        }
        assertEq(registry.nextContributorNonce(contributor), expected);
        if (address(handler) != address(0)) {
            assertEq(registry.nextContributorNonce(contributor), handler.ghostContributorSubmissions());
        }
    }

    function invariant_evidenceIdIsDeterministic() public {
        // 1. All existing commitments stored in the registry match computeEvidenceId deterministically
        uint256 totalClaims = 5;
        uint256 maxPage = registry.MAX_PAGE_SIZE();
        for (uint256 cid = 1; cid <= totalClaims; ) {
            if (!claimRegistry.claimExists(cid)) {
                unchecked { ++cid; }
                continue;
            }
            uint256 cnt = registry.evidenceCount(cid);
            if (cnt == 0) {
                unchecked { ++cid; }
                continue;
            }
            uint256 cursor = 0;
            uint256 read = 0;
            while (read < cnt) {
                uint256 limit = cnt - read;
                if (limit > maxPage) limit = maxPage;
                (uint256[] memory ids, uint256 nextCursor) = registry.claimEvidence(cid, cursor, limit);
                for (uint256 j = 0; j < ids.length; ) {
                    uint256 eid = ids[j];
                    EvidenceRegistry.EvidenceCommitment memory ec = registry.getEvidenceCommitment(eid);
                    uint256 expectedId = registry.computeEvidenceId(
                        ec.claimId, ec.contributor, ec.contentDigest, ec.metadataDigest, ec.nonce
                    );
                    assertEq(eid, expectedId, "Stored evidenceId must match deterministic computation");
                    assertTrue(
                        registry.verifyEvidenceCommitment(
                            eid, ec.claimId, ec.contributor, ec.contentDigest, ec.metadataDigest, ec.nonce
                        ),
                        "Stored evidence must verify against computeEvidenceId"
                    );
                    unchecked { ++j; }
                }
                read += ids.length;
                if (nextCursor == cursor || ids.length == 0) break;
                cursor = nextCursor;
            }
            unchecked { ++cid; }
        }

        // 2. Pre-computed ID equals post-committed ID for new unique submissions when active
        if (!registry.paused() && registry.evidenceCount(CLAIM_A) < registry.MAX_EVIDENCE_PER_CLAIM()) {
            uint256 nonce = registry.nextContributorNonce(contributor);
            bytes32 uniqueContent = keccak256(abi.encode(CONTENT_B, nonce));
            bytes32 md = keccak256(META_A);
            uint256 preId = registry.computeEvidenceId(CLAIM_A, contributor, uniqueContent, md, nonce);
            vm.prank(contributor);
            uint256 postId = registry.commitEvidence(CLAIM_A, uniqueContent, md, nonce);
            assertEq(preId, postId, "Pre-computed ID must match post-commit ID");
            assertTrue(
                registry.verifyEvidenceCommitment(postId, CLAIM_A, contributor, uniqueContent, md, nonce),
                "Post-commitment verification failed"
            );
        }
    }

    // =============================================================
    // PREWAVE-SC-015 REGRESSION TESTS & COUNTEREXAMPLE REPRODUCTIONS
    // =============================================================

    /// @notice Reproduces the duplicate evidence counterexample that broke invariant_evidenceIdIsDeterministic
    ///         when static content was reused across consecutive nonce submissions.
    function test_regression_persistedCounterexample_evidenceIdDuplicate_reproducedAndHandled() public {
        bytes32 md = keccak256(META_A);
        uint256 nonce0 = registry.nextContributorNonce(contributor);
        vm.prank(contributor);
        uint256 id0 = registry.commitEvidence(CLAIM_A, CONTENT_B, md, nonce0);
        assertTrue(id0 != 0);

        // Counterexample behavior: Submitting identical (CLAIM_A, contributor, CONTENT_B, md) with nonce1 reverts
        uint256 nonce1 = registry.nextContributorNonce(contributor);
        bytes32 dedupKey = keccak256(abi.encode(CLAIM_A, contributor, CONTENT_B, md));
        vm.prank(contributor);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.DuplicateEvidence.selector, dedupKey));
        registry.commitEvidence(CLAIM_A, CONTENT_B, md, nonce1);

        // Correct behavior: Unique content per nonce derives deterministic, non-colliding evidence IDs
        bytes32 uniqueContent1 = keccak256(abi.encode(CONTENT_B, nonce1));
        uint256 preId1 = registry.computeEvidenceId(CLAIM_A, contributor, uniqueContent1, md, nonce1);
        vm.prank(contributor);
        uint256 postId1 = registry.commitEvidence(CLAIM_A, uniqueContent1, md, nonce1);
        assertEq(preId1, postId1);
        assertTrue(registry.verifyEvidenceCommitment(postId1, CLAIM_A, contributor, uniqueContent1, md, nonce1));
    }

    /// @notice Reproduces the zero-limit and non-existent claim counterexample that broke
    ///         invariant_nonceEqualsContributorSubmissions.
    function test_regression_persistedCounterexample_nonceZeroLimitAndUncreatedClaim() public {
        // Counterexample 1: Calling claimEvidence with limit = 0 reverts with InvalidPageLimit(0)
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.InvalidPageLimit.selector, 0));
        registry.claimEvidence(CLAIM_A, 0, 0);

        // Counterexample 2: Calling claimEvidence on non-existent claim 5 reverts with InvalidClaim(5)
        assertFalse(claimRegistry.claimExists(5));
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.InvalidClaim.selector, 5));
        registry.claimEvidence(5, 0, 1);

        // Safe accounting: When count is 0, invariant loops skip zero-limit queries, preserving accurate nonce accounting
        assertEq(registry.evidenceCount(CLAIM_A), 0);
        assertEq(registry.nextContributorNonce(contributor), 0);
    }

    /// @notice Regression test: Finalized claims reject new evidence submissions fail-closed,
    ///         reverted operations do not increment contributor nonces, and historical pages remain readable.
    function test_regression_finalizedClaimRejectsEvidenceAndPreservesHistoricalReads() public {
        // Commit evidence on CLAIM_B before finalization
        bytes32 md = keccak256(META_A);
        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(CLAIM_B, CONTENT_A, md, 0);
        assertEq(registry.nextContributorNonce(contributor), 1);

        // Finalize CLAIM_B
        claimRegistry.setClaimStatus(CLAIM_B, IClaimRegistry.ClaimStatus.VerifiedTrue);

        // Attempt submission to finalized claim reverts
        vm.prank(contributor);
        vm.expectRevert(abi.encodeWithSelector(
            EvidenceRegistry.ClaimFinalized.selector,
            CLAIM_B,
            IClaimRegistry.ClaimStatus.VerifiedTrue
        ));
        registry.commitEvidence(CLAIM_B, CONTENT_B, md, 1);

        // Contributor nonce is untouched after revert
        assertEq(registry.nextContributorNonce(contributor), 1);

        // Historical evidence remains readable
        (uint256[] memory page, ) = registry.claimEvidence(CLAIM_B, 0, 10);
        assertEq(page.length, 1);
        assertEq(page[0], eid);
    }

    /// @notice Regression test: Page limits enforce strict bounds [1, MAX_PAGE_SIZE].
    function test_regression_invalidPageLimits_failClosed() public {
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.InvalidPageLimit.selector, 0));
        registry.claimEvidence(CLAIM_A, 0, 0);

        uint256 max = registry.MAX_PAGE_SIZE();
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.InvalidPageLimit.selector, max + 1));
        registry.claimEvidence(CLAIM_A, 0, max + 1);

        // Boundaries 1 and MAX_PAGE_SIZE are accepted without revert
        (uint256[] memory pageMin, ) = registry.claimEvidence(CLAIM_A, 0, 1);
        assertEq(pageMin.length, 0);

        (uint256[] memory pageMax, ) = registry.claimEvidence(CLAIM_A, 0, max);
        assertEq(pageMax.length, 0);
    }
}

contract EvidenceRegistryFuzzTest is Test {
    EvidenceRegistry internal registry;
    MockEvidenceClaimRegistry internal claimRegistry;

    address internal admin = address(this);

    uint64 internal FAR_FUTURE;

    function setUp() public {
        FAR_FUTURE = uint64(block.timestamp + 52 weeks);
        claimRegistry = new MockEvidenceClaimRegistry();
        registry = new EvidenceRegistry(admin, address(claimRegistry));
        claimRegistry.setClaim(1, admin, FAR_FUTURE, IClaimRegistry.ClaimStatus.Pending);
        claimRegistry.setClaim(2, admin, FAR_FUTURE, IClaimRegistry.ClaimStatus.UnderVerification);
    }

    function testFuzz_submitUniqueEvidence_doesNotRevert(
        address contributor,
        bytes32 contentDigest,
        bytes32 metadataDigest,
        uint256 seedClaim
    ) public {
        vm.assume(contributor != address(0));
        vm.assume(contentDigest != bytes32(0));
        vm.assume(metadataDigest != bytes32(0));
        uint256 claimId = bound(seedClaim, 1, 2);

        uint256 nonce = registry.nextContributorNonce(contributor);
        bytes32 dedupKey = keccak256(abi.encode(claimId, contributor, contentDigest, metadataDigest));
        if (nonce > 0) return;

        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(claimId, contentDigest, metadataDigest, nonce);
        assertTrue(eid != 0);
        assertTrue(registry.verifyEvidenceCommitment(eid, claimId, contributor, contentDigest, metadataDigest, nonce));

        vm.prank(contributor);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.DuplicateEvidence.selector, dedupKey));
        registry.commitEvidence(claimId, contentDigest, metadataDigest, nonce + 1);
    }

    function testFuzz_verifyCommitment_detectsAnyBitFlip(
        address contributor,
        bytes32 content,
        bytes32 metadata,
        uint256 mutationMask
    ) public {
        vm.assume(contributor != address(0));
        vm.assume(content != bytes32(0));
        vm.assume(metadata != bytes32(0));

        vm.prank(contributor);
        uint256 eid = registry.commitEvidence(1, content, metadata, 0);

        bytes32 mutatedContent = content ^ bytes32(uint256(1) << bound(mutationMask % 256, 0, 255));
        if (mutatedContent == content) return;

        vm.expectRevert(abi.encodeWithSelector(
            EvidenceRegistry.CommitmentVerificationFailed.selector, eid
        ));
        registry.verifyEvidenceCommitment(eid, 1, contributor, mutatedContent, metadata, 0);
    }

    function testFuzz_nonceSequence_isStrictlyMonotonic(
        address contributor,
        uint8 submissions,
        bytes32 baseC,
        bytes32 baseM
    ) public {
        vm.assume(contributor != address(0));
        uint256 count = bound(submissions, 0, 10);
        uint256 prevNonce = registry.nextContributorNonce(contributor);

        for (uint256 i = 0; i < count; ) {
            bytes32 c = keccak256(abi.encode(baseC, i));
            bytes32 m = keccak256(abi.encode(baseM, i));
            uint256 expectedNonce = registry.nextContributorNonce(contributor);
            vm.prank(contributor);
            registry.commitEvidence(1, c, m, expectedNonce);
            assertEq(registry.nextContributorNonce(contributor), expectedNonce + 1);
            unchecked { ++i; }
        }

        assertEq(registry.nextContributorNonce(contributor), prevNonce + count);
    }
}
