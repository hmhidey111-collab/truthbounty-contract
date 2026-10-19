// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {EvidenceRegistry} from "../../contracts/v2/EvidenceRegistry.sol";
import {StakeVault} from "../../contracts/v2/StakeVault.sol";
import {EmergencyControls} from "../../contracts/v2/EmergencyControls.sol";

import {IV2Module} from "../../contracts/v2/interfaces/IV2Module.sol";
import {IEvidence} from "../../contracts/v2/interfaces/IEvidence.sol";
import {IStakeCustody} from "../../contracts/v2/interfaces/IStakeCustody.sol";
import {IEmergencyControls} from "../../contracts/v2/interfaces/IEmergencyControls.sol";

import {MockModuleRegistry} from "../../contracts/mocks/MockModuleRegistry.sol";
import {MockERC20} from "../../contracts/MockERC20.sol";

/// @title V2ConformanceFuzzTest
/// @notice ERC-165 negative-space property for the canonical V2 modules
///         (V2-SC-045 / #427): a conforming module must return `false` from
///         `supportsInterface` for every interface id outside the exact set it
///         advertises. This guards against a module silently claiming support
///         for interfaces it does not implement (spoofed conformance).
contract V2ConformanceFuzzTest is Test {
    EvidenceRegistry internal evidence;
    StakeVault internal stakeVault;
    EmergencyControls internal emergencyControls;

    function setUp() public {
        address admin = address(this);
        evidence = new EvidenceRegistry(admin, address(0xC1A1));

        MockModuleRegistry registry = new MockModuleRegistry();
        MockERC20 token = new MockERC20("Stake", "STK");
        stakeVault = new StakeVault(address(registry), address(token), admin);

        emergencyControls = new EmergencyControls(admin, address(0xE1), address(0x60));
    }

    /// @dev EvidenceRegistry advertises exactly {IERC165, IAccessControl,
    ///      IV2Module, IEvidence}. Every other id (including 0xffffffff) is false.
    function testFuzz_evidenceRegistry_rejectsUnadvertisedInterface(bytes4 id)
        public
        view
    {
        vm.assume(id != type(IERC165).interfaceId);
        vm.assume(id != type(IAccessControl).interfaceId);
        vm.assume(id != type(IV2Module).interfaceId);
        vm.assume(id != type(IEvidence).interfaceId);

        assertFalse(evidence.supportsInterface(id));
    }

    /// @dev StakeVault advertises exactly {IERC165, IAccessControl, IV2Module,
    ///      IStakeCustody}. Every other id (including 0xffffffff) is false.
    function testFuzz_stakeVault_rejectsUnadvertisedInterface(bytes4 id)
        public
        view
    {
        vm.assume(id != type(IERC165).interfaceId);
        vm.assume(id != type(IAccessControl).interfaceId);
        vm.assume(id != type(IV2Module).interfaceId);
        vm.assume(id != type(IStakeCustody).interfaceId);

        assertFalse(stakeVault.supportsInterface(id));
    }

    /// @dev EmergencyControls advertises exactly {IERC165, IAccessControl,
    ///      IV2Module, IEmergencyControls}. Every other id (including 0xffffffff) is false.
    function testFuzz_emergencyControls_rejectsUnadvertisedInterface(bytes4 id)
        public
        view
    {
        vm.assume(id != type(IERC165).interfaceId);
        vm.assume(id != type(IAccessControl).interfaceId);
        vm.assume(id != type(IV2Module).interfaceId);
        vm.assume(id != type(IEmergencyControls).interfaceId);

        assertFalse(emergencyControls.supportsInterface(id));
    }
}
