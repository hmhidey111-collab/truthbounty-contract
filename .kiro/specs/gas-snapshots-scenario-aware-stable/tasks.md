# SC-064 Implementation Tasks

- [ ] 1. Verify the gas measurement and pinned toolchain boundary
  - Confirm the CI-pinned Foundry `v1.8.3` executable and supported call-level snapshot API; add a minimal proof scenario before expanding the suite.
  - Compare Foundry's effective compiler/EVM/optimizer settings with `hardhat.config.ts` and the V2 release manifest; make only verified-equivalent settings explicit.
  - Record the exact measured boundary and toolchain identity, and fail the proof check for missing or mismatched pins.
  - _Requirements: 1.1, 2.1, 2.3, 2.4_

- [ ] 2. Add scenario catalog validation and self-tests
  - Extend `config/gas-budgets.json` additively while preserving every existing operation budget and protocol bound.
  - Implement structural validation for scenario IDs, target functions, snapshot keys, reviewed limits, required families, and the recommended ceiling.
  - Match the focused snapshot one-to-one with the catalog and report missing, duplicate, unexpected, malformed, and over-budget entries with scenario/function details.
  - Add Node tests for valid configuration, completeness, compiler/toolchain drift, noisy measurements, deliberate regression, and malformed or missing artifacts.
  - _Requirements: 1.1, 1.6, 2.3, 2.4, 3.1, 3.2, 3.3, 3.5, 4.2, 4.3, 4.4, 4.5_

- [ ] 3. Implement representative Foundry scenario measurements
  - Add isolated scenarios for cold/warm and first/repeat states where applicable, using the verified measurement boundary from Task 1.
  - Cover approved maximum input and batch bounds, expected failure/revert paths, upgrade operations, and successful batch operations.
  - Assert functional outcomes and expected revert behavior in addition to gas limits; do not modify production contract behavior.
  - Map each scenario to an existing reviewed operation budget where valid; otherwise derive a proposed limit from pinned measurements and include it for explicit review without silently raising unrelated budgets.
  - _Requirements: 1.2, 1.3, 1.4, 1.5, 3.4, 4.6, 5.1, 5.3, 5.4_

- [ ] 4. Add deterministic focused snapshot commands and artifact
  - Add package commands to regenerate and check the SC-064 snapshot without changing the existing `test:gas` command semantics.
  - Generate the focused `.gas-snapshot.sc064` artifact under the pinned Foundry toolchain and verify unchanged regeneration is byte-for-byte stable.
  - Preserve the repository-wide `.gas-snapshot` check and ensure a compiler/toolchain change requires explicit baseline review.
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 3.2, 4.1_

- [ ] 5. Enforce the shared gas gate in CI and document baseline review
  - Make the main CI gas job and standalone gas workflow invoke the same fail-closed check command with pinned Node and Foundry versions.
  - Remove advisory gas-test behavior, missing-baseline skips, and diff-only success paths while retaining report uploads strictly as diagnostics.
  - Document scenario identity, local check/regeneration commands, toolchain pins, and the explicit review process for snapshot and budget changes.
  - _Requirements: 3.2, 3.4, 3.5, 4.6, 5.2, 5.4_

- [ ] 6. Run focused and required regression gates
  - Run validator unit tests, scenario completeness tests, focused Foundry gas tests, and deterministic regeneration checks.
  - Run existing full Foundry snapshot, release-reproducibility, contract, security, fuzz/invariant, and repository lint gates that are available in the environment.
  - Confirm no Solidity ABI, storage layout, consumer handoff, protocol topology, arithmetic, governance/timelock, pause, or unrelated budget changes occurred.
  - _Requirements: 1.6, 2.2, 3.1, 3.2, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 5.1, 5.2, 5.3, 5.4_
