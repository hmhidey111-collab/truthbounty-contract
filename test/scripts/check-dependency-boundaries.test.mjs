/**
 * @file check-dependency-boundaries.test.mjs
 * @description Comprehensive unit tests for repository import and dependency boundary enforcement.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  stripCommentsPreservingLines,
  extractImports,
  checkFileBoundaries,
  checkRepositoryBoundaries,
  APPROVED_VENDOR_PREFIXES
} from "../../scripts/check-dependency-boundaries.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "../..");
const CONTRACTS_ROOT = resolve(REPO_ROOT, "contracts");

describe("Dependency & Import Boundary Enforcement", () => {
  describe("stripCommentsPreservingLines", () => {
    it("strips single-line comments while preserving newlines and line numbers", () => {
      const source = `// comment line 1\ncontract Foo {\n  // comment line 3\n  uint256 x;\n}`;
      const cleaned = stripCommentsPreservingLines(source);
      assert.ok(!cleaned.includes("// comment line 1"));
      assert.ok(!cleaned.includes("// comment line 3"));
      assert.ok(cleaned.includes("contract Foo {"));
      assert.ok(cleaned.includes("uint256 x;"));
      assert.equal(source.split("\n").length, cleaned.split("\n").length);
    });

    it("strips multi-line block comments while preserving line count", () => {
      const source = `/*\n * Multi-line\n * comment\n */\ncontract Bar {}`;
      const cleaned = stripCommentsPreservingLines(source);
      assert.ok(!cleaned.includes("Multi-line"));
      assert.ok(cleaned.includes("contract Bar {}"));
      assert.equal(source.split("\n").length, cleaned.split("\n").length);
    });
  });

  describe("extractImports", () => {
    it("extracts simple quoted imports and correct line numbers", () => {
      const source = `// Header\nimport "./interfaces/IClaimRegistry.sol";\n\nimport "@openzeppelin/contracts/access/AccessControl.sol";`;
      const imports = extractImports(source);
      assert.equal(imports.length, 2);
      assert.equal(imports[0].importPath, "./interfaces/IClaimRegistry.sol");
      assert.equal(imports[0].lineNumber, 2);
      assert.equal(imports[1].importPath, "@openzeppelin/contracts/access/AccessControl.sol");
      assert.equal(imports[1].lineNumber, 4);
    });

    it("extracts named multiline imports", () => {
      const source = `import {\n  AccessControl,\n  IAccessControl\n} from "@openzeppelin/contracts/access/AccessControl.sol";`;
      const imports = extractImports(source);
      assert.equal(imports.length, 1);
      assert.equal(imports[0].importPath, "@openzeppelin/contracts/access/AccessControl.sol");
      assert.equal(imports[0].lineNumber, 1);
    });

    it("extracts star-alias and direct alias imports", () => {
      const source = `import * as Core from "./ClaimRegistry.sol";\nimport "./ClaimRegistry.sol" as Registry;\nimport * as OZ from "@openzeppelin/contracts/access/AccessControl.sol";`;
      const imports = extractImports(source);
      assert.equal(imports.length, 3);
      assert.equal(imports[0].importPath, "./ClaimRegistry.sol");
      assert.equal(imports[0].lineNumber, 1);
      assert.equal(imports[1].importPath, "./ClaimRegistry.sol");
      assert.equal(imports[1].lineNumber, 2);
      assert.equal(imports[2].importPath, "@openzeppelin/contracts/access/AccessControl.sol");
      assert.equal(imports[2].lineNumber, 3);
    });

    it("ignores imports located inside comments", () => {
      const source = `// import "frontend/App.sol";\n/*\nimport "@stellar/freighter";\n*/\nimport "./Valid.sol";`;
      const imports = extractImports(source);
      assert.equal(imports.length, 1);
      assert.equal(imports[0].importPath, "./Valid.sol");
      assert.equal(imports[0].lineNumber, 5);
    });
  });

  describe("checkFileBoundaries", () => {
    const dummyContractPath = resolve(CONTRACTS_ROOT, "Dummy.sol");
    const allowedRoots = [CONTRACTS_ROOT];

    it("accepts valid OpenZeppelin and internal contract imports", () => {
      const validCode = `// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n\nimport "@openzeppelin/contracts/access/AccessControl.sol";\nimport "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";\nimport "./ClaimRegistry.sol";\n\ncontract Dummy {}`;
      const violations = checkFileBoundaries(dummyContractPath, validCode, allowedRoots);
      assert.equal(violations.length, 0);
    });

    it("rejects imports referencing frontend, UI, or API paths", () => {
      const invalidCode = `import "../frontend/components/Wallet.sol";\nimport "api/routes/auth.sol";\nimport "@/ui/Button.sol";`;
      const violations = checkFileBoundaries(dummyContractPath, invalidCode, allowedRoots);
      const rules = violations.map((v) => v.rule);
      assert.ok(rules.includes("rule-no-frontend-api"));
      assert.ok(violations.some((v) => v.importPath === "../frontend/components/Wallet.sol"));
      assert.ok(violations.some((v) => v.importPath === "@/ui/Button.sol"));
    });

    it("rejects imports of generated consumer artifacts, schemas, or JSON files", () => {
      const invalidCode = `import "./artifacts/TruthBounty.json";\nimport "typechain-types/index.sol";\nimport "./schemas/event-schema-v1.json";`;
      const violations = checkFileBoundaries(dummyContractPath, invalidCode, allowedRoots);
      const rules = violations.map((v) => v.rule);
      assert.ok(rules.includes("rule-no-generated-artifacts"));
      assert.ok(violations.some((v) => v.importPath === "./artifacts/TruthBounty.json"));
      assert.ok(violations.some((v) => v.importPath === "typechain-types/index.sol"));
    });

    it("rejects unapproved external vendor packages", () => {
      const invalidCode = `import "@solady/utils/LibString.sol";\nimport "unapproved-package/Security.sol";`;
      const violations = checkFileBoundaries(dummyContractPath, invalidCode, allowedRoots);
      const rules = violations.map((v) => v.rule);
      assert.ok(rules.includes("rule-unapproved-vendor-boundary"));
      assert.equal(violations.filter((v) => v.rule === "rule-unapproved-vendor-boundary").length, 2);
    });

    it("rejects alternate-chain imports (Stellar, Soroban, Freighter)", () => {
      const invalidCode = `import "@stellar/freighter-api/index.sol";\nimport "soroban-contracts/SorobanToken.sol";`;
      const violations = checkFileBoundaries(dummyContractPath, invalidCode, allowedRoots);
      const rules = violations.map((v) => v.rule);
      assert.ok(rules.includes("rule-no-alternate-chain"));
    });

    it("rejects alternate-chain runtime references in contract body", () => {
      const invalidCode = `contract Dummy {\n  function callSoroban() external {}\n  address stellarGateway;\n}`;
      const violations = checkFileBoundaries(dummyContractPath, invalidCode, allowedRoots);
      const rules = violations.map((v) => v.rule);
      assert.ok(rules.includes("rule-no-alternate-chain-runtime"));
      assert.equal(violations.filter((v) => v.rule === "rule-no-alternate-chain-runtime").length, 2);
    });

    it("rejects relative imports that escape the allowed contract roots (path traversal)", () => {
      const invalidCode = `import "../../indexer/EventConsumer.sol";\nimport "../../../outside/Secrets.sol";`;
      const violations = checkFileBoundaries(dummyContractPath, invalidCode, allowedRoots);
      const rules = violations.map((v) => v.rule);
      assert.ok(rules.includes("rule-path-traversal-boundary"));
    });

    it("rejects relative imports pointing to non-existent files inside contract root", () => {
      const invalidCode = `import "./NonExistentContractXYZ123.sol";`;
      const violations = checkFileBoundaries(dummyContractPath, invalidCode, allowedRoots);
      const rules = violations.map((v) => v.rule);
      assert.ok(rules.includes("rule-unresolved-import"));
    });

    it("rejects alias imports that target forbidden paths", () => {
      const invalidCode = `import * as BadFrontend from "../frontend/App.sol";\nimport "unapproved-pkg/Lib.sol" as BadLib;\nimport * as Alternate from "@stellar/freighter";`;
      const violations = checkFileBoundaries(dummyContractPath, invalidCode, allowedRoots);
      const rules = violations.map((v) => v.rule);
      assert.ok(rules.includes("rule-no-frontend-api"));
      assert.ok(rules.includes("rule-unapproved-vendor-boundary"));
      assert.ok(rules.includes("rule-no-alternate-chain"));
    });
  });

  describe("checkRepositoryBoundaries (Live Repo Verification)", () => {
    it("passes cleanly on the current live codebase with 0 violations", async () => {
      const result = await checkRepositoryBoundaries({
        rootDir: REPO_ROOT,
        contractDirs: ["contracts", "contracts-vrm"]
      });
      assert.equal(result.passed, true);
      assert.equal(result.violations.length, 0);
      assert.ok(result.filesChecked > 0, "Should have scanned production contracts");
    });

    it("fails when a configured contract root is missing", async () => {
      await assert.rejects(
        () =>
          checkRepositoryBoundaries({
            rootDir: REPO_ROOT,
            contractDirs: ["contracts", "non-existent-contract-dir-xyz"]
          }),
        /Configured contract root does not exist/
      );
    });
  });
});
