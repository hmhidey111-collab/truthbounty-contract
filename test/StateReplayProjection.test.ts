import { expect } from "chai";
import { ethers } from "hardhat";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const replayFixture = JSON.parse(
  readFileSync(join(__dirname, "fixtures", "event-replay", "v1.json"), "utf8")
) as {
  fixtureVersion: number;
  eventSchemaVersion: number;
  eventOrder: string[];
  journeys: Record<string, string[]>;
};

interface ReplayLog {
  chainId: number;
  blockNumber: number;
  blockHash: string;
  transactionHash: string;
  logIndex: number;
  eventName: string;
  schemaVersion: number;
  topics: string[];
  data: string;
}

interface ReplayCheckpoint {
  fixtureVersion: number;
  events: ReplayLog[];
}

class VersionedLogReplay {
  private events: ReplayLog[];
  private seen: Set<string>;

  constructor(fixtureVersion: number, checkpoint?: ReplayCheckpoint) {
    if (fixtureVersion !== replayFixture.fixtureVersion) {
      throw new Error(`Unsupported replay fixture version: ${fixtureVersion}`);
    }
    if (checkpoint && checkpoint.fixtureVersion !== fixtureVersion) {
      throw new Error(`Checkpoint version ${checkpoint.fixtureVersion} does not match ${fixtureVersion}`);
    }
    this.events = checkpoint ? [...checkpoint.events] : [];
    this.seen = new Set(this.events.map((event) => this.identity(event)));
  }

  apply(event: ReplayLog): void {
    if (event.schemaVersion !== replayFixture.eventSchemaVersion) {
      throw new Error(`Unsupported event schema version: ${event.schemaVersion}`);
    }
    const key = this.identity(event);
    if (this.seen.has(key)) return;
    this.events.push(event);
    this.events.sort((left, right) =>
      left.blockNumber - right.blockNumber || left.logIndex - right.logIndex
    );
    this.seen.add(key);
  }

  rollbackFrom(blockNumber: number): void {
    this.events = this.events.filter((event) => event.blockNumber < blockNumber);
    this.seen = new Set(this.events.map((event) => this.identity(event)));
  }

  checkpoint(): ReplayCheckpoint {
    return { fixtureVersion: replayFixture.fixtureVersion, events: [...this.events] };
  }

  getEvents(): ReplayLog[] {
    return [...this.events];
  }

  digest(): string {
    const canonical = this.events.map((event) => [
      event.chainId,
      event.blockNumber,
      event.blockHash,
      event.transactionHash,
      event.logIndex,
      event.eventName,
      event.schemaVersion,
      event.topics,
      event.data,
    ]);
    return ethers.keccak256(ethers.toUtf8Bytes(JSON.stringify(canonical)));
  }

  private identity(event: ReplayLog): string {
    return `${event.chainId}:${event.blockHash}:${event.transactionHash}:${event.logIndex}`;
  }
}

function assertFixtureCompleteness(events: ReplayLog[]): void {
  const required = Object.values(replayFixture.journeys).flat().sort();
  expect([...replayFixture.eventOrder].sort()).to.deep.equal(required);
  expect(events.map((event) => event.eventName)).to.deep.equal(replayFixture.eventOrder);
}

function assertReplayDigest(expectedDigest: string, replay: VersionedLogReplay): void {
  if (replay.digest() !== expectedDigest) {
    throw new Error("Replayed event digest does not match the on-chain query digest");
  }
}

interface ProjectedClaim {
  id: bigint;
  creator: string;
  metadataHash: string;
  status: number;
  resolved: boolean;
  outcome?: boolean;
  finalized: boolean;
}

interface ProjectedEvidence {
  claimId: bigint;
  evidenceId: bigint;
  submitter: string;
  evidenceHash: string;
  revoked: boolean;
}

interface ProjectedVerifierState {
  totalStaked: bigint;
  activeStaked: bigint;
  slashed: bigint;
  rewardsClaimed: bigint;
}

interface ProjectedTreasury {
  accounts: Record<number, bigint>;
  totalAssets: bigint;
}

class ProtocolStateProjection {
  public claims = new Map<bigint, ProjectedClaim>();
  public evidence = new Map<bigint, ProjectedEvidence[]>();
  public verifiers = new Map<string, ProjectedVerifierState>();
  public votes = new Map<string, { support: boolean; stake: bigint }>();
  public rewardsEscrowed = new Map<string, bigint>();
  public treasury: ProjectedTreasury = { accounts: {}, totalAssets: 0n };
  public parameters = new Map<string, { version: bigint; value: bigint }>();
  public disputes = new Map<bigint, {
    challenger: string;
    bondAmount: bigint;
    open: boolean;
    ruling?: number;
    outcome?: number;
  }>();
  public roles = new Set<string>();
  public governanceProposals = new Map<string, { proposer: string; executed: boolean }>();
  public paused = false;
  public upgradeProposals = new Map<string, {
    version: [bigint, bigint, bigint];
    implementation: string;
    approved: boolean;
  }>();
  public implementationByModule = new Map<string, string>();

  private getVerifier(addr: string): ProjectedVerifierState {
    const key = addr.toLowerCase();
    if (!this.verifiers.has(key)) {
      this.verifiers.set(key, {
        totalStaked: 0n,
        activeStaked: 0n,
        slashed: 0n,
        rewardsClaimed: 0n,
      });
    }
    return this.verifiers.get(key)!;
  }

  public applyLog(eventName: string, args: any) {
    switch (eventName) {
      case "ClaimCreatedV1": {
        this.claims.set(args.claimId, {
          id: args.claimId,
          creator: args.actor,
          metadataHash: args.metadataHash,
          status: 0,
          resolved: false,
          finalized: false,
        });
        break;
      }

      case "ClaimStatusTransitionedV1": {
        const claim = this.claims.get(args.claimId);
        if (claim) {
          claim.status = Number(args.newStatus);
        }
        break;
      }

      case "ClaimResolvedV1": {
        const claim = this.claims.get(args.claimId);
        if (claim) {
          claim.resolved = true;
          claim.outcome = args.outcome;
        }
        break;
      }

      case "ClaimFinalizedV1": {
        const claim = this.claims.get(args.claimId);
        if (claim) {
          claim.finalized = true;
        }
        break;
      }

      case "EvidenceSubmittedV1": {
        const list = this.evidence.get(args.claimId) || [];
        list.push({
          claimId: args.claimId,
          evidenceId: args.evidenceId,
          submitter: args.submitter,
          evidenceHash: args.evidenceHash,
          revoked: false,
        });
        this.evidence.set(args.claimId, list);
        break;
      }

      case "EvidenceRevokedV1": {
        const list = this.evidence.get(args.claimId) || [];
        const item = list.find((e) => e.evidenceId === args.evidenceId);
        if (item) {
          item.revoked = true;
        }
        break;
      }

      case "StakeDepositedV1": {
        const v = this.getVerifier(args.verifier);
        v.totalStaked = args.newBalance;
        break;
      }

      case "StakeLockedV1": {
        const v = this.getVerifier(args.verifier);
        v.activeStaked = args.resultingActiveStake;
        break;
      }

      case "StakeUnlockedV1": {
        const v = this.getVerifier(args.verifier);
        v.activeStaked = args.resultingActiveStake;
        break;
      }

      case "StakeWithdrawnV1": {
        const v = this.getVerifier(args.verifier);
        v.totalStaked = args.newBalance;
        break;
      }

      case "VerificationSubmittedV1": {
        const key = `${args.claimId}-${args.verifier.toLowerCase()}`;
        this.votes.set(key, {
          support: args.support,
          stake: args.stakeAmount,
        });
        break;
      }

      case "SlashExecutedV1": {
        const v = this.getVerifier(args.verifier);
        v.slashed += args.amount;
        break;
      }

      case "RewardEscrowedV1": {
        const key = args.recipient.toLowerCase();
        const cur = this.rewardsEscrowed.get(key) || 0n;
        this.rewardsEscrowed.set(key, cur + args.amount);
        break;
      }

      case "RewardClaimedV1": {
        const v = this.getVerifier(args.recipient);
        v.rewardsClaimed += args.amount;
        const cur = this.rewardsEscrowed.get(args.recipient.toLowerCase()) || 0n;
        this.rewardsEscrowed.set(args.recipient.toLowerCase(), cur - args.amount);
        break;
      }

      case "TreasuryDepositV1": {
        const acc = Number(args.account);
        const cur = this.treasury.accounts[acc] || 0n;
        this.treasury.accounts[acc] = cur + args.amount;
        this.treasury.totalAssets += args.amount;
        break;
      }

      case "TreasuryTransferV1": {
        // Accounting value transfer
        break;
      }

      case "ParameterUpdatedV1": {
        this.parameters.set(args.paramName, {
          version: args.parameterVersion,
          value: args.newValue,
        });
        break;
      }

      case "DisputeRaisedV1":
      case "DisputeOpenedV1": {
        this.disputes.set(args.disputeId, {
          challenger: args.challenger,
          bondAmount: args.bondAmount,
          open: true,
        });
        break;
      }

      case "DisputeResolvedV1": {
        const dispute = this.disputes.get(args.disputeId);
        if (dispute) {
          dispute.open = false;
          dispute.ruling = Number(args.ruling);
          dispute.outcome = Number(args.resultingOutcome);
        }
        break;
      }

      case "RoleGrantedV1": {
        this.roles.add(`${args.role.toLowerCase()}:${args.account.toLowerCase()}`);
        break;
      }

      case "RoleRevokedV1": {
        this.roles.delete(`${args.role.toLowerCase()}:${args.account.toLowerCase()}`);
        break;
      }

      case "GovernanceProposalCreatedV1": {
        this.governanceProposals.set(args.proposalId.toLowerCase(), {
          proposer: args.proposer.toLowerCase(),
          executed: false,
        });
        break;
      }

      case "GovernanceProposalExecutedV1": {
        const proposal = this.governanceProposals.get(args.proposalId.toLowerCase());
        if (proposal) proposal.executed = true;
        break;
      }

      case "EmergencyPauseActivatedV1": {
        this.paused = true;
        break;
      }

      case "EmergencyPauseRecoveredV1": {
        this.paused = false;
        break;
      }

      case "UpgradeProposedV1": {
        const key = `${args.moduleId.toLowerCase()}:${args.proposalId}`;
        this.upgradeProposals.set(key, {
          version: [args.toMajor, args.toMinor, args.toPatch],
          implementation: args.newImplementation.toLowerCase(),
          approved: false,
        });
        break;
      }

      case "UpgradeApprovedV1": {
        const proposal = this.upgradeProposals.get(`${args.moduleId.toLowerCase()}:${args.proposalId}`);
        if (proposal) proposal.approved = true;
        break;
      }

      case "UpgradeExecutedV1": {
        this.implementationByModule.set(args.moduleId.toLowerCase(), args.newImplementation.toLowerCase());
        break;
      }

      case "UpgradeRolledBackV1": {
        this.implementationByModule.set(args.moduleId.toLowerCase(), args.restoredImplementation.toLowerCase());
        break;
      }
    }
  }
}

describe("State Replay Projection Fixture (From Logs Only)", function () {
  it("fully reconstructs a complete claim lifecycle and financial balances from logs", async function () {
    const [admin, creator, verifier1, verifier2, challenger] = await ethers.getSigners();
    const factory = await ethers.getContractFactory("EventArchitectureHarness");
    const harness = await factory.deploy();
    await harness.waitForDeployment();

    const projection = new ProtocolStateProjection();
    const claimId = 42n;
    const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("claim-42-content"));
    const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes("evidence-ipfs-cid-v2"));
    const reasonSlash = ethers.keccak256(ethers.toUtf8Bytes("LOSING_VOTE"));
    const paramMinStake = ethers.keccak256(ethers.toUtf8Bytes("MIN_STAKE"));

    // 1. Governance parameter update
    let tx = await harness.emitParameterUpdatedV1(paramMinStake, 1n, 100n, 200n, 1700000000);
    let receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // 2. Claim created
    tx = await harness.emitClaimCreatedV1(claimId, creator.address, metadataHash);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // 3. Evidence attached
    tx = await harness.emitEvidenceSubmittedV1(claimId, 1n, creator.address, evidenceHash);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // 4. Status -> UnderVerification
    tx = await harness.emitClaimStatusTransitionedV1(claimId, admin.address, 0, 1);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // 5. Verifiers deposit collateral
    tx = await harness.emitStakeDepositedV1(verifier1.address, 1000n, 1000n);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    tx = await harness.emitStakeDepositedV1(verifier2.address, 1000n, 1000n);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // 6. Verifiers lock stake and vote
    tx = await harness.emitStakeLockedV1(claimId, verifier1.address, 1n, 500n, 500n);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    tx = await harness.emitVerificationSubmittedV1(claimId, verifier1.address, true, 500n);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    tx = await harness.emitStakeLockedV1(claimId, verifier2.address, 1n, 500n, 500n);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    tx = await harness.emitVerificationSubmittedV1(claimId, verifier2.address, false, 500n);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // 7. Round aggregation and claim resolved TRUE
    tx = await harness.emitOutcomeAggregatedV1(claimId, 1n, 1, 500n, 500n, 10000);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    tx = await harness.emitClaimResolvedV1(claimId, admin.address, true);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // 8. Slashing losing verifier2 (100 tokens)
    tx = await harness.emitSlashExecutedV1(claimId, verifier2.address, reasonSlash, 100n);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // 9. Reward escrowed for winner verifier1 (80 tokens)
    tx = await harness.emitRewardEscrowedV1(claimId, verifier1.address, 80n);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // 10. Verifier1 claims reward
    tx = await harness.emitRewardClaimedV1(claimId, verifier1.address, 80n);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // 11. Stakes unlocked
    tx = await harness.emitStakeUnlockedV1(claimId, verifier1.address, 1n, 500n, 0n);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    tx = await harness.emitStakeUnlockedV1(claimId, verifier2.address, 1n, 400n, 0n);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // 12. Finalize claim
    tx = await harness.emitClaimFinalizedV1(claimId, admin.address);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // 13. Treasury deposit of remaining 20 slashed tokens into Protocol Fees
    const opId = ethers.keccak256(ethers.toUtf8Bytes("SLASH_FEE_OP_42"));
    tx = await harness.emitTreasuryDepositV1(opId, 2, ethers.ZeroAddress, 20n, admin.address);
    receipt = await tx.wait();
    for (const log of receipt!.logs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) projection.applyLog(parsed.name, parsed.args);
    }

    // =========================================================================
    // INVARIANT ASSERTIONS ON RECONSTRUCTED STATE
    // =========================================================================
    // 1. Claim state reconstructed
    const projectedClaim = projection.claims.get(claimId);
    expect(projectedClaim).to.not.be.undefined;
    expect(projectedClaim!.creator).to.equal(creator.address);
    expect(projectedClaim!.metadataHash).to.equal(metadataHash);
    expect(projectedClaim!.status).to.equal(1);
    expect(projectedClaim!.resolved).to.be.true;
    expect(projectedClaim!.outcome).to.be.true;
    expect(projectedClaim!.finalized).to.be.true;

    // 2. Evidence state reconstructed
    const projectedEvidence = projection.evidence.get(claimId);
    expect(projectedEvidence).to.have.length(1);
    expect(projectedEvidence![0].evidenceHash).to.equal(evidenceHash);
    expect(projectedEvidence![0].revoked).to.be.false;

    // 3. Verifier 1 (Winner) financial accounting reconciled
    const v1State = projection.verifiers.get(verifier1.address.toLowerCase());
    expect(v1State).to.not.be.undefined;
    expect(v1State!.totalStaked).to.equal(1000n);
    expect(v1State!.activeStaked).to.equal(0n);
    expect(v1State!.rewardsClaimed).to.equal(80n);
    expect(v1State!.slashed).to.equal(0n);

    // 4. Verifier 2 (Loser) financial accounting reconciled
    const v2State = projection.verifiers.get(verifier2.address.toLowerCase());
    expect(v2State).to.not.be.undefined;
    expect(v2State!.totalStaked).to.equal(1000n);
    expect(v2State!.activeStaked).to.equal(0n);
    expect(v2State!.slashed).to.equal(100n);
    expect(v2State!.rewardsClaimed).to.equal(0n);

    // 5. Escrow and Treasury financial reconciliation
    expect(projection.rewardsEscrowed.get(verifier1.address.toLowerCase())).to.equal(0n);
    expect(projection.treasury.accounts[2]).to.equal(20n); // 20 tokens to protocol fee bucket
    expect(projection.treasury.totalAssets).to.equal(20n);

    // Financial balance invariant: Slashed Total (100) = Winner Reward (80) + Treasury Fee (20)
    expect(v2State!.slashed).to.equal(v1State!.rewardsClaimed + projection.treasury.accounts[2]);

    // 6. Parameter versioning
    const param = projection.parameters.get(paramMinStake);
    expect(param).to.not.be.undefined;
    expect(param!.version).to.equal(1n);
    expect(param!.value).to.equal(200n);
  });

  it("replays versioned journeys across restart, duplicate delivery, missing logs, reorgs, and schema changes", async function () {
    const [admin, creator, verifier, challenger, implementation] = await ethers.getSigners();
    const factory = await ethers.getContractFactory("EventArchitectureHarness");
    const harness = await factory.deploy();
    await harness.waitForDeployment();

    const chainId = Number((await ethers.provider.getNetwork()).chainId);
    const claimId = 57n;
    const moduleId = ethers.keccak256(ethers.toUtf8Bytes("truth-bounty-module"));
    const proposalId = ethers.keccak256(ethers.toUtf8Bytes("sc-057-proposal"));
    const reasonHash = ethers.keccak256(ethers.toUtf8Bytes("fixture-reason"));
    const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("fixture-metadata"));
    const canonicalLogs: ReplayLog[] = [];

    const record = async (send: () => Promise<any>) => {
      const receipt = await (await send()).wait();
      for (const log of receipt!.logs) {
        if (log.address.toLowerCase() !== (await harness.getAddress()).toLowerCase()) continue;
        const parsed = harness.interface.parseLog(log);
        if (!parsed) continue;
        canonicalLogs.push({
          chainId,
          blockNumber: log.blockNumber,
          blockHash: log.blockHash,
          transactionHash: log.transactionHash,
          logIndex: log.index,
          eventName: parsed.name,
          schemaVersion: Number(parsed.args[parsed.args.length - 1]),
          topics: [...log.topics],
          data: log.data,
        });
      }
    };

    const calls: Array<() => Promise<any>> = [
      () => harness.emitClaimCreatedV1(claimId, creator.address, metadataHash),
      () => harness.emitEvidenceSubmittedV1(claimId, 1n, creator.address, reasonHash),
      () => harness.emitClaimStatusTransitionedV1(claimId, admin.address, 0, 1),
      () => harness.emitStakeDepositedV1(verifier.address, 1000n, 1000n),
      () => harness.emitStakeLockedV1(claimId, verifier.address, 1n, 500n, 500n),
      () => harness.emitVerificationSubmittedV1(claimId, verifier.address, true, 500n),
      () => harness.emitOutcomeAggregatedV1(claimId, 1n, 1, 500n, 0n, 10000n),
      () => harness.emitDisputeRaisedV1(claimId, 1n, challenger.address, 100n, reasonHash),
      () => harness.emitDisputeOpenedV1(
        claimId, 1n, challenger.address, 1, 2, ethers.ZeroAddress, 100n, 1900000000n, reasonHash
      ),
      () => harness.emitDisputeResolvedV1(claimId, 1n, admin.address, 1, 1),
      () => harness.emitClaimResolvedV1(claimId, admin.address, true),
      () => harness.emitSlashExecutedV1(claimId, verifier.address, reasonHash, 100n),
      () => harness.emitRewardEscrowedV1(claimId, verifier.address, 80n),
      () => harness.emitRewardClaimedV1(claimId, verifier.address, 80n),
      () => harness.emitStakeUnlockedV1(claimId, verifier.address, 1n, 500n, 0n),
      () => harness.emitTreasuryDepositV1(proposalId, 2, ethers.ZeroAddress, 20n, admin.address),
      () => harness.emitClaimFinalizedV1(claimId, admin.address),
      () => harness.emitParameterUpdatedV1(reasonHash, 2n, 100n, 200n, 1700000000n),
      () => harness.emitRoleGrantedV1(reasonHash, verifier.address, admin.address),
      () => harness.emitGovernanceProposalCreatedV1(proposalId, admin.address, metadataHash),
      () => harness.emitGovernanceProposalExecutedV1(proposalId, admin.address),
      () => harness.emitEmergencyPauseActivatedV1(admin.address, reasonHash),
      () => harness.emitEmergencyPauseRecoveredV1(admin.address),
      () => harness.emitUpgradeProposedV1(
        1n, moduleId, implementation.address, 2n, 0n, 0n, metadataHash, admin.address
      ),
      () => harness.emitUpgradeApprovedV1(1n, moduleId, 1700000000n, admin.address),
      () => harness.emitUpgradeExecutedV1(1n, moduleId, admin.address, implementation.address, admin.address),
      () => harness.emitUpgradeRolledBackV1(
        moduleId, implementation.address, admin.address, reasonHash, admin.address
      ),
    ];
    for (const call of calls) await record(call);

    const uninterrupted = new VersionedLogReplay(replayFixture.fixtureVersion);
    canonicalLogs.forEach((log) => uninterrupted.apply(log));
    assertFixtureCompleteness(uninterrupted.getEvents());

    const queriedLogs = await ethers.provider.getLogs({
      address: await harness.getAddress(),
      fromBlock: canonicalLogs[0].blockNumber,
      toBlock: canonicalLogs[canonicalLogs.length - 1].blockNumber,
    });
    const onChainQuery = new VersionedLogReplay(replayFixture.fixtureVersion);
    for (const log of queriedLogs) {
      const parsed = harness.interface.parseLog(log);
      if (!parsed) continue;
      onChainQuery.apply({
        chainId,
        blockNumber: log.blockNumber,
        blockHash: log.blockHash,
        transactionHash: log.transactionHash,
        logIndex: log.index,
        eventName: parsed.name,
        schemaVersion: Number(parsed.args[parsed.args.length - 1]),
        topics: [...log.topics],
        data: log.data,
      });
    }
    assertFixtureCompleteness(onChainQuery.getEvents());
    const onChainQueryDigest = onChainQuery.digest();
    assertReplayDigest(onChainQueryDigest, uninterrupted);

    const replayedState = new ProtocolStateProjection();
    for (const log of queriedLogs) {
      const parsed = harness.interface.parseLog(log);
      if (parsed) replayedState.applyLog(parsed.name, parsed.args);
    }
    const projectedClaim = replayedState.claims.get(claimId);
    expect(projectedClaim?.status).to.equal(1);
    expect(projectedClaim?.resolved).to.equal(true);
    expect(projectedClaim?.outcome).to.equal(true);
    expect(projectedClaim?.finalized).to.equal(true);
    const verifierState = replayedState.verifiers.get(verifier.address.toLowerCase());
    expect(verifierState?.totalStaked).to.equal(1000n);
    expect(verifierState?.activeStaked).to.equal(0n);
    expect(verifierState?.slashed).to.equal(100n);
    expect(verifierState?.rewardsClaimed).to.equal(80n);
    expect(replayedState.rewardsEscrowed.get(verifier.address.toLowerCase())).to.equal(0n);
    expect(replayedState.treasury.accounts[2]).to.equal(20n);
    expect(verifierState!.slashed).to.equal(
      verifierState!.rewardsClaimed + replayedState.treasury.accounts[2]
    );
    const dispute = replayedState.disputes.get(1n);
    expect(dispute?.open).to.equal(false);
    expect(dispute?.ruling).to.equal(1);
    expect(dispute?.outcome).to.equal(1);
    expect(replayedState.parameters.get(reasonHash)?.version).to.equal(2n);
    expect(replayedState.parameters.get(reasonHash)?.value).to.equal(200n);
    expect(replayedState.roles.has(`${reasonHash}:${verifier.address.toLowerCase()}`)).to.equal(true);
    expect(replayedState.governanceProposals.get(proposalId)?.executed).to.equal(true);
    expect(replayedState.paused).to.equal(false);
    expect(replayedState.upgradeProposals.get(`${moduleId}:1`)?.approved).to.equal(true);
    expect(replayedState.upgradeProposals.get(`${moduleId}:1`)?.version).to.deep.equal([2n, 0n, 0n]);
    expect(replayedState.implementationByModule.get(moduleId)).to.equal(admin.address.toLowerCase());

    const split = Math.floor(canonicalLogs.length / 2);
    const beforeRestart = new VersionedLogReplay(replayFixture.fixtureVersion);
    canonicalLogs.slice(0, split).forEach((log) => beforeRestart.apply(log));
    const afterRestart = new VersionedLogReplay(
      replayFixture.fixtureVersion,
      beforeRestart.checkpoint()
    );
    canonicalLogs.slice(split).forEach((log) => afterRestart.apply(log));
    assertReplayDigest(onChainQueryDigest, afterRestart);

    const duplicateDelivery = new VersionedLogReplay(replayFixture.fixtureVersion);
    [...canonicalLogs, ...canonicalLogs].forEach((log) => duplicateDelivery.apply(log));
    assertReplayDigest(onChainQueryDigest, duplicateDelivery);

    const missingLog = new VersionedLogReplay(replayFixture.fixtureVersion);
    canonicalLogs.filter((_, index) => index !== 6).forEach((log) => missingLog.apply(log));
    expect(() => assertFixtureCompleteness(missingLog.getEvents())).to.throw();
    expect(() => assertReplayDigest(onChainQueryDigest, missingLog)).to.throw();

    const changedLog = new VersionedLogReplay(replayFixture.fixtureVersion);
    canonicalLogs.forEach((log, index) => changedLog.apply(
      index === 6 ? { ...log, data: `${log.data.slice(0, -2)}00` } : log
    ));
    expect(() => assertReplayDigest(onChainQueryDigest, changedLog)).to.throw();

    const reorgBlock = canonicalLogs[split].blockNumber;
    const reorgReplay = new VersionedLogReplay(replayFixture.fixtureVersion);
    canonicalLogs.forEach((log) => reorgReplay.apply(log));
    reorgReplay.rollbackFrom(reorgBlock);
    canonicalLogs
      .filter((log) => log.blockNumber >= reorgBlock)
      .map((log) => ({ ...log, blockHash: ethers.keccak256(ethers.toUtf8Bytes(`fork-${log.blockHash}`)) }))
      .forEach((log) => reorgReplay.apply(log));
    expect(reorgReplay.getEvents().some((log) => log.blockNumber >= reorgBlock &&
      log.blockHash === canonicalLogs.find((canonical) => canonical.blockNumber === log.blockNumber)?.blockHash
    )).to.equal(false);
    expect(() => assertReplayDigest(onChainQueryDigest, reorgReplay)).to.throw();

    expect(() => new VersionedLogReplay(replayFixture.fixtureVersion + 1)).to.throw();
    expect(() => {
      const replay = new VersionedLogReplay(replayFixture.fixtureVersion);
      replay.apply({ ...canonicalLogs[0], schemaVersion: replayFixture.eventSchemaVersion + 1 });
    }).to.throw();
  });
});
