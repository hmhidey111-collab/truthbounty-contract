# Legacy V1 Contracts

**Status:** 🟡 LEGACY / MAINTENANCE MODE  
**Protocol Version:** 1.x  
**Last Updated:** September 24, 2026

---

## Directory Purpose

This directory contains **V1 (legacy) protocol contracts** that are in maintenance mode. These contracts are functional and may still be deployed on testnets or in production, but new feature development should target V2.

---

## Known Issues

### Contract Size Violations

| Contract | Size | Limit | Status |
|----------|------|-------|--------|
| **TruthBountyWeighted.sol** | 25,167 bytes | 24,576 bytes | ⚠️ EXCEEDS LIMIT |

**Impact:** Cannot deploy to mainnet without optimization or library extraction.

**Recommendation:** Migrate functionality to V2 modular architecture instead of optimizing V1.

---

## Legacy Contract Inventory

### Core V1 Contracts

| Contract | Status | Notes |
|----------|--------|-------|
| `TruthBounty.sol` | 🟡 LEGACY | Original core contract |
| `TruthBountyClaims.sol` | 🟡 LEGACY | Claims management |
| `TruthBountyWeighted.sol` | 🟡 LEGACY | Weighted voting (SIZE ISSUE) |
| `staking.sol` | 🟡 LEGACY | V1 staking |
| `WeightedStaking.sol` | 🟡 LEGACY | V1 weighted staking |
| `StakeVault.sol` | 🟡 LEGACY | V1 vault (replaced by v2/StakeVault.sol) |

### V1 Support Modules

| Directory/File | Status | Purpose |
|---------------|--------|---------|
| `reputation/` | 🟡 LEGACY | V1 reputation system |
| `reward/` | 🟡 LEGACY | V1 reward distribution |
| `governance/` | 🟡 LEGACY | V1 governance |
| `fees/` | 🟡 LEGACY | V1 fee management |
| `insurance/` | 🟡 LEGACY | V1 insurance fund |
| `tokenomics/` | 🟡 LEGACY | V1 tokenomics |
| `treasury/` | 🟡 LEGACY | V1 treasury |
| `settlement/` | 🟡 LEGACY | V1 settlement |
| `disputes/` | 🟡 LEGACY | V1 disputes |

### Deprecated Modules

| Directory | Status | Notes |
|-----------|--------|-------|
| `crosschain/` | 🔴 DEPRECATED | Early cross-chain experiments |
| `bootstrap/` | 🟡 LEGACY | Initial deployment helpers |

---

## V1 Deployment Status

V1 contracts may be deployed on:
- ✅ Local hardhat networks
- ✅ Optimism Sepolia (testnet)
- ⚠️ Optimism Mainnet (with size limitations)

**Mainnet Deployment Warning:** `TruthBountyWeighted.sol` cannot be deployed due to size limit violation.

---

## Maintenance Policy

### DO ✅

- Fix critical security issues
- Apply emergency patches
- Maintain existing deployments
- Document known issues
- Test before any deployment

### DON'T ❌

- Add new features (use V2 instead)
- Refactor without V2 migration plan
- Deploy TruthBountyWeighted.sol to mainnet
- Break backward compatibility unnecessarily

---

## Migration to V2

### Why Migrate?

1. **Modularity:** V2 uses independent, composable modules
2. **Size Limits:** V2 modules stay well under 24KB limit
3. **Multi-Asset:** V2 supports multiple tokens natively
4. **Gas Efficiency:** V2 is optimized for lower gas costs
5. **Upgradability:** V2 uses UUPS proxy pattern per module
6. **Content Addressing:** V2 uses deterministic, verifiable IDs

### Migration Path

For projects using V1 contracts:

1. **Assess Current Usage**
   - Identify V1 contracts in use
   - Document state and data dependencies
   - Plan data migration strategy

2. **Deploy V2 Modules**
   - Deploy canonical V2 contracts from `contracts/v2/`
   - Configure module registry
   - Set up access controls

3. **Migrate State**
   - Export critical state from V1
   - Import into V2 using migration scripts
   - Verify data integrity

4. **Gradual Transition**
   - Run V1 and V2 in parallel initially
   - Migrate users/verifiers gradually
   - Sunset V1 after full migration

### V1 to V2 Mapping

| V1 Contract | V2 Equivalent | Status |
|-------------|---------------|--------|
| TruthBounty.sol | ClaimsRegistry (pending) | ⏳ V2 implementation needed |
| EvidenceManager.sol | v2/EvidenceRegistry.sol | ✅ V2 implemented |
| StakeVault.sol | v2/StakeVault.sol | ✅ V2 implemented |
| WeightedStaking.sol | v2/StakeVault.sol + reputation | ✅ V2 implemented |
| DisputeResolution.sol | v2/DisputeResolver (pending) | ⏳ V2 implementation needed |

---

## Testing Legacy Contracts

### Running V1 Tests

```bash
# All tests (includes V1)
npx hardhat test

# Exclude V2-specific tests to focus on V1
npx hardhat test --grep -v "V2|Evidence Registry|StakeVault"

# Foundry tests
forge test --no-match-path "test/v2/**"
```

### Test Files

Legacy tests are spread throughout the `test/` directory. V1-specific tests include:

```
test/TruthBountyClaims.test.ts
test/TruthBountyWeighted.test.ts
test/WeightedStaking.test.ts
test/DisputeResolution.test.ts
test/ReputationEngine.test.ts
test/RewardEngine.distribution.test.ts
test/TokenomicsEngine.gas.test.ts
... and many more
```

---

## Contract Size Mitigation (If Required)

If TruthBountyWeighted.sol MUST be deployed to mainnet:

### Option 1: Library Extraction

```solidity
// Extract to separate library
library ReputationValidation {
    function validateReputationFreshness(...) external { ... }
    function checkReputationStaleness(...) external view returns (...) { ... }
    function getLastReputationSnapshot(...) external view returns (...) { ... }
}

// In TruthBountyWeighted, delegate to library
function checkReputationStaleness(...) external view returns (...) {
    return ReputationValidation.checkReputationStaleness(...);
}
```

### Option 2: Increase Optimizer Runs

```javascript
// hardhat.config.ts
optimizer: {
  enabled: true,
  runs: 1000  // Increase from 200
}
```

**Warning:** Higher runs = smaller deployment size but higher execution gas.

### Option 3: Remove Features

Remove recently added features (e.g., reputation staleness validation) to reduce size. Not recommended as it reduces functionality.

---

## Security Considerations

### Known Issues

1. **TruthBountyWeighted Size:** Cannot deploy to mainnet
2. **Legacy Architecture:** Monolithic contracts harder to audit/upgrade
3. **Single Token:** V1 locked to single protocol token

### Security Practices

- ✅ All V1 contracts use OpenZeppelin libraries
- ✅ ReentrancyGuard applied where needed
- ✅ Pausable functionality for emergencies
- ✅ Role-based access control (RBAC)

### Recommended Actions

- Run static analysis: `slither .`
- External audit before mainnet deployment
- Comprehensive testing before any upgrade
- Monitor for exploits in similar contracts

---

## Deprecation Timeline

### Current Status (Sept 2026)

- V1: Maintenance mode
- V2: Baseline established, feature development starting

### Planned Timeline

- **Q4 2026:** V2 core modules complete
- **Q1 2027:** V2 testnet deployment
- **Q2 2027:** V2 mainnet deployment
- **Q3 2027:** V1 migration begins
- **Q4 2027:** V1 sunset (if migration successful)

---

## Documentation

For V1 contract documentation:
- Original README.md (includes V1 usage examples)
- NatSpec comments in contract files
- Test files for usage examples
- Deployment scripts in `scripts/`

For migration to V2:
- See `contracts/v2/CANONICAL_V2.md`
- Review `V2_BASELINE_AUDIT_REPORT.md`

---

## Support

For V1-related questions:
1. Check this LEGACY_V1.md file
2. Review contract NatSpec documentation
3. Examine test files for usage examples
4. Consider migrating to V2 instead

---

**These contracts are in maintenance mode.**  
**New development should target V2 in contracts/v2/**
