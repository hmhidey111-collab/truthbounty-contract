# Optimism Sepolia Release Package (STAB-SC-007)

Status: **candidate generator + gate shipped; publication pending maintainer-supplied owners**
Owner: contracts maintainers · Consumers: API #586, frontend artifact verifier (UX-SC-001)
Chain: **Optimism Sepolia only — chain id `11155420`**. This package is not a mainnet deployment
and is not mainnet approval.

---

## 1. What the package is

The release package is the single, checksummed document that lets the API and the frontend run one
pinned testnet journey against the same contracts:

```
config/optimism-sepolia-release.json            reviewed release definition (human input)
deployments/releases/optimism-sepolia/
├── release.json                                canonical release package (generated)
├── release.sha256                              sha256 of the exact release.json bytes
├── artifact-pins.json                          reviewed ABI / bytecode / immutable pins
└── abis/<Contract>.json                        ABI export per canonical contract
```

`release.json` records:

| Section | Contents |
| --- | --- |
| `network` | chain id `11155420`, CAIP-2 `eip155:11155420`, explorer base, RPC env var |
| `releaseId` | immutable identity of the complete canonical suite (see §3) |
| `toolchain` | solc `0.8.28`, EVM `cancun`, `viaIR`, optimizer 200, `ipfs` metadata, Node/npm/Foundry pins |
| `deterministicDeployment` | CREATE2 factory, salt domain, bootstrap admin, nonce plan |
| `contracts[]` | address, source + sha256, salt, init-code hash, constructor args + digest, ABI/bytecode checksums, runtime/creation size, immutable slots, proxy relationship, source-verification link |
| `roleOwnership[]` | governance, timelock, guardian, upgrade-admin, treasury and operational ownership after finalization |
| `roleGrants[]` | every role × contract grant with holder and role hash |
| `finalization` | ordered grant / renounce / verify steps that remove deployer authority |
| `deployment` | deployment block, block hash, timestamp, **event start cursor**, reference block |
| `verification` | explorer verification progress and on-chain code check results |
| `commands` | build, generate, check, deploy, verify, on-chain, clean-environment reproduce |
| `rollback` | pause, governed unpause, role transfer, upgrade rollback, recovery |
| `consumers` | API and frontend blocks, each pinning the same `releaseId` and `packageChecksum` |
| `blockers` | machine-readable reasons a candidate may not be published |

Canonical suite (11 contracts): `RewardToken`, `ModuleRegistry`, `Claims`, `StakeVault`,
`EvidenceRegistry`, `Aggregation`, `FinalRewardAllocator`, `EmergencyControls`,
`EmergencyGatekeeper`, `EventCompletenessAnchor`, `ConsumerGuaranteesAnchor`.

`SupplyChainAttestationAnchor` is intentionally **outside** this package: the supply-chain
attestation is produced by the SBOM/provenance pipeline (#734) and is consumed as a separate
artifact; embedding it here would duplicate that authority.

---

## 2. Generate and verify

npm scripts (thin wrappers, same commands):

| Script | Command |
| --- | --- |
| `npm run build:release-artifacts` | rebuild the canonical artifacts with the pinned compiler |
| `npm run check:release-artifacts` | prove the committed artifacts match a clean rebuild |
| `npm run check:release` | offline gate |
| `npm run check:release:artifacts` | offline gate + rebuild comparison (`--artifacts hardhat`) |
| `npm run check:release:onchain` | read-only on-chain gate (`$OPTIMISM_SEPOLIA_RPC_URL`) |
| `npm run release:generate` | regenerate the package after an intentional change |
| `npm run release:promote` | publish a candidate from real deployment evidence |
| `npm run test:release` | 75-case self-test suite |

```bash
# 1. Build the canonical suite with the pinned toolchain
#    (solc 0.8.28, cancun, viaIR, optimizer 200, ipfs metadata).
npm run build:release-artifacts

# 2. Regenerate the package after an intentional change.
node scripts/generateOptimismSepoliaReleasePackage.mjs --write

# 3. Drift gate (what CI runs).
node scripts/check-optimism-sepolia-release.mjs --with-artifacts --artifacts hardhat

# 4. Read-only on-chain check (requires an RPC endpoint; no keys).
node scripts/check-optimism-sepolia-release.mjs --onchain --rpc-url $OPTIMISM_SEPOLIA_RPC_URL
```

`--write` is the only supported way to change `release.json`. Hand edits invalidate both the
package checksum and the release ID and fail the gate.

### Clean-environment reproduction check

```bash
git clean -xdf -e node_modules
npm ci
npm run build:release-artifacts
npm run check:release-artifacts
node scripts/check-optimism-sepolia-release.mjs --with-artifacts --artifacts hardhat
```

Without build outputs the five rebuild-comparison tests are **skipped**, never silently passed: the
offline gate and the 66 static invariants still run, so a checkout with no `artifacts/` cannot
report a false success. `artifacts/` is gitignored build output and is never committed.

The gate recomputes, from the rebuild, every ABI checksum, creation-bytecode hash, deployed-bytecode
hash, immutable-slot count and init-code hash, and fails if any differs from the committed package.
`scripts/generateOptimismSepoliaReleasePackage.mjs --check` additionally proves that regenerating
from the same inputs produces **byte-identical** output.

---

## 3. Immutable release ID

```
releaseId = keccak256(canonicalJson({
  chainId, releaseName, protocolVersion, configurationVersion, saltDomain, factory,
  toolchain,
  contracts: [{ name, source, sourceSha256, address, salt, initCodeHash,
                constructorArgsSha256, bytecodeKeccak, deployedBytecodeKeccak, abiSha256 }],
  roleGrants:      [{ contract, role, custodyRef }],
  roleOwnership:   [{ class, custodyRef }]
}))
```

Properties:

- **Stable across promotion.** Publication adds evidence (status, block, verification links) but
  never changes the component set, so the API and frontend can pin `releaseId` before the
  deployment is broadcast.
- **Custody-by-reference.** Role grants are bound to a custody *slot*, not to the current owner, so
  rotating a multisig does not silently create a "new release".
- **Checksummed twice.** `release.json` carries `packageChecksum = sha256(canonicalJson(package))`
  and `release.sha256` pins the sha256 of the exact file bytes, so both a JSON-naive `sha256sum -c`
  and a canonical-JSON verifier agree.

---

## 4. Deterministic addresses

Every canonical address is the CREATE2 address of the reviewed creation code:

```
salt        = keccak256("<saltDomain>:<ContractName>")
initCode    = creationBytecode ‖ abi.encode(constructorArgs)
initCodeHash= keccak256(initCode)
address     = keccak256(0xff ‖ factory ‖ salt ‖ initCodeHash)[12:]
```

- Factory: `0x4e59b44847b379578588920cA78FbF26c0B4956C` (deterministic deployment proxy, code hash
  `0x2fa86add…98f` pinned in the package and verifiable with `eth_getCode`).
- Addresses are therefore independent of the broadcaster's nonce sequence: the same package yields
  the same addresses on any EVM at any block.
- `artifact-pins.json` pins `bytecodeKeccak`, `deployedBytecodeKeccak`, `creationBytes`,
  `runtimeBytes`, `immutableSlots`, `linkReferences` and `abiSha256` per contract. The offline gate
  compares the package to these pins; `--with-artifacts` compares the pins to a fresh build.

Constructor inputs never contain secrets: they are literals, suite-contract references
(`$contract:Name`) or custody slots.

---

## 5. Role ownership and deployer authority removal

The package models the **final** state, after handoff:

| Role class | Owner | Notes |
| --- | --- | --- |
| governance | timelock custody slot | `ModuleRegistry.GOVERNANCE_ROLE`, `EmergencyControls.GOVERNANCE_ROLE` |
| timelock | timelock custody slot | 172800s minimum delay on every governed action |
| guardian | guardian custody slot | veto / pause only; cannot mutate the registry or unpause |
| upgrade admin | upgrade-admin custody slot | no proxy admin; module replacement = `GOVERNANCE_ROLE` + 172800s timelock |
| treasury | treasury custody slot | `Claims.feeRecipient`, treasury flows |
| operational | pause-initiator / pause-resolver custody slots | split pause authority, 3600s rewire delay |

`finalization.steps` is an ordered, executable plan: grant every reviewed role, renounce
`DEFAULT_ADMIN_ROLE` from the bootstrap admin on every `AccessControl` contract, then run
`PostDeploymentRoleCheck.checkAllRoles(bootstrapAdmin, canonicalContracts)` and require zero
violations. `script/deploy/VerifyRoleRenunciation.s.sol` performs the same check on-chain.

The gate fails if **any** role grant resolves to the bootstrap admin, if a required role class is
missing, if a role hash does not match its name, or if the finalization plan has no renounce and
verify step.

### Custody slots

Until the maintainer supplies real Optimism Sepolia owners, custody slots are derived placeholders:

```
address = keccak256("truthbounty:optimism-sepolia:custody:<slot>")[12:]
```

They are explicitly typed `custody: "unassigned"` and are **not** owners: no key is known, no
authority can be exercised. The gate refuses to publish a package while any slot is unassigned
(`promotion refuses unassigned custody even with full evidence`), so an unassigned slot can never be
mistaken for a live owner. Assigning a slot means editing `custody.<slot>` in the release definition
and regenerating — which produces a new address set and therefore a new `releaseId`, exactly as a
different owner set should.

---

## 6. Deployment block and event start cursor

- `deployment.blockNumber`, `deployment.blockHash`, `deployment.timestamp` — populated by promotion
  from the deployment evidence file written by `scripts/deployOptimismSepoliaRelease.ts`.
- `deployment.eventStartCursor = { blockNumber, blockHash }` — the indexer must start ingestion at
  this block, not at genesis and not at `0`. It is asserted to equal the deployment block and block
  hash.
- `deployment.referenceBlock` — the Optimism Sepolia block the package was built against
  (50207495, `0x5ae4b51a…4647`), used to prove the package was produced against a recent chain view.

A candidate package must leave all of these `null`. Claiming a block that was never produced is
rejected, which keeps the "no fabricated evidence" property structural rather than editorial.

---

## 7. Publication (promotion)

```bash
# 1. Fill every custody slot with a real Optimism Sepolia owner in
#    config/optimism-sepolia-release.json (custody: "assigned", label: "...").
# 2. Regenerate and re-review the manifest (new releaseId, new addresses).
node scripts/generateOptimismSepoliaReleasePackage.mjs --write

# 3. Broadcast deterministically.
npx hardhat run scripts/deployOptimismSepoliaRelease.ts --network optimismSepolia

# 4. Verify every contract with the pinned compiler inputs.
npx hardhat run scripts/verifyOptimismSepoliaRelease.ts --network optimismSepolia

# 5. Verify code + roles read-only against the chain.
node scripts/check-optimism-sepolia-release.mjs --onchain --rpc-url $OPTIMISM_SEPOLIA_RPC_URL

# 6. Promote: publish only if all evidence is complete.
node scripts/generateOptimismSepoliaReleasePackage.mjs --promote
```

Promotion refuses to run unless: custody is assigned, the evidence covers every contract and the
package address, explorer verification succeeded for every contract, and the recomputed release ID
is unchanged. The result is `status: "published"` with `evidenceClass: "optimism-sepolia"`.

---

## 8. Consumer integration

Both consumers read the same file through the same module:

```js
import { loadReleasePackageForConsumer } from "./scripts/lib/releasePackageConsumer.mjs";

const api = loadReleasePackageForConsumer("api");           // API #586
const ui = loadReleasePackageForConsumer("frontend");       // UX-SC-001 artifact verifier
// both throw unless the package is published, checksummed, on-chain 11155420 and secret-free
```

`assertConsumersAgree()` fails closed when the two profiles disagree on `releaseId`,
`packageChecksum`, file sha256, chain id, deployment block, event cursor, or any shared address.
`test/scripts/check-optimism-sepolia-release.test.mjs` runs that assertion against the committed
package.

---

## 9. Drift gates

`--onchain` additionally asserts the RPC chain id, the pinned CREATE2 factory runtime hash, the
pinned reference-block hash, and per-contract code presence/length/hash (immutable-bearing
contracts are identified by length, and the package records why).

`node scripts/check-optimism-sepolia-release.mjs` fails on:

| Drift | Detected by |
| --- | --- |
| wrong chain id / network / explorer | `network` checks |
| solc, optimizer, EVM version, viaIR | `hardhat.config.ts` + `foundry.toml` pins |
| source change under `contracts/` | `sourceSha256` |
| ABI change | `abiSha256` + ABI file sha256 + `artifact-pins.json` |
| bytecode / deployed bytecode change | `artifact-pins.json`, `--with-artifacts` |
| constructor-argument change | `constructorArgsSha256` + CREATE2 address recomputation |
| address substitution | CREATE2 recomputation vs factory/salt/init code |
| placeholder / local / zero / duplicate address | address hygiene checks |
| role mutation / retained deployer authority | role graph + bootstrap-admin exclusion |
| deployment-block or cursor mutation | block/cursor equality rules |
| toolchain or consumer mismatch | toolchain and consumer checks |
| secrets in commands or fields | secret scanner |
| factory runtime drift (on-chain mode) | pinned factory `codeHash` vs `eth_getCode` |
| reference block drift (on-chain mode) | pinned block hash vs `eth_getBlockByNumber` |

CI (`.github/workflows/release-package.yml`) runs the offline gate, the byte-identical
regeneration check, the rebuild comparison and the 75-case self-test suite on every push and pull
request, plus a read-only on-chain check when `OPTIMISM_SEPOLIA_RPC_URL` is configured. The
repository's `.github/workflows/ci.yml` is gitignored upstream, so the release gate lives in its own
tracked workflow file rather than in that hidden pipeline.

---

## 10. Rollback and recovery

- **Pause** — `EmergencyGatekeeper.pause(scope)` by the pause initiator; scope-bounded.
- **Governed unpause** — only the timelock executes the resolver path after the 172800s delay; the
  guardian cannot unpause.
- **Role transfer** — re-run the finalization grant/renounce steps, then
  `forge script script/deploy/VerifyRoleRenunciation.s.sol` against the canonical addresses.
- **Upgrade rollback** — `ModuleRegistry.cancelModuleReplacement(moduleId)` before execution; after
  execution, re-register the previous implementation (`GOVERNANCE_ROLE` + 172800s timelock). Storage
  layouts remain frozen by `storage-layouts/manifest.json`.
- **Recovery** — `docs/runbooks/rollback.md`; restore the previous release package by `releaseId`,
  replay events from the pinned `eventStartCursor`, and re-verify roles with
  `PostDeploymentRoleCheck`.

No private key, mnemonic, API key, or production credential appears in the package, the generator,
the gate, or the docs. Deployment keys are supplied only through the operator environment.

---

## 10a. Scope boundaries (what this package deliberately does not claim)

- **Not mainnet.** Chain id 11155420 only; a mainnet release requires its own package and ID.
- **No module registration.** `ModuleRegistry` ships as a registry contract; registering and
  activating the 14 canonical module keys (`ModuleRegistryLib`) is a post-deployment, governed
  action and is not encoded in this package. The package therefore records
  `proxy.kind = "none"` for every contract — the canonical V2 modules are non-upgradeable
  implementations, not ERC-1967 proxies.
- **No production economic parameters.** Constructor inputs are the reviewed testnet values.
- **No transaction claiming.** A candidate package carries `null` block evidence; a published one
  carries evidence written by the broadcaster. Neither is hand-edited.

## 10b. Why the release build is scoped, not whole-tree

`scripts/buildReleaseArtifacts.mjs` compiles **exactly** the contracts declared in
`config/optimism-sepolia-release.json` plus their import closure (11 targets / 71 sources) and
nothing else. Two reasons:

1. **Identity hygiene.** A release digest must depend only on release sources. A whole-tree build
   lets an unrelated contract edit move a release-critical bytecode hash.
2. **The tree does not currently compile.** At HEAD, `forge build` and `npx hardhat compile` both
   fail on pre-existing syntax errors in three files that are *not* release sources:
   `contracts/deployment/MigrationManager.sol`, `contracts/upgrade/IProtocolUpgradeManager.sol`,
   `contracts/upgrade/VersionRegistry.sol`. Those defects belong to other work items and must not
   gate publication of this package; the scoped build keeps the release gate meaningful in the
   meantime. `npm run check:release-artifacts` re-derives every artifact from scratch and fails if
   any byte moved.

## 11. Repository-level notes

- The approved release build is the **Hardhat** build (`hardhat.config.ts`: solc `0.8.28`,
  `cancun`, `viaIR`, optimizer 200). `foundry.toml` still pins `evm_version = "prague"`; that
  discrepancy is owned by the compiler-authority work (#667/#735) and is deliberately not
  "fixed" here, because changing it would silently alter every Foundry artifact hash.
  `--with-artifacts` therefore prefers Hardhat outputs, and the package's toolchain block records
  the Hardhat release pins.
- `deployments/releases/v2-sc-129-release-manifest.json` is a *source/bytecode reproducibility*
  manifest and is **not** consumed here; this package supersedes it as the consumer-facing artifact.
- The package is Optimism Sepolia only. Adding any other chain requires a new package with its own
  release ID; a package is never mainnet approval.
