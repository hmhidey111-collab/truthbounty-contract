# Canonical EIP-712 signing surface (V2-SC-152)

Every signed protocol operation must be reproducible across Solidity, ethers, viem, and hardware/contract-wallet tooling. This document is the human-readable half of that contract; the machine-readable half is

* `test/vectors/eip712-verifier.vectors.json` — canonical domain, type hashes, struct hashes, digests, and failure cases.
* `contracts/test/EIP712CanonicalVectors.sol` — the Solidity mirror of that JSON, generated from it and never hand-edited.
* `scripts/check-eip712-vectors.mjs` — the drift check that keeps the JSON, the mirror, the implementations, and ethers in sync.

Nothing in this repository stores a private key or a live signature. Tests derive signature material at runtime from the publicly documented Hardhat test key `0xac0974…ff80` (`vm.sign` in Foundry, `wallet.signTypedData` in ethers); production keys must never appear in a vector, a test, or a script.

## Implementations in scope

The same EIP-712 surface exists in two files today. Both declare identical domain/struct type strings and field order, and both are covered by the drift check:

* `contracts/EIP712Verifier.sol` — contract `EIP712Verifier`.
* `contracts/decay.sol` — contract `EIP712Verifier`.

## Domain

| Field | Value |
| --- | --- |
| `name` | `TruthBounty` |
| `version` | `1` |
| `chainId` | live `block.chainid`, never cached |
| `verifyingContract` | live `address(this)`, never cached |
| domain type string | `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` |
| domain type hash | `0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f` |
| `keccak256("TruthBounty")` | `0x2fa99e49f5b52f9531f70c914e05e3b21b20a47ed8412a97840d11b17c33037e` |
| `keccak256("1")` | `0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6` |

## Structs, type hashes, and field order

Field order is part of the signed encoding: `abi.encode(typeHash, field1, …, fieldN)` in declaration order.

| Struct | Type string | Type hash |
| --- | --- | --- |
| `ClaimSubmission` | `ClaimSubmission(address claimant,uint256 bountyId,bytes32 contentHash,uint256 nonce,uint256 deadline)` | `0x583cd3a93ae50e2578ccd80e1f370aebc93e9e7f97bd0e38d39e542213b6e927` |
| `VerificationIntent` | `VerificationIntent(address verifier,uint256 bountyId,bool approve,string reason,uint256 nonce,uint256 deadline)` | `0xc5a057e833163fcd0c5e1783fe90adfb24b27445ca62299745fbddb51869fd69` |

| Entry point | Hash helper |
| --- | --- |
| `ClaimSubmission` | `EIP712Verifier.verifyClaimSubmission / EIP712Verifier.getClaimSubmissionHash` |
| `VerificationIntent` | `EIP712Verifier.verifyVerificationIntent / EIP712Verifier.getVerificationIntentHash` |

## Chain ID semantics

`_buildDomainSeparator()` reads `block.chainid` on every call and never caches the separator, so a signature produced on one chain cannot be replayed on another chain that shares the same genesis. The published separators are:

| Chain | Chain ID | Domain separator |
| --- | --- | --- |
| mainnet | 1 | `0x3eb1639b71106693914d735157d11474bfdb60ffd5b896fb8311b7a8c9998b11` |
| local/test | 31337 | `0x50a672b15211d46ac48525c21fd2b336612308d62a2fcf5aeaffcfea87bce188` |

Changing the domain separator is a breaking change for every off-chain signer: publish new vectors before shipping it.

## Verifying contract semantics

`address(this)` is taken live, so the same struct signed for one deployment is invalid for another. The canonical vectors use `0x5FbDB2315678afecb367f032d93F642f64180aa3`; the drift check pins a second address (`0x000000000000000000000000000000000000bEEF`) to prove the digest changes with the deployment.

## Version semantics

`version` is fixed at `1` and is covered by `VERSION_HASH` inside the separator. A semantic change to any struct or to the verification flow requires a version bump plus a new vector set — never a silent edit of the type strings.

## Nonce semantics

nonces[account] starts at 0, is embedded in the struct hash, and increments by exactly 1 on every successful verification; a digest can never be used twice (usedSignatures).

## Deadline semantics

verifyClaimSubmission/verifyVerificationIntent revert with SignatureExpired when block.timestamp > deadline; a signature valid at deadline is accepted (inclusive bound).

The canonical deadline used by the vectors is `4102444800` (2100-01-01T00:00:00Z), so no test ever has to move the chain clock backwards.

## Positive vectors

| Case | Operation | Chain | Struct hash | Digest |
| --- | --- | --- | --- | --- |
| `claim-submission-mainnet` | `claimSubmission` | 1 | `0xc6398127fdbb4a3bd776eb683a6569078a2cfd1eb0bac2b44714d05a733ee96c` | `0xbb5a29bd1e537284bc2631d86375fd606d16aaf7bb45144fd39eeea665a8cdb7` |
| `claim-submission-local` | `claimSubmission` | 31337 | `0x17a0828b8159f7e3fcd9e6e9ac42695948f679c0ea3ff30394ec9bdd5021e2c8` | `0x3624b82c760989324db7d91cb30762b0c3dc60f7ec1ecf9b23b864d2ac2e12e3` |
| `verification-intent-mainnet` | `verificationIntent` | 1 | `0x815f537bcffdc44868a823f6bd959fe11b90e1641d0c5dc661b85847583fa4f5` | `0xc24ae15f7579d0e5dac930fa987581be9895f8648630859ed87edc617f2f498a` |
| `verification-intent-local` | `verificationIntent` | 31337 | `0x664ef87190c6c36a5f13dcec98307ee0eacd91d28f94f273735f6c4a9c3b31ed` | `0x4cb2cda7f6326bad39f733145e9ccec0ffcdaae4b5e8089d3a41c4a68bfb6db6` |

## Negative vectors

| Case | Mutation | Mutated value | Digest | Must differ from |
| --- | --- | --- | --- | --- |
| `claim-wrong-chain-id` | `chainId` | `10` | `0x29a07b0cb851e735e1b24eff7b0c28c10fbddb76740339ed9dd6c98d876bd067` | `claim-submission-mainnet` |
| `claim-wrong-verifying-contract` | `verifyingContract` | `0x000000000000000000000000000000000000bEEF` | `0x4f19d2936b9d635fc6071bf5ab59f2a3cac27da622a49382fec685f040ad9db8` | `claim-submission-mainnet` |
| `claim-wrong-domain-name` | `domainName` | `TruthBountyV2` | `0x1f8f2d5d044080f9d17ca414195c6164c4cadaac01c7123ee08fd35b5f66c9f3` | `claim-submission-mainnet` |
| `claim-wrong-nonce` | `nonce` | `8` | `0x29e682d8a3a1700dda7c3b1e8a1c1567b2d0a1a4f3a126cacdaa87e99d8d33d6` | `claim-submission-mainnet` |
| `claim-wrong-deadline` | `deadline` | `4102444801` | `0xf2a3dcb9373cc48266a7102813180a56308a019d36ddb6db309684919ee03f8d` | `claim-submission-mainnet` |
| `claim-mutated-field-order` | `fieldOrder` | `claimant<->bountyId` | `0x24506cb83fd05e41be9f0a7d73dda470e2578c9bcb7f0f4b230a67d5256c57b5` | `claim-submission-mainnet` |
| `claim-mutated-type-string` | `typeString` | `ClaimSubmission(address claimant,uint256 bountyId,bytes32 contentHash,uint8 nonce,uint256 deadline)` | `0x019d904b3f6ec16bfa522cd00d39396a635bd2ede8e7b93a4091e6350c340cfd` | `claim-submission-mainnet` |
| `intent-wrong-approve-flag` | `approve` | `false` | `0x1098e444df7fe0aabe800043494864ccaf11210a27bf36a24d22f6080cfd7090` | `verification-intent-mainnet` |
| `intent-wrong-reason` | `reason` | `evidence verified ` | `0x862028ada5fec6673a96453d38d7735b6a5937d0983e3d028536132f2edb663e` | `verification-intent-mainnet` |
| `claim-expired-deadline` | `deadlineExpired` | `block.timestamp > deadline` | `0xbb5a29bd1e537284bc2631d86375fd606d16aaf7bb45144fd39eeea665a8cdb7` | equals the positive digest; reverts `SignatureExpired` |

## Tooling

| Task | Command |
| --- | --- |
| Check vectors, mirror, and implementations (CI) | `node scripts/check-eip712-vectors.mjs` |
| Deterministically regenerate JSON and Solidity mirror | `node scripts/check-eip712-vectors.mjs --emit` |
| Drift-failure self-tests | `node --test test/scripts/check-eip712-vectors.test.mjs` |
| On-chain positive/negative vectors and signatures | `forge test --match-path 'test/v2/EIP712CanonicalVectors.t.sol' -vvv` |
| Solidity ↔ ethers parity and on-chain signatures | `npx hardhat test test/EIP712CanonicalVectors.test.ts` |

CI runs the first three commands in the `lint` job, so a stale vector, a stale mirror constant, or an
implementation whose type string drifted fails the pull request with the expected/found diff.

## Changing a signed operation

1. Update the type string in every implementation listed above.
2. Review the canonical inputs in `scripts/check-eip712-vectors.mjs`; `VERIFICATION_INTENT_TYPE_STRING` defines the JavaScript field list and its hash. Both Solidity declarations must agree before emission is allowed.
3. Run `node scripts/check-eip712-vectors.mjs --emit` and commit both generated artifacts. This also regenerates numeric constants such as nonce and deadline; never repair them by hand.
4. Run `node scripts/check-eip712-vectors.mjs`, `node --test test/scripts/check-eip712-vectors.test.mjs`, the Foundry vector test, and the Hardhat parity test.

A missing vector, a stale mirror constant, or an implementation whose type string no longer matches the JSON fails CI with the expected/found diff for that exact constant, so drift cannot land silently.

## Verification-intent restoration (#689)

`VERIFICATION_INTENT_TYPE_STRING` is the canonical tooling definition. The production
contracts retain their existing `VERIFICATION_INTENT_TYPEHASH` getters and signing
format; the checker validates the actual `keccak256` declarations in both files,
ignoring comments. No production ABI, storage, domain or authorization behavior changes.
The JSON, generated Solidity mirror, and documentation row must match that definition.

In addition to approve/reason mutations, the vector registry now includes intent-specific
chain ID, verifying contract, domain name, field order, nonce, deadline and expired-deadline
cases. `test_VerificationIntentMutationMatrix` requires `InvalidSignature` for each
signed-payload mutation and verifies that rejected attempts do not consume the nonce.
The separate deadline test requires `SignatureExpired` after the bound and accepts the
same signature exactly at the bound. Replay with an already-consumed nonce fails with
`InvalidSignature`: the contract rebuilds the digest with the current nonce before recovery.

The Node self-tests regenerate in two independent fresh temporary trees, compare both
outputs byte-for-byte (normalizing only checkout CRLF to LF), and run the full drift check.
For an additional clean Git-tree check after committing reviewed inputs:

```sh
node scripts/check-eip712-vectors.mjs --emit
git diff --exit-code -- test/vectors/eip712-verifier.vectors.json contracts/test/EIP712CanonicalVectors.sol
node scripts/check-eip712-vectors.mjs --emit
git diff --exit-code -- test/vectors/eip712-verifier.vectors.json contracts/test/EIP712CanonicalVectors.sol
node --test test/scripts/check-eip712-vectors.test.mjs
```

Restoration toolchain: Node 24.21.0, npm 11.19.0, ethers 6.17.0, Hardhat 3.16.0,
Foundry 1.8.3 (`cae51ad458f6abb64852b7709eb784352429825d`), Solidity 0.8.28,
optimizer 200 runs, via IR, Cancun EVM. Use `npm ci` and the pinned submodule revisions;
do not regenerate with the separately installed `solc` npm package (0.8.37).
