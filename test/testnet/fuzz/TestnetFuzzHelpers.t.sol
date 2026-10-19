// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

/// @title Testnet Fuzz Helpers (V2-SC-130)
/// @notice Fuzz test helpers for bounded random protocol operations.
///         Provides seeded randomness, bounded amounts, and state transitions.
///
/// Acceptance Criteria:
///   AC-7: Stateful fuzz/invariant coverage for every affected protocol property
///   AC-8: Regression tests for each legacy or audit defect displaced
library TestnetFuzzHelpers {
    uint256 public constant MIN_STAKE = 100 * 10**18;
    uint256 public constant MAX_STAKE = 100_000 * 10**18;

    function boundedAmount(uint256 seed) internal pure returns (uint256) {
        return MIN_STAKE + (seed % (MAX_STAKE - MIN_STAKE));
    }

    function boundedAmountInRange(uint256 seed, uint256 min, uint256 max) internal pure returns (uint256) {
        if (min >= max) revert("Invalid range");
        uint256 range = max - min;
        return min + (seed % range);
    }

    function randomSupport(uint256 seed) internal pure returns (bool) {
        return (seed % 2) == 0;
    }

    function randomVerifier(uint256 seed, address[] memory verifiers) internal pure returns (address) {
        if (verifiers.length == 0) revert("No verifiers available");
        return verifiers[seed % verifiers.length];
    }

    function randomClaimId(uint256 seed, uint256 claimCount) internal pure returns (uint256) {
        if (claimCount == 0) revert("No claims available");
        return seed % claimCount;
    }

    function validateClaimCreation(uint256 claimId, uint256 counter) internal pure {
        if (claimId >= counter) revert("Invalid claim ID");
    }

    function validateStaking(uint256 amount) internal pure {
        if (amount < MIN_STAKE) revert("Stake below minimum");
        if (amount > MAX_STAKE) revert("Stake exceeds maximum");
    }

    function validateVoting(bool voted, uint256 stakeAmount) internal pure {
        if (!voted && stakeAmount > 0) revert("Invalid vote state");
        if (voted && stakeAmount == 0) revert("Vote amount cannot be zero");
    }

    function validateSettlement(bool settled, bool finalized) internal pure {
        if (settled && finalized) revert("Claim already finalized");
    }

    function validatePauseLevel(uint8 level) internal pure {
        if (level > 3) revert("Invalid pause level");
    }

    function validateVersion(uint64 major, uint64 minor, uint64 patch) internal pure {
        if (major == 0) revert("Invalid version");
    }

    function validateBps(uint256 bps) internal pure {
        if (bps > 10000) revert("BPS exceeds maximum");
    }

    function validateTimelock(uint256 delay) internal pure {
        if (delay < 3600) revert("Timelock below minimum");
    }

    function boundedLoopCheck(uint256 iterations, uint256 max) internal pure {
        if (iterations > max) revert("Loop exceeds bounded limit");
    }

    function assertNoUnboundedLoops(uint256 iterations) internal pure {
        if (iterations > 100) revert("Potential unbounded loop detected");
    }

    function deterministicClaimId(uint256 beforeCounter, uint256 afterCounter, uint256 created) internal pure {
        assertEq(afterCounter, beforeCounter + created);
    }

    function assertMonotonic(uint256 prev, uint256 curr) internal pure {
        if (curr <= prev) revert("Non-monotonic sequence");
    }

    function assertAssetBalance(
        uint256 balanceBefore,
        uint256 balanceAfter,
        uint256 expectedChange
    ) internal pure {
        if (balanceBefore - balanceAfter != expectedChange) {
            revert("Asset conservation violated");
        }
    }

    function assertNoZeroAddress(address addr) internal pure {
        if (addr == address(0)) revert("Zero address detected");
    }

    function assertEventVersion(uint16 version) internal pure {
        if (version != 1) revert("Unexpected event schema version");
    }

    function toBoolean(uint256 value) internal pure returns (bool) {
        return value % 2 == 0;
    }
}

function assertEq(uint256 a, uint256 b) pure {
    if (a != b) revert("Values not equal");
}
