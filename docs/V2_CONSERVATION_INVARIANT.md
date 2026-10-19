# V2 Protocol-Wide Asset Conservation Invariant

The canonical V2 custody invariant is:

`actualBalance(asset) = custody(asset) = claimable(asset) + locked(asset) + protocolAllocation(asset)`

This equation is enforced by the canonical vault in `contracts/v2/StakeVault.sol` and is exposed through the `reconcile()` and `conservation()` views.

## Canonical accounting buckets

- `claimable(asset)`: user-claimable withdrawals, unlocked and not escrowed.
- $locked(asset)`: all categorized lock cells for principal, challenge bonds, settlement allocations, etc.
- `protocolAllocation(asset)`: slashed or protocol-owned value moved out of a lock but still held in custody.
- `custody(asset)`: the full tracked amount that the vault is responsible for, matching the accounting sum above.
- `actualBalance(asset)`: the live ERC20 balance of the vault for that asset.

## Tracked custody components

Tracked custody is the sum of exactly these components, each accrued once and never double-counted:

- `trackedPrincipal(asset)`: principal deposited by users that remains in custody.
- `rewards(asset)`: accrued rewards not yet claimed.
- $fees(asset)`: fees collected and held in custody.
- `donations(asset)`: voluntary inflows attributed to the protocol.
- `protocolAllocation(asset)`: value moved out of a lock but still in custody.

The authoritative reconciliation is:

`actualBalance(asset) == trackedPrincipal(asset) + rewards(asset) + fees(asset) + donations(asset) + protocolAllocation(asset)
`

The bucket views `claimable()` and `locked()` are derived from these components and must not be added on top of them.

## Unexplained deltas

Any positive token delta not reflected in the component totals is an unexplained delta. The vault rejects unexplained balance drift, fee-on-transfer mismatches, and unsupported-asset accounting drift by reverting on every accounting boundary.

When an unexplained delta is detected, the vault must either revert with `ConservationInvariantViolation` or enter the governed recovery path defined by the authority model. The governed recovery path attributes the delta to a named component only through an authorized governance action and never silently absorbs it into an existing bucket.

## Rounding and dust policy

- Burns, fee-on-transfer hooks, rebasing tokens, and token-dependent rounding are rejected by design.
- Zero-value dust is treated as a stranded-but-zero state only when the tracked component totals are exactly zero.
- Any nonzero residual balance that is not represented in trackedPrincipal, rewards, fees, donations, or protocolAllocation is treated as a protocol invariant violation.

## Error payloads

When the invariant is violated, the vault reverts with `ConservationInvariantViolation` carrying the asset address, the expected total, and the actual balance. The payload must report non-duplicated values: the expected total is the sum of the components and must not include the actual balance, and the actual balance must not be added into the component total.

## Source of truth

The canonical authority remains the vault's ERC20 balance plus its typed lock and allocation accounting; no backend, indexer, guardian, or test harness is permitted to mutate protocol custody. Expected values are derived from this authoritative source and must not be adjusted to match broken output.