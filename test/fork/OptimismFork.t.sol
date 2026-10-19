// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../contracts/StakeVault.sol";
import "../../contracts/libraries/AmountUnits.sol";

/**
 * @title OptimismForkTest
 * @notice Exercises StakeVault deployment and bond lifecycle against a pinned Optimism mainnet fork.
 * @dev Requires `OPTIMISM_MAINNET_RPC_URL` (archive node). Skipped when unset so offline CI stays green.
 *      `OPTIMISM_FORK_BLOCK` may override the pinned block (e.g. for non-archive RPCs).
 *      Run: `forge test --match-contract OptimismForkTest -vv`.
 */
contract OptimismForkTest is Test {
    uint256 internal constant FORK_BLOCK = 120_000_000;
    uint256 internal constant OPTIMISM_CHAIN_ID = 10;

    address internal constant L1_BLOCK = 0x4200000000000000000000000000000000000015;
    address internal constant GAS_PRICE_ORACLE = 0x420000000000000000000000000000000000000F;
    address internal constant OP_TOKEN = 0x4200000000000000000000000000000000000042;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    uint256 internal constant LOCK_GAS_CEILING = 250_000;

    uint256 internal forkBlock;
    StakeVault internal vault;
    address internal operator = makeAddr("operator");
    address internal depositor = makeAddr("depositor");

    function setUp() public {
        string memory rpc = vm.envOr("OPTIMISM_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        forkBlock = vm.envOr("OPTIMISM_FORK_BLOCK", FORK_BLOCK);
        vm.createSelectFork(rpc, forkBlock);

        vault = new StakeVault(address(this), USDC);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
    }

    function test_ChainAndPredeploys() public view {
        assertEq(block.chainid, OPTIMISM_CHAIN_ID);
        assertEq(block.number, forkBlock);
        assertGt(L1_BLOCK.code.length, 0, "L1Block predeploy missing");
        assertGt(GAS_PRICE_ORACLE.code.length, 0, "GasPriceOracle predeploy missing");
    }

    function test_RealTokenDecimals() public view {
        assertEq(AmountUnits.tokenDecimals(USDC), 6);
        assertEq(AmountUnits.tokenDecimals(OP_TOKEN), 18);
    }

    function test_UsdcBondLifecycle() public {
        uint256 raw = AmountUnits.fromCanonical(100e18, AmountUnits.tokenDecimals(USDC));
        deal(USDC, depositor, raw);
        vm.prank(depositor);
        IERC20(USDC).approve(address(vault), raw);

        vm.prank(operator);
        uint256 gasBefore = gasleft();
        vault.lockBond(1, USDC, depositor, raw);
        assertLt(gasBefore - gasleft(), LOCK_GAS_CEILING, "lockBond gas regression");

        assertEq(IERC20(USDC).balanceOf(address(vault)), raw);
        assertEq(vault.totalLocked(), raw);

        vm.prank(operator);
        vault.releaseBond(1, depositor);
        assertEq(IERC20(USDC).balanceOf(depositor), raw);
        assertEq(vault.totalLocked(), 0);
    }

    function test_UnauthorizedLockReverts() public {
        vm.expectRevert();
        vault.lockBond(2, USDC, depositor, 1);
    }

    function test_InsufficientRealBalanceFailsClosed() public {
        vm.prank(depositor);
        IERC20(USDC).approve(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert();
        vault.lockBond(3, USDC, depositor, 1e6);
        assertEq(vault.totalLocked(), 0);
    }
}
