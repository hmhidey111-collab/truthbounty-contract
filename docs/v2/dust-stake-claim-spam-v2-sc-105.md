# V2-SC-105 — Dust Stakes and Claim Spam Griefing

## Objective

Prevent storage, computation, settlement, and indexer griefing caused by minimum-value stakes, dust bounties, and unbounded claim creation.

## Threat model (scoped)

| Vector | Impact | Mitigation |
| --- | --- | --- |
| Dust verifier stakes (`amount → 1`) | Inflates stake maps, settlement loops, and indexer rows while economic weight stays negligible | `StakeVault.minStakeAmount` + `AntiGriefing.requireMinAmount` on `depositStake` |
| Free / dust claim spam | Unbounded `_claims` growth, evidence fan-out, and parameter-version linkage churn | `Claims` rate window, open-claim cap, min bounty, submission fee |
| Legacy sequential `ClaimRegistry.createClaim` spam | Same storage/indexer pressure on the shared registry | Per-account sliding window + open-claim inventory caps |

## Authoritative behavior

1. **Stake floor** — `StakeVault.depositStake` reverts with `V2Errors.DustStake` when `amount < minStakeAmount`. Default floor is `1 ether` (aligned with `ParameterVersionRegistry` genesis `minStakeAmount`). Governance may raise/lower via `setMinStakeAmount`, but never to zero.
2. **Claim economic floor** — Canonical V2 `Claims.createClaim` rejects `reward < minBounty`, pulls `reward + claimSubmissionFee` from the claimant, forwards the fee to `feeRecipient`, and escrows the bounty.
3. **Claim spam window** — At most `MAX_CLAIMS_PER_ACCOUNT_WINDOW` (default 10) creations per `CLAIM_SPAM_WINDOW_SECONDS` (default 1 hour) per account.
4. **Open-claim inventory** — At most `MAX_OPEN_CLAIMS_PER_CREATOR` (default 25) non-terminal claims per account. Capacity frees on cancel/finalize.
5. **Legacy registry** — `ClaimRegistry.createClaim` applies the same window / open-claim caps and links the claim via `parameterVersionRegistry.recordClaimCreation`.

Constants live in `ProtocolExecutionBounds` and are catalogued in `LoopBoundsCatalog` for audit projection.

## Module boundaries

- Optimism/EVM contracts remain authoritative for mutation and settlement.
- `Claims` and `StakeVault` never grant API, indexer, guardian, or frontend settlement authority.
- Fees are pull-transferred to a configured recipient; no fail-open fee skip when `claimSubmissionFee > 0`.
- Active-claim parameters stay immutable after creation; anti-grief knobs are governance-timelocked off-module via admin roles.

## Migration / compatibility

- Existing Foundry `StakeVault` suites use `STAKE = 100 ether`, above the default floor.
- Hardhat `ClaimRegistry` suites create a handful of claims per account — within default spam caps.
- Deployments that previously allowed 1-wei stakes must set `minStakeAmount` explicitly if a lower floor is intentionally required (not recommended).

## Residual risk

- Coordinated Sybil identities can still create claims up to the per-account caps; economic fees + min bounty raise the cost. Reputation / identity gating is out of scope (see V2 reputation modules).
- Fee-on-transfer bounty tokens remain rejected by exact-balance checks (`TransferAmountMismatch`).

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| Objective implemented without unrelated scope | `AntiGriefing.sol`, `Claims.sol`, `StakeVault` min stake, `ClaimRegistry` spam caps |
| Invariants documented and tested | This doc + `test/v2/AntiGriefing.t.sol` |
| Events/storage sufficient for projection | `ClaimCreated` / `ClaimStateChanged` / `MinStakeAmountUpdated` / `AntiGriefParamsUpdated` |
| No backend-authoritative mutation | Claimant-signed creation; manager role only finalizes |
| Residual risk identified | Sybil section above |
