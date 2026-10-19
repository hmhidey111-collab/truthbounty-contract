// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "forge-std/Base.sol";
import "../contracts/crosschain/ChainConfigRegistry.sol";
import "../contracts/crosschain/IChainConfigRegistry.sol";

// ═══════════════════════════════════════════════════════════════════════════════
// V2-SC-139 — ChainConfigRegistry Test Suite
//
// Coverage matrix:
//   ✓ Positive (happy-path)        — register, seal, upgrade, claim link
//   ✓ Negative (rejection)         — every custom error path
//   ✓ Boundary                     — max assets, timelock edge, version counter
//   ✓ Authorization                — role enforcement for all three roles
//   ✓ Replay                       — salt reuse, governance reuse, claim reuse
//   ✓ Failure-path                 — seal before timelock, cancel after seal
//   ✓ Fuzz (stateless)             — random registration parameters
//   ✓ Invariant (stateful fuzz)    — handler-driven protocol property coverage
//   ✓ Event/storage reconciliation — emitted events match on-chain state
// ═══════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

contract ChainConfigTestBase is Test {
    ChainConfigRegistry internal registry;

    address internal admin    = address(0xAD01);
    address internal proposer = address(0xBE01);
    address internal executor = address(0xCE01);
    address internal guardian = address(0xDE01);
    address internal outsider = address(0xFF01);

    // Valid default config parameters
    bytes32 internal constant SALT_1      = keccak256("salt-v1");
    bytes32 internal constant SALT_2      = keccak256("salt-v2");
    bytes32 internal constant SALT_3      = keccak256("salt-v3");
    bytes32 internal constant MANIFEST    = keccak256("manifest-v1");
    bytes32 internal constant MANIFEST_2  = keccak256("manifest-v2");
    address internal constant GOV_1       = address(0x6001);
    address internal constant GOV_2       = address(0x6002);
    address internal constant GOV_3       = address(0x6003);
    address internal constant TREASURY_1  = address(0x7001);
    address internal constant TREASURY_2  = address(0x7002);
    address internal constant ASSET_A     = address(0xA001);
    address internal constant ASSET_B     = address(0xA002);
    uint64  internal constant FIN_BLOCKS  = 15;
    uint64  internal constant FIN_SECS    = 900;

    function setUp() public virtual {
        registry = new ChainConfigRegistry(admin);

        // Grant separate roles to distinct accounts
        vm.startPrank(admin);
        registry.grantRole(registry.CHAIN_CONFIG_PROPOSER_ROLE(), proposer);
        registry.grantRole(registry.CHAIN_CONFIG_EXECUTOR_ROLE(), executor);
        registry.grantRole(registry.CHAIN_CONFIG_GUARDIAN_ROLE(), guardian);
        vm.stopPrank();
    }

    function _defaultAssets() internal pure returns (address[] memory) {
        address[] memory a = new address[](2);
        a[0] = ASSET_A;
        a[1] = ASSET_B;
        return a;
    }

    function _singleAsset(address asset) internal pure returns (address[] memory) {
        address[] memory a = new address[](1);
        a[0] = asset;
        return a;
    }

    /// @dev Register + seal a config in one helper (advances time past timelock).
    function _registerAndSeal(
        bytes32 salt,
        address gov,
        address treasury
    ) internal returns (uint256 ver) {
        vm.prank(proposer);
        ver = registry.registerChainConfig(
            block.chainid, salt, MANIFEST, gov, treasury,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK());
        vm.prank(executor);
        registry.sealChainConfig(block.chainid, ver);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 1. POSITIVE TESTS (happy-path)
// ═══════════════════════════════════════════════════════════════════════════════

contract ChainConfigPositiveTest is ChainConfigTestBase {

    function test_registerChainConfig_happy() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        assertEq(ver, 1, "First version should be 1");
        assertEq(registry.getLatestVersion(block.chainid), 1);
        assertTrue(registry.isSaltUsed(SALT_1));

        IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, 1);
        assertEq(cfg.chainId, block.chainid);
        assertEq(cfg.configVersion, 1);
        assertEq(cfg.salt, SALT_1);
        assertEq(cfg.manifestHash, MANIFEST);
        assertEq(cfg.governance, GOV_1);
        assertEq(cfg.treasury, TREASURY_1);
        assertEq(cfg.acceptedAssets.length, 2);
        assertEq(cfg.acceptedAssets[0], ASSET_A);
        assertEq(cfg.acceptedAssets[1], ASSET_B);
        assertEq(cfg.finalityBlocks, FIN_BLOCKS);
        assertEq(cfg.finalitySeconds, FIN_SECS);
        assertEq(uint256(cfg.status), uint256(IChainConfigRegistry.ConfigStatus.DRAFT));
        assertEq(cfg.proposer, proposer);
        assertEq(cfg.sealedAt, 0);
        assertGt(cfg.executeAfter, block.timestamp);
    }

    function test_sealChainConfig_happy() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        // Advance past timelock
        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK());

        vm.prank(executor);
        registry.sealChainConfig(block.chainid, ver);

        IChainConfigRegistry.ChainConfig memory sealedCfg = registry.getSealedConfig(block.chainid);
        assertEq(uint256(sealedCfg.status), uint256(IChainConfigRegistry.ConfigStatus.SEALED));
        assertEq(sealedCfg.sealedAt, block.timestamp);
        assertTrue(registry.isGovernanceSealed(GOV_1));
    }

    function test_upgradeConfig_deprecatesPrevious() public {
        // Seal version 1
        uint256 v1 = _registerAndSeal(SALT_1, GOV_1, TREASURY_1);
        assertEq(v1, 1);

        // Register version 2
        vm.prank(proposer);
        uint256 v2 = registry.registerChainConfig(
            block.chainid, SALT_2, MANIFEST_2, GOV_2, TREASURY_2,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
        assertEq(v2, 2);

        // Seal version 2 → version 1 should be DEPRECATED
        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK());
        vm.prank(executor);
        registry.sealChainConfig(block.chainid, v2);

        IChainConfigRegistry.ChainConfig memory oldCfg = registry.getConfig(block.chainid, v1);
        assertEq(uint256(oldCfg.status), uint256(IChainConfigRegistry.ConfigStatus.DEPRECATED));

        IChainConfigRegistry.ChainConfig memory newCfg = registry.getSealedConfig(block.chainid);
        assertEq(newCfg.configVersion, v2);
        assertEq(uint256(newCfg.status), uint256(IChainConfigRegistry.ConfigStatus.SEALED));
    }

    function test_recordClaimConfig_linksToSealedVersion() public {
        uint256 ver = _registerAndSeal(SALT_1, GOV_1, TREASURY_1);

        registry.recordClaimConfig(42);
        assertEq(registry.getClaimConfigVersion(42), ver);

        IChainConfigRegistry.ChainConfig memory claimCfg = registry.getConfigForClaim(42);
        assertEq(claimCfg.configVersion, ver);
    }

    function test_cancelDraft_happy() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        vm.prank(guardian);
        registry.cancelDraft(block.chainid, ver);

        IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, ver);
        assertEq(uint256(cfg.status), uint256(IChainConfigRegistry.ConfigStatus.CANCELLED));
    }

    function test_singleAsset_registration() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _singleAsset(ASSET_A), FIN_BLOCKS, FIN_SECS
        );
        IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, ver);
        assertEq(cfg.acceptedAssets.length, 1);
        assertEq(cfg.acceptedAssets[0], ASSET_A);
    }

    function test_adminCanRegister() public {
        // Admin also holds PROPOSER_ROLE from constructor
        vm.prank(admin);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
        assertEq(ver, 1);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 2. NEGATIVE TESTS (rejection / every error path)
// ═══════════════════════════════════════════════════════════════════════════════

contract ChainConfigNegativeTest is ChainConfigTestBase {

    // ── registerChainConfig rejections ────────────────────────────────────────

    function test_revert_chainIdMismatch() public {
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.ChainIdMismatch.selector,
                block.chainid,
                999
            )
        );
        registry.registerChainConfig(
            999, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function test_revert_saltAlreadyUsed() public {
        vm.prank(proposer);
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(IChainConfigRegistry.SaltAlreadyUsed.selector, SALT_1)
        );
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_2, TREASURY_2,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function test_revert_manifestHashRequired() public {
        vm.prank(proposer);
        vm.expectRevert(IChainConfigRegistry.ManifestHashRequired.selector);
        registry.registerChainConfig(
            block.chainid, SALT_1, bytes32(0), GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function test_revert_governanceZeroAddress() public {
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.GovernanceAddressConflict.selector,
                address(0)
            )
        );
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, address(0), TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function test_revert_governanceAlreadySealed() public {
        _registerAndSeal(SALT_1, GOV_1, TREASURY_1);

        // Try to register new draft with same governance
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.GovernanceAddressConflict.selector,
                GOV_1
            )
        );
        registry.registerChainConfig(
            block.chainid, SALT_2, MANIFEST_2, GOV_1, TREASURY_2,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function test_revert_zeroTreasury() public {
        vm.prank(proposer);
        vm.expectRevert(IChainConfigRegistry.ZeroTreasury.selector);
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, address(0),
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function test_revert_emptyAssetList() public {
        address[] memory empty = new address[](0);
        vm.prank(proposer);
        vm.expectRevert(IChainConfigRegistry.InvalidAssetList.selector);
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            empty, FIN_BLOCKS, FIN_SECS
        );
    }

    function test_revert_assetListContainsZero() public {
        address[] memory assets = new address[](2);
        assets[0] = ASSET_A;
        assets[1] = address(0);
        vm.prank(proposer);
        vm.expectRevert(IChainConfigRegistry.InvalidAssetList.selector);
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            assets, FIN_BLOCKS, FIN_SECS
        );
    }

    function test_revert_finalityBlocksZero() public {
        vm.prank(proposer);
        vm.expectRevert(IChainConfigRegistry.InvalidFinalitySettings.selector);
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), 0, FIN_SECS
        );
    }

    function test_revert_finalitySecondsZero() public {
        vm.prank(proposer);
        vm.expectRevert(IChainConfigRegistry.InvalidFinalitySettings.selector);
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, 0
        );
    }

    // ── sealChainConfig rejections ───────────────────────────────────────────

    function test_revert_sealConfigNotFound() public {
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.ConfigNotFound.selector,
                block.chainid, 99
            )
        );
        registry.sealChainConfig(block.chainid, 99);
    }

    function test_revert_sealConfigNotDraft() public {
        uint256 ver = _registerAndSeal(SALT_1, GOV_1, TREASURY_1);

        // Already sealed — cannot seal again
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.ConfigNotDraft.selector,
                block.chainid, ver
            )
        );
        registry.sealChainConfig(block.chainid, ver);
    }

    function test_revert_sealTimelockNotExpired() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        // Do NOT advance time
        IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, ver);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.TimelockNotExpired.selector,
                cfg.executeAfter
            )
        );
        registry.sealChainConfig(block.chainid, ver);
    }

    // ── cancelDraft rejections ───────────────────────────────────────────────

    function test_revert_cancelConfigNotFound() public {
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.ConfigNotFound.selector,
                block.chainid, 99
            )
        );
        registry.cancelDraft(block.chainid, 99);
    }

    function test_revert_cancelConfigNotDraft() public {
        uint256 ver = _registerAndSeal(SALT_1, GOV_1, TREASURY_1);

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.ConfigNotDraft.selector,
                block.chainid, ver
            )
        );
        registry.cancelDraft(block.chainid, ver);
    }

    // ── view function rejections ─────────────────────────────────────────────

    function test_revert_getSealedConfig_noneExists() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.NoSealedConfig.selector,
                block.chainid
            )
        );
        registry.getSealedConfig(block.chainid);
    }

    function test_revert_getConfig_notFound() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.ConfigNotFound.selector,
                block.chainid, 1
            )
        );
        registry.getConfig(block.chainid, 1);
    }

    function test_revert_getConfigForClaim_notRecorded() public {
        vm.expectRevert();
        registry.getConfigForClaim(999);
    }

    // ── constructor rejection ────────────────────────────────────────────────

    function test_revert_constructorZeroAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.GovernanceAddressConflict.selector,
                address(0)
            )
        );
        new ChainConfigRegistry(address(0));
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 3. AUTHORIZATION TESTS (role enforcement)
// ═══════════════════════════════════════════════════════════════════════════════

contract ChainConfigAuthorizationTest is ChainConfigTestBase {

    function test_revert_registerWithoutProposerRole() public {
        vm.prank(outsider);
        vm.expectRevert();
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function test_revert_sealWithoutExecutorRole() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK());

        vm.prank(outsider);
        vm.expectRevert();
        registry.sealChainConfig(block.chainid, ver);
    }

    function test_revert_cancelWithoutGuardianRole() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        vm.prank(outsider);
        vm.expectRevert();
        registry.cancelDraft(block.chainid, ver);
    }

    function test_revert_proposerCannotSeal() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK());

        vm.prank(proposer);
        vm.expectRevert();
        registry.sealChainConfig(block.chainid, ver);
    }

    function test_revert_executorCannotRegister() public {
        vm.prank(executor);
        vm.expectRevert();
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function test_revert_guardianCannotSeal() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK());

        vm.prank(guardian);
        vm.expectRevert();
        registry.sealChainConfig(block.chainid, ver);
    }

    function test_revert_guardianCannotRegister() public {
        vm.prank(guardian);
        vm.expectRevert();
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 4. REPLAY & CROSS-CONTAMINATION TESTS
// ═══════════════════════════════════════════════════════════════════════════════

contract ChainConfigReplayTest is ChainConfigTestBase {

    function test_saltConsumedAfterCancel() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        vm.prank(guardian);
        registry.cancelDraft(block.chainid, ver);

        // Salt still consumed — cannot reuse
        assertTrue(registry.isSaltUsed(SALT_1));
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(IChainConfigRegistry.SaltAlreadyUsed.selector, SALT_1)
        );
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_2, TREASURY_2,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function test_governanceSealedCannotBeReused() public {
        _registerAndSeal(SALT_1, GOV_1, TREASURY_1);

        assertTrue(registry.isGovernanceSealed(GOV_1));

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.GovernanceAddressConflict.selector,
                GOV_1
            )
        );
        registry.registerChainConfig(
            block.chainid, SALT_2, MANIFEST_2, GOV_1, TREASURY_2,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function test_claimCannotBeRecordedTwice() public {
        _registerAndSeal(SALT_1, GOV_1, TREASURY_1);

        registry.recordClaimConfig(100);

        vm.expectRevert();
        registry.recordClaimConfig(100);
    }

    function test_claimCannotBeRecordedWithZeroId() public {
        _registerAndSeal(SALT_1, GOV_1, TREASURY_1);

        vm.expectRevert();
        registry.recordClaimConfig(0);
    }

    function test_claimCannotBeRecordedWithoutSealedConfig() public {
        // No config sealed yet
        vm.expectRevert();
        registry.recordClaimConfig(1);
    }

    function test_sealCannotBeReplayedOnSameVersion() public {
        uint256 ver = _registerAndSeal(SALT_1, GOV_1, TREASURY_1);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.ConfigNotDraft.selector,
                block.chainid, ver
            )
        );
        registry.sealChainConfig(block.chainid, ver);
    }

    function test_cancelCannotBeReplayedOnCancelledDraft() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        vm.prank(guardian);
        registry.cancelDraft(block.chainid, ver);

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.ConfigNotDraft.selector,
                block.chainid, ver
            )
        );
        registry.cancelDraft(block.chainid, ver);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 5. BOUNDARY TESTS
// ═══════════════════════════════════════════════════════════════════════════════

contract ChainConfigBoundaryTest is ChainConfigTestBase {

    function test_maxAcceptedAssets() public {
        address[] memory assets = new address[](64);
        for (uint256 i = 0; i < 64; i++) {
            assets[i] = address(uint160(0xA000 + i + 1)); // non-zero
        }

        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            assets, FIN_BLOCKS, FIN_SECS
        );

        IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, ver);
        assertEq(cfg.acceptedAssets.length, 64);
    }

    function test_revert_exceedMaxAcceptedAssets() public {
        address[] memory assets = new address[](65);
        for (uint256 i = 0; i < 65; i++) {
            assets[i] = address(uint160(0xA000 + i + 1));
        }

        vm.prank(proposer);
        vm.expectRevert();
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            assets, FIN_BLOCKS, FIN_SECS
        );
    }

    function test_sealExactlyAtTimelockBoundary() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, ver);

        // Warp to exactly executeAfter (should succeed, >= comparison)
        vm.warp(cfg.executeAfter);

        vm.prank(executor);
        registry.sealChainConfig(block.chainid, ver);

        IChainConfigRegistry.ChainConfig memory sealedCfg = registry.getSealedConfig(block.chainid);
        assertEq(uint256(sealedCfg.status), uint256(IChainConfigRegistry.ConfigStatus.SEALED));
    }

    function test_revert_sealOneSecondBeforeTimelock() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, ver);

        // Warp to 1 second before executeAfter
        vm.warp(cfg.executeAfter - 1);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.TimelockNotExpired.selector,
                cfg.executeAfter
            )
        );
        registry.sealChainConfig(block.chainid, ver);
    }

    function test_versionCounterMonotonicallyIncreases() public {
        for (uint256 i = 1; i <= 5; i++) {
            bytes32 salt = keccak256(abi.encodePacked("salt-", i));
            address gov = address(uint160(0x6000 + i));
            vm.prank(proposer);
            uint256 ver = registry.registerChainConfig(
                block.chainid, salt, MANIFEST, gov, TREASURY_1,
                _defaultAssets(), FIN_BLOCKS, FIN_SECS
            );
            assertEq(ver, i, "Version should be monotonically increasing");
        }
        assertEq(registry.getLatestVersion(block.chainid), 5);
    }

    function test_maxFinalityValues() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), type(uint64).max, type(uint64).max
        );
        IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, ver);
        assertEq(cfg.finalityBlocks, type(uint64).max);
        assertEq(cfg.finalitySeconds, type(uint64).max);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 6. EVENT / STORAGE RECONCILIATION TESTS
// ═══════════════════════════════════════════════════════════════════════════════

contract ChainConfigEventTest is ChainConfigTestBase {

    function test_event_ChainConfigRegistered() public {
        uint256 expectedExecuteAfter = block.timestamp + registry.CONFIG_TIMELOCK();

        vm.expectEmit(true, true, true, true);
        emit IChainConfigRegistry.ChainConfigRegistered(
            block.chainid, 1, SALT_1, MANIFEST, GOV_1, proposer, expectedExecuteAfter
        );

        vm.prank(proposer);
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function test_event_ChainConfigSealed() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK());
        uint256 sealTime = block.timestamp;

        vm.expectEmit(true, true, false, true);
        emit IChainConfigRegistry.ChainConfigSealed(
            block.chainid, ver, sealTime, executor
        );

        vm.prank(executor);
        registry.sealChainConfig(block.chainid, ver);
    }

    function test_event_ChainConfigDeprecated() public {
        uint256 v1 = _registerAndSeal(SALT_1, GOV_1, TREASURY_1);

        vm.prank(proposer);
        uint256 v2 = registry.registerChainConfig(
            block.chainid, SALT_2, MANIFEST_2, GOV_2, TREASURY_2,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK());

        vm.expectEmit(true, true, false, true);
        emit IChainConfigRegistry.ChainConfigDeprecated(block.chainid, v1, v2);

        vm.prank(executor);
        registry.sealChainConfig(block.chainid, v2);
    }

    function test_event_ChainConfigCancelled() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        vm.expectEmit(true, true, true, true);
        emit IChainConfigRegistry.ChainConfigCancelled(block.chainid, ver, guardian);

        vm.prank(guardian);
        registry.cancelDraft(block.chainid, ver);
    }

    function test_event_ClaimLinkedToConfig() public {
        uint256 ver = _registerAndSeal(SALT_1, GOV_1, TREASURY_1);

        vm.expectEmit(true, true, true, true);
        emit ChainConfigRegistry.ClaimLinkedToConfig(42, block.chainid, ver);

        registry.recordClaimConfig(42);
    }

    function test_storageMatchesEventsAfterFullLifecycle() public {
        // Register
        vm.prank(proposer);
        uint256 v1 = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        // Verify draft state
        IChainConfigRegistry.ChainConfig memory draft = registry.getConfig(block.chainid, v1);
        assertEq(uint256(draft.status), uint256(IChainConfigRegistry.ConfigStatus.DRAFT));
        assertEq(draft.sealedAt, 0);

        // Seal
        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK());
        vm.prank(executor);
        registry.sealChainConfig(block.chainid, v1);

        // Verify sealed state matches
        IChainConfigRegistry.ChainConfig memory sealedCfg = registry.getSealedConfig(block.chainid);
        assertEq(uint256(sealedCfg.status), uint256(IChainConfigRegistry.ConfigStatus.SEALED));
        assertEq(sealedCfg.sealedAt, block.timestamp);
        assertEq(sealedCfg.chainId, block.chainid);
        assertEq(sealedCfg.salt, SALT_1);
        assertEq(sealedCfg.governance, GOV_1);
        assertEq(sealedCfg.treasury, TREASURY_1);
        assertTrue(registry.isGovernanceSealed(GOV_1));
        assertTrue(registry.isSaltUsed(SALT_1));

        // Register v2, seal it, verify v1 deprecated
        vm.prank(proposer);
        uint256 v2 = registry.registerChainConfig(
            block.chainid, SALT_2, MANIFEST_2, GOV_2, TREASURY_2,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK());
        vm.prank(executor);
        registry.sealChainConfig(block.chainid, v2);

        IChainConfigRegistry.ChainConfig memory deprecated = registry.getConfig(block.chainid, v1);
        assertEq(uint256(deprecated.status), uint256(IChainConfigRegistry.ConfigStatus.DEPRECATED));

        IChainConfigRegistry.ChainConfig memory newSealed = registry.getSealedConfig(block.chainid);
        assertEq(newSealed.configVersion, v2);
        assertEq(registry.getLatestVersion(block.chainid), v2);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 7. FUZZ TESTS (stateless)
// ═══════════════════════════════════════════════════════════════════════════════

contract ChainConfigFuzzTest is ChainConfigTestBase {

    function testFuzz_registerWithArbitrarySalt(bytes32 salt) public {
        // Skip zero-salt (if it happens to hash to zero, very unlikely but...)
        // salt itself is any value — only constraint is uniqueness
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, salt, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
        assertEq(ver, 1);
        assertTrue(registry.isSaltUsed(salt));
    }

    function testFuzz_registerWithArbitraryFinalitySettings(
        uint64 blocks,
        uint64 secs
    ) public {
        vm.assume(blocks > 0);
        vm.assume(secs > 0);

        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), blocks, secs
        );
        IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, ver);
        assertEq(cfg.finalityBlocks, blocks);
        assertEq(cfg.finalitySeconds, secs);
    }

    function testFuzz_registerRejectsFinalityZero(uint64 blocks, uint64 secs) public {
        // At least one must be zero
        vm.assume(blocks == 0 || secs == 0);

        vm.prank(proposer);
        vm.expectRevert(IChainConfigRegistry.InvalidFinalitySettings.selector);
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), blocks, secs
        );
    }

    function testFuzz_saltUniquenessEnforced(bytes32 salt) public {
        vm.prank(proposer);
        registry.registerChainConfig(
            block.chainid, salt, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(IChainConfigRegistry.SaltAlreadyUsed.selector, salt)
        );
        registry.registerChainConfig(
            block.chainid, salt, MANIFEST_2, GOV_2, TREASURY_2,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function testFuzz_chainIdMismatch(uint256 wrongChainId) public {
        vm.assume(wrongChainId != block.chainid);

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.ChainIdMismatch.selector,
                block.chainid,
                wrongChainId
            )
        );
        registry.registerChainConfig(
            wrongChainId, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    function testFuzz_registerWithArbitraryValidGovernance(address gov) public {
        vm.assume(gov != address(0));

        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, gov, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
        IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, ver);
        assertEq(cfg.governance, gov);
    }

    function testFuzz_sealTimelockRespected(uint256 warpDelta) public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, ver);
        uint256 timelockDelta = cfg.executeAfter - block.timestamp;

        // Bound warpDelta to be less than the timelock
        warpDelta = bound(warpDelta, 0, timelockDelta - 1);
        vm.warp(block.timestamp + warpDelta);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.TimelockNotExpired.selector,
                cfg.executeAfter
            )
        );
        registry.sealChainConfig(block.chainid, ver);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 8. INVARIANT TESTS (stateful fuzz with handler)
// ═══════════════════════════════════════════════════════════════════════════════

contract ChainConfigHandler is CommonBase {
    ChainConfigRegistry public registry;
    address public proposer;
    address public executor;
    address public guardian;

    uint256 public registrationCount;
    uint256 public sealCount;
    uint256 public cancelCount;

    // Track all salts used for invariant checks
    bytes32[] public usedSalts;
    // Track all governance addresses sealed
    address[] public sealedGovs;
    // Track registered versions
    uint256[] public registeredVersions;

    constructor(
        ChainConfigRegistry _registry,
        address _proposer,
        address _executor,
        address _guardian
    ) {
        registry = _registry;
        proposer = _proposer;
        executor = _executor;
        guardian = _guardian;
    }

    function registerConfig(uint256 seed) public {
        bytes32 salt = keccak256(abi.encodePacked("handler-salt-", registrationCount, seed));
        address gov = address(uint160(0x9000 + registrationCount + 1));
        address treasury = address(uint160(0x8000 + registrationCount + 1));

        address[] memory assets = new address[](1);
        assets[0] = address(uint160(0xA000 + registrationCount + 1));

        vm.prank(proposer);
        try registry.registerChainConfig(
            block.chainid, salt, keccak256(abi.encodePacked("manifest-", registrationCount)),
            gov, treasury, assets, 10, 600
        ) returns (uint256 ver) {
            registrationCount++;
            usedSalts.push(salt);
            registeredVersions.push(ver);
        } catch {
            // Registration may fail if gov already sealed etc.
        }
    }

    function sealConfig(uint256 versionSeed) public {
        if (registeredVersions.length == 0) return;

        uint256 ver = registeredVersions[versionSeed % registeredVersions.length];

        // Try to advance time and seal
        vm.warp(block.timestamp + 3 days);

        vm.prank(executor);
        try registry.sealChainConfig(block.chainid, ver) {
            sealCount++;
            IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, ver);
            sealedGovs.push(cfg.governance);
        } catch {
            // May fail if already sealed, cancelled, or timelock
        }
    }

    function cancelConfig(uint256 versionSeed) public {
        if (registeredVersions.length == 0) return;

        uint256 ver = registeredVersions[versionSeed % registeredVersions.length];

        vm.prank(guardian);
        try registry.cancelDraft(block.chainid, ver) {
            cancelCount++;
        } catch {
            // May fail if not a draft
        }
    }

    function getUsedSaltsCount() external view returns (uint256) {
        return usedSalts.length;
    }

    function getSealedGovsCount() external view returns (uint256) {
        return sealedGovs.length;
    }
}

contract ChainConfigInvariantTest is StdInvariant, Test {
    ChainConfigRegistry public registry;
    ChainConfigHandler  public handler;

    address internal admin    = address(0xAD01);
    address internal prop     = address(0xBE01);
    address internal exec     = address(0xCE01);
    address internal guard    = address(0xDE01);

    function setUp() public {
        registry = new ChainConfigRegistry(admin);

        vm.startPrank(admin);
        registry.grantRole(registry.CHAIN_CONFIG_PROPOSER_ROLE(), prop);
        registry.grantRole(registry.CHAIN_CONFIG_EXECUTOR_ROLE(), exec);
        registry.grantRole(registry.CHAIN_CONFIG_GUARDIAN_ROLE(), guard);
        vm.stopPrank();

        handler = new ChainConfigHandler(registry, prop, exec, guard);
        targetContract(address(handler));
    }

    /// @notice Salt uniqueness: every salt in the handler's tracking array is marked used.
    function invariant_allUsedSaltsAreMarked() public view {
        uint256 count = handler.getUsedSaltsCount();
        for (uint256 i = 0; i < count; i++) {
            assertTrue(registry.isSaltUsed(handler.usedSalts(i)));
        }
    }

    /// @notice Sealed governance addresses are unique: no two sealed configs share governance.
    function invariant_sealedGovernanceUnique() public view {
        uint256 count = handler.getSealedGovsCount();
        for (uint256 i = 0; i < count; i++) {
            assertTrue(registry.isGovernanceSealed(handler.sealedGovs(i)));
            for (uint256 j = i + 1; j < count; j++) {
                assertTrue(handler.sealedGovs(i) != handler.sealedGovs(j));
            }
        }
    }

    /// @notice Version counter is monotonically increasing and matches registration count.
    function invariant_versionCounterMatchesRegistrations() public view {
        assertEq(
            registry.getLatestVersion(block.chainid),
            handler.registrationCount()
        );
    }

    /// @notice The sealed version (if any) must have SEALED status.
    function invariant_sealedVersionHasSealedStatus() public view {
        uint256 latest = registry.getLatestVersion(block.chainid);
        if (latest == 0) return;

        try registry.getSealedConfig(block.chainid) returns (
            IChainConfigRegistry.ChainConfig memory cfg
        ) {
            assertEq(uint256(cfg.status), uint256(IChainConfigRegistry.ConfigStatus.SEALED));
            assertGt(cfg.sealedAt, 0);
            assertEq(cfg.chainId, block.chainid);
        } catch {
            // No sealed config yet — that's fine
        }
    }

    /// @notice CONFIG_TIMELOCK is always 2 days.
    function invariant_timelockConstant() public view {
        assertEq(registry.CONFIG_TIMELOCK(), 2 days);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 9. REGRESSION: Displaced audit defects
// ═══════════════════════════════════════════════════════════════════════════════

contract ChainConfigRegressionTest is ChainConfigTestBase {

    /// @notice Regression: zero-address governance must never be accepted.
    ///         (Displaced: cross-chain zero-address injection defect pattern.)
    function test_regression_zeroGovernanceNeverAccepted() public {
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.GovernanceAddressConflict.selector,
                address(0)
            )
        );
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, address(0), TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
    }

    /// @notice Regression: cancelled drafts must not be sealable.
    ///         (Displaced: fail-open cancellation bypass.)
    function test_regression_cancelledDraftCannotBeSealed() public {
        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        vm.prank(guardian);
        registry.cancelDraft(block.chainid, ver);

        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK());

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.ConfigNotDraft.selector,
                block.chainid, ver
            )
        );
        registry.sealChainConfig(block.chainid, ver);
    }

    /// @notice Regression: deprecated versions must not be re-sealed.
    ///         (Displaced: status downgrade replay attack.)
    function test_regression_deprecatedVersionCannotBeResealed() public {
        uint256 v1 = _registerAndSeal(SALT_1, GOV_1, TREASURY_1);

        // Seal v2 to deprecate v1
        vm.prank(proposer);
        uint256 v2 = registry.registerChainConfig(
            block.chainid, SALT_2, MANIFEST_2, GOV_2, TREASURY_2,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );
        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK());
        vm.prank(executor);
        registry.sealChainConfig(block.chainid, v2);

        // Attempt to re-seal v1
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainConfigRegistry.ConfigNotDraft.selector,
                block.chainid, v1
            )
        );
        registry.sealChainConfig(block.chainid, v1);
    }

    /// @notice Regression: asset list with zero address in any position is rejected.
    ///         (Displaced: zero-address token acceptance leading to failed transfers.)
    function test_regression_zeroAddressInAssetListRejected() public {
        // Zero in first position
        address[] memory a1 = new address[](1);
        a1[0] = address(0);
        vm.prank(proposer);
        vm.expectRevert(IChainConfigRegistry.InvalidAssetList.selector);
        registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            a1, FIN_BLOCKS, FIN_SECS
        );

        // Zero in middle
        address[] memory a2 = new address[](3);
        a2[0] = ASSET_A;
        a2[1] = address(0);
        a2[2] = ASSET_B;
        vm.prank(proposer);
        vm.expectRevert(IChainConfigRegistry.InvalidAssetList.selector);
        registry.registerChainConfig(
            block.chainid, SALT_2, MANIFEST, GOV_1, TREASURY_1,
            a2, FIN_BLOCKS, FIN_SECS
        );
    }

    /// @notice Regression: timelocked operations cannot be front-run to skip the delay.
    function test_regression_timelockCannotBeSkipped() public {
        uint256 startTime = block.timestamp;

        vm.prank(proposer);
        uint256 ver = registry.registerChainConfig(
            block.chainid, SALT_1, MANIFEST, GOV_1, TREASURY_1,
            _defaultAssets(), FIN_BLOCKS, FIN_SECS
        );

        // Timelock must enforce the minimum CONFIG_TIMELOCK delay
        IChainConfigRegistry.ChainConfig memory cfg = registry.getConfig(block.chainid, ver);
        assertGe(cfg.executeAfter, startTime + registry.CONFIG_TIMELOCK());

        // Cannot seal at current time
        vm.prank(executor);
        vm.expectRevert();
        registry.sealChainConfig(block.chainid, ver);
    }

    /// @notice Regression: sealed config immutability — fields cannot change after seal.
    function test_regression_sealedConfigImmutable() public {
        uint256 ver = _registerAndSeal(SALT_1, GOV_1, TREASURY_1);

        IChainConfigRegistry.ChainConfig memory before_ = registry.getConfig(block.chainid, ver);

        // Try any further mutation on the sealed version (only option is seal/cancel — both must fail)
        vm.prank(executor);
        vm.expectRevert();
        registry.sealChainConfig(block.chainid, ver);

        vm.prank(guardian);
        vm.expectRevert();
        registry.cancelDraft(block.chainid, ver);

        // Verify state unchanged
        IChainConfigRegistry.ChainConfig memory after_ = registry.getConfig(block.chainid, ver);
        assertEq(after_.salt, before_.salt);
        assertEq(after_.governance, before_.governance);
        assertEq(after_.treasury, before_.treasury);
        assertEq(after_.manifestHash, before_.manifestHash);
        assertEq(uint256(after_.status), uint256(before_.status));
        assertEq(after_.sealedAt, before_.sealedAt);
    }
}
