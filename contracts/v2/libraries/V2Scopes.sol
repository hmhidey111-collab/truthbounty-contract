// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {V2OperationIds} from "./V2OperationIds.sol";

/// @title V2Scopes
/// @notice Canonical emergency-control scope manifest for the TruthBounty V2 protocol.
/// @dev Every protected canonical mutation declares exactly one scope from this library and
///      gates on it through `EmergencyGuarded`. Scopes are stable wire identifiers: the
///      `keccak256` preimage is consumed by indexers and governance proposals, so renaming a
///      scope is a breaking protocol change.
///
///      This manifest is the single source of truth for:
///      - the known-scope set seeded into `EmergencyControls` at deploy time,
///      - the documentation surface (`description`) consumed by `docs/v2/emergency-controls.md`,
///      - the coverage tests that assert each scope pauses independently and that no wired
///        module can mutate while its scope is paused.
///
///      Scope names reuse the pre-existing `EmergencyController` operation identifiers where a
///      matching category already existed (`claim_creation`, `staking`, `withdrawal`,
///      `verification_submission`, `reward_distribution`, `treasury_transfer`,
///      `governance_recovery`) so both control planes speak the same vocabulary.
library V2Scopes {
    /// @notice Number of scopes in the canonical manifest.
    uint256 internal constant CANONICAL_SCOPE_COUNT = 26;

    /// @notice Number of canonical operation identifiers in the published matrix.
    uint256 internal constant CANONICAL_OPERATION_COUNT = 26;

    // -------------------------------------------------------------------------
    // Protocol-wide
    // -------------------------------------------------------------------------

    /// @notice Protocol-wide kill switch. Pausing this scope pauses every other scope.
    bytes32 internal constant GLOBAL = keccak256("global");

    // -------------------------------------------------------------------------
    // Claims
    // -------------------------------------------------------------------------

    /// @notice Creation of a new canonical claim.
    bytes32 internal constant CLAIM_CREATION = keccak256("claim_creation");

    /// @notice Claim state machine transitions and cancellation.
    bytes32 internal constant CLAIM_TRANSITION = keccak256("claim_transition");

    // -------------------------------------------------------------------------
    // Evidence
    // -------------------------------------------------------------------------

    /// @notice Commitment of new evidence digests.
    bytes32 internal constant EVIDENCE_SUBMISSION = keccak256("evidence_submission");

    /// @notice Adjudication of an evidence commitment's status.
    bytes32 internal constant EVIDENCE_STATUS = keccak256("evidence_status");

    // -------------------------------------------------------------------------
    // Stake custody
    // -------------------------------------------------------------------------

    /// @notice Stake deposits and lock placement.
    bytes32 internal constant STAKING = keccak256("staking");

    /// @notice Unlocking of escrowed principal back to claimable balance.
    bytes32 internal constant STAKE_RELEASE = keccak256("stake_release");

    /// @notice Pull-based withdrawal of claimable balances out of custody.
    bytes32 internal constant WITHDRAWAL = keccak256("withdrawal");

    // -------------------------------------------------------------------------
    // Verification and aggregation
    // -------------------------------------------------------------------------

    /// @notice Verifier attestation submission.
    bytes32 internal constant VERIFICATION_SUBMISSION = keccak256("verification_submission");

    /// @notice Deterministic aggregation of verifier weight into an outcome.
    bytes32 internal constant AGGREGATION_FINALIZATION = keccak256("aggregation_finalization");

    // -------------------------------------------------------------------------
    // Settlement
    // -------------------------------------------------------------------------

    /// @notice Queuing of a settlement for later execution.
    bytes32 internal constant SETTLEMENT_QUEUE = keccak256("settlement_queue");

    /// @notice Execution of a queued settlement and the typed custody hooks it drives.
    bytes32 internal constant SETTLEMENT_EXECUTION = keccak256("settlement_execution");

    // -------------------------------------------------------------------------
    // Disputes
    // -------------------------------------------------------------------------

    /// @notice Opening a dispute against a claim.
    bytes32 internal constant DISPUTE_OPEN = keccak256("dispute_open");

    /// @notice Resolver adjudication of an open dispute.
    bytes32 internal constant DISPUTE_RESOLUTION = keccak256("dispute_resolution");

    // -------------------------------------------------------------------------
    // Rewards
    // -------------------------------------------------------------------------

    /// @notice Accrual of rewards against a claim.
    bytes32 internal constant REWARD_ACCRUAL = keccak256("reward_accrual");

    /// @notice Distribution and claiming of accrued rewards.
    bytes32 internal constant REWARD_DISTRIBUTION = keccak256("reward_distribution");

    // -------------------------------------------------------------------------
    // Slashing
    // -------------------------------------------------------------------------

    /// @notice Proposal of a stake penalty.
    bytes32 internal constant SLASH_PROPOSAL = keccak256("slash_proposal");

    /// @notice Execution of an approved stake penalty.
    bytes32 internal constant SLASH_EXECUTION = keccak256("slash_execution");

    // -------------------------------------------------------------------------
    // Treasury
    // -------------------------------------------------------------------------

    /// @notice Deposits into protocol treasury buckets.
    bytes32 internal constant TREASURY_DEPOSIT = keccak256("treasury_deposit");

    /// @notice Transfers out of protocol treasury buckets.
    bytes32 internal constant TREASURY_TRANSFER = keccak256("treasury_transfer");

    // -------------------------------------------------------------------------
    // Configuration, registry, reputation, upgrade
    // -------------------------------------------------------------------------

    /// @notice Publication of a new canonical parameter set.
    bytes32 internal constant CONFIGURATION_PUBLISH = keccak256("configuration_publish");

    /// @notice Registration or removal of canonical modules.
    bytes32 internal constant MODULE_REGISTRY = keccak256("module_registry");

    /// @notice Epoch reputation root proposal and acceptance.
    bytes32 internal constant REPUTATION_ROOT = keccak256("reputation_root");

    /// @notice Proposal of a protocol upgrade.
    bytes32 internal constant UPGRADE_PROPOSAL = keccak256("upgrade_proposal");

    /// @notice Execution of a scheduled protocol upgrade.
    bytes32 internal constant UPGRADE_EXECUTION = keccak256("upgrade_execution");

    // -------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------

    /// @notice Governance recovery operations, permitted at every pause level.
    bytes32 internal constant GOVERNANCE_RECOVERY = keccak256("governance_recovery");

    /// @notice Returns the complete canonical scope manifest in stable order.
    /// @dev Order is part of the manifest: appended scopes must go at the end so that
    ///      indexers relying on positional reads keep observing a stable prefix.
    function canonicalScopes() internal pure returns (bytes32[] memory scopes) {
        scopes = new bytes32[](CANONICAL_SCOPE_COUNT);
        scopes[0] = GLOBAL;
        scopes[1] = CLAIM_CREATION;
        scopes[2] = CLAIM_TRANSITION;
        scopes[3] = EVIDENCE_SUBMISSION;
        scopes[4] = EVIDENCE_STATUS;
        scopes[5] = STAKING;
        scopes[6] = STAKE_RELEASE;
        scopes[7] = WITHDRAWAL;
        scopes[8] = VERIFICATION_SUBMISSION;
        scopes[9] = AGGREGATION_FINALIZATION;
        scopes[10] = SETTLEMENT_QUEUE;
        scopes[11] = SETTLEMENT_EXECUTION;
        scopes[12] = DISPUTE_OPEN;
        scopes[13] = DISPUTE_RESOLUTION;
        scopes[14] = REWARD_ACCRUAL;
        scopes[15] = REWARD_DISTRIBUTION;
        scopes[16] = SLASH_PROPOSAL;
        scopes[17] = SLASH_EXECUTION;
        scopes[18] = TREASURY_DEPOSIT;
        scopes[19] = TREASURY_TRANSFER;
        scopes[20] = CONFIGURATION_PUBLISH;
        scopes[21] = MODULE_REGISTRY;
        scopes[22] = REPUTATION_ROOT;
        scopes[23] = UPGRADE_PROPOSAL;
        scopes[24] = UPGRADE_EXECUTION;
        scopes[25] = GOVERNANCE_RECOVERY;
    }

    /// @notice Returns the human-readable description of a canonical scope.
    /// @dev Used by documentation tooling and the scope-coverage tests. Returns an empty
    ///      string for a scope that is not part of the canonical manifest.
    function description(bytes32 scope) internal pure returns (string memory) {
        if (scope == GLOBAL) return "Protocol-wide emergency shutdown";
        if (scope == CLAIM_CREATION) return "Claim creation";
        if (scope == CLAIM_TRANSITION) return "Claim state transition and cancellation";
        if (scope == EVIDENCE_SUBMISSION) return "Evidence commitment submission";
        if (scope == EVIDENCE_STATUS) return "Evidence status adjudication";
        if (scope == STAKING) return "Stake deposit and lock placement";
        if (scope == STAKE_RELEASE) return "Escrowed principal release";
        if (scope == WITHDRAWAL) return "Claimable balance withdrawal";
        if (scope == VERIFICATION_SUBMISSION) return "Verifier attestation submission";
        if (scope == AGGREGATION_FINALIZATION) return "Verification aggregation finalization";
        if (scope == SETTLEMENT_QUEUE) return "Settlement queuing";
        if (scope == SETTLEMENT_EXECUTION) return "Settlement execution";
        if (scope == DISPUTE_OPEN) return "Dispute opening";
        if (scope == DISPUTE_RESOLUTION) return "Dispute resolution";
        if (scope == REWARD_ACCRUAL) return "Reward accrual";
        if (scope == REWARD_DISTRIBUTION) return "Reward distribution and claiming";
        if (scope == SLASH_PROPOSAL) return "Slash proposal";
        if (scope == SLASH_EXECUTION) return "Slash execution";
        if (scope == TREASURY_DEPOSIT) return "Treasury deposit";
        if (scope == TREASURY_TRANSFER) return "Treasury transfer";
        if (scope == CONFIGURATION_PUBLISH) return "Parameter set publication";
        if (scope == MODULE_REGISTRY) return "Canonical module registry mutation";
        if (scope == REPUTATION_ROOT) return "Reputation root proposal and acceptance";
        if (scope == UPGRADE_PROPOSAL) return "Upgrade proposal";
        if (scope == UPGRADE_EXECUTION) return "Upgrade execution";
        if (scope == GOVERNANCE_RECOVERY) return "Governance recovery operation";
        return "";
    }

    /// @notice Returns true when the scope belongs to the canonical manifest.
    function isCanonical(bytes32 scope) internal pure returns (bool) {
        return bytes(description(scope)).length != 0;
    }

    /// @notice Returns the stable operation identifier for a canonical scope.
    /// @dev Operation IDs are derived deterministically from the scope preimage so that
    ///      renamed functions, proxy upgrades, and interface reshuffles cannot silently
    ///      change the wire identifier. Unknown scopes fail closed by reverting.
    function operationId(bytes32 scope) internal pure returns (bytes32) {
        require(isCanonical(scope), "V2Scopes: unknown operation");
        return keccak256(abi.encodePacked("v2.operation", scope));
    }

    /// @notice Returns the canonical scope for a given operation identifier.
    /// @dev Inverse of `operationId`. Reverts when the operation is not part of the
    ///      published matrix, preventing accidental global-scope aliasing.
    function scopeForOperation(bytes32 opId) internal pure returns (bytes32) {
        bytes32[] memory scopes = canonicalScopes();
        for (uint256 i = 0; i < scopes.length; ++i) {
            if (operationId(scopes[i]) == opId) {
                return scopes[i];
            }
        }
        revert("V2Scopes: unknown operation");
    }

    /// @notice Returns the complete canonical operation matrix in stable order.
    /// @dev Positional order matches `canonicalScopes()`; consumers (frontend, API,
    ///      indexers) must treat this as the authoritative published matrix.
    function canonicalOperations() internal pure returns (bytes32[] memory ops) {
        bytes32[] memory scopes = canonicalScopes();
        ops = new bytes32[](scopes.length);
        for (uint256 i = 0; i < scopes.length; ++i) {
            ops[i] = operationId(scopes[i]);
        }
    }

    /// @notice Returns true when the operation identifier belongs to the canonical matrix.
    function isCanonicalOperation(bytes32 opId) internal pure returns (bool) {
        bytes32[] memory scopes = canonicalScopes();
        for (uint256 i = 0; i < scopes.length; ++i) {
            if (operationId(scopes[i]) == opId) {
                return true;
            }
        }
        return false;
    }

    /// @notice Returns the operation identifier paired with its scope and description.
    /// @dev Published matrix surface for frontend/API consumers and coverage tests.
    function operationMatrix()
        internal
        pure
        returns (bytes32[] memory ops, bytes32[] memory scopes, string[] memory descriptions)
    {
        scopes = canonicalScopes();
        ops = new bytes32[](scopes.length);
        descriptions = new string[](scopes.length);
        for (uint256 i = 0; i < scopes.length; ++i) {
            ops[i] = operationId(scopes[i]);
            descriptions[i] = description(scopes[i]);
        }
    }
}
