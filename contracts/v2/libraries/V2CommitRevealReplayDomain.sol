// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IV2CommitReveal} from "../interfaces/IV2CommitReveal.sol";

/**
 * @title V2CommitRevealReplayDomain
 * @notice Canonical cross-domain and replay protection library for TruthBounty V2
 *         commit-reveal voting (PREWAVE-SC-003, #678).
 * @dev Every commitment binds all ten approved dimensions into a single fixed-width
 *      EIP-712-style preimage:
 *        1. chainId: live chain identification (prevents cross-chain replay)
 *        2. releaseVersion: pinned protocol release identifier (prevents cross-release replay)
 *        3. verifyingContract: target contract deployment (prevents cross-contract replay)
 *        4. claimId: claim identifier (prevents cross-claim replay)
 *        5. roundId: verification round identifier (prevents cross-round replay)
 *        6. voter: designated voter account (prevents identity/signature stealing)
 *        7. decision: voter's choice/verdict (hidden until reveal)
 *        8. rationaleHash: digest of off-chain reasoning (hidden until reveal)
 *        9. salt: 256-bit cryptographically secure random salt (hidden until reveal)
 *       10. deadline: commit deadline bounding validity (enforces deterministic timing)
 *
 *      Pure encoding rule:
 *      The preimage uses `abi.encode` over fixed-width operands only, eliminating all
 *      ambiguity and collision risks inherent in packed encodings. Mutating any single
 *      dimension strictly changes the commitment hash.
 *
 *      Fail-closed rule:
 *      Zero addresses, zero salts, zero release versions, or zero identifiers revert
 *      immediately before any hash is computed.
 */
library V2CommitRevealReplayDomain {
    /// @notice Canonical release identifier matching the post-Wave-9 V2 deployment.
    bytes32 public constant CANONICAL_RELEASE_VERSION = keccak256("TruthBounty-V2.0.0-cancun");

    /// @notice Domain schema version.
    uint16 public constant REPLAY_DOMAIN_VERSION = 1;

    /// @notice Maximum allowed decision value for verification verdicts (0 = OPPOSE, 1 = SUPPORT).
    uint8 public constant MAX_VERIFICATION_DECISION = 1;

    /// @notice EIP-712 typehash for the commit-reveal operation.
    bytes32 public constant COMMIT_REVEAL_TYPEHASH = keccak256(
        "V2CommitReveal(uint256 chainId,bytes32 releaseVersion,address verifyingContract,uint256 claimId,uint256 roundId,address voter,uint8 decision,bytes32 rationaleHash,bytes32 salt,uint64 deadline)"
    );

    // =========================================================================
    // Commitment Computation
    // =========================================================================

    /**
     * @notice Computes the cryptographic commitment digest binding all 10 replay dimensions.
     * @param chainId Chain ID where the commitment is valid.
     * @param releaseVersion Pinned protocol release version hash.
     * @param verifyingContract Deployment address that accepts the reveal.
     * @param claimId Claim being verified.
     * @param roundId Round identifier within the claim.
     * @param voter Account that authorized the commitment.
     * @param decision The private vote decision (0 or 1).
     * @param rationaleHash keccak256 hash of the off-chain rationale text.
     * @param salt High-entropy 256-bit random salt.
     * @param deadline The commit phase deadline (upper bound of commit window).
     * @return commitment The deterministic keccak256 digest over the fixed-width preimage.
     */
    function computeCommitment(
        uint256 chainId,
        bytes32 releaseVersion,
        address verifyingContract,
        uint256 claimId,
        uint256 roundId,
        address voter,
        uint8 decision,
        bytes32 rationaleHash,
        bytes32 salt,
        uint64 deadline
    ) internal pure returns (bytes32 commitment) {
        validateInputs(chainId, releaseVersion, verifyingContract, claimId, roundId, voter, salt, deadline);
        commitment = keccak256(
            abi.encode(
                COMMIT_REVEAL_TYPEHASH,
                chainId,
                releaseVersion,
                verifyingContract,
                claimId,
                roundId,
                voter,
                decision,
                rationaleHash,
                salt,
                deadline
            )
        );
    }

    /**
     * @notice Computes the commitment with the chain ID read live from `block.chainid`.
     */
    function computeLiveCommitment(
        bytes32 releaseVersion,
        address verifyingContract,
        uint256 claimId,
        uint256 roundId,
        address voter,
        uint8 decision,
        bytes32 rationaleHash,
        bytes32 salt,
        uint64 deadline
    ) internal view returns (bytes32 commitment) {
        return computeCommitment(
            block.chainid,
            releaseVersion,
            verifyingContract,
            claimId,
            roundId,
            voter,
            decision,
            rationaleHash,
            salt,
            deadline
        );
    }

    // =========================================================================
    // Fail-Closed Validation Helpers
    // =========================================================================

    /**
     * @notice Validates that required commitment dimensions are non-zero and within bounds.
     */
    function validateInputs(
        uint256 chainId,
        bytes32 releaseVersion,
        address verifyingContract,
        uint256 claimId,
        uint256 roundId,
        address voter,
        bytes32 salt,
        uint64 deadline
    ) internal pure {
        if (chainId == 0) revert IV2CommitReveal.CommitmentMismatch(bytes32(0), bytes32(0));
        if (releaseVersion == bytes32(0)) revert IV2CommitReveal.CommitmentMismatch(bytes32(0), bytes32(0));
        if (verifyingContract == address(0)) revert IV2CommitReveal.ZeroAddress();
        if (claimId == 0) revert IV2CommitReveal.CommitmentNotFound(0, roundId, voter);
        if (roundId == 0) revert IV2CommitReveal.CommitmentNotFound(claimId, 0, voter);
        if (voter == address(0)) revert IV2CommitReveal.ZeroAddress();
        if (salt == bytes32(0)) revert IV2CommitReveal.ZeroSalt();
        if (deadline == 0) revert IV2CommitReveal.CommitDeadlinePassed(0, 0);
    }

    /**
     * @notice Validates that the current block timestamp is within the active commit window.
     * @dev Inclusive upper bound: timestamp <= commitDeadline.
     */
    function validateCommitWindow(uint64 commitDeadline, uint64 currentTimestamp) internal pure {
        if (currentTimestamp > commitDeadline) {
            revert IV2CommitReveal.CommitDeadlinePassed(currentTimestamp, commitDeadline);
        }
    }

    /**
     * @notice Validates that the current block timestamp is strictly within the reveal window.
     * @dev Commit window must be closed (timestamp > commitDeadline) and reveal window open
     *      (timestamp <= revealDeadline).
     */
    function validateRevealWindow(
        uint64 commitDeadline,
        uint64 revealDeadline,
        uint64 currentTimestamp
    ) internal pure {
        if (currentTimestamp <= commitDeadline) {
            revert IV2CommitReveal.RevealWindowNotOpen(currentTimestamp, commitDeadline);
        }
        if (currentTimestamp > revealDeadline) {
            revert IV2CommitReveal.RevealDeadlinePassed(currentTimestamp, revealDeadline);
        }
    }

    /**
     * @notice Validates that the reveal window has passed for missed reveal processing.
     * @dev Strictly after reveal deadline: timestamp > revealDeadline.
     */
    function validateRevealExpired(uint64 revealDeadline, uint64 currentTimestamp) internal pure {
        if (currentTimestamp <= revealDeadline) {
            revert IV2CommitReveal.RevealDeadlineNotPassed(currentTimestamp, revealDeadline);
        }
    }
}
