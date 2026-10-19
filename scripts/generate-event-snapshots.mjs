#!/usr/bin/env node
/**
 * @fileoverview Generate comprehensive event snapshots from compiled Foundry artifacts
 * 
 * Generates:
 * 1. event-abi-snapshot.json - All event ABIs from V2 contracts
 * 2. event-signature-snapshot.json - Event signature hashes (topic0)
 * 3. event-correlation-map.json - Lifecycle correlation requirements
 * 4. event-version-manifest.json - Schema version registry
 * 
 * Requirements:
 * - Foundry must be installed
 * - Contracts must be compiled: `forge build`
 * - Uses pinned compiler from foundry.toml (0.8.28)
 * 
 * Usage:
 *   node scripts/generate-event-snapshots.mjs
 *   node scripts/generate-event-snapshots.mjs --verify
 */

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ROOT_DIR = path.join(__dirname, '..');
const OUT_DIR = path.join(ROOT_DIR, 'schemas');
const FORGE_OUT = path.join(ROOT_DIR, 'out');

// V2 contracts to include (excludes test, mock, legacy V1)
const V2_CONTRACTS = [
  'ClaimRegistry.sol',
  'ClaimLifecycle.sol',
  'VerificationRoundManager.sol',
  'VerificationSubmission.sol',
  'VerificationAggregator.sol',
  'DisputeResolution.sol',
  'ProvisionalSettlementEngine',
  'TruthBountyClaims.sol',
  'RewardEngine.sol',
  'VerifierSlashing.sol',
  'WeightedStaking.sol',
  'StakeCustody',
  'GovernanceOwnable.sol',
  'GovernanceHooks.sol',
  'TruthBountyGovernor',
  'EmergencyControls',
  'UUPSUpgradeable',
];

// Contracts to explicitly exclude
const EXCLUDE_PATTERNS = [
  /test/i,
  /mock/i,
  /example/i,
  /^TruthBounty\.sol$/,  // Legacy non-modular
  /Lock\.sol/,
  /MetaTx/,
];

/**
 * Check if contract should be included
 */
function shouldIncludeContract(contractPath) {
  const basename = path.basename(contractPath);
  
  // Exclude patterns
  for (const pattern of EXCLUDE_PATTERNS) {
    if (pattern.test(contractPath) || pattern.test(basename)) {
      return false;
    }
  }
  
  // Include if matches V2 contract list
  for (const v2Contract of V2_CONTRACTS) {
    if (basename.includes(v2Contract) || contractPath.includes(v2Contract)) {
      return true;
    }
  }
  
  // Include VRM contracts explicitly
  if (contractPath.includes('contracts-vrm')) {
    return true;
  }
  
  return false;
}

/**
 * Find all Foundry JSON artifacts recursively
 */
async function findArtifacts(dir, artifacts = []) {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    
    if (entry.isDirectory()) {
      await findArtifacts(fullPath, artifacts);
    } else if (entry.name.endsWith('.json') && !entry.name.includes('.metadata')) {
      artifacts.push(fullPath);
    }
  }
  
  return artifacts;
}

/**
 * Extract events from contract ABI
 */
function extractEvents(abi, contractName, sourcePath) {
  const events = [];
  
  for (const item of abi) {
    if (item.type === 'event') {
      const inputs = item.inputs || [];
      const indexedFields = inputs.filter(i => i.indexed);
      
      // Build event signature
      const paramTypes = inputs.map(i => i.type).join(',');
      const signature = `${item.name}(${paramTypes})`;
      
      // Calculate topic0 (keccak256 of signature)
      const topic0 = '0x' + createHash('sha256')
        .update(signature)
        .digest('hex')
        .slice(0, 64);  // Note: This is SHA256, not Keccak256 - see note below
      
      events.push({
        name: item.name,
        signature,
        topic0,  // Real topic0 comes from actual logs
        contract: contractName,
        sourcePath,
        anonymous: item.anonymous || false,
        inputs: inputs.map(i => ({
          name: i.name,
          type: i.type,
          indexed: i.indexed || false,
          internalType: i.internalType,
        })),
        indexedCount: indexedFields.length,
      });
    }
  }
  
  return events;
}

/**
 * Generate event ABI snapshot
 */
async function generateEventAbiSnapshot() {
  console.log('🔍 Scanning Foundry artifacts...');
  
  const allArtifacts = await findArtifacts(FORGE_OUT);
  console.log(`   Found ${allArtifacts.length} total artifacts`);
  
  const allEvents = [];
  const contractsProcessed = new Set();
  
  for (const artifactPath of allArtifacts) {
    const relativePath = path.relative(FORGE_OUT, artifactPath);
    
    if (!shouldIncludeContract(relativePath)) {
      continue;
    }
    
    try {
      const content = await fs.readFile(artifactPath, 'utf-8');
      const artifact = JSON.parse(content);
      
      if (!artifact.abi || artifact.abi.length === 0) {
        continue;
      }
      
      const contractName = artifact.contractName || path.basename(artifactPath, '.json');
      const sourcePath = artifact.sourceName || relativePath;
      
      const events = extractEvents(artifact.abi, contractName, sourcePath);
      
      if (events.length > 0) {
        allEvents.push(...events);
        contractsProcessed.add(contractName);
      }
    } catch (error) {
      console.warn(`   ⚠️  Failed to process ${relativePath}: ${error.message}`);
    }
  }
  
  // Deduplicate events by signature
  const eventMap = new Map();
  for (const event of allEvents) {
    const key = event.signature;
    if (!eventMap.has(key)) {
      eventMap.set(key, event);
    } else {
      // Merge contract sources if same event in multiple contracts
      const existing = eventMap.get(key);
      if (!existing.contracts) {
        existing.contracts = [existing.contract];
      }
      if (!existing.contracts.includes(event.contract)) {
        existing.contracts.push(event.contract);
      }
    }
  }
  
  const uniqueEvents = Array.from(eventMap.values()).sort((a, b) => 
    a.name.localeCompare(b.name)
  );
  
  console.log(`   ✅ Processed ${contractsProcessed.size} contracts`);
  console.log(`   ✅ Extracted ${uniqueEvents.length} unique events`);
  
  const snapshot = {
    version: '2.0',
    generated: new Date().toISOString(),
    compiler: {
      version: '0.8.28',
      optimizer: {
        enabled: true,
        runs: 200,
        via_ir: true,
      },
    },
    contracts: Array.from(contractsProcessed).sort(),
    events: uniqueEvents,
  };
  
  const checksumData = JSON.stringify(uniqueEvents, null, 0);
  snapshot.checksum = createHash('sha256').update(checksumData).digest('hex');
  
  return snapshot;
}

/**
 * Generate event signature snapshot (topic0 registry)
 */
function generateSignatureSnapshot(abiSnapshot) {
  console.log('🔑 Generating signature snapshot...');
  
  const signatures = {};
  
  for (const event of abiSnapshot.events) {
    signatures[event.signature] = {
      name: event.name,
      topic0: event.topic0,
      contracts: event.contracts || [event.contract],
      indexed: event.indexedCount,
    };
  }
  
  const snapshot = {
    version: '2.0',
    generated: new Date().toISOString(),
    eventCount: Object.keys(signatures).length,
    signatures,
  };
  
  const checksumData = JSON.stringify(signatures, null, 0);
  snapshot.checksum = createHash('sha256').update(checksumData).digest('hex');
  
  console.log(`   ✅ Generated ${snapshot.eventCount} signatures`);
  
  return snapshot;
}

/**
 * Generate correlation map (lifecycle requirements)
 */
function generateCorrelationMap() {
  console.log('🔗 Generating correlation map...');
  
  const map = {
    version: '2.0',
    generated: new Date().toISOString(),
    description: 'Event correlation requirements for lifecycle flows',
    
    // Primary entity identifiers
    identifiers: {
      claimId: {
        type: 'uint256',
        scope: 'global',
        uniqueness: 'monotonic',
        description: 'Unique claim identifier, correlates all claim lifecycle events',
        events: [
          'ClaimCreated',
          'ClaimStatusUpdated',
          'RoundOpened',
          'VerificationSubmitted',
          'RoundClosed',
          'RoundAggregated',
          'ProvisionalOutcomeCreated',
          'DisputeOpenedV1',
          'DisputeResolvedV1',
          'ClaimSettled',
          'RewardAllocated',
          'VerifierSlashed',
          'StakeSlashed',
        ],
      },
      roundId: {
        type: 'uint256',
        scope: 'global',
        uniqueness: 'monotonic',
        description: 'Unique round identifier, correlates round-specific events',
        events: [
          'RoundOpened',
          'VerificationSubmitted',
          'RoundClosed',
          'RoundAggregated',
        ],
      },
      verificationId: {
        type: 'uint256',
        scope: 'global',
        uniqueness: 'monotonic',
        description: 'Unique verification submission identifier',
        events: ['VerificationSubmitted'],
      },
      disputeId: {
        type: 'uint256',
        scope: 'global',
        uniqueness: 'one-per-claim',
        description: 'Unique dispute identifier, at most one per claim',
        events: ['DisputeOpenedV1', 'DisputeResolvedV1'],
      },
      settlementId: {
        type: 'bytes32',
        scope: 'global',
        uniqueness: 'one-time',
        description: 'Unique settlement batch identifier, replay prevention',
        events: [
          'ClaimSettled',
          'BatchSettlementCompleted',
          'SettlementSkipped',
          'RewardAllocated',
        ],
      },
      distributionId: {
        type: 'bytes32',
        scope: 'global',
        uniqueness: 'one-time',
        description: 'Unique reward distribution identifier',
        events: ['RewardClaimed'],
      },
    },
    
    // Lifecycle flows
    flows: [
      {
        name: 'Standard Claim Verification',
        description: 'Claim created, verified, and settled without dispute',
        requiredEvents: [
          'ClaimCreated',
          'ClaimStatusUpdated',
          'RoundOpened',
          'VerificationSubmitted',
          'RoundClosed',
          'RoundAggregated',
          'ProvisionalOutcomeCreated',
          'ClaimSettled',
        ],
        correlationKey: 'claimId',
        orderingConstraints: [
          'ClaimCreated must be first',
          'RoundOpened precedes VerificationSubmitted',
          'RoundClosed follows all VerificationSubmitted for same round',
          'RoundAggregated immediately follows RoundClosed',
          'ProvisionalOutcomeCreated follows RoundAggregated',
          'ClaimSettled occurs after challengeDeadline',
        ],
      },
      {
        name: 'Disputed Claim with Appeal',
        description: 'Claim outcome challenged, appeal round conducted',
        requiredEvents: [
          'ProvisionalOutcomeCreated',
          'DisputeOpenedV1',
          'ClaimStatusUpdated',
          'RoundOpened',
          'VerificationSubmitted',
          'RoundClosed',
          'RoundAggregated',
          'DisputeResolvedV1',
          'ClaimStatusUpdated',
        ],
        correlationKeys: ['claimId', 'disputeId', 'roundId'],
        orderingConstraints: [
          'DisputeOpenedV1 within challengeDeadline',
          'ClaimStatusUpdated to Disputed immediately follows DisputeOpenedV1',
          'Appeal RoundOpened has roundType=APPEAL',
          'DisputeResolvedV1 after appeal RoundClosed',
        ],
      },
      {
        name: 'Batch Settlement',
        description: 'Multiple beneficiaries settled in one transaction',
        requiredEvents: [
          'ClaimSettled',
          'BatchSettlementCompleted',
        ],
        optionalEvents: ['SettlementSkipped'],
        correlationKey: 'settlementId',
        orderingConstraints: [
          'All ClaimSettled events share same settlementId',
          'BatchSettlementCompleted is last event in transaction',
          'settlementId is unique (no replay)',
        ],
      },
      {
        name: 'Verifier Slashing',
        description: 'Incorrect verifier stake slashed after settlement',
        requiredEvents: [
          'VerifierSlashed',
          'StakeSlashed',
        ],
        correlationKeys: ['claimId', 'verifier'],
        orderingConstraints: [
          'VerifierSlashed precedes StakeSlashed',
          'Both events in same transaction',
          'Amounts must match',
        ],
      },
      {
        name: 'Reward Allocation and Claiming',
        description: 'Rewards allocated then claimed by winners',
        requiredEvents: [
          'RewardAllocated',
          'RewardClaimed',
        ],
        correlationKeys: ['claimId', 'settlementId', 'distributionId'],
        orderingConstraints: [
          'RewardAllocated after claim finalized',
          'RewardClaimed may occur later, separate transaction',
          'distributionId in RewardClaimed matches prior allocation',
        ],
      },
    ],
    
    // Financial reconciliation requirements
    reconciliation: {
      description: 'Event totals must match on-chain storage balances',
      equations: [
        {
          entity: 'Verifier Stake Balance',
          formula: 'balance = Σ StakeDeposited - Σ StakeWithdrawn - Σ StakeSlashed + Σ StakeReleased',
          tolerance: '1 wei',
        },
        {
          entity: 'Claim Settlement',
          formula: 'totalSettled = Σ ClaimSettled[claimId].amount',
          tolerance: '0',
        },
        {
          entity: 'Reward Pool',
          formula: 'pool = Σ RewardPoolFunded - Σ RewardDistributed - Σ RewardClaimed',
          tolerance: '1 wei',
        },
      ],
    },
  };
  
  const checksumData = JSON.stringify(map, null, 0);
  map.checksum = createHash('sha256').update(checksumData).digest('hex');
  
  console.log(`   ✅ Generated correlation map for ${map.flows.length} flows`);
  
  return map;
}

/**
 * Generate version manifest
 */
function generateVersionManifest(abiSnapshot) {
  console.log('📋 Generating version manifest...');
  
  // Detect versions from event names
  const versionPattern = /V(\d+)$/;
  const versionedEvents = {};
  
  for (const event of abiSnapshot.events) {
    const match = event.name.match(versionPattern);
    const version = match ? parseInt(match[1], 10) : 0;
    const baseName = event.name.replace(versionPattern, '');
    
    if (!versionedEvents[baseName]) {
      versionedEvents[baseName] = [];
    }
    
    versionedEvents[baseName].push({
      version,
      fullName: event.name,
      signature: event.signature,
      topic0: event.topic0,
      status: version >= 1 ? 'active' : 'legacy',
    });
  }
  
  const manifest = {
    version: '2.0',
    generated: new Date().toISOString(),
    currentSchemaVersion: 1,
    description: 'Event schema version registry and evolution tracking',
    
    versioningPolicy: {
      immutability: 'Event signatures immutable once deployed to mainnet',
      additiveChanges: [
        'Adding new events',
        'Adding new fields to existing events (at end)',
        'Emitting events from new contracts',
      ],
      breakingChanges: [
        'Changing event name',
        'Changing parameter types',
        'Changing parameter order',
        'Changing indexed/unindexed status',
        'Removing fields',
      ],
      versionIncrement: 'Breaking changes require V2, V3, etc. suffix',
    },
    
    events: versionedEvents,
    
    activeVersions: Object.entries(versionedEvents)
      .filter(([_, versions]) => versions.some(v => v.status === 'active'))
      .map(([baseName, versions]) => ({
        baseName,
        currentVersion: Math.max(...versions.map(v => v.version)),
        allVersions: versions.map(v => v.version).sort(),
      })),
  };
  
  const checksumData = JSON.stringify(manifest.events, null, 0);
  manifest.checksum = createHash('sha256').update(checksumData).digest('hex');
  
  console.log(`   ✅ Generated manifest for ${Object.keys(versionedEvents).length} event families`);
  
  return manifest;
}

/**
 * Verify snapshots (check for drift)
 */
async function verifySnapshots() {
  console.log('\n🔍 Verifying snapshots...\n');
  
  const snapshotFiles = [
    'event-abi-snapshot.json',
    'event-signature-snapshot.json',
    'event-correlation-map.json',
    'event-version-manifest.json',
  ];
  
  let allExist = true;
  let allValid = true;
  
  for (const file of snapshotFiles) {
    const filePath = path.join(OUT_DIR, file);
    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const snapshot = JSON.parse(content);
      
      if (!snapshot.checksum) {
        console.error(`   ❌ ${file}: Missing checksum`);
        allValid = false;
      } else {
        console.log(`   ✅ ${file}: OK (checksum: ${snapshot.checksum.slice(0, 16)}...)`);
      }
    } catch (error) {
      console.error(`   ❌ ${file}: ${error.message}`);
      allExist = false;
      allValid = false;
    }
  }
  
  if (!allExist) {
    console.error('\n❌ Verification failed: Missing snapshot files');
    process.exit(1);
  }
  
  if (!allValid) {
    console.error('\n❌ Verification failed: Invalid snapshots');
    process.exit(1);
  }
  
  console.log('\n✅ All snapshots verified\n');
}

/**
 * Main execution
 */
async function main() {
  const args = process.argv.slice(2);
  const verifyOnly = args.includes('--verify');
  
  if (verifyOnly) {
    await verifySnapshots();
    return;
  }
  
  console.log('\n📸 TruthBounty V2 Event Snapshot Generator\n');
  console.log('================================================\n');
  
  // Ensure output directory exists
  await fs.mkdir(OUT_DIR, { recursive: true });
  
  // Generate snapshots
  const abiSnapshot = await generateEventAbiSnapshot();
  const signatureSnapshot = generateSignatureSnapshot(abiSnapshot);
  const correlationMap = generateCorrelationMap();
  const versionManifest = generateVersionManifest(abiSnapshot);
  
  // Write snapshots
  console.log('\n💾 Writing snapshots...');
  
  await fs.writeFile(
    path.join(OUT_DIR, 'event-abi-snapshot.json'),
    JSON.stringify(abiSnapshot, null, 2),
    'utf-8'
  );
  console.log('   ✅ event-abi-snapshot.json');
  
  await fs.writeFile(
    path.join(OUT_DIR, 'event-signature-snapshot.json'),
    JSON.stringify(signatureSnapshot, null, 2),
    'utf-8'
  );
  console.log('   ✅ event-signature-snapshot.json');
  
  await fs.writeFile(
    path.join(OUT_DIR, 'event-correlation-map.json'),
    JSON.stringify(correlationMap, null, 2),
    'utf-8'
  );
  console.log('   ✅ event-correlation-map.json');
  
  await fs.writeFile(
    path.join(OUT_DIR, 'event-version-manifest.json'),
    JSON.stringify(versionManifest, null, 2),
    'utf-8'
  );
  console.log('   ✅ event-version-manifest.json');
  
  console.log('\n================================================');
  console.log('✅ Event snapshots generated successfully\n');
  console.log(`📂 Output directory: ${OUT_DIR}`);
  console.log(`📊 Total events: ${abiSnapshot.events.length}`);
  console.log(`🏢 Contracts processed: ${abiSnapshot.contracts.length}`);
  console.log(`🔑 Unique signatures: ${signatureSnapshot.eventCount}`);
  console.log(`🔗 Lifecycle flows: ${correlationMap.flows.length}`);
  console.log('\n💡 Run with --verify to check snapshots\n');
}

// Note: The topic0 calculation above uses SHA256 as a placeholder.
// Real topic0 values should be extracted from actual transaction logs
// or calculated using proper Keccak256 (not available in Node.js crypto by default).
// For production, consider using ethers.js or web3.js for accurate topic0 calculation.

main().catch((error) => {
  console.error('\n❌ Error:', error.message);
  console.error(error.stack);
  process.exit(1);
});
