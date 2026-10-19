# V2 Revert Taxonomy (V2-SC-073)

## Goal

All V2 modules share one machine-readable custom-error catalog in
`contracts/v2/libraries/V2Errors.sol`. Call sites must not use string
`require`/`revert` reasons or overlapping local `error` declarations that
share a name but differ by ABI.

## Rules

1. **Fail closed** with a typed `V2Errors.*` selector.
2. **Prefer parameters over strings** — encode the distinguishing values
   (`claimId`, `deadline`, balances, rounds) in the error ABI.
3. **One canonical signature per failure mode** — modules import `V2Errors`
   instead of re-declaring `EvidenceNotFound`, `UnsupportedAsset`, etc.
4. **No panics for expected failures** — validation and auth paths revert
   with catalog errors; arithmetic still relies on checked Solidity 0.8.
5. **Governance / evidence / stake / config** map into the domains documented
   in the `V2Errors` NatSpec table.

## Notable migrations

| Prior pattern | Canonical replacement |
| --- | --- |
| `InvalidArgument("same round")` | `InvalidRoundTransfer(fromRound, toRound)` |
| Local `EvidenceWindowClosed()` | `EvidenceWindowClosed(claimId, deadline, timestamp)` |
| Local `DuplicateEvidence()` | `DuplicateEvidence(commitmentKey)` |
| Local V2Lifecycle config errors | Same names under `V2Errors.*` |
| Silent `uint64(block.timestamp)` / `uintN(x)` truncation | `SafeCastOverflow(field, value, max)` via `V2SafeCast` (V2-SC-161) |
| Silent `uint256(int256)` sign flip | `SafeCastNegative(field, value)` via `V2SafeCast` (V2-SC-161) |

## Stake amount errors (V2-SC-018)

`StakeVault.depositStake` validates the amount in this order: zero reverts with
`ZeroAmount()`, then any positive amount below `minStakeAmount` reverts with
`DustStake(provided, minimum)`. Both selectors are canonical entries in
`V2Errors`; callers can distinguish invalid zero input from a positive stake
below the configured per-deposit floor. Other stake mutations reject zero with
`ZeroAmount()` and enforce available-balance bounds with `InsufficientLocked`
or `InsufficientClaimable` rather than applying the deposit floor again. See
[`stake-amount-semantics-v2-sc-018.md`](stake-amount-semantics-v2-sc-018.md).

## Integer-width boundaries (V2-SC-161)

`SafeCastOverflow(bytes32 field, uint256 value, uint256 max)` and
`SafeCastNegative(bytes32 field, int256 value)` identify the violated bound
deterministically: `field` is an ASCII literal such as `"Claims.createdAt"`
(constants in `V2SafeCast`) and `max` is the destination's `type(uintN).max`.
See `docs/v2/safe-cast-integer-boundaries.md` for the full inventory.

## Tests

- `test/v2/V2Errors.t.sol` — selector stability, config fail-closed paths,
  absence of string-reason `InvalidArgument`.
- `test/v2/StakeVault.t.sol` — `InvalidRoundTransfer` on same-round carry-forward.
- `test/v2/SafeCastBoundaries.t.sol` — exact `(field, value, max)` payloads for
  every narrowing width and lifecycle boundary.
