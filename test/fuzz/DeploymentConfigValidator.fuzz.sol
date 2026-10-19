// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { DeploymentConfigValidator } from "../../contracts/deployment/DeploymentConfigValidator.sol";

contract FuzzTokenLike is ERC20 {
    constructor() ERC20("FuzzTokenLike", "FTK") { }

    function totalSupply() public view override returns (uint256) {
        return 1;
    }
}

contract FuzzGovernanceControllerLike {
    function version() external pure returns (string memory) {
        return "1";
    }
}

contract FuzzTimelockLike {
    function getMinDelay() external pure returns (uint256) {
        return 1;
    }
}

contract FuzzGovernorLike {
    function proposalThreshold() external pure returns (uint256) {
        return 1;
    }
}

contract FuzzModuleRegistryLike {
    function moduleCount() external pure returns (uint256) {
        return 1;
    }
}

contract FuzzGovernanceGuardianLike {
    function governor() external pure returns (address) {
        return address(0);
    }
}

contract FuzzReputationOracleLike {
    function isActive() external pure returns (bool) {
        return true;
    }
}

/// @notice External wrapper so vm.expectRevert can observe library reverts across a call boundary.
contract FuzzValidatorProbe {
    function validate(DeploymentConfigValidator.Config memory config) external view {
        DeploymentConfigValidator.validate(config);
    }
}

/**
 * @title DeploymentConfigValidatorFuzz
 * @notice Foundry fuzz tests for the canonical V2 deployment validator (SC-068).
 * @dev Soundness properties driven by random configurations:
 *      - any configuration drawn from the valid envelope never reverts;
 *      - the four hard-fail classes (identity zero, duplicate identity, wrong chain id, and
 *        EOA pre-wired modules) revert for arbitrary seeds, so the validator fails closed.
 */
contract DeploymentConfigValidatorFuzz is Test {
    FuzzTokenLike public governanceToken;
    FuzzTokenLike public token;
    FuzzGovernanceControllerLike public governanceController;
    FuzzTimelockLike public timelock;
    FuzzGovernorLike public governor;
    FuzzModuleRegistryLike public moduleRegistry;
    FuzzGovernanceGuardianLike public governanceGuardian;
    FuzzReputationOracleLike public reputationOracle;

    FuzzValidatorProbe public probe;

    address public admin = address(0xA11CE);
    address public guardian = address(0x6A2d1);

    function setUp() public {
        governanceController = new FuzzGovernanceControllerLike();
        governanceToken = new FuzzTokenLike();
        token = new FuzzTokenLike();
        timelock = new FuzzTimelockLike();
        governor = new FuzzGovernorLike();
        moduleRegistry = new FuzzModuleRegistryLike();
        governanceGuardian = new FuzzGovernanceGuardianLike();
        reputationOracle = new FuzzReputationOracleLike();
        probe = new FuzzValidatorProbe();
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    function _rng(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    function _randomConfig(uint256 seed) internal view returns (DeploymentConfigValidator.Config memory) {
        uint256 settlementPercent = bound(_rng(seed, 0x01), 1, 100);
        uint256 rewardPercent = bound(_rng(seed, 0x02), 1, 100);
        uint256 slashPercent = bound(_rng(seed, 0x03), 0, 100 - rewardPercent);
        uint256 minReputation = bound(_rng(seed, 0x04), 1, 100);
        uint256 maxReputation = bound(_rng(seed, 0x05), minReputation, 100);
        uint256 defaultReputation = bound(_rng(seed, 0x06), minReputation, maxReputation);
        uint256 votingPeriod = bound(_rng(seed, 0x07), 1 days, 30 days);
        uint256 votingDelay = bound(_rng(seed, 0x08), 0, votingPeriod - 1);
        uint256 stakingLock = bound(_rng(seed, 0x09), 0, 365 days);
        uint256 delay = bound(_rng(seed, 0x0a), 0, 365 days);

        return DeploymentConfigValidator.Config({
            deployer: address(this),
            admin: admin,
            guardian: guardian,
            governanceController: address(governanceController),
            governanceToken: address(governanceToken),
            timelock: address(timelock),
            governor: address(governor),
            moduleRegistry: address(moduleRegistry),
            governanceGuardian: address(governanceGuardian),
            reputationOracle: address(reputationOracle),
            token: address(token),
            expectedChainId: block.chainid,
            minStakeAmount: bound(_rng(seed, 0x0b), 0, 1_000_000 ether),
            settlementThresholdPercent: settlementPercent,
            rewardPercent: rewardPercent,
            slashPercent: slashPercent,
            confirmationDelay: delay,
            minReputationScore: minReputation,
            maxReputationScore: maxReputation,
            defaultReputationScore: defaultReputation,
            stakingLockDuration: stakingLock,
            votingDelay: votingDelay,
            votingPeriod: votingPeriod,
            proposalThreshold: bound(_rng(seed, 0x0c), 0, 1_000_000 ether),
            quorumNumerator: bound(_rng(seed, 0x0d), 1, 99),
            timelockMinDelay: bound(_rng(seed, 0x0e), 0, 365 days),
            tokenSupply: bound(_rng(seed, 0x0f), 1, 1_000_000_000_000 ether),
            minVerificationCount: bound(_rng(seed, 0x10), 1, 100),
            minConfidenceBps: bound(_rng(seed, 0x11), 0, 10_000),
            challengeWindowDuration: bound(_rng(seed, 0x12), 0, 365 days),
            appealDuration: bound(_rng(seed, 0x13), 0, 365 days),
            minAppealStake: bound(_rng(seed, 0x14), 0, 1_000_000 ether),
            appealMultiplierBps: bound(_rng(seed, 0x15), 0, 100_000),
            maxWeightCap: bound(_rng(seed, 0x16), 0, 1_000_000 ether),
            legacyDenylist: new address[](0)
        });
    }

    /// @dev Returns an arbitrary non-placeholder address, distinct from the fixed identity set,
    ///      with no code on the test chain (a plain EOA). Deterministic per (seed, salt).
    function _randomEOA(uint256 seed, uint256 salt) internal view returns (address eoa) {
        address[] memory fixedAddrs = new address[](2);
        fixedAddrs[0] = admin;
        fixedAddrs[1] = guardian;

        for (uint256 i = 0; i < 8; ++i) {
            eoa = address(uint160(_rng(seed, salt + i)));
            if (eoa == address(0)) continue;
            if (
                eoa == address(uint160(1)) || eoa == address(uint160(2)) || eoa == address(uint160(3))
                    || eoa == address(uint160(4)) || eoa == address(uint160(5)) || eoa == address(uint160(6))
                    || eoa == address(uint160(7)) || eoa == address(uint160(8)) || eoa == address(uint160(9))
            ) {
                continue;
            }
            if (eoa == address(uint160(0xdEaD)) || eoa == address(uint160(type(uint160).max))) continue;
            bool isFixed;
            for (uint256 j = 0; j < fixedAddrs.length; ++j) {
                if (eoa == fixedAddrs[j]) {
                    isFixed = true;
                    break;
                }
            }
            if (!isFixed) return eoa;
        }
        return address(uint160(0xb0b7)); // practically unreachable fallback
    }

    // ── Soundness properties ────────────────────────────────────────────────

    /// @dev Anything drawn from the valid envelope must be accepted (never a false reject).
    function testFuzz_ValidRandomConfigNeverReverts(uint256 seed) public {
        DeploymentConfigValidator.Config memory config = _randomConfig(seed);
        probe.validate(config);
    }

    /// @dev A zero admin is rejected for every random configuration.
    function testFuzz_ZeroAdminAlwaysReverts(uint256 seed) public {
        DeploymentConfigValidator.Config memory config = _randomConfig(seed);
        config.admin = address(0);
        _assertRevert(config, DeploymentConfigValidator.ZeroAddress.selector);
    }

    /// @dev Identity duplicates are rejected for every random configuration.
    function testFuzz_DuplicateIdentityAlwaysReverts(uint256 seed) public {
        DeploymentConfigValidator.Config memory config = _randomConfig(seed);
        config.guardian = admin;
        _assertRevert(config, DeploymentConfigValidator.DuplicateAddress.selector);
    }

    /// @dev A config bound to the wrong chain is rejected for every random configuration.
    function testFuzz_WrongChainAlwaysReverts(uint256 seed) public {
        DeploymentConfigValidator.Config memory config = _randomConfig(seed);
        config.expectedChainId = block.chainid + 1 + (seed % 1_000_000);
        _assertRevert(config, DeploymentConfigValidator.WrongChainId.selector);
    }

    /// @dev Any pre-wired module address that carries no code is rejected (EOA), no matter the seed.
    function testFuzz_EOAModuleAlwaysReverts(uint256 seed) public {
        DeploymentConfigValidator.Config memory config = _randomConfig(seed);
        config.governanceToken = _randomEOA(seed, 0x20);
        _assertRevert(config, DeploymentConfigValidator.EOAAddress.selector);
    }

    /// @dev A legacy-denylisted module address is always rejected.
    function testFuzz_LegacyDenylistAlwaysReverts(uint256 seed) public {
        DeploymentConfigValidator.Config memory config = _randomConfig(seed);
        address[] memory denylist = new address[](1);
        denylist[0] = address(token);
        config.legacyDenylist = denylist;
        _assertRevert(config, DeploymentConfigValidator.LegacyAddress.selector);
    }

    /// @dev Every placeholder address is rejected for every configured identity field. Loops the
    ///      full placeholder class so no sentinel slips through.
    function testFuzz_AllPlaceholdersAlwaysRejected(uint256 seed, uint256 fieldIndex, uint256 placeholderIndex) public {
        fieldIndex = bound(fieldIndex, 0, 1);
        placeholderIndex = bound(placeholderIndex, 0, 8);

        DeploymentConfigValidator.Config memory config = _randomConfig(seed);
        address placeholder = address(uint160(1 + placeholderIndex));
        if (fieldIndex == 0) {
            config.admin = placeholder;
        } else {
            config.guardian = placeholder;
        }
        _assertRevert(config, DeploymentConfigValidator.PlaceholderAddress.selector);
    }

    function _assertRevert(DeploymentConfigValidator.Config memory config, bytes4 expectedSelector) internal {
        try probe.validate(config) {
            fail();
        } catch (bytes memory reason) {
            if (reason.length < 4) fail();
            assertEq(bytes4(reason), expectedSelector);
        }
    }
}
