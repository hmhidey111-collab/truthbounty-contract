// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

import {V2SafeCast} from "../../contracts/v2/libraries/V2SafeCast.sol";
import {V2Errors} from "../../contracts/v2/libraries/V2Errors.sol";
import {V2AmountUnits} from "../../contracts/v2/libraries/V2AmountUnits.sol";
import {AmountUnits} from "../../contracts/libraries/AmountUnits.sol";
import {ProtocolExecutionBounds} from "../../contracts/performance/ProtocolExecutionBounds.sol";

import {Claims} from "../../contracts/v2/Claims.sol";
import {StakeVault} from "../../contracts/v2/StakeVault.sol";
import {EvidenceRegistry} from "../../contracts/v2/EvidenceRegistry.sol";
import {ModuleRegistry} from "../../contracts/v2/ModuleRegistry.sol";
import {ModuleRegistryLib} from "../../contracts/v2/libraries/ModuleRegistryLib.sol";
import {IModuleRegistry} from "../../contracts/v2/interfaces/IModuleRegistry.sol";
import {IV2Types} from "../../contracts/v2/interfaces/IV2Types.sol";
import {ClaimRegistry} from "../../contracts/ClaimRegistry.sol";
import {IClaimRegistry} from "../../contracts/interfaces/IClaimRegistry.sol";
import {TruthBountyGovernanceToken} from "../../contracts/governance/v2/TruthBountyGovernanceToken.sol";
import {ReputationWeightedVotingBounds} from "../../contracts/verification/ReputationWeightedVotingBounds.sol";

import {MockModuleRegistry} from "../../contracts/mocks/MockModuleRegistry.sol";
import {MockEvidenceClaimRegistry} from "../../contracts/mocks/MockEvidenceClaimRegistry.sol";
import {MockDecimalsERC20} from "../../contracts/mocks/MockDecimalsERC20.sol";
import {MockV2Module} from "../../contracts/mocks/MockV2Module.sol";
import {MockERC20} from "../../contracts/MockERC20.sol";

/// @dev External wrapper around the internal V2SafeCast / amount-unit libraries plus one fully
///      packed storage slot, so reverts are observable and neighbours can be checked with vm.load.
contract SafeCastHarness {
    bytes32 internal constant FIELD = "Harness.value";
    bytes32 internal constant FIELD_AMOUNT = "Harness.amount";
    bytes32 internal constant FIELD_SNAPSHOT = "Harness.snapshot";

    /// @dev Exactly 32 bytes, so the whole struct lives in slot 0:
    ///      createdAt [0..63] | status [64..71] | amount [72..199] | snapshot [200..247] | tail [248..255]
    struct Packed {
        uint64 createdAt;
        uint8 status;
        uint128 amount;
        uint48 snapshot;
        uint8 tail;
    }

    Packed public packed;

    function toUint8(uint256 v) external pure returns (uint8) { return V2SafeCast.toUint8(v, FIELD); }
    function toUint16(uint256 v) external pure returns (uint16) { return V2SafeCast.toUint16(v, FIELD); }
    function toUint24(uint256 v) external pure returns (uint24) { return V2SafeCast.toUint24(v, FIELD); }
    function toUint32(uint256 v) external pure returns (uint32) { return V2SafeCast.toUint32(v, FIELD); }
    function toUint48(uint256 v) external pure returns (uint48) { return V2SafeCast.toUint48(v, FIELD); }
    function toUint64(uint256 v) external pure returns (uint64) { return V2SafeCast.toUint64(v, FIELD); }
    function toUint96(uint256 v) external pure returns (uint96) { return V2SafeCast.toUint96(v, FIELD); }
    function toUint128(uint256 v) external pure returns (uint128) { return V2SafeCast.toUint128(v, FIELD); }
    function toUint256(int256 v) external pure returns (uint256) { return V2SafeCast.toUint256(v, FIELD); }

    function toUint64Field(uint256 v, bytes32 field) external pure returns (uint64) {
        return V2SafeCast.toUint64(v, field);
    }

    function now64() external view returns (uint64) {
        return V2SafeCast.timestamp64(V2SafeCast.FIELD_CLAIM_CREATED_AT);
    }

    function now48() external view returns (uint48) {
        return V2SafeCast.timestamp48(V2SafeCast.FIELD_GOVERNANCE_CLOCK);
    }

    function writeCreatedAt(uint256 v) external {
        packed.createdAt = V2SafeCast.toUint64(v, V2SafeCast.FIELD_CLAIM_CREATED_AT);
    }

    function writeAmount(uint256 v) external {
        packed.amount = V2SafeCast.toUint128(v, FIELD_AMOUNT);
    }

    function writeSnapshot(uint256 v) external {
        packed.snapshot = V2SafeCast.toUint48(v, FIELD_SNAPSHOT);
    }

    function decimalsOf(address asset) external view returns (uint8) {
        return V2AmountUnits.decimalsOf(asset);
    }

    function tokenDecimals(address asset) external view returns (uint8) {
        return AmountUnits.tokenDecimals(asset);
    }

    function toNormalized(uint256 amount, uint8 decimals) external pure returns (uint256) {
        return V2AmountUnits.toNormalized(amount, decimals);
    }

    function fromNormalized(uint256 amount, uint8 decimals) external pure returns (uint256) {
        return V2AmountUnits.fromNormalized(amount, decimals);
    }
}

/// @dev Adversarial metadata: `decimals()` returns a full uint256, e.g. 256, which a raw
///      `uint8(raw)` would alias to 0.
contract WideDecimalsToken {
    uint256 public decimals;

    constructor(uint256 decimals_) {
        decimals = decimals_;
    }
}

/// @title SafeCastBoundaries (V2-SC-161)
/// @notice Exact min/max, max+1, zero, negative-to-unsigned, mixed-decimal, fuzzed round-trip,
///         packed-slot sentinel, and lifecycle boundary evidence for every guarded narrowing.
contract SafeCastBoundariesTest is Test {
    bytes32 internal constant FIELD = "Harness.value";
    bytes32 internal constant FIELD_AMOUNT = "Harness.amount";
    bytes32 internal constant FIELD_SNAPSHOT = "Harness.snapshot";

    uint256 internal constant U64_MAX = type(uint64).max;
    uint256 internal constant U48_MAX = type(uint48).max;

    SafeCastHarness internal h;

    address internal admin = address(this);
    address internal alice = address(0xA11CE);
    address internal feeSink = address(0xFEE);
    address internal settlement = address(0xA001);

    function setUp() public {
        h = new SafeCastHarness();
    }

    function _overflow(bytes32 field, uint256 value, uint256 max) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(V2Errors.SafeCastOverflow.selector, field, value, max);
    }

    // =========================================================================
    // Error ABI stability
    // =========================================================================

    function test_errorSelectorsAreStable() public pure {
        assertEq(V2Errors.SafeCastOverflow.selector, bytes4(keccak256("SafeCastOverflow(bytes32,uint256,uint256)")));
        assertEq(V2Errors.SafeCastNegative.selector, bytes4(keccak256("SafeCastNegative(bytes32,int256)")));
    }

    function test_fieldIdentifiersAreDistinctAsciiLiterals() public pure {
        assertEq(V2SafeCast.FIELD_CLAIM_CREATED_AT, bytes32("Claims.createdAt"));
        assertEq(V2SafeCast.FIELD_VAULT_EVENT_TIMESTAMP, bytes32("StakeVault.eventTimestamp"));
        assertEq(V2SafeCast.FIELD_REGISTRY_CANONICAL_CREATED_AT, bytes32("ClaimRegistry.canonicalCreatedAt"));
        assertTrue(V2SafeCast.FIELD_MODULE_CHANGED_AT != V2SafeCast.FIELD_MODULE_ACTIVATED_AT);
        assertTrue(V2SafeCast.FIELD_CLAIM_CREATED_AT != V2SafeCast.FIELD_CLAIM_EVENT_TIMESTAMP);
        assertTrue(V2SafeCast.FIELD_GUARANTEES_CHAIN_ID != V2SafeCast.FIELD_ATTESTATION_CHAIN_ID);
    }

    // =========================================================================
    // Exact max / max+1 / zero for every width
    // =========================================================================

    function test_exactMaxZeroAndMaxPlusOne_allWidths() public {
        assertEq(h.toUint8(0), 0);
        assertEq(h.toUint8(type(uint8).max), type(uint8).max);
        vm.expectRevert(_overflow(FIELD, uint256(type(uint8).max) + 1, type(uint8).max));
        h.toUint8(uint256(type(uint8).max) + 1);

        assertEq(h.toUint16(0), 0);
        assertEq(h.toUint16(type(uint16).max), type(uint16).max);
        vm.expectRevert(_overflow(FIELD, uint256(type(uint16).max) + 1, type(uint16).max));
        h.toUint16(uint256(type(uint16).max) + 1);

        assertEq(h.toUint24(0), 0);
        assertEq(h.toUint24(type(uint24).max), type(uint24).max);
        vm.expectRevert(_overflow(FIELD, uint256(type(uint24).max) + 1, type(uint24).max));
        h.toUint24(uint256(type(uint24).max) + 1);

        assertEq(h.toUint32(0), 0);
        assertEq(h.toUint32(type(uint32).max), type(uint32).max);
        vm.expectRevert(_overflow(FIELD, uint256(type(uint32).max) + 1, type(uint32).max));
        h.toUint32(uint256(type(uint32).max) + 1);

        assertEq(h.toUint48(0), 0);
        assertEq(h.toUint48(type(uint48).max), type(uint48).max);
        vm.expectRevert(_overflow(FIELD, uint256(type(uint48).max) + 1, type(uint48).max));
        h.toUint48(uint256(type(uint48).max) + 1);

        assertEq(h.toUint64(0), 0);
        assertEq(h.toUint64(type(uint64).max), type(uint64).max);
        vm.expectRevert(_overflow(FIELD, uint256(type(uint64).max) + 1, type(uint64).max));
        h.toUint64(uint256(type(uint64).max) + 1);

        assertEq(h.toUint96(0), 0);
        assertEq(h.toUint96(type(uint96).max), type(uint96).max);
        vm.expectRevert(_overflow(FIELD, uint256(type(uint96).max) + 1, type(uint96).max));
        h.toUint96(uint256(type(uint96).max) + 1);

        assertEq(h.toUint128(0), 0);
        assertEq(h.toUint128(type(uint128).max), type(uint128).max);
        vm.expectRevert(_overflow(FIELD, uint256(type(uint128).max) + 1, type(uint128).max));
        h.toUint128(uint256(type(uint128).max) + 1);
    }

    function test_uint256MaxNeverAliasesToASmallValue() public {
        // A raw uint64(type(uint256).max) would silently yield type(uint64).max; 2^64 would yield 0.
        vm.expectRevert(_overflow(FIELD, type(uint256).max, U64_MAX));
        h.toUint64(type(uint256).max);
        vm.expectRevert(_overflow(FIELD, uint256(1) << 64, U64_MAX));
        h.toUint64(uint256(1) << 64);
    }

    function test_revertNamesTheViolatedField() public {
        vm.expectRevert(_overflow(V2SafeCast.FIELD_GUARANTEES_CHAIN_ID, U64_MAX + 1, U64_MAX));
        h.toUint64Field(U64_MAX + 1, V2SafeCast.FIELD_GUARANTEES_CHAIN_ID);
        vm.expectRevert(_overflow(V2SafeCast.FIELD_ATTESTATION_CHAIN_ID, U64_MAX + 1, U64_MAX));
        h.toUint64Field(U64_MAX + 1, V2SafeCast.FIELD_ATTESTATION_CHAIN_ID);
    }

    // =========================================================================
    // Negative-to-unsigned
    // =========================================================================

    function test_negativeToUnsigned_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SafeCastNegative.selector, FIELD, int256(-1)));
        h.toUint256(-1);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SafeCastNegative.selector, FIELD, type(int256).min));
        h.toUint256(type(int256).min);
    }

    function test_nonNegativeToUnsigned_isExact() public view {
        assertEq(h.toUint256(0), 0);
        assertEq(h.toUint256(type(int256).max), uint256(type(int256).max));
    }

    function testFuzz_signedRoundTrip(int256 x) public {
        if (x < 0) {
            vm.expectRevert(abi.encodeWithSelector(V2Errors.SafeCastNegative.selector, FIELD, x));
            h.toUint256(x);
        } else {
            assertEq(h.toUint256(x), uint256(x));
        }
    }

    // =========================================================================
    // Fuzzed round-trip properties
    // =========================================================================

    function testFuzz_roundTrip_uint8(uint256 x) public view {
        x = bound(x, 0, type(uint8).max);
        assertEq(uint256(h.toUint8(x)), x);
    }

    function testFuzz_roundTrip_uint24(uint256 x) public view {
        x = bound(x, 0, type(uint24).max);
        assertEq(uint256(h.toUint24(x)), x);
    }

    function testFuzz_roundTrip_uint48(uint256 x) public view {
        x = bound(x, 0, type(uint48).max);
        assertEq(uint256(h.toUint48(x)), x);
    }

    function testFuzz_roundTrip_uint64(uint256 x) public view {
        x = bound(x, 0, type(uint64).max);
        assertEq(uint256(h.toUint64(x)), x);
    }

    function testFuzz_roundTrip_uint128(uint256 x) public view {
        x = bound(x, 0, type(uint128).max);
        assertEq(uint256(h.toUint128(x)), x);
    }

    function testFuzz_overflow_uint64_revertsWithExactArgs(uint256 x) public {
        x = bound(x, U64_MAX + 1, type(uint256).max);
        vm.expectRevert(_overflow(FIELD, x, U64_MAX));
        h.toUint64(x);
    }

    function testFuzz_overflow_uint128_revertsWithExactArgs(uint256 x) public {
        x = bound(x, uint256(type(uint128).max) + 1, type(uint256).max);
        vm.expectRevert(_overflow(FIELD, x, type(uint128).max));
        h.toUint128(x);
    }

    // =========================================================================
    // Packed-slot sentinel preservation
    // =========================================================================

    uint256 internal constant CREATED_MASK = (uint256(1) << 64) - 1;
    uint256 internal constant AMOUNT_MASK = ((uint256(1) << 128) - 1) << 72;
    uint256 internal constant SNAPSHOT_MASK = ((uint256(1) << 48) - 1) << 200;

    function _slot0() internal view returns (uint256) {
        return uint256(vm.load(address(h), bytes32(0)));
    }

    function test_packedSlot_sentinelsSurviveBoundaryWrites() public {
        // status = 0xA5 and tail = 0x5A act as sentinels; every other lane is 0xFF…
        uint256 sentinel = type(uint256).max;
        sentinel = (sentinel & ~(uint256(0xFF) << 64)) | (uint256(0xA5) << 64);
        sentinel = (sentinel & ~(uint256(0xFF) << 248)) | (uint256(0x5A) << 248);
        vm.store(address(h), bytes32(0), bytes32(sentinel));

        h.writeCreatedAt(U64_MAX);
        h.writeAmount(type(uint128).max);
        h.writeSnapshot(U48_MAX);
        assertEq(_slot0(), sentinel, "max writes must be bit-exact");

        h.writeCreatedAt(0);
        h.writeAmount(0);
        h.writeSnapshot(0);
        uint256 word = _slot0();
        assertEq(word & CREATED_MASK, 0);
        assertEq(word & AMOUNT_MASK, 0);
        assertEq(word & SNAPSHOT_MASK, 0);
        (, uint8 status,,, uint8 tail) = h.packed();
        assertEq(status, 0xA5, "status sentinel clobbered");
        assertEq(tail, 0x5A, "tail sentinel clobbered");

        // max+1 must revert and leave the slot bit-for-bit unchanged.
        vm.expectRevert(_overflow(V2SafeCast.FIELD_CLAIM_CREATED_AT, U64_MAX + 1, U64_MAX));
        h.writeCreatedAt(U64_MAX + 1);
        vm.expectRevert(_overflow(FIELD_AMOUNT, uint256(type(uint128).max) + 1, type(uint128).max));
        h.writeAmount(uint256(type(uint128).max) + 1);
        vm.expectRevert(_overflow(FIELD_SNAPSHOT, U48_MAX + 1, U48_MAX));
        h.writeSnapshot(U48_MAX + 1);
        assertEq(_slot0(), word, "rejected writes must not touch the slot");
    }

    function testFuzz_packedSlot_writeOnlyTouchesItsLane(uint256 sentinel, uint256 createdAt, uint256 amount) public {
        createdAt = bound(createdAt, 0, U64_MAX);
        amount = bound(amount, 0, type(uint128).max);
        vm.store(address(h), bytes32(0), bytes32(sentinel));

        h.writeCreatedAt(createdAt);
        uint256 afterCreated = _slot0();
        assertEq(afterCreated & ~CREATED_MASK, sentinel & ~CREATED_MASK, "createdAt write leaked into neighbours");
        assertEq(afterCreated & CREATED_MASK, createdAt, "createdAt round trip");

        h.writeAmount(amount);
        uint256 afterAmount = _slot0();
        assertEq(afterAmount & ~AMOUNT_MASK, afterCreated & ~AMOUNT_MASK, "amount write leaked into neighbours");
        assertEq((afterAmount & AMOUNT_MASK) >> 72, amount, "amount round trip");
    }

    // =========================================================================
    // Clock helpers
    // =========================================================================

    function test_timestamp48_boundary() public {
        vm.warp(U48_MAX);
        assertEq(h.now48(), type(uint48).max);
        vm.warp(U48_MAX + 1);
        vm.expectRevert(_overflow(V2SafeCast.FIELD_GOVERNANCE_CLOCK, U48_MAX + 1, U48_MAX));
        h.now48();
    }

    function test_timestamp64_boundary() public {
        vm.warp(U64_MAX);
        assertEq(h.now64(), type(uint64).max);
        vm.warp(U64_MAX + 1);
        vm.expectRevert(_overflow(V2SafeCast.FIELD_CLAIM_CREATED_AT, U64_MAX + 1, U64_MAX));
        h.now64();
    }

    // =========================================================================
    // Proven-safe constants and bounded decimals
    // =========================================================================

    function test_provenSafeConstantsFitTheirWidth() public pure {
        uint256 window = ProtocolExecutionBounds.CLAIM_SPAM_WINDOW_SECONDS;
        assertLe(window, U64_MAX);
        assertEq(uint256(uint64(window)), window, "spam window must round-trip through uint64");
    }

    function test_mixedDecimals_readAndRoundTrip() public {
        uint8[4] memory decs = [uint8(6), 8, 18, 36];
        for (uint256 i; i < decs.length; ++i) {
            MockDecimalsERC20 token = new MockDecimalsERC20("T", "T", decs[i]);
            assertEq(h.decimalsOf(address(token)), decs[i]);
            assertEq(h.tokenDecimals(address(token)), decs[i]);

            uint256 oneUnit = 10 ** decs[i];
            assertEq(h.toNormalized(oneUnit, decs[i]), 1e18, "one whole token normalizes to 1e18");
            assertEq(h.fromNormalized(1e18, decs[i]), oneUnit, "1e18 denormalizes to one whole token");
        }
        // 6-decimal amount at the uint128 storage boundary keeps its units through a round trip.
        uint256 usdcMax = uint256(type(uint128).max) / 1e12;
        uint256 normalized = h.toNormalized(usdcMax, 6);
        h.writeAmount(normalized);
        (,, uint128 stored,,) = h.packed();
        assertEq(h.fromNormalized(uint256(stored), 6), usdcMax, "no unit change through storage");
    }

    function testFuzz_mixedDecimals_lowDecimalsRoundTripExactly(uint256 amount, uint8 dec) public view {
        dec = uint8(bound(dec, 0, 18));
        amount = bound(amount, 0, type(uint256).max / (10 ** (18 - dec)));
        assertEq(h.fromNormalized(h.toNormalized(amount, dec), dec), amount);
    }

    function test_decimalsAboveBoundNeverAlias() public {
        MockDecimalsERC20 thirtySeven = new MockDecimalsERC20("T", "T", 37);
        vm.expectRevert(abi.encodeWithSelector(V2AmountUnits.UnsupportedDecimals.selector, address(thirtySeven)));
        h.decimalsOf(address(thirtySeven));
        vm.expectRevert(abi.encodeWithSelector(AmountUnits.UnsupportedDecimals.selector, uint8(37)));
        h.tokenDecimals(address(thirtySeven));

        // 256 would alias to 0 under a raw uint8(raw); both readers must fail closed instead.
        WideDecimalsToken wide = new WideDecimalsToken(256);
        vm.expectRevert(abi.encodeWithSelector(V2AmountUnits.UnsupportedDecimals.selector, address(wide)));
        h.decimalsOf(address(wide));
        vm.expectRevert(abi.encodeWithSelector(AmountUnits.UnsupportedDecimals.selector, type(uint8).max));
        h.tokenDecimals(address(wide));

        vm.expectRevert(abi.encodeWithSelector(V2AmountUnits.DecimalsOutOfRange.selector, uint8(37)));
        h.toNormalized(1, 37);
    }

    // =========================================================================
    // Lifecycle: Claims (timestamp, amount, counter)
    // =========================================================================

    function _claims(MockERC20 token) internal returns (Claims claims) {
        claims = new Claims(admin, address(token), feeSink, 1 ether, 0);
        token.mint(alice, type(uint128).max);
        vm.prank(alice);
        token.approve(address(claims), type(uint256).max);
    }

    function test_claims_timestampBoundary() public {
        MockERC20 token = new MockERC20("B", "B");
        Claims claims = _claims(token);

        vm.warp(U64_MAX);
        vm.prank(alice);
        uint256 id = claims.createClaim(keccak256("s1"), 1 ether, "");
        IV2Types.Claim memory c = claims.getClaim(id);
        assertEq(c.createdAt, type(uint64).max, "createdAt stored exactly at uint64 max");
        assertEq(uint256(c.status), uint256(IV2Types.ClaimStatus.OPEN), "packed status neighbour preserved");
        assertEq(c.reward, 1 ether);

        // A second claim in the same window must not overflow windowStart + window at the boundary.
        vm.prank(alice);
        claims.createClaim(keccak256("s2"), 1 ether, "");
        (uint64 windowStart, uint256 count) = claims.claimsInWindow(alice);
        assertEq(windowStart, type(uint64).max);
        assertEq(count, 2);

        vm.warp(U64_MAX + 1);
        vm.prank(alice);
        vm.expectRevert(_overflow(V2SafeCast.FIELD_CLAIM_CREATED_AT, U64_MAX + 1, U64_MAX));
        claims.createClaim(keccak256("s3"), 1 ether, "");

        vm.prank(alice);
        vm.expectRevert(_overflow(V2SafeCast.FIELD_CLAIM_EVENT_TIMESTAMP, U64_MAX + 1, U64_MAX));
        claims.cancelClaim(id);
        assertEq(uint256(claims.getClaim(id).status), uint256(IV2Types.ClaimStatus.OPEN), "rejected cancel is atomic");
        assertEq(claims.openClaimCount(alice), 2);
    }

    function test_claimMetadataBudgetRejectsOversizedBytes() public {
        MockERC20 token = new MockERC20("B", "B");
        Claims claims = _claims(token);
        bytes memory metadata = new bytes(claims.MAX_CLAIM_METADATA_BYTES() + 1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.ClaimMetadataTooLarge.selector,
                metadata.length,
                claims.MAX_CLAIM_METADATA_BYTES()
            )
        );
        claims.createClaim(keccak256("bounded"), 1 ether, metadata);
    }

    function test_claims_amountBoundary_rewardStoredUnnarrowed() public {
        MockERC20 token = new MockERC20("B", "B");
        Claims claims = _claims(token);
        uint256 reward = type(uint128).max;
        vm.prank(alice);
        uint256 id = claims.createClaim(keccak256("big"), reward, "");
        assertEq(claims.getClaim(id).reward, reward, "uint256 reward is never narrowed");
    }

    // =========================================================================
    // Lifecycle: StakeVault (timestamp, round, amount)
    // =========================================================================

    function _vault(MockERC20 token) internal returns (StakeVault vault) {
        MockModuleRegistry registry = new MockModuleRegistry();
        vault = new StakeVault(address(registry), address(token), admin);
        registry.permitModule(vault.MODULE_SETTLEMENT(), settlement);
        token.mint(alice, 1_000 ether);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
    }

    function test_stakeVault_timestampBoundary() public {
        MockERC20 token = new MockERC20("S", "S");
        StakeVault vault = _vault(token);
        uint256 amount = vault.minStakeAmount() + 1 ether;

        vm.warp(U64_MAX);
        vm.prank(alice);
        vault.depositStake(1, amount);
        assertEq(vault.staked(1, alice), amount);

        vm.warp(U64_MAX + 1);
        vm.prank(alice);
        vm.expectRevert(_overflow(V2SafeCast.FIELD_VAULT_EVENT_TIMESTAMP, U64_MAX + 1, U64_MAX));
        vault.depositStake(2, amount);
        assertEq(vault.staked(2, alice), 0, "rejected deposit leaves no custody");
    }

    function test_stakeVault_roundBoundary_maxRoundKeepsExactAmount() public {
        MockERC20 token = new MockERC20("S", "S");
        StakeVault vault = _vault(token);
        uint256 amount = vault.minStakeAmount() + 1 ether;
        vm.prank(alice);
        vault.depositStake(7, amount);

        vm.prank(settlement);
        vault.carryForwardAppeal(address(token), alice, 7, 0, type(uint256).max, amount);
        assertEq(
            vault.lockedPrincipal(address(token), alice, 7, type(uint256).max, IV2Types.LockCategory.VERIFIER_PRINCIPAL),
            amount,
            "uint256 round ids are never narrowed"
        );
        assertEq(vault.lockedPrincipal(address(token), alice, 7, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL), 0);
    }

    // =========================================================================
    // Lifecycle: EvidenceRegistry (timestamp, nonce)
    // =========================================================================

    function test_evidence_timestampAndNonceBoundary() public {
        MockEvidenceClaimRegistry claimRegistry = new MockEvidenceClaimRegistry();
        EvidenceRegistry registry = new EvidenceRegistry(admin, address(claimRegistry));
        claimRegistry.setClaim(1, admin, type(uint64).max, IClaimRegistry.ClaimStatus.Pending);

        vm.warp(U64_MAX);
        vm.startPrank(alice);
        uint256 e0 = registry.commitEvidence(1, keccak256("c0"), keccak256("m0"), 0);
        uint256 e1 = registry.commitEvidence(1, keccak256("c1"), keccak256("m1"), 1);
        vm.stopPrank();

        EvidenceRegistry.EvidenceCommitment memory c0 = registry.getEvidenceCommitment(e0);
        EvidenceRegistry.EvidenceCommitment memory c1 = registry.getEvidenceCommitment(e1);
        assertEq(c0.committedAt, type(uint64).max, "committedAt stored exactly at uint64 max");
        assertEq(c0.nonce, 0);
        assertEq(c1.nonce, 1, "uint256 nonce round-trips unnarrowed");
        assertEq(uint256(c1.status), uint256(IV2Types.EvidenceStatus.SUBMITTED), "packed status neighbour preserved");

        vm.warp(U64_MAX + 1);
        vm.prank(alice);
        vm.expectRevert(_overflow(V2SafeCast.FIELD_EVIDENCE_COMMITTED_AT, U64_MAX + 1, U64_MAX));
        registry.commitEvidence(1, keccak256("c2"), keccak256("m2"), 2);
    }

    // =========================================================================
    // Lifecycle: ModuleRegistry (timestamp, version identifiers)
    // =========================================================================

    function test_moduleRegistry_timestampAndVersionBoundary() public {
        ModuleRegistry registry = new ModuleRegistry(admin, makeAddr("governance"), makeAddr("guardian"));
        bytes32 moduleId = ModuleRegistryLib.MODULE_CLAIMS;
        bytes4 iface = ModuleRegistryLib.canonicalInterfaceOf(moduleId);
        MockV2Module module = new MockV2Module(2, type(uint16).max, iface);
        IModuleRegistry.ModuleRegistration memory reg = IModuleRegistry.ModuleRegistration({
            moduleId: moduleId,
            interfaceId: iface,
            proxy: address(module),
            implementation: address(0),
            major: 2,
            minor: type(uint16).max
        });

        vm.warp(U64_MAX);
        registry.registerModule(reg);
        registry.activateModule(moduleId);

        IModuleRegistry.ModuleInfo memory info = registry.getModule(moduleId);
        assertEq(info.activatedAt, type(uint64).max, "activatedAt at uint64 max");
        assertEq(info.changedAt, type(uint64).max, "changedAt at uint64 max");
        assertEq(info.major, 2);
        assertEq(info.minor, type(uint16).max, "uint16 version minor preserved at max");
        assertEq(info.interfaceId, iface, "packed interfaceId neighbour preserved");
        assertEq(uint256(info.status), uint256(IModuleRegistry.ModuleStatus.ACTIVE), "packed status neighbour preserved");

        bytes32 otherId = ModuleRegistryLib.MODULE_EVIDENCE;
        bytes4 otherIface = ModuleRegistryLib.canonicalInterfaceOf(otherId);
        MockV2Module other = new MockV2Module(2, 0, otherIface);
        vm.warp(U64_MAX + 1);
        vm.expectRevert(_overflow(V2SafeCast.FIELD_MODULE_CHANGED_AT, U64_MAX + 1, U64_MAX));
        registry.registerModule(
            IModuleRegistry.ModuleRegistration({
                moduleId: otherId,
                interfaceId: otherIface,
                proxy: address(other),
                implementation: address(0),
                major: 2,
                minor: 0
            })
        );
    }

    // =========================================================================
    // Lifecycle: ClaimRegistry (timestamp + deadline horizon arithmetic)
    // =========================================================================

    function test_claimRegistry_deadlineHorizonNearUint64Max() public {
        ClaimRegistry registry = new ClaimRegistry(admin, address(0xB0B));
        string memory statement = "a statement of at least ten bytes";
        string memory cid = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";

        // Before V2-SC-161, now_ + MAX_DEADLINE_HORIZON overflowed uint64 here and panicked.
        vm.warp(U64_MAX - 1);
        vm.prank(alice);
        uint256 id = registry.createClaim(statement, cid, type(uint64).max);
        IClaimRegistry.Claim memory c = registry.getClaim(id);
        assertEq(c.createdAt, type(uint64).max - 1);
        assertEq(c.verificationDeadline, type(uint64).max);

        vm.warp(U64_MAX + 1);
        vm.prank(alice);
        vm.expectRevert(_overflow(V2SafeCast.FIELD_REGISTRY_CREATED_AT, U64_MAX + 1, U64_MAX));
        registry.createClaim(statement, cid, type(uint64).max);
    }

    // =========================================================================
    // Lifecycle: governance clock (uint48 timestamp) and voting weight (uint208)
    // =========================================================================

    function test_governanceToken_clockBoundary() public {
        TruthBountyGovernanceToken token = new TruthBountyGovernanceToken(alice, 1_000 ether);

        vm.warp(U48_MAX);
        assertEq(token.clock(), type(uint48).max);

        vm.warp(U48_MAX + 1);
        vm.expectRevert(_overflow(V2SafeCast.FIELD_GOVERNANCE_CLOCK, U48_MAX + 1, U48_MAX));
        token.clock();

        // Checkpoint writes read clock(); they fail closed instead of recording a wrapped timepoint.
        vm.prank(alice);
        vm.expectRevert(_overflow(V2SafeCast.FIELD_GOVERNANCE_CLOCK, U48_MAX + 1, U48_MAX));
        token.delegate(alice);
    }

    function test_governanceToken_votingWeightBoundary() public {
        uint256 cap = type(uint208).max;
        TruthBountyGovernanceToken token = new TruthBountyGovernanceToken(alice, cap);
        vm.prank(alice);
        token.delegate(alice);
        vm.warp(block.timestamp + 1);
        assertEq(token.getVotes(alice), cap, "uint208 checkpoint holds the exact max weight");

        vm.expectRevert(abi.encodeWithSelector(ERC20Votes.ERC20ExceededSafeSupply.selector, cap + 1, cap));
        new TruthBountyGovernanceToken(alice, cap + 1);
    }

    // =========================================================================
    // Lifecycle: reputation-weighted voting (weight, bps widths)
    // =========================================================================

    function test_votingWeight_boundaries() public {
        ReputationWeightedVotingBounds bounds = new ReputationWeightedVotingBounds(admin, address(0));
        uint256 stake = type(uint128).max;

        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: stake,
            reputationScore: 0,
            weightCapBps: 10_000,
            minReputationBps: 10_000,
            maxReputationBps: 10_000,
            appealMultiplierBps: type(uint24).max,
            totalRoundStake: 0
        });
        ReputationWeightedVotingBounds.VotingWeightOutput memory out = bounds.computeEffectiveVotingWeight(input);
        assertEq(out.effectiveWeight, Math.mulDiv(stake, type(uint24).max, 10_000), "max multiplier is exact");

        input.weightCapBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(ReputationWeightedVotingBounds.InvalidWeightCap.selector, uint16(10_001)));
        bounds.computeEffectiveVotingWeight(input);

        input.weightCapBps = 10_000;
        input.appealMultiplierBps = 0;
        vm.expectRevert(abi.encodeWithSelector(ReputationWeightedVotingBounds.InvalidAppealMultiplier.selector, uint24(0)));
        bounds.computeEffectiveVotingWeight(input);
    }
}
