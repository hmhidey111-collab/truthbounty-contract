// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SignatureNonces} from "./SignatureNonces.sol";
import {V2ReplayDomain} from "./libraries/V2ReplayDomain.sol";

/// @title VerificationCommitReveal
/// @notice PREWAVE-SC-085: a verifier's commitment can be revealed exactly once. A second reveal, a
///         changed decision or rationale, a wrong salt / verifier / round, and a replayed signature
///         are all rejected without touching stored state.
/// @dev Each `(verifier, claimId, roundId)` slot holds at most one commitment for its whole life:
///      `commit` can never overwrite it and `reveal` moves it `Committed -> Revealed` once.
///      Commitments use `abi.encode` (never `abi.encodePacked`) and bind chain id, release version,
///      this contract, the verifier, claim, round, decision, rationale hash, salt and deadline.
///      Events preserve privacy until reveal (only the commitment hash is emitted on commit) and
///      never emit the salt. A revert rolls back everything, so a failed reveal leaves the
///      commitment (and any signature nonce) exactly as it was.
///      This is a self-contained building block: it does not change any existing V2 module.
contract VerificationCommitReveal is SignatureNonces {
    /// @notice Lifecycle of one commitment slot.
    enum Status {
        None,
        Committed,
        Revealed
    }

    /// @notice Stored state of one commitment slot.
    struct Record {
        Status status;
        bytes32 commitment;
        bool decision; // only meaningful once status == Revealed
        bytes32 rationaleHash; // only meaningful once status == Revealed
        uint64 committedAt;
        uint64 revealedAt;
        uint64 deadline; // commit deadline bound to this commitment for temporal replay protection
    }

    /// @notice Pinned protocol release version for cross-release replay protection.
    ///         Frozen at deployment; all commitments must bind to this release domain.
    bytes32 public constant RELEASE_VERSION = keccak256("TruthBounty-V2.0.0-cancun");

    /// @notice Domain tag mixed into every commitment. Includes release version and deadline
    ///         so commitments are unambiguously bound to a single release and time window.
    bytes32 public constant COMMITMENT_TYPEHASH = keccak256(
        "VerificationCommitment(uint256 chainId,bytes32 releaseVersion,address verifyingContract,address verifier,uint256 claimId,uint256 roundId,uint64 deadline,bool decision,bytes32 rationaleHash,bytes32 salt)"
    );

    /// @notice Replay-domain action type for relayed (signed) reveals.
    bytes32 public constant REVEAL_ACTION = keccak256("verification_reveal");

    /// @notice Minimum deadline buffer (1 hour) to prevent premature expiry under sequencer drift.
    uint64 public constant MIN_DEADLINE_BUFFER = 1 hours;

    /// @notice Maximum deadline horizon (365 days) to prevent infinitely far futures.
    uint64 public constant MAX_DEADLINE_HORIZON = 365 days;

    /// @dev key = keccak256(abi.encode(verifier, claimId, roundId))
    mapping(bytes32 => Record) private _records;

    /// @notice Emitted on commit. Carries only the hash, so the decision stays private.
    event Committed(address indexed verifier, uint256 indexed claimId, uint256 indexed roundId, bytes32 commitment);

    /// @notice Emitted once per commitment, when it is revealed. Never includes the salt.
    event Revealed(
        address indexed verifier,
        uint256 indexed claimId,
        uint256 indexed roundId,
        bytes32 commitment,
        bool decision,
        bytes32 rationaleHash
    );

    /// @notice The commitment hash is zero.
    error ZeroCommitment();
    /// @notice The salt is zero (trivially guessable commitments are refused).
    error ZeroSalt();
    /// @notice The salt is weak (low entropy or trivially guessable).
    error WeakSalt();
    /// @notice This verifier already has a commitment for this claim and round.
    error CommitmentAlreadyExists();
    /// @notice No commitment exists for this verifier, claim and round.
    error NoCommitment();
    /// @notice The commitment was already revealed; it settles only once.
    error AlreadyRevealed();
    /// @notice The revealed fields do not hash to the stored commitment.
    error CommitmentMismatch();
    /// @notice The signature is malformed or was not made by the stated verifier for this reveal.
    error InvalidSignature();
    /// @notice The commit deadline has already passed.
    error DeadlinePassed(uint64 currentTimestamp, uint64 deadline);
    /// @notice The commit deadline is too soon (below MIN_DEADLINE_BUFFER).
    error DeadlineTooShort(uint64 duration, uint64 minBuffer);
    /// @notice The commit deadline is too far in the future (above MAX_DEADLINE_HORIZON).
    error DeadlineTooFar(uint64 duration, uint64 maxHorizon);

    // ---------------------------------------------------------------------------------------
    // Commit
    // ---------------------------------------------------------------------------------------

    /// @notice Stores the caller's commitment for `(claimId, roundId)` bound to a commit deadline.
    /// @dev The slot is write-once: an existing commitment (revealed or not) can never be replaced.
    ///      The deadline is stored in the record and must be re-submitted identically at reveal.
    function commit(
        uint256 claimId,
        uint256 roundId,
        bytes32 commitment,
        uint64 deadline
    ) external {
        if (commitment == bytes32(0)) revert ZeroCommitment();

        // Validate deadline: must be strictly in the future, within buffer and horizon bounds.
        uint64 nowTs = uint64(block.timestamp);
        if (deadline <= nowTs) revert DeadlinePassed(nowTs, deadline);
        uint64 duration = deadline - nowTs;
        if (duration < MIN_DEADLINE_BUFFER) revert DeadlineTooShort(duration, MIN_DEADLINE_BUFFER);
        if (duration > MAX_DEADLINE_HORIZON) revert DeadlineTooFar(duration, MAX_DEADLINE_HORIZON);

        bytes32 key = _key(msg.sender, claimId, roundId);
        Record storage rec = _records[key];
        if (rec.status != Status.None) revert CommitmentAlreadyExists();

        rec.status = Status.Committed;
        rec.commitment = commitment;
        rec.committedAt = nowTs;
        rec.deadline = deadline;

        emit Committed(msg.sender, claimId, roundId, commitment);
    }

    // ---------------------------------------------------------------------------------------
    // Reveal
    // ---------------------------------------------------------------------------------------

    /// @notice Reveals the caller's own commitment. Settles once.
    function reveal(
        uint256 claimId,
        uint256 roundId,
        bool decision,
        bytes32 rationaleHash,
        bytes32 salt,
        uint64 deadline
    ) external {
        _reveal(msg.sender, claimId, roundId, decision, rationaleHash, salt, deadline);
    }

    /// @notice Reveals `verifier`'s commitment on their behalf using their signature.
    /// @dev The signed digest binds action, this contract, chain id, signer, the commitment hash,
    ///      a single-use nonce and a deadline. Replays fail because the nonce is consumed and the
    ///      commitment can only be revealed once.
    function revealWithSignature(
        address verifier,
        uint256 claimId,
        uint256 roundId,
        bool decision,
        bytes32 rationaleHash,
        bytes32 salt,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        // Cheap state checks first; the full reveal logic below re-checks them.
        Record storage rec = _records[_key(verifier, claimId, roundId)];
        if (rec.status == Status.None) revert NoCommitment();
        if (rec.status == Status.Revealed) revert AlreadyRevealed();

        bytes32 commitment = computeCommitment(
            verifier, claimId, roundId, decision, rationaleHash, salt, uint64(deadline)
        );
        bytes32 digest =
            V2ReplayDomain.liveDigest(REVEAL_ACTION, address(this), verifier, uint256(commitment), nonce, deadline);
        if (_recover(digest, signature) != verifier) revert InvalidSignature();

        _useCheckedNonce(verifier, nonce, deadline);
        _reveal(verifier, claimId, roundId, decision, rationaleHash, salt, uint64(deadline));
    }

    function _reveal(
        address verifier,
        uint256 claimId,
        uint256 roundId,
        bool decision,
        bytes32 rationaleHash,
        bytes32 salt,
        uint64 deadline
    ) private {
        if (salt == bytes32(0)) revert ZeroSalt();
        if (_isWeakSalt(salt)) revert WeakSalt();

        Record storage rec = _records[_key(verifier, claimId, roundId)];
        if (rec.status == Status.None) revert NoCommitment();
        if (rec.status == Status.Revealed) revert AlreadyRevealed();

        // The deadline submitted at reveal must match the deadline stored at commit time.
        if (rec.deadline != deadline) revert DeadlinePassed(uint64(block.timestamp), rec.deadline);

        bytes32 expected = computeCommitment(verifier, claimId, roundId, decision, rationaleHash, salt, deadline);
        if (expected != rec.commitment) revert CommitmentMismatch();

        rec.status = Status.Revealed;
        rec.decision = decision;
        rec.rationaleHash = rationaleHash;
        rec.revealedAt = uint64(block.timestamp);

        emit Revealed(verifier, claimId, roundId, expected, decision, rationaleHash);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    /// @notice Computes the commitment a verifier must store to later reveal these exact fields.
    /// @dev Preimage uses `abi.encode` over fixed-width operands only (never `abi.encodePacked`),
    ///      binding all ten replay dimensions: chainId, releaseVersion, verifyingContract,
    ///      verifier, claimId, roundId, deadline, decision, rationaleHash, salt.
    function computeCommitment(
        address verifier,
        uint256 claimId,
        uint256 roundId,
        bool decision,
        bytes32 rationaleHash,
        bytes32 salt,
        uint64 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                COMMITMENT_TYPEHASH,
                block.chainid,
                RELEASE_VERSION,
                address(this),
                verifier,
                claimId,
                roundId,
                deadline,
                decision,
                rationaleHash,
                salt
            )
        );
    }

    /// @notice Reads the stored record for a slot.
    function getRecord(address verifier, uint256 claimId, uint256 roundId) external view returns (Record memory) {
        return _records[_key(verifier, claimId, roundId)];
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    function _key(address verifier, uint256 claimId, uint256 roundId) private pure returns (bytes32) {
        return keccak256(abi.encode(verifier, claimId, roundId));
    }

    /// @dev Rejects salts with obviously low entropy: all bytes identical, or only the final
    ///      byte non-zero (a common weak pattern), or small integer-like values.
    function _isWeakSalt(bytes32 salt) internal pure returns (bool) {
        // All bytes identical (e.g. 0x010101...01 or 0xFF...FF).
        bytes32 firstByte = bytes32(uint256(salt) >> 248);
        bool allSame = true;
        for (uint256 i = 1; i < 32; ) {
            bytes32 byteMask = bytes32(uint256(0xFF) << (248 - i * 8));
            bytes32 byteValue = (salt & byteMask);
            bytes32 expectedByte = bytes32(uint256(firstByte) << (248 - i * 8));
            if (byteValue != expectedByte) {
                allSame = false;
                break;
            }
            unchecked { i++; }
        }
        if (allSame) return true;

        // Only the last byte is non-zero (e.g. 0x00...0001 through 0x00...00FF).
        bytes32 lastByteMask = bytes32(uint256(0xFF));
        if ((salt & ~lastByteMask) == bytes32(0) && (salt & lastByteMask) != bytes32(0)) return true;

        // Small integer-like salts (0x00...0100 through 0x00...FFFF).
        bytes32 lastTwoBytesMask = bytes32(uint256(0xFFFF));
        if ((salt & ~lastTwoBytesMask) == bytes32(0) && (salt & lastTwoBytesMask) != bytes32(0)) return true;

        return false;
    }

    /// @dev Strict ECDSA recovery: 65-byte signatures, canonical low-s, v in {27, 28}.
    ///      Returns address(0) on any malformed input so the caller can fail closed.
    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }
}
