// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { ReleaseReproducibility } from "../../contracts/v2/libraries/ReleaseReproducibility.sol";

/// @dev Exposes the internal pure helpers of ReleaseReproducibility for testing.
contract ReproHarness {
    function validateCompiler(
        uint256 major,
        uint256 minor,
        uint256 patch,
        bool optimizerEnabled,
        uint256 runs,
        bool viaIR,
        bytes32 evmVersionHash
    ) external pure {
        ReleaseReproducibility.validateCompiler(major, minor, patch, optimizerEnabled, runs, viaIR, evmVersionHash);
    }

    function pack(uint256 major, uint256 minor, uint256 patch) external pure returns (uint256) {
        return ReleaseReproducibility.packSolcVersion(major, minor, patch);
    }

    function validateLibrary(address dependency) external pure {
        ReleaseReproducibility.validateLibraryAddress(dependency);
    }

    function validateNamed(string calldata libName, address dependency) external pure {
        ReleaseReproducibility.validateNamedLibrary(libName, dependency);
    }

    function assertNoLinks(uint256 count) external pure {
        ReleaseReproducibility.assertNoLinkReferences(count);
    }

    function digest(
        uint256 solcVersionCode,
        bool optimizerEnabled,
        uint256 optimizerRuns,
        bool viaIR,
        bytes32 evmVersionHash,
        bytes32[] calldata sourceHashes,
        bytes32[] calldata bytecodeHashes
    ) external pure returns (bytes32) {
        return ReleaseReproducibility.releaseDigest(
            solcVersionCode, optimizerEnabled, optimizerRuns, viaIR, evmVersionHash, sourceHashes, bytecodeHashes
        );
    }

    function check(bytes32 expectedDigest, bytes32 actualDigest) external pure {
        ReleaseReproducibility.checkDigest(expectedDigest, actualDigest);
    }

    function requireSource(string calldata source, bytes32 sourceHash) external pure {
        ReleaseReproducibility.requireSourceHash(source, sourceHash);
    }

    function requireBytecode(string calldata artifact, bytes32 bytecodeHash) external pure {
        ReleaseReproducibility.requireBytecodeHash(artifact, bytecodeHash);
    }
}

/// @dev Models the release-digest pinning rule: exactly one approved digest may be
///      pinned, it can never be re-pinned (no double claim), and it is immutable
///      once pinned (immutable active-claim parameters analog).
contract SinglePinHarness {
    bytes32 public pinned;
    bool public isPinned;

    error AlreadyPinned(bytes32 existing);

    function pin(bytes32 digest) external {
        if (isPinned) revert AlreadyPinned(pinned);
        if (digest == bytes32(0)) revert ReleaseReproducibility.EmptyBytecodeHash("digest");
        pinned = digest;
        isPinned = true;
    }
}

/// @title ReleaseReproducibilityTest
/// @notice V2-SC-129 — unit, boundary, authorization, replay, and failure-path
///         coverage for source/bytecode/metadata reproducibility pins.
/// @dev The library under test is pure and holds no authority: authorization is
///      covered by caller-invariance (any caller gets identical results, no
///      privileged path exists), replay by determinism checks.
contract ReleaseReproducibilityTest is Test {
    using stdJson for string;

    ReproHarness internal harness;
    SinglePinHarness internal pinHarness;

    uint256 internal constant APPROVED_MAJOR = 0;
    uint256 internal constant APPROVED_MINOR = 8;
    uint256 internal constant APPROVED_PATCH = 28;
    uint256 internal constant APPROVED_RUNS = 200;
    bytes32 internal EVM_HASH;

    function setUp() public {
        harness = new ReproHarness();
        pinHarness = new SinglePinHarness();
        EVM_HASH = keccak256("cancun");
    }

    // =========================================================================
    // Positive
    // =========================================================================

    function test_ValidateCompiler_AcceptsApprovedToolchain() public view {
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, APPROVED_PATCH, true, APPROVED_RUNS, true, EVM_HASH);
    }

    function test_PackSolcVersion_EncodesApprovedRelease() public view {
        assertEq(harness.pack(0, 8, 28), 8028);
    }

    function test_NonZeroLibraryAddress_Passes() public view {
        harness.validateLibrary(address(0xdead));
        harness.validateNamed("SomeLib", address(0xdead));
    }

    function test_ZeroLinkReferences_Pass() public view {
        harness.assertNoLinks(0);
    }

    function test_NonEmptyHashes_Pass() public view {
        harness.requireSource("contracts/v2/StakeVault.sol", keccak256("code"));
        harness.requireBytecode("StakeVault", keccak256("bytecode"));
    }

    function test_MatchingDigest_Passes() public view {
        bytes32 digest = keccak256("release");
        harness.check(digest, digest);
    }

    // =========================================================================
    // Negative / failure-path
    // =========================================================================

    function test_ValidateCompiler_RejectsWrongPatch() public {
        vm.expectRevert(
            abi.encodeWithSelector(ReleaseReproducibility.UnexpectedSolcVersion.selector, uint256(8028), uint256(8027))
        );
        harness.validateCompiler(0, 8, 27, true, APPROVED_RUNS, true, EVM_HASH);
    }

    function test_ValidateCompiler_RejectsWrongMinor() public {
        vm.expectRevert(
            abi.encodeWithSelector(ReleaseReproducibility.UnexpectedSolcVersion.selector, uint256(8028), uint256(7028))
        );
        harness.validateCompiler(0, 7, 28, true, APPROVED_RUNS, true, EVM_HASH);
    }

    function test_ValidateCompiler_RejectsDisabledOptimizer() public {
        vm.expectRevert(ReleaseReproducibility.OptimizerDisabled.selector);
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, APPROVED_PATCH, false, APPROVED_RUNS, true, EVM_HASH);
    }

    function test_ValidateCompiler_RejectsWrongRuns() public {
        vm.expectRevert(
            abi.encodeWithSelector(ReleaseReproducibility.UnexpectedOptimizerRuns.selector, APPROVED_RUNS, 199)
        );
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, APPROVED_PATCH, true, 199, true, EVM_HASH);
    }

    function test_ValidateCompiler_RejectsDisabledViaIR() public {
        vm.expectRevert(ReleaseReproducibility.ViaIRDisabled.selector);
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, APPROVED_PATCH, true, APPROVED_RUNS, false, EVM_HASH);
    }

    function test_ValidateCompiler_RejectsWrongEvm() public {
        bytes32 wrong = keccak256("london");
        vm.expectRevert(abi.encodeWithSelector(ReleaseReproducibility.EvmVersionMismatch.selector, EVM_HASH, wrong));
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, APPROVED_PATCH, true, APPROVED_RUNS, true, wrong);
    }

    function test_ValidateLibrary_RejectsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ReleaseReproducibility.ZeroLibraryAddress.selector, "unknown"));
        harness.validateLibrary(address(0));
    }

    function test_ValidateNamedLibrary_RejectsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ReleaseReproducibility.ZeroLibraryAddress.selector, "SomeLib"));
        harness.validateNamed("SomeLib", address(0));
    }

    function test_AssertNoLinks_RejectsUnresolvedReferences() public {
        vm.expectRevert(abi.encodeWithSelector(ReleaseReproducibility.UnexpectedLinkReference.selector, uint256(2)));
        harness.assertNoLinks(2);
    }

    function test_RequireSource_RejectsEmptyHash() public {
        vm.expectRevert(
            abi.encodeWithSelector(ReleaseReproducibility.EmptySourceHash.selector, "contracts/v2/StakeVault.sol")
        );
        harness.requireSource("contracts/v2/StakeVault.sol", bytes32(0));
    }

    function test_RequireBytecode_RejectsEmptyHash() public {
        vm.expectRevert(abi.encodeWithSelector(ReleaseReproducibility.EmptyBytecodeHash.selector, "StakeVault"));
        harness.requireBytecode("StakeVault", bytes32(0));
    }

    function test_CheckDigest_RejectsMismatch() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ReleaseReproducibility.DigestMismatch.selector, bytes32(uint256(1)), uint256(bytes32(uint256(2)))
            )
        );
        harness.check(bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function test_PackSolcVersion_RejectsOversizedMajor() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ReleaseReproducibility.UnexpectedSolcVersion.selector, uint256(8028), type(uint256).max
            )
        );
        harness.pack(256, 8, 28);
    }

    function test_PackSolcVersion_RejectsOversizedMinor() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ReleaseReproducibility.UnexpectedSolcVersion.selector, uint256(8028), type(uint256).max
            )
        );
        harness.pack(0, 1000, 28);
    }

    function test_PackSolcVersion_RejectsOversizedPatch() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ReleaseReproducibility.UnexpectedSolcVersion.selector, uint256(8028), type(uint256).max
            )
        );
        harness.pack(0, 8, 1000);
    }

    // =========================================================================
    // Boundary
    // =========================================================================

    function test_Boundary_RunsOneBelowAndAbove() public {
        vm.expectRevert(
            abi.encodeWithSelector(ReleaseReproducibility.UnexpectedOptimizerRuns.selector, APPROVED_RUNS, 199)
        );
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, APPROVED_PATCH, true, 199, true, EVM_HASH);
        vm.expectRevert(
            abi.encodeWithSelector(ReleaseReproducibility.UnexpectedOptimizerRuns.selector, APPROVED_RUNS, 201)
        );
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, APPROVED_PATCH, true, 201, true, EVM_HASH);
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, APPROVED_PATCH, true, 200, true, EVM_HASH);
    }

    function test_Boundary_PatchOneBelowAndAbove() public {
        assertEq(harness.pack(0, 8, 27), 8027);
        assertEq(harness.pack(0, 8, 29), 8029);
        vm.expectRevert(
            abi.encodeWithSelector(ReleaseReproducibility.UnexpectedSolcVersion.selector, uint256(8028), uint256(8027))
        );
        harness.validateCompiler(0, 8, 27, true, APPROVED_RUNS, true, EVM_HASH);
    }

    function test_Boundary_SingleLinkReferenceFails() public {
        vm.expectRevert(abi.encodeWithSelector(ReleaseReproducibility.UnexpectedLinkReference.selector, uint256(1)));
        harness.assertNoLinks(1);
    }

    // =========================================================================
    // Authorization (no privileged path: caller-invariance) and replay
    // =========================================================================

    function test_CallerInvariance_NoPrivilegedPath() public {
        bytes32[] memory sources = new bytes32[](1);
        sources[0] = keccak256("src");
        bytes32[] memory artifacts = new bytes32[](1);
        artifacts[0] = keccak256("bin");
        address alice = address(0xa11ce);
        address bob = address(0xb0b);
        vm.prank(alice);
        bytes32 fromAlice = harness.digest(8028, true, APPROVED_RUNS, true, EVM_HASH, sources, artifacts);
        vm.prank(bob);
        bytes32 fromBob = harness.digest(8028, true, APPROVED_RUNS, true, EVM_HASH, sources, artifacts);
        assertEq(fromAlice, fromBob);
        vm.prank(alice);
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, APPROVED_PATCH, true, APPROVED_RUNS, true, EVM_HASH);
        vm.prank(bob);
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, APPROVED_PATCH, true, APPROVED_RUNS, true, EVM_HASH);
    }

    function test_Replay_DigestIsDeterministic() public view {
        bytes32[] memory sources = new bytes32[](2);
        sources[0] = bytes32(uint256(11));
        sources[1] = bytes32(uint256(22));
        bytes32[] memory artifacts = new bytes32[](1);
        artifacts[0] = bytes32(uint256(33));
        bytes32 first = harness.digest(8028, true, APPROVED_RUNS, true, EVM_HASH, sources, artifacts);
        bytes32 second = harness.digest(8028, true, APPROVED_RUNS, true, EVM_HASH, sources, artifacts);
        assertEq(first, second);
        assertTrue(first != bytes32(0));
    }

    function test_Replay_DigestSensitiveToInputs() public view {
        bytes32[] memory sources = new bytes32[](1);
        sources[0] = bytes32(uint256(1));
        bytes32[] memory artifacts = new bytes32[](1);
        artifacts[0] = bytes32(uint256(2));
        bytes32 base = harness.digest(8028, true, APPROVED_RUNS, true, EVM_HASH, sources, artifacts);
        bytes32 drifted = harness.digest(8028, true, 201, true, EVM_HASH, sources, artifacts);
        assertTrue(base != drifted);
    }

    // =========================================================================
    // Single-settlement analog: one digest pin, no double pin, immutable
    // =========================================================================

    function test_PinDigest_SingleSettlement() public {
        bytes32 digest = keccak256("approved-release");
        pinHarness.pin(digest);
        assertEq(pinHarness.pinned(), digest);
        assertTrue(pinHarness.isPinned());
    }

    function test_PinDigest_RejectsDoublePin() public {
        bytes32 digest = keccak256("approved-release");
        pinHarness.pin(digest);
        vm.expectRevert(abi.encodeWithSelector(SinglePinHarness.AlreadyPinned.selector, digest));
        pinHarness.pin(keccak256("other-release"));
        assertEq(pinHarness.pinned(), digest);
    }

    function test_PinDigest_RejectsZeroDigest() public {
        vm.expectRevert(abi.encodeWithSelector(ReleaseReproducibility.EmptyBytecodeHash.selector, "digest"));
        pinHarness.pin(bytes32(0));
    }

    // =========================================================================
    // Approved manifest reconciliation (event/storage/ABI drift surface)
    // =========================================================================

    function test_Manifest_PinsApprovedToolchain() public view {
        string memory manifest = vm.readFile("deployments/releases/v2-sc-129-release-manifest.json");
        assertEq(manifest.readString(".toolchain.solc"), "0.8.28");
        assertEq(manifest.readString(".toolchain.evmVersion"), "cancun");
        assertTrue(manifest.readBool(".toolchain.viaIR"));
        assertTrue(manifest.readBool(".toolchain.optimizer.enabled"));
        assertEq(manifest.readUint(".toolchain.optimizer.runs"), 200);
        assertEq(manifest.readString(".protocolVersion"), "2.0.0");
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, APPROVED_PATCH, true, APPROVED_RUNS, true, EVM_HASH);
    }

    function test_Manifest_DigestWellFormed() public view {
        string memory manifest = vm.readFile("deployments/releases/v2-sc-129-release-manifest.json");
        bytes memory digest = bytes(manifest.readString(".manifestDigest"));
        assertEq(digest.length, 66);
        assertEq(digest[0], bytes1("0"));
        assertEq(digest[1], bytes1("x"));
    }

    // =========================================================================
    // Fuzz / invariant-style
    // =========================================================================

    function testFuzz_RejectsNonApprovedRuns(uint256 runs) public {
        vm.assume(runs != APPROVED_RUNS);
        vm.expectRevert(
            abi.encodeWithSelector(ReleaseReproducibility.UnexpectedOptimizerRuns.selector, APPROVED_RUNS, runs)
        );
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, APPROVED_PATCH, true, runs, true, EVM_HASH);
    }

    function testFuzz_RejectsNonApprovedPatch(uint256 patch) public {
        vm.assume(patch != APPROVED_PATCH && patch <= 999);
        uint256 code = 8000 + patch;
        vm.expectRevert(
            abi.encodeWithSelector(ReleaseReproducibility.UnexpectedSolcVersion.selector, uint256(8028), code)
        );
        harness.validateCompiler(APPROVED_MAJOR, APPROVED_MINOR, patch, true, APPROVED_RUNS, true, EVM_HASH);
    }

    function testFuzz_NonZeroLibraryPasses(address dependency) public view {
        vm.assume(dependency != address(0));
        harness.validateLibrary(dependency);
    }

    function testFuzz_NonZeroLinkCountReverts(uint256 count) public {
        vm.assume(count != 0);
        vm.expectRevert(abi.encodeWithSelector(ReleaseReproducibility.UnexpectedLinkReference.selector, count));
        harness.assertNoLinks(count);
    }

    function testFuzz_DigestSensitiveToRuns(uint256 a, uint256 b) public view {
        vm.assume(a != b);
        bytes32[] memory sources = new bytes32[](1);
        sources[0] = bytes32(uint256(7));
        bytes32[] memory artifacts = new bytes32[](1);
        artifacts[0] = bytes32(uint256(9));
        bytes32 first = harness.digest(8028, true, a, true, EVM_HASH, sources, artifacts);
        bytes32 second = harness.digest(8028, true, b, true, EVM_HASH, sources, artifacts);
        assertTrue(first != second);
    }

    function testFuzz_PackRejectsOversizedMinor(uint256 minor) public {
        vm.assume(minor > 999);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReleaseReproducibility.UnexpectedSolcVersion.selector, uint256(8028), type(uint256).max
            )
        );
        harness.pack(0, minor, 28);
    }
}
