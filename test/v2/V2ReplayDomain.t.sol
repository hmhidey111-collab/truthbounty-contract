// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import { V2ReplayDomain } from "../../contracts/v2/libraries/V2ReplayDomain.sol";
import { V2ReplayDomainHarness } from "../../contracts/test/V2ReplayDomainHarness.sol";

/// @title V2ReplayDomainTest
/// @notice V2-SC-086 acceptance suite for the cross-chain replay domain of signed operations.
/// @dev Sections mirror the issue's Technical Scope:
///        1. schema pinning (type hash + domain version),
///        2. Solidity-side digest parity against an independent keccak256(abi.encode(...)) oracle,
///        3. live chain and verifying-contract binding, proven by `vm.chainId` (cross-chain replay),
///        4. injectivity: every one of the replay dimensions changes the digest,
///        5. inclusive deadline bound,
///        6. fail-closed reverts for malformed or stale operations.
///      All positive vectors reuse the same action/deadline constants as the TypeScript suite
///      (test/V2ReplayDomain.test.ts) so the two harnesses prove byte-for-byte identical digests.
contract V2ReplayDomainTest is Test {
    V2ReplayDomainHarness internal harness;

    // Canonical positive vector, shared with the TypeScript suite.
    bytes32 internal constant ACTION = keccak256("verification_submission");
    bytes32 internal constant ALT_ACTION = keccak256("staking");
    address internal constant SIGNER = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    address internal constant ALT_SIGNER = address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
    uint256 internal constant ENTITY = 42;
    uint256 internal constant NONCE = 7;
    uint256 internal constant DEADLINE = 4102444800; // 2100-01-01
    uint256 internal constant CHAIN = 10; // optimism mainnet
    uint16 internal constant VERSION = 1;

    function setUp() public {
        harness = new V2ReplayDomainHarness();
    }

    /// @dev Independent oracle for the canonical digest, mirroring the library encoding exactly.
    function _oracleDigest(
        bytes32 actionType,
        address verifyingContract,
        uint256 chainId,
        uint16 version,
        address signer,
        uint256 entityId,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        bytes32 typehash = keccak256(
            "V2SignedOperation(bytes32 actionType,address verifyingContract,uint256 chainId,uint16 version,address signer,uint256 entityId,uint256 nonce,uint256 deadline)"
        );
        return keccak256(
            abi.encode(
                typehash,
                actionType,
                verifyingContract,
                chainId,
                version,
                signer,
                entityId,
                nonce,
                deadline
            )
        );
    }

    // =========================================================================================
    // 1. Schema pinning
    // =========================================================================================

    function test_typehashPinsCanonicalFieldOrder() public view {
        assertEq(harness.typehash(), V2ReplayDomain.SIGNED_OPERATION_TYPEHASH);
        assertEq(uint256(harness.domainVersion()), uint256(V2ReplayDomain.REPLAY_DOMAIN_VERSION));
        assertEq(uint256(harness.domainVersion()), 1);
    }

    // =========================================================================================
    // 2. Digest parity against an independent oracle
    // =========================================================================================

    function test_digestMatchesIndependentOracle() public view {
        bytes32 fromLibrary = harness.digest(ACTION, address(harness), CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE);
        bytes32 fromOracle = _oracleDigest(ACTION, address(harness), CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE);
        assertEq(fromLibrary, fromOracle);
    }

    // =========================================================================================
    // 3. Live chain and verifying-contract binding (cross-chain replay is structurally impossible)
    // =========================================================================================

    function test_liveDigestBindsBlockChainidAndDeployment() public {
        vm.chainId(CHAIN);
        bytes32 live = harness.liveDigest(ACTION, SIGNER, ENTITY, NONCE, DEADLINE);
        bytes32 explicit = harness.digest(ACTION, address(harness), CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE);
        assertEq(live, explicit, "liveDigest must equal the explicit digest on the same chain");

        // A signature minted for chain 10 must not verify on chain 1.
        vm.chainId(1);
        bytes32 replayedElsewhere = harness.liveDigest(ACTION, SIGNER, ENTITY, NONCE, DEADLINE);
        assertTrue(live != replayedElsewhere, "cross-chain replay must produce a different digest");
    }

    // =========================================================================================
    // 4. Injectivity: each replay dimension changes the digest
    // =========================================================================================

    function test_eachDimensionChangesDigest() public view {
        address vc = address(harness);
        bytes32 base = harness.digest(ACTION, vc, CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE);

        assertTrue(harness.digest(ALT_ACTION, vc, CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE) != base, "actionType");
        assertTrue(harness.digest(ACTION, address(0xBEEF), CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE) != base, "verifyingContract");
        assertTrue(harness.digest(ACTION, vc, 42161, VERSION, SIGNER, ENTITY, NONCE, DEADLINE) != base, "chainId");
        assertTrue(harness.digest(ACTION, vc, CHAIN, VERSION, ALT_SIGNER, ENTITY, NONCE, DEADLINE) != base, "signer");
        assertTrue(harness.digest(ACTION, vc, CHAIN, VERSION, SIGNER, ENTITY + 1, NONCE, DEADLINE) != base, "entityId");
        assertTrue(harness.digest(ACTION, vc, CHAIN, VERSION, SIGNER, ENTITY, NONCE + 1, DEADLINE) != base, "nonce");
        assertTrue(harness.digest(ACTION, vc, CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE + 1) != base, "deadline");
    }

    function testFuzz_changingNonceBindsUniquely(bytes32 actionType, address signer, uint256 entityId, uint256 nonce, uint256 deadline)
        public
        view
    {
        // Sanitize to valid (non-reverting) inputs so the fuzz exercises digest distinctness, not guards.
        bytes32 act = actionType == bytes32(0) ? bytes32(uint256(1)) : actionType;
        address sgn = signer == address(0) ? address(1) : signer;
        uint256 other = nonce == type(uint256).max ? nonce - 1 : nonce + 1;

        bytes32 a = harness.digest(act, address(harness), CHAIN, VERSION, sgn, entityId, nonce, deadline);
        bytes32 b = harness.digest(act, address(harness), CHAIN, VERSION, sgn, entityId, other, deadline);
        assertTrue(a != b, "distinct nonces must produce distinct digests");
    }

    // =========================================================================================
    // 5. Inclusive deadline bound
    // =========================================================================================

    function test_deadlineIsInclusiveUpperBound() public {
        harness.requireNotExpired(DEADLINE, DEADLINE); // exactly at the bound is valid
        harness.requireNotExpired(DEADLINE, DEADLINE - 1); // before the bound is valid

        vm.expectRevert(abi.encodeWithSelector(V2ReplayDomain.ReplayDomainDeadlineExpired.selector, DEADLINE, DEADLINE + 1));
        harness.requireNotExpired(DEADLINE, DEADLINE + 1);
    }

    // =========================================================================================
    // 6. Fail-closed guards
    // =========================================================================================

    function test_revertOnEmptyActionType() public {
        vm.expectRevert(V2ReplayDomain.ReplayDomainEmptyActionType.selector);
        harness.digest(bytes32(0), address(harness), CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE);
    }

    function test_revertOnZeroVerifier() public {
        vm.expectRevert(V2ReplayDomain.ReplayDomainZeroVerifier.selector);
        harness.digest(ACTION, address(0), CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE);
    }

    function test_revertOnZeroSigner() public {
        vm.expectRevert(V2ReplayDomain.ReplayDomainZeroSigner.selector);
        harness.digest(ACTION, address(harness), CHAIN, VERSION, address(0), ENTITY, NONCE, DEADLINE);
    }

    function test_revertOnUnknownVersion() public {
        vm.expectRevert(abi.encodeWithSelector(V2ReplayDomain.ReplayDomainInvalidVersion.selector, uint16(9), uint16(1)));
        harness.digest(ACTION, address(harness), CHAIN, uint16(9), SIGNER, ENTITY, NONCE, DEADLINE);
    }

    function test_requireVersionFailsClosed() public {
        vm.expectRevert(abi.encodeWithSelector(V2ReplayDomain.ReplayDomainInvalidVersion.selector, uint16(2), uint16(1)));
        harness.requireVersion(uint16(2));
    }
}
