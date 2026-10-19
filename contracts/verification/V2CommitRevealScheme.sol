// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IV2CommitReveal} from "../v2/interfaces/IV2CommitReveal.sol";
import {V2CommitRevealReplayDomain} from "../v2/libraries/V2CommitRevealReplayDomain.sol";
import {V2TimeBounds} from "../v2/libraries/V2TimeBounds.sol";

/**
 * @title V2CommitRevealScheme
 * @notice Authoritative V2 implementation of commit-reveal privacy, timing boundaries,
 *         and cross-domain replay protection (PREWAVE-SC-003, #678).
 * @dev Enforces:
 *      1. Zero-leakage commitment phase: choices, salts, and rationales remain strictly off-chain.
 *      2. 10-dimensional domain separation: cross-claim, cross-round, cross-chain, and cross-release
 *         replays fail closed with typed reverts.
 *      3. Deterministic timing: commit window (<= commitDeadline), reveal window (> commitDeadline and <= revealDeadline),
 *         and post-deadline expiry (> revealDeadline) mapped strictly to Optimism's authoritative `block.timestamp`.
 *      4. Replacement policy: permits replacement before commitDeadline under ALLOWED_BEFORE_DEADLINE,
 *         or strictly rejects under FORBIDDEN.
 *      5. Missed-reveal and slashing lifecycle: guarantees complete event emissions for off-chain indexers and audit readiness.
 */
contract V2CommitRevealScheme is AccessControl, Pausable, ReentrancyGuard, IV2CommitReveal {
    bytes32 public constant ROUND_MANAGER_ROLE = keccak256("ROUND_MANAGER_ROLE");
    bytes32 public constant SLASH_ADMIN_ROLE = keccak256("SLASH_ADMIN_ROLE");

    /// @notice Pinned release version identifier for cross-release replay protection.
    bytes32 public immutable releaseVersion;

    /// @notice Mapping from claimId => roundId => RoundTiming.
    mapping(uint256 => mapping(uint256 => RoundTiming)) private _rounds;

    /// @notice Mapping from claimId => roundId => voter => CommitmentRecord.
    mapping(uint256 => mapping(uint256 => mapping(address => CommitmentRecord))) private _commitments;

    /// @notice Mapping from claimId => roundId => list of participating voter addresses.
    mapping(uint256 => mapping(uint256 => address[])) private _roundVoters;

    constructor(address admin, bytes32 releaseVersion_) {
        if (admin == address(0)) revert ZeroAddress();
        releaseVersion = releaseVersion_ == bytes32(0)
            ? V2CommitRevealReplayDomain.CANONICAL_RELEASE_VERSION
            : releaseVersion_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ROUND_MANAGER_ROLE, admin);
        _grantRole(SLASH_ADMIN_ROLE, admin);
    }

    // =========================================================================
    // Emergency Controls
    // =========================================================================

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // =========================================================================
    // Round Registration
    // =========================================================================

    /**
     * @inheritdoc IV2CommitReveal
     */
    function registerRound(
        uint256 claimId,
        uint256 roundId,
        uint64 commitDeadline,
        uint64 revealDeadline,
        ReplacementPolicy policy
    ) external onlyRole(ROUND_MANAGER_ROLE) whenNotPaused {
        if (claimId == 0 || roundId == 0) revert CommitmentNotFound(claimId, roundId, address(0));
        if (_rounds[claimId][roundId].exists) revert RoundAlreadyRegistered(claimId, roundId);

        uint64 nowTs = uint64(block.timestamp);
        if (commitDeadline <= nowTs || revealDeadline <= commitDeadline) {
            revert InvalidDeadlines(nowTs, commitDeadline, revealDeadline);
        }

        // Enforce protocol minimum duration envelopes
        if (commitDeadline - nowTs < V2TimeBounds.MIN_ROUND_DURATION) {
            revert InvalidDeadlines(nowTs, commitDeadline, revealDeadline);
        }
        if (revealDeadline - commitDeadline < V2TimeBounds.MIN_ROUND_DURATION) {
            revert InvalidDeadlines(nowTs, commitDeadline, revealDeadline);
        }

        _rounds[claimId][roundId] = RoundTiming({
            startedAt: nowTs,
            commitDeadline: commitDeadline,
            revealDeadline: revealDeadline,
            replacementPolicy: policy,
            exists: true
        });

        emit RoundRegistered(claimId, roundId, nowTs, commitDeadline, revealDeadline, policy);
    }

    // =========================================================================
    // Commit Phase
    // =========================================================================

    /**
     * @inheritdoc IV2CommitReveal
     */
    function commit(
        uint256 claimId,
        uint256 roundId,
        bytes32 commitmentHash,
        uint256 stakeAmount
    ) external whenNotPaused nonReentrant {
        RoundTiming memory round = _rounds[claimId][roundId];
        if (!round.exists) revert RoundNotFound(claimId, roundId);
        if (commitmentHash == bytes32(0)) revert ZeroCommitment();

        uint64 nowTs = uint64(block.timestamp);
        V2CommitRevealReplayDomain.validateCommitWindow(round.commitDeadline, nowTs);

        CommitmentRecord storage record = _commitments[claimId][roundId][msg.sender];

        if (record.state == CommitState.NONE) {
            // Initial commit
            record.commitmentHash = commitmentHash;
            record.committedAt = nowTs;
            record.commitDeadline = round.commitDeadline;
            record.revealDeadline = round.revealDeadline;
            record.stakeAmount = stakeAmount;
            record.replacementCount = 0;
            record.state = CommitState.COMMITTED;

            _roundVoters[claimId][roundId].push(msg.sender);

            emit CommitSubmitted(
                claimId,
                roundId,
                msg.sender,
                commitmentHash,
                round.commitDeadline,
                round.revealDeadline,
                stakeAmount,
                nowTs
            );
        } else if (record.state == CommitState.COMMITTED) {
            // Replacement attempt
            if (round.replacementPolicy == ReplacementPolicy.FORBIDDEN) {
                revert CommitReplacementForbidden(claimId, roundId, msg.sender);
            }

            bytes32 oldHash = record.commitmentHash;
            record.commitmentHash = commitmentHash;
            record.committedAt = nowTs;
            record.stakeAmount = stakeAmount;
            record.replacementCount += 1;

            emit CommitReplaced(
                claimId,
                roundId,
                msg.sender,
                oldHash,
                commitmentHash,
                record.replacementCount,
                nowTs
            );
        } else if (record.state == CommitState.REVEALED) {
            revert CommitmentAlreadyRevealed(claimId, roundId, msg.sender);
        } else {
            revert CommitmentAlreadySlashed(claimId, roundId, msg.sender);
        }
    }

    // =========================================================================
    // Reveal Phase
    // =========================================================================

    /**
     * @inheritdoc IV2CommitReveal
     */
    function reveal(
        uint256 claimId,
        uint256 roundId,
        uint8 decision,
        bytes32 rationaleHash,
        bytes32 salt
    ) external whenNotPaused nonReentrant {
        RoundTiming memory round = _rounds[claimId][roundId];
        if (!round.exists) revert RoundNotFound(claimId, roundId);

        uint64 nowTs = uint64(block.timestamp);
        V2CommitRevealReplayDomain.validateRevealWindow(round.commitDeadline, round.revealDeadline, nowTs);

        if (decision > V2CommitRevealReplayDomain.MAX_VERIFICATION_DECISION) {
            revert InvalidDecision(decision);
        }

        CommitmentRecord storage record = _commitments[claimId][roundId][msg.sender];
        if (record.state == CommitState.NONE) {
            revert CommitmentNotFound(claimId, roundId, msg.sender);
        }
        if (record.state == CommitState.REVEALED) {
            revert CommitmentAlreadyRevealed(claimId, roundId, msg.sender);
        }
        if (record.state != CommitState.COMMITTED) {
            revert CommitmentAlreadySlashed(claimId, roundId, msg.sender);
        }

        // Recompute commitment over exact 10-dimensional domain
        bytes32 expectedDigest = V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            releaseVersion,
            address(this),
            claimId,
            roundId,
            msg.sender,
            decision,
            rationaleHash,
            salt,
            round.commitDeadline
        );

        if (expectedDigest != record.commitmentHash) {
            revert CommitmentMismatch(record.commitmentHash, expectedDigest);
        }

        record.state = CommitState.REVEALED;

        emit VoteRevealed(
            claimId,
            roundId,
            msg.sender,
            decision,
            rationaleHash,
            record.stakeAmount,
            nowTs
        );
    }

    // =========================================================================
    // Missed Reveal & Slashing Phase
    // =========================================================================

    /**
     * @inheritdoc IV2CommitReveal
     */
    function recordMissedReveal(
        uint256 claimId,
        uint256 roundId,
        address voter
    ) external whenNotPaused {
        if (voter == address(0)) revert ZeroAddress();
        RoundTiming memory round = _rounds[claimId][roundId];
        if (!round.exists) revert RoundNotFound(claimId, roundId);

        uint64 nowTs = uint64(block.timestamp);
        V2CommitRevealReplayDomain.validateRevealExpired(round.revealDeadline, nowTs);

        CommitmentRecord storage record = _commitments[claimId][roundId][voter];
        if (record.state == CommitState.NONE) revert CommitmentNotFound(claimId, roundId, voter);
        if (record.state == CommitState.REVEALED) revert CommitmentAlreadyRevealed(claimId, roundId, voter);
        if (record.state != CommitState.COMMITTED) revert CommitmentAlreadySlashed(claimId, roundId, voter);

        record.state = CommitState.MISSED_REVEAL;

        emit MissedRevealRecorded(
            claimId,
            roundId,
            voter,
            record.commitmentHash,
            record.stakeAmount,
            nowTs
        );
    }

    /**
     * @inheritdoc IV2CommitReveal
     */
    function slashMissedReveal(
        uint256 claimId,
        uint256 roundId,
        address voter,
        uint256 slashBps
    ) external onlyRole(SLASH_ADMIN_ROLE) whenNotPaused nonReentrant returns (uint256 slashAmount) {
        if (voter == address(0)) revert ZeroAddress();
        if (slashBps > 10_000) revert InvalidSlashBps(slashBps);

        RoundTiming memory round = _rounds[claimId][roundId];
        if (!round.exists) revert RoundNotFound(claimId, roundId);

        uint64 nowTs = uint64(block.timestamp);
        V2CommitRevealReplayDomain.validateRevealExpired(round.revealDeadline, nowTs);

        CommitmentRecord storage record = _commitments[claimId][roundId][voter];
        if (record.state == CommitState.NONE) revert CommitmentNotFound(claimId, roundId, voter);
        if (record.state == CommitState.REVEALED) revert CommitmentAlreadyRevealed(claimId, roundId, voter);
        if (record.state == CommitState.SLASHED) revert CommitmentAlreadySlashed(claimId, roundId, voter);

        slashAmount = (record.stakeAmount * slashBps) / 10_000;
        uint256 remainingStake = record.stakeAmount - slashAmount;

        record.state = CommitState.SLASHED;
        record.stakeAmount = remainingStake;

        emit VoterSlashed(
            claimId,
            roundId,
            voter,
            slashAmount,
            remainingStake,
            record.commitmentHash,
            nowTs
        );
    }

    // =========================================================================
    // View Queries
    // =========================================================================

    /**
     * @inheritdoc IV2CommitReveal
     */
    function getCommitment(
        uint256 claimId,
        uint256 roundId,
        address voter
    ) external view returns (CommitmentRecord memory) {
        return _commitments[claimId][roundId][voter];
    }

    /**
     * @inheritdoc IV2CommitReveal
     */
    function getRound(
        uint256 claimId,
        uint256 roundId
    ) external view returns (RoundTiming memory) {
        return _rounds[claimId][roundId];
    }

    /**
     * @notice Returns the list of all participating voters for a round.
     */
    function getRoundVoters(
        uint256 claimId,
        uint256 roundId
    ) external view returns (address[] memory) {
        return _roundVoters[claimId][roundId];
    }

    /**
     * @notice Helper to recompute the commitment hash for off-chain and test parity.
     */
    function computeCommitmentHash(
        uint256 claimId,
        uint256 roundId,
        address voter,
        uint8 decision,
        bytes32 rationaleHash,
        bytes32 salt
    ) external view returns (bytes32) {
        RoundTiming memory round = _rounds[claimId][roundId];
        if (!round.exists) revert RoundNotFound(claimId, roundId);
        return V2CommitRevealReplayDomain.computeCommitment(
            block.chainid,
            releaseVersion,
            address(this),
            claimId,
            roundId,
            voter,
            decision,
            rationaleHash,
            salt,
            round.commitDeadline
        );
    }
}
