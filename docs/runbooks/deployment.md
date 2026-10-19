# Deployment Runbook

## Purpose

This runbook defines the standard deployment procedure for TruthBounty V2.

## Prerequisites

- All CI checks passing
- Unit tests passing
- Invariant tests passing
- Fuzz tests passing
- Security review completed

## Pre-Broadcast Configuration Validation (SC-068)

Every deployment configuration MUST be validated **before any deployment transaction is
broadcast**. Malformed, unanswered, placeholder, duplicate, or legacy configuration is rejected
and aborts the deployment locally — no on-chain transaction is ever submitted for an invalid
configuration.

Validation is fail-closed and rejects:

- **Zero addresses** in identity-critical fields (`admin`, `guardian`).
- **Duplicate addresses** across configured roles and modules.
- **Placeholder/burn addresses** (`address(1)`..`address(9)`, `0xdEaD`, `0xdeadbeef…`,
  `0x1111…`/`0x2222…`/`0x3333…`/`0x4444…`/`0x5555…`, `0xeee…` / `type(uint160).max`).
- **Wrong chain id** — the configured chain must equal the executing chain.
- **EOA pre-wired modules** — any pre-wired module address must carry deployed code.
- **Wrong interface** — pre-wired modules must answer their canonical selector probe
  (`version()`, `totalSupply()`, `getMinDelay()`, `proposalThreshold()`, `moduleCount()`,
  `governor()`, `isActive()`).
- **Legacy addresses** — configured modules must not appear in the legacy V1 denylist.
- **Out-of-range parameters** — e.g. `quorumNumerator` outside `(0, 100)`,
  `appealMultiplierBps` above `100_000`, `rewardPercent + slashPercent` above `100`,
  `votingDelay` at or above `votingPeriod`, timings above `365 days`.

Canonical source of truth: `contracts/deployment/DeploymentConfigValidator.sol`
(Forge deploy scripts) and `scripts/validateDeploymentConfig.ts` (TypeScript deploy paths).

## Deployment Steps

1. Verify deployment configuration — run the canonical validator before broadcasting:
   - Forge V2 governance deploy (`script/deploy/DeployGovernanceV2.s.sol`):
     `forge script script/deploy/DeployGovernanceV2.s.sol` — the script calls
     `DeploymentConfigValidator.validate(...)` before `vm.startBroadcast`. Set `ADMIN_ADDRESS`,
     `GUARDIAN_ADDRESS`, and optionally `DEPLOYER_ADDRESS` (must match the broadcast key).
   - Canonical V2 economy suite (`scripts/deployCanonicalV2.ts`): parameters are compared against
     the canonical bounds up front; anything out of range aborts before the first deploy.
2. Deploy implementation contracts.
3. Deploy proxy contracts.
4. Configure governance ownership.
5. Configure treasury ownership.
6. Verify deployed contracts.
7. Validate roles and permissions.
8. Record deployment artifacts.

## Post Deployment

- Verify ownership
- Verify events
- Verify monitoring
- Archive deployment logs