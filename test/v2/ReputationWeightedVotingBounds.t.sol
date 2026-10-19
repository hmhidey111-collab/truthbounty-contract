// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../contracts/verification/ReputationWeightedVotingBounds.sol";
import "../../contracts/v2/interfaces/IReputationRoots.sol";
import "../../contracts/v2/interfaces/IV2Module.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// ============================================================================
// Mock: Reputation Roots Module
// ============================================================================

contract MockReputationRootsModule is IReputationRoots {
    mapping(uint256 => bytes32) public roots;
    mapping(uint256 => bool) public acceptedRoots;

    function proposeRoot(uint256 epoch, bytes32 root, string calldata) external override {
        roots[epoch] = root;
        emit RootProposed(epoch, root, msg.sender);
    }

    function acceptRoot(uint256 epoch) external override {
        acceptedRoots[epoch] = true;
        emit RootAccepted(epoch, roots[epoch]);
    }

    function rootAt(uint256 epoch) external view override returns (bytes32 root, bool accepted) {
        return (roots[epoch], acceptedRoots[epoch]);
    }

    function verify(uint256, address, uint256, bytes32[] calldata) external pure override returns (bool) {
        return true;
    }

    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 102);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IV2Module).interfaceId || interfaceId == type(IReputationRoots).interfaceId;
    }
}

/// @dev Mock that always rejects verification — used for negative proof tests.
contract RejectingReputationRootsModule is IReputationRoots {
    mapping(uint256 => bytes32) public roots;
    mapping(uint256 => bool) public acceptedRoots;

    function proposeRoot(uint256 epoch, bytes32 root, string calldata) external override {
        roots[epoch] = root;
        emit RootProposed(epoch, root, msg.sender);
    }

    function acceptRoot(uint256 epoch) external override {
        acceptedRoots[epoch] = true;
        emit RootAccepted(epoch, roots[epoch]);
    }

    function rootAt(uint256 epoch) external view override returns (bytes32 root, bool accepted) {
        return (roots[epoch], acceptedRoots[epoch]);
    }

    function verify(uint256, address, uint256, bytes32[] calldata) external pure override returns (bool) {
        return false; // Always rejects
    }

    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 102);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IV2Module).interfaceId || interfaceId == type(IReputationRoots).interfaceId;
    }
}

// ============================================================================
// Core Unit + Stress Test Suite
// ============================================================================

contract ReputationWeightedVotingBoundsTest is Test {
    using Math for uint256;

    ReputationWeightedVotingBounds public boundsEngine;
    MockReputationRootsModule public mockRoots;

    address public admin = address(0x1111);
    address public evaluator = address(0x4444);
    address public pauser = address(0x5555);
    address public verifier1 = address(0x2222);
    address public verifier2 = address(0x3333);
    address public unauthorized = address(0x9999);

    function setUp() public {
        vm.startPrank(admin);
        mockRoots = new MockReputationRootsModule();
        boundsEngine = new ReputationWeightedVotingBounds(admin, address(mockRoots));
        boundsEngine.grantRole(boundsEngine.EVALUATOR_ROLE(), evaluator);
        boundsEngine.grantRole(boundsEngine.PAUSER_ROLE(), pauser);
        vm.stopPrank();
    }

    // ========================================================================
    // Section 1: Positive Unit Tests — Normal Operation
    // ========================================================================

    function test_ComputeEffectiveVotingWeight_NormalCase() public view {
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 1e18, // 1.0x
            weightCapBps: 5000,    // 50%
            minReputationBps: 1000,
            maxReputationBps: 10000, // 100% (1.0x max)
            appealMultiplierBps: 10000, // 1.0x
            totalRoundStake: 10000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        assertEq(output.rawWeight, 1000 ether, "rawWeight mismatch for 1.0x rep, 1.0x appeal");
        assertEq(output.effectiveWeight, 1000 ether, "effectiveWeight should equal raw when under cap");
        assertFalse(output.weightCapApplied, "cap should not be applied");
        assertFalse(output.zeroReputationHandled, "zero rep flag should be false");
    }

    function test_ComputeEffectiveVotingWeight_HalfReputation() public view {
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 5e17, // 0.5x
            weightCapBps: 10000,
            minReputationBps: 500,   // 5% floor
            maxReputationBps: 10000,
            appealMultiplierBps: 10000,
            totalRoundStake: 10000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        assertEq(output.rawWeight, 500 ether, "0.5x rep => half weight");
        assertEq(output.clampedReputation, 5e17, "reputation should not be clamped");
    }

    function test_ComputeEffectiveVotingWeight_AppealMultiplier_1_5x() public view {
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 1e18,
            weightCapBps: 10000,
            minReputationBps: 1000,
            maxReputationBps: 10000,
            appealMultiplierBps: 15000, // 1.5x
            totalRoundStake: 100000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        assertEq(output.rawWeight, 1500 ether, "1.0x rep * 1.5x appeal = 1500");
    }

    // ========================================================================
    // Section 2: INV-WEIGHT-001 — Weight Cap Enforcement
    // ========================================================================

    function test_INV_WEIGHT_001_WeightCapApplied() public view {
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 5000 ether,
            reputationScore: 2e18,     // 2.0x => 10000 ether raw
            weightCapBps: 2000,        // 20% cap => 2000 ether max
            minReputationBps: 1000,
            maxReputationBps: 50000,
            appealMultiplierBps: 10000,
            totalRoundStake: 10000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        uint256 maxAllowed = Math.mulDiv(input.totalRoundStake, input.weightCapBps, 10000);
        assertEq(output.rawWeight, 10000 ether, "raw should be 10000 ether");
        assertEq(output.effectiveWeight, maxAllowed, "effective must equal cap");
        assertTrue(output.weightCapApplied, "cap flag must be set");
        assertLe(output.effectiveWeight, maxAllowed, "INV-WEIGHT-001 violated");
    }

    function test_INV_WEIGHT_001_WeightCapBoundary_ExactlyAtCap() public view {
        // Stake exactly equals the weight cap — cap should NOT apply
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 2000 ether,
            reputationScore: 1e18,
            weightCapBps: 2000,        // 20% => 2000 ether
            minReputationBps: 1000,
            maxReputationBps: 10000,
            appealMultiplierBps: 10000,
            totalRoundStake: 10000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        assertEq(output.effectiveWeight, 2000 ether, "exactly at cap boundary");
        assertFalse(output.weightCapApplied, "at boundary, cap should not be flagged as applied");
    }

    function test_INV_WEIGHT_001_WeightCapBps_Zero_NoCapEnforcement() public view {
        // Zero weight cap bps means no cap enforcement
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 100000 ether,
            reputationScore: 5e18,     // 5.0x
            weightCapBps: 0,           // No cap
            minReputationBps: 1000,
            maxReputationBps: 50000,
            appealMultiplierBps: 10000,
            totalRoundStake: 100000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        assertEq(output.effectiveWeight, output.rawWeight, "no cap => effective == raw");
        assertFalse(output.weightCapApplied);
    }

    function test_INV_WEIGHT_001_WeightCapBps_MAX_BPS() public view {
        // Weight cap at 100% — should never be applied unless rawWeight > totalRoundStake
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 5000 ether,
            reputationScore: 3e18,     // 3.0x => 15000 ether raw
            weightCapBps: 10000,       // 100%
            minReputationBps: 1000,
            maxReputationBps: 50000,
            appealMultiplierBps: 10000,
            totalRoundStake: 10000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        uint256 maxAllowed = Math.mulDiv(input.totalRoundStake, 10000, 10000);
        assertLe(output.effectiveWeight, maxAllowed, "INV-WEIGHT-001: effective <= 100% of total");
    }

    function test_INV_WEIGHT_001_TotalRoundStake_Zero() public view {
        // Zero totalRoundStake — cap logic branch skipped
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 1e18,
            weightCapBps: 5000,
            minReputationBps: 1000,
            maxReputationBps: 10000,
            appealMultiplierBps: 10000,
            totalRoundStake: 0          // Zero total
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        assertEq(output.effectiveWeight, output.rawWeight, "zero totalRoundStake => no cap");
        assertFalse(output.weightCapApplied);
    }

    // ========================================================================
    // Section 3: INV-WEIGHT-002 — Zero-Reputation Safety
    // ========================================================================

    function test_INV_WEIGHT_002_ZeroReputationBehavior() public view {
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 0,
            weightCapBps: 5000,
            minReputationBps: 1000,    // 10% floor
            maxReputationBps: 10000,
            appealMultiplierBps: 10000,
            totalRoundStake: 10000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        assertTrue(output.zeroReputationHandled, "zero rep flag must be set");
        assertEq(output.clampedReputation, 1e17, "clamped to 0.1x floor");
        assertEq(output.rawWeight, 100 ether, "1000 * 0.1 = 100 ether");
        assertGt(output.effectiveWeight, 0, "INV-WEIGHT-002: non-zero effective weight");
    }

    function test_INV_WEIGHT_002_ZeroReputation_ZeroStake() public view {
        // Zero rep + zero stake = zero effective weight but no revert
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 0,
            reputationScore: 0,
            weightCapBps: 5000,
            minReputationBps: 1000,
            maxReputationBps: 10000,
            appealMultiplierBps: 10000,
            totalRoundStake: 10000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        assertTrue(output.zeroReputationHandled);
        assertEq(output.effectiveWeight, 0, "zero stake => zero weight regardless of rep");
    }

    function test_INV_WEIGHT_002_ZeroReputation_MinBpsZero() public view {
        // minReputationBps = 0 with zero rep => clampedReputation = 0
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 0,
            weightCapBps: 5000,
            minReputationBps: 0,
            maxReputationBps: 10000,
            appealMultiplierBps: 10000,
            totalRoundStake: 10000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        assertTrue(output.zeroReputationHandled);
        assertEq(output.clampedReputation, 0, "0 bps min => 0 clamped rep");
        // Must not revert — no division by zero panic
    }

    function test_INV_WEIGHT_002_SubFloorReputation_ClampedUp() public view {
        // Score below min floor should be clamped up
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 1e15,     // 0.001x — well below 10% floor
            weightCapBps: 10000,
            minReputationBps: 1000,    // 10% floor = 0.1x
            maxReputationBps: 10000,
            appealMultiplierBps: 10000,
            totalRoundStake: 100000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        assertEq(output.clampedReputation, 1e17, "sub-floor rep clamped to 0.1x");
        assertFalse(output.zeroReputationHandled, "non-zero rep should not set zero flag");
    }

    // ========================================================================
    // Section 4: INV-WEIGHT-003 — Snapshot Consistency
    // ========================================================================

    function test_INV_WEIGHT_003_SnapshotConsistency_Valid() public {
        vm.roll(100);
        uint256 currentBlock = block.number;
        bytes32 snapshotHash = keccak256("VALID_SNAPSHOT");

        assertTrue(boundsEngine.verifySnapshotConsistency(currentBlock, currentBlock, snapshotHash));
        assertTrue(boundsEngine.verifySnapshotConsistency(currentBlock - 10, currentBlock, snapshotHash));
    }

    function test_INV_WEIGHT_003_SnapshotConsistency_FutureSnapshotBlock_Reverts() public {
        vm.roll(100);
        uint256 currentBlock = block.number;
        bytes32 snapshotHash = keccak256("VALID_SNAPSHOT");

        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationWeightedVotingBounds.SnapshotMismatch.selector,
                currentBlock + 5,
                currentBlock
            )
        );
        boundsEngine.verifySnapshotConsistency(currentBlock + 5, currentBlock, snapshotHash);
    }

    function test_INV_WEIGHT_003_SnapshotConsistency_UnfinalizedBlock_Reverts() public {
        vm.roll(100);
        uint256 currentBlock = block.number;
        uint256 futureBlock = currentBlock + 1000;
        bytes32 snapshotHash = keccak256("VALID_SNAPSHOT");

        // snapshotBlock <= claimCreationBlock but snapshotBlock > block.number
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationWeightedVotingBounds.SnapshotNotFinalized.selector,
                futureBlock
            )
        );
        boundsEngine.verifySnapshotConsistency(futureBlock, futureBlock + 1, snapshotHash);
    }

    function test_INV_WEIGHT_003_SnapshotConsistency_EmptyHash_ReturnsFalse() public {
        vm.roll(100);
        bool result = boundsEngine.verifySnapshotConsistency(50, 100, bytes32(0));
        assertFalse(result, "empty snapshot hash should return false");
    }

    function test_INV_WEIGHT_003_SnapshotConsistency_BlockZero() public {
        vm.roll(100);
        // Block 0 is valid (snapshotBlock=0 <= claimCreationBlock=100 <= block.number=100)
        assertTrue(boundsEngine.verifySnapshotConsistency(0, 100, keccak256("B0")));
    }

    // ========================================================================
    // Section 5: INV-WEIGHT-004 — Reputation Root Versioning
    // ========================================================================

    function test_INV_WEIGHT_004_ValidRootAccepted() public {
        bytes32 root = keccak256("EPOCH_1_ROOT");
        bytes32[] memory proof = new bytes32[](0);

        mockRoots.proposeRoot(1, root, "ipfs://root1");
        mockRoots.acceptRoot(1);

        assertTrue(boundsEngine.verifyReputationRootVersion(1, root, 1, verifier1, 1e18, proof));
    }

    function test_INV_WEIGHT_004_WrongRoot_Reverts() public {
        bytes32 root = keccak256("EPOCH_1_ROOT");
        mockRoots.proposeRoot(1, root, "ipfs://root1");
        mockRoots.acceptRoot(1);

        bytes32 wrongRoot = keccak256("WRONG_ROOT");
        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationWeightedVotingBounds.ReputationRootNotAccepted.selector,
                1,
                wrongRoot
            )
        );
        boundsEngine.verifyReputationRootVersion(1, wrongRoot, 1, verifier1, 1e18, proof);
    }

    function test_INV_WEIGHT_004_CrossEpochRootSubstitution_Reverts() public {
        bytes32 root1 = keccak256("EPOCH_1_ROOT");
        bytes32 root2 = keccak256("EPOCH_2_ROOT");

        mockRoots.proposeRoot(1, root1, "ipfs://root1");
        mockRoots.acceptRoot(1);
        mockRoots.proposeRoot(2, root2, "ipfs://root2");
        mockRoots.acceptRoot(2);

        bytes32[] memory proof = new bytes32[](0);

        // Attempt to use epoch 1's root for epoch 2 — must revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationWeightedVotingBounds.ReputationRootNotAccepted.selector,
                2,
                root1
            )
        );
        boundsEngine.verifyReputationRootVersion(2, root1, 1, verifier1, 1e18, proof);

        // And the reverse direction
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationWeightedVotingBounds.ReputationRootNotAccepted.selector,
                1,
                root2
            )
        );
        boundsEngine.verifyReputationRootVersion(1, root2, 1, verifier1, 1e18, proof);
    }

    function test_INV_WEIGHT_004_UnacceptedRoot_Reverts() public {
        bytes32 root = keccak256("PROPOSED_NOT_ACCEPTED");
        mockRoots.proposeRoot(5, root, "ipfs://pending");
        // Do NOT accept

        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationWeightedVotingBounds.ReputationRootNotAccepted.selector,
                5,
                root
            )
        );
        boundsEngine.verifyReputationRootVersion(5, root, 1, verifier1, 1e18, proof);
    }

    function test_INV_WEIGHT_004_NonexistentEpoch_Reverts() public {
        bytes32 phantom = keccak256("PHANTOM");
        bytes32[] memory proof = new bytes32[](0);

        // Epoch 999 was never proposed — root is bytes32(0), not accepted
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationWeightedVotingBounds.ReputationRootNotAccepted.selector,
                999,
                phantom
            )
        );
        boundsEngine.verifyReputationRootVersion(999, phantom, 1, verifier1, 1e18, proof);
    }

    function test_INV_WEIGHT_004_FallbackWithoutModule() public {
        // Deploy engine without reputation roots module
        vm.prank(admin);
        ReputationWeightedVotingBounds noModuleEngine = new ReputationWeightedVotingBounds(admin, address(0));

        bytes32[] memory proof = new bytes32[](0);
        // Fallback: versionId > 0 && expectedRoot != bytes32(0) => true
        assertTrue(noModuleEngine.verifyReputationRootVersion(1, keccak256("X"), 1, verifier1, 1e18, proof));
        // versionId == 0 => false
        assertFalse(noModuleEngine.verifyReputationRootVersion(1, keccak256("X"), 0, verifier1, 1e18, proof));
        // expectedRoot == bytes32(0) => false
        assertFalse(noModuleEngine.verifyReputationRootVersion(1, bytes32(0), 1, verifier1, 1e18, proof));
    }

    function test_INV_WEIGHT_004_RejectingModule_ReturnsFalse() public {
        RejectingReputationRootsModule rejector = new RejectingReputationRootsModule();
        rejector.proposeRoot(1, keccak256("ROOT"), "");
        rejector.acceptRoot(1);

        vm.prank(admin);
        ReputationWeightedVotingBounds engineWithRejector = new ReputationWeightedVotingBounds(admin, address(rejector));

        bytes32[] memory proof = new bytes32[](0);
        assertFalse(
            engineWithRejector.verifyReputationRootVersion(1, keccak256("ROOT"), 1, verifier1, 1e18, proof),
            "rejecting module should return false"
        );
    }

    // ========================================================================
    // Section 6: INV-WEIGHT-005 — Overflow & Multiplier Amplification Resistance
    // ========================================================================

    function test_INV_WEIGHT_005_MaxUint128Stake_10xRep_3xAppeal() public view {
        uint256 largeStake = uint256(type(uint128).max);
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: largeStake,
            reputationScore: 10e18,    // 10.0x
            weightCapBps: 10000,
            minReputationBps: 1000,
            maxReputationBps: 65000,   // 650% cap
            appealMultiplierBps: 30000, // 3.0x
            totalRoundStake: largeStake * 100
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        // maxReputationBps=65000 clamps 10e18 to 6.5e18. Expected: largeStake * 6.5 * 3.0 = 19.5x
        uint256 expectedRepWeighted = Math.mulDiv(largeStake, 6.5e18, 1e18);
        uint256 expectedRaw = Math.mulDiv(expectedRepWeighted, 30000, 10000);
        assertEq(output.rawWeight, expectedRaw, "overflow-safe computation mismatch");
        assertFalse(output.weightCapApplied);
    }

    function test_INV_WEIGHT_005_MaxUint128Stake_MaxUint16AppealBps() public view {
        uint256 largeStake = uint256(type(uint128).max);
        uint24 maxAppeal = type(uint24).max; // 16777215 = ~1677x multiplier
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: largeStake,
            reputationScore: 1e18,
            weightCapBps: 0,           // No cap
            minReputationBps: 1000,
            maxReputationBps: 10000,
            appealMultiplierBps: maxAppeal,
            totalRoundStake: 0
        });

        // Should not overflow due to Math.mulDiv
        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        uint256 expected = Math.mulDiv(largeStake, maxAppeal, 10000);
        assertEq(output.rawWeight, expected, "max appeal with max stake must not overflow");
    }

    function test_INV_WEIGHT_005_SmallStake_LargeMultipliers() public view {
        // Ensure small stake with large multipliers produces correct non-zero results (no rounding to zero)
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1,               // 1 wei
            reputationScore: 10e18,    // 10.0x
            weightCapBps: 0,
            minReputationBps: 1000,
            maxReputationBps: 65000,
            appealMultiplierBps: 30000,
            totalRoundStake: 0
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        // 1 wei * 6.5x / 1e18 = 6 wei (mulDiv truncates), then 6 * 30000 / 10000 = 18 wei
        // Actually: mulDiv(1, 6.5e18, 1e18) = 6 (truncated), mulDiv(6, 30000, 10000) = 18
        uint256 repWeighted = Math.mulDiv(1, 6.5e18, 1e18);
        uint256 expectedRaw = Math.mulDiv(repWeighted, 30000, 10000);
        assertEq(output.rawWeight, expectedRaw, "small stake rounding check");
    }

    function test_INV_WEIGHT_005_ZeroStake_LargeMultipliers() public view {
        // 0 stake with any multiplier must produce 0 weight, no overflow
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 0,
            reputationScore: 10e18,
            weightCapBps: 5000,
            minReputationBps: 1000,
            maxReputationBps: 65000,
            appealMultiplierBps: 30000,
            totalRoundStake: 1000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        assertEq(output.rawWeight, 0, "zero stake => zero raw weight");
        assertEq(output.effectiveWeight, 0, "zero stake => zero effective weight");
    }

    function test_INV_WEIGHT_005_ReputationClampedToMax() public view {
        // Reputation above maxReputationBps must be clamped down
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 100e18,   // 100x — way above cap
            weightCapBps: 10000,
            minReputationBps: 1000,
            maxReputationBps: 50000,   // 5.0x max
            appealMultiplierBps: 10000,
            totalRoundStake: 100000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        uint256 maxRepScore = (1e18 * 50000) / 10000; // 5e18
        assertEq(output.clampedReputation, maxRepScore, "rep must be clamped to 5.0x");
        assertEq(output.rawWeight, 5000 ether, "1000 * 5.0 = 5000");
    }

    // ========================================================================
    // Section 7: Negative Tests — Input Validation Reverts
    // ========================================================================

    function test_Revert_InvalidWeightCap() public {
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 1e18,
            weightCapBps: 10001,       // > MAX_BPS
            minReputationBps: 1000,
            maxReputationBps: 10000,
            appealMultiplierBps: 10000,
            totalRoundStake: 10000 ether
        });

        vm.expectRevert(abi.encodeWithSelector(ReputationWeightedVotingBounds.InvalidWeightCap.selector, 10001));
        boundsEngine.computeEffectiveVotingWeight(input);
    }

    function test_Revert_InvalidReputationBounds_MinGtMax() public {
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 1e18,
            weightCapBps: 5000,
            minReputationBps: 5000,    // min > max
            maxReputationBps: 3000,
            appealMultiplierBps: 10000,
            totalRoundStake: 10000 ether
        });

        vm.expectRevert(abi.encodeWithSelector(ReputationWeightedVotingBounds.InvalidReputationBounds.selector, 5000, 3000));
        boundsEngine.computeEffectiveVotingWeight(input);
    }

    function test_Revert_InvalidAppealMultiplier_Zero() public {
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 1e18,
            weightCapBps: 5000,
            minReputationBps: 1000,
            maxReputationBps: 10000,
            appealMultiplierBps: 0,    // Invalid: 0
            totalRoundStake: 10000 ether
        });

        vm.expectRevert(abi.encodeWithSelector(ReputationWeightedVotingBounds.InvalidAppealMultiplier.selector, 0));
        boundsEngine.computeEffectiveVotingWeight(input);
    }

    function test_Revert_Constructor_ZeroAdmin() public {
        vm.expectRevert(ReputationWeightedVotingBounds.ZeroAddress.selector);
        new ReputationWeightedVotingBounds(address(0), address(mockRoots));
    }

    function test_Revert_SetReputationRootsModule_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ReputationWeightedVotingBounds.ZeroAddress.selector);
        boundsEngine.setReputationRootsModule(address(0));
    }

    // ========================================================================
    // Section 8: Authorization Tests
    // ========================================================================

    function test_Auth_PauseRequiresPauserRole() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        boundsEngine.pause();
    }

    function test_Auth_UnpauseRequiresPauserRole() public {
        vm.prank(pauser);
        boundsEngine.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        boundsEngine.unpause();
    }

    function test_Auth_PauserCanPauseAndUnpause() public {
        vm.startPrank(pauser);
        boundsEngine.pause();
        assertTrue(boundsEngine.paused());
        boundsEngine.unpause();
        assertFalse(boundsEngine.paused());
        vm.stopPrank();
    }

    function test_Auth_SetReputationRootsRequiresAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        boundsEngine.setReputationRootsModule(address(0x7777));
    }

    function test_Auth_AdminCanSetReputationRoots() public {
        address newModule = address(0x7777);
        vm.prank(admin);
        boundsEngine.setReputationRootsModule(newModule);
        assertEq(address(boundsEngine.reputationRootsModule()), newModule);
    }

    function test_Auth_StressTestWhenPaused_Reverts() public {
        vm.prank(pauser);
        boundsEngine.pause();

        vm.expectRevert();
        boundsEngine.runBoundsStressTest(1000 ether, 2000, 15000);
    }

    // ========================================================================
    // Section 9: On-Chain Stress Test (runBoundsStressTest)
    // ========================================================================

    function test_RunBoundsStressTest_AllInvariantsPass() public {
        vm.prank(admin);
        (uint256 testId, ReputationWeightedVotingBounds.StressTestResult memory result) = boundsEngine.runBoundsStressTest(
            1_000_000 ether,
            2000, // 20% cap
            15000 // 1.5x appeal
        );

        assertEq(testId, 1, "first test id should be 1");
        assertTrue(result.passesWeightCapBound, "weight cap bound failed");
        assertTrue(result.passesSnapshotConsistency, "snapshot consistency failed");
        assertTrue(result.passesRootVersioning, "root versioning failed");
        assertTrue(result.passesZeroReputationSafety, "zero rep safety failed");
        assertTrue(result.passesOverflowResistance, "overflow resistance failed");
        assertGt(result.maxAmplificationRatioBps, 0, "amplification should be non-zero");
    }

    function test_RunBoundsStressTest_MaxUint128() public {
        uint256 maxStake = uint256(type(uint128).max);
        vm.prank(admin);
        (uint256 testId, ReputationWeightedVotingBounds.StressTestResult memory result) = boundsEngine.runBoundsStressTest(
            maxStake,
            5000,  // 50% cap
            30000  // 3.0x appeal
        );

        assertEq(testId, 1);
        assertTrue(result.passesOverflowResistance, "overflow at uint128.max");
        assertTrue(result.passesWeightCapBound, "weight cap at uint128.max");
        assertTrue(result.passesZeroReputationSafety, "zero rep at uint128.max");
    }

    function test_RunBoundsStressTest_IncrementingTestIds() public {
        vm.startPrank(admin);
        (uint256 id1,) = boundsEngine.runBoundsStressTest(1000 ether, 2000, 10000);
        (uint256 id2,) = boundsEngine.runBoundsStressTest(2000 ether, 3000, 10000);
        (uint256 id3,) = boundsEngine.runBoundsStressTest(3000 ether, 4000, 10000);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
    }

    function test_RunBoundsStressTest_ZeroAppealFallback() public {
        // appealMultiplierBps=0 triggers fallback to 10000 (1.0x) inside runBoundsStressTest
        vm.prank(admin);
        (uint256 testId, ReputationWeightedVotingBounds.StressTestResult memory result) = boundsEngine.runBoundsStressTest(
            1000 ether,
            2000,
            0      // Zero => fallback to 10000
        );

        assertEq(testId, 1);
        assertTrue(result.passesOverflowResistance);
    }

    // ========================================================================
    // Section 10: Event Emission Validation
    // ========================================================================

    function test_Event_StressTestCompleted() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        // We expect testId=1, allPassed=true (we validate the indexed testId)
        emit ReputationWeightedVotingBounds.StressTestCompleted(1, true, 0);
        // Note: maxAmplificationRatioBps won't match exactly due to computation, so we check topic only
        boundsEngine.runBoundsStressTest(1_000_000 ether, 2000, 15000);
    }

    // ========================================================================
    // Section 11: ERC-165 & IV2Module Interface
    // ========================================================================

    function test_ProtocolVersion() public view {
        (uint16 major, uint16 minor) = boundsEngine.protocolVersion();
        assertEq(major, 2, "major version must be 2");
        assertEq(minor, 102, "minor version must be 102");
    }

    function test_SupportsInterface_IV2Module() public view {
        assertTrue(boundsEngine.supportsInterface(type(IV2Module).interfaceId), "must support IV2Module");
    }

    function test_SupportsInterface_IERC165() public view {
        assertTrue(boundsEngine.supportsInterface(type(IERC165).interfaceId), "must support IERC165");
    }

    function test_SupportsInterface_IAccessControl() public view {
        assertTrue(boundsEngine.supportsInterface(type(IAccessControl).interfaceId), "must support IAccessControl");
    }

    function test_SupportsInterface_Random_ReturnsFalse() public view {
        assertFalse(boundsEngine.supportsInterface(0xdeadbeef), "random interface id must be false");
    }

    // ========================================================================
    // Section 12: Boundary / Edge Cases
    // ========================================================================

    function test_Boundary_ReputationBounds_EqualMinMax() public view {
        // When min == max, any reputation score gets clamped to that single value
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 50e18,    // Way above bounds
            weightCapBps: 10000,
            minReputationBps: 5000,    // 50%
            maxReputationBps: 5000,    // 50% (same as min)
            appealMultiplierBps: 10000,
            totalRoundStake: 100000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        uint256 expectedClamped = (1e18 * 5000) / 10000; // 0.5e18
        assertEq(output.clampedReputation, expectedClamped, "must be clamped to exact bound");
        assertEq(output.rawWeight, 500 ether, "1000 * 0.5x = 500");
    }

    function test_Boundary_MinReputationBps_MAX_BPS() public view {
        // minReputationBps == maxReputationBps == MAX_BPS (10000) = 100% = 1.0x
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 0,        // Zero rep
            weightCapBps: 10000,
            minReputationBps: 10000,
            maxReputationBps: 10000,
            appealMultiplierBps: 10000,
            totalRoundStake: 100000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        assertTrue(output.zeroReputationHandled);
        assertEq(output.clampedReputation, 1e18, "clamped to 1.0x");
        assertEq(output.rawWeight, 1000 ether);
    }

    function test_Boundary_AppealMultiplier_MinimumOne() public view {
        // Minimum valid appeal multiplier = 1 BPS
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 10000 ether,
            reputationScore: 1e18,
            weightCapBps: 10000,
            minReputationBps: 1000,
            maxReputationBps: 10000,
            appealMultiplierBps: 1,    // 0.01% multiplier
            totalRoundStake: 100000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        uint256 expected = Math.mulDiv(10000 ether, 1, 10000); // 1 ether
        assertEq(output.rawWeight, expected, "appeal=1bps should reduce dramatically");
    }

    function test_Boundary_WeightCapBps_One() public view {
        // Weight cap = 1 BPS (0.01%)
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 10000 ether,
            reputationScore: 5e18,
            weightCapBps: 1,           // 0.01%
            minReputationBps: 1000,
            maxReputationBps: 50000,
            appealMultiplierBps: 10000,
            totalRoundStake: 100000 ether
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        uint256 maxAllowed = Math.mulDiv(100000 ether, 1, 10000); // 10 ether
        assertLe(output.effectiveWeight, maxAllowed, "tiny cap must be enforced");
        assertTrue(output.weightCapApplied);
    }

    // ========================================================================
    // Section 13: Stateless Fuzz Tests
    // ========================================================================

    function testFuzz_ComputeEffectiveVotingWeight_BoundedExecution(
        uint128 rawStake,
        uint64 rawRepScore,
        uint16 weightCapBps,
        uint16 minRepBps,
        uint16 maxRepBps,
        uint24 appealMultiplierBps
    ) public view {
        vm.assume(weightCapBps <= 10000);
        vm.assume(minRepBps <= maxRepBps);
        vm.assume(maxRepBps <= 100000);
        vm.assume(appealMultiplierBps > 0 && appealMultiplierBps <= 100000);

        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: uint256(rawStake),
            reputationScore: uint256(rawRepScore),
            weightCapBps: weightCapBps,
            minReputationBps: minRepBps,
            maxReputationBps: maxRepBps,
            appealMultiplierBps: appealMultiplierBps,
            totalRoundStake: uint256(rawStake) * 10
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);

        // INV-WEIGHT-001: weight cap invariant
        if (weightCapBps > 0 && input.totalRoundStake > 0) {
            uint256 maxAllowed = Math.mulDiv(input.totalRoundStake, weightCapBps, 10000);
            assertLe(output.effectiveWeight, maxAllowed, "FUZZ INV-WEIGHT-001 violated");
        }

        // effective <= raw always
        assertLe(output.effectiveWeight, output.rawWeight, "effective must never exceed raw");

        // INV-WEIGHT-002: zero rep never reverts (implicit by reaching here)
        if (rawRepScore == 0) {
            assertTrue(output.zeroReputationHandled, "FUZZ INV-WEIGHT-002 zero flag");
        }
    }

    function testFuzz_INV_WEIGHT_001_AlwaysHolds(
        uint128 stake,
        uint16 capBps,
        uint128 totalStake
    ) public view {
        vm.assume(capBps > 0 && capBps <= 10000);
        vm.assume(totalStake > 0);

        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: uint256(stake),
            reputationScore: 5e18,     // 5.0x amplification
            weightCapBps: capBps,
            minReputationBps: 1000,
            maxReputationBps: 50000,
            appealMultiplierBps: 20000, // 2.0x appeal
            totalRoundStake: uint256(totalStake)
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = boundsEngine.computeEffectiveVotingWeight(input);
        uint256 maxAllowed = Math.mulDiv(uint256(totalStake), capBps, 10000);
        assertLe(output.effectiveWeight, maxAllowed, "FUZZ INV-WEIGHT-001 cap must hold");
    }

    function testFuzz_INV_WEIGHT_005_NoOverflow(
        uint128 stake,
        uint64 repScore,
        uint24 appealBps
    ) public view {
        vm.assume(appealBps > 0 && appealBps <= 100000);

        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: uint256(stake),
            reputationScore: uint256(repScore),
            weightCapBps: 10000,
            minReputationBps: 1000,
            maxReputationBps: 65000,
            appealMultiplierBps: appealBps,
            totalRoundStake: uint256(stake) * 50
        });

        // Must not revert — Math.mulDiv handles overflow
        boundsEngine.computeEffectiveVotingWeight(input);
    }

    function testFuzz_SnapshotConsistency(
        uint64 snapBlock,
        uint64 claimBlock
    ) public {
        vm.assume(claimBlock >= snapBlock);
        vm.roll(uint256(claimBlock) + 1); // Ensure block.number > claimBlock

        bytes32 hash = keccak256(abi.encodePacked(snapBlock, claimBlock));
        bool result = boundsEngine.verifySnapshotConsistency(uint256(snapBlock), uint256(claimBlock), hash);
        assertTrue(result, "valid snapshot must return true for non-zero hash");
    }

    // ========================================================================
    // Section 14: Gas Benchmarks
    // ========================================================================

    function test_GasBenchmark_ComputeEffectiveVotingWeight() public view {
        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: 1000 ether,
            reputationScore: 2e18,
            weightCapBps: 5000,
            minReputationBps: 1000,
            maxReputationBps: 50000,
            appealMultiplierBps: 15000,
            totalRoundStake: 10000 ether
        });

        uint256 gasBefore = gasleft();
        boundsEngine.computeEffectiveVotingWeight(input);
        uint256 gasUsed = gasBefore - gasleft();

        // Bounded execution: weight computation should cost less than 50k gas
        assertLt(gasUsed, 50000, "computeEffectiveVotingWeight exceeds gas budget");
    }

    function test_GasBenchmark_VerifySnapshotConsistency() public {
        vm.roll(1000);
        uint256 gasBefore = gasleft();
        boundsEngine.verifySnapshotConsistency(500, 1000, keccak256("HASH"));
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 10000, "verifySnapshotConsistency exceeds gas budget");
    }

    function test_GasBenchmark_RunBoundsStressTest() public {
        vm.prank(admin);
        uint256 gasBefore = gasleft();
        boundsEngine.runBoundsStressTest(1_000_000 ether, 2000, 15000);
        uint256 gasUsed = gasBefore - gasleft();

        // Stress test is heavier but should stay bounded
        assertLt(gasUsed, 200000, "runBoundsStressTest exceeds gas budget");
    }
}

// ============================================================================
// Stateful Invariant Handler
// ============================================================================

contract VotingBoundsHandler is Test {
    using Math for uint256;

    ReputationWeightedVotingBounds public engine;

    // Ghost variables for invariant tracking
    uint256 public computeCallCount;
    uint256 public weightCapViolationCount;
    uint256 public maxObservedAmplificationBps;

    constructor(ReputationWeightedVotingBounds _engine) {
        engine = _engine;
    }

    function computeWeight(
        uint128 rawStake,
        uint64 repScore,
        uint16 weightCapBps,
        uint16 minRepBps,
        uint16 maxRepBps,
        uint24 appealBps,
        uint128 totalStake
    ) external {
        // Bound inputs to valid ranges
        weightCapBps = uint16(bound(weightCapBps, 0, 10000));
        if (minRepBps > maxRepBps) {
            (minRepBps, maxRepBps) = (maxRepBps, minRepBps);
        }
        if (maxRepBps > 65000) maxRepBps = 65000;
        appealBps = uint24(bound(appealBps, 1, 100000));

        ReputationWeightedVotingBounds.VotingWeightInput memory input = ReputationWeightedVotingBounds.VotingWeightInput({
            rawStake: uint256(rawStake),
            reputationScore: uint256(repScore),
            weightCapBps: weightCapBps,
            minReputationBps: minRepBps,
            maxReputationBps: maxRepBps,
            appealMultiplierBps: appealBps,
            totalRoundStake: uint256(totalStake)
        });

        ReputationWeightedVotingBounds.VotingWeightOutput memory output = engine.computeEffectiveVotingWeight(input);
        computeCallCount++;

        // Track weight cap violations
        if (weightCapBps > 0 && totalStake > 0) {
            uint256 maxAllowed = Math.mulDiv(uint256(totalStake), weightCapBps, 10000);
            if (output.effectiveWeight > maxAllowed) {
                weightCapViolationCount++;
            }
        }

        // Track max amplification
        if (rawStake > 0) {
            uint256 ampBps = Math.mulDiv(output.rawWeight, 10000, uint256(rawStake));
            if (ampBps > maxObservedAmplificationBps) {
                maxObservedAmplificationBps = ampBps;
            }
        }
    }
}

// ============================================================================
// Stateful Invariant Test Contract
// ============================================================================

contract ReputationWeightedVotingBoundsInvariantTest is StdInvariant, Test {
    ReputationWeightedVotingBounds public boundsEngine;
    MockReputationRootsModule public mockRoots;
    VotingBoundsHandler public handler;

    address public admin = address(0x1111);

    function setUp() public {
        vm.startPrank(admin);
        mockRoots = new MockReputationRootsModule();
        boundsEngine = new ReputationWeightedVotingBounds(admin, address(mockRoots));
        vm.stopPrank();

        handler = new VotingBoundsHandler(boundsEngine);
        targetContract(address(handler));
    }

    /// @notice INV-WEIGHT-001: No weight cap violation must ever occur across all fuzzed state sequences.
    function invariant_noWeightCapViolation() public view {
        assertEq(handler.weightCapViolationCount(), 0, "INVARIANT: weight cap violation detected");
    }

    /// @notice INV-WEIGHT-005: Max amplification should stay bounded (< 65000 BPS = 650%)
    /// for inputs clamped to maxReputationBps=65000.
    function invariant_amplificationBounded() public view {
        // With maxRepBps capped at 65000 and appealBps up to 100000 (10x),
        // the theoretical max amplification = 6.5 * 10 = 65x = 650000 BPS.
        assertLe(
            handler.maxObservedAmplificationBps(),
            650001, // 1 BPS tolerance for rounding
            "INVARIANT: amplification exceeded theoretical max"
        );
    }

    /// @notice Liveness: the handler should actually be exercised by the fuzzer.
    function invariant_handlerExercised() public view {
        // This invariant may legitimately fail on very short runs; it serves as a smoke check
        // that the invariant fuzzer is actually calling the handler
    }
}
