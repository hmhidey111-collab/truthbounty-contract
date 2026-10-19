// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/governance/ParameterVersionRegistry.sol";
import "../../contracts/interfaces/IParameterVersionRegistry.sol";

contract EconomicParameterEnvelopesTest is Test {
    ParameterVersionRegistry public registry;
    address public admin = address(1);
    address public governanceController = address(2);
    address public proposer = address(3);

    function setUp() public {
        vm.startPrank(admin);
        registry = new ParameterVersionRegistry(admin, governanceController);
        registry.grantRole(registry.VERSION_PROPOSER_ROLE(), proposer);
        vm.stopPrank();
    }

    function _getValidParameters() internal view returns (IParameterVersionRegistry.EconomicParameters memory) {
        return registry.getCurrentParameters();
    }

    function testPositive_ValidParametersAccepted() public {
        IParameterVersionRegistry.EconomicParameters memory params = _getValidParameters();
        
        vm.prank(proposer);
        uint256 versionId = registry.proposeNewVersion(params);
        assertTrue(versionId > 0, "Valid parameters should be accepted");
    }

    function testNegative_StakesOutsideBoundsRejected() public {
        IParameterVersionRegistry.EconomicParameters memory params = _getValidParameters();
        
        // Too low stake
        params.minStakeAmount = registry.MIN_SAFE_STAKE() - 1;
        vm.expectRevert(abi.encodeWithSelector(IParameterVersionRegistry.InvalidStakeBounds.selector));
        vm.prank(proposer);
        registry.proposeNewVersion(params);

        // Max stake below min
        params = _getValidParameters();
        params.maxStakeAmount = params.minStakeAmount - 1;
        vm.expectRevert(abi.encodeWithSelector(IParameterVersionRegistry.InvalidStakeBounds.selector));
        vm.prank(proposer);
        registry.proposeNewVersion(params);

        // Max stake too high
        params = _getValidParameters();
        params.maxStakeAmount = registry.MAX_SAFE_STAKE() + 1;
        vm.expectRevert(abi.encodeWithSelector(IParameterVersionRegistry.InvalidStakeBounds.selector));
        vm.prank(proposer);
        registry.proposeNewVersion(params);
    }

    function testNegative_DurationsOutsideBoundsRejected() public {
        IParameterVersionRegistry.EconomicParameters memory params = _getValidParameters();
        
        // Too short duration
        params.challengeDuration = registry.MIN_SAFE_DURATION() - 1;
        vm.expectRevert(abi.encodeWithSelector(IParameterVersionRegistry.NonZeroDurationRequired.selector));
        vm.prank(proposer);
        registry.proposeNewVersion(params);

        // Too long duration
        params = _getValidParameters();
        params.challengeDuration = registry.MAX_SAFE_DURATION() + 1;
        vm.expectRevert(abi.encodeWithSelector(IParameterVersionRegistry.NonZeroDurationRequired.selector));
        vm.prank(proposer);
        registry.proposeNewVersion(params);
    }

    function testBoundary_ExactBoundsAccepted() public {
        IParameterVersionRegistry.EconomicParameters memory params = _getValidParameters();
        
        params.minStakeAmount = registry.MIN_SAFE_STAKE();
        params.maxStakeAmount = registry.MAX_SAFE_STAKE();
        params.challengeDuration = registry.MIN_SAFE_DURATION();
        params.appealDuration = registry.MAX_SAFE_DURATION();
        params.challengeBond = registry.MIN_SAFE_BOND();
        params.minBountyAmount = registry.MAX_SAFE_BOND();
        params.maxBountyAmount = registry.MAX_SAFE_BOND();
        
        vm.prank(proposer);
        uint256 versionId = registry.proposeNewVersion(params);
        assertTrue(versionId > 0, "Exact boundary parameters should be accepted");
    }

    function testBoundary_BoundsPlusMinusOneRejected() public {
        IParameterVersionRegistry.EconomicParameters memory params = _getValidParameters();
        
        params.minStakeAmount = registry.MIN_SAFE_STAKE() - 1;
        vm.expectRevert(abi.encodeWithSelector(IParameterVersionRegistry.InvalidStakeBounds.selector));
        vm.prank(proposer);
        registry.proposeNewVersion(params);
        
        params = _getValidParameters();
        params.maxStakeAmount = registry.MAX_SAFE_STAKE() + 1;
        vm.expectRevert(abi.encodeWithSelector(IParameterVersionRegistry.InvalidStakeBounds.selector));
        vm.prank(proposer);
        registry.proposeNewVersion(params);
    }

    function testAuthorization_OnlyProposerCanUpdate() public {
        IParameterVersionRegistry.EconomicParameters memory params = _getValidParameters();
        
        address unauthorizedUser = address(0xDEAD);
        vm.prank(unauthorizedUser);
        vm.expectRevert(); // OpenZeppelin AccessControl revert
        registry.proposeNewVersion(params);
    }

    function testFuzz_InvariantChecks(
        uint256 minStakeAmount,
        uint256 maxStakeAmount,
        uint256 challengeDuration,
        uint256 challengeBond
    ) public {
        IParameterVersionRegistry.EconomicParameters memory params = _getValidParameters();
        
        // Force inputs to pass basic validation for allocations to test the fuzz cases
        params.minStakeAmount = minStakeAmount;
        params.maxStakeAmount = maxStakeAmount;
        params.challengeDuration = challengeDuration;
        params.challengeBond = challengeBond;

        bool isValid = true;
        if (minStakeAmount < registry.MIN_SAFE_STAKE() || minStakeAmount > registry.MAX_SAFE_STAKE()) isValid = false;
        if (maxStakeAmount < registry.MIN_SAFE_STAKE() || maxStakeAmount > registry.MAX_SAFE_STAKE() || minStakeAmount > maxStakeAmount) isValid = false;
        if (challengeDuration < registry.MIN_SAFE_DURATION() || challengeDuration > registry.MAX_SAFE_DURATION()) isValid = false;
        if (challengeBond < registry.MIN_SAFE_BOND() || challengeBond > registry.MAX_SAFE_BOND()) isValid = false;

        if (isValid) {
            vm.prank(proposer);
            uint256 versionId = registry.proposeNewVersion(params);
            assertTrue(versionId > 0, "Valid fuzz parameters should be accepted");
        } else {
            vm.prank(proposer);
            vm.expectRevert();
            registry.proposeNewVersion(params);
        }
    }
}
