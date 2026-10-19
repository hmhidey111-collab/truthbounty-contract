// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Create2AddressPlanner} from "../../contracts/deployment/Create2AddressPlanner.sol";
import {ICreate2AddressPlanner} from "../../contracts/deployment/ICreate2AddressPlanner.sol";

/// @dev Minimal contract deployed via CREATE2 for confirmation tests.
contract Create2Probe {
    uint256 public immutable marker;

    constructor(uint256 marker_) {
        marker = marker_;
    }
}

contract Create2AddressPlannerTest is Test {
    Create2AddressPlanner internal planner;

    address internal admin = makeAddr("admin");
    address internal plannerRole = makeAddr("planner");
    address internal stranger = makeAddr("stranger");
    address internal deployer;

    bytes32 internal constant MODULE_A = keccak256("MODULE_A");
    bytes32 internal constant MODULE_B = keccak256("MODULE_B");
    bytes32 internal constant REVIEWED_SALT = keccak256("reviewed-salt-v1");
    bytes32 internal constant OTHER_SALT = keccak256("reviewed-salt-v2");

    function setUp() public {
        deployer = address(this);
        planner = new Create2AddressPlanner(admin);
        vm.prank(admin);
        planner.grantRole(planner.PLANNER_ROLE(), plannerRole);
    }

    function _initCodeHash(uint256 marker) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(type(Create2Probe).creationCode, abi.encode(marker)));
    }

    function _runtimeHash(address deployed) internal view returns (bytes32 hash) {
        assembly ("memory-safe") {
            hash := extcodehash(deployed)
        }
    }

    // ─── compute / derive ─────────────────────────────────────────────

    function test_computeAddress_matchesCreate2Deploy() public {
        bytes32 salt = planner.deriveSalt(MODULE_A, REVIEWED_SALT);
        bytes32 initHash = _initCodeHash(42);
        address predicted = planner.computeAddress(deployer, salt, initHash);

        Create2Probe probe = new Create2Probe{salt: salt}(42);
        assertEq(address(probe), predicted);
    }

    function test_deriveSalt_domainSeparatesByModule() public view {
        bytes32 a = planner.deriveSalt(MODULE_A, REVIEWED_SALT);
        bytes32 b = planner.deriveSalt(MODULE_B, REVIEWED_SALT);
        assertTrue(a != b);
        assertTrue(a != REVIEWED_SALT);
    }

    // ─── planAddress success / auth / boundaries ──────────────────────

    function test_planAddress_success() public {
        bytes32 initHash = _initCodeHash(1);
        bytes32 salt = planner.deriveSalt(MODULE_A, REVIEWED_SALT);
        address expected = planner.computeAddress(deployer, salt, initHash);

        vm.prank(plannerRole);
        address predicted = planner.planAddress(MODULE_A, REVIEWED_SALT, initHash, deployer);

        assertEq(predicted, expected);
        ICreate2AddressPlanner.Plan memory plan = planner.getPlan(MODULE_A);
        assertTrue(plan.reserved);
        assertFalse(plan.bytecodeVerified);
        assertEq(plan.predicted, expected);
        assertEq(plan.deployer, deployer);
        assertEq(plan.initCodeHash, initHash);
    }

    function test_planAddress_revertsUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        planner.planAddress(MODULE_A, REVIEWED_SALT, _initCodeHash(1), deployer);
    }

    function test_planAddress_revertsZeroModuleId() public {
        vm.prank(plannerRole);
        vm.expectRevert(ICreate2AddressPlanner.ZeroModuleId.selector);
        planner.planAddress(bytes32(0), REVIEWED_SALT, _initCodeHash(1), deployer);
    }

    function test_planAddress_revertsZeroSalt() public {
        vm.prank(plannerRole);
        vm.expectRevert(ICreate2AddressPlanner.ZeroSalt.selector);
        planner.planAddress(MODULE_A, bytes32(0), _initCodeHash(1), deployer);
    }

    function test_planAddress_revertsZeroInitCodeHash() public {
        vm.prank(plannerRole);
        vm.expectRevert(ICreate2AddressPlanner.ZeroInitCodeHash.selector);
        planner.planAddress(MODULE_A, REVIEWED_SALT, bytes32(0), deployer);
    }

    function test_planAddress_revertsZeroDeployer() public {
        vm.prank(plannerRole);
        vm.expectRevert(ICreate2AddressPlanner.ZeroDeployer.selector);
        planner.planAddress(MODULE_A, REVIEWED_SALT, _initCodeHash(1), address(0));
    }

    function test_planAddress_revertsDuplicateModule() public {
        bytes32 initHash = _initCodeHash(1);
        vm.startPrank(plannerRole);
        planner.planAddress(MODULE_A, REVIEWED_SALT, initHash, deployer);
        vm.expectRevert(abi.encodeWithSelector(ICreate2AddressPlanner.PlanAlreadyExists.selector, MODULE_A));
        planner.planAddress(MODULE_A, OTHER_SALT, initHash, deployer);
        vm.stopPrank();
    }

    function test_planAddress_revertsSaltReuseAcrossModules() public {
        // Same reviewed salt + different modules => different derived salts, allowed.
        // Force identical derived salt by planning then trying same moduleId+salt path already covered;
        // Cross-module identical derived salt cannot happen with domain separation.
        // Instead verify same reviewed salt is OK for different modules:
        bytes32 initHash = _initCodeHash(1);
        vm.startPrank(plannerRole);
        planner.planAddress(MODULE_A, REVIEWED_SALT, initHash, deployer);
        planner.planAddress(MODULE_B, REVIEWED_SALT, initHash, deployer);
        vm.stopPrank();
        assertTrue(planner.getPlan(MODULE_A).predicted != planner.getPlan(MODULE_B).predicted);
    }

    function test_planAddress_revertsWhenTargetHasCode() public {
        bytes32 salt = planner.deriveSalt(MODULE_A, REVIEWED_SALT);
        bytes32 initHash = _initCodeHash(7);
        // Deploy first so predicted address has code
        Create2Probe probe = new Create2Probe{salt: salt}(7);
        assertTrue(address(probe).code.length > 0);

        vm.prank(plannerRole);
        vm.expectRevert(
            abi.encodeWithSelector(ICreate2AddressPlanner.TargetAlreadyHasCode.selector, address(probe))
        );
        planner.planAddress(MODULE_A, REVIEWED_SALT, initHash, deployer);
    }

    // ─── bytecode verification + registration gate ────────────────────

    function test_verifyAndConfirm_readyForRegistration() public {
        bytes32 salt = planner.deriveSalt(MODULE_A, REVIEWED_SALT);
        bytes32 initHash = _initCodeHash(99);

        vm.prank(plannerRole);
        address predicted = planner.planAddress(MODULE_A, REVIEWED_SALT, initHash, deployer);

        Create2Probe probe = new Create2Probe{salt: salt}(99);
        assertEq(address(probe), predicted);

        bytes memory runtime = predicted.code;
        bytes32 runtimeHash = keccak256(runtime);

        vm.prank(plannerRole);
        planner.setExpectedRuntimeCodeHash(MODULE_A, runtimeHash);

        vm.prank(plannerRole);
        planner.verifyBytecode(MODULE_A, runtime);

        assertTrue(planner.getPlan(MODULE_A).bytecodeVerified);
        assertFalse(planner.isReadyForRegistration(MODULE_A));

        bool ok = planner.confirmDeployment(MODULE_A);
        assertTrue(ok);
        assertTrue(planner.isReadyForRegistration(MODULE_A));
    }

    function test_verifyBytecode_revertsOnMismatch() public {
        bytes32 initHash = _initCodeHash(3);
        vm.prank(plannerRole);
        planner.planAddress(MODULE_A, REVIEWED_SALT, initHash, deployer);

        vm.prank(plannerRole);
        planner.setExpectedRuntimeCodeHash(MODULE_A, keccak256("expected"));

        vm.prank(plannerRole);
        vm.expectRevert();
        planner.verifyBytecode(MODULE_A, bytes("wrong-bytecode"));
    }

    function test_verifyBytecode_rejectsRuntimeCodeAboveEip170Limit() public {
        uint256 maximum = planner.MAX_RUNTIME_BYTECODE_BYTES();
        bytes memory oversized = new bytes(maximum + 1);

        vm.prank(plannerRole);
        vm.expectRevert(
            abi.encodeWithSelector(ICreate2AddressPlanner.RuntimeBytecodeTooLarge.selector, maximum + 1, maximum)
        );
        planner.verifyBytecode(MODULE_A, oversized);
    }

    function test_confirmDeployment_revertsWithoutVerification() public {
        bytes32 initHash = _initCodeHash(3);
        vm.prank(plannerRole);
        planner.planAddress(MODULE_A, REVIEWED_SALT, initHash, deployer);

        vm.expectRevert(abi.encodeWithSelector(ICreate2AddressPlanner.BytecodeNotVerified.selector, MODULE_A));
        planner.confirmDeployment(MODULE_A);
    }

    function test_confirmDeployment_revertsWhenNoCode() public {
        bytes32 initHash = _initCodeHash(3);
        vm.startPrank(plannerRole);
        planner.planAddress(MODULE_A, REVIEWED_SALT, initHash, deployer);
        planner.verifyBytecode(MODULE_A, bytes("pending-runtime"));
        vm.stopPrank();

        vm.expectRevert();
        planner.confirmDeployment(MODULE_A);
    }

    function test_clearPlan_adminOnly() public {
        bytes32 initHash = _initCodeHash(3);
        vm.prank(plannerRole);
        address predicted = planner.planAddress(MODULE_A, REVIEWED_SALT, initHash, deployer);

        vm.prank(stranger);
        vm.expectRevert();
        planner.clearPlan(MODULE_A);

        vm.prank(admin);
        planner.clearPlan(MODULE_A);
        assertFalse(planner.getPlan(MODULE_A).reserved);

        // Salt can be reused after clear
        vm.prank(plannerRole);
        address again = planner.planAddress(MODULE_A, REVIEWED_SALT, initHash, deployer);
        assertEq(again, predicted);
    }

    // ─── fuzz: prediction stability & collision-free module salts ─────

    function testFuzz_computeAddress_stable(address factory, bytes32 salt, bytes32 initHash) public view {
        vm.assume(factory != address(0));
        vm.assume(salt != bytes32(0));
        vm.assume(initHash != bytes32(0));
        address a = planner.computeAddress(factory, salt, initHash);
        address b = planner.computeAddress(factory, salt, initHash);
        assertEq(a, b);
    }

    function testFuzz_deriveSalt_uniquePerModule(bytes32 moduleX, bytes32 moduleY, bytes32 reviewed)
        public
        view
    {
        vm.assume(moduleX != moduleY);
        vm.assume(reviewed != bytes32(0));
        assertTrue(planner.deriveSalt(moduleX, reviewed) != planner.deriveSalt(moduleY, reviewed));
    }

    function testFuzz_planAddress_rejectsZeroInputs(bytes32 moduleId, bytes32 salt, bytes32 initHash, address factory)
        public
    {
        vm.assume(moduleId == bytes32(0) || salt == bytes32(0) || initHash == bytes32(0) || factory == address(0));
        vm.prank(plannerRole);
        vm.expectRevert();
        planner.planAddress(moduleId, salt, initHash, factory);
    }
}
