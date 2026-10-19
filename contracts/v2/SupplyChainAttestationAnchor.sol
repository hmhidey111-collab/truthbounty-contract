// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { ISupplyChainAttestations } from "./interfaces/ISupplyChainAttestations.sol";
import { IV2Module } from "./interfaces/IV2Module.sol";
import { V2Errors } from "./libraries/V2Errors.sol";
import { V2SafeCast } from "./libraries/V2SafeCast.sol";
import { V2SubmoduleProvenance } from "./libraries/V2SubmoduleProvenance.sol";

/// @title SupplyChainAttestationAnchor
/// @notice Read-only discovery anchor that publishes the authoritative
///         supply-chain attestation for one canonical V2 contract release.
/// @dev    V2-SC-138. Deployment-scoped, immutable after construction, and
///         strictly passive: the anchor never holds funds, never authorizes a
///         caller, and exposes no state-changing function beyond the
///         constructor. Consumers read `supplyChainAttestation()` or index the
///         `SupplyChainAttestationPublished` event; no off-chain actor gains any
///         settlement or treasury authority from this contract.
contract SupplyChainAttestationAnchor is ERC165, IV2Module, ISupplyChainAttestations {
    /// @notice Canonical SBOM/attestation schema identifier for release provenance.
    string public constant SBOM_FORMAT = "CycloneDX-1.5+in-toto/SLSA-v1";

    /// @notice Predicate type URI for the release SBOM attestation.
    string public constant SBOM_PREDICATE_TYPE =
        "https://truthbounty.protocol/attestation/release-sbom/v1";

    /// @notice Schema version for the attestation format.
    uint16 public constant ATTESTATION_SCHEMA_VERSION = 1;

    /// @notice Predicate type URI for in-toto / SLSA provenance attestations.
    string public constant PREDICATE_TYPE =
        "https://truthbounty.protocol/attestation/contract-release/v1";

    /// @notice Number of pinned submodule dependencies required for a valid release.
    /// @dev PREWAVE-SC-067: forge-std, OpenZeppelin, and nested submodules must all be
    ///      declared with immutable URL + SHA + license provenance before build.
    uint256 public constant MIN_PINNED_SUBMODULES = 3;

    /// @notice The immutable attestation fields for this deployment.
    /// @dev Written once in the constructor and never mutated (strings, arrays and structs cannot be `immutable`);
    ///      `supplyChainAttestation()` reassembles the authoritative record.
    string private _protocol;
    string private _releaseVersion;
    string private _sourceCommit;

    ISupplyChainAttestations.CompilerSettings private _compiler;

    /// @notice Chain ID this anchor is bound to, fixed at deployment.
    /// @dev Snapshot of block.chainid at construction; deployment manifests
    ///      must declare the same value.
    uint64 public immutable CHAIN_ID;

    /// @notice Deployer/admin recorded for provenance only. It carries no
    ///         runtime authority: the anchor has no functions it could call.
    address public immutable deployer;

    /// @notice Dependencies array stored as packed immutables.
    /// @dev Each dependency is encoded as: name|version|kind|rev|integrity
    string[] private _dependencyData;

    /// @notice Artifacts array stored as packed immutables.
    /// @dev Each artifact is encoded as: path|sha256|size
    string[] private _artifactData;

    ISupplyChainAttestations.WorkflowIdentity private _workflowIdentity;

    /// @notice Subjects array stored as packed immutables.
    /// @dev Each subject is encoded as: name|digest
    string[] private _subjectData;

    /// @notice Materials array stored as packed immutables.
    /// @dev Each material is encoded as: uri|digest
    string[] private _materialData;

    /// @notice Immutable digest of the canonical SBOM document.
    /// @dev Binds the on-chain anchor to the exact CycloneDX SBOM bytes.
    bytes32 private _sbomDigest;

    /// @notice Immutable digest of the in-toto/SLSA provenance envelope.
    bytes32 private _provenanceDigest;

    bytes32 private immutable _checksum;

    /// @param attestation_ The validated attestation record to publish.
    /// @param deployer_    Deployment provenance address; must not be zero.
    constructor(
        ISupplyChainAttestations.SupplyChainAttestation memory attestation_,
        address deployer_
    ) {
        if (deployer_ == address(0)) {
            revert V2Errors.ZeroAddress();
        }
        if (attestation_.schemaVersion != ATTESTATION_SCHEMA_VERSION) {
            revert V2Errors.InvalidAttestationSchemaVersion();
        }
        if (bytes(attestation_.protocol).length == 0) {
            revert V2Errors.EmptyProtocolName();
        }
        if (bytes(attestation_.releaseVersion).length == 0) {
            revert V2Errors.EmptyReleaseVersion();
        }
        if (!isValidSourceCommit(attestation_.sourceCommit)) {
            revert V2Errors.InvalidSourceCommit();
        }
        if (attestation_.checksum == bytes32(0)) {
            revert V2Errors.InvalidChecksum();
        }
        if (attestation_.sbomDigest == bytes32(0)) {
            revert V2Errors.InvalidChecksum();
        }
        if (attestation_.provenanceDigest == bytes32(0)) {
            revert V2Errors.InvalidChecksum();
        }
        // PREWAVE-SC-067: enforce immutable recursive dependency graph and reject
        // dirty/substituted content, missing nested modules, and license mismatch
        // before the anchor is deployed.
        if (!V2SubmoduleProvenance.verifyDependencyGraph(attestation_.dependencies, MIN_PINNED_SUBMODULES)) {
            revert V2Errors.InvalidSubmoduleProvenance();
        }

        _protocol = attestation_.protocol;
        _releaseVersion = attestation_.releaseVersion;
        _sourceCommit = attestation_.sourceCommit;
        _compiler = attestation_.compiler;
        // V2-SC-161: EIP-155 chain ids are not bounded by the EVM; refuse to truncate one.
        CHAIN_ID = V2SafeCast.toUint64(block.chainid, V2SafeCast.FIELD_ATTESTATION_CHAIN_ID);
        deployer = deployer_;

        _dependencyData = packDependencies(attestation_.dependencies);
        _artifactData = packArtifacts(attestation_.artifacts);
        _workflowIdentity = attestation_.workflowIdentity;
        _subjectData = packSubjects(attestation_.subjects);
        _materialData = packMaterials(attestation_.materials);
        _checksum = attestation_.checksum;
        _sbomDigest = attestation_.sbomDigest;
        _provenanceDigest = attestation_.provenanceDigest;

        // PREWAVE-SC-067: emit release attestation recording pinned submodule SHAs
        // so off-chain verifiers can reconstruct the immutable dependency graph.
        emit SubmoduleProvenancePinned(attestation_.dependencies);

        emit SupplyChainAttestationPublished(attestation_);
    }

    /// @inheritdoc ISupplyChainAttestations
    function supplyChainAttestation() external view override returns (ISupplyChainAttestations.SupplyChainAttestation memory) {
        return ISupplyChainAttestations.SupplyChainAttestation({
            schemaVersion: ATTESTATION_SCHEMA_VERSION,
            protocol: _protocol,
            releaseVersion: _releaseVersion,
            sourceCommit: _sourceCommit,
            compiler: _compiler,
            dependencies: unpackDependencies(_dependencyData),
            artifacts: unpackArtifacts(_artifactData),
            workflowIdentity: _workflowIdentity,
            subjects: unpackSubjects(_subjectData),
            materials: unpackMaterials(_materialData),
            checksum: _checksum,
            sbomDigest: _sbomDigest,
            provenanceDigest: _provenanceDigest
        });
    }

    /// @notice Returns the pinned submodule dependency graph for release attestation.
    /// @dev PREWAVE-SC-067: exposes the immutable dependency list so verifiers can
    ///      confirm URLs/SHAs/licenses without trusting off-chain manifests.
    function pinnedSubmodules() external view returns (ISupplyChainAttestations.DependencyEntry[] memory) {
        return unpackDependencies(_dependencyData);
    }

    /// @notice Immutable protocol version marker shared by canonical V2 modules.
    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    /// @notice Returns the canonical SBOM format identifier.
    function sbomFormat() external pure returns (string memory) {
        return SBOM_FORMAT;
    }

    /// @notice Returns the predicate type URI for the release SBOM attestation.
    function sbomPredicateType() external pure returns (string memory) {
        return SBOM_PREDICATE_TYPE;
    }

    /// @notice ERC-165: advertises ISupplyChainAttestations, IV2Module, and ERC-165.
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(ISupplyChainAttestations).interfaceId
            || interfaceId == type(IV2Module).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Emitted when the pinned submodule dependency graph is recorded.
    /// @dev PREWAVE-SC-067: release attestation records SHAs for all pinned modules.
    event SubmoduleProvenancePinned(ISupplyChainAttestations.DependencyEntry[] dependencies);

    /// @dev Validates 40-character lowercase hex source commit.
    function isValidSourceCommit(string memory commit) internal pure returns (bool) {
        if (bytes(commit).length != 40) {
            return false;
        }
        for (uint256 i = 0; i < 40; i++) {
            uint8 c = uint8(bytes(commit)[i]);
            if (!((c >= 48 && c <= 57) || (c >= 97 && c <= 102))) { // 0-9, a-f
                return false;
            }
        }
        return true;
    }

    /// @dev PREWAVE-SC-067: rejects any dependency whose integrity field is not a
    ///      full 40-char commit SHA, preventing substituted or dirty content from
    ///      being recorded in the immutable dependency graph.
    function _requirePinnedRev(string memory rev) internal pure returns (bool) {
        return isValidSourceCommit(rev);
    }

    /// @dev V2-SC-160: a delimiter-joined record is injective only if no variable-length field
    ///      can contain the delimiter. Without this guard `name = "a|b", version = "c"` and
    ///      `name = "a", version = "b|c"` pack to the same record and read back as the latter,
    ///      silently shifting every later field (including `integrity`). Fixed-format fields
    ///      (lowercase hex digests and decimal sizes rendered on-chain) cannot contain '|'.
    function _requireNoDelimiter(string memory field) internal pure {
        bytes memory b = bytes(field);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == bytes1("|")) {
                revert V2Errors.AttestationFieldContainsDelimiter();
            }
        }
    }

    /// @dev Packs dependencies into delimiter-separated strings for immutable storage.
    function packDependencies(ISupplyChainAttestations.DependencyEntry[] memory deps) internal pure returns (string[] memory) {
        string[] memory packed = new string[](deps.length);
        for (uint256 i = 0; i < deps.length; i++) {
            _requireNoDelimiter(deps[i].name);
            _requireNoDelimiter(deps[i].version);
            _requireNoDelimiter(deps[i].kind);
            _requireNoDelimiter(deps[i].rev);
            _requireNoDelimiter(deps[i].integrity);
            // PREWAVE-SC-067: every dependency must carry a pinned commit SHA.
            if (!_requirePinnedRev(deps[i].rev)) {
                revert V2Errors.InvalidSubmoduleProvenance();
            }
            packed[i] = string(
                abi.encodePacked(
                    deps[i].name, "|",
                    deps[i].version, "|",
                    deps[i].kind, "|",
                    deps[i].rev, "|",
                    deps[i].integrity
                )
            );
        }
        return packed;
    }

    /// @dev Packs artifacts into delimiter-separated strings for immutable storage.
    function packArtifacts(ISupplyChainAttestations.ArtifactHash[] memory artifacts) internal pure returns (string[] memory) {
        string[] memory packed = new string[](artifacts.length);
        for (uint256 i = 0; i < artifacts.length; i++) {
            _requireNoDelimiter(artifacts[i].path);
            packed[i] = string(
                abi.encodePacked(
                    artifacts[i].path, "|",
                    bytes32ToHexString(artifacts[i].sha256), "|",
                    uint2str(artifacts[i].size)
                )
            );
        }
        return packed;
    }

    /// @dev Packs subjects into delimiter-separated strings for immutable storage.
    function packSubjects(ISupplyChainAttestations.AttestationSubject[] memory subjects) internal pure returns (string[] memory) {
        string[] memory packed = new string[](subjects.length);
        for (uint256 i = 0; i < subjects.length; i++) {
            _requireNoDelimiter(subjects[i].name);
            packed[i] = string(
                abi.encodePacked(
                    subjects[i].name, "|",
                    bytes32ToHexString(subjects[i].digest)
                )
            );
        }
        return packed;
    }

    /// @dev Packs materials into delimiter-separated strings for immutable storage.
    function packMaterials(ISupplyChainAttestations.AttestationMaterial[] memory materials) internal pure returns (string[] memory) {
        string[] memory packed = new string[](materials.length);
        for (uint256 i = 0; i < materials.length; i++) {
            _requireNoDelimiter(materials[i].uri);
            packed[i] = string(
                abi.encodePacked(
                    materials[i].uri, "|",
                    bytes32ToHexString(materials[i].digest)
                )
            );
        }
        return packed;
    }

    /// @dev Unpacks dependencies from delimiter-separated strings.
    function unpackDependencies(string[] memory packed) internal pure returns (ISupplyChainAttestations.DependencyEntry[] memory) {
        ISupplyChainAttestations.DependencyEntry[] memory deps = new ISupplyChainAttestations.DependencyEntry[](packed.length);
        for (uint256 i = 0; i < packed.length; i++) {
            (string memory name, string memory version, string memory kind, string memory rev, string memory integrity) =
                split5(packed[i], '|');
            deps[i] = ISupplyChainAttestations.DependencyEntry({
                name: name,
                version: version,
                kind: kind,
                rev: rev,
                integrity: integrity
            });
        }
        return deps;
    }

    /// @dev Unpacks artifacts from delimiter-separated strings.
    function unpackArtifacts(string[] memory packed) internal pure returns (ISupplyChainAttestations.ArtifactHash[] memory) {
        ISupplyChainAttestations.ArtifactHash[] memory artifacts = new ISupplyChainAttestations.ArtifactHash[](packed.length);
        for (uint256 i = 0; i < packed.length; i++) {
            (string memory path, string memory sha256Hex, string memory sizeStr) = split3(packed[i], '|');
            artifacts[i] = ISupplyChainAttestations.ArtifactHash({
                path: path,
                sha256: hexStringToBytes32(sha256Hex),
                size: parseUint(sizeStr)
            });
        }
        return artifacts;
    }

    /// @dev Unpacks subjects from delimiter-separated strings.
    function unpackSubjects(string[] memory packed) internal pure returns (ISupplyChainAttestations.AttestationSubject[] memory) {
        ISupplyChainAttestations.AttestationSubject[] memory subjects = new ISupplyChainAttestations.AttestationSubject[](packed.length);
        for (uint256 i = 0; i < packed.length; i++) {
            (string memory name, string memory digestHex) = split2(packed[i], '|');
            subjects[i] = ISupplyChainAttestations.AttestationSubject({
                name: name,
                digest: hexStringToBytes32(digestHex)
            });
        }
        return subjects;
    }

    /// @dev Unpacks materials from delimiter-separated strings.
    function unpackMaterials(string[] memory packed) internal pure returns (ISupplyChainAttestations.AttestationMaterial[] memory) {
        ISupplyChainAttestations.AttestationMaterial[] memory materials = new ISupplyChainAttestations.AttestationMaterial[](packed.length);
        for (uint256 i = 0; i < packed.length; i++) {
            (string memory uri, string memory digestHex) = split2(packed[i], '|');
            materials[i] = ISupplyChainAttestations.AttestationMaterial({
                uri: uri,
                digest: hexStringToBytes32(digestHex)
            });
        }
        return materials;
    }

    /// @dev Splits a string by delimiter into 2 parts.
    function split2(string memory data, bytes1 delimiter) internal pure returns (string memory, string memory) {
        uint256 pos = findDelimiter(data, delimiter);
        return (substring(data, 0, pos), substring(data, pos + 1, bytes(data).length));
    }

    /// @dev Splits a string by delimiter into 3 parts.
    function split3(string memory data, bytes1 delimiter) internal pure returns (string memory, string memory, string memory) {
        uint256 pos1 = findDelimiter(data, delimiter);
        uint256 pos2 = findDelimiterPos(data, delimiter, pos1 + 1);
        return (
            substring(data, 0, pos1),
            substring(data, pos1 + 1, pos2),
            substring(data, pos2 + 1, bytes(data).length)
        );
    }

    /// @dev Splits a string by delimiter into 5 parts.
    function split5(string memory data, bytes1 delimiter) internal pure returns (string memory, string memory, string memory, string memory, string memory) {
        uint256 pos1 = findDelimiter(data, delimiter);
        uint256 pos2 = findDelimiterPos(data, delimiter, pos1 + 1);
        uint256 pos3 = findDelimiterPos(data, delimiter, pos2 + 1);
        uint256 pos4 = findDelimiterPos(data, delimiter, pos3 + 1);
        return (
            substring(data, 0, pos1),
            substring(data, pos1 + 1, pos2),
            substring(data, pos2 + 1, pos3),
            substring(data, pos3 + 1, pos4),
            substring(data, pos4 + 1, bytes(data).length)
        );
    }

    /// @dev Finds first delimiter position.
    function findDelimiter(string memory data, bytes1 delimiter) internal pure returns (uint256) {
        bytes memory b = bytes(data);
        for (uint256 i = 0; i < b.length; i++) {
            if (uint8(b[i]) == uint8(delimiter)) {
                return i;
            }
        }
        return b.length;
    }

    /// @dev Finds next delimiter position after start.
    function findDelimiterPos(string memory data, bytes1 delimiter, uint256 start) internal pure returns (uint256) {
        bytes memory b = bytes(data);
        for (uint256 i = start; i < b.length; i++) {
            if (uint8(b[i]) == uint8(delimiter)) {
                return i;
            }
        }
        return b.length;
    }

    /// @dev Extracts substring from string.
    function substring(string memory data, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory b = bytes(data);
        bytes memory result = new bytes(end - start);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = b[start + i];
        }
        return string(result);
    }

    /// @dev Converts hex string to bytes32.
    function hexStringToBytes32(string memory hexStr) internal pure returns (bytes32) {
        bytes memory b = bytes(hexStr);
        require(b.length == 64, "invalid hex length");
        uint256 result;
        for (uint256 i = 0; i < 64; i++) {
            result = (result << 4) | parseHexNibble(uint8(b[i]));
        }
        return bytes32(result);
    }

    /// @dev Parses a single hex nibble.
    function parseHexNibble(uint8 c) internal pure returns (uint8) {
        if (c >= 48 && c <= 57) return c - 48;      // 0-9
        if (c >= 97 && c <= 102) return c - 87;      // a-f
        if (c >= 65 && c <= 70) return c - 55;       // A-F
        return 0;
    }

    /// @dev Parses uint256 from string.
    function parseUint(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 48 && c <= 57) {
                result = result * 10 + (c - 48);
            }
        }
        return result;
    }

    /// @dev Converts uint256 to decimal string.
    function uint2str(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits = 0;
        while (temp > 0) {
            temp /= 10;
            digits++;
        }
        bytes memory buffer = new bytes(digits);
        while (value > 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }

    /// @dev Converts bytes32 to 64-char hex string.
    function bytes32ToHexString(bytes32 data) internal pure returns (string memory) {
        bytes memory hexBytes = new bytes(64);
        bytes memory alphabet = "0123456789abcdef";
        for (uint256 i = 0; i < 32; i++) {
            uint8 byteValue = uint8(data[i]);
            hexBytes[i * 2] = alphabet[byteValue >> 4];
            hexBytes[i * 2 + 1] = alphabet[byteValue & 0x0f];
        }
        return string(hexBytes);
    }
}