// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {DeploymentAttestationRegistry} from "../../contracts/deployment/DeploymentAttestationRegistry.sol";

contract DeploymentAttestationRegistryTest is Test {
    DeploymentAttestationRegistry internal registry;
    address internal authority = makeAddr("authority");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        registry = new DeploymentAttestationRegistry(authority);
    }

    function testRecordsImmutableDeploymentManifest() public {
        bytes32 releaseId = keccak256("release-2026-09-25");
        bytes32 digest = keccak256("artifact");
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("governor");
        ids[1] = keccak256("treasury");
        address[] memory modules = new address[](2);
        modules[0] = makeAddr("governor");
        modules[1] = makeAddr("treasury");

        vm.prank(authority);
        registry.attestDeployment(releaseId, block.chainid, digest, 7, ids, modules);

        DeploymentAttestationRegistry.Attestation memory attestation = registry.getAttestation(releaseId);
        assertEq(attestation.releaseId, releaseId);
        assertEq(attestation.chainId, block.chainid);
        assertEq(attestation.artifactDigest, digest);
        assertEq(attestation.configurationVersion, 7);
        assertEq(registry.governanceAuthority(), authority);
        assertEq(registry.attestationCount(), 1);
        assertEq(registry.getModuleCount(releaseId), 2);

        (bytes32 moduleId, address moduleAddress) = registry.getModule(releaseId, 1);
        assertEq(moduleId, ids[1]);
        assertEq(moduleAddress, modules[1]);
    }

    function testRejectsUnauthorizedAndDuplicateAttestations() public {
        bytes32 releaseId = keccak256("release");
        bytes32[] memory ids = new bytes32[](0);
        address[] memory modules = new address[](0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DeploymentAttestationRegistry.Unauthorized.selector, stranger));
        registry.attestDeployment(releaseId, block.chainid, keccak256("artifact"), 1, ids, modules);

        vm.prank(authority);
        registry.attestDeployment(releaseId, block.chainid, keccak256("artifact"), 1, ids, modules);

        vm.prank(authority);
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentAttestationRegistry.AttestationAlreadyExists.selector, releaseId)
        );
        registry.attestDeployment(releaseId, block.chainid, keccak256("other-artifact"), 2, ids, modules);
    }

    function testRejectsInvalidManifestInputs() public {
        bytes32[] memory ids = new bytes32[](1);
        address[] memory modules = new address[](1);

        vm.startPrank(authority);
        vm.expectRevert(DeploymentAttestationRegistry.InvalidReleaseId.selector);
        registry.attestDeployment(bytes32(0), block.chainid, keccak256("artifact"), 1, ids, modules);

        vm.expectRevert(DeploymentAttestationRegistry.InvalidChainId.selector);
        registry.attestDeployment(keccak256("release"), block.chainid + 1, keccak256("artifact"), 1, ids, modules);

        vm.expectRevert(DeploymentAttestationRegistry.ZeroModuleId.selector);
        registry.attestDeployment(keccak256("release"), block.chainid, keccak256("artifact"), 1, ids, modules);
        vm.stopPrank();
    }
}
