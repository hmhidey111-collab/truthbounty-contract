# Mythril and Equivalent Symbolic Security Checks for Critical Paths

## Objective

This document defines the bounded symbolic-analysis gate for the TruthBounty V2 protocol-critical flows. The goal is to validate the highest-risk authorization, custody, settlement, reward, upgrade, and emergency paths without introducing unrelated scope.

## Scope

The analysis covers the protocol surfaces most likely to affect treasury integrity, protocol mutation, or user settlement outcomes:

- Authorization and role gating
- Custody and vault accounting
- Settlement and claim finalization
- Reward allocation and withdrawals
- Upgrade and migration boundaries
- Emergency controls and pause paths

## Canonical critical-path targets

The reproducible check uses the following contracts as the authoritative minimum set:

- `contracts/DisputeResolution.sol`
- `contracts/StakeVault.sol`
- `contracts/TruthBountyWeighted.sol`
- `contracts/treasury/TreasuryManagement.sol`
- `contracts/settlement/ProvisionalSettlementEngine.sol`
- `contracts/tokenomics/TokenomicsEngine.sol`
- `contracts/verification/VerificationAggregator.sol`
- `contracts/governance/v2/GovernanceRoleTopology.sol`

## Required execution bounds

The symbolic analysis is intentionally bounded to keep execution deterministic and reviewable:

- Maximum execution time: 60 seconds per contract
- Maximum symbolic depth: 20
- Loop bound: 3
- Solver timeout: 60000ms

These limits are captured in `.mythril.ini` and enforced by `scripts/symbolic-check.sh`.

## Failure modes explicitly checked

The analysis is designed to surface the following negative cases:

- Missing or permissive authorization
- Zero-address or unsafe dependency handling
- Replay or double-claim settlement paths
- Treasury or reward accounting drift
- Unsafe token transfer assumptions
- Fail-open emergency or upgrade paths
- Non-deterministic rounding or settlement semantics

## Execution command

From the repository root:

```bash
./scripts/symbolic-check.sh --tool auto
```

For a dry-run without executing the analyzer:

```bash
./scripts/symbolic-check.sh --dry-run
```

The script compiles the protocol with Foundry before running the selected analyzer and exits non-zero if the required bound checks are not satisfied.

## Fallback and equivalent tooling

If Mythril is unavailable in a target environment, the project falls back to Slither while preserving the same critical-path scope and bounded execution policy. The fallback is configured via `slither.config.json`.

## Release gate

A protocol release should not proceed unless the symbolic/static analysis output is reviewed and no critical findings remain unresolved. This check is intentionally narrow and reviewable: it covers the protocol's critical mutation and settlement flows without absorbing unrelated implementation work.
