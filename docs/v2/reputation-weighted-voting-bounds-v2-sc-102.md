# V2-SC-102 — Stress-Test Reputation-Weighted Voting Bounds

## Overview

This specification establishes the canonical protocol guarantees, module boundaries, math formulations, invariant enforcement, and stress-testing harness for **Reputation-Weighted Voting Bounds** in TruthBounty V2.

The objective of V2-SC-102 is to eliminate risk vectors surrounding reputation-weighted voting power manipulation, multiplier amplification attacks, snapshot inconsistencies, root version drift, zero-reputation zero-division panics, and weight cap bypasses.

---

## Technical Scope & Authoritative Boundaries

| Module / Artifact | Role & Responsibility |
|---|---|
| `contracts/verification/ReputationWeightedVotingBounds.sol` | Canonical V2 engine for evaluating, capping, and stress-testing reputation-weighted voting power. |
| `contracts/v2/interfaces/IReputationRoots.sol` | Authoritative interface for publishing, accepting, and verifying versioned epoch reputation roots. |
| `test/v2/ReputationWeightedVotingBounds.t.sol` | Full Foundry unit, fuzz, invariant, snapshot consistency, and stress-test suite. |
| `docs/v2/reputation-weighted-voting-bounds-v2-sc-102.md` | Formal architecture specification and invariant catalogue. |

---

## Technical Specifications

### 1. Effective Voting Weight Calculation

Voting weight $W_{\text{effective}}$ for a verifier with raw stake $S$, reputation score $R$, min reputation bound $R_{\min}$, max reputation bound $R_{\max}$, appeal multiplier $M_{\text{appeal}}$, total round stake $S_{\text{total}}$, and weight cap $C_{\text{bps}}$ (in basis points, $10,000 = 100\%$) is derived as follows. Stakes and weights use the token's smallest integer unit; reputation uses WAD (`10^{18}`); multiplier and cap inputs use basis points (`10,000`):

$$\text{Clamped Reputation } R_{\text{clamped}} = \max(R_{\min}, \min(R_{\max}, R))$$

$$W_{\text{rep}} = \left\lfloor\frac{S \times R_{\text{clamped}}}{10^{18}}\right\rfloor$$

$$W_{\text{raw}} = \left\lfloor\frac{W_{\text{rep}} \times M_{\text{appeal}}}{10,000}\right\rfloor$$

$$W_{\max} = \left\lfloor\frac{S_{\text{total}} \times C_{\text{bps}}}{10,000}\right\rfloor$$

$$W_{\text{effective}} = \min(W_{\text{raw}}, W_{\max})$$

Each division rounds down independently, matching the two sequential full-precision `mulDiv`
operations in `ReputationWeightedVotingBounds.computeEffectiveVotingWeight`. This staged
rounding is part of the protocol result; it is not interchangeable with one division of the
three-factor product. A zero cap disables the cap, and a zero total round stake also skips
cap enforcement. `mulDiv` uses a 512-bit intermediate and reverts if the final quotient
cannot fit in `uint256`; invalid cap and reputation bounds are rejected before calculation.

### 2. Zero-Reputation Behavior

Verifiers with zero or uninitialized reputation score ($R = 0$) do not revert or trigger division-by-zero panics. Instead:
- $R$ is defaulted to the configured minimum floor $R_{\min}$ (e.g. 0.1x / 10%).
- `zeroReputationHandled` flag is set to `true`.
- The verifier obtains a bounded, non-zero effective weight proportional to their stake without gaining unearned amplification.

### 3. Snapshot Consistency

Reputation snapshots are locked at claim creation block height ($B_{\text{claim}}$):
- Snapshot block $B_{\text{snap}}$ must satisfy $B_{\text{snap}} \le B_{\text{claim}} \le B_{\text{current}}$.
- Once locked, score updates occurring after $B_{\text{snap}}$ do not modify voting power for open rounds.
- Non-finalized blocks or future blocks are rejected via `SnapshotMismatch` or `SnapshotNotFinalized`.

### 4. Reputation-Root Versioning

- Epoch Merkle trees publish root $H_{\text{epoch}}$ to `IReputationRoots`.
- Roots are valid for proof verification only after governance or designated authority issues `acceptRoot(epoch)`.
- Cross-epoch root substitution or version drift is rejected on-chain.

### 5. Multiplier Amplification & Overflow Resistance

- Multiplication order utilizes `Math.mulDiv` to ensure full 256-bit intermediate precision.
- Extreme stake amounts up to $2^{128} - 1$ combined with $10\times$ reputation multipliers and $3\times$ appeal multipliers calculate without overflow.
- Weight caps ($C_{\text{bps}}$) enforce a strict upper bound on single-voter influence regardless of multiplier size.

---

## Security Invariants

| Invariant ID | Definition |
|---|---|
| `INV-WEIGHT-001` | For any verifier, $W_{\text{effective}} \le \frac{S_{\text{total}} \times C_{\text{bps}}}{10,000}$ whenever $C_{\text{bps}} > 0$. |
| `INV-WEIGHT-002` | $R = 0$ is safely bounded to $R_{\min}$ without division by zero or reversion. |
| `INV-WEIGHT-003` | Reputation score changes at block $B > B_{\text{snap}}$ cannot alter snapshot weight at $B_{\text{snap}}$. |
| `INV-WEIGHT-004` | Merkle proofs for epoch $E_1$ are invalid for epoch $E_2$. |
| `INV-WEIGHT-005` | $W_{\text{raw}}$ computation never overflows for any valid $S \le 2^{128}-1$ and multipliers $\le 100\times$. |

---

## Migration & Compatibility

- **Active Claims:** Active claims retain their frozen snapshot parameters and weight cap configuration.
- **Artifact Compatibility:** `ReputationWeightedVotingBounds` implements standard `IV2Module` (ERC-165) interface identification.
- **Off-Chain / Indexer Alignment:** Emits standard `WeightCapEnforced`, `SnapshotConsistencyVerified`, and `ReputationRootVersionValidated` events for deterministic indexer projection.
