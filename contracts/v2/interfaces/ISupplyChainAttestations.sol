// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IV2Module } from "./IV2Module.sol";

/// @title ISupplyChainAttestations
/// @notice Read-only discovery anchor that publishes the authoritative
///         supply-chain attestation for one canonical V2 contract release.
/// @dev    V2-SC-138. Deployment-scoped, immutable after construction, and
///         strictly passive: the anchor never holds funds, never authorizes a
///         caller, and exposes no state-changing function beyond the
///         constructor. Consumers read `supplyChainAttestation()` or index the
///         `SupplyChainAttestationPublished` event; no off-chain actor gains any
///         settlement or treasury authority from this contract.
interface ISupplyChainAttestations is IV2Module {
    /// @notice Compiler settings used for the release build.
    struct CompilerSettings {
        string solidityVersion;
        string evmVersion;
        bool viaIR;
        bool optimizerEnabled;
        uint256 optimizerRuns;
    }

    /// @notice Dependency entry (npm or git submodule).
    struct DependencyEntry {
        string name;
        string version;
        string kind; // "npm" | "git-submodule"
        string rev; // git commit hash for submodules
        string integrity; // optional integrity hash
    }

    /// @notice Build artifact hash entry.
    struct ArtifactHash {
        string path;
        bytes32 sha256;
        uint256 size;
    }

    /// @notice CI/CD workflow identity.
    struct WorkflowIdentity {
        bool present;
        string repository;
        string workflow;
        string workflowRef;
        string runId;
        string runAttempt;
        string ref;
        string sha;
        string serverUrl;
    }

    /// @notice Attestation subject (artifact with digest).
    struct AttestationSubject {
        string name;
        bytes32 digest;
    }

    /// @notice Attestation material (dependency with optional digest).
    struct AttestationMaterial {
        string uri;
        bytes32 digest; // zero if not applicable
    }

    /// @notice Complete supply-chain attestation record.
    struct SupplyChainAttestation {
        uint16 schemaVersion;
        string protocol;
        string releaseVersion;
        string sourceCommit; // 40-char hex
        CompilerSettings compiler;
        DependencyEntry[] dependencies;
        ArtifactHash[] artifacts;
        WorkflowIdentity workflowIdentity;
        AttestationSubject[] subjects;
        AttestationMaterial[] materials;
        bytes32 checksum; // SHA256 of canonicalized attestation (excluding this field)
    }

    /// @notice Emitted once at construction with the full attestation.
    event SupplyChainAttestationPublished(SupplyChainAttestation attestation);

    /// @notice Returns the immutable supply-chain attestation for this deployment.
    function supplyChainAttestation() external view returns (SupplyChainAttestation memory);
}