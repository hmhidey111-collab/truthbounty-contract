// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IConsumerGuarantees
/// @notice Authoritative on-chain declaration of the chain reorganization
///         guarantees that every canonical TruthBounty V2 event stream exposes
///         to off-chain consumers (indexers, APIs, explorers, analytics).
/// @dev    V2-SC-134. The guarantees published by this interface are the single
///         source of truth for reorg consumers. Off-chain clients MUST read
///         these values on-chain (or from a deployment manifest pinned to a
///         commit and chain ID) and MUST NOT hardcode independent assumptions.
///         Publication of guarantees never confers settlement, treasury, or
///         outcome authority on any off-chain consumer.
interface IConsumerGuarantees {
    // =========================================================================
    // Finality classes
    // =========================================================================

    /// @notice Finality class offered to consumers for irreversible processing.
    /// @dev Carried as uint8 in `ConsumerGuarantees.maxFinalityClass` so that
    ///      validation is a real, reachable check: Solidity reverts out-of-range
    ///      native enums at the ABI/memory boundary before any library guard
    ///      could run. Values are the ordinal of `FinalityClass`; unknown
    ///      ordinals are rejected by `V2Guarantees.validate`.
    enum FinalityClass {
        /// @notice No guarantee; unconfirmed heads only (raw mempool view).
        None,
        /// @notice Confirmation-depth guarantee; bounded by maxReorgDepth.
        SoftConfirmation,
        /// @notice Deterministic challenge/settlement window elapsed on top of
        ///         SoftConfirmation; the protocol outcome is final.
        ProtocolFinalized
    }

    /// @notice Removal (orphan rollback) and replay semantics of the protocol
    ///         event stream, expressed as a stateless commitment consumers can
    ///         validate and store.
    /// @dev Every field is an authoritative promise about the emitted log
    ///      surface. Non-zero `chainId` and `contractAddress` bind the record
    ///      to one deployment; records are never valid across deployments.
    struct ConsumerGuarantees {
        /// @notice Number of ancestor blocks a consumer must observe before
        ///         treating an event as confirmed. Consumers with weaker
        ///         tolerance MUST use at least this value. Always >= 1.
        uint64 confirmationDepth;
        /// @notice Strongest finality class the canonical stream provides, as
        ///         the uint8 ordinal of `FinalityClass`. Must be within the
        ///         enum range; validated (not trusted) by `V2Guarantees`.
        uint8 maxFinalityClass;
        /// @notice Upper bound on reorganization depth the protocol expects
        ///         consumers to absorb. A reorg deeper than this bound requires
        ///         resynchronization from genesis; it is out of guarantee scope.
        uint64 maxReorgDepth;
        /// @notice True when every emitted event is a deterministic function of
        ///         (chainId, contractAddress, blockNumber, transactionHash,
        ///         logIndex, blockHash). True for all canonical V2 modules:
        ///         events are pure EVM log emissions with no extra-protocol
        ///         non-determinism.
        bool eventsAreReplayable;
        /// @notice True when every canonical event key is unique for the
        ///         lifetime of the deployment (single settlement, no double
        ///         claim => no legitimate duplicate topic0+identity emissions).
        bool eventKeysAreUnique;
        /// @notice True when events are only emitted after the state transition
        ///         they describe has succeeded; reverted transactions produce
        ///         no logs, so consumers never observe failed mutations.
        bool eventsAreTerminalOnEmission;
    }

    /// @notice Emitted once at deployment when the guarantees become readable
    ///         on-chain. Consumers may index on this event to discover the
    ///         authoritative record without calling the getter.
    /// @param guarantees The complete, immutable guarantees record.
    event ConsumerGuaranteesPublished(ConsumerGuarantees guarantees);

    /// @notice Returns the immutable guarantees record for this deployment.
    /// @dev The returned record is the single source of truth for reorg
    ///      handling. Callers MUST reject zero-depth records defensively.
    function consumerGuarantees() external view returns (ConsumerGuarantees memory);
}
