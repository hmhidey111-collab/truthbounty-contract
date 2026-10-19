// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/v2/Aggregation.sol";
import "../../contracts/v2/libraries/V2Errors.sol";
import "../../contracts/v2/interfaces/IAggregation.sol";
import "../../contracts/v2/interfaces/IVerification.sol";
import "../../contracts/v2/interfaces/IConfiguration.sol";
import "../../contracts/v2/interfaces/IV2Module.sol";
import "../../contracts/v2/interfaces/IV2Types.sol";
import "../../contracts/mocks/MockModuleRegistry.sol";

contract MockConfiguration is IConfiguration {
    ParameterSet public params;
    uint256 public latestVersion = 1;

    function publish(ParameterSet calldata) external returns (uint256) { return 0; }
    function getParameterSet(uint256) external view returns (ParameterSet memory) { return params; }
    function getLatestVersion() external view returns (uint256) { return latestVersion; }
    function getVersionCount() external view returns (uint256) { return 1; }
    
    function protocolVersion() external pure returns (uint16, uint16) { return (2, 0); }
    function supportsInterface(bytes4) external pure returns (bool) { return true; }

    function setParams(uint256 weightCap, uint256 participationThreshold, uint256 confidenceThreshold) external {
        params.weightCap = weightCap;
        params.participationThreshold = participationThreshold;
        params.confidenceThreshold = confidenceThreshold;
    }
}

contract MockVerification is IVerification {
    IV2Types.Verification[] public verifications;

    function protocolVersion() external pure returns (uint16, uint16) { return (2, 0); }
    function supportsInterface(bytes4) external pure returns (bool) { return true; }
    
    function submitVerification(uint256, bool, bytes calldata) external returns (uint256) { return 0; }
    
    function getVerification(uint256 verificationId) external view returns (IV2Types.Verification memory) {
        return verifications[verificationId];
    }
    
    function claimVerifications(uint256, uint256 cursor, uint256 limit) external view returns (uint256[] memory ids, uint256 nextCursor) {
        uint256 total = verifications.length;
        if (cursor >= total) return (new uint256[](0), total);
        uint256 end = cursor + limit;
        if (end > total) end = total;
        
        ids = new uint256[](end - cursor);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = cursor + i;
        }
        return (ids, end);
    }

    function addVerification(bool supportsClaim, uint256 stake) external {
        verifications.push(IV2Types.Verification({
            id: verifications.length,
            claimId: 1,
            verifier: address(0),
            supportsClaim: supportsClaim,
            stake: stake,
            submittedAt: uint64(block.timestamp)
        }));
    }
    
    function clearVerifications() external {
        delete verifications;
    }
}

contract AggregationTest is Test {
    Aggregation public aggregation;
    MockModuleRegistry public registry;
    MockConfiguration public config;
    MockVerification public verification;

    function setUp() public {
        registry = new MockModuleRegistry();
        config = new MockConfiguration();
        verification = new MockVerification();

        registry.permitModule(keccak256("CONFIGURATION"), address(config));
        registry.permitModule(keccak256("VERIFICATION"), address(verification));

        aggregation = new Aggregation(address(registry));
    }

    function test_zeroParticipation() public {
        config.setParams(100 ether, 100 ether, 5000);
        
        aggregation.finalizeAggregation(1);
        (bool finalized, bool accepted, uint256 sup, uint256 opp) = aggregation.outcome(1);
        
        assertTrue(finalized);
        assertFalse(accepted);
        assertEq(sup, 0);
        assertEq(opp, 0);
    }

    function test_quorumBoundaries() public {
        config.setParams(100 ether, 100 ether, 5000);
        
        verification.addVerification(true, 99 ether);
        aggregation.finalizeAggregation(1);
        (, bool accepted1, , ) = aggregation.outcome(1);
        assertFalse(accepted1, "Failed quorum");

        verification.clearVerifications();
        verification.addVerification(true, 100 ether);
        Aggregation agg2 = new Aggregation(address(registry));
        agg2.finalizeAggregation(1);
        (, bool accepted2, , ) = agg2.outcome(1);
        assertTrue(accepted2, "Passed quorum");
    }

    function test_ties() public {
        config.setParams(100 ether, 100 ether, 5000);
        
        verification.addVerification(true, 50 ether);
        verification.addVerification(false, 50 ether);
        
        aggregation.finalizeAggregation(1);
        (, bool accepted, , ) = aggregation.outcome(1);
        
        assertFalse(accepted, "Tie should fail closed");
    }

    function test_maximumWeights() public {
        config.setParams(50 ether, 100 ether, 5000); // weight cap is 50
        
        // Verifier stakes 100, but should be capped at 50
        verification.addVerification(true, 100 ether);
        verification.addVerification(false, 50 ether);
        
        aggregation.finalizeAggregation(1);
        (, bool accepted, uint256 sup, uint256 opp) = aggregation.outcome(1);
        
        assertEq(sup, 50 ether, "Should be capped");
        assertEq(opp, 50 ether, "Should be unchanged");
        assertFalse(accepted, "Tie fails closed");
    }

    function test_remainderAllocation_rounding() public {
        // Rounding test: 33% threshold.
        // Total weight = 100. 100 * 3333 / 10000 = 33.33 -> 34 required support.
        config.setParams(100 ether, 100, 3333);
        
        verification.addVerification(true, 33);
        verification.addVerification(false, 67);
        
        aggregation.finalizeAggregation(1);
        (, bool accepted, , ) = aggregation.outcome(1);
        assertFalse(accepted, "33 is less than rounded up 34");

        verification.clearVerifications();
        verification.addVerification(true, 34);
        verification.addVerification(false, 66);
        Aggregation agg2 = new Aggregation(address(registry));
        agg2.finalizeAggregation(1);
        (, bool accepted2, , ) = agg2.outcome(1);
        assertTrue(accepted2, "34 is enough");
    }
}
