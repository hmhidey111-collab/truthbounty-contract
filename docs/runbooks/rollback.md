# Upgrade Rollback Runbook

Canonical operational runbook for proving upgrade rollback state equivalence for the V2 Optimism/EVM topology. This document is release-bound: every execution must reference an immutable release artifact digest and the approved timelock/role authority for that release.

---

## 1. Preconditions

Before any upgrade or rollback exercise, confirm all of the following. Any failed precondition is a hard stop.

1. **Release binding**: the candidate implementation and the rollback target are identified by immutable artifact digests (bytecode hash, source commit, build metadata). Record them in the evidence bundle.
2. **Topology**: the approved V2 Optimism/EVM topology is unchanged (network, chain ID, proxy addresses, admin/proxy admin addresses, contract relationships).
3. **Authority**: the timelock and role authority for the upgrade and rollback paths is the approved authority. No EOA/multisig/single-key bypass is permitted.
4. **Rollback policy**: the rollback policy and its limits are explicitly declared and match the release manifest (see Section 2).
5. **Snapshot**: a canonical storage/state snapshot of the current implementation is taken and hashed before any mutation.
6. **Emergency controls**: operation-scoped emergency controls (pause/freeze) are identified and their scope is confirmed to the operation only; they must not be weakened.
7. **Consumer interfaces**: pinned consumer interfaces (ABI/selectors/event signatures) have been recorded and are expected to be preserved across the upgrade/rollback cycle.
8. **Determinism**: all artifacts are deterministic; no non-deterministic codegen or deployment step is in the path.

---

## 2. Rollback Policy and Limits

### 2.1 Supported rollback

- Rollback is supported only when the prior implementation artifact digest is available and pinned in the release manifest.
- Rollback is supported only when the storage layout of the new implementation is backward-compatible with the prior implementation for all written slots.
- Rollbback is supported only when no irreversible migration has been executed (no destructive slot rewrite, no deletion of canonical state, no one-way flag set).

### 2.2 Unsupported rollback

#### 2.2.1 Unsupported conditions

Rollback is unsupported and MUST fail before execution when any of the following holds:

- The prior implementation artifact digest is missing or does not match the release manifest.
- The new implementation introduced a storage layout that is not backward-compatible with the prior implementation.
- A one-way migration has already been executed and its effects cannot be reversed without data loss.
- The timelock/role authority for the rollback path is not the approved authority for this release.
- The canonical state snapshot is missing, incomplete, or its hash does not match the pre-mutation state.
- The operation-scoped emergency controls are in a state that would require weakening a security gate to proceed.

#### 2.2.2 Fail-before-execution requirement

The rollback guard MUST evaluate all conditions in Section 2.2.1 and revert before any state mutation or proxy admin call is submitted. A rollback that cannot prove its preconditions is a failed operation, not a partial operation.

### 2.3 Limits

- Rollback is limited to a single step from the current implementation to the immediately prior implementation pinned in the release manifest. Multi-step rollback chains are out of scope.
- Rollback does not reverse off-chain effects (indexer cursors, external consumer state); the runbook documents the required reconciliation for consumers.
- Rollback does not weaken any security gate. If a gate would need to be weakened, the rollback is unsupported and must fail before execution.

---

## 3. Upgrade Rollback Procedure

### 3.1 Snapshot canonical state before upgrade

1. Identify the canonical storage slots and structures for the contract set in scope (admin, roles, pause flags, custody accounting, pending claims, disputes, and any other canonical state).
2. Read and record each slot value and its key derivation inputs.
3. Compute a canonical state hash over the ordered set of (key, value) pairs using the release-pinned hash function and encoding.
4. Store the snapshot and its hash in the evidence bundle with the release artifact digest.
5. Confirm the snapshot is complete (covers all canonical slots) and the hash is reproducible.

### 3.2 Exercise the new implementation

1. Apply the new implementation through the approved timelock/role authority only.
2. Execute the new storage writes that the upgrade requires, including any new slots and initialization.
3. Emit and capture the events produced by the upgrade and the new storage writes.
4. Verify roles, pause state, custody, pending claims, and disputes are well-defined and consistent with the new implementation.
5. Record the post-upgrade state snapshot and its hash.

### 3.3 Rollback where supported

1. Evaluate the rollback guard conditions in Section 2.2.1. If any condition holds, the rollback MUST fail before execution.
2. If supported, execute the rollback through the approved timelock/role authority only, restoring the prior implementation artifact digest pinned in the release manifest.
3. Capture the rollback events and the restored implementation address/digest.
4. Take a post-rollback state snapshot and its hash.
5. Compare the post-rollback state hash to the pre-upgrade state hash for the canonical state that must be preserved.

### 3.4 State equivalence invariants

The following invariants MUST hold after a rollback:

- Canonical storage for preserved slots is byte-for-byte equivalent to the pre-upgrade snapshot.
- Role assignments and timelock authority are identical to the pre-upgrade state.
- Pause flags and operation-scoped emergency controls are identical to the pre-upgrade state.
- Custody accounting (balances, ownership, allocations) is identical to the pre-upgrade state.
- Pending claims and disputes are identical to the pre-upgrade state.
- Pinned consumer interfaces (ABI/selectors/event signatures) are preserved across the cycle.
- Arithmetic is exact and unchanged by the upgrade/rollback cycle.

---

## 4. Ownership Verification

1. Verify the proxy admin address is the approved address for this release.
2. Verify the timelock address and its delay/execution parameters match the release manifest.
3. Verify all role assignments (admin, guardian, operator, pauser, and any other role in scope) match the pre-upgrade state after rollback.
4. Verify the operation-scoped emergency controls are unchanged and remain scoped to the operation.
5. Record the ownership verification evidence in the bundle.

---

## 5. Storage Verification

1. Read every canonical slot after rollback and record its value.
2. Recompute the canonical state hash using the same hash function and encoding as the pre-upgrade snapshot.
3. Compare the recomputed hash to the pre-upgrade state hash. A mismatch is a failed rollback.
4. Verify the following explicitly and record each as evidence:
   - New storage writes from the upgrade are either reverted or proven non-canonical and non-destructive.
   - Events emitted by the upgrade and rollback are captured and match the expected signatures.
   - Roles and timelock authority are identical to the pre-upgrade state.
   - Pause flags and operation-scoped emergency controls are identical to the pre-upgrade state.
   - Custody accounting is identical to the pre-upgrade state.
   - Pending claims and disputes are identical to the pre-upgrade state.
5. Record the storage verification evidence in the bundle.

---

## 6. Resume Protocol

Resume is allowed only when the rollback is proven complete and the state equivalence invariants in Section 3.4 hold.

1. Confirm the post-rollback state hash equals the pre-upgrade state hash for all preserved canonical slots.
2. Confirm the rollback was executed through the approved timelock/role authority and that no security gate was weakened.
3. Confirm the pinned consumer interfaces are preserved and the exact arithmetic is unchanged.
4. Confirm the evidence bundle is complete and release-bound (release artifact digest, snapshot hashes, transaction hashes, event logs, ownership and storage verification records).
5. Resume normal operations only after all checks in this section pass.
6. If any check fails, keep the operation paused within the operation-scoped emergency controls and escalate to the approved authority. Do not weaken any security gate to resume.

---

## 7. Required Test Evidence

The following tests MUST be executed and their results recorded in the release-bound evidence bundle:

- Upgrade/rollback cycle test.
- New storage writes test.
- Events test.
- Roles test.
- Pause test.
- Custody test.
- Pending claims/disputes test.
- Failed migration test (unsupported rollback fails before execution).

---

## 8 Acceptance Criteria Mapping

- Rollback policy and limits are explicit: Section 2.
- Existing state/custody remains valid: Sections 3.4, 5, and 6.
- Unsupported rollback fails before execution: Section 2.2.2.
- Evidence is release-bound: Sections 1, 5, 6, and 7.
