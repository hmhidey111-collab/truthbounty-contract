// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernedModuleRegistry} from "../../contracts/governance/v2/GovernedModuleRegistry.sol";
import {TruthBountyGovernanceToken} from "../../contracts/governance/v2/TruthBountyGovernanceToken.sol";
import {TruthBountyGovernor} from "../../contracts/governance/v2/TruthBountyGovernor.sol";
import {IGovernanceSnapshot} from "../../contracts/governance/v2/IGovernanceSnapshot.sol";
import {GovernanceGuardian} from "../../contracts/governance/v2/GovernanceGuardian.sol";
import {ITruthBountyGovernor} from "../../contracts/governance/v2/ITruthBountyGovernor.sol";
import {GovernanceRoleTopology} from "../../contracts/governance/v2/GovernanceRoleTopology.sol";
import {MockGovernedModule} from "../../contracts/mocks/MockGovernedModule.sol";

/**
 * @notice V2-SC-066 — Safe Governance Proposal Cancellation Semantics.
 *
 * Verifies that cancellation is only permitted under the four explicit conditions
 * (proposer, threshold, guardian, invalidation), that censorship and replay are
 * impossible, and that previously unsafe behaviors no longer occur:
 *  - a decided (Defeated) proposal can no longer be rewritten to Canceled,
 *  - a stale proposal targeting a deregistered module can be cleared by anyone.
 */
contract GovernanceCancellationTest is Test {
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
    TruthBountyGovernor internal governor;
    GovernanceGuardian internal guardianContract;
    MockGovernedModule internal module;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal voter = makeAddr("voter");
    address internal proposer = makeAddr("proposer");
    address internal rando = makeAddr("rando");
    address internal sink = makeAddr("sink");

    function setUp() public {
        vm.startPrank(admin);

        registry = new GovernedModuleRegistry(admin);
        token = new TruthBountyGovernanceToken(admin, TOKEN_SUPPLY);
        token.transfer(proposer, PROPOSER_BALANCE);
        token.transfer(voter, 800_000 ether);

        address[] memory noProposers = new address[](0);
        address[] memory noExecutors = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, noProposers, noExecutors, admin);

        governor = new TruthBountyGovernor(
            token,
            timelock,
            registry,
            IGovernanceSnapshot(address(0)),
            guardian,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_NUMERATOR
        );

        guardianContract = new GovernanceGuardian(admin, guardian, ITruthBountyGovernor(address(governor)));
        vm.stopPrank();

        vm.prank(guardian);
        governor.setGovernanceGuardianModule(address(guardianContract));

        vm.startPrank(admin);
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

    function _toActive() internal {
        vm.warp(block.timestamp + VOTING_DELAY + 1);
    }

    function _toSucceeded(uint256 proposalId) internal {
        _toActive();
        vm.prank(voter);
        governor.castVote(proposalId, 1);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
    }

    function _toQueued(uint256 proposalId) internal {
        _toSucceeded(proposalId);
        governor.queue(proposalId);
    }

    function _toDefeated() internal {
        vm.warp(block.timestamp + VOTING_DELAY + VOTING_PERIOD + 1);
    }

    /// @dev Mirrors GovernorTimelockControl's operation id derivation for a single-target proposal.
    function _timelockOperationIdFor(uint256 newValue) internal view returns (bytes32) {
        address[] memory targets = new address[](1);
        targets[0] = address(module);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = _proposalCalldata(newValue);
        bytes32 descriptionHash = keccak256(bytes(DESCRIPTION));
        bytes32 salt = bytes32(bytes20(address(governor))) ^ descriptionHash;
        return timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);
    }

    function _assertAuthority(
        uint256 proposalId,
        address caller,
        TruthBountyGovernor.CancelAuthority expected
    ) internal view {
        assertEq(
            uint256(governor.cancellationAuthority(proposalId, caller)),
            uint256(expected),
            "unexpected cancellation authority"
        );
    }

    function _expectUnauthorized(uint256 proposalId, address caller) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                TruthBountyGovernor.ProposalCancellationUnauthorized.selector, proposalId, caller
            )
        );
    }

    function _assertState(uint256 proposalId, IGovernor.ProposalState expected) internal view {
        assertEq(uint256(governor.state(proposalId)), uint256(expected));
    }

    // ------------------------------------------------- explicit cancel conditions

    function test_ProposerCancelsPendingProposal() public {
        uint256 id = _createProposal(11);
        _assertAuthority(id, proposer, TruthBountyGovernor.CancelAuthority.PROPOSER);

        vm.expectEmit(true, true, false, true, address(governor));
        emit TruthBountyGovernor.ProposalCancellationAuthorized(
            id, proposer, TruthBountyGovernor.CancelAuthority.PROPOSER
        );
        vm.prank(proposer);
        governor.cancel(id);

        _assertState(id, IGovernor.ProposalState.Canceled);
    }

    function test_ProposerCancelsActiveProposal() public {
        uint256 id = _createProposal(12);
        _toActive();

        _assertAuthority(id, proposer, TruthBountyGovernor.CancelAuthority.PROPOSER);
        vm.prank(proposer);
        governor.cancel(id);

        _assertState(id, IGovernor.ProposalState.Canceled);
    }

    function test_GuardianModuleVetoesPendingProposal() public {
        uint256 id = _createProposal(13);
        _assertAuthority(id, address(guardianContract), TruthBountyGovernor.CancelAuthority.GUARDIAN);

        // Emission order: governor attributes the cancellation, then the module records the veto.
        vm.expectEmit(true, true, false, true, address(governor));
        emit TruthBountyGovernor.ProposalCancellationAuthorized(
            id, address(guardianContract), TruthBountyGovernor.CancelAuthority.GUARDIAN
        );
        vm.expectEmit(true, true, false, true, address(governor));
        emit IGovernor.ProposalCanceled(id);
        vm.expectEmit(true, true, false, true, address(guardianContract));
        emit GovernanceGuardian.ProposalVetoed(id, guardian);

        vm.prank(guardian);
        guardianContract.vetoProposal(id);

        _assertState(id, IGovernor.ProposalState.Canceled);
    }

    function test_GuardianVetoesQueuedProposalAndClearsTimelock() public {
        uint256 id = _createProposal(14);
        _toQueued(id);
        bytes32 operationId = _timelockOperationIdFor(14);
        assertTrue(timelock.isOperationPending(operationId), "timelock op should be pending before veto");

        _assertAuthority(id, guardian, TruthBountyGovernor.CancelAuthority.GUARDIAN);
        vm.prank(guardian);
        governor.cancel(id);

        _assertState(id, IGovernor.ProposalState.Canceled);
        assertFalse(timelock.isOperationPending(operationId), "timelock op must be cleared by cancellation");

        // Anti-replay: the cleared operation can no longer be executed through the governor.
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        vm.expectRevert();
        governor.execute(id);
        assertEq(module.value(), 0, "cancelled proposal must never execute");
    }

    function test_ThresholdConditionAllowsPermissionlessCancelWhilePending() public {
        uint256 id = _createProposal(15);

        // Proposer sheds voting power below the proposal threshold while still Pending.
        vm.prank(proposer);
        token.transfer(sink, 150_000 ether);
        vm.warp(block.timestamp + 1);

        _assertAuthority(id, rando, TruthBountyGovernor.CancelAuthority.THRESHOLD);
        vm.expectEmit(true, true, false, true, address(governor));
        emit TruthBountyGovernor.ProposalCancellationAuthorized(
            id, rando, TruthBountyGovernor.CancelAuthority.THRESHOLD
        );
        vm.prank(rando);
        governor.cancel(id);

        _assertState(id, IGovernor.ProposalState.Canceled);
    }

    function test_InvalidatedProposalCancellableByAnyone() public {
        uint256 id = _createProposal(16);
        assertFalse(governor.isProposalInvalidated(id));

        vm.prank(admin);
        registry.removeModule("MOCK_MODULE");
        assertTrue(governor.isProposalInvalidated(id));

        // Regression vs prior behavior: without this condition only the guardian could stop a
        // proposal whose target was deregistered; now any caller may clear it.
        _assertAuthority(id, rando, TruthBountyGovernor.CancelAuthority.INVALIDATED);
        vm.expectEmit(true, true, false, true, address(governor));
        emit TruthBountyGovernor.ProposalCancellationAuthorized(
            id, rando, TruthBountyGovernor.CancelAuthority.INVALIDATED
        );
        vm.prank(rando);
        governor.cancel(id);

        _assertState(id, IGovernor.ProposalState.Canceled);
        // Terminal states fail closed: invalidation no longer reports authority after cancellation.
        assertFalse(governor.isProposalInvalidated(id));
        _assertAuthority(id, rando, TruthBountyGovernor.CancelAuthority.NONE);
    }

    function test_InvalidatedQueuedProposalCancellableByAnyoneAndClearsTimelock() public {
        uint256 id = _createProposal(17);
        _toQueued(id);
        bytes32 operationId = _timelockOperationIdFor(17);
        assertTrue(timelock.isOperationPending(operationId));

        vm.prank(admin);
        registry.removeModule("MOCK_MODULE");
        assertTrue(governor.isProposalInvalidated(id));

        vm.prank(rando);
        governor.cancel(id);

        _assertState(id, IGovernor.ProposalState.Canceled);
        assertFalse(timelock.isOperationPending(operationId));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        vm.expectRevert();
        governor.execute(id);
        assertEq(module.value(), 0, "invalidated proposal must never execute");
    }

    // ------------------------------------------------------- anti-censorship

    function test_UnauthorizedCallerCannotCancel() public {
        uint256 id = _createProposal(21);
        _assertAuthority(id, rando, TruthBountyGovernor.CancelAuthority.NONE);
        _expectUnauthorized(id, rando);
        vm.prank(rando);
        governor.cancel(id);
        _assertState(id, IGovernor.ProposalState.Pending);
    }

    function test_ProposerCannotCancelAfterVoteSucceeds() public {
        uint256 id = _createProposal(22);
        _toSucceeded(id);

        // Once the electorate has decided, the proposer may not veto their own passed proposal.
        _assertAuthority(id, proposer, TruthBountyGovernor.CancelAuthority.NONE);
        _expectUnauthorized(id, proposer);
        vm.prank(proposer);
        governor.cancel(id);
        _assertState(id, IGovernor.ProposalState.Succeeded);
    }

    function test_ThresholdConditionCannotCancelActiveVote() public {
        uint256 id = _createProposal(23);
        _toActive();

        // Proposer loses all voting power mid-vote, but the power snapshot is already taken.
        vm.prank(proposer);
        token.transfer(sink, PROPOSER_BALANCE);
        vm.warp(block.timestamp + 1);

        // Permissionless threshold invalidation must not be usable to censor a live vote.
        _assertAuthority(id, rando, TruthBountyGovernor.CancelAuthority.NONE);
        _expectUnauthorized(id, rando);
        vm.prank(rando);
        governor.cancel(id);
        _assertState(id, IGovernor.ProposalState.Active);
    }

    function test_RegisteredTargetBlocksInvalidatedAuthority() public {
        uint256 id = _createProposal(24);
        assertFalse(governor.isProposalInvalidated(id));
        _assertAuthority(id, rando, TruthBountyGovernor.CancelAuthority.NONE);
    }

    // ----------------------------------------------- prior unsafe behavior regression

    function test_DefeatedProposalCannotBeCancelledByGuardian() public {
        uint256 id = _createProposal(25);
        _toDefeated();
        _assertState(id, IGovernor.ProposalState.Defeated);

        // Regression: the previous implementation let the guardian flip a decided proposal from
        // Defeated to Canceled, rewriting decided history. Terminal states now fail closed.
        _assertAuthority(id, guardian, TruthBountyGovernor.CancelAuthority.NONE);
        _assertAuthority(id, address(guardianContract), TruthBountyGovernor.CancelAuthority.NONE);
        _expectUnauthorized(id, guardian);
        vm.prank(guardian);
        governor.cancel(id);
        _assertState(id, IGovernor.ProposalState.Defeated);
    }

    // ------------------------------------------------------------- anti-replay

    function test_DoubleCancelReverts() public {
        uint256 id = _createProposal(31);
        vm.prank(proposer);
        governor.cancel(id);
        _assertState(id, IGovernor.ProposalState.Canceled);

        // A cancellation cannot be replayed by any party, including the guardian.
        _assertAuthority(id, guardian, TruthBountyGovernor.CancelAuthority.NONE);
        _expectUnauthorized(id, guardian);
        vm.prank(guardian);
        governor.cancel(id);

        _expectUnauthorized(id, proposer);
        vm.prank(proposer);
        governor.cancel(id);
    }

    function test_CancelledProposalCannotBeReplayedIntoQueueOrExecute() public {
        uint256 id = _createProposal(32);
        _toActive();
        vm.prank(proposer);
        governor.cancel(id);

        // Cross the voting deadline: even if time passes, a cancelled proposal never resurrects.
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _assertState(id, IGovernor.ProposalState.Canceled);

        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                id,
                IGovernor.ProposalState.Canceled,
                bytes32(uint256(1) << uint8(IGovernor.ProposalState.Succeeded))
            )
        );
        governor.queue(id);

        vm.expectRevert();
        governor.execute(id);

        vm.expectRevert();
        governor.castVote(id, 1);

        assertEq(module.value(), 0, "cancelled proposal must never execute");
    }

    function test_CancelNonexistentProposalReverts() public {
        uint256 unknownId = uint256(keccak256("nonexistent"));
        _assertAuthority(unknownId, guardian, TruthBountyGovernor.CancelAuthority.NONE);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, unknownId));
        vm.prank(guardian);
        governor.cancel(unknownId);
    }

    // --------------------------------------------------------------------- fuzz

    function testFuzz_UnauthorizedCallerCannotCancel(address caller) public {
        vm.assume(caller != address(0));
        vm.assume(caller != guardian);
        vm.assume(caller != proposer);
        vm.assume(caller != address(guardianContract));

        uint256 id = _createProposal(41);

        _assertAuthority(id, caller, TruthBountyGovernor.CancelAuthority.NONE);
        _expectUnauthorized(id, caller);
        vm.prank(caller);
        governor.cancel(id);
        _assertState(id, IGovernor.ProposalState.Pending);
    }

    function testFuzz_ThresholdAuthorityTracksProposerVotes(uint256 transferAmount) public {
        uint256 amount = bound(transferAmount, 0, PROPOSER_BALANCE);
        uint256 id = _createProposal(42);

        if (amount > 0) {
            vm.prank(proposer);
            token.transfer(sink, amount);
            vm.warp(block.timestamp + 1);
        }

        uint256 remainingVotes = PROPOSER_BALANCE - amount;
        bool belowThreshold = remainingVotes < PROPOSAL_THRESHOLD;

        _assertAuthority(
            id,
            rando,
            belowThreshold
                ? TruthBountyGovernor.CancelAuthority.THRESHOLD
                : TruthBountyGovernor.CancelAuthority.NONE
        );

        if (belowThreshold) {
            vm.prank(rando);
            governor.cancel(id);
            _assertState(id, IGovernor.ProposalState.Canceled);
        } else {
            _expectUnauthorized(id, rando);
            vm.prank(rando);
            governor.cancel(id);
            _assertState(id, IGovernor.ProposalState.Pending);
        }
    }
}
