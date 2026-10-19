// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import "../../contracts/v2/ModuleRegistry.sol";
import "../../contracts/v2/libraries/ModuleRegistryLib.sol";
import "../../contracts/v2/libraries/V2Errors.sol";
import "../../contracts/v2/interfaces/IV2Module.sol";
import "../../contracts/v2/interfaces/IConfiguration.sol";
import "../../contracts/v2/interfaces/IClaims.sol";
import "../../contracts/v2/interfaces/IEvidence.sol";
import "../../contracts/v2/interfaces/IStakeCustody.sol";
import "../../contracts/v2/interfaces/IVerification.sol";
import "../../contracts/v2/interfaces/IAggregation.sol";
import "../../contracts/v2/interfaces/ISettlement.sol";
import "../../contracts/v2/interfaces/IDisputes.sol";
import "../../contracts/v2/interfaces/IRewards.sol";
import "../../contracts/v2/interfaces/ISlashing.sol";
import "../../contracts/v2/interfaces/ITreasury.sol";
import "../../contracts/v2/interfaces/IReputationRoots.sol";
import "../../contracts/v2/interfaces/IGovernanceHooks.sol";
import "../../contracts/v2/interfaces/IEmergencyControls.sol";
import "../../contracts/v2/interfaces/V2ConformanceFixture.sol";
import "../../contracts/mocks/MockV2Module.sol";

contract ModuleRegistryTest is Test {
    ModuleRegistry internal registry;
    MockV2Module internal module;

    address internal deployer = address(this);
    address internal governance = makeAddr("governance");
    address internal guardian = makeAddr("guardian");
    address internal random = makeAddr("random");

    bytes32 internal constant UNKNOWN_ID = keccak256("NOT_CANONICAL");

    function setUp() public {
        registry = new ModuleRegistry(deployer, governance, guardian);
    }

    function _regVers(bytes32 moduleId, MockV2Module proxy, uint16 major, uint16 minor)
        internal
        pure
        returns (IModuleRegistry.ModuleRegistration memory)
    {
        return IModuleRegistry.ModuleRegistration({
            moduleId: moduleId,
            interfaceId: ModuleRegistryLib.canonicalInterfaceOf(moduleId),
            proxy: address(proxy),
            implementation: address(0),
            major: major,
            minor: minor
        });
    }

    function _reg(bytes32 moduleId, MockV2Module proxy)
        internal
        pure
        returns (IModuleRegistry.ModuleRegistration memory)
    {
        return _regVers(moduleId, proxy, 2, 0);
    }

    function _fresh(bytes32 moduleId, uint16 major, uint16 minor) internal returns (MockV2Module) {
        return new MockV2Module(major, minor, ModuleRegistryLib.canonicalInterfaceOf(moduleId));
    }

    function _registerAndActivate(bytes32 moduleId, MockV2Module proxy) internal {
        registry.registerModule(_reg(moduleId, proxy));
        registry.activateModule(moduleId);
    }

    // =========================================================================
    // Registration & authorization
    // =========================================================================

    function test_register_emitsVersionedEvent_andStoresRecord() public {
        bytes32 moduleId = ModuleRegistryLib.MODULE_CLAIMS;
        module = _fresh(moduleId, 2, 0);

        bytes32 expected = registry.versionIdOf(_reg(moduleId, module));

        vm.expectEmit();
        emit IModuleRegistry.ModuleRegistered(moduleId, expected, address(module), address(0), 2, 0, registry.canonicalInterfaceOf(moduleId));
        registry.registerModule(_reg(moduleId, module));

        IModuleRegistry.ModuleInfo memory info = registry.getModule(moduleId);
        assertEq(info.versionId, expected);
        assertEq(info.proxy, address(module));
        assertEq(uint256(info.status), uint256(IModuleRegistry.ModuleStatus.REGISTERED));
        assertFalse(registry.isRegistered(moduleId));
        assertEq(registry.moduleCount(), 1);
        assertEq(registry.getRegisteredKeys().length, 1);
        assertEq(uint256(registry.moduleStatus(moduleId)), uint256(IModuleRegistry.ModuleStatus.REGISTERED));
    }

    function test_register_requiresDeploymentRole() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        bytes32 deploymentRole = registry.DEPLOYMENT_ROLE();
        MockV2Module module = _fresh(claims, 2, 0);
        IModuleRegistry.ModuleRegistration memory registration = _reg(claims, module);
        vm.prank(random);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, random, deploymentRole)
        );
        registry.registerModule(registration);
    }

    function test_activate_requiresDeploymentRole() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        registry.registerModule(_reg(claims, _fresh(claims, 2, 0)));
        bytes32 deploymentRole = registry.DEPLOYMENT_ROLE();
        vm.prank(random);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, random, deploymentRole)
        );
        registry.activateModule(claims);
    }

    function test_registerModules_registersBatch() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        bytes32 evidence = ModuleRegistryLib.MODULE_EVIDENCE;
        MockV2Module a = _fresh(claims, 2, 0);
        MockV2Module b = _fresh(evidence, 2, 0);

        IModuleRegistry.ModuleRegistration[] memory regs = new IModuleRegistry.ModuleRegistration[](2);
        regs[0] = _reg(claims, a);
        regs[1] = _reg(evidence, b);

        bytes32[] memory versionIds = registry.registerModules(regs);
        assertEq(versionIds.length, 2);
        assertEq(registry.moduleCount(), 2);
        assertEq(uint256(registry.moduleStatus(claims)), uint256(IModuleRegistry.ModuleStatus.REGISTERED));
        assertEq(uint256(registry.moduleStatus(evidence)), uint256(IModuleRegistry.ModuleStatus.REGISTERED));
    }

    function test_registerModules_rejectsBatchAbovePublishedLimit() public {
        IModuleRegistry.ModuleRegistration[] memory regs = new IModuleRegistry.ModuleRegistration[](
            registry.MAX_REGISTRY_BATCH_SIZE() + 1
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.RegistryBatchTooLarge.selector,
                regs.length,
                registry.MAX_REGISTRY_BATCH_SIZE()
            )
        );
        registry.registerModules(regs);
    }

    function test_registerModules_atomicBatch_revertsEverything() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        MockV2Module a = _fresh(claims, 2, 0);
        MockV2Module b = _fresh(UNKNOWN_ID, 2, 0);

        IModuleRegistry.ModuleRegistration[] memory regs = new IModuleRegistry.ModuleRegistration[](2);
        regs[0] = _reg(claims, a);
        regs[1] = _reg(UNKNOWN_ID, b);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownModuleId.selector, UNKNOWN_ID));
        registry.registerModules(regs);

        assertEq(registry.moduleCount(), 0, "atomic batch must not partially register");
    }

    // =========================================================================
    // Activation & dependency resolution
    // =========================================================================

    function test_activateEvents_marksActive() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        module = _fresh(claims, 2, 0);
        registry.registerModule(_reg(claims, module));

        vm.expectEmit();
        emit IModuleRegistry.ModuleActivated(claims, registry.versionIdOf(_reg(claims, module)), address(module));
        registry.activateModule(claims);

        assertTrue(registry.isRegistered(claims));
        assertTrue(registry.isActive(claims));
        assertEq(uint256(registry.moduleStatus(claims)), uint256(IModuleRegistry.ModuleStatus.ACTIVE));
        (address proxy, uint16 major, uint16 minor) = registry.module(claims);
        assertEq(proxy, address(module));
        assertEq(uint256(major), 2);
        assertEq(uint256(minor), 0);
    }

    function test_activate_requiresDependencyActive() public {
        bytes32 aggregation = ModuleRegistryLib.MODULE_AGGREGATION;
        module = _fresh(aggregation, 2, 0);
        registry.registerModule(_reg(aggregation, module));

        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.DependencyUnsatisfied.selector, aggregation, ModuleRegistryLib.MODULE_VERIFICATION)
        );
        registry.activateModule(aggregation);
    }

    function test_activate_dependenciesMeta_reverts() public {
        bytes32 verification = ModuleRegistryLib.MODULE_VERIFICATION;
        module = _fresh(verification, 2, 0);
        registry.registerModule(_reg(verification, module));

        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.DependencyUnsatisfied.selector, verification, ModuleRegistryLib.MODULE_CLAIMS
            )
        );
        registry.activateModule(verification);
    }

    function test_activateModules_resolvesIntraBatchDependencies() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        bytes32 evidence = ModuleRegistryLib.MODULE_EVIDENCE;
        bytes32 custody = ModuleRegistryLib.MODULE_STAKE_CUSTODY;
        bytes32 verification = ModuleRegistryLib.MODULE_VERIFICATION;

        IModuleRegistry.ModuleRegistration[] memory regs = new IModuleRegistry.ModuleRegistration[](4);
        regs[0] = _reg(claims, _fresh(claims, 2, 0));
        regs[1] = _reg(evidence, _fresh(evidence, 2, 0));
        regs[2] = _reg(custody, _fresh(custody, 2, 0));
        regs[3] = _reg(verification, _fresh(verification, 2, 0));
        registry.registerModules(regs);

        bytes32[] memory batch = new bytes32[](4);
        batch[0] = verification;
        batch[1] = claims;
        batch[2] = evidence;
        batch[3] = custody;
        registry.activateModules(batch);

        assertTrue(registry.isRegistered(verification));
        assertTrue(registry.isRegistered(claims));
        assertTrue(registry.isRegistered(evidence));
        assertTrue(registry.isRegistered(custody));
    }

    function test_activateModules_atomic_revertsAndLeavesFirstUnactive() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        bytes32 aggregation = ModuleRegistryLib.MODULE_AGGREGATION;

        IModuleRegistry.ModuleRegistration[] memory regs = new IModuleRegistry.ModuleRegistration[](2);
        regs[0] = _reg(claims, _fresh(claims, 2, 0));
        regs[1] = _reg(aggregation, _fresh(aggregation, 2, 0));
        registry.registerModules(regs);

        bytes32[] memory batch = new bytes32[](2);
        batch[0] = claims;
        batch[1] = aggregation;

        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.DependencyUnsatisfied.selector, aggregation, ModuleRegistryLib.MODULE_VERIFICATION
            )
        );
        registry.activateModules(batch);

        assertEq(
            uint256(registry.moduleStatus(claims)), uint256(IModuleRegistry.ModuleStatus.REGISTERED),
            "claims must not be written when the batch fails"
        );
        assertEq(
            uint256(registry.moduleStatus(aggregation)), uint256(IModuleRegistry.ModuleStatus.REGISTERED),
            "aggregation must not be written when the batch fails"
        );
    }

    function test_activateModules_atomic_multipleUnsat() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        bytes32 verification = ModuleRegistryLib.MODULE_STAKE_CUSTODY; // no canonical deps
        bytes32 evidence = ModuleRegistryLib.MODULE_EVIDENCE;
        bytes32 aggregation = ModuleRegistryLib.MODULE_AGGREGATION;

        IModuleRegistry.ModuleRegistration[] memory regs = new IModuleRegistry.ModuleRegistration[](4);
        regs[0] = _reg(claims, _fresh(claims, 2, 0));
        regs[1] = _reg(verification, _fresh(verification, 2, 0));
        regs[2] = _reg(evidence, _fresh(evidence, 2, 0));
        regs[3] = _reg(aggregation, _fresh(aggregation, 2, 0));
        registry.registerModules(regs);

        bytes32[] memory batch = new bytes32[](4);
        batch[0] = claims;
        batch[1] = verification;
        batch[2] = evidence;
        batch[3] = aggregation;

        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.DependencyUnsatisfied.selector, aggregation, ModuleRegistryLib.MODULE_VERIFICATION
            )
        );
        registry.activateModules(batch);

        assertFalse(registry.isRegistered(claims));
        assertFalse(registry.isRegistered(verification));
        assertFalse(registry.isRegistered(evidence));
    }

    // =========================================================================
    // Invalid keys / addresses (incl. fuzz)
    // =========================================================================

    function test_unknownModuleId_reverts() public {
        MockV2Module m = _fresh(UNKNOWN_ID, 2, 0);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownModuleId.selector, UNKNOWN_ID));
        registry.registerModule(_reg(UNKNOWN_ID, m));
    }

    function test_eoaProxy_reverts() public {
        address eoa = makeAddr("eoa");
        IModuleRegistry.ModuleRegistration memory registration = _reg(ModuleRegistryLib.MODULE_CLAIMS, _fresh(ModuleRegistryLib.MODULE_CLAIMS, 2, 0));
        registration.proxy = eoa;
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ModuleNotAContract.selector, eoa));
        registry.registerModule(registration);
    }

    function test_zeroProxy_reverts() public {
        IModuleRegistry.ModuleRegistration memory registration = _reg(ModuleRegistryLib.MODULE_CLAIMS, _fresh(ModuleRegistryLib.MODULE_CLAIMS, 2, 0));
        registration.proxy = address(0);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ModuleNotAContract.selector, address(0)));
        registry.registerModule(registration);
    }

    function test_selfRegistration_reverts() public {
        IModuleRegistry.ModuleRegistration memory registration = _reg(ModuleRegistryLib.MODULE_CLAIMS, _fresh(ModuleRegistryLib.MODULE_CLAIMS, 2, 0));
        registration.proxy = address(registry);
        vm.expectRevert(V2Errors.SelfRegistration.selector);
        registry.registerModule(registration);
    }

    function test_duplicateProxy_reverts() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        bytes32 evidence = ModuleRegistryLib.MODULE_EVIDENCE;
        MockV2Module shared = _fresh(claims, 2, 0);
        registry.registerModule(_reg(claims, shared));

        IModuleRegistry.ModuleRegistration memory registration = _reg(evidence, shared);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.DuplicateProxy.selector, address(shared)));
        registry.registerModule(registration);
    }

    function testFuzz_unknownModuleId_reverts(bytes32 moduleId, uint16 major, uint16 minor) public {
        vm.assume(!ModuleRegistryLib.isCanonicalKey(moduleId));
        MockV2Module m = new MockV2Module(major, minor, registry.canonicalInterfaceOf(ModuleRegistryLib.MODULE_CLAIMS));
        IModuleRegistry.ModuleRegistration memory registration = _reg(ModuleRegistryLib.MODULE_CLAIMS, m);
        registration.moduleId = moduleId;
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnknownModuleId.selector, moduleId));
        registry.registerModule(registration);
    }

    function testFuzz_eoaAddress_reverts(address proxy) public {
        vm.assume(proxy != address(0));
        vm.assume(proxy != address(registry));
        vm.assume(proxy.code.length == 0);
        vm.assume(!registry.isForbidden(proxy));
        IModuleRegistry.ModuleRegistration memory registration = _reg(ModuleRegistryLib.MODULE_CLAIMS, _fresh(ModuleRegistryLib.MODULE_CLAIMS, 2, 0));
        registration.proxy = proxy;
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ModuleNotAContract.selector, proxy));
        registry.registerModule(registration);
    }

    // =========================================================================
    // Interface & version integrity
    // =========================================================================

    function test_interfaceMismatch_reverts() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        bytes32 evidence = ModuleRegistryLib.MODULE_EVIDENCE;
        // Module implementing CLAIMS interface registered under the EVIDENCE key.
        MockV2Module wrong = new MockV2Module(2, 0, ModuleRegistryLib.canonicalInterfaceOf(claims));
        IModuleRegistry.ModuleRegistration memory registration = _reg(evidence, wrong);

        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.ModuleInterfaceMismatch.selector,
                registry.canonicalInterfaceOf(evidence),
                bytes4(0)
            )
        );
        registry.registerModule(registration);
    }

    function test_versionMajorMismatch_reverts() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        MockV2Module old = new MockV2Module(1, 0, registry.canonicalInterfaceOf(claims));
        IModuleRegistry.ModuleRegistration memory registration = _reg(claims, old);
        registration.major = 1;

        vm.expectRevert(abi.encodeWithSelector(V2Errors.ModuleVersionMismatch.selector, 1, 2));
        registry.registerModule(registration);
    }

    function test_declaredVersionMismatch_reverts() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        MockV2Module module2_0 = _fresh(claims, 2, 0);
        IModuleRegistry.ModuleRegistration memory registration = _reg(claims, module2_0);
        registration.minor = 5;

        vm.expectRevert(abi.encodeWithSelector(V2Errors.DeclaredVersionMismatch.selector, 2, 5, 2, 0));
        registry.registerModule(registration);
    }

    // =========================================================================
    // Forbidden legacy + deprecation + regression vs the legacy stub
    // =========================================================================

    function test_forbidModule_thenRegisterReverts() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        MockV2Module legacy = _fresh(claims, 2, 0);
        vm.prank(governance);
        registry.forbidModule(address(legacy));

        IModuleRegistry.ModuleRegistration memory registration = _reg(claims, legacy);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ForbiddenModule.selector, address(legacy)));
        registry.registerModule(registration);
    }

    function test_unforbidModule_permitsRegistration() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        MockV2Module legacy = _fresh(claims, 2, 0);
        vm.prank(governance);
        registry.forbidModule(address(legacy));
        vm.prank(governance);
        registry.unforbidModule(address(legacy));

        registry.registerModule(_reg(claims, legacy));
        assertEq(registry.moduleCount(), 1);
    }

    function test_Regression_legacyPermissiveRegistrationNowRejected() public {
        // The pre-V2-SC-005 stub accepted any address with zero validation.
        // None of these may succeed on the real registry.
        bytes32 slashing = ModuleRegistryLib.MODULE_SLASHING;
        address eoa = makeAddr("eoa");
        IModuleRegistry.ModuleRegistration memory eoaReg = _reg(slashing, _fresh(slashing, 2, 0));
        eoaReg.proxy = eoa;
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ModuleNotAContract.selector, eoa));
        registry.registerModule(eoaReg);

        IModuleRegistry.ModuleRegistration memory zeroReg = _reg(slashing, _fresh(slashing, 2, 0));
        zeroReg.proxy = address(0);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ModuleNotAContract.selector, address(0)));
        registry.registerModule(zeroReg);

        IModuleRegistry.ModuleRegistration memory selfReg = _reg(slashing, _fresh(slashing, 2, 0));
        selfReg.proxy = address(registry);
        vm.expectRevert(V2Errors.SelfRegistration.selector);
        registry.registerModule(selfReg);
    }

    function test_deprecate_blocksFutureActivationAndRegistration() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        MockV2Module v1 = _fresh(claims, 2, 0);
        _registerAndActivate(claims, v1);
        assertTrue(registry.isRegistered(claims));

        vm.prank(governance);
        registry.deprecateModule(claims);

        assertTrue(registry.isDeprecated(claims));
        assertEq(uint256(registry.moduleStatus(claims)), uint256(IModuleRegistry.ModuleStatus.DEPRECATED));
        assertFalse(registry.isRegistered(claims), "deprecated module must not count as registered");

        vm.expectRevert(abi.encodeWithSelector(V2Errors.DeprecatedModule.selector, claims));
        registry.activateModule(claims);

        MockV2Module v2 = _fresh(claims, 2, 0);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.DeprecatedModule.selector, claims));
        registry.registerModule(_reg(claims, v2));
    }

    function test_deprecateModule_requiresGovernance() public {
        bytes32 governanceRole = registry.GOVERNANCE_ROLE();
        vm.prank(random);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, random, governanceRole)
        );
        registry.deprecateModule(ModuleRegistryLib.MODULE_CLAIMS);
    }

    // =========================================================================
    // Guarded roles
    // =========================================================================

    function test_guardianCannotMutateRegistry() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        MockV2Module v1 = _fresh(claims, 2, 0);
        registry.registerModule(_reg(claims, v1));
        registry.activateModule(claims);

        MockV2Module evidenceModule = _fresh(ModuleRegistryLib.MODULE_EVIDENCE, 2, 0);
        IModuleRegistry.ModuleRegistration memory evidenceReg = _reg(ModuleRegistryLib.MODULE_EVIDENCE, evidenceModule);
        MockV2Module newClaims = _fresh(claims, 2, 1);
        IModuleRegistry.ModuleRegistration memory replacement = _regVers(claims, newClaims, 2, 1);

        registry.grantRole(registry.DEPLOYMENT_ROLE(), guardian);
        registry.grantRole(registry.GOVERNANCE_ROLE(), guardian);

        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.GuardianCannotReplaceModule.selector, guardian));
        registry.registerModule(evidenceReg);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.GuardianCannotReplaceModule.selector, guardian));
        registry.activateModule(claims);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.GuardianCannotReplaceModule.selector, guardian));
        registry.proposeModuleReplacement(replacement);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.GuardianCannotReplaceModule.selector, guardian));
        registry.deprecateModule(claims);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.GuardianCannotReplaceModule.selector, guardian));
        registry.removeModule(claims);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.GuardianCannotReplaceModule.selector, guardian));
        registry.forbidModule(random);
        vm.stopPrank();
    }

    // =========================================================================
    // Timelocked replacement
    // =========================================================================

    function test_replace_requiresGovernanceRole() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        _registerAndActivate(claims, _fresh(claims, 2, 0));

        IModuleRegistry.ModuleRegistration memory replacement = _reg(claims, _fresh(claims, 2, 1));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, registry.GOVERNANCE_ROLE())
        );
        registry.proposeModuleReplacement(replacement);
    }

    function test_replace_timelockProposeAndActivate() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        MockV2Module v1 = _fresh(claims, 2, 0);
        _registerAndActivate(claims, v1);
        bytes32 oldVersion = registry.versionIdOf(_reg(claims, v1));

        MockV2Module v2 = _fresh(claims, 2, 1);
        IModuleRegistry.ModuleRegistration memory replacement = _regVers(claims, v2, 2, 1);
        bytes32 newVersion = registry.versionIdOf(replacement);

        vm.prank(governance);
        registry.proposeModuleReplacement(replacement);

        uint256 readyAt = registry.replacementReadyAt(claims);
        assertEq(readyAt, block.timestamp + ModuleRegistryLib.REPLACEMENT_DELAY);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.ReplacementNotReady.selector, claims, readyAt));
        registry.activateModuleReplacement(claims);

        vm.warp(readyAt);

        vm.prank(random); // permissionless after the timelock
        registry.activateModuleReplacement(claims);

        (address proxy,, uint16 minor) = registry.module(claims);
        assertEq(proxy, address(v2));
        assertEq(uint256(minor), 1);
        (bytes32 currentVersion,,) = registry.versionOf(claims);
        assertEq(currentVersion, newVersion);
        assertTrue(newVersion != oldVersion);
        assertEq(registry.replacementReadyAt(claims), 0);
        assertTrue(registry.isRegistered(claims));
        assertTrue(v2.supportsInterface(type(IV2Module).interfaceId));
        assertTrue(v2.supportsInterface(type(IClaims).interfaceId));
        assertFalse(v2.supportsInterface(type(IEvidence).interfaceId));
    }

    function test_replace_rejectsImplementationThatDropsCanonicalInterface() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        _registerAndActivate(claims, _fresh(claims, 2, 0));

        MockV2Module incompatible = new MockV2Module(2, 1, type(IEvidence).interfaceId);
        IModuleRegistry.ModuleRegistration memory replacement = _regVers(claims, incompatible, 2, 1);

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.ModuleInterfaceMismatch.selector,
                type(IClaims).interfaceId,
                bytes4(0)
            )
        );
        registry.proposeModuleReplacement(replacement);
    }

    function test_fixtureReportsOnlyItsDeclaredInterfaces() public {
        V2ConformanceFixture fixture = new V2ConformanceFixture();

        assertTrue(fixture.supportsInterface(0x01ffc9a7));
        assertTrue(fixture.supportsInterface(type(IV2Module).interfaceId));
        assertTrue(fixture.supportsInterface(type(IClaims).interfaceId));
        assertTrue(fixture.supportsInterface(type(IAggregation).interfaceId));
        assertFalse(fixture.supportsInterface(type(IEvidence).interfaceId));
        assertFalse(fixture.supportsInterface(0xffffffff));
    }

    function test_registryReportsItsExpectedDiscoveryInterfaces() public view {
        assertTrue(registry.supportsInterface(type(IModuleRegistry).interfaceId));
        assertTrue(registry.supportsInterface(type(IV2Module).interfaceId));
        assertTrue(registry.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(registry.supportsInterface(0x01ffc9a7));
        assertFalse(registry.supportsInterface(type(IClaims).interfaceId));
        assertFalse(registry.supportsInterface(0xffffffff));
    }

    function test_replace_noopRejected() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        MockV2Module v1 = _fresh(claims, 2, 0);
        _registerAndActivate(claims, v1);

        IModuleRegistry.ModuleRegistration memory identical = _reg(claims, v1);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ReplacementNoop.selector, claims));
        registry.proposeModuleReplacement(identical);
    }

    function test_replace_cancelBeforeReady() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        MockV2Module v1 = _fresh(claims, 2, 0);
        _registerAndActivate(claims, v1);

        IModuleRegistry.ModuleRegistration memory replacement = _regVers(claims, _fresh(claims, 2, 1), 2, 1);
        vm.prank(governance);
        registry.proposeModuleReplacement(replacement);
        assertGt(registry.replacementReadyAt(claims), 0);

        vm.prank(governance);
        registry.cancelModuleReplacement(claims);
        assertEq(registry.replacementReadyAt(claims), 0);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.ReplacementNotPending.selector, claims));
        registry.activateModuleReplacement(claims);
    }

    function test_replace_cancelNotPending_reverts() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ReplacementNotPending.selector, ModuleRegistryLib.MODULE_CLAIMS));
        registry.cancelModuleReplacement(ModuleRegistryLib.MODULE_CLAIMS);
    }

    function test_replace_revalidatesNewProxy() public {
        // Replacing onto a proxy that fails validation must revert at propose time.
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        MockV2Module v1 = _fresh(claims, 2, 0);
        _registerAndActivate(claims, v1);

        address eoa = makeAddr("new-proxy-eoa");
        IModuleRegistry.ModuleRegistration memory bad = _regVers(claims, _fresh(claims, 2, 1), 2, 1);
        bad.proxy = eoa;

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ModuleNotAContract.selector, eoa));
        registry.proposeModuleReplacement(bad);
    }

    // =========================================================================
    // Canonical manifest views
    // =========================================================================

    function test_canonicalManifest_interfaceIdsMatchAbi() public view {
        bytes32[] memory ids = registry.canonicalModuleIds();
        assertEq(ids.length, 14);

        assertEq(registry.canonicalInterfaceOf(ids[0]), type(IConfiguration).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[1]), type(IClaims).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[2]), type(IEvidence).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[3]), type(IStakeCustody).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[4]), type(IVerification).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[5]), type(IAggregation).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[6]), type(ISettlement).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[7]), type(IDisputes).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[8]), type(IRewards).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[9]), type(ISlashing).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[10]), type(ITreasury).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[11]), type(IReputationRoots).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[12]), type(IGovernanceHooks).interfaceId);
        assertEq(registry.canonicalInterfaceOf(ids[13]), type(IEmergencyControls).interfaceId);

        assertEq(registry.canonicalInterfaceOf(UNKNOWN_ID), bytes4(0));
    }

    function test_canonicalDependencies_manifest() public view {
        IModuleRegistry.Dependency[] memory edges = registry.canonicalDependencies();
        assertEq(edges.length, 11);

        assertEq(edges[0].moduleId, ModuleRegistryLib.MODULE_EVIDENCE);
        assertEq(edges[0].requiredModuleId, ModuleRegistryLib.MODULE_CLAIMS);
        assertEq(edges[1].moduleId, ModuleRegistryLib.MODULE_VERIFICATION);
        assertEq(edges[1].requiredModuleId, ModuleRegistryLib.MODULE_CLAIMS);
        assertEq(edges[2].moduleId, ModuleRegistryLib.MODULE_VERIFICATION);
        assertEq(edges[2].requiredModuleId, ModuleRegistryLib.MODULE_EVIDENCE);
        assertEq(edges[3].moduleId, ModuleRegistryLib.MODULE_VERIFICATION);
        assertEq(edges[3].requiredModuleId, ModuleRegistryLib.MODULE_STAKE_CUSTODY);
        assertEq(edges[4].moduleId, ModuleRegistryLib.MODULE_AGGREGATION);
        assertEq(edges[4].requiredModuleId, ModuleRegistryLib.MODULE_VERIFICATION);
        assertEq(edges[5].moduleId, ModuleRegistryLib.MODULE_SETTLEMENT);
        assertEq(edges[5].requiredModuleId, ModuleRegistryLib.MODULE_AGGREGATION);
        assertEq(edges[6].moduleId, ModuleRegistryLib.MODULE_SETTLEMENT);
        assertEq(edges[6].requiredModuleId, ModuleRegistryLib.MODULE_STAKE_CUSTODY);
        assertEq(edges[7].moduleId, ModuleRegistryLib.MODULE_DISPUTES);
        assertEq(edges[7].requiredModuleId, ModuleRegistryLib.MODULE_CLAIMS);
        assertEq(edges[8].moduleId, ModuleRegistryLib.MODULE_DISPUTES);
        assertEq(edges[8].requiredModuleId, ModuleRegistryLib.MODULE_VERIFICATION);
        assertEq(edges[9].moduleId, ModuleRegistryLib.MODULE_REWARDS);
        assertEq(edges[9].requiredModuleId, ModuleRegistryLib.MODULE_SETTLEMENT);
        assertEq(edges[10].moduleId, ModuleRegistryLib.MODULE_REWARDS);
        assertEq(edges[10].requiredModuleId, ModuleRegistryLib.MODULE_TREASURY);
    }

    // =========================================================================
    // Preflight views
    // =========================================================================

    function test_preflightRegistration_validReturnsOk() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        MockV2Module m = _fresh(claims, 2, 0);
        IModuleRegistry.PreflightResult memory result = registry.preflightRegistration(_reg(claims, m));
        assertTrue(result.ok);
        assertEq(result.errorCode, bytes32(0));
        assertEq(result.canonicalInterfaceId, registry.canonicalInterfaceOf(claims));
    }

    function test_preflightRegistration_neverRevertsOnBadInput() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        IModuleRegistry.ModuleRegistration memory registration = _reg(claims, _fresh(claims, 2, 0));
        registration.proxy = makeAddr("eoa");
        IModuleRegistry.PreflightResult memory result = registry.preflightRegistration(registration);
        assertFalse(result.ok);
        assertEq(result.errorCode, "NOT_A_CONTRACT");
    }

    function test_preflightRegistration_declaredVersionCode() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        IModuleRegistry.ModuleRegistration memory registration = _reg(claims, _fresh(claims, 2, 0));
        registration.minor = 9;
        IModuleRegistry.PreflightResult memory result = registry.preflightRegistration(registration);
        assertFalse(result.ok);
        assertEq(result.errorCode, "DECLARED_VERSION");
    }

    function test_preflightActivation_reportsUnsatisfiedDependency() public {
        bytes32 aggregation = ModuleRegistryLib.MODULE_AGGREGATION;
        registry.registerModule(_reg(aggregation, _fresh(aggregation, 2, 0)));
        IModuleRegistry.PreflightResult memory result = registry.preflightActivation(aggregation);
        assertFalse(result.ok);
        assertEq(result.errorCode, "DEPENDENCY");
    }

    function test_preflightActivation_alreadyActive() public {
        bytes32 claims = ModuleRegistryLib.MODULE_CLAIMS;
        _registerAndActivate(claims, _fresh(claims, 2, 0));
        IModuleRegistry.PreflightResult memory result = registry.preflightActivation(claims);
        assertFalse(result.ok);
        assertEq(result.errorCode, "ALREADY_ACTIVE");
    }

    function test_validateCanonicalSuite_tracksFullSuite() public {
        IModuleRegistry.PreflightResult memory incomplete = registry.validateCanonicalSuite();
        assertFalse(incomplete.ok);
        assertEq(incomplete.errorCode, "INCOMPLETE_SUITE");

        _bootstrapFullSuite();

        IModuleRegistry.PreflightResult memory complete = registry.validateCanonicalSuite();
        assertTrue(complete.ok);
        assertEq(complete.errorCode, bytes32(0));
    }

    function test_canonicalModules_suiteAccurate() public {
        _bootstrapFullSuite();
        IModuleRegistry.ModuleInfo[] memory infos = registry.canonicalModules();
        assertEq(infos.length, 14);
        for (uint256 i = 0; i < infos.length; ++i) {
            assertEq(uint256(infos[i].status), uint256(IModuleRegistry.ModuleStatus.ACTIVE));
            assertTrue(infos[i].versionId != bytes32(0));
        }
    }

    // =========================================================================
    // Full canonical-suite bootstrap
    // =========================================================================

    function _bootstrapFullSuite() internal {
        bytes32[14] memory ids = ModuleRegistryLib.canonicalModuleIds();
        IModuleRegistry.ModuleRegistration[] memory regs = new IModuleRegistry.ModuleRegistration[](14);
        for (uint256 i = 0; i < 14; ++i) {
            regs[i] = _reg(ids[i], new MockV2Module(2, 0, registry.canonicalInterfaceOf(ids[i])));
        }
        registry.registerModules(regs);

        bytes32[] memory batch = new bytes32[](14);
        for (uint256 i = 0; i < 14; ++i) {
            batch[i] = ids[i];
        }
        registry.activateModules(batch);

        for (uint256 i = 0; i < 14; ++i) {
            assertTrue(registry.isRegistered(ids[i]));
        }
    }
}
