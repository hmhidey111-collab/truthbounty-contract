# Coverage Quality Gates

## Overview

This document describes the coverage quality gates established for the TruthBounty V2 protocol. These gates enforce minimum coverage thresholds across multiple dimensions to prevent superficial tests from satisfying critical-path requirements.

## Quality Gate Dimensions

### 1. Line Coverage (Threshold: 85%)
Measures the percentage of executable lines that are executed during testing.
- **Target**: 85% minimum
- **Critical Paths**: All core protocol contracts must meet this threshold

### 2. Branch Coverage (Threshold: 80%)
Measures the percentage of decision points (if/else, ternary operators, etc.) that are evaluated in both directions.
- **Target**: 80% minimum
- **Critical Paths**: All core protocol contracts must meet this threshold

### 3. Function Coverage (Threshold: 90%)
Measures the percentage of functions that are called during testing.
- **Target**: 90% minimum
- **Critical Paths**: All core protocol contracts must meet this threshold

### 4. Invariant-State Coverage (Threshold: 100% passing)
Measures whether all invariant tests pass. Invariant tests validate protocol-wide properties that must hold under all possible states.
- **Target**: 100% of invariant tests passing
- **Test Location**: `test/invariant/**`

### 5. Event-Transition Coverage (Threshold: 100% passing)
Measures whether all event-related tests pass. These tests validate that events are emitted correctly during state transitions.
- **Target**: 100% of event tests passing
- **Test Locations**: 
  - `test/**/*Event*.test.ts`
  - `test/**/*Event*.t.sol`
  - `test/CanonicalEvents.test.ts`
  - `test/EventArchitecture.test.ts`
  - `test/EventSchemaConsistency.test.ts`

## Configuration

### Foundry Configuration (`foundry.toml`)

```toml
[coverage]
# Coverage quality gates - enforce minimum thresholds to prevent superficial tests
# from satisfying critical-path requirements
line_threshold = 85
branch_threshold = 80
function_threshold = 90

# Exclude mocks, tests, and generated files from coverage
skip = [
    "test/**",
    "script/**",
    "contracts/mocks/**",
    "contracts/test/**",
    "contracts/bootstrap/**",
    "contracts/upgrade/**",
    "contracts/performance/**",
    "lib/**",
    "@openzeppelin/**",
]

# Report format
reports = ["lcov", "summary", "json"]
```

### Quality Gate Configuration (`config/coverage-quality-gate.json`)

```json
{
  "thresholds": {
    "line": 85,
    "branch": 80,
    "function": 90
  },
  "criticalPaths": [
    "contracts/TruthBounty.sol",
    "contracts/TruthBountyWeighted.sol",
    ...
  ],
  "excludedPaths": [
    "test/**",
    "script/**",
    "contracts/mocks/**",
    ...
  ],
  "invariantTestPaths": [
    "test/invariant/**"
  ],
  "eventTestPaths": [
    "test/**/*Event*.test.ts",
    "test/**/*Event*.t.sol",
    "test/CanonicalEvents.test.ts",
    "test/EventArchitecture.test.ts",
    "test/EventSchemaConsistency.test.ts"
  ]
}
```

## Critical Path Contracts

The following contracts are designated as critical paths and must meet all coverage thresholds:

| Contract | Description |
|----------|-------------|
| `TruthBounty.sol` | Core claim lifecycle and settlement |
| `TruthBountyWeighted.sol` | Weighted voting and staking |
| `TruthBountyClaims.sol` | Claim management |
| `WeightedStaking.sol` / `staking.sol` | Staking logic |
| `ReputationUpdateEngine.sol` | Reputation updates |
| `ReputationEngine.sol` | Reputation calculation |
| `ReputationSnapshot.sol` / `ReputationSnapshotEngine.sol` | Reputation snapshots |
| `RewardEngine.sol` | Reward distribution |
| `TreasuryAccounting.sol` / `TreasuryManagement.sol` | Treasury operations |
| `ClaimRegistry.sol` / `ClaimLifecycle.sol` | Claim registry and lifecycle |
| `DisputeResolution.sol` | Dispute handling |
| `VerificationRoundManager.sol` / `VerificationSubmission.sol` | Verification rounds |
| `VerificationAggregator.sol` / `VerificationAggregation.sol` | Verification aggregation |
| `EvidenceManager.sol` | Evidence management |
| `FeeManager.sol` | Fee management |
| `ProvisionalSettlementEngine.sol` | Settlement logic |
| `VerifierSlashing.sol` | Slashing mechanism |
| `GovernanceController.sol` / `EmergencyController.sol` | Governance |
| `GovernanceOwnable.sol` / `ParameterVersionRegistry.sol` | Governance modules |
| `ResolverRoleTimelock.sol` | Role management |

## Running Coverage Quality Gates Locally

### Prerequisites
- Foundry installed (`forge`)
- Node.js with TypeScript (`npx ts-node`)

### Commands

```bash
# Generate coverage report
forge coverage --report lcov --report summary --skip script

# Run quality gate check
npx ts-node scripts/coverage-quality-gate.ts

# Or run both together
forge coverage --report lcov --report summary --skip script && npx ts-node scripts/coverage-quality-gate.ts
```

### Expected Output

```
🛡️  Coverage Quality Gate
==========================
Line threshold: 85%
Branch threshold: 80%
Function threshold: 90%

📊 Coverage Results:
  Line Coverage:     87.45%
  Branch Coverage:   82.10%
  Function Coverage: 91.23%

🎯 Critical Path Coverage:
  ✅ contracts/TruthBounty.sol (89.2%)
  ✅ contracts/TruthBountyWeighted.sol (91.5%)
  ...

🔬 Invariant-State Coverage:
  Invariant Tests Passing: 100.0%
  ✅ All invariant tests passing

📡 Event-Transition Coverage:
  Event Tests Passing: 100.0%
  ✅ All event transition tests passing

==========================
🎉 All coverage quality gates PASSED!
```

## CI Integration

The coverage quality gate runs as a separate job in the CI pipeline (`.github/workflows/ci.yml`):

```yaml
coverage-quality-gate:
  name: Coverage Quality Gate
  runs-on: ubuntu-latest
  needs: test
  steps:
    - uses: actions/checkout@v7
      with:
        submodules: recursive
    - uses: actions/setup-node@v7
      with:
        node-version: 20
    - uses: actions/cache@v6
      with:
        path: node_modules
    - run: npm ci
    - uses: foundry-rs/foundry-toolchain@v1
      with:
        version: latest
    - run: forge coverage --report lcov --report summary --skip script
    - run: npx ts-node scripts/coverage-quality-gate.ts
```

## Anti-Gaming Measures

The quality gates include several measures to prevent superficial tests from satisfying requirements:

1. **Excluded Paths**: Mocks, test files, bootstrap, upgrade, and performance contracts are excluded from coverage calculations
2. **Critical Path Enforcement**: Core protocol contracts are explicitly checked for coverage
3. **Multiple Dimensions**: Line, branch, AND function coverage must all pass
4. **Invariant Tests**: Protocol-wide invariants must be tested and passing
5. **Event Tests**: Event emission during state transitions must be validated

## Adding New Critical Path Contracts

To add a new contract to the critical paths list:

1. Add the contract path to `criticalPaths` in `config/coverage-quality-gate.json`
2. Ensure the contract has comprehensive tests covering:
   - All public/external functions (function coverage)
   - All branches in conditional logic (branch coverage)
   - All executable lines (line coverage)
   - Invariant properties (invariant tests)
   - Event emissions (event tests)

## Troubleshooting

### Line Coverage Below Threshold
- Add tests for uncovered lines
- Focus on error paths and edge cases
- Ensure all `require`/`revert` conditions are tested

### Branch Coverage Below Threshold
- Test both true/false branches of all conditionals
- Test edge cases for loops and conditionals
- Add tests for `if/else` and ternary operator branches

### Function Coverage Below Threshold
- Ensure all public/external functions are called in tests
- Test internal functions through public interfaces
- Add tests for fallback/receive functions if applicable

### Invariant Tests Failing
- Review the failing invariant to understand the protocol property
- Fix the underlying issue or add proper test setup
- Ensure invariant tests are deterministic

### Event Tests Failing
- Verify events are emitted with correct parameters
- Check event ordering in complex transactions
- Ensure events are emitted for all state transitions

## Migration Guide

### From No Coverage Gates

1. Add the coverage configuration to `foundry.toml`
2. Create `config/coverage-quality-gate.json` with your critical paths
3. Run `forge coverage --report lcov --report summary --skip script` to baseline
4. Run `npx ts-node scripts/coverage-quality-gate.ts` to see current status
5. Improve coverage until all gates pass
6. Add the CI job to your workflow

### Upgrading Thresholds

1. Update thresholds in both `foundry.toml` and `config/coverage-quality-gate.json`
2. Run the quality gate locally to verify
3. Update CI if needed
4. Commit changes

## References

- [Foundry Coverage Documentation](https://book.getfoundry.sh/reference/forge/forge-coverage)
- [LCOV Format Specification](http://ltp.sourceforge.net/coverage/lcov/geninfo.1.php)
- [Protocol Invariants Documentation](./verification/protocol-invariants.md)
- [Event Architecture Documentation](./event-architecture.md)