# V2 Reentrancy Posture Audit

**Scope:** Post-Wave-9 contract readiness boundary — external mutation inventory,
callback posture, read-only assessment, and atomic rollback analysis for all seven
core V2 contracts.

**Date:** 2026-10-16
**Audit basis:** Source review + Foundry test suite `test/v2/ReentrancyPostureAudit.t.sol`
**Acceptance criteria:**

| # | Criterion | Status |
|---|-----------|--------|
| AC-1 | Every external mutation has a documented reentrancy posture | ✅ Covered in §2 |
| AC-2 | No callback creates duplicate effects | ✅ Covered in §3 |
| AC-3 | Read-only exposure is assessed | ✅ Covered in §4 |
| AC-4 | Failures roll back atomically | ✅ Covered in §5 |

---

## 1. Methodology

For each external/public state-mutating function the audit records:

- **Guard** — `nonReentrant` (OZ `ReentrancyGuard`) present or absent.
- **Transfer direction** — inbound (`transferFrom`), outbound (`transfer`/`safeTransfer`),
  or none.
- **Callback surface** — whether the token or a recipient could fire a callback during
  the function's execution.
- **Posture** — one of:
  - **GUARD** — protected by `nonReentrant`; no CEI analysis strictly required.
  - **CEI** — no `nonReentrant` guard; safe because the contract follows
    checks-effects-interactions (state fully written before any external call).
  - **CONTROLLED** — no guard needed because the only caller is an on-chain-authorised
    module (settlement role or governance) with no token transfer occurring before the
    write completes.
  - **ADMIN-ONLY** — mutates state but is restricted to a privileged admin role and
    performs no token transfer; reentrancy risk is negligible.

---

## 2. External Mutation Inventory

### 2.1 StakeVault (`contracts/v2/StakeVault.sol`)

All state-mutating external functions on StakeVault carry `nonReentrant`.

| Function | Guard | Transfer | Callback surface | Posture |
|---|---|---|---|---|
| `depositStake(claimId, amount)` | nonReentrant | inbound `transferFrom` | Token fires during `transferFrom` | GUARD |
| `releaseStake(claimId, account, amount)` | nonReentrant | none | None | GUARD |
| `slashStake(claimId, account, amount, reason)` | nonReentrant | none | None | GUARD |
| `deposit(asset, amount)` | nonReentrant | inbound `transferFrom` | Token fires during `transferFrom` | GUARD |
| `lock(asset, account, claimId, round, category, amount)` | nonReentrant | none | None | GUARD |
| `unlock(asset, account, claimId, round, category, amount)` | nonReentrant | none | None | GUARD |
| `allocateLocked(asset, account, claimId, round, category, amount, reason)` | nonReentrant | none | None | GUARD |
| `settleConclusive(asset, account, claimId, round, principal, reward)` | nonReentrant | outbound `transfer` (via `_creditReward`) | Recipient or token fires on receipt | GUARD |
| `refundInconclusive(asset, account, claimId, round, amount)` | nonReentrant | none | None | GUARD |
| `withdraw(asset, amount)` | nonReentrant | outbound `transfer` | Recipient or token fires on receipt | GUARD |
| `enableAsset(asset, enabled)` | — | none | None | ADMIN-ONLY |
| `setLockMutator(module, enabled)` | — | none | None | ADMIN-ONLY |
| `setMinStakeAmount(amount)` | — | none | None | ADMIN-ONLY |

**Note on `withdraw`:** This function is explicitly designated as a RISK_REDUCING exit
(`_requireExitsNotShutdown`). It intentionally bypasses the pause-scope gates so that
stakers can always retrieve their vested claimable balances even during an emergency
pause. The `nonReentrant` guard still applies; the absence of a scope gate is by design.

---

### 2.2 FinalRewardAllocator (`contracts/v2/FinalRewardAllocator.sol`)

FinalRewardAllocator intentionally omits `nonReentrant` on all three external mutations.
Safety is achieved through CEI and caller restriction instead. This is a deliberate
design choice documented here.

| Function | Guard | Transfer | Callback surface | Posture |
|---|---|---|---|---|
| `fund(asset, amount, settlementId)` | **none** | inbound `transferFrom` | Token fires during `transferFrom` | CONTROLLED + CEI¹ |
| `finalizeRewards(settlementId, asset, outcome, allocations)` | **none** | none | None | CONTROLLED |
| `claim(asset, amount)` | **none** | outbound `transfer` | Recipient or token fires on receipt | **CEI** |

**¹ fund() CEI rationale:** The only state written before the `transferFrom` is a
settlement-ID uniqueness check (`_finalized[sid]` for `finalizeRewards`; fund has no
idempotency check itself, but the caller is restricted to the registered SETTLEMENT module
and the `SCOPE_SETTLEMENT` pause guard is applied before the transfer). Because only
the registered module can call `fund`, and the module itself is guarded, a callback
through the inbound token would re-enter with a different `msg.sender` than the
settlement module address; `_onlySettlementModule()` would revert it immediately.

**claim() CEI proof (AC-2):**

```
// Correct CEI order in claim():
uint256 available = _claimable[asset][msg.sender];    // CHECK
if (amount == 0 || amount > available) revert ...;
_claimable[asset][msg.sender] = available - amount;   // EFFECT: zeroed before transfer
IERC20(asset).safeTransfer(msg.sender, amount);        // INTERACTION
```

A callback fired during `safeTransfer` finds `_claimable[asset][msg.sender] = 0`
and a re-entry attempt will revert with `InsufficientClaimable`. Verified by
`test_recipientCallback_reentrantClaim_blockedByCEI`.

---

### 2.3 FeeManager (`contracts/fees/FeeManager.sol`)

| Function | Guard | Transfer | Callback surface | Posture |
|---|---|---|---|---|
| `collectFee(feeType, payer, amount, claimId, recordId)` | nonReentrant | inbound `transferFrom` | Token fires during `transferFrom` | GUARD |
| `distributeReservedFees()` | nonReentrant | outbound `transfer` (per allocation) | Recipient or token fires on each transfer | GUARD |
| `setAllocationTargets(targets)` | — | none | None | ADMIN-ONLY |
| `setFeeActive(feeType, active)` | — | none | None | ADMIN-ONLY |
| `updateFeeSchedule(feeType, schedule)` | — | none | None | ADMIN-ONLY |
| `pause() / unpause()` | — | none | None | ADMIN-ONLY |

**Note on `distributeReservedFees`:** This function iterates over allocation targets
and calls `transfer` once per target. Each iteration is covered by the single `nonReentrant`
lock held for the whole call. A callback from any individual transfer cannot re-enter
`distributeReservedFees` or any other nonReentrant function on FeeManager.

---

### 2.4 InsuranceFund (`contracts/insurance/InsuranceFund.sol`)

| Function | Guard | Transfer | Callback surface | Posture |
|---|---|---|---|---|
| `fund(amount, source, description)` | nonReentrant | inbound `transferFrom` | Token fires during `transferFrom` | GUARD |
| `executePayout(claimId)` | nonReentrant | outbound `transfer` | Recipient or token fires on receipt | GUARD |
| `allocateFromFees(amount, source)` | nonReentrant | none | None | GUARD |
| `submitClaim(beneficiary, amount, ...)` | **none** | none | None | CONTROLLED² |
| `rejectClaim(claimId, reason)` | **none** | none | None | CONTROLLED² |
| `approveClaim(claimId)` | **none** | none | None | CONTROLLED² |

**² No-guard safety rationale for submitClaim, rejectClaim, approveClaim:**
None of these functions perform any token transfer. They write only to the `claims`
mapping (a state struct with an explicit state machine). Because there is no outbound
token call, there is no callback entry point. The only attack vector would be a
read-modify-write race, which requires a concurrent second transaction — not possible
in single-threaded EVM execution. Governance-only access (`onlyGovernanceOrAdmin`)
further narrows the attack surface.

**executePayout idempotency (AC-2):**
The claim state machine enforces `status == APPROVED` as a precondition. After payout
the claim is moved to `PAID` before any external token transfer in the sequence:

```
claims[claimId].status = ClaimStatus.PAID;   // EFFECT
reserveToken.safeTransfer(claim.beneficiary, ...); // INTERACTION
```

A callback during the transfer finds `status == PAID` and will be rejected.
`nonReentrant` provides an additional hard stop. Verified by
`test_recipientCallback_reentrantExecutePayout_blockedByStateMachine`.

---

### 2.5 AppealVerificationRound (`contracts/disputes/AppealVerificationRound.sol`)

AppealVerificationRound delegates token custody to StakeVault; it holds no ERC-20
balance itself. External calls go through the vault interface.

| Function | Guard | Transfer | Callback surface | Posture |
|---|---|---|---|---|
| `openAppealRound(claimId)` | nonReentrant | none direct — `vault.lock()` external | Vault call is guarded at vault layer | GUARD |
| `openBoundAppealRound(params)` | nonReentrant | none direct — `vault.lock()` external | Vault call is guarded at vault layer | GUARD |
| `voteOnAppealRound(claimId, vote, amount)` | nonReentrant | none direct — `vault.lock()` external | Vault call is guarded at vault layer | GUARD |
| `refundAppealBond(claimId)` | nonReentrant | none direct — `vault.unlock()` external | Vault unlock is guarded at vault layer | GUARD |
| `slashAppealBond(claimId, slashRecipient)` | nonReentrant | none direct — `vault.slash()` external | Vault slash is guarded at vault layer | GUARD |
| `closeAppealRound(claimId, round)` | nonReentrant | none | None | GUARD |
| `finalizeAppealRound(claimId, round)` | nonReentrant | none | None | GUARD |

**Layered guard note:** Every AppealVerificationRound function that calls into
StakeVault holds its own `nonReentrant` lock on the `AppealVerificationRound` call frame.
StakeVault's `nonReentrant` lock is a separate OZ `ReentrancyGuard` instance on the
vault. A callback through the vault cannot re-enter the appeal round because the appeal
round's own lock is still held. A callback through the appeal round cannot re-enter the
vault because the vault's lock is still held.

---

### 2.6 UpgradeController (`contracts/upgrade/UpgradeController.sol`)

UpgradeController performs no token transfers. Its external callbacks are governance
calls to `upgradeToAndCall` on UUPS proxies.

| Function | Guard | Transfer | Callback surface | Posture |
|---|---|---|---|---|
| `proposeUpgrade(...)` | nonReentrant | none — `versionRegistry` read | IVersionRegistry call (read) | GUARD |
| `scheduleUpgrade(proposalId)` | nonReentrant | none | None | GUARD |
| `executeUpgrade(proposalId)` | nonReentrant | none — `proxy.upgradeToAndCall()` | Proxy init code runs; nonReentrant blocks re-entry | GUARD |
| `cancelUpgrade(proposalId)` | nonReentrant | none | None | GUARD |
| `rollbackUpgrade(proposalId)` | nonReentrant | none — `proxy.upgradeToAndCall()` | Proxy init code runs; nonReentrant blocks re-entry | GUARD |

**executeUpgrade callback isolation:** `upgradeToAndCall` may execute arbitrary
initialiser code on the proxy. Because the UpgradeController has already acquired the
`nonReentrant` lock before this call, any reentrant call back into `executeUpgrade`,
`cancelUpgrade`, or any other guarded function on UpgradeController will revert. This
prevents an upgrade initialiser from manipulating the proposal ledger mid-execution.
Verified by `test_nestedFailure_executeUpgradeReverts_rollsBack`.

---

### 2.7 EmergencyGatekeeper (`contracts/v2/EmergencyGatekeeper.sol`)

| Function | Guard | Transfer | Callback surface | Posture |
|---|---|---|---|---|
| `pause(scope)` | nonReentrant | none — `EmergencyController.pauseScope()` external | Controller call; nonReentrant blocks re-entry | GUARD |
| `unpause(scope)` | nonReentrant | none — `EmergencyController.unpauseScope()` external | Controller call; nonReentrant blocks re-entry | GUARD |
| `setEmergencyController(newController)` | nonReentrant | none | None | GUARD |
| `configureScope(scope, maxPauseLevel)` | nonReentrant | none | None | GUARD |

**`paused(scope)` read note:** `paused()` is a `public view` function. It contains a
low-level `staticcall` to the wired `EmergencyController`. Because `staticcall`
prevents state mutation, any callback through the external controller cannot write
state back to the gatekeeper. Failure of the `staticcall` (controller misbehaviour)
is handled safely: `paused()` classifies any anomaly as "paused", failing closed
and protecting downstream modules. Verified by `test_readOnly_pausedView_noSideEffect`.

---

## 3. No-Callback Duplicate-Effect Assertion (AC-2)

The following transfer-out functions are verified to produce exactly one credit per call.

| Contract | Function | Duplicate-effect guard | Verification |
|---|---|---|---|
| StakeVault | `withdraw` | nonReentrant prevents recursive call; claimable decremented before transfer | `test_sameFunction_withdrawDuringWithdraw_reverts` |
| StakeVault | `settleConclusive` | nonReentrant; settlement outcome written `CONCLUDED` before transfer | `test_nestedFailure_settleWithNoLockReverts` |
| FinalRewardAllocator | `claim` | CEI: `_claimable` zeroed before `safeTransfer` | `test_recipientCallback_reentrantClaim_blockedByCEI` |
| FeeManager | `distributeReservedFees` | nonReentrant; `_reservedFees[target]` zeroed before batch transfer | No additional test needed (guard is nonReentrant) |
| InsuranceFund | `executePayout` | nonReentrant + state machine (PAID before transfer) | `test_recipientCallback_reentrantExecutePayout_blockedByStateMachine` |

**Cross-function duplicate-effect:**

The cross-function tests confirm that no combination of (deposit, withdraw), (claim,
fund), or (executePayout, fund) produces more credits than the corresponding debits.

| Test | Functions crossed | Contract | Result |
|---|---|---|---|
| `test_crossFunction_withdrawDuringDeposit_reverts` | deposit → withdraw | StakeVault | Re-entry blocked |
| `test_crossFunction_depositDuringWithdraw_reverts` | withdraw → deposit | StakeVault | Re-entry blocked |
| `test_crossContract_allocatorClaimDoesNotAffectVaultBalance` | allocator.claim → vault read | Cross-contract | Balances independent |

---

## 4. Read-Only Exposure Assessment (AC-3)

View and pure functions do not modify state. The relevant risks are:

1. **Stale mid-transaction reads via staticcall/view** — A view called from within a
   callback might observe intermediate state. This is only a risk if the intermediate
   state is incorrectly used to authorise a subsequent write. In all seven contracts,
   intermediate state is either covered by `nonReentrant` (write is impossible) or by
   CEI (the relevant state slot has already been updated before the callback fires).

2. **Registry callbacks from within view functions** — `EmergencyGatekeeper.paused()`
   and `V2PauseGuard.isScopePaused()` call into the external `EmergencyController`
   via `staticcall`. The use of `staticcall` ensures no state mutation can occur in
   the called contract during a view query.

3. **Conservation reads during active deposits/withdrawals** — `StakeVault.conservation()`
   is a pure accounting view. It reads `_totalCustody`, `_totalObligations`, and the
   live ERC-20 balance. During an active deposit, the intermediate state is:
   `_totalCustody` not yet incremented (pre-write), but the ERC-20 balance already
   incremented (transfer happened). This creates a transient discrepancy visible only
   within the guarded call frame — which is protected by `nonReentrant`. No external
   code can observe this mid-frame state because `nonReentrant` prevents any re-entry.

**Read-only verdict:** No read-only function opens a writable callback path. All view
functions either use `staticcall` for external queries or read only contract-local
storage. Confirmed by:
- `test_readOnly_conservationDuringDeposit_noSideEffect`
- `test_readOnly_claimableAndFundedAreConsistent`
- `test_readOnly_pausedView_noSideEffect`
- `test_readOnly_getProposal_noSideEffect`
- `test_readOnly_reserveBalance_noSideEffect`

---

## 5. Atomic Rollback Note (AC-4)

The EVM guarantees that every revert unwinds all state changes made within the
same call frame and all subordinate call frames. The following specific cases are
verified by the test suite:

| Scenario | Expected rollback | Verification |
|---|---|---|
| `deposit` with over-budget `transferFrom` | Zero custody change | `test_nestedFailure_depositRevertsOnTransferFailure` |
| `withdraw` with insufficient claimable | Zero balance change | `test_nestedFailure_withdrawRevertsOnInsufficientBalance` |
| `FinalRewardAllocator.finalizeRewards` with `PoolExceeded` | Finalized flag stays false; no claimable credit | `test_nestedFailure_finalizeRevertsOnPoolExceeded` |
| `InsuranceFund.executePayout` before timelock | Reserve unchanged; status stays APPROVED | `test_nestedFailure_payoutBeforeTimelockReverts` |
| `UpgradeController.executeUpgrade` when proxy reverts | Proposal status stays SCHEDULED | `test_nestedFailure_executeUpgradeReverts_rollsBack` |
| `StakeVault.settleConclusive` with no lock | Conservation invariant preserved | `test_nestedFailure_settleWithNoLockReverts` |
| `EmergencyGatekeeper.configureScope` with invalid level | Scope state unchanged | `test_nestedFailure_configureScope_outOfRange_reverts` |

In every case the conservation invariant `custody == obligations == actual_balance`
(for StakeVault) and the accounting tallies (for other contracts) are asserted after
the reverted transaction to confirm no partial write persisted.

---

## 6. Summary Findings

### Safe postures (no change required)

- All StakeVault external mutations are GUARD-class.
- FeeManager collectFee and distributeReservedFees are GUARD-class.
- InsuranceFund fund, executePayout, and allocateFromFees are GUARD-class.
- AppealVerificationRound external mutations are GUARD-class with layered vault guard.
- UpgradeController and EmergencyGatekeeper are GUARD-class.

### Accepted non-guard postures (documented rationale)

| Contract | Functions | Posture | Rationale |
|---|---|---|---|
| FinalRewardAllocator | `fund`, `finalizeRewards` | CONTROLLED | SETTLEMENT-role-only; no outbound transfer; scope-pause checked before transfer |
| FinalRewardAllocator | `claim` | CEI | State zeroed before transfer; reentrant claim fails with InsufficientClaimable |
| InsuranceFund | `submitClaim`, `rejectClaim`, `approveClaim` | CONTROLLED | Governance-only; no token transfer; no callback surface |

### No open findings

No function was identified that:
- Performs an outbound token transfer without either `nonReentrant` or CEI.
- Reads state after an outbound call without protection.
- Exposes a read-only path that could be abused to pass stale state to a write path.

---

## 7. Test Coverage Map

The Foundry test file `test/v2/ReentrancyPostureAudit.t.sol` provides the following
test-to-criterion coverage:

| Test name | Category | Contracts | AC |
|---|---|---|---|
| `test_tokenCallback_sameFunction_depositDuringDeposit_reverts` | D, B | StakeVault | AC-2, AC-4 |
| `test_tokenCallback_sameFunction_withdrawDuringWithdraw_reverts` | D, B | StakeVault | AC-2, AC-4 |
| `test_crossFunction_withdrawDuringDeposit_reverts` | A | StakeVault | AC-2 |
| `test_crossFunction_depositDuringWithdraw_reverts` | A | StakeVault | AC-2 |
| `test_readOnly_conservationDuringDeposit_noSideEffect` | C | StakeVault | AC-3 |
| `test_pause_scopeStaking_blocksDeposit` | G | StakeVault | AC-2 |
| `test_pause_noShutdown_withdrawSucceeds` | G | StakeVault | AC-4 |
| `test_nestedFailure_depositRevertsOnTransferFailure` | F | StakeVault | AC-4 |
| `test_nestedFailure_withdrawRevertsOnInsufficientBalance` | F | StakeVault | AC-4 |
| `test_recipientCallback_reentrantClaim_blockedByCEI` | E | FinalRewardAllocator | AC-2, AC-4 |
| `test_sameFunction_fundNotDoubleAccounted` | B | FinalRewardAllocator | AC-2 |
| `test_nestedFailure_finalizeRevertsOnPoolExceeded` | F | FinalRewardAllocator | AC-4 |
| `test_readOnly_claimableAndFundedAreConsistent` | C | FinalRewardAllocator | AC-3 |
| `test_pause_unpaused_fundAndFinalizeSucceed` | G | FinalRewardAllocator | AC-2 |
| `test_pause_idempotentDoubleCall_noExtraEffect` | B, G | EmergencyGatekeeper | AC-2 |
| `test_pause_initiatorCannotUnpause` | G | EmergencyGatekeeper | AC-2 |
| `test_pause_resolverUnpause_restoresScope` | G | EmergencyGatekeeper | AC-4 |
| `test_nestedFailure_configureScope_outOfRange_reverts` | F | EmergencyGatekeeper | AC-4 |
| `test_readOnly_pausedView_noSideEffect` | C | EmergencyGatekeeper | AC-3 |
| `test_crossContract_allocatorClaimDoesNotAffectVaultBalance` | A | StakeVault × FinalRewardAllocator | AC-2 |
| `test_nestedFailure_settleWithNoLockReverts` | F | StakeVault | AC-4 |
| `test_nestedFailure_executeUpgradeReverts_rollsBack` | F | UpgradeController | AC-4 |
| `test_sameFunction_doubleCancelReverts` | B | UpgradeController | AC-2 |
| `test_readOnly_getProposal_noSideEffect` | C | UpgradeController | AC-3 |
| `test_recipientCallback_reentrantExecutePayout_blockedByStateMachine` | E | InsuranceFund | AC-2, AC-4 |
| `test_sameFunction_fundNotDoubleAccounted` (InsuranceFund) | B | InsuranceFund | AC-2 |
| `test_nestedFailure_payoutBeforeTimelockReverts` | F | InsuranceFund | AC-4 |
| `test_readOnly_reserveBalance_noSideEffect` | C | InsuranceFund | AC-3 |

**Category coverage:**

| Category | Tests |
|---|---|
| A — Cross-function reentrancy | 3 |
| B — Same-function reentrancy | 5 |
| C — Read-only exposure | 5 |
| D — Token-callback reentrancy | 2 |
| E — Recipient-callback reentrancy | 2 |
| F — Nested failure rollback | 7 |
| G — Pause-gate interaction | 6 |

All seven required test categories are covered.
