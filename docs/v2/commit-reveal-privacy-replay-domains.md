# Commit-Reveal Privacy, Deadlines, and Replay Domains (PREWAVE-SC-003)

| Metadata | Specification |
| :--- | :--- |
| **Document ID** | `TB-V2-SPEC-003` |
| **Issue Reference** | [#678 PREWAVE-SC-003](https://github.com/DigiNodes/truthbounty-contract/issues/678) |
| **Dependencies** | #674, PREWAVE-SC-001 (#676), #468, [Frontend Implementation Matrix](https://www.drips.network/external/https%3A%2F%2Fgithub.com%2FDigiNodes%2Ftruthbounty-protocol%2Fblob%2Fmain%2Fdocs%2Fux-authority%2FFRONTEND_IMPLEMENTATION_MATRIX.md) |
| **Topology** | Optimism (OP Stack) EVM |
| **Status** | Approved Candidate |
| **Security Classification** | Release-Readiness, Anti-Frontrunning & Privacy Boundary |

---

## 1. Executive Summary & Problem Context

In decentralized oracle and verification systems, transparent on-chain voting introduces critical security vulnerabilities:
1. **Front-running & Copycat Voting**: Malicious or lazy participants observe reputable verifiers' transactions in the public mempool or on-chain history and duplicate their votes without conducting independent analysis.
2. **Order Manipulation & Bandwagon Effects**: Early votes skew participation dynamics, discouraging minority dissent and reducing consensus robustness.
3. **Cross-Domain Replay**: Signatures or commitments created for one claim, round, deployment, release, or chain can be replayed in foreign contexts unless strictly bound to all identifying dimensions.

Under the post-Wave-9 testnet-readiness audit, **PREWAVE-SC-003** establishes independently reviewable proof for the contract boundary consumed by the API and approved frontend designs.

This specification documents:
- The **10-dimensional cryptographic commitment model** preventing cross-domain substitution and collision.
- The **strict off-chain data inventory** required before reveal to preserve complete privacy.
- The **deterministic deadline boundaries** governing the commit, reveal, and missed-reveal phases.
- The **commit replacement policy** and **missed-reveal slashing lifecycle**.

---

## 2. The 10-Dimensional Commitment Binding Model

Every commitment is computed as an EIP-712-style fixed-width digest over exactly ten parameters:

$$\text{commitment} = \text{keccak256}\Big(\text{abi.encode}\big(\text{TYPEHASH}, \text{chainId}, \text{releaseVersion}, \text{verifyingContract}, \text{claimId}, \text{roundId}, \text{voter}, \text{decision}, \text{rationaleHash}, \text{salt}, \text{deadline}\big)\Big)$$

### 2.1 Pinned Schema Definition

```solidity
bytes32 public constant COMMIT_REVEAL_TYPEHASH = keccak256(
    "V2CommitReveal(uint256 chainId,bytes32 releaseVersion,address verifyingContract,uint256 claimId,uint256 roundId,address voter,uint8 decision,bytes32 rationaleHash,bytes32 salt,uint64 deadline)"
);
```

### 2.2 Dimension Inventory

| # | Dimension | Solidity Type | Wire Offset | Description & Replay Protection Purpose |
| :- | :--- | :--- | :--- | :--- |
| **1** | `chainId` | `uint256` | 32..64 | Live execution chain ID (`block.chainid`). Prevents cross-chain replay between OP Stack networks, testnets, and L1. |
| **2** | `releaseVersion` | `bytes32` | 64..96 | Pinned protocol release version hash (`keccak256("TruthBounty-V2.0.0-cancun")`). Prevents cross-release replay across protocol upgrades. |
| **3** | `verifyingContract` | `address` | 96..128 | Verifying contract deployment address (`address(this)`). Prevents cross-contract and cross-instance replay. |
| **4** | `claimId` | `uint256` | 128..160 | Unique monotonic claim identifier. Prevents cross-claim vote replay. |
| **5** | `roundId` | `uint256` | 160..192 | Round index within the claim (initial pass vs appeal ladder). Prevents cross-round vote replay. |
| **6** | `voter` | `address` | 192..224 | Designated voter account. Binds the vote strictly to `msg.sender`, preventing theft or unauthorized reveal by third parties. |
| **7** | `decision` | `uint8` | 224..256 | Vote choice (`0 = OPPOSE`, `1 = SUPPORT`). Kept strictly off-chain until reveal. |
| **8** | `rationaleHash` | `bytes32` | 256..288 | Digest of off-chain reasoning/evidence citations. Kept strictly off-chain until reveal. |
| **9** | `salt` | `bytes32` | 288..320 | High-entropy 256-bit cryptographically secure random number. Defeats dictionary and rainbow table brute-force attacks. |
| **10** | `deadline` | `uint64` | 320..352 | Round commit deadline. Binds commitment expiry and prevents stale parameter reuse. |

### 2.3 Mathematical Collision Resistance

Because all ten parameters use standard `abi.encode` with fixed-width types:
1. Every argument occupies an exact 32-byte slot; total preimage length is fixed at **352 bytes** ($11 \times 32\text{ bytes}$).
2. No packed-encoding length extension or boundary shifting (e.g. `abi.encodePacked`) is possible.
3. The preimage mapping $f: D_1 \times D_2 \times \dots \times D_{10} \to \{0,1\}^{2816}$ is strictly injective. Mutating any single bit in any dimension produces a totally distinct keccak256 hash.

---

## 3. Strict Off-Chain Data Specification (Pre-Reveal Privacy)

To guarantee that protected choices and rationales are never emitted prematurely, the protocol partitions data strictly across phases:

```
[Phase 1: Commit Window] ------------------------> [Phase 2: Reveal Window]
- Off-Chain:                                      - On-Chain Calldata:
  * decision (0 or 1)                               * decision
  * salt (256-bit CSPRNG)                           * salt
  * rationale text                                  * rationaleHash
- On-Chain Event (CommitSubmitted):               - Verification:
  * claimId, roundId, voter                         * computeCommitment(...) == storedHash
  * commitmentHash                                - On-Chain Event (VoteRevealed):
  * commitDeadline, revealDeadline                  * voter, decision, rationaleHash
  * stakeAmount, committedAt
```

### 3.1 Data Stored Exclusively Off-Chain Before Reveal

1. **`decision` (`uint8`)**:
   - The verifier's choice (e.g., `0 = FALSE`, `1 = TRUE`).
   - Must remain stored on client devices or encrypted off-chain storage.
2. **`salt` (`bytes32`)**:
   - Minimum **256 bits of entropy** generated via a Cryptographically Secure Pseudorandom Number Generator (CSPRNG).
   - Because the decision space is small (1 bit for boolean verification), low-entropy salts (e.g., small integers or dictionary phrases) can be trivially precomputed and brute-forced via rainbow tables. A 256-bit salt provides $2^{256}$ security, rendering precomputation computationally impossible.
3. **`rationale` (`string` / raw bytes)**:
   - Human-readable explanation and citations supporting the verdict.
   - Kept off-chain; only its digest (`rationaleHash = keccak256(bytes(rationale))`) is committed.

### 3.2 Data Emitted On-Chain During Commit Phase

The `CommitSubmitted` event emits ONLY public metadata:
```solidity
event CommitSubmitted(
    uint256 indexed claimId,
    uint256 indexed roundId,
    address indexed voter,
    bytes32 commitmentHash,
    uint64 commitDeadline,
    uint64 revealDeadline,
    uint256 stakeAmount,
    uint64 committedAt
);
```

> **Privacy Verification Rule**: The event payload contains zero occurrences of `decision`, `salt`, or `rationale`. Off-chain observers, indexers, and mempool eavesdroppers learn nothing about the voter's stance or rationale.

---

## 4. Deterministic Deadline & Timing Semantics

Time in TruthBounty V2 on Optimism is strictly governed by `block.timestamp` as defined in [PREWAVE-SC-090](file:///docs/v2/block-timestamp-number-assumptions.md).

### 4.1 Timing Boundary Intervals

```
   startedAt                    commitDeadline                  revealDeadline
-------|------------------------------|-------------------------------|------------> time
       <------- Commit Phase ---------><-------- Reveal Phase --------><- Missed/Slash ->
       (block.timestamp <= deadline)   (t > commit && t <= reveal)     (t > reveal)
```

1. **Commit Window**:
   - Active when: $\text{startedAt} \le \text{block.timestamp} \le \text{commitDeadline}$
   - At $\text{block.timestamp} = \text{commitDeadline}$: Commit is **valid** (inclusive upper bound).
   - At $\text{block.timestamp} = \text{commitDeadline} + 1$: Commit is **rejected** (`CommitDeadlinePassed`).
2. **Reveal Window**:
   - Active when: $\text{commitDeadline} < \text{block.timestamp} \le \text{revealDeadline}$
   - At $\text{block.timestamp} \le \text{commitDeadline}$: Reveal is **rejected** (`RevealWindowNotOpen`). Choice cannot be revealed before commit closes.
   - At $\text{block.timestamp} = \text{revealDeadline}$: Reveal is **valid** (inclusive upper bound).
   - At $\text{block.timestamp} = \text{revealDeadline} + 1$: Reveal is **rejected** (`RevealDeadlinePassed`).
3. **Missed Reveal & Slashing Window**:
   - Active when: $\text{block.timestamp} > \text{revealDeadline}$
   - At $\text{block.timestamp} \le \text{revealDeadline}$: Missed reveal recording is **rejected** (`RevealDeadlineNotPassed`).
   - At $\text{block.timestamp} > \text{revealDeadline}$: Recording and slashing are **valid**.

---

## 5. Commit Replacement Policy

V2 supports explicit commit replacement policies configured at round registration:

### 5.1 `ALLOWED_BEFORE_DEADLINE` (Default)
- A voter who has already committed may submit an updated commitment prior to `commitDeadline`.
- Updates `commitmentHash`, updates `committedAt`, and increments `replacementCount`.
- Emits `CommitReplaced(claimId, roundId, voter, oldHash, newHash, replacementCount, timestamp)`.
- The previous commitment is invalidated; only the newest commitment can be revealed.
- Attempting to replace at $\text{block.timestamp} > \text{commitDeadline}$ fails closed with `CommitDeadlinePassed`.

### 5.2 `FORBIDDEN`
- The voter's first commitment is final and write-once.
- Any subsequent call to `commit()` reverts with `CommitReplacementForbidden(claimId, roundId, voter)`.

---

## 6. Missed-Reveal and Slashing Lifecycle

When a voter commits stake but fails to reveal before `revealDeadline`, the protocol enforces complete accountability:

```
[Voter Commits Stake]
        │
        ▼ (revealDeadline passes without reveal)
[recordMissedReveal] ───> State: MISSED_REVEAL ───> Event: MissedRevealRecorded(...)
        │
        ▼
[slashMissedReveal]  ───> State: SLASHED       ───> Event: VoterSlashed(...)
```

### 6.1 Slashing Execution & Events
- Slashing is executed by authorized controllers (`SLASH_ADMIN_ROLE`).
- Formula:
  $$\text{slashAmount} = \frac{\text{stakeAmount} \times \text{slashBps}}{10\,000}$$
- State transitions irreversibly to `SLASHED`. Double slashing is prevented fail-closed with `CommitmentAlreadySlashed`.
- Complete event emitted:
```solidity
event VoterSlashed(
    uint256 indexed claimId,
    uint256 indexed roundId,
    address indexed voter,
    uint256 slashAmount,
    uint256 remainingStake,
    bytes32 commitmentHash,
    uint64 slashedAt
);
```

---

## 7. Replay Protection Verification Matrix

| Replay Attack Vector | Target Dimension | Mitigation & Failure Mode |
| :--- | :--- | :--- |
| **Cross-Claim Replay** | `claimId` | Commitment for Claim 100 cannot be revealed for Claim 101 (`CommitmentMismatch`). |
| **Cross-Round Replay** | `roundId` | Commitment for Round 1 cannot be revealed in Round 2 (`CommitmentMismatch`). |
| **Cross-Chain Replay** | `chainId` | Commitment for Optimism (10) cannot be revealed on Ethereum L1 (1) (`CommitmentMismatch`). |
| **Cross-Release Replay** | `releaseVersion` | Commitment for V2.0.0 cannot be revealed in V2.1.0 (`CommitmentMismatch`). |
| **Cross-Contract Replay** | `verifyingContract` | Commitment targeting Deployment A fails on Deployment B (`CommitmentMismatch`). |
| **Unauthorized Reveal** | `voter` | Eve attempting to reveal Alice's commitment uses Eve's address as `msg.sender`, causing immediate mismatch (`CommitmentNotFound` or `CommitmentMismatch`). |
| **Stale Vote Substitution**| `decision` / `salt` | Voter attempting to reveal a different decision or salt causes digest mismatch (`CommitmentMismatch`). |
