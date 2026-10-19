# SC-064: Scenario-Aware, Stable Gas Snapshots

## Document Information

- **Feature Name:** PREWAVE-SC-064 — Make Gas Snapshots Scenario-Aware and Stable
- **Version:** 1.0 (draft)
- **Date:** 2026-10-16
- **Author:** Repository maintainers
- **Stakeholders:** Contract maintainers, security reviewers, CI/release owners, consumer teams
- **Dependencies:** #684, #667
- **Status:** Candidate; activation remains maintainer-controlled

## Introduction

The current gas controls include Foundry snapshots, named budget configuration, gas tests, and a CI workflow, but the workflow can treat test failures as non-blocking and reports snapshot differences without enforcing reviewed scenario budgets. A whole-suite or function-only aggregate is insufficient to explain whether a regression affects a cold or warm access, a first or repeated call, a maximum-size input, a revert path, an upgrade, or a batch operation.

This feature defines a deterministic, scenario-aware gas baseline and gate. It makes material gas changes reproducible and attributable to a scenario and function while preserving existing contract semantics and security controls.

## Feature Summary

Generate deterministic gas snapshots for a complete, named set of representative protocol scenarios and enforce reviewed per-scenario budgets in CI.

## Business Value

Maintainers can distinguish real cost regressions from toolchain or measurement noise, review budget changes alongside functional changes, and identify the exact affected scenario and function before release.

## Scope

Included: a scenario catalog; pinned-toolchain baseline generation and regeneration; comparison against reviewed budgets; actionable regression reports; CI failure behavior; and tests for regeneration, compiler changes, noisy baselines, deliberate regressions, and scenario completeness.

Excluded: unrelated contract changes, mainnet deployment, and activating Stellar Wave before maintainer authorization.

---

## Requirements

### Requirement 1: Representative Scenario Catalog

**User Story:** As a contract maintainer, I want gas measurements organized by representative execution scenarios, so that each measured cost reflects a meaningful state and workload.

**Acceptance Criteria (EARS)**
- WHEN a gas snapshot is generated, THEN the Gas Snapshot Gate SHALL associate every measurement with a stable scenario identifier and the target function.
- WHERE a function is included in the gas catalog, the catalog SHALL distinguish cold and warm access cases and first and repeated invocation cases when those states apply to that function.
- WHERE a protocol operation has a configured maximum input or batch bound, the catalog SHALL include a maximum-size scenario using that bound.
- WHERE a relevant operation can fail, the catalog SHALL include representative failure/revert scenarios alongside successful scenarios.
- WHERE an upgradeable operation or batch operation is in scope, the catalog SHALL include representative upgrade and batch scenarios.
- WHEN scenario completeness is validated, THEN the validation SHALL fail if any required scenario family is absent or a catalog entry lacks its function identity and required setup metadata.

**Additional Details**
- **Priority:** High
- **Complexity:** High
- **Dependencies:** #684, #667
- **Assumptions:** Scenario setup and maximum sizes are derived from approved protocol bounds and the existing V2 configuration; this requirement does not authorize changing those bounds.

### Requirement 2: Pinned and Reproducible Baselines

**User Story:** As a release owner, I want gas baselines generated from a pinned toolchain, so that snapshot changes represent reviewed code or configuration changes rather than ambient compiler drift.

**Acceptance Criteria (EARS)**
- WHEN a baseline is generated, THEN the Gas Snapshot Gate SHALL use and record the pinned compiler and all gas-relevant build settings required to reproduce the measurement.
- WHEN snapshots are regenerated from unchanged source, scenario definitions, and pinned toolchain, THEN the generated artifacts SHALL be byte-for-byte stable.
- WHEN a compiler or other gas-relevant toolchain setting changes, THEN the gate SHALL identify the toolchain change and require explicit baseline review rather than silently accepting or overwriting the existing baseline.
- IF a required pinned toolchain component is unavailable or differs from the recorded baseline metadata, THEN baseline generation or comparison SHALL fail with a diagnostic identifying the mismatch.

**Additional Details**
- **Priority:** High
- **Complexity:** High
- **Dependencies:** Requirement 1
- **Assumptions:** The applicable compiler/build settings may differ between Foundry and Hardhat workflows and must be identified for each measured scenario.

### Requirement 3: Reviewed Scenario Budgets and Regression Reporting

**User Story:** As a contract maintainer, I want each scenario compared with a reviewed budget, so that gas regressions are actionable and cannot pass as informational output.

**Acceptance Criteria (EARS)**
- WHEN a scenario measurement exceeds its reviewed budget, THEN the gate SHALL fail and report the scenario identifier, function, measured gas, allowed budget, and regression amount.
- WHEN a snapshot or budget comparison detects a regression, THEN the gate SHALL return a non-zero result suitable for CI enforcement.
- IF a scenario measurement is noisy or inconsistent across the required repeatability check, THEN the gate SHALL report the instability and SHALL NOT automatically replace the reviewed baseline or raise its budget.
- WHEN a functional change alters a scenario's gas usage, THEN the corresponding snapshot and any required budget change SHALL be included in the change for explicit maintainer review.
- IF a required scenario budget is missing, malformed, or unreviewed, THEN the gate SHALL fail closed rather than skip that scenario.

**Additional Details**
- **Priority:** High
- **Complexity:** High
- **Dependencies:** Requirements 1 and 2
- **Assumptions:** The design phase will define the budget schema, review evidence, and any repeatability/noise policy without weakening existing gates or inventing unreviewed budget values.

### Requirement 4: Required Gate-Test Coverage

**User Story:** As a CI owner, I want tests to exercise snapshot and budget failure modes, so that the gas gate itself cannot silently stop detecting regressions.

**Acceptance Criteria (EARS)**
- WHEN the snapshot regeneration test runs with unchanged inputs and pinned settings, THEN it SHALL verify deterministic output.
- WHEN the compiler-change test changes the effective compiler identity, THEN it SHALL verify that the baseline is invalidated or requires explicit review and is not silently accepted.
- WHEN the noisy-baseline test supplies inconsistent measurements, THEN it SHALL verify that the gate reports instability and does not auto-update the reviewed baseline.
- WHEN the deliberate-regression test exceeds a scenario budget, THEN it SHALL verify that the gate fails and identifies the scenario and function.
- WHEN the scenario-completeness test runs, THEN it SHALL verify that each required scenario family is represented and that removing a required scenario causes failure.
- WHEN any required gas test, snapshot comparison, or budget validation fails in CI, THEN the gas workflow SHALL fail rather than continue successfully or skip a missing baseline.

**Additional Details**
- **Priority:** High
- **Complexity:** High
- **Dependencies:** Requirements 1, 2, and 3
- **Assumptions:** Tests may use controlled fixtures or synthetic measurements to exercise gate behavior; they SHALL NOT alter production contract behavior.

### Requirement 5: Protocol and Security Boundary Preservation

**User Story:** As a security reviewer, I want gas-gate changes to preserve protocol and release controls, so that performance measurement does not weaken approved V2 guarantees.

**Acceptance Criteria (EARS)**
- WHEN the gas snapshot workflow or its tests are changed, THEN the change SHALL preserve the approved V2 Optimism/EVM topology, exact arithmetic, governance and timelock authority, scoped pause model, and consumer interface handoffs.
- IF an existing security, correctness, or release gate fails, THEN the gas-snapshot change SHALL NOT disable, downgrade, bypass, or conceal that failure.
- WHERE Stellar Wave activation has not been explicitly authorized by maintainers, the implementation SHALL NOT activate Stellar-specific deployment or alter the approved topology.
- WHEN a reviewed gas budget is updated, THEN the update SHALL be limited to the affected scenario and SHALL retain all unrelated budgets and security thresholds.

**Additional Details**
- **Priority:** High
- **Complexity:** High
- **Dependencies:** Requirements 1 through 4
- **Assumptions:** Any required protocol behavior change is outside this feature and requires separate authorization and review.

---

## Non-Functional Requirements

**Performance and Determinism**
- WHEN generation is repeated under identical source, scenario definitions, and pinned toolchain, THEN output SHALL be byte-for-byte stable.
- WHEN a measurement is compared with its approved scenario budget, THEN the comparison SHALL use a documented, deterministic policy and SHALL not silently absorb measurement noise.

**Security and Governance**
- WHEN a budget or baseline is changed, THEN the change SHALL remain auditable and subject to explicit maintainer review.
- IF a gas gate cannot validate its inputs, THEN it SHALL fail closed without changing contract authorization, arithmetic, pause, or interface behavior.

**Reliability**
- WHEN required snapshots, scenario metadata, or budgets are missing or invalid, THEN CI SHALL fail with a diagnostic identifying the invalid or missing item.

## Constraints and Assumptions

**Technical Constraints**
- Preserve the repository's approved V2 Optimism/EVM topology and consumer interfaces.
- Preserve exact arithmetic, governance/timelock authority, and the scoped pause model.
- Baselines must be generated from pinned, explicitly identified toolchain settings.
- Existing gas budgets and protocol maximums are not to be changed without review.

**Business Constraints**
- This is a focused contract-readiness boundary; unrelated work and mainnet deployment are excluded.
- Stellar Wave must not be applied before maintainer activation.
- Complexity is High; estimate is 200 points.

**Assumptions**
- Dependencies #684 and #667 provide prerequisite context and remain authoritative.
- Existing snapshots and budget files are inputs to review, not presumed-correct per-scenario baselines.
- Maintainers decide activation and review budget changes.

## Success Criteria

**Definition of Done**
- Every required scenario family is represented and linked to a function.
- Repeated snapshot generation under an unchanged pinned toolchain produces identical artifacts.
- Compiler changes, noisy baselines, and missing/incomplete scenario metadata are detected and reported.
- A deliberate over-budget regression fails CI and identifies its scenario and function.
- Functional gas changes require an explicit reviewed snapshot/budget update.
- Failure paths are included, and no existing security gate is weakened.

**Acceptance Metrics**
- Snapshot regeneration determinism: exact artifact match under unchanged inputs.
- Scenario completeness: all required scenario families pass the completeness test.
- Regression detection: a deliberately over-budget scenario returns non-zero and names its scenario and function.
- CI enforcement: missing or invalid inputs and failing gas tests produce a failed workflow.

## Glossary

| Term | Definition |
|---|---|
| Scenario | A named gas measurement case specifying a function, relevant state/setup, and workload. |
| Reviewed budget | A maintainer-approved maximum gas value associated with a specific scenario. |
| Cold/warm access | First versus subsequent access cost within the applicable EVM transaction context. |
| First/repeat invocation | Initial execution versus a later execution with relevant state already established. |
| Noisy baseline | A measurement set whose repeated results are inconsistent under the defined pinned environment. |
| Snapshot | A deterministic artifact recording measured gas values and required toolchain/scenario identity. |
