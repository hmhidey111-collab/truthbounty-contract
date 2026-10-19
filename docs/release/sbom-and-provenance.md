# Contract Release SBOM and Provenance Attestation (V2-SC-088)

## Purpose

Every TruthBounty V2 release candidate must publish a machine-readable Software
Bill of Materials (SBOM) bound to a provenance attestation. The attestation
records:

| Field | Source |
| --- | --- |
| Dependencies | `package.json` (+ optional `foundry.lock` git submodule revs) |
| Compiler | `hardhat.config.ts` Solidity version / EVM / `viaIR` |
| Optimizer | `optimizer.enabled` and `optimizer.runs` |
| Source commit | `RELEASE_SOURCE_COMMIT` or `GITHUB_SHA` (40-char hex) |
| Artifact hashes | SHA-256 of canonical contract sources and lock/config files |
| Workflow identity | GitHub Actions repository / workflow / run id / ref |

Optimism/EVM remains authoritative. Stellar, Soroban, and Freighter runtime
dependencies are rejected (fail closed).

## Generate

```bash
export RELEASE_SOURCE_COMMIT="$(git rev-parse HEAD)"
export RELEASE_VERSION="2.0.0-rc.1"
# Optional CI identity (all-or-nothing):
# export GITHUB_REPOSITORY=DigiNodes/truthbounty-contract
# export GITHUB_WORKFLOW="Release Candidate"
# export GITHUB_RUN_ID=12345
# export GITHUB_SHA="$RELEASE_SOURCE_COMMIT"

npx hardhat run scripts/generateContractReleaseSbom.ts
# or:
npx ts-node scripts/generateContractReleaseSbom.ts
```

Output lands at
`deployments/sbom/contract-release-sbom-<version>.json`.

Schema:
[`../../schemas/contract-release-sbom.schema.json`](../../schemas/contract-release-sbom.schema.json).

## Fail-closed rules

- Invalid or missing 40-character source commit SHA
- Missing Solidity compiler version
- Optimizer enabled with non-positive `runs`
- Incomplete CI workflow identity (any CI var without the full set)
- `GITHUB_SHA` mismatch vs attested `sourceCommit`
- Forbidden Stellar / Soroban / Freighter packages
- Path-traversal artifact paths
- Invalid `foundry.lock` revision entries
- Placeholder `0.0.0` release versions

## Verification

```bash
npx hardhat test test/ContractReleaseSbom.test.ts
```

## Non-goals

- Mainnet deployment
- Backend-authoritative protocol mutation
- Restoring legacy V1 as canonical
