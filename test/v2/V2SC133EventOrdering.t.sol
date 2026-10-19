// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {
    CorrelatedFixtureModule,
    TreasuryOrderingFixture,
    RewardsOrderingFixture,
    SettlementOrderingFixture,
    CustodyOrderingFixture,
    ClaimsOrderingFixture,
    GovernanceOrderingFixture
} from "../../contracts/mocks/CrossModuleEventOrderingFixture.sol";

contract V2SC133EventOrderingTest is Test {
    bytes32 internal constant EVENT_SIG = keccak256("ModuleEntered(bytes32,bytes32,uint256)");
    bytes32 internal constant COMPLETE_SIG = keccak256("ModuleCompleted(bytes32,bytes32,uint256)");

    TreasuryOrderingFixture internal treasury;
    RewardsOrderingFixture internal rewards;
    SettlementOrderingFixture internal settlement;
    CustodyOrderingFixture internal custody;
    ClaimsOrderingFixture internal claims;
    GovernanceOrderingFixture internal governance;

    function setUp() public {
        // CREATE-address prediction permits immutable, cyclic caller/downstream wiring
        // without setters or privileged post-deployment configuration.
        address deployer = address(this);
        uint256 nonce = vm.getNonce(deployer);
        address treasuryAddress = vm.computeCreateAddress(deployer, nonce);
        address rewardsAddress = vm.computeCreateAddress(deployer, nonce + 1);
        address settlementAddress = vm.computeCreateAddress(deployer, nonce + 2);
        address custodyAddress = vm.computeCreateAddress(deployer, nonce + 3);
        address claimsAddress = vm.computeCreateAddress(deployer, nonce + 4);
        address governanceAddress = vm.computeCreateAddress(deployer, nonce + 5);

        treasury = new TreasuryOrderingFixture(rewardsAddress);
        rewards = new RewardsOrderingFixture(settlementAddress, treasury);
        settlement = new SettlementOrderingFixture(custodyAddress, rewards);
        custody = new CustodyOrderingFixture(claimsAddress, settlement);
        claims = new ClaimsOrderingFixture(governanceAddress, custody);
        governance = new GovernanceOrderingFixture(address(this), claims);

        assertEq(address(treasury), treasuryAddress);
        assertEq(address(governance), governanceAddress);
    }

    function test_exactNestedOrderingAndCorrelation() public {
        bytes32 correlationId = keccak256("settlement/claim/7/round/0");
        vm.recordLogs();
        governance.execute(correlationId, 7, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 12);
        address[6] memory emitters = [address(governance), address(claims), address(custody), address(settlement), address(rewards), address(treasury)];
        bytes32[6] memory moduleIds = [
            governance.MODULE_ID(),
            claims.MODULE_ID(),
            custody.MODULE_ID(),
            settlement.MODULE_ID(),
            rewards.MODULE_ID(),
            treasury.MODULE_ID()
        ];
        for (uint256 i; i < 6; ++i) {
            _assertLog(logs[i], emitters[i], EVENT_SIG, correlationId, moduleIds[i], 7);
            _assertLog(logs[11 - i], emitters[i], COMPLETE_SIG, correlationId, moduleIds[i], 7);
        }
        assertTrue(governance.consumed(correlationId));
        assertEq(treasury.reconciledClaim(correlationId), 7);
    }

    function test_replayRejectedWithoutAdditionalLogs() public {
        bytes32 correlationId = keccak256("one-shot");
        governance.execute(correlationId, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(GovernanceOrderingFixture.CorrelationAlreadyConsumed.selector, correlationId));
        governance.execute(correlationId, 1, 0);
    }

    function test_unauthorizedGovernanceAndNestedCallsFailClosed() public {
        bytes32 correlationId = keccak256("unauthorized");
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(GovernanceOrderingFixture.UnauthorizedCaller.selector, attacker));
        governance.execute(correlationId, 1, 0);

        vm.expectRevert(abi.encodeWithSelector(CorrelatedFixtureModule.UnauthorizedCaller.selector, address(this)));
        claims.finalize(correlationId, 1, false);
        assertFalse(governance.consumed(correlationId));
    }

    function test_zeroCorrelationRejected() public {
        vm.expectRevert(GovernanceOrderingFixture.ZeroCorrelationId.selector);
        governance.execute(bytes32(0), 1, 0);
    }

    function test_zeroAddressDependenciesRejected() public {
        vm.expectRevert(CorrelatedFixtureModule.ZeroAddress.selector);
        new TreasuryOrderingFixture(address(0));

        vm.expectRevert(GovernanceOrderingFixture.ZeroAddress.selector);
        new GovernanceOrderingFixture(address(0), claims);
    }

    function test_nestedFailureRollsBackEventsAndStorage() public {
        for (uint8 failAt = 1; failAt <= 6; ++failAt) {
            bytes32 correlationId = keccak256(abi.encode("atomic-failure", failAt));
            vm.recordLogs();
            vm.expectRevert(abi.encodeWithSelector(CorrelatedFixtureModule.InjectedFailure.selector, failAt));
            governance.execute(correlationId, 9, failAt);
            assertEq(vm.getRecordedLogs().length, 0);
            assertFalse(governance.consumed(correlationId));
            assertEq(governance.lastEnteredClaim(correlationId), 0);
            assertEq(claims.lastEnteredClaim(correlationId), 0);
            assertEq(custody.lastEnteredClaim(correlationId), 0);
            assertEq(settlement.lastEnteredClaim(correlationId), 0);
            assertEq(rewards.lastEnteredClaim(correlationId), 0);
            assertEq(treasury.lastEnteredClaim(correlationId), 0);
            assertEq(treasury.reconciledClaim(correlationId), 0);

            // A reverted attempt must not consume the replay marker or poison a retry.
            governance.execute(correlationId, 9, 0);
            assertTrue(governance.consumed(correlationId));
            assertEq(treasury.reconciledClaim(correlationId), 9);
        }
    }

    function testFuzz_everySuccessfulPathHasTwelveCorrelatedLogs(bytes32 correlationId, uint256 claimId) public {
        vm.assume(correlationId != bytes32(0));
        vm.recordLogs();
        governance.execute(correlationId, claimId, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 12);
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].topics[1], correlationId);
            assertEq(uint256(logs[i].topics[3]), claimId);
        }
        assertEq(treasury.reconciledClaim(correlationId), claimId);
    }

    function testFuzz_boundedSequenceReconcilesEveryOperation(uint8 rawCount, uint256 seed) public {
        uint256 count = bound(uint256(rawCount), 1, 16);
        for (uint256 i; i < count; ++i) {
            bytes32 correlationId = keccak256(abi.encode(address(this), seed, i));
            uint256 claimId = uint256(keccak256(abi.encode(seed, i, "claim")));
            governance.execute(correlationId, claimId, 0);
            assertTrue(governance.consumed(correlationId));
            assertEq(treasury.reconciledClaim(correlationId), claimId);
        }
    }

    function _assertLog(
        Vm.Log memory log,
        address emitter,
        bytes32 signature,
        bytes32 correlationId,
        bytes32 moduleId,
        uint256 claimId
    ) internal pure {
        assertEq(log.emitter, emitter);
        assertEq(log.topics.length, 4);
        assertEq(log.topics[0], signature);
        assertEq(log.topics[1], correlationId);
        assertEq(log.topics[2], moduleId);
        assertEq(uint256(log.topics[3]), claimId);
    }
}
