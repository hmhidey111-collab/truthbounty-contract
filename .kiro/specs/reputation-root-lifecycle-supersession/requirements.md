# Requirements Document

## Introduction

V2-SC-063 implements the Reputation Root Lifecycle and Supersession Rules for the TruthBounty V2 protocol. The feature introduces a `ReputationRootRegistry` contract that manages the complete on-chain lifecycle of Merkle roots used for off-chain reputation proof verification.

The registry enforces seven core properties: (1) monotonic version enforcement — every newly published root must carry a strictly higher version number than the current active root; (2) activation delays — a published root enters a `PENDING` state and only becomes `ACTIVE` after a configurable delay period has elapsed, providing a challenge window; (3) issuer authorization — only addresses holding `ISSUER_ROLE` may publish new roots; (4) supersession — publishing a new root while an existing root is `PENDING` immediately invalidates the superseded root before the new one enters `PENDING`; (5) emergency invalidation — addresses holding `ADMIN_ROLE` may immediately invalidate the current `ACTIVE` root, triggering fallback to the last known valid root; (6) immutable historical lookup — every published root is permanently recorded and queryable by version number; (7) the single-active invariant — at most one root is `ACTIVE` at any point in time, and a `PENDING` root MUST NOT be used for proof verification until its activation timestamp has passed.

The implementation targets Optimism/EVM exclusively. It must preserve canonical V2 state transitions and must not introduce Stellar, Soroban, or Freighter runtime dependencies. All paths must fail closed on invalid configuration, authorization, version mismatch, and external-call failure. Every new public surface must carry NatSpec, events, and custom errors. The complete CI suite (build, unit, fuzz, invariant, gas, static-analysis, artifact) must pass on the final commit.

Dependencies: V2-SC-024 (issuer role framework), V2-SC-030 (root commitment primitives).

Non-Goals: production mainnet deployment, backend-authoritative protocol mutation, reintroducing or extending the V1 canonical path.

---

## Glossary

- **ReputationRootRegistry**: The new V2 contract introduced by this spec that manages the full lifecycle of reputation Merkle roots, including publishing, activation delay enforcement, supersession, emergency invalidation, and historical lookup.
- **Merkle_Root**: A `bytes32` value representing the root of a Merkle tree whose leaves encode individual user reputation scores. Published on-chain; used off-chain for proof generation and verification.
- **Root_Version**: A monotonically increasing `uint256` assigned to each published root by the issuer. Every new `Root_Version` MUST be strictly greater than the `Root_Version` of the current `ACTIVE` root.
- **Root_State**: The lifecycle phase of a specific root entry. Valid values: `NONE` (never published), `PENDING` (published but activation delay not yet elapsed), `ACTIVE` (activation delay has elapsed; may be used for proof verification), `SUPERSEDED` (replaced by a newer `PENDING` root before becoming `ACTIVE`), `INVALIDATED` (emergency-invalidated by an admin while `ACTIVE`).
- **Activation_Delay**: A configurable `uint64` duration (in seconds) that must elapse between a root's publication timestamp and its eligibility to become `ACTIVE`. Stored in `ReputationRootRegistry.activationDelay`.
- **Activation_Timestamp**: The `uint64` value `block.timestamp + activationDelay` recorded when a root is published. A root MAY be promoted to `ACTIVE` only after `block.timestamp >= activationTimestamp`.
- **ISSUER_ROLE**: The `bytes32` role constant `keccak256("ISSUER_ROLE")` that authorizes an address to publish new reputation roots.
- **ADMIN_ROLE**: The `bytes32` role constant `keccak256("ADMIN_ROLE")` that authorizes an address to perform emergency invalidation of the current active root and to configure registry parameters.
- **Active_Root**: The single root entry whose `Root_State` is `ACTIVE`. There is at most one `Active_Root` at any time. If no root has been activated or the last active root was invalidated without a fallback, the `Active_Root` is undefined (zero values returned).
- **Pending_Root**: The single root entry whose `Root_State` is `PENDING`. There is at most one `Pending_Root` at any time. A `Pending_Root` MUST NOT be used for proof verification.
- **Supersession**: The act of transitioning the current `Pending_Root` to `Root_State.SUPERSEDED` when a new root is published while a `Pending_Root` already exists.
- **Emergency_Invalidation**: The act of transitioning the current `Active_Root` to `Root_State.INVALIDATED` immediately upon an `ADMIN_ROLE` call, bypassing the activation delay.
- **Fallback_Root**: The most recent root entry in `Root_State.ACTIVE` whose version is strictly less than the invalidated root's version. After emergency invalidation, the registry reports the `Fallback_Root` as the current active root until a new root completes its activation delay.
- **Root_Record**: The immutable struct stored per `Root_Version` containing: `bytes32 merkleRoot`, `uint256 version`, `address issuer`, `uint64 publishedAt`, `uint64 activationTimestamp`, `Root_State state`.
- **Historical_Lookup**: The `getRootByVersion(uint256 version)` view function that returns the `Root_Record` for any previously published version. Records are never deleted or overwritten.
- **Single_Active_Invariant**: The mathematical property that at most one `Root_Record` in the registry has `Root_State.ACTIVE` at any block. Verifiable as a Foundry invariant test.
- **NatSpec**: The Ethereum Natural Language Specification Format used for Solidity documentation.
- **V2Errors**: The shared custom-error library (`contracts/v2/libraries/V2Errors.sol`) extended by this feature.

---

## Requirements

---

### Requirement 1: Root Publication and Activation Delay

**User Story:** As a protocol issuer, I want to publish a new reputation Merkle root that enters a pending state before becoming active, so that the system has a challenge window during which errors can be caught before proofs are accepted.

#### Acceptance Criteria

1. WHEN `publishRoot(bytes32 merkleRoot, uint256 version)` is called by an address holding `ISSUER_ROLE`, THE `ReputationRootRegistry` SHALL record a new `Root_Record` with `state = Root_State.PENDING`, `publishedAt = block.timestamp`, and `activationTimestamp = block.timestamp + activationDelay`.
2. WHEN a root is published, THE `ReputationRootRegistry` SHALL emit `RootPublished(uint256 indexed version, bytes32 indexed merkleRoot, address indexed issuer, uint64 activationTimestamp)`.
3. WHILE a root's `Root_State` is `PENDING` (i.e., `block.timestamp < activationTimestamp`), THE `ReputationRootRegistry` SHALL return `false` from `isRootActive(uint256 version)`.
4. WHEN `block.timestamp >= activationTimestamp` for a root in `Root_State.PENDING`, THE `ReputationRootRegistry` SHALL permit `activateRoot(uint256 version)` to transition the root's state to `Root_State.ACTIVE`.
5. WHEN `activateRoot(uint256 version)` is called before the root's `activationTimestamp` has elapsed, THE `ReputationRootRegistry` SHALL revert with `ActivationDelayNotElapsed(uint256 version, uint64 activationTimestamp, uint64 currentTimestamp)`.
6. WHEN `publishRoot` is called with `merkleRoot == bytes32(0)`, THE `ReputationRootRegistry` SHALL revert with `ZeroMerkleRoot()`.
7. IF `publishRoot` is called by any address that does not hold `ISSUER_ROLE`, THEN THE `ReputationRootRegistry` SHALL revert with `V2Errors.Unauthorized()`.

---

### Requirement 2: Monotonic Version Enforcement

**User Story:** As a protocol engineer, I want each new root publication to carry a strictly higher version number than the current active root, so that the version sequence provides a tamper-evident ordering and prevents version replay attacks.

#### Acceptance Criteria

1. THE `ReputationRootRegistry` SHALL maintain a `uint256 latestVersion` that records the highest version number of any published root (regardless of current state).
2. WHEN `publishRoot` is called with `version <= latestVersion`, THE `ReputationRootRegistry` SHALL revert with `NonMonotonicVersion(uint256 provided, uint256 required)` where `required = latestVersion + 1` (minimum valid next version).
3. WHEN `publishRoot` is called with `version > latestVersion`, THE `ReputationRootRegistry` SHALL accept the root and update `latestVersion = version`.
4. WHEN `publishRoot` is called with `version == latestVersion + 1`, THE `ReputationRootRegistry` SHALL accept the root without reverting (exact-increment path).
5. WHEN `publishRoot` is called with a `version` that was previously used (including versions from roots now in `SUPERSEDED` or `INVALIDATED` state), THE `ReputationRootRegistry` SHALL revert with `NonMonotonicVersion(uint256 provided, uint256 required)`.
6. FOR ALL valid sequences of `publishRoot` calls, the version sequence SHALL be strictly monotonically increasing (verifiable by fuzz test asserting that every accepted publication increments `latestVersion`).

---

### Requirement 3: Issuer Authorization

**User Story:** As a protocol operator, I want only addresses holding the ISSUER_ROLE to be able to publish new reputation roots, so that unauthorized parties cannot inject malicious root values.

#### Acceptance Criteria

1. THE `ReputationRootRegistry` SHALL define `bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE")`.
2. WHEN `publishRoot` is called by any address that does not hold `ISSUER_ROLE`, THE `ReputationRootRegistry` SHALL revert with `V2Errors.Unauthorized()` before reading or writing any root state.
3. WHEN `ADMIN_ROLE` grants `ISSUER_ROLE` to an address, THE `ReputationRootRegistry` SHALL immediately authorize that address to call `publishRoot` on the next transaction.
4. WHEN `ADMIN_ROLE` revokes `ISSUER_ROLE` from an address, THE `ReputationRootRegistry` SHALL immediately deny that address from calling `publishRoot` on all subsequent transactions.
5. THE `ReputationRootRegistry` SHALL use OpenZeppelin `AccessControl` for all role management, inheriting `DEFAULT_ADMIN_ROLE` as the role admin for both `ISSUER_ROLE` and `ADMIN_ROLE`.
6. FOR ALL unauthorized callers (any address not holding `ISSUER_ROLE`), calling `publishRoot` SHALL revert with `V2Errors.Unauthorized()` (verifiable by unit test for address(0), address(1), and a fuzz-generated address set).

---

### Requirement 4: Supersession of Pending Roots

**User Story:** As a protocol issuer, I want publishing a new root to automatically supersede any currently pending root, so that only the most recent published root can become active and there is never more than one root awaiting activation.

#### Acceptance Criteria

1. WHEN `publishRoot` is called and a root in `Root_State.PENDING` already exists, THE `ReputationRootRegistry` SHALL transition the existing `Pending_Root` to `Root_State.SUPERSEDED` atomically before recording the new root as `PENDING`.
2. WHEN a root is superseded, THE `ReputationRootRegistry` SHALL emit `RootSuperseded(uint256 indexed supersededVersion, uint256 indexed newVersion, address indexed issuer)`.
3. WHEN a root has been superseded, THE `ReputationRootRegistry` SHALL return `Root_State.SUPERSEDED` from `getRootByVersion(supersededVersion).state`.
4. WHEN a root has been superseded, THE `ReputationRootRegistry` SHALL return `false` from `isRootActive(supersededVersion)` for all time.
5. WHEN `publishRoot` is called and no root is currently in `Root_State.PENDING`, THE `ReputationRootRegistry` SHALL NOT emit `RootSuperseded` (no spurious supersession events).
6. FOR ALL valid sequences of `publishRoot` calls (any number of rapid re-publications), at most one `Root_Record` SHALL have `Root_State.PENDING` at any block (verifiable by invariant test asserting `pendingRootCount <= 1`).
7. FOR ALL superseded roots, the `Root_Record` SHALL remain queryable via `getRootByVersion` and the stored `merkleRoot`, `version`, `issuer`, and `publishedAt` fields SHALL be immutable after publication.

---

### Requirement 5: Emergency Invalidation and Fallback

**User Story:** As a protocol admin, I want to immediately invalidate the currently active root if a security issue is discovered, and have the registry fall back to the last known valid root, so that the protocol can respond to compromised roots without a full shutdown.

#### Acceptance Criteria

1. WHEN `invalidateActiveRoot()` is called by an address holding `ADMIN_ROLE`, THE `ReputationRootRegistry` SHALL transition the current `Active_Root` to `Root_State.INVALIDATED` and emit `RootInvalidated(uint256 indexed version, address indexed admin)`.
2. WHEN the current `Active_Root` is invalidated, THE `ReputationRootRegistry` SHALL locate the `Fallback_Root` — the highest-version root with `Root_State.ACTIVE` whose version is strictly less than the invalidated root's version — and record it as the current active version pointer.
3. WHEN no `Fallback_Root` exists (the first-ever active root is invalidated), THE `ReputationRootRegistry` SHALL set the current active version pointer to zero and return zero values from `getActiveRoot()`.
4. WHEN `invalidateActiveRoot()` is called and no root is currently in `Root_State.ACTIVE`, THE `ReputationRootRegistry` SHALL revert with `NoActiveRoot()`.
5. IF `invalidateActiveRoot()` is called by any address that does not hold `ADMIN_ROLE`, THEN THE `ReputationRootRegistry` SHALL revert with `V2Errors.Unauthorized()`.
6. WHEN an invalidated root's version is queried via `getRootByVersion`, THE `ReputationRootRegistry` SHALL return `Root_State.INVALIDATED` in the returned `Root_Record`, and `isRootActive(version)` SHALL return `false`.
7. WHEN `invalidateActiveRoot()` is called, THE `ReputationRootRegistry` SHALL emit `ActiveRootChanged(uint256 indexed previousVersion, uint256 indexed newVersion)` where `newVersion` is the fallback version (or zero if no fallback exists).

---

### Requirement 6: Immutable Historical Lookup

**User Story:** As a protocol auditor or off-chain verifier, I want to look up any historically published root by its version number and receive its complete record, so that historical proofs can always be reconstructed and audit trails remain intact.

#### Acceptance Criteria

1. THE `ReputationRootRegistry` SHALL expose `getRootByVersion(uint256 version) external view returns (Root_Record memory)` that returns the full `Root_Record` for any version that has ever been published.
2. WHEN `getRootByVersion` is called with a version that has never been published, THE `ReputationRootRegistry` SHALL revert with `RootVersionNotFound(uint256 version)`.
3. THE `ReputationRootRegistry` SHALL expose `isRootActive(uint256 version) external view returns (bool)` that returns `true` if and only if the root at that version currently has `Root_State.ACTIVE`.
4. THE `ReputationRootRegistry` SHALL expose `getActiveRoot() external view returns (Root_Record memory)` that returns the `Root_Record` of the current `Active_Root`, or reverts with `NoActiveRoot()` if no root is active.
5. FOR ALL published roots (in any state), the stored `merkleRoot`, `version`, `issuer`, `publishedAt`, and `activationTimestamp` fields in `Root_Record` SHALL be immutable after the root is published — no write path SHALL overwrite these fields.
6. FOR ALL versions that have ever been published, `getRootByVersion(version)` SHALL return a non-reverting result for the lifetime of the contract (verifiable by fuzz test asserting that any version in `[1, latestVersion]` returns a record without reverting).
7. THE `ReputationRootRegistry` SHALL expose `latestVersion() external view returns (uint256)` to allow off-chain systems to enumerate all published versions.

---

### Requirement 7: Single-Active Invariant and Proof Verification Gate

**User Story:** As a protocol engineer, I want the registry to enforce that at most one root is active at any time and that pending roots cannot be used for proof verification, so that there is always a single canonical source of truth for reputation scores.

#### Acceptance Criteria

1. THE `ReputationRootRegistry` SHALL maintain a `uint256 activeVersion` pointer that tracks the version number of the current `Active_Root` (zero if no root is active).
2. WHEN `activateRoot(uint256 version)` is called for a `PENDING` root whose `activationTimestamp` has elapsed, THE `ReputationRootRegistry` SHALL set `activeVersion = version`, transition the root's state to `ACTIVE`, emit `RootActivated(uint256 indexed version, bytes32 indexed merkleRoot)`, and emit `ActiveRootChanged(uint256 indexed previousVersion, uint256 indexed newVersion)`.
3. WHEN `activateRoot` is called for a root that is not in `Root_State.PENDING`, THE `ReputationRootRegistry` SHALL revert with `InvalidRootStateTransition(uint256 version, Root_State currentState, Root_State requiredState)`.
4. WHEN `isRootActive(uint256 version)` returns `true`, THE root's `activationTimestamp` SHALL be in the past (i.e., `activationTimestamp <= block.timestamp`).
5. THE `ReputationRootRegistry` SHALL expose `canVerifyProof(uint256 version) external view returns (bool)` that returns `true` if and only if `isRootActive(version)` is `true`, providing an explicit proof-verification gate for callers.
6. FOR ALL blocks, the count of roots with `Root_State.ACTIVE` SHALL be at most one (verifiable by Foundry invariant test asserting `activeRootCount() <= 1` with `runs = 500, depth = 20`).
7. WHEN `activateRoot` is called for a root in `Root_State.PENDING` and the prior `activeVersion` pointed to an existing `ACTIVE` root, THE `ReputationRootRegistry` SHALL transition the prior `ACTIVE` root to `Root_State.SUPERSEDED` before setting the new `activeVersion` (preventing two simultaneous active roots from any race path).

---

### Requirement 8: Activation Delay Configuration

**User Story:** As a protocol admin, I want to configure the activation delay duration, so that the challenge window can be adjusted as protocol maturity and security requirements evolve.

#### Acceptance Criteria

1. THE `ReputationRootRegistry` SHALL expose `setActivationDelay(uint64 newDelay)` callable only by an address holding `ADMIN_ROLE`.
2. WHEN `setActivationDelay` is called, THE `ReputationRootRegistry` SHALL update `activationDelay` and emit `ActivationDelayUpdated(uint64 indexed previousDelay, uint64 indexed newDelay)`.
3. WHEN `setActivationDelay` is called with `newDelay == 0`, THE `ReputationRootRegistry` SHALL accept the value (zero delay is valid — roots become activatable immediately after publication) and emit the event.
4. IF `setActivationDelay` is called by any address that does not hold `ADMIN_ROLE`, THEN THE `ReputationRootRegistry` SHALL revert with `V2Errors.Unauthorized()`.
5. WHEN the `activationDelay` is updated, THE new delay SHALL apply only to roots published AFTER the update — previously published `PENDING` roots SHALL retain their original `activationTimestamp`.
6. THE `ReputationRootRegistry` SHALL expose `activationDelay() external view returns (uint64)` to allow off-chain systems to query the current delay.
7. WHEN the `ReputationRootRegistry` constructor is called with `initialActivationDelay`, THE `activationDelay` SHALL be set to `initialActivationDelay` (including zero) without reverting.

---

### Requirement 9: Fail-Closed on Invalid Configuration and External-Call Outcomes

**User Story:** As a protocol engineer, I want the registry to fail closed on all invalid configuration, authorization, and state transition attempts, so that an improperly configured or attacked deployment cannot corrupt the root state.

#### Acceptance Criteria

1. WHEN `ReputationRootRegistry` is deployed with `initialAdmin == address(0)`, THE constructor SHALL revert with `V2Errors.ZeroAddress()`.
2. WHEN `publishRoot` is called with `merkleRoot == bytes32(0)`, THE `ReputationRootRegistry` SHALL revert with `ZeroMerkleRoot()` before writing any state.
3. WHEN `publishRoot` is called with `version == 0`, THE `ReputationRootRegistry` SHALL revert with `NonMonotonicVersion(0, 1)` (version zero is never valid; the minimum valid version is 1).
4. WHEN `activateRoot` is called for a root in `Root_State.NONE` (version never published), THE `ReputationRootRegistry` SHALL revert with `RootVersionNotFound(uint256 version)`.
5. WHEN `activateRoot` is called for a root already in `Root_State.ACTIVE`, `Root_State.SUPERSEDED`, or `Root_State.INVALIDATED`, THE `ReputationRootRegistry` SHALL revert with `InvalidRootStateTransition(version, currentState, Root_State.PENDING)`.
6. WHEN any state-mutating function is called during a re-entrant call (if the registry is extended with external hooks in future), THE `ReputationRootRegistry` SHALL be protected by `ReentrancyGuard` inherited from OpenZeppelin.
7. IF any constructor parameter is zero where non-zero is required, THEN THE `ReputationRootRegistry` constructor SHALL revert with `V2Errors.ZeroAddress()` or `ZeroMerkleRoot()` as applicable, leaving no contract state deployed.

---

### Requirement 10: Events and NatSpec on Every New Public Surface

**User Story:** As a protocol auditor, I want every new public function, event, and custom error to be fully documented with NatSpec and emitted events, so that on-chain behaviour is observable and security properties can be reviewed without reading implementation internals.

#### Acceptance Criteria

1. THE `ReputationRootRegistry` SHALL define and emit the following events, each with indexed fields where applicable:
   - `RootPublished(uint256 indexed version, bytes32 indexed merkleRoot, address indexed issuer, uint64 activationTimestamp)`
   - `RootActivated(uint256 indexed version, bytes32 indexed merkleRoot)`
   - `RootSuperseded(uint256 indexed supersededVersion, uint256 indexed newVersion, address indexed issuer)`
   - `RootInvalidated(uint256 indexed version, address indexed admin)`
   - `ActiveRootChanged(uint256 indexed previousVersion, uint256 indexed newVersion)`
   - `ActivationDelayUpdated(uint64 indexed previousDelay, uint64 indexed newDelay)`
2. THE `ReputationRootRegistry` SHALL define the following custom errors:
   - `ZeroMerkleRoot()`
   - `NonMonotonicVersion(uint256 provided, uint256 required)`
   - `ActivationDelayNotElapsed(uint256 version, uint64 activationTimestamp, uint64 currentTimestamp)`
   - `NoActiveRoot()`
   - `RootVersionNotFound(uint256 version)`
   - `InvalidRootStateTransition(uint256 version, Root_State currentState, Root_State requiredState)`
3. THE `ReputationRootRegistry` interface (`IReputationRootRegistry`) SHALL include `@title`, `@notice`, and `@dev` NatSpec on the interface declaration.
4. THE `ReputationRootRegistry` interface SHALL include `@notice` and `@param` and `@return` NatSpec on every public or external function signature.
5. THE `ReputationRootRegistry` interface SHALL include `@notice` NatSpec on every event and error declaration.
6. WHEN new `V2Errors` entries are required by this feature, THE `V2Errors` library SHALL include `@notice` NatSpec on each new error declaration.

---

### Requirement 11: Test Coverage — Unit, Fuzz, and Invariant

**User Story:** As a protocol engineer, I want comprehensive test coverage across all root lifecycle paths, so that the correctness and security properties are demonstrated to hold under all valid inputs, boundary conditions, and adversarial orderings.

#### Acceptance Criteria

1. THE test suite SHALL include Foundry unit tests for every success path: publish → pending, pending → active (after delay), publish-while-pending → supersede-old + new-pending, active → invalidated (with fallback), active → invalidated (no fallback, zero activeVersion).
2. THE test suite SHALL include Foundry unit tests for all boundary conditions: `version = latestVersion + 1` (minimum valid increment), `version = type(uint256).max` (maximum version), `activationDelay = 0` (immediate activation eligibility), `activationDelay = type(uint64).max` (maximum delay).
3. THE test suite SHALL include Foundry unit tests for all authorization failure paths: non-issuer calling `publishRoot`, non-admin calling `invalidateActiveRoot`, non-admin calling `setActivationDelay`, unauthorized caller calling `activateRoot` before delay (any caller may call `activateRoot` after delay but state MUST be enforced regardless).
4. THE test suite SHALL include Foundry fuzz tests asserting: for any valid `(merkleRoot, version)` tuple where `version > latestVersion`, a published root is recorded in `Root_State.PENDING` and `isRootActive(version)` returns `false` until `activationTimestamp` has elapsed.
5. THE test suite SHALL include a Foundry invariant test for `ReputationRootRegistry` asserting the Single_Active_Invariant holds over any sequence of lifecycle operations (publish, activate, supersede, invalidate), configured with `runs = 500, depth = 20`.
6. THE test suite SHALL include a round-trip property test: for any published and activated root, `getActiveRoot().merkleRoot == merkleRoot` and `getRootByVersion(version).merkleRoot == merkleRoot` (immutability of stored root data after write).
7. THE test suite SHALL include a regression test demonstrating that `isRootActive` returns `false` for a `PENDING` root before its `activationTimestamp`, and `true` after — confirming the activation delay gate prevents premature proof verification.
8. THE test suite SHALL include a fuzz test asserting that any sequence of `publishRoot` calls produces strictly increasing `latestVersion` values and that duplicate or retrograde versions always revert.
9. WHEN the complete Foundry CI suite is run on the final commit, THE suite SHALL produce zero failing tests across build, unit, fuzz, invariant, gas, and static-analysis checks.

---

### Requirement 12: No Unrelated Refactoring and Strict Scope Boundary

**User Story:** As a protocol maintainer, I want the implementation to be strictly scoped to the reputation root lifecycle and supersession rules, so that the PR remains independently reviewable and does not introduce unrelated risk.

#### Acceptance Criteria

1. THE implementation SHALL NOT modify any V1 contract (including any file under `contracts/` that is not in the `contracts/v2/` subtree), any module outside `ReputationRootRegistry`, `IReputationRootRegistry`, and `V2Errors` (new error additions only). Any modification to a V1 contract violates this constraint regardless of whether routing flows through V2.
2. THE implementation SHALL NOT introduce Stellar, Soroban, or Freighter runtime dependencies in any Solidity, TypeScript, or configuration file.
3. THE implementation SHALL NOT embed placeholder, test, or production private keys, RPC URLs, or secret values in any committed file.
4. THE implementation SHALL NOT reintroduce or extend the V1 legacy path as a canonical module; all root lifecycle transitions SHALL flow through `contracts/v2/ReputationRootRegistry.sol` via `IReputationRootRegistry`.
5. IF the implementation requires modifying any module outside the stated scope, THEN THE PR description SHALL document the additional scope change and obtain explicit maintainer review and approval before merging.
6. THE implementation SHALL preserve all existing V2 module public API surfaces without breaking changes to existing function signatures or event topics.
