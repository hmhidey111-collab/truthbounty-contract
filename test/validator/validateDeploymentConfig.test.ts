/**
 * @title validateDeploymentConfig.test
 * @notice Unit tests for the TypeScript mirror of the canonical V2 deployment validator (SC-068).
 * @dev Run with plain Node 24+ type stripping (hardhat's ESM requirement currently breaks the
 *      project-wide `hardhat test` runner):
 *        node --test test/validator/validateDeploymentConfig.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  validateDeploymentConfig,
  validateRuntimeConfig,
  validateCanonicalV2Parameters,
  DeploymentValidationError,
  type DeploymentConfig,
  type ProviderLike,
} from "../../scripts/validateDeploymentConfig.ts";

const ZERO = "0x0000000000000000000000000000000000000000";
const ADMIN = "0xA11CEd1111111111111111111111111111111111";
const GUARDIAN = "0x6A2d111111111111111111111111111111111111";
const DAY = BigInt(24) * BigInt(3600);

function validConfig(): DeploymentConfig {
  return {
    deployer: undefined,
    admin: ADMIN,
    guardian: GUARDIAN,
    expectedChainId: 31337,
    minStakeAmount: 100n,
    settlementThresholdPercent: 50,
    rewardPercent: 40,
    slashPercent: 40,
    confirmationDelay: 3n * DAY,
    minReputationScore: 1,
    maxReputationScore: 100,
    defaultReputationScore: 10,
    stakingLockDuration: 90n * DAY,
    votingDelay: 1n * DAY,
    votingPeriod: 3n * DAY,
    proposalThreshold: 1000n,
    quorumNumerator: 4,
    timelockMinDelay: 2n * DAY,
    tokenSupply: 1000000n,
    minVerificationCount: 2,
    minConfidenceBps: 500,
    challengeWindowDuration: 3n * DAY,
    appealDuration: 3n * DAY,
    minAppealStake: 200n,
    appealMultiplierBps: 15000,
    maxWeightCap: 100000n,
    legacyDenylist: [],
  };
}

function expectFailure(fn: () => void, code: string, field: string): void {
  assert.throws(fn, (err: unknown) => {
    assert.ok(err instanceof DeploymentValidationError, `expected DeploymentValidationError, got ${String(err)}`);
    assert.equal(err.code, code);
    assert.equal(err.field, field);
    return true;
  });
}

// ── identity / authorization ───────────────────────────────────────────────

test("valid full config passes", () => {
  assert.doesNotThrow(() => validateDeploymentConfig(validConfig()));
});

test("deploy-fresh governance config (all SCM-064/governance params, fresh modules) passes", () => {
  const config = validConfig();
  config.governanceController = undefined;
  config.governanceToken = undefined;
  config.timelock = undefined;
  config.governor = undefined;
  config.moduleRegistry = undefined;
  config.governanceGuardian = undefined;
  config.reputationOracle = undefined;
  config.token = undefined;
  config.minStakeAmount = undefined;
  config.settlementThresholdPercent = undefined;
  config.rewardPercent = undefined;
  config.slashPercent = undefined;
  config.confirmationDelay = undefined;
  config.stakingLockDuration = undefined;
  config.minConfidenceBps = undefined;
  config.challengeWindowDuration = undefined;
  config.appealDuration = undefined;
  config.minAppealStake = undefined;
  config.appealMultiplierBps = undefined;
  config.maxWeightCap = undefined;
  assert.doesNotThrow(() => validateDeploymentConfig(config));
});

test("zero admin rejected", () => {
  const config = validConfig();
  config.admin = ZERO;
  expectFailure(() => validateDeploymentConfig(config), "ZERO_ADDRESS", "admin");
});

test("zero guardian rejected", () => {
  const config = validConfig();
  config.guardian = ZERO;
  expectFailure(() => validateDeploymentConfig(config), "ZERO_ADDRESS", "guardian");
});

test("duplicate admin/guardian rejected", () => {
  const config = validConfig();
  config.guardian = ADMIN;
  expectFailure(() => validateDeploymentConfig(config), "DUPLICATE_ADDRESS", "admin");
});

test("duplicate optional module rejected", () => {
  const config = validConfig();
  config.governanceToken = "0x000000000000000000000000000000000000B0B1";
  config.token = config.governanceToken;
  expectFailure(() => validateDeploymentConfig(config), "DUPLICATE_ADDRESS", "governanceToken");
});

test("placeholder admin rejected", () => {
  const config = validConfig();
  config.admin = "0x0000000000000000000000000000000000000001";
  expectFailure(() => validateDeploymentConfig(config), "PLACEHOLDER_ADDRESS", "admin");
});

test("burn placeholder guardian rejected", () => {
  const config = validConfig();
  config.guardian = "0x000000000000000000000000000000000000dEaD";
  expectFailure(() => validateDeploymentConfig(config), "PLACEHOLDER_ADDRESS", "guardian");
});

test("wrong chain id rejected at runtime stage", async () => {
  const config = validConfig();
  await assert.rejects(
    validateRuntimeConfig(config, undefined, 1n),
    (err: unknown) => err instanceof DeploymentValidationError && err.code === "WRONG_CHAIN_ID",
  );
});

// ── numeric bounds ─────────────────────────────────────────────────────────

test("settlement threshold over cap rejected", () => {
  const config = validConfig();
  config.settlementThresholdPercent = 101;
  expectFailure(() => validateDeploymentConfig(config), "INVALID_PARAMETER_RANGE", "settlementThresholdPercent");
});

test("reward+slash over 100 rejected", () => {
  const config = validConfig();
  config.rewardPercent = 50;
  config.slashPercent = 51;
  expectFailure(() => validateDeploymentConfig(config), "INVALID_PARAMETER_RANGE", "rewardPercent+slashPercent");
});

test("min reputation above max rejected", () => {
  const config = validConfig();
  config.minReputationScore = 101;
  expectFailure(() => validateDeploymentConfig(config), "INVALID_PARAMETER_RANGE", "minReputationScore");
});

test("default reputation out of range rejected", () => {
  const config = validConfig();
  config.defaultReputationScore = 1000;
  expectFailure(() => validateDeploymentConfig(config), "INVALID_PARAMETER_RANGE", "defaultReputationScore");
});

test("voting delay not below voting period rejected", () => {
  const config = validConfig();
  config.votingDelay = config.votingPeriod;
  expectFailure(() => validateDeploymentConfig(config), "INVALID_PARAMETER_RANGE", "votingDelay");
});

test("quorum numerator zero rejected", () => {
  const config = validConfig();
  config.quorumNumerator = 0;
  expectFailure(() => validateDeploymentConfig(config), "INVALID_PARAMETER_RANGE", "quorumNumerator");
});

test("quorum numerator 100 rejected", () => {
  const config = validConfig();
  config.quorumNumerator = 100;
  expectFailure(() => validateDeploymentConfig(config), "INVALID_PARAMETER_RANGE", "quorumNumerator");
});

test("zero voting period rejected", () => {
  const config = validConfig();
  config.votingPeriod = 0;
  expectFailure(() => validateDeploymentConfig(config), "INVALID_PARAMETER_RANGE", "votingPeriod");
});

test("timelock min delay over cap rejected", () => {
  const config = validConfig();
  config.timelockMinDelay = 366n * DAY;
  expectFailure(() => validateDeploymentConfig(config), "INVALID_PARAMETER_RANGE", "timelockMinDelay");
});

test("zero token supply rejected", () => {
  const config = validConfig();
  config.tokenSupply = 0;
  expectFailure(() => validateDeploymentConfig(config), "INVALID_PARAMETER_RANGE", "tokenSupply");
});

test("appeal multiplier over cap rejected", () => {
  const config = validConfig();
  config.appealMultiplierBps = 100001;
  expectFailure(() => validateDeploymentConfig(config), "INVALID_PARAMETER_RANGE", "appealMultiplierBps");
});

test("canonical default appeal multiplier passes upper boundary", () => {
  const config = validConfig();
  config.appealMultiplierBps = 15000;
  assert.doesNotThrow(() => validateDeploymentConfig(config));
});

// ── canonical V2 economy-suite parameters ─────────────────────────────────

test("canonical V2 defaults pass", () => {
  assert.doesNotThrow(() =>
    validateCanonicalV2Parameters({
      initialSupply: 10000000000000000000000000n,
      minVerificationCount: 1n,
      minTotalWeight: 0n,
      minConfidenceBps: 0n,
      challengeWindowDuration: 3 * 24 * 3600,
      appealDuration: 3 * 24 * 3600,
      minAppealStake: 200000000000000000000n,
      appealMultiplierBps: 15000n,
      maxWeightCap: 100000000000000000000000n,
      parameterVersion: 1n,
    }),
  );
});

test("canonical V2 appeal multiplier over cap rejected", () => {
  expectFailure(
    () =>
      validateCanonicalV2Parameters({
        appealMultiplierBps: 100001n,
      }),
    "INVALID_PARAMETER_RANGE",
    "appealMultiplierBps",
  );
});

test("canonical V2 zero minVerificationCount rejected", () => {
  expectFailure(
    () =>
      validateCanonicalV2Parameters({
        minVerificationCount: 0n,
      }),
    "INVALID_PARAMETER_RANGE",
    "minVerificationCount",
  );
});

// ── runtime checks ─────────────────────────────────────────────────────────

test("legacy denylist match rejected", async () => {
  const config = validConfig();
  config.token = "0x000000000000000000000000000000000000B0B0";
  config.legacyDenylist = [config.token];
  await assert.rejects(
    validateRuntimeConfig(config),
    (err: unknown) => err instanceof DeploymentValidationError && err.code === "LEGACY_ADDRESS",
  );
});

test("EOA pre-wired module rejected", async () => {
  const provider: ProviderLike = {
    getCode: async () => "0x",
    call: async () => {
      throw new Error("unreachable");
    },
  };
  const config = validConfig();
  config.governanceToken = "0x000000000000000000000000000000000000B0B0";
  await assert.rejects(
    validateRuntimeConfig(config, provider, 31337n),
    (err: unknown) => err instanceof DeploymentValidationError && err.code === "EOA_ADDRESS",
  );
});

test("wrong-interface probe rejected", async () => {
  const provider: ProviderLike = {
    getCode: async () => "0x60006000",
    call: async () => {
      throw new Error("revert");
    },
  };
  const config = validConfig();
  config.governor = "0x000000000000000000000000000000000000B0B0";
  await assert.rejects(
    validateRuntimeConfig(config, provider, 31337n),
    (err: unknown) => err instanceof DeploymentValidationError && err.code === "WRONG_INTERFACE",
  );
});

test("correct interface probes pass", async () => {
  const provider: ProviderLike = {
    getCode: async () => "0x60006000",
    call: async () => "0x0000000000000000000000000000000000000000000000000000000000000001",
  };
  const config = validConfig();
  await validateRuntimeConfig(config, provider, 31337n);
});

test("unauthorized deployer rejected at runtime stage", async () => {
  const config = validConfig();
  config.deployer = ADMIN;
  await assert.rejects(
    validateRuntimeConfig(config, undefined, 31337n, GUARDIAN),
    (err: unknown) => err instanceof DeploymentValidationError && err.code === "UNAUTHORIZED_DEPLOYER",
  );
});