// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title V2Errors
/// @notice Canonical custom-error catalog for the TruthBounty V2 protocol.
/// @dev Revert taxonomy (machine-readable, no string reasons):
///
///      | Domain            | Selector family                         | Fail-closed on                          |
///      |-------------------|-----------------------------------------|-----------------------------------------|
///      | Auth / access     | Unauthorized*, ZeroAddress, Zero*       | Missing role, zero identity             |
///      | Claims            | Claim*, CanonicalClaim*, InvalidClaim*  | Missing / duplicate / illegal transition |
///      | Evidence          | Evidence*, DuplicateEvidence, ZeroDigest| Window, digest, nonce, duplicate        |
///      | Verification      | Verification*, AlreadyVerified, Verdict | Window / stake / verdict                |
///      | Settlement        | Settlement*, InvalidRoundTransfer       | Timing, outcome, round integrity        |
///      | Disputes          | Dispute*                                | Window / duplicate / reason             |
///      | Stake / custody   | Insufficient*, UnsupportedAsset, …      | Balances, assets, conservation          |
///      | Aggregation       | InvalidAggregation*, Reputation*        | Score / update failures                 |
///      | Configuration     | Invalid*Range/Duration/Bps, Parameter*  | Invalid set invariants                   |
///      | Governance        | NotGovernance, ZeroGuardian*, Module*   | Authority / allowlist                   |
///      | Slashing          | Slash*, SlashingNotPermitted            | Over-slash / policy                     |
///      | Emergency         | ProtocolPaused, EmergencyAuthority*     | Pause / guardian path                   |
///      | Integer widths    | SafeCastOverflow, SafeCastNegative      | Narrowing past the field's width        |
///
///      Modules MUST revert with these selectors (via `V2Errors.<Error>`) instead of
///      `require`/`revert` string reasons or ad-hoc local errors that collide by name
///      but differ by ABI. Prefer typed parameters over `string` reasons.
library V2Errors {
    // =========================================================================
    // Authorization & Access Control
    // =========================================================================

    /// @notice Attempted action by unauthorized caller.
    error Unauthorized();

    /// @notice Attempted action by address(0).
    error ZeroAddress();

    /// @notice Attempted action with zero amount.
    error ZeroAmount();

    /// @notice Stake amount is below the configured anti-dust floor (V2-SC-105).
    error DustStake(uint256 provided, uint256 minimum);

    /// @notice Claim creation exceeded the per-account anti-spam budget (V2-SC-105).
    error ClaimSpamRateExceeded(address account, uint256 count, uint256 limit);

    /// @notice Creator holds too many non-terminal claims (V2-SC-105).
    error TooManyOpenClaims(address account, uint256 count, uint256 limit);
    /// @notice Claim metadata exceeded its published calldata budget.
    error ClaimMetadataTooLarge(uint256 provided, uint256 maximum);


    /// @notice Attempted action by an unregistered or unauthorized module.
    /// @param caller Address that failed the module authorization check.
    error UnauthorizedModule(address caller);

    /// @notice A module registry batch exceeded its published item limit.
    error RegistryBatchTooLarge(uint256 provided, uint256 maximum);
    /// @notice Registering modules would exceed the bounded module catalog.
    error RegisteredModuleLimitExceeded(uint256 provided, uint256 maximum);

    /// @notice Zero admin address supplied at construction.
    error ZeroAdmin();

    /// @notice Zero claim-registry address supplied at construction.
    error ZeroClaimRegistry();

    /// @notice Zero relayer address supplied for an authorized relayer change.
    error ZeroRelayer();

    /// @notice Zero timelock address supplied for a cooldown change.
    error ZeroTimelock();

    /// @notice Zero allowance target supplied for an allowance change.
    error ZeroAllowanceTarget();

    /// @notice Authorized relayer was updated.
    /// @param previous Previous authorized relayer.
    /// @param current New authorized relayer.
    event RelayerUpdated(address indexed previous, address indexed current);

    /// @notice Timelock cooldown was updated.
    /// @param previous Previous cooldown duration in seconds.
    /// @param current New cooldown duration in seconds.
    event TimelockCooldownUpdated(uint64 previous, uint64 current);

    /// @notice Allowance was updated.
    /// @param account Account whose allowance changed.
    /// @param previous Previous allowance amount.
    /// @param current New allowance amount.
    event AllowanceUpdated(address indexed account, uint256 previous, uint256 current);

    // =========================================================================
    // Claims
    // =========================================================================

    /// @notice Claim not found.
    /// @param claimId Claim identifier that was not found.
    error ClaimNotFound(uint256 claimId);

    /// @notice Canonical claim not found.
    /// @param claimId Canonical claim commitment that was not found.
    error CanonicalClaimNotFound(bytes32 claimId);

    /// @notice Invalid claim state transition.
    /// @param claimId Claim whose requested transition is invalid.
    error InvalidClaimStateTransition(uint256 claimId);

    /// @notice Claim already exists.
    /// @param claimId Existing claim identifier.
    error ClaimAlreadyExists(uint256 claimId);

    /// @notice Canonical claim already exists.
    /// @param claimId Existing canonical claim commitment.
    error CanonicalClaimAlreadyExists(bytes32 claimId);

    /// @notice Invalid claim subject.
    error InvalidClaimSubject();

    /// @notice Invalid claim reward amount.
    error InvalidReward();

    /// @notice Referenced claim id is unknown to the claim registry.
    error InvalidClaim(uint256 claimId);

    /// @notice Claim no longer accepts evidence (finalized / terminal status).
    /// @param status Underlying claim-status enum cast to uint8.
    error ClaimFinalized(uint256 claimId, uint8 status);

    // =========================================================================
    // Evidence
    // =========================================================================

    /// @notice Evidence not found.
    /// @param evidenceId Missing evidence identifier.
    error EvidenceNotFound(uint256 evidenceId);

    /// @notice Invalid evidence content hash.
    error InvalidEvidenceHash();

    /// @notice Evidence submission window closed.
    error EvidenceWindowClosed(uint256 claimId, uint64 deadline, uint64 timestamp);

    /// @notice Duplicate evidence submission.
    error DuplicateEvidence(bytes32 commitmentKey);

    /// @notice Zero content or metadata digest.
    error ZeroDigest();

    /// @notice Contributor nonce mismatch.
    error InvalidNonce(address contributor, uint256 expected, uint256 provided);

    /// @notice Pagination limit out of bounds.
    /// @param limit Requested page size that violated the configured bounds.
    error InvalidPageLimit(uint256 limit);

    /// @notice Pagination cursor does not bind the requested claim/release/order context.
    /// @param claimId Claim the cursor was expected to bind.
    /// @param releaseId Release the cursor was expected to bind.
    /// @param orderKey Ordering key the cursor was expected to bind.
    error InvalidEvidenceCursor(uint256 claimId, uint256 releaseId, bytes32 orderKey);

    /// @notice Evidence ordering key is malformed or non-monotonic.
    /// @param orderKey Offending ordering key.
    error InvalidEvidenceOrder(bytes32 orderKey);

    /// @notice Evidence page bounds are inverted or otherwise invalid.
    /// @param fromKey Inclusive lower ordering key.
    /// @param toKey Exclusive upper ordering key.
    error InvalidEvidenceBounds(bytes32 fromKey, bytes32 toKey);

    // =========================================================================
    // Verification
    // =========================================================================

    /// @notice Verification not found.
    /// @param verificationId Missing verification identifier.
    error VerificationNotFound(uint256 verificationId);

    /// @notice Verification window closed.
    error VerificationWindowClosed();

    /// @notice Verifier already submitted verification for this claim.
    error AlreadyVerified();

    /// @notice Insufficient stake amount.
    error InsufficientStake();

    /// @notice Invalid verification verdict.
    error InvalidVerdict();

    // =========================================================================
    // Settlement
    // =========================================================================

    /// @notice Settlement not found.
    /// @param claimId Claim without a settlement record.
    error SettlementNotFound(uint256 claimId);

    /// @notice Settlement not executable yet.
    /// @param executeAfter Earliest executable Unix timestamp.
    error SettlementNotExecutable(uint64 executeAfter);

    /// @notice Settlement execution failed.
    error SettlementExecutionFailed();

    /// @notice Invalid settlement amount.
    error InvalidSettlementAmount();

    /// @notice Canonical asset conservation invariant is violated; on-chain balance and accounting buckets must match exactly.
    /// @param asset Asset whose reconciliation failed.
    /// @param custody Tracked principal + rewards + fees + donations (accounted custody).
    /// @param obligations Sum of recorded obligations (principal owed to claimants/stakers).
    /// @param balance Raw on-chain token balance observed by the vault.
    /// @param unexplainedDeltas Non-negative residual not attributable to any tracked bucket.
    error ConservationInvariantViolation(address asset, uint256 custody, uint256 obligations, uint256 balance, uint256 unexplainedDeltas);

    /// @notice Settlement outcome already recorded for this claim-round.
    /// @param claimId Settlement claim.
    /// @param round Settlement round.
    error SettlementAlreadyFinalized(uint256 claimId, uint256 round);

    /// @notice Invalid settlement outcome requested for this claim-round.
    /// @param claimId Settlement claim.
    /// @param round Settlement round.
    error InvalidSettlementOutcome(uint256 claimId, uint256 round);

    /// @notice Round transfer / rollover / carry-forward rejected because from == to.
    error InvalidRoundTransfer(uint256 fromRound, uint256 toRound);

    /// @notice Deadline has not yet been reached; the action is still within its inclusive window.
    /// @dev Inclusive semantics: an action is valid while `block.timestamp <= deadline`.
    ///      Raised when `block.timestamp < deadline` for an action that requires the deadline to have elapsed.
    /// @param deadline The inclusive deadline timestamp that has not yet been reached.
    error DeadlineNotReached(uint64 deadline, uint64 timestamp);

    // =========================================================================
    // Disputes
    // =========================================================================

    /// @notice Dispute not found.
    /// @param disputeId Missing dispute identifier.
    error DisputeNotFound(uint256 disputeId);

    /// @notice Dispute window closed.
    error DisputeWindowClosed();

    /// @notice Deadline has elapsed; the action is past its inclusive window.
    /// @dev Inclusive semantics: an action is valid while `block.timestamp <= deadline`.
    ///      Raised when `block.timestamp > deadline`.
    /// @param deadline The inclusive deadline timestamp that has elapsed.
    error DeadlineExpired(uint64 deadline, uint64 timestamp);

    /// @notice Dispute already opened.
    error DisputeAlreadyExists();

    /// @notice Invalid dispute reason.
    error InvalidDisputeReason();

    /// @notice Appeal round is invalid for rollover (zero, non-monotonic, or beyond the bounded window).
    /// @param fromRound Round the rollover originates from.
    /// @param toRound Round the rollover targets.
    error InvalidAppealRound(uint256 fromRound, uint256 toRound);

    // =========================================================================
    // Stake & Custody
    // =========================================================================

    /// @notice Insufficient stake balance.
    error InsufficientStakeBalance();

    /// @notice Stake withdrawal not permitted.
    error StakeWithdrawalNotPermitted();

    /// @notice Invalid custody reference.
    error InvalidCustodyReference();

    /// @notice Asset is not supported by the custody vault.
    /// @param asset Asset address rejected by configuration.
    error UnsupportedAsset(address asset);

    /// @notice Insufficient claimable balance for the requested operation.
    /// @param account Account whose balance was checked.
    /// @param requested Amount requested.
    /// @param available Available claimable amount.
    error InsufficientClaimable(address account, uint256 requested, uint256 available);

    /// @notice Insufficient locked balance for the requested operation.
    /// @param requested Amount requested.
    /// @param available Available locked amount.
    error InsufficientLocked(uint256 requested, uint256 available);

    /// @notice Insufficient protocol allocation for the requested operation.
    /// @param requested Amount requested.
    /// @param available Available protocol allocation.
    error InsufficientProtocolAllocation(uint256 requested, uint256 available);

    /// @notice Token transfer amount does not match the expected value.
    /// @param expected Amount requested from the token.
    /// @param received Amount actually received.
    error TransferAmountMismatch(uint256 expected, uint256 received);

    /// @notice Recorded obligations exceed on-chain custody for an asset.
    /// @param asset Asset whose accounting failed reconciliation.
    /// @param custody Accounted custody.
    /// @param obligations Sum of recorded obligations.
    /// @param balance Raw on-chain token balance observed by the vault.
    /// @param unexplainedDeltas Non-negative residual not attributable to any tracked bucket.
    error ObligationsExceedCustody(address asset, uint256 custody, uint256 obligations, uint256 balance, uint256 unexplainedDeltas);

    /// @notice On-chain balance exceeds tracked custody by an unexplained, non-governed delta.
    /// @dev Raised when a direct transfer, rebase, or hostile token inflates the raw balance
    ///      without a corresponding accounting entry. The delta must enter the governed
    ///      recovery path rather than being silently absorbed into custody.
    /// @param asset Asset whose reconciliation detected the surplus.
    /// @param custody Accounted custody (principal + rewards + fees + donations).
    /// @param balance Raw on-chain token balance observed by the vault.
    /// @param unexplainedDeltas Non-negative residual (balance - custody) not attributable to any bucket.
    error UnexplainedBalanceDelta(address asset, uint256 custody, uint256 balance, uint256 unexplainedDeltas);

    /// @notice A tracked custody bucket was mutated without a matching on-chain movement.
    /// @dev Raised when accounting changes (reward accrual, slash, refund, recovery) do not
    ///      reconcile against the observed token balance, preventing double-counting of custody.
    /// @param asset Asset whose bucket mutation failed reconciliation.
    /// @param bucket Left-aligned ASCII identifier of the mutated bucket (`"<Module>.<bucket>"`).
    /// @param expected Expected post-mutation custody.
    /// @param actual Observed post-mutation custody.
    error CustodyBucketMismatch(address asset, bytes32 bucket, uint256 expected, uint256 actual);

    /// @notice Appeal rollover would strand, duplicate, or lose principal across rounds.
    /// @param asset Asset whose principal conservation failed.
    /// @param round Round at which the invariant was checked.
    /// @param expected Principal expected to be preserved.
    /// @param actual Principal observed after rollover.
    error AppealPrincipalNotPreserved(address asset, uint256 round, uint256 expected, uint256 actual);

    /// @notice Appeal rollover would strand, duplicate, or lose custody across rounds.
    /// @param asset Asset whose custody conservation failed.
    /// @param round Round at which the invariant was checked.
    /// @param expected Custody expected to be preserved.
    /// @param actual Custody observed after rollover.
    error AppealCustodyNotPreserved(address asset, uint256 round, uint256 expected, uint256 actual);

    // =========================================================================
    // Aggregation & Reputation
    // =========================================================================

    /// @notice Invalid aggregation result.
    error InvalidAggregationResult();

    /// @notice Reputation update failed.
    error ReputationUpdateFailed();

    /// @notice Invalid reputation score.
    error InvalidReputationScore();

    // =========================================================================
    // Configuration & Parameter Registry
    // =========================================================================

    /// @notice Configuration not found.
    error ConfigurationNotFound();

    /// @notice Invalid parameter version.
    error InvalidParameterVersion();

    /// @notice Parameter update not authorized.
    error ParameterUpdateNotAuthorized();

    /// @notice Caller is not the configured governance authority.
    error NotGovernance(address sender);

    /// @notice Governance address invalid for registry initialization.
    error InvalidGovernance(address governance);

    /// @notice Supported-assets list is empty or otherwise invalid.
    error InvalidSupportedAssets(uint256 assetCount);

    /// @notice Configured asset list exceeds the bounded-execution cap.
    /// @param provided Number of assets supplied.
    /// @param max Maximum assets permitted by ProtocolExecutionBounds.
    error SupportedAssetLimitExceeded(uint256 provided, uint256 max);

    /// @notice Bounty min/max range is inverted or empty.
    error InvalidBountyRange(uint128 minBounty, uint128 maxBounty);

    /// @notice Stake min/max range is inverted or empty.
    error InvalidStakeRange(uint128 minStake, uint128 maxStake);

    /// @notice Duration field is zero or otherwise invalid.
    /// @param field 1=claim, 2=verification, 3=dispute, 4=appeal.
    error InvalidDuration(uint8 field);

    /// @notice Allocation basis-points do not sum to 10_000.
    error InvalidBasisPointsTotal(uint256 totalBps);

    /// @notice Single allocation leg exceeds 10_000 bps.
    error InvalidAllocationBps(uint16 bps);

    /// @notice Weight cap exceeds 10_000 bps.
    error InvalidWeightCap(uint16 weightCapBps);

    /// @notice Participation threshold invalid.
    error InvalidParticipationThreshold(uint24 thresholdBps);

    /// @notice Confidence threshold exceeds 10_000 bps.
    error InvalidConfidenceThreshold(uint16 confidenceBps);

    /// @notice Appeal bond multiplier invalid (zero).
    error InvalidAppealMultiplier(uint24 multiplierBps);

    /// @notice Appeal depth exceeds the configured maximum number of rounds.
    /// @param provided Requested appeal round.
    /// @param max Maximum appeal rounds permitted.
    error AppealDepthExceeded(uint256 provided, uint256 max);

    /// @notice Reputation bound pair invalid.
    error InvalidReputationBounds(uint16 minBps, uint16 maxBps);

    /// @notice Pause / unpause cooldown is zero.
    error InvalidPauseCooldown(uint48 cooldown);

    /// @notice Appeal bond escalation overflowed the bounded maximum.
    /// @param round Appeal round whose bond overflowed.
    /// @param bond Computed bond that exceeded the cap.
    /// @param cap Maximum bond permitted.
    error AppealBondOverflow(uint256 round, uint256 bond, uint256 cap);

    /// @notice Appeal bond is below the anti-dust floor.
    /// @param provided Bond supplied.
    /// @param minimum Minimum bond required.
    error AppealBondDust(uint256 provided, uint256 minimum);

    /// @notice Appeal deadline has elapsed; the round can no longer be opened.
    /// @param deadline Unix timestamp at which the appeal window closed.
    /// @param timestamp Current block timestamp.
    error AppealDeadlineMissed(uint64 deadline, uint64 timestamp);

    /// @notice Rounding policy enum out of range.
    error InvalidRoundingPolicy(uint8 roundingPolicy);

    /// @notice Parameter set version already published.
    error ParameterSetAlreadyExists(bytes32 versionId);

    /// @notice Parameter set version not published.
    error ParameterSetNotFound(bytes32 versionId);

    /// @notice Appeal counter cannot be reset once a round has been opened.
    /// @param claimId Claim whose appeal counter reset was rejected.
    /// @param current Current appeal round.
    error AppealCounterResetForbidden(uint256 claimId, uint256 current);

    /// @notice Asset adapter already registered.
    error AssetAdapterAlreadySet(address asset);

    // =========================================================================
    // Governance Modules
    // =========================================================================

    /// @notice Zero guardian address.
    error ZeroGuardianAddress();

    /// @notice Zero governor address.
    error ZeroGovernorAddress();

    /// @notice Zero module address in governed registry.
    error ZeroModuleAddress();

    /// @notice Caller is not a guardian.
    error NotGuardian(address caller);

    /// @notice Proposal target is not a governed module.
    error TargetNotGovernedModule(address target);

    /// @notice Guardian module already configured.
    error GovernanceGuardianModuleAlreadySet(address existingModule);

    /// @notice Caller may not set the guardian module.
    error UnauthorizedGuardianModuleSetter(address caller);

    /// @notice Module already registered in the governed allowlist.
    error ModuleAlreadyRegistered(address module);

    /// @notice Module not registered in the governed allowlist.
    error ModuleNotRegistered(address module);

    // =========================================================================
    // Slashing
    // =========================================================================

    /// @notice Slash amount exceeds stake.
    error SlashAmountExceedsStake();

    /// @notice Slashing not permitted for this verifier.
    error SlashingNotPermitted();

    // =========================================================================
    // Emergency Controls
    // =========================================================================

    /// @notice Protocol is paused.
    error ProtocolPaused();

    /// @notice Protocol is paused (OpenZeppelin `Pausable`-compatible selector).
    /// @dev Canonical alias for `ProtocolPaused()` so callers and tests that
    ///      assert the OZ `EnforcedPause()` selector observe the same failure.
    ///      Both selectors are emitted by the emergency-control layer; the
    ///      operation-scoped pause path reverts with `ScopePaused(bytes32)`.
    error EnforcedPause();

    /// @notice Token operation failed without a revert reason (SafeERC20-compatible selector).
    /// @dev Canonical alias for `SafeERC20FailedOperation(address)` so custody
    ///      paths that surface a false-return or reverting token map to one
    ///      documented error instead of ad-hoc string reasons.
    /// @param token Address of the token whose operation failed.
    error SafeERC20FailedOperation(address token);

    /// @notice Token operation failed with a bubbled revert reason (SafeERC20-compatible selector).
    /// @dev Canonical alias for `SafeERC20FailedOperation(address)` carrying the
    ///      underlying revert data so token failures cannot corrupt custody.
    /// @param token Address of the token whose operation failed.
    /// @param reason Raw revert data returned by the token.
    error SafeERC20FailedOperationWithReason(address token, bytes reason);

    /// @notice Operation requires emergency authority.
    error EmergencyAuthorityRequired();

    /// @notice The referenced scope is not part of the canonical emergency scope manifest.
    /// @dev Raised instead of silently allowing an unrecognised operation. Emergency controls
    ///      fail closed: an unknown scope is never treated as unpaused.
    error UnknownOperation(bytes32 scope);

    /// @notice The scope is currently paused and the mutation must not proceed.
    error ScopePaused(bytes32 scope);

    /// @notice The scope is not paused, so the requested recovery action is invalid.
    error ScopeNotPaused(bytes32 scope);

    /// @notice The scope is already paused.
    error ScopeAlreadyPaused(bytes32 scope);

    /// @notice The scope is already part of the known-scope set.
    error ScopeAlreadyRegistered(bytes32 scope);

    /// @notice The recovery timelock for the scope has not elapsed yet.
    error RecoveryTimelockActive(bytes32 scope, uint256 readyAt);

    /// @notice Recovery cannot complete because no recovery conditions were documented for the scope.
    error NoRecoveryConditionsDeclared(bytes32 scope);

    /// @notice A declared recovery condition has not been satisfied or waived.
    error RecoveryPrerequisitesUnmet(bytes32 scope, bytes32 conditionId);

    /// @notice A recovery condition with this identifier is already declared for the scope.
    error RecoveryConditionAlreadyDeclared(bytes32 scope, bytes32 conditionId);

    /// @notice No recovery condition with this identifier is declared for the scope.
    error RecoveryConditionNotFound(bytes32 scope, bytes32 conditionId);

    /// @notice The recovery condition has already been satisfied or waived.
    error RecoveryConditionAlreadyResolved(bytes32 scope, bytes32 conditionId);

    /// @notice The caller does not hold the role required for this emergency action.
    error UnauthorizedEmergencyCaller(address caller);

    /// @notice Caller is blacklisted for the requested operation.
    /// @dev Fail-closed: a blacklisted account can never be treated as allowed.
    /// @param account Address rejected by the blacklist.
    error Blacklisted(address account);

    /// @notice Recipient rejected an incoming token transfer.
    /// @dev Fail-closed: a rejecting recipient must not leave custody accounting
    ///      advanced without a matching balance movement.
    /// @param recipient Address that rejected the transfer.
    /// @param asset Asset address whose transfer was rejected.
    error RecipientRejected(address recipient, address asset);

    /// @notice A guarded module has no emergency-control dependency configured.
    /// @dev Raised instead of allowing the mutation. An unwired module is frozen, never open.
    error EmergencyControlsNotConfigured();

    /// @notice Guardian attempted to unpause a scope; guardians may only pause.
    /// @dev Enforces the V2 invariant that unpause is a governed, timelocked action.
    /// @param caller The guardian address that attempted the unpause.
    error GuardianCannotUnpause(address caller);

    /// @notice The incident reference supplied for governed unpause is stale or unknown.
    /// @param incidentId The incident reference that failed validation.
    /// @param recordedAt Timestamp at which the incident was recorded.
    error StaleIncidentReference(bytes32 incidentId, uint256 recordedAt);

    /// @notice The repaired release hash does not match the approved release manifest.
    /// @param provided The release hash supplied by the caller.
    /// @param expected The canonical approved release hash.
    error WrongRepairedRelease(bytes32 provided, bytes32 expected);

    /// @notice Dependency health evidence for the scope is missing or failed.
    /// @param scope The operation scope whose dependencies are unhealthy.
    /// @param evidenceHash Commitment to the supplied dependency-health evidence.
    error DependencyHealthUnproven(bytes32 scope, bytes32 evidenceHash);

    /// @notice The scope is only partially paused; governed unpause requires a full pause.
    /// @param scope The operation scope that is not fully paused.
    /// @param pausedSubscopes Bitmap of currently paused subscopes.
    error PartialPauseState(bytes32 scope, uint256 pausedSubscopes);

    /// @notice The scope has already been unpaused; repeated unpause is rejected.
    /// @param scope The operation scope that is not currently paused.
    error AlreadyUnpaused(bytes32 scope);

    /// @notice The governed unpause timelock has not elapsed yet.
    /// @param scope The operation scope awaiting timelock expiry.
    /// @param readyAt Earliest Unix timestamp at which unpause may execute.
    error UnpauseTimelockNotReady(bytes32 scope, uint256 readyAt);

    // =========================================================================
    // Generic Validation (typed — avoid string reasons)
    // Module Registry Errors
    // =========================================================================

    /// @notice Module key is not part of the canonical manifest.
    error UnknownModuleId(bytes32 moduleId);

    /// @notice Module key already has a pending or active registration.
    error DuplicateModule(bytes32 moduleId);

    /// @notice Module record does not exist.
    error ModuleNotFound(bytes32 moduleId);

    /// @notice Module is registered but not yet active.
    error ModuleNotActive(bytes32 moduleId);

    /// @notice Module is already ACTIVE; activation is a no-op.
    error AlreadyActive(bytes32 moduleId);

    /// @notice Module key has been deprecated and cannot be (re)activated.
    error DeprecatedModule(bytes32 moduleId);

    /// @notice Address carries no code (an EOA or empty address cannot be a module).
    error ModuleNotAContract(address target);

    /// @notice Attempted self-registration: the registry cannot register itself.
    error SelfRegistration();

    /// @notice A proxy is already bound to another module key (prevents circular authority).
    error DuplicateProxy(address proxy);

    /// @notice Module does not implement the expected canonical interface.
    error ModuleInterfaceMismatch(bytes4 expected, bytes4 actual);

    /// @notice Module protocol version is incompatible with the canonical release.
    error ModuleVersionMismatch(uint16 actualMajor, uint16 expectedMajor);

    /// @notice Declared registration version differs from the live module's reported version.
    error DeclaredVersionMismatch(uint16 declaredMajor, uint16 declaredMinor, uint16 actualMajor, uint16 actualMinor);

    /// @notice Address is on the forbidden legacy list.
    error ForbiddenModule(address implementation);

    /// @notice A required canonical dependency is not active.
    error DependencyUnsatisfied(bytes32 moduleId, bytes32 requiredModuleId);

    /// @notice Replacement proposed with identical content to the current module version.
    error ReplacementNoop(bytes32 moduleId);

    /// @notice No replacement is pending for the module key.
    error ReplacementNotPending(bytes32 moduleId);

    /// @notice Replacement timelock has not elapsed.
    error ReplacementNotReady(bytes32 moduleId, uint256 readyAt);

    /// @notice A zero or ERC-165-invalid interface ID was supplied.
    error InvalidInterfaceId(bytes4 interfaceId);

    /// @notice Guardian role is explicitly excluded from registry mutations.
    error GuardianCannotReplaceModule(address caller);

    /// @notice Denied mutator without the required deployer/governance role.
    error RegistryUnauthorized();

    // =========================================================================
    // Generic Validation Errors
    // =========================================================================

    /// @notice Invalid function argument.
    /// @param reason Description of what was invalid.
    error InvalidArgument(string reason);

    /// @notice Operation not supported.
    error NotSupported();

    /// @notice Reentrancy guard detected.
    error ReentrancyDetected();

    // =========================================================================
    // Supply-Chain Attestation Errors (V2-SC-138)
    // =========================================================================

    /// @notice Invalid attestation schema version.
    error InvalidAttestationSchemaVersion();

    /// @notice Empty protocol name in attestation.
    error EmptyProtocolName();

    /// @notice Empty release version in attestation.
    error EmptyReleaseVersion();

    /// @notice Invalid source commit format (must be 40-char lowercase hex).
    error InvalidSourceCommit();

    /// @notice Invalid checksum (zero or malformed).
    error InvalidChecksum();

    /// @notice A variable-length attestation field contains the '|' field delimiter (V2-SC-160).
    /// @dev Delimiter-joined records are only unambiguous when no field can contain the
    ///      delimiter; otherwise field boundaries shift on read-back.
    error AttestationFieldContainsDelimiter();

    // =========================================================================
    // Precision & Arithmetic Errors (V2-SC-100)
    // =========================================================================

    /// @notice Division or proportional split attempted with a zero denominator.
    /// @dev Raised explicitly rather than relying on a division panic, so the
    ///      revert reason identifies the cause.
    error ZeroDenominator();

    /// @notice Basis-point value exceeded 10_000 (100%).
    /// @param bps The offending value.
    error BpsOutOfRange(uint256 bps);

    /// @notice Percentage value exceeded 100.
    /// @param percent The offending value.
    error PercentOutOfRange(uint256 percent);

    /// @notice An allocation's basis-point parts did not sum to exactly 10_000.
    /// @dev Exact rather than "at most": a split summing to less than 100%
    ///      silently strands value in the paying contract.
    /// @param total The sum that was supplied.
    error BpsSumNotExact(uint256 total);

    /// @notice Index addressed a position outside the supplied array.
    /// @param index The offending index.
    error IndexOutOfBounds(uint256 index);

    /// @notice Two arrays that must be index-aligned had different lengths.
    error LengthMismatch();

    // =========================================================================
    // Safe-Cast & Integer-Width Boundaries (V2-SC-161)
    // =========================================================================

    /// @notice A value does not fit the narrower integer width of the named field.
    /// @dev Raised by `V2SafeCast` instead of silently truncating to the low bits.
    /// @param field Left-aligned ASCII identifier of the field (`"<Module>.<field>"`).
    /// @param value The rejected value.
    /// @param max The largest value the destination width can hold (`type(uintN).max`).
    error SafeCastOverflow(bytes32 field, uint256 value, uint256 max);

    /// @notice A negative signed value was converted to an unsigned field.
    /// @param field Left-aligned ASCII identifier of the field.
    /// @param value The rejected signed value.
    error SafeCastNegative(bytes32 field, int256 value);
}
