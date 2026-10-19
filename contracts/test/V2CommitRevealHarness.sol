// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {V2CommitRevealReplayDomain} from "../v2/libraries/V2CommitRevealReplayDomain.sol";

/**
 * @title V2CommitRevealHarness
 * @notice Test-only contract exposing pure library helpers from `V2CommitRevealReplayDomain`
 *         to external callers for property/fuzz testing, cross-domain injection checks,
 *         and vector validation across Foundry and TypeScript.
 * @dev Carries no protocol authority and is never deployed in production.
 */
contract V2CommitRevealHarness {
    function typehash() external pure returns (bytes32) {
        return V2CommitRevealReplayDomain.COMMIT_REVEAL_TYPEHASH;
    }

    function canonicalReleaseVersion() external pure returns (bytes32) {
        return V2CommitRevealReplayDomain.CANONICAL_RELEASE_VERSION;
    }

    function replayDomainVersion() external pure returns (uint16) {
        return V2CommitRevealReplayDomain.REPLAY_DOMAIN_VERSION;
    }

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
    ) external pure returns (bytes32) {
        return V2CommitRevealReplayDomain.computeCommitment(
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
        );
    }

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
    ) external view returns (bytes32) {
        return V2CommitRevealReplayDomain.computeLiveCommitment(
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

    function validateCommitWindow(uint64 commitDeadline, uint64 currentTimestamp) external pure {
        V2CommitRevealReplayDomain.validateCommitWindow(commitDeadline, currentTimestamp);
    }

    function validateRevealWindow(
        uint64 commitDeadline,
        uint64 revealDeadline,
        uint64 currentTimestamp
    ) external pure {
        V2CommitRevealReplayDomain.validateRevealWindow(commitDeadline, revealDeadline, currentTimestamp);
    }

    function validateRevealExpired(uint64 revealDeadline, uint64 currentTimestamp) external pure {
        V2CommitRevealReplayDomain.validateRevealExpired(revealDeadline, currentTimestamp);
    }
}
