# Dependency Gate — V2-SC-103, V2-SC-104, V2-SC-106, V2-SC-109

Investigation record for issues #489, #490, #491 and #494. No production Solidity,
tests or fixtures are proposed here: all four are blocked on dependencies that are
not on `main`, and each issue body states the gate explicitly.

> This issue must remain unassigned until every dependency is verified complete
> and compatible.

This document records what was verified, so the gate can be re-checked cheaply
once the upstream work lands.

## Scope Under Investigation

| Issue | ID | Objective | Declared dependencies |
|---|---|---|---|
| #489 | V2-SC-103 | Stake splitting and identity fragmentation attacks | V2-SC-091, V2-SC-100 |
| #490 | V2-SC-104 | Last-block and deadline manipulation resistance | V2-SC-091, V2-SC-100 |
| #491 | V2-SC-106 | Emission caps across revenue sources | V2-SC-091, V2-SC-100 |
| #494 | V2-SC-109 | Gas-bounded settlement capacity | V2-SC-091, V2-SC-100 |

All four declare the same two dependencies.

## Dependency Status

Verified at `main` = `58e1302` (`Merge pull request #545`).

| Dependency | Tracking issue | State | Deliverable on `main`? |
|---|---|---|---|
| V2-SC-091 — Protocol-Wide Asset Conservation Invariant | #477 | **open**, assigned to `Babigdk` | No. In flight as PR #557 (open, mergeable, 5 files). |
| V2-SC-100 — Canonical Rounding and Precision Library | #486 | **open** | No. Not started, and itself gated. |

Neither dependency is satisfied.

### V2-SC-100 is a second-order block

V2-SC-100 (#486) is not merely unfinished — it is itself gated. Its own declared
dependencies are V2-SC-090 (#472, open, assigned to `Abdulrasaq1515`) and V2-SC-091
(#477, the same open dependency as above). So the chain for all four issues in this
document is:

```
V2-SC-090 (#472, open)  ─┐
                         ├─> V2-SC-100 (#486, open, blocked) ─> #489 #490 #491 #494
V2-SC-091 (#477, open)  ─┘                                   ─> (also a direct dependency)
```

Two merges must land before any of these four can start, and one of them (#486) has
not begun.

### Evidence that the deliverables are absent from `main`

- No asset-conservation invariant exists. A case-insensitive search for
  `asset conservation` / `assetConservation` across `contracts/`, `test/` and
  `docs/` returns nothing.
- No canonical rounding or precision library exists under `contracts/`. The only
  matches for `round` are `VerificationRoundManager`, `AppealVerificationRound`,
  `FrozenRoundConfigStore` and their interfaces — round *lifecycle*, unrelated to
  rounding arithmetic.
- `test/invariant/` already holds a usable harness pattern for this kind of work:
  `TimingInvariant.t.sol` is directly adjacent to #490, and `SlashingInvariant.t.sol`
  and `SimulationInvariant.t.sol` to #489. `docs/gas-bounded-execution-v2-sc-038.md`
  is prior art for #494. The shape of the eventual work is clear; the formalized
  invariant and the rounding library those proofs must assert against are what is
  missing.

## Why This Blocks Rather Than Merely Complicates

All four are *proof* tasks — "model", "test", "verify", "quantify". Their deliverable
is a demonstration that a property holds, not a feature. Two consequences:

1. Without V2-SC-091 on `main` there is no authoritative asset-conservation property
   to prove against. Any harness written now would assert a property this PR
   invented. PR #557, by the assignee of #477, defines exactly that formalization
   and is open and mergeable, so a second independent version would duplicate their
   work and conflict on merge.
2. Without V2-SC-100 there is no canonical rounding library. #491 in particular
   ("prove per-period and lifetime emission limits remain correct across every
   revenue source, multiplier, pause, configuration version, and batch
   distribution") is an arithmetic-boundary proof. Proving emission caps against
   ad-hoc arithmetic and then re-proving them once the canonical library lands means
   doing the work twice, and the first result would not be evidence for the
   acceptance criteria.

Note also that V2-SC-100 is assigned to a *different* contributor account than these
four issues. Pre-empting it here by writing the rounding library into this branch
would cross that boundary and collide with the other account's work on the same
upstream repository.

## Secondary Constraint: Acceptance Bar Cannot Be Met Locally

Independently of the dependency gate, every one of the four issues requires:

> Full Foundry build, unit, fuzz, invariant, gas, lint, and configured
> static-analysis suites.

The repository is 145 contract files (~29,800 lines) and 45 test files (~10,900
lines), and `foundry.toml` sets `via_ir = true` with `optimizer_runs = 200`. The
`lib/forge-std` and `lib/openzeppelin-contracts` submodules are unpopulated in a
fresh clone. Satisfying that criterion needs a full Foundry toolchain, initialized
submodules, and a via-IR build of the whole tree — so evidence for the acceptance
criteria has to come from CI (`ci.yml`, `fuzz-tests.yml`, `gas-check.yml`) rather
than from a local run.

This is a note on where evidence must come from, not a reason the work cannot be
done. #494 in particular depends on it: worst-case gas figures are only meaningful
from a consistent build profile, so its numbers should be produced by
`gas-check.yml` rather than a developer machine.

## Missing Information

1. Merge order and target for PR #557 (V2-SC-091), which fixes the invariant
   interface all four proofs assert against.
2. Whether V2-SC-100 (#486) will be scoped to subsume the rounding semantics already
   specified in open PR #560, or stay independent. #491 needs that resolved before
   its emission-cap arithmetic has a stable basis.
3. For #494: the "realistic participant counts" to measure against. No canonical
   load profile was found in `docs/` — `docs/gas-bounded-execution-v2-sc-038.md` and
   `docs/event-gas-benchmarks.md` record method-level figures, not participant-scaled
   scenarios. A maintainer-supplied target (for example p50/p99 verifier counts per
   claim) is required, otherwise "worst-case" is unfalsifiable.
4. For #490: the sequencer variance assumption to test against. The issue names
   "sequencer variance assumptions" but no documented bound was found; Optimism
   block-time tolerance needs to be stated before timestamp-boundary tests can
   assert anything meaningful.
5. For #489: whether per-identity participation thresholds are intended to be
   Sybil-resistant at the protocol layer at all, or whether fragmentation is
   accepted and mitigated economically. The expected answer determines whether a
   finding is a bug or a documented property.

## Recommended Next Steps

1. Land PR #557 (V2-SC-091), then re-verify this gate.
2. Unblock and complete V2-SC-100 (#486) — it is the shared prerequisite for all
   four issues here and is currently the deeper blocker, since it has not started.
3. Supply the two missing measurement inputs before implementation, not during:
   the participant-count profile for #494 and the sequencer variance bound for #490.
   Both are maintainer decisions and both are prerequisites for a falsifiable test.
4. Sequence the four as #490 → #489 → #491 → #494. #490 builds most directly on the
   existing `TimingInvariant.t.sol`; #491 is the most dependent on the rounding
   library; #494 should come last so it measures the final gas profile rather than an
   intermediate one.
5. Keep each as its own PR at implementation time. Every issue body requires an
   independently reviewable change and prohibits automatic merge, so a combined
   change would not be reviewable against the stated criteria.

## Residual Risk If Merged As-Is

None to protocol behaviour: this document adds no executable code, no interfaces,
no storage and no deployment artifacts. The risk is purely informational — if the
dependency PRs land in a materially different shape, the sequencing advice above
needs re-checking against their merged form rather than their current diffs.
