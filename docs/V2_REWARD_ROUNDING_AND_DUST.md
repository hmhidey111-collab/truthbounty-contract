# V2 Reward Allocation Rounding and Dust Ownership (V2-SC-096)

Conservation invariants for staking, reward funding, claiming, slashing, refunds, and withdrawals, plus the rounding and dust ownership rules that make them hold.

Reward allocation splits one funded amount across several accounts by effective weight. Integer division truncates, so the split is almost never exact. This document specifies which way every division rounds and who owns what truncation leaves behind.

Enforced by `contracts/v2/FinalRewardAllocator.sol`. Tested by `test/v2/RewardAllocationRounding.t.sol` and the stateful invariant suite in `test/v2/ConservationInvariants.t.sol`.

## The two rules

**1. Every per-recipient share rounds down.**

```
share(i) = floor(amount * effectiveWeight(i) / totalWeight)
```

Down is the only safe direction for a payout. Each recipient is credited no more than their exact pro-rata entitlement, so the shares can only ever sum to at most `amount`. Rounding up would let the sum of shares exceed the pool that funded them.

**2. The shortfall is credited to an explicit remainder recipient.**

```
internal settlement invariant:
remainder = amount - sum(share(i))
credited(remainderRecipient) += remainder
```

Therefore, for every allocation category:

```
sum(credited) == allocation.amount     exactly
remainder      < allocation.accounts.length
```

Dust is never stranded in the allocator and never silently absorbed.

## Why the remainder recipient is a parameter

Deciding who receives dust is an allocation-policy question, not an arithmetic one. The settlement module supplies `remainderRecipient` per category, and a zero address is rejected (`InvalidRemainderRecipient`). There is no implicit fallback — no "dust goes to the treasury by default", because a silent default is how dust ownership stops being reviewable.

Authority to select a remainder recipient is bounded to the registered `SEDTLEMENT` module. If the registry is missing, ambiguous, or points at an unrecognized module, funding and finalization fail closed rather than falling back to a default owner.

The remainder recipient may also be one of the weighted accounts. In that case the dust is credited *on top of* their share.

## Rounding direction by category

All five `RewardCategory` values use the same rule. Rounding direction is a property of the operation, not of the category:

| Category | Share rounding | Dust |
| --- | --- | --- |
| `SUBMITTER_REFUND` | down | to `remainderRecipient` |
| `SUCCESSFUL_CHALLENGE` | down | to `remainderRecipient` |
| `VERIFIER_REWARD` | down | to `remainderRecipient` |
| `PROTOCOL_FEE` | down | to `remainderRecipient` |
| `INCONCLUSIVE_REFUND` | down | to `remainderRecipient` |

Each category carries its own `remainderRecipient`, so a single settlement can route verifier dust and protocol-fee dust to different owners. A category may appear at most once per settlement (`DuplicateCategory`).

## Decimals

The allocator works exclusively in an asset's base units and never reads `decimals()`. Rounding is therefore identical at every supported decimals value, across the full `V2AmountUnits.MAX_ASSET_DECIMALS` range of 0 to 36. This is asserted directly rather than assumed: `test_roundingIsIndependentOfAssetDecimals` runs the same base-unit split at 0, 2, 6, 8, 18 and 36 decimals and requires identical output.

Normalization to 18-decimal units (`V2AmountUnits`) is a reporting and cross-asset-comparison concern. It is not used in allocation, so it cannot introduce a second rounding step into a payout.

## Arithmetic

Shares are computed with `V2Precision.mulDivDown` (V2-SC-100), which evaluates `a * b / d` over a 512-bit intermediate. The previous inline form multiplied before dividing:

```solidity
uint256 share = allocation.amount * allocation.effectiveWeights[i] / totalWeight;
```

With a large amount and large effective weights that product exceeds 2^256 and the settlement reverts even though the result is representable. `test_largeAmountTimesLargeWeightDoesNotOverflow` is the regression test for it.

`totalWeight` cannot be zero: every effective weight is rejected at zero (`ZeroEffectiveWeight`) and at least one account is required.

## Conservation invariants

Every operation that moves value across the contract boundary preserves a single accounting identity. Let `Accounted` denote the sum of all per-account ledger balances (staked, locked, claimable, refundable, and protocol-owned) for a given asset.

**Invariant C1. Balance reconciliation.** After every state transition,

```
Accounted == asset.balanceOf(address(this)) - excludedBalance
```

where `excludedBalance` is zero for supported tokens. No value is stranded, duplicated, or unaccounted.

**Invariant C2. No over-claim.** For every participant and asset, cumulative claims and withdrawals never exceed the cumulative amount authorized to that participant by deposits, reward funding, refunds, and slash distribution.

```
claimed(i, a) + withdrawn(i, a) <= authorized(i, a)
```

**Invariant C3. Slash conservation.** A slash debits the slashed stake and credits the same total to the designated recipients (including protocol-owned shares). For each slash of amount `s`:

```
sum(creditedToRecipients) == s
slashedStake(i) -= s
Accounted -= s
```

Slashing never destroys value and never creates it.

**Invariant C4. Reward funding and claim.** Funding increases the pool by exactly the transferred amount (for supported tokens); claiming decreases the pool and the claimant's claimable by the same amount.

```
pool(a) += funded(a)
claimable(i, a) -= paid
claimed(i, a) += paid
pool(a) -= paid
```

**Invariant C5. Refund and withdrawal.** A refund moves value from the settlement pool to the refundee without changing total accounted value. A withdrawal of unlocked stake decreases both the participant's stake and the contract balance by the same amount.

**Invariant C6. Concurrent claims and verifications.** Claims and verifications are serialized by the EVM. For any interleaving of claims, verifications, slashes, and refunds, C1 through C5 hold after every transaction. A claim that would drive `claimable` below zero reverts (`InsufficientClaimable`) rather than consuming another participant's entitlement.

## Rounding policy (explicit and bounded)

Rounding is confined to the allocation step described above. The policy is:

- **Round down** on every per-recipient share.
- **Remainder** credited to the explicit `remainderRecipient` for that category
- **Bound**: for each category, `remainder < numberOfAccounts`, so the absolute rounding error is bounded by the account count in base units
- **No second rounding**: no decimal normalization is applied in the payout path

The stateful invariant suite fuzzes zero, minimum, maximum, and rounding-boundary amounts and requires C1 through C6 after every generated sequence.

## Unsupported tokens

Fee-on-transfer, rebasing, and other non-standard tokens are rejected. The contract measures the received delta on funding and requires it to equal the requested amount; a shortfall or excess fails closed. Rebasing tokens are excluded because their balance can change without a transfer, which would break C1. The excluded token set is explicit and enforced at the registry boundary.

## Security rules

- Shares round down; no operation in an allocation path rounds up.
- `sum(credited) == allocation.amount` for every category, with no exception for empty or vanishing shares.
- A weight too small to earn one base unit is credited nothing. The value is not lost — it falls into the remainder and stays owned.
- Funding is tracked per settlement id, so one settlement can never allocate against another's pool (`PoolExceeded`).
- Only the registered `SEDTLEMENT` module may fund or finalize. Re-pointing the registry revokes the previous module immediately.
- Missing or ambiguous authority fails closed; there is no implicit fallback owner.
- Finalization is single-shot per settlement id (`SettlementAlreadyFinalized`).
- Claiming is pull-based and bounded by the credited entitlement (`InsufficientClaimable`).
- No storage layout, role, pause, upgrade, or economic change is inferred from legacy contracts; the V2 topology and Optimism/EVM runtime are preserved.

## Source of truth

The allocator's `claimable(asset, account)` ledger is authoritative for entitlements. Reward events are a projection of it and carry no authority; no indexer, backend, or harness may mutate an entitlement.

Evidence for this document is generated from pinned artifacts at exact commits. 
