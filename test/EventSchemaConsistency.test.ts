import { expect } from "chai";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";
import { generateEventSchema } from "../scripts/generate-event-schema";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

describe("Event Schema-to-ABI Consistency", function () {
  let schema: any;
  let artifactAbi: any[];

  before(function () {
    const schemaPath = path.join(__dirname, "../schemas/event-schema-v1.json");
    if (!fs.existsSync(schemaPath)) {
      schema = generateEventSchema();
    } else {
      schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
    }

    const artifactPath = path.join(
      __dirname,
      "../artifacts/contracts/interfaces/ITruthBountyEvents.sol/ITruthBountyEvents.json"
    );
    const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
    artifactAbi = artifact.abi;
  });

  it("contains all 16 specification §20 event families", function () {
    expect(schema.families).to.have.length(16);
    const familyIds = schema.families.map((f: any) => f.id);
    const expectedFamilies = [
      "claims",
      "evidence",
      "staking",
      "verification",
      "rounds",
      "outcomes",
      "disputes",
      "rewards",
      "slashing",
      "withdrawals",
      "treasury",
      "parameters",
      "reputation",
      "roles",
      "emergency",
      "upgrades",
    ];
    for (const exp of expectedFamilies) {
      expect(familyIds).to.include(exp);
    }
  });

  it("every event in ABI is represented in the machine-readable schema", function () {
    const iface = new ethers.Interface(artifactAbi);
    const abiEvents = iface.fragments.filter((f) => f.type === "event") as ethers.EventFragment[];
    expect(schema.events).to.have.length(abiEvents.length);

    for (const eventFrag of abiEvents) {
      const schemaEvent = schema.events.find((e: any) => e.name === eventFrag.name);
      expect(schemaEvent, `Missing event ${eventFrag.name} in schema`).to.not.be.undefined;
      expect(schemaEvent.topic0).to.equal(eventFrag.topicHash);
      expect(schemaEvent.signature).to.equal(eventFrag.format("full"));
      expect(schemaEvent.version).to.equal(1);
    }
  });

  it("enforces EVM indexing rule of at most 3 indexed fields per event", function () {
    for (const event of schema.events) {
      expect(
        event.indexedFieldsCount,
        `Event ${event.name} exceeds max 3 indexed parameters`
      ).to.be.at.most(3);
    }
  });

  it("every event carries standard timestamp (uint64) and version (uint16) trailing fields", function () {
    for (const event of schema.events) {
      const params = event.parameters;
      expect(params.length).to.be.at.least(2);
      const lastParam = params[params.length - 1];
      const secondLastParam = params[params.length - 2];

      expect(lastParam.name).to.equal("version");
      expect(lastParam.type).to.equal("uint16");

      expect(secondLastParam.name).to.equal("timestamp");
      expect(secondLastParam.type).to.equal("uint64");
    }
  });

  it("verifies schema generation is deterministic and checksum is valid", function () {
    const regenerated = generateEventSchema();
    expect(regenerated.checksum).to.equal(schema.checksum);
    expect(regenerated.events.length).to.equal(schema.events.length);
  });
});
