# Chain Reorganization Consumer Guarantees

- **Issue**: V2-SC-134
- **Status**: Authoritative for canonical V2 event consumers
- **Protocol version**: `2.0.0`
- **On-chain source of truth**: [`contracts/v2/interfaces/IConsumerGuarantees.sol`](../contracts/v2/interfaces/IConsumerGuarantees.sol)
- **Anchor implementation**: [`contracts/v2/ConsumerGuaranteesAnchor.sol`](../contracts/v2/ConsumerGuaranteesAnchor.sol)
- **Deployment manifest**: [`deployments/config/consumer-guarantees.json`](../deployments/config/consumer-guarantees.json)
- **Related**: [`docs/event-architecture.md`](./event-architecture.md) (ordering and idempotency), [`docs/event-consumer-checklist.md`](./event-consumer-checklist.md) (SC-022 compatibility), [`docs/indexer-ordering.md`](./indexer-ordering.md) (canonical ordering)

This document defines the **confirmation, finality, replacement, removal, and replay guarantees** that canonical TruthBounty V2 contract events and deployment manifests expose to off-chain consumers (indexers, APIs, explorers, analytics, notification systems). It closes the assurance gap left by SC-022, which specified log ordering and idempotent ingestion but did not make reorg expectations authoritative or machine-readable.

---

## 1. Trust Boundary Statement

The EVM contracts deployed on Optimism remain the **only** authority for protocol mutation and settlement. The guarantees published here:

- describe how consumers must interpret the **existing** canonical event stream;
- introduce **no** new settlement, treasury, guardian, deployer, or outcome authority;
- grant **no** API, indexer, frontend, or test harness any privilege over claim outcomes;
- are enforced **fail-closed**: invalid records revert at publication and cannot be widened after deployment.

Off-chain components that need the guarantees MUST read them from the on-chain anchor or from a manifest pinned to a commit and chain ID. Hardcoded independent assumptions are non-conforming.

---

## 2. Published Guarantees

The authoritative record is `IConsumerGuarantees.ConsumerGuarantees`:

| Field | Type | Canonical value | Meaning |
|---|---|---|---|
| `confirmationDepth` | `uint64` | `1_800` (~1 h of Optimism 2 s blocks) | Ancestor blocks a consumer must observe before treating an event as confirmed. Consumers with weaker tolerance MUST use at least this value. |
| `maxFinalityClass` | `uint8` | `2` (`ProtocolFinalized`) | Strongest finality class the canonical stream provides (see §3). |
| `maxReorgDepth` | `uint64` | `12` | Upper bound on reorganization depth consumers are expected to absorb (see §5). |
| `eventsAreReplayable` | `bool` | `true` | Every event is a deterministic function of `(chainId, contractAddress, blockNumber, transactionHash, logIndex, blockHash)`. |
| `eventKeysAreUnique` | `bool` | `true` | Canonical event keys are unique for the lifetime of the deployment (single settlement; no double claim ⇒ no legitimate duplicate identity). |
| `eventsAreTerminalOnEmission` | `bool` | `true` | Events are emitted only after the state transition they describe succeeds; reverted transactions produce no logs. |

The record is published once at deployment by `ConsumerGuaranteesAnchor` (emitting `ConsumerGuaranteesPublished`), is immutable after construction, and is reassembled verbatim by `consumerGuarantees()`. The anchor is read-only: it holds no funds, exposes no state-changing function, and its recorded `deployer` provenance address carries no runtime authority.

### 2.1 Validation is fail-closed

`V2Guarantees.validate` reverts unless **all** of the following hold. Publication can therefore never succeed with a weaker-than-declared guarantee:

- record is not entirely zeroed (`ZeroedGuarantees`);
- `MIN_CONFIRMATION_DEPTH (1) <= confirmationDepth <= MAX_CONFIRMATION_DEPTH (1_296_000)`;
- `0 < maxReorgDepth <= MAX_REORG_DEPTH (100_000)`;
- `maxFinalityClass` is within the `FinalityClass` range and coherent with a positive depth;
- all three semantic booleans are `true`.

`maxFinalityClass` is carried as `uint8` rather than a native enum precisely so this check is a real, reachable guard: Solidity reverts out-of-range native enums at the ABI/memory boundary **before** any library validation could run, which would leave the bound unenforceable.

---

## 3. Confirmation and Finality Classes

Consumers choose a finality class per workflow; the class is the trigger for irreversible processing (payout display, balance finalization, cross-chain relay, notifications).

| Class | Ordinal | Semantics | Trigger |
|---|---|---|---|
| `None` | `0` | Unconfirmed head. Events may be reordered or removed without notice. | Only for provisional projection/display. |
| `SoftConfirmation` | `1` | `confirmationDepth` ancestor blocks observed. Rollback still possible but bounded by `maxReorgDepth`. | Depth threshold reached. |
| `ProtocolFinalized` | `2` | Deterministic challenge/settlement window elapsed **on confirmed blocks**. The protocol outcome is final and cannot be replaced. | Depth threshold **and** protocol window elapsed (tracked by consumers from canonical events, e.g. settlement queue + timelock). |

Rules:

1. A consumer requiring class `X` may treat any **stronger** class as satisfying it, never a weaker one.
2. `finalityForDepth(guarantees, observedDepth)` maps an observed depth to `SoftConfirmation` when `observedDepth >= confirmationDepth`, otherwise `None`. Reaching `SoftConfirmation` never implies `ProtocolFinalized`; the protocol window is separate evidence.
3. Consumers MUST NOT perform irreversible actions at class `None`.

---

## 4. Replacement and Removal (Orphan Rollback)

### 4.1 Canonical event identity

Every canonical log has exactly one identity:

```
eventKey = keccak256(abi.encode(chainId, contractAddress, blockNumber, blockHash, transactionHash, logIndex))
```

`blockHash` is included deliberately: two representations of the same `(blockNumber, transactionHash, logIndex)` on divergent branches produce different keys, which is what makes removal well-defined.

### 4.2 Replacement

When a reorganization replaces a block:

- all events of the orphaned branch (block hash no longer canonical) MUST be un-applied **before** events of the replacement branch are applied;
- the replacement branch re-emits logs with the **same** canonical coordinates but the **new** `blockHash`, producing new keys;
- consumers MUST re-derive finality for the replacement events; previously reached `SoftConfirmation` on the orphaned branch is void.

### 4.3 Removal is lawful only when recomputable

`V2Guarantees.isRemovalCanonical(...)` re-derives the key from the canonical coordinates of the log being removed and compares it with the removal target. A removal MUST only be applied when this returns `true`; otherwise the removal is forged or corrupt and MUST be rejected (`InvalidRemoval`). This blocks rollback replay that would delete canonical events or inject phantom removals.

### 4.4 Bounded absorption

Consumers MUST absorb reorgs up to `maxReorgDepth` (`12` on canonical deployments). A reorg **deeper** than this bound is outside guarantee scope: consumers MUST resynchronize from genesis (or from their last verified checkpoint), never attempt incremental repair. Deeper-than-guaranteed reorgs on Optimism would indicate a consensus-level failure that no consumer-side patching should mask.

---

## 5. Replay Expectations

`eventsAreReplayable == true` commits the protocol to: replaying ingestion from genesis over the canonical logs of the pinned deployment reproduces the **identical** key set and projection. Consumers SHOULD:

1. store `(chainId, anchorAddress)` at ingestion time; guarantees are never valid across deployments;
2. compute `V2Guarantees.guaranteesCommitment(guarantees, chainId, module)` and persist it;
3. re-derive the commitment on replay — a mismatch means the stream is not the pinned deployment and MUST halt;
4. verify replay determinism periodically (rebuild the projection from logs, compare key sets) as a self-check.

---

## 6. Consumer Responsibilities (normative summary)

1. Ingest canonical events ordered by `blockNumber`, `transactionIndex`, `logIndex` (SC-022 ordering, unchanged).
2. Deduplicate by canonical `eventKey`; the key embeds chain ID, contract address, and block hash, so it is safe across deployments and reorgs.
3. Delay irreversible processing until the configured finality class is reached (§3).
4. Absorb reorgs by lawful removal only (§4.3), bounded by `maxReorgDepth` (§4.4).
5. Resynchronize from genesis beyond the bounded depth instead of incremental repair.
6. Verify replay determinism (§5).
7. Never infer state from reverted transactions — none exist (`eventsAreTerminalOnEmission`), but defensive consumers still reject logs from failed receipts.
8. Treat metadata hashes as references; verify fetched content independently.

---

## 7. Deployment Manifest Binding

[`deployments/config/consumer-guarantees.json`](../deployments/config/consumer-guarantees.json) mirrors the published record for deployment-time consumers and review. It declares:

- the guarantees (identical values to `V2Guarantees.defaultGuarantees()`), the finality-class vocabulary, and the identity/removal/replay rules;
- the target `chainId` and environment;
- the anchor artifact name, publication event, and the explicit statement that no authority is granted.

Drift between manifest and contract is a CI failure: `test/v2/ConsumerGuaranteesManifest.t.sol` parses the manifest and asserts field-by-field equality with `defaultGuarantees()`, validates the vocabulary against the Solidity enum, and re-validates manifest values through `V2Guarantees.validate` and a fresh anchor. Editing either side without the other fails the suite.

---

## 8. Invariants and Enforcement Map

| # | Invariant | Enforcement |
|---|---|---|
| I1 | Published guarantees are within bounds and fail-closed | `V2Guarantees.validate`; unit + fuzz tests on every bound |
| I2 | Published guarantees are immutable after deployment | anchor immutables; `invariant_GuaranteesImmutable` |
| I3 | Confirmation depth is always a meaningful threshold | `invariant_ConfirmationDepthWithinBounds` |
| I4 | Canonical event keys are unique and injective per field | `testFuzz_EventKeyInjectivePerField`; `invariant_IndexedKeysAreCanonicalIdentitiesAndReplayable` |
| I5 | Removals are lawful (recomputable identities only) | `isRemovalCanonical`; handler asserts every removal in the reorg model |
| I6 | Projection conserves events (applied − removed = live) | `invariant_ProjectionReconciles` |
| I7 | Reorg absorption is bounded by `maxReorgDepth` | `invariant_ReorgAbsorptionBounded`; fuzz depth binding |
| I8 | Replay from genesis is deterministic | `invariant_IndexedKeysAreCanonicalIdentitiesAndReplayable`; manifest replay rule |
| I9 | Consumers never gain settlement/treasury authority | anchor has no state-changing surface (`test_AnchorHasNoStateChangingFunctions`); zero-value custody |

---

## 9. Migration and Compatibility

- **No storage migration**: the anchor is a new, deployment-scoped singleton; no existing module changes storage layout, events, or interfaces.
- **Additive ABI**: `IConsumerGuarantees` is new; existing canonical interfaces (`ICanonicalV2` family) are untouched, so released artifacts and active claims are unaffected.
- **Released event signatures immutable**: the SC-022 catalogue is unchanged; the guarantees describe the existing stream, they do not redefine it.
- **Consumer upgrade path**: consumers continue to work unchanged (the guarantees codify current safe behavior) and MAY adopt the anchor/manifest when they add bounded reorg handling and finality gating.
- **Legacy consumers**: `docs/event-consumer-checklist.md` gains a pointer to this document; its existing rules remain valid.

---

## 10. Residual Risk

- **Deeper-than-guaranteed reorgs** are resynchronization events by design; the guarantee is explicitly bounded and consumers must handle the exceedance path.
- **Parameter values** (`1800` depth, `12` reorg depth) are deployment governance choices published from `V2Guarantees` constants; per-environment overrides are possible by constructing the anchor with different (validated) values, but the canonical deployment uses the defaults documented here.
- **L1→L2 message finality** (deposits) inherits Optimism's L1 finality; this document bounds L2 event reorgs only and does not extend guarantees to preconfirmations of L1-originated data.
