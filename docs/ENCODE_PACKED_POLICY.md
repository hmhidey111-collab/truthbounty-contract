# Packed-Encoding Commitment Policy (V2-SC-160)

`abi.encodePacked` does not record where one operand ends and the next begins. When two or more
variable-length operands (`string`, `bytes`, dynamic arrays) sit in one packed preimage, different
inputs can produce the same bytes — `("ab","c")` and `("a","bc")` both pack to `0x616263` — and
therefore the same hash. This document is the authoritative inventory of packed encodings in the
repository, the classification and justification of every use that is kept, the migration impact of
every digest that changed, and the map from each V2-SC-160 acceptance criterion to reproducible
evidence.

## Policy

A packed encoding that feeds a hash (`keccak256`, `sha256`, `ripemd160`) is permitted only in one of
these classes:

| Class | Rule | Where allowed |
| --- | --- | --- |
| `FIXED_WIDTH` | Every operand is a fixed-width value type (`address`, `bool`, `uintN`, `bytesN`, enums, structs of value types) or a compile-time constant string literal. The preimage length is constant, so it has exactly one parse. | Everywhere |
| `LENGTH_PREFIXED` | Every variable-length operand is immediately preceded by `uint256(bytes(x).length)`. Boundaries are explicit. | Everywhere |
| `PROTOCOL_DEFINED` | An external standard fixes the byte layout (e.g. CREATE2 init code). The entry must cite the standard. | Everywhere |
| `SINGLE_DYNAMIC` | Exactly one variable-length operand, all others fixed-width. This has one parse, but a caller-chosen variable-length operand can still soak up another schema's bytes (see the cross-schema fixture below). | Legacy, deprecated and test code only. **Never inside the canonical V2 scope.** |
| `LEGACY_MIRROR` | Test fixtures that reproduce a retired scheme on purpose, to prove the collision or the non-reinterpretation. | `test/` only |

Packed encodings that are **not** hashed are `NON_DIGEST` (error strings, file paths, JSON bodies,
calldata or signature assembly). They are `DELIMITED_VALIDATED` when free-form fields are joined with
a delimiter and a named guard rejects the delimiter in every free-form field.

Two or more variable-length operands in a hash preimage are forbidden unless they are
`LENGTH_PREFIXED` or `PROTOCOL_DEFINED`. New commitments use typed `abi.encode` with a
version/domain tag as the first word (the pattern in `ReputationMerkleDomain`, `EIP712Verifier`,
and the V2-SC-160 schemes below).

The canonical V2 scope, where digests must be `FIXED_WIDTH`, `LENGTH_PREFIXED` or
`PROTOCOL_DEFINED`, is: `contracts/v2/`, `contracts/governance/v2/`, `contracts/libraries/`,
`contracts/upgrade/`, `contracts/deployment/`, `contracts/verification/`, `contracts/settlement/`,
`contracts/reward/`, `contracts/disputes/`, `contracts/utils/` and `contracts/EIP712Verifier.sol`.

## Static enforcement

[`scripts/check-encode-packed.mjs`](../scripts/check-encode-packed.mjs) scans `contracts/`,
`contracts-vrm/`, `script/`, `scripts/` and `test/` (never `lib/` or `node_modules/`) for:

* Solidity `abi.encodePacked(...)`, and `bytes.concat(...)` / `string.concat(...)` used directly as a
  hash preimage;
* off-chain `solidityPacked`, `solidityPackedKeccak256`, `solidityPackedSha256`,
  `solidityKeccak256`, `solidityPack` and viem `encodePacked`.

Comments and quoted text are ignored. Each use is keyed by a fingerprint (the first 12 hex chars of
sha256 over the whitespace-free call expression), so moving a line does not churn the policy, while
any edit to the expression forces a re-review. Every use must match an entry in
[`scripts/encode-packed-policy.json`](../scripts/encode-packed-policy.json) that declares its
context (digest / non-digest), its classification, its operand types (for digests), and a
justification. The checker:

* fails on an unlisted use, a stale entry, or an occurrence-count drift;
* fails when the declared context does not match the detected context;
* cross-checks declared operand types against the source (string literals, casts, `type(X).creationCode`,
  local and state declarations, and the explicit type list of off-chain packers), so a string cannot
  be declared fixed-width;
* fails when two or more variable-length operands feed a hash outside `LENGTH_PREFIXED` /
  `PROTOCOL_DEFINED` / `LEGACY_MIRROR`, and when a canonical V2 digest is anything other than
  `FIXED_WIDTH`, `LENGTH_PREFIXED` or `PROTOCOL_DEFINED`;
* verifies anchors that keep the V2-SC-160 replacements in place (scheme tags, typed encodings, the
  delimiter guard).

`scripts/check-encode-packed.mjs`, `scripts/check-encode-packed-vectors.mjs` and
`test/scripts/check-encode-packed.test.mjs` are excluded from the scan because they quote or
deliberately recompute the patterns they police; none produces a protocol commitment.

Known limits: operand typing is best-effort (an identifier declared with different types in two
functions of the same file resolves to the first declaration), and a packed value stored in a local
variable and hashed later is classified by the call site (`non-digest`); reviewers must check such
cases when approving a `NON_DIGEST` entry.

## Inventory

104 packed encodings in 102 distinct expressions (`node scripts/check-encode-packed.mjs --report`).

### Changed (V2-SC-160)

| File | Use | Before | After |
| --- | --- | --- | --- |
| `contracts/libraries/CanonicalEventLibrary.sol` | `computeOperationId` | `keccak256(abi.encodePacked(domain, nonce, actor))` — caller-chosen `string domain` | `keccak256(abi.encode(OPERATION_ID_SCHEME_V2, domain, nonce, actor))` |
| `contracts/upgrade/UpgradeController.sol` | `proposeUpgrade` → `proposalId` | `keccak256(abi.encodePacked("UPGRADE", target, newImpl, version, msg.sender, block.timestamp))` | `keccak256(abi.encode(UPGRADE_PROPOSAL_ID_SCHEME_V2, target, newImpl, version, msg.sender, block.timestamp))` |
| `contracts/upgrade/UpgradeController.sol` | `proposeUpgrade` → `upgradeHash` | `keccak256(abi.encodePacked(target, currentImpl, newImpl, version, upgradeType, block.timestamp))` | `keccak256(abi.encode(UPGRADE_HASH_SCHEME_V2, target, currentImpl, newImpl, version, upgradeType, block.timestamp))` |
| `contracts/upgrade/VersionRegistry.sol` | `_strEq` | `keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b))` | `keccak256(bytes(a)) == keccak256(bytes(b))` — byte-identical, no digest change |
| `contracts/v2/SupplyChainAttestationAnchor.sol` | `pack*` (4 records) | free-form fields joined with `\|`, no validation | every free-form field passes `_requireNoDelimiter` (reverts `V2Errors.AttestationFieldContainsDelimiter`) |

### Retained digests (production contracts)

| File | Operands | Class | Justification |
| --- | --- | --- | --- |
| `contracts/EIP712Verifier.sol` `_hashTypedDataV4` | `"\x19\x01"`, `bytes32`, `bytes32` | `FIXED_WIDTH` | EIP-191/EIP-712 prefix; always 66 bytes; pinned by V2-SC-152 vectors. |
| `contracts/decay.sol` `_hashTypedDataV4` | `"\x19\x01"`, `bytes32`, `bytes32` | `FIXED_WIDTH` | Same as above. |
| `contracts/deployment/Create2AddressPlanner.sol` `computeAddress` | `bytes1`, `address`, `bytes32`, `bytes32` | `FIXED_WIDTH` | EIP-1014 CREATE2 layout (85 bytes); pinned by the EIP-1014 published examples. |
| `contracts/deployment/Create2AddressPlanner.sol` `deriveSalt` | `bytes32`, `bytes32` | `FIXED_WIDTH` | 64 bytes; planned deployment addresses depend on it. |
| `contracts/disputes/AppealVerificationRound.sol` `_appealLockId` | `"V2_APPEAL_BOND"`, `uint256`, `uint256` | `FIXED_WIDTH` | Constant 14-byte tag + two words = 78 bytes; live vault locks depend on it. |
| `contracts/upgrade/TimelockOwnedProxyAdmin.sol` `upgradeId` | `address`, `address`, `uint256`, `uint256` | `FIXED_WIDTH` | 104 bytes; nonce + existence check. |
| `contracts/utils/ResolverRoleTimelock.sol` `operationId` | `address`, `bytes32`, `address`, `bool`, `uint256`, `uint256` | `FIXED_WIDTH` | 137 bytes; bound to `address(this)` and a nonce. |
| `contracts/ReputationSnapshot.sol` / `contracts/ReputationReceiver.sol` `_makeLeaf` | inner `address`, `uint256`, `uint256`; outer `bytes32` | `FIXED_WIDTH` | 84-byte leaf preimage, double-hashed so leaves (32-byte preimage) never parse as nodes (64-byte preimage); consumed off-chain by the tree builder. |
| `contracts/ReputationSnapshot.sol` tree build, `contracts/ReputationReceiver.sol` `_verifyProof` | `bytes32`, `bytes32` | `FIXED_WIDTH` | 64-byte position-ordered node. |
| `contracts/VerifierSlashing.sol` `penaltyId` (legacy V1) | `address`, `bytes32`, `uint256`, `uint256` | `FIXED_WIDTH` | 116 bytes; internal key. |
| `contracts/treasury/TreasuryAccounting.sol` `_generateTransactionId` (legacy V1) | `uint256`, `uint256`, `address`, `uint256` | `FIXED_WIDTH` | 116 bytes; internal key. |
| `contracts/treasury/TreasuryManagement.sol` `_createRecord` (legacy V1) | 7 × `uint256`/`address` | `FIXED_WIDTH` | 188 bytes; `_recordExists` check. |
| `contracts/simulation/EconomicSimulation.sol` `_generateSimulationId` | `SimulationConfig` (value types only), `uint256`, `uint256` | `FIXED_WIDTH` | Analysis tooling; not security sensitive. |
| `contracts/crosschain/CrossChainEndpoint.sol` `sendMessage` / `processMessage` (deprecated) | `uint256`, `uint256`, `address`, `address`, `bytes payload`, `uint256` | `SINGLE_DYNAMIC` | Only `payload` is variable-length, so `len(payload) = len(preimage) − 136`: one parse. Relayers recompute the id and in-flight messages depend on it; the deprecated module is not expanded (non-goal). Outside the canonical scope. |
| `contracts/insurance/InsuranceFund.sol` `incidentHash` (legacy V1) | `address`, `uint8`, `uint256`, `string descriptionURI` | `SINGLE_DYNAMIC` | Single trailing variable-length operand: one parse. Duplicate-incident guard compared only against the same schema in a private mapping; not a signature or claim commitment. Outside the canonical scope. |

### Retained non-digest uses (production and scripts)

| File | Class | Purpose |
| --- | --- | --- |
| `contracts/v2/SupplyChainAttestationAnchor.sol` (4) | `DELIMITED_VALIDATED` | Delimiter-joined attestation records, read back by `supplyChainAttestation()`; `_requireNoDelimiter` makes them injective. |
| `contracts/ExampleSettlement.sol` (2) | `NON_DIGEST` | Human-readable slashing reason strings. |
| `contracts/simulation/EconomicSimulation.sol` (5) | `NON_DIGEST` | Human-readable warning strings. |
| `script/deploy/DeployBase.s.sol` (3) | `NON_DIGEST` | Revert message, artifact path, deployment JSON body. |

### Tests and off-chain helpers

| Area | Class | Notes |
| --- | --- | --- |
| `test/ReputationReceiver.test.ts`, `test/ReputationSnapshot*.test.ts` (9) | `FIXED_WIDTH` | Off-chain mirrors of the Merkle leaf/node derivation (explicit ethers type lists). |
| `test/upgrade/StorageLayoutManifest.t.sol` | `LENGTH_PREFIXED` | V2-SC-121 canonical storage-layout hash: domain tag, schema version, then each variable-length field preceded by its length. |
| `test/deployment/Create2AddressPlanner.t.sol` | `PROTOCOL_DEFINED` | Init code = `creationCode ‖ abi.encode(args)` as the EVM defines it. |
| `test/fuzz/InsuranceFund.fuzz.sol`, `test/testnet/helpers/TestnetHelpers.t.sol` (2), `test/RewardEngine.fuzz.test.ts` (2) | `SINGLE_DYNAMIC` | Mirror of the legacy incident hash; single-string hashes (identical to `keccak256(bytes(s))`); test-only ids with a constant string. |
| `test/v2/EncodePackedCommitments.t.sol` (6) | `LEGACY_MIRROR` | Constructive collision fixtures reproducing the retired schemes. |
| Remaining test salts/content hashes (literal tag + fixed-width values) | `FIXED_WIDTH` | Fixed-width by construction. |
| Signature assembly `r ‖ s ‖ v`, calldata assembly, JSON paths, claim text | `NON_DIGEST` | Not hashed. |

The full per-expression list, with fingerprints and justifications, is
`scripts/encode-packed-policy.json`.

## Constructive collision fixtures

Every unsafe pattern that was removed has a fixture that shows the collision under the retired
encoding and the separation under the new one (`test/v2/EncodePackedCommitments.t.sol`, section 1,
and `collisions` in the vectors):

1. **Adjacent variable-length operands.** `keccak256(abi.encodePacked("ab","c")) ==
   keccak256(abi.encodePacked("a","bc")) == keccak256("abc")`, while the typed encodings differ.
2. **Cross-schema absorption (`computeOperationId` V1 vs `UpgradeController` V1 proposal id).** With
   `domain = "UPGRADE" ‖ target ‖ newImplementation ‖ version`, `nonce = proposer ‖ timestamp[0:12]`
   and `actor = timestamp[12:32]`, the retired operation id equals the retired upgrade proposal id
   byte for byte (`0x2ef83327…33b3`). Both are "operation identifiers" that indexers ingest, so one
   could be forged to alias the other. Under the V2 schemes the same inputs give
   `0x18e2bd11…245a` and `0x93eb8e99…18bc`.
3. **Delimiter shift.** `name="a|b", version="c"` and `name="a", version="b|c"` both join to
   `a|b|c`; the anchor now reverts `AttestationFieldContainsDelimiter`
   (`test_AnchorRejectsDelimiterInDependencyField`, `test_AnchorRejectsDelimiterInArtifactPath` in
   `test/v2/SupplyChainAttestationManifest.t.sol`).

## Versioned digests and migration impact

| Scheme | Tag constant | Tag preimage | Tag |
| --- | --- | --- | --- |
| Operation id v2 | `CanonicalEventLibrary.OPERATION_ID_SCHEME_V2` | `TruthBounty.CanonicalEventLibrary.operationId.v2` | `0x8c64e5c5cfa178c0038b286a8308bc8123d76ea44174910a08ded4a9b9cf443e` |
| Upgrade hash v2 | `UpgradeController.UPGRADE_HASH_SCHEME_V2` | `TruthBounty.UpgradeController.upgradeHash.v2` | `0x811553cc20c92c3707264c87d19f1ed9f2ca671214b9d6a3ecc419c6a7523b5c` |
| Upgrade proposal id v2 | `UpgradeController.UPGRADE_PROPOSAL_ID_SCHEME_V2` | `TruthBounty.UpgradeController.proposalId.v2` | `0x22015412ba7af32cf094b083b6dc19f23039090bf7813354d4d610afddfc54e4` |

Off-chain recomputation (ethers v6):

```js
const coder = ethers.AbiCoder.defaultAbiCoder();
// CanonicalEventLibrary.computeOperationId
ethers.keccak256(coder.encode(["bytes32", "string", "uint256", "address"], [OPERATION_ID_SCHEME_V2, domain, nonce, actor]));
// UpgradeController proposalId
ethers.keccak256(coder.encode(["bytes32", "address", "address", "string", "address", "uint256"],
  [UPGRADE_PROPOSAL_ID_SCHEME_V2, target, newImplementation, version, proposer, timestamp]));
// UpgradeController upgradeHash (upgradeType: STANDARD = 0, EMERGENCY = 1, ROLLBACK = 2)
ethers.keccak256(coder.encode(["bytes32", "address", "address", "address", "string", "uint8", "uint256"],
  [UPGRADE_HASH_SCHEME_V2, target, currentImplementation, newImplementation, version, upgradeType, timestamp]));
```

Compatibility impact:

* **Changed digests cannot reinterpret existing ones.** Every V2 preimage begins with its own
  32-byte scheme tag. The V1 proposal-id preimage begins with ASCII `UPGRADE`, which differs from
  the first 7 bytes of the tag (`test_versioned_v2PreimageCannotMatchLegacyPrefix`), so no V2
  proposal id can equal a V1 proposal id. The three tags are pairwise distinct, so V2 schemes are
  mutually domain separated. Fixed vectors and fuzz properties show V2 ≠ V1 for the same inputs.
* **`UpgradeController` is not upgradeable** (plain `AccessControl` contract, no proxy), so the
  change takes effect only on a new deployment, with empty proposal state. Proposals on an existing
  deployment keep their V1 ids and remain addressable there; nothing is re-keyed. Integrators that
  predicted a proposal id off-chain (rather than reading the return value or `UpgradeProposed`) must
  switch to the V2 formula for new deployments. The ABI gains two view getters
  (`UPGRADE_HASH_SCHEME_V2()`, `UPGRADE_PROPOSAL_ID_SCHEME_V2()`); no function or event signature
  changes, and there is no storage-layout change (constants only).
* **`CanonicalEventLibrary.computeOperationId`** is an `internal` library function with no call
  sites in production contracts at the time of the change, so no deployed contract or emitted id
  changes. Contracts compiled after this change emit V2 ids. Because the V1 packed scheme could be
  made to reproduce arbitrary preimages (fixture 2), it is retired rather than kept in parallel;
  indexers holding historical ids from out-of-tree users must key them by (scheme version, id).
* **`VersionRegistry._strEq`** is byte-identical (`keccak256(abi.encodePacked(s)) == keccak256(bytes(s))`).
* **`SupplyChainAttestationAnchor`** rejects `|` in free-form fields at construction. The committed
  manifest (`deployments/config/supply-chain-attestations.json`) contains no `|`, so it is
  unaffected. The anchor is deployment-scoped and immutable, so existing anchors are unchanged.
  The ABI gains the custom error `AttestationFieldContainsDelimiter()` in `V2Errors`.
* **Retained digests are unchanged**: EIP-712 digests (V2-SC-152 vectors), reputation Merkle
  leaves and nodes, CREATE2 addresses and reviewed salts, appeal-bond lock ids and all other
  fixed-width ids produce the same bytes as before. The `retained` vectors pin them.

## Cross-tool vectors

[`test/vectors/encode-packed-commitments.vectors.json`](../test/vectors/encode-packed-commitments.vectors.json)
holds the scheme tags, the collision fixtures, the versioned digests (with their V1 counterparts),
and the retained compatibility vectors. They are:

* recomputed with ethers (`solidityPacked`, `AbiCoder`, `getCreate2Address`) by
  `scripts/check-encode-packed-vectors.mjs`, which also checks each tag against its literal
  preimage in the contract source and checks that the EIP-712 vector equals the V2-SC-152 canonical
  vector;
* mirrored in `contracts/test/EncodePackedCommitmentVectors.sol`, compared constant by constant by
  the same script;
* checked against the live `CanonicalEventLibrary`, `UpgradeController` and `Create2AddressPlanner`
  (and OpenZeppelin `MessageHashUtils`, forge-std `computeCreate2Address`) by
  `test/v2/EncodePackedCommitments.t.sol`.

## Acceptance criteria → evidence

| Acceptance criterion | Evidence |
| --- | --- |
| No security-sensitive digest relies on ambiguous packed encoding. | `scripts/check-encode-packed.mjs` (CI `lint` job) rejects any hash preimage with two or more variable-length operands outside `LENGTH_PREFIXED`/`PROTOCOL_DEFINED`, and any canonical V2 digest that is not `FIXED_WIDTH`/`LENGTH_PREFIXED`/`PROTOCOL_DEFINED`; live-repository test `no canonical V2 digest relies on a variable-length packed operand`. The two canonical uses with a variable-length operand (`computeOperationId`, `UpgradeController` ids) now use typed `abi.encode`; the delimiter records are guarded. Collision fixtures: `test_collision_adjacentDynamicOperands`, `test_collision_crossSchema_operationIdVsUpgradeProposalId`, `test_collision_delimiterShift`, `test_AnchorRejectsDelimiterIn*`. |
| Each retained packed use has a documented fixed-width safety justification. | Every entry in `scripts/encode-packed-policy.json` carries a classification, declared operand types for digests (cross-checked against the source) and a justification of at least 40 characters; the tables above. Positive compatibility vectors: `test_retained_*` and `retained` in the vectors JSON. |
| Changed digests are versioned and cannot reinterpret active claims or signatures. | Scheme tags `OPERATION_ID_SCHEME_V2`, `UPGRADE_HASH_SCHEME_V2`, `UPGRADE_PROPOSAL_ID_SCHEME_V2` (anchored by the checker); `test_versioned_schemeTagsMatchVectors`, `test_versioned_operationIdV2MatchesVectorAndDiffersFromLegacy`, `test_versioned_upgradeIdsMatchVectorsAndDifferFromLegacy`, `test_versioned_v2PreimageCannotMatchLegacyPrefix`, `testFuzz_operationId_v2NeverEqualsLegacy`; EIP-712 signature digests are untouched (`test_retained_eip712TypedDataPrefix` equals the V2-SC-152 vector). Migration notes above. |
| Static scanning prevents unsafe patterns from returning. | `node scripts/check-encode-packed.mjs` and `node --test test/scripts/check-encode-packed.test.mjs` in the CI `lint` job; synthetic fixtures cover unlisted uses, stale entries, count drift, mislabelled operand types, two-dynamic digests, canonical-scope restrictions, length-prefix validation, context mismatches, guards and off-chain type lists. |
| Required: fuzzed distinct-input / non-equal-digest properties. | `testFuzz_splitPoint_packedCollides_typedSeparates`, `testFuzz_operationId_distinctInputs_distinctDigests`, `testFuzz_upgradeProposalId_distinctVersions_distinctDigests`, `testFuzz_crossSchema_v2OperationIdNeverEqualsV2ProposalId`, `testFuzz_merkleLeaf_distinctInputs_distinctDigests`. |
| Required: cross-tool digest vectors where commitments are consumed off-chain. | `node scripts/check-encode-packed-vectors.mjs` (CI `lint` job) ↔ `contracts/test/EncodePackedCommitmentVectors.sol` ↔ `test/v2/EncodePackedCommitments.t.sol`. |

## Running the checks

```
node scripts/check-encode-packed.mjs            # inventory + classification + anchors
node scripts/check-encode-packed.mjs --report   # detected inventory with fingerprints
node scripts/check-encode-packed-vectors.mjs    # ethers <-> JSON <-> Solidity mirror
node --test test/scripts/check-encode-packed.test.mjs
forge test --match-path "test/v2/EncodePackedCommitments.t.sol"
forge test --match-path "test/v2/SupplyChainAttestationManifest.t.sol"
```

Adding a packed encoding: prefer `abi.encode` with a version tag. If a packed form is genuinely
required (a standard's byte layout, or fixed-width operands only), run `--report`, add an entry with
the fingerprint, operand types and a justification to `scripts/encode-packed-policy.json`, and get
it reviewed.
