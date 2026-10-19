// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Testnet Helper Utilities (V2-SC-130)
/// @notice Pure utility functions for testnet deployment and recovery tests.
///         Provides assertion helpers, type conversion, and state verification.
library TestnetHelpers {
    uint256 public constant MIN_STAKE = 100 * 10**18;
    uint256 public constant VERIFICATION_WINDOW = 2 days;
    uint256 public constant MAX_STAKE = 100_000 * 10**18;

    function assertGt(uint256 a, uint256 b) internal pure {
        if (a <= b) revert("Assertion failed: not greater than");
    }

    function assertGe(uint256 a, uint256 b) internal pure {
        if (a < b) revert("Assertion failed: not greater than or equal");
    }

    function assertLe(uint256 a, uint256 b) internal pure {
        if (a > b) revert("Assertion failed: not less than or equal");
    }

    function assertLt(uint256 a, uint256 b) internal pure {
        if (a >= b) revert("Assertion failed: not less than");
    }

    function assertEq(uint256 a, uint256 b) internal pure {
        if (a != b) revert("Assertion failed: values not equal");
    }

    function assertEqBool(bool a, bool b) internal pure {
        if (a != b) revert("Assertion failed: booleans not equal");
    }

    function assertRevert(bool reverted) internal pure {
        if (!reverted) revert("Expected revert not triggered");
    }

    function verifyNoZeroAddress(address addr, string memory label) internal pure {
        if (addr == address(0)) revert(string(abi.encodePacked("Zero address: ", label)));
    }

    function verifyNonZero(uint256 value, string memory label) internal pure {
        if (value == 0) revert(string(abi.encodePacked("Zero value: ", label)));
    }

    function boundAmount(uint256 amount) internal pure returns (uint256) {
        if (amount < MIN_STAKE) return MIN_STAKE;
        if (amount > MAX_STAKE) return MAX_STAKE;
        return amount;
    }

    function validateBps(uint256 bps) internal pure {
        if (bps > 10000) revert("BPS exceeds maximum (10000)");
    }

    function validatePauseLevel(uint8 level) internal pure {
        if (level > 3) revert("Invalid pause level");
    }

    function validateVersion(uint256 major, uint256 minor, uint256 patch) internal pure {
        if (major == 0) revert("Invalid version: major must be > 0");
    }

    function validateTimelock(uint256 delay) internal pure {
        if (delay < 3600) revert("Timelock below minimum (1 hour)");
    }

    function isValidClaimId(uint256 claimId, uint256 counter) internal pure returns (bool) {
        return claimId < counter;
    }

    function monotonicCheck(uint256 prev, uint256 curr) internal pure returns (bool) {
        return curr > prev;
    }

    function computeEffectiveStake(uint256 stakeAmount, uint256 reputation) internal pure returns (uint256) {
        return (stakeAmount * reputation) / 1e18;
    }

    function computeWeightedVote(uint256 effectiveStake, bool support, uint256 totalFor, uint256 totalAgainst) internal pure returns (uint256 newFor, uint256 newAgainst) {
        if (support) {
            return (totalFor + effectiveStake, totalAgainst);
        }
        return (totalFor, totalAgainst + effectiveStake);
    }

    function assertAssetConservation(
        uint256 balanceBefore,
        uint256 balanceAfter,
        uint256 transferredAmount
    ) internal pure {
        assertEq(balanceBefore - balanceAfter, transferredAmount);
    }

    function toBytes32(uint256 value) internal pure returns (bytes32) {
        return bytes32(value);
    }

    function toUint256(bytes32 value) internal pure returns (uint256) {
        return uint256(value);
    }

    function keccakString(string memory s) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(s));
    }

    function roleHash(string memory role) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(role));
    }

    function parsePauseLevel(uint8 level) internal pure returns (string memory) {
        if (level == 0) return "Normal";
        if (level == 1) return "HighRisk";
        if (level == 2) return "Financial";
        if (level == 3) return "Shutdown";
        revert("Invalid pause level");
    }

    function verifyBoundedLoop(uint256 iterations, uint256 max) internal pure {
        if (iterations > max) revert("Loop exceeds bounded execution limit");
    }
}
