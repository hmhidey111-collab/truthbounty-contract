# Bounded Loops and Storage Growth (V2-SC-084)

## Scope

Canonical V2 user-controlled arrays and per-claim evidence storage are bounded so governance publication and terminal lifecycle reads remain executable at configured limits.

## Controls

- `ProtocolExecutionBounds.MAX_SUPPORTED_ASSETS` caps the `supportedAssets` array validated and copied when publishing a parameter version.
- `EvidenceRegistry.MAX_EVIDENCE_PER_CLAIM` caps evidence commitments per claim.
- `EvidenceRegistry.claimEvidence` remains paginated with a fixed maximum page size.
- Over-limit inputs revert with typed errors before the unbounded write or loop can occur.

## Evidence

- `test/EvidenceRegistry.test.ts` proves exactly the evidence limit succeeds and the next commitment reverts.
- `test/v2/V2LifecycleBounds.t.sol` proves the maximum supported-asset list succeeds and the next length reverts.
- Existing `test/GasBoundedExecution.t.sol` continues to cover the canonical pull settlement and batch execution limits from V2-SC-038.

The complete project CI suite is required before merge, including Hardhat tests, Foundry unit/fuzz/invariant/gas checks, static analysis, and artifact validation.
