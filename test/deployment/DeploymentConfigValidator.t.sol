// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { DeploymentConfigValidator } from "../../contracts/deployment/DeploymentConfigValidator.sol";

/// @notice Fakes answering the canonical interface probes used by the validator.
contract MockGovernanceControllerLike {
    function version() external pure returns (string memory) {
        return "1";
    }
}

contract MockTokenLike is ERC20 {
    constructor() ERC20("MockTokenLike", "MTK") {
        _mint(msg.sender, 1000000);
    }

    function totalSupply() public view override returns (uint256) {
        return 1;
    }
}

contract MockTimelockLike {
    function getMinDelay() external pure returns (uint256) {
        return 1;
    }
}

contract MockGovernorLike {
    function proposalThreshold() external pure returns (uint256) {
        return 1;
    }
}

contract MockModuleRegistryLike {
    function moduleCount() external pure returns (uint256) {
        return 1;
    }
}

contract MockGovernanceGuardianLike {
    function governor() external pure returns (address) {
        return address(0);
    }
}

contract MockReputationOracleLike {
    function isActive() external pure returns (bool) {
        return true;
    }
}

/// @notice Answers version() only; placing it where proposalThreshold() is probed fails the probe.
contract MockWrongInterface {
    function version() external pure returns (string memory) {
        return "1";
    }
}

/// @notice External wrapper so vm.expectRevert can observe library reverts across a call boundary.
contract ValidatorProbe {
    function validate(DeploymentConfigValidator.Config memory config) external view {
        DeploymentConfigValidator.validate(config);
    }

    function validateStatic(DeploymentConfigValidator.Config memory config) external view {
        DeploymentConfigValidator.validateStatic(config);
    }
}

/**
 * @title DeploymentConfigValidatorTest
 * @notice Foundry unit tests for the canonical V2 deployment-configuration validator (SC-068).
 * @dev Every scenario that must be rejected before a deployment transaction is broadcast is
 *      asserted to revert with the granular validator error. See also
 *      test/fuzz/DeploymentConfigValidator.fuzz.sol and the invariant suite.
 */
contract DeploymentConfigValidatorTest is Test {
    // ── Witness contracts ──────────────────────────────────────────────────

    MockGovernanceControllerLike public governanceController;
    MockTokenLike public governanceToken;
    MockTokenLike public token;
    MockTimelockLike public timelock;
    MockGovernorLike public governor;
    MockModuleRegistryLike public moduleRegistry;
    MockGovernanceGuardianLike public governanceGuardian;
    MockReputationOracleLike public reputationOracle;
    MockWrongInterface public wrongInterface;
    ValidatorProbe public probe;

    address public admin = address(0xA11CE);
    address public guardian = address(0x6A2d1);
    address public otherDeployer = address(0x711A1);

    uint256 public constant ONE_DAY = 1 days;

    // ── Setup ──────────────────────────────────────────────────────────────

    function setUp() public {
        governanceController = new MockGovernanceControllerLike();
        governanceToken = new MockTokenLike();
        token = new MockTokenLike();
        timelock = new MockTimelockLike();
        governor = new MockGovernorLike();
        moduleRegistry = new MockModuleRegistryLike();
        governanceGuardian = new MockGovernanceGuardianLike();
        reputationOracle = new MockReputationOracleLike();
        wrongInterface = new MockWrongInterface();
        probe = new ValidatorProbe();
    }

    // ── Harness: fully-wired canonical config ───────────────────────────────

    function _fullyWired() internal view returns (DeploymentConfigValidator.Config memory) {
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

    /// @notice Mirrors the DeployGovernanceV2 configuration: every module deployed fresh, only
    ///         governance params concretized, everything else at framework defaults.
    function _deployFreshGovernance() internal view returns (DeploymentConfigValidator.Config memory) {
        return DeploymentConfigValidator.Config({
            deployer: address(0),
            admin: admin,
            guardian: guardian,
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
            votingDelay: 1 days,
            votingPeriod: 3 days,
            proposalThreshold: 100_000 ether,
            quorumNumerator: 4,
            timelockMinDelay: 2 days,
            tokenSupply: 1_000_000_000 ether,
            minVerificationCount: 1,
            minConfidenceBps: 0,
            challengeWindowDuration: 0,
            appealDuration: 0,
            minAppealStake: 0,
            appealMultiplierBps: 0,
            maxWeightCap: 0,
            legacyDenylist: new address[](0)
        });
    }

    // ── Happy paths ─────────────────────────────────────────────────────────

    function test_Validate_Passes_FullyWiredConfig() public {
        probe.validate(_fullyWired());
    }

    function test_Validate_Passes_DeployFreshSentinelConfig() public {
        probe.validate(_deployFreshGovernance());
    }

    function test_Validate_Passes_QuorumNumeratorBoundaries() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();

        config.quorumNumerator = 1;
        probe.validate(config);

        config.quorumNumerator = 99;
        probe.validate(config);
    }

    function test_Validate_Passes_AppealMultiplierAtCanonicalDefaultCap() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();

        config.appealMultiplierBps = 100_000;
        probe.validate(config);
    }

    function test_Validate_Passes_EmptyLegacyDenylistAndOptionalModules() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.legacyDenylist = new address[](0);
        config.governanceToken = address(0);
        config.token = address(0);
        config.timelock = address(0);
        config.governor = address(0);
        config.moduleRegistry = address(0);
        config.governanceGuardian = address(0);
        config.reputationOracle = address(0);
        config.governanceController = address(0);

        probe.validate(config);
    }

    // ── Identity / authorization ────────────────────────────────────────────

    function test_Validate_RevertsOnZeroAdmin() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.admin = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentConfigValidator.ZeroAddress.selector, "admin"));
        probe.validate(config);
    }

    function test_Validate_RevertsOnZeroGuardian() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.guardian = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentConfigValidator.ZeroAddress.selector, "guardian"));
        probe.validate(config);
    }

    function test_validateStatic_RevertsOnUnauthorizedDeployer() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.deployer = address(this);
        vm.prank(otherDeployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.UnauthorizedDeployer.selector, address(this), otherDeployer
            )
        );
        probe.validateStatic(config);
    }

    function test_validateStatic_SkipsDeployerAuthWhenUnset() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.deployer = address(0);
        vm.prank(otherDeployer);
        probe.validateStatic(config);
    }

    // ── Duplicates ──────────────────────────────────────────────────────────

    function test_Validate_RevertsOnDuplicateAdminGuardian() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.guardian = admin;
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentConfigValidator.DuplicateAddress.selector, "admin", "guardian", admin)
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnDuplicateIdentityAndOptionalModule() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.token = admin;
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentConfigValidator.DuplicateAddress.selector, "admin", "token", admin)
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnDuplicateOptionalModules() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.governanceToken = address(token);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.DuplicateAddress.selector, "governanceToken", "token", address(token)
            )
        );
        probe.validate(config);
    }

    // ── Placeholders ────────────────────────────────────────────────────────

    function test_Validate_RevertsOnPlaceholderAdmin() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.admin = address(1);
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentConfigValidator.PlaceholderAddress.selector, "admin", address(1))
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnBurnPlaceholderGuardian() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.guardian = address(uint160(0xdEaD));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.PlaceholderAddress.selector, "guardian", address(uint160(0xdEaD))
            )
        );
        probe.validate(config);
    }

    // ── Chain binding ───────────────────────────────────────────────────────

    function test_Validate_RevertsOnWrongChainId() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.expectedChainId = block.chainid + 1;
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentConfigValidator.WrongChainId.selector, block.chainid + 1, block.chainid)
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnChainIdZero() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.expectedChainId = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.InvalidParameterRange.selector,
                "expectedChainId",
                uint256(0),
                uint256(1),
                type(uint256).max
            )
        );
        probe.validate(config);
    }

    // ── Runtime: EOA / wrong interface / legacy denylist ────────────────────

    function test_Validate_RevertsOnPreWiredEOAModule() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        address eoa = address(0xB0B);
        config.governanceToken = eoa;
        vm.expectRevert(abi.encodeWithSelector(DeploymentConfigValidator.EOAAddress.selector, "governanceToken", eoa));
        probe.validate(config);
    }

    function test_Validate_RevertsOnWrongInterfaceProbe() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.governor = address(wrongInterface);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.WrongInterface.selector,
                "governor",
                address(wrongInterface),
                bytes4(0xb58131b0)
            )
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnLegacyDenylistMatch() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        address[] memory denylist = new address[](1);
        denylist[0] = address(token);
        config.legacyDenylist = denylist;
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentConfigValidator.LegacyAddress.selector, "token", address(token))
        );
        probe.validate(config);
    }

    function test_validateStatic_DoesNotInspectExternalState() public {
        // validateStatic must never probe on-chain state: an EOA wired as a module is only
        // rejected by the runtime stage, proving the static stage is provider-independent.
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.governanceToken = address(0xB0B);
        probe.validateStatic(config);
    }

    // ── Numeric bounds ──────────────────────────────────────────────────────

    function test_Validate_RevertsOnSettlementThresholdOverCap() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.settlementThresholdPercent = 101;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.InvalidParameterRange.selector,
                "settlementThresholdPercent",
                uint256(101),
                uint256(1),
                uint256(100)
            )
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnRewardPlusSlashOverCap() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.rewardPercent = 50;
        config.slashPercent = 51;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.InvalidParameterRange.selector,
                "rewardPercent+slashPercent",
                uint256(101),
                uint256(1),
                uint256(100)
            )
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnMinReputationGreaterThanMax() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.minReputationScore = 101;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.InvalidParameterRange.selector,
                "minReputationScore",
                uint256(101),
                uint256(1),
                uint256(100)
            )
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnDefaultReputationOutOfRange() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.defaultReputationScore = 1000;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.InvalidParameterRange.selector,
                "defaultReputationScore",
                uint256(1000),
                uint256(1),
                uint256(100)
            )
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnVotingDelayAtOrAboveVotingPeriod() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.votingDelay = 3 days;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.InvalidParameterRange.selector,
                "votingDelay",
                uint256(3 days),
                uint256(0),
                uint256(3 days - 1)
            )
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnZeroQuorumNumerator() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.quorumNumerator = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.InvalidParameterRange.selector,
                "quorumNumerator",
                uint256(0),
                uint256(1),
                uint256(99)
            )
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnHundredQuorumNumerator() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.quorumNumerator = 100;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.InvalidParameterRange.selector,
                "quorumNumerator",
                uint256(100),
                uint256(1),
                uint256(99)
            )
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnZeroVotingPeriod() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.votingPeriod = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.InvalidParameterRange.selector,
                "votingPeriod",
                uint256(0),
                uint256(1),
                uint256(type(uint32).max)
            )
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnTimelockMinDelayOverCap() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.timelockMinDelay = 366 days;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.InvalidParameterRange.selector,
                "timelockMinDelay",
                uint256(366 days),
                uint256(0),
                uint256(365 days)
            )
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnZeroTokenSupply() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.tokenSupply = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.InvalidParameterRange.selector,
                "tokenSupply",
                uint256(0),
                uint256(1),
                type(uint256).max
            )
        );
        probe.validate(config);
    }

    function test_Validate_RevertsOnAppealMultiplierOverCap() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();
        config.appealMultiplierBps = 100_001;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfigValidator.InvalidParameterRange.selector,
                "appealMultiplierBps",
                uint256(100_001),
                uint256(1),
                uint256(100_000)
            )
        );
        probe.validate(config);
    }

    // ── Regression: previously-unsafe configurations are all rejected ───────

    /// @dev Harness capturing the configuration classes that pre-SC-068 DeployGovernanceV2 /
    ///      deployCanonicalV2 accepted without any validation before broadcasting. Each of these
    ///      configurations MUST be rejected before the first deployment transaction; any of them
    ///      being accepted would constitute a regression to unsafe deploy behaviour.
    function test_Regression_PriorUnsafeConfigsAreAllRejected() public {
        DeploymentConfigValidator.Config memory config = _fullyWired();

        config = _fullyWired();
        config.admin = address(0);
        _expectReject(config);

        config = _fullyWired();
        config.guardian = address(0);
        _expectReject(config);

        config = _fullyWired();
        config.guardian = address(1);
        _expectReject(config);

        config = _fullyWired();
        config.admin = address(uint160(0xdEaD));
        _expectReject(config);

        config = _fullyWired();
        config.expectedChainId = block.chainid + 1;
        _expectReject(config);

        config = _fullyWired();
        config.quorumNumerator = 0;
        _expectReject(config);

        config = _fullyWired();
        config.quorumNumerator = 100;
        _expectReject(config);

        config = _fullyWired();
        config.appealMultiplierBps = 100_001;
        _expectReject(config);

        config = _fullyWired();
        config.timelockMinDelay = 366 days;
        _expectReject(config);

        config = _fullyWired();
        config.votingDelay = 3 days;
        _expectReject(config);

        config = _fullyWired();
        config.tokenSupply = 0;
        _expectReject(config);
    }

    function _expectReject(DeploymentConfigValidator.Config memory config) internal {
        vm.expectRevert();
        probe.validate(config);
    }
}
