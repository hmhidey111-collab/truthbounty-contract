// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EIP712Verifier} from "../../contracts/EIP712Verifier.sol";
import {EIP712CanonicalVectors as V} from "../../contracts/test/EIP712CanonicalVectors.sol";

/// @title EIP712CanonicalVectorsTest
/// @notice On-chain verification of the canonical EIP-712 vectors published for V2-SC-152.
/// @dev The verifier runtime code is placed at {V-VERIFYING_CONTRACT} so `address(this)` — and
///      therefore the domain separator — is exactly the one the published vectors were computed
///      against. No signature is committed anywhere: every signature in this file is produced at
///      runtime from publicly documented Hardhat test keys.
contract EIP712CanonicalVectorsTest is Test {
    /// @dev Hardhat account #0 test key. Publicly documented, test-only, never funded on mainnet.
    uint256 internal constant TEST_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    /// @dev A second documented Hardhat test key, used only as "some other signer".
    uint256 internal constant OTHER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    EIP712Verifier internal verifier;

    function setUp() public {
        vm.chainId(V.CHAIN_ID_MAINNET);
        verifier = _deployVerifierAt(V.VERIFYING_CONTRACT);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    /// @dev Copy the canonical verifier runtime code to an exact address (immutables only hold the
    ///      pre-hashed domain name/version, so the code is address-independent).
    function _deployVerifierAt(address target) internal returns (EIP712Verifier) {
        EIP712Verifier fresh = new EIP712Verifier();
        vm.etch(target, address(fresh).code);
        return EIP712Verifier(target);
    }

    function _claimStructHash(
        address claimant,
        uint256 bountyId,
        bytes32 contentHash,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(V.CLAIM_SUBMISSION_TYPE_HASH, claimant, bountyId, contentHash, nonce, deadline)
            );
    }

    function _intentStructHash(
        address verifier_,
        uint256 bountyId,
        bool approve,
        string memory reason,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    V.VERIFICATION_INTENT_TYPE_HASH,
                    verifier_,
                    bountyId,
                    approve,
                    keccak256(bytes(reason)),
                    nonce,
                    deadline
                )
            );
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Advance `claimant`'s live nonce to `target` by verifying throwaway claims, so the
    ///      published nonce can be reached without touching storage directly.
    function _warmupClaimNonce(address claimant, uint256 target) internal {
        while (verifier.getNonce(claimant) < target) {
            uint256 nonce = verifier.getNonce(claimant);
            bytes32 contentHash = keccak256(abi.encodePacked("canonical-warmup-claim", nonce));
            bytes32 digest = verifier.getClaimSubmissionHash(
                claimant,
                V.BOUNTY_ID_A,
                contentHash,
                nonce,
                V.CANONICAL_DEADLINE
            );
            verifier.verifyClaimSubmission(
                claimant,
                V.BOUNTY_ID_A,
                contentHash,
                V.CANONICAL_DEADLINE,
                _sign(TEST_KEY, digest)
            );
        }
    }

    function _warmupIntentNonce(address verifier_, uint256 target) internal {
        while (verifier.getNonce(verifier_) < target) {
            uint256 nonce = verifier.getNonce(verifier_);
            string memory reason = string.concat("canonical-warmup-intent-", vm.toString(nonce));
            bytes32 digest = verifier.getVerificationIntentHash(
                verifier_,
                V.BOUNTY_ID_A,
                true,
                reason,
                nonce,
                V.CANONICAL_DEADLINE
            );
            verifier.verifyVerificationIntent(
                verifier_,
                V.BOUNTY_ID_A,
                true,
                reason,
                V.CANONICAL_DEADLINE,
                _sign(OTHER_KEY, digest)
            );
        }
    }

    // ---------------------------------------------------------------------
    // type strings, type hashes, domain separators
    // ---------------------------------------------------------------------

    function test_TypeHashesMatchCanonicalTypeStringsAndImplementation() public view {
        // The published type hash is the keccak256 of the published type string.
        assertEq(keccak256(bytes(V.DOMAIN_TYPE_STRING)), V.DOMAIN_TYPE_HASH);
        assertEq(keccak256(bytes(V.CLAIM_TYPE_STRING)), V.CLAIM_SUBMISSION_TYPE_HASH);
        assertEq(keccak256(bytes(V.VERIFICATION_INTENT_TYPE_STRING)), V.VERIFICATION_INTENT_TYPE_HASH);

        // ... and it is the hash the live implementation uses.
        assertEq(verifier.CLAIM_SUBMISSION_TYPEHASH(), V.CLAIM_SUBMISSION_TYPE_HASH);
        assertEq(verifier.VERIFICATION_INTENT_TYPEHASH(), V.VERIFICATION_INTENT_TYPE_HASH);

        // The negative vector is a real drift: one field type changed, different type hash.
        assertTrue(keccak256(bytes(V.MUTATED_CLAIM_TYPE_STRING)) != V.CLAIM_SUBMISSION_TYPE_HASH);
    }

    function test_DomainSeparatorTracksLiveChainIdAndMatchesVectors() public {
        assertEq(verifier.getChainId(), V.CHAIN_ID_MAINNET);
        assertEq(verifier.getDomainSeparator(), V.DOMAIN_SEPARATOR_MAINNET);
        // Independent recomputation of the EIP-712 domain separator formula.
        assertEq(
            keccak256(
                abi.encode(
                    V.DOMAIN_TYPE_HASH,
                    V.NAME_HASH,
                    V.VERSION_HASH,
                    V.CHAIN_ID_MAINNET,
                    V.VERIFYING_CONTRACT
                )
            ),
            V.DOMAIN_SEPARATOR_MAINNET
        );

        vm.chainId(V.CHAIN_ID_LOCAL);
        assertEq(verifier.getChainId(), V.CHAIN_ID_LOCAL);
        assertEq(verifier.getDomainSeparator(), V.DOMAIN_SEPARATOR_LOCAL);
        assertEq(
            keccak256(
                abi.encode(
                    V.DOMAIN_TYPE_HASH,
                    V.NAME_HASH,
                    V.VERSION_HASH,
                    V.CHAIN_ID_LOCAL,
                    V.VERIFYING_CONTRACT
                )
            ),
            V.DOMAIN_SEPARATOR_LOCAL
        );

        vm.chainId(V.CHAIN_ID_MAINNET);
        assertEq(verifier.getDomainSeparator(), V.DOMAIN_SEPARATOR_MAINNET);
    }

    // ---------------------------------------------------------------------
    // positive vectors
    // ---------------------------------------------------------------------

    function test_PositiveClaimSubmissionVectors() public {
        bytes32 structHash = _claimStructHash(
            V.CLAIMANT_A,
            V.BOUNTY_ID_A,
            V.claimAContentHash(),
            V.CLAIM_NONCE_A,
            V.CANONICAL_DEADLINE
        );
        assertEq(structHash, V.CLAIM_MAINNET_STRUCT_HASH);
        assertEq(
            verifier.getClaimSubmissionHash(
                V.CLAIMANT_A,
                V.BOUNTY_ID_A,
                V.claimAContentHash(),
                V.CLAIM_NONCE_A,
                V.CANONICAL_DEADLINE
            ),
            V.CLAIM_MAINNET_DIGEST
        );

        vm.chainId(V.CHAIN_ID_LOCAL);
        assertEq(
            verifier.getClaimSubmissionHash(
                V.CLAIMANT_B,
                V.BOUNTY_ID_B,
                V.claimBContentHash(),
                V.CLAIM_NONCE_B,
                V.CANONICAL_DEADLINE
            ),
            V.CLAIM_LOCAL_DIGEST
        );
        assertTrue(V.CLAIM_LOCAL_DIGEST != V.CLAIM_MAINNET_DIGEST);
    }

    function test_PositiveVerificationIntentVectors() public {
        bytes32 structHash = _intentStructHash(
            V.VERIFIER_A,
            V.BOUNTY_ID_A,
            true,
            V.INTENT_A_REASON,
            V.INTENT_NONCE_A,
            V.CANONICAL_DEADLINE
        );
        assertEq(structHash, V.INTENT_MAINNET_STRUCT_HASH);
        assertEq(
            verifier.getVerificationIntentHash(
                V.VERIFIER_A,
                V.BOUNTY_ID_A,
                true,
                V.INTENT_A_REASON,
                V.INTENT_NONCE_A,
                V.CANONICAL_DEADLINE
            ),
            V.INTENT_MAINNET_DIGEST
        );

        vm.chainId(V.CHAIN_ID_LOCAL);
        assertEq(
            verifier.getVerificationIntentHash(
                V.VERIFIER_A,
                V.BOUNTY_ID_A,
                false,
                V.INTENT_B_REASON,
                V.INTENT_NONCE_B,
                V.CANONICAL_DEADLINE
            ),
            V.INTENT_LOCAL_DIGEST
        );
        assertTrue(V.INTENT_LOCAL_DIGEST != V.INTENT_MAINNET_DIGEST);
    }

    // ---------------------------------------------------------------------
    // negative vectors (each one reproduced by the live contract)
    // ---------------------------------------------------------------------

    function test_NegativeVectors_ChainIdVerifyingContractAndDomainName() public {
        // chain id: the same message on chain 10 produces the published wrong-chain digest.
        vm.chainId(V.CHAIN_ID_WRONG);
        assertEq(
            verifier.getClaimSubmissionHash(
                V.CLAIMANT_A,
                V.BOUNTY_ID_A,
                V.claimAContentHash(),
                V.CLAIM_NONCE_A,
                V.CANONICAL_DEADLINE
            ),
            V.CLAIM_WRONG_CHAIN_ID_DIGEST
        );
        vm.chainId(V.CHAIN_ID_MAINNET);

        // verifying contract: identical bytecode, different deployment address.
        EIP712Verifier otherDeployment = _deployVerifierAt(V.WRONG_VERIFYING_CONTRACT);
        assertEq(
            otherDeployment.getClaimSubmissionHash(
                V.CLAIMANT_A,
                V.BOUNTY_ID_A,
                V.claimAContentHash(),
                V.CLAIM_NONCE_A,
                V.CANONICAL_DEADLINE
            ),
            V.CLAIM_WRONG_VERIFYING_CONTRACT_DIGEST
        );

        // domain name: not deployable through this constructor, so the vector is asserted as a
        // digest that must differ from the canonical one (and it is rejected on-chain in
        // test_NegativeSignatures_RejectedOnChain).
        assertTrue(V.CLAIM_WRONG_DOMAIN_NAME_DIGEST != V.CLAIM_MAINNET_DIGEST);
        assertTrue(V.CLAIM_WRONG_CHAIN_ID_DIGEST != V.CLAIM_MAINNET_DIGEST);
        assertTrue(V.CLAIM_WRONG_VERIFYING_CONTRACT_DIGEST != V.CLAIM_MAINNET_DIGEST);
    }

    function test_NegativeVectors_NonceAndDeadline() public view {
        assertEq(
            verifier.getClaimSubmissionHash(
                V.CLAIMANT_A,
                V.BOUNTY_ID_A,
                V.claimAContentHash(),
                V.CLAIM_NONCE_A + 1,
                V.CANONICAL_DEADLINE
            ),
            V.CLAIM_WRONG_NONCE_DIGEST
        );
        assertEq(
            verifier.getClaimSubmissionHash(
                V.CLAIMANT_A,
                V.BOUNTY_ID_A,
                V.claimAContentHash(),
                V.CLAIM_NONCE_A,
                V.CANONICAL_DEADLINE + 1
            ),
            V.CLAIM_WRONG_DEADLINE_DIGEST
        );
        assertTrue(V.CLAIM_WRONG_NONCE_DIGEST != V.CLAIM_MAINNET_DIGEST);
        assertTrue(V.CLAIM_WRONG_DEADLINE_DIGEST != V.CLAIM_MAINNET_DIGEST);
    }

    function test_NegativeVectors_FieldOrderAndTypeString() public view {
        // Field order drift: same type hash, claimant and bountyId encoded the other way round.
        bytes32 swapped = keccak256(
            abi.encode(
                V.CLAIM_SUBMISSION_TYPE_HASH,
                V.BOUNTY_ID_A,
                V.CLAIMANT_A,
                V.claimAContentHash(),
                V.CLAIM_NONCE_A,
                V.CANONICAL_DEADLINE
            )
        );
        assertEq(swapped, V.CLAIM_MUTATED_FIELD_ORDER_STRUCT_HASH);
        assertTrue(swapped != V.CLAIM_MAINNET_STRUCT_HASH);
        assertTrue(V.CLAIM_MUTATED_FIELD_ORDER_DIGEST != V.CLAIM_MAINNET_DIGEST);

        // Type string drift: one field type widened/narrowed, same values.
        bytes32 mutatedType = keccak256(
            abi.encode(
                keccak256(bytes(V.MUTATED_CLAIM_TYPE_STRING)),
                V.CLAIMANT_A,
                V.BOUNTY_ID_A,
                V.claimAContentHash(),
                V.CLAIM_NONCE_A,
                V.CANONICAL_DEADLINE
            )
        );
        assertEq(mutatedType, V.CLAIM_MUTATED_TYPE_STRING_STRUCT_HASH);
        assertTrue(mutatedType != V.CLAIM_MAINNET_STRUCT_HASH);
        assertTrue(V.CLAIM_MUTATED_TYPE_STRING_DIGEST != V.CLAIM_MAINNET_DIGEST);
    }

    function test_NegativeVectors_IntentApproveFlagAndReason() public view {
        assertEq(
            verifier.getVerificationIntentHash(
                V.VERIFIER_A,
                V.BOUNTY_ID_A,
                false,
                V.INTENT_A_REASON,
                V.INTENT_NONCE_A,
                V.CANONICAL_DEADLINE
            ),
            V.INTENT_WRONG_APPROVE_FLAG_DIGEST
        );
        assertEq(
            verifier.getVerificationIntentHash(
                V.VERIFIER_A,
                V.BOUNTY_ID_A,
                true,
                string.concat(V.INTENT_A_REASON, " "),
                V.INTENT_NONCE_A,
                V.CANONICAL_DEADLINE
            ),
            V.INTENT_WRONG_REASON_DIGEST
        );
        assertTrue(V.INTENT_WRONG_APPROVE_FLAG_DIGEST != V.INTENT_MAINNET_DIGEST);
        assertTrue(V.INTENT_WRONG_REASON_DIGEST != V.INTENT_MAINNET_DIGEST);
    }

    // ---------------------------------------------------------------------
    // signatures: positive on-chain verification, replay, expiry-boundary
    // ---------------------------------------------------------------------

    function test_PositiveClaimVector_VerifiedOnChainWithRuntimeSignature() public {
        address claimant = vm.addr(TEST_KEY);
        assertEq(claimant, V.CLAIMANT_A);
        assertEq(verifier.getNonce(claimant), 0);

        _warmupClaimNonce(claimant, V.CLAIM_NONCE_A);

        // The deadline is an inclusive bound: a signature is accepted at exactly `deadline`.
        vm.warp(V.CANONICAL_DEADLINE);
        bytes32 digest = verifier.getClaimSubmissionHash(
            claimant,
            V.BOUNTY_ID_A,
            V.claimAContentHash(),
            V.CLAIM_NONCE_A,
            V.CANONICAL_DEADLINE
        );
        assertEq(digest, V.CLAIM_MAINNET_DIGEST);

        bytes memory signature = _sign(TEST_KEY, digest);
        assertTrue(
            verifier.verifyClaimSubmission(
                claimant,
                V.BOUNTY_ID_A,
                V.claimAContentHash(),
                V.CANONICAL_DEADLINE,
                signature
            )
        );
        assertEq(verifier.getNonce(claimant), V.CLAIM_NONCE_A + 1);
        assertTrue(verifier.isSignatureUsed(digest));

        // Same signature again: rejected as a replay.
        // The live nonce has advanced, so recovery fails for the rebuilt digest.
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        verifier.verifyClaimSubmission(
            claimant,
            V.BOUNTY_ID_A,
            V.claimAContentHash(),
            V.CANONICAL_DEADLINE,
            signature
        );

        // Expired: one second past the deadline the same digest is refused before any state change.
        bytes32 nextDigest = verifier.getClaimSubmissionHash(
            claimant,
            V.BOUNTY_ID_A,
            V.claimAContentHash(),
            V.CLAIM_NONCE_A + 1,
            V.CANONICAL_DEADLINE
        );
        bytes memory nextSignature = _sign(TEST_KEY, nextDigest);
        vm.warp(V.CANONICAL_DEADLINE + 1);
        vm.expectRevert(EIP712Verifier.SignatureExpired.selector);
        verifier.verifyClaimSubmission(
            claimant,
            V.BOUNTY_ID_A,
            V.claimAContentHash(),
            V.CANONICAL_DEADLINE,
            nextSignature
        );
        assertEq(verifier.getNonce(claimant), V.CLAIM_NONCE_A + 1);
    }

    function test_NegativeSignatures_RejectedOnChain() public {
        address claimant = vm.addr(TEST_KEY);
        _warmupClaimNonce(claimant, V.CLAIM_NONCE_A);

        bytes32 canonicalDigest = verifier.getClaimSubmissionHash(
            claimant,
            V.BOUNTY_ID_A,
            V.claimAContentHash(),
            V.CLAIM_NONCE_A,
            V.CANONICAL_DEADLINE
        );

        // Wrong signer: a valid signature by somebody else is not the claimant's.
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        verifier.verifyClaimSubmission(
            claimant,
            V.BOUNTY_ID_A,
            V.claimAContentHash(),
            V.CANONICAL_DEADLINE,
            _sign(OTHER_KEY, canonicalDigest)
        );

        // Wrong domain name: the published wrong-name digest is rejected on-chain.
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        verifier.verifyClaimSubmission(
            claimant,
            V.BOUNTY_ID_A,
            V.claimAContentHash(),
            V.CANONICAL_DEADLINE,
            _sign(TEST_KEY, V.CLAIM_WRONG_DOMAIN_NAME_DIGEST)
        );

        // Mutated field order: the digest produced by the swapped encoding is rejected.
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        verifier.verifyClaimSubmission(
            claimant,
            V.BOUNTY_ID_A,
            V.claimAContentHash(),
            V.CANONICAL_DEADLINE,
            _sign(TEST_KEY, V.CLAIM_MUTATED_FIELD_ORDER_DIGEST)
        );

        // Mutated type string is rejected too.
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        verifier.verifyClaimSubmission(
            claimant,
            V.BOUNTY_ID_A,
            V.claimAContentHash(),
            V.CANONICAL_DEADLINE,
            _sign(TEST_KEY, V.CLAIM_MUTATED_TYPE_STRING_DIGEST)
        );

        // Cross-chain: signed under chain 10, offered on chain 1.
        vm.chainId(V.CHAIN_ID_WRONG);
        bytes32 crossChainDigest = verifier.getClaimSubmissionHash(
            claimant,
            V.BOUNTY_ID_A,
            V.claimAContentHash(),
            V.CLAIM_NONCE_A,
            V.CANONICAL_DEADLINE
        );
        assertEq(crossChainDigest, V.CLAIM_WRONG_CHAIN_ID_DIGEST);
        bytes memory crossChainSignature = _sign(TEST_KEY, crossChainDigest);
        vm.chainId(V.CHAIN_ID_MAINNET);

        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        verifier.verifyClaimSubmission(
            claimant,
            V.BOUNTY_ID_A,
            V.claimAContentHash(),
            V.CANONICAL_DEADLINE,
            crossChainSignature
        );

        assertEq(verifier.getNonce(claimant), V.CLAIM_NONCE_A);
    }

    function test_PositiveAndNegativeVerificationIntentSignatures() public {
        // A distinct signer keeps its own nonce space, so the canonical nonce is reachable
        // without disturbing the claim-submission nonce tested above.
        address verifier_ = vm.addr(OTHER_KEY);
        _warmupIntentNonce(verifier_, V.INTENT_NONCE_A);
        assertEq(verifier.getNonce(verifier_), V.INTENT_NONCE_A);

        bytes32 digest = verifier.getVerificationIntentHash(
            verifier_,
            V.BOUNTY_ID_A,
            true,
            V.INTENT_A_REASON,
            V.INTENT_NONCE_A,
            V.CANONICAL_DEADLINE
        );
        assertTrue(
            verifier.verifyVerificationIntent(
                verifier_,
                V.BOUNTY_ID_A,
                true,
                V.INTENT_A_REASON,
                V.CANONICAL_DEADLINE,
                _sign(OTHER_KEY, digest)
            )
        );
        assertEq(verifier.getNonce(verifier_), V.INTENT_NONCE_A + 1);
        assertTrue(verifier.isSignatureUsed(digest));

        // The live nonce has advanced, so recovery fails for the rebuilt digest.
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        verifier.verifyVerificationIntent(
            verifier_,
            V.BOUNTY_ID_A,
            true,
            V.INTENT_A_REASON,
            V.CANONICAL_DEADLINE,
            _sign(OTHER_KEY, digest)
        );

        // Flipping `approve` after signing yields a different digest and is rejected.
        bytes32 flippedDigest = verifier.getVerificationIntentHash(
            verifier_,
            V.BOUNTY_ID_A,
            false,
            V.INTENT_A_REASON,
            V.INTENT_NONCE_A + 1,
            V.CANONICAL_DEADLINE
        );
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        verifier.verifyVerificationIntent(
            verifier_,
            V.BOUNTY_ID_A,
            true,
            V.INTENT_A_REASON,
            V.CANONICAL_DEADLINE,
            _sign(OTHER_KEY, flippedDigest)
        );

        // Reason drift: signing a trailing-space reason does not authorise the canonical reason.
        bytes32 reasonDigest = verifier.getVerificationIntentHash(
            verifier_,
            V.BOUNTY_ID_A,
            true,
            string.concat(V.INTENT_A_REASON, " "),
            V.INTENT_NONCE_A + 1,
            V.CANONICAL_DEADLINE
        );
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        verifier.verifyVerificationIntent(
            verifier_,
            V.BOUNTY_ID_A,
            true,
            V.INTENT_A_REASON,
            V.CANONICAL_DEADLINE,
            _sign(OTHER_KEY, reasonDigest)
        );

        assertEq(verifier.getNonce(verifier_), V.INTENT_NONCE_A + 1);
    }

    /// @dev Each mutation signs different bytes while submission remains canonical.
    ///      Exact selectors and unchanged replay state rule out unrelated rejection reasons.
    function test_VerificationIntentMutationMatrix() public {
        address signer = vm.addr(TEST_KEY);
        bytes32 canonicalStruct = _intentStructHash(signer, V.BOUNTY_ID_A, true, V.INTENT_A_REASON, 0, V.CANONICAL_DEADLINE);
        bytes32 domain = verifier.getDomainSeparator();
        bytes32[8] memory digests;
        digests[0] = keccak256(abi.encodePacked(hex"1901", keccak256(abi.encode(
            V.DOMAIN_TYPE_HASH, V.NAME_HASH, V.VERSION_HASH, V.CHAIN_ID_WRONG, address(verifier)
        )), canonicalStruct));
        digests[1] = keccak256(abi.encodePacked(hex"1901", keccak256(abi.encode(
            V.DOMAIN_TYPE_HASH, V.NAME_HASH, V.VERSION_HASH, block.chainid, V.WRONG_VERIFYING_CONTRACT
        )), canonicalStruct));
        digests[2] = keccak256(abi.encodePacked(hex"1901", keccak256(abi.encode(
            V.DOMAIN_TYPE_HASH, keccak256("TruthBountyV2"), V.VERSION_HASH, block.chainid, address(verifier)
        )), canonicalStruct));
        bytes32 reordered = keccak256(abi.encode(
            keccak256("VerificationIntent(uint256 bountyId,address verifier,bool approve,string reason,uint256 nonce,uint256 deadline)"),
            V.BOUNTY_ID_A, signer, true, keccak256(bytes(V.INTENT_A_REASON)), uint256(0), V.CANONICAL_DEADLINE
        ));
        digests[3] = keccak256(abi.encodePacked(hex"1901", domain, reordered));
        digests[4] = verifier.getVerificationIntentHash(signer, V.BOUNTY_ID_A, true, V.INTENT_A_REASON, 1, V.CANONICAL_DEADLINE);
        digests[5] = verifier.getVerificationIntentHash(signer, V.BOUNTY_ID_A, true, V.INTENT_A_REASON, 0, V.CANONICAL_DEADLINE + 1);
        digests[6] = verifier.getVerificationIntentHash(signer, V.BOUNTY_ID_A, false, V.INTENT_A_REASON, 0, V.CANONICAL_DEADLINE);
        digests[7] = verifier.getVerificationIntentHash(signer, V.BOUNTY_ID_A, true, string.concat(V.INTENT_A_REASON, " "), 0, V.CANONICAL_DEADLINE);
        bytes32 canonicalDigest = verifier.getVerificationIntentHash(signer, V.BOUNTY_ID_A, true, V.INTENT_A_REASON, 0, V.CANONICAL_DEADLINE);
        for (uint256 i; i < digests.length; ++i) {
            assertTrue(digests[i] != canonicalDigest, "mutation must change digest");
            bytes memory signature = _sign(TEST_KEY, digests[i]);
            vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
            verifier.verifyVerificationIntent(signer, V.BOUNTY_ID_A, true, V.INTENT_A_REASON, V.CANONICAL_DEADLINE, signature);
            assertEq(verifier.getNonce(signer), 0, "rejected intent must not consume nonce");
            assertFalse(verifier.isSignatureUsed(canonicalDigest));
        }
        assertTrue(verifier.verifyVerificationIntent(signer, V.BOUNTY_ID_A, true, V.INTENT_A_REASON,
            V.CANONICAL_DEADLINE, _sign(TEST_KEY, canonicalDigest)));
    }

    function test_VerificationIntentDeadlineIsInclusive() public {
        address signer = vm.addr(TEST_KEY);
        bytes32 digest = verifier.getVerificationIntentHash(signer, V.BOUNTY_ID_A, true, V.INTENT_A_REASON, 0, V.CANONICAL_DEADLINE);
        bytes memory signature = _sign(TEST_KEY, digest);
        vm.warp(V.CANONICAL_DEADLINE + 1);
        vm.expectRevert(EIP712Verifier.SignatureExpired.selector);
        verifier.verifyVerificationIntent(signer, V.BOUNTY_ID_A, true, V.INTENT_A_REASON, V.CANONICAL_DEADLINE, signature);
        assertEq(verifier.getNonce(signer), 0);
        vm.warp(V.CANONICAL_DEADLINE);
        assertTrue(verifier.verifyVerificationIntent(signer, V.BOUNTY_ID_A, true, V.INTENT_A_REASON, V.CANONICAL_DEADLINE, signature));
    }

    function test_NoncesAreMonotonicAndIndependentPerAccount() public {
        address claimant = vm.addr(TEST_KEY);
        address other = vm.addr(OTHER_KEY);

        _warmupClaimNonce(claimant, 3);
        assertEq(verifier.getNonce(claimant), 3);
        assertEq(verifier.getNonce(other), 0);

        bytes32 otherDigest = verifier.getClaimSubmissionHash(
            other,
            V.BOUNTY_ID_B,
            V.claimBContentHash(),
            0,
            V.CANONICAL_DEADLINE
        );
        // `other` never signed this digest, so the recovery does not match and no nonce moves.
        vm.expectRevert(EIP712Verifier.InvalidSignature.selector);
        verifier.verifyClaimSubmission(
            other,
            V.BOUNTY_ID_B,
            V.claimBContentHash(),
            V.CANONICAL_DEADLINE,
            _sign(TEST_KEY, otherDigest)
        );
        assertEq(verifier.getNonce(other), 0);
        assertEq(verifier.getNonce(claimant), 3);
    }
}
