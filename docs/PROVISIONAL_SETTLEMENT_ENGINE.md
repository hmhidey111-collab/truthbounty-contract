# Provisional Settlement Engine (`SC-015`)

## 1. Overview

The **ProvisionalSettlementEngine** provides the canonical implementation for TruthBounty V2 permissionless first-round consensus settlement, deterministic outcome storage, and dispute challenge window initiation.

```
┌─────────────────────────────────────────────────────────────┐
│                 Claim Lifecycle Transition                  │
│                                                             │
│   ┌───────────────────────┐                                 │
│   │   UnderVerification   │                                 │
│   └──────────┬────────────┘                                 │
│              │ block.timestamp >= verificationDeadline      │
│              ▼                                              │
│   ┌───────────────────────┐   Reads Consensus   ┌───────┐   │
│   │   provisionalSettle   ├────────────────────►│  Agg  │   │
│   └──────────┬────────────┘                     └───────┘   │
│              │                                              │
│              ▼                                              │
│   ┌───────────────────────┐                                 │
│   │    ChallengeWindow    │ (challengeDeadline set)         │
│   │  (Funds remain locked)│                                 │
│   └───────────────────────┘                                 │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Protocol Invariants & Safety

1. **Zero Caller Data**:
   - The aggregation outcome is computed strictly on-chain by invoking the canonical `VerificationAggregator`. The caller cannot inject or alter consensus outcomes.
2. **Deterministic Time Gating**:
   - Reverts with `VerificationWindowStillOpen` if invoked before `claim.verificationDeadline`.
3. **Single Transition**:
   - Reverts with `AlreadyProvisionallySettled` if provisional settlement has already been executed for the given `claimId`.
4. **Fund Freezing & Vault Custody**:
   - Does not release winner rewards or slash verifier stakes. All funds remain locked until the dispute window expires or an appeal round finalizes.
5. **Emergency Pause**:
   - Governed by `PAUSER_ROLE` and `GovernanceOwnable`.

### 2.1 Idempotent Settlement Across Every Terminal Outcome

Settlement is idempotent across every terminal outcome. Each `(claimId, round)` pair settles at most once, regardless of how many callers invoke settlement, how many times they retry, or whether external payouts fail partway through.

**Terminal outcomes covered:** `ACCEPTED`, `REJECTED`, `TIE`, `REFUND`, `SLASH`, `EXPIRED`, `APPEALED`.

**Settlement marker / effect ordering (checks-effects-interactions):**

1. **Checks** — validate time gating, caller authority, and that the round is not already settled.
2. **Effects (marker first)** — write the terminal marker (`settled = true`, `terminalOutcome`, `settledAt`, `parameterVersion`) *before* any external call. The marker is the single source of truth for idempotency.
3. **Interactions (unsafe calls last)** — perform external payouts, slashes, refunds, or callbacks only after the marker is committed. A revert in this phase MUST NOT roll back the marker in a way that permits a second settlement of the same round.

**Retryability:** If an external payout fails, the round remains marked settled. The failed payout is recorded in a per-recipient `pendingPayout` entry and can be retried via `retryPayout(claimId, round, recipient)` without repeating any state effects (no double marker write, no double event emission for the settlement itself).

**Reorg model:** The marker is written in the same transaction that emits `RoundSettled`. Consumers MUST treat `RoundSettled` as the canonical replay anchor and MUST ignore any prior provisional events if a reorg replaces the settlement transaction. Because the marker precedes unsafe calls, a reorg that drops the payout transaction still leaves the round settled and the payout retryable.

**Concurrent callers:** The first caller to pass checks writes the marker; all subsequent callers revert with `AlreadySettled` (or, for retry paths, are routed to `retryPayout`). No two callers can both observe an unsettled round and both proceed to effects.

**Callback failure:** If a downstream callback reverts, the settlement transaction reverts as a whole *only if* the marker has not yet been committed. Once the marker is committed, callback failures are isolated to the retry path and never re-open settlement.

---

## 3. Interfaces & Storage

### Struct: `ProvisionalOutcome`

```solidity
struct ProvisionalOutcome {
    Outcome outcome;           // VERIFIED_TRUE, VERIFIED_FALSE, INCONCLUSIVE
    uint256 confidence;        // Basis points (0 - 10,000)
    uint256 trueWeight;        // Aggregate weight supporting TRUE
    uint256 falseWeight;       // Aggregate weight supporting FALSE
    uint256 totalWeight;       // Total participating weight
    uint256 verifierCount;     // Number of unique verifiers
    uint256 challengeDeadline; // block.timestamp + challengeWindowDuration
    uint256 settledAt;         // Timestamp of provisional settlement
    uint256 parameterVersion;  // Parameter version active at settlement
    bool settled;              // Settlement flag
}
```

### Events Emitted

- `RoundAggregated(uint256 indexed claimId, Outcome outcome, uint256 confidence, uint256 trueWeight, uint256 falseWeight, uint256 totalWeight, uint256 verifierCount)`
- `ProvisionalOutcomeCreated(uint256 indexed claimId, Outcome outcome, uint256 challengeDeadline, uint256 confidence, address indexed triggeredBy)`
- `ChallengeWindowDurationUpdated(uint256 oldDuration, uint256 newDuration)`
- `AggregatorUpdated(address indexed oldAggregator, address indexed newAggregator)`
- `ParameterVersionUpdated(uint256 oldVersion, uint256 newVersion)`
- `RoundSettled(uint256 indexed claimId, uint256 indexed round, Outcome terminalOutcome, uint256 settledAt, uint256 parameterVersion)` — canonical replay anchor; emitted exactly once per `(claimId, round)`.
- `PayoutFailed(uint256 indexed claimId, uint256 indexed round, address indexed recipient, uint256 amount, bytes reason)` — emitted when an external payout fails after the marker is committed; the payout remains retryable.
- `PayoutRetried(uint256 indexed claimId, uint256 indexed round, address indexed recipient, uint256 amount, bool success)` — emitted on each retry attempt.

### Events Support Exact Replay

Consumers reconstruct terminal state deterministically from `RoundSettled` alone: `(claimId, round, terminalOutcome, settledAt, parameterVersion)` is sufficient to replay every terminal outcome. `PayoutFailed` and `PayoutRetried` are auxiliary and MUST NOT be required to determine whether a round settled. Because the marker precedes unsafe calls, `RoundSettled` is always emitted before any `PayoutFailed`/`PayoutRetried` for the same round, giving a total order for replay.
