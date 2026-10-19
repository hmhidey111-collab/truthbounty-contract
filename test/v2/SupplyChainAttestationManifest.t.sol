// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { SupplyChainAttestationAnchor } from "../../contracts/v2/SupplyChainAttestationAnchor.sol";
import { ISupplyChainAttestations } from "../../contracts/v2/interfaces/ISupplyChainAttestations.sol";
import { IV2Module } from "../../contracts/v2/interfaces/IV2Module.sol";
import { V2Errors } from "../../contracts/v2/libraries/V2Errors.sol";

/// @title SupplyChainAttestationManifest
/// @notice Deployment-artifact drift validation: the published manifest at
///         deployments/config/supply-chain-attestations.json must agree field-by-field
///         with the on-chain attestation produced from the same constants. A
///         maintainer editing either side without the other fails CI here.
contract SupplyChainAttestationManifestTest is Test {
    string internal manifestJson;
    string internal manifestPath;

    function setUp() public {
        // forge-repo-root relative path; the cheatcode reads from the repository
        // root so the manifest is validated exactly as committed.
        manifestPath = "deployments/config/supply-chain-attestations.json";
        manifestJson = vm.readFile(manifestPath);
    }

    function test_ManifestExistsAndParses() public view {
        assertTrue(bytes(manifestJson).length > 0, "manifest must not be empty");
        assertEq(vm.parseJsonUint(manifestJson, ".manifestVersion"), 1);
        assertEq(vm.parseJsonString(manifestJson, ".issue"), "V2-SC-138");
    }

    function test_ManifestAttestationMatchesContractDefaults() public view {
        // Verify schema version
        assertEq(vm.parseJsonUint(manifestJson, ".supplyChainAttestation.schemaVersion"), 1);

        // Verify protocol name
        assertEq(vm.parseJsonString(manifestJson, ".supplyChainAttestation.protocol"), "TruthBounty");

        // Verify release version is not empty/placeholder
        string memory releaseVersion = vm.parseJsonString(manifestJson, ".supplyChainAttestation.releaseVersion");
        assertFalse(bytes(releaseVersion).length == 0, "releaseVersion must not be empty");
        assertFalse(keccak256(bytes(releaseVersion)) == keccak256(bytes("0.0.0")), "releaseVersion must not be placeholder");

        // Verify source commit format (40-char hex)
        string memory sourceCommit = vm.parseJsonString(manifestJson, ".supplyChainAttestation.sourceCommit");
        assertTrue(isValidSourceCommit(sourceCommit), "sourceCommit must be 40-char lowercase hex");

        // Verify compiler settings
        assertEq(vm.parseJsonString(manifestJson, ".supplyChainAttestation.compiler.solidityVersion"), "0.8.28");
        assertEq(vm.parseJsonString(manifestJson, ".supplyChainAttestation.compiler.evmVersion"), "cancun");
        assertTrue(vm.parseJsonBool(manifestJson, ".supplyChainAttestation.compiler.viaIR"));
        assertTrue(vm.parseJsonBool(manifestJson, ".supplyChainAttestation.compiler.optimizerEnabled"));
        assertEq(vm.parseJsonUint(manifestJson, ".supplyChainAttestation.compiler.optimizerRuns"), 200);

        // Verify dependencies array is present and non-empty
        uint256 depCount = vm.parseJsonUint(manifestJson, ".supplyChainAttestation.dependencies.length");
        assertGt(depCount, 0, "must have at least one dependency");

        // Verify artifacts array is present and non-empty
        uint256 artifactCount = vm.parseJsonUint(manifestJson, ".supplyChainAttestation.artifacts.length");
        assertGt(artifactCount, 0, "must have at least one artifact");

        // Verify subjects array matches artifacts count
        uint256 subjectCount = vm.parseJsonUint(manifestJson, ".supplyChainAttestation.subjects.length");
        assertEq(subjectCount, artifactCount, "subjects count must match artifacts count");

        // Verify materials array is present
        uint256 materialCount = vm.parseJsonUint(manifestJson, ".supplyChainAttestation.materials.length");
        assertGt(materialCount, 0, "must have at least one material");

        // Verify checksum is present and valid hex
        string memory checksum = vm.parseJsonString(manifestJson, ".supplyChainAttestation.checksum");
        assertTrue(bytes(checksum).length == 64, "checksum must be 64-char hex");
    }

    function test_ManifestValuesPassContractValidation() public {
        // Build attestation from manifest
        ISupplyChainAttestations.SupplyChainAttestation memory attestation = buildAttestationFromManifest();

        // Deploy anchor with manifest values - must not revert
        vm.chainId(vm.parseJsonUint(manifestJson, ".chainId"));
        SupplyChainAttestationAnchor anchor = new SupplyChainAttestationAnchor(attestation, address(this));

        // Verify anchor exposes attestation verbatim
        ISupplyChainAttestations.SupplyChainAttestation memory published = anchor.supplyChainAttestation();

        assertEq(published.schemaVersion, attestation.schemaVersion);
        assertEq(keccak256(bytes(published.protocol)), keccak256(bytes(attestation.protocol)));
        assertEq(keccak256(bytes(published.releaseVersion)), keccak256(bytes(attestation.releaseVersion)));
        assertEq(keccak256(bytes(published.sourceCommit)), keccak256(bytes(attestation.sourceCommit)));
        assertEq(published.compiler.solidityVersion, attestation.compiler.solidityVersion);
        assertEq(published.compiler.evmVersion, attestation.compiler.evmVersion);
        assertEq(published.compiler.viaIR, attestation.compiler.viaIR);
        assertEq(published.compiler.optimizerEnabled, attestation.compiler.optimizerEnabled);
        assertEq(published.compiler.optimizerRuns, attestation.compiler.optimizerRuns);

        // Verify dependencies
        assertEq(published.dependencies.length, attestation.dependencies.length);
        for (uint256 i = 0; i < published.dependencies.length; i++) {
            assertEq(keccak256(bytes(published.dependencies[i].name)), keccak256(bytes(attestation.dependencies[i].name)));
            assertEq(keccak256(bytes(published.dependencies[i].version)), keccak256(bytes(attestation.dependencies[i].version)));
        }

        // Verify artifacts
        assertEq(published.artifacts.length, attestation.artifacts.length);
        for (uint256 i = 0; i < published.artifacts.length; i++) {
            assertEq(keccak256(bytes(published.artifacts[i].path)), keccak256(bytes(attestation.artifacts[i].path)));
            assertEq(published.artifacts[i].sha256, attestation.artifacts[i].sha256);
            assertEq(published.artifacts[i].size, attestation.artifacts[i].size);
        }

        // Verify workflow identity
        assertEq(published.workflowIdentity.present, attestation.workflowIdentity.present);
        if (attestation.workflowIdentity.present) {
            assertEq(keccak256(bytes(published.workflowIdentity.repository)), keccak256(bytes(attestation.workflowIdentity.repository)));
            assertEq(keccak256(bytes(published.workflowIdentity.workflow)), keccak256(bytes(attestation.workflowIdentity.workflow)));
            assertEq(keccak256(bytes(published.workflowIdentity.runId)), keccak256(bytes(attestation.workflowIdentity.runId)));
        }

        // Verify subjects
        assertEq(published.subjects.length, attestation.subjects.length);
        for (uint256 i = 0; i < published.subjects.length; i++) {
            assertEq(keccak256(bytes(published.subjects[i].name)), keccak256(bytes(attestation.subjects[i].name)));
            assertEq(published.subjects[i].digest, attestation.subjects[i].digest);
        }

        // Verify materials
        assertEq(published.materials.length, attestation.materials.length);
        for (uint256 i = 0; i < published.materials.length; i++) {
            assertEq(keccak256(bytes(published.materials[i].uri)), keccak256(bytes(attestation.materials[i].uri)));
            assertEq(published.materials[i].digest, attestation.materials[i].digest);
        }

        // Verify checksum
        assertEq(published.checksum, attestation.checksum);
    }

    function test_ManifestChainIdAndIdentityRulesPresent() public view {
        assertEq(vm.parseJsonUint(manifestJson, ".chainId"), 11155420);
        assertFalse(bytes(vm.parseJsonString(manifestJson, ".anchor.artifact")).length == 0);
        assertFalse(bytes(vm.parseJsonString(manifestJson, ".anchor.source")).length == 0);
        assertFalse(bytes(vm.parseJsonString(manifestJson, ".anchor.deployTimePublicationEvent")).length == 0);
    }

    function test_ManifestConsumerResponsibilitiesPresent() public view {
        uint256 count = vm.parseJsonUint(manifestJson, ".consumerResponsibilities.length");
        assertGt(count, 0, "consumer responsibilities must be documented");
    }

    function test_AnchorRejectsInvalidSchemaVersion() public {
        ISupplyChainAttestations.SupplyChainAttestation memory attestation = buildAttestationFromManifest();
        attestation.schemaVersion = 999; // Invalid

        vm.expectRevert(V2Errors.InvalidAttestationSchemaVersion.selector);
        new SupplyChainAttestationAnchor(attestation, address(this));
    }

    function test_AnchorRejectsZeroDeployer() public {
        ISupplyChainAttestations.SupplyChainAttestation memory attestation = buildAttestationFromManifest();

        vm.expectRevert(V2Errors.ZeroAddress.selector);
        new SupplyChainAttestationAnchor(attestation, address(0));
    }

    function test_AnchorRejectsEmptyProtocol() public {
        ISupplyChainAttestations.SupplyChainAttestation memory attestation = buildAttestationFromManifest();
        attestation.protocol = "";

        vm.expectRevert(V2Errors.EmptyProtocolName.selector);
        new SupplyChainAttestationAnchor(attestation, address(this));
    }

    function test_AnchorRejectsEmptyReleaseVersion() public {
        ISupplyChainAttestations.SupplyChainAttestation memory attestation = buildAttestationFromManifest();
        attestation.releaseVersion = "";

        vm.expectRevert(V2Errors.EmptyReleaseVersion.selector);
        new SupplyChainAttestationAnchor(attestation, address(this));
    }

    function test_AnchorRejectsInvalidSourceCommit() public {
        ISupplyChainAttestations.SupplyChainAttestation memory attestation = buildAttestationFromManifest();
        attestation.sourceCommit = "not-a-valid-commit";

        vm.expectRevert(V2Errors.InvalidSourceCommit.selector);
        new SupplyChainAttestationAnchor(attestation, address(this));
    }

    function test_AnchorRejectsZeroChecksum() public {
        ISupplyChainAttestations.SupplyChainAttestation memory attestation = buildAttestationFromManifest();
        attestation.checksum = bytes32(0);

        vm.expectRevert(V2Errors.InvalidChecksum.selector);
        new SupplyChainAttestationAnchor(attestation, address(this));
    }

    /// @dev V2-SC-160 constructive fixture: `name = "a|b", version = "c"` would pack to the same
    ///      delimiter-joined record as `name = "a", version = "b|c"`; the anchor must refuse it.
    function test_AnchorRejectsDelimiterInDependencyField() public {
        ISupplyChainAttestations.SupplyChainAttestation memory attestation = buildAttestationFromManifest();
        attestation.dependencies[0].name = "a|b";

        vm.expectRevert(V2Errors.AttestationFieldContainsDelimiter.selector);
        new SupplyChainAttestationAnchor(attestation, address(this));
    }

    function test_AnchorRejectsDelimiterInArtifactPath() public {
        ISupplyChainAttestations.SupplyChainAttestation memory attestation = buildAttestationFromManifest();
        attestation.artifacts[0].path = "out/A.json|deadbeef";

        vm.expectRevert(V2Errors.AttestationFieldContainsDelimiter.selector);
        new SupplyChainAttestationAnchor(attestation, address(this));
    }

    function test_ProtocolVersionMarker() public {
        ISupplyChainAttestations.SupplyChainAttestation memory attestation = buildAttestationFromManifest();
        SupplyChainAttestationAnchor anchor = new SupplyChainAttestationAnchor(attestation, address(this));

        (uint16 major, uint16 minor) = anchor.protocolVersion();
        assertEq(major, 2);
        assertEq(minor, 0);
    }

    function test_SupportsInterfaces() public {
        ISupplyChainAttestations.SupplyChainAttestation memory attestation = buildAttestationFromManifest();
        SupplyChainAttestationAnchor anchor = new SupplyChainAttestationAnchor(attestation, address(this));

        assertTrue(anchor.supportsInterface(type(ISupplyChainAttestations).interfaceId));
        assertTrue(anchor.supportsInterface(type(IV2Module).interfaceId));
        assertTrue(anchor.supportsInterface(0x01ffc9a7)); // ERC165
    }

    // Builds attestation struct from manifest JSON
    function buildAttestationFromManifest() internal view returns (ISupplyChainAttestations.SupplyChainAttestation memory) {
        ISupplyChainAttestations.SupplyChainAttestation memory attestation;

        attestation.schemaVersion = uint16(vm.parseJsonUint(manifestJson, ".supplyChainAttestation.schemaVersion"));
        attestation.protocol = vm.parseJsonString(manifestJson, ".supplyChainAttestation.protocol");
        attestation.releaseVersion = vm.parseJsonString(manifestJson, ".supplyChainAttestation.releaseVersion");
        attestation.sourceCommit = vm.parseJsonString(manifestJson, ".supplyChainAttestation.sourceCommit");

        // Compiler
        attestation.compiler = ISupplyChainAttestations.CompilerSettings({
            solidityVersion: vm.parseJsonString(manifestJson, ".supplyChainAttestation.compiler.solidityVersion"),
            evmVersion: vm.parseJsonString(manifestJson, ".supplyChainAttestation.compiler.evmVersion"),
            viaIR: vm.parseJsonBool(manifestJson, ".supplyChainAttestation.compiler.viaIR"),
            optimizerEnabled: vm.parseJsonBool(manifestJson, ".supplyChainAttestation.compiler.optimizerEnabled"),
            optimizerRuns: vm.parseJsonUint(manifestJson, ".supplyChainAttestation.compiler.optimizerRuns")
        });

        // Dependencies
        uint256 depCount = vm.parseJsonUint(manifestJson, ".supplyChainAttestation.dependencies.length");
        attestation.dependencies = new ISupplyChainAttestations.DependencyEntry[](depCount);
        for (uint256 i = 0; i < depCount; i++) {
            attestation.dependencies[i] = ISupplyChainAttestations.DependencyEntry({
                name: vm.parseJsonString(manifestJson, string(abi.encodePacked(".supplyChainAttestation.dependencies[", vm.toString(i), "].name"))),
                version: vm.parseJsonString(manifestJson, string(abi.encodePacked(".supplyChainAttestation.dependencies[", vm.toString(i), "].version"))),
                kind: vm.parseJsonString(manifestJson, string(abi.encodePacked(".supplyChainAttestation.dependencies[", vm.toString(i), "].kind"))),
                rev: vm.parseJsonString(manifestJson, string(abi.encodePacked(".supplyChainAttestation.dependencies[", vm.toString(i), "].rev"))),
                integrity: vm.parseJsonString(manifestJson, string(abi.encodePacked(".supplyChainAttestation.dependencies[", vm.toString(i), "].integrity")))
            });
        }

        // Artifacts
        uint256 artifactCount = vm.parseJsonUint(manifestJson, ".supplyChainAttestation.artifacts.length");
        attestation.artifacts = new ISupplyChainAttestations.ArtifactHash[](artifactCount);
        for (uint256 i = 0; i < artifactCount; i++) {
            string memory sha256Hex = vm.parseJsonString(manifestJson, string(abi.encodePacked(".supplyChainAttestation.artifacts[", vm.toString(i), "].sha256")));
            attestation.artifacts[i] = ISupplyChainAttestations.ArtifactHash({
                path: vm.parseJsonString(manifestJson, string(abi.encodePacked(".supplyChainAttestation.artifacts[", vm.toString(i), "].path"))),
                sha256: parseHexStringToBytes32(sha256Hex),
                size: vm.parseJsonUint(manifestJson, string(abi.encodePacked(".supplyChainAttestation.artifacts[", vm.toString(i), "].size")))
            });
        }

        // Workflow Identity
        attestation.workflowIdentity = ISupplyChainAttestations.WorkflowIdentity({
            present: vm.parseJsonBool(manifestJson, ".supplyChainAttestation.workflowIdentity.present"),
            repository: vm.parseJsonString(manifestJson, ".supplyChainAttestation.workflowIdentity.repository"),
            workflow: vm.parseJsonString(manifestJson, ".supplyChainAttestation.workflowIdentity.workflow"),
            workflowRef: vm.parseJsonString(manifestJson, ".supplyChainAttestation.workflowIdentity.workflowRef"),
            runId: vm.parseJsonString(manifestJson, ".supplyChainAttestation.workflowIdentity.runId"),
            runAttempt: vm.parseJsonString(manifestJson, ".supplyChainAttestation.workflowIdentity.runAttempt"),
            ref: vm.parseJsonString(manifestJson, ".supplyChainAttestation.workflowIdentity.ref"),
            sha: vm.parseJsonString(manifestJson, ".supplyChainAttestation.workflowIdentity.sha"),
            serverUrl: vm.parseJsonString(manifestJson, ".supplyChainAttestation.workflowIdentity.serverUrl")
        });

        // Subjects
        uint256 subjectCount = vm.parseJsonUint(manifestJson, ".supplyChainAttestation.subjects.length");
        attestation.subjects = new ISupplyChainAttestations.AttestationSubject[](subjectCount);
        for (uint256 i = 0; i < subjectCount; i++) {
            string memory digestHex = vm.parseJsonString(manifestJson, string(abi.encodePacked(".supplyChainAttestation.subjects[", vm.toString(i), "].digest")));
            attestation.subjects[i] = ISupplyChainAttestations.AttestationSubject({
                name: vm.parseJsonString(manifestJson, string(abi.encodePacked(".supplyChainAttestation.subjects[", vm.toString(i), "].name"))),
                digest: parseHexStringToBytes32(digestHex)
            });
        }

        // Materials
        uint256 materialCount = vm.parseJsonUint(manifestJson, ".supplyChainAttestation.materials.length");
        attestation.materials = new ISupplyChainAttestations.AttestationMaterial[](materialCount);
        for (uint256 i = 0; i < materialCount; i++) {
            string memory digestHex = vm.parseJsonString(manifestJson, string(abi.encodePacked(".supplyChainAttestation.materials[", vm.toString(i), "].digest")));
            attestation.materials[i] = ISupplyChainAttestations.AttestationMaterial({
                uri: vm.parseJsonString(manifestJson, string(abi.encodePacked(".supplyChainAttestation.materials[", vm.toString(i), "].uri"))),
                digest: parseHexStringToBytes32(digestHex)
            });
        }

        // Checksum
        string memory checksumHex = vm.parseJsonString(manifestJson, ".supplyChainAttestation.checksum");
        attestation.checksum = parseHexStringToBytes32(checksumHex);

        return attestation;
    }

    // Validates 40-character lowercase hex source commit
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

    // Parses 64-char hex string to bytes32
    function parseHexStringToBytes32(string memory hexStr) internal pure returns (bytes32) {
        bytes memory b = bytes(hexStr);
        require(b.length == 64, "invalid hex length");
        uint256 result;
        for (uint256 i = 0; i < 64; i++) {
            result = (result << 4) | parseHexNibble(uint8(b[i]));
        }
        return bytes32(result);
    }

    // Parses a single hex nibble
    function parseHexNibble(uint8 c) internal pure returns (uint8) {
        if (c >= 48 && c <= 57) return c - 48;      // 0-9
        if (c >= 97 && c <= 102) return c - 87;      // a-f
        if (c >= 65 && c <= 70) return c - 55;       // A-F
        return 0;
    }
}