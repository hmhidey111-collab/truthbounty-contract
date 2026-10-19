# Requirements Document

## Introduction

V2-SC-053 introduces domain-separated identifier derivation for all cross-module entity identifiers in the TruthBounty V2 protocol. Currently, claim, lock, dispute, settlement, reward, and governance identifiers are derived from plain uint256 monotonic counters or simple keccak hashes that do not encode the originating module name or chain context. This creates a structural aliasing risk: two different modules on different chains (or different module types on the same chain) can produce identical `bytes32` identifiers for distinct entities, enabling cross-module confusion, replay, and referencing bugs.

This feature delivers a canonical `DomainSeparatedIds` library that embeds chain ID, protocol version, module name, and entity type into every identifier derivation. It is a focused, independently reviewable V2 contract work item with no mainnet deployment scope. It targets Optimism/EVM exclusively and must not introduce Stellar, Soroban, or Freighter dependencies. All changes must fail closed on invalid configuration, version, or authorization inputs.

## Glossary

- **DomainSeparatedIds**: The new Solidity library that provides all identifier derivation functions for V2 cross-module identifiers.
- **Domain Separator**: A `bytes32` value derived from the chain ID, protocol version, and module name that makes identifier derivation unique per deployment context.
- **Claim_Identifier**: A `bytes32` identifier derived with domain separation for a claim entity. Replaces the aliasing-unsafe plain `uint256 claimId` when used in cross-module contexts.
- **Lock_Identifier**: A `bytes32` identifier derived with domain separation for a stake lock cell, incorporating asset, account, claimId, round, and category.
- **Dispute_Identifier**: A `bytes32` identifier derived with domain separation for a dispute entity.
- **Settlement_Identifier**: A `bytes32` identifier derived with domain separation for a settlement record keyed to a claim and round.
- **Reward_Identifier**: A `bytes32` identifier derived with domain separation for a reward accrual record.
- **Governance_Identifier**: A `bytes32` identifier derived with domain separation for a governance action record.
- **Module_Name**: A `bytes32` constant unique to each V2 module (e.g. `keccak256("CLAIMS")`, `keccak256("DISPUTES")`). Used as a domain component.
- **Protocol_Version**: A packed `uint32` encoding `(major << 16) | minor` for the canonical V2 protocol version implemented by a module.
- **Chain_Domain**: A `bytes32` value derived from `block.chainid` and the protocol version, baked into every domain separator.
- **IV2Module**: The existing interface every V2 module implements, exposing `protocolVersion()`.
- **StakeVault**: The existing canonical V2 custody contract that currently uses `_lockKey()` without chain-domain separation.
- **V2Errors**: The existing shared custom-error library extended by this feature.
- **Aliasing**: The condition where two distinct entities in different modules or chains produce the same identifier, enabling incorrect cross-module references.

## Requirements

---

### Requirement 1: Domain Separator Construction

**User Story:** As a protocol engineer, I want every identifier derivation to embed the chain ID, protocol version, and module name, so that identifiers produced on one chain or in one module cannot alias identifiers from another chain or module.

#### Acceptance Criteria

1. THE `DomainSeparatedIds` SHALL expose a pure function `buildDomainSeparator(uint32 protocolVersion, bytes32 moduleName)` that returns a `bytes32` domain separator computed as `keccak256(abi.encode("TRUTHBOUNTY_V2_DOMAIN", block.chainid, protocolVersion, moduleName))`.
2. WHEN `protocolVersion` is zero, THE `DomainSeparatedIds` SHALL revert with `InvalidProtocolVersion(protocolVersion)`.
3. WHEN `moduleName` is `bytes32(0)`, THE `DomainSeparatedIds` SHALL revert with `InvalidModuleName(moduleName)`.
4. THE `DomainSeparatedIds` SHALL expose a pure helper `packVersion(uint16 major, uint16 minor)` that returns `uint32((uint32(major) << 16) | uint32(minor))`.
5. FOR ALL valid `(protocolVersion, moduleName)` pairs, calling `buildDomainSeparator` with the same inputs on the same chain SHALL return the same value (deterministic).
6. FOR ALL valid `(protocolVersion, moduleName)` pairs, calling `buildDomainSeparator` with differing `block.chainid` values SHALL return different domain separators (cross-chain uniqueness — verifiable by fuzz).

---

### Requirement 2: Claim Identifier Derivation

**User Story:** As a protocol engineer, I want claim identifiers to encode chain, module, and sequential nonce, so that cross-module references to claims cannot be confused with identifiers from other modules or deployments.

#### Acceptance Criteria

1. THE `DomainSeparatedIds` SHALL expose a pure function `claimId(bytes32 domainSeparator, uint256 nonce)` that returns `keccak256(abi.encode(domainSeparator, "CLAIM", nonce))`.
2. WHEN `domainSeparator` is `bytes32(0)`, THE `DomainSeparatedIds` SHALL revert with `InvalidDomainSeparator()`.
3. FOR ALL `(domainSeparator, nonce)` inputs, `claimId` SHALL return a unique `bytes32` for each unique `(domainSeparator, nonce)` pair (collision resistance — verifiable by fuzz).
4. FOR ALL valid inputs, `claimId(domainSeparator, nonce)` on chain A SHALL differ from `claimId(domainSeparator', nonce)` where `domainSeparator'` was built with a different chain ID (cross-chain non-aliasing property).

---

### Requirement 3: Lock Identifier Derivation

**User Story:** As a protocol engineer, I want lock identifiers to encode chain, module, asset, account, claim, round, and category, so that stake lock cells cannot be aliased across chains or modules.

#### Acceptance Criteria

1. THE `DomainSeparatedIds` SHALL expose a pure function `lockId(bytes32 domainSeparator, address asset, address account, uint256 claimNonce, uint256 round, uint8 category)` that returns `keccak256(abi.encode(domainSeparator, "LOCK", asset, account, claimNonce, round, category))`.
2. WHEN `domainSeparator` is `bytes32(0)`, THE `DomainSeparatedIds` SHALL revert with `InvalidDomainSeparator()`.
3. WHEN `asset` is `address(0)`, THE `DomainSeparatedIds` SHALL revert with `InvalidLockAsset()`.
4. WHEN `account` is `address(0)`, THE `DomainSeparatedIds` SHALL revert with `InvalidLockAccount()`.
5. FOR ALL valid `(domainSeparator, asset, account, claimNonce, round, category)` tuples, `lockId` SHALL return a unique `bytes32` for each unique tuple (collision resistance — verifiable by fuzz).

---

### Requirement 4: Dispute Identifier Derivation

**User Story:** As a protocol engineer, I want dispute identifiers to encode chain, module, claim nonce, and opener, so that disputes across modules or chains cannot reference each other's records.

#### Acceptance Criteria

1. THE `DomainSeparatedIds` SHALL expose a pure function `disputeId(bytes32 domainSeparator, uint256 claimNonce, address opener, uint256 nonce)` that returns `keccak256(abi.encode(domainSeparator, "DISPUTE", claimNonce, opener, nonce))`.
2. WHEN `domainSeparator` is `bytes32(0)`, THE `DomainSeparatedIds` SHALL revert with `InvalidDomainSeparator()`.
3. WHEN `opener` is `address(0)`, THE `DomainSeparatedIds` SHALL revert with `InvalidDisputeOpener()`.
4. FOR ALL valid `(domainSeparator, claimNonce, opener, nonce)` tuples, `disputeId` SHALL return a unique `bytes32` for each unique tuple (collision resistance — verifiable by fuzz).

---

### Requirement 5: Settlement Identifier Derivation

**User Story:** As a protocol engineer, I want settlement identifiers to encode chain, module, claim nonce, and round, so that settlement records cannot be aliased between claim-round pairs across modules.

#### Acceptance Criteria

1. THE `DomainSeparatedIds` SHALL expose a pure function `settlementId(bytes32 domainSeparator, uint256 claimNonce, uint256 round)` that returns `keccak256(abi.encode(domainSeparator, "SETTLEMENT", claimNonce, round))`.
2. WHEN `domainSeparator` is `bytes32(0)`, THE `DomainSeparatedIds` SHALL revert with `InvalidDomainSeparator()`.
3. FOR ALL `(domainSeparator, claimNonce, round)` inputs, `settlementId` SHALL return a unique `bytes32` for each unique tuple (collision resistance — verifiable by fuzz).
4. FOR ALL valid inputs, the `settlementId` for `(domainSeparator_A, n, r)` SHALL differ from `settlementId(domainSeparator_B, n, r)` when `domainSeparator_A ≠ domainSeparator_B` (cross-domain non-aliasing).

---

### Requirement 6: Reward Identifier Derivation

**User Story:** As a protocol engineer, I want reward accrual identifiers to encode chain, module, account, and claim nonce, so that reward records in one module cannot collide with records in another.

#### Acceptance Criteria

1. THE `DomainSeparatedIds` SHALL expose a pure function `rewardId(bytes32 domainSeparator, address account, uint256 claimNonce)` that returns `keccak256(abi.encode(domainSeparator, "REWARD", account, claimNonce))`.
2. WHEN `domainSeparator` is `bytes32(0)`, THE `DomainSeparatedIds` SHALL revert with `InvalidDomainSeparator()`.
3. WHEN `account` is `address(0)`, THE `DomainSeparatedIds` SHALL revert with `InvalidRewardAccount()`.
4. FOR ALL valid `(domainSeparator, account, claimNonce)` tuples, `rewardId` SHALL return a unique `bytes32` for each unique tuple (collision resistance — verifiable by fuzz).

---

### Requirement 7: Governance Identifier Derivation

**User Story:** As a protocol engineer, I want governance action identifiers to encode chain, module, target, selector, and a nonce, so that governance actions cannot be replayed or confused across modules or chains.

#### Acceptance Criteria

1. THE `DomainSeparatedIds` SHALL expose a pure function `governanceId(bytes32 domainSeparator, address target, bytes4 selector, uint256 nonce)` that returns `keccak256(abi.encode(domainSeparator, "GOVERNANCE", target, selector, nonce))`.
2. WHEN `domainSeparator` is `bytes32(0)`, THE `DomainSeparatedIds` SHALL revert with `InvalidDomainSeparator()`.
3. WHEN `target` is `address(0)`, THE `DomainSeparatedIds` SHALL revert with `InvalidGovernanceTarget()`.
4. FOR ALL valid `(domainSeparator, target, selector, nonce)` tuples, `governanceId` SHALL return a unique `bytes32` for each unique tuple (collision resistance — verifiable by fuzz).
5. FOR ALL valid inputs, two calls with identical `(target, selector, nonce)` but different `domainSeparator` values SHALL return different identifiers (cross-domain replay prevention).

---

### Requirement 8: Domain Separator Caching in Modules

**User Story:** As a protocol engineer, I want each V2 module contract to cache its domain separator at construction time, so that identifier derivation is gas-efficient and the domain is immutable after deployment.

#### Acceptance Criteria

1. WHEN a V2 module contract that uses `DomainSeparatedIds` is deployed, THE module SHALL compute and store its domain separator as an `immutable bytes32` using `DomainSeparatedIds.buildDomainSeparator(DomainSeparatedIds.packVersion(major, minor), MODULE_NAME)`.
2. WHEN an invalid `protocolVersion` or `moduleName` would produce a zero domain separator, THE module constructor SHALL revert, failing closed on misconfiguration.
3. THE cached domain separator SHALL be exposed via a `public immutable` state variable named `DOMAIN_SEPARATOR` to enable off-chain verification.
4. WHILE a module is deployed, THE module SHALL use only its cached `DOMAIN_SEPARATOR` for all identifier derivations, never recomputing dynamically from mutable state.

---

### Requirement 9: StakeVault Lock Key Migration

**User Story:** As a protocol engineer, I want the StakeVault `_lockKey` function to use domain-separated identifiers, so that lock cells are chain- and module-unique and cannot be aliased across deployments.

#### Acceptance Criteria

1. THE `StakeVault` SHALL replace its current `_lockKey(asset, account, claimId, round, category)` implementation with one that calls `DomainSeparatedIds.lockId(DOMAIN_SEPARATOR, asset, account, claimId, round, uint8(category))`.
2. WHEN `StakeVault` is deployed, THE `StakeVault` SHALL initialize its `DOMAIN_SEPARATOR` using `DomainSeparatedIds.buildDomainSeparator(DomainSeparatedIds.packVersion(2, 0), keccak256("STAKE_VAULT"))`.
3. IF the computed domain separator is `bytes32(0)` at construction, THEN THE `StakeVault` constructor SHALL revert.
4. THE existing `StakeVault` public API (deposit, lock, unlock, withdraw, settlement hooks) SHALL remain unchanged after the migration.
5. FOR ALL valid lock operations, the domain-separated lock key SHALL be globally unique per `(chainId, protocolVersion, module, asset, account, claimId, round, category)` tuple (verifiable by invariant test).

---

### Requirement 10: GovernanceHooks Action Identifier Migration

**User Story:** As a protocol engineer, I want governance action identifiers produced by `GovernanceHooks` to use domain-separated derivation, so that governance actions cannot be replayed from another chain or module.

#### Acceptance Criteria

1. THE `GovernanceHooks` module SHALL derive action authorization identifiers using `DomainSeparatedIds.governanceId(DOMAIN_SEPARATOR, target, selector, nonce)` rather than accepting bare caller-supplied `bytes32 actionId` values.
2. WHEN `GovernanceHooks` is deployed, THE `GovernanceHooks` SHALL initialize its `DOMAIN_SEPARATOR` using `DomainSeparatedIds.buildDomainSeparator(DomainSeparatedIds.packVersion(2, 0), keccak256("GOVERNANCE_HOOKS"))`.
3. IF a caller supplies an `actionId` that does not match the library-derived value for the given `(target, selector, nonce)`, THEN THE `GovernanceHooks` SHALL revert with `InvalidActionId()`.
4. FOR ALL valid `(target, selector, nonce)` inputs, the derived `governanceId` SHALL be unique (verifiable by fuzz test).

---

### Requirement 11: Error Surface Extension

**User Story:** As a protocol engineer, I want all domain-separation failures to produce descriptive custom errors, so that integrators and monitoring systems can distinguish misconfiguration from authorization failures.

#### Acceptance Criteria

1. THE `DomainSeparatedIds` library SHALL define and use the following custom errors: `InvalidProtocolVersion(uint32 version)`, `InvalidModuleName(bytes32 name)`, `InvalidDomainSeparator()`, `InvalidLockAsset()`, `InvalidLockAccount()`, `InvalidDisputeOpener()`, `InvalidRewardAccount()`, `InvalidGovernanceTarget()`.
2. THE `V2Errors` library SHALL expose a new error `InvalidActionId()` for governance identifier mismatch.
3. WHEN any identifier derivation function receives an invalid zero-value input, THE function SHALL revert with the specific error corresponding to that parameter, not a generic revert.

---

### Requirement 12: NatSpec, Events, and Public Surface Documentation

**User Story:** As a protocol auditor, I want every new public function and event to have complete NatSpec documentation, so that the security properties can be reviewed and verified without examining implementation internals.

#### Acceptance Criteria

1. THE `DomainSeparatedIds` library SHALL include `@title`, `@notice`, and `@dev` NatSpec on the library declaration.
2. THE `DomainSeparatedIds` library SHALL include `@notice` and `@param` NatSpec on every public or external function.
3. WHEN a module caches its domain separator, THE module SHALL emit a `DomainSeparatorSet(bytes32 indexed domainSeparator, bytes32 indexed moduleName, uint32 protocolVersion)` event from its constructor or initializer.
4. THE `DomainSeparatorSet` event SHALL be defined in an `IDomainSeparated` interface that modules implementing domain separation MUST inherit.
5. THE `IDomainSeparated` interface SHALL include `@notice` NatSpec on the event and a `domainSeparator()` view function that returns the module's cached `DOMAIN_SEPARATOR`.

---

### Requirement 13: Test Coverage — Unit, Fuzz, and Invariant

**User Story:** As a protocol engineer, I want comprehensive test coverage for all domain-separated identifier functions, so that the security property (no aliasing) is demonstrated to hold across all valid inputs and boundary conditions.

#### Acceptance Criteria

1. THE test suite SHALL include unit tests for success paths covering all six identifier types: claim, lock, dispute, settlement, reward, and governance.
2. THE test suite SHALL include unit tests for boundary conditions: zero `nonce`, maximum `uint256` nonce, zero `round`, maximum `round`, all `LockCategory` values including `NONE`.
3. THE test suite SHALL include unit tests for authorization failure paths: invalid domain separator, zero asset, zero account, zero opener, zero target.
4. THE test suite SHALL include fuzz tests (Foundry `invariant` or `fuzz` test functions) that assert: for any two distinct valid input tuples, the derived identifiers differ (collision resistance).
5. THE test suite SHALL include a regression test that demonstrates identifiers derived without domain separation (the prior `_lockKey` pattern: `keccak256(abi.encode(asset, account, claimId, round, category))`) collide when the same `(asset, account, claimId, round, category)` is used by two different modules on different chains — and that the new domain-separated derivation prevents this collision.
6. THE test suite SHALL include invariant tests for `StakeVault` that assert custody reconciliation (`obligations <= custody`) holds after any sequence of domain-separated lock operations.
7. WHEN the complete Foundry CI suite is run against the final commit, THE suite SHALL pass with zero failing tests across build, unit, fuzz, invariant, gas, and static-analysis checks.

---

### Requirement 14: No Legacy or Out-of-Scope Changes

**User Story:** As a protocol maintainer, I want the implementation to be strictly scoped to domain-separated identifier derivation, so that unrelated modules are not inadvertently changed and the PR remains independently reviewable.

#### Acceptance Criteria

1. THE implementation SHALL NOT modify any V1 contract, legacy path, or any module outside the scope of Requirement 9 (`StakeVault`) and Requirement 10 (`GovernanceHooks`) and the new `DomainSeparatedIds` library plus `IDomainSeparated` interface.
2. THE implementation SHALL NOT introduce Stellar, Soroban, or Freighter runtime dependencies in any Solidity, TypeScript, or configuration file.
3. THE implementation SHALL NOT embed placeholder, test, or production private keys, RPC URLs, or secret values in any committed file.
4. IF any module other than `StakeVault` or `GovernanceHooks` requires cross-module identifier changes, THEN THE PR description SHALL document the additional scope change and obtain explicit maintainer approval before merging.
5. THE implementation SHALL preserve all existing `StakeVault` and `GovernanceHooks` public API surfaces without breaking changes to function signatures or event topics that downstream indexers depend on.
