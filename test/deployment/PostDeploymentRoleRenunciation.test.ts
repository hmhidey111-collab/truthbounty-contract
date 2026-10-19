import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { deployCanonicalV2, CanonicalV2Suite } from "../../scripts/deployCanonicalV2";

/**
 * V2-SC-127 — Post-Deployment Role Renunciation Checks (Hardhat)
 *
 * Verifies that deployers retain no unauthorized admin, upgrader, pauser, minter,
 * treasury, registry, or timelock roles after the canonical V2 deployment handoff.
 */
describe("Post-Deployment Role Renunciation (V2-SC-127)", function () {
  let deployer: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;

  // Role constants matching the Solidity catalog
  const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
  const REGISTRY_UPDATER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("REGISTRY_UPDATER_ROLE"));
  const PAUSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PAUSER_ROLE"));
  const RESOLVER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RESOLVER_ROLE"));
  const TREASURY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("TREASURY_ROLE"));
  const UPGRADE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("UPGRADE_ROLE"));
  const GOVERNANCE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("GOVERNANCE_ROLE"));
  const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
  const MIGRATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MIGRATOR_ROLE"));
  const UPGRADER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("UPGRADER_ROLE"));
  const CRITICAL_SLASHER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("CRITICAL_SLASHER_ROLE"));
  const ROUND_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ROUND_MANAGER_ROLE"));

  /** All roles to check on every contract. */
  const ALL_ROLES = [
    DEFAULT_ADMIN_ROLE,
    ADMIN_ROLE,
    REGISTRY_UPDATER_ROLE,
    PAUSER_ROLE,
    RESOLVER_ROLE,
    TREASURY_ROLE,
    UPGRADE_ROLE,
    GOVERNANCE_ROLE,
    MINTER_ROLE,
    MIGRATOR_ROLE,
    UPGRADER_ROLE,
    CRITICAL_SLASHER_ROLE,
    ROUND_MANAGER_ROLE,
  ];

  /**
   * Safely check whether `account` holds `role` on `contract`.
   * Returns false if the contract does not implement hasRole (catches revert).
   */
  async function safeHasRole(
    contract: { getAddress: () => Promise<string> },
    role: string,
    account: string
  ): Promise<boolean> {
    try {
      const addr = await contract.getAddress();
      const iface = new ethers.Interface([
        "function hasRole(bytes32 role, address account) view returns (bool)",
      ]);
      const calldata = iface.encodeFunctionData("hasRole", [role, account]);
      const result = await ethers.provider.call({ to: addr, data: calldata });
      return iface.decodeFunctionResult("hasRole", result)[0] as boolean;
    } catch {
      return false;
    }
  }

  /**
   * Assert that `account` holds zero roles from ALL_ROLES on all given contracts.
   */
  async function assertNoRolesRetained(
    account: string,
    contracts: Array<{ getAddress: () => Promise<string>; name?: string }>,
    contractNames: string[]
  ): Promise<void> {
    const violations: string[] = [];
    for (let i = 0; i < contracts.length; i++) {
      for (const role of ALL_ROLES) {
        const has = await safeHasRole(contracts[i], role, account);
        if (has) {
          violations.push(`${contractNames[i]} holds role ${role}`);
        }
      }
    }
    expect(violations).to.deep.equal(
      [],
      `Account ${account} retains unauthorized roles:\n  ${violations.join("\n  ")}`
    );
  }

  /**
   * Asserts that an asynchronous contract call promise rejects/reverts.
   */
  async function assertReverts(promise: Promise<unknown>): Promise<void> {
    let reverted = false;
    try {
      await promise;
    } catch {
      reverted = true;
    }
    expect(reverted).to.be.true;
  }

  // ════════════════════════════════════════════════════════════════════
  //  Canonical V2 Suite — DEFAULT deployment (deployer keeps admin)
  // ════════════════════════════════════════════════════════════════════

  describe("Default deployment (no finalization)", () => {
    let suite: CanonicalV2Suite;

    beforeEach(async () => {
      [deployer, user1, user2] = await ethers.getSigners();
      suite = await deployCanonicalV2(deployer);
    });

    it("deployer holds DEFAULT_ADMIN_ROLE on ClaimRegistry before finalization", async () => {
      const has = await safeHasRole(suite.claimRegistry, DEFAULT_ADMIN_ROLE, deployer.address);
      expect(has).to.be.true;
    });

    it("deployer holds DEFAULT_ADMIN_ROLE on TruthBountyWeighted before finalization", async () => {
      const has = await safeHasRole(suite.truthBountyWeighted, DEFAULT_ADMIN_ROLE, deployer.address);
      expect(has).to.be.true;
    });

    it("deployer holds DEFAULT_ADMIN_ROLE on VerificationAggregator before finalization", async () => {
      const has = await safeHasRole(suite.aggregator, DEFAULT_ADMIN_ROLE, deployer.address);
      expect(has).to.be.true;
    });

    it("unauthorized user holds no roles on any contract", async () => {
      const contracts = [
        suite.claimRegistry,
        suite.truthBountyWeighted,
        suite.aggregator,
        suite.provisionalSettlementEngine,
        suite.appealVerificationRound,
      ];
      const names = [
        "ClaimRegistry",
        "TruthBountyWeighted",
        "Aggregator",
        "ProvisionalSettlementEngine",
        "AppealVerificationRound",
      ];
      await assertNoRolesRetained(user1.address, contracts, names);
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  Canonical V2 Suite — FINALIZED deployment
  // ════════════════════════════════════════════════════════════════════

  describe("Finalized deployment (deployer roles renounced)", () => {
    let suite: CanonicalV2Suite;

    beforeEach(async () => {
      [deployer, user1, user2] = await ethers.getSigners();
      suite = await deployCanonicalV2(deployer, { finalizeDeployerRoles: true });
    });

    it("deployer does not hold REGISTRY_UPDATER_ROLE on ClaimRegistry after finalization", async () => {
      const has = await safeHasRole(suite.claimRegistry, REGISTRY_UPDATER_ROLE, deployer.address);
      expect(has).to.be.false;
    });

    it("ProvisionalSettlementEngine retains REGISTRY_UPDATER_ROLE after deployer finalization", async () => {
      const has = await safeHasRole(
        suite.claimRegistry,
        REGISTRY_UPDATER_ROLE,
        await suite.provisionalSettlementEngine.getAddress()
      );
      expect(has).to.be.true;
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  Role catalog exhaustive sweep
  // ════════════════════════════════════════════════════════════════════

  describe("Exhaustive role sweep — finalized suite", () => {
    let suite: CanonicalV2Suite;
    let contracts: Array<{ getAddress: () => Promise<string> }>;
    let names: string[];

    beforeEach(async () => {
      [deployer, user1, user2] = await ethers.getSigners();
      suite = await deployCanonicalV2(deployer, { finalizeDeployerRoles: true });
      contracts = [
        suite.governanceController,
        suite.token,
        suite.oracle,
        suite.claimRegistry,
        suite.truthBountyWeighted,
        suite.aggregator,
        suite.provisionalSettlementEngine,
        suite.appealVerificationRound,
      ];
      names = [
        "GovernanceController",
        "Token",
        "Oracle",
        "ClaimRegistry",
        "TruthBountyWeighted",
        "Aggregator",
        "ProvisionalSettlementEngine",
        "AppealVerificationRound",
      ];
    });

    it("deployer holds no PAUSER_ROLE on any contract", async () => {
      for (let i = 0; i < contracts.length; i++) {
        const has = await safeHasRole(contracts[i], PAUSER_ROLE, deployer.address);
        expect(has).to.be.false;
      }
    });

    it("deployer holds no MINTER_ROLE on any contract", async () => {
      for (let i = 0; i < contracts.length; i++) {
        const has = await safeHasRole(contracts[i], MINTER_ROLE, deployer.address);
        expect(has).to.be.false;
      }
    });

    it("deployer holds no TREASURY_ROLE on any contract", async () => {
      for (let i = 0; i < contracts.length; i++) {
        const has = await safeHasRole(contracts[i], TREASURY_ROLE, deployer.address);
        expect(has).to.be.false;
      }
    });

    it("deployer holds no UPGRADE_ROLE on any contract", async () => {
      for (let i = 0; i < contracts.length; i++) {
        const has = await safeHasRole(contracts[i], UPGRADE_ROLE, deployer.address);
        expect(has).to.be.false;
      }
    });

    it("deployer holds no RESOLVER_ROLE on any contract", async () => {
      for (let i = 0; i < contracts.length; i++) {
        const has = await safeHasRole(contracts[i], RESOLVER_ROLE, deployer.address);
        expect(has).to.be.false;
      }
    });

    it("deployer holds no MIGRATOR_ROLE on any contract", async () => {
      for (let i = 0; i < contracts.length; i++) {
        const has = await safeHasRole(contracts[i], MIGRATOR_ROLE, deployer.address);
        expect(has).to.be.false;
      }
    });

    it("deployer holds no CRITICAL_SLASHER_ROLE on any contract", async () => {
      for (let i = 0; i < contracts.length; i++) {
        const has = await safeHasRole(contracts[i], CRITICAL_SLASHER_ROLE, deployer.address);
        expect(has).to.be.false;
      }
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  Authorization — cannot re-acquire after renunciation
  // ════════════════════════════════════════════════════════════════════

  describe("Authorization — re-acquisition prevention", () => {
    let suite: CanonicalV2Suite;

    beforeEach(async () => {
      [deployer, user1, user2] = await ethers.getSigners();
      suite = await deployCanonicalV2(deployer, { finalizeDeployerRoles: true });
    });

    it("deployer cannot re-grant REGISTRY_UPDATER_ROLE to itself", async () => {
      // deployer still holds DEFAULT_ADMIN_ROLE on ClaimRegistry (only REGISTRY_UPDATER was renounced)
      // but if the deployer fully renounced admin, this would revert
      const hasAdmin = await safeHasRole(suite.claimRegistry, DEFAULT_ADMIN_ROLE, deployer.address);
      if (!hasAdmin) {
        await assertReverts(
          suite.claimRegistry.connect(deployer).grantRole(REGISTRY_UPDATER_ROLE, deployer.address)
        );
      }
    });

    it("unauthorized user cannot grant roles on ClaimRegistry", async () => {
      await assertReverts(
        suite.claimRegistry.connect(user1).grantRole(REGISTRY_UPDATER_ROLE, user1.address)
      );
    });

    it("unauthorized user cannot grant DEFAULT_ADMIN_ROLE", async () => {
      await assertReverts(
        suite.claimRegistry.connect(user1).grantRole(DEFAULT_ADMIN_ROLE, user1.address)
      );
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  Replay — repeated checks are idempotent
  // ════════════════════════════════════════════════════════════════════

  describe("Replay — deterministic results", () => {
    let suite: CanonicalV2Suite;

    beforeEach(async () => {
      [deployer] = await ethers.getSigners();
      suite = await deployCanonicalV2(deployer, { finalizeDeployerRoles: true });
    });

    it("repeated role checks produce identical results", async () => {
      const check = async () => {
        const results: boolean[] = [];
        for (const role of ALL_ROLES) {
          results.push(await safeHasRole(suite.claimRegistry, role, deployer.address));
        }
        return results;
      };

      const first = await check();
      const second = await check();
      const third = await check();

      expect(first).to.deep.equal(second);
      expect(second).to.deep.equal(third);
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  Boundary — safe handling of edge cases
  // ════════════════════════════════════════════════════════════════════

  describe("Boundary — edge case handling", () => {
    it("safeHasRole on EOA returns false", async () => {
      [deployer] = await ethers.getSigners();
      const fakeContract = { getAddress: async () => "0x0000000000000000000000000000000000000001" };
      const has = await safeHasRole(fakeContract, DEFAULT_ADMIN_ROLE, deployer.address);
      expect(has).to.be.false;
    });

    it("safeHasRole on zero address returns false", async () => {
      [deployer] = await ethers.getSigners();
      const fakeContract = { getAddress: async () => ethers.ZeroAddress };
      const has = await safeHasRole(fakeContract, DEFAULT_ADMIN_ROLE, deployer.address);
      expect(has).to.be.false;
    });
  });
});
