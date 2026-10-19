import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

interface EventParam {
  name: string;
  type: string;
  indexed: boolean;
  description?: string;
}

interface EventSchemaEntry {
  name: string;
  family: string;
  signature: string;
  topic0: string;
  version: number;
  indexedFieldsCount: number;
  parameters: EventParam[];
  stateReplayRole: string;
  financialImpact: boolean;
  description: string;
}

interface EventFamilyGroup {
  id: string;
  name: string;
  description: string;
  eventNames: string[];
}

interface CanonicalEventSchema {
  schemaVersion: number;
  protocol: string;
  releaseVersion: string;
  standard: string;
  checksum: string;
  families: EventFamilyGroup[];
  events: EventSchemaEntry[];
}

const FAMILIES_METADATA: Record<string, { name: string; description: string }> = {
  claims: {
    name: "Claims Lifecycle",
    description: "Reconstructs claim registration, updates, status transitions, resolution outcomes, and finalization.",
  },
  evidence: {
    name: "Evidence Management",
    description: "Tracks content-addressed evidence commitments, revocations, and claim evidence window closures.",
  },
  staking: {
    name: "Staking & Collateral Accounting",
    description: "Reconciles verifier collateral deposits, round locking, unlocking, and withdrawals.",
  },
  verification: {
    name: "Verification & Voting",
    description: "Records individual verifier submissions, support verdicts, committed stakes, and challenges.",
  },
  rounds: {
    name: "Rounds Management",
    description: "Defines round lifecycle windows, participant counts, and weighted vote totals.",
  },
  outcomes: {
    name: "Outcomes & Consensus Aggregation",
    description: "Tracks deterministic aggregation of weighted verifications, consensus verdict, and confidence scores.",
  },
  disputes: {
    name: "Dispute Resolution",
    description: "Reconstructs dispute challenges, escalation bonds, rulings, and resulting outcome overrides.",
  },
  rewards: {
    name: "Reward Calculation & Distribution",
    description: "Reconciles deterministic reward calculations, escrow reservations, claims, and batch payouts.",
  },
  slashing: {
    name: "Slashing Penalties",
    description: "Reconciles collateral slashing for losing votes or Byzantine behaviour across individual and batch flows.",
  },
  withdrawals: {
    name: "Withdrawal Queue & Timelocks",
    description: "Tracks queueing, cooldown expiry, cancellations, and execution of large verifier withdrawals.",
  },
  treasury: {
    name: "Treasury Accounting & Solvency",
    description: "Maintains full double-entry reconciliation of deposits, internal bucket transfers, withdrawals, and snapshots.",
  },
  parameters: {
    name: "Protocol Parameters & Schedules",
    description: "Tracks versioned governance parameter updates, address reconfigurations, and fee schedule updates.",
  },
  reputation: {
    name: "Reputation Roots & Snapshots",
    description: "Publishes cross-chain Merkle roots, individual score adjustments, and decay updates.",
  },
  roles: {
    name: "Access Control & Roles",
    description: "Tracks role granting, revocation, and admin role hierarchy changes across protocol modules.",
  },
  emergency: {
    name: "Emergency Controls & Pauses",
    description: "Reconstructs protocol emergency pause activation and recovery events.",
  },
  upgrades: {
    name: "Upgrades & Version Management",
    description: "Reconstructs module registrations, upgrade proposals, approvals, executions, and rollbacks.",
  },
};

const EVENT_FAMILY_MAP: Record<string, string> = {
  ClaimCreatedV1: "claims",
  ClaimUpdatedV1: "claims",
  ClaimStatusTransitionedV1: "claims",
  ClaimResolvedV1: "claims",
  ClaimFinalizedV1: "claims",
  EvidenceSubmittedV1: "evidence",
  EvidenceRevokedV1: "evidence",
  ClaimClosedForEvidenceV1: "evidence",
  StakeDepositedV1: "staking",
  StakeLockedV1: "staking",
  StakeUnlockedV1: "staking",
  StakeWithdrawnV1: "staking",
  VerificationSubmittedV1: "verification",
  VerificationChallengedV1: "verification",
  RoundStartedV1: "rounds",
  RoundEndedV1: "rounds",
  OutcomeAggregatedV1: "outcomes",
  DisputeOpenedV1: "disputes",
  DisputeRaisedV1: "disputes",
  DisputeResolvedV1: "disputes",
  RewardCalculatedV1: "rewards",
  RewardEscrowedV1: "rewards",
  RewardClaimedV1: "rewards",
  BatchRewardClaimedV1: "rewards",
  SlashExecutedV1: "slashing",
  BatchSlashExecutedV1: "slashing",
  WithdrawalQueuedV1: "withdrawals",
  WithdrawalExecutedV1: "withdrawals",
  WithdrawalCancelledV1: "withdrawals",
  TreasuryDepositV1: "treasury",
  TreasuryTransferV1: "treasury",
  TreasuryWithdrawalV1: "treasury",
  TreasurySnapshotRecordedV1: "treasury",
  ParameterUpdatedV1: "parameters",
  AddressParameterUpdatedV1: "parameters",
  FeeScheduleUpdatedV1: "parameters",
  ReputationRootPublishedV1: "reputation",
  ReputationScoreUpdatedV1: "reputation",
  ReputationDecayedV1: "reputation",
  RoleGrantedV1: "roles",
  RoleRevokedV1: "roles",
  RoleAdminChangedV1: "roles",
  EmergencyPauseActivatedV1: "emergency",
  EmergencyPauseRecoveredV1: "emergency",
  GovernanceProposalCreatedV1: "upgrades",
  GovernanceProposalExecutedV1: "upgrades",
  ModuleRegisteredV1: "upgrades",
  UpgradeProposedV1: "upgrades",
  UpgradeApprovedV1: "upgrades",
  UpgradeExecutedV1: "upgrades",
  UpgradeRolledBackV1: "upgrades",
};

const FINANCIAL_EVENTS = new Set([
  "StakeDepositedV1",
  "StakeLockedV1",
  "StakeUnlockedV1",
  "StakeWithdrawnV1",
  "RewardCalculatedV1",
  "RewardEscrowedV1",
  "RewardClaimedV1",
  "BatchRewardClaimedV1",
  "SlashExecutedV1",
  "BatchSlashExecutedV1",
  "TreasuryDepositV1",
  "TreasuryTransferV1",
  "TreasuryWithdrawalV1",
  "WithdrawalQueuedV1",
  "WithdrawalExecutedV1",
]);

export function generateEventSchema(): CanonicalEventSchema {
  const artifactPath = path.join(
    __dirname,
    "../artifacts/contracts/interfaces/ITruthBountyEvents.sol/ITruthBountyEvents.json"
  );

  let abi: any[];
  if (fs.existsSync(artifactPath)) {
    const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
    abi = artifact.abi;
  } else {
    throw new Error(`Artifact not found at ${artifactPath}. Please compile first.`);
  }

  const iface = new ethers.Interface(abi);
  const events: EventSchemaEntry[] = [];
  const familyBuckets: Record<string, string[]> = {};

  for (const familyId of Object.keys(FAMILIES_METADATA)) {
    familyBuckets[familyId] = [];
  }

  for (const fragment of iface.fragments) {
    if (fragment.type === "event") {
      const eventFrag = fragment as ethers.EventFragment;
      const name = eventFrag.name;
      const signature = eventFrag.format("sighash");
      const topic0 = eventFrag.topicHash;
      const family = EVENT_FAMILY_MAP[name] || "uncategorized";

      if (familyBuckets[family]) {
        familyBuckets[family].push(name);
      }

      const params: EventParam[] = eventFrag.inputs.map((input) => ({
        name: input.name,
        type: input.type,
        indexed: Boolean(input.indexed),
      }));

      const indexedCount = params.filter((p) => p.indexed).length;

      events.push({
        name,
        family,
        signature: eventFrag.format("full"),
        topic0,
        version: 1,
        indexedFieldsCount: indexedCount,
        parameters: params,
        stateReplayRole: `Reconstructs ${family} state transitions for indexer projection.`,
        financialImpact: FINANCIAL_EVENTS.has(name),
        description: `Canonical V1 event for ${name}.`,
      });
    }
  }

  // Sort events deterministically by name
  events.sort((a, b) => a.name.localeCompare(b.name));

  const families: EventFamilyGroup[] = Object.entries(FAMILIES_METADATA).map(
    ([id, meta]) => ({
      id,
      name: meta.name,
      description: meta.description,
      eventNames: (familyBuckets[id] || []).sort(),
    })
  );

  const rawSchema = {
    schemaVersion: 1,
    protocol: "TruthBounty",
    releaseVersion: "2.0.0",
    standard: "TruthBounty Canonical Event Schema Specification §20",
    families,
    events,
  };

  const schemaString = JSON.stringify(rawSchema, null, 2);
  const checksum = ethers.keccak256(ethers.toUtf8Bytes(schemaString));

  const finalSchema: CanonicalEventSchema = {
    ...rawSchema,
    checksum,
  };

  return finalSchema;
}

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === new URL(`file://${process.argv[1]}`).href;

if (invokedDirectly) {
  const schema = generateEventSchema();
  const outDir = path.join(__dirname, "../schemas");
  if (!fs.existsSync(outDir)) {
    fs.mkdirSync(outDir, { recursive: true });
  }
  const outPath = path.join(outDir, "event-schema-v1.json");
  fs.writeFileSync(outPath, JSON.stringify(schema, null, 2), "utf8");
  console.log(`Generated canonical event schema v1 at: ${outPath}`);
  console.log(`Total events: ${schema.events.length} across ${schema.families.length} families.`);
  console.log(`Schema checksum: ${schema.checksum}`);
}
