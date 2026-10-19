// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title EncodePackedCommitmentVectors
/// @notice Solidity mirror of test/vectors/encode-packed-commitments.vectors.json (V2-SC-160).
/// @dev Test-only constants. Every value is recomputed with ethers by
///      scripts/check-encode-packed-vectors.mjs and checked against the live contracts by
///      test/v2/EncodePackedCommitments.t.sol. Edit the JSON first, then this mirror.
library EncodePackedCommitmentVectors {
    // ---- V2-SC-160 scheme tags ----
    bytes32 internal constant OPERATION_ID_SCHEME_V2 = 0x8c64e5c5cfa178c0038b286a8308bc8123d76ea44174910a08ded4a9b9cf443e;
    bytes32 internal constant UPGRADE_HASH_SCHEME_V2 = 0x811553cc20c92c3707264c87d19f1ed9f2ca671214b9d6a3ecc419c6a7523b5c;
    bytes32 internal constant UPGRADE_PROPOSAL_ID_SCHEME_V2 = 0x22015412ba7af32cf094b083b6dc19f23039090bf7813354d4d610afddfc54e4;

    // ---- collision fixture: adjacent dynamic strings ("ab","c") vs ("a","bc") ----
    bytes32 internal constant PACKED_AB_C_DIGEST = 0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45;
    bytes32 internal constant ENCODED_AB_C_DIGEST = 0x8c98d57214b9f76c3240d1fc677eb9fc1529ec2a4f56949bb6abe31d50b4b7c6;
    bytes32 internal constant ENCODED_A_BC_DIGEST = 0x68cd083d4c97fcbd081751d5390da5b37f5c485fd0879180d4816c456e8e532c;

    // ---- upgrade-controller fixture inputs ----
    address internal constant UPGRADE_TARGET = 0x0000000000000000000000000000000000000100;
    address internal constant UPGRADE_NEW_IMPL = 0x0000000000000000000000000000000000000200;
    address internal constant UPGRADE_CURRENT_IMPL = 0x0000000000000000000000000000000000000300;
    address internal constant UPGRADE_PROPOSER = 0x0000000000000000000000000000000000000001;
    string internal constant UPGRADE_VERSION = "1.0.0";
    uint256 internal constant UPGRADE_TIMESTAMP = 1700000000;

    // ---- upgrade-controller digests (retired V1 packed vs V2 typed) ----
    bytes32 internal constant LEGACY_UPGRADE_PROPOSAL_ID = 0x2ef83327175faaa58db707d67d66e94f36313b5b3189a20d80d969881c6033b3;
    bytes32 internal constant LEGACY_UPGRADE_HASH = 0x36a179d16a23259fedfaceb62719c4b0cfc8c3ae56617e221fb3906bc879533a;
    bytes32 internal constant UPGRADE_PROPOSAL_ID_V2 = 0x93eb8e998bd92e62312bac5c251fa484735589510ee38c01de4ec82ff4de18bc;
    bytes32 internal constant UPGRADE_HASH_V2 = 0x56bea276f375065927572197cc18eca4b3ba703e84bc2b41c01a2b4a89be090c;

    // ---- cross-schema collision: V1 operation id reproducing the V1 proposal id ----
    uint256 internal constant COLLIDING_OPERATION_NONCE = 79228162514264337593543950336;
    address internal constant COLLIDING_OPERATION_ACTOR = 0x000000000000000000000000000000006553F100;
    bytes32 internal constant COLLIDING_OPERATION_ID_V2 = 0x18e2bd11254229c836a6cd9cb970a8dc8d35dd6f4f91879616f0bf18024b245a;

    // ---- operation-id fixture ----
    string internal constant OPERATION_DOMAIN = "TREASURY_TRANSFER";
    uint256 internal constant OPERATION_NONCE = 7;
    address internal constant OPERATION_ACTOR = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    bytes32 internal constant OPERATION_ID_V2 = 0xb04f0d6ca05d779e0cb5cd55cfa720b3f29fba0866fcdfb9077030efd31acdce;
    bytes32 internal constant OPERATION_ID_LEGACY = 0x50cd82ce731115d88a9a49b58792e309ffbbc7b4a8df7b35fd95f4cd7b49e73a;

    // ---- retained: EIP-712 typed-data prefix (V2-SC-152 claim-submission-mainnet) ----
    bytes32 internal constant EIP712_DOMAIN_SEPARATOR = 0x3eb1639b71106693914d735157d11474bfdb60ffd5b896fb8311b7a8c9998b11;
    bytes32 internal constant EIP712_STRUCT_HASH = 0xc6398127fdbb4a3bd776eb683a6569078a2cfd1eb0bac2b44714d05a733ee96c;
    bytes32 internal constant EIP712_DIGEST = 0xbb5a29bd1e537284bc2631d86375fd606d16aaf7bb45144fd39eeea665a8cdb7;

    // ---- retained: reputation Merkle leaves and node ----
    address internal constant MERKLE_USER_A = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 internal constant MERKLE_SCORE_A = 750;
    address internal constant MERKLE_USER_B = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 internal constant MERKLE_SCORE_B = 420;
    uint256 internal constant MERKLE_TIMESTAMP = 1700000000;
    bytes32 internal constant MERKLE_LEAF_A = 0x5f4d2c9c957379c6f6c653d1ede2852067b2f9bb917f443ff43830dfbc36617e;
    bytes32 internal constant MERKLE_LEAF_B = 0x35a17e0d0499b2cf6c72cd171b0833ffb05db4990aa50902dedab8fc537342d3;
    bytes32 internal constant MERKLE_NODE_AB = 0x1102396d83afab8d5d9d9fd04b0092fb3a7107da629322894fe727b274094d5f;

    // ---- retained: CREATE2 (EIP-1014 published examples) and salt derivation ----
    bytes32 internal constant CREATE2_INIT_CODE_00_HASH = 0xbc36789e7a1e281436464229828f817d6612f7b477d66591ff96a9e064bcc98a;
    address internal constant CREATE2_EX1_DEPLOYER = 0xdEADBEeF00000000000000000000000000000000;
    address internal constant CREATE2_EIP1014_EX0 = 0x4D1A2e2bB4F88F0250f26Ffff098B0b30B26BF38;
    address internal constant CREATE2_EIP1014_EX1 = 0xB928f69Bb1D91Cd65274e3c79d8986362984fDA3;
    bytes32 internal constant CREATE2_MODULE_ID = 0x63c43e26c2cd8dbdeb207363b5fc64f11bc49c2ef7986e441831d8ecf47fde6a;
    bytes32 internal constant CREATE2_REVIEWED_SALT = 0xb536522237efc0e1288fd596380074b31b96e4cae77fc9f8ff5f7e78418fd223;
    bytes32 internal constant CREATE2_DERIVED_SALT = 0x0d1f0dec3426cfde7dcdea9d16fd20dfa258ddd232c47781d2c6d0c30c91e74d;

    // ---- retained: appeal-bond vault lock id (claimId = 1, roundIndex = 0) ----
    bytes32 internal constant APPEAL_LOCK_ID_1_0 = 0xacb1e16f53c23624eaa5626a9fc6ba0e08035da5a3813a40136faf5a2e958575;
}
