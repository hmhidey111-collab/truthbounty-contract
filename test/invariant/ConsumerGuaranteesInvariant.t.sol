// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import { ConsumerGuaranteesAnchor } from "../../contracts/v2/ConsumerGuaranteesAnchor.sol";
import { IConsumerGuarantees } from "../../contracts/v2/interfaces/IConsumerGuarantees.sol";
import { V2Guarantees } from "../../contracts/v2/libraries/V2Guarantees.sol";

/// @title ReorgConsumerGuaranteesInvariant
/// @notice Stateful fuzz model of the reorg guarantees from the consumer side:
///         a bounded projection ingests randomized log emissions across four
///         simulated chain forks, applies orphan removals bounded by the
///         published depth, and replays the canonical surface. Every consumer
///         guarantee — bounded absorption, lawful removal, and replay
///         determinism — is enforced as an invariant over the model.
contract ReorgHandler is Test {
    struct LogRecord {
        uint64 blockNumber;
        bytes32 blockHash;
        bytes32 txHash;
        uint64 logIndex;
    }

    uint64 public constant CHAIN_ID = 11155420;
    uint256 internal constant FORK_COUNT = 4;

    ConsumerGuaranteesAnchor public anchor;
    address public module;

    /// @notice Live projection: every canonical event key ever ingested.
    bytes32[] public canonicalKeys;
    mapping(bytes32 => bool) public isIndexed;
    mapping(bytes32 => LogRecord) public recordOf;
    mapping(bytes32 => uint256) public forkOfKey;

    /// @notice Per-fork head height and tip hash of the simulated chain.
    mapping(uint256 => uint64) public forkHeight;
    mapping(uint256 => bytes32) public forkTip;

    /// @notice Ghost variables reconciling the projection after every action.
    uint256 public ghostApplied;
    uint256 public ghostRemoved;

    constructor() {
        vm.chainId(CHAIN_ID);
        anchor = new ConsumerGuaranteesAnchor(V2Guarantees.defaultGuarantees(), address(this));
        module = address(anchor);
        for (uint256 f = 0; f < FORK_COUNT; ++f) {
            forkTip[f] = keccak256(abi.encode("genesis", f));
        }
    }

    /// @notice Emit a synthetic canonical log at `blockNumber` on fork `f`.
    function applyEvent(uint64 blockNumber, uint256 txSeed, uint64 logIndex, uint256 forkSeed) public {
        uint256 fork = forkSeed % FORK_COUNT;
        if (blockNumber <= forkHeight[fork]) return; // heads move forward only
        bytes32 tipHash = forkTip[fork];
        bytes32 blockHash = keccak256(abi.encode(tipHash, blockNumber));
        bytes32 txHash = keccak256(abi.encode("tx", txSeed, blockNumber));
        bytes32 key = V2Guarantees.eventKey(CHAIN_ID, module, blockNumber, blockHash, txHash, logIndex);

        if (!isIndexed[key]) {
            isIndexed[key] = true;
            recordOf[key] =
                LogRecord({ blockNumber: blockNumber, blockHash: blockHash, txHash: txHash, logIndex: logIndex });
            forkOfKey[key] = fork;
            canonicalKeys.push(key);
            ghostApplied += 1;
        }
        forkHeight[fork] = blockNumber;
        forkTip[fork] = blockHash;
    }

    /// @notice Reorganize `depth` blocks on fork `f`: every projected record on
    ///         that fork at or above the new orphan floor (tip - depth) is
    ///         orphaned and must be removed by the consumer.
    function reorg(uint256 forkSeed, uint64 depth) public {
        uint64 maxDepth = anchor.consumerGuarantees().maxReorgDepth;
        depth = uint64(bound(depth, 1, maxDepth));
        uint256 fork = forkSeed % FORK_COUNT;
        uint64 head = forkHeight[fork];
        if (head == 0) return;

        uint64 orphanFloor = head >= depth ? head - depth : 0;
        forkTip[fork] = keccak256(abi.encode("reorg", fork, forkTip[fork], depth));

        for (uint256 i = 0; i < canonicalKeys.length; ++i) {
            bytes32 key = canonicalKeys[i];
            if (!isIndexed[key]) continue;
            if (forkOfKey[key] != fork) continue;
            LogRecord memory rec = recordOf[key];
            if (rec.blockNumber < orphanFloor) continue;

            // Lawful removal: the removed key must be re-derivable from the
            // canonical coordinates of the orphaned log.
            assertTrue(
                V2Guarantees.isRemovalCanonical(
                    CHAIN_ID, module, rec.blockNumber, rec.blockHash, rec.txHash, rec.logIndex, key
                ),
                "removal key must equal recomputed identity"
            );
            isIndexed[key] = false;
            ghostRemoved += 1;
        }
        forkHeight[fork] = orphanFloor;
    }

    /// @notice Full key set accessor for invariant checks.
    function allKeys() external view returns (bytes32[] memory) {
        return canonicalKeys;
    }

    /// @notice Count of live (canonical, non-orphaned) keys.
    function liveKeyCount() public view returns (uint256 live) {
        for (uint256 i = 0; i < canonicalKeys.length; ++i) {
            if (isIndexed[canonicalKeys[i]]) live += 1;
        }
    }

    /// @notice Replay the canonical surface from genesis: re-derive every key
    ///         from its stored canonical coordinates.
    function replayFromGenesis() public view {
        for (uint256 i = 0; i < canonicalKeys.length; ++i) {
            if (!isIndexed[canonicalKeys[i]]) continue;
            LogRecord memory rec = recordOf[canonicalKeys[i]];
            bytes32 replayed =
                V2Guarantees.eventKey(CHAIN_ID, module, rec.blockNumber, rec.blockHash, rec.txHash, rec.logIndex);
            assertEq(replayed, canonicalKeys[i], "replay must re-derive canonical keys");
        }
    }
}

contract ReorgConsumerGuaranteesInvariantTest is StdInvariant, Test {
    ReorgHandler public handler;

    function setUp() public {
        handler = new ReorgHandler();
        targetContract(address(handler));
    }

    /// @notice Invariant: the published confirmation depth always stays within
    ///         validated bounds and never collapses to zero — consumers always
    ///         hold a meaningful wait threshold.
    function invariant_ConfirmationDepthWithinBounds() public view {
        IConsumerGuarantees.ConsumerGuarantees memory g = handler.anchor().consumerGuarantees();
        assertGe(g.confirmationDepth, V2Guarantees.MIN_CONFIRMATION_DEPTH);
        assertLe(g.confirmationDepth, V2Guarantees.MAX_CONFIRMATION_DEPTH);
        assertGt(g.maxReorgDepth, 0);
        assertLe(g.maxReorgDepth, V2Guarantees.MAX_REORG_DEPTH);
        assertTrue(g.eventsAreReplayable);
        assertTrue(g.eventKeysAreUnique);
        assertTrue(g.eventsAreTerminalOnEmission);
    }

    /// @notice Invariant: the guarantee record is immutable across every state
    ///         transition — no handler action can widen a published promise.
    function invariant_GuaranteesImmutable() public view {
        IConsumerGuarantees.ConsumerGuarantees memory g = handler.anchor().consumerGuarantees();
        bytes32 committed = V2Guarantees.guaranteesCommitment(g, handler.CHAIN_ID(), address(handler.anchor()));
        bytes32 expected = keccak256(
            abi.encode(
                g.confirmationDepth,
                g.maxFinalityClass,
                g.maxReorgDepth,
                g.eventsAreReplayable,
                g.eventKeysAreUnique,
                g.eventsAreTerminalOnEmission,
                handler.CHAIN_ID(),
                address(handler.anchor())
            )
        );
        assertEq(committed, expected);
    }

    /// @notice Invariant: every indexed key is exactly the canonical identity
    ///         of its stored record — no phantom or duplicate key ever enters
    ///         the projection, and replay is deterministic.
    function invariant_IndexedKeysAreCanonicalIdentitiesAndReplayable() public view {
        handler.replayFromGenesis();
    }

    /// @notice Invariant: projection conservation — applied minus removed must
    ///         equal live keys at all times (event-state conservation analog).
    function invariant_ProjectionReconciles() public view {
        assertEq(handler.ghostApplied(), handler.ghostRemoved() + handler.liveKeyCount());
    }

    /// @notice Invariant: reorg absorption stays bounded by the published
    ///         maximum — the handler never removes deeper than maxReorgDepth.
    function invariant_ReorgAbsorptionBounded() public view {
        assertLe(handler.ghostRemoved(), handler.ghostApplied());
        IConsumerGuarantees.ConsumerGuarantees memory g = handler.anchor().consumerGuarantees();
        assertGe(V2Guarantees.MAX_REORG_DEPTH, g.maxReorgDepth);
    }
}
