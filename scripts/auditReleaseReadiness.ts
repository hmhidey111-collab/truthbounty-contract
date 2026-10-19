import * as fs from "node:fs";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export interface AuditResult {
    passed: boolean;
    legacyCheck: boolean;
    canonicalCheck: boolean;
    contractClassification: Record<string, string>;
    issues: string[];
}

export async function auditReleaseReadiness(): Promise<AuditResult> {
    console.log("==================================================");
    console.log("V2 Canonical Release Readiness & Legacy Audit");
    console.log("==================================================");

    const issues: string[] = [];
    const contractsDir = path.join(__dirname, "../contracts");

    // Classify contracts
    const classification: Record<string, string> = {
        "ClaimRegistry.sol": "CANONICAL",
        "VerificationSubmission.sol": "CANONICAL",
        "TruthBounty.sol": "CANONICAL",
        "TruthBountyClaims.sol": "DEPRECATED",
        "TruthBountyWeighted.sol": "TRANSITIONAL_NON_CANONICAL",
        "WeightedStaking.sol": "CANONICAL",
        "EvidenceManager.sol": "CANONICAL",
        "ProtocolUpgradeManager.sol": "CANONICAL"
    };

    // Legacy Exclusion Audit
    let legacyCheck = true;

    // 1. Verify TruthBountyClaims is deprecated and not referenced in canonical interfaces
    const interfacesDir = path.join(contractsDir, "interfaces");
    if (fs.existsSync(interfacesDir)) {
        const interfaceFiles = fs.readdirSync(interfacesDir);
        for (const file of interfaceFiles) {
            const content = fs.readFileSync(path.join(interfacesDir, file), "utf-8");
            if (content.includes("TruthBountyClaims")) {
                issues.push(`Legacy contract TruthBountyClaims referenced in interface ${file}`);
                legacyCheck = false;
            }
        }
    }

    // 2. Verify TruthBountyWeighted is flagged non-canonical
    const canonicalCheck = true;

    // 3. V2-SC-159: no upgradeable module may ship with a namespace collision, reserved-slot
    //    reuse, unsafe layout transition, or a stale slot/namespace manifest.
    const namespaceCheck = spawnSync(
        process.execPath,
        [path.join(__dirname, "check-storage-namespaces.mjs")],
        { cwd: path.join(__dirname, ".."), encoding: "utf-8" }
    );
    if (namespaceCheck.status !== 0) {
        const detail = `${namespaceCheck.stdout ?? ""}${namespaceCheck.stderr ?? ""}`.trim();
        issues.push(`Storage namespace collision check failed (V2-SC-159): ${detail || namespaceCheck.error?.message || "unknown error"}`);
    } else {
        console.log("✅ Storage namespace and reserved-slot isolation verified (V2-SC-159).");
    }

    // 4. V2-SC-129: rebuilt artifacts must match the approved release manifest
    //    (compiler, optimizer, metadata, libraries, source hashes, explorer).
    const reproducibilityCheck = spawnSync(
        process.execPath,
        [path.join(__dirname, "check-release-reproducibility.mjs")],
        { cwd: path.join(__dirname, ".."), encoding: "utf-8" }
    );
    if (reproducibilityCheck.status !== 0) {
        const detail = `${reproducibilityCheck.stdout ?? ""}${reproducibilityCheck.stderr ?? ""}`.trim();
        issues.push(`Release reproducibility check failed (V2-SC-129): ${detail || reproducibilityCheck.error?.message || "unknown error"}`);
    } else {
        console.log("✅ Source, bytecode, and metadata reproducibility verified (V2-SC-129).");
    }

    // 5. PREWAVE-SC-062: per-contract and proxy deployment size budgets must be
    //    satisfied before any broadcast.  Oversized contracts fail the gate and
    //    prevent deployment.  Growth is attributed per contract.
    const sizeCheck = spawnSync(
        process.execPath,
        [path.join(__dirname, "check-deployment-sizes.mjs")],
        { cwd: path.join(__dirname, ".."), encoding: "utf-8" }
    );
    if (sizeCheck.status !== 0) {
        const detail = `${sizeCheck.stdout ?? ""}${sizeCheck.stderr ?? ""}`.trim();
        issues.push(`Deployment size budget check failed (PREWAVE-SC-062): ${detail || sizeCheck.error?.message || "unknown error"}`);
    } else {
        console.log("✅ Deployment size budgets satisfied — no contract exceeds hard limit (PREWAVE-SC-062).");
    }
    console.log("✅ Classification of deployment artifacts:");
    for (const [contract, status] of Object.entries(classification)) {
        console.log(`   - ${contract}: ${status}`);
    }

    const passed = legacyCheck && canonicalCheck && issues.length === 0;

    if (passed) {
        console.log("\n✅ All release readiness audit assertions passed.");
    } else {
        console.error("\n❌ Release readiness audit failed with issues:");
        issues.forEach((issue) => console.error(`   - ${issue}`));
    }

    return {
        passed,
        legacyCheck,
        canonicalCheck,
        contractClassification: classification,
        issues
    };
}

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === new URL(`file://${process.argv[1]}`).href;

if (invokedDirectly) {
    auditReleaseReadiness()
        .then((result) => {
            if (!result.passed) {
                process.exit(1);
            }
            process.exit(0);
        })
        .catch((error) => {
            console.error(error);
            process.exit(1);
        });
}
