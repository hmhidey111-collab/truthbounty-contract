# TruthBounty V2 Governance (V2-SC-027)

## Overview

V2 governance introduces an OpenZeppelin `Governor` integrated with `TimelockController` for
protocol configuration changes. Governance **cannot** invoke claim-specific settlement or
outcome override calls.

## Architecture

| Contract | Role |
|----------|------|
| `TruthBountyGovernanceToken` | ERC20Votes token; delegation required before voting |
| `TruthBountyGovernor` | Proposal, voting, queue, cancel, execute lifecycle |
| `TimelockController` | Minimum execution delay after successful votes |
| `GovernedModuleRegistry` | Allowlist of proposal targets |
| `GovernanceGuardian` | Separate veto/cancel authority; no execution power |
| `GovernanceRoleTopology` | Canonical timelock role wiring (V2-SC-026 dependency) |
| `TimelockRolePolicy` | Canonical proposer/executor/canceller role graph and open/closed executor policy |

## Proposal Lifecycle

1. **Propose** — proposer meets threshold; targets must be registered modules; forbidden selectors rejected
2. **Pending → Active** — after `votingDelay`
3. **Vote** — simple for/against/abstain counting with quorum fraction
4. **Succeeded → Queued** — operations scheduled on timelock
5. **Execute** — only after timelock `minDelay`; duplicate execution reverts
6. **Cancel** — proposer, governance, or guardian (via `_validateCancel`)

## Forbidden Calls

`GovernanceForbiddenCalls` blocks:

- `settleClaim(uint256)` — TruthBountyWeighted / legacy paths
- `settleClaim(address,uint256)` — TruthBountyClaims
- `settleClaimsBatch(address[],uint256[])` — batch treasury payouts
- `settleClaim(uint256,bytes32)` — legacy settlement variants

## Guardian Separation

- Guardian receives `CANCELLER_ROLE` on timelock and may veto via `GovernanceGuardian`
- `GovernanceGuardian` calls `TruthBountyGovernor.cancel(proposalId)`; the governor must be wired once via `setGovernanceGuardianModule`
- Guardian cannot propose, execute, or bypass timelock delays
- Guardian cancellation is bounded to queued/pending proposals and emits an audited `ProposalCancelled` event
- Cancellation authority is exactly `{Governor, Guardian}`; no other actor may hold `CANCELLER_ROLE`
- Governance cannot invoke guardian emergency pause paths

## Timelock Delay Bounds & Self-Administration (V2-SC-072)

- `TimelockController` enforces a `minDelay` floor and a `maxDelay` ceiling on any delay change
- Delay changes must be scheduled through the timelock itself (self-call); immediate decrease is rejected
- Each scheduled operation is identified by `keccak256(targets, values, calldatas, predecessor, salt)`; duplicate IDs revert
- `predecessor` must reference a completed operation or `bytes32(0)`; missing predecessors block execution
- Operations expire after the timelock grace period and cannot execute once expired
- Cancellation is restricted to `CANCELLER_ROLE`; cancelled operations cannot execute
- `CallScheduled`, `CallExecuted`, `Cancelled`, and `MinDelayChange` events are emitted for every state transition

## Token & Delegation Assumptions

- Voting uses timestamp clock (`mode=timestamp`)
- Holders must call `delegate()` before voting power is counted
- Proposal threshold and quorum are configurable at deploy; launch values are a separate decision

## Voting-Power Snapshot Immutability

- Voting power is captured from `ERC20Votes.getPastVotes(account, snapshotTimestamp)` at the
  proposal's snapshot, where `snapshotTimestamp = proposalSnapshot(proposalId)`.
- `proposalSnapshot(proposalId)` is fixed at proposal creation as
  `block.timestamp + votingDelay()`; it is never recomputed after the proposal exists.
- Transfers, mints, burns, and delegation or redelegation changes that occur at or after the
  snapshot timestamp MUST NOT alter the voting power available to that proposal.
- Same-block edge behavior: a delegation or transfer included in the same block as the snapshot
  timestamp is only counted if it is ordered before the snapshot checkpoint; otherwise it is
  excluded. This ordering is explicit and covered by same-block and adjacent-block tests.
- Total voting power is conserved across snapshot boundaries: sum of `getPastVotes` over all
  accounts at the snapshot equals the total supply checkpointed at that timestamp.

## Deployment

```bash
forge script script/deploy/DeployGovernanceV2.s.sol --rpc-url $RPC_URL --broadcast
```

Required env vars: `ADMIN_ADDRESS`, `GUARDIAN_ADDRESS`. Optional: `TIMELOCK_MIN_DELAY`,
`GOV_VOTING_DELAY`, `GOV_VOTING_PERIOD`, `GOV_PROPOSAL_THRESHOLD`, `GOV_QUORUM_NUMERATOR`,
`GOV_TOKEN_SUPPLY`.

Deployment must satisfy the canonical timelock role graph: `PROPOSER_ROLE` = Governor only,
`EXECUTOR_ROLE` = closed (address(0) only, no open executor), `CANCELLER_ROLE` = {Governor, Guardian},
and `TIMELOCK_ADMIN_ROLE` renounced to the timelock itself after `finalizeTimelockAdmin`.

Manifest entries are emitted via `TruthBountyGovernor.publishManifest()` and written by
`DeployBase.generateManifestWithGovernance()`.

Deployment is machine-checked against this role graph; missing/extra roles, same-actor conflicts,
open executor grants, unauthorized cancellers, delay bypass, and admin retention all revert.

## Reuse / Replace / Deprecate Map

| Path | Status | Notes |
|------|--------|-------|
| `contracts/governance/GovernanceController.sol` | **Retained (legacy)** | Parameter store for V1 modules; not used by V2 governor execution path |
| `contracts/governance/GovernorAccess.sol` | **Retained (legacy)** | Role helpers for legacy controller |
| `contracts/governance/v2/*` | **New (canonical V2)** | Governor proposal and execution controls |
| `contracts/utils/ResolverRoleTimelock.sol` | **Reused** | Operational resolver changes remain timelocked outside governance |

## Security Properties

- Duplicate execution prevented by OpenZeppelin governor + timelock state machine
- Stale/defeated/expired proposals cannot execute
- Proposal spam mitigated by `proposalThreshold`
- Post-snapshot transfers, mints, burns, and delegation changes cannot increase historical voting power
- Timelock bypass prevented: governor is sole proposer; guardian cannot execute
- Target allowlist enforced at proposal creation
- No actor can both propose and execute: `PROPOSER_ROLE` and `EXECUTOR_ROLE` are disjoint
- Open executor policy is rejected: `EXECUTOR_ROLE` is granted to no address
- Cancellation is bounded to `{Governor, Guardian}` and audited via events
- Timelock self-administration is explicit: `TIMELOCK_ADMIN_ROLE` held by the timelock after renunciation

## Authority Boundaries (V2-SC-111)

`GovernanceAuthorityBoundaries` publishes the canonical `(role, capability)` matrix encoded by
`GovernanceAuthorityMatrix`. Each authority role is bound to at most one accountable account and an
account may hold at most one role, so overlapping authority is rejected on-chain.

| Authority | Exclusive capabilities |
|-----------|------------------------|
| Governor | `PROPOSE_PROPOSAL`, `QUEUE_PROPOSAL` |
| Timelock | `EXECUTE_PROPOSAL`, `SET_TIMELOCK_ROLES`, `UPGRADE_IMPLEMENTATION` |
| Guardian | `PAUSE_PROTOCOL` |
| Registry | `REGISTER_GOVERNED_MODULE` |
| Configuration | `SET_PROTOCOL_PARAMETER` |
| Treasury | `RELEASE_TREASURY_FUNDS` |
| Operations | `ROTATE_OPERATIONAL_ROLE` |

`CANCEL_PROPOSAL` is the only intentionally shared capability (Governor and Guardian). Claim-outcome
selectors (`settleClaim*`) belong to no authority and remain rejected by `GovernanceForbiddenCalls`.

`AUTHORITY_ADMIN_ROLE` is granted to the bootstrap admin at deployment and must be handed to the
timelock once the topology is bound, mirroring `GovernanceRoleTopology.finalizeTimelockAdmin`.

## Snapshot Test Coverage (PREWAVE-SC-019)

- Transfer, delegate, redelegate, mint, burn, and self-delegation around snapshot boundaries.
- Same-block and adjacent-block proposal creation versus delegation/transfer ordering.
- Historical checkpoint lookup fuzzing against `getPastVotes` at and around the snapshot.
- Regression: `test_VotingPowerFrozenAtSnapshot_TransferAfterProposalDoesNotHelp` must pass.