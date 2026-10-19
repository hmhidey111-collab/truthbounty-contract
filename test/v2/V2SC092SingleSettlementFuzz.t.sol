// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/v2/StakeVault.sol";
import "../../contracts/v2/FinalRewardAllocator.sol";
import "../../contracts/v2/interfaces/IFinalRewardAllocator.sol";
import "../../contracts/v2/interfaces/IV2Types.sol";
import "../../contracts/mocks/MockModuleRegistry.sol";
import "../../contracts/MockERC20.sol";

contract V2SC092SingleSettlementFuzzTest is Test {
    uint256 internal constant CLAIM_ID = 23;
    uint256 internal constant STAKE = 100 ether;

    function testFuzz_claimRoundHasAtMostOneTerminalSettlement(uint8[] calldata actions) public {
        MockModuleRegistry registry = new MockModuleRegistry();
        MockERC20 token = new MockERC20("Stake", "STK");
        StakeVault vault = new StakeVault(address(registry), address(token), address(this));
        registry.permitModule(vault.MODULE_SETTLEMENT(), address(this));

        token.mint(address(this), STAKE);
        token.approve(address(vault), STAKE);
        vault.depositStake(CLAIM_ID, STAKE);

        uint256 successes;
        uint256 count = actions.length > 64 ? 64 : actions.length;
        for (uint256 i; i < count; ++i) {
            bytes memory callData;
            if (actions[i] % 5 == 0) {
                callData = abi.encodeCall(vault.settleConclusive, (address(token), address(this), CLAIM_ID, 0, STAKE, 0));
            } else if (actions[i] % 5 == 1) {
                callData = abi.encodeCall(vault.refundInconclusive, (address(token), address(this), CLAIM_ID, 0, STAKE));
            } else if (actions[i] % 5 == 2) {
                callData = abi.encodeCall(vault.finalUnlock, (address(token), address(this), CLAIM_ID, 0, STAKE));
            } else if (actions[i] % 5 == 3) {
                callData = abi.encodeCall(vault.carryForwardAppeal, (address(token), address(this), CLAIM_ID, 0, 1, STAKE));
            } else {
                callData = abi.encodeCall(vault.rolloverRound, (address(token), address(this), CLAIM_ID, 0, 1, STAKE));
            }

            (bool success,) = address(vault).call(callData);
            if (success) ++successes;
            assertLe(successes, 1, "claim-round finalized more than once");
        }

        IV2Types.SettlementOutcome outcome = vault.settlementOutcome(CLAIM_ID, 0);
        assertEq(outcome == IV2Types.SettlementOutcome.NONE, successes == 0);
        if (successes == 1) assertTrue(outcome != IV2Types.SettlementOutcome.NONE);
        (uint256 custody, uint256 obligations, uint256 actualBalance) = vault.conservation(address(token));
        assertEq(custody, obligations);
        assertEq(custody, actualBalance);
    }

    function testFuzz_rewardEntitlementCanOnlyBeClaimedOnce(uint96 rawFunding, uint96[] calldata requests) public {
        uint256 funding = bound(uint256(rawFunding), 1, 1e24);
        MockModuleRegistry registry = new MockModuleRegistry();
        MockERC20 token = new MockERC20("Reward", "RWD");
        FinalRewardAllocator allocator = new FinalRewardAllocator(address(registry), 2);
        registry.permitModule(allocator.MODULE_SETTLEMENT(), address(this));

        bytes32 settlementId = keccak256(abi.encode("single-claim", funding));
        token.mint(address(this), funding);
        token.approve(address(allocator), funding);
        allocator.fund(address(token), funding, settlementId);

        IFinalRewardAllocator.Allocation[] memory allocations = new IFinalRewardAllocator.Allocation[](1);
        address[] memory recipients = new address[](1);
        recipients[0] = address(this);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        allocations[0] = IFinalRewardAllocator.Allocation({
            category: IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
            accounts: recipients,
            effectiveWeights: weights,
            amount: funding,
            remainderRecipient: address(this)
        });
        allocator.finalizeRewards(
            settlementId,
            address(token),
            IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE,
            allocations
        );

        uint256 remaining = funding;
        uint256 claimed;
        uint256 count = requests.length > 64 ? 64 : requests.length;
        for (uint256 i; i < count; ++i) {
            uint256 amount = uint256(requests[i]);
            (bool success,) = address(allocator).call(abi.encodeCall(allocator.claim, (address(token), amount)));
            bool expectedSuccess = amount != 0 && amount <= remaining;
            assertEq(success, expectedSuccess);
            if (expectedSuccess) {
                remaining -= amount;
                claimed += amount;
            }
            assertEq(allocator.claimable(address(token), address(this)), remaining);
        }

        (bool replaySucceeded,) = address(allocator).call(
            abi.encodeCall(
                allocator.finalizeRewards,
                (
                    settlementId,
                    address(token),
                    IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE,
                    allocations
                )
            )
        );
        assertFalse(replaySucceeded, "finalized reward settlement replay succeeded");
        assertTrue(allocator.finalized(settlementId));
        assertEq(allocator.claimable(address(token), address(this)), remaining);
        assertEq(token.balanceOf(address(this)), claimed);
    }
}