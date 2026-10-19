// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { CanonicalEventLibrary } from "../../contracts/libraries/CanonicalEventLibrary.sol";
import { IUpgradeController } from "../../contracts/upgrade/IUpgradeController.sol";
import { UpgradeController } from "../../contracts/upgrade/UpgradeController.sol";
import { VersionRegistry } from "../../contracts/upgrade/VersionRegistry.sol";
import { StorageCompatibilityValidator } from "../../contracts/upgrade/StorageCompatibilityValidator.sol";
import { Create2AddressPlanner } from "../../contracts/deployment/Create2AddressPlanner.sol";
import { EncodePackedCommitmentVectors as V } from "../../contracts/test/EncodePackedCommitmentVectors.sol";
import { EIP712CanonicalVectors as E } from "../../contracts/test/EIP712CanonicalVectors.sol";

/// @title EncodePackedCommitmentsTest
/// @notice V2-SC-160 evidence suite for ambiguous packed-encoding commitments.
/// @dev Sections:
///        1. constructive collision fixtures for every unsafe pattern that was removed;
///        2. versioned V2 digests, checked against the live contracts and the vectors;
///        3. positive compatibility vectors for every retained fixed-width pattern;
///        4. fuzzed distinct-input / distinct-digest properties.
///      Every expected value comes from contracts/test/EncodePackedCommitmentVectors.sol, which
///      scripts/check-encode-packed-vectors.mjs keeps identical to the ethers-computed JSON
///      vectors (cross-tool evidence). The `_legacy*` helpers intentionally reproduce the
///      retired packed schemes; they are declared LEGACY_MIRROR in scripts/encode-packed-policy.json.
contract EncodePackedCommitmentsTest is Test {
    UpgradeController internal controller;
    VersionRegistry internal registry;
    StorageCompatibilityValidator internal validator;
    Create2AddressPlanner internal planner;

    function setUp() public {
        registry = new VersionRegistry(V.UPGRADE_PROPOSER);
        validator = new StorageCompatibilityValidator();
        controller = new UpgradeController(V.UPGRADE_PROPOSER, address(registry), address(validator));
        planner = new Create2AddressPlanner(address(this));

        vm.prank(V.UPGRADE_PROPOSER);
        controller.setCurrentImplementation(V.UPGRADE_TARGET, V.UPGRADE_CURRENT_IMPL);
    }

    // =========================================================================================
    // Retired packed schemes (LEGACY_MIRROR) and retained fixed-width mirrors
    // =========================================================================================

    function _legacyPackedPair(string memory left, string memory right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }

    function _legacyOperationId(string memory domain, uint256 nonce, address actor) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(domain, nonce, actor));
    }

    function _legacyProposalId(address target, address newImpl, string memory version, address proposer, uint256 ts)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked("UPGRADE", target, newImpl, version, proposer, ts));
    }

    function _legacyUpgradeHash(
        address target,
        address currentImpl,
        address newImpl,
        string memory version,
        uint8 upgradeType,
        uint256 ts
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(target, currentImpl, newImpl, version, upgradeType, ts));
    }

    function _legacyDelimitedRecord(string memory name, string memory version) internal pure returns (string memory) {
        return string(abi.encodePacked(name, "|", version));
    }

    /// @dev domain = "UPGRADE" || target || newImplementation || version, i.e. the prefix of the
    ///      retired proposal-id preimage that a caller-chosen operation domain can absorb.
    function _collidingDomain() internal pure returns (string memory) {
        return string(abi.encodePacked("UPGRADE", V.UPGRADE_TARGET, V.UPGRADE_NEW_IMPL, V.UPGRADE_VERSION));
    }

    function _merkleLeaf(address user, uint256 score, uint256 ts) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256(abi.encodePacked(user, score, ts))));
    }

    function _merkleNode(bytes32 leftNode, bytes32 rightNode) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(leftNode, rightNode));
    }

    function _appealLockId(uint256 claimId, uint256 roundIndex) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("V2_APPEAL_BOND", claimId, roundIndex)));
    }

    function _typedDataDigest(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _v2ProposalId(address target, address newImpl, string memory version, address proposer, uint256 ts)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(V.UPGRADE_PROPOSAL_ID_SCHEME_V2, target, newImpl, version, proposer, ts));
    }

    function _split(bytes memory data, uint256 at) internal pure returns (string memory head, string memory tail) {
        bytes memory h = new bytes(at);
        bytes memory t = new bytes(data.length - at);
        for (uint256 i = 0; i < at; i++) h[i] = data[i];
        for (uint256 i = at; i < data.length; i++) t[i - at] = data[i];
        return (string(h), string(t));
    }

    function _propose(string memory version) internal returns (bytes32) {
        vm.prank(V.UPGRADE_PROPOSER);
        return controller.proposeUpgrade(
            V.UPGRADE_TARGET, V.UPGRADE_NEW_IMPL, version, IUpgradeController.UpgradeType.STANDARD, bytes32(0)
        );
    }

    // =========================================================================================
    // 1. Constructive collision fixtures (unsafe patterns that were removed)
    // =========================================================================================

    /// @notice Two adjacent variable-length operands: ("ab","c") and ("a","bc") collide when
    ///         packed and separate under typed abi.encode.
    function test_collision_adjacentDynamicOperands() public pure {
        bytes32 left = _legacyPackedPair("ab", "c");
        bytes32 right = _legacyPackedPair("a", "bc");
        assertEq(left, right, "packed operands must collide");
        assertEq(left, V.PACKED_AB_C_DIGEST, "packed digest must equal keccak256('abc')");
        assertEq(left, keccak256(bytes("abc")));

        bytes32 typedLeft = keccak256(abi.encode(string("ab"), string("c")));
        bytes32 typedRight = keccak256(abi.encode(string("a"), string("bc")));
        assertEq(typedLeft, V.ENCODED_AB_C_DIGEST);
        assertEq(typedRight, V.ENCODED_A_BC_DIGEST);
        assertTrue(typedLeft != typedRight, "typed encoding must separate the operands");
    }

    /// @notice The retired V1 operation id reproduced the retired V1 upgrade proposal id byte for
    ///         byte; the V2 schemes separate them.
    function test_collision_crossSchema_operationIdVsUpgradeProposalId() public {
        string memory domain = _collidingDomain();
        uint256 nonce = (uint256(uint160(V.UPGRADE_PROPOSER)) << 96) | (V.UPGRADE_TIMESTAMP >> 160);
        address actor = address(uint160(V.UPGRADE_TIMESTAMP));
        assertEq(nonce, V.COLLIDING_OPERATION_NONCE);
        assertEq(actor, V.COLLIDING_OPERATION_ACTOR);

        bytes32 legacyProposal = _legacyProposalId(
            V.UPGRADE_TARGET, V.UPGRADE_NEW_IMPL, V.UPGRADE_VERSION, V.UPGRADE_PROPOSER, V.UPGRADE_TIMESTAMP
        );
        bytes32 legacyOperation = _legacyOperationId(domain, nonce, actor);
        assertEq(legacyProposal, V.LEGACY_UPGRADE_PROPOSAL_ID);
        assertEq(legacyOperation, legacyProposal, "retired schemes must collide across schemas");

        // V2: the live library and the live controller produce distinct ids for the same bytes.
        bytes32 v2Operation = CanonicalEventLibrary.computeOperationId(domain, nonce, actor);
        assertEq(v2Operation, V.COLLIDING_OPERATION_ID_V2);

        vm.warp(V.UPGRADE_TIMESTAMP);
        bytes32 v2Proposal = _propose(V.UPGRADE_VERSION);
        assertEq(v2Proposal, V.UPGRADE_PROPOSAL_ID_V2);
        assertTrue(v2Operation != v2Proposal, "V2 schemes must be domain separated");
        assertTrue(v2Operation != legacyOperation && v2Proposal != legacyProposal);
    }

    /// @notice Delimiter-joined records shift field boundaries when a field contains the
    ///         delimiter; SupplyChainAttestationAnchor now rejects such fields (see
    ///         test/v2/SupplyChainAttestationManifest.t.sol for the live rejection).
    function test_collision_delimiterShift() public pure {
        string memory left = _legacyDelimitedRecord("a|b", "c");
        string memory right = _legacyDelimitedRecord("a", "b|c");
        assertEq(keccak256(bytes(left)), keccak256(bytes(right)), "delimited records must collide");
        assertEq(left, "a|b|c");
    }

    // =========================================================================================
    // 2. Versioned V2 digests (changed schemes)
    // =========================================================================================

    function test_versioned_schemeTagsMatchVectors() public view {
        assertEq(CanonicalEventLibrary.OPERATION_ID_SCHEME_V2, V.OPERATION_ID_SCHEME_V2);
        assertEq(CanonicalEventLibrary.OPERATION_ID_SCHEME_V2, keccak256("TruthBounty.CanonicalEventLibrary.operationId.v2"));
        assertEq(controller.UPGRADE_HASH_SCHEME_V2(), V.UPGRADE_HASH_SCHEME_V2);
        assertEq(controller.UPGRADE_HASH_SCHEME_V2(), keccak256("TruthBounty.UpgradeController.upgradeHash.v2"));
        assertEq(controller.UPGRADE_PROPOSAL_ID_SCHEME_V2(), V.UPGRADE_PROPOSAL_ID_SCHEME_V2);
        assertEq(controller.UPGRADE_PROPOSAL_ID_SCHEME_V2(), keccak256("TruthBounty.UpgradeController.proposalId.v2"));
    }

    function test_versioned_operationIdV2MatchesVectorAndDiffersFromLegacy() public pure {
        bytes32 id = CanonicalEventLibrary.computeOperationId(V.OPERATION_DOMAIN, V.OPERATION_NONCE, V.OPERATION_ACTOR);
        assertEq(id, V.OPERATION_ID_V2);
        assertEq(
            id, keccak256(abi.encode(V.OPERATION_ID_SCHEME_V2, V.OPERATION_DOMAIN, V.OPERATION_NONCE, V.OPERATION_ACTOR))
        );
        assertEq(_legacyOperationId(V.OPERATION_DOMAIN, V.OPERATION_NONCE, V.OPERATION_ACTOR), V.OPERATION_ID_LEGACY);
        assertTrue(id != V.OPERATION_ID_LEGACY, "changed digest must not reinterpret a V1 id");
    }

    function test_versioned_upgradeIdsMatchVectorsAndDifferFromLegacy() public {
        vm.warp(V.UPGRADE_TIMESTAMP);
        bytes32 proposalId = _propose(V.UPGRADE_VERSION);
        IUpgradeController.UpgradeProposal memory proposal = controller.getProposal(proposalId);

        assertEq(proposalId, V.UPGRADE_PROPOSAL_ID_V2);
        assertEq(
            proposalId,
            _v2ProposalId(V.UPGRADE_TARGET, V.UPGRADE_NEW_IMPL, V.UPGRADE_VERSION, V.UPGRADE_PROPOSER, V.UPGRADE_TIMESTAMP)
        );
        assertEq(proposal.upgradeHash, V.UPGRADE_HASH_V2);
        assertEq(
            proposal.upgradeHash,
            keccak256(
                abi.encode(
                    V.UPGRADE_HASH_SCHEME_V2,
                    V.UPGRADE_TARGET,
                    V.UPGRADE_CURRENT_IMPL,
                    V.UPGRADE_NEW_IMPL,
                    V.UPGRADE_VERSION,
                    IUpgradeController.UpgradeType.STANDARD,
                    V.UPGRADE_TIMESTAMP
                )
            )
        );

        assertEq(
            _legacyUpgradeHash(
                V.UPGRADE_TARGET, V.UPGRADE_CURRENT_IMPL, V.UPGRADE_NEW_IMPL, V.UPGRADE_VERSION, 0, V.UPGRADE_TIMESTAMP
            ),
            V.LEGACY_UPGRADE_HASH
        );
        assertTrue(proposalId != V.LEGACY_UPGRADE_PROPOSAL_ID, "V2 proposal id must not alias a V1 id");
        assertTrue(proposal.upgradeHash != V.LEGACY_UPGRADE_HASH, "V2 upgrade hash must not alias a V1 hash");
    }

    /// @notice Structural non-reinterpretation: a V2 proposal-id preimage starts with the
    ///         32-byte scheme tag while every V1 preimage starts with ASCII "UPGRADE", so no V2
    ///         id can equal a V1 id (short of a keccak256 collision).
    function test_versioned_v2PreimageCannotMatchLegacyPrefix() public pure {
        assertTrue(bytes7(V.UPGRADE_PROPOSAL_ID_SCHEME_V2) != bytes7("UPGRADE"));
        assertTrue(V.OPERATION_ID_SCHEME_V2 != V.UPGRADE_PROPOSAL_ID_SCHEME_V2);
        assertTrue(V.OPERATION_ID_SCHEME_V2 != V.UPGRADE_HASH_SCHEME_V2);
        assertTrue(V.UPGRADE_HASH_SCHEME_V2 != V.UPGRADE_PROPOSAL_ID_SCHEME_V2);
    }

    // =========================================================================================
    // 3. Positive compatibility vectors (retained fixed-width patterns must not change)
    // =========================================================================================

    function test_retained_eip712TypedDataPrefix() public pure {
        bytes32 digest = _typedDataDigest(V.EIP712_DOMAIN_SEPARATOR, V.EIP712_STRUCT_HASH);
        assertEq(digest, V.EIP712_DIGEST);
        assertEq(digest, MessageHashUtils.toTypedDataHash(V.EIP712_DOMAIN_SEPARATOR, V.EIP712_STRUCT_HASH));
        // Same vector as the V2-SC-152 canonical suite.
        assertEq(V.EIP712_DOMAIN_SEPARATOR, E.DOMAIN_SEPARATOR_MAINNET);
        assertEq(V.EIP712_STRUCT_HASH, E.CLAIM_MAINNET_STRUCT_HASH);
        assertEq(V.EIP712_DIGEST, E.CLAIM_MAINNET_DIGEST);
    }

    function test_retained_reputationMerkleLeavesAndNode() public pure {
        bytes32 leafA = _merkleLeaf(V.MERKLE_USER_A, V.MERKLE_SCORE_A, V.MERKLE_TIMESTAMP);
        bytes32 leafB = _merkleLeaf(V.MERKLE_USER_B, V.MERKLE_SCORE_B, V.MERKLE_TIMESTAMP);
        assertEq(leafA, V.MERKLE_LEAF_A);
        assertEq(leafB, V.MERKLE_LEAF_B);
        assertEq(_merkleNode(leafA, leafB), V.MERKLE_NODE_AB);
        // Positional (unsorted) node hashing: swapping children changes the node.
        assertTrue(_merkleNode(leafB, leafA) != V.MERKLE_NODE_AB);
    }

    function test_retained_create2Eip1014Examples() public view {
        bytes memory initCode = hex"00";
        assertEq(keccak256(initCode), V.CREATE2_INIT_CODE_00_HASH);

        assertEq(planner.computeAddress(address(0), bytes32(0), V.CREATE2_INIT_CODE_00_HASH), V.CREATE2_EIP1014_EX0);
        assertEq(
            planner.computeAddress(V.CREATE2_EX1_DEPLOYER, bytes32(0), V.CREATE2_INIT_CODE_00_HASH), V.CREATE2_EIP1014_EX1
        );
        // Independent implementation (forge-std) agrees.
        assertEq(computeCreate2Address(bytes32(0), V.CREATE2_INIT_CODE_00_HASH, address(0)), V.CREATE2_EIP1014_EX0);
        assertEq(
            computeCreate2Address(bytes32(0), V.CREATE2_INIT_CODE_00_HASH, V.CREATE2_EX1_DEPLOYER), V.CREATE2_EIP1014_EX1
        );
    }

    function test_retained_create2DeriveSalt() public view {
        assertEq(V.CREATE2_MODULE_ID, keccak256("TruthBounty.ModuleRegistry"));
        assertEq(V.CREATE2_REVIEWED_SALT, keccak256("reviewed-salt-1"));
        assertEq(planner.deriveSalt(V.CREATE2_MODULE_ID, V.CREATE2_REVIEWED_SALT), V.CREATE2_DERIVED_SALT);
    }

    function test_retained_appealBondLockId() public pure {
        assertEq(_appealLockId(1, 0), uint256(V.APPEAL_LOCK_ID_1_0));
    }

    // =========================================================================================
    // 4. Fuzzed distinct-input / distinct-digest properties
    // =========================================================================================

    /// @notice For any byte string and any two distinct split points, the packed pair collides
    ///         while the typed pair does not — the ambiguity is structural, not a corner case.
    function testFuzz_splitPoint_packedCollides_typedSeparates(bytes memory data, uint256 i, uint256 j) public pure {
        if (data.length == 0) data = hex"01";
        i = bound(i, 0, data.length);
        j = bound(j, 0, data.length);
        if (i == j) j = (i + 1) % (data.length + 1);

        (string memory a1, string memory b1) = _split(data, i);
        (string memory a2, string memory b2) = _split(data, j);

        assertEq(_legacyPackedPair(a1, b1), _legacyPackedPair(a2, b2));
        assertTrue(keccak256(abi.encode(a1, b1)) != keccak256(abi.encode(a2, b2)));
    }

    function testFuzz_operationId_distinctInputs_distinctDigests(
        string memory d1,
        uint256 n1,
        address a1,
        string memory d2,
        uint256 n2,
        address a2
    ) public pure {
        vm.assume(keccak256(bytes(d1)) != keccak256(bytes(d2)) || n1 != n2 || a1 != a2);
        assertTrue(CanonicalEventLibrary.computeOperationId(d1, n1, a1) != CanonicalEventLibrary.computeOperationId(d2, n2, a2));
    }

    function testFuzz_operationId_v2NeverEqualsLegacy(string memory domain, uint256 nonce, address actor) public pure {
        assertTrue(CanonicalEventLibrary.computeOperationId(domain, nonce, actor) != _legacyOperationId(domain, nonce, actor));
    }

    function testFuzz_upgradeProposalId_distinctVersions_distinctDigests(string memory v1, string memory v2) public {
        vm.assume(bytes(v1).length > 0 && bytes(v2).length > 0);
        vm.assume(keccak256(bytes(v1)) != keccak256(bytes(v2)));
        vm.warp(V.UPGRADE_TIMESTAMP);

        bytes32 id1 = _propose(v1);
        bytes32 id2 = _propose(v2);
        assertTrue(id1 != id2, "distinct versions must yield distinct proposal ids");
        assertEq(controller.getProposal(id1).version, v1);
        assertEq(controller.getProposal(id2).version, v2);
        assertTrue(controller.getProposal(id1).upgradeHash != controller.getProposal(id2).upgradeHash);
    }

    function testFuzz_crossSchema_v2OperationIdNeverEqualsV2ProposalId(
        bytes memory domain,
        uint256 nonce,
        address actor,
        address target,
        string memory version,
        uint256 ts
    ) public pure {
        assertTrue(
            CanonicalEventLibrary.computeOperationId(string(domain), nonce, actor)
                != _v2ProposalId(target, V.UPGRADE_NEW_IMPL, version, actor, ts)
        );
    }

    function testFuzz_merkleLeaf_distinctInputs_distinctDigests(
        address u1,
        uint256 s1,
        uint256 t1,
        address u2,
        uint256 s2,
        uint256 t2
    ) public pure {
        vm.assume(u1 != u2 || s1 != s2 || t1 != t2);
        assertTrue(_merkleLeaf(u1, s1, t1) != _merkleLeaf(u2, s2, t2));
    }
}
