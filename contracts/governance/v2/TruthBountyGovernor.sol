// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorStorage} from "@openzeppelin/contracts/governance/extensions/GovernorStorage.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernedModuleRegistry} from "./IGovernedModuleRegistry.sol";
import {IGovernanceSnapshot} from "./IGovernanceSnapshot.sol";
import {GovernanceForbiddenCalls} from "./libraries/GovernanceForbiddenCalls.sol";

/**
 * @title TruthBountyGovernor
 * @notice GovernorBravo-compatible OpenZeppelin governor integrated with {TimelockController}.
 * @dev Proposals may only target registered governed modules and are blocked from claim-outcome calls.
 *      Guardian cancellation is separate from timelock execution authority.
 *
 *      Cancellation semantics (V2-SC-066): a proposal may only be cancelled while it is in a
 *      non-terminal state (Pending, Active, Succeeded, or Queued) and only under one of the four
 *      explicit {CancelAuthority} conditions — proposer withdrawal, proposer-below-threshold
 *      invalidation, guardian veto, or governed-module invalidation. Every other path fails closed
 *      with {ProposalCancellationUnauthorized}. Cancellation decisions are evaluated freshly on
 *      every call against canonical state, so no authorisation can be stored, replayed, or reused
 *      after the proposal it was granted for has left the cancelable window.
 *      ## Canonical Snapshot Integration (V2-SC-063)
 *
 *      At proposal creation, `_propose` calls `governanceSnapshot.registerSnapshot(proposalId)`,
 *      recording the exact `block.timestamp` at which the proposal was created as the
 *      canonical voting-power freeze point. This timestamp is identical to
 *      `proposalSnapshot(proposalId)` used by {GovernorVotes._getVotes} and ensures that
 *      voting-power queries cannot be influenced by token transfers, delegations, or
 *      stake changes that occur after proposal creation.
 *
 *      If `governanceSnapshot` is set (non-zero), snapshot registration is mandatory: a
 *      failed call reverts the entire `_propose` call, preventing proposals from existing
 *      without a canonical snapshot entry (fail-closed).
 *      ## Native Value Isolation (V2-SC-153)
 *
 *      TruthBounty V2 accounting is token-denominated, so the governor never holds, forwards,
 *      or accounts for native currency:
 *        - {receive} rejects every native transfer unconditionally, in every executor
 *          configuration and identically for the implementation and any proxy.
 *        - Both {execute} overloads reject an attached `msg.value`, so execution can never be
 *          funded with native currency (which would otherwise be credited to the timelock and
 *          could be disbursed through a proposal's `values`).
 *        - Every proposal operation must carry a zero native value (`values[i] == 0`),
 *          enforced when the proposal is created and again when it executes.
 *
 *      Native currency forced onto this contract or onto the timelock (for example through
 *      SELFDESTRUCT) cannot be prevented at the EVM level, but it is economically inert: no
 *      governance path reads `address(this).balance`, no path transfers it out, and it grants no
 *      voting weight, no proposal threshold credit, and no claimable balance anywhere.
 */
contract TruthBountyGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    GovernorStorage
{
    using GovernanceForbiddenCalls for bytes;

    /// @notice Maximum number of calls in one governance proposal.
    uint256 public constant MAX_PROPOSAL_OPERATIONS = 20;
    /// @notice Maximum encoded calldata for one governed action.
    uint256 public constant MAX_OPERATION_CALLDATA_BYTES = 8_192;
    /// @notice Maximum combined encoded calldata across one proposal.
    uint256 public constant MAX_PROPOSAL_CALLDATA_BYTES = 65_536;
    /// @notice Maximum UTF-8 description size for a governance proposal.
    uint256 public constant MAX_PROPOSAL_DESCRIPTION_BYTES = 4_096;

    /// @notice Explicit, exhaustive conditions under which a governance proposal may be cancelled (V2-SC-066).
    enum CancelAuthority {
        /// @dev No cancellation condition satisfied — every cancel attempt fails closed.
        NONE,
        /// @dev The original proposer withdraws their own proposal while it is Pending or Active.
        PROPOSER,
        /// @dev Permissionless: the proposer's live voting power fell below `proposalThreshold()`
        ///      while the proposal is still Pending, so the proposal no longer meets the spam bar
        ///      that allowed it to be created.
        THRESHOLD,
        /// @dev The guardian (or the wired guardian module) vetoes before execution.
        GUARDIAN,
        /// @dev Permissionless: at least one proposal target was removed from the governed module
        ///      registry after creation, so the proposal no longer targets canonical modules.
        INVALIDATED
    }

    /// @notice Registry consulted for every proposal target; unregistered targets revert.
    IGovernedModuleRegistry public immutable moduleRegistry;
    /// @notice Optional snapshot registry notified when a proposal is created; zero disables it.
    IGovernanceSnapshot public immutable governanceSnapshot;
    /// @notice Address currently authorized to cancel proposals.
    address public guardian;
    /// @notice Optional bootstrap guardian module authorized to cancel proposals.
    address public governanceGuardianModule;

    /// @notice Emitted alongside {Governor-ProposalCanceled} recording who cancelled and under which condition.
    event ProposalCancellationAuthorized(
        uint256 indexed proposalId,
        address indexed caller,
        CancelAuthority authority
    );

    /// @notice Emitted when the governor guardian is rotated by governance.
    /// @param oldGuardian Previous guardian.
    /// @param newGuardian New guardian.
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    /// @notice Emitted when the optional guardian module is initialized.
    /// @param oldModule Previous module, zero during bootstrap.
    /// @param newModule New module.
    event GovernanceGuardianModuleUpdated(address indexed oldModule, address indexed newModule);
    event GovernanceManifestPublished(
        address indexed governor,
        address indexed timelock,
        address indexed token,
        address moduleRegistry,
        address governanceSnapshot,
        uint256 votingDelay,
        uint256 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumNumerator,
        uint256 timelockMinDelay
    );

    /// @notice Guardian address must not be zero.
    error ZeroGuardianAddress();
    /// @notice Proposal target is not in the governed module allowlist.
    /// @param target Rejected target address.
    error TargetNotGovernedModule(address target);
    /// @notice Proposal action arrays are empty, over limit, or have mismatched lengths.
    error InvalidProposalOperationCount(uint256 targets, uint256 values, uint256 calldatas, uint256 maximum);
    /// @notice One action's calldata exceeds its published limit.
    error OperationCalldataTooLarge(uint256 index, uint256 provided, uint256 maximum);
    /// @notice Aggregate action calldata exceeds its published limit.
    error ProposalCalldataTooLarge(uint256 provided, uint256 maximum);
    /// @notice Proposal description exceeds its published limit.
    error ProposalDescriptionTooLarge(uint256 provided, uint256 maximum);
    /// @notice Guardian module can only be initialized once.
    /// @param existingModule Already configured module.
    error GovernanceGuardianModuleAlreadySet(address existingModule);
    /// @notice Caller is not the bootstrap guardian.
    /// @param caller Unauthorized caller.
    error UnauthorizedGuardianModuleSetter(address caller);
    /// @dev Thrown when a cancel attempt satisfies none of the explicit {CancelAuthority} conditions.
    error ProposalCancellationUnauthorized(uint256 proposalId, address caller);
    /// @notice Native value was attached to a token-denominated governor entry point (V2-SC-153).
    /// @param value Rejected `msg.value`.
    error UnexpectedNativeValue(uint256 value);
    /// @notice A proposal operation carried a non-zero native value (V2-SC-153).
    /// @param index Index of the offending operation.
    /// @param value Rejected native value for that operation.
    error NativeValueProposalNotAllowed(uint256 index, uint256 value);
    /// @notice The canonical snapshot timestamp for a proposal is not strictly in the past (V2-SC-019).
    /// @param proposalId Proposal whose snapshot is being queried.
    /// @param snapshotTs Registered snapshot timestamp.
    /// @param currentTs Current governor clock.
    error SnapshotNotInPast(uint256 proposalId, uint48 snapshotTs, uint48 currentTs);
    /// @notice The canonical snapshot registry returned an inconsistent timestamp (V2-SC-019).
    /// @param proposalId Proposal whose snapshot is being queried.
    /// @param expected Expected snapshot timestamp derived from governor state.
    /// @param actual Timestamp returned by the canonical snapshot registry.
    error SnapshotTimestampMismatch(uint256 proposalId, uint48 expected, uint48 actual);

    /// @param token_ ERC20Votes token used to calculate voting power.
    /// @param timelock_ Timelock that queues and executes proposals.
    /// @param registry_ Allowlist of modules that proposals may target.
    /// @param snapshot_ Optional snapshot registry notified of every proposal snapshot (zero disables).
    /// @param guardian_ Initial proposal-cancellation guardian.
    /// @param votingDelay_ Delay between proposal creation and voting, in seconds.
    /// @param votingPeriod_ Voting duration in seconds.
    /// @param proposalThreshold_ Minimum token weight required to propose.
    /// @param quorumNumerator_ Fraction numerator for quorum, measured against total voting weight.
    constructor(
        IVotes token_,
        TimelockController timelock_,
        IGovernedModuleRegistry registry_,
        IGovernanceSnapshot snapshot_,
        address guardian_,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_,
        uint256 quorumNumerator_
    )
        Governor("TruthBountyGovernor")
        GovernorSettings(votingDelay_, votingPeriod_, proposalThreshold_)
        GovernorVotes(token_)
        GovernorVotesQuorumFraction(quorumNumerator_)
        GovernorTimelockControl(timelock_)
    {
        if (guardian_ == address(0)) revert ZeroGuardianAddress();
        moduleRegistry = registry_;
        governanceSnapshot = snapshot_;
        guardian = guardian_;
    }

    /**
     * @notice Publish canonical governance configuration for manifest generation and indexers.
     * @dev Permissionless read-only manifest emission; it does not mutate governance state or grant authority.
     */
    function publishManifest() external {
        emit GovernanceManifestPublished(
            address(this),
            timelock(),
            address(token()),
            address(moduleRegistry),
            address(governanceSnapshot),
            votingDelay(),
            votingPeriod(),
            proposalThreshold(),
            quorumNumerator(),
            TimelockController(payable(timelock())).getMinDelay()
        );
    }

    /**
     * @notice Rotate the guardian address. Callable only through a successful governance proposal.
     * @param newGuardian Non-zero guardian authorized for proposal cancellation.
     */
    function setGuardian(address newGuardian) external onlyGovernance {
        if (newGuardian == address(0)) revert ZeroGuardianAddress();
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(oldGuardian, newGuardian);
    }

    /**
     * @notice Wire the external guardian module once after deployment.
     * @dev Callable once by the current guardian address during bootstrap; this one-time exception cannot be repeated or used to execute calls.
     * @param module Non-zero module authorized to cancel proposals after bootstrap.
     */
    function setGovernanceGuardianModule(address module) external {
        if (module == address(0)) revert ZeroGuardianAddress();
        if (governanceGuardianModule != address(0)) {
            revert GovernanceGuardianModuleAlreadySet(governanceGuardianModule);
        }
        if (msg.sender != guardian) revert UnauthorizedGuardianModuleSetter(msg.sender);
        governanceGuardianModule = module;
        emit GovernanceGuardianModuleUpdated(address(0), module);
    }

    /**
     * @notice Reject every native transfer to the governor (V2-SC-153).
     * @dev Unconditional rejection: the governor is a token-denominated component, so the policy is
     *      identical for every executor configuration and for the implementation as well as any
     *      proxy that delegates to it. Forced native value already on the contract (SELFDESTRUCT) is
     *      excluded from all accounting because no governor path reads `address(this).balance`.
     */
    receive() external payable virtual override {
        revert UnexpectedNativeValue(msg.value);
    }

    /**
     * @notice Execute a queued proposal by id, rejecting attached native value (V2-SC-153).
     * @dev Identical to the inherited proposal-id {GovernorStorage-execute} except that `msg.value`
     *      must be zero: execution may not be funded with native currency, so a caller can never
     *      silently credit the timelock with balance that no TruthBounty invariant accounts for.
     * @param proposalId Proposal to execute.
     */
    function execute(uint256 proposalId) public payable override {
        _rejectNativeValue();
        super.execute(proposalId);
    }

    /**
     * @notice Execute a queued proposal by operations, rejecting attached native value (V2-SC-153).
     * @dev See {execute(uint256)}. The rejection happens before any proposal state, timelock queue
     *      entry, or target call is touched, so a rejected call cannot produce partial mutation.
     * @param targets Proposal targets.
     * @param values Native value per target; every entry must be zero (V2-SC-153).
     * @param calldatas Encoded calls, one per target.
     * @param descriptionHash keccak256 hash of the proposal description.
     * @return proposalId The executed proposal id.
     */
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable override returns (uint256) {
        _rejectNativeValue();
        _validateProposalOperations(targets, values, calldatas);
        _validateProposalValues(values);
        return super.execute(targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc Governor
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256) {
        _validateProposalOperations(targets, values, calldatas);
        _validateProposalValues(values);
        _validateProposalDescription(description);
        return super.propose(targets, values, calldatas, description);
    }

    /// @inheritdoc Governor
    function _propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address proposer
    ) internal override(Governor, GovernorStorage) returns (uint256) {
        _validateProposalOperations(targets, values, calldatas);
        _validateProposalValues(values);
        _validateProposalDescription(description);
        uint256 proposalId = super._propose(targets, values, calldatas, description, proposer);

        // Register the canonical snapshot timestamp for this proposal.
        // proposalSnapshot(proposalId) == clock() + votingDelay() at proposal creation —
        // this is the exact timepoint that GovernorVotes uses for all getPastVotes queries.
        // If governanceSnapshot is configured, registration is mandatory: a revert here
        // propagates upward and prevents the proposal from existing without a snapshot.
        if (address(governanceSnapshot) != address(0)) {
            uint48 snapTs = uint48(proposalSnapshot(proposalId));
            governanceSnapshot.registerSnapshot(proposalId, snapTs);
        }

        return proposalId;
    }

    /**
     * @notice Canonical voting-power freeze point for `proposalId` (V2-SC-019).
     * @dev Returns the exact timepoint at which voting power for `proposalId` is frozen. When a
     *      canonical {IGovernanceSnapshot} registry is wired, its registered timestamp is treated
     *      as authoritative and is cross-checked against `proposalSnapshot(proposalId)`; any
     *      divergence reverts with {SnapshotTimestampMismatch} so a corrupted or stale registry
     *      cannot silently shift the freeze point. When no registry is wired, the governor's own
     *      `proposalSnapshot(proposalId)` is returned.
     *
     *      The returned timepoint is guaranteed to be strictly in the past relative to `clock()`
     *      for any proposal that has been created, because `proposalSnapshot` is
     *      `creationTime + votingDelay` and `votingDelay >= 1` is enforced by {GovernorSettings}.
     *      Callers that query historical voting power MUST use this value (via
     *      {GovernorVotes-getVotes} / `token().getPastVotes(account, snapshotTs)`) rather than
     *      `clock() - 1`, so post-snapshot transfers, delegations, mints, and burns cannot alter
     *      the voting power attributed to a proposal.
     * @param proposalId Proposal to inspect.
     * @return snapshotTs Canonical voting-power freeze timepoint.
     */
    function canonicalSnapshot(uint256 proposalId) public view returns (uint48 snapshotTs) {
        uint48 governorSnapshot = uint48(proposalSnapshot(proposalId));
        if (governorSnapshot == 0) {
            return 0;
        }
        if (address(governanceSnapshot) != address(0)) {
            uint48 registered = governanceSnapshot.snapshotTimestamp(proposalId);
            if (registered != governorSnapshot) {
                revert SnapshotTimestampMismatch(proposalId, governorSnapshot, registered);
            }
            return registered;
        }
        return governorSnapshot;
    }

    /**
     * @notice Historical voting power for `account` at the canonical snapshot of `proposalId` (V2-SC-019).
     * @dev Convenience wrapper that always queries the canonical freeze point, never `clock() - 1`.
     *      Reverts with {SnapshotNotInPast} if the snapshot is not strictly in the past, which
     *      cannot happen for a created proposal but fails closed if the invariant is ever violated.
     * @param proposalId Proposal whose snapshot is used.
     * @param account Voter whose historical weight is queried.
     * @return votes Historical voting power at the canonical snapshot.
     */
    function votesAtSnapshot(uint256 proposalId, address account) public view returns (uint256 votes) {
        uint48 snapshotTs = canonicalSnapshot(proposalId);
        if (snapshotTs == 0 || snapshotTs >= clock()) {
            revert SnapshotNotInPast(proposalId, snapshotTs, clock());
        }
        return token().getPastVotes(account, snapshotTs);
    }

    /**
     * @notice Cancel a proposal under the explicit V2-SC-066 cancellation conditions.
     * @dev Reverts with {ProposalCancellationUnauthorized} unless `caller` satisfies one of the
     *      {CancelAuthority} conditions for the proposal's current state. Emits
     *      {ProposalCancellationAuthorized} before {Governor-ProposalCanceled} so indexers can
     *      attribute every cancellation to its condition. Unknown proposal ids revert with
     *      {Governor-GovernorNonexistentProposal}.
     * @param targets Proposal target contracts (must hash to a known proposal id).
     * @param values ETH value per target.
     * @param calldatas Encoded calls per target.
     * @param descriptionHash keccak256 hash of the proposal description.
     * @return proposalId The cancelled proposal id.
     */
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public override returns (uint256) {
        _validateProposalOperations(targets, values, calldatas);
        _validateProposalValues(values);
        uint256 proposalId = getProposalId(targets, values, calldatas, descriptionHash);
        address caller = _msgSender();

        if (proposalSnapshot(proposalId) != 0) {
            CancelAuthority authority = cancellationAuthority(proposalId, caller);
            if (authority == CancelAuthority.NONE) {
                revert ProposalCancellationUnauthorized(proposalId, caller);
            }
            emit ProposalCancellationAuthorized(proposalId, caller, authority);
        }

        return super.cancel(targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc Governor
    function _validateCancel(uint256 proposalId, address caller) internal view override returns (bool) {
        return _cancellationAuthority(proposalId, caller, state(proposalId)) != CancelAuthority.NONE;
    }

    /**
     * @notice Return the explicit condition under which `caller` may cancel `proposalId` right now.
     * @dev Conditions are evaluated against fresh canonical state on every call: nothing is cached,
     *      stored, or reusable, so a previously valid authorisation cannot be replayed once the
     *      proposal leaves the cancelable window. Returns {CancelAuthority-NONE} for unknown
     *      proposals and for every terminal state (Defeated, Canceled, Expired, Executed).
     * @param proposalId The proposal to evaluate.
     * @param caller The address that would submit the cancellation.
     * @return The satisfied condition, or {CancelAuthority-NONE} when cancellation must fail closed.
     */
    function cancellationAuthority(uint256 proposalId, address caller) public view returns (CancelAuthority) {
        if (proposalSnapshot(proposalId) == 0) {
            return CancelAuthority.NONE;
        }
        return _cancellationAuthority(proposalId, caller, state(proposalId));
    }

    /**
     * @notice Whether `proposalId` targets at least one address no longer in the governed module registry.
     * @dev Only meaningful while the proposal is in a non-terminal cancelable state; returns false
     *      for unknown proposals and terminal states so callers fail closed rather than assume
     *      invalidation that can no longer act.
     * @param proposalId The proposal to inspect.
     * @return True when a target was deregistered after proposal creation.
     */
    function isProposalInvalidated(uint256 proposalId) public view returns (bool) {
        if (proposalSnapshot(proposalId) == 0) {
            return false;
        }
        ProposalState currentState = state(proposalId);
        if (!_isCancelableState(currentState)) {
            return false;
        }
        return _hasDeregisteredTarget(proposalId);
    }

    /// @dev Core authority rules shared by the public view and the {Governor-_validateCancel} hook.
    function _cancellationAuthority(
        uint256 proposalId,
        address caller,
        ProposalState currentState
    ) internal view returns (CancelAuthority) {
        if (!_isCancelableState(currentState)) {
            return CancelAuthority.NONE;
        }
        if (caller == guardian || caller == governanceGuardianModule) {
            return CancelAuthority.GUARDIAN;
        }

        address proposer = proposalProposer(proposalId);
        if (caller == proposer && (currentState == ProposalState.Pending || currentState == ProposalState.Active)) {
            return CancelAuthority.PROPOSER;
        }
        if (_hasDeregisteredTarget(proposalId)) {
            return CancelAuthority.INVALIDATED;
        }

        // Threshold invalidation is deliberately restricted to Pending: once voting has started the
        // proposer's power is snapshotted, and permissionless cancellation must never be usable to
        // censor a live vote (anti-censorship property).
        uint256 votesThreshold = proposalThreshold();
        if (
            currentState == ProposalState.Pending &&
            votesThreshold > 0 &&
            getVotes(proposer, clock() - 1) < votesThreshold
        ) {
            return CancelAuthority.THRESHOLD;
        }
        return CancelAuthority.NONE;
    }

    /// @dev True only for states in which OpenZeppelin's state machine still accepts a cancellation.
    function _isCancelableState(ProposalState currentState) internal pure returns (bool) {
        return
            currentState == ProposalState.Pending ||
            currentState == ProposalState.Active ||
            currentState == ProposalState.Succeeded ||
            currentState == ProposalState.Queued;
    }

    /// @dev True when any proposal target has been removed from the governed module registry.
    function _hasDeregisteredTarget(uint256 proposalId) internal view returns (bool) {
        (address[] memory targets,,,) = proposalDetails(proposalId);
        uint256 length = targets.length;
        for (uint256 i = 0; i < length; ++i) {
            if (!moduleRegistry.isGovernedModule(targets[i])) {
                return true;
            }
        }
        return false;
    }

    /// @notice Returns the current token weight required to create a proposal.
    /// @return threshold Required voting weight in token base units.
    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256 threshold) {
        return super.proposalThreshold();
    }

    /// @notice Returns the quorum weight at a voting timepoint.
    /// @param timepoint Unix timestamp for which quorum is queried.
    /// @return quorumWeight Required participating voting weight.
    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256 quorumWeight) {
        return super.quorum(timepoint);
    }

    /// @notice Returns the governor lifecycle state for a proposal.
    /// @param proposalId Proposal to inspect.
    /// @return proposalState Current proposal state.
    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    /// @notice Reports whether a successful proposal must be queued in the timelock.
    /// @param proposalId Proposal to inspect.
    /// @return needsQueueing True when the proposal must be queued before execution.
    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        // Defense in depth (V2-SC-153): proposals created before the native-value policy cannot be
        // executed, so a queued `values` entry can never move forced native balance held elsewhere.
        _validateProposalValues(values);
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    function _validateProposalOperations(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) internal view {
        uint256 length = targets.length;
        if (
            length == 0 || length != values.length || length != calldatas.length
                || length > MAX_PROPOSAL_OPERATIONS
        ) {
            revert InvalidProposalOperationCount(length, values.length, calldatas.length, MAX_PROPOSAL_OPERATIONS);
        }
        uint256 totalCalldataBytes;
        for (uint256 i = 0; i < length; ++i) {
            uint256 calldataLength = calldatas[i].length;
            if (calldataLength > MAX_OPERATION_CALLDATA_BYTES) {
                revert OperationCalldataTooLarge(i, calldataLength, MAX_OPERATION_CALLDATA_BYTES);
            }
            totalCalldataBytes += calldataLength;
            if (totalCalldataBytes > MAX_PROPOSAL_CALLDATA_BYTES) {
                revert ProposalCalldataTooLarge(totalCalldataBytes, MAX_PROPOSAL_CALLDATA_BYTES);
            }
            if (!moduleRegistry.isGovernedModule(targets[i])) {
                revert TargetNotGovernedModule(targets[i]);
            }
            calldatas[i].enforceAllowed();
        }
    }

    /// @dev Reverts when native value is attached to a token-denominated governor entry point (V2-SC-153).
    function _rejectNativeValue() internal view {
        if (msg.value != 0) revert UnexpectedNativeValue(msg.value);
    }

    /// @dev Every governance operation must be native-value free (V2-SC-153).
    function _validateProposalValues(uint256[] memory values) internal pure {
        uint256 length = values.length;
        for (uint256 i = 0; i < length; ++i) {
            if (values[i] != 0) revert NativeValueProposalNotAllowed(i, values[i]);
        }
    }

    /// @dev Enforce that the canonical snapshot for `proposalId` is strictly in the past (V2-SC-019).
    function _requireSnapshotInPast(uint256 proposalId) internal view {
        uint48 snapshotTs = canonicalSnapshot(proposalId);
        if (snapshotTs == 0 || snapshotTs >= clock()) {
            revert SnapshotNotInPast(proposalId, snapshotTs, clock());
        }
    }

    function _validateProposalDescription(string memory description) internal pure {
        uint256 descriptionLength = bytes(description).length;
        if (descriptionLength > MAX_PROPOSAL_DESCRIPTION_BYTES) {
            revert ProposalDescriptionTooLarge(descriptionLength, MAX_PROPOSAL_DESCRIPTION_BYTES);
        }
    }
}