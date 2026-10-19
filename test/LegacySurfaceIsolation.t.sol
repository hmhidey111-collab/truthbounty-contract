// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/v2/StakeVault.sol";
import "../contracts/mocks/MockModuleRegistry.sol";
import "../contracts/MockERC20.sol";

contract LegacySurfaceIsolationTest is Test {
    StakeVault internal vault;
    MockERC20 internal token;
    address internal verifier = address(0xBEEF);
    uint256 internal constant STAKE = 100 ether;

    function setUp() public {
        MockModuleRegistry registry = new MockModuleRegistry();
        token = new MockERC20("Stake", "STK");
        vault = new StakeVault(address(registry), address(token), address(this));
        token.mint(verifier, STAKE);
        vm.prank(verifier);
        token.approve(address(vault), STAKE);
    }

    /// @dev Deprecated V1 treasury calls must revert without changing V2 custody or stake.
    function testFuzz_legacyTreasuryCallsCannotMutateVault(address caller, uint96 amount) public {
        vm.prank(verifier);
        vault.depositStake(1, STAKE);

        bytes[] memory legacyCalls = new bytes[](4);
        legacyCalls[0] = abi.encodeWithSignature("settleClaim(address,uint256)", verifier, uint256(amount));
        legacyCalls[1] =
            abi.encodeWithSignature("settleClaimsBatch(address[],uint256[])", new address[](0), new uint256[](0));
        legacyCalls[2] =
            abi.encodeWithSignature("rescueTokens(address,address,uint256)", address(token), caller, uint256(amount));
        legacyCalls[3] = abi.encodeWithSignature("TREASURY_ROLE()");

        uint256 custodyBefore = vault.totalCustody(address(token));
        uint256 stakeBefore = vault.staked(1, verifier);
        for (uint256 i = 0; i < legacyCalls.length; ++i) {
            vm.prank(caller);
            (bool success,) = address(vault).call(legacyCalls[i]);
            assertFalse(success, "legacy selector reached V2 vault");
            assertEq(vault.totalCustody(address(token)), custodyBefore, "legacy call changed custody");
            assertEq(vault.staked(1, verifier), stakeBefore, "legacy call changed stake");
            assertEq(token.balanceOf(address(vault)), custodyBefore, "legacy call moved assets");
        }
    }
}
