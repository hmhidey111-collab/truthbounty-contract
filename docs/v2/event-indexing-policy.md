# V2 Event Indexing Policy

**Issue:** PREWAVE-SC-089 (#765)
**Policy version:** `2.0.0-indexing-1`
**Machine-readable policy:** `config/event-indexing-policy.json`
**Gas report:** `schemas/event-indexing-gas-report-v2.json`
**Gate:** `npm run check:event-indexing` (tests: `npm run test:event-indexing`, both part of `npm run lint`)

Events are read-only evidence. This policy changes no contract, role, timelock or
settlement behaviour; it freezes and audits how existing events are laid out.

## 1. Scope

46 events are classified: the 40 events of the released V2 layout
(`schemas/event-layout-v2.json`) and the 6 commit-reveal events declared in
`contracts/v2/interfaces/IV2CommitReveal.sol`. The commit-reveal events are not part
of the canonical ABI export, so the gate parses them from source (no compiler needed)
and pins their layout inside the policy file.

## 2. Classification

Every field of every event carries a `class` and a `reason`:

| Class | Indexed | Meaning |
|-------|---------|---------|
| `projection-key` | yes | Entity id a consumer replays and joins on (`claimId`, `settlementId`, `bucket`, ...). Listed in the event's `projectionKeys`. |
| `filter-key` | yes | Bounded-cardinality value consumers filter by (actor addresses, assets, reason codes). |
| `payload` | no | Carried in log data. No consumer filters on it. |

A field is indexed only when it is a query key. The deciding inputs are:

- **Query need.** Required projection keys must be topics so consumers can use `eth_getLogs` filters.
- **Privacy.** Protected data is never indexed, and pre-reveal data is never emitted (section 3).
- **Cardinality.** Per-event-unique values (hashes, commitments, timestamps, amounts) stay in data. A low-cardinality `bool`/`uint8` topic is wasted.
- **Topic limit.** At most 3 indexed fields per (non-anonymous) event, so topic0 plus 3 fills the 4 EVM topics.
- **Gas.** Moving one static word from data to a topic costs `375 - 8 * 32 = 119` gas (section 5).

## 3. Privacy rules

Matched on field names; the patterns live in the policy file and are tested.

1. **Never emitted, anywhere:** `salt`, `secret`, `preimage`, `plaintext`, `privateKey`, `mnemonic`, raw `rationale`. No exception can waive this.
2. **Reveal-only:** `decision`, `rationaleHash`, `supportsClaim` (and `vote`/`choice`/`verdict`). These may be emitted only by a reveal-phase event (`VoteRevealed`) and are never indexed.
3. **Commit-phase events** (every event in `IV2CommitReveal.sol` except `VoteRevealed`) may not carry any reveal-only field. No exception can waive this. `CommitSubmitted` emits only the commitment hash, deadlines and stake.
4. The one documented exception: `VerificationSubmitted.supportsClaim`. The direct verification path has no commit phase, so the verdict is public at submission. It stays unindexed.

## 4. Frozen and versioned topic layouts

Each policy entry pins `signature`, `topic0`, `anonymous` and the ordered field list
with `indexed` flags. The gate fails on:

- indexed/unindexed flips, field reordering or type changes (topic-order drift);
- removed events;
- a new event whose name does not end in a version suffix (`V2`, `Version3`, ...);
- a `topic0` that is not `keccak256(signature)`;
- any event present in code but absent from the policy, or the reverse.

An incompatible layout change therefore needs a new versioned event name, a new
policy entry, and a bumped `policyVersion`. Anonymous events are forbidden: they
have no topic0, so a consumer cannot filter for them safely.

## 5. Gas

LOG cost is `375 + 375 * topics + 8 * dataBytes`, where `topics` includes topic0.
`schemas/event-indexing-gas-report-v2.json` records topics, data bytes and LOG gas for
all 46 events (total 113,876; largest is `CommitSubmitted` at 3,155). Each event also
has a `logGasBudget` in the policy equal to its recorded cost, so adding a topic or a
data word fails the gate until the budget is raised deliberately. Regenerate the report
with `npm run events:indexing:gas`.

The model covers LOG opcode cost only. It excludes memory expansion and the emitting
call's own execution, and it lower-bounds dynamic fields (none exist in the current set).

## 6. Exceptions (all documented in the policy)

| Event | Field | Rule | Why |
|-------|-------|------|-----|
| `RewardAllocated` | `category` | low-cardinality-indexed | Released layout is frozen. Fixing it means a new `RewardAllocatedV2`. |
| `RootAccepted`, `RootProposed` | `root` | high-cardinality-indexed | Roots are looked up by value to match proofs. |
| `VerificationSubmitted` | `supportsClaim` | protected-emitted | Direct path has no commit phase (section 3). |

Exceptions need a non-empty reason, may only waive the four rules listed in the
policy, and fail as stale when they no longer apply.

## 7. Open finding (not changed here)

`RewardAllocated` spends a topic on the 8-bit `category` while leaving `account`
unindexed. Per-account allocation queries must scan by `settlementId` and decode. This
is a released, frozen layout, so correcting it is out of scope for this change and
belongs in a future versioned event.
