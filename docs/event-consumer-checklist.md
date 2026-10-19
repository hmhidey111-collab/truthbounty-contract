# Event consumer compatibility checklist

Indexer, backend, frontend, explorer, and analytics consumers should apply the following rules to the SC-022 event surface.

Reorganization expectations (confirmation depth, finality classes, bounded replacement/removal, and replay) are now authoritative and machine-readable: see [`docs/reorg-consumer-guarantees.md`](./reorg-consumer-guarantees.md) and the on-chain `IConsumerGuarantees` anchor. The rules below remain valid; the guarantees document makes them normative.

- Filter by contract address and canonical event signature before decoding.
- Treat indexed entity identifiers and actors as the primary query keys.
- Persist block number, block hash, transaction hash, transaction index, and log index with every decoded event.
- Deduplicate by chain ID, transaction hash, and log index.
- Delay irreversible processing until the consumer's configured confirmation depth is reached.
- Roll back events whose block hash is no longer canonical after a reorganization.
- Reject unsupported schema versions without corrupting previously indexed state.
- Process logs in block number, transaction index, then log index order.
- Never infer a successful state transition from a reverted transaction; reverted transactions produce no logs.
- Treat metadata hashes as references and verify fetched metadata independently.

Schema version `1` is the initial compatibility target.

---

## Amplification metrics (PREWAVE-SC-024)

The stress-test completion event exposes amplification metrics that must be decoded with documented units and bounds. The authoritative source is the on-chain emitter and its ABI artifact; the values below are normative for consumers and must not be relaxed to match broken output.

The `StressTestCompleted` event emits `uint256 maxAmplificationRatioBps`.

- Units: basis points (bps), where `1 bps = 0.01 %`. The ratio is expressed as a non-negative integer in bps.
- Bounds: `0 `<= `$maxAmplificationRatioBps` `<= 1000000000` (100,000,000,000 bps = 100,000,000% ). This bound is the canonical maximum for the metric and is enforced before emission.
- Overflow behavior: the emitter must revert when the computed ratio exceeds the canonical maximum or when arithmetic would overflow `uint256`. No wrapped or clipped value may be emitted.
- Zero is valid and means no amplification was observed.
- The event fixture in the test suite must match runtime output exactly, including topic and data layout.
- Monitoring consumers must decode the metric directly from the event data without heuristics or unit guessing.
- Impossible values (out-of-bounds or overflowing) must fail before emission.

Consumers must also apply the following checks to the amplification metrics:

- Reject any `StressTestCompleted` log whose decoded `maxAmplificationRatioBps` exceeds the canonical maximum.
- Treat the metric as a non-negative integer in bps; do not scale it by 10,000 or by 100 without an explicit documented conversion.
- Verify the event topic against the published ABI artifact and fail closed on schema drift.

---

## Canonical V2 projection replay (V2-SC-132)

Consumers of the canonical V2 modules must also apply the following. The
machine-readable catalogue is published on-chain by the read-only
`EventCompletenessAnchor` and mirrored in
[`deployments/config/event-completeness.json`](../deployments/config/event-completeness.json);
the normative rules are in
[`docs/v2/event-completeness-projection-replay.md`](./v2/event-completeness-projection-replay.md).

Current published catalogue: 8 modules, 30 cells, 57 closing bindings, 10
restatements, 8 reduction rules, catalogue root
`0x1764935cecbbcfc6d387c9f03037d65e6ffabaaa19450c93cfc4f800498efb58`.

- Pin `catalogueRoot`, `closingSetRoot`, and `restatementSetRoot` at ingestion and re-derive all three on every replay; treat any drift as a catalogue change, not as consumer drift.
- Apply a cell's `closingEvents` as its sources. Treat its `restatements` as cross-checks and never as sources — applying both double-counts, which `test_ApplyingRestatementsAsSourcesDoubleCounts` demonstrates.
- Apply the cell's published `reductionRuleId` for every `Aggregate` or `Derived` cell. An ad-hoc reduction will disagree with the anchor on at least one of the eight rules.
- Reconstruct the verifier-stake cell from the `Stake*` family only (R6). The vault lock events restate the same delta.
- Read `EvidenceCommitted` as establishing status `SUBMITTED`, then apply `EvidenceStatusChanged` to overwrite it (R7). A consumer that watches only the status-change event cannot distinguish a committed record in `SUBMITTED` from a record it never observed.
- Take a transition's block number and timestamp from the receipt, never from the log's own `timestamp` field, which is proposer-influenceable (R5).
- Re-derive the projection fold with `V2EventCompleteness.replayFold` from `EMPTY_FOLD` and compare it to your own. A mismatch means a log was applied twice, skipped, or applied out of order.
- Assert conservation before serving a read: `claimable + locked + protocolAllocation == totalCustody` for every asset, summed over the per-key cells.
- Do not decode these documented non-canonical emissions: `EvidenceSubmitted`, `EvidenceSubmittedV1`, `Paused`, `Unpaused`, `RoleGranted`, `RoleRevoked`, `ModuleRegistered`, `ModuleRemoved`. They are published machine-readably in `nonCanonicalEmissions` in the manifest, with each `topic0` and its reason. Quarantine anything outside that list and the catalogue; never silently ignore an unlisted emission.
- Reject a record whose chain id disagrees with the chain being indexed.

---

## Canonical event ordering within transactions (PREWAVE-SC-056)

When a single call emits multiple events, consumers must replay them in a
deterministic order that is fully reconstructable from the receipt alone,
without reading contract state. The normative ordering and the regression
tests are defined below and in
[`docs/event-ordering.md`](/docs/event-ordering.md).

### Global order

1. Block number ascending.
2. Transaction index within the block ascending.
3. Log index within the transaction ascending.
4. Within a single log index, the event is atomic and never split.

Log index is the only tie-breaker inside a transaction. Never sort by
event name, address, actor, or decoded payload. The emitting order is the
canonical order.

### Lifecycle and custody

Within one transaction the contract emits lifecycle and custody events in
causal order:

1. Custody movement events (deposit, lock, release, transfer) in the order the funds move.
2. Lifecycle transition events (create, activate, complete, cancel) after the custody effects they describe.
3. Settlement events after the custody and lifecycle events that produce the settled state.

### Configuration, role, and pause

1. Configuration change events are emitted before the events that depend on the new configuration.
2. Role grant/revoke events are emitted before the actions they authorize within the same call.
3. Pause and unpause events are emitted at the point the pause state changes, before any guarded effect that depends on it.

### Upgrade

Proxy upgrade emissions (`Upgraded`) are emitted after the implementation
pointer changes and after any initialization events the new implementation
emits within the same call. Consumers must not assume the implementation
pointer is valid until the `Upgraded` log has been applied.

### Reverted calls

A reverted call emits no durable logs. Consumers must drop every log from a
receipt whose status is not success, even if an explorer or node returns them.

### Nested calls and batches

Nested calls and batches are flattened into the receipt's log index order. The
causal order is the order of emission, not the order of call frames. Consumers
must not re-group logs by call frame or by sub-call depth.

### Repeated actions

Repeated identical actions in one transaction emit one event per occurrence,
each with its own log index. Consumers must not collapse them into a single
record; the count of occurrences is part of the canonical state.

### No duplicate semantic event

Each state transition is represented by exactly one canonical event in the
catalogue. Any secondary emission that restates the same delta is listed as a
restatement and must not be applied as a source.

### Regression tests

The ordering is regression-tested by the following suites:

- Success/revert: a successful call emits its events in the documented order; a reverted call emits no durable logs.
- Nested call: events from nested calls appear in log-index order.
- Batch: batched actions emit one event per action in emission order.
- Repeated action: repeated identical actions emit distinct, non-collapsed events.
- Proxy upgrade: `Upgraded` is emitted after the implementation change and any initialization events.
- Fuzz ordering: randomized sequences of canonical events replay to the same fold as the emission order.

A replay that applies logs out of log-index order, skips a log, or applies a
duplicate must fail comparison against the canonical fold.
