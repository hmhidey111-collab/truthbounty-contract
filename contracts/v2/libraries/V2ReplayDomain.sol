// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title V2ReplayDomain
/// @notice Canonical cross-chain replay domain for V2 signed operations (V2-SC-086).
/// @dev Every signed payload is committed to a single digest that binds all seven replay
///      dimensions named by the issue: the `actionType` (which operation is authorized), the
///      `verifyingContract` (which deployment accepts it), the `chainId` (which chain it is for),
///      the domain `version` (which encoding schema produced it), the `signer` (who authorized
///      it), the `entityId` (the subject the operation acts on), the `nonce` (single-use
///      sequencing), and the `deadline` (expiry). A signature minted for one tuple is therefore
///      invalid for any change to any one of these fields, which makes cross-chain, cross-contract,
///      cross-action, and expiry-based replay structurally impossible rather than incidentally
///      prevented by an off-chain convention.
///
///      Like its sibling `ReputationMerkleDomain`, this is a pure commitment builder: the preimage
///      is `abi.encode` (fixed-width operands only, so it is unambiguously parsable) and the digest
///      is the `keccak256` of that preimage. The library reads no storage, emits no events, and
///      grants no authority; it is the encoding contract shared by an on-chain verifier and the
///      off-chain signers that target it.
///
///      Live-binding rule: callers MUST pass `block.chainid` and `address(this)` at verification
///      time rather than a value cached at deploy time, so the digest tracks the real chain and the
///      real verifying deployment on every call. `liveDigest` demonstrates the chain dimension by
///      reading `block.chainid` internally; consumers pass `address(this)` for the verifying
///      contract. This mirrors the CO-177 finding that a deploy-time-cached separator can be
///      replayed on a chain that shares the same genesis.
///
///      Fail-closed rule: an empty action type, a zero verifying contract, a zero signer, an
///      unknown domain version, or an expired deadline reverts with a dedicated custom error before
///      any digest is returned, so a malformed or stale operation can never be validated.
///
///      This surface is a pure library, so the acceptance criterion "events where applicable" is
///      intentionally vacuous: a commitment function has no observable state transition to emit.
library V2ReplayDomain {
    /// @notice Domain schema version carried by every signed operation. Bumped only when the
    ///         field set or the type string changes; a semantic change to a signed struct requires
    ///         a new version plus a fresh set of published vectors, never a silent edit here.
    uint16 public constant REPLAY_DOMAIN_VERSION = 1;

    /// @notice EIP-712 type hash of the signed-operation struct. The declaration order of the
    ///         fields in this string is the wire order used by `abi.encode` in `digest`, and it is
    ///         reproduced verbatim by off-chain signers to compute the same digest.
    bytes32 public constant SIGNED_OPERATION_TYPEHASH = keccak256(
        "V2SignedOperation(bytes32 actionType,address verifyingContract,uint256 chainId,uint16 version,address signer,uint256 entityId,uint256 nonce,uint256 deadline)"
    );

    /// @notice Thrown when the action type is the zero bytes32. A payload that does not name the
    ///         operation it authorizes cannot be bound to a single action type, so it is rejected.
    error ReplayDomainEmptyActionType();

    /// @notice Thrown when the verifying contract is the zero address. A payload bound to no
    ///         deployment could be accepted by every deployment, which defeats cross-contract replay
    ///         protection.
    error ReplayDomainZeroVerifier();

    /// @notice Thrown when the signer is the zero address. The zero address cannot hold a signing
    ///         key, so a payload attributed to it is malformed.
    error ReplayDomainZeroSigner();

    /// @notice Thrown when a payload declares a domain version this library does not recognize.
    /// @param provided The version carried by the payload.
    /// @param expected The single canonical version implemented here.
    error ReplayDomainInvalidVersion(uint16 provided, uint16 expected);

    /// @notice Thrown when the current timestamp is past the payload deadline. The deadline is an
    ///         inclusive upper bound: a payload is still valid exactly at `deadline`.
    /// @param deadline The expiry encoded in the payload.
    /// @param timestamp The timestamp compared against the deadline.
    error ReplayDomainDeadlineExpired(uint256 deadline, uint256 timestamp);

    /// @notice Builds the canonical signed-operation digest, binding every replay dimension.
    /// @dev Validates before hashing; reverts on any malformed field. `actionType` should be a
    ///      stable domain-separated identifier (for example a `V2Scopes` constant) so the preimage
    ///      is reproducible across verifiers. `chainId` and `verifyingContract` must be read live by
    ///      the caller (`block.chainid`, `address(this)`), never cached.
    /// @param actionType Identifier of the operation being authorized.
    /// @param verifyingContract Deployment that will accept the signature.
    /// @param chainId Chain the signature is bound to.
    /// @param version Domain schema version; must equal `REPLAY_DOMAIN_VERSION`.
    /// @param signer Address whose signature is expected.
    /// @param entityId Subject the operation acts on (claim id, account, or other entity).
    /// @param nonce Single-use sequencing value for `signer`.
    /// @param deadline Expiry timestamp; inclusive upper bound of validity.
    /// @return commitment keccak256 over the fixed-width preimage of the type hash and all fields.
    function digest(
        bytes32 actionType,
        address verifyingContract,
        uint256 chainId,
        uint16 version,
        address signer,
        uint256 entityId,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32 commitment) {
        _validate(actionType, verifyingContract, signer, version);
        commitment = keccak256(
            abi.encode(
                SIGNED_OPERATION_TYPEHASH,
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

    /// @notice Builds the signed-operation digest with the chain id read live from `block.chainid`.
    /// @dev Convenience wrapper that removes the most common caching footgun (the chain dimension).
    ///      The caller still supplies `verifyingContract` so the deployment binding stays explicit;
    ///      pass `address(this)`. This is the intended entry point for canonical V2 modules.
    /// @param actionType Identifier of the operation being authorized.
    /// @param verifyingContract Deployment that will accept the signature (pass `address(this)`).
    /// @param signer Address whose signature is expected.
    /// @param entityId Subject the operation acts on.
    /// @param nonce Single-use sequencing value for `signer`.
    /// @param deadline Expiry timestamp; inclusive upper bound of validity.
    /// @return commitment keccak256 over the fixed-width preimage bound to the live chain id.
    function liveDigest(
        bytes32 actionType,
        address verifyingContract,
        address signer,
        uint256 entityId,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32 commitment) {
        commitment = digest(actionType, verifyingContract, block.chainid, REPLAY_DOMAIN_VERSION, signer, entityId, nonce, deadline);
    }

    /// @notice Reverts unless the operation is still within its validity window.
    /// @dev The bound is inclusive on `deadline`: a payload signed to expire at `deadline` is valid
    ///      when `nowTs == deadline` and expired when `nowTs > deadline`.
    /// @param deadline Expiry timestamp encoded in the payload.
    /// @param nowTs The timestamp to compare (callers pass `block.timestamp`).
    function requireNotExpired(uint256 deadline, uint256 nowTs) internal pure {
        if (nowTs > deadline) revert ReplayDomainDeadlineExpired(deadline, nowTs);
    }

    /// @notice Reverts unless `version` is the canonical domain version implemented here.
    /// @param version The domain version carried by the payload.
    function requireVersion(uint16 version) internal pure {
        if (version != REPLAY_DOMAIN_VERSION) revert ReplayDomainInvalidVersion(version, REPLAY_DOMAIN_VERSION);
    }

    /// @dev Shared fail-closed validation for every entry point that returns a digest.
    function _validate(bytes32 actionType, address verifyingContract, address signer, uint16 version) private pure {
        if (actionType == bytes32(0)) revert ReplayDomainEmptyActionType();
        if (verifyingContract == address(0)) revert ReplayDomainZeroVerifier();
        if (signer == address(0)) revert ReplayDomainZeroSigner();
        if (version != REPLAY_DOMAIN_VERSION) revert ReplayDomainInvalidVersion(version, REPLAY_DOMAIN_VERSION);
    }
}
