# Block Timestamp and Number Assumptions (PREWAVE-SC-090)

| Metadata | Specification |
| :--- | :--- |
| **Document ID** | `TB-V2-SPEC-090` |
| **Issue Reference** | [#766 PREWAVE-SC-090](https://github.com/DigiNodes/truthbounty-contract/issues/766) |
| **Related Issues** | #472 (V2-SC-090 Release Audit), #702, #720 |
| **Topology** | Optimism (OP Stack) EVM |
| **Status** | Approved Candidate |
| **Security Classification** | Release-Readiness & Correctness Boundary |

---

## 1. Executive Summary & Problem Context

The post-Wave-9 comprehensive contract audit identified block timestamp and block number handling as a distinct security, correctness, and release-readiness boundary. In layered distributed systems like the Optimism (OP Stack) L2 rollup, block generation dynamics diverge significantly from Ethereum L1 mainnet. Specifically:

1. **Target Block Time**: Optimism generates blocks at a canonical cadence of **2.0 seconds** per block (compared to 12.0 seconds on Ethereum post-Merge).
2. **Sequencer Clock Skew**: The OP Stack sequencer is allowed to drift forward relative to the L1 origin timestamp within an allowed window governed by `max_sequencer_drift` (canonically 600 seconds / 10 minutes).
3. **Same-Timestamp Blocks & Sub-second Batches**: Transactions grouped within the same block share identical `block.timestamp`.
4. **Mempool / Batcher Ingestion Delays**: Transactions submitted by network participants can experience delayed inclusion due to network spikes, sequencer batching, or transient L1 congestion.

Without explicit boundary definitions, naive contracts risk assuming wall-clock equivalence, relying on `block.number` for elapsed duration calculations (introducing a 6x / 600% error rate), or setting tight deadline buffers that could be prematurely invalidated by sequencer drift.

This specification documents the authoritative clock source, establishes explicit timestamp envelopes, formalizes the 7-category timing inventory, and provides justified boundaries for `block.number` use.

---

## 2. Authoritative Time Source Specification

### 2.1 The Canonical Clock
In the TruthBounty V2 protocol on Optimism:
- **`block.timestamp` is the SOLE authoritative time source** for all contract state machines, deadlines, cooldowns, decay rates, rounds, and timelocks.
- **`block.number` MUST NEVER be used as a measure of duration or elapsed time.**

### 2.2 Core Invariants
1. **Monotonicity**: The OP Stack consensus engine guarantees weak monotonicity:
   $$\text{block.timestamp} \ge \text{parent.timestamp}$$
   Contracts must never assume strict inequality between consecutive transactions or operations; equality ($\Delta t = 0$) is valid and standard for operations executing in the same block.
2. **Envelopes Over Equalities**: No security property or state transition assumes exact wall-clock time. All time-sensitive gates employ inclusive or exclusive interval inequalities (`<=`, `>=`, `<`), never exact equality (`==`).
3. **Fail-Closed Timing Gates**: If a transaction arrives past a deadline, it must fail closed and revert cleanly (`IV2TimeBounds.DeadlinePassed`), ensuring no partial state corruption.
4. **Buffer Primacy**: Protocol minimum deadline buffers are parameterized at $\ge 1\text{ hour}$ ($3,600\text{ seconds}$), ensuring the maximum possible sequencer forward skew ($600\text{ seconds}$) is strictly $< 17\%$ of the buffer.

---

## 3. Seven-Category Timing Inventory

The TruthBounty V2 protocol state transitions span seven distinct categories of time dependency:

| # | Category | Applicable Modules | Invariant / Boundary Rule | Canonical Range / Constant |
| :- | :--- | :--- | :--- | :--- |
| **1** | **Deadlines** | `Claims.sol`, `VerificationSubmission.sol`, `MetaTxExample.sol` | Must be strictly in the future when initialized: `deadline > currentTimestamp`. Submissions valid while `block.timestamp <= deadline`. | `MIN_DEADLINE_BUFFER = 1 hours`<br>`MAX_DEADLINE_HORIZON = 365 days` |
| **2** | **Decay** | `ReputationDecay.sol`, `ReputationEngine.sol` | Discrete epoch-based decay: $\lfloor \frac{\text{now} - \text{lastActivity}}{\text{decayInterval}} \rfloor$. Elapsed time cannot be negative. If $\Delta t < \text{interval}$, decay count is 0. | `MIN_DECAY_INTERVAL = 1 hours` |
| **3** | **Cooldowns** | `EmergencyControls.sol`, `VerifierSlashing.sol`, `V2Lifecycle.sol` | Required elapsed quiet period between sensitive mutations: `block.timestamp >= lastAction + cooldown`. | `MIN_COOLDOWN_DURATION = 1 hours`<br>`MAX_COOLDOWN_DURATION = 30 days` |
| **4** | **Timelocks** | `EmergencyControls.sol`, `StakeVault.sol`, `InsuranceFund.sol` | Privileged operations queue at $T_0$ and mature at $T_{\text{ready}} = T_0 + \text{delay}$. Execution strictly prohibited when `block.timestamp < readyAt`. | `MIN_TIMELOCK_DELAY = 1 hours`<br>`STANDARD_GOVERNANCE = 48 hours`<br>`MAX_TIMELOCK_DELAY = 30 days` |
| **5** | **Rounds** | `VerificationRoundManager.sol`, `AppealVerificationRound.sol` | Round lifecycle: $\text{startedAt} \le \text{submissions} \le \text{deadline} < \text{closedAt}$. Round cannot close before deadline. | `MIN_ROUND_DURATION = 1 hours`<br>`MAX_ROUND_DURATION = 30 days` |
| **6** | **Finality** | `IProvisionalSettlementEngine.sol`, `PullSettlementLedger.sol` | Settlement challenge period elapses with zero dispute: `block.timestamp >= challengeDeadline`. Unlocks final asset distribution. | Challenge window: $24\text{ hours}$ to $14\text{ days}$ |
| **7** | **Rate Calculations** | `RewardEngine.sol`, `TokenomicsEngine.sol` | Daily buckets ($\lfloor \frac{\text{timestamp}}{1\text{ days}} \rfloor$) and streaming rates ($\frac{\Delta \text{amount}}{\Delta t}$). Must handle $\Delta t = 0$ safely without division by zero. | `MAX_RATE_CALCULATION_WINDOW = 365 days` |

---

## 4. Optimism Sequencer & Network Bounds

### 4.1 Sequencer Drift Window
Under OP Stack consensus rules, the sequencer possesses bounded discretion over `block.timestamp`:
- **Lower Bound**: The timestamp cannot be earlier than the timestamp of the L1 origin block from which the L2 block derives.
- **Upper Bound**: The sequencer timestamp may drift forward by at most `max_sequencer_drift`:
  $$\text{L1\_Origin.timestamp} \le \text{L2\_Block.timestamp} \le \text{L1\_Origin.timestamp} + 600\text{ seconds}$$

### 4.2 Security Analysis of Drift
- **Attack Vector: Premature Deadline Expiration**: A malicious or drifted sequencer advances timestamps ahead by up to 600s.
  - **Mitigation**: Because all TruthBounty deadlines require `MIN_DEADLINE_BUFFER = 1 hours` (3,600s), an honest user submitting within the active window has a 3,000s margin remaining even under maximum forward drift.
- **Attack Vector: Timelock Bypassing**: An attacker attempts to exploit forward drift to execute a queued timelock early.
  - **Mitigation**: Timelocks fail closed until `block.timestamp >= readyAt`. A 48-hour timelock requires 172,800s. A 600s forward drift accounts for only 0.34% of the delay, preserving security guarantees.
- **Attack Vector: Same-Timestamp Arithmetic Failure**: Multiple calls within the same block have identical timestamps ($\Delta t = 0$).
  - **Mitigation**: Pure rate calculations use `calculateRateSafe` which explicitly validates non-zero elapsed windows, avoiding division-by-zero panics.

### 4.3 Three-Tier Finality Mapping
Consumers and off-chain agents must understand the three stages of Optimism finality:

```
[Unsafe State]                [Safe State]                  [Finalized State]
Sequencer Execution (~2s) ──> L1 Batch Submitted (~1-3m) ──> L1 Casper Finality + 7-Day Window
  * Immediate UX               * Reorg impossible unless     * Irrevocable on Ethereum L1
  * Fast state transitions       L1 itself reorgs             * Fault proof window closed
```

Within smart contract logic, the contract executes on the current L2 state. Cross-chain settlements and critical withdrawals observe appropriate confirmation delays or dispute windows.

---

## 5. Justification of `block.number` Use vs Prohibition

### 5.1 Prohibition as a Clock: The 6x Discrepancy
In Ethereum L1 contracts, developers often estimate durations using block numbers (e.g. `1 day = 7,200 blocks` at 12s/block). On Optimism, blocks advance at 2.0s per block, yielding:
$$\text{L2 Blocks Per Day} = \frac{86,400\text{ seconds}}{2\text{ seconds/block}} = 43,200\text{ blocks}$$

$$\text{Discrepancy Ratio} = \frac{12.0\text{ s (L1)}}{2.0\text{ s (L2)}} = 6.0\text{x}\quad (600\%)$$

If an off-chain integration or contract logic assumes 7,200 blocks equals one day, **the time window expires in just 4.0 hours**, catastrophically undermining auction, verification, and appeal integrity. Therefore, `block.number` is strictly prohibited for any elapsed time calculation.

### 5.2 Approved and Justified Uses of `block.number`
`block.number` is strictly permitted for non-temporal state machines:

1. **Same-Block Mutation Barriers (Anti-Double-Slashing & Anti-Flash-Loans)**:
   - Example: `VerifierSlashing.sol` uses `if (lastSlashBlock[verifier] == block.number)` to prevent a verifier from being slashed multiple times or reentrantly manipulated within a single block.
   - Example: `TreasuryAccounting.sol` records `lastTransactionBlock[account]` to enforce intra-block isolation.
2. **Historical Checkpoint Indexing (Voting Power Binary Search)**:
   - Example: `ReputationSnapshotEngine.sol` stores reputation checkpoints mapped to `block.number` (`_reputationHistory[verifier].push(block.number, score)`).
   - This prevents flash-loan voting power attacks: votes are weighted against past checkpoints where `snapshotBlock <= block.number`.
3. **Discrete Sequencing and Reorg Anchoring**:
   - Tracking discrete execution steps within block boundaries.

---

## 6. Consumer Guidance for Off-Chain Integrations

All client SDKs, verifiers, keepers, and indexing bots must adhere to the following consumer rules:

1. **Query Authoritative Clock**: Do not estimate deadline expiration using local system wall-clock time or L1 block timestamps. Always inspect `block.timestamp` returned by the Optimism RPC (`eth_getBlockByNumber`).
2. **Buffer Margin on Submission**: Client transactions proposing deadlines should add at least `MIN_DEADLINE_BUFFER` (1 hour) plus an additional network inclusion buffer (e.g., 5-15 minutes) to comfortably absorb mempool delays and sequencer drift.
3. **Safe Cast Compliance (V2-SC-161)**: When storing timestamps in contract structs or ABI payloads, narrowings must use `V2SafeCast.timestamp64` or `toUint64` to prevent silent high-bit truncation.
4. **Idempotency on Delayed Inclusion**: If an off-chain keeper transaction is delayed and included past the deadline, client software must handle `IV2TimeBounds.DeadlinePassed` gracefully as an expected fail-closed state.

---

## 7. Acceptance Criteria Verification

| Criterion | Implementation Mechanism | Verification Suite |
| :--- | :--- | :--- |
| **No security property assumes exact wall-clock time** | All logic relies on inequalities (`<=`, `>=`, `<`), envelope buffers $\ge 1\text{ hour}$, and tolerance for sequencer drift of up to 600s. | `test_forward_skew_*`, `testFuzz_forward_skew_bounded` |
| **Timestamp bounds are explicit** | Enforced via `V2TimeBounds.sol` constants: `MIN_DEADLINE_BUFFER`, `MAX_DEADLINE_HORIZON`, `MIN_ROUND_DURATION`, `MAX_ROUND_DURATION`, `STANDARD_GOVERNANCE_TIMELOCK`. | `test_boundaries_*`, `testFuzz_timelock_enforcement` |
| **Block-number use is justified** | Justified exclusively for same-block reentrancy/slashing protection and checkpoint indexing. Prohibited as a clock. | `test_same_timestamp_blocks_block_number_protection`, `test_l1_l2_context_block_number_skew_demonstration` |
| **Consumer docs expose authoritative time source** | Section 2 & 6 document `block.timestamp` as sole authoritative clock, detailing L1/L2 rollup implications. | Documented in `docs/v2/block-timestamp-number-assumptions.md` |

---

## 8. Pinned References & Code Layout

- Interface: [`contracts/v2/interfaces/IV2TimeBounds.sol`](../../contracts/v2/interfaces/IV2TimeBounds.sol)
- Library: [`contracts/v2/libraries/V2TimeBounds.sol`](../../contracts/v2/libraries/V2TimeBounds.sol)
- Test Suite: [`test/v2/BlockTimestampAssumptions.t.sol`](../../test/v2/BlockTimestampAssumptions.t.sol)
- Safe Casting Library: [`contracts/v2/libraries/V2SafeCast.sol`](../../contracts/v2/libraries/V2SafeCast.sol)
