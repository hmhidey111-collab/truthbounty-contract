import { expect } from "chai";
import { artifacts } from "hardhat";
import { Interface } from "ethers";

describe("Legacy V1 surface isolation from canonical V2 artifacts", function () {
  it("excludes deprecated treasury methods, roles, and events", async function () {
    const legacy = await artifacts.readArtifact("contracts/TruthBountyClaims.sol:TruthBountyClaims");
    const canonical = await artifacts.readArtifact("ICanonicalV2");
    const vault = await artifacts.readArtifact("contracts/v2/StakeVault.sol:StakeVault");
    const legacyInterface = new Interface(legacy.abi);

    expect(vault.sourceName).to.equal("contracts/v2/StakeVault.sol");
    for (const artifact of [canonical, vault]) {
      const v2Interface = new Interface(artifact.abi);
      for (const name of ["settleClaim", "settleClaimsBatch", "rescueTokens", "TREASURY_ROLE"]) {
        const legacyFunction = legacyInterface.getFunction(name);
        expect(legacyFunction, `${name} must exist on the legacy artifact`).not.to.be.null;
        expect(
          v2Interface.fragments.some((fragment: any) =>
            fragment.type === "function" && fragment.selector === legacyFunction!.selector
          ),
          `${artifact.contractName} must not expose the legacy ${name} selector`
        ).to.be.false;
      }
      for (const name of ["ClaimSettled", "BatchSettlementCompleted"]) {
        const legacyEvent = legacyInterface.getEvent(name);
        expect(legacyEvent, `${name} must exist on the legacy artifact`).not.to.be.null;
        expect(
          v2Interface.fragments.some((fragment: any) =>
            fragment.type === "event" && fragment.topicHash === legacyEvent!.topicHash
          ),
          `${artifact.contractName} must not emit the legacy ${name} event`
        ).to.be.false;
      }
    }
  });
});
