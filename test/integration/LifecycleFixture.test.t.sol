// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../utils/LifecycleFixture.t.sol";

contract LifecycleFixtureTest is LifecycleFixture {
    
    function setUp() public override {
        super.setUp();
    }

    function testUndisputedClaimLifecycle() public {
        uint256 initialBal1 = bountyToken.balanceOf(verifier1);
        uint256 initialBal2 = bountyToken.balanceOf(verifier2);
        
        uint256 claimId = driveUndisputedClaim(true);
        
        // Assert state matches expected
        // Claim struct has 12 fields. 6th is `settled`
        (, , , , , bool settled, , , , , , ) = truthBounty.claims(claimId);
        assertTrue(settled, "Claim should be settled");
        
        // A unanimous settlement has no losing stake to slash, so the reward pool is zero
        // by construction: winners get their full stake back and the claim is finalised.
        (, , , , , bool v1RewardClaimed, bool v1StakeReturned, , , , ) = truthBounty.votes(claimId, verifier1);
        assertTrue(v1RewardClaimed, "V1 claim processed");
        assertTrue(v1StakeReturned, "V1 stake returned");
        assertEq(bountyToken.balanceOf(verifier1), initialBal1, "Verifier 1 recovered full stake");

        (, , , , , bool v2RewardClaimed, bool v2StakeReturned, , , , ) = truthBounty.votes(claimId, verifier2);
        assertTrue(v2RewardClaimed, "V2 claim processed");
        assertTrue(v2StakeReturned, "V2 stake returned");
        assertEq(bountyToken.balanceOf(verifier2), initialBal2, "Verifier 2 recovered full stake");
    }

    function testChallengedClaimLifecycle_ChallengerWins() public {
        uint256 claimId = driveChallengedClaim(true);
        
        (, , , , , bool settled, , , , , , ) = truthBounty.claims(claimId);
        assertTrue(settled, "Claim should be settled");
        
        // Vote struct has 11 fields. 6th is `rewardClaimed`, 7th is `stakeReturned`
        (, , , , , bool v1RewardClaimed, bool v1StakeReturned, , , , ) = truthBounty.votes(claimId, verifier1);
        assertFalse(v1RewardClaimed, "V1 should not claim rewards");
        assertTrue(v1StakeReturned, "V1 stake should be returned (minus slash)");
        
        (, , , , , bool v3RewardClaimed, bool v3StakeReturned, , , , ) = truthBounty.votes(claimId, verifier3);
        assertTrue(v3RewardClaimed, "V3 should have claimed rewards");
        assertTrue(v3StakeReturned, "V3 stake should be fully returned");
    }

    function testChallengedClaimLifecycle_SubmitterWins() public {
        uint256 claimId = driveChallengedClaim(false);
        
        (, , , , , bool settled, , , , , , ) = truthBounty.claims(claimId);
        assertTrue(settled, "Claim should be settled");
        
        (, , , , , bool v1RewardClaimed, bool v1StakeReturned, , , , ) = truthBounty.votes(claimId, verifier1);
        assertTrue(v1RewardClaimed, "V1 should have claimed rewards");
        assertTrue(v1StakeReturned, "V1 stake should be fully returned");
        
        (, , , , , bool v3RewardClaimed, bool v3StakeReturned, , , , ) = truthBounty.votes(claimId, verifier3);
        assertFalse(v3RewardClaimed, "V3 should not claim rewards");
        assertTrue(v3StakeReturned, "V3 stake should be returned (minus slash)");
    }
}
