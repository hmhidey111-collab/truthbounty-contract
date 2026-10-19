// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";

/// @notice Pull-based reward entitlements created from a finalized V2 outcome.
interface IFinalRewardAllocator is IV2Module {
    enum FinalOutcome {
        CONCLUSIVE_TRUE,
        CONCLUSIVE_FALSE,
        INCONCLUSIVE,
        DISPUTED,
        UNDISPUTED
    }

    enum RewardCategory {
        SUBMITTER_REFUND,
        SUCCESSFUL_CHALLENGE,
        VERIFIER_REWARD,
        PROTOCOL_FEE,
        INCONCLUSIVE_REFUND
    }

    struct Allocation {
        RewardCategory category;
        address[] accounts;
        uint256[] effectiveWeights;
        uint256 amount;
        address remainderRecipient;
    }

    event RewardAllocated(
        bytes32 indexed settlementId,
        RewardCategory indexed category,
        address indexed asset,
        address account,
        uint256 amount
    );
    event RewardPoolFunded(address indexed asset, uint256 amount, bytes32 indexed settlementId);
    event RewardsFinalized(
        bytes32 indexed settlementId,
        address indexed asset,
        FinalOutcome outcome,
        uint256 totalAmount
    );
    event RewardClaimed(address indexed asset, address indexed account, uint256 amount);

    function fund(address asset, uint256 amount, bytes32 settlementId) external;

    function finalizeRewards(
        bytes32 settlementId,
        address asset,
        FinalOutcome outcome,
        Allocation[] calldata allocations
    ) external;

    function claim(address asset, uint256 amount) external;
    function claimable(address asset, address account) external view returns (uint256);
    function funded(address asset) external view returns (uint256);
    function allocated(address asset) external view returns (uint256);
    function finalized(bytes32 settlementId) external view returns (bool);
    function finalOutcome(bytes32 settlementId) external view returns (FinalOutcome);
}