// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/StdUtils.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { DeploymentConfigValidator } from "../../contracts/deployment/DeploymentConfigValidator.sol";

contract HandlerTokenLike is ERC20 {
    constructor() ERC20("HandlerTokenLike", "HTK") { }

    function totalSupply() public view override returns (uint256) {
        return 1;
    }
}

contract HandlerGovernanceControllerLike {
    function version() external pure returns (string memory) {
        return "1";
    }
}

contract HandlerTimelockLike {
    function getMinDelay() external pure returns (uint256) {
        return 1;
    }
}

contract HandlerGovernorLike {
    function proposalThreshold() external pure returns (uint256) {
        return 1;
    }
}

contract HandlerModuleRegistryLike {
    function moduleCount() external pure returns (uint256) {
        return 1;
    }
}

contract HandlerGovernanceGuardianLike {
    function governor() external pure returns (address) {
        return address(0);
    }
}

contract HandlerReputationOracleLike {
    function isActive() external pure returns (bool) {
        return true;
    }
}

/**
 * @title DeploymentConfigValidatorHandler
 * @notice Stateful handler driving random single-field mutations of a canonical deployment
 *         configuration for the invariant suite (SC-068).
 * @dev Each mutation is classified as either a documented unsafe class (poisons the config) or a
 *      safe rotation. The invariant asserts that a poisoned config is ALWAYS rejected by the
 *      validator and a clean config is NEVER rejected, across arbitrary mutation sequences.
 */
contract DeploymentConfigValidatorHandler is StdUtils {
    DeploymentConfigValidator.Config public storedConfig;
    bool public poisoned;
    uint256 public mutations;

    address public constant SAFE_A = address(0xA11CE);
    address public constant SAFE_B = address(0x6A2d1);

    constructor() {
        storedConfig = _baseValid();
    }

    function config() external view returns (DeploymentConfigValidator.Config memory) {
        return storedConfig;
    }

    function mutate(uint256 seed) external {
        uint256 action = bound(seed, 0, 10);
        DeploymentConfigValidator.Config memory c = storedConfig;

        if (action == 0) {
            c.admin = address(0);
            poisoned = true;
        } else if (action == 1) {
            c.guardian = address(0);
            poisoned = true;
        } else if (action == 2) {
            c.guardian = c.admin;
            poisoned = true;
        } else if (action == 3) {
            c.admin = address(1);
            poisoned = true;
        } else if (action == 4) {
            c.expectedChainId = block.chainid + 1 + (seed % 1_000_000);
            poisoned = true;
        } else if (action == 5) {
            c.quorumNumerator = 0;
            poisoned = true;
        } else if (action == 6) {
            c.appealMultiplierBps = 100_001;
            poisoned = true;
        } else if (action == 7) {
            c.tokenSupply = 0;
            poisoned = true;
        } else if (action == 8) {
            // Wire a module address that carries no code (plain EOA).
            c.governanceToken = address(0xB0B);
            poisoned = true;
        } else if (action == 9) {
            c.timelockMinDelay = 366 days;
            poisoned = true;
        } else {
            // Safe reset: restore a fully canonical, clean configuration.
            storedConfig = _baseValid();
            poisoned = false;
            mutations++;
            return;
        }

        storedConfig = c;
        mutations++;
    }

    function _baseValid() internal returns (DeploymentConfigValidator.Config memory) {
        return DeploymentConfigValidator.Config({
            deployer: address(0),
            admin: SAFE_A,
            guardian: SAFE_B,
            governanceController: address(new HandlerGovernanceControllerLike()),
            governanceToken: address(new HandlerTokenLike()),
            timelock: address(new HandlerTimelockLike()),
            governor: address(new HandlerGovernorLike()),
            moduleRegistry: address(new HandlerModuleRegistryLike()),
            governanceGuardian: address(new HandlerGovernanceGuardianLike()),
            reputationOracle: address(new HandlerReputationOracleLike()),
            token: address(new HandlerTokenLike()),
            expectedChainId: block.chainid,
            minStakeAmount: 100 ether,
            settlementThresholdPercent: 50,
            rewardPercent: 40,
            slashPercent: 40,
            confirmationDelay: 3 days,
            minReputationScore: 1,
            maxReputationScore: 100,
            defaultReputationScore: 10,
            stakingLockDuration: 90 days,
            votingDelay: 1 days,
            votingPeriod: 3 days,
            proposalThreshold: 1000 ether,
            quorumNumerator: 4,
            timelockMinDelay: 2 days,
            tokenSupply: 1_000_000_000 ether,
            minVerificationCount: 2,
            minConfidenceBps: 500,
            challengeWindowDuration: 3 days,
            appealDuration: 3 days,
            minAppealStake: 200 ether,
            appealMultiplierBps: 15000,
            maxWeightCap: 100_000 ether,
            legacyDenylist: new address[](0)
        });
    }
}
