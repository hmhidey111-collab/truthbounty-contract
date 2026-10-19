# Source, Bytecode, and Metadata Reproducibility (V2-SC-129)

Status: enforced in CI (`npm run lint` → `check:reproducibility`) · Owner: contracts maintainers ·
Depends on V2-SC-111 (authority boundaries) and V2-SC-121 (storage-layout manifests).

## 1. Objective

Rebuild deployed artifacts from source and confirm that compiler, optimizer,
metadata, libraries, source hashes, and explorer-verification inputs match the
approved release manifest at
`deployments/releases/v2-sc-129-release-manifest.json`.

This closes the assurance gap between "code review passed" and "the deployed
bytecode is exactly what was reviewed": any drift in toolchain settings,
source bytes, linked libraries, CBOR metadata, or explorer inputs fails closed
in CI and blocks release attestation (`scripts/auditReleaseReadiness.ts`).

## 2. Authoritative behavior

- The manifest is authoritative for the release toolchain: solc **0.8.28**, EVM
  version **cancun**, **`viaIR: true`**, optimizer **enabled** with exactly
  **200 runs**, metadata hash mode **ipfs**.
- `scripts/check-release-reproducibility.mjs` verifies, in order:
  1. **Digest**: `manifestDigest` recomputes (keccak-256 over the canonical
     JSON encoding, dependency-free `scripts/lib/keccak256.mjs`). Hand edits
     without regeneration fail.
  2. **Toolchain**: `hardhat.config.ts` and `foundry.toml` pins equal the
     manifest (parsed as text, no compiler or network required).
  3. **Sources**: sha-256 of every pinned source matches; missing, duplicated,
     or drifted sources fail. Pinned sources must contain no
     Stellar/Soroban/Freighter references and no `__$..$__` link placeholders.
  4. **Artifacts**: rebuilt `bytecode`/`deployedBytecode` (Foundry `out/` first,
     then Hardhat `artifacts/`) must hash (keccak-256) to the pinned values.
     Missing build outputs fail with "rebuild required" — unverified bytecode
     never passes. Any `__$..$__` placeholder or nonzero link-reference set
     fails (canonical modules link no external libraries).
  5. **Metadata**: the CBOR tail of each deployed bytecode must decode to the
     pinned solc version (`0.8.28`). Missing or mismatched metadata fails.
  6. **Libraries**: every pinned library address must be non-zero and
     well-formed.
  7. **Explorer**: the manifest's explorer block must carry the full
     verification field set (contract, source, compiler, EVM, optimizer,
     via-IR, bytecode hashes, metadata solc, libraries, target networks) with
     values consistent with the toolchain pins.
- `node scripts/check-release-reproducibility.mjs --write-manifest` regenerates
  computed hashes and the digest. It **refuses** when toolchain pins drift, so
  regeneration is always a maintainer-reviewed, explicitly-diffed step — never
  an auto-pass.
- `contracts/v2/libraries/ReleaseReproducibility.sol` is the on-chain mirror of
  the same pins: pure, stateless, authority-free helpers (`validateCompiler`,
  `validateLibraryAddress`, `assertNoLinkReferences`, `releaseDigest`,
  `checkDigest`) that revert with typed custom errors on any deviation.

## 3. Assumptions

- A deterministic toolchain: `foundry.toml` pins `solc = "0.8.28"` (added by
  this change; previously the compiler floated with `^0.8.20` pragmas) and
  `hardhat.config.ts` pins `0.8.28`/`cancun`/`viaIR`/200 runs.
- Rebuilds run from a clean checkout at the release commit; output selection
  differences outside bytecode (e.g. source maps) do not affect the pinned
  hashes.
- `contracts/v2/SignatureNonces.sol` is `abstract` and therefore has no
  bytecode by design. It is pinned under `sources` only; its code is covered
  transitively through the bytecode of inheriting modules.
- Explorer verification targets are Optimism mainnet (chain 10) and Optimism
  Sepolia (chain 11155420). No production addresses or secrets are pinned.

## 4. Failure modes (all fail closed)

| Failure | Signal |
|---|---|
| solc / EVM / via-IR / optimizer drift | `toolchain drift: …` |
| edited source file | `source drift: <path> sha256 …` |
| missing/duplicated source pin | `pinned source missing` / `duplicate source pin` |
| no build outputs present | `no build outputs found: run forge build …` |
| rebuilt bytecode differs | `<contract>: bytecode drift` / `deployedBytecode drift` |
| unresolved libraries | `unresolved link placeholders` / `unresolved link references` |
| zero/malformed library address | `pinned library … zero or malformed` |
| CBOR metadata missing or wrong solc | `no decodable solc CBOR metadata` / `embedded metadata solc …` |
| explorer inputs incomplete/inconsistent | `explorer block …` |
| hand-edited manifest | `manifest digest mismatch` |
| alternate-chain runtime in pinned source | `forbidden alternate-chain runtime reference` |

## 5. Module boundaries

| Component | Authority | Notes |
|---|---|---|
| `ReleaseReproducibility` library | **None** — `pure`, no storage, no events, no calls, no value | Callable by anyone with identical results; no privileged path |
| `check-release-reproducibility.mjs` | **None** — offline file reads + hashing only | No network, no keys, no deployment, no `grantRole`/transfer/call |
| release manifest JSON | Attestation data only | Digest-tamper-evident; regeneration is maintainer-gated |
| `auditReleaseReadiness.ts` integration | Read-only gate | Fails release readiness on any checker failure |

Contracts remain authoritative for protocol mutation and settlement. No API,
indexer, frontend, guardian, deployer, or test harness gains settlement or
treasury authority through this change.

## 6. Affected interfaces, storage, events, roles, config, deployment artifacts

- **Interfaces**: none changed. The checker reads `IStakeCustody`,
  `IEvidence`, `IEventCompleteness`, `IV2Module` sources as pinned inputs only.
- **Storage**: none added or moved. No storage-layout impact (V2-SC-121
  manifests untouched).
- **Events**: five stale `emit` sites in `contracts/v2/StakeVault.sol`
  (`StakeDeposited`, `StakeReleased`, `StakeSlashed`, `VaultCarriedForward`,
  `VaultRolledOver`) were missing the `(timestamp, version)` tail required by
  `IStakeCustody` and did not compile. They now follow the established
  `(uint64(block.timestamp), EVENT_SCHEMA_VERSION)` pattern used by the
  already-correct sites. Three `expectEmit` sites in
  `test/v2/V2SecurityAudit.t.sol` were updated to the same signatures. Event
  semantics are unchanged; projection/replay compatibility is preserved
  (timestamps were already emitted by the sibling sites).
- **Roles**: none added, removed, or re-scoped (V2-SC-111 topology untouched).
- **Configuration versions**: protocol `2.0.0`; manifest `schemaVersion: 1`;
  toolchain pins as in §2.
- **Deployment artifacts**: new `deployments/releases/` manifest; `foundry.toml`
  gains the `solc = "0.8.28"` pin. No deployment scripts, constructor args, or
  addresses changed.

## 7. Preserved protocol properties

- **Bounded execution**: checker loops are bounded by the manifest's pinned
  source/artifact sets; `BoundedSafeERC20` gains `safeDecreaseAllowance` with
  the same bounded-returndata pattern as `safeIncreaseAllowance` (OZ-mirroring
  semantics: revert on underflow instead of wrapping).
- **Pull-based value transfer**: untouched; this change moves no value.
- **Deterministic rounding**: untouched; digest uses `abi.encode` (never
  `abi.encodePacked`) so the preimage has exactly one parse.
- **Replayable event semantics**: restored — the fixed `emit` sites now match
  the interface definitions every projector decodes against.
- **Asset conservation / single settlement / no double claim / immutable
  active-claim parameters / timelocked governance**: untouched on-chain; the
  `SinglePinHarness` in `test/v2/ReleaseReproducibility.t.sol` covers the
  analog properties for the release digest itself (pin once, reject double
  pin, reject zero digest, immutable after pin).

## 8. Migration impact and compatibility

- No migration required. No active-claim parameters, storage slots, selectors,
  or event topic-0 values change (the previously non-compiling emits could
  never have produced on-chain history).
- Released artifacts: bytecode hashes for the 12 canonical modules are
  (re-)pinned by this change; any downstream release manifest that embedded
  the old non-buildable tree must re-resolve against the new manifest digest
  `0xd1533659b11fcef911ff25296f8aba5d5a6c74589aeaac6063f29d344af36248`.
- Consumers (indexers, frontends) observably gain the five previously-missing
  event emissions once a build containing this change is deployed; field
  layouts match the already-published `IStakeCustody` definitions.

## 9. Drive-by restoration (prerequisite, independently reviewable)

The tree at `upstream/main` did not compile under the pinned solc 0.8.28 (and
does not compile under newer solc either). Without a compilable tree,
"rebuild deployed artifacts" is unachievable, so this PR carries the minimal
repairs, each behavior-preserving and each documented here:

1. `contracts/governance/EmergencyProtected.sol` — bad merge splice left two
   nested `whenNotPaused` definitions; restored the main-line (`e98c124`)
   modifier verbatim (8 deleted lines, no semantic change).
2. `contracts/EIP712Verifier.sol` + `contracts/decay.sol` — stray
   `_requireReasonBound(reason)` lines inside parameter-less
   `getClaimSubmissionHash` (undeclared identifier); removed the stray lines.
3. `contracts/libraries/BoundedSafeERC20.sol` — added the missing
   `safeDecreaseAllowance` called by `TokenomicsEngine` (mirrors OZ semantics
   with bounded returndata; reverts on underflow).
4. Import-scope collisions (`SafeERC20` alias vs OZ `SafeERC20`): converted
   plain source-unit imports to explicit symbol imports in
   `contracts/mocks/MockRewardEngineHarness.sol` and
   `test/RewardPoolExhaustion.t.sol`; aliased the OZ import to `OZSafeERC20`
   in `test/v2/AdversarialERC20.t.sol` and `test/v2/PauseExitLiveness.t.sol`;
   fixed `IAccessControl` error qualifier in
   `test/fuzz/GasBudgetRegistryFuzz.t.sol`; removed a duplicated
   `operatorRole` declaration in `test/DisputeResolution.t.sol`.

## 10. Tests and evidence

- `test/v2/ReleaseReproducibility.t.sol` — 38 tests: positive, negative,
  boundary (runs 199/201, patch ±1, single link ref, oversized version
  components), authorization (caller-invariance, no privileged path), replay
  (determinism, input sensitivity), single-pin settlement analog, manifest
  reconciliation, and fuzz (`runs`, `patch`, library addresses, link counts,
  digest sensitivity, oversized components).
- `test/scripts/check-release-reproducibility.test.mjs` — 17 tests covering
  every checker failure class in §4 plus determinism and fail-closed
  no-build-output behavior.
- `forge test --match-contract ReleaseReproducibilityTest`: 38 passed.
- `node --test test/scripts/check-release-reproducibility.test.mjs`: 17 passed.
- `node scripts/check-release-reproducibility.mjs`: verified against real
  `forge build` (solc 0.8.28) outputs.

## 11. Residual risk

- The manifest pins 12 canonical modules' bytecode today; extending coverage
  to the full 460-file tree is future work (tracked; the checker already
  supports it — add entries and regenerate).
- Build determinism across machines (absolute paths in metadata, timestamps)
  is mitigated by comparing keccak hashes of `bytecode`/`deployedBytecode`
  objects only, but a hermetic-builder attestation (container digest pinning)
  is not yet in scope.
- `via-IR` full-tree builds are memory-intensive (~OOM on 2-CPU/8 GB
  builders); CI builders must meet the memory floor or build the pinned
  module set in batches as documented in this PR's verification log.
