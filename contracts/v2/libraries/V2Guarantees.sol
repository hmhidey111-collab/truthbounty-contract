// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IConsumerGuarantees } from "../interfaces/IConsumerGuarantees.sol";

/// @title V2Guarantees
/// @notice Pure helpers that let any module publish and consumers validate the
///         authoritative chain reorganization guarantees (V2-SC-134).
/// @dev    Pure only: no state, no authority, no settlement surface. Canonical
///         event identity is defined here so that on-chain publishers and
///         off-chain consumers derive identical keys from identical inputs.
library V2Guarantees {
    // =========================================================================
    // Bounds and defaults
    // =========================================================================

    /// @notice Minimum confirmation depth any published guarantee may declare.
    uint64 internal constant MIN_CONFIRMATION_DEPTH = 1;

    /// @notice Maximum confirmation depth (30 days of Optimism 2s blocks).
    uint64 internal constant MAX_CONFIRMATION_DEPTH = 1_296_000;

    /// @notice Maximum appeal-rollover rounds a single appeal chain may span.
    /// @dev Bounds rollover inputs so principal/custody preservation can be
    ///      proven inductively across a finite, deterministic round count.
    uint64 internal constant MAX_APPEAL_ROUNDS = 64;

    /// @notice Minimum stake (dust floor) any appeal round may carry.
    /// @dev Rounds below this floor are invalid and must fail canonically.
    uint256 internal constant MIN_APPEAL_STAKE = 1;

    /// @notice Maximum stake any single appeal round may carry.
    /// @dev Prevents overflow of cumulative principal across rollover rounds.
    uint256 internal constant MAX_APPEAL_STAKE = type(uint128).max;

    /// @notice Default confirmation depth used by canonical V2 deployments.
    /// @dev Covers L2 sequencer batch windows; ~1 hour of 2-second blocks.
    uint64 internal constant DEFAULT_CONFIRMATION_DEPTH = 1_800;

    /// @notice Maximum reorg depth consumers are expected to absorb.
    uint64 internal constant MAX_REORG_DEPTH = 100_000;

    /// @notice Default reorg-depth tolerance used by canonical V2 deployments.
    uint64 internal constant DEFAULT_REORG_DEPTH = 12;

    /// @notice Strongest finality class canonical V2 streams can offer.
    /// @dev ProtocolFinalized because claim settlement runs through a
    ///      deterministic, timelocked challenge/settlement window; once that
    ///      window has elapsed on confirmed blocks the outcome is final.
    IConsumerGuarantees.FinalityClass internal constant MAX_FINALITY_CLASS =
    IConsumerGuarantees.FinalityClass.ProtocolFinalized;

    // =========================================================================
    // Errors (all library-owned; no contract state is read or written)
    // =========================================================================

    /// @notice A guarantee field violates its bound.
    error InvalidGuarantees(string reason);
    /// @notice The guarantees record is entirely zeroed.
    error ZeroedGuarantees();
    /// @notice A deployment manifest field disagrees with the on-chain record.
    error ManifestMismatch(string field);
    /// @notice A deadline was evaluated with the wrong inclusive/exclusive rule.
    error DeadlineBoundaryViolation(string reason);
    /// @notice An appeal round is invalid (out of range, dust, or over max).
    error InvalidAppealRound(uint64 round);
    /// @notice An appeal rollover would lose, duplicate, or strand principal.
    error AppealRolloverViolation(string reason);
    /// @notice The consumer applied a removal that contradicts canonical log
    ///         identity (defense against corrupt or forged rollback inputs).
    error InvalidRemoval(bytes32 eventKey);

    // =========================================================================
    // Validation
    // =========================================================================

    /// @notice Reverts unless `guarantees` is a publishable record.
    /// @dev Checked in this order: zeroed record, confirmation bounds, reorg
    ///      bounds, strongest-class coherence, finality coherence, and the
    ///      three semantic booleans, which must all be true for the canonical
    ///      V2 event surface.
    function validate(IConsumerGuarantees.ConsumerGuarantees memory guarantees) internal pure {
        if (
            guarantees.confirmationDepth == 0 && guarantees.maxFinalityClass == 0 && guarantees.maxReorgDepth == 0
                && !guarantees.eventsAreReplayable && !guarantees.eventKeysAreUnique
                && !guarantees.eventsAreTerminalOnEmission
        ) {
            revert ZeroedGuarantees();
        }
        if (guarantees.confirmationDepth < MIN_CONFIRMATION_DEPTH) {
            revert InvalidGuarantees("confirmationDepth below minimum");
        }
        if (guarantees.confirmationDepth > MAX_CONFIRMATION_DEPTH) {
            revert InvalidGuarantees("confirmationDepth above maximum");
        }
        if (guarantees.maxReorgDepth > MAX_REORG_DEPTH) {
            revert InvalidGuarantees("maxReorgDepth above maximum");
        }
        if (guarantees.maxReorgDepth == 0) {
            revert InvalidGuarantees("maxReorgDepth must be positive");
        }
        if (guarantees.maxFinalityClass > uint8(MAX_FINALITY_CLASS)) {
            revert InvalidGuarantees("finality class above canonical maximum");
        }
        if (guarantees.confirmationDepth > 0 && guarantees.maxFinalityClass == 0) {
            revert InvalidGuarantees("positive confirmation depth requires non-None finality");
        }
        if (!guarantees.eventsAreReplayable) {
            revert InvalidGuarantees("canonical V2 events must be replayable");
        }
        if (!guarantees.eventKeysAreUnique) {
            revert InvalidGuarantees("canonical V2 event keys must be unique");
        }
        if (!guarantees.eventsAreTerminalOnEmission) {
            revert InvalidGuarantees("canonical V2 events must be terminal on emission");
        }
    }

    // =========================================================================
    // Deadline semantics (inclusive/exclusive)
    // =========================================================================

    /// @notice True when `now` is strictly before the exclusive deadline.
    /// @dev Deadlines are exclusive: the action is valid only while
    ///      `now < deadline`. At `now == deadline` the action is expired.
    function isBeforeDeadline(uint64 now, uint64 deadline) internal pure returns (bool) {
        return now < deadline;
    }

    /// @notice True when `now` is at or after the exclusive deadline.
    /// @dev Complement of `isBeforeDeadline`; exact-deadline is expired.
    function isAtOrAfterDeadline(uint64 now, uint64 deadline) internal pure returns (bool) {
        return now >= deadline;
    }

    /// @notice Reverts unless `now` is strictly before the exclusive deadline.
    /// @dev Canonical error for expired actions; one-second-before passes,
    ///      exact-deadline and one-second-after fail.
    function requireBeforeDeadline(uint64 now, uint64 deadline) internal pure {
        if (!isBeforeDeadline(now, deadline)) {
            revert DeadlineBoundaryViolation("action expired at exclusive deadline");
        }
    }

    // =========================================================================
    // Appeal rollover (principal and custody preservation)
    // =========================================================================

    /// @notice Validates one appeal round's stake against canonical bounds.
    /// @dev Reverts with `InvalidAppealRound` for out-of-range rounds, dust
    ///      stakes below `MIN_APPEAL_STAKE`, and stakes above `MAX_APPEAL_STAKE`.
    function validateAppealRound(uint64 round, uint256 stake) internal pure {
        if (round >= MAX_APPEAL_ROUNDS) {
            revert InvalidAppealRound(round);
        }
        if (stake < MIN_APPEAL_STAKE) {
            revert InvalidAppealRound(round);
        }
        if (stake > MAX_APPEAL_STAKE) {
            revert InvalidAppealRound(round);
        }
    }

    /// @notice Rolls one appeal round's principal and custody forward.
    /// @dev Pure conservation: the returned principal equals the incoming
    ///      principal plus the round stake, and custody is preserved exactly.
    ///      Reverts if the round is invalid or if the addition would overflow,
    ///      so principal can never be lost, duplicated, or stranded.
    function rolloverAppeal(
        uint64 round,
        uint256 principal,
        uint256 stake,
        bytes32 custody
    ) internal pure returns (uint256 newPrincipal, bytes32 newCustody) {
        validateAppealRound(round, stake);
        if (principal > type(uint256).max - stake) {
            revert AppealRolloverViolation("principal overflow on rollover");
        }
        newPrincipal = principal + stake;
        newCustody = custody;
    }

    /// @notice Returns the deployment-default guarantees for Optimism/EVM L2.
    function defaultGuarantees() internal pure returns (IConsumerGuarantees.ConsumerGuarantees memory) {
        return IConsumerGuarantees.ConsumerGuarantees({
            confirmationDepth: DEFAULT_CONFIRMATION_DEPTH,
            maxFinalityClass: uint8(MAX_FINALITY_CLASS),
            maxReorgDepth: DEFAULT_REORG_DEPTH,
            eventsAreReplayable: true,
            eventKeysAreUnique: true,
            eventsAreTerminalOnEmission: true
        });
    }

    /// @notice Finality class implied by an observed confirmation depth, as the
    ///         uint8 ordinal of `IConsumerGuarantees.FinalityClass`.
    /// @dev At or beyond the published confirmation depth the stream offers at
    ///      least SoftConfirmation; ProtocolFinalized additionally requires the
    ///      protocol-level windows to have elapsed (tracked by consumers, not
    ///      by block depth alone).
    function finalityForDepth(IConsumerGuarantees.ConsumerGuarantees memory guarantees, uint64 observedDepth)
        internal
        pure
        returns (uint8)
    {
        if (observedDepth >= guarantees.confirmationDepth) {
            return uint8(IConsumerGuarantees.FinalityClass.SoftConfirmation);
        }
        return uint8(IConsumerGuarantees.FinalityClass.None);
    }

    // =========================================================================
    // Canonical event identity
    // =========================================================================

    /// @notice Deterministic, replay-safe key for one canonical log emission.
    /// @dev `blockHash` is included so the key is reorg-aware: two
    ///      representations of the same (blockNumber, txHash, logIndex) on
    ///      divergent branches produce different keys, and the losing branch is
    ///      removed by `isRemovalCanonical` below.
    function eventKey(
        uint64 chainId,
        address contractAddress,
        uint64 blockNumber,
        bytes32 blockHash,
        bytes32 transactionHash,
        uint64 logIndex
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(chainId, contractAddress, blockNumber, blockHash, transactionHash, logIndex));
    }

    /// @notice True when a removal (orphan rollback) targets exactly the key
    ///         derivable from the canonical log coordinates being removed.
    /// @dev Pure defense: consumers must only ever remove an event whose
    ///      identity they can recompute. Prevents rollback replay that deletes
    ///      canonical events or injects phantom removals.
    function isRemovalCanonical(
        uint64 chainId,
        address contractAddress,
        uint64 blockNumber,
        bytes32 blockHash,
        bytes32 transactionHash,
        uint64 logIndex,
        bytes32 removalKey
    ) internal pure returns (bool) {
        return eventKey(chainId, contractAddress, blockNumber, blockHash, transactionHash, logIndex) == removalKey;
    }

    /// @notice Deterministic commitment binding the guarantees to one
    ///         deployment (chain and module address).
    /// @dev Consumers store this hash at ingestion time and re-derive it on
    ///      replay; a mismatch means the stream is not the pinned deployment.
    function guaranteesCommitment(
        IConsumerGuarantees.ConsumerGuarantees memory guarantees,
        uint64 chainId,
        address module
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                guarantees.confirmationDepth,
                guarantees.maxFinalityClass,
                guarantees.maxReorgDepth,
                guarantees.eventsAreReplayable,
                guarantees.eventKeysAreUnique,
                guarantees.eventsAreTerminalOnEmission,
                chainId,
                module
            )
        );
    }
}
