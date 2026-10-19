// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/TruthBountyWeighted.sol";
import "../../contracts/MockERC20.sol";
import "../../contracts/MockReputationOracle.sol";

contract LifecycleFixture is Test {
    TruthBountyWeighted public truthBounty;
    MockERC20 public bountyToken;
    MockReputationOracle public reputationOracle;

    address public admin = address(0x1000);
    address public governance = address(0x2000);

    // Test users
    address public submitter = address(0x1);
    address public verifier1 = address(0x2);
    address public verifier2 = address(0x3);
    address public verifier3 = address(0x4);
    address public verifier4 = address(0x5);

    function setUp() public virtual {
        // Deploy dependencies
        vm.startPrank(admin);
        
        bountyToken = new MockERC20("Bounty Token", "BOUNTY");
        reputationOracle = new MockReputationOracle();
        
        truthBounty = new TruthBountyWeighted(
            address(bountyToken),
            address(reputationOracle),
            admin,
            governance
        );
        
        vm.stopPrank();

        // Provision tokens to verifiers
        _provision(verifier1, 1000 ether);
        _provision(verifier2, 1000 ether);
        _provision(verifier3, 1000 ether);
        _provision(verifier4, 1000 ether);
        
        // Setup initial reputation scores (must be admin/owner)
        vm.startPrank(admin);
        reputationOracle.setReputationScore(verifier1, 1 ether); // 1.0x
        reputationOracle.setReputationScore(verifier2, 1 ether); // 1.0x
        reputationOracle.setReputationScore(verifier3, 1 ether); // 1.0x
        reputationOracle.setReputationScore(verifier4, 1 ether); // 1.0x
        vm.stopPrank();
    }

    function _provision(address user, uint256 amount) internal {
        bountyToken.mint(user, amount);
        vm.prank(user);
        bountyToken.approve(address(truthBounty), type(uint256).max);
    }

    function _createAndStake(address _submitter, string memory content) internal returns (uint256) {
        vm.prank(_submitter);
        uint256 claimId = truthBounty.createClaim(content);
        return claimId;
    }

    function driveUndisputedClaim(bool pass) public returns (uint256 claimId) {
        claimId = _createAndStake(submitter, "Undisputed Claim Content");
        
        // Verifiers stake. `stake` requires msg.sender == tx.origin, so prank both.
        vm.prank(verifier1, verifier1);
        truthBounty.stake(100 ether);
        
        vm.prank(verifier2, verifier2);
        truthBounty.stake(100 ether);

        // Verifiers vote
        vm.prank(verifier1);
        truthBounty.vote(claimId, pass, 100 ether);
        
        vm.prank(verifier2);
        truthBounty.vote(claimId, pass, 100 ether);
        
        // Fast forward past verification window and confirmation delay
        vm.warp(block.timestamp + truthBounty.verificationWindowDuration() + truthBounty.confirmationDelay() + 1);
        
        truthBounty.settleClaim(claimId);
        
        // Claim rewards / return stakes
        if (pass) {
            vm.prank(verifier1);
            truthBounty.claimSettlementRewards(claimId);
            vm.prank(verifier2);
            truthBounty.claimSettlementRewards(claimId);
        } else {
            // If they both voted False, they won (since threshold wasn't met for True)
            vm.prank(verifier1);
            truthBounty.claimSettlementRewards(claimId);
            vm.prank(verifier2);
            truthBounty.claimSettlementRewards(claimId);
        }
    }

    function driveChallengedClaim(bool challengerWins) public returns (uint256 claimId) {
        claimId = _createAndStake(submitter, "Challenged Claim Content");
        
        // Vote sizes are chosen so one side clears the 60% settlement threshold and the
        // other cannot, with every vote >= the 100 minimum stake and within available stake.
        uint256 supportStake = challengerWins ? 100 ether : 200 ether;
        uint256 opposeStake = challengerWins ? 200 ether : 100 ether;

        // Verifier 1 & 2 support, Verifier 3 & 4 oppose.
        // `stake` requires msg.sender == tx.origin, so prank both.
        vm.prank(verifier1, verifier1); truthBounty.stake(supportStake);
        vm.prank(verifier2, verifier2); truthBounty.stake(supportStake);
        vm.prank(verifier3, verifier3); truthBounty.stake(opposeStake);
        vm.prank(verifier4, verifier4); truthBounty.stake(opposeStake);
        
        vm.prank(verifier1); truthBounty.vote(claimId, true, supportStake);
        vm.prank(verifier2); truthBounty.vote(claimId, true, supportStake);
        
        vm.prank(verifier3); truthBounty.vote(claimId, false, opposeStake);
        vm.prank(verifier4); truthBounty.vote(claimId, false, opposeStake);

        vm.warp(block.timestamp + truthBounty.verificationWindowDuration() + truthBounty.confirmationDelay() + 1);
        
        truthBounty.settleClaim(claimId);
        
        // Winners claim, losers withdraw slashed
        if (!challengerWins) {
            // True won
            vm.prank(verifier1); truthBounty.claimSettlementRewards(claimId);
            vm.prank(verifier2); truthBounty.claimSettlementRewards(claimId);
            vm.prank(verifier3); truthBounty.withdrawSettledStake(claimId);
            vm.prank(verifier4); truthBounty.withdrawSettledStake(claimId);
        } else {
            // False won
            vm.prank(verifier1); truthBounty.withdrawSettledStake(claimId);
            vm.prank(verifier2); truthBounty.withdrawSettledStake(claimId);
            vm.prank(verifier3); truthBounty.claimSettlementRewards(claimId);
            vm.prank(verifier4); truthBounty.claimSettlementRewards(claimId);
        }
    }
}
