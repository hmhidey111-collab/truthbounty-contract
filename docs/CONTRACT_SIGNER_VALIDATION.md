# Contract-Signer Validation

Canonical typed operations use the ECDSA path for externally owned accounts and
the ERC-1271 path for deployed contract signers.

| Operation | Contract signer | Validation |
| --- | --- | --- |
| `EIP712Verifier.verifyClaimSubmission` | Permitted | ECDSA for EOAs; bounded ERC-1271 for contract claimants |
| `EIP712Verifier.verifyVerificationIntent` | Permitted | ECDSA for EOAs; bounded ERC-1271 for contract verifiers |
| `MetaTxExample.executeTransfer` | Permitted | ECDSA for EOAs; bounded ERC-1271 for contract `from` accounts |
| `contracts/v2/SignatureNonces` consumers | EOA-only by default | The consuming operation must explicitly add ERC-1271 validation if its specification permits contract signers |

ERC-1271 validation requires deployed code, the canonical `0x1626ba7e` magic
value with exactly canonical ABI return data, and a successful `staticcall`.
Validation is capped at 50,000 gas and rejects recursive validation through the
validating contract. Signature expiry, nonce consumption, and digest replay
checks happen independently and are unchanged.