# Economic Parameter Safety Envelopes (V2)

## Overview

The V2 protocol implements machine-enforced safety envelopes for all core economic parameters. These hard-coded bounds protect the protocol from misconfigurations, governance attacks, and catastrophic edge cases. 

Parameter intake points, such as `ParameterVersionRegistry.proposeNewVersion()`, validate all incoming parameters against these bounds. Values outside the defined envelopes will strictly revert the transaction; there are no fail-open paths.

## Envelope Constants & Economic Rationale

### 1. Stakes
- **`MIN_SAFE_STAKE` (1e18)**: Prevents sybil dust attacks.
- **`MAX_SAFE_STAKE` (1,000,000e18)**: Bounds a single actor's outsized influence over the network's consensus.

### 2. Bonds & Bounties
- **`MIN_SAFE_BOND` (1e18)**: Ensures challenges and bounties carry meaningful economic weight to disincentivize spam.
- **`MAX_SAFE_BOND` (100,000e18)**: Ensures challenges remain accessible and not overly punitive, preventing "whale-only" dispute mechanics.

### 3. Durations
- **`MIN_SAFE_DURATION` (1 hours)**: Allows sufficient time for network propagation, response, and oracle synchronization.
- **`MAX_SAFE_DURATION` (30 days)**: Prevents indefinite lockups of protocol operations or stalled settlements.

### 4. Caps & Thresholds
- **`MIN_SAFE_WEIGHT_CAP` (1%)**: Prevents zero-weight edge cases.
- **`MIN_SAFE_PARTICIPATION_THRESHOLD` (1%)**: Ensures a bare minimum level of network engagement for valid settlements.
- **`MIN_SAFE_CONFIDENCE_THRESHOLD` (51%)**: Guarantees simple majority consensus.
- **Maximum Caps and Thresholds (100%)**: Upper bound limit for BPS (10000).

### 5. Allocations
- **`MAX_SAFE_ALLOCATION` (100%)**: Any single economic pool cannot be allocated more than 100%, and the sum of all allocations must be exactly 10,000 BPS (100%).

### 6. Multipliers
- **`MIN_SAFE_MULTIPLIER` (1x)**: Prevents negative yield scenarios.
- **`MAX_SAFE_MULTIPLIER` (10x)**: Bounds hyper-inflationary reward emissions.
- **`MIN_SAFE_APPEAL_MULTIPLIER` (1x)**: Escalating appeal costs must strictly escalate or remain identical.
- **`MAX_SAFE_APPEAL_MULTIPLIER` (5x)**: Bounds runaway exponential costs for appeals.

## Migration Impact & Compatibility

**Compatibility with Active Claims**:
- Existing claims are unaffected by parameter updates. They strictly use the parameter version active at the time of claim creation (frozen state).
- New claims will automatically inherit the newly activated parameter versions if they comply with the safety envelopes.

**Migration**:
- No migration is necessary for previous V1/V2 deployments unless their existing parameter set violates the newly established safety envelopes. In that case, governance must propose a valid set of parameters in `ParameterVersionRegistry` that complies with the bounds.

## Enforcement in Logic

Validation occurs directly in the `_validateParameterBounds(EconomicParameters memory parameters)` function within `ParameterVersionRegistry.sol`. 

Revert scenarios are backed by custom errors (e.g., `InvalidStakeBounds`, `NonZeroDurationRequired`) ensuring maximum predictability during simulations and runtime execution.
