// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {ProtocolExecutionBounds} from "../../contracts/performance/ProtocolExecutionBounds.sol";
import {V2Lifecycle} from "../../contracts/v2/libraries/V2Lifecycle.sol";
import {V2Errors} from "../../contracts/v2/libraries/V2Errors.sol";

contract V2LifecycleBoundsHarness {
    function validate(address[] calldata assets) external pure {
        V2Lifecycle.ParameterSet memory params;
        params.supportedAssets = assets;
        params.minBounty = 1;
        params.maxBounty = 1;
        params.minStake = 1;
        params.maxStake = 1;
        params.claimDuration = 1;
        params.verificationDuration = 1;
        params.disputeDuration = 1;
        params.appealDuration = 1;
        params.appealMultiplierBps = 1;
        params.pauseCooldown = 1;
        params.unpauseCooldown = 1;
        params.bountyAllocationBps = 5_000;
        params.stakeAllocationBps = 3_000;
        params.protocolAllocationBps = 2_000;
        V2Lifecycle.validateParameterSet(params);
    }
}

contract V2LifecycleBoundsTest is Test {
    V2LifecycleBoundsHarness internal harness;

    function setUp() public {
        harness = new V2LifecycleBoundsHarness();
    }

    function test_maxSupportedAssetsAccepted() public {
        address[] memory assets = _assets(ProtocolExecutionBounds.MAX_SUPPORTED_ASSETS);
        harness.validate(assets);
    }

    function test_supportedAssetLimitExceeded() public {
        uint256 count = ProtocolExecutionBounds.MAX_SUPPORTED_ASSETS + 1;
        address[] memory assets = _assets(count);

        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.SupportedAssetLimitExceeded.selector,
                count,
                ProtocolExecutionBounds.MAX_SUPPORTED_ASSETS
            )
        );
        harness.validate(assets);
    }

    function _assets(uint256 count) private pure returns (address[] memory assets) {
        assets = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            assets[i] = address(uint160(i + 1));
        }
    }
}
