# Requirements Document

## Introduction

This feature implements **Deterministic Reward Remainder Allocation** (V2-SC-060) for the TruthBounty V2 protocol on Optimism/EVM. When a reward pool of `totalReward` tokens is distributed across `N` recipients via integer division, the operation `totalReward / N` produces a per-share amount and a remainder `totalReward % N` (0 ≤ remainder < N). Without explicit handling, this remainder is either stranded as contract dust or silently over- or under-allocated.

The feature introduces a standalone Solidity library, `RewardRemainderLib`, that applies a documented deterministic rounding rule — **Largest Remainder Method (LRM)** by ascending recipient-index order — so that:

1. The conservation invariant holds: `sum(allocations[i]) == totalReward` for all inputs.
2. No single recipient receives more than `floor(totalReward / N) + 1` tokens.
3. The allocation outcome depends only on the function inputs, never on call order, block context, or msg.sender.
4. The algorithm and its selection rationale are recorded on-chain via NatSpec and emit a structured event.

The library is consumed by the existing `RewardEngine` batch-allocation path and is gated behind the versioned `V2Lifecycle.ParameterSet.roundingPolicy` field (value `1` = LRM). The feature does not deploy to production mainnet, does not reintroduce V1 canonical paths, and does not add Stellar/Soroban/Freighter dependencies.

---

## Glossary

- **RewardRemainderLib**: New Solidity pure-function library that implements deterministic remainder splitting.
- **RewardEngine**: Existing V2 contract at `contracts/reward/RewardEngine.sol` that manages allocation and distribution of reward tokens.
- **Allocation**: The act of assigning a token amount to a recipient's claimable balance within RewardEngine; no token transfer occurs until claim.
- **totalReward**: The gross uint256 token amount to be split across all recipients in a single batch settlement.
- **N**: The number of distinct recipient addresses in a distribution round; must satisfy `N > 0`.
- **perShare**: `floor(totalReward / N)`, the base allocation each recipient receives before remainder handling.
- **remainder**: `totalReward % N`; the number of recipients that each receive one extra token (one wei) above `perShare`.
- **Largest Remainder Method (LRM)**: Rounding rule that distributes each unit of the remainder to the next recipient by ascending index until the remainder is exhausted. Recipients at indices `0` through `remainder - 1` receive `perShare + 1`; remaining recipients receive `perShare`.
- **Conservation Invariant**: The property `sum(allocations[i] for i in 0..N-1) == totalReward`.
- **Dust**: Stranded wei left in the contract after distribution that belongs to no recipient.
- **roundingPolicy**: `uint8` field in `V2Lifecycle.ParameterSet`; value `1` selects LRM; value `0` retains legacy floor-only behaviour.
- **DISTRIBUTOR_ROLE**: Access-control role in RewardEngine required to invoke batch reward allocation.
- **V2Errors**: Shared error library at `contracts/v2/libraries/V2Errors.sol`.
- **Pool**: The `availableRewardBalance()` tracked by RewardEngine; allocations must never exceed this.

---

## Requirements

### Requirement 1: Conservation Invariant Enforcement

**User Story:** As a protocol maintainer, I want every reward distribution to allocate exactly `totalReward` tokens in total, so that no dust accumulates in the contract and the pool balance accounting remains exact.

#### Acceptance Criteria

1. THE `RewardRemainderLib` SHALL compute allocations such that the sum of all returned allocation amounts equals `totalReward` for any `totalReward ≥ 0` and any `N ≥ 1`.
2. WHEN `totalReward` is zero, THE `RewardRemainderLib` SHALL return an array of `N` zero-valued allocations.
3. WHEN `N` equals 1, THE `RewardRemainderLib` SHALL assign all of `totalReward` to the single recipient at index 0.
4. WHEN `totalReward % N` equals zero, THE `RewardRemainderLib` SHALL return `N` equal allocations each of value `totalReward / N`, producing a zero remainder.
5. FOR ALL valid inputs `(totalReward, N)`, THE `RewardRemainderLib` SHALL NOT produce any allocation that would cause the sum of allocations to exceed `totalReward`.

---

### Requirement 2: Deterministic Largest Remainder Method

**User Story:** As an auditor, I want the remainder unit assignment to follow a documented, reproducible rule independent of call order or block state, so that I can verify the allocation offline and the protocol cannot be gamed by transaction ordering.

#### Acceptance Criteria

1. WHEN `totalReward % N > 0`, THE `RewardRemainderLib` SHALL assign allocation `perShare + 1` to each recipient at array index `i` where `i < (totalReward % N)`, and allocation `perShare` to all remaining recipients.
2. THE `RewardRemainderLib` SHALL produce identical output for identical `(totalReward, N)` inputs regardless of the order in which callers invoke it, the block number, the block timestamp, or `msg.sender`.
3. THE `RewardRemainderLib` SHALL NOT read from contract storage, emit events, or make external calls; it SHALL be a pure Solidity library function.
4. THE `RewardRemainderLib` SHALL NOT use randomness sources (`block.prevrandao`, `blockhash`, `chainid`, or any oracle) to determine remainder assignment.
5. THE `RewardRemainderLib` NatSpec SHALL document the algorithm name (Largest Remainder Method), the tie-breaking rule (ascending index), and the conservation invariant as `@dev` remarks on the public function.

---

### Requirement 3: Pool Integrity — No Over-Allocation

**User Story:** As a token holder, I want the RewardEngine to reject any split instruction whose total would exceed the available pool, so that the reward token solvency is always maintained.

#### Acceptance Criteria

1. WHEN `RewardEngine` invokes `RewardRemainderLib` for a batch split, THE `RewardEngine` SHALL verify that `totalReward ≤ availableRewardBalance()` before performing the split, and SHALL revert with `InsufficientRewardPool` if the condition is not met.
2. AFTER a successful split allocation, THE `RewardEngine` SHALL reduce `availableRewardBalance()` by exactly `totalReward` (not by the sum of individual perShare amounts), preserving dust-free accounting.
3. IF `N` equals 0, THEN THE `RewardRemainderLib` SHALL revert with `V2Errors.InvalidArgument("zero recipients")`.
4. IF any computed individual allocation would overflow `uint256`, THEN THE `RewardRemainderLib` SHALL revert; in practice this is prevented by the conservation invariant and checked arithmetic.

---

### Requirement 4: Rounding Policy Governance Gate

**User Story:** As a governance participant, I want the remainder allocation algorithm to be selectable via the versioned parameter set, so that the protocol can upgrade rounding behaviour through the established governance process without redeploying core contracts.

#### Acceptance Criteria

1. WHEN `V2Lifecycle.ParameterSet.roundingPolicy` equals `1`, THE `RewardEngine` SHALL apply `RewardRemainderLib` for all batch splits.
2. WHEN `V2Lifecycle.ParameterSet.roundingPolicy` equals `0`, THE `RewardEngine` SHALL apply the legacy floor-only path (each recipient receives `perShare`; dust is not distributed).
3. IF `roundingPolicy` contains a value other than `0` or `1`, THEN THE `RewardEngine` SHALL revert with `V2Errors.InvalidArgument("unsupported rounding policy")` when the parameter set is activated.
4. THE `RewardEngine` SHALL emit a `RoundingPolicyActivated(uint8 policy, bytes32 parameterSetId)` event whenever a new parameter set is activated that changes the active rounding policy.
5. THE `roundingPolicy` field SHALL be readable via a public view function `activeRoundingPolicy() returns (uint8)` on `RewardEngine`.

---

### Requirement 5: Structured Event and NatSpec Surface

**User Story:** As an integrator, I want every batch split to emit a structured on-chain event recording the inputs and remainder size, so that off-chain indexers can reconstruct exact per-recipient amounts without re-executing the algorithm.

#### Acceptance Criteria

1. WHEN `RewardEngine` executes a batch remainder split, THE `RewardEngine` SHALL emit `RemainderAllocated(bytes32 indexed settlementId, uint256 totalReward, uint256 recipientCount, uint256 remainder, uint8 policy)` after the allocation array is computed.
2. THE `RemainderAllocated` event SHALL be emitted exactly once per batch split call, even when `remainder` is zero.
3. WHEN `remainder` equals zero, THE `RemainderAllocated` event SHALL record `remainder = 0`, confirming an even split with no remainder units assigned.
4. THE `RewardEngine` public function that triggers batch splitting SHALL have complete NatSpec (`@notice`, `@param`, `@return`, `@dev`) including an explicit note on the conservation invariant.
5. EVERY new custom error introduced by this feature SHALL be defined in `V2Errors.sol` or in the new library file with accompanying NatSpec `@notice` documentation.

---

### Requirement 6: Authorization and Fail-Closed Security

**User Story:** As a security reviewer, I want all remainder allocation operations to be callable only by the authorised distributor role, and to revert closed on any invalid input or configuration, so that no adversary can exploit ordering, grief the pool, or bypass access control.

#### Acceptance Criteria

1. WHEN a caller without `DISTRIBUTOR_ROLE` attempts to invoke the batch-split entrypoint on `RewardEngine`, THE `RewardEngine` SHALL revert with an access-control error.
2. IF `RewardEngine` is paused, THEN THE batch-split entrypoint SHALL revert with a paused-state error before any other input validation is performed, including array length checks.
3. IF any recipient address in the input array is `address(0)`, THEN THE `RewardEngine` SHALL revert with `V2Errors.ZeroAddress()` before touching pool balances.
4. WHILE `RewardEngine` is not paused, IF the input recipients array and the weights or amounts arrays have mismatched lengths, THEN THE `RewardEngine` SHALL revert with `V2Errors.InvalidArgument("array length mismatch")`.
5. THE `RewardEngine` SHALL apply `nonReentrant` protection to the batch-split entrypoint; re-entrant calls SHALL revert.
6. THE `RewardEngine` SHALL NOT delegate remainders or any part of `totalReward` to `msg.sender` or to the contract itself except as explicitly specified by the distribution inputs.

---

### Requirement 7: Regression — No Call-Order Dependency

**User Story:** As a protocol security analyst, I want a regression test that demonstrates the prior unsafe behaviour (dust stranded or allocation dependent on call order) fails against the new implementation, so that the fix is provably in place.

#### Acceptance Criteria

1. THE test suite SHALL include a Foundry fuzz test (`test/fuzz/RewardRemainderFuzz.t.sol`) that, for all `(totalReward, N)` pairs with `N ∈ [1, 100]` and `totalReward ∈ [0, type(uint128).max]`, asserts the conservation invariant holds.
2. THE test suite SHALL include a Foundry fuzz test that asserts no individual allocation exceeds `perShare + 1`.
3. THE test suite SHALL include a Foundry invariant test (`test/invariant/RewardRemainderInvariant.t.sol`) that asserts `totalReserved + totalDistributed + availableRewardBalance() == totalFunded` at all times during randomised call sequences.
4. THE test suite SHALL include a unit test that calls the batch-split function twice with the same inputs in different block contexts and asserts identical per-recipient allocation arrays are produced (determinism regression).
5. THE test suite SHALL include a unit test that asserts a prior-behaviour scenario — where `totalReward % N != 0` previously left dust — now results in zero dust and the full `totalReward` allocated.

---

### Requirement 8: CI Suite Compliance

**User Story:** As a maintainer reviewing the PR, I want the complete required CI checks to pass on the final commit, so that the merge is safe to approve without manual re-verification of build, lint, gas, and security gates.

#### Acceptance Criteria

1. THE implementation SHALL compile without errors or warnings under `forge build` with the project's existing `foundry.toml` settings (optimizer enabled, `via_ir = true`).
2. THE implementation SHALL pass `forge test --match-path "test/fuzz/RewardRemainder*"` and `forge test --match-path "test/invariant/RewardRemainder*"` with zero failures.
3. THE implementation SHALL pass `forge test --match-contract RewardEngine` (all existing RewardEngine tests) to verify no regressions.
4. THE implementation SHALL not increase any function's gas cost by more than 5 % relative to the baseline measured before this change, as verified by the gas-check CI workflow.
5. THE implementation SHALL pass `slither` static analysis with no new high-severity findings introduced by the changed files.
6. THE implementation SHALL produce deterministic compiler artifacts that match the expected ABI output recorded in the CI artifact-check step.
