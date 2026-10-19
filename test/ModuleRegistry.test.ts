import { expect } from "chai";
import { network } from "hardhat";
import type { Contract } from "ethers";

// V2-SC-005: canonical module registry — test evidence in the approved Hardhat (v3) style.
// PB-P0 / Test-2.2, Test-2.3, Test-2.4 (v2.a/b/c/d), Test-2.5.

describe("V2-SC-005 ModuleRegistry", function () {
  let ethers: any;
  let registry: Contract;
  let admin: any, governance: any, guardian: any, random: any;

  const REPLACEMENT_DELAY = 2 * 24 * 60 * 60; // 2 days

  const MODULE_CLAIMS = () => ethers.id("CLAIMS");
  const MODULE_EVIDENCE = () => ethers.id("EVIDENCE");

  before(async function () {
    ({ ethers } = await network.create());
  });

  beforeEach(async function () {
    [admin, governance, guardian, random] = await ethers.getSigners();
    registry = await ethers.deployContract("contracts/v2/ModuleRegistry.sol:ModuleRegistry", [
      await admin.getAddress(),
      await governance.getAddress(),
      await guardian.getAddress(),
    ]);
  });

  async function deployModule(moduleId: string, major = 2, minor = 0) {
    const interfaceId = await registry.canonicalInterfaceOf(moduleId);
    return ethers.deployContract("contracts/mocks/MockV2Module.sol:MockV2Module", [major, minor, interfaceId]);
  }

  async function canonicalReg(moduleId: string, proxy: string, major = 2, minor = 0) {
    const interfaceId = await registry.canonicalInterfaceOf(moduleId);
    return {
      moduleId,
      interfaceId,
      proxy,
      implementation: ethers.ZeroAddress,
      major,
      minor,
    };
  }

  function stripPad(b32: string) {
    return ethers.toUtf8String(b32).replace(/\u0000+$/, "");
  }

  describe("registration and activation", function () {
    it("registers in REGISTERED state with a deterministic version id", async function () {
      const module = await deployModule(MODULE_CLAIMS());
      const reg = await canonicalReg(MODULE_CLAIMS(), await module.getAddress());

      const expectedVersion = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["bytes32", "bytes4", "address", "address", "uint16", "uint16"],
          [MODULE_CLAIMS(), reg.interfaceId, await module.getAddress(), ethers.ZeroAddress, 2, 0]
        )
      );

      const tx = await registry.registerModule(reg);
      await expect(tx)
        .to.emit(registry, "ModuleRegistered")
        .withArgs(MODULE_CLAIMS(), expectedVersion, await module.getAddress(), ethers.ZeroAddress, 2, 0, reg.interfaceId);

      expect(await registry.moduleCount()).to.equal(1);
      expect(await registry.moduleStatus(MODULE_CLAIMS())).to.equal(1); // REGISTERED
      expect(await registry.isRegistered(MODULE_CLAIMS())).to.equal(false);
      const info = await registry.getModule(MODULE_CLAIMS());
      expect(info.versionId).to.equal(expectedVersion);
    });

    it("activates a module and exposes it through the StakeVault-compatible getters", async function () {
      const module = await deployModule(MODULE_CLAIMS());
      const reg = await canonicalReg(MODULE_CLAIMS(), await module.getAddress());
      await registry.registerModule(reg);

      await expect(registry.activateModule(MODULE_CLAIMS())).to.emit(registry, "ModuleActivated");

      expect(await registry.isRegistered(MODULE_CLAIMS())).to.equal(true);
      expect(await registry.isActive(MODULE_CLAIMS())).to.equal(true);

      const [implementation, major, minor] = await registry.module(MODULE_CLAIMS());
      expect(implementation).to.equal(await module.getAddress());
      expect(major).to.equal(2);
      expect(minor).to.equal(0);
    });

    it("reverts registration and activation for a non-deployment caller", async function () {
      const module = await deployModule(MODULE_CLAIMS());
      const reg = await canonicalReg(MODULE_CLAIMS(), await module.getAddress());

      const DEPLOYMENT_ROLE = await registry.DEPLOYMENT_ROLE();
      await expect(registry.connect(random).registerModule(reg))
        .to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount")
        .withArgs(await random.getAddress(), DEPLOYMENT_ROLE);

      await registry.registerModule(reg);
      await expect(registry.connect(random).activateModule(MODULE_CLAIMS()))
        .to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount")
        .withArgs(await random.getAddress(), DEPLOYMENT_ROLE);
    });
  });

  describe("validation and unsafe-input rejection", function () {
    it("rejects EOA proxies, zero proxies, self-registration and unknown keys", async function () {
      const eoaReg = await canonicalReg(MODULE_EVIDENCE(), random.address);
      await expect(registry.registerModule(eoaReg))
        .to.be.revertedWithCustomError(registry, "ModuleNotAContract")
        .withArgs(random.address);

      const zeroReg = await canonicalReg(MODULE_EVIDENCE(), ethers.ZeroAddress);
      await expect(registry.registerModule(zeroReg))
        .to.be.revertedWithCustomError(registry, "ModuleNotAContract")
        .withArgs(ethers.ZeroAddress);

      const selfReg = await canonicalReg(MODULE_EVIDENCE(), await registry.getAddress());
      await expect(registry.registerModule(selfReg)).to.be.revertedWithCustomError(registry, "SelfRegistration");

      const unknownReg = await canonicalReg(ethers.id("NOPE"), random.address);
      await expect(registry.registerModule(unknownReg))
        .to.be.revertedWithCustomError(registry, "UnknownModuleId")
        .withArgs(ethers.id("NOPE"));
    });

    it("rejects a proxy that does not implement the claimed canonical interface", async function () {
      const module = await deployModule(MODULE_CLAIMS()); // supports CLAIMS, but we claim EVIDENCE
      const badReg = await canonicalReg(MODULE_EVIDENCE(), await module.getAddress());
      await expect(registry.registerModule(badReg))
        .to.be.revertedWithCustomError(registry, "ModuleInterfaceMismatch")
        .withArgs(await registry.canonicalInterfaceOf(MODULE_EVIDENCE()), "0x00000000");
    });

    it("rejects version mismatches (release major and declared version)", async function () {
      const oldModule = await deployModule(MODULE_CLAIMS(), 1, 0); // reports major 1
      const majorReg = { ...(await canonicalReg(MODULE_CLAIMS(), await oldModule.getAddress())), major: 1 };
      await expect(registry.registerModule(majorReg))
        .to.be.revertedWithCustomError(registry, "ModuleVersionMismatch")
        .withArgs(1, 2);

      const module = await deployModule(MODULE_CLAIMS(), 2, 0);
      const declaredReg = { ...(await canonicalReg(MODULE_CLAIMS(), await module.getAddress())), minor: 5 };
      await expect(registry.registerModule(declaredReg))
        .to.be.revertedWithCustomError(registry, "DeclaredVersionMismatch")
        .withArgs(2, 5, 2, 0);
    });

    it("rejects duplicate proxies bound to another module key", async function () {
      const module = await deployModule(MODULE_CLAIMS());
      await registry.registerModule(await canonicalReg(MODULE_CLAIMS(), await module.getAddress()));
      const reg = await canonicalReg(MODULE_EVIDENCE(), await module.getAddress());
      await expect(registry.registerModule(reg))
        .to.be.revertedWithCustomError(registry, "DuplicateProxy")
        .withArgs(await module.getAddress());
    });

    it("forbids and un-forbids legacy addresses (Test-2.4 legacy regression)", async function () {
      const module = await deployModule(MODULE_EVIDENCE());
      const addr = await module.getAddress();

      await expect(registry.connect(governance).forbidModule(addr)).to.emit(registry, "ModuleForbidden");
      expect(await registry.isForbidden(addr)).to.equal(true);

      await expect(registry.registerModule(await canonicalReg(MODULE_EVIDENCE(), addr)))
        .to.be.revertedWithCustomError(registry, "ForbiddenModule")
        .withArgs(addr);

      await expect(registry.connect(governance).unforbidModule(addr)).to.emit(registry, "ModuleUnforbidden");
      await registry.registerModule(await canonicalReg(MODULE_EVIDENCE(), addr));
      expect(await registry.moduleCount()).to.equal(1);
    });
  });

  describe("governance redress", function () {
    it("allows GOVERNANCE_ROLE-only deprecation that permanently blocks re-activation", async function () {
      const module = await deployModule(MODULE_CLAIMS());
      await registry.registerModule(await canonicalReg(MODULE_CLAIMS(), await module.getAddress()));
      await registry.activateModule(MODULE_CLAIMS());

      const GOVERNANCE_ROLE = await registry.GOVERNANCE_ROLE();
      await expect(registry.connect(random).deprecateModule(MODULE_CLAIMS()))
        .to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount")
        .withArgs(await random.getAddress(), GOVERNANCE_ROLE);
      await expect(registry.connect(governance).deprecateModule(MODULE_CLAIMS())).to.emit(
        registry,
        "ModuleDeprecated"
      );

      expect(await registry.isDeprecated(MODULE_CLAIMS())).to.equal(true);
      expect(await registry.isRegistered(MODULE_CLAIMS())).to.equal(false);
      await expect(registry.activateModule(MODULE_CLAIMS()))
        .to.be.revertedWithCustomError(registry, "DeprecatedModule")
        .withArgs(MODULE_CLAIMS());
    });

    it("rejects every registry mutation attempted by the guardian role (Test-2.2/e)", async function () {
      await registry.grantRole(await registry.DEPLOYMENT_ROLE(), await guardian.getAddress());
      await registry.grantRole(await registry.GOVERNANCE_ROLE(), await guardian.getAddress());

      const module = await deployModule(MODULE_EVIDENCE());
      const reg = await canonicalReg(MODULE_EVIDENCE(), await module.getAddress());
      await expect(registry.connect(guardian).registerModule(reg))
        .to.be.revertedWithCustomError(registry, "GuardianCannotReplaceModule")
        .withArgs(await guardian.getAddress());

      await expect(registry.connect(guardian).forbidModule(random.address))
        .to.be.revertedWithCustomError(registry, "GuardianCannotReplaceModule")
        .withArgs(await guardian.getAddress());
    });

    it("executes a timelocked governance replacement and updates the module version", async function () {
      const v1 = await deployModule(MODULE_CLAIMS(), 2, 0);
      const v1Reg = await canonicalReg(MODULE_CLAIMS(), await v1.getAddress());
      await registry.registerModule(v1Reg);
      await registry.activateModule(MODULE_CLAIMS());
      const oldVersion = await registry.versionIdOf(v1Reg);

      const v2 = await deployModule(MODULE_CLAIMS(), 2, 1);
      const v2Reg = await canonicalReg(MODULE_CLAIMS(), await v2.getAddress(), 2, 1);
      const newVersion = await registry.versionIdOf(v2Reg);
      expect(newVersion).not.to.equal(oldVersion);

      const GOVERNANCE_ROLE = await registry.GOVERNANCE_ROLE();
      await expect(registry.connect(random).proposeModuleReplacement(v2Reg))
        .to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount")
        .withArgs(await random.getAddress(), GOVERNANCE_ROLE);

      await expect(registry.connect(governance).proposeModuleReplacement(v2Reg)).to.emit(
        registry,
        "ModuleReplacementProposed"
      );

      const readyAt = await registry.replacementReadyAt(MODULE_CLAIMS());
      expect(readyAt).to.equal((await ethers.provider.getBlock("latest")).timestamp + REPLACEMENT_DELAY);

      await expect(registry.activateModuleReplacement(MODULE_CLAIMS()))
        .to.be.revertedWithCustomError(registry, "ReplacementNotReady")
        .withArgs(MODULE_CLAIMS(), readyAt);

      await ethers.provider.send("evm_increaseTime", [REPLACEMENT_DELAY + 60]);
      await ethers.provider.send("evm_mine", []);

      await expect(registry.connect(random).activateModuleReplacement(MODULE_CLAIMS())).to.emit(
        registry,
        "ModuleReplacementActivated"
      );

      const [implementation, , minor] = await registry.module(MODULE_CLAIMS());
      expect(implementation).to.equal(await v2.getAddress());
      expect(minor).to.equal(1);
      expect(await registry.replacementReadyAt(MODULE_CLAIMS())).to.equal(0);
      expect(await registry.isRegistered(MODULE_CLAIMS())).to.equal(true);
    });

    it("cancels a pending replacement and rejects no-op replacements", async function () {
      const v1 = await deployModule(MODULE_CLAIMS(), 2, 0);
      await registry.registerModule(await canonicalReg(MODULE_CLAIMS(), await v1.getAddress()));
      await registry.activateModule(MODULE_CLAIMS());

      const identical = await canonicalReg(MODULE_CLAIMS(), await v1.getAddress());
      await expect(registry.connect(governance).proposeModuleReplacement(identical))
        .to.be.revertedWithCustomError(registry, "ReplacementNoop")
        .withArgs(MODULE_CLAIMS());

      const v2 = await deployModule(MODULE_CLAIMS(), 2, 1);
      await registry
        .connect(governance)
        .proposeModuleReplacement(await canonicalReg(MODULE_CLAIMS(), await v2.getAddress(), 2, 1));
      expect(await registry.replacementReadyAt(MODULE_CLAIMS())).to.be.gt(0);

      await expect(registry.connect(governance).cancelModuleReplacement(MODULE_CLAIMS())).to.emit(
        registry,
        "ModuleReplacementCancelled"
      );
      expect(await registry.replacementReadyAt(MODULE_CLAIMS())).to.equal(0);
      await expect(registry.activateModuleReplacement(MODULE_CLAIMS()))
        .to.be.revertedWithCustomError(registry, "ReplacementNotPending")
        .withArgs(MODULE_CLAIMS());
    });
  });

  describe("canonical manifest and preflight views", function () {
    it("exposes 14 stable canonical keys with non-zero interface ids and the dependency edgeset", async function () {
      const ids = Array.from(await registry.canonicalModuleIds());
      expect(ids.length).to.equal(14);
      for (const id of ids) {
        expect(await registry.canonicalInterfaceOf(id)).not.to.equal("0x00000000");
      }
      const edges = await registry.canonicalDependencies();
      expect(edges.length).to.equal(11);
    });

    it("preflights a registration and exposes failure codes without reverting", async function () {
      const module = await deployModule(MODULE_CLAIMS());
      const reg = await canonicalReg(MODULE_CLAIMS(), await module.getAddress());

      const ok = await registry.preflightRegistration(reg);
      expect(ok.ok).to.equal(true);
      expect(ok.canonicalInterfaceId).to.equal(reg.interfaceId);

      const bad = await registry.preflightRegistration({ ...reg, proxy: random.address });
      expect(bad.ok).to.equal(false);
      expect(stripPad(bad.errorCode)).to.equal("NOT_A_CONTRACT");
    });

    it("reports an incomplete canonical suite before bootstrap and validates it afterwards", async function () {
      const incomplete = await registry.validateCanonicalSuite();
      expect(incomplete.ok).to.equal(false);
      expect(stripPad(incomplete.errorCode)).to.equal("INCOMPLETE_SUITE");

      const ids: string[] = Array.from(await registry.canonicalModuleIds()) as string[];
      for (const id of ids) {
        const m = await deployModule(id, 2, 0);
        await registry.registerModule(await canonicalReg(id, await m.getAddress()));
      }
      await registry.activateModules(ids);

      const complete = await registry.validateCanonicalSuite();
      expect(complete.ok).to.equal(true);
      for (const id of ids) {
        expect(await registry.isRegistered(id)).to.equal(true);
      }
    });
  });
});