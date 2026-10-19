# Canonical Modular Deployment Composition (`SC-031`)

## 1. Overview

The **Canonical Modular Deployment Composition** provides the definitive dependency graph and automated deployment module for the TruthBounty V2 protocol. It replaces legacy ad-hoc deployments (`FullDeploy.ts` with legacy `TruthBountyClaims`) with a strictly ordered, role-configured, and parameterized architecture.

```
┌──────────────────────────────────────────────────────────────────┐
│             Canonical V2 Deployment Topology                     │
│                                                                  │
│  [1. GovernanceController] ◄─── Timelock & Policy Controller     │
│            ▲                                                     │
│            │                                                     │
│  [2. RewardToken]          [3. MockReputationOracle]             │
│            │                          │                          │
│            ▼                          ▼                          │
│  [4. ClaimRegistry]        [5. TruthBountyWeighted]              │
│            │                          │                          │
│            │                          ▼                          │
│            │               [6. VerificationAggregator]           │
│            │                          │                          │
│            ▼                          ▼                          │
│  [7. ProvisionalSettlementEngine] ◄───┘                          │
│            │                                                     │
│            ▼                          [8. StakeVault] ◄─────────┐
│  [9. AppealVerificationRound] (Dispute Escalation) ─────────────┘
│            │  (vault = StakeVault, OPERATOR_ROLE granted)        │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. Dependency Order

1. **Governance & Ownership**:
   - `GovernanceController`: Central coordinator for DAO proposals and parameter changes.
2. **Economic & Reputation Foundation**:
   - `RewardToken`: Canonical ERC20 protocol token.
   - `MockReputationOracle`: Verifier weight multiplier source.
3. **Core Registries & Verification**:
   - `ClaimRegistry`: Immutable single source of truth for claim metadata and status.
   - `TruthBountyWeighted`: Staking vault and reputation-weighted vote collector.
4. **Consensus & Settlement Layer**:
   - `VerificationAggregator`: Deterministic consensus engine consuming verification sources.
   - `ProvisionalSettlementEngine`: Automated post-deadline round 1 settlement and dispute window activator.
   - `StakeVault`: Minimal `ISTakeVault` bond-custody vault and lock ledger (V2-SC-009 stand-in) holding appeal/challenge bonds.
   - `AppealVerificationRound`: Isolated second-round appeal manager with heightened economic security; bond-gated, bounded `maxAppealRounds` ladder (V2-SC-059).

---

## 3. Role Wiring & Access Control

- **`REGISTRY_UPDATER_ROLE`**:
  - Granted on `ClaimRegistry` exclusively to authorized settlement contracts (`ProvisionalSettlementEngine`).
  - Deployer authority is revoked during finalization to guarantee decentralization.
- **`GOVERNANCE_ROLE`**:
  - Bound to `GovernanceController` across all governance-controlled modules.
- **Vault `OPERATOR_ROLE`**:
  - Granted on `StakeVault` to `AppealVerificationRound` (`AppealVerificationRoundRoleGranted`) so the appeal module can `lockBond` appeal bonds; the vault is passed into the appeal constructor as `_vault` and exposed as `appealVerificationRound.vault()`.
- **Legacy Exclusion**:
  - Deprecated legacy contracts (such as `TruthBountyClaims` and unweighted settlement targets) are completely excluded from the canonical composition.

---

## 4. Usage

### Hardhat Ignition

```bash
npx hardhat ignition deploy ignition/modules/CanonicalV2.ts --network <network>
```

### TypeScript Composition Helper

```typescript
import { deployCanonicalV2 } from "./scripts/deployCanonicalV2";

const suite = await deployCanonicalV2(deployer);
```

## 5. Deterministic Deployment Manifest (`V2-SC-125`)

The canonical manifest is generated from versioned inputs and compiled artifacts:

```bash
DEPLOYER_ADDRESS=0x... \
DEPLOYMENT_STARTING_NONCE=0 \
RELEASE_VERSION=2.0.0 \
npm run manifest:canonical-v2
```

The generator writes `deployments/<DEPLOY_ENV>/canonical-v2-manifest.json` and
prints its Keccak-256 digest. The manifest records:

- compiler version, EVM target, optimizer, and IR settings;
- canonical contract order, constructor references, explicit library addresses,
   bytecode hashes, and deployed-bytecode hashes;
- versioned step salts, transaction indexes/nonces, dependency edges, and
   CREATE addresses derived from the deployer and starting nonce; and
- the post-deployment `REGISTRY_UPDATER_ROLE` wiring call.

The canonical plan also includes the bond `StakeVault`, `ParameterVersionRegistry`,
the appeal module's vault-operator grant, and the optional deployer-role renunciation.
These steps consume nonces just like contract creation. Dependencies must point to
earlier deployments; calls cannot precede their target deployment.

### Ordered checkpoints and resume (#705)

The TypeScript helper executes the same manifest constructor inputs with explicit,
contiguous nonces. The CLI requires `DEPLOYMENT_STARTING_NONCE` and writes to
`DEPLOYMENT_CHECKPOINT` (default
`deployments/<DEPLOY_ENV>/canonical-v2-checkpoint.json`). Preserve this file and
reuse the original starting nonce and options on every resume. Programmatic users
enable durable execution with `{ startingNonce, checkpointFile }`; the in-memory
default is intended for isolated tests.

Before invoking the signer, the helper atomically flushes an intent. It records the
returned transaction hash before waiting for its receipt. Before resume it checks
the plan hash, signer and chain, every previous transaction's exact input and successful
canonical receipt, and every deployed contract's runtime code at both its receipt
block and the current head. Archive access is required when historical code is no
longer available. Confirmed and pending deployer nonces must both equal the next
planned nonce. Missing history, reorgs, code changes, and external nonce consumption
stop execution. Use a dedicated deployer; do not share it with other transactions.

A recorded hash is never automatically replaced or rebroadcast. If the RPC response
was lost, the intent may have no hash: first investigate the deployer's nonce on
chain and in the mempool. The programmatic `reconcile: { index, hash }` option accepts
only a mined transaction that matches every planned field and a successful receipt.
If no matching transaction can be proven, abandon the run and review a new plan;
deleting the intent and blindly retrying is unsafe. A process crash leaves an
exclusive `.lock` file: remove it only after establishing that its process has
stopped, then resume using the intact checkpoint. Do not edit receipt or code hashes.

Only a fully verified execution writes `<checkpoint>.manifest.json`. Its ordered
transactions include the actual hashes, receipt block hashes/numbers, transaction
positions, CREATE addresses and observed runtime hashes. Planned artifact runtime
hashes can differ from observed hashes where Solidity embeds constructor immutables.
This path adds no deployment authority or production-readiness attestation; #706
and #685 remain independent release dependencies. The legacy Foundry workflow and
direct Ignition commands do not consume this journal.

Reproduce interruption, drift, reconciliation, reorg, code-change, concurrent-writer
and manifest-ordering tests with `npm run test:deployment:resume` (Anvil on `PATH`).

The manifest contains no timestamp, private key, RPC URL, or launch address. A
fresh deployment account and the same starting nonce are required for address
reproduction. The recorded salts identify versioned deployment steps; the
current Ignition module uses ordinary CREATE transactions, not a CREATE2 factory.
Released legacy Foundry manifests remain compatible and are not rewritten by
this generator.
