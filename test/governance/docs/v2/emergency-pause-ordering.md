# V2 Emergency Pause Dependency Ordering (V2-SC-117)

## Purpose

This document is the authoritative specification for **which operations pause together**, **which remain available for safety**, **how pause level rules propagate across modules**, and **the ordered recovery path** after an emergency pause is lifted.

On-chain source of truth for the allow/deny matrix:

- `contracts/governance/libraries/EmergencyPauseOrdering.sol`
- Consumed by `EmergencyController.isOperationAllowed(bytes32)`

Scoped pause (per-`bytes32` scope) via `IEmergencyControls` / Gatekeeper is **additive**. It does not replace this level matrix.

## Pause levels

| Level | Name | Protocol effect |
|-------|------|-----------------|
| 0 | NORMAL | Full operation |
| 1 | HIGH_RISK | Block risk-increasing commitments |
| 2 | FINANCIAL | Also block value egress / distribution |
| 3 | SHUTDOWN | Only governance recovery mutations |

Levels only **increase** via `activatePause`. Lowering requires DAO `liftPause` to NORMAL, then staged recovery.

## Operation cohorts (pause together)

### HIGH_RISK cohort (blocked at level ≥ 1)

| Operation id string | Constant |
|---------------------|----------|
| `claim_creation` | `OP_CLAIM_CREATION` |
| `staking` | `OP_STAKING` |
| `verification_submission` | `OP_VERIFICATION_SUBMISSION` |

### FINANCIAL cohort (blocked at level ≥ 2)

| Operation id string | Constant |
|---------------------|----------|
| `reward_distribution` | `OP_REWARD_DISTRIBUTION` |
| `treasury_transfer` | `OP_TREASURY_TRANSFER` |
| `withdrawal` | `OP_WITHDRAWAL` |

At level 2, **both** cohorts are blocked (dependency propagation: financial pause implies high-risk still frozen).

### SHUTDOWN (level 3)

Only `governance_recovery` is allowed. All other operation types, including safety pulls, are denied.

## Safety-available paths

| Path | L0 | L1 | L2 | L3 |
|------|----|----|----|-----|
| Pure views / reads | yes | yes | yes | yes (do not gate views) |
| `governance_recovery` | yes | yes | yes | **yes (only mutation class)** |
| `pull_settled_claim` (opt-in) | yes | yes | yes | no |
| Generic `withdrawal` | yes | yes | **no** | no |

Notes:

- Modules must **not** apply `whenNotPaused` to pure view functions.
- `pull_settled_claim` is for **pull-based**, already-settled user value only. It must not create new protocol liability or double-claim.
- Generic `withdrawal` stays blocked at FINANCIAL+ so treasury/user egress can be frozen during a financial incident.

## Module integration

```solidity
import {EmergencyProtected} from ".../EmergencyProtected.sol";
import {EmergencyPauseOrdering} from ".../libraries/EmergencyPauseOrdering.sol";

function createClaim(...) external whenNotPaused(EmergencyPauseOrdering.OP_CLAIM_CREATION) {
    // ...
}
EmergencyProtected.whenNotPaused fail-closes if the controller is missing or the staticcall fails.
Recovery order (controlled recovery)
After DAO governance calls liftPause (level → NORMAL):
Step
Label
Intent
1
inventory_risk_surfaces
Confirm claim/stake/verification inventory and gates
2
inventory_financial_surfaces
Confirm treasury/reward/withdrawal accounting
3
finalise_recovery
Sets recoveryComplete
Steps must run in order via completeRecoveryStep. They do not grant settlement or treasury authority.
Roles (unchanged)
Role
Activate pause
Lift pause
Recovery steps
EMERGENCY_COUNCIL
L1–L3
No
No
DAO_GOVERNANCE
L1–L2 (and L3 with council rules in controller)
Yes
Via RECOVERY_EXECUTOR
TIMELOCK_CONTROLLER
L1 only (+ cooldown)
No
No
RECOVERY_EXECUTOR
—
—
Yes after lift
Migration / compatibility
keccak256("claim_creation") and other prior strings are byte-identical to library constants.
Existing modules using those strings need no storage migration.
Unknown operation ids remain allowed below SHUTDOWN (same as prior controller behaviour).
Residual risk
Modules that never call whenNotPaused are not enforced by this matrix.
Unknown op ids can still execute at L1/L2; prefer canonical constants.
Authority account binding for roles is owned by V2-SC-111; this issue does not rebind roles.
Non-goals
API / indexer / frontend settlement
Production addresses or secrets
Replacing V2-SC-067 scoped Gatekeeper drills
