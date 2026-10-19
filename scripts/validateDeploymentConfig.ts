/**
 * @title validateDeploymentConfig
 * @notice TypeScript mirror of the canonical TruthBounty V2 deployment-configuration validator.
 * @dev Canonical source of truth: contracts/deployment/DeploymentConfigValidator.sol.
 *      Validates the deployment configuration BEFORE any deploy transaction is created so that
 *      malformed, dangerous, or placeholder configuration is rejected and never broadcast.
 *
 *      Split into the same two stages as the Solidity library:
 *      - validateDeploymentConfig: zero, duplicate, placeholder, wrong-chain, numeric-range, and
 *        broadcaster-authorization checks (no external state).
 *      - validateRuntimeConfig: legacy-denylist, EOA (code-size), and wrong-interface checks
 *        against pre-wired module addresses (requires a provider).
 *
 *      Validation fails closed: any invalid field throws a DeploymentValidationError naming the
 *      offending field and value. Optional addresses accept "0x0000000000000000000000000000000000000000"
 *      as a "deploy fresh" sentinel; optional numerics accept 0 as "use framework default".
 */

export type DeploymentConfigNumber = bigint | number | string;

export interface DeploymentConfig {
  deployer?: string;
  admin?: string;
  guardian?: string;
  governanceController?: string;
  governanceToken?: string;
  timelock?: string;
  governor?: string;
  moduleRegistry?: string;
  governanceGuardian?: string;
  reputationOracle?: string;
  token?: string;
  expectedChainId?: DeploymentConfigNumber;
  minStakeAmount?: DeploymentConfigNumber;
  settlementThresholdPercent?: DeploymentConfigNumber;
  rewardPercent?: DeploymentConfigNumber;
  slashPercent?: DeploymentConfigNumber;
  confirmationDelay?: DeploymentConfigNumber;
  minReputationScore?: DeploymentConfigNumber;
  maxReputationScore?: DeploymentConfigNumber;
  defaultReputationScore?: DeploymentConfigNumber;
  stakingLockDuration?: DeploymentConfigNumber;
  votingDelay?: DeploymentConfigNumber;
  votingPeriod?: DeploymentConfigNumber;
  proposalThreshold?: DeploymentConfigNumber;
  quorumNumerator?: DeploymentConfigNumber;
  timelockMinDelay?: DeploymentConfigNumber;
  tokenSupply?: DeploymentConfigNumber;
  minVerificationCount?: DeploymentConfigNumber;
  minConfidenceBps?: DeploymentConfigNumber;
  challengeWindowDuration?: DeploymentConfigNumber;
  appealDuration?: DeploymentConfigNumber;
  minAppealStake?: DeploymentConfigNumber;
  appealMultiplierBps?: DeploymentConfigNumber;
  maxWeightCap?: DeploymentConfigNumber;
  legacyDenylist?: string[];
}

/** Minimal provider surface used for runtime (EOA / interface-probe) checks. */
export interface ProviderLike {
  getCode(address: string): Promise<string>;
  call(request: { to: string; data: string; from?: string }): Promise<string>;
}

export class DeploymentValidationError extends Error {
  readonly field: string;
  readonly code: string;
  readonly value?: unknown;

  constructor(code: string, field: string, message: string, value?: unknown) {
    super(message);
    this.name = "DeploymentValidationError";
    this.code = code;
    this.field = field;
    this.value = value;
  }
}

const MAX_BPS = 10_000n;
const QUORUM_DENOMINATOR = 100n;
const MAX_TIMELOCK_MIN_DELAY = 365n * 24n * 3600n;
const MAX_LOCK_DURATION = 365n * 24n * 3600n;
const MAX_TIMING_DURATION = 365n * 24n * 3600n;
const MAX_VOTING_DELAY = 2n ** 48n - 1n;
const MAX_VOTING_PERIOD = 2n ** 32n - 1n;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

const PLACEHOLDER_ADDRESSES: readonly string[] = [
  "0x0000000000000000000000000000000000000001",
  "0x0000000000000000000000000000000000000002",
  "0x0000000000000000000000000000000000000003",
  "0x0000000000000000000000000000000000000004",
  "0x0000000000000000000000000000000000000005",
  "0x0000000000000000000000000000000000000006",
  "0x0000000000000000000000000000000000000007",
  "0x0000000000000000000000000000000000000008",
  "0x0000000000000000000000000000000000000009",
  "0x000000000000000000000000000000000000dead",
  "0xdeadbeef00000000000000000000000000000000",
  "0x1111111111111111111111111111111111111111",
  "0x2222222222222222222222222222222222222222",
  "0x3333333333333333333333333333333333333333",
  "0x4444444444444444444444444444444444444444",
  "0x5555555555555555555555555555555555555555",
  "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
];

// Interface probe selectors shared with the Solidity library.
const SELECTORS = {
  version: "0x54fd4d50",
  totalSupply: "0x18160ddd",
  getMinDelay: "0xf27a0c92",
  proposalThreshold: "0xb58131b0",
  moduleCount: "0x334f7ac5",
  governor: "0x0c340a24",
  isActive: "0x22f3e2d4",
} as const;

function big(value: DeploymentConfigNumber | undefined): bigint {
  if (value === undefined) return 0n;
  return typeof value === "string" ? BigInt(value) : BigInt(value);
}

function addressField(config: DeploymentConfig, key: keyof DeploymentConfig): string {
  const value = config[key];
  if (typeof value === "string") return value.toLowerCase();
  return ZERO_ADDRESS;
}

function expectNonZero(value: bigint, field: string): void {
  if (value === 0n) {
    throw new DeploymentValidationError(
      "ZERO_ADDRESS",
      field,
      `DeploymentValidationError: field "${field}" must be non-zero`,
      "0x0000000000000000000000000000000000000000",
    );
  }
}

function throwZero(field: string, value: string): never {
  throw new DeploymentValidationError(
    "ZERO_ADDRESS",
    field,
    `DeploymentValidationError: address field "${field}" must be non-zero`,
    value,
  );
}

function throwDuplicate(fieldA: string, fieldB: string, value: string): never {
  throw new DeploymentValidationError(
    "DUPLICATE_ADDRESS",
    fieldA,
    `DeploymentValidationError: fields "${fieldA}" and "${fieldB}" resolve to the same address "${value}"`,
    value,
  );
}

function throwPlaceholder(field: string, value: string): never {
  throw new DeploymentValidationError(
    "PLACEHOLDER_ADDRESS",
    field,
    `DeploymentValidationError: address field "${field}" is a well-known placeholder/burn address "${value}"`,
    value,
  );
}

function throwRange(field: string, value: bigint, min: bigint, max: bigint): never {
  throw new DeploymentValidationError(
    "INVALID_PARAMETER_RANGE",
    field,
    `DeploymentValidationError: parameter "${field}" value ${value} outside allowed range [${min}, ${max}]`,
    value,
  );
}

function checkRange(
  field: string,
  value: bigint,
  min: bigint,
  max: bigint,
  allowZero: boolean,
): void {
  if (value === 0n && allowZero) return;
  if (value < min || value > max) throwRange(field, value, min, max);
}

/**
 * @notice Validates the static subset of a deployment configuration. Pure, synchronous, and
 *         provider-independent. Throws DeploymentValidationError on the first invalid field.
 */
export function validateDeploymentConfig(config: DeploymentConfig): void {
  const deployer = addressField(config, "deployer");
  const admin = addressField(config, "admin");
  const guardian = addressField(config, "guardian");
  const governanceController = addressField(config, "governanceController");
  const governanceToken = addressField(config, "governanceToken");
  const timelock = addressField(config, "timelock");
  const governor = addressField(config, "governor");
  const moduleRegistry = addressField(config, "moduleRegistry");
  const governanceGuardian = addressField(config, "governanceGuardian");
  const reputationOracle = addressField(config, "reputationOracle");
  const token = addressField(config, "token");

  // Identity
  if (admin === ZERO_ADDRESS) throwZero("admin", admin);
  if (guardian === ZERO_ADDRESS) throwZero("guardian", guardian);

  // Placeholders
  const configured: Array<[string, string]> = [
    ["admin", admin],
    ["guardian", guardian],
    ["governanceController", governanceController],
    ["governanceToken", governanceToken],
    ["timelock", timelock],
    ["governor", governor],
    ["moduleRegistry", moduleRegistry],
    ["governanceGuardian", governanceGuardian],
    ["reputationOracle", reputationOracle],
    ["token", token],
  ];
  for (const [field, value] of configured) {
    if (value === ZERO_ADDRESS) continue;
    if (PLACEHOLDER_ADDRESSES.includes(value)) throwPlaceholder(field, value);
  }

  // Duplicates across every configured non-zero address
  for (let i = 0; i < configured.length; ++i) {
    const [fieldA, valueA] = configured[i];
    if (valueA === ZERO_ADDRESS) continue;
    for (let j = i + 1; j < configured.length; ++j) {
      const [fieldB, valueB] = configured[j];
      if (valueB === ZERO_ADDRESS) continue;
      if (valueA === valueB) throwDuplicate(fieldA, fieldB, valueA);
    }
  }

  // Chain binding
  const expectedChainId = big(config.expectedChainId);
  checkRange("expectedChainId", expectedChainId, 1n, (2n ** 256n) - 1n, false);

  // Economic allocations
  checkRange("minStakeAmount", big(config.minStakeAmount), 0n, (2n ** 256n) - 1n, true);
  checkRange("settlementThresholdPercent", big(config.settlementThresholdPercent), 1n, 100n, true);
  const rewardPercent = big(config.rewardPercent);
  const slashPercent = big(config.slashPercent);
  checkRange("rewardPercent", rewardPercent, 1n, 100n, true);
  checkRange("slashPercent", slashPercent, 1n, 100n, true);
  if (rewardPercent !== 0n || slashPercent !== 0n) {
    const totalAllocation = rewardPercent + slashPercent;
    if (totalAllocation > 100n) {
      throw new DeploymentValidationError(
        "INVALID_PARAMETER_RANGE",
        "rewardPercent+slashPercent",
        `DeploymentValidationError: parameter "rewardPercent+slashPercent" value ${totalAllocation} exceeds 100`,
        totalAllocation,
      );
    }
  }
  checkRange("confirmationDelay", big(config.confirmationDelay), 1n, MAX_TIMING_DURATION, true);
  checkRange("stakingLockDuration", big(config.stakingLockDuration), 1n, MAX_LOCK_DURATION, true);

  // Reputation bounds
  const minReputationScore = big(config.minReputationScore);
  const maxReputationScore = big(config.maxReputationScore);
  const defaultReputationScore = big(config.defaultReputationScore);
  if (minReputationScore !== 0n && maxReputationScore !== 0n && minReputationScore > maxReputationScore) {
    throw new DeploymentValidationError(
      "INVALID_PARAMETER_RANGE",
      "minReputationScore",
      `DeploymentValidationError: parameter "minReputationScore" value ${minReputationScore} exceeds maxReputationScore ${maxReputationScore}`,
      minReputationScore,
    );
  }
  if (defaultReputationScore !== 0n) {
    const minScore = minReputationScore === 0n ? defaultReputationScore : minReputationScore;
    const maxScore = maxReputationScore === 0n ? defaultReputationScore : maxReputationScore;
    if (defaultReputationScore < minScore || defaultReputationScore > maxScore) {
      throwRange("defaultReputationScore", defaultReputationScore, minScore, maxScore);
    }
  }

  // Governance bounds
  const votingDelay = big(config.votingDelay);
  const votingPeriod = big(config.votingPeriod);
  checkRange("votingDelay", votingDelay, 0n, MAX_VOTING_DELAY, true);
  checkRange("votingPeriod", votingPeriod, 1n, MAX_VOTING_PERIOD, false);
  if (votingPeriod !== 0n && votingDelay >= votingPeriod) {
    throw new DeploymentValidationError(
      "INVALID_PARAMETER_RANGE",
      "votingDelay",
      `DeploymentValidationError: parameter "votingDelay" value ${votingDelay} must be smaller than votingPeriod ${votingPeriod}`,
      votingDelay,
    );
  }
  checkRange("proposalThreshold", big(config.proposalThreshold), 0n, (2n ** 256n) - 1n, true);
  checkRange("quorumNumerator", big(config.quorumNumerator), 1n, QUORUM_DENOMINATOR - 1n, false);
  checkRange("timelockMinDelay", big(config.timelockMinDelay), 0n, MAX_TIMELOCK_MIN_DELAY, true);
  checkRange("tokenSupply", big(config.tokenSupply), 1n, (2n ** 256n) - 1n, false);

  // Canonical verification bounds
  checkRange("minVerificationCount", big(config.minVerificationCount), 1n, (2n ** 256n) - 1n, false);
  checkRange("minConfidenceBps", big(config.minConfidenceBps), 0n, MAX_BPS, true);
  checkRange("challengeWindowDuration", big(config.challengeWindowDuration), 1n, MAX_TIMING_DURATION, true);
  checkRange("appealDuration", big(config.appealDuration), 1n, MAX_TIMING_DURATION, true);
  checkRange("minAppealStake", big(config.minAppealStake), 1n, (2n ** 256n) - 1n, true);
  checkRange("appealMultiplierBps", big(config.appealMultiplierBps), 1n, MAX_BPS * 10n, true);
  checkRange("maxWeightCap", big(config.maxWeightCap), 1n, (2n ** 256n) - 1n, true);
}

/**
 * @notice Validates the runtime subset of a deployment configuration: legacy-denylist presence,
 *         EOA detection, and canonical interface probes for pre-wired module addresses.
 * @param config The deployment configuration to validate (static stage assumed to have passed).
 * @param provider An optional JSON-RPC-style provider used for code-size and interface checks.
 * @param actualChainId The chain id resolved from the provider; if omitted, and expectedChainId is
 *        set, the wrong-chain check is skipped (the caller must resolve it instead).
 * @param sender Optional expected broadcaster used for the sender-authorization check.
 */
export async function validateRuntimeConfig(
  config: DeploymentConfig,
  provider?: ProviderLike,
  actualChainId?: bigint,
  sender?: string,
): Promise<void> {
  const expectedChainId = big(config.expectedChainId);
  if (expectedChainId !== 0n && actualChainId !== undefined && expectedChainId !== actualChainId) {
    throw new DeploymentValidationError(
      "WRONG_CHAIN_ID",
      "expectedChainId",
      `DeploymentValidationError: expectedChainId ${expectedChainId} does not match actual chain id ${actualChainId}`,
      expectedChainId,
    );
  }

  const deployer = addressField(config, "deployer");
  if (deployer !== ZERO_ADDRESS && sender !== undefined && deployer !== sender.toLowerCase()) {
    throw new DeploymentValidationError(
      "UNAUTHORIZED_DEPLOYER",
      "deployer",
      `DeploymentValidationError: expected deployer ${deployer} does not match sender ${sender}`,
      deployer,
    );
  }

  const moduleFields: Array<[string, string]> = [
    ["governanceController", addressField(config, "governanceController")],
    ["governanceToken", addressField(config, "governanceToken")],
    ["timelock", addressField(config, "timelock")],
    ["governor", addressField(config, "governor")],
    ["moduleRegistry", addressField(config, "moduleRegistry")],
    ["governanceGuardian", addressField(config, "governanceGuardian")],
    ["reputationOracle", addressField(config, "reputationOracle")],
    ["token", addressField(config, "token")],
  ];

  // Legacy denylist
  if (config.legacyDenylist && config.legacyDenylist.length > 0) {
    const legacySet = new Set(config.legacyDenylist.map((a) => a.toLowerCase()));
    for (const [field, value] of moduleFields) {
      if (value !== ZERO_ADDRESS && legacySet.has(value)) {
        throw new DeploymentValidationError(
          "LEGACY_ADDRESS",
          field,
          `DeploymentValidationError: address field "${field}" is a legacy V1 contract address "${value}"`,
          value,
        );
      }
    }
  }

  if (!provider) return;

  // EOA detection + interface probes
  const probes: Array<[string, string, string]> = [
    ["governanceController", "version", SELECTORS.version],
    ["governanceToken", "totalSupply", SELECTORS.totalSupply],
    ["timelock", "getMinDelay", SELECTORS.getMinDelay],
    ["governor", "proposalThreshold", SELECTORS.proposalThreshold],
    ["moduleRegistry", "moduleCount", SELECTORS.moduleCount],
    ["governanceGuardian", "governor", SELECTORS.governor],
    ["reputationOracle", "isActive", SELECTORS.isActive],
    ["token", "totalSupply", SELECTORS.totalSupply],
  ];
  for (const [field, label, selector] of probes) {
    const value = addressField(config, field as keyof DeploymentConfig);
    if (value === ZERO_ADDRESS) continue;
    const code = await provider.getCode(value);
    if (!code || code === "0x" || code === "0x0") {
      throw new DeploymentValidationError(
        "EOA_ADDRESS",
        field,
        `DeploymentValidationError: address field "${field}" has no contract code (plain EOA) at "${value}"`,
        value,
      );
    }
    try {
      await provider.call({ to: value, data: selector, from: ZERO_ADDRESS });
    } catch (error) {
      throw new DeploymentValidationError(
        "WRONG_INTERFACE",
        field,
        `DeploymentValidationError: address field "${field}" does not answer interface probe ${label} (${selector}) at "${value}": ${String(error)}`,
        value,
      );
    }
  }
}

/** Canonical V2 economy-suite deployment parameters (mirrors scripts/deployCanonicalV2.ts). */
export interface CanonicalV2Parameters {
  initialSupply?: DeploymentConfigNumber;
  minVerificationCount?: DeploymentConfigNumber;
  minTotalWeight?: DeploymentConfigNumber;
  minConfidenceBps?: DeploymentConfigNumber;
  challengeWindowDuration?: DeploymentConfigNumber;
  appealDuration?: DeploymentConfigNumber;
  minAppealStake?: DeploymentConfigNumber;
  appealMultiplierBps?: DeploymentConfigNumber;
  maxWeightCap?: DeploymentConfigNumber;
  parameterVersion?: DeploymentConfigNumber;
}

/** @notice Validates the numeric parameters of the canonical V2 economy-suite deployment. */
export function validateCanonicalV2Parameters(params: CanonicalV2Parameters): void {
  const n = (field: keyof CanonicalV2Parameters): boolean => params[field] !== undefined;

  if (n("initialSupply")) checkRange("initialSupply", big(params.initialSupply), 1n, (2n ** 256n) - 1n, false);
  if (n("minVerificationCount")) {
    checkRange("minVerificationCount", big(params.minVerificationCount), 1n, (2n ** 256n) - 1n, false);
  }
  if (n("minTotalWeight")) checkRange("minTotalWeight", big(params.minTotalWeight), 0n, (2n ** 256n) - 1n, true);
  if (n("minConfidenceBps")) checkRange("minConfidenceBps", big(params.minConfidenceBps), 0n, MAX_BPS, true);
  if (n("challengeWindowDuration")) {
    checkRange("challengeWindowDuration", big(params.challengeWindowDuration), 1n, MAX_TIMING_DURATION, true);
  }
  if (n("appealDuration")) checkRange("appealDuration", big(params.appealDuration), 1n, MAX_TIMING_DURATION, true);
  if (n("minAppealStake")) checkRange("minAppealStake", big(params.minAppealStake), 1n, (2n ** 256n) - 1n, true);
  if (n("appealMultiplierBps")) {
    checkRange("appealMultiplierBps", big(params.appealMultiplierBps), 1n, MAX_BPS * 10n, true);
  }
  if (n("maxWeightCap")) checkRange("maxWeightCap", big(params.maxWeightCap), 1n, (2n ** 256n) - 1n, true);
  if (n("parameterVersion")) {
    checkRange("parameterVersion", big(params.parameterVersion), 1n, (2n ** 256n) - 1n, false);
  }
}

/** @notice Convenience wrapper performing static + runtime validation. */
export async function validateDeployment(config: DeploymentConfig, provider?: ProviderLike): Promise<void> {
  validateDeploymentConfig(config);
  await validateRuntimeConfig(config, provider);
}