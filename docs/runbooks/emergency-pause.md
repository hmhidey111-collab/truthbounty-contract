# Emergency Pause Runbook

## Purpose

This runbook defines the authoritative operational procedure for activating, verifying, and monitoring emergency pause states across the TruthBounty protocol. It governs both the multi-level circuit breaker framework (`EmergencyController.sol`) and the scoped V2 module controls (`EmergencyControls.sol`).

---

## Authority & Separation of Powers

The protocol enforces strict separation of powers across distinct administrative roles:

| Role | Authorized Address / Actor | Activation Powers | Lifting Powers | Security Invariants |
|---|---|---|---|---|
| **EMERGENCY_COUNCIL** | Multi-sig / rapid response key | Levels 1, 2, 3 (or any V2 scope) | **NONE (Cannot lift pause)** | Rapid response only; cannot unilaterally resume operations |
| **DAO_GOVERNANCE** | Governor + Timelock | Levels 1, 2 (or any V2 scope) | **Full lifting authority** | Formal governance consensus required to lift any pause |
| **TIMELOCK_CONTROLLER** | Governance Timelock contract | Level 1 only (HighRisk) | **NONE** | Subject to mandatory `timelockCooldown` (default 1 hour) |
| **RECOVERY_EXECUTOR** | Designated operational role | None (execution only) | Stepwise recovery | Must execute post-lift verification steps (1 → 2 → 3) |
| **GUARDIAN** | Emergency guardian key | Scoped pause only | **NONE (Cannot unpause)** | May only tighten control; unpause always requires governed authority |

---

## Operation ID Matrix (V2-SC-034)

Every pausable mutation maps to exactly one canonical operation ID. IDs are derived from function/interface authority and are stable across renames, proxy upgrades, and redeploys. The runtime source of truth is `contracts/v2/libraries/PauseMatrix.sol`; the machine-readable matrix is `config/pause-matrix.json`.

| Operation ID | Module | Function Authority | Scope | Scoped Pause Effect |
|---|---|---|---|---|
| `claim_creation` | Claims | `createClaim()` | `SCOPE_CLAIMS` | Blocked while scope paused or protocol level ≥ 1 |
| `claim_cancel` | Claims | `cancelClaim()` | `SCOPE_CLAIMS` | Always available to the claimant (owner-refund) |
| `staking` | StakeVault | `stake(), delegate() | `SCOPE_STAKING` | Blocked while scope paused or protocol level ≥ 1 |
| `withdrawal` | StakeVault | `withdraw()` | `SCOPE_STAKING` | Always available for claimable balances |
| `verification_submission` | VerificationRegistry | `submitVerification() | `SCOPE_VERIFICATION` | Blocked while scope paused or protocol level ≥ 1 |
| `aggregation` | VerificationRegistry | `aggregate()` | `SCOPE_VERIFICATION` | Blocked while scope paused or protocol level ≥ 1 |
| `evidence_submission` | EvidenceRegistry | `submitEvidence() | `SCOPE_EVIDENCE` | Blocked while scope paused or protocol level ≥ 1 |
| `evidence_pause` | EvidenceRegistry | `pause()` | `SCOPE_EVIDENCE` | Always available (protective action) |
| `reward_distribution` | FinalRewardAllocator | `distribute() | `SCOPE_TREASURY` | Blocked while scope paused or protocol level ≥ 2 |
| `reward_claim` | FinalRewardAllocator | `claim() | `SCOPE_TREASURY` | Always available for claimable balances |
| `treasury_transfer` | Treasury | `transfer() | `SCOPE_TREASURY` | Blocked while scope paused or protocol level ≥ 2 |
| `settlement_pull` | PullSettlementLedger | pull() | `SCOPE_SETTLEMENT` | Blocked while scope paused or protocol level ≥ 1 |
| `settlement_withdraw` | PullSettlementLedger | `withdraw(), withdrawFromRef()` | `SCOPE_SETTLEMENT` | Always available for claimable balances |
| `governance_params` | Governance | `setParam()` | `SCOPE_GOVERNANCE` | Blocked while scope paused or protocol level ≥ 1 |
| `governance_recovery` | EmergencyController | `liftPause(), completeRecoveryStep()` | `SCOPE_ALL` | Available to DAO governance only |

 IDs are canonical and cannot collide silently: the runtime checks `PauseMatrix.registerOperation()` and reverts with `DuplicateOperationId()` on any duplicate mapping. Unknown operations fail closed via `VCErrors.UnknownOperation()` on `isOperationPaused()` and `requireOperationNotPaused()`.

### Stability guarantees

- **Selector collision**: two distinct function signatures that hash to the same 4-byte selector must not share an operation ID; the matrix registration rejects the collision.
- **Renamed function**: operation IDs are derived from the canonical interface authority, not the Solidity function name, so renaming a function without changing its authority does not move the ID.
- **Proxy upgrade**: the matrix is keyed by operation ID, not implementation address, so an upgrade that preserves the interface authority preserves the ID.
- **Unknown operation**: any operation ID not present in the matrix fails closed.
- **Duplicate mapping**: attempting to register the same operation ID twice reverts.
- **Nested pause**: a scoped pause nested inside a protocol-level escalation is idempotent; the operation remains blocked and the ID is unchanged.

#### Published matrix consumers

The matrix is published for frontend and API consumers:

- **Frontend**: import `config/pause-matrix.json` to disable or decorate mutation controls by operation ID.
- **API**: expose `isOperationPaused(operationId)` and the matrix digest from the runtime contract.

The published matrix must match the runtime checks; check the digest in CI and fail the release gate on any drift.

---

## Multi-Level Circuit Breaker Matrix

The protocol supports four tiered operational levels:

### Level 0 — Normal
- **Description:** Full protocol operations.
- **Allowed Operations:** All claims, evidence, verifications, staking, disputes, treasury, and withdrawals.
- **Recovery Status:** `recoveryComplete == true`.

### Level 1 — HighRisk
- **Description:** Halts high-risk protocol mutations when suspect activity, oracle drift, or verification anomalies are detected.
- **Blocked Operations:**
  - `claim_creation`
  - `staking`
  - `verification_submission`
- **Permitted Operations:**
  - Treasury movements and reward distributions
  - Withdrawals
  - All read-only state queries
  - Governance proposals and timelock executions

### Level 2 — Financial
- **Description:** Halts all value transfers and financial movements in addition to Level 1 restrictions when fund drain risk or invariant violation is suspected.
- **Blocked Operations:**
  - All Level 1 blocked operations
  - `reward_distribution`
  - `treasury_transfer`
  - `withdrawal`
- **Permitted Operations:**
  - Read-only queries
  - Governance recovery actions

### Level 3 — Shutdown
- **Description:** Global emergency lockdown.
- **Blocked Operations:**
  - All standard protocol mutations and user actions.
- **Permitted Operations:**
  - `governance_recovery` calls authorized by DAO governance.

---

## Trigger Procedures

### 1. Emergency Council Rapid Activation (Levels 1–3)

1. Verify the incident nature and select the appropriate pause level.
2. Formulate an immutable on-chain reason and governance tracking reference:
   ```solidity
   emergencyController.activatePause(
       level,              // 1, 2, or 3
       "Reason string",    // e.g. "Oracle discrepancy in verification round"
       proposalRef         // keccak256("INCIDENT-YYYY-MM-DD-001")
   );
   ```
3. For canonical V2 module-scoped emergencies:
   ```solidity
   emergencyControls.pause(scope); // e.g. SCOPE_CLAIMS, SCOPE_TREASURY, or SCOPE_ALL
   ```

### 2. Timelock Controller Activation (Level 1)

1. Timelock initiates `activatePause(LEVEL_HIGH_RISK, reason, proposalRef)`.
2. Must verify that `block.timestamp >= lastTimelockActivation + timelockCooldown`.

---

## Governed-Unpause Preconditions (PREWAVE-SC-035)

An unpause (`EmergencyGatekeeper.unpause(scope)`) is only accepted when **all**
of the following machine-verifiable preconditions hold. Any failure reverts and
leaves the scope paused:

1. **Governed authority** — the caller holds `PAUSE_RESOLVER`, which is granted
   only through the governance timelock. The guardian and `PAUSE_INITIATOR`
   roles can never unpause.
2. **Timelock ready** — `block.timestamp >= unpauseReadyAt(scope)`, where
   `unpauseReadyAt` is set at pause time to `pausedAt + emergencyUnpauseDelay`.
3. **Incident reference** — a non-zero `incidentRef` (e.g.
   `keccak256("INCIDENT-YYYY-MM-DD-001")`) must be supplied and must match the
   reference recorded at pause time.
4. **Repaired release** — `releaseHash` must equal the currently approved
   release hash; unpausing against a stale or unapproved release reverts.
5. **Dependency health** — the wired `EmergencyController` must be reachable
   and report a level at or below the scope's tolerance.
6. **Current pause state** — `locallyPaused(scope)` must be `true`; a repeated
   unpause of an already-resolved scope reverts with `ScopeNotPaused`.

Unpause affects only the targeted `scope`. Sibling scopes remain paused until
individually resolved, and each resolution emits `EmergencyUnpaused` linked to
the originating `EmergencyPaused` record via the shared `incidentRef`.

---

### A. Multi-Level Controller Verification (`$EMERGENCY_CONTROLLER`)

1. **Verify On-Chain Pause Level:**
   ```bash
   cast call $EMERGENCY_CONTROLLER "getPauseLevel()(uint8)"
   ```
   *Expected:* Returns target level (1, 2, or 3).

2. **Verify Audit Trail Registration:**
   ```bash
   cast call $EMERGENCY_CONTROLLER "getEmergencyHistoryCount()(uint256)"
   ```
   Query the latest record via `getEmergencyHistory(start, count)` to ensure initiator, reason, and proposal reference are immutably logged.

3. **Verify Operation Freezing:**
   Simulate restricted transactions via `eth_call`:
   - High-risk operations must revert with `OperationPaused(operationType, level)`.
   - Financial withdrawals must revert when level ≥ 2.

4. **Confirm Read Integrity:**
   Ensure read calls (e.g. balance queries, claim state, parameter queries) succeed without disruption.

### B. V2 Scoped Emergency Controls Verification (`$EMERGENCY_CONTROLS`)

1. **Verify Target Scope Pause Status:**
   ```bash
   cast call $EMERGENCY_CONTROLS "paused(bytes32)(bool)" $SCOPE
   ```
   *Expected:* Returns `true` for paused scope (or all scopes if `SCOPE_ALL` was paused).

2. **Verify Pause Metadata:**
   ```bash
   cast call $EMERGENCY_CONTROLS "pausedAt(bytes32)(uint256)" $SCOPE
   cast call $EMERGENCY_CONTROLS "pauseCount(bytes32)(uint256)" $SCOPE
   ```

3. **Verify Event Emission:**
   Check event logs for `EmergencyPaused(bytes32 indexed scope, address indexed actor, uint64 timestamp, uint16 version)` confirming actor, timestamp, and version `1`.

4. **Verify Gated Module Mutation Rejection:**
   Verify that calls to modules implementing `IEmergencyControls` checks revert with `V2Errors.ProtocolPaused()`.

5. **Verify Operation ID Matrix Digest:**
   ```bash
   cast call $EMERGENCY_CONTROLS "operationMatrixDigest())"ybytes32"
   ```
   Compare the returned digest to the digest of `config/pause-matrix.json`. Any mismatch fails the release gate.

---

## Post-Pause Recovery Handoff

Once the pause is active and state is frozen:
1. Initiate the **Emergency Recovery and Unpause Drill Runbook** (`docs/runbooks/emergency-drills.md`).
2. Convene DAO Governance and Security Council to diagnose root cause.
3. Prepare timelocked configuration repairs or module upgrades before lifting.
# Runbook: Emergency Pause (V2)

Operational procedure for pausing and recovering the protocol using the
canonical V2 emergency surface.

## Who can pause

| Actor | Surface | Capability |
|---|---|---|
| Emergency Council | `EmergencyController.activatePause` | Escalate protocol pause levels 1–3 (rapid response) |
| DAO Governance | `EmergencyController.activatePause` / `liftPause` | Escalate any level; the only authority that can de-escalate |
| Timelock Controller | `EmergencyController.activatePause` | Level 1 only, subject to a cooldown between activations |
| PAUSE_INITIATOR | `EmergencyGatekeeper.pause` | Scoped pause; can never unpause |
| PAUSE_RESOLVER | `EmergencyGatekeeper.pause` / `unpause` | Scoped pause and post-remediation resolution |

Every pause action emits an immutable audit event
(`EmergencyPauseActivated`, `EmergencyPaused`, and companions in
`docs/event-catalogue-v1.md`).

## When pause is allowed

- Scoped pauses (`EmergencyGatekeeper.pause(scope)`) are allowed while the
  protocol-level controller is not escalated beyond the scope's configured
  tolerance (`setScopeMaxPauseLevel`).
- Global escalation via `EmergencyController` contains every scope; at
  level 3 (shutdown) the gatekeeper treats all scopes as paused regardless
  of tolerance.
- If the wired `EmergencyController` is unavailable (unreachable,
  reverts, or returns malformed data), the gatekeeper fails closed: reads
  classify every scope as paused and mutations revert.

## How to verify pause

1. `EmergencyGatekeeper.paused(scope)` — must return `true` for the
   affected scope(s).
2. `EmergencyGatekeeper.locallyPaused(scope)` — `true` means a scoped
   pause record exists (vs. containment by protocol escalation).
3. `EmergencyController.getPauseLevel()` — the protocol-wide level.
4. Attempt a gated mutation against a canary module; it must revert with
   `V2Errors.ProtocolPaused`.
5. `isOperationPaused(operationId)` must match the operation ID row in
   `config/pause-matrix.json` for the affected module.

## Recovery procedure

1. **Remediate the incident** off-chain; agree the remediation record.
2. **De-escalate the protocol level**: only `DAO_Governance` may call
   `EmergencyController.liftPause`.
3. **Complete the staged recovery steps** on the `EmergencyController`
   (`completeRecoveryStep` × 3 by the recovery executor).
4. **Resolve scoped pauses**: `PAUSE_RESOLVER` calls
   `EmergencyGatekeeper.unpause(scope)` for each scope. Resolution is
   rejected while the protocol level exceeds the scope's tolerance.
   The call must carry the incident reference and repaired release hash and
   must satisfy every governed-unpause precondition listed above; the guardian
   role cannot perform this step under any circumstance.
5. **Verify resumption**: `paused(scope)` returns `false` and a canary
   gated mutation succeeds. Escrowed balances must be unchanged across
   the pause window.

Dependency rewiring (`EmergencyGatekeeper.setEmergencyController`) is
timelocked: replacing or removing a wired controller requires waiting
`emergencyRewireDelay` (default 1 hour, bounded [1 hour, 30 days]).
Wiring a controller when none is wired is immediate, because that
direction only ever tightens control.

## Exercise suite

`test/v2/EmergencyPauseRecoveryExercise.t.sol` rehearses this runbook
against the canonical contracts:

| Drill group | What is proven |
|---|---|
| Configuration | Invalid admin/initiator/resolver, delay bounds, hostile dependency surface, scope-tolerance bounds — all fail closed |
| Compromised roles | Unprivileged callers cannot pause/unpause; the initiator can never unpause |
| Governed unpause | Guardian attempt, stale incident, wrong release, timelock-not-ready, partial pause, repeated unpause, and successful governed unpause |
| Selective pause | Pausing one scope freezes it while sibling scopes stay operational; escrow survives |
| Full pause | Protocol levels 1–3 contain scopes per tolerance; shutdown contains everything and blocks resolution |
| Dependency failure | Reverting, short-returndata, and corrupt-returndata dependencies fail closed; recovery requires a healthy dependency |
| Timelock | Rewiring or unwiring the dependency waits the enforced delay; the new authority takes effect immediately after |
| Remediation & resumption | De-escalation, staged resolution, and safe resumption with intact escrow |
| Operation ID stability | Selector collision, renamed function, proxy upgrade, unknown operation, duplicate mapping, and nested pause all fail closed or remain stable |

Fuzz properties: `test/v2/EmergencyGatekeeperFuzz.t.sol`.
Invariants (pause effectiveness, escalation containment, exact ghost
bookkeeping): `test/v2/EmergencyGatekeeperInvariant.t.sol`.

## What stays available while paused (V2-SC-162)

The authoritative per-operation matrix is `config/pause-matrix.json`
(mirrored in `contracts/v2/libraries/PauseMatrix.sol`). The full
specification is in `docs/v2/emergency-pause-exit-liveness.md`.

- **Scoped pauses and protocol levels 1–2 never block user exits.** The
  exits are `StakeVault.withdraw` of claimable balances,
  `FinalRewardAllocator.claim`, `PullSettlementLedger.withdraw` and
  `withdrawFromRef`, and a claimant's own `Claims.cancelClaim` refund.
  Protective actions (`EvidenceRegistry.pause`, `cancelNonce`, revoking
  a lock mutator) also stay available.
- **Level 3 (SHUTDOWN) freezes value exits.** They resume as soon as DAO
  governance calls `liftPause`. The emergency council cannot lift.
- **Risk-increasing operations fail closed** on their scope: claim
  creation, staking, verification and aggregation, evidence, settlement,
  and governance parameters (`SCOPE_GOVERNANCE`). They also fail closed
  whenever the pause authority is unreachable or misbehaving. Exits do
  **not** depend on the authority being healthy.
- **Before go-live**, register the gatekeeper under `EMERGENCY_CONTROLS`
  in the module registry. Then call `setPauseAuthority(gatekeeper)` once
( on Claims, EvidenceRegistry, and PullSettlementLedger. Wiring is
  write-once: it cannot be used to lift a pause.
- **Verification.** `isScopePaused(scope)` and `exitsFrozen()` on any
  canonical module must match `EmergencyGatekeeper.paused(scope)` and
  whether the level is 3.