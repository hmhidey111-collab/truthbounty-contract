# V2 Baseline Quick Start Guide

**Purpose:** Establish reproducible build environment for V2 baseline verification

---

## Prerequisites

- Node.js v18+ (v20 recommended)
- npm v8+
- Git
- Foundry (forge, cast, anvil)

---

## Quick Setup (Windows PowerShell)

### Step 1: Clean Environment

```powershell
# Remove existing node_modules and lock files
Remove-Item -Recurse -Force node_modules -ErrorAction SilentlyContinue
Remove-Item package-lock.json -ErrorAction SilentlyContinue
```

### Step 2: Install Dependencies

```powershell
# Install with legacy peer deps to resolve hardhat v3 compatibility
npm install --legacy-peer-deps
```

### Step 3: Verify Installation

```powershell
# Check installed versions
npx hardhat --version
forge --version
```

### Step 4: Compile Contracts

```powershell
# Hardhat compilation
npx hardhat compile

# Foundry compilation
forge build
```

### Step 5: Run Tests

```powershell
# Run all Hardhat tests
npx hardhat test

# Run Foundry tests (excluding fuzz/invariant)
forge test --no-match-path "test/{invariant,fuzz}/**"

# Run fuzz tests
forge test --match-path "test/fuzz/**"

# Run invariant tests
forge test --match-path "test/invariant/**"

# Generate gas report
$env:REPORT_GAS="true"; npx hardhat test

# Generate gas snapshots
forge snapshot
```

---

## Troubleshooting

### Issue: "hardhat not found"

**Solution:**
```powershell
npm install --legacy-peer-deps
```

### Issue: "@typechain/hardhat peer dependency conflict"

**Solution:** Already fixed in package.json
- `@typechain/hardhat` updated to `^10.0.0`
- Compatible with `hardhat@^3.16.0`

### Issue: "forge not found"

**Solution:** Install Foundry
```powershell
# Download foundryup installer
Invoke-WebRequest -Uri https://foundry.paradigm.xyz/foundryup.ps1 -OutFile foundryup.ps1

# Run installer
.\foundryup.ps1

# Verify installation
forge --version
```

### Issue: Compilation warnings about contract size

**Expected:** TruthBountyWeighted.sol exceeds 24KB limit
**Status:** LEGACY contract, non-blocking for V2
**Action:** No action required for V2 baseline

---

## V2-Specific Commands

### Compile Only V2 Contracts

```powershell
# V2 contracts are in contracts/v2/
# Hardhat compiles all contracts together, but you can test V2 specifically:

npx hardhat test test/v2/
npx hardhat test test/EvidenceRegistry.test.ts
npx hardhat test test/StakeVault.test.ts
npx hardhat test test/V2Interfaces.test.ts
```

### Run V2 Tests

```powershell
# Hardhat V2 tests
npx hardhat test test/v2/ test/EvidenceRegistry.test.ts test/StakeVault.test.ts test/V2Interfaces.test.ts

# Foundry V2 tests
forge test --match-path "test/StakeVault.t.sol"
```

---

## Expected Results

### Successful Compilation

```
Compiled 117 Solidity files successfully (evm target: cancun)
Generating typings for: 127 artifacts
Successfully generated 340 typings!
```

### Warnings (Expected & Safe)

- Contract size warning for TruthBountyWeighted.sol (LEGACY)
- Function mutability warnings (optimization suggestions, non-blocking)

### Test Success Criteria

- ✅ All unit tests pass
- ✅ All fuzz tests pass
- ✅ All invariant tests pass
- ✅ Gas snapshots generate without errors

---

## CI Simulation (Local)

Simulate the GitHub Actions CI pipeline locally:

```powershell
# Job 1: Lint (if configured)
npm run lint:sol --if-present
npm run lint --if-present

# Job 2: Test
forge build
forge test --no-match-path "test/{invariant,fuzz}/**"
npx hardhat test

# Job 3: Fuzz Tests
forge test --match-path "test/fuzz/**"

# Job 4: Invariant Tests
forge test --match-path "test/invariant/**"

# Job 5: Gas Check
forge snapshot --check
```

---

## Environment Variables (.env)

Create `.env` file from `.env.example`:

```powershell
Copy-Item .env.example .env
```

Required for deployment/interaction scripts only. Not required for compilation/testing.

---

## Verification Checklist

- [ ] node_modules installed successfully
- [ ] `npx hardhat --version` returns version
- [ ] `forge --version` returns version
- [ ] `npx hardhat compile` succeeds (117 files)
- [ ] `forge build` succeeds
- [ ] `npx hardhat test` passes all tests
- [ ] `forge test` passes all tests
- [ ] No Stellar/Soroban dependencies found
- [ ] V2 contracts compile without errors

---

## Next Steps After Setup

1. Review `V2_BASELINE_AUDIT_REPORT.md` for full audit findings
2. Verify all acceptance criteria are met
3. Get human maintainer approval
4. Proceed to V2-SC-042, V2-SC-043, V2-SC-044

---

## Support

For issues during setup:
1. Check this Quick Start Guide
2. Review V2_BASELINE_AUDIT_REPORT.md Section 11 (Critical Issues)
3. Verify toolchain versions match requirements
4. Check package.json for correct dependency versions

---

**Last Updated:** September 24, 2026
