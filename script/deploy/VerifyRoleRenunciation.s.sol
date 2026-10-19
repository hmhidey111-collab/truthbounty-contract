// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PostDeploymentRoleCheck} from "../../contracts/deployment/PostDeploymentRoleCheck.sol";

/**
 * @title VerifyRoleRenunciation
 * @notice Forge script for live post-deployment role renunciation verification (V2-SC-127).
 * @dev Run against a live deployment to verify the deployer holds zero roles:
 *
 *      forge script script/deploy/VerifyRoleRenunciation.s.sol \
 *        --rpc-url $RPC_URL \
 *        --sig "run(address,address[])" \
 *        $DEPLOYER_ADDRESS \
 *        "[$CONTRACT_1,$CONTRACT_2,...]"
 *
 *      Or load addresses from a manifest:
 *
 *      forge script script/deploy/VerifyRoleRenunciation.s.sol \
 *        --rpc-url $RPC_URL \
 *        --sig "runFromManifest(string)" \
 *        "deployments/mainnet/manifest.json"
 */
contract VerifyRoleRenunciation is Script {
    using PostDeploymentRoleCheck for *;

    // ── Events mirrored for readability ──────────────────────────────────
    event CheckResult(
        address indexed deployer,
        uint256 contractsChecked,
        uint256 violations
    );

    /**
     * @notice Check a deployer address against an explicit list of contract addresses.
     * @param deployer  The deployer/script EOA to verify holds no roles.
     * @param targets   Array of deployed AccessControl contract addresses.
     */
    function run(address deployer, address[] calldata targets) external view {
        require(deployer != address(0), "zero deployer address");
        require(targets.length > 0, "empty target list");

        console2.log("=== Post-Deployment Role Renunciation Check (V2-SC-127) ===");
        console2.log("Deployer:", deployer);
        console2.log("Contracts to check:", targets.length);

        bytes32[] memory roles = PostDeploymentRoleCheck.roleCatalog();
        console2.log("Roles in catalog:", roles.length);

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, targets);

        if (violations.length == 0) {
            console2.log("PASSED: deployer retains 0 roles across all contracts");
        } else {
            console2.log("FAILED: deployer retains roles on %d (target, role) pairs", violations.length);
            for (uint256 i; i < violations.length; ++i) {
                console2.log("  VIOLATION: target=%s role=%s",
                    vm.toString(violations[i].target),
                    vm.toString(violations[i].role)
                );
            }
            revert("deployer retains unauthorized roles");
        }
    }

    /**
     * @notice Load deployment addresses from a JSON manifest and check the deployer.
     * @param manifestPath Relative path to the deployment manifest JSON.
     */
    function runFromManifest(string calldata manifestPath) external view {
        string memory json = vm.readFile(manifestPath);

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        require(deployer != address(0), "DEPLOYER_ADDRESS env not set");

        console2.log("=== Post-Deployment Role Renunciation Check (V2-SC-127) ===");
        console2.log("Deployer:", deployer);
        console2.log("Manifest:", manifestPath);

        // Parse known contract keys from the manifest
        string[] memory keys = new string[](12);
        keys[0] = ".contracts.MigrationManager";
        keys[1] = ".contracts.TruthBountyToken";
        keys[2] = ".contracts.ReputationOracle";
        keys[3] = ".contracts.TruthBountyWeighted";
        keys[4] = ".contracts.Staking";
        keys[5] = ".contracts.VerifierSlashing";
        keys[6] = ".contracts.TruthBountyClaims";
        keys[7] = ".contracts.TruthBountyGovernanceToken";
        keys[8] = ".contracts.TimelockController";
        keys[9] = ".contracts.TruthBountyGovernor";
        keys[10] = ".contracts.GovernedModuleRegistry";
        keys[11] = ".contracts.GovernanceGuardian";

        // Collect non-zero addresses
        address[] memory buffer = new address[](keys.length);
        uint256 count;
        for (uint256 i; i < keys.length; ++i) {
            bytes memory raw = vm.parseJson(json, keys[i]);
            if (raw.length >= 32) {
                address addr = abi.decode(raw, (address));
                if (addr != address(0)) {
                    buffer[count++] = addr;
                    console2.log("  Found:", keys[i], vm.toString(addr));
                }
            }
        }

        require(count > 0, "no contract addresses found in manifest");

        address[] memory targets = new address[](count);
        for (uint256 i; i < count; ++i) {
            targets[i] = buffer[i];
        }

        PostDeploymentRoleCheck.RoleViolation[] memory violations =
            PostDeploymentRoleCheck.checkAllRoles(deployer, targets);

        if (violations.length == 0) {
            console2.log("PASSED: deployer retains 0 roles across %d contracts", count);
        } else {
            console2.log("FAILED: %d violations found", violations.length);
            for (uint256 i; i < violations.length; ++i) {
                console2.log("  VIOLATION: target=%s role=%s",
                    vm.toString(violations[i].target),
                    vm.toString(violations[i].role)
                );
            }
            revert("deployer retains unauthorized roles");
        }
    }
}
