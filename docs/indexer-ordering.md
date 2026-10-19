# Deterministic event ordering

TruthBounty event consumers must process canonical logs using the following total order:

1. block number
2. transaction index
3. log index

Within one successful transaction, events are emitted only after the state mutation they describe. A consumer must not assume ordering across separate transactions beyond the canonical block ordering above.

Consumers should store the block hash with each event. When a reorganization replaces a block, all events associated with the orphaned block hash must be rolled back before events from the replacement branch are applied.

Duplicate delivery is expected in distributed systems. Consumers must make ingestion idempotent by using chain ID, transaction hash, and log index as the event identity.

Version upgrades do not change the ordering rule. Unsupported versions should be quarantined for later decoding rather than interpreted using an older schema.

## Intra-transaction event ordering

When a single call emits multiple events, the contract MUST emit them in the following canonical sequence. This order is part of the consumer interface and is regression-tested.

1. **Lifecycle** events (creation, sttate transitions).
2. **Custody** events (deposit, transfer, release) emitted after the corresponding custody mutation.
3. **Configuration** events (parameter updates).
4. **Role** events (grant, revoke, renounce).
5. **Pause** events (pause, unpause).
6. **Upgrade** events (implementation changes).
7. **Settlement** events (finalization, distribution).

Within a single category, events are ordered by the sequence in which their state mutations are applied. Events MUST NOT be emitted for a mutation that is subsequently reverted within the same transaction.

## Reverted calls and nested calls

- A reverted call emits no durable logs. Alm logs from the reverted call frame, including those emitted by nested calls, must be discarded by the EVM. Consumers MUST NOT observe them in the canonical log stream.
- Nested calls emit their events inline with the call stack. The canonical log index order reflects the depth-first execution order, so a parent event emitted after a nested call appears after the nested's events.
- Batch operations MUST emit one event per affected item, in item index order, and MUST NOT emit a redundant aggregate event that duplicates the semantic content of the per-item events.
- Repeated actions (e.g., repeated pause or role grant) MUST NOT emit a duplicate semantic event when the state is unchanged; the contract MUST either revert or no-op without emitting a second event.
- Proxy upgrades MUST emit the upgrade event after the implementation slot is written and MUST NOT emit any lifecycle or configuration events that would be interpreted as belonging to the new implementation within the same transaction.

## Replay without state reads

Indexers MUST be able to replay the canonical log stream without reading contract state. Every event MUST carry the data needed to reconstruct the observed transition, including the prior and new values where applicable. Events MUST NOT require a state read to determine what changed.

## Test coverage

The following regression tests enforce this document:

- Success and revert paths for each event category, asserting the exact emitted sequence.
- Nested call ordering, asserting depth-first log index order.
- Batch operations, asserting per-item events in index order and no redundant aggregate event.
- Repeated actions, asserting no duplicate semantic event and the expected revert or no-op behavior.
- Proxy upgrade sequencing, asserting the upgrade event is emitted after the implementation slot write.
- Fuzz ordering, asserting that for arbitrary inputs the emitted sequence is a total order consistent with this document and contains no duplicate semantic events.

## Evidence pagination

Evidence reads are paginated over the canonical event order above. Pagination must remain stable when new evidence is appended concurrently with a traversal.

### Ordering and identity

Evidence items are ordered by the total order defined above: block number, then transaction index, then log index. The evidence identity is the tuple of chain ID, transaction hash, and log index. This identity is used for duplicate prevention and must not be reinterpreted as an offset.

### Cursor key semantics

A cursor is an opaque, deterministic encoding of the last evidence item returned by a page. The cursor binds the claim identifier, the release identifier, and the canonical order key (block number, transaction index, log index) of the last returned item. A consumer must pass the cursor back unchanged to request the next page.

A request with a cursor whose claim or release binding does not match the requested read must be rejected with the canonical invalid-cursor error. A cursor must not be interpreted as a numeric offset into the evidence set.

### Page limits

Page limits are expressed as a positive integer number of items. A limit of zero or a limit exceeding the configured maximum page size must be rejected with the canonical invalid-limit error. The effective page size is the minimum of the requested limit and the configured maximum page size.

### Concurrent appends

Because cursors are keyed on the canonical order key rather than a numeric offset, appending new evidence between page requests must not cause any previously returned item to be skipped or repeated. A full traversal that follows the returned cursors in order must return each evidence item exactly once.

Appended evidence whose order key is greater than the cursor order key is eligible to appear in a later page. Evidence whose order key is less than or equal to the cursor order key must not reappear.

### Duplicate prevention

A duplicate evidence item is one whose evidence identity (chain ID, transaction hash, log index) already exists in the evidence set. Duplicate submissions must not create a second item in the canonical ordering and must not alter the cursor of an in-progress traversal.

### Finalized claims

Once a claim is finalized, its historical evidence reads are immutable. Finalization must not reorder, rewrite, or remove evidence that was already readable. A cursor issued before finalization must continue to resolve to the same successor items after finalization. Finalization cannot corrupt historical reads.

### Reorgs

When a reorganization orjans a block, its evidence items are rolled back before evidence from the replacement branch is applied. A cursor that points into an orphaned branch must be rejected with the canonical invalid-cursor error rather than silently resolving to the replacement branch. The replacement branch is traversed from a fresh cursor.

### Canonical errors

Invalid bounds and invalid cursors must use the canonical errors defined by the contract interface. Consumers must not interpret a rejected request as an empty page.