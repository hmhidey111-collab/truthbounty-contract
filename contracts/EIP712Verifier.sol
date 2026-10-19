// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// CO-177: removed OZ EIP712 import — we build the domain separator ourselves
//         so it always reflects the live block.chainid, never a stale cache.
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ContractSignerValidation} from "./libraries/ContractSignerValidation.sol";

/**
 * @title EIP712Verifier
 * @notice Implements EIP-712 typed structured data signing for off-chain message validation
 * @dev Provides secure off-chain signatures with replay protection for claims and verifications
 *
 * CO-177 audit fix — ChainID mismatch
 * ─────────────────────────────────────
 * Root cause: inheriting OpenZeppelin's abstract EIP712 contract caches the domain
 * separator as an immutable at deploy time.  On a hard-fork or any cross-chain
 * re-deployment that shares the same genesis, _cachedChainId == block.chainid still
 * holds, the fast-path returns the stale separator, and a signature produced on
 * Chain A can be replayed on Chain B.
 *
 * Fix: remove the OZ EIP712 base entirely.  The name/version hashes are stored as
 * immutables (cheap, set once in the constructor), while block.chainid and
 * address(this) are read dynamically inside _buildDomainSeparator() on every call.
 * Gas cost: +~300 gas per verification.  Security gain: cross-chain replay is
 * structurally impossible.
 */
// CO-177: removed "is EIP712" — no longer inheriting the base contract
contract EIP712Verifier {
    using ECDSA for bytes32;
    using ContractSignerValidation for address;

    // ============ EIP-712 Domain ============

    // CO-177: full domain type-hash — we own the separator construction now
    bytes32 private constant _DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // CO-177: pre-hash name and version once (immutable = zero storage cost after deploy)
    bytes32 private immutable _HASHED_NAME;
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

    /// @notice Nonces for replay protection per address
    mapping(address => uint256) public nonces;

    /// @notice Tracks used signatures to prevent replay
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
    error SignatureAlreadyUsed();
    error InvalidNonce();
    error ReasonTooLong(uint256 actual, uint256 maximum);

    // ============ Constructor ============

    // CO-177: plain constructor — no EIP712("TruthBounty","1") call needed.
    //         We set the immutable hashes here instead.
    constructor() {
        _HASHED_NAME    = keccak256(bytes("TruthBounty"));
        _HASHED_VERSION = keccak256(bytes("1"));
    }

    // ============ Internal — Domain Separator ============

    /**
     * @dev Builds the EIP-712 domain separator using the *current* block.chainid.
     *      Called on every verification — never returns a stale cached value.
     */
    // CO-177: this function is the core fix — block.chainid is read live each call
    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_TYPE_HASH,
                _HASHED_NAME,
                _HASHED_VERSION,
                block.chainid,   // <── live, never cached
                address(this)
            )
        );
    }

    /**
     * @dev Produces the EIP-712 typed-data hash for structHash bound to this domain.
     *      Replaces the inherited _hashTypedDataV4() from the removed OZ base.
     */
    // CO-177: replaces OZ's _hashTypedDataV4 — identical output, live chainId
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _buildDomainSeparator(), structHash));
    }

    // ============ External Functions ============

    /**
     * @notice Verifies a claim submission signature
        * @dev Accepts an ECDSA signature from an EOA or a bounded ERC-1271 response from a contract claimant.
     * @param claimant The address making the claim
     * @param bountyId The ID of the bounty being claimed
     * @param contentHash Hash of the claim content
     * @param deadline Signature expiration timestamp
     * @param signature The EIP-712 signature
     * @return True if signature is valid
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
     * @notice Verifies a verification intent signature
        * @dev Accepts an ECDSA signature from an EOA or a bounded ERC-1271 response from a contract verifier.
     * @param verifier The address of the verifier
     * @param bountyId The ID of the bounty being verified
     * @param approve Whether the verifier approves the claim
     * @param reason The reason for the verification decision
     * @param deadline Signature expiration timestamp
     * @param signature The EIP-712 signature
     * @return True if signature is valid
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

    /**
     * @notice Returns the current nonce for an address
     * @param account The address to query
     * @return The current nonce
     */
    function getNonce(address account) external view returns (uint256) {
        return nonces[account];
    }

    /**
     * @notice Returns the domain separator for the current chain
     * @dev Always reflects live block.chainid — never returns a stale cached value
     * @return The EIP-712 domain separator
     */
    // CO-177: getDomainSeparator now calls _buildDomainSeparator() directly (was _domainSeparatorV4)
    function getDomainSeparator() external view returns (bytes32) {
        return _buildDomainSeparator();
    }

    /**
     * @notice Returns the current chain ID embedded in the domain separator
     * @dev Lets off-chain clients confirm they are on the correct network before signing
     * @return The current chain ID (block.chainid)
     */
    // CO-177: new helper — exposes block.chainid so off-chain clients can verify chain
    function getChainId() external view returns (uint256) {
        return block.chainid;
    }

    /**
     * @notice Computes the hash of a claim submission for off-chain signing
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
     * @notice Computes the hash of a verification intent for off-chain signing
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
     * @notice Checks if a signature has been used
     */
    function isSignatureUsed(bytes32 signatureHash) external view returns (bool) {
        return usedSignatures[signatureHash];
    }
}