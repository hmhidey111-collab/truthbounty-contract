# V2 Final Reward Allocator

`FinalRewardAllocator` is the V2 pull-based entitlement ledger for finalized
settlements. The registered `SETTLEMENT` module is the only address allowed to
fund a pool or finalize an allocation. Users can only claim their own recorded
balance.

## Allocation model

Each settlement is finalized once with a stored `FinalOutcome` and zero or more
category records:

- submitter refunds
- successful-challenge rewards
- verifier rewards
- protocol fees
- inconclusive refunds

Every category supplies frozen effective weights. Each account receives
`amount * weight / totalWeight`; integer remainder is credited to the explicit
`remainderRecipient`. The category record is rejected when its amount exceeds
the funds tagged to that settlement. Duplicate categories are rejected.

## Security and migration

The contract retains no push-payout or backend settlement authority. It does
not reuse the legacy `RewardEngine` or the permissive V2 `IRewards.accrue`
surface, both of which accept caller-supplied reward amounts. Existing vault
settlement hooks remain reusable for principal transitions, but reward
entitlements use this dedicated ledger so one finalization cannot consume
another account's or settlement's pool.

Finalization performs at most five category iterations, with a configurable
recipient limit per category. Storage grows with funded settlements and
claimable accounts; claims are pull-based and idempotent by balance decrement.
No withdrawals are executed by the allocator beyond a caller's explicit claim.

The deployment must register the deployed allocator under the canonical
`SETTLEMENT` module identity and fund it from the settlement module before
calling `finalizeRewards`. The existing legacy `Rewards.ts` deployment is not a
compatible migration path and should remain deprecated for V2.