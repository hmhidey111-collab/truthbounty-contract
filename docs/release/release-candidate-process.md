# Release Candidate Process

Development

↓

Code Review

↓

Security Review

↗

Unit Tests

↓

Integration Tests

↓

Invariant Testing

↓

Fuzz Testing

↗

Static Analysis

↗

Formal Verification

↗

External Audit

↗

Testnet Deployment

↗

Governance Approval

↗

Mainnet Deployment

## Upgrade Rollback State Equivalence (PREWAVE-SC-076)

As a release-readiness boundary, every upgrade candidate must prove that a rollback restores canonical storage and invariants to the pre-upgrade baseline. This proof is required before Governance Approval and is release-bound to the candidate artifact hash.

### Rollback Policy and Limits

- Rollback is supported only for implementation changes that do not alter the canonical storage layout or the event signatures consumed by pinned interfaces.
- Rollback is supported only within the timelock window and under the existing timelock/role authority; no new role or owner is granted by the rollback path.
- Rollback is rejected before execution when the candidate introduces a storage layout change, a migration with irreversible writes, or a consumer-interface break that the previous implementation cannot read.
- Emergency controls remain operation-scoped; rollback must not weaken or bypass any security gate.

### Required Evidence

The release bundle must contain deterministic artifacts for the following tests, bound to the candidate artifact hash:

1. **Snapshot and rollback** — capture canonical storage/state before the upgrade, exercise the new implementation, roll back, and compare invariants and compatibility against the snapshot.
2. **New storage writes** — verify writes made by the new implementation are either reverted or explicitly declared irreversible and rejected before execution.
3. **Events** — confirm emitted events match the pinned consumer interfaces and rollback does not emit spurious events.
4. **Roles** — confirm role assignments and authority are identical after rollback.
5. **Pause** — confirm pause state and operation-scoped emergency controls return to the snapshoted state.
6. **Custody** — confirm existing custody remains valid and unchanged across the rollback.
7. **Pending claims and disputes** — confirm pending claims and disputes remain readable and resolvable after rollback.
8. **Failed migration** — confirm a failed migration fails before execution and leaves state unchanged.

### Acceptance Criteria

- [ ] Rollback policy and limits are explicit.
- [ ] Existing state/custody remains valid.
- [ ] Unsupported rollback fails before execution.
- [ ] Evidence is release-bound.

### Constraints

- Preserve the approved V2 Optimism/EVM topology.
- Preserve exact arithmetic.
- Preserve timelock/role authority.
- Preserve operation-scoped emergency controls.
- Preserve deterministic artifacts.
- Preserve pinned consumer interfaces.
- Never weaken a security gate.

### Non-goals

- Unrelated work.
- Mainnet deployment.
- Applying `Stellar Wave` before maintainer activation.
