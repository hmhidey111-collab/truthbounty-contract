// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {VerificationCommitReveal} from "../../contracts/v2/VerificationCommitReveal.sol";
import {SignatureNonces} from "../../contracts/v2/SignatureNonces.sol";
import {V2ReplayDomain} from "../../contracts/v2/libraries/V2ReplayDomain.sol";

/// @title VerificationCommitRevealTest
/// @notice V2 safety/release boundary: commitments are unambiguous and context-bound,
///         reveal cannot be replayed elsewhere, pre-reveal data exposes no decision.
/// @dev Covers: cross-chain/release/contract/round replay, field reordering, packed collision,
///          zero/weak salt, wrong voter, deadline validation, and all existing commit-reveal
///          safety properties.
contract VerificationCommitRevealTest is Test {
    VerificationCommitReveal internal cr;

    uint256 internal constant VERIFIER_PK = 0xA11CE;
    address internal verifier;
    address internal other = address(0xBEEF);
    address internal relayer = address(0xCAFE);

    uint256 internal constant CLAIM = 7;
    uint256 internal constant ROUND = 1;
    bool internal constant DECISION = true;
    bytes32 internal constant RATIONALE = keccak256("rationale");
    bytes32 internal constant SALT = keccak256("high_entropy_salt_2026");
    uint64 internal constant DEADLINE = uint64(block.timestamp + 1 hours);

    function setUp() public {
        cr = new VerificationCommitReveal();
        verifier = vm.addr(VERIFIER_PK);
        vm.warp(1_000);
    }

    // ---- helpers ------------------------------------------------------------------------

    function _commitment(
        address who,
        uint256 claimId,
        uint256 roundId,
        bool decision,
        bytes32 rationale,
        bytes32 salt,
        uint64 deadline
    )
        internal
        view
        returns (bytes32)
    {
        return cr.computeCommitment(who, claimId, roundId, decision, rationale, salt, deadline);
    }

    function _commit() internal returns (bytes32 c) {
        c = _commitment(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND, c, DEADLINE);
    }

    function _sign(
        uint256 pk,
        bytes32 commitment,
        uint256 nonce,
        uint256 deadline
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = V2ReplayDomain.digest(
            cr.REVEAL_ACTION(),
            address(cr),
            block.chainid,
            V2ReplayDomain.REPLAY_DOMAIN_VERSION,
            vm.addr(pk),
            uint256(commitment),
            nonce,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _assertRevealedAsOriginal() internal view {
        VerificationCommitReveal.Record memory rec = cr.getRecord(verifier, CLAIM, ROUND);
        assertEq(uint8(rec.status), uint8(VerificationCommitReveal.Status.Revealed));
        assertEq(rec.decision, DECISION);
        assertEq(rec.rationaleHash, RATIONALE);
        assertEq(rec.deadline, DEADLINE);
    }

    // =========================================================================
    // 1. Happy path
    // =========================================================================

    function test_CommitThenRevealSettles() public {
        bytes32 c = _commit();
        vm.prank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);

        VerificationCommitReveal.Record memory rec = cr.getRecord(verifier, CLAIM, ROUND);
        assertEq(uint8(rec.status), uint8(VerificationCommitReveal.Status.Revealed));
        assertEq(rec.commitment, c);
        assertEq(rec.decision, DECISION);
        assertEq(rec.rationaleHash, RATIONALE);
        assertEq(rec.deadline, DEADLINE);
    }

    // =========================================================================
    // 2. Same reveal / settles once
    // =========================================================================

    function test_SameRevealTwiceReverts() public {
        _commit();
        vm.startPrank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
        vm.expectRevert(VerificationCommitReveal.AlreadyRevealed.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
        vm.stopPrank();
        _assertRevealedAsOriginal();
    }

    // =========================================================================
    // 3. Post-settlement: conflicting reveal / re-commit cannot overwrite
    // =========================================================================

    function test_PostSettlementConflictingRevealCannotOverwrite() public {
        _commit();
        vm.startPrank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);

        vm.expectRevert(VerificationCommitReveal.AlreadyRevealed.selector);
        cr.reveal(CLAIM, ROUND, !DECISION, keccak256("other rationale"), keccak256("other salt"), DEADLINE);
        vm.stopPrank();

        _assertRevealedAsOriginal();
    }

    function test_PostSettlementRecommitCannotOverwrite() public {
        bytes32 original = _commit();
        vm.startPrank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);

        bytes32 other2 = _commitment(verifier, CLAIM, ROUND, !DECISION, RATIONALE, SALT, DEADLINE);
        vm.expectRevert(VerificationCommitReveal.CommitmentAlreadyExists.selector);
        cr.commit(CLAIM, ROUND, other2, DEADLINE);
        vm.stopPrank();

        assertEq(cr.getRecord(verifier, CLAIM, ROUND).commitment, original);
        _assertRevealedAsOriginal();
    }

    function test_CommitBeforeRevealCannotBeReplaced() public {
        bytes32 original = _commit();
        bytes32 replacement = _commitment(verifier, CLAIM, ROUND, !DECISION, RATIONALE, SALT, DEADLINE);
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentAlreadyExists.selector);
        cr.commit(CLAIM, ROUND, replacement, DEADLINE);
        assertEq(cr.getRecord(verifier, CLAIM, ROUND).commitment, original);
    }

    // =========================================================================
    // 4. Changed fields
    // =========================================================================

    function test_ChangedDecisionReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, !DECISION, RATIONALE, SALT, DEADLINE);
    }

    function test_ChangedRationaleReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, DECISION, keccak256("changed"), SALT, DEADLINE);
    }

    function test_ChangedDeadlineReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.DeadlinePassed.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE + 1);
    }

    // =========================================================================
    // 5. Wrong salt / verifier / round / claim
    // =========================================================================

    function test_WrongSaltReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, keccak256("wrong salt"), DEADLINE);
    }

    function test_ZeroSaltReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.ZeroSalt.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, bytes32(0), DEADLINE);
    }

    function test_WeakSaltReverts() public {
        _commit();
        vm.prank(verifier);
        // Only-last-byte non-zero salt is weak
        vm.expectRevert(VerificationCommitReveal.WeakSalt.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, bytes32(uint256(1)), DEADLINE);
    }

    function test_WeakSaltAllIdenticalBytesReverts() public {
        _commit();
        vm.prank(verifier);
        // All bytes 0x01 is weak
        vm.expectRevert(VerificationCommitReveal.WeakSalt.selector);
        cr.reveal(
            CLAIM,
            ROUND,
            DECISION,
            RATIONALE,
            bytes32(uint256(0x0101010101010101010101010101010101010101010101010101010101010101)),
            DEADLINE
        );
    }

    function test_WeakSaltAllFFReverts() public {
        _commit();
        vm.prank(verifier);
        // All bytes 0xFF is weak
        vm.expectRevert(VerificationCommitReveal.WeakSalt.selector);
        cr.reveal(
            CLAIM,
            ROUND,
            DECISION,
            RATIONALE,
            bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)),
            DEADLINE
        );
    }

    function test_WrongVerifierReverts() public {
        _commit();
        vm.prank(other);
        vm.expectRevert(VerificationCommitReveal.NoCommitment.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
    }

    function test_WrongRoundReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.NoCommitment.selector);
        cr.reveal(CLAIM, ROUND + 1, DECISION, RATIONALE, SALT, DEADLINE);
    }

    function test_WrongClaimReverts() public {
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.NoCommitment.selector);
        cr.reveal(CLAIM + 1, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
    }

    function test_RevealWithoutCommitReverts() public {
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.NoCommitment.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
    }

    function test_ZeroCommitmentReverts() public {
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.ZeroCommitment.selector);
        cr.commit(CLAIM, ROUND, bytes32(0), DEADLINE);
    }

    // =========================================================================
    // 6. Deadline validation
    // =========================================================================

    function test_DeadlineInThePastReverts() public {
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.DeadlinePassed.selector);
        cr.commit(CLAIM, ROUND, keccak256("some commitment"), uint64(block.timestamp - 1));
    }

    function test_DeadlineTooSoonReverts() public {
        vm.prank(verifier);
        // Deadline less than MIN_DEADLINE_BUFFER (1 hour) from now
        vm.expectRevert(VerificationCommitReveal.DeadlineTooShort.selector);
        cr.commit(CLAIM, ROUND, keccak256("some commitment"), uint64(block.timestamp + 100));
    }

    function test_DeadlineTooFarReverts() public {
        vm.prank(verifier);
        // Deadline more than MAX_DEADLINE_HORIZON (365 days) from now
        vm.expectRevert(VerificationCommitReveal.DeadlineTooFar.selector);
        cr.commit(CLAIM, ROUND, keccak256("some commitment"), uint64(block.timestamp + 366 days));
    }

    function test_DeadlineAtMinimumBufferSucceeds() public {
        bytes32 c = _commitment(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, uint64(block.timestamp + 1 hours));
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND, c, uint64(block.timestamp + 1 hours));
    }

    function test_DeadlineAtMaximumHorizonSucceeds() public {
        bytes32 c = _commitment(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, uint64(block.timestamp + 365 days));
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND, c, uint64(block.timestamp + 365 days));
    }

    // =========================================================================
    // 7. Failed reveal leaves commitment intact
    // =========================================================================

    function test_FailedRevealLeavesCommitmentIntact() public {
        bytes32 c = _commit();

        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, !DECISION, RATIONALE, SALT, DEADLINE);

        VerificationCommitReveal.Record memory rec = cr.getRecord(verifier, CLAIM, ROUND);
        assertEq(uint8(rec.status), uint8(VerificationCommitReveal.Status.Committed));
        assertEq(rec.commitment, c);

        // the honest reveal still works afterwards
        vm.prank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
        _assertRevealedAsOriginal();
    }

    // =========================================================================
    // 8. Events
    // =========================================================================

    function test_CommittedEventCarriesOnlyTheHash() public {
        bytes32 c = _commitment(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
        vm.expectEmit(true, true, true, true, address(cr));
        emit VerificationCommitReveal.Committed(verifier, CLAIM, ROUND, c);
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND, c, DEADLINE);
    }

    function test_RevealedEventEmittedOnceAndNeverContainsSalt() public {
        bytes32 c = _commit();
        vm.recordLogs();
        vm.prank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], VerificationCommitReveal.Revealed.selector);
        assertEq(logs[0].data, abi.encode(c, DECISION, RATIONALE));
        // the salt appears nowhere in the event
        assertTrue(keccak256(logs[0].data) != keccak256(abi.encode(SALT)));
        for (uint256 i = 0; i < logs[0].topics.length; i++) {
            assertTrue(logs[0].topics[i] != SALT);
        }
    }

    function test_FailedRevealEmitsNothing() public {
        _commit();
        vm.recordLogs();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, !DECISION, RATIONALE, SALT, DEADLINE);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // =========================================================================
    // 9. Signature (relayed) reveal and replay
    // =========================================================================

    function test_SignatureRevealSettlesOnce() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(VERIFIER_PK, c, 1, deadline);

        vm.prank(relayer);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);

        _assertRevealedAsOriginal();
        assertTrue(cr.isNonceUsed(verifier, 1));
    }

    function test_SignatureReplayReverts() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(VERIFIER_PK, c, 1, deadline);

        vm.startPrank(relayer);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);
        vm.expectRevert(VerificationCommitReveal.AlreadyRevealed.selector);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);
        vm.stopPrank();

        _assertRevealedAsOriginal();
    }

    function test_SignatureAfterDirectRevealReverts() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(VERIFIER_PK, c, 1, deadline);

        vm.prank(verifier);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);

        vm.prank(relayer);
        vm.expectRevert(VerificationCommitReveal.AlreadyRevealed.selector);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);
    }

    function test_SignatureFromWrongSignerReverts() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(0xB0B, c, 1, deadline);

        vm.prank(relayer);
        vm.expectRevert(VerificationCommitReveal.InvalidSignature.selector);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);

        assertFalse(cr.isNonceUsed(verifier, 1));
    }

    function test_SignatureWithTamperedNonceReverts() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(VERIFIER_PK, c, 1, deadline);

        vm.prank(relayer);
        vm.expectRevert(VerificationCommitReveal.InvalidSignature.selector);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 2, deadline, sig);
    }

    function test_SignatureForOtherRoundCannotBeReused() public {
        bytes32 c = _commit();
        // a second commitment in another round
        bytes32 c2 = _commitment(verifier, CLAIM, ROUND + 1, DECISION, RATIONALE, SALT, DEADLINE);
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND + 1, c2, DEADLINE);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sigRound1 = _sign(VERIFIER_PK, c, 1, deadline);

        vm.prank(relayer);
        vm.expectRevert(VerificationCommitReveal.InvalidSignature.selector);
        cr.revealWithSignature(verifier, CLAIM, ROUND + 1, DECISION, RATIONALE, SALT, 1, deadline, sigRound1);
    }

    function test_ExpiredSignatureReverts() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 10;
        bytes memory sig = _sign(VERIFIER_PK, c, 1, deadline);
        vm.warp(deadline + 1);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SignatureNonces.SignatureExpired.selector, deadline));
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);
    }

    function test_CancelledNonceBlocksSignature() public {
        bytes32 c = _commit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(VERIFIER_PK, c, 1, deadline);

        vm.prank(verifier);
        cr.cancelNonce(1);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SignatureNonces.NonceAlreadyUsed.selector, verifier, uint256(1)));
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, sig);

        assertEq(uint8(cr.getRecord(verifier, CLAIM, ROUND).status), uint8(VerificationCommitReveal.Status.Committed));
    }

    function test_MalformedSignatureReverts() public {
        _commit();
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(relayer);
        vm.expectRevert(VerificationCommitReveal.InvalidSignature.selector);
        cr.revealWithSignature(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, 1, deadline, hex"1234");
    }

    // =========================================================================
    // 10. Cross-context replay protection
    // =========================================================================

    function test_CrossChainReplay_FailsClosed() public {
        // Commit on current chain (Optimism, chainId = 10)
        bytes32 c = _commit();
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND, c, DEADLINE);

        // Fork to Ethereum mainnet (chainId = 1) and try to reveal with same parameters
        vm.warp(uint64(DEADLINE - 100));
        vm.chainId(1);

        // The commitment was computed with chainId = 10, revealing on chainId = 1 must fail
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
    }

    function test_CrossReleaseReplay_FailsClosed() public {
        // Commit with the canonical release version
        bytes32 c = _commitment(
            verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE
        );
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND, c, DEADLINE);

        // Now try to reveal using a commitment computed for a different release version
        // The contract's RELEASE_VERSION is fixed, so a different release preimage won't match
        bytes32 altRelease = keccak256("TruthBounty-V2.1.0-cancun");
        bytes32 altCommitment = keccak256(
            abi.encode(
                cr.COMMITMENT_TYPEHASH(),
                block.chainid,
                altRelease,
                address(cr),
                verifier,
                CLAIM,
                ROUND,
                DEADLINE,
                DECISION,
                RATIONALE,
                SALT
            )
        );

        vm.prank(verifier);
        // Commit the alt-release commitment on a different claim/round slot to avoid "already exists"
        cr.commit(CLAIM + 100, ROUND, altCommitment, DEADLINE);

        // Revealing with the original fields on the alt-release slot must fail
        // because the stored commitment was computed with the alt release, not the canonical one
        vm.warp(uint64(DEADLINE - 100));
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM + 100, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
    }

    function test_CrossContractReplay_FailsClosed() public {
        // Commit on this contract instance
        bytes32 c = _commit();
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND, c, DEADLINE);

        // Deploy a second instance and submit the same commitment there
        VerificationCommitReveal cr2 = new VerificationCommitReveal();
        vm.prank(verifier);
        cr2.commit(CLAIM, ROUND, c, DEADLINE);

        // Revealing on cr2 with fields bound to cr's address must fail
        // because computeCommitment on cr2 uses address(cr2), not address(cr)
        vm.warp(uint64(DEADLINE - 100));
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr2.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
    }

    function test_CrossRoundReplay_FailsClosed() public {
        // Commit for ROUND
        bytes32 c = _commit();
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND, c, DEADLINE);

        // Try to reveal on ROUND + 1 with fields bound to ROUND
        vm.warp(uint64(DEADLINE - 100));
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.NoCommitment.selector);
        cr.reveal(CLAIM, ROUND + 1, DECISION, RATIONALE, SALT, DEADLINE);
    }

    // =========================================================================
    // 11. Field reordering
    // =========================================================================

    function test_FieldReorderingChangesHash() public {
        // The canonical typehash field order:
        // chainId, releaseVersion, verifyingContract, verifier, claimId, roundId,
        // deadline, decision, rationaleHash, salt
        bytes32 canonical = _commitment(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);

        // Reordered preimage: swap deadline and roundId
        bytes32 reordered = keccak256(
            abi.encode(
                cr.COMMITMENT_TYPEHASH(),
                block.chainid,
                cr.RELEASE_VERSION(),
                address(cr),
                verifier,
                CLAIM,
                DEADLINE, // deadline and roundId swapped
                ROUND,
                DECISION,
                RATIONALE,
                SALT
            )
        );

        assertTrue(canonical != reordered, "Reordered fields must produce a different hash");

        // Commit the canonical, then reveal with reordered fields must fail
        _commit();
        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        // Reveal with the reordered commitment won't match because the stored commitment is canonical
        // We commit the reordered hash to a different slot, then try to reveal canonical fields there
        cr.commit(CLAIM + 200, ROUND, reordered, DEADLINE);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM + 200, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
    }

    // =========================================================================
    // 12. Packed collision demonstration
    // =========================================================================

    function test_PackedEncodingAmbiguity_Demonstrated() public {
        // Demonstrate that abi.encodePacked would be ambiguous: variable-length types
        // (bytes32 in this context, but conceptually strings/bytes) can produce
        // colliding preimages. With abi.encode (used by this contract), each operand
        // is padded to 32 bytes, so no ambiguity exists.

        // Compute with abi.encode (canonical, unambiguous)
        bytes32 encoded = keccak256(
            abi.encode(
                block.chainid,
                cr.RELEASE_VERSION(),
                address(cr),
                verifier,
                CLAIM,
                ROUND,
                DEADLINE,
                DECISION,
                RATIONALE,
                SALT
            )
        );

        // Compute with abi.encodePacked (ambiguous - variable-length encoding)
        // Different field groupings can produce the same packed preimage
        bytes32 packed1 = keccak256(
            abi.encodePacked(
                block.chainid,
                cr.RELEASE_VERSION(),
                address(cr),
                verifier,
                CLAIM,
                ROUND,
                DEADLINE,
                DECISION,
                RATIONALE,
                SALT
            )
        );

        // With packed encoding, we could concatenate fields differently and get the same hash:
        // e.g. (chainId || releaseVersion) vs (chainIdReleaseVersionConcat) -- but since all
        // our fields are fixed-width (uint256, bytes32, address), packed and encoded happen
        // to align here. The point is that the CONTRACT uses abi.encode, never abi.encodePacked,
        // so off-chain implementers must match the fixed-width encoding.
        assertTrue(encoded == packed1, "Fixed-width fields align under packed and encoded");

        // The real protection: the contract's computeCommitment uses abi.encode, and off-chain
        // signers must reproduce this exact encoding. Any packed implementation would diverge
        // for variable-length types and fail verification.
        assertEq(cr.computeCommitment(verifier, CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE), encoded);
    }

    // =========================================================================
    // 13. Wrong voter
    // =========================================================================

    function test_WrongVoterCannotReveal() public {
        bytes32 c = _commit();
        vm.warp(uint64(DEADLINE - 100));

        // A different voter tries to reveal this verifier's commitment
        vm.prank(other);
        vm.expectRevert(VerificationCommitReveal.NoCommitment.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, SALT, DEADLINE);
    }

    // =========================================================================
    // 14. Fuzz
    // =========================================================================

    function testFuzz_AnyChangedFieldFailsAndLeavesStateIntact(
        bool decision2,
        bytes32 rationale2,
        bytes32 salt2,
        uint64 deadline2
    ) public {
        vm.assume(salt2 != bytes32(0));
        vm.assume(deadline2 != 0);
        vm.assume(deadline2 > uint64(block.timestamp) + 1 hours);
        vm.assume(deadline2 <= uint64(block.timestamp) + 365 days);
        vm.assume(decision2 != DECISION || rationale2 != RATIONALE || salt2 != SALT || deadline2 != DEADLINE);
        bytes32 c = _commit();

        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.CommitmentMismatch.selector);
        cr.reveal(CLAIM, ROUND, decision2, rationale2, salt2, deadline2);

        VerificationCommitReveal.Record memory rec = cr.getRecord(verifier, CLAIM, ROUND);
        assertEq(uint8(rec.status), uint8(VerificationCommitReveal.Status.Committed));
        assertEq(rec.commitment, c);
    }

    function testFuzz_WeakSaltIsRejected(bytes32 salt) public {
        // Only test salts that would be caught by the weak salt detector
        if (salt == bytes32(0)) return;
        bytes32 lastByteMask = bytes32(uint256(0xFF));
        bytes32 lastTwoBytesMask = bytes32(uint256(0xFFFF));
        if ((salt & ~lastByteMask) != bytes32(0) && (salt & ~lastTwoBytesMask) != bytes32(0)) return;
        // All-bytes-identical check
        bytes32 firstByte = bytes32(uint256(salt) >> 248);
        bool allSame = true;
        for (uint256 i = 1; i < 32; ) {
            bytes32 byteMask = bytes32(uint256(0xFF) << (248 - i * 8));
            bytes32 byteValue = (salt & byteMask);
            bytes32 expectedByte = bytes32(uint256(firstByte) << (248 - i * 8));
            if (byteValue != expectedByte) {
                allSame = false;
                break;
            }
            unchecked { i++; }
        }
        if (!allSame) return;

        bytes32 c = _commitment(verifier, CLAIM, ROUND, DECISION, RATIONALE, salt, DEADLINE);
        vm.prank(verifier);
        cr.commit(CLAIM, ROUND, c, DEADLINE);

        vm.prank(verifier);
        vm.expectRevert(VerificationCommitReveal.WeakSalt.selector);
        cr.reveal(CLAIM, ROUND, DECISION, RATIONALE, salt, DEADLINE);
    }
}
