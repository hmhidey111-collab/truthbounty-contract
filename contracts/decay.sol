// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ContractSignerValidation} from "./libraries/ContractSignerValidation.sol";

/**
 * @title EIP712Verifier
 * @notice Implements EIP-712 typed structured data signing for off-chain message validation.
 * @dev Provides secure off-chain signatures with replay protection for claims and verifications.
 *
 *  ╔══════════════════════════════════════════════════════════════════════════════╗
 *  ║  AUDIT FIX — CO-177: EIP-712 ChainID Mismatch                              ║
 *  ║                                                                              ║
 *  ║  Root cause: The previous version inherited OpenZeppelin's abstract EIP712   ║
 *  ║  base contract, which caches the domain separator at construction time.      ║
 *  ║  On a hard-fork or cross-chain deployment that reuses contract state, the    ║
 *  ║  cached separator could diverge from the actual `block.chainid`, making     ║
 *  ║  signatures valid on the wrong chain (cross-chain replay attack surface).    ║
 *  ║                                                                              ║
 *  ║  Fix: Domain separator is now built on-the-fly using `block.chainid` every  ║
 *  ║  time it is required.  The domain type-hash, name-hash, and version-hash     ║
 *  ║  are stored as immutable values for gas efficiency; only `block.chainid`     ║
 *  ║  and `address(this)` are read dynamically.                                  ║
 *  ╚══════════════════════════════════════════════════════════════════════════════╝
 */
contract EIP712Verifier {
    using ECDSA for bytes32;
    using ContractSignerValidation for address;

    // ============ EIP-712 Domain ============

    /// @dev keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 private constant _DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev Precomputed keccak256(bytes("TruthBounty")) — immutable for gas savings.
    bytes32 private immutable _HASHED_NAME;

    /// @dev Precomputed keccak256(bytes("1")) — immutable for gas savings.
    bytes32 private immutable _HASHED_VERSION;

    // ============ Type Hashes ============

    uint256 internal constant MAX_SIGNATURE_BYTES = 65;
    uint256 internal constant MAX_REASON_BYTES = 256;

    bytes32 public constant CLAIM_SUBMISSION_TYPEHASH = keccak256(
        "ClaimSubmission(address claimant,uint256 bountyId,bytes32 contentHash,uint256 nonce,uint256 deadline)"
    );

    bytes32 public constant VERIFICATION_INTENT_TYPEHASH = keccak256(
        "VerificationIntent(address verifier,uint256 bountyId,bool approve,string reason,uint256 nonce,uint256 deadline)"
    );

    // ============ State ============

    /// @notice Nonces for replay protection per address.
    mapping(address => uint256) public nonces;

    /// @notice Tracks used digest hashes to prevent signature replay.
    mapping(bytes32 => bool) public usedSignatures;

    // ============ Events ============

    event ClaimSubmissionVerified(
        address indexed claimant,
        uint256 indexed bountyId,
        bytes32 contentHash,
        uint256 nonce
    );

    event VerificationIntentVerified(
        address indexed verifier,
        uint256 indexed bountyId,
        bool approve,
        uint256 nonce
    );

    // ============ Errors ============

    error InvalidSignature();
    error SignatureExpired();
    error ReasonTooLong(uint256 actual, uint256 maximum);
    error SignatureAlreadyUsed();
    error InvalidNonce();

    // ============ Constructor ============

    constructor() {
        _HASHED_NAME    = keccak256(bytes("TruthBounty"));
        _HASHED_VERSION = keccak256(bytes("1"));
    }

    // ============ Internal — Domain Separator ============

    /**
     * @dev Builds the EIP-712 domain separator using the *current* `block.chainid`.
     *
     *  Why not cache it?
     *  ─────────────────
     *  Caching the domain separator at deploy-time is safe only when the contract is
     *  guaranteed to never be replayed on a chain with a different chain-id.  In
     *  practice, contracts are sometimes redeployed at the same address on test-nets,
     *  forked networks, or Layer-2s that share the same genesis.  Using `block.chainid`
     *  directly ensures the separator is always correct for the network executing the
     *  transaction, making cross-chain signature replay impossible.
     *
     *  Gas note: The extra keccak256 call costs ~300 gas per verification call —
     *  an acceptable trade-off for the security guarantee.
     */
    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_TYPE_HASH,
                _HASHED_NAME,
                _HASHED_VERSION,
                block.chainid,   // <── live value, never stale
                address(this)
            )
        );
    }

    /**
     * @dev Returns the EIP-712 typed-data hash for `structHash` bound to this
     *      contract's domain.
     */
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _buildDomainSeparator(), structHash));
    }

    // ============ External — Verification ============

    /**
     * @notice Verifies a claim submission signature.
        * @dev Accepts an ECDSA signature from an EOA or a bounded ERC-1271 response from a contract claimant.
     * @param claimant     The address making the claim.
     * @param bountyId     The ID of the bounty being claimed.
     * @param contentHash  Hash of the claim content.
     * @param deadline     Signature expiration timestamp (unix seconds).
     * @param signature    The EIP-712 signature bytes.
     * @return True if the signature is valid; reverts otherwise.
     */
    function verifyClaimSubmission(
        address claimant,
        uint256 bountyId,
        bytes32 contentHash,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bool) {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (signature.length > MAX_SIGNATURE_BYTES) revert InvalidSignature();

        uint256 currentNonce = nonces[claimant];

        bytes32 structHash = keccak256(abi.encode(
            CLAIM_SUBMISSION_TYPEHASH,
            claimant,
            bountyId,
            contentHash,
            currentNonce,
            deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);

        if (usedSignatures[digest]) revert SignatureAlreadyUsed();

        if (claimant.code.length == 0) {
            if (digest.recover(signature) != claimant) revert InvalidSignature();
        } else if (!claimant.isValidContractSignature(digest, signature)) {
            revert InvalidSignature();
        }

        usedSignatures[digest] = true;
        nonces[claimant] = currentNonce + 1;

        emit ClaimSubmissionVerified(claimant, bountyId, contentHash, currentNonce);

        return true;
    }

    /**
     * @notice Verifies a verification intent signature.
        * @dev Accepts an ECDSA signature from an EOA or a bounded ERC-1271 response from a contract verifier.
     * @param verifier   The address of the verifier.
     * @param bountyId   The ID of the bounty being verified.
     * @param approve    Whether the verifier approves the claim.
     * @param reason     The reason for the verification decision.
     * @param deadline   Signature expiration timestamp (unix seconds).
     * @param signature  The EIP-712 signature bytes.
     * @return True if the signature is valid; reverts otherwise.
     */
    function verifyVerificationIntent(
        address verifier,
        uint256 bountyId,
        bool approve,
        string calldata reason,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bool) {
        if (block.timestamp > deadline) revert SignatureExpired();
        _requireReasonBound(reason);
        if (signature.length > MAX_SIGNATURE_BYTES) revert InvalidSignature();

        uint256 currentNonce = nonces[verifier];

        bytes32 structHash = keccak256(abi.encode(
            VERIFICATION_INTENT_TYPEHASH,
            verifier,
            bountyId,
            approve,
            keccak256(bytes(reason)),
            currentNonce,
            deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);

        if (usedSignatures[digest]) revert SignatureAlreadyUsed();

        if (verifier.code.length == 0) {
            if (digest.recover(signature) != verifier) revert InvalidSignature();
        } else if (!verifier.isValidContractSignature(digest, signature)) {
            revert InvalidSignature();
        }

        usedSignatures[digest] = true;
        nonces[verifier] = currentNonce + 1;

        emit VerificationIntentVerified(verifier, bountyId, approve, currentNonce);

        return true;
    }

    // ============ External — View Helpers ============

    /**
     * @notice Returns the current nonce for an address.
     * @param account The address to query.
     * @return The current nonce.
     */
    function getNonce(address account) external view returns (uint256) {
        return nonces[account];
    }

    /**
     * @notice Returns the domain separator computed for the *current* chain.
     * @dev    Always reflects `block.chainid`; never returns a stale cached value.
     * @return The EIP-712 domain separator.
     */
    function getDomainSeparator() external view returns (bytes32) {
        return _buildDomainSeparator();
    }

    /**
     * @notice Returns the current chain ID embedded in the domain separator.
     * @dev    Useful for off-chain clients to confirm they are on the right network.
     * @return The current chain ID (`block.chainid`).
     */
    function getChainId() external view returns (uint256) {
        return block.chainid;
    }

    /**
     * @notice Computes the typed-data hash for a claim submission (for off-chain signing).
     * @param claimant     The address making the claim.
     * @param bountyId     The ID of the bounty being claimed.
     * @param contentHash  Hash of the claim content.
     * @param nonce        The nonce for replay protection.
     * @param deadline     Signature expiration timestamp.
     * @return The EIP-712 typed-data hash to be signed.
     */
    function getClaimSubmissionHash(
        address claimant,
        uint256 bountyId,
        bytes32 contentHash,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            CLAIM_SUBMISSION_TYPEHASH,
            claimant,
            bountyId,
            contentHash,
            nonce,
            deadline
        ));
        return _hashTypedDataV4(structHash);
    }

    function _requireReasonBound(string calldata reason) private pure {
        uint256 actual = bytes(reason).length;
        if (actual > MAX_REASON_BYTES) revert ReasonTooLong(actual, MAX_REASON_BYTES);
    }

    /**
     * @notice Computes the typed-data hash for a verification intent (for off-chain signing).
     * @param verifier   The address of the verifier.
     * @param bountyId   The ID of the bounty being verified.
     * @param approve    Whether the verifier approves.
     * @param reason     The reason for the decision.
     * @param nonce      The nonce for replay protection.
     * @param deadline   Signature expiration timestamp.
     * @return The EIP-712 typed-data hash to be signed.
     */
    function getVerificationIntentHash(
        address verifier,
        uint256 bountyId,
        bool approve,
        string calldata reason,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            VERIFICATION_INTENT_TYPEHASH,
            verifier,
            bountyId,
            approve,
            keccak256(bytes(reason)),
            nonce,
            deadline
        ));
        return _hashTypedDataV4(structHash);
    }

    /**
     * @notice Checks whether a digest has already been consumed.
     * @param signatureHash The digest (result of `_hashTypedDataV4`) to check.
     * @return True if the digest has been used.
     */
    function isSignatureUsed(bytes32 signatureHash) external view returns (bool) {
        return usedSignatures[signatureHash];
    }
}
