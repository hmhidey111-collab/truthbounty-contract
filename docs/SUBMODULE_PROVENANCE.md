# Submodule Provenance and Verification

This document pins the git submodule dependency graph for the V2 Optimism/EVM topology and describes how to verify provenance before build.

## Pinned dependency graph

The recursive dependency graph is immutable: every submodule is pinned to an exact commit SHA in the parent repository tree. The canonical manifest is maintained in `deployments/submodules/submodule-manifest.json` and enforced by `scripts/verifySubmoduleProvenance.ts`.

| Submodule path                           | Upstream URL                                                                 | License         |
|-------------------------------------------|-----------------------------------------------------------------------------------|-----------------|
| `lib/forge-std`                           | `https://github.com/foundry-rs/forge-std`                                                | MIT / Apache-2.0 |
| `lib/openzeppelin-contracts`                 | `https://github.com/OpenZeppelin/openzeppelin-contracts`                                       | MIT             |
| `lib/openzeppelin-contracts-upgradeable`   | `https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable`                            | MIT             |

Nested submodules (for example `forge-std/lib/dsqth`, `forge-std/lib/ds-test`) are recorded in the manifest with their parent path prefix and must be present and at the pinned SHA.

## What the verifier enforces

`scripts/verifySubmoduleProvenance.ts` fails closed on any of the following:

- **SHA/URL mutation** — the checked-out commit SHA or the configured remote URL differs from the manifest.
- Placeholder URLs (for example `*.example.com`) are rejected outright.
- A transitive submodule remote that is not the canonical upstream for that path is rejected.
- **Missing nested module** — a submodule recorded in the manifest is not initialized.
- Durty tree** — `git status --porcelain` inside a submodule reports modified or untracked files.
- **Unreachable commit** — the pinned commit cannot be resolved in the local clone.
- A substituted content fingerprint — the commit tree or the content hash of the submodule directory differs from the manifest.
- **License mismatch** — the detected license identifier for a submodule differs from the manifest entry.

## Release attestation

Every release attestation in `deployments/releases/*-release-manifest.json` must include a submodule section recording the exact commit SHA and URL for every submodule in the recursive graph. The attestation is produced by the same script that enforces the manifest, so the recorded SHAs are the ones that were actually verified at build time.

## Upgrade procedure

To upgrade a submodule dependency:

1. Open a pr against the parent repository that only bumps the submodule pointer and the corresponding `entries` in `deployments/submodules/submodule-manifest.json`.
2. Update the commit SHA, URL, license identifier, and content fingerprint for the affected submodule and any nested submodules that change.
3. Run `npm run verify:submodules` (or `npm run build`, which invokes the verifier as a prebuild step) and commit the regenerated attestation alongside the manifest change.
4. Request review from the governance/timelock authority representative. The change is accepted only if the verifier passes on a clean checkout and the attestation is present.
5. Never force-push or rewrite the submodule pointer outside of a reviewed pr. Never weaken the verifier to accommodate a failing dependency.

## Running the verifier

```bash
npm run verify:submodules
npm run verify:submodules -- --manifest deployments/submodules/submodule-manifest.json
```

The verifier exits with a nonzero status and a typed error message on any failure. It is wired into the build pipeline as a prebuild step so a dirty or substituted dependency graph cannot reach a release build.
