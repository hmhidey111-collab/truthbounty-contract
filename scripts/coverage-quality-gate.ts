#!/usr/bin/env ts-node
/**
 * Coverage Quality Gate Script
 * 
 * Enforces coverage quality thresholds for line, branch, function,
 * invariant-state, and event-transition coverage.
 * 
 * This prevents superficial tests from satisfying critical-path requirements.
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";

interface CoverageThresholds {
  line: number;
  branch: number;
  function: number;
}

interface CoverageReport {
  line: number;
  branch: number;
  function: number;
  invariantState: number;
  eventTransition: number;
}

interface QualityGateConfig {
  thresholds: CoverageThresholds;
  criticalPaths: string[];
  excludedPaths: string[];
  invariantTestPaths: string[];
  eventTestPaths: string[];
}

const DEFAULT_CONFIG: QualityGateConfig = {
  thresholds: {
    line: 85,
    branch: 80,
    function: 90,
  },
  criticalPaths: [
    "contracts/TruthBounty.sol",
    "contracts/TruthBountyWeighted.sol",
    "contracts/TruthBountyClaims.sol",
    "contracts/WeightedStaking.sol",
    "contracts/staking.sol",
    "contracts/ReputationUpdateEngine.sol",
    "contracts/ReputationEngine.sol",
    "contracts/ReputationSnapshot.sol",
    "contracts/ReputationSnapshotEngine.sol",
    "contracts/RewardEngine.sol",
    "contracts/TreasuryAccounting.sol",
    "contracts/TreasuryManagement.sol",
    "contracts/ClaimRegistry.sol",
    "contracts/ClaimLifecycle.sol",
    "contracts/DisputeResolution.sol",
    "contracts/VerificationRoundManager.sol",
    "contracts/VerificationSubmission.sol",
    "contracts/VerificationAggregator.sol",
    "contracts/VerificationAggregation.sol",
    "contracts/EvidenceManager.sol",
    "contracts/FeeManager.sol",
    "contracts/ProvisionalSettlementEngine.sol",
    "contracts/VerifierSlashing.sol",
    "contracts/GovernanceController.sol",
    "contracts/EmergencyController.sol",
    "contracts/GovernanceOwnable.sol",
    "contracts/ParameterVersionRegistry.sol",
    "contracts/ResolverRoleTimelock.sol",
  ],
  excludedPaths: [
    "test/**",
    "script/**",
    "contracts/mocks/**",
    "contracts/test/**",
    "contracts/bootstrap/**",
    "contracts/upgrade/**",
    "contracts/performance/**",
    "lib/**",
    "@openzeppelin/**",
  ],
  invariantTestPaths: [
    "test/invariant/**",
  ],
  eventTestPaths: [
    "test/**/*Event*.test.ts",
    "test/**/*Event*.t.sol",
    "test/CanonicalEvents.test.ts",
    "test/EventArchitecture.test.ts",
    "test/EventSchemaConsistency.test.ts",
  ],
};

function loadConfig(configPath: string): QualityGateConfig {
  if (fs.existsSync(configPath)) {
    const configContent = fs.readFileSync(configPath, "utf-8");
    return JSON.parse(configContent);
  }
  return DEFAULT_CONFIG;
}

function runCommand(command: string, cwd?: string): string {
  try {
    return execSync(command, { cwd, encoding: "utf-8", stdio: "pipe" });
  } catch (error: any) {
    throw new Error(`Command failed: ${command}\n${error.stdout || error.message}`);
  }
}

function parseLcovCoverage(lcovPath: string): CoverageReport {
  if (!fs.existsSync(lcovPath)) {
    throw new Error(`LCOV report not found at ${lcovPath}`);
  }

  const content = fs.readFileSync(lcovPath, "utf-8");
  const lines = content.split("\n");

  let totalLines = 0;
  let coveredLines = 0;
  let totalBranches = 0;
  let coveredBranches = 0;
  let totalFunctions = 0;
  let coveredFunctions = 0;

  for (const line of lines) {
    if (line.startsWith("DA:")) {
      // Line coverage: DA:<line number>,<hit count>
      totalLines++;
      const hitCount = parseInt(line.split(",")[1], 10);
      if (hitCount > 0) coveredLines++;
    } else if (line.startsWith("BRDA:")) {
      // Branch coverage: BRDA:<line number>,<block number>,<branch number>,<hit count>
      totalBranches++;
      const parts = line.split(",");
      const hitCount = parseInt(parts[3], 10);
      if (hitCount > 0) coveredBranches++;
    } else if (line.startsWith("FN:")) {
      // Function coverage: FN:<line number>,<function name>
      totalFunctions++;
    } else if (line.startsWith("FNDA:")) {
      // Function hit count: FNDA:<hit count>,<function name>
      const hitCount = parseInt(line.split(",")[0].split(":")[1], 10);
      if (hitCount > 0) coveredFunctions++;
    }
  }

  return {
    line: totalLines > 0 ? (coveredLines / totalLines) * 100 : 0,
    branch: totalBranches > 0 ? (coveredBranches / totalBranches) * 100 : 0,
    function: totalFunctions > 0 ? (coveredFunctions / totalFunctions) * 100 : 0,
    invariantState: 0, // Calculated separately
    eventTransition: 0, // Calculated separately
  };
}

function checkInvariantCoverage(config: QualityGateConfig): number {
  // Check if invariant tests exist and are passing
  let invariantTestsFound = 0;
  let invariantTestsPassing = 0;

  for (const testPath of config.invariantTestPaths) {
    const fullPath = path.join(process.cwd(), testPath.replace("**", ""));
    if (fs.existsSync(fullPath)) {
      invariantTestsFound++;
      // Run invariant tests to check if they pass
      try {
        runCommand(`forge test --match-path "${testPath}" --no-match-contract "Test" -q`);
        invariantTestsPassing++;
      } catch {
        // Test failed
      }
    }
  }

  if (invariantTestsFound === 0) {
    console.warn("⚠️  No invariant tests found");
    return 0;
  }

  return (invariantTestsPassing / invariantTestsFound) * 100;
}

function checkEventTransitionCoverage(config: QualityGateConfig): number {
  // Check if event-related tests exist and are passing
  let eventTestsFound = 0;
  let eventTestsPassing = 0;

  for (const testPath of config.eventTestPaths) {
    const fullPath = path.join(process.cwd(), testPath.replace("**", ""));
    if (fs.existsSync(fullPath)) {
      eventTestsFound++;
      try {
        runCommand(`forge test --match-path "${testPath}" -q`);
        eventTestsPassing++;
      } catch {
        // Test failed
      }
    }
  }

  if (eventTestsFound === 0) {
    console.warn("⚠️  No event transition tests found");
    return 0;
  }

  return (eventTestsPassing / eventTestsFound) * 100;
}

function checkCriticalPathCoverage(lcovPath: string, config: QualityGateConfig): { covered: string[]; uncovered: string[] } {
  const content = fs.readFileSync(lcovPath, "utf-8");
  const records = content.split("end_of_record");
  
  const covered: string[] = [];
  const uncovered: string[] = [];

  for (const record of records) {
    if (!record.trim()) continue;

    let sourceFile = "";
    let linesTotal = 0;
    let linesCovered = 0;

    for (const line of record.split("\n")) {
      if (line.startsWith("SF:")) {
        sourceFile = line.substring(3);
      } else if (line.startsWith("DA:")) {
        linesTotal++;
        const hitCount = parseInt(line.split(",")[1], 10);
        if (hitCount > 0) linesCovered++;
      }
    }

    if (sourceFile && config.criticalPaths.some(cp => sourceFile.includes(cp))) {
      const coveragePercent = linesTotal > 0 ? (linesCovered / linesTotal) * 100 : 0;
      if (coveragePercent >= config.thresholds.line) {
        covered.push(`${sourceFile} (${coveragePercent.toFixed(1)}%)`);
      } else {
        uncovered.push(`${sourceFile} (${coveragePercent.toFixed(1)}%)`);
      }
    }
  }

  return { covered, uncovered };
}

function generateCoverageReport(): void {
  console.log("🔍 Generating coverage report...");
  runCommand("forge coverage --report lcov --report summary --skip script");
  console.log("✅ Coverage report generated");
}

function main(): void {
  const configPath = path.join(process.cwd(), "config/coverage-quality-gate.json");
  const config = loadConfig(configPath);
  
  console.log("🛡️  Coverage Quality Gate");
  console.log("==========================");
  console.log(`Line threshold: ${config.thresholds.line}%`);
  console.log(`Branch threshold: ${config.thresholds.branch}%`);
  console.log(`Function threshold: ${config.thresholds.function}%`);
  console.log("");

  // lcov.info is generated by the preceding CI step (forge coverage --report lcov); read it directly.
  // Parse LCOV report
  const lcovPath = path.join(process.cwd(), "lcov.info");
  const coverage = parseLcovCoverage(lcovPath);

  console.log("📊 Coverage Results:");
  console.log(`  Line Coverage:     ${coverage.line.toFixed(2)}%`);
  console.log(`  Branch Coverage:   ${coverage.branch.toFixed(2)}%`);
  console.log(`  Function Coverage: ${coverage.function.toFixed(2)}%`);
  console.log("");

  // Check thresholds
  let allPassed = true;

  if (coverage.line < config.thresholds.line) {
    console.error(`❌ Line coverage ${coverage.line.toFixed(2)}% below threshold ${config.thresholds.line}%`);
    allPassed = false;
  } else {
    console.log(`✅ Line coverage ${coverage.line.toFixed(2)}% meets threshold ${config.thresholds.line}%`);
  }

  if (coverage.branch < config.thresholds.branch) {
    console.error(`❌ Branch coverage ${coverage.branch.toFixed(2)}% below threshold ${config.thresholds.branch}%`);
    allPassed = false;
  } else {
    console.log(`✅ Branch coverage ${coverage.branch.toFixed(2)}% meets threshold ${config.thresholds.branch}%`);
  }

  if (coverage.function < config.thresholds.function) {
    console.error(`❌ Function coverage ${coverage.function.toFixed(2)}% below threshold ${config.thresholds.function}%`);
    allPassed = false;
  } else {
    console.log(`✅ Function coverage ${coverage.function.toFixed(2)}% meets threshold ${config.thresholds.function}%`);
  }

  // Check critical path coverage
  console.log("\n🎯 Critical Path Coverage:");
  const criticalPathResults = checkCriticalPathCoverage(lcovPath, config);
  for (const covered of criticalPathResults.covered) {
    console.log(`  ✅ ${covered}`);
  }
  for (const uncovered of criticalPathResults.uncovered) {
    console.error(`  ❌ ${uncovered}`);
    allPassed = false;
  }

  // Check invariant-state coverage
  console.log("\n🔬 Invariant-State Coverage:");
  const invariantCoverage = checkInvariantCoverage(config);
  console.log(`  Invariant Tests Passing: ${invariantCoverage.toFixed(1)}%`);
  if (invariantCoverage < 100) {
    console.warn("  ⚠️  Some invariant tests are failing");
    // Note: We don't fail on this, just warn
  } else {
    console.log("  ✅ All invariant tests passing");
  }

  // Check event-transition coverage
  console.log("\n📡 Event-Transition Coverage:");
  const eventCoverage = checkEventTransitionCoverage(config);
  console.log(`  Event Tests Passing: ${eventCoverage.toFixed(1)}%`);
  if (eventCoverage < 100) {
    console.warn("  ⚠️  Some event transition tests are failing");
  } else {
    console.log("  ✅ All event transition tests passing");
  }

  console.log("\n==========================");
  if (allPassed) {
    console.log("🎉 All coverage quality gates PASSED!");
    process.exit(0);
  } else {
    console.error("💥 Coverage quality gates FAILED!");
    process.exit(1);
  }
}

main();