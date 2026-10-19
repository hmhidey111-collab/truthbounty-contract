# V2 Asset Units, Signature Nonces, and Adversarial Token Assurance

Covers V2-SC-079 (#461), V2-SC-080 (#462), V2-SC-087 (#469), and V2-SC-099 (#485).

## Scope and module boundaries

| Item | Surface | Type |
| --- | --- | --- |
| #462 | `contracts/v2/libraries/V2AmountUnits.sol` | Internal library (no storage, no events) |
| #469 | `contracts/v2/SignatureNonces.sol` | Abstract module (inherit to use) |
| #485 | `test/v2/AdversarialERC20.t.sol`, `test/invariant/AdversarialERC20Invariant.t.sol` | Tests only |
| #461 | `test/v2/OptimismFork.t.sol` | Tests only |

`StakeVault` and every other existing contract are unchanged: no storage layout, event, ABI, role, or
configuration-version change.

## Asset units (#462)

- **Custody is always in native base units.** `StakeVault` storage, events (`VaultDeposited`, `VaultLocked`,
  `VaultWithdrawn`, ...), and reconciliation views report the asset's own units (e.g. `1e6` = 1 USDC).
- **Normalized units are 18 decimals** and only for cross-asset comparison or reporting. They are never stored
  as custody.
- `decimalsOf(asset)` fails closed (`UnsupportedDecimals`) for EOAs, missing or reverting `decimals()`,
  malformed return data (not exactly 32 bytes), and values above 36.
- `toNormalized` / `fromNormalized` round down, toward the protocol. Round trips never inflate an amount, and
  overflow reverts with checked arithmetic. Decimals above 36 revert with `DecimalsOutOfRange`.

## Signature nonces (#469)

- Bitmap (unordered) nonces per owner. Independent signatures never block each other.
- `_useCheckedNonce(owner, nonce, deadline)` checks the deadline first (`SignatureExpired`), then consumes the
  nonce (`NonceAlreadyUsed` on reuse) and emits `NonceConsumed`.
- `cancelNonce(nonce)` lets the owner invalidate a signed-but-unsubmitted payload (`NonceCancelled`). It only
  affects `msg.sender`.
- Signed payloads must commit to `(owner, nonce, deadline)` in an EIP-712 struct. The EIP-712 domain
  (chain ID and verifying contract) prevents cross-chain and cross-deployment replay.
- **Integration status:** no canonical V2 contract verifies signatures today. `EvidenceRegistry` uses a
  sequential per-sender nonce for evidence-ID derivation, not for signatures, and is intentionally unchanged.
  Any future V2 signature path must inherit `SignatureNonces` and call `_useCheckedNonce` after signer recovery.

## Supported ERC-20 policy (#485)

Only standard, non-rebasing, non-fee, non-callback ERC-20s with fixed decimals may be enabled with
`setSupportedAsset`.

| Behavior | StakeVault outcome |
| --- | --- |
| Unsupported asset | Reverts `UnsupportedAsset` |
| Fee-on-transfer | Reverts `TransferAmountMismatch` (exact-balance check) |
| Returns `false` | Reverts `SafeERC20FailedOperation` |
| No return data (USDT-style) | Handled by `SafeERC20` |
| Paused / blacklisted | Transfer reverts, and balances stay with the original account |
| Callback / reentrant | Blocked by `nonReentrant`, and the deposit reverts |
| Positive rebase / donation / mint to vault | Not credited, and surplus stays unaccounted |
| Negative rebase | **Unsupported**: holdings fall below obligations |
| Non-18 decimals | Accounted in native units |

Invariants tested (`AdversarialERC20InvariantTest`):

1. `custody == obligations` and `balanceOf(vault) >= custody` for every asset (asset conservation).
2. Per-account claimable and locked balances match an independent ghost model. Custody equals their sum, so
   nothing leaks across accounts and donations are never credited.
3. False-return and callback tokens never enter custody.

## Optimism fork tests (#461)

```bash
OPTIMISM_RPC_URL=<archive-capable OP mainnet RPC> forge test --match-path test/v2/OptimismFork.t.sol
# optional: OPTIMISM_FORK_BLOCK=<block>   (default 125000000)
```

These tests check chain ID 10, the L1Block, GasPriceOracle and WETH predeploys, Ecotone gas rules (non-zero L1 data fee), real
USDC (6 decimals) and WETH (18 decimals), a full USDC deposit → lock → final unlock → withdraw cycle, and a WETH
`depositStake`. Without `OPTIMISM_RPC_URL` every test is skipped, so offline CI is unaffected. The RPC must
serve historical state at the pinned block.

No production `IModuleRegistry` implementation exists yet, so the fork test registers modules through
`MockModuleRegistry`, the same registry the other V2 tests use.

## Migration impact

- Additive only. There are no storage, ABI, event, or deployment-artifact changes to released contracts, and
  active claims are unaffected.
- Integrators that display amounts must read `decimals()` per asset and must not assume 18.
- Governance must not enable rebasing, fee-on-transfer, or callback tokens through `setSupportedAsset`.

## Residual risk

- Asset policy is enforced by governance review, not on-chain. A negative-rebase token enabled by mistake would
  leave the vault holding less than it owes.
- Fee-on-transfer dust whose fee rounds to zero is accepted, because the full amount arrives. This is safe:
  exact-balance accounting still holds.
- Admin actions on the token itself (pause, blacklist, upgrade) can freeze withdrawals. Balances are
  preserved but cannot be withdrawn until the token issuer acts.
- `SignatureNonces` protects nothing until a signature path inherits it.
