# Repository Import and Dependency Boundaries (V2-SC-137)

## Overview

TruthBounty V2 smart contracts are authoritative on Optimism/EVM for all protocol mutations, staking, claims, settlement, and treasury accounting. To preserve protocol invariants, prevent supply-chain compromises, and guarantee architectural integrity, strict dependency and import boundaries are enforced across the repository.

Automated boundary validation runs as part of the primary CI pipeline (`.github/workflows/ci.yml`) and locally via `npm run check:boundaries`.

---

## Architectural Rules

### 1. No API or Frontend Dependencies
Smart contracts must never depend on, import, or reference:
- Client application code, UI component trees, or web frontends.
- API route handlers, server-side services, or database wrappers.
- Path aliases reserved for web bundles (`@/`, `~/`).

**Rationale:** Contract logic must remain entirely self-contained, deterministic, and decoupled from off-chain interfaces.

### 2. No Generated Consumer Artifacts
Contracts must not import:
- Build output directories (`artifacts/`, `typechain/`, `typechain-types/`).
- Off-chain indexing schemas (`schemas/`).
- Deployment outputs or JSON manifests (`deployments/`, `*.json`, `*.abi`).

**Rationale:** Importing build artifacts into Solidity sources creates circular dependencies, cache invalidation race conditions, and artifact drift.

### 3. Approved Vendor Package Whitelist
External package imports in contracts must originate strictly from verified vendor dependencies:
- `@openzeppelin/contracts/*`
- `@openzeppelin/contracts-upgradeable/*`

Any external package import outside this whitelist is rejected.

**Rationale:** Minimizes the attack surface for third-party supply chain vulnerabilities and prevents unvetted libraries from entering core protocol execution.

### 4. Strict Multi-Chain Isolation (Optimism/EVM-Only)
TruthBounty V2 is strictly designed for EVM/Optimism networks. Contracts must not import or reference:
- `stellar`, `soroban`, `freighter`, or `@stellar/*`.
- Alternate-chain execution environments or SDKs.

**Rationale:** Prevents runtime confusion, cross-chain assumptions, and accidental inclusion of incompatible primitives.

### 5. Strict Directory Confinement
Relative imports (`./`, `../`) within contract directories must resolve within the authorized contract source trees (`contracts/`, `contracts-vrm/`).
- Traversal out of the contract root (e.g. `../../indexer`, `../../scripts`) is strictly rejected.
- All referenced internal files must exist on disk.

---

## Verification & Tooling

- **Enforcement Script:** `scripts/check-dependency-boundaries.mjs`
- **Unit & Boundary Tests:** `test/scripts/check-dependency-boundaries.test.mjs`
- **CLI Commands:**
  ```bash
  # Run boundary checks across all contract files
  npm run check:boundaries

  # Run the unit test suite for the boundary engine
  npm run test:boundaries
  ```
- **CI Integration:** Embedded as a required check in `.github/workflows/ci.yml` under the `lint` job.
