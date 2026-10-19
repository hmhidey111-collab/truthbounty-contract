# Requirements Document

## Introduction

V2-SC-058 validates the Dispute Bond Economics and Custody Lifecycle for the TruthBounty V2 protocol. The feature covers the complete bond lifecycle for challenge bonds: allowance verification, ERC20 transfer into custody, lock cell creation, bond refund to the challenger on a successful dispute, bond slash to protocol allocation on a failed dispute, expiry of the challenge window, and cancellation paths. Conservation assertions ensure no bond value is created or destroyed outside the defined state transitions — every token entering custody must exit through exactly one terminal path (refund, slash, or cancellation).

The implementation targets Optimism/EVM exclusively. It must preserve canonical V2 state transitions and must not introduce Stellar, Soroban, or Freighter runtime dependencies. All paths must fail closed on invalid configuration, authorization, version mismatch, and external-call failure. Every new public surface must carry NatSpec, events, and custom errors. The complete CI suite (build, unit, fuzz, invariant, gas, static-analysis, artifact) must pass on the final commit.

Dependencies: V2-SC-016 (dispute opening bond primitives), V2-SC-043 (settlement allocation layer).

Non-Goals: production mainnet deployment, backend-authoritative protocol mutation, reintroducing or extending the V1 canonical path.

---

## Glossary

- **Challenge_Bond**: An ERC20 token amount posted by a challenger when opening a dispute. Held in the `BondCustody` module under the `CHALLENGE_BOND` lock category until a terminal lifecycle event occurs.
- **BondCustody**: The V2 `StakeVault` contract serving as the canonical on-chain custodian of all challenge bonds. Identified by its `IStakeCustody` interface.
- **Bond_State**: The lifecycle phase of a specific challenge bond: `LOCKED`, `REFUNDED`, `SLASHED`, `EXPIRED`, or `CANCELLED`.
- **Bond_Ledger**: The mapping within `BondCustody` that records each bond lock cell, keyed by `(asset, account, claimId, round=0, LockCategory.CHALLENGE_BOND)`.
- **Challenger**: The `address` that calls `openDispute` and posts the challenge bond.
- **DisputeResolution**: The V2 contract (V2-SC-016) responsible for dispute lifecycle management. It is the only authorized `OPERATOR` for bond lock and release transitions.
- **DisputeBondManager**: The new V2 module introduced by this spec that orchestrates the bond economics transitions (refund, slash, expiry, cancellation) by calling `BondCustody` through the `IStakeCustody` interface. Registered as `MODULE_DISPUTES` in the `ModuleRegistry`.
- **Refund**: The path in which a challenger's bond is returned to the challenger's claimable balance because the dispute was upheld (claim overturned).
- **Slash**: The path in which a challenger's bond is moved to protocol allocation because the dispute was rejected (original claim result sustained).
- **Expiry**: The path in which an unclosed dispute bond is resolved after the `disputeDeadline` has passed without a formal resolution — treated as a failed dispute (slash path).
- **Cancellation**: The path in which an open dispute is administratively cancelled before its deadline by an authorized governance action, returning the bond to the challenger.
- **Conservation_Invariant**: The mathematical property that `totalCustody(asset) == protocolAllocation(asset) + assetTotalLocked(asset) + assetTotalClaimable(asset)` holds after every bond lifecycle transition.
- **Bond_Amount**: The fixed ERC20 amount, denominated in the configured `bondToken`, required to open a dispute. Stored in `DisputeResolution.bondAmount`.
- **Bond_Token**: The ERC20 token address used as the bond denomination, stored in `DisputeResolution.bondToken`.
- **Allowance_Gate**: The pre-condition check that verifies `IERC20(bondToken).allowance(challenger, address(BondCustody)) >= bondAmount` before any custody transfer is attempted.
- **LockCategory**: The `IV2Types.LockCategory` enum value `CHALLENGE_BOND` (value 2) used to segregate challenge bond locks from verifier stake locks within `BondCustody`.
- **ModuleRegistry**: The canonical V2 registry that authorizes which addresses may call lock-mutation functions on `BondCustody`.
- **V2Errors**: The shared custom-error library (`contracts/v2/libraries/V2Errors.sol`) extended by this feature.
- **SettlementOutcome**: The `IV2Types.SettlementOutcome` enum recorded per `(claimId, round=0)` in `BondCustody` when a bond reaches a terminal state, preventing double-processing.
- **NatSpec**: The Ethereum Natural Language Specification Format used for Solidity documentation.

---

## Requirements

---

### Requirement 1: Allowance Gate — Pre-Transfer Verification

**User Story:** As a protocol engineer, I want the bond custody path to verify the challenger's ERC20 allowance before attempting a transfer, so that disputes never partially open due to a silent token failure.

#### Acceptance Criteria

1. WHEN `openDispute` is called, THE `DisputeResolution` SHALL verify that `IERC20(bondToken).allowance(msg.sender, address(vault)) >= bondAmount` before invoking any custody transfer.
2. IF the allowance check fails, THEN THE `DisputeResolution` SHALL revert with `InsufficientBondAllowance()` and leave no dispute record, no bond lock, and no claim state transition.
3. WHEN `bondAmount` is zero, THE `DisputeResolution` SHALL revert with `BondNotConfigured()` regardless of any token approval.
4. WHEN `bondToken` is `address(0)`, THE `DisputeResolution` SHALL revert with `BondNotConfigured()` regardless of any token approval.
5. FOR ALL valid `(bondToken, bondAmount, challenger)` tuples where allowance equals exactly `bondAmount`, THE `DisputeResolution` SHALL proceed to the custody transfer step without reverting on the allowance gate.

---

### Requirement 2: Bond Transfer into Custody

**User Story:** As a protocol engineer, I want the challenge bond to be pulled into vault custody atomically with dispute record creation, so that no dispute record can exist without a corresponding locked bond.

#### Acceptance Criteria

1. WHEN `openDispute` passes the allowance gate, THE `DisputeResolution` SHALL call `BondCustody.lock(bondToken, challenger, claimId, round=0, LockCategory.CHALLENGE_BOND, bondAmount)` to transfer the bond into custody.
2. WHEN the `BondCustody.lock` call succeeds, THE `BondCustody` SHALL record the bond in its lock ledger under the key `(bondToken, challenger, claimId, 0, CHALLENGE_BOND)` and increase `assetTotalLocked[bondToken]` by `bondAmount`.
3. WHEN the `BondCustody.lock` call reverts for any reason, THE `DisputeResolution` SHALL propagate the revert and leave no dispute record and no claim state transition.
4. IF `BondCustody` receives a lock call for a `(asset, account, claimId, round, category)` tuple already holding a non-zero balance, THEN THE `BondCustody` SHALL accept the additive deposit (existing staking semantics) — a dispute bond re-lock on the same tuple is prevented at the `DisputeResolution` layer by the one-dispute-per-claim guard.
5. WHEN a bond transfer is custodied, THE `BondCustody` SHALL emit `VaultLocked(bondToken, challenger, claimId, 0, LockCategory.CHALLENGE_BOND, bondAmount)`.
6. FOR ALL valid custody operations, THE Conservation_Invariant SHALL hold: `totalCustody(asset) == protocolAllocation(asset) + assetTotalLocked(asset) + assetTotalClaimable(asset)` (verifiable by invariant test).

---

### Requirement 3: Bond Refund Path — Successful Dispute

**User Story:** As a protocol engineer, I want a challenger's bond to be returned to the challenger's claimable balance when the dispute is upheld, so that successful challengers are made whole and the bond is never lost.

#### Acceptance Criteria

1. WHEN `DisputeBondManager.refundBond(claimId, challenger)` is called by an authorized resolver, THE `DisputeBondManager` SHALL call `BondCustody.unlock(bondToken, challenger, claimId, 0, LockCategory.CHALLENGE_BOND, bondAmount)` to move the bond back to claimable balance.
2. WHEN the refund is processed, THE `BondCustody` SHALL decrease `assetTotalLocked[bondToken]` by `bondAmount` and increase `_claimable[bondToken][challenger]` by `bondAmount`.
3. WHEN the refund is processed, THE `BondCustody` SHALL emit `VaultUnlocked(bondToken, challenger, claimId, 0, LockCategory.CHALLENGE_BOND, bondAmount)`.
4. WHEN the refund is processed, THE `DisputeBondManager` SHALL emit `BondRefunded(claimId, challenger, bondToken, bondAmount)`.
5. IF `refundBond` is called for a `claimId` whose bond has already reached a terminal state (`Bond_State` is not `LOCKED`), THEN THE `DisputeBondManager` SHALL revert with `BondAlreadySettled(claimId)`.
6. IF `refundBond` is called by any address that is not the authorized dispute resolver, THEN THE `DisputeBondManager` SHALL revert with `V2Errors.UnauthorizedModule(caller)`.
7. FOR ALL valid refunds, THE Conservation_Invariant SHALL hold after the operation (verifiable by invariant test).

---

### Requirement 4: Bond Slash Path — Failed Dispute

**User Story:** As a protocol engineer, I want a challenger's bond to be moved to protocol allocation when the dispute is rejected, so that frivolous challenges carry a real economic deterrent.

#### Acceptance Criteria

1. WHEN `DisputeBondManager.slashBond(claimId, challenger, reason)` is called by an authorized resolver, THE `DisputeBondManager` SHALL call `BondCustody.allocateLocked(bondToken, challenger, claimId, 0, LockCategory.CHALLENGE_BOND, bondAmount, reason)` to move the bond to protocol allocation.
2. WHEN the slash is processed, THE `BondCustody` SHALL decrease `assetTotalLocked[bondToken]` by `bondAmount` and increase `_protocolAllocation[bondToken]` by `bondAmount`.
3. WHEN the slash is processed, THE `BondCustody` SHALL emit `ProtocolAllocationIncreased(bondToken, bondAmount, reason)`.
4. WHEN the slash is processed, THE `DisputeBondManager` SHALL emit `BondSlashed(claimId, challenger, bondToken, bondAmount, reason)`.
5. IF `slashBond` is called for a `claimId` whose bond has already reached a terminal state, THEN THE `DisputeBondManager` SHALL revert with `BondAlreadySettled(claimId)`.
6. IF `slashBond` is called by any address that is not the authorized dispute resolver, THEN THE `DisputeBondManager` SHALL revert with `V2Errors.UnauthorizedModule(caller)`.
7. FOR ALL valid slash operations, THE Conservation_Invariant SHALL hold after the operation (verifiable by invariant test).

---

### Requirement 5: Bond Expiry Path — Unresolved Dispute After Deadline

**User Story:** As a protocol engineer, I want bonds for disputes that are not formally resolved before the dispute deadline to be slashed automatically, so that stale disputes do not hold bond value hostage indefinitely.

#### Acceptance Criteria

1. WHILE `block.timestamp > dispute.disputeDeadline` AND the bond `Bond_State` is `LOCKED`, THE `DisputeBondManager` SHALL permit any caller to trigger `expireBond(claimId)`, which executes the slash path for the expired bond.
2. WHEN `expireBond(claimId)` is called before `dispute.disputeDeadline`, THE `DisputeBondManager` SHALL revert with `DisputeNotExpired(claimId, dispute.disputeDeadline)`.
3. WHEN `expireBond` executes the slash path, THE `DisputeBondManager` SHALL record the bond `Bond_State` as `EXPIRED` and emit `BondExpired(claimId, challenger, bondToken, bondAmount)`.
4. IF `expireBond` is called for a `claimId` whose bond has already reached a terminal state, THEN THE `DisputeBondManager` SHALL revert with `BondAlreadySettled(claimId)`.
5. FOR ALL expired bond operations, THE Conservation_Invariant SHALL hold after the operation (verifiable by invariant test).

---

### Requirement 6: Bond Cancellation Path — Administrative Return

**User Story:** As a protocol engineer, I want an authorized governance action to be able to cancel an open dispute and return the challenger's bond, so that protocol administration can remediate disputes that were opened in error or under anomalous conditions.

#### Acceptance Criteria

1. WHEN `DisputeBondManager.cancelBond(claimId)` is called by an address holding `ADMIN_ROLE`, THE `DisputeBondManager` SHALL call `BondCustody.unlock(bondToken, challenger, claimId, 0, LockCategory.CHALLENGE_BOND, bondAmount)` to return the bond to the challenger's claimable balance.
2. WHEN the cancellation is processed, THE `DisputeBondManager` SHALL record the bond `Bond_State` as `CANCELLED` and emit `BondCancelled(claimId, challenger, bondToken, bondAmount)`.
3. IF `cancelBond` is called by any address not holding `ADMIN_ROLE`, THEN THE `DisputeBondManager` SHALL revert with `V2Errors.Unauthorized()`.
4. IF `cancelBond` is called for a `claimId` whose bond has already reached a terminal state, THEN THE `DisputeBondManager` SHALL revert with `BondAlreadySettled(claimId)`.
5. WHEN `cancelBond` is executed, THE `BondCustody` SHALL emit `VaultUnlocked(bondToken, challenger, claimId, 0, LockCategory.CHALLENGE_BOND, bondAmount)`.
6. FOR ALL cancellation operations, THE Conservation_Invariant SHALL hold after the operation (verifiable by invariant test).

---

### Requirement 7: Bond State Machine — Idempotency and Terminal State Enforcement

**User Story:** As a protocol engineer, I want each challenge bond to transition through exactly one terminal state, so that a bond cannot be both refunded and slashed, or processed twice.

#### Acceptance Criteria

1. THE `DisputeBondManager` SHALL maintain a `mapping(uint256 claimId => BondState)` where `BondState` is an enum with values `{ NONE, LOCKED, REFUNDED, SLASHED, EXPIRED, CANCELLED }`.
2. WHEN a bond lock is created via `openDispute`, THE `DisputeBondManager` SHALL record `bondState[claimId] = BondState.LOCKED`.
3. WHEN a terminal transition is recorded (`REFUNDED`, `SLASHED`, `EXPIRED`, or `CANCELLED`), THE `DisputeBondManager` SHALL update `bondState[claimId]` to the corresponding terminal value and MUST NOT permit any further transition from that terminal state.
4. IF any bond lifecycle function (`refundBond`, `slashBond`, `expireBond`, `cancelBond`) is called for a `claimId` where `bondState[claimId]` is `NONE` (bond was never locked, e.g. invalid or nonexistent claimId), THEN THE `DisputeBondManager` SHALL revert with `BondNotFound(claimId)` rather than `BondAlreadySettled(claimId)`.
5. IF any bond lifecycle function (`refundBond`, `slashBond`, `expireBond`, `cancelBond`) is called for a `claimId` where `bondState[claimId]` is already a terminal value (`REFUNDED`, `SLASHED`, `EXPIRED`, or `CANCELLED`), THEN THE `DisputeBondManager` SHALL revert with `BondAlreadySettled(claimId)`.
6. FOR ALL valid `claimId` values, the `bondState` SHALL transition through at most one terminal state (verifiable by fuzz test asserting `stateTransitionCount(claimId) <= 1`).
7. THE `DisputeBondManager` SHALL expose a `bondState(uint256 claimId) external view returns (BondState)` function for off-chain and cross-module queries.

---

### Requirement 8: Conservation Assertions — No Bond Value Creation or Destruction

**User Story:** As a protocol engineer, I want conservation assertions to verify that no bond token value is created or destroyed outside the defined state transitions, so that the custody ledger remains a faithful accounting of all bonded assets at all times.

#### Acceptance Criteria

1. THE `BondCustody` SHALL enforce the Conservation_Invariant `totalCustody(asset) == protocolAllocation(asset) + assetTotalLocked(asset) + assetTotalClaimable(asset)` after every mutating operation by calling `_assertReconciliation(asset)`.
2. IF the Conservation_Invariant is violated after any mutating operation, THEN THE `BondCustody` SHALL revert with `V2Errors.ObligationsExceedCustody(asset, custody, obligations)`.
3. THE `BondCustody` SHALL expose a `reconcile(address asset) external view returns (uint256 custody, uint256 obligations)` function that enables off-chain and test-layer reconciliation.
4. FOR ALL sequences of bond lifecycle operations (any permutation of lock, refund, slash, expiry, cancellation), the Conservation_Invariant SHALL hold after each step (verifiable by Foundry invariant test with `runs = 500, depth = 20`).
5. FOR ALL arithmetic operations on bond amounts, THE `BondCustody` SHALL use checked arithmetic (Solidity ^0.8.x built-in overflow detection) and SHALL NOT use `unchecked` blocks for balance updates that include bond lock/unlock/slash paths.
6. WHEN a token transfer produces a received amount that differs from the requested amount (fee-on-transfer scenario), THE `BondCustody` SHALL revert with `V2Errors.TransferAmountMismatch(expected, received)` and leave the custody ledger unchanged.

---

### Requirement 9: Authorization — Only Registered Modules May Mutate Bonds

**User Story:** As a protocol engineer, I want bond custody mutations to be restricted to registered V2 modules, so that no unauthorized address can lock, unlock, or allocate bond tokens.

#### Acceptance Criteria

1. THE `BondCustody` SHALL authorize lock-mutation calls only from addresses that satisfy `isAuthorizedMutator(caller)`, which returns `true` if `lockMutators[caller]` is set OR the caller is the registered `MODULE_DISPUTES` address in the `ModuleRegistry`.
2. IF a lock-mutation function (`lock`, `unlock`, `allocateLocked`) is called by an address that is not an authorized mutator, THEN THE `BondCustody` SHALL revert with `V2Errors.UnauthorizedModule(caller)`.
3. WHEN the `ModuleRegistry` returns a zero address for `MODULE_DISPUTES`, THE `BondCustody` SHALL treat the module as not registered and deny all lock mutations from that path.
4. THE `BondCustody` SHALL expose `isAuthorizedMutator(address caller) public view returns (bool)` so that callers can pre-check authorization without paying for a failed transaction.
5. FOR ALL unauthorized callers (not admin, not registered module, not explicit mutator), attempting any bond state transition SHALL revert with `V2Errors.UnauthorizedModule(caller)` (verifiable by unit test).

---

### Requirement 10: Fail-Closed on Invalid Configuration

**User Story:** As a protocol engineer, I want the protocol to fail closed on misconfigured or uninitialized bond parameters, so that an improperly configured deployment cannot process bonds in an unsafe state.

#### Acceptance Criteria

1. WHEN `DisputeResolution` is deployed with `bondToken == address(0)` or `bondAmount == 0`, THE constructor SHALL revert with `BondNotConfigured()`.
2. WHEN `DisputeBondManager` is deployed with a zero `BondCustody` address or zero `DisputeResolution` address, THE constructor SHALL revert with `V2Errors.ZeroAddress()`.
3. WHEN `DisputeBondManager` is deployed with a zero `ModuleRegistry` address, THE constructor SHALL revert with `V2Errors.ZeroAddress()`.
4. IF `setBondToken(address(0))` is called on `DisputeResolution`, THEN THE function SHALL revert with `V2Errors.ZeroAddress()`.
5. IF `setBondAmount(0)` is called on `DisputeResolution`, THEN THE `DisputeResolution` SHALL revert with `BondNotConfigured()`.
6. WHILE the `BondCustody` is paused, THE `BondCustody` SHALL revert all lock and unlock operations with the OpenZeppelin `Pausable` revert, preserving existing bond state.

---

### Requirement 11: Events and NatSpec on Every New Public Surface

**User Story:** As a protocol auditor, I want every new public function, event, and custom error to be fully documented with NatSpec and emitted events, so that on-chain behaviour is observable and the security properties can be reviewed without reading implementation internals.

#### Acceptance Criteria

1. THE `DisputeBondManager` SHALL define and emit the following events, each with indexed fields where applicable:
   - `BondRefunded(uint256 indexed claimId, address indexed challenger, address bondToken, uint256 bondAmount)`
   - `BondSlashed(uint256 indexed claimId, address indexed challenger, address bondToken, uint256 bondAmount, bytes32 indexed reason)`
   - `BondExpired(uint256 indexed claimId, address indexed challenger, address bondToken, uint256 bondAmount)`
   - `BondCancelled(uint256 indexed claimId, address indexed challenger, address bondToken, uint256 bondAmount)`
2. THE `DisputeBondManager` SHALL define the following custom errors: `BondAlreadySettled(uint256 claimId)`, `BondNotFound(uint256 claimId)`, `DisputeNotExpired(uint256 claimId, uint64 deadline)`.
3. THE `DisputeBondManager` interface (`IDisputeBondManager`) SHALL include `@title`, `@notice`, and `@dev` NatSpec on the interface declaration.
4. THE `DisputeBondManager` interface SHALL include `@notice` and `@param` NatSpec on every public or external function signature.
5. THE `DisputeBondManager` interface SHALL include `@notice` NatSpec on every event and error declaration.
6. WHEN a new `V2Errors` entry is added, THE `V2Errors` library SHALL include `@notice` NatSpec on the new error declaration.

---

### Requirement 12: Test Coverage — Unit, Fuzz, and Invariant

**User Story:** As a protocol engineer, I want comprehensive test coverage across all bond lifecycle paths, so that the economic correctness and security properties are demonstrated to hold under all valid inputs, boundary conditions, and adversarial orderings.

#### Acceptance Criteria

1. THE test suite SHALL include Foundry unit tests for every success path: allowance pass → lock, lock → refund, lock → slash, lock → expiry (after deadline), lock → cancellation (admin role).
2. THE test suite SHALL include Foundry unit tests for all boundary conditions: `bondAmount = 1` (minimum non-zero), `bondAmount = type(uint256).max` (maximum), challenger with allowance exactly equal to `bondAmount`, challenger with allowance of exactly `bondAmount - 1` (should revert).
3. THE test suite SHALL include Foundry unit tests for all authorization failure paths: non-operator calling lock, non-resolver calling refund/slash, non-admin calling cancel, unauthorized caller calling expiry for a non-expired dispute.
4. THE test suite SHALL include Foundry fuzz tests asserting: for any valid `(asset, challenger, claimId, bondAmount)` tuple, after a single refund or slash, the `bondState` is terminal and a second call to the same terminal path reverts.
5. THE test suite SHALL include a Foundry invariant test for `BondCustody` asserting the Conservation_Invariant holds over any sequence of bond lifecycle transitions, configured with `runs = 500, depth = 20`.
6. THE test suite SHALL include a regression test demonstrating that the prior `StakeVault.lockBond` path (V2-SC-016) does NOT enforce `LockCategory.CHALLENGE_BOND` segregation, and that the new `DisputeBondManager` path DOES — confirming the defect addressed by V2-SC-058 is resolved.
7. THE test suite SHALL include a round-trip property test: for any valid bond lock followed by a refund, `claimableBalance(bondToken, challenger)` increases by exactly `bondAmount` and `totalCustody(bondToken)` is unchanged (modulo other concurrent operations).
8. WHEN the complete Foundry CI suite is run on the final commit, THE suite SHALL produce zero failing tests across build, unit, fuzz, invariant, gas, and static-analysis checks.

---

### Requirement 13: No Unrelated Refactoring and Strict Scope Boundary

**User Story:** As a protocol maintainer, I want the implementation to be strictly scoped to the bond economics and custody lifecycle, so that the PR remains independently reviewable and does not introduce unrelated risk.

#### Acceptance Criteria

1. THE implementation SHALL NOT modify any V1 contract (including any file under `contracts/` that is not in the `contracts/v2/` subtree), any module outside `DisputeBondManager`, `DisputeResolution` (bond config extension only), `BondCustody` (`StakeVault` — CHALLENGE_BOND category wiring only), and `V2Errors` (new error additions only). Any modification to a V1 contract violates this constraint regardless of whether custody routing flows through V2.
2. THE implementation SHALL NOT introduce Stellar, Soroban, or Freighter runtime dependencies in any Solidity, TypeScript, or configuration file.
3. THE implementation SHALL NOT embed placeholder, test, or production private keys, RPC URLs, or secret values in any committed file.
4. THE implementation SHALL preserve all existing `StakeVault` and `DisputeResolution` public API surfaces without breaking changes to existing function signatures or existing event topics.
5. IF the implementation requires modifying any module outside the stated scope, THEN THE PR description SHALL document the additional scope change and obtain explicit maintainer review and approval before merging.
6. THE implementation SHALL NOT reintroduce or extend the V1 legacy `contracts/StakeVault.sol` as a canonical module; all bond custody transitions SHALL flow through `contracts/v2/StakeVault.sol` via `IStakeCustody`.
