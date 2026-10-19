// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Claims} from "../../contracts/v2/Claims.sol";
import {FinalRewardAllocator} from "../../contracts/v2/FinalRewardAllocator.sol";
import {IFinalRewardAllocator} from "../../contracts/v2/interfaces/IFinalRewardAllocator.sol";
import {FeeManager} from "../../contracts/fees/FeeManager.sol";
import {IFeeManager} from "../../contracts/fees/IFeeManager.sol";
import {MockModuleRegistry} from "../../contracts/mocks/MockModuleRegistry.sol";
import {MockERC20} from "../../contracts/MockERC20.sol";

/// @dev Hook interface shared by the hostile-recipient harnesses below.
interface IFeeReceiveHook {
    function onFeeReceived(uint256 amount) external;
}

/// @dev ERC20 that notifies a recipient after every transfer, so a recipient
///      contract can attempt reentrancy exactly where a fee lands.
contract HookERC20 is ERC20 {
    mapping(address => bool) public notify;

    constructor() ERC20("Hook", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setNotify(address who, bool value) external {
        notify[who] = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (notify[to]) {
            IFeeReceiveHook(to).onFeeReceived(amount);
        }
        return ok;
    }
}

/// @dev ERC20 that refuses to pay a blocked address, modelling a malicious or
///      broken fee recipient that makes an entire distribution transfer revert.
contract BlockedRecipientERC20 is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Blocked", "BLK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address who, bool value) external {
        blocked[who] = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blocked[to], "BlockedRecipientERC20: recipient blocked");
        return super.transfer(to, amount);
    }
}

/// @dev Reenters FeeManager.distributeReservedFees when it receives a fee.
contract ReentrantFeeSink is IFeeReceiveHook {
    IFeeManager public immutable manager;
    bool public attacked;
    bool public reentryReverted;
    uint256 public received;

    constructor(address manager_) {
        manager = IFeeManager(manager_);
    }

    function onFeeReceived(uint256 amount) external override {
        received += amount;
        if (attacked) return;
        attacked = true;
        try manager.distributeReservedFees() {} catch {
            reentryReverted = true;
        }
    }
}

/// @dev Reenters Claims.cancelClaim while its own refund is in flight.
contract ReentrantClaimant is IFeeReceiveHook {
    Claims public immutable claims;
    IERC20 public immutable token;
    uint256 public claimId;
    bool public attacked;
    bool public reentryReverted;

    constructor(address claims_, address token_) {
        claims = Claims(claims_);
        token = IERC20(token_);
    }

    function create(bytes32 subject, uint256 reward, uint256 fee) external {
        token.approve(address(claims), reward + fee);
        claimId = claims.createClaim(subject, reward, "");
    }

    function cancel() external {
        claims.cancelClaim(claimId);
    }

    function onFeeReceived(uint256) external override {
        if (attacked) return;
        attacked = true;
        try claims.cancelClaim(claimId) {} catch {
            reentryReverted = true;
        }
    }
}

/// @title V2SC039FeeRoutingAccountingTest
/// @notice PREWAVE-SC-039 — verify fee routing and basis-point accounting.
///
/// @dev Focused candidate for the V2 fee boundary. The canonical inventory it
///      pins lives in docs/v2/fee-routing-bps-accounting-v2-sc-039.md. Every fee
///      source in the approved V2 topology is exercised here:
///
///        1. Claims.claimSubmissionFee            -> feeRecipient
///        2. FinalRewardAllocator PROTOCOL_FEE     -> accounts + remainderRecipient
///        3. FeeManager schedules + routing table  -> allocation targets
///
///      The properties under test are exactly the acceptance criteria:
///      bounded BPS totals and caps, one fee routed once, explicit dust
///      ownership, exact integer event amounts, no fee-on-fee, and
///      conservation of every unit at every hop.
contract V2SC039FeeRoutingAccountingTest is Test {
    // ── Claims surface ────────────────────────────────────────────────────────
    MockERC20 internal bountyToken;
    Claims internal claims;
    address internal claimsAdmin = makeAddr("claimsAdmin");
    address internal feeSink = makeAddr("feeSink");
    address internal claimant = makeAddr("claimant");

    uint256 internal constant MIN_BOUNTY = 1 ether;
    uint256 internal constant CLAIM_FEE = 0.001 ether;

    // ── FeeManager surface ────────────────────────────────────────────────────
    MockERC20 internal feeToken;
    FeeManager internal feeManager;
    address internal treasury = makeAddr("treasury");
    address internal security = makeAddr("security");
    address internal ecosystem = makeAddr("ecosystem");
    address internal contributors = makeAddr("contributors");
    address internal emergency = makeAddr("emergency");
    address internal payer = makeAddr("payer");

    bytes32 internal constant CLAIM_SUBMISSION_FEE = keccak256("CLAIM_SUBMISSION_FEE");
    bytes32 internal constant PROTOCOL_RESERVE_FEE = keccak256("PROTOCOL_RESERVE_FEE");
    bytes32 internal constant ALLOC_TREASURY_RESERVE = keccak256("TREASURY_RESERVE");
    bytes32 internal constant ALLOC_SECURITY_FUND = keccak256("SECURITY_FUND");
    bytes32 internal constant ALLOC_ECOSYSTEM_FUND = keccak256("ECOSYSTEM_FUND");
    bytes32 internal constant ALLOC_CONTRIBUTOR_INCENTIVES = keccak256("CONTRIBUTOR_INCENTIVES");
    bytes32 internal constant ALLOC_EMERGENCY_RESERVE = keccak256("EMERGENCY_RESERVE");

    // ── FinalRewardAllocator surface ──────────────────────────────────────────
    MockModuleRegistry internal registry;
    MockERC20 internal poolToken;
    FinalRewardAllocator internal allocator;
    address internal settlement = makeAddr("settlement");
    address internal protocolVault = makeAddr("protocolVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    event ClaimFeeCharged(uint256 indexed claimId, address indexed payer, address indexed feeRecipient, uint256 amount);

    function setUp() public {
        // Claims
        bountyToken = new MockERC20("Bounty", "BNTY");
        claims = new Claims(claimsAdmin, address(bountyToken), feeSink, MIN_BOUNTY, CLAIM_FEE);
        vm.prank(claimant);
        bountyToken.mint(claimant, 1_000_000 ether);
        vm.prank(claimant);
        bountyToken.approve(address(claims), type(uint256).max);

        // FeeManager
        feeToken = new MockERC20("Fee", "FEE");
        feeManager = new FeeManager(
            address(feeToken),
            address(this),
            address(0),
            treasury,
            security,
            ecosystem,
            contributors,
            emergency
        );
        feeToken.mint(payer, 1_000_000_000 ether);
        vm.prank(payer);
        feeToken.approve(address(feeManager), type(uint256).max);
        feeManager.grantRole(feeManager.COLLECTOR_ROLE(), payer);

        // FinalRewardAllocator
        registry = new MockModuleRegistry();
        poolToken = new MockERC20("Pool", "POOL");
        allocator = new FinalRewardAllocator(address(registry), 10);
        registry.permitModule(allocator.MODULE_SETTLEMENT(), settlement);
    }

    // =========================================================================
    // § 1  Claims submission fee — source inventory, zero/max, single routing
    // =========================================================================

    /// @dev Zero fee: no fee event, no fee transfer, escrow grows by exactly the reward.
    function test_claims_zeroFeeRoutesNothingAndEscrowsExactlyReward() public {
        vm.startPrank(claimsAdmin);
        claims.setAntiGriefParams(MIN_BOUNTY, 0, 100, 1 hours, 10, feeSink);
        vm.stopPrank();

        vm.recordLogs();
        vm.prank(claimant);
        uint256 id = claims.createClaim(keccak256("subject"), 5 ether, "");

        assertEq(bountyToken.balanceOf(address(claims)), 5 ether, "escrow is exactly the reward");
        assertEq(bountyToken.balanceOf(feeSink), 0, "no fee routed");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ClaimFeeCharged.selector, "no fee event at zero fee");
        }
        assertEq(id, 1);
    }

    /// @dev Paid fee: routed exactly once, event carries the exact integer amount,
    ///      and the escrowed bounty is untouched by fee arithmetic (no fee-on-fee).
    function test_claims_paidFeeRoutesOnceWithExactEventAmount() public {
        uint256 reward = 7 ether;
        uint256 oddFee = 0.123456789012345678 ether;

        vm.startPrank(claimsAdmin);
        claims.setAntiGriefParams(MIN_BOUNTY, oddFee, 100, 1 hours, 10, feeSink);
        vm.stopPrank();

        uint256 claimantBefore = bountyToken.balanceOf(claimant);

        vm.expectEmit(true, true, true, true, address(claims));
        emit ClaimFeeCharged(1, claimant, feeSink, oddFee);
        vm.prank(claimant);
        claims.createClaim(keccak256("subject"), reward, "");

        assertEq(claimantBefore - bountyToken.balanceOf(claimant), reward + oddFee, "paid bounty + fee once");
        assertEq(bountyToken.balanceOf(feeSink), oddFee, "fee destination received the exact amount");
        assertEq(bountyToken.balanceOf(address(claims)), reward, "escrow reduced by nothing");
    }

    /// @dev Max fee: a fee larger than the bounty still routes once and leaves the
    ///      escrow exactly equal to the reward.
    function test_claims_maxFeeRoutesOnceAndEscrowUnaffected() public {
        uint256 reward = 1 ether;
        uint256 hugeFee = 500_000 ether;

        vm.startPrank(claimsAdmin);
        claims.setAntiGriefParams(MIN_BOUNTY, hugeFee, 100, 1 hours, 10, feeSink);
        vm.stopPrank();

        vm.prank(claimant);
        claims.createClaim(keccak256("subject"), reward, "");

        assertEq(bountyToken.balanceOf(feeSink), hugeFee);
        assertEq(bountyToken.balanceOf(address(claims)), reward);
    }

    /// @dev If the claimant cannot cover reward + fee, nothing moves at all:
    ///      no partial fee, no partial escrow, no claim record (fail closed).
    function test_claims_underfundedCreationIsAtomic() public {
        address poor = makeAddr("poor");
        bountyToken.mint(poor, 5 ether); // enough for the bounty, not bounty + fee

        vm.prank(poor);
        vm.expectRevert();
        claims.createClaim(keccak256("subject"), 5 ether, "");

        assertEq(bountyToken.balanceOf(address(claims)), 0, "no escrow");
        assertEq(bountyToken.balanceOf(feeSink), 0, "no fee");
        assertEq(bountyToken.balanceOf(poor), 5 ether, "no tokens pulled");
    }

    /// @dev Cancellation refunds the bounty only: the fee was routed once and is
    ///      never refunded (no double routing in reverse either).
    function test_claims_cancelRefundsRewardButNotFee() public {
        uint256 reward = 3 ether;
        vm.prank(claimant);
        uint256 id = claims.createClaim(keccak256("subject"), reward, "");

        uint256 before = bountyToken.balanceOf(claimant);
        vm.prank(claimant);
        claims.cancelClaim(id);

        assertEq(bountyToken.balanceOf(claimant) - before, reward, "refund is exactly the escrow");
        assertEq(bountyToken.balanceOf(feeSink), CLAIM_FEE, "fee stays routed once");
        assertEq(bountyToken.balanceOf(address(claims)), 0, "escrow fully returned");
    }

    /// @dev A changed fee configuration applies to subsequent claims only; each
    ///      historical fee keeps its exact amount and attribution.
    function test_claims_configChangeAppliesToSubsequentClaimsOnly() public {
        vm.prank(claimant);
        claims.createClaim(keccak256("first"), 1 ether, "");

        uint256 newFee = 0.05 ether;
        vm.startPrank(claimsAdmin);
        claims.setAntiGriefParams(MIN_BOUNTY, newFee, 100, 1 hours, 10, feeSink);
        vm.stopPrank();

        vm.prank(claimant);
        claims.createClaim(keccak256("second"), 1 ether, "");

        assertEq(bountyToken.balanceOf(feeSink), CLAIM_FEE + newFee, "each fee routed exactly once");
    }

    /// @dev The fee recipient must always be an explicit, non-zero destination.
    function test_claims_feeRecipientCannotBeZero() public {
        vm.startPrank(claimsAdmin);
        vm.expectRevert();
        claims.setAntiGriefParams(MIN_BOUNTY, CLAIM_FEE, 100, 1 hours, 10, address(0));
        vm.stopPrank();
    }

    /// @dev A malicious refund recipient cannot double-withdraw through reentrancy.
    function test_claims_maliciousRecipientCannotReenterCancel() public {
        HookERC20 hookToken = new HookERC20();
        Claims hookClaims = new Claims(claimsAdmin, address(hookToken), feeSink, MIN_BOUNTY, 0);
        ReentrantClaimant attacker = new ReentrantClaimant(address(hookClaims), address(hookToken));

        hookToken.mint(address(attacker), 10 ether);
        hookToken.setNotify(address(attacker), true);

        attacker.create(keccak256("subject"), 4 ether, 0);
        uint256 before = hookToken.balanceOf(address(attacker));
        attacker.cancel();

        assertTrue(attacker.attacked(), "attack hook fired");
        assertTrue(attacker.reentryReverted(), "reentrant cancel blocked");
        assertEq(hookToken.balanceOf(address(attacker)) - before, 4 ether, "exactly one refund");
    }

    /// @dev Conservation, fuzzed: the claimant always ends exactly one fee poorer,
    ///      the escrow is always exactly the reward, and the fee lands exactly once.
    function testFuzz_claimsFeeConservation(uint96 rewardRaw, uint32 feeRaw) public {
        uint256 reward = bound(uint256(rewardRaw), MIN_BOUNTY, 100_000 ether);
        uint256 fee = bound(uint256(feeRaw), 0, 500_000 ether);

        vm.startPrank(claimsAdmin);
        claims.setAntiGriefParams(MIN_BOUNTY, fee, 100, 1 hours, 10, feeSink);
        vm.stopPrank();

        uint256 before = bountyToken.balanceOf(claimant);
        vm.prank(claimant);
        uint256 id = claims.createClaim(keccak256("subject"), reward, "");
        assertEq(before - bountyToken.balanceOf(claimant), reward + fee, "charged once");

        vm.prank(claimant);
        claims.cancelClaim(id);
        assertEq(bountyToken.balanceOf(claimant), before - fee, "net cost is exactly one fee");
        assertEq(bountyToken.balanceOf(feeSink), fee, "fee routed once");
        assertEq(bountyToken.balanceOf(address(claims)), 0, "escrow conserved");
    }

    // =========================================================================
    // § 2  FeeManager — bounded BPS totals, caps, dust, duplicate routing
    // =========================================================================

    function _collect(uint256 amount) internal {
        vm.prank(payer);
        feeManager.collectFee(CLAIM_SUBMISSION_FEE, payer, amount);
    }

    function _defaultTargets(uint256 tBps) internal view returns (IFeeManager.AllocationTarget[] memory targets) {
        targets = new IFeeManager.AllocationTarget[](5);
        targets[0] = IFeeManager.AllocationTarget(ALLOC_TREASURY_RESERVE, treasury, tBps, true);
        targets[1] = IFeeManager.AllocationTarget(ALLOC_SECURITY_FUND, security, 2000, true);
        targets[2] = IFeeManager.AllocationTarget(ALLOC_ECOSYSTEM_FUND, ecosystem, 2000, true);
        targets[3] = IFeeManager.AllocationTarget(ALLOC_CONTRIBUTOR_INCENTIVES, contributors, 1000, true);
        targets[4] = IFeeManager.AllocationTarget(ALLOC_EMERGENCY_RESERVE, emergency, 1000, true);
    }

    /// @dev Zero fee: collection of a zero amount is rejected outright.
    function test_feeManager_zeroFeeAmountRejected() public {
        vm.prank(payer);
        vm.expectRevert(FeeManager.ZeroAmount.selector);
        feeManager.collectFee(CLAIM_SUBMISSION_FEE, payer, 0);
    }

    /// @dev A zero base with a percentage schedule yields the fixed component only —
    ///      the BPS slice is exactly zero, never a rounding artifact.
    function test_feeManager_zeroBaseChargesFixedComponentOnly() public {
        vm.prank(address(this));
        feeManager.updateFeeSchedule(PROTOCOL_RESERVE_FEE, 0.5 ether, 50, 0, 0);
        assertEq(feeManager.calculateFee(PROTOCOL_RESERVE_FEE, 0), 0.5 ether);
    }

    /// @dev Max BPS: 10000 bps is exactly 100% of the base; 10001 is rejected.
    function test_feeManager_maxBpsIsExactlyOneHundredPercent() public {
        vm.startPrank(address(this));
        feeManager.updateFeeSchedule(PROTOCOL_RESERVE_FEE, 0, 10_000, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(FeeManager.InvalidBasisPoints.selector, 10_001));
        feeManager.updateFeeSchedule(PROTOCOL_RESERVE_FEE, 0, 10_001, 0, 0);
        vm.stopPrank();

        assertEq(feeManager.calculateFee(PROTOCOL_RESERVE_FEE, 123.456 ether), 123.456 ether, "100% of base");
    }

    /// @dev A schedule whose floor exceeds its cap is rejected at configuration time.
    function test_feeManager_minAboveMaxRejected() public {
        vm.startPrank(address(this));
        vm.expectRevert(abi.encodeWithSelector(FeeManager.FeeBelowMinimum.selector, 1 ether, 0.5 ether));
        feeManager.updateFeeSchedule(PROTOCOL_RESERVE_FEE, 0, 10, 1 ether, 0.5 ether);
        vm.stopPrank();
    }

    function test_feeManager_minCapFloorsAndMaxCapCeils() public {
        vm.startPrank(address(this));
        feeManager.updateFeeSchedule(PROTOCOL_RESERVE_FEE, 0, 10, 0.5 ether, 0); // 0.1% with 0.5 floor
        feeManager.updateFeeSchedule(CLAIM_SUBMISSION_FEE, 0, 10_000, 0, 0.25 ether); // 100% capped at 0.25
        vm.stopPrank();

        assertEq(feeManager.calculateFee(PROTOCOL_RESERVE_FEE, 1 ether), 0.5 ether, "min floors");
        assertEq(feeManager.calculateFee(CLAIM_SUBMISSION_FEE, 100 ether), 0.25 ether, "max ceils");

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(FeeManager.FeeAboveMaximum.selector, 1 ether, 0.25 ether));
        feeManager.collectFee(CLAIM_SUBMISSION_FEE, payer, 1 ether);
    }

    /// @dev Routing table BPS totals must be exactly 10000 — short or long both revert.
    function test_feeManager_allocationTotalsMustBeExactly10000() public {
        IFeeManager.AllocationTarget[] memory short = _defaultTargets(3999); // sums to 9999
        vm.startPrank(address(this));
        vm.expectRevert(abi.encodeWithSelector(FeeManager.InvalidBasisPoints.selector, 9999));
        feeManager.setAllocationTargets(short);

        IFeeManager.AllocationTarget[] memory long = _defaultTargets(4001); // sums to 10001
        vm.expectRevert(abi.encodeWithSelector(FeeManager.InvalidBasisPoints.selector, 10_001));
        feeManager.setAllocationTargets(long);

        feeManager.setAllocationTargets(_defaultTargets(4000)); // exactly 10000
        vm.stopPrank();
    }

    /// @dev A routing-table name may appear only once: duplicate names would split
    ///      one fee across two recipients under one attribution key.
    function test_feeManager_duplicateAllocationNameRejected() public {
        IFeeManager.AllocationTarget[] memory dup = new IFeeManager.AllocationTarget[](4);
        dup[0] = IFeeManager.AllocationTarget(ALLOC_TREASURY_RESERVE, treasury, 4000, true);
        dup[1] = IFeeManager.AllocationTarget(ALLOC_SECURITY_FUND, security, 3000, true);
        dup[2] = IFeeManager.AllocationTarget(ALLOC_SECURITY_FUND, contributors, 2000, true); // duplicate name
        dup[3] = IFeeManager.AllocationTarget(ALLOC_EMERGENCY_RESERVE, emergency, 1000, true);

        vm.startPrank(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(FeeManager.DuplicateAllocationName.selector, ALLOC_SECURITY_FUND)
        );
        feeManager.setAllocationTargets(dup);
        vm.stopPrank();
    }

    /// @dev Too many targets is rejected before any routing table is written.
    function test_feeManager_tooManyTargetsRejected() public {
        IFeeManager.AllocationTarget[] memory targets = new IFeeManager.AllocationTarget[](21);
        for (uint256 i; i < 21; ++i) {
            targets[i] = IFeeManager.AllocationTarget(keccak256(abi.encode("T", i)), makeAddr("r"), 476, true);
        }
        targets[0] = IFeeManager.AllocationTarget(ALLOC_TREASURY_RESERVE, treasury, 484, true);
        vm.startPrank(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(FeeManager.TooManyAllocationTargets.selector, 21, 20)
        );
        feeManager.setAllocationTargets(targets);
        vm.stopPrank();
    }

    /// @dev Multiple recipients + rounding dust: with 10_001 the proportional shares
    ///      truncate and the deterministic remainder (1) lands in TREASURY_RESERVE,
    ///      with every unit accounted for exactly once.
    function test_feeManager_multipleRecipientsRoundingDustOwnedByTreasury() public {
        _collect(10_001);
        feeManager.distributeReservedFees();

        assertEq(feeToken.balanceOf(security), 2000, "security exact share");
        assertEq(feeToken.balanceOf(ecosystem), 2000, "ecosystem exact share");
        assertEq(feeToken.balanceOf(contributors), 1000, "contributors exact share");
        assertEq(feeToken.balanceOf(emergency), 1000, "emergency exact share");
        assertEq(feeToken.balanceOf(treasury), 4001, "treasury pro-rata plus owned dust");

        uint256 sum = feeToken.balanceOf(treasury) + feeToken.balanceOf(security) + feeToken.balanceOf(ecosystem)
            + feeToken.balanceOf(contributors) + feeToken.balanceOf(emergency);
        assertEq(sum, 10_001, "every unit routed exactly once");
        assertEq(feeManager.getRetainedBalance(), 0, "nothing stranded");
    }

    /// @dev Dust ownership is canonical, not positional: re-ordering the same table
    ///      routes the identical amounts.
    function test_feeManager_dustOwnerIsOrderIndependent() public {
        IFeeManager.AllocationTarget[] memory shuffled = new IFeeManager.AllocationTarget[](5);
        shuffled[0] = IFeeManager.AllocationTarget(ALLOC_EMERGENCY_RESERVE, emergency, 1000, true);
        shuffled[1] = IFeeManager.AllocationTarget(ALLOC_TREASURY_RESERVE, treasury, 4000, true);
        shuffled[2] = IFeeManager.AllocationTarget(ALLOC_CONTRIBUTOR_INCENTIVES, contributors, 1000, true);
        shuffled[3] = IFeeManager.AllocationTarget(ALLOC_ECOSYSTEM_FUND, ecosystem, 2000, true);
        shuffled[4] = IFeeManager.AllocationTarget(ALLOC_SECURITY_FUND, security, 2000, true);
        vm.prank(address(this));
        feeManager.setAllocationTargets(shuffled);

        _collect(10_001);
        feeManager.distributeReservedFees();

        assertEq(feeToken.balanceOf(treasury), 4001, "same dust owner despite table order");
        assertEq(feeToken.balanceOf(security), 2000);
        assertEq(feeToken.balanceOf(ecosystem), 2000);
        assertEq(feeToken.balanceOf(contributors), 1000);
        assertEq(feeToken.balanceOf(emergency), 1000);
    }

    /// @dev Distribution events expose exact integer amounts that sum to the batch.
    function test_feeManager_distributionEventsExposeExactAmounts() public {
        _collect(10_001);

        vm.recordLogs();
        feeManager.distributeReservedFees();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256("FeeDistributed(bytes32,uint256)");
        uint256 sum;
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            seen++;
            sum += abi.decode(logs[i].data, (uint256));
        }
        assertEq(seen, 5, "one exact-integer event per recipient");
        assertEq(sum, 10_001, "events sum to the routed batch");
    }

    /// @dev Fee-on-fee is impossible at the routing layer: recipients collectively
    ///      receive the full reserved gross with zero deduction, and nothing can
    ///      distribute the same reservation twice.
    function test_feeManager_noFeeOnFeeAndNoDoubleDistribution() public {
        vm.expectRevert(FeeManager.NoReservedFees.selector);
        feeManager.distributeReservedFees(); // nothing reserved yet — nothing to route

        _collect(1 ether);
        feeManager.distributeReservedFees();

        uint256 sum = feeToken.balanceOf(treasury) + feeToken.balanceOf(security) + feeToken.balanceOf(ecosystem)
            + feeToken.balanceOf(contributors) + feeToken.balanceOf(emergency);
        assertEq(sum, 1 ether, "no deduction on distribution");

        vm.expectRevert(FeeManager.NoReservedFees.selector);
        feeManager.distributeReservedFees(); // same fees cannot be routed twice
    }

    /// @dev Identical collections are distinct immutable records — each routed once,
    ///      each recorded once, none merged or replayed.
    function test_feeManager_identicalFeesAreDistinctRecords() public {
        _collect(5 ether);
        _collect(5 ether);

        assertEq(feeManager.getFeeRecordCount(), 2, "two distinct records");
        assertEq(feeManager.getTotalFeesCollected(), 10 ether);
        assertEq(feeManager.getFeesByType(CLAIM_SUBMISSION_FEE), 10 ether);
        assertEq(feeManager.getFeeRecord(0).amount, 5 ether);
        assertEq(feeManager.getFeeRecord(1).amount, 5 ether);
    }

    /// @dev Changed config: a new schedule governs only subsequent collections, the
    ///      archive keeps the old exact integers, and the schedule event exposes the
    ///      full new configuration.
    function test_feeManager_changedConfigVersionedAndAttributed() public {
        vm.startPrank(address(this));
        vm.expectEmit(true, true, true, true, address(feeManager));
        emit FeeManager.FeeScheduleConfigUpdated(CLAIM_SUBMISSION_FEE, 0.002 ether, 25, 0, 1 ether, 1);
        feeManager.updateFeeSchedule(CLAIM_SUBMISSION_FEE, 0.002 ether, 25, 0, 1 ether);
        feeManager.updateFeeSchedule(CLAIM_SUBMISSION_FEE, 0.003 ether, 0, 0, 0);
        vm.stopPrank();

        IFeeManager.FeeSchedule memory archived = feeManager.getFeeScheduleAtVersion(CLAIM_SUBMISSION_FEE, 1);
        assertEq(archived.fixedAmount, 0.002 ether, "archive keeps exact prior integers");
        assertEq(archived.basisPoints, 25);
        assertEq(archived.maxValue, 1 ether);

        // Modules must route through calculateFee -> collectFee; the new schedule
        // computes the new exact fee for subsequent collections only.
        uint256 newFee = feeManager.calculateFee(CLAIM_SUBMISSION_FEE, 1 ether);
        assertEq(newFee, 0.003 ether, "new schedule computes the new fee");
        _collect(newFee);
        assertEq(feeManager.getFeeRecord(0).amount, 0.003 ether, "new schedule governs new fees only");
    }

    /// @dev Changed config, routing side: fees already reserved but not yet
    ///      distributed are routed by the current governance-approved table, and
    ///      that is explicit — the replacement event pins the change.
    function test_feeManager_changedRoutingTableGovernsNextDistribution() public {
        _collect(100 ether); // reserved under the default table

        IFeeManager.AllocationTarget[] memory two = new IFeeManager.AllocationTarget[](2);
        two[0] = IFeeManager.AllocationTarget(ALLOC_TREASURY_RESERVE, treasury, 7000, true);
        two[1] = IFeeManager.AllocationTarget(ALLOC_SECURITY_FUND, security, 3000, true);
        vm.expectEmit(true, true, true, true, address(feeManager));
        emit IFeeManager.AllocationTargetsUpdated(address(this), 2);
        vm.prank(address(this));
        feeManager.setAllocationTargets(two);

        feeManager.distributeReservedFees();
        assertEq(feeToken.balanceOf(treasury), 70 ether, "new table routes reserved fees");
        assertEq(feeToken.balanceOf(security), 30 ether);
        assertEq(feeToken.balanceOf(ecosystem), 0, "removed target receives nothing");
    }

    /// @dev A malicious recipient that reverts on transfer fails the whole batch
    ///      closed — no partial routing, no partial accounting — and governance can
    ///      then re-route around it with an explicit table change.
    function test_feeManager_maliciousRecipientFailsClosedAndReroutes() public {
        BlockedRecipientERC20 blocked = new BlockedRecipientERC20();
        FeeManager bm = new FeeManager(
            address(blocked),
            address(this),
            address(0),
            treasury,
            security,
            ecosystem,
            contributors,
            emergency
        );
        blocked.mint(payer, 100 ether);
        vm.prank(payer);
        blocked.approve(address(bm), type(uint256).max);

        bm.collectFee(CLAIM_SUBMISSION_FEE, payer, 100 ether);

        blocked.setBlocked(security, true); // security fund can no longer receive
        vm.expectRevert();
        bm.distributeReservedFees();

        assertEq(bm.getReservedFees(), 100 ether, "reservation intact after failed batch");
        assertEq(bm.getTotalFeesDistributed(), 0, "nothing partially routed");
        assertEq(blocked.balanceOf(treasury), 0, "no partial transfers");
        assertEq(blocked.balanceOf(address(bm)), 100 ether, "funds still escrowed");

        // Governance re-routes around the malicious recipient.
        IFeeManager.AllocationTarget[] memory rerouted = new IFeeManager.AllocationTarget[](2);
        rerouted[0] = IFeeManager.AllocationTarget(ALLOC_TREASURY_RESERVE, treasury, 6000, true);
        rerouted[1] = IFeeManager.AllocationTarget(ALLOC_ECOSYSTEM_FUND, ecosystem, 4000, true);
        vm.prank(address(this));
        bm.setAllocationTargets(rerouted);

        bm.distributeReservedFees();
        assertEq(blocked.balanceOf(treasury), 60 ether);
        assertEq(blocked.balanceOf(ecosystem), 40 ether);
        assertEq(blocked.balanceOf(address(bm)), 0, "fully routed after re-route");
    }

    /// @dev A malicious recipient cannot re-enter distribution to double-collect.
    function test_feeManager_maliciousRecipientCannotReenterDistribution() public {
        HookERC20 hook = new HookERC20();
        FeeManager hm = new FeeManager(
            address(hook),
            address(this),
            address(0),
            treasury,
            security,
            ecosystem,
            contributors,
            emergency
        );
        ReentrantFeeSink sink = new ReentrantFeeSink(address(hm));
        hook.mint(payer, 10 ether);
        vm.prank(payer);
        hook.approve(address(hm), type(uint256).max);
        hook.setNotify(address(sink), true);
        // Route 100% of the fee to the hostile sink so the hook fires mid-batch.
        IFeeManager.AllocationTarget[] memory hostile = new IFeeManager.AllocationTarget[](2);
        hostile[0] = IFeeManager.AllocationTarget(ALLOC_TREASURY_RESERVE, address(sink), 6000, true);
        hostile[1] = IFeeManager.AllocationTarget(ALLOC_ECOSYSTEM_FUND, ecosystem, 4000, true);
        vm.prank(address(this));
        hm.setAllocationTargets(hostile);

        hm.collectFee(CLAIM_SUBMISSION_FEE, payer, 10 ether);
        hm.distributeReservedFees();

        assertTrue(sink.attacked(), "hook fired");
        assertTrue(sink.reentryReverted(), "reentrant distribution blocked");
        assertEq(hook.balanceOf(address(sink)), 6 ether, "exactly one routing");
        assertEq(hm.getReservedFees(), 0);
        assertEq(hook.balanceOf(address(hm)), 0, "batch fully routed once");
    }

    /// @dev Reservation token identity: swapping the fee token while fees are
    ///      reserved would pay one asset for amounts collected in another.
    function test_feeManager_feeTokenSwapBlockedWhileReserved() public {
        _collect(1 ether);

        MockERC20 newToken = new MockERC20("New", "NEW");
        vm.startPrank(address(this));
        vm.expectRevert(abi.encodeWithSelector(FeeManager.ReservedFeesOutstanding.selector, 1 ether));
        feeManager.setFeeToken(address(newToken));
        vm.stopPrank();

        feeManager.distributeReservedFees();

        vm.prank(address(this));
        feeManager.setFeeToken(address(newToken)); // clean once reserved is zero
        assertEq(address(feeManager.getFeeToken()), address(newToken));
    }

    /// @dev Conservation, fuzzed: whatever the amounts, every unit ends in exactly
    ///      one destination and nothing is stranded in the manager.
    function testFuzz_feeManagerConservation(uint96 amountA, uint96 amountB) public {
        uint256 a = bound(uint256(amountA), 1, 1_000_000 ether);
        uint256 b = bound(uint256(amountB), 1, 1_000_000 ether);

        _collect(a);
        _collect(b);
        assertEq(feeManager.getReservedFees(), a + b);

        feeManager.distributeReservedFees();

        assertEq(feeManager.getTotalFeesCollected(), a + b);
        assertEq(feeManager.getTotalFeesDistributed(), a + b, "conservation: collected == distributed");
        assertEq(feeManager.getReservedFees(), 0);
        assertEq(feeManager.getRetainedBalance(), 0, "conservation: nothing stranded");

        uint256 total = a + b;
        uint256 proportional = (total * 2000) / 10_000 * 2 + (total * 1000) / 10_000 * 2;
        assertEq(
            feeManager.getTotalByAllocation(ALLOC_TREASURY_RESERVE),
            total - proportional,
            "treasury owns every truncation unit"
        );
    }

    // =========================================================================
    // § 3  FinalRewardAllocator PROTOCOL_FEE — settlement-level fee routing
    // =========================================================================

    function _fund(uint256 amount, bytes32 settlementId) internal {
        poolToken.mint(settlement, amount);
        vm.startPrank(settlement);
        poolToken.approve(address(allocator), amount);
        allocator.fund(address(poolToken), amount, settlementId);
        vm.stopPrank();
    }

    function _alloc(
        IFinalRewardAllocator.RewardCategory category,
        address[] memory accounts,
        uint256[] memory weights,
        uint256 amount,
        address remainder
    ) internal pure returns (IFinalRewardAllocator.Allocation memory) {
        return IFinalRewardAllocator.Allocation({
            category: category,
            accounts: accounts,
            effectiveWeights: weights,
            amount: amount,
            remainderRecipient: remainder
        });
    }

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _weights1(uint256 w) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = w;
    }

    function _three(address a, address b, address c) internal pure returns (address[] memory out) {
        out = new address[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _weights3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _finalize(bytes32 settlementId, IFinalRewardAllocator.Allocation[] memory allocations) internal {
        vm.prank(settlement);
        allocator.finalizeRewards(settlementId, address(poolToken), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, allocations);
    }

    /// @dev The protocol fee is computed once from the funded gross pool and routed
    ///      once; replaying the settlement cannot route it again.
    function test_allocator_protocolFeeRoutedOncePerSettlement() public {
        bytes32 sid = bytes32("sc039-1");
        _fund(1000 ether, sid);

        IFinalRewardAllocator.Allocation[] memory allocs = new IFinalRewardAllocator.Allocation[](2);
        allocs[0] = _alloc(IFinalRewardAllocator.RewardCategory.PROTOCOL_FEE, _one(protocolVault), _weights1(1), 100 ether, treasury);
        address[] memory verifiers = _three(alice, bob, carol);
        allocs[1] = _alloc(IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD, verifiers, _weights3(1, 1, 1), 900 ether, treasury);
        _finalize(sid, allocs);

        assertEq(allocator.claimable(address(poolToken), protocolVault), 100 ether, "protocol fee routed once");
        assertEq(allocator.allocated(address(poolToken)), 1000 ether, "whole pool allocated");

        IFinalRewardAllocator.Allocation[] memory replay = new IFinalRewardAllocator.Allocation[](1);
        replay[0] = _alloc(IFinalRewardAllocator.RewardCategory.PROTOCOL_FEE, _one(protocolVault), _weights1(1), 100 ether, treasury);
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(FinalRewardAllocator.SettlementAlreadyFinalized.selector, sid));
        allocator.finalizeRewards(sid, address(poolToken), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, replay);

        assertEq(allocator.claimable(address(poolToken), protocolVault), 100 ether, "still routed exactly once");
    }

    /// @dev One category, one settlement: a second protocol-fee allocation in the
    ///      same settlement is duplicate routing and reverts with nothing credited.
    function test_allocator_duplicateProtocolFeeCategoryRejected() public {
        bytes32 sid = bytes32("sc039-2");
        _fund(1000 ether, sid);

        IFinalRewardAllocator.Allocation[] memory allocs = new IFinalRewardAllocator.Allocation[](2);
        allocs[0] = _alloc(IFinalRewardAllocator.RewardCategory.PROTOCOL_FEE, _one(protocolVault), _weights1(1), 100 ether, treasury);
        allocs[1] = _alloc(IFinalRewardAllocator.RewardCategory.PROTOCOL_FEE, _one(security), _weights1(1), 50 ether, treasury);

        vm.prank(settlement);
        vm.expectRevert(FinalRewardAllocator.DuplicateCategory.selector);
        allocator.finalizeRewards(sid, address(poolToken), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, allocs);

        assertEq(allocator.claimable(address(poolToken), protocolVault), 0, "failed batch credited nothing");
        assertEq(allocator.claimable(address(poolToken), security), 0);
        assertEq(allocator.allocated(address(poolToken)), 0);
    }

    /// @dev Protocol-fee dust ownership is explicit: truncation lands in the
    ///      category's remainderRecipient and the category sums exactly.
    function test_allocator_protocolFeeDustExplicit() public {
        bytes32 sid = bytes32("sc039-3");
        _fund(10, sid);

        IFinalRewardAllocator.Allocation[] memory allocs = new IFinalRewardAllocator.Allocation[](1);
        address[] memory vaults = _three(protocolVault, security, ecosystem);
        allocs[0] = _alloc(IFinalRewardAllocator.RewardCategory.PROTOCOL_FEE, vaults, _weights3(1, 1, 1), 10, treasury);
        _finalize(sid, allocs);

        assertEq(allocator.claimable(address(poolToken), protocolVault), 3);
        assertEq(allocator.claimable(address(poolToken), security), 3);
        assertEq(allocator.claimable(address(poolToken), ecosystem), 3);
        assertEq(allocator.claimable(address(poolToken), treasury), 1, "dust has an explicit owner");
        assertEq(
            allocator.claimable(address(poolToken), protocolVault) + allocator.claimable(address(poolToken), security)
                + allocator.claimable(address(poolToken), ecosystem) + allocator.claimable(address(poolToken), treasury),
            10,
            "category sums exactly"
        );
    }

    /// @dev Over-allocation against the settlement's own pool fails closed and
    ///      credits nothing — one settlement can never route another's value.
    function test_allocator_overAllocationFailsClosed() public {
        bytes32 sid = bytes32("sc039-4");
        _fund(100 ether, sid);

        IFinalRewardAllocator.Allocation[] memory allocs = new IFinalRewardAllocator.Allocation[](1);
        allocs[0] = _alloc(IFinalRewardAllocator.RewardCategory.PROTOCOL_FEE, _one(protocolVault), _weights1(1), 101 ether, treasury);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(FinalRewardAllocator.PoolExceeded.selector, 101 ether, 100 ether));
        allocator.finalizeRewards(sid, address(poolToken), IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE, allocs);

        assertEq(allocator.claimable(address(poolToken), protocolVault), 0, "no credit on failed routing");
    }

    /// @dev A malicious recipient can never extract more than its credited integer.
    function test_allocator_maliciousRecipientCannotOverClaim() public {
        bytes32 sid = bytes32("sc039-5");
        _fund(1000 ether, sid);

        IFinalRewardAllocator.Allocation[] memory allocs = new IFinalRewardAllocator.Allocation[](1);
        allocs[0] = _alloc(IFinalRewardAllocator.RewardCategory.PROTOCOL_FEE, _one(protocolVault), _weights1(1), 100 ether, treasury);
        _finalize(sid, allocs);

        vm.prank(protocolVault);
        vm.expectRevert(
            abi.encodeWithSelector(FinalRewardAllocator.InsufficientClaimable.selector, 101 ether, 100 ether)
        );
        allocator.claim(address(poolToken), 101 ether);

        vm.prank(protocolVault);
        allocator.claim(address(poolToken), 100 ether);
        vm.prank(protocolVault);
        vm.expectRevert(abi.encodeWithSelector(FinalRewardAllocator.InsufficientClaimable.selector, 1, 0));
        allocator.claim(address(poolToken), 1);
    }

    /// @dev Conservation, fuzzed: protocol fee plus verifier rewards always equal
    ///      the funded pool exactly, with every truncation unit owned.
    function testFuzz_allocatorProtocolFeeConservation(uint96 poolRaw, uint16 feeBpsRaw) public {
        uint256 pool = bound(uint256(poolRaw), 3, 1_000_000 ether);
        uint256 feeBps = bound(uint256(feeBpsRaw), 0, 9999);
        uint256 feeAmount = (pool * feeBps) / 10_000;
        uint256 verifierAmount = pool - feeAmount;

        bytes32 sid = bytes32("sc039-fuzz");
        _fund(pool, sid);

        if (feeAmount == 0) {
            // Zero protocol fee: model the pool as a single verifier category.
            IFinalRewardAllocator.Allocation[] memory single = new IFinalRewardAllocator.Allocation[](1);
            single[0] = _alloc(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD, _one(alice), _weights1(1), pool, treasury
            );
            _finalize(sid, single);
        } else {
            IFinalRewardAllocator.Allocation[] memory allocs = new IFinalRewardAllocator.Allocation[](2);
            allocs[0] = _alloc(
                IFinalRewardAllocator.RewardCategory.PROTOCOL_FEE, _one(protocolVault), _weights1(1), feeAmount, treasury
            );
            allocs[1] = _alloc(
                IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
                _three(alice, bob, carol),
                _weights3(1, 1, 1),
                verifierAmount,
                treasury
            );
            _finalize(sid, allocs);
        }

        assertEq(allocator.allocated(address(poolToken)), pool, "whole pool routed");
        assertEq(
            allocator.funded(address(poolToken)) - allocator.allocated(address(poolToken)),
            0,
            "no unallocated residue"
        );

        // Pull every entitlement; the vault must drain to exactly zero.
        _drainAll(protocolVault);
        _drainAll(alice);
        _drainAll(bob);
        _drainAll(carol);
        _drainAll(treasury);
        assertEq(poolToken.balanceOf(address(allocator)), 0, "every credited unit claimable and claimed");
    }

    function _drainAll(address account) internal {
        uint256 amount = allocator.claimable(address(poolToken), account);
        if (amount == 0) return;
        vm.prank(account);
        allocator.claim(address(poolToken), amount);
    }
}
