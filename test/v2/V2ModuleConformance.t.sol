// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {EvidenceRegistry} from "../../contracts/v2/EvidenceRegistry.sol";
import {StakeVault} from "../../contracts/v2/StakeVault.sol";
import {EmergencyControls} from "../../contracts/v2/EmergencyControls.sol";
import {V2ConformanceFixture} from "../../contracts/v2/interfaces/V2ConformanceFixture.sol";

import {IV2Module} from "../../contracts/v2/interfaces/IV2Module.sol";
import {IEvidence} from "../../contracts/v2/interfaces/IEvidence.sol";
import {IStakeCustody} from "../../contracts/v2/interfaces/IStakeCustody.sol";
import {IClaims} from "../../contracts/v2/interfaces/IClaims.sol";
import {IAggregation} from "../../contracts/v2/interfaces/IAggregation.sol";
import {IEmergencyControls} from "../../contracts/v2/interfaces/IEmergencyControls.sol";

import {MockModuleRegistry} from "../../contracts/mocks/MockModuleRegistry.sol";
import {MockERC20} from "../../contracts/MockERC20.sol";

/// @title V2ModuleConformanceTest
/// @notice Runtime ERC-165 / interface-version conformance for every canonical
///         V2 module (V2-SC-045 / #427). Every deployable canonical module must
///         advertise `IERC165`, `IV2Module`, and its canonical module interface,
///         reject the invalid `0xffffffff` id, and report the canonical protocol
///         major version. These tests fail closed if a module ever drops its
///         interface advertisement or ships an incompatible version.
contract V2ModuleConformanceTest is Test {
    /// @dev Canonical V2 protocol major version. A module reporting a different
    ///      major is treated as an incompatible, non-conforming module.
    uint16 internal constant CANONICAL_MAJOR = 2;

    /// @dev The ERC-165 invalid interface id, which MUST always resolve to false.
    bytes4 internal constant INVALID_INTERFACE_ID = 0xffffffff;

    EvidenceRegistry internal evidence;
    StakeVault internal stakeVault;
    EmergencyControls internal emergencyControls;
    V2ConformanceFixture internal fixture;

    function setUp() public {
        address admin = address(this);

        // EvidenceRegistry only records `claimRegistry` as an immutable address;
        // conformance calls never touch it, so a non-zero placeholder suffices.
        evidence = new EvidenceRegistry(admin, address(0xC1A1));

        MockModuleRegistry registry = new MockModuleRegistry();
        MockERC20 token = new MockERC20("Stake", "STK");
        stakeVault = new StakeVault(address(registry), address(token), admin);

        emergencyControls = new EmergencyControls(admin, address(0xE1), address(0x60));

        fixture = new V2ConformanceFixture();
    }

    // -------------------------------------------------------------------------
    // Shared conformance assertions
    // -------------------------------------------------------------------------

    /// @dev Every conforming module must satisfy the ERC-165 baseline: advertise
    ///      IERC165 and reject the reserved invalid id.
    function _assertErc165Baseline(address module) internal view {
        assertTrue(
            IERC165(module).supportsInterface(type(IERC165).interfaceId),
            "module does not advertise IERC165"
        );
        assertFalse(
            IERC165(module).supportsInterface(INVALID_INTERFACE_ID),
            "module must reject the invalid ERC-165 id"
        );
    }

    /// @dev Every canonical (deployable) module must advertise IV2Module and
    ///      report the canonical protocol major version.
    function _assertV2ModuleSurface(address module) internal view {
        assertTrue(
            IERC165(module).supportsInterface(type(IV2Module).interfaceId),
            "module does not advertise IV2Module"
        );
        (uint16 major,) = IV2Module(module).protocolVersion();
        assertEq(major, CANONICAL_MAJOR, "module reports an incompatible protocol major");
    }

    // -------------------------------------------------------------------------
    // Per-module conformance
    // -------------------------------------------------------------------------

    function test_evidenceRegistry_conforms() public view {
        _assertErc165Baseline(address(evidence));
        _assertV2ModuleSurface(address(evidence));
        assertTrue(
            evidence.supportsInterface(type(IEvidence).interfaceId),
            "EvidenceRegistry does not advertise IEvidence"
        );
        assertTrue(
            evidence.supportsInterface(type(IAccessControl).interfaceId),
            "EvidenceRegistry does not advertise IAccessControl"
        );
    }

    function test_stakeVault_conforms() public view {
        _assertErc165Baseline(address(stakeVault));
        _assertV2ModuleSurface(address(stakeVault));
        assertTrue(
            stakeVault.supportsInterface(type(IStakeCustody).interfaceId),
            "StakeVault does not advertise IStakeCustody"
        );
        assertTrue(
            stakeVault.supportsInterface(type(IAccessControl).interfaceId),
            "StakeVault does not advertise IAccessControl"
        );
    }

    function test_emergencyControls_conforms() public view {
        _assertErc165Baseline(address(emergencyControls));
        _assertV2ModuleSurface(address(emergencyControls));
        assertTrue(
            emergencyControls.supportsInterface(type(IEmergencyControls).interfaceId),
            "EmergencyControls does not advertise IEmergencyControls"
        );
        assertTrue(
            emergencyControls.supportsInterface(type(IAccessControl).interfaceId),
            "EmergencyControls does not advertise IAccessControl"
        );
    }

    /// @dev The conformance fixture proves a representative module can implement
    ///      the canonical claims/aggregation surface. It intentionally does not
    ///      advertise IV2Module (it is a compile-time fixture, not a deployable
    ///      module), so only the ERC-165 baseline and its declared interfaces are
    ///      asserted here.
    function test_conformanceFixture_conforms() public view {
        _assertErc165Baseline(address(fixture));
        assertTrue(
            fixture.supportsInterface(type(IClaims).interfaceId),
            "fixture does not advertise IClaims"
        );
        assertTrue(
            fixture.supportsInterface(type(IAggregation).interfaceId),
            "fixture does not advertise IAggregation"
        );
        (uint16 major,) = fixture.protocolVersion();
        assertEq(major, CANONICAL_MAJOR, "fixture reports an incompatible protocol major");
    }
}
