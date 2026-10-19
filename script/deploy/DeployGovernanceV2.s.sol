// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { GovernedModuleRegistry } from "../../contracts/governance/v2/GovernedModuleRegistry.sol";
import { TruthBountyGovernanceToken } from "../../contracts/governance/v2/TruthBountyGovernanceToken.sol";
import { TruthBountyGovernor } from "../../contracts/governance/v2/TruthBountyGovernor.sol";
import { GovernanceSnapshot } from "../../contracts/governance/v2/GovernanceSnapshot.sol";
import { IGovernanceSnapshot } from "../../contracts/governance/v2/IGovernanceSnapshot.sol";
import { GovernanceGuardian } from "../../contracts/governance/v2/GovernanceGuardian.sol";
import { ITruthBountyGovernor } from "../../contracts/governance/v2/ITruthBountyGovernor.sol";
import { GovernanceRoleTopology } from "../../contracts/governance/v2/GovernanceRoleTopology.sol";
import { DeploymentPreflight } from "./DeploymentPreflight.sol";
import { DeploymentConfigValidator } from "../../contracts/deployment/DeploymentConfigValidator.sol";

/**
 * @title DeployGovernanceV2
 * @notice Deploys V2 governor, timelock, governance token, module registry, guardian, and
 *         canonical governance snapshot registry.
 *
 * @dev Deployment order:
 *      1. GovernedModuleRegistry
 *      2. TruthBountyGovernanceToken
 *      3. TimelockController (no proposers/executors yet)
 *      4. TruthBountyGovernor — needs token, timelock, registry, snapshot address
 *         but snapshot needs the governor address → bootstrap order:
 *         deploy governor with snapshot=address(0), then deploy snapshot with
 *         governor as registrar.
 *
 *      Actually: deploy snapshot with admin as temporary registrar, then deploy
 *      governor with snapshot address. After governor is deployed, grant
 *      SNAPSHOT_REGISTRAR_ROLE to governor and revoke from admin.
 *
 *      This ensures the governor has the role before any proposal can be created
 *      (proposals require threshold tokens → delegation → no proposal is possible
 *      during deployment).
 */
contract DeployGovernanceV2 is Script {
    struct GovernanceConfig {
        address admin;
        address guardian;
        uint256 timelockMinDelay;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumNumerator;
        uint256 tokenSupply;
    }

    function run() external {
        GovernanceConfig memory cfg = GovernanceConfig({
            admin: vm.envAddress("ADMIN_ADDRESS"),
            guardian: vm.envAddress("GUARDIAN_ADDRESS"),
            timelockMinDelay: vm.envOr("TIMELOCK_MIN_DELAY", uint256(2 days)),
            votingDelay: uint48(vm.envOr("GOV_VOTING_DELAY", uint256(1 days))),
            votingPeriod: uint32(vm.envOr("GOV_VOTING_PERIOD", uint256(3 days))),
            proposalThreshold: vm.envOr("GOV_PROPOSAL_THRESHOLD", uint256(100_000 ether)),
            quorumNumerator: vm.envOr("GOV_QUORUM_NUMERATOR", uint256(4)),
            tokenSupply: vm.envOr("GOV_TOKEN_SUPPLY", uint256(1_000_000_000 ether))
        });

        uint256 expectedChainId = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        if (expectedChainId != 0) DeploymentPreflight.requireExpectedChainId(expectedChainId);

        DeploymentPreflight.requireNonZeroAddress(cfg.admin, "admin");
        DeploymentPreflight.requireNonZeroAddress(cfg.guardian, "guardian");

        address expectedDeployer = vm.envOr("EXPECTED_DEPLOYER", address(0));
        if (expectedDeployer != address(0)) {
            DeploymentPreflight.requireDeployer(expectedDeployer, msg.sender);
        }

        uint256 minBalance = vm.envOr("MIN_GAS_BALANCE", uint256(0.05 ether));
        if (minBalance != 0) DeploymentPreflight.requireSufficientBalance(msg.sender, minBalance);
        DeploymentConfigValidator.validate(_validatorConfig(cfg));

        vm.startBroadcast(cfg.admin);

        GovernedModuleRegistry registry = new GovernedModuleRegistry(cfg.admin);
        TruthBountyGovernanceToken token = new TruthBountyGovernanceToken(cfg.admin, cfg.tokenSupply);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        TimelockController timelock = new TimelockController(cfg.timelockMinDelay, proposers, executors, cfg.admin);

        // Check the deployed timelock and module compatibility before completing setup.
        DeploymentPreflight.requireTimelock(address(timelock), "governance timelock");

        // Deploy the snapshot registry with admin as temporary registrar, then transfer its role.
        GovernanceSnapshot snapshot = new GovernanceSnapshot(cfg.admin, cfg.admin);

        TruthBountyGovernor governor = new TruthBountyGovernor(
            token,
            timelock,
            registry,
            IGovernanceSnapshot(address(snapshot)),
            cfg.guardian,
            cfg.votingDelay,
            cfg.votingPeriod,
            cfg.proposalThreshold,
            cfg.quorumNumerator
        );

        // Check the newly deployed registry, governor, and timelock are compatible.
        DeploymentPreflight.requireCompatibleModules(address(registry), address(governor), address(timelock));

        // Transfer SNAPSHOT_REGISTRAR_ROLE to governor and revoke it from the admin.
        snapshot.grantRole(snapshot.SNAPSHOT_REGISTRAR_ROLE(), address(governor));
        snapshot.revokeRole(snapshot.SNAPSHOT_REGISTRAR_ROLE(), cfg.admin);

        GovernanceGuardian guardianContract = new GovernanceGuardian(
            cfg.admin,
            cfg.guardian,
            ITruthBountyGovernor(address(governor))
        );

        vm.stopBroadcast();
        vm.startBroadcast(cfg.guardian);
        governor.setGovernanceGuardianModule(address(guardianContract));
        vm.stopBroadcast();
        vm.startBroadcast(cfg.admin);

        GovernanceRoleTopology.configure(timelock, governor, cfg.guardian, cfg.timelockMinDelay);
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, cfg.admin);

        // Governance (the timelock) administers the module registry. The grant targets the
        // registry contract: granting on the timelock would only mint an unused role there, and
        // after `finalizeTimelockAdmin` the broadcasting admin no longer holds timelock authority.
        registry.grantRole(registry.REGISTRY_ADMIN_ROLE(), address(timelock));

        governor.publishManifest();

        vm.stopBroadcast();

        console2.log("GovernedModuleRegistry", address(registry));
        console2.log("TruthBountyGovernanceToken", address(token));
        console2.log("TimelockController", address(timelock));
        console2.log("GovernanceSnapshot", address(snapshot));
        console2.log("TruthBountyGovernor", address(governor));
        console2.log("GovernanceGuardian", address(guardianContract));
    }

    /// @notice Maps the governance deployment configuration into the canonical validator model.
    /// @dev Every optional module address is left as the deploy-fresh sentinel because this
    ///      script deploys the complete governance suite itself. `deployer` is pinned from the
    ///      environment when provided so a config cannot be broadcast from the wrong key.
    function _validatorConfig(GovernanceConfig memory cfg)
        internal
        view
        returns (DeploymentConfigValidator.Config memory)
    {
        return DeploymentConfigValidator.Config({
            deployer: vm.envOr("DEPLOYER_ADDRESS", address(0)),
            admin: cfg.admin,
            guardian: cfg.guardian,
            governanceController: address(0),
            governanceToken: address(0),
            timelock: address(0),
            governor: address(0),
            moduleRegistry: address(0),
            governanceGuardian: address(0),
            reputationOracle: address(0),
            token: address(0),
            expectedChainId: block.chainid,
            minStakeAmount: 0,
            settlementThresholdPercent: 0,
            rewardPercent: 0,
            slashPercent: 0,
            confirmationDelay: 0,
            minReputationScore: 0,
            maxReputationScore: 0,
            defaultReputationScore: 0,
            stakingLockDuration: 0,
            votingDelay: cfg.votingDelay,
            votingPeriod: cfg.votingPeriod,
            proposalThreshold: cfg.proposalThreshold,
            quorumNumerator: cfg.quorumNumerator,
            timelockMinDelay: cfg.timelockMinDelay,
            tokenSupply: cfg.tokenSupply,
            minVerificationCount: 0,
            minConfidenceBps: 0,
            challengeWindowDuration: 0,
            appealDuration: 0,
            minAppealStake: 0,
            appealMultiplierBps: 0,
            maxWeightCap: 0,
            legacyDenylist: new address[](0)
        });
    }
}
