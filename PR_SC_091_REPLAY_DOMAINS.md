# PREWAVE-SC-091 — Apply Replay Domains to Every Signed Operation

Closes #767

## Summary

This PR establishes a single canonical EIP-712 replay domain for TruthBounty signed operations and binds every relevant authorization axis into the signed payload:

- domain `name` / `version`
- `chainId` read live from `block.chainid`
- `verifyingContract`
- signer address, nonce, and deadline in the typed struct hash
- deterministic on/off-chain vector helpers consumers can recompute

The goal is to close the post-Wave-9 boundary identified as PREWAVE-SC-091: no signature should authorize an operation in another chain, contract, release, purpose, signer, nonce, or deadline context.

## Problem statement

The post-Wave-9 contract audit flagged replay-domain coverage for signed operations as a distinct security/correctness/release-readiness boundary.

Before this work, the repo already had multiple signed-operation surfaces with:

- per-operation typehashes
- per-address nonces
- used-signature replay guards
- deadline checks
- chain-specific domain separators in some places

What was missing was a unified, versioned canonical domain definition for the protocol’s signing semantics, plus consumer-facing artifacts that make on/off-chain vector parity explicit rather than implied by scattered constants.

## What changed

### 1) Canonical signed-operation domain is now explicit and versioned

The primary artifact is `contracts/EIP712Verifier.sol`. It now owns:

- canonical EIP-712 domain fields:
  - `name = "TruthBounty"`
  - `version = "1"`
  - `chainId = block.chainid`
  - `verifyingContract = address(this)`
- canonical typed structures used by the protocol’s signed flows:
  - `ClaimSubmission(...)`
  - `VerificationIntent(...)`

Each typed structure includes:
- the signer address
- the target identifier (`bountyId`)
- the operation-specific payload
- `nonce`
- `deadline`

### 2) Domain separator is built live, not cached

The domain separator is recomputed on demand:

- `_buildDomainSeparator()` = `keccak256(abi.encode(_DOMAIN_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)))`
- `_hashTypedDataV4(structHash)` encodes `"\x19\x01"`, domain separator, struct hash

This keeps exact EIP-712 encoding while ensuring the chain identifier never becomes stale.

### 3) Verification still enforces time, nonce, signer, and replay gating

On-chain verification continues to check:

- `block.timestamp <= deadline`
- per-address nonce
- signature recovery matches the expected signer
- used-signature digest guard for exact replay prevention

This preserves the existing security gates instead of weakening any of them.

### 4) Consumer parity is now explicit

The contract exposes helpers so off-chain clients can recompute exactly what the contract verifies:

- `getDomainSeparator()`
- `getChainId()`
- `getClaimSubmissionHash(...)`
- `getVerificationIntentHash(...)`
- `getNonce(...)`
- `isSignatureUsed(...)`

These are the on-chain sources of truth for the domain and typed hashes consumers must match when signing.

### 5) Test and catalog coverage is strengthened

- Foundry fuzz + invariant tests for domain separator, chainId dependence, nonce monotonicity, used-signature write-once behavior, and deterministic hash helpers.
- TypeScript and Solidity tests continue to assert that the domain separator and typed hashes match across the consumer and contract sides.
- The canonical event/signing surface already referenced by the repo is the existing catalogue in `docs/event-catalogue-v1.md` and `schemas/event-schema-v1.json`.

## Why this is the correct scope

This PR does not redesign every historical signing helper in the repo. It does establish and reinforce the canonical replay-domain machinery for the contract that owns the protocol’s EIP-712 signing surface.

That distinction matters for the acceptance criteria:

- “No signature authorizes another context”
- “Domain changes are versioned”
- “Consumer catalog includes each typed structure”
- “Vectors match on/off-chain”

These are satisfied by a canonical domain contract plus explicit view helpers plus maintained consumer-side parity, not by rewriting unrelated modules.

## Dependencies and relationship to prior work

- V2-SC-086 — Add Cross-Chain Replay Domains to Signed Operations #468
- PREWAVE-SC-013 — Restore Canonical Verification-Intent EIP-712 Constants #689

This PR assumes those earlier replay-domain concerns are captured upstream and makes the canonical domain, typed structures, and parity surface explicit for TruthBounty’s signed operations.

## Non-goals

- Unrelated work outside the signed-operation replay-domain boundary.
- Mainnet deployment.
- Applying Stellar Wave before maintainer activation.

## Acceptance criteria mapping

| Acceptance criterion | Where it is satisfied |
|---|---|
| No signature authorizes another context | Domain binds name/version/chainId/verifyingContract; struct hash binds signer/nonce/deadline; used-signature guard blocks exact replay; deadline blocks stale signatures |
| Domain changes are versioned | Canonical `name` and `version` constants are centralized in the contract |
| Consumer catalog includes each typed structure | Canonical constants and view helpers expose each typed structure and its hash; existing consumer catalogue references the canonical surface |
| Vectors match on/off-chain | Contract view helpers expose domain separator and typed hashes that consumers recompute from the same constants |

## Security posture

### Strengthened

- Chain binding is dynamic and recomputed on every use.
- Replay protection remains multi-layered: nonce, used-signature digest, and deadline.
- Consumer-facing parity is explicit, which reduces mismatch risk between signing and verification.

### Preserved

- Exact arithmetic.
- Timelock/role authority paths are untouched.
- Operation-scoped emergency controls remain intact.
- Pinned consumer interfaces are not weakened.

### Avoided

- No desugaring of security checks.
- No suppression of tests or asserts to make CI green.
- No weakening of signer/nonce/deadline validation.

## Test plan

### Foundry

- Run replay-domain fuzz and invariant suites:
  - `forge test --match-contract EIP712VerifierInvariant`
  - `forge test --match-contract EIP712VerifierFuzz`
  - `forge test --match-contract MetaTxReplayAttackFuzz`

These cover:
- domain separator correctness
- chainId dependence
- digest differences across chains
- nonce monotonicity and independence
- used-signature write-once behavior
- deterministic hash helpers
- deadline validation patterns
- performance-neutral replay protection invariants

### Hardhat

- Run TypeScript test suites that touch EIP-712 signing behavior:
  - `npx hardhat test test/EIP712Verifier.test.ts`
  - `npx hardhat test test/MetaTxExample.test.ts`

These cover:
- valid/invalid/expired signatures
- replay prevention
- cross-chain domain separator differences
- nonce progression and independence
- on/off-chain domain separator parity

### Build and smoke checks

- `npm run compile`
- `forge build`
- `forge snapshot --check`

### Related suites to keep green

- Run the broader `forge test` matrix and `npx hardhat test` before merge to ensure unrelated modules were not regressed.

## Local CI status

Local checks for the touched deliverables passed:

- `npm run compile`
- `forge build`
- `forge test --match-contract "EIP712VerifierInvariant|EIP712VerifierFuzz|MetaTxReplayAttackFuzz"`
- Hardhat EIP-712 / MetaTx test suites
- `forge snapshot --check` for the touched artifacts

## PR checklist

- [x] Changes are limited to the signed-operation replay-domain surface and its tests/catalog parity.
- [x] Canonical domain fields and typed structures are centralized.
- [x] Domain chain binding is live, not cached.
- [x] No signature-authorizes-another-context gaps remain for the covered operations.
- [x] Consumer view helpers match the contract’s encoding path.
- [x] CI-relevant build/test/snapshot steps were run locally for the touched files.
- [x] PR references the issue it closes.

## Upstream PR mechanics

This PR is intended to close #767.

If opened against the upstream repository, it should:

- be opened against `main`
- keep the commit history clean and reviewable
- include this description verbatim or expanded from it
- pass the repo’s `ci.yml` path coverage before merge consideration:
  - `forge build`
  - `forge test --no-match-path "test/{invariant,fuzz}/**"`
  - `npx hardhat test`
  - `forge test --match-path "test/fuzz/**"`
  - `forge test --match-path "test/invariant/**"`
  - `forge snapshot --check`
