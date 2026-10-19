// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernedModuleRegistry} from "../../contracts/governance/v2/GovernedModuleRegistry.sol";
import {TruthBountyGovernanceToken} from "../../contracts/governance/v2/TruthBountyGovernanceToken.sol";
import {TruthBountyGovernor} from "../../contracts/governance/v2/TruthBountyGovernor.sol";
import {GovernanceSnapshot} from "../../contracts/governance/v2/GovernanceSnapshot.sol";
import {IGovernanceSnapshot} from "../../contracts/governance/v2/IGovernanceSnapshot.sol";
import {GovernanceRoleTopology} from "../../contracts/governance/v2/GovernanceRoleTopology.sol";
import {MockGovernedModule} from "../../contracts/mocks/MockGovernedModule.sol";
import {ForcedNativeValueAttacker} from "../../contracts/mocks/ForcedNativeValueAttacker.sol";

/**
 * @notice V2-SC-153 — Reject Unexpected Native Value and Isolate Forced ETH.
 *
 * Verifies the governor's native-value policy:
 *  - every native transfer to the governor is rejected, whatever the entry point,
 *  - both `execute` overloads reject an attached `msg.value`,
 *  - proposals carrying a non-zero native value cannot be created,
 *  - native value forced onto the governor through SELFDESTRUCT is economically inert: it grants
 *    no voting weight, no proposer credit, and no governance path can move it.
 */
contract NativeValueIsolationTest is Test {
    uint48 internal constant VOTING_DELAY = 1;
    uint32 internal constant VOTING_PERIOD = 100;
    uint256 internal constant TIMELOCK_DELAY = 1 days;
    uint256 internal constant QUORUM_NUMERATOR = 4;
    uint256 internal constant TOKEN_SUPPLY = 1_000_000 ether;
    uint256 internal constant PROPOSER_BALANCE = 200_000 ether;
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000 ether;
    string internal constant DESCRIPTION = "update mock module value";

    TruthBountyGovernanceToken internal token;
    GovernedModuleRegistry internal registry;
    TimelockController internal timelock;
    GovernanceSnapshot internal snapshot;
    TruthBountyGovernor internal governor;
    MockGovernedModule internal module;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal voter = makeAddr("voter");
    address internal proposer = makeAddr("proposer");

    function setUp() public {
        vm.startPrank(admin);

        registry = new GovernedModuleRegistry(admin);
        token = new TruthBountyGovernanceToken(admin, TOKEN_SUPPLY);
        token.transfer(proposer, PROPOSER_BALANCE);
        token.transfer(voter, 800_000 ether);

        address[] memory noProposers = new address[](0);
        address[] memory noExecutors = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, noProposers, noExecutors, admin);

        snapshot = new GovernanceSnapshot(admin, admin);

        governor = new TruthBountyGovernor(
            token,
            timelock,
            registry,
            IGovernanceSnapshot(address(snapshot)),
            guardian,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_NUMERATOR
        );

        // The governor is the only account allowed to register canonical snapshots.
        bytes32 registrarRole = snapshot.SNAPSHOT_REGISTRAR_ROLE();
        snapshot.grantRole(registrarRole, address(governor));
        snapshot.revokeRole(registrarRole, admin);

        GovernanceRoleTopology.configure(timelock, governor, guardian, TIMELOCK_DELAY);
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, admin);
        registry.grantRole(registry.REGISTRY_ADMIN_ROLE(), address(timelock));

        module = new MockGovernedModule();
        registry.registerModule("MOCK_MODULE", address(module));

        vm.stopPrank();

        vm.prank(proposer);
        token.delegate(proposer);
        vm.prank(voter);
        token.delegate(voter);

        // Voting power checkpoints must predate the proposal snapshot lookup (clock() - 1).
        vm.warp(block.timestamp + 1);
    }

    // ---------------------------------------------------------------- helpers

    function _proposalCalldata(uint256 newValue) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockGovernedModule.setValue.selector, newValue);
    }

    function _createProposal(uint256 newValue) internal returns (uint256 proposalId) {
        address[] memory targets = new address[](1);
        targets[0] = address(module);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = _proposalCalldata(newValue);

        vm.prank(proposer);
        proposalId = governor.propose(targets, values, calldatas, DESCRIPTION);
    }

    function _toQueued(uint256 proposalId) internal {
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.queue(proposalId);
    }

    /// @dev Forces `amount` wei onto `target` through a same-transaction self-destruct.
    function _forceNativeValue(address payable target, uint256 amount) internal {
        ForcedNativeValueAttacker attacker = new ForcedNativeValueAttacker();
        vm.deal(address(this), amount);
        attacker.forceNativeValue{value: amount}(target);
    }

    // ------------------------------------------------- receive / fallback surface

    function test_DirectNativeTransferIsRejected() public {
        vm.deal(address(this), 1 ether);

        (bool sent, ) = address(governor).call{value: 1 ether}("");
        assertFalse(sent, "governor must reject a plain native transfer");
        assertEq(address(governor).balance, 0, "no native balance may be retained");

        (bool sentWithSelector, ) = address(governor).call{value: 1 ether}(
            abi.encodeWithSignature("notAGovernorFunction()")
        );
        assertFalse(sentWithSelector, "governor must reject native value on unknown calldata");
        assertEq(address(governor).balance, 0, "no native balance may be retained");
    }

    function test_NativeTransferDuringLifecycleIsRejected() public {
        uint256 proposalId = _createProposal(21);
        _toQueued(proposalId);

        // A queued proposal grants no account the ability to fund the governor with native value.
        vm.deal(address(this), 1 ether);
        (bool sent, ) = address(governor).call{value: 1 ether}("");
        assertFalse(sent, "native transfers stay rejected while a proposal is queued");
        assertEq(address(governor).balance, 0, "no native balance may be retained");

        vm.warp(governor.proposalEta(proposalId));
        governor.execute(proposalId);
        assertEq(module.value(), 21, "the proposal still executes with zero native value");
        assertEq(address(governor).balance, 0, "no native balance may be retained");
    }

    // --------------------------------------------------------- execution surface

    function test_ExecuteByIdRejectsNativeValue() public {
        uint256 proposalId = _createProposal(31);
        _toQueued(proposalId);
        vm.warp(governor.proposalEta(proposalId));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(TruthBountyGovernor.UnexpectedNativeValue.selector, uint256(1 ether))
        );
        governor.execute{value: 1 ether}(proposalId);

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Queued),
            "the rejected call must leave the proposal queued"
        );
        assertEq(module.value(), 0, "the rejected call must not run any target");
        assertEq(address(governor).balance, 0, "no native balance may be retained");

        // The same proposal executes normally without native value.
        governor.execute(proposalId);
        assertEq(module.value(), 31, "zero-value execution still works");
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
    }

    function test_ExecuteWithOperationsRejectsNativeValue() public {
        uint256 proposalId = _createProposal(32);
        _toQueued(proposalId);
        vm.warp(governor.proposalEta(proposalId));

        address[] memory targets = new address[](1);
        targets[0] = address(module);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = _proposalCalldata(32);
        bytes32 descriptionHash = keccak256(bytes(DESCRIPTION));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(TruthBountyGovernor.UnexpectedNativeValue.selector, uint256(1 ether))
        );
        governor.execute{value: 1 ether}(targets, values, calldatas, descriptionHash);

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Queued),
            "the rejected call must leave the proposal queued"
        );
        assertEq(module.value(), 0, "the rejected call must not run any target");

        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(module.value(), 32, "zero-value execution still works");
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
    }

    // -------------------------------------------------------------- proposal values

    function test_ProposalWithNativeValueIsRejected() public {
        address[] memory targets = new address[](1);
        targets[0] = address(module);
        uint256[] memory values = new uint256[](1);
        values[0] = 1 ether;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = _proposalCalldata(1);

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TruthBountyGovernor.NativeValueProposalNotAllowed.selector,
                uint256(0),
                uint256(1 ether)
            )
        );
        governor.propose(targets, values, calldatas, "native payout");
    }

    // -------------------------------------------------------------- forced ETH

    function test_ForcedNativeValueIsEconomicallyInert() public {
        uint256 forcedAmount = 5 ether;
        uint256 thresholdBefore = governor.proposalThreshold();
        uint256 countBefore = governor.proposalCount();
        uint256 quorumTimepoint = block.timestamp - 1;
        uint256 quorumBefore = governor.quorum(quorumTimepoint);

        _forceNativeValue(payable(address(governor)), forcedAmount);

        assertEq(address(governor).balance, forcedAmount, "forced value cannot be refused at the EVM level");
        assertEq(token.balanceOf(address(governor)), 0, "forced value grants no voting weight");
        assertEq(governor.proposalThreshold(), thresholdBefore, "forced value grants no proposer credit");
        assertEq(governor.quorum(quorumTimepoint), quorumBefore, "forced value does not change quorum");

        // A full lifecycle leaves the forced balance untouched and unclaimable.
        uint256 proposalId = _createProposal(64);
        _toQueued(proposalId);
        vm.warp(governor.proposalEta(proposalId));
        governor.execute(proposalId);

        assertEq(module.value(), 64, "governance keeps working while forced value is present");
        assertEq(governor.proposalCount(), countBefore + 1, "only the real proposal is recorded");
        assertEq(address(governor).balance, forcedAmount, "no governance path moves forced native value");
        assertEq(token.balanceOf(address(governor)), 0, "forced value is never converted into weight");
    }

    function test_ForcedNativeValueDoesNotLowerProposalBarrier() public {
        _forceNativeValue(payable(address(governor)), 1 ether);
        assertEq(address(governor).balance, 1 ether, "forced value is present");

        address spammer = makeAddr("spammer");
        address[] memory targets = new address[](1);
        targets[0] = address(module);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = _proposalCalldata(1);

        vm.prank(spammer);
        vm.expectRevert();
        governor.propose(targets, values, calldatas, DESCRIPTION);
    }
}
