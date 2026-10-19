# Emergency Pause Exit Liveness (V2-SC-162)

**Status:** Enforced in CI · **Matrix version:** 1 · **Depends on:** V2-SC-028, V2-SC-042, V2-SC-062, V2-SC-067, V2-SC-117, V2-SC-118

Emergency controls must stop new risk without trapping user funds. This document is the
specification for which canonical V2 operations a pause blocks, which exits stay available, and
how both are enforced and tested.

Sources of truth:

| Artifact | Role |
|---|---|
| `config/pause-matrix.json` | Versioned, reviewed classification of every operation (with rationale and history) |
| `contracts/v2/libraries/PauseMatrix.sol` | Solidity mirror of the matrix and `PAUSE_MATRIX_VERSION` |
| `contracts/v2/libraries/V2PauseGuard.sol` | The two gates every module uses (`V2PauseGuard`, `V2WiredPauseGuard`) |
| `scripts/check-pause-matrix.mjs` | CI gate: source ⇄ matrix ⇄ mirror ⇄ version agreement |

## 1. Model

### 1.1 Classes

| Class | Meaning | Gate |
|---|---|---|
| `RISK_INCREASING` | Creates new exposure, or mutates an outcome that is not final yet: claim creation, staking, verification, evidence, disputes, settlement, slashing, governance parameters | **Fail closed** on every listed scope |
| `NEUTRAL` | Authority wiring or a module-local toggle. It creates no exposure and moves no value | Never scope-gated |
| `RISK_REDUCING` | A permissionless exit of value that is already final and owned by the caller, or a protective action (pausing, cancelling a nonce) | Never scope-gated on the caller's own path |

Read paths (`view` / `pure`) are never gated.

### 1.2 Gates

- **Scope gate:** `_requireScopeNotPaused(PauseMatrix.SCOPE_X)`. It reverts with
  `V2Errors.ProtocolPaused()` while the pause authority reports the scope as paused. It also fails
  **closed** when the authority cannot be resolved, when the authority call reverts, or when the
  authority returns malformed data.
- **Exit gate (`EXIT_SHUTDOWN_ONLY`):** `_requireExitsNotShutdown()`. It reverts with
  `ExitsFrozenByShutdown()` only when the authority's wired `EmergencyController` gives a healthy
  answer that `pull_settled_claim` is denied. That happens only at level 3 (SHUTDOWN), following
  V2-SC-117 `EmergencyPauseOrdering`. It fails **open** on every dependency failure, so exit
  liveness never depends on the health of the authority, the controller, or the registry. Each
  exit-path probe is gas-capped at `PROBE_GAS_LIMIT` (100k), so a hostile dependency cannot starve
  an exit by burning gas.

### 1.3 Pause authority resolution

| Module | Resolution | How the authority can change |
|---|---|---|
| StakeVault, FinalRewardAllocator, Aggregation | Module registry key `EMERGENCY_CONTROLS` (`_registryPauseAuthority`) | Only through the registry's timelocked replacement (`REPLACEMENT_DELAY`) |
| Claims, EvidenceRegistry, PullSettlementLedger | `setPauseAuthority(address)`, **write-once** (`V2WiredPauseGuard`) | Never from the module. Rotation happens inside the authority, e.g. through the timelocked `EmergencyGatekeeper.setEmergencyController` |

A module whose authority is unwired (`address(0)`) enforces no scoped pause. This keeps the
behaviour from before V2-SC-162. **Deployments must wire the authority before the module accepts
value.**

### 1.4 Core properties

1. **Monotone pause.** A pause only removes capabilities. The exits available while paused are a
   subset of the exits available while unpaused. No path exists only because the protocol is paused.
2. **Frozen claimable set.** Every path that can increase a claimable, credited, or allocated
   balance is `RISK_INCREASING` under `SCOPE_SETTLEMENT`. While settlement is paused, exit-bearing
   balances can therefore only decrease. Exits cannot be amplified, and they cannot change or skip
   settlement.
3. **State-keyed idempotency.** Exits debit accounting before the transfer, and settlement records
   its outcome per `(claimId, round)`, `settlementId`, or `settlementRef`. None of this depends on
   pause state, so pause/unpause ordering cannot replay an exit or a settlement.
4. **Atomic failure.** A rejected transfer (hostile recipient, failing token) reverts the whole
   exit. The value stays tracked and can be retried once the recipient or token is fixed.

## 2. Pause matrix v1

`gates` are unconditional. `conditional` gates apply on a branch only (noted in the rationale).

### StakeVault (`contracts/v2/StakeVault.sol`, registry-resolved)

| Operation | Class | Gates | Notes |
|---|---|---|---|
| `depositStake(uint256,uint256)` | RISK_INCREASING | STAKING | new locked principal |
| `deposit(address,uint256)` | RISK_INCREASING | STAKING | new custody |
| `lock(...)` | RISK_INCREASING | STAKING | new lock (module-only) |
| `releaseStake(uint256,address,uint256)` | RISK_INCREASING | SETTLEMENT | outcome decision |
| `slashStake(uint256,address,uint256,bytes32)` | RISK_INCREASING | SETTLEMENT | outcome decision |
| `unlock(...)` | RISK_INCREASING | SETTLEMENT | live under a staking-only pause, so refunds continue |
| `allocateLocked(...)` | RISK_INCREASING | SETTLEMENT | outcome decision |
| `settleConclusive` / `refundInconclusive` / `carryForwardAppeal` / `rolloverRound` / `finalUnlock` | RISK_INCREASING | SETTLEMENT | single outcome per (claim, round) |
| `setMinStakeAmount(uint256)` | RISK_INCREASING | GOVERNANCE | parameter |
| `setSupportedAsset(address,bool)` | RISK_INCREASING | conditional GOVERNANCE | enabling is gated; disabling stays live |
| `setLockMutator(address,bool)` | RISK_INCREASING | conditional GOVERNANCE | granting is gated; revoking stays live |
| `withdraw(address,uint256)` | **RISK_REDUCING** | EXIT_SHUTDOWN_ONLY | matured (claimable) balance |

### Claims (`contracts/v2/Claims.sol`, wired)

| Operation | Class | Gates | Notes |
|---|---|---|---|
| `createClaim(bytes32,uint256,bytes)` | RISK_INCREASING | CLAIMS | new escrow |
| `finalizeClaim(uint256,IV2Types.ClaimStatus)` | RISK_INCREASING | SETTLEMENT | terminal outcome |
| `setAntiGriefParams(...)` | RISK_INCREASING | GOVERNANCE | parameters |
| `cancelClaim(uint256)` | **RISK_REDUCING** | EXIT_SHUTDOWN_ONLY + conditional SETTLEMENT | the claimant's own refund is an exit; a manager cancelling someone else's claim is an outcome decision and is gated |
| `setPauseAuthority(address)` | NEUTRAL | none | write-once wiring |

### EvidenceRegistry (`contracts/v2/EvidenceRegistry.sol`, wired, nested local pause)

| Operation | Class | Gates | Notes |
|---|---|---|---|
| `submitEvidence(uint256,bytes32,bytes)` | RISK_INCREASING | EVIDENCE (via `commitEvidence`) + local `whenNotPaused` | |
| `commitEvidence(uint256,bytes32,bytes32,uint256)` | RISK_INCREASING | EVIDENCE + local `whenNotPaused` | nested pause |
| `setEvidenceStatus(uint256,IV2Types.EvidenceStatus)` | RISK_INCREASING | EVIDENCE | adjudication can change outcomes |
| `pause()` | **RISK_REDUCING** | none | protective |
| `unpause()` | NEUTRAL | none | lifts only the local switch |
| `setPauseAuthority(address)` | NEUTRAL | none | write-once wiring |

### FinalRewardAllocator (`contracts/v2/FinalRewardAllocator.sol`, registry-resolved)

| Operation | Class | Gates |
|---|---|---|
| `fund(address,uint256,bytes32)` | RISK_INCREASING | SETTLEMENT |
| `finalizeRewards(bytes32,address,FinalOutcome,Allocation[])` | RISK_INCREASING | SETTLEMENT |
| `claim(address,uint256)` | **RISK_REDUCING** | EXIT_SHUTDOWN_ONLY |

### Aggregation (`contracts/v2/Aggregation.sol`, registry-resolved)

| Operation | Class | Gates | Notes |
|---|---|---|---|
| `finalizeAggregation(uint256)` | RISK_INCREASING | VERIFICATION + SETTLEMENT | a verification pause freezes new votes. Finalizing over a frozen, partial vote set would let a pause change the outcome |

### PullSettlementLedger (`contracts/performance/PullSettlementLedger.sol`, wired)

| Operation | Class | Gates |
|---|---|---|
| `credit(address,uint256,bytes32)` | RISK_INCREASING | SETTLEMENT |
| `creditBatch(address[],uint256[],bytes32)` | RISK_INCREASING | SETTLEMENT |
| `withdraw(uint256)` | **RISK_REDUCING** | EXIT_SHUTDOWN_ONLY |
| `withdrawFromRef(bytes32,uint256)` | **RISK_REDUCING** | EXIT_SHUTDOWN_ONLY |
| `setPauseAuthority(address)` | NEUTRAL | none |

### SignatureNonces (`contracts/v2/SignatureNonces.sol`)

| Operation | Class | Gates |
|---|---|---|
| `cancelNonce(uint256)` | **RISK_REDUCING** | none (protective) |

### Other files

- `ConsumerGuaranteesAnchor`, `SupplyChainAttestationAnchor`: view-only, with no mutating operations.
- Inherited OpenZeppelin `grantRole` / `revokeRole` / `renounceRole`: NEUTRAL and not gated, so a
  compromised role can always be revoked during an incident. The role admin is governance.
- Excluded (authority layer): `EmergencyControls`, `EmergencyGatekeeper`, `ModuleRegistry`. These
  are the pause authority and its resolution source, and gating them on themselves would be
  circular. Their separation of powers and timelocks are covered by V2-SC-067 and V2-SC-005.

## 3. Interplay with protocol levels (V2-SC-117)

With the reference scope tolerances (claims, staking, verification, and evidence contained from
level 1; the other scopes from level 2):

| Protocol level | Scoped risk-increasing ops | Value exits | Protective / neutral ops |
|---|---|---|---|
| 0 NORMAL | per scoped pause | live | live |
| 1 HIGH_RISK | HIGH_RISK cohort blocked | **live** | live |
| 2 FINANCIAL | all configured scopes blocked | **live** (`pull_settled_claim` allowed) | live |
| 3 SHUTDOWN | all blocked | **frozen until DAO `liftPause`** | live |

Only `DAO_GOVERNANCE` can lift SHUTDOWN. `EMERGENCY_COUNCIL` cannot, so the council cannot freeze
exits permanently on its own authority.

## 4. Nested and partial pauses

- **Scoped + protocol.** A scoped pause survives de-escalation. While the protocol level exceeds a
  scope's tolerance, that scope cannot be resolved (`EmergencyGatekeeper.unpause` reverts).
- **Module-local + scoped (EvidenceRegistry).** Either switch blocks submission. Lifting one never
  reopens the other.
- **Partial.** A staking-only pause blocks new stake while settlement refunds and exits continue.
  A settlement-only pause freezes outcomes while staking and exits continue. Scopes that no
  canonical module gates on today (`TREASURY`, `DISPUTES`) change nothing.

## 4.1 Read-only status and recovery matrix

`view` and `pure` calls remain callable under local, scoped, nested, global, and protocol-level
pauses. Their return values describe the state observed at the call; they do not authorize a later
transaction. Every submitted mutation must still satisfy its role, lifecycle, pause, and shutdown
checks at execution time. Clients must therefore re-simulate or handle a revert instead of treating
a previously displayed status as an execution permit.

| Read surface | Data remains available while paused | Related execution rule |
|---|---|---|
| `Claims.getClaim`, `stateOf`, `openClaimCount`, `claimsInWindow` | Claim status, lifecycle and limits | `createClaim` checks CLAIMS; `finalizeClaim` checks SETTLEMENT; claimant cancellation remains an exit, subject to shutdown and its conditional settlement rule |
| `EvidenceRegistry.getEvidence`, `getEvidenceCommitment`, `claimEvidence`, `nextContributorNonce`, `evidenceCount` | Evidence state and pagination | Submission checks both the local switch and EVIDENCE; adjudication checks EVIDENCE |
| `StakeVault.staked`, `totalStaked`, `lockedPrincipal`, `claimableBalance`, `settlementOutcome`, `reconcile`, `totalCustody` | Stake, exit eligibility and custody accounting | Deposits and settlement transitions are independently gated; `withdraw` rechecks caller balance and shutdown at execution |
| `FinalRewardAllocator.claimable`, `funded`, `allocated`, `finalized`, `finalOutcome` | Reward and finalization status | `claim` rechecks claimable amount; funding/finalization check SETTLEMENT |
| `PullSettlementLedger.credited`, `withdrawn`, `availableBalance`, `availableRefBalance`, `isRefProcessed` | Recovery balances and settlement-reference status | Both withdrawal forms recheck aggregate credit and shutdown; credits check SETTLEMENT |
| `Aggregation.outcome` and the view-only consumer guarantee / event anchors | Result and integration metadata | Aggregation finalization still checks VERIFICATION and SETTLEMENT; consumer metadata is descriptive |

The frontend/API presentation should pair status with the current pause state from the configured
emergency-controls authority (`paused(scope)`), and present gated actions as unavailable while that
scope is paused. Recovery balances and status must stay visible. The on-chain mutation remains the
source of truth if the pause changes between a read and transaction inclusion.

The executable coverage for the read contract is in
`test/v2/PauseExitLiveness.t.sol::test_pauseViewsRemainReadable_butStaleStatusCannotAuthorizeSettlement`.
Nested local/scoped behavior, global authority behavior, and consumer gating are covered by the
adjacent tests in `PauseExitLiveness.t.sol` and `EmergencyPauseRecoveryExercise.t.sol`.

## 5. Contract behaviour changes

| Change | Why |
|---|---|
| Scope gates added to every RISK_INCREASING operation in StakeVault, Claims, EvidenceRegistry, FinalRewardAllocator, Aggregation, and PullSettlementLedger | These paths did not consult any pause authority, so they stayed open during a pause |
| Exit gate (SHUTDOWN only) added to every value exit | Keeps exits consistent with V2-SC-117 `pull_settled_claim`, and is otherwise unconditionally live |
| `Claims.cancelClaim`: a manager cancelling someone else's claim is gated under SETTLEMENT | That cancellation is an outcome decision. The claimant's own refund stays an exit |
| `StakeVault.setSupportedAsset` / `setLockMutator`: only the enabling direction is gated | Revoking a compromised mutator, or disabling an asset, must stay possible during an incident |
| **`PullSettlementLedger.withdrawFromRef` is also bounded by the aggregate balance** | Bug fix. Aggregate `withdraw` never advanced the per-ref counters, so value already pulled through `withdraw` could be pulled a second time through `withdrawFromRef`, which drew down other beneficiaries' funds. `withdrawn <= credited` now holds across any mix of the two paths |
| `setPauseAuthority` (write-once) on Claims, EvidenceRegistry, and PullSettlementLedger | Lets modules without a registry be wired, and ensures a module admin can never unwire the authority to lift a pause |
| `Claims.stateOf`: `DISPUTLED` corrected to `DISPUTED` | Compile fix in a file this change touches, needed for the new tests |

Storage: the canonical V2 modules are non-upgradeable (constructor + immutables) and are not listed
in `storage-layouts/manifest.json`. The wired modules gain one appended slot (`_wiredPauseAuthority`).

Gas: each gated operation makes one or two extra static calls to the authority (plus a registry
lookup for registry-resolved modules), and each exit makes up to three capped probes.
**`.gas-snapshot` must be regenerated** (`forge snapshot`), because the existing `StakeVaultTest`
entries change.

## 6. Versioning policy

- `PauseMatrix.PAUSE_MATRIX_VERSION`, `matrixVersion` in the JSON, and the latest `history[].version`
  must be equal. Every module exposes `pauseMatrixVersion()`.
- `history[].digest` is `sha256` over the sorted canonical lines
  `Module|signature|CLASS|gate,gate` (unconditional and conditional gates, sorted). Any change to a
  classification or gate changes the digest. CI then fails until the version is bumped in both
  places and a new history entry is appended. Editing a published history entry blocks review.
- `node scripts/check-pause-matrix.mjs --report` prints the detected operations and the current digest.

## 7. Static gate (CI, lint job)

`scripts/check-pause-matrix.mjs` fails when:

- a module declares an external or public non-view operation that the matrix does not classify, or
  the matrix lists an operation that no longer exists;
- the source gates differ from the matrix. Examples: a RISK_INCREASING operation without its scope
  gate, a RISK_REDUCING exit behind a scoped or local pause, an undeclared gate, or a scope gate
  whose argument is not a `PauseMatrix.SCOPE_*` constant;
- the Solidity mirror disagrees with the JSON in either direction;
- the versions disagree, or the digest drifted without a version bump;
- a top-level `contracts/v2/*.sol` file is neither classified nor excluded;
- the fail-closed, fail-open, write-once, or SHUTDOWN-rule anchors in `V2PauseGuard.sol` are missing.

The checker's own tests, using synthetic fixtures and a live-repository check, are in
`test/scripts/check-pause-matrix.test.mjs`.

## 8. Acceptance criteria → evidence

| Acceptance criterion | Evidence (reproducible) |
|---|---|
| The pause matrix is explicit, versioned, and enforced consistently across modules | `config/pause-matrix.json` + `PauseMatrix.sol`. CI runs `node scripts/check-pause-matrix.mjs` and `node --test test/scripts/check-pause-matrix.test.mjs`. `PauseExitLivenessTest.test_matrixClassifiesEveryOperationConsistently`, `test_matrixVersionIsConsistentAcrossModules`, and `test_matrixRejectsUnclassifiedOperation`. `_assertGateConsistency` in every liveness test and `invariant_gatesMatchAuthority` check that all modules agree with the authority |
| Eligible risk-reducing exits remain permissionless and idempotent | `test_liveness_under{Claims,Evidence,Staking,Verification,Settlement,Treasury,Disputes,Governance}Pause`, `test_liveness_underEveryScopePausedAtOnce`, `test_liveness_underProtocol{HighRisk,Financial}`, and `testFuzz_liveness_underAnyScopedPauseSubset`. Each one pays every exit exactly once (`_exerciseAllExits`), then checks that every repeat reverts with a custom error and moves no value (`_assertRepeatExitsIdempotent`). Liveness under dependency failure: `test_dependencyFailure_riskFailsClosed_exitsStayLive`, `test_registryFailure_riskFailsClosed_exitsStayLive`, and `test_gasBurningAuthority_cannotStarveExits`. Stateful checks: `invariant_eligibleExitsAlwaysLive` and `invariant_exitsFreezeOnlyAtShutdown` |
| No paused path can create new exposure, alter final outcomes, or bypass timelock authority | `test_everyGatedOperationFailsClosedUnderItsScope` covers every RISK_INCREASING operation. `_assertRiskGates` runs in every liveness configuration. Outcome and settlement coverage: `test_settlementPause_lockedStakeCannotExitAroundSettlement` and `test_managerCancel_isOutcomeDecision_claimantRefundIsExit`. Governance coverage: `test_governanceMutations_failClosed_revocationsStayLive`. Authority coverage: `test_wiring_isWriteOnce_soAdminCannotLiftAPause` and `test_shutdown_freezesExitsOnlyUntilGovernanceLifts` (the council cannot lift). The authority's own timelocks are covered by `EmergencyPauseRecoveryExercise.t.sol` |
| No sequence of pause, exit, recovery, and unpause strands or duplicates tracked value | `test_pauseUnpauseCycles_cannotReplaySettlementOrExit`, `test_ledgerMixedExitPaths_cannotDoubleWithdraw`, `test_failedTransfer_leavesExitRetryableAndSinglePay`, `test_rejectingRecipient_isIsolatedAndRecoverable`, `test_hostileReentrantRecipient_cannotDoubleWithdraw`, `test_hostileRejectingRecipient_thenRecovers`, `test_nestedPause_*`, and `test_partialPause_*`. `_assertConservation` covers the vault, the allocator, the ledger, and the claims escrow. Stateful checks: `invariant_noDuplication`, `invariant_vaultConservation`, `invariant_rewardSingleClaim`, `invariant_ledgerConservation`, and `invariant_claimsEscrow` |

Reproduce:

```bash
node scripts/check-pause-matrix.mjs
node --test test/scripts/check-pause-matrix.test.mjs
forge test --match-path test/v2/PauseExitLiveness.t.sol -vv
forge test --match-path test/v2/invariant/PauseExitLivenessInvariant.t.sol -vv
```

## 9. Residual risk and non-goals

- **Unwired modules** enforce no scoped pause, which matches their behaviour before V2-SC-162.
  Deployment tooling must wire `EMERGENCY_CONTROLS` in the registry and call `setPauseAuthority` on
  the wired modules.
- **Pre-pause corruption.** Exits stay live under every scoped pause and under levels 1–2. If an
  incident has already inflated a claimable balance before the pause, only SHUTDOWN (level 3)
  freezes egress. This follows the V2-SC-117 `pull_settled_claim` rule.
- `ProvisionalSettlementEngine` and the legacy V1 contracts are out of scope. They keep their own
  `Pausable` switches.
- **Stranded stake (outside this issue).** StakeVault records one settlement outcome per
  `(claimId, round)` for the whole claim, not per account. After the first account settles on a
  claim round, other accounts' locks on that round cannot be released. This is a protocol-design
  property and is left unchanged here (protocol redesign is a non-goal).
