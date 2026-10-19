# TruthBounty V2 — Canonical Contract Threat Model

**Scope**: V2-SC-147, PREWAVE-SC-021  
**Version**: 1.1.0  
**Status**: Draft — awaiting independent maintainer approval  
**Date**: 2026-09-24  
**Covers**: Canonical modular V2 contract suite deployed on Optimism/EVM  

---

## 1. Protocol Summary

TruthBounty is an on-chain truth-bounty and verifier-incentive protocol deployed on Optimism.
Claimants post bounties against factual claims; verifiers stake reputation-weighted tokens to
vote on claim outcomes; a settlement engine distributes rewards. The V2 canonical suite is modular
and UUPS-upgradeable under timelocked governance.

---

## 2. Asset Inventory

| Asset | Location | Value Class |
|---|---|---|
| BOUNTY token | `TruthBountyToken` (ERC-20) | High — fungible protocol token |
| Verifier stake | `VerificationSubmission` stake ledger | High — principal at risk of slashing |
| Challenge bonds | `StakeVault` (`BondLock` ledger) | High — locked collateral |
| Claim bounty rewards | `ClaimRegistry` / `SettlementEngine` | High — pending payout |
| Reputation scores | `ReputationSnapshot` / oracle | Medium — influences stake weight |
| Admin roles | `AccessControl` role mappings | Critical — controls all mutations |
| Upgrade authorization | `UpgradeController` timelock | Critical — controls contract logic |
| Storage layout | Proxy storage slots | Critical — corruption = state loss |
| Fee revenue | `FeeManager` treasury | Medium — accumulated protocol fees |

---

## 3. Actor Inventory

| Actor | Trust Level | Capabilities |
|---|---|---|
| **Claimant** | Untrusted | Submit claims, post bounties, call permissionless functions |
| **Verifier** | Untrusted | Submit stakes, cast votes via `VerificationSubmission` |
| **Challenger** | Untrusted | Open disputes by posting challenge bonds |
| **Resolver** (`RESOLVER_ROLE`) | Privileged | Settle claims (timelocked grant) |
| **Admin** (`ADMIN_ROLE`) | Privileged | Configure parameters, grant roles (timelocked for resolver) |
| **Default Admin** (`DEFAULT_ADMIN_ROLE`) | Privileged | Grant/revoke all roles |
| **Guardian** | Privileged (narrow) | Pause contracts only; no settlement or treasury authority |
| **Round Manager** (`ROUND_MANAGER_ROLE`) | Privileged | Open verification rounds, record participants |
| **Upgrade Controller** | Privileged (timelocked) | Propose and execute UUPS upgrades |
| **Fee Manager** | Internal contract | Route fee deductions; no settlement authority |
| **Off-chain Indexer / Relayer** | Untrusted observer | Read-only; no settlement authority |
| **Governance Token Holder** | Delegated | Vote on proposals; no direct on-chain mutation |

---

## 4. Trust Boundaries

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         ON-CHAIN (EVM — Optimism)                            │
│                                                                              │
│  ┌──────────────┐      ┌─────────────────────┐      ┌────────────────────┐  │
│  │ ClaimRegistry│◄────►│VerificationSubmission│◄────►│VerificationRound   │  │
│  │  (UUPS)      │      │   (immutable)        │      │   Manager          │  │
│  └──────┬───────┘      └──────────────────────┘      └────────────────────┘  │
│         │                                                                    │
│         │    ┌──────────────────────────┐    ┌──────────────────────────┐   │
│         └───►│   DisputeResolution      │───►│       StakeVault          │   │
│              └──────────────────────────┘    │   (bond custody)          │   │
│                                              └──────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────────────┐    │
│  │          UpgradeController (timelocked) — governs all UUPS proxies  │    │
│  └──────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  TRUST BOUNDARY: No off-chain component (API, indexer, frontend,            │
│  guardian, deployer) may gain settlement, treasury, or admin authority.      │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

     ▲                ▲                   ▲
     │                │                   │
  Claimant        Verifier           Challenger
 (untrusted)    (untrusted)         (untrusted)
```

**Key boundaries**:

1. **On-chain vs. off-chain**: Off-chain components (API, indexer, guardian, relayer, frontend) are read-only observers. They may never call settlement, treasury, or admin functions.
2. **Role boundary**: `RESOLVER_ROLE` grants are timelocked via `ResolverRoleTimelock`. No instant privileged grant.
3. **Upgrade boundary**: UUPS `_authorizeUpgrade` is gated by `UpgradeController` timelock (minimum 1 hour, 24 hours for emergency). No deployer or admin can bypass.
4. **Bond custody boundary**: Only `OPERATOR_ROLE` (the DisputeResolution module) can lock/release bonds. No governance, guardian, or treasury role can release an active bond.
5. **Claim immutability boundary**: Once a claim enters `Active` status, its core parameters (bounty amount, currency, deadline) are immutable.

---

## 5. Attack Trees

### 5.1 — Treasury Drain

```
GOAL: Extract funds from the protocol treasury / reward pool

├── A1. Exploit reentrancy in settlement payout
│   ├── A1.1 Call settle() with malicious ERC-20 that re-enters
│   │   └── CONTROL: SafeERC20 + ReentrancyGuard on all payout paths
│   └── A1.2 ERC-777 / callback token re-entrance
│       └── CONTROL: SafeERC20 transfer (no callback hooks used)
│
├── A2. Double-claim settlement
│   ├── A2.1 Replay same claim settlement twice
│   │   └── CONTROL: Status transitions are monotonic (DRAFT→ACTIVE→SETTLED)
│   └── A2.2 Submit claim with duplicate content hash
│       └── CONTROL: `_canonicalClaimExists` mapping rejects duplicate hashes
│
├── A3. Role escalation to gain RESOLVER_ROLE
│   ├── A3.1 Compromise DEFAULT_ADMIN key, grant RESOLVER_ROLE instantly
│   │   └── CONTROL: ResolverRoleTimelock delays any RESOLVER_ROLE grant
│   └── A3.2 Flash-loan governance to pass upgrade that removes timelock
│       └── CONTROL: Upgrade timelock independent of governance votes;
│                    governor cannot remove its own timelock in one tx
│
└── A4. Upgrade to malicious implementation
    ├── A4.1 Call upgradeToAndCall directly on proxy
    │   └── CONTROL: _authorizeUpgrade requires UpgradeController approval
    └── A4.2 Inject malicious module via governance proposal
        └── CONTROL: Timelocked upgrade + independent review window
```

### 5.2 — Double-Settlement / Claim Replay

```
GOAL: Settle or withdraw rewards for the same claim more than once

├── B1. Concurrent settlement calls race
│   └── CONTROL: ReentrancyGuard + monotonic status check (reverts if not Active)
│
├── B2. Manipulate claim ID assignment
│   └── CONTROL: _nextClaimId is monotonically incremented; no reuse
│
└── B3. Exploit canonical claim hash collision
    └── CONTROL: SHA-256 content hashing; _canonicalClaimExists mapping
```

### 5.3 — Stake Drain / Slashing Bypass

```
GOAL: Withdraw stake without authorization or avoid slashing

├── C1. Direct withdrawal of locked bond from StakeVault
│   └── CONTROL: Only OPERATOR_ROLE (DisputeResolution) can release bonds;
│                no direct depositor withdrawal of active bonds
│
├── C2. Bypass RESOLVER_ROLE timelock to instant-slash
│   └── CONTROL: All slashing paths require RESOLVER_ROLE which is timelocked
│
└── C3. Grief verifiers by spamming dust stakes to inflate round gas
    └── CONTROL: Minimum stake bound enforced at VerificationSubmission entry;
                 pagination on getClaimVerificationsPaginated prevents gas DoS
```

### 5.4 — Verification Manipulation

```
GOAL: Influence claim outcome without legitimate stake or reputation

├── D1. Sybil attack — create many verifier addresses
│   └── PARTIAL CONTROL: Reputation weighting caps low-rep dominance;
│                         min reputation threshold (0.1 × 1e18) enforced
│
├── D2. Oracle manipulation — feed false reputation scores
│   └── CONTROL: Oracle address is admin-controlled; oracle updates are logged;
│                governance timelock applies to oracle replacement
│   ⚠️  RESIDUAL RISK: Off-chain oracle data source integrity is outside
│       the on-chain trust boundary; oracle freshness is not time-gated on-chain.
│
├── D3. Replay a vote from a previous round
│   └── CONTROL: Round ID scoped to each verification record;
│                round parameters are write-once after openRound()
│
└── D4. Open a second OPEN round for the same claim
    └── CONTROL: At most one OPEN round of each type per claim (VRM invariant #2)
```

### 5.5 — Governance Hijack

```
GOAL: Take permanent control of the protocol

├── E1. Acquire governance token majority, pass malicious proposal
│   └── CONTROL: Upgrade timelock (1 hour minimum) separates vote from execution;
│                independent maintainer review required before execution
│
├── E2. Frontrun upgrade execution with a malicious calldata injection
│   └── CONTROL: Upgrade payload is committed at proposal time and hash-locked
│
└── E3. Admin key compromise — grant unlimited roles
    └── CONTROL: DEFAULT_ADMIN is recommended to be a multisig or timelock;
                 RESOLVER_ROLE grant is independently timelocked regardless
    ⚠️  RESIDUAL RISK: If DEFAULT_ADMIN is a single EOA, key compromise = full control.
                       Mitigation: deploy with multisig admin (documented in deployment spec).
```

---

## 6. Abuse Cases

| ID | Actor | Abuse Case | Current Control |
|---|---|---|---|
| AB-01 | Claimant | Submit claim with bounty 0 (dust claim) | `assetMinBounty` per asset enforced by `ClaimRegistry` |
| AB-02 | Verifier | Submit stake of 0 after round opens | Minimum stake enforced by `VerificationSubmission` |
| AB-03 | Challenger | Open duplicate disputes to lock bond budget | `_disputesByClaim` mapping enforces exactly one dispute per claim |
| AB-04 | Admin | Set `slashPercentage` to 100% to drain all verifier stakes | Percentage capped at 100 but no lower bound documented; ⚠️ residual risk |
| AB-05 | Off-chain relayer | Replay meta-transactions | EIP-712 nonce per submitter enforced by `_submitterNonce` |
| AB-06 | Verifier | Submit to a closed round | Round status check reverts on non-OPEN round |
| AB-07 | Round Manager | Open unlimited rounds to grief gas | Deadline enforced; closure is permissionless after deadline |
| AB-08 | Governance | Pass emergency pause as prelude to malicious upgrade | Pause and upgrade are independent; pause alone cannot unlock upgrade |
| AB-09 | Indexer | Read stale paginated events and project wrong state | Events are monotonically ordered by block; replay is deterministic |

---

## 7. Existing Controls

| Control | Implementation Location | Property Enforced |
|---|---|---|
| `ReentrancyGuard` | All payout/stake/bond paths | No re-entrant state manipulation |
| `SafeERC20` | All token transfer sites | No callback/hook exploitation |
| Monotonic claim status | `ClaimRegistry` | No status rollback; no double-settle |
| `_nextClaimId` monotonic counter | `ClaimRegistry` | No claim ID reuse |
| Canonical content hash dedup | `_canonicalClaimExists` | No duplicate claim content |
| `ResolverRoleTimelock` | `TruthBountyToken`, `GovernanceOwnable` | Delayed RESOLVER_ROLE grants |
| UUPS `_authorizeUpgrade` | All UUPS contracts + `UpgradeController` | Timelocked upgrade execution |
| `StakeVault` bond custody | `StakeVault`, `OPERATOR_ROLE` restriction | No direct bond withdrawal |
| `AccessControl` role gating | All privileged entrypoints | Least-privilege enforcement |
| Pausable | All settlement/staking paths | Emergency halt without upgrade |
| Canonical pause/token-failure errors | All pause and token-transfer paths | Deterministic, operation-scoped failure semantics (see §14) |
| Round write-once parameters | `VerificationRoundManager` | No post-open round manipulation |
| At-most-one-open-round invariant | `VerificationRoundManager` | No round spam per claim |
| Reputation bounds | `WeightedStaking` (min 0.1, max 10×) | Sybil stake dominance limited |
| EIP-712 nonce | `ClaimRegistry._submitterNonce` | Meta-tx replay prevention |
| Storage layout guard | `StorageCompatibilityValidator` script | No upgrade storage corruption |
| Paginated getters | `VerificationSubmission`, `VerificationRoundManager` | Gas-bounded read paths |
| `MAX_DEADLINE_HORIZON` | `ClaimRegistry` (365 days) | No unbounded claim lock-up |
| Statement length bounds | `ClaimRegistry` (10–2000 bytes) | No calldata bloat DoS |

---

## 8. Assumptions

| ID | Assumption | Consequence if false |
|---|---|---|
| AS-01 | `DEFAULT_ADMIN_ROLE` is held by a multisig or governance timelock | Single EOA compromise = full protocol control |
| AS-02 | The reputation oracle data source is honest and fresh | Stale/manipulated scores distort verification outcomes |
| AS-03 | Optimism sequencer does not censor settlement transactions | Griefable by sequencer in edge cases |
| AS-04 | The ERC-20 bounty token is not rebasing or fee-on-transfer | Accounting invariants break with non-standard tokens |
| AS-05 | `RESOLVER_ROLE` is granted only to the canonical settlement contract | Unauthorized settlement if admin grants to a malicious address within the timelock window |
| AS-06 | `OPERATOR_ROLE` in `StakeVault` is granted only to `DisputeResolution` | Bond release to arbitrary recipient if misconfigured |
| AS-07 | All deployed implementations match their audited source hashes | Bytecode mismatch = unknown logic |

---

## 9. Monitoring Signals

| Signal | Source Event | Alert Condition |
|---|---|---|
| Unexpected role grant | `RoleGranted(role, account, sender)` | RESOLVER_ROLE or DEFAULT_ADMIN_ROLE granted to unknown address |
| Upgrade proposal | `UpgradeProposed(impl, callData, eta)` | Any upgrade proposal |
| Claim status anomaly | `ClaimStatusChanged(id, from, to)` | Non-monotonic status transition |
| Large single payout | `RewardClaimed(claimId, recipient, amount)` | Amount > configurable threshold |
| Oracle replacement | `ReputationOracleUpdated(old, new)` | Any oracle address change |
| Dispute bond locked | `BondLocked(disputeId, amount, locker)` | Bond amount < configured minimum |
| Emergency pause | `Paused(account)` | Any pause event |
| Settlement of paused contract | Any settlement call while `paused` | Should revert — alert if it does not |
| Slashing above 50% | `VerifierSlashed(verifier, slashed, remaining, reason)` | `slashedAmount / (slashedAmount + remaining) > 0.5` |

---

## 10. Residual Risks

| ID | Risk | Severity | Mitigation Path |
|---|---|---|---|
| RR-01 | Off-chain oracle integrity not enforced on-chain | High | Add freshness timestamp validation; oracle multi-source aggregation (V2-SC-future) |
| RR-02 | Single EOA as DEFAULT_ADMIN | Critical | Enforce multisig deployment; add `require(isContract(admin))` check in initializer |
| RR-03 | Reputation min/max bounds are admin-settable without timelock | Medium | Add governance timelock to reputation bound changes |
| RR-04 | Slash percentage lower bound not set (can be 0%) | Low | Add `require(percentage >= MIN_SLASH_PERCENT)` with a documented minimum |
| RR-05 | ERC-777 / callback tokens accepted as bounty assets | Medium | Add explicit allowlist check for supported asset types |
| RR-06 | Optimism L2 sequencer liveness dependency for timely settlement | Low | Document as known L2 risk; monitor sequencer health |
| RR-07 | Canonical content hash uses off-chain CID — IPFS availability not guaranteed | Low | Document as known off-chain dependency; CID is evidence pointer, not proof |

---

## 11. Protocol Invariants Linked to Tests

Each invariant below is mapped to its corresponding test file.

| Invariant | Contract | Test Reference |
|---|---|---|
| Claim status is monotonically increasing | `ClaimRegistry` | `test/invariant/TruthBountyInvariant.t.sol` |
| Total verifier weight equals sum of individual weights | `WeightedStaking` | `test/fuzz/WeightedStaking.fuzz.sol` |
| No claim may be settled twice | `ClaimRegistry` | `test/TruthBountyClaims.test.ts` |
| Bond balance in StakeVault ≥ sum of all active locks | `StakeVault` | `test/v2/StakeVaultInvariant.t.sol` |
| Exactly one OPEN round per claim type at any time | `VerificationRoundManager` | `test/VerificationRoundManager.test.ts` |
| Round parameters immutable after `openRound` | `VerificationRoundManager` | `test/VerificationRoundManager.test.ts` |
| `_nextClaimId` strictly increases; no reuse | `ClaimRegistry` | `test/invariant/TruthBountyInvariant.t.sol` |
| Reputation score clipped to `[minScore, maxScore]` | `WeightedStaking` | `test/WeightedStaking.test.ts` |
| RESOLVER_ROLE grant always delayed by timelock | `TruthBountyToken` | `test/ResolverRoleTimelock.test.ts` |
| Upgrade only callable through UpgradeController | All UUPS proxies | `test/upgrade/UpgradeController.t.sol` |
| Treasury emission per epoch ≤ configured cap | Tokenomics module | `test/invariant/TokenomicsInvariant.t.sol` |
| Canonical claim hash is globally unique | `ClaimRegistry` | `test/ClaimRegistry.test.ts` |

---

## 12. Module Boundary Summary

| Module | Reads | Writes | Authority Granted |
|---|---|---|---|
| `ClaimRegistry` | Self | Claim storage | `REGISTRY_UPDATER_ROLE` callers |
| `VerificationSubmission` | `ClaimRegistry` | Stake ledger | None (ReentrancyGuard only) |
| `VerificationRoundManager` | Self | Round ledger | `ROUND_MANAGER_ROLE` callers |
| `DisputeResolution` | `ClaimRegistry`, `StakeVault`, `FeeManager` | Claim status, BondLock | `OPERATOR_ROLE` on StakeVault |
| `StakeVault` | Self | Bond ledger | `OPERATOR_ROLE` only (DisputeResolution) |
| `WeightedStaking` | Oracle | None persistent | None |
| `UpgradeController` | All UUPS proxies | Upgrade execution | Governed timelock |
| `FeeManager` | Self | Fee ledger | No settlement authority |
| Off-chain API / Indexer | Events (read-only) | **None** | **None** — hard boundary |

---

## 13. Migration and Compatibility

- **Active claims in-flight at upgrade time**: Claim parameters are immutable; upgrading `ClaimRegistry` cannot alter in-flight claim state. Storage layout is validated by `StorageCompatibilityValidator` before every upgrade execution.
- **Verifier stakes in-flight**: `VerificationSubmission` is not UUPS; it is replaced by pointing the registry at a new address via admin configuration. Existing stake records remain readable at the old address.
- **Event replay guarantee**: All events (claim create, status change, stake deposit, bond lock, round open/close) carry sufficient indexed fields for deterministic off-chain projection replay. No event-only data is discarded on upgrade.

---

*This document covers the canonical V2 modular suite only. Legacy `TruthBountyClaims`, `TruthBountyWeighted`, and V1 contracts are explicitly out of scope.*

---

## 14. Pause and Token-Failure Error Semantics (PREWAVE-SC-021)

This section is the canonical authority for which layer owns each pause and token-failure
error, and for the precedence rules that govern them. Any test, fixture, manifest, or vector
that asserts a different error must be regenerated from this section. Legacy string errors
are explicitly non-canonical and must not be asserted by new tests.

### 14.1 — Canonical Error Mapping

| Failure Condition | Canonical Error | Owning Layer | Notes |
|---|---|---|---|
| Local pause active on the called contract | `EnforcedPause()` | Contract-local `Pausable` (OZ v5) | Raised by `whenNotPaused` on the entrypoint |
| Scoped pause active (module/operation scope) | `ProtocolPaused(bytes32 scope)` | Pause controller / `PauseGuard` | `scope` is a deterministic operation identifier |
| Global pause active (protocol-wide) | `ProtocolPaused(bytes32 scope)` with `scope == GLOBAL_SCOPE` | Pause controller / `PauseGuard` | Global pause is a scoped pause with the reserved global scope |
| Blacklisted account (sender or recipient) | `Blacklisted(address account)` | Token / compliance layer | Checked before any balance mutation |
| Token returns `false` from `transfer`/`transferFrom` | `SafeERC20FailedOperation(address token)` | `SafeERC20` wrapper | Raised by `SafeERC20` on false return |
| Token reverts on `transfer`/`transferFrom` | `SafeERC20FailedOperation(address token)` | `SafeERC20` wrapper | Revert data is bubbled or wrapped per `SafeERC20` |
| Recipient rejects transfer (e.g. reverting hook) | `SafeERC20FailedOperation(address token)` | `SafeERC20` wrapper | Custody state must not advance |
| Callback reentrancy during payout | `ReentrancyGuardReentrantCall()` | `ReentrancyGuard` | Raised before any state mutation on re-entry |
| Legacy string errors (`"Paused"`, `"paused"`, `"SafeERC20: ..."`) | **Non-canonical** | — | Must not be asserted; remove stale assertions |

### 14.2 — Pause Precedence (Deterministic, Operation-Scoped)

Precedence is evaluated in this fixed order on every guarded entrypoint:

1. **Reentrancy guard** — `ReentrancyGuardReentrantCall()` wins over all pause errors.
2. **Global pause** — `ProtocolPaused(GLOBAL_SCOPE)`.
3. **Scoped pause** — `ProtocolPaused(scope)` for the operation's scope.
4. **Local pause** — `EnforcedPause()` on the called contract.
5. **Authorization** — `AccessControlUnauthorizedAccount(account, role)`.
6. **Token / compliance failures** — `Blacklisted` or `SafeERC20FailedOperation`.

Rules:

- A pause check MUST occur before any token transfer, balance mutation, or external call.
- A scoped pause MUST NOT block operations outside its scope; scope identifiers are stable
  and documented per operation.
- Global pause MUST block every state-mutating operation but MUST NOT block view functions
  or recovery/retry entrypoints explicitly designated as pause-exempt.
- When multiple pause conditions are simultaneously active, the highest-precedence error in
  the list above is the only error surfaced.

### 14.3 — Fail-Closed Guarantees

- **Paused paths**: no state mutation, no token movement, no bond release while any pause
  applies. Recovery entrypoints remain callable and retryable after the pause clears.
- **Blacklisted paths**: transfers to or from a blacklisted account revert with
  `Blacklisted(account)`; custody balances are unchanged.
- **False-return / reverting token paths**: `SafeERC20FailedOperation(token)` is raised and
  custody accounting MUST NOT advance. A failed payout cannot be recorded as settled.
- **Rejecting-recipient paths**: `SafeERC20FailedOperation(token)` is raised; the claim
  remains retryable to an accepted recipient where the operation permits recipient change.
- **Callback reentrancy paths**: `ReentrancyGuardReentrantCall()` is raised before any
  mutation; no double-pay or custody corruption is possible.

### 14.4 — Recovery and Retry

Operations that fail due to a pause, blacklist, false-return token, reverting token, or
rejecting recipient MUST leave the operation in a state that is retryable once the
condition clears, except where the operation is explicitly terminal (e.g. a settled claim).
Retries MUST re-evaluate pause precedence from step 1.

### 14.5 — Reproduction and Toolchain

Canonical error semantics are verified by selector-level ABI regression tests plus the
behavioral tests listed in §11. Reproduction commands and exact toolchain versions are
recorded in the repository's CI configuration and MUST be updated in the same change as
any modification to this section.
