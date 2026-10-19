# Appeal Verification Round (`SC-017`)

## 1. Overview

The **AppealVerificationRound** contract manages the second-round verification lifecycle for claims undergoing disputes. When a provisional consensus outcome is disputed, an appeal round is opened with heightened economic security parameters (higher minimum stake, multiplier, and weight caps). Since **V2-SC-059**, the appeal path is a *bounded ladder*: at most `maxAppealRounds` rounds (default 1) can be opened per claim, every round is *bond-gated* (the opener posts an escalating, module-computed bond in vaulted custody), and a finalized path is irreversibly terminal. The ladder depth, bond escalation, deadlines, and terminal fallback are all explicitly bounded and enforced on-chain.

```
┌──────────────────────────────────────────────────────────────────┐
│                 Appeal Round Ladder (bounded)                    │
│                                                                  │
│   ┌───────────────────────┐                                      │
│   │   Provisional Dispute │                                      │
│   └──────────┬────────────┘                                      │
│              │ openAppealRound(claimId)                          │
│              │   [bond-gated: vault.lockBond before state]       │
│              ▼                                                   │
│   ┌───────────────────────┐   submitAppealVote(...)              │
│   │   Appeal Round OPEN   │◄──────────────────────────────────┐  │
│   └──────────┬────────────┘ (Heightened Stake & Bond Custody) │  │
│              │ block.timestamp >= round.deadline              │  │
│              ▼                                                │  │
│   ┌───────────────────────┐   closeAppealRound / finalize     │  │
│   │  Appeal Round CLOSED  ├────────────────────────────────┐  │  │
│   └──────────┬────────────┘                                │  │  │
│              │                                             │  │  │
│              │ nextRound <= maxRounds ? ─── reopen (bond escalates)
│              │                                             │  │  │
│              ▼                          (final round)      ▼  ▼
│   ┌───────────────────────┐   AppealPathFinalized ──► TERMINAL
│   │VerificationAggregator │   (irreversible seal; no reopen)
│   └───────────────────────┘
└──────────────────────────────────────────────────────────────────┘
```

## 2. Core Protocol Invariants (V2-SC-059)

1. **Bounded Appeal Ladder**: `roundIndex <= maxAppealRounds` (frozen per round at open; 1..`MAX_APPEAL_ROUNDS`). A terminal path can never be reopened, even by governance raising the cap; a round can only open after the prior round closed. The appeal counter is monotonic per claim and cannot be reset by any actor, including governance or the opener.
2. **Bond Escalation & Custody**: `appealBond <= requiredBond <= maxAppealBond`, with `requiredBond = min(maxAppealBond, appealBond * esc^(roundIndex-1) / 1e4)` computed via overflow-safe `mulDiv` (reverts `BondOverflow` on overflow). Every round posts exactly one `ISTakeVault.lockBond` **before** round state is committed — no appeal round exists without its vault lock. Dust bonds below `MIN_APPEAL_BOND` revert `BondTooSmall`.
3. **Fail Closed**: Config with zero bond, zero voter cap, out-of-range ladder cap, or a vault that declines a lock reverts the whole call (`CustodyTransitionFailed`). A missed deadline leaves the round OPEN until permissionless `finalizeAppealRound` closes it; the terminal fallback conserves all locked funds and releases them only via the vault operator.
4. **Storage Isolation**: Against the prior round/ownership of bond disposition; claim-state finalization and bond disposition are exclusive to the vault operator (V2-SC-018). Repeated malicious `openAppealRound` calls cannot reset `roundIndex` or `requiredBond`; the counter only advances on a successful close.
5. **Immutable Frozen Round Parameters**: `roundDuration`, `minStakeAmount`, `stakeMultiplierBps`, `maxWeightCap`, `maxRounds`, `requiredBond`, `maxVoters` are snapshotted at open; later config changes never retroactively alter an active round. Ties resolve deterministically to the false (reject) side to prevent griefing.
6. **One Address One Position**: Verifiers may cast exactly one vote per appeal round.
7. **Bounded Processing**: A round admits at most `maxVotersPerRound` (<= `MAX_VOTERS_PER_ROUND = 200`) voters so downstream aggregation is O(n) with n capped (gas budget: `APPEAL_SETTLEMENT`).
8. **Aggregation Ready**: Implements `IVerificationSource` (`getClaimVoterCount`, `getClaimVoterAt`, `getVoteData`) for direct consumption by `VerificationAggregator`.

## 3. Interfaces & Storage

### Addresses

- `stakingToken`: ERC20 used for appeal staking (votes are approved **to this contract**).
- `claimRegistry`: canonical `IClaimRegistry` (claim existence check).
- `reputationOracle`: verifier weight multiplier source (fallback baseline 1.0).
- `vault`: `ISTakeVault` bond-custody vault. The opener must approve the **vault** for the required bond; vote stakes are approved to the contract.

### Structs

```solidity
struct AppealRoundConfig {
    uint256 roundDuration;            // e.g. 1 day
    uint256 minStakeAmount;           // higher minimum stake for appeal
    uint256 stakeMultiplierBps;       // e.g. 15000 = 1.5x
    uint256 maxWeightCap;             // maximum weight per verifier
    uint256 parameterVersion;
    uint256 maxAppealRounds;          // ladder cap (1..MAX_APPEAL_ROUNDS), default 1
    uint256 appealBond;               // base bond posted by the opener of round 1
    uint256 appealBondEscalationBps;  // per-round escalation (10000..40000, e.g. 15000 = +50%)
    uint256 maxAppealBond;            // hard cap on any single round bond
    uint256 maxVotersPerRound;        // bounded-processing cap (1..MAX_VOTERS_PER_ROUND)
}

struct AppealRound {
    uint256 claimId;
    AppealRoundStatus status;     // NONE, OPEN, CLOSED, RESOLVED
    uint256 openedAt;
    uint256 deadline;
    uint256 minStakeAmount;
    uint256 stakeMultiplierBps;
    uint256 maxWeightCap;
    uint256 totalTrueStake;
    uint256 totalFalseStake;
    uint256 totalTrueWeight;
    uint256 totalFalseWeight;
    uint256 verifierCount;
    uint256 roundIndex;       // 1-based position within the claim's ladder (monotonic, never reset)
    uint256 maxRounds;        // ladder cap frozen at open
    uint256 requiredBond;     // bond posted by the opener (vaulted, exact and bounded)
    uint256 bondLockId;       // unique ISTakeVault lock id for this round
    uint256 maxVoters;        // voter cap frozen at open
}

struct AppealVote {
    bool voted;
    bool support;
    uint256 stakeAmount;
    uint256 effectiveStake;
    uint256 timestamp;
}
```

## 4. Bond Custody & Terminality

- **Bond flow**: `openAppealRound` computes `requiredBond` from the frozen config, requires `allowance(opener, vault) >= requiredBond` (`InsufficientBondAllowance`), then `vault.lockBond(lockId, token, msg.sender, requiredBond)` (`try/catch` — failure reverts `CustodyTransitionFailed`, atomically rolling back the open). Lock ids are namespaced (`keccak256("V2_APPEAL_BOND", claimId, roundIndex)`) and disjoint from `DisputeResolution` dispute-id locks. `requiredBond` is exact (no rounding drift) and bounded above by `maxAppealBond`.
- **Reconciliation**: `totalLocked()` reconciles 1:1 with the sum of `AppealRound.requiredBond`; `getAppealBondLock(claimId)` exposes the vault lock ledger record. Terminal fallback releases exactly the sum of locked bonds, conserving funds with no leakage.
- **Disposition**: The module never disposes bonds. Only the vault `OPERATOR_ROLE` (the finalization module, SC-018) may release a lock.
- **Terminality**: Closing the final round (`roundIndex >= maxRounds`) or a permissionless `finalizeAppealRound` seals the path (`AppealPathFinalized`). `finalizeAppealRound` closes an OPEN-but-expired round inside the same transaction and is idempotency-guarded (`AppealPathAlreadyFinalized`). Sealed paths cannot be reopened, and a missed deadline cannot be used to extend the ladder or reset the counter.

## 5. Events

- `AppealRoundOpened(uint256 indexed claimId, uint256 deadline, uint256 minStake, uint256 multiplierBps, address indexed openedBy, uint256 roundIndex, uint256 maxRounds, uint256 requiredBond, uint256 bondLockId)`
- `AppealVoteSubmitted(uint256 indexed claimId, address indexed verifier, bool support, uint256 stakeAmount, uint256 effectiveWeight)`
- `AppealRoundClosed(uint256 indexed claimId, uint256 totalTrueWeight, uint256 totalFalseWeight, uint256 verifierCount, address indexed closedBy, uint256 roundIndex)`
- `AppealPathFinalized(uint256 indexed claimId, uint256 roundIndex, uint256 totalTrueWeight, uint256 totalFalseWeight, uint256 verifierCount)`
- `DefaultAppealConfigUpdated(uint256 duration, uint256 minStake, uint256 multiplierBps, uint256 maxWeightCap, uint256 maxAppealRounds, uint256 appealBond, uint256 appealBondEscalationBps, uint256 maxAppealBond, uint256 maxVotersPerRound)`
- `VaultUpdated(address indexed oldVault, address indexed newVault)`

## 6. Bounds, Errors, and Test Matrix

- **Constants**: `MAX_APPEAL_ROUNDS = 8`, `MAX_VOTERS_PER_ROUND = 200`, `MIN_APPEAL_BOND = 1e6`, `BPS_DENOMINATOR = 1e4`.
- **Errors**: `BondOverflow`, `BondTooSmall`, `InsufficientBondAllowance`, `CustodyTransitionFailed`, `AppealPathAlreadyFinalized`, `AppealLadderExhausted`, `DeadlineNotReached`.
- **Required tests**: max-1 / max / max+1 rounds; escalating bonds (exact `mulDiv`); dust below `MIN_APPEAL_BOND`; overflow at escalation cap; missed-deadline finalize; tie resolution; malicious repeat `openAppealRound` cannot reset counter.
- **Acceptance**: appeal depth finite and explicit; required bond exact and bounded; terminal fallback conserves funds; no actor can reset the appeal counter.