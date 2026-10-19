#!/usr/bin/env node
/**
 * @file check-dependency-boundaries.mjs
 * @description Enforces strict repository import and dependency boundaries on contracts.
 * 
 * Boundary Rules:
 *  1. No API/frontend imports (ui, components, web, api, client).
 *  2. No generated consumer artifacts (artifacts, typechain, schemas, deployments, *.json).
 *  3. Approved vendor package whitelist (@openzeppelin/contracts, @openzeppelin/contracts-upgradeable).
 *  4. Strict Optimism/EVM isolation (no stellar, soroban, or freighter imports or symbols).
 *  5. Strict directory confinement: relative imports cannot escape the contract directory tree.
 */

import { readdir, readFile, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { resolve, dirname, relative, isAbsolute, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "..");

export const APPROVED_VENDOR_PREFIXES = [
  "@openzeppelin/contracts/",
  "@openzeppelin/contracts-upgradeable/"
];

export const FORBIDDEN_IMPORT_PATTERNS = [
  {
    regex: /(?:^|\/)(?:frontend|api|web|client|ui|components)(?:\/|$)/i,
    rule: "rule-no-frontend-api",
    reason: "Contracts must not import API, web, or frontend dependencies."
  },
  {
    regex: /^(?:@\/|~\/)/,
    rule: "rule-no-frontend-api",
    reason: "Contracts must not use frontend path aliases (@/ or ~/)."
  },
  {
    regex: /(?:^|\/)(?:artifacts|typechain|typechain-types|schemas|deployments)(?:\/|$)/i,
    rule: "rule-no-generated-artifacts",
    reason: "Contracts must not import generated consumer artifacts, schemas, or TypeChain output."
  },
  {
    regex: /\.(?:json|abi)$/i,
    rule: "rule-no-generated-artifacts",
    reason: "Contracts must not import JSON or ABI files directly."
  },
  {
    regex: /(?:stellar|soroban|freighter)/i,
    rule: "rule-no-alternate-chain",
    reason: "TruthBounty contracts are Optimism/EVM-only and must not import Stellar, Soroban, or Freighter dependencies."
  }
];

export const FORBIDDEN_CONTENT_PATTERNS = [
  {
    regex: /(?:stellar|soroban|freighter)/i,
    rule: "rule-no-alternate-chain-runtime",
    reason: "TruthBounty V2 is Optimism/EVM-only; alternate-chain runtime references are forbidden in contract code."
  }
];

/**
 * Strips comments from Solidity source code while preserving exact line positions.
 * @param {string} source
 * @returns {string}
 */
export function stripCommentsPreservingLines(source) {
  // Replace block comments /* ... */ with equivalent whitespace/newlines
  let cleaned = source.replace(/\/\*[\s\S]*?\*\//g, (match) => {
    return match.replace(/[^\r\n]/g, " ");
  });
  // Replace line comments // ... with whitespace
  cleaned = cleaned.replace(/\/\/[^\r\n]*/g, (match) => {
    return " ".repeat(match.length);
  });
  return cleaned;
}

/**
 * Extracts all import paths and their 1-based line numbers from Solidity source.
 * @param {string} source
 * @returns {Array<{ importPath: string, lineNumber: number }>}
 */
export function extractImports(source) {
  const cleaned = stripCommentsPreservingLines(source);
  // Matches all variations of Solidity imports including:
  // 1. import "path";
  // 2. import "path" as Alias;
  // 3. import * as Alias from "path";
  // 4. import { A, B as C } from "path";
  // 5. import Symbol from "path";
  const importRegex =
    /import\s+(?:(?:\*(?:\s+as\s+[a-zA-Z_$][\w$]*)?|\{[^}]*\}|[a-zA-Z_$][\w$,\s]*)\s+from\s+["']([^"']+)["']|["']([^"']+)["'](?:\s+as\s+[a-zA-Z_$][\w$]*)?)\s*;/gs;
  const results = [];
  let match;
  while ((match = importRegex.exec(cleaned)) !== null) {
    const importPath = match[1] || match[2];
    const textBefore = source.slice(0, match.index);
    const lineNumber = textBefore.split(/\r\n|\r|\n/).length;
    results.push({ importPath, lineNumber });
  }
  return results;
}

/**
 * Recursively retrieves all .sol files in the target directories.
 * @param {string} dir
 * @returns {Promise<string[]>}
 */
async function findSolidityFiles(dir) {
  const results = [];
  if (!existsSync(dir)) return results;

  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = resolve(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...(await findSolidityFiles(fullPath)));
    } else if (entry.isFile() && entry.name.endsWith(".sol")) {
      results.push(fullPath);
    }
  }
  return results;
}

/**
 * Checks a single contract file against dependency boundary rules.
 * @param {string} filePath
 * @param {string} content
 * @param {string[]} allowedRoots
 * @returns {Array<{ file: string, line: number, importPath?: string, rule: string, reason: string }>}
 */
export function checkFileBoundaries(filePath, content, allowedRoots) {
  const violations = [];
  const normalizedFile = normalize(filePath);
  const imports = extractImports(content);

  for (const { importPath, lineNumber } of imports) {
    // 1. Check forbidden import patterns
    for (const { regex, rule, reason } of FORBIDDEN_IMPORT_PATTERNS) {
      if (regex.test(importPath)) {
        violations.push({
          file: normalizedFile,
          line: lineNumber,
          importPath,
          rule,
          reason
        });
      }
    }

    // 2. Relative import checks (boundary confinement & existence)
    if (importPath.startsWith("./") || importPath.startsWith("../")) {
      const fileDir = dirname(normalizedFile);
      const resolvedTarget = resolve(fileDir, importPath);

      // Verify the resolved path stays within at least one allowed contract root
      const isConfined = allowedRoots.some((root) => {
        const normRoot = normalize(root);
        const rel = relative(normRoot, resolvedTarget);
        return !rel.startsWith("..") && !isAbsolute(rel);
      });

      if (!isConfined) {
        violations.push({
          file: normalizedFile,
          line: lineNumber,
          importPath,
          rule: "rule-path-traversal-boundary",
          reason: `Relative import escapes allowed contract roots (${importPath} -> ${resolvedTarget}).`
        });
      } else if (!existsSync(resolvedTarget) && !existsSync(`${resolvedTarget}.sol`)) {
        violations.push({
          file: normalizedFile,
          line: lineNumber,
          importPath,
          rule: "rule-unresolved-import",
          reason: `Relative import targets a non-existent file: ${importPath}`
        });
      }
    } else {
      // 3. External package imports must be in the approved vendor whitelist
      const isApprovedVendor = APPROVED_VENDOR_PREFIXES.some((prefix) =>
        importPath.startsWith(prefix)
      );

      if (!isApprovedVendor) {
        violations.push({
          file: normalizedFile,
          line: lineNumber,
          importPath,
          rule: "rule-unapproved-vendor-boundary",
          reason: `External import "${importPath}" is not in the approved vendor whitelist (${APPROVED_VENDOR_PREFIXES.join(", ")}).`
        });
      }
    }
  }

  // 4. Check for forbidden alternate-chain runtime references in code body
  const cleanedBody = stripCommentsPreservingLines(content);
  const lines = cleanedBody.split(/\r\n|\r|\n/);
  for (let idx = 0; idx < lines.length; idx++) {
    const lineText = lines[idx];
    for (const { regex, rule, reason } of FORBIDDEN_CONTENT_PATTERNS) {
      if (regex.test(lineText)) {
        violations.push({
          file: normalizedFile,
          line: idx + 1,
          rule,
          reason: `${reason} Found: "${lineText.trim()}"`
        });
      }
    }
  }

  return violations;
}

/**
 * Runs the boundary check across specified contract directories.
 * @param {object} options
 * @param {string} [options.rootDir]
 * @param {string[]} [options.contractDirs]
 * @returns {Promise<{ passed: boolean, filesChecked: number, violations: Array<object> }>}
 */
export async function checkRepositoryBoundaries({
  rootDir = REPO_ROOT,
  contractDirs = ["contracts", "contracts-vrm"]
} = {}) {
  const allowedRoots = contractDirs.map((dir) => resolve(rootDir, dir));
  const allFiles = [];

  for (const root of allowedRoots) {
    if (!existsSync(root)) {
      throw new Error(`Configured contract root does not exist: ${root}`);
    }
    const files = await findSolidityFiles(root);
    allFiles.push(...files);
  }

  const allViolations = [];
  for (const file of allFiles) {
    const content = await readFile(file, "utf8");
    const fileViolations = checkFileBoundaries(file, content, allowedRoots);
    allViolations.push(...fileViolations);
  }

  return {
    passed: allViolations.length === 0,
    filesChecked: allFiles.length,
    violations: allViolations
  };
}

// CLI entry point
if (process.argv[1] && resolve(process.argv[1]) === resolve(__filename)) {
  console.log("==> Running Repository Import and Dependency Boundary Checks...");
  checkRepositoryBoundaries()
    .then(({ passed, filesChecked, violations }) => {
      console.log(`==> Scanned ${filesChecked} Solidity contract files.`);
      if (passed) {
        console.log("✓ All contract import and dependency boundaries verified cleanly (0 violations).");
        process.exit(0);
      } else {
        console.error(`\n❌ Found ${violations.length} boundary violation(s):`);
        for (const v of violations) {
          const relPath = relative(REPO_ROOT, v.file);
          console.error(
            `  - [${v.rule}] ${relPath}:${v.line} -> ${v.reason}${v.importPath ? ` (${v.importPath})` : ""}`
          );
        }
        process.exit(1);
      }
    })
    .catch((err) => {
      console.error("Fatal error during boundary check:", err);
      process.exit(1);
    });
}
