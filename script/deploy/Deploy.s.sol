// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "./DeployBase.s.sol";
import "../../contracts/TruthBounty.sol";
import "../../contracts/MockReputationOracle.sol";
import "../../contracts/TruthBountyWeighted.sol";
import "../../contracts/staking.sol";
import "../../contracts/VerifierSlashing.sol";
import "../../contracts/TruthBountyClaims.sol";
import "../../contracts/governance/GovernanceController.sol";
import "../../contracts/deployment/MigrationManager.sol";

contract Deploy is DeployBase {
    function run(string memory env) external {
        loadConfig(env);

        vm.startBroadcast();

        console2.log("Deploying to:", env);
        console2.log("Admin:", config.admin);

        GovernanceController governance;
        if (config.governanceController != address(0)) {
            governance = GovernanceController(payable(config.governanceController));
            console2.log("Using existing GovernanceController:", config.governanceController);
        } else {
            governance = new GovernanceController(config.admin);
            console2.log("Deployed GovernanceController:", address(governance));
        }

        MigrationManager migrationManager = new MigrationManager(config.admin, address(governance));
        console2.log("Deployed MigrationManager:", address(migrationManager));

        TruthBountyToken token = new TruthBountyToken(config.admin);
        console2.log("Deployed TruthBountyToken:", address(token));

        MockReputationOracle oracle = new MockReputationOracle();
        console2.log("Deployed MockReputationOracle:", address(oracle));

        Staking staking = new Staking(address(token), config.stakingLockDuration, config.admin);
        console2.log("Deployed Staking:", address(staking));

        TruthBountyWeighted bounty = new TruthBountyWeighted(
            address(token),
            address(oracle),
            config.admin,
            address(governance)
        );
        console2.log("Deployed TruthBountyWeighted:", address(bounty));

        VerifierSlashing slashing = new VerifierSlashing(address(staking), config.admin, address(governance));
        console2.log("Deployed VerifierSlashing:", address(slashing));

        TruthBountyClaims claims = new TruthBountyClaims(address(token), config.admin);
        console2.log("Deployed TruthBountyClaims:", address(claims));

        vm.stopBroadcast();

        string memory version = vm.envOr("RELEASE_VERSION", string("2.0.0"));
        string memory manifest = generateManifest(
            version,
            address(migrationManager),
            address(token),
            address(oracle),
            address(bounty),
            address(staking),
            address(slashing),
            address(claims)
        );

        saveDeployment("manifest.json", manifest);
        console2.log("Deployment complete. Manifest saved.");
    }

    function run() external {
        this.run(vm.envOr("DEPLOY_ENV", string("local")));
    }
}