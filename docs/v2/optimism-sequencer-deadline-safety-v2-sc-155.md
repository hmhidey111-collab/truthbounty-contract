# V2-SC-155 — Optimism Sequencer-Outage Deadline Safety

Closes #634

## Clock and outage model

The affected Solidity paths use the timestamp of the L2 block that includes a transaction. They do not use a caller-supplied clock, an off-chain sequencer-health signal, or a wall-clock submission time. During an outage, a submitted transaction is not included. On recovery, the L2 block timestamp is authoritative; a timestamp jump does not pause, extend, or rewind a deadline.

No global grace period is required by the current rules. Adding one would change active-claim behavior and needs an explicitly governed, versioned rule. Existing absolute deadlines, authorization checks, finality guards, and custody invariants therefore remain unchanged.

## Deadline behavior

| Flow | Clock and boundary | Outage and recovery behavior |
|---|---|---|
| Claim creation | `ClaimRegistry` requires `verificationDeadline > block.timestamp` and enforces a maximum horizon. | A claim cannot be created with an expired or current-time deadline. Existing claims keep their recorded deadline. |
| Verification submission | `VerificationSubmission` rejects only when `block.timestamp > verificationDeadline`; inclusion exactly at the deadline is accepted. `TruthBountyWeighted` uses the stricter `block.timestamp < verificationWindowEnd`; inclusion at the endpoint is rejected. | The applicable contract's existing boundary is stable. A late transaction cannot become timely merely because it was submitted before the outage. |
| Aggregation and settlement | `VerificationAggregation` cannot aggregate before its source window end. `TruthBountyWeighted.settleClaim` additionally waits until `verificationWindowEnd + confirmationDelay`. | Recovery does not bypass the confirmation delay, single-settlement guard, or deterministic vote result. |
| Dispute opening | `DisputeResolution` requires `timestamp > verificationDeadline` and `timestamp <= verificationDeadline + challengeWindowDuration`. | The challenge window remains fixed. Opening still requires a valid claim state and bond custody; after the frozen upper bound, opening is rejected. |
| Appeal voting and closure | `AppealVerificationRound` rejects votes at `timestamp >= round.deadline`; permissionless closure is available at `timestamp >= round.deadline`. | A delayed appeal vote is rejected, while anyone can advance an expired round without releasing its bond. |
| Governance voting and execution | The governor's clock is the governance token's timestamp clock. Voting and timelock actions follow the governor and timelock state machines; execution requires the scheduled ETA. | A timestamp jump cannot satisfy voting or timelock authorization early. At an eligible boundary, only the normal governor/timelock path can advance the proposal. |
| Stake release | `StakeVault` has no time-based self-release path. Settlement module authorization and one-time settlement outcomes control principal release. | Elapsed time or sequencer recovery alone cannot unlock or transfer stake. |

## Regression evidence

- `test/ClaimRegistry.test.ts`: rejects deadlines equal to the current timestamp and in the past.
- `test/VerificationSubmission.test.ts`: accepts inclusion exactly at the deadline, rejects at `deadline + 1`, and preserves the verification count.
- `test/TruthBountyWeighted.test.ts`: fixes the vote cutoff across a timestamp jump, checks rejection at the endpoint, settles at the confirmation boundary, and rejects settlement replay.
- `test/DisputeResolution.t.sol`: covers opening at the frozen upper bound and rejection after it; existing cases cover opening before the challenge window and after the upper bound.
- `test/v2/AppealBounds.t.sol`: rejects a vote at the appeal deadline, permits permissionless closure at that timestamp, and proves the bond remains locked.
- `test/governance/TruthBountyGovernor.t.sol`: covers voting at the voting deadline and execution at the exact timelock ETA.
- `test/v2/StakeVault.t.sol`: proves a long timestamp jump cannot bypass settlement authorization or alter custody.
- `test/v2/OptimismFork.t.sol`: fork-gated Optimism scenario models an outage as a seven-day timestamp jump; a deadline-boundary vote remains recorded, a post-recovery vote is rejected, and no extra stake is pulled. Run with `OPTIMISM_RPC_URL` and optionally `OPTIMISM_FORK_BLOCK`.

The fork scenario is a deterministic timestamp-jump simulation on an Optimism fork; it does not claim to reproduce a live sequencer outage. No contract behavior or active-claim deadline is modified.

## Acceptance criteria evidence

| Criterion | Evidence |
|---|---|
| Every critical deadline has explicit outage behavior and regression coverage. | Deadline behavior matrix and exact/adjacent boundary tests listed above. |
| Outages cannot bypass dispute, appeal, timelock, authorization, or settlement guarantees. | `DisputeResolution.t.sol`, `AppealBounds.t.sol`, `TruthBountyGovernor.t.sol`, `StakeVault.t.sol`, and `TruthBountyWeighted.test.ts`. |
| Any grace behavior is bounded, deterministic, versioned, and pinned for active claims. | No grace rule is needed or introduced; active deadlines remain unchanged and fixed. |
| Optimism fork tests reproduce the documented behavior. | `OptimismFork.t.sol` applies a controlled timestamp jump on the configured Optimism fork and checks the post-recovery transaction outcome. |

## Checks

Focused Foundry and Hardhat tests are listed in the regression evidence above. They could not be executed in the current environment because Foundry is not installed and the workspace's Hardhat dependencies are absent. Editor diagnostics reported no errors for the modified test files.
