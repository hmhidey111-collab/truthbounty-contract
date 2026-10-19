// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {V2Errors} from "../../contracts/v2/libraries/V2Errors.sol";
import {V2Lifecycle} from "../../contracts/v2/libraries/V2Lifecycle.sol";

/// @title V2ErrorsTest
/// @notice Regression coverage for V2-SC-073 revert taxonomy standardization.
contract V2ErrorsTest is Test {
    using V2Lifecycle for V2Lifecycle.VersionedConfigRegistry;

    V2Lifecycle.VersionedConfigRegistry internal registry;

    function test_selectorsAreStableAndDistinct() public pure {
        // Auth vs evidence vs settlement families must not collide.
        assertTrue(V2Errors.Unauthorized.selector != V2Errors.ZeroAddress.selector);
        assertTrue(V2Errors.EvidenceNotFound.selector != V2Errors.ClaimNotFound.selector);
        assertTrue(V2Errors.InvalidRoundTransfer.selector != bytes4(0));
        assertTrue(V2Errors.EvidenceWindowClosed.selector != bytes4(keccak256("EvidenceWindowClosed()")));
        assertTrue(
            V2Errors.EvidenceWindowClosed.selector
                == bytes4(keccak256("EvidenceWindowClosed(uint256,uint64,uint64)"))
        );
        assertTrue(
            V2Errors.DuplicateEvidence.selector == bytes4(keccak256("DuplicateEvidence(bytes32)"))
        );
        assertTrue(
            V2Errors.InvalidRoundTransfer.selector
                == bytes4(keccak256("InvalidRoundTransfer(uint256,uint256)"))
        );
        // String-reason InvalidArgument must not exist in the canonical catalog.
        assertTrue(bytes4(keccak256("InvalidArgument(string)")) != V2Errors.InvalidRoundTransfer.selector);
    }

    function test_validateParameterSet_emptyAssetsRevertsTyped() public {
        V2Lifecycle.ParameterSet memory params;
        params.minBounty = 1;
        params.maxBounty = 2;
        params.minStake = 1;
        params.maxStake = 2;
        params.claimDuration = 1;
        params.verificationDuration = 1;
        params.disputeDuration = 1;
        params.appealDuration = 1;
        params.pauseCooldown = 1;
        params.unpauseCooldown = 1;
        params.appealMultiplierBps = 1;
        params.bountyAllocationBps = 5000;
        params.stakeAllocationBps = 4000;
        params.protocolAllocationBps = 1000;
        params.maxReputationBps = 10_000;

        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidSupportedAssets.selector, uint256(0)));
        V2Lifecycle.validateParameterSet(params);
    }

    function test_validateParameterSet_invertedBountyRevertsTyped() public {
        address[] memory assets = new address[](1);
        assets[0] = address(0xBEEF);

        V2Lifecycle.ParameterSet memory params;
        params.supportedAssets = assets;
        params.minBounty = 10;
        params.maxBounty = 1;
        params.minStake = 1;
        params.maxStake = 2;
        params.claimDuration = 1;
        params.verificationDuration = 1;
        params.disputeDuration = 1;
        params.appealDuration = 1;
        params.pauseCooldown = 1;
        params.unpauseCooldown = 1;
        params.appealMultiplierBps = 1;
        params.bountyAllocationBps = 5000;
        params.stakeAllocationBps = 4000;
        params.protocolAllocationBps = 1000;
        params.maxReputationBps = 10_000;

        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidBountyRange.selector, uint128(10), uint128(1)));
        V2Lifecycle.validateParameterSet(params);
    }

    function test_initializeConfigRegistry_zeroGovernanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InvalidGovernance.selector, address(0)));
        registry.initializeConfigRegistry(address(0));
    }

    function test_setAssetAdapter_notGovernanceReverts() public {
        registry.initializeConfigRegistry(address(this));
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(V2Errors.NotGovernance.selector, address(0xBAD)));
        registry.setAssetAdapter(address(0xA11CE), address(0xADA7));
    }

    function test_noStringReasonInvalidArgumentInCatalog() public pure {
        // Prior unsafe pattern: InvalidArgument(string). Canonical catalog replaces it
        // with typed domain errors (e.g. InvalidRoundTransfer).
        bytes4 legacy = bytes4(keccak256("InvalidArgument(string)"));
        // Ensure we did not accidentally reintroduce a matching library error selector
        // by checking against known catalog selectors used in stake/settlement paths.
        assertTrue(legacy != V2Errors.InvalidRoundTransfer.selector);
        assertTrue(legacy != V2Errors.ZeroAmount.selector);
        assertEq(V2Errors.DustStake.selector, bytes4(keccak256("DustStake(uint256,uint256)")));
        assertTrue(legacy != V2Errors.UnauthorizedModule.selector);
    }
}
