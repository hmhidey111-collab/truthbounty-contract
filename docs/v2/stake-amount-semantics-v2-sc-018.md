# Stake Amount Semantics (V2-SC-018)

## Canonical rules

`StakeVault.depositStake(claimId, amount)` applies the configured
`minStakeAmount` to each new verifier-principal deposit, in the ERC-20's raw
integer base units. It does not infer decimal precision or round amounts.
Validation is ordered so `amount == 0` returns `V2Errors.ZeroAmount()` and a
positive `amount < minStakeAmount` returns
`V2Errors.DustStake(amount, minStakeAmount)`. The exact minimum and larger
integer amounts are accepted, subject to token transfer and accounting checks.

The minimum is an entry floor, not a minimum balance invariant. A later partial
release, slash, settlement, or appeal transfer can leave a positive position
below the floor. Those paths preserve the requested integer amount exactly and
must not round it up, reject it as dust, or silently discard a remainder.

## Operation contract

| Operation | Zero input | Positive amount below `minStakeAmount` | Balance boundary |
| --- | --- | --- | --- |
| `depositStake` | `ZeroAmount()` | `DustStake(provided, minimum)` | Exact token receipt required; lock is created only after transfer succeeds |
| Generic `deposit` | `ZeroAmount()` | Accepted; it credits claimable funds and does not create verifier stake | Exact token receipt required |
| `lock` / `unlock` | `ZeroAmount()` | Accepted for any positive amount | Insufficient source balance reverts with the corresponding typed error |
| `releaseStake` / `slashStake` | `ZeroAmount()` | Accepted for any positive amount | Cannot exceed the verifier's locked principal |
| `carryForwardAppeal` | `ZeroAmount()` | Accepted for any positive amount | Must move to a later round and cannot exceed the source lock |
| Reconciliation | Not applicable (view) | Not applicable (view) | `reconcile(asset)` reports custody and obligations; state-changing paths assert equality |

Failed zero, dust, or over-balance operations leave custody, locks, stake
aggregates, and claimable balances unchanged. Reconciliation remains exact
across successful deposit/release and slash/carry-forward transitions; integer
remainders stay assigned to the same account or protocol allocation as the
operation specifies.

## Regression coverage

`test/v2/StakeVault.t.sol` covers zero rejection, the `minimum - 1`, exact
minimum, and `minimum + 1` boundaries, and verifies a rejected dust deposit
does not alter custody or stake. Zero-input regressions cover deposit, release,
slash, and appeal carry-forward. Its existing release/slash tests cover
over-unlock and over-slash bounds. `test/v2/StakeVaultInvariant.t.sol` exercises
round-trip stake transitions and asserts custody reconciliation. Amounts are
integers in token base units; no floating-point or decimal conversion is used.
