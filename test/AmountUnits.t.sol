// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/libraries/AmountUnits.sol";
import "../contracts/StakeVault.sol";
import "../contracts/mocks/MockDecimalsERC20.sol";

contract AmountUnitsHarness {
    function convert(uint256 a, uint8 f, uint8 t) external pure returns (uint256) {
        return AmountUnits.convert(a, f, t);
    }

    function toCanonical(uint256 a, uint8 d) external pure returns (uint256) {
        return AmountUnits.toCanonical(a, d);
    }

    function fromCanonical(uint256 a, uint8 d) external pure returns (uint256) {
        return AmountUnits.fromCanonical(a, d);
    }

    function tokenDecimals(address token) external view returns (uint8) {
        return AmountUnits.tokenDecimals(token);
    }
}

contract BadDecimalsToken {
    function decimals() external pure returns (uint256) {
        return 77;
    }
}

contract LargeDecimalsReturnToken {
    fallback() external {
        assembly {
            mstore(0, 18)
            return(0, 0x10000)
        }
    }
}

/**
 * @title AmountUnitsTest
 * @notice Covers explicit raw <-> canonical unit conversion for non-18-decimal assets.
 */
contract AmountUnitsTest is Test {
    AmountUnitsHarness internal h;

    function setUp() public {
        h = new AmountUnitsHarness();
    }

    function test_SixDecimalRoundTrip() public view {
        assertEq(h.toCanonical(1_500_000, 6), 1.5e18);
        assertEq(h.fromCanonical(1.5e18, 6), 1_500_000);
    }

    function test_EighteenDecimalIsIdentity() public view {
        assertEq(h.toCanonical(123, 18), 123);
        assertEq(h.fromCanonical(123, 18), 123);
    }

    function test_ZeroDecimals() public view {
        assertEq(h.toCanonical(7, 0), 7e18);
        assertEq(h.fromCanonical(7e18, 0), 7);
    }

    function test_HighDecimalsDownscale() public view {
        assertEq(h.toCanonical(2e24, 24), 2e18);
    }

    /// @dev Regression: a naive `amount / 1e12` silently truncates dust; this must fail closed.
    function test_RevertOnPrecisionLoss() public {
        vm.expectRevert(abi.encodeWithSelector(AmountUnits.PrecisionLoss.selector, 1e18 + 1, 18, 6));
        h.fromCanonical(1e18 + 1, 6);
    }

    function test_RevertOnUnsupportedDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(AmountUnits.UnsupportedDecimals.selector, 37));
        h.toCanonical(1, 37);
    }

    function test_RevertOnOverflow() public {
        vm.expectRevert();
        h.toCanonical(type(uint256).max, 6);
    }

    function test_TokenDecimals() public {
        assertEq(h.tokenDecimals(address(new MockDecimalsERC20("USD", "USD", 6))), 6);
        assertEq(h.tokenDecimals(address(new MockDecimalsERC20("WBTC", "WBTC", 8))), 8);
    }

    function test_TokenDecimalsFailsClosed() public {
        vm.expectRevert(abi.encodeWithSelector(AmountUnits.DecimalsUnavailable.selector, address(0xBEEF)));
        h.tokenDecimals(address(0xBEEF));

        address bad = address(new BadDecimalsToken());
        vm.expectRevert(abi.encodeWithSelector(AmountUnits.UnsupportedDecimals.selector, 77));
        h.tokenDecimals(bad);

        address noDecimals = address(new AmountUnitsHarness());
        vm.expectRevert(abi.encodeWithSelector(AmountUnits.DecimalsUnavailable.selector, noDecimals));
        h.tokenDecimals(noDecimals);
    }

    function test_TokenDecimalsRejectsOversizedReturndataWithoutCopyingIt() public {
        address token = address(new LargeDecimalsReturnToken());
        uint256 gasBefore = gasleft();

        vm.expectRevert(abi.encodeWithSelector(AmountUnits.DecimalsUnavailable.selector, token));
        h.tokenDecimals(token);

        assertLt(gasBefore - gasleft(), 250_000);
    }

    /// @notice StakeVault ledgers raw units; canonical conversion must reconcile for a 6-decimal bond.
    function test_StakeVaultSixDecimalBondReconciles() public {
        MockDecimalsERC20 usdc = new MockDecimalsERC20("USD Coin", "USDC", 6);
        StakeVault vault = new StakeVault(address(this), address(usdc));
        vault.grantRole(vault.OPERATOR_ROLE(), address(this));
        address depositor = address(0xCAFE);
        uint256 raw = h.fromCanonical(250e18, usdc.decimals());
        usdc.mint(depositor, raw);
        vm.prank(depositor);
        usdc.approve(address(vault), raw);

        vault.lockBond(1, address(usdc), depositor, raw);
        assertEq(vault.totalLocked(), 250_000_000);
        assertEq(h.toCanonical(vault.totalLocked(), usdc.decimals()), 250e18);
    }

    function testFuzz_RoundTrip(uint128 raw, uint8 decimals) public view {
        decimals = uint8(bound(decimals, 0, 18));
        assertEq(h.fromCanonical(h.toCanonical(raw, decimals), decimals), raw);
    }

    function testFuzz_DownscaleExactOrReverts(uint256 canonical, uint8 decimals) public {
        decimals = uint8(bound(decimals, 0, 17));
        uint256 factor = 10 ** (18 - decimals);
        if (canonical % factor != 0) {
            vm.expectRevert(abi.encodeWithSelector(AmountUnits.PrecisionLoss.selector, canonical, 18, decimals));
            h.fromCanonical(canonical, decimals);
        } else {
            assertEq(h.fromCanonical(canonical, decimals) * factor, canonical);
        }
    }
}
