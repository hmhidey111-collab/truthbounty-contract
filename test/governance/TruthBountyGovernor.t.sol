// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernanceForbiddenCalls} from "../../contracts/governance/v2/libraries/GovernanceForbiddenCalls.sol";
import {GovernedModuleRegistry} from "../../contracts/governance/v2/GovernedModuleRegistry.sol";
import {TruthBountyGovernanceToken} from "../../contracts/governance/v2/TruthBountyGovernanceToken.sol";
import {TruthBountyGovernor} from "../../contracts/governance/v2/TruthBountyGovernor.sol";
import {GovernanceSnapshot} from "../../contracts/governance/v2/GovernanceSnapshot.sol";
import {IGovernanceSnapshot} from "../../contracts/governance/v2/IGovernanceSnapshot.sol";
import {GovernanceGuardian} from "../../contracts/governance/v2/GovernanceGuardian.sol";
import {ITruthBountyGovernor} from "../../contracts/governance/v2/ITruthBountyGovernor.sol";
import {GovernanceRoleTopology} from "../../contracts/governance/v2/GovernanceRoleTopology.sol";
import {MockGovernedModule} from "../../contracts/mocks/MockGovernedModule.sol";

contract TruthBountyGovernorTest is Test {
    uint48 internal constant VOTING_DELAY = 1;
    uint32 internal constant VOTING_PERIOD = 100;
    uint256 internal constant TIMELOCK_DELAY = 1 days;
    uint256 internal constant QUORUM_NUMERATOR = 4;
    uint256 internal constant TOKEN_SUPPLY = 1_000_000 ether;

    TruthBountyGovernanceToken internal token;
    GovernedModuleRegistry internal registry;
    TimelockController internal timelock;
    GovernanceSnapshot internal snapshot;
    TruthBountyGovernor internal governor;
    GovernanceGuardian internal guardianContract;
    MockGovernedModule internal module;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal voter = makeAddr("voter");
    address internal proposer = makeAddr("proposer");

    function setUp() public {
        vm.startPrank(admin);

        registry = new GovernedModuleRegistry(admin);
        token = new TruthBountyGovernanceToken(admin, TOKEN_SUPPLY);
        token.transfer(proposer, 200_000 ether);
        token.transfer(voter, 800_000 ether);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, admin);

        // Deploy snapshot with admin as temporary registrar, then hand off to governor
        snapshot = new GovernanceSnapshot(admin, admin);

        governor = new TruthBountyGovernor(
            token,
            timelock,
            registry,
            IGovernanceSnapshot(address(snapshot)),
            guardian,
            VOTING_DELAY,
            VOTING_PERIOD,
            100_000 ether,
            QUORUM_NUMERATOR
        );

        // Wire the snapshot registrar role to the governor
        bytes32 registrarRole = snapshot.SNAPSHOT_REGISTRAR_ROLE();
        snapshot.grantRole(registrarRole, address(governor));
        snapshot.revokeRole(registrarRole, admin);

        guardianContract = new GovernanceGuardian(admin, guardian, ITruthBountyGovernor(address(governor)));
        vm.stopPrank();

        vm.prank(guardian);
        governor.setGovernanceGuardianModule(address(guardianContract));

        vm.startPrank(admin);
        GovernanceRoleTopology.configure(timelock, governor, guardian, TIMELOCK_DELAY);
        GovernanceRoleTopology.finalizeTimelockAdmin(timelock, admin);
        bytes32 registryAdminRole = registry.REGISTRY_ADMIN_ROLE();
        registry.grantRole(registryAdminRole, address(timelock));

        module = new MockGovernedModule();
        registry.registerModule("MOCK_MODULE", address(module));

        vm.stopPrank();

        vm.prank(guardian);
        governor.setGovernanceGuardianModule(address(guardianContract));

        vm.prank(proposer);
        token.delegate(proposer);
        vm.prank(voter);
        token.delegate(voter);

        // Voting power checkpoints must predate the proposal snapshot lookup (clock() - 1).
        vm.warp(block.timestamp + 1);
        // Warp so delegation checkpoints are in the past — getPastVotes(x, block.timestamp)
        // requires the timepoint to be strictly before current block.timestamp (OZ Votes invariant).
        vm.warp(block.timestamp + 2);
    }

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
        proposalId = governor.propose(targets, values, calldatas, "update mock module value");
    }

    function _voteAndQueue(uint256 proposalId) internal {
        // Enter the Active window first so the vote is accepted ...
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);
        // ... then cross the voting deadline so the proposal reaches Succeeded and can be queued.
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.queue(proposalId);
    }

    function test_FullProposalLifecycle() public {
        uint256 proposalId = _createProposal(42);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));

        _voteAndQueue(proposalId);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Queued));

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(proposalId);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
        assertEq(module.value(), 42);
    }

    function test_ProposalDefeatedWithoutQuorum() public {
        uint256 proposalId = _createProposal(7);
        vm.warp(block.timestamp + VOTING_DELAY + VOTING_PERIOD + 1);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_VotingBeforeDelayReverts() public {
        uint256 proposalId = _createProposal(8);

        vm.prank(voter);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    function test_VoteAtVotingDeadlineIsCountedBeforeQueueing() public {
        uint256 proposalId = _createProposal(18);
        uint256 deadline = governor.proposalDeadline(proposalId);

        vm.warp(deadline);
        vm.prank(voter);
        uint256 votingWeight = governor.castVote(proposalId, 1);

        assertEq(votingWeight, 800_000 ether);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Active));

        vm.warp(deadline + 1);
        vm.expectRevert();
        vm.prank(proposer);
        governor.castVote(proposalId, 1);

        governor.queue(proposalId);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Queued));
    }

    function test_ProposerCanCancelPendingProposal() public {
        uint256 proposalId = _createProposal(12);

        vm.prank(proposer);
        governor.cancel(proposalId);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
        vm.expectRevert();
        governor.queue(proposalId);
    }

    function test_CancelledProposalCannotExecute() public {
        uint256 proposalId = _createProposal(13);

        vm.prank(guardian);
        guardianContract.vetoProposal(proposalId);

        vm.expectRevert();
        governor.execute(proposalId);
    }

    function test_CancelledByGuardian() public {
        uint256 proposalId = _createProposal(11);
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(guardian);
        guardianContract.vetoProposal(proposalId);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_EarlyExecuteReverts() public {
        uint256 proposalId = _createProposal(99);
        _voteAndQueue(proposalId);

        vm.expectRevert();
        governor.execute(proposalId);
    }

    function test_TimelockExecutesAtExactEtaAfterRecovery() public {
        uint256 proposalId = _createProposal(77);
        _voteAndQueue(proposalId);
        uint256 eta = governor.proposalEta(proposalId);

        vm.warp(eta);
        governor.execute(proposalId);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
        assertEq(module.value(), 77);
    }

    function test_DuplicateExecuteReverts() public {
        uint256 proposalId = _createProposal(55);
        _voteAndQueue(proposalId);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(proposalId);

        vm.expectRevert();
        governor.execute(proposalId);
    }

    function test_ForbiddenTargetReverts() public {
        address unregistered = makeAddr("unregistered");
        address[] memory targets = new address[](1);
        targets[0] = unregistered;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = _proposalCalldata(1);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(TruthBountyGovernor.TargetNotGovernedModule.selector, unregistered));
        governor.propose(targets, values, calldatas, "bad target");
    }

    function test_ForbiddenSelectorReverts() public {
        address[] memory targets = new address[](1);
        targets[0] = address(module);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(MockGovernedModule.settleClaim.selector, uint256(1));

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceForbiddenCalls.ForbiddenGovernanceCall.selector, MockGovernedModule.settleClaim.selector)
        );
        governor.propose(targets, values, calldatas, "forbidden settlement");
    }

    function test_ProposalThresholdBlocksSpam() public {
        address spammer = makeAddr("spammer");
        address[] memory targets = new address[](1);
        targets[0] = address(module);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = _proposalCalldata(1);

        vm.prank(spammer);
        vm.expectRevert();
        governor.propose(targets, values, calldatas, "spam");
    }

    function test_ProposalRejectsMismatchedOperationArrays() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](0);
        bytes[] memory calldatas = new bytes[](1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TruthBountyGovernor.InvalidProposalOperationCount.selector, 1, 0, 1,
                governor.MAX_PROPOSAL_OPERATIONS()
            )
        );
        governor.propose(targets, values, calldatas, "bad arrays");
    }

    function test_ProposalRejectsTooManyOperations() public {
        uint256 count = governor.MAX_PROPOSAL_OPERATIONS() + 1;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory calldatas = new bytes[](count);

        vm.expectRevert(
            abi.encodeWithSelector(
                TruthBountyGovernor.InvalidProposalOperationCount.selector, count, count, count,
                governor.MAX_PROPOSAL_OPERATIONS()
            )
        );
        governor.propose(targets, values, calldatas, "too many operations");
    }

    function test_ProposalRejectsOversizedOperationCalldata() public {
        address[] memory targets = new address[](1);
        targets[0] = address(module);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = new bytes(governor.MAX_OPERATION_CALLDATA_BYTES() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TruthBountyGovernor.OperationCalldataTooLarge.selector,
                0,
                governor.MAX_OPERATION_CALLDATA_BYTES() + 1,
                governor.MAX_OPERATION_CALLDATA_BYTES()
            )
        );
        governor.propose(targets, values, calldatas, "oversized action");
    }

    function test_ProposalRejectsOversizedAggregateCalldata() public {
        uint256 perOperationLimit = governor.MAX_OPERATION_CALLDATA_BYTES();
        uint256 count = governor.MAX_PROPOSAL_CALLDATA_BYTES() / perOperationLimit + 1;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory calldatas = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            targets[i] = address(module);
            calldatas[i] = new bytes(perOperationLimit);
        }

        uint256 aggregateSize = count * perOperationLimit;
        vm.expectRevert(
            abi.encodeWithSelector(
                TruthBountyGovernor.ProposalCalldataTooLarge.selector,
                aggregateSize,
                governor.MAX_PROPOSAL_CALLDATA_BYTES()
            )
        );
        governor.propose(targets, values, calldatas, "oversized proposal payload");
    }

    function test_ProposalRejectsOversizedDescription() public {
        address[] memory targets = new address[](1);
        targets[0] = address(module);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = _proposalCalldata(1);
        string memory description = new string(governor.MAX_PROPOSAL_DESCRIPTION_BYTES() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TruthBountyGovernor.ProposalDescriptionTooLarge.selector,
                governor.MAX_PROPOSAL_DESCRIPTION_BYTES() + 1,
                governor.MAX_PROPOSAL_DESCRIPTION_BYTES()
            )
        );
        governor.propose(targets, values, calldatas, description);
    }

    function test_PublishManifestEmitsConfig() public {
        vm.expectEmit(true, true, true, false);
        emit TruthBountyGovernor.GovernanceManifestPublished(
            address(governor),
            address(timelock),
            address(token),
            address(registry),
            address(snapshot),
            VOTING_DELAY,
            VOTING_PERIOD,
            100_000 ether,
            QUORUM_NUMERATOR,
            TIMELOCK_DELAY
        );
        governor.publishManifest();
    }
}
