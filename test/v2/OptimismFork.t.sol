// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/ClaimRegistry.sol";
import "../../contracts/MockERC20.sol";
import "../../contracts/VerificationSubmission.sol";
import "../../contracts/governance/ParameterVersionRegistry.sol";
import "../../contracts/interfaces/IClaimRegistry.sol";
import "../../contracts/interfaces/IVerificationSubmission.sol";
import "../../contracts/v2/StakeVault.sol";
import "../../contracts/v2/libraries/V2AmountUnits.sol";
import "../../contracts/mocks/MockModuleRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IGasPriceOracle {
    function getL1Fee(bytes memory data) external view returns (uint256);
    function isEcotone() external view returns (bool);
}

interface IL1Block {
    function number() external view returns (uint64);
    function basefee() external view returns (uint256);
}

/// @notice Canonical V2 custody lifecycle against a pinned Optimism mainnet fork (V2-SC-079).
/// @dev Runs only when `OPTIMISM_RPC_URL` is set; otherwise every test is skipped so offline CI stays green.
///      Pin with `OPTIMISM_FORK_BLOCK` (defaults to `DEFAULT_FORK_BLOCK`).
contract OptimismForkTest is Test {
    uint256 internal constant OPTIMISM_CHAIN_ID = 10;
    uint256 internal constant DEFAULT_FORK_BLOCK = 125_000_000;

    // Optimism predeploys and canonical tokens.
    address internal constant L1_BLOCK = 0x4200000000000000000000000000000000000015;
    address internal constant GAS_PRICE_ORACLE = 0x420000000000000000000000000000000000000F;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    bool internal forked;
    StakeVault internal vault;
    MockModuleRegistry internal registry;
    address internal alice = address(0xA11CE);

    function setUp() public {
        string memory rpc = vm.envOr("OPTIMISM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.envOr("OPTIMISM_FORK_BLOCK", DEFAULT_FORK_BLOCK));
        forked = true;

        registry = new MockModuleRegistry();
        vault = new StakeVault(address(registry), WETH, address(this));
        vault.setSupportedAsset(USDC, true);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_ChainIdAndPredeploys() public onlyFork {
        assertEq(block.chainid, OPTIMISM_CHAIN_ID);
        assertGt(L1_BLOCK.code.length, 0);
        assertGt(GAS_PRICE_ORACLE.code.length, 0);
        assertGt(WETH.code.length, 0);
    }

    /// @notice Optimism gas rules: L2 basefee, L1 block oracle, and a non-zero L1 data fee for V2 calldata.
    function test_GasRules() public onlyFork {
        assertGt(block.basefee, 0);
        assertGt(IL1Block(L1_BLOCK).number(), 0);
        assertGt(IL1Block(L1_BLOCK).basefee(), 0);
        assertTrue(IGasPriceOracle(GAS_PRICE_ORACLE).isEcotone());
        bytes memory depositCall = abi.encodeCall(StakeVault.deposit, (USDC, 1_000e6));
        assertGt(IGasPriceOracle(GAS_PRICE_ORACLE).getL1Fee(depositCall), 0);
    }

    function test_RealTokenDecimals() public onlyFork {
        assertEq(this.readDecimals(USDC), 6);
        assertEq(this.readDecimals(WETH), 18);
    }

    function readDecimals(address asset) external view returns (uint8) {
        return V2AmountUnits.decimalsOf(asset);
    }

    function test_UsdcDepositLockSettleWithdraw() public onlyFork {
        address settlement = address(0x5E77);
        registry.permitModule(vault.MODULE_SETTLEMENT(), settlement);

        deal(USDC, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), 1_000e6);
        vault.deposit(USDC, 1_000e6);
        vm.stopPrank();

        vm.prank(settlement);
        vault.lock(USDC, alice, 1, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 400e6);
        vm.prank(settlement);
        vault.finalUnlock(USDC, alice, 1, 0, 400e6);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        vault.withdraw(USDC, 1_000e6);
        assertLt(gasBefore - gasleft(), 200_000);

        assertEq(IERC20(USDC).balanceOf(alice), 1_000e6);
        (uint256 custody, uint256 obligations) = vault.reconcile(USDC);
        assertEq(custody, 0);
        assertEq(obligations, 0);
    }

    function test_WethStakeLifecycle() public onlyFork {
        deal(WETH, alice, 5 ether);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), 5 ether);
        vault.depositStake(7, 5 ether);
        vm.stopPrank();
        assertEq(vault.staked(7, alice), 5 ether);
        assertEq(vault.totalCustody(WETH), 5 ether);
    }

    function test_VerificationDeadlineStaysClosedAfterSequencerTimestampJump() public onlyFork {
        MockERC20 stakeToken = new MockERC20("Verification Stake", "VST");
        ParameterVersionRegistry parameters = new ParameterVersionRegistry(address(this), address(this));
        ClaimRegistry claims = new ClaimRegistry(address(this), address(parameters));
        VerificationSubmission submissions = new VerificationSubmission(address(claims), address(stakeToken), 1);

        claims.grantRole(claims.REGISTRY_UPDATER_ROLE(), address(this));
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint256 claimId = claims.createClaim(
            "Sequencer outage deadline regression",
            "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG",
            deadline
        );
        claims.updateClaimStatus(claimId, IClaimRegistry.ClaimStatus.UnderVerification);

        address onTimeVerifier = makeAddr("onTimeVerifier");
        address delayedVerifier = makeAddr("delayedVerifier");
        stakeToken.mint(onTimeVerifier, 2);
        stakeToken.mint(delayedVerifier, 2);
        vm.prank(onTimeVerifier);
        stakeToken.approve(address(submissions), 1);
        vm.prank(delayedVerifier);
        stakeToken.approve(address(submissions), 1);

        vm.warp(deadline);
        vm.prank(onTimeVerifier);
        submissions.submitVerification(claimId, IVerificationSubmission.VerificationVerdict.TRUE, 1);
        assertEq(submissions.getVerification(1).submittedAt, deadline);

        vm.warp(uint256(deadline) + 7 days);
        vm.expectRevert(IVerificationSubmission.VerificationWindowClosed.selector);
        vm.prank(delayedVerifier);
        submissions.submitVerification(claimId, IVerificationSubmission.VerificationVerdict.FALSE, 1);

        assertEq(submissions.getVerificationCount(), 1);
        assertEq(stakeToken.balanceOf(address(submissions)), 1);
    }
}
