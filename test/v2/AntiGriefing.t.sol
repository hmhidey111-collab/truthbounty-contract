// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/v2/Claims.sol";
import "../../contracts/v2/StakeVault.sol";
import "../../contracts/v2/libraries/AntiGriefing.sol";
import "../../contracts/v2/libraries/V2Errors.sol";
import "../../contracts/v2/interfaces/IV2Types.sol";
import "../../contracts/performance/ProtocolExecutionBounds.sol";
import "../../contracts/mocks/MockModuleRegistry.sol";
import "../../contracts/MockERC20.sol";

contract AntiGriefingTest is Test {
    Claims internal claims;
    StakeVault internal vault;
    MockModuleRegistry internal registry;
    MockERC20 internal token;

    address internal admin = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal feeSink = address(0xFEE);

    uint256 internal constant MIN_BOUNTY = 1 ether;
    uint256 internal constant FEE = 0.01 ether;

    function setUp() public {
        registry = new MockModuleRegistry();
        token = new MockERC20("Stake", "STK");
        vault = new StakeVault(address(registry), address(token), admin);
        claims = new Claims(admin, address(token), feeSink, MIN_BOUNTY, FEE);

        token.mint(alice, 1_000 ether);
        token.mint(bob, 1_000 ether);
        vm.prank(alice);
        token.approve(address(claims), type(uint256).max);
        vm.prank(bob);
        token.approve(address(claims), type(uint256).max);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
    }

    function test_library_requireMinAmount_revertsOnDust() public {
        vm.expectRevert(abi.encodeWithSelector(AntiGriefing.DustAmount.selector, 1, MIN_BOUNTY));
        this.wrapperRequireMin(1, MIN_BOUNTY);
    }

    function wrapperRequireMin(uint256 amount, uint256 minimum) external pure {
        AntiGriefing.requireMinAmount(amount, minimum);
    }

    function test_stakeVault_rejectsDustStake() public {
        assertEq(vault.minStakeAmount(), ProtocolExecutionBounds.DEFAULT_MIN_STAKE_AMOUNT);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.DustStake.selector, 1, ProtocolExecutionBounds.DEFAULT_MIN_STAKE_AMOUNT
            )
        );
        vault.depositStake(1, 1);
    }

    function test_stakeVault_acceptsFloorStake() public {
        uint256 floor = vault.minStakeAmount();
        vm.prank(alice);
        vault.depositStake(1, floor);
        assertEq(vault.staked(1, alice), floor);
    }

    function test_stakeVault_setMinStakeAmount_rejectsZero() public {
        vm.expectRevert(V2Errors.ZeroAmount.selector);
        vault.setMinStakeAmount(0);
    }

    function test_claims_rejectsDustBounty() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AntiGriefing.DustAmount.selector, MIN_BOUNTY - 1, MIN_BOUNTY));
        claims.createClaim(keccak256("subject"), MIN_BOUNTY - 1, "");
    }

    function test_claims_createPaysFeeAndEscrowsBounty() public {
        uint256 reward = 2 ether;
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 feeBefore = token.balanceOf(feeSink);

        vm.prank(alice);
        uint256 claimId = claims.createClaim(keccak256("subject-a"), reward, hex"1234");

        assertEq(claimId, 1);
        assertEq(token.balanceOf(alice), aliceBefore - reward - FEE);
        assertEq(token.balanceOf(feeSink), feeBefore + FEE);
        assertEq(token.balanceOf(address(claims)), reward);
        assertEq(claims.openClaimCount(alice), 1);

        IV2Types.Claim memory c = claims.getClaim(claimId);
        assertEq(c.claimant, alice);
        assertEq(c.reward, reward);
        assertEq(uint256(c.status), uint256(IV2Types.ClaimStatus.OPEN));
    }

    function test_claims_rateLimitRejectsSpam() public {
        uint256 limit = ProtocolExecutionBounds.MAX_CLAIMS_PER_ACCOUNT_WINDOW;
        for (uint256 i = 0; i < limit; i++) {
            vm.prank(alice);
            claims.createClaim(keccak256(abi.encode("s", i)), MIN_BOUNTY, "");
        }

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AntiGriefing.ClaimRateExceeded.selector, alice, limit + 1, limit)
        );
        claims.createClaim(keccak256("overflow"), MIN_BOUNTY, "");
    }

    function test_claims_rateLimitResetsAfterWindow() public {
        uint256 limit = ProtocolExecutionBounds.MAX_CLAIMS_PER_ACCOUNT_WINDOW;
        for (uint256 i = 0; i < limit; i++) {
            vm.prank(alice);
            claims.createClaim(keccak256(abi.encode("w", i)), MIN_BOUNTY, "");
        }

        vm.warp(block.timestamp + ProtocolExecutionBounds.CLAIM_SPAM_WINDOW_SECONDS + 1);
        vm.prank(alice);
        uint256 id = claims.createClaim(keccak256("after-window"), MIN_BOUNTY, "");
        assertTrue(id > limit);
    }

    function test_claims_openClaimCap() public {
        // Shrink caps so the open-claim inventory binds before the rate window.
        claims.setAntiGriefParams(MIN_BOUNTY, FEE, 100, 1 hours, 3, feeSink);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            claims.createClaim(keccak256(abi.encode("open", i)), MIN_BOUNTY, "");
        }

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AntiGriefing.TooManyOpenClaims.selector, alice, 3, 3));
        claims.createClaim(keccak256("blocked"), MIN_BOUNTY, "");

        vm.prank(alice);
        claims.cancelClaim(1);
        assertEq(claims.openClaimCount(alice), 2);

        vm.prank(alice);
        claims.createClaim(keccak256("after-cancel"), MIN_BOUNTY, "");
        assertEq(claims.openClaimCount(alice), 3);
    }

    function test_claims_cancelRefundsBountyKeepsFee() public {
        vm.prank(alice);
        uint256 claimId = claims.createClaim(keccak256("cancel-me"), MIN_BOUNTY, "");
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 feeBal = token.balanceOf(feeSink);

        vm.prank(alice);
        claims.cancelClaim(claimId);

        assertEq(token.balanceOf(alice), aliceBefore + MIN_BOUNTY);
        assertEq(token.balanceOf(feeSink), feeBal);
        assertEq(claims.openClaimCount(alice), 0);
    }

    function test_bounds_catalogConstants() public pure {
        assertEq(ProtocolExecutionBounds.MAX_CLAIMS_PER_ACCOUNT_WINDOW, 10);
        assertEq(ProtocolExecutionBounds.CLAIM_SPAM_WINDOW_SECONDS, 1 hours);
        assertEq(ProtocolExecutionBounds.MAX_OPEN_CLAIMS_PER_CREATOR, 25);
        assertEq(ProtocolExecutionBounds.DEFAULT_MIN_STAKE_AMOUNT, 1 ether);
        assertEq(ProtocolExecutionBounds.DEFAULT_MIN_BOUNTY_AMOUNT, 1 ether);
    }
}
