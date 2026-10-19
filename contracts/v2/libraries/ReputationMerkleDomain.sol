// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * Domain-separated reputation Merkle leaf encoding (V2-SC-064 / issue #446).
 * Binds leaves to chain, registry, schema version, epoch, subject, score, and expiry
 * to prevent cross-context proof reuse.
 */
library ReputationMerkleDomain {
    bytes32 internal constant LEAF_TYPEHASH = keccak256(
        "ReputationLeaf(uint256 chainId,address registry,uint256 schemaVersion,uint256 epoch,address subject,uint256 score,uint256 expiry)"
    );

    function leafHash(
        uint256 chainId,
        address registry,
        uint256 schemaVersion,
        uint256 epoch,
        address subject,
        uint256 score,
        uint256 expiry
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                LEAF_TYPEHASH,
                chainId,
                registry,
                schemaVersion,
                epoch,
                subject,
                score,
                expiry
            )
        );
    }

    function requireNotExpired(uint256 expiry, uint256 nowTs) internal pure {
        require(expiry == 0 || nowTs <= expiry, "REPUTATION_LEAF_EXPIRED");
    }
}
