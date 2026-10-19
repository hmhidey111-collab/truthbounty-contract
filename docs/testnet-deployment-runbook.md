# Testnet Deployment and Recovery Runbook (V2-SC-130)

## Overview

This runbook documents the complete testnet deployment, smoke test, pause drill, governed change, indexer replay check, and recovery exercise procedures for the TruthBounty V2 protocol.

## Prerequisites

- All CI checks passing
- Unit tests passing
- Invariant tests passing
- Fuzz tests passing
- Security review completed
- Dependencies V2-SC-111 and V2-SC-121 verified complete

## Deployment Configuration

### Testnet Environment (Optimism Sepolia)

| Parameter | Value |
|-----------|-------|
| Chain ID | 11155420 |
| Environment | testnet |
| Gas Budget | See `config/gas-budgets.json` |
| Block Gas Limit | 30,000,000 |
| Recommended TX Gas Ceiling | 12,000,000 |

### Deployment Artifacts

All deployment artifacts are recorded in `deployments/config/testnet.json`:
- Governance Controller address
- Token address
- Oracle address
- ClaimRegistry address
- TruthBountyWeighted address
- VerificationAggregator address
- ProvisionalSettlementEngine address
- AppealVerificationRound address

## Deployment Steps

### 1. Verify Deployment Configuration

```bash
# Validate environment variables
export ADMIN_ADDRESS=<admin-address>
export OPTIMISM_SEPOLIA_RPC_URL=<rpc-url>

# Run deployment readiness audit
npx hardhat run scripts/auditReleaseReadiness.ts --network optimismSepolia
```

### 2. Deploy Canonical V2 Suite

```bash
# Using Hardhat Ignition
npx hardhat ignition deploy ignition/modules/CanonicalV2.ts --network optimismSepolia

# Or using Foundry script
forge script script/deploy/Deploy.s.sol --rpc-url $OPTIMISM_SEPOLIA_RPC_URL --broadcast
```

### 3. Configure Governance Ownership

- Verify `GovernanceController` has correct role assignments
- Verify `EmergencyController` has correct role assignments
- Verify `ParameterVersionRegistry` genesis version is active
- Verify `ProtocolUpgradeManager` module registry is empty

### 4. Configure Treasury Ownership

- Set treasury role on governance
- Verify treasury address is non-zero
- Verify no production secrets in configuration

### 5. Verify Roles and Permissions

```typescript
// Verify all roles are correctly assigned
const REGISTRY_UPDATER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("REGISTRY_UPDATER_ROLE"));
const hasRole = await claimRegistry.hasRole(REGISTRY_UPDATER_ROLE, settlementEngine.address);
```

### 6. Record Deployment Artifacts

```bash
# Save deployment manifest
forge script script/deploy/Deploy.s.sol --network testnet --broadcast
```

## Smoke Test Procedure

### Test Matrix

| Test | Description | Expected Result |
|------|-------------|-----------------|
| Full Claim Lifecycle | Create, stake, vote, settle | Claim settles correctly |
| Emergency Pause/Recovery | Activate L1, lift, recover | Protocol returns to normal |
| Governed Parameter Change | Request, timelock, execute | Parameter updated after delay |
| Upgrade Flow | Register, propose, approve, execute | Version incremented |
| Cross-module Wiring | Verify all references | All addresses non-zero |

### Smoke Test Execution

```bash
# Run all smoke tests
forge test --match-test "test_smoke_" --broadcast

# Run with verbose output
forge test --match-test "test_smoke_" -vvv
```

## Pause Drill Procedure

### Pause Levels

| Level | Name | Effect | Authorized Roles |
|-------|------|--------|-----------------|
| 0 | Normal | Full operation | - |
| 1 | HighRisk | Pause claims, staking, verification | EMERGENCY_COUNCIL, DAO_GOVERNANCE, TIMELOCK_CONTROLLER |
| 2 | Financial | Pause rewards, treasury, withdrawals | EMERGENCY_COUNCIL, DAO_GOVERNANCE |
| 3 | Shutdown | Global emergency shutdown | EMERGENCY_COUNCIL, DAO_GOVERNANCE |

### Pause Drill Steps

1. **Activate L1**: Call `EmergencyController.activatePause(1, reason, proposalRef)`
2. **Verify Block**: Confirm `isOperationAllowed` returns false for restricted operations
3. **Lift Pause**: Call `EmergencyController.liftPause(proposalRef)` (DAO governance only)
4. **Complete Recovery**: Call `EmergencyController.completeRecoveryStep()` sequentially 3 times
5. **Verify Normal**: Confirm `currentPauseLevel()` returns 0

### Failure Modes

| Failure | Expected Behavior |
|---------|-------------------|
| Emergency Council tries to lift | Revert: "Only DAO governance can lift pause" |
| Decrease pause level | Revert: "Already at level" |
| Lift when not paused | Revert: "Protocol not paused" |
| Recovery without pause | Revert: "Protocol is still paused" |
| Double recovery complete | Revert: "Recovery already complete" |
| Unauthorized recovery | Revert: "Not authorised for recovery" |

## Governed Change Procedure

### Parameter Update Flow

1. **Request**: Call `GovernanceController.requestParameterUpdate(paramType, newValue)`
2. **Timelock**: Wait for `proposalTimelock` to elapse (minimum 1 hour)
3. **Execute**: Call `GovernanceController.executeParameterUpdate(proposalId)`
4. **Verify**: Confirm parameter value updated

### Address Parameter Update Flow

1. **Request**: Call `GovernanceController.requestAddressParameterUpdate(paramType, newAddress)`
2. **Validation**: Zero-address check enforced
3. **Timelock**: Wait for timelock to elapse
4. **Execute**: Call `GovernanceController.executeParameterUpdate(proposalId)`

### Upgrade Authorization Flow

1. **Request**: Call `GovernanceController.requestUpgradeAuthorization(newImplementation)`
2. **Timelock**: Wait for timelock
3. **Execute**: Call `GovernanceController.executeUpgrade(proposalId)`

### Cancellation

- Proposer or admin can cancel pending proposals
- Only before execution
- Emits `ParameterUpdateCancelled` event

## Indexer Replay Check

### Event Schema Validation

All events follow the canonical V1 schema (Specification §20):
- Each event has `uint64 timestamp` and `uint16 version` trailing fields
- Maximum 3 indexed fields per event (EVM limit)
- Event schema version is always 1

### Replay Verification Steps

1. **Event Emission**: Verify all 16 canonical event families emit correctly
2. **Topic Count**: Verify indexed fields ≤ 3 for all events
3. **Schema Version**: Verify `EVENT_SCHEMA_VERSION` = 1 in all events
4. **Storage Reconciliation**: Verify storage state matches event logs
5. **Deterministic Ordering**: Verify claim IDs are monotonically increasing
6. **No Duplicates**: Verify each event is uniquely identifiable

### Indexer Configuration

```typescript
const config: IndexerConfig = {
    chainId: 11155420,
    rpcUrl: process.env.OPTIMISM_SEPOLIA_RPC_URL,
    contracts: [{ name: "TruthBountyWeighted", address: "...", abi: TRUTH_BOUNTY_ABI }],
    startBlock: 1,
    checkpointInterval: 100,
    maxReorgDepth: 12,
    confirmations: 0,
};
```

## Recovery Exercise

### Recovery Scenario Matrix

| Scenario | Steps | Residual Risk | Evidence |
|----------|-------|---------------|----------|
| Emergency Pause L1 | Activate → Verify → Lift → Recover | R-001: Council cannot unpause | Pause/Lift events |
| Financial Pause L2 | Activate → Verify financial ops blocked → Lift → Recover | R-003: Timelock delays | Pause/Lift events |
| Full Shutdown L3 | Activate → Verify all ops blocked → Lift → Recover | R-001: Governance-only recovery | Full audit trail |
| Upgrade Compromise | Register → Propose → Execute → Rollback | R-002: Single rollback target | Upgrade/Rollback events |
| Storage Incompatibility | Propose → Attest false → Validate migration → Approve | R-005: Off-chain validation | StorageAttested events |
| Governance Rejection | Request → Cancel → Verify no state change | None | Cancel event |
| Timelock Expiration | Request → Verify reversion → Fast-forward → Execute | R-003: Delay prevents rapid response | Execute event |

### Recovery Procedure (Sequential Steps)

1. **Step 1**: Verify all claims and state
2. **Step 2**: Validate contract balances and storage
3. **Step 3**: Resume normal operations

Recovery is only accessible after pause is fully lifted (`currentPauseLevel() == 0`).
Only `RECOVERY_EXECUTOR` role can complete recovery steps.

## Migration Impact and Compatibility

### Legacy Contract Exclusion

| Contract | Status | Notes |
|----------|--------|-------|
| TruthBountyClaims | DEPRECATED | Not referenced in canonical interfaces |
| TruthBountyWeighted | TRANSITIONAL_NON_CANONICAL | Use ClaimRegistry for canonical claims |
| TruthBountyToken | CANONICAL | ERC20 token with staking |
| ClaimRegistry | CANONICAL | Core claim management |
| ParameterVersionRegistry | CANONICAL | Versioned parameter management |
| ProtocolUpgradeManager | CANONICAL | Upgrade and rollback framework |

### Storage Compatibility

- All upgrades must pass `StorageCompatibilityValidator` checks
- Minor/patch upgrades: append-only layout, storage attested
- Major upgrades: validated migration hash required
- `StorageCompatibilityValidator` tracks registered layouts

### Parameter Version Registry

- Claims are frozen to their creation version
- New claims use the current active version
- `getParametersForClaim(claimId)` returns frozen parameters
- `currentActiveVersionId()` tracks the active version

## Security Architecture

### Trust Boundaries

- **Optimism/EVM contracts**: Authoritative for protocol mutation and settlement
- **No API/indexer/frontend**: May gain settlement or treasury authority
- **No guardian/deployer/test harness**: May gain settlement or treasury authority

### Failure Mode Rejection

| Pattern | Status |
|---------|--------|
| Zero-address dependencies | Rejected |
| Unsafe token assumptions | Rejected |
| Unbounded loops | Rejected |
| Replay paths | Rejected |
| Fail-open authorization | Rejected |

### Preservation Requirements

- Asset conservation (token supply preserved)
- Single settlement (no double claim)
- Immutable active-claim parameters
- Timelocked governance
- Deterministic rounding (Math.mulDiv)
- Replayable event semantics

## Residual Risk Register

| ID | Risk | Impact | Mitigation |
|----|------|--------|------------|
| R-001 | Emergency Council cannot lift pause | Recovery delay | DAO governance has lifting authority |
| R-002 | Only single previous implementation retained | Limited rollback depth | Fresh proposal for deeper rollback |
| R-003 | Timelock delays may prevent rapid response | Delayed recovery | Emergency Council can pause faster |
| R-004 | Recovery executor role management | Off-chain dependency | Secure key management practices |
| R-005 | Storage layout changes require off-chain validation | Upgrade risk | CI validation tooling in place |

## Gas Budgets

See `config/gas-budgets.json` for configured gas limits:
- Claim Creation: 350,000 gas
- Verification Vote: 350,000 gas
- Provisional Settlement: 250,000 gas
- Challenge Open: 120,000 gas
- Finalization: 200,000 gas

## Verification Checklist

- [ ] All 16 canonical event families emit correctly
- [ ] Event schema version is 1
- [ ] All indexed fields ≤ 3 per event
- [ ] Storage reconciliation matches event logs
- [ ] No duplicate events
- [ ] Deterministic claim ID ordering
- [ ] Asset conservation verified
- [ ] No zero-address dependencies
- [ ] Timelock enforcement verified
- [ ] Pause/recovery cycle complete
- [ ] Upgrade/rollback flow verified
- [ ] Governance parameter changes traceable
- [ ] All gas usage within budget
- [ ] No unbounded loops
- [ ] No replay path vulnerabilities
- [ ] All access control checks pass
- [ ] No fail-open authorization
- [ ] Legacy contracts properly excluded

## Acceptance Criteria Mapping

| AC | Description | Test Coverage |
|----|-------------|---------------|
| AC-1 | Authoritative behavior documented | TestnetDeployment, RecoveryRunbook |
| AC-2 | Minimum production contracts implemented | TestnetDeployment, TestnetInvariants |
| AC-3 | Interfaces, storage, events mapped | TestnetReconciliationDrift |
| AC-4 | Bounded execution, pull-based transfers | TestnetGasBudgets, TestnetInvariants |
| AC-5 | Migration impact documented | RecoveryRunbook |
| AC-6 | Positive/negative/boundary tests | TestnetDeployment |
| AC-7 | Stateful fuzz/invariant coverage | TestnetInvariants, TestnetFuzz |
| AC-8 | Regression tests for legacy defects | TestnetFuzz, AuditFixes |
| AC-9 | Event/storage reconciliation | TestnetIndexerReplay, TestnetReconciliationDrift |
| AC-10 | Full Foundry build and analysis | All test files |

## Evidence Log

### Independent Review Approval

- **Required**: Independent exact-head human maintainer approval
- **Status**: Pending manual review
- **Merge Policy**: Automatic merge prohibited
- **Risk Level**: Protocol-critical
- **Complexity**: High (200 points)

### Test Execution Results

All tests must pass before deployment:
```bash
forge build
forge test --match-test "test_smoke_" 
forge test --match-test "test_gas_"
forge test --match-test "test_fuzz_"
forge test --match-test "invariant_"
forge test --match-test "test_recovery_"
forge test --match-test "test_reconciliation_"
forge test --match-test "test_deploy_"
```

## Maintenance Notes

- This runbook is maintained alongside the protocol
- All changes to deployment configuration require runbook update
- Recovery exercises should be rehearsed quarterly
- Emergency contact procedures are maintained off-chain
- Gas budgets should be reviewed with each network upgrade
