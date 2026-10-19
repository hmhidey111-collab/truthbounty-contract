// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ITreasuryAccounting
 * @dev Interface for the TreasuryAccounting contract that defines all external functions
 *      used by other protocol contracts (staking, rewards, slashing)
 */
interface ITreasuryAccounting {
    // =========== ENUMS ===========

    enum TreasuryAccount {
        STAKING_RESERVE,      // Tokens actively staked by users
        REWARDS_POOL,         // Reserved for reward distribution
        PROTOCOL_FEES,        // Accumulated protocol fees
        GOVERNANCE_RESERVES,  // Governance-controlled reserve fund
        ECOSYSTEM_FUND,       // Future ecosystem development fund
        SLASHED_TREASURY      // Tokens slashed from verifiers
    }

    // =========== STRUCTS ===========

    struct TokenMovement {
        uint256 timestamp;
        address from;
        address to;
        uint256 amount;
        TreasuryAccount fromAccount;
        TreasuryAccount toAccount;
        string movementType;
        bytes32 transactionId;
    }

    struct AccountSnapshot {
        uint256 timestamp;
        uint256 blockNumber;
        uint256[6] balances;
        uint256 totalAssets;
        address snapshotSender;
    }

    // =========== CANONICAL ACCOUNTING COMPONENTS ===========

    /**
     * @dev The canonical accounting components that make up tracked custody.
     *      Tracked custody = principal + rewards + fees + donations.
     *      Unexplained deltas are reconciled as a governed recovery path.
     */
    struct ConservationComponents {
        uint256 trackedPrincipal;
        uint256 trackedRewards;
        uint256 trackedFees;
        uint256 trackedDonations;
        uint256 unexplainedDelta;
        uint256 totalTrackedCustody;
    }

    // =========== EXTERNAL FUNCTIONS USED BY PROTOCOL CONTRACTS ===========

    /**
     * @dev Deposit tokens from external sources into a specific treasury account
     * @param targetAccount The treasury account to credit
     * @param amount Amount of tokens to deposit
     */
    function depositToAccount(TreasuryAccount targetAccount, uint256 amount) external;

    /**
     * @dev Record a user staking tokens into the staking reserve
     * @param user The user address that staked
     * @param amount The amount staked
     */
    function recordStake(address user, uint256 amount) external;

    /**
     * @dev Record a user unstaking tokens from the staking reserve
     * @param user The user address that unstaked
     * @param amount The amount unstaked
     */
    function recordUnstake(address user, uint256 amount) external;

    /**
     * @dev Record a slashing event moving funds from staking to slashed treasury
     * @param verifier The verifier address that was slashed
     * @param amount The amount slashed
     */
    function recordSlash(address verifier, uint256 amount) external;

    /**
     * @dev Record reward distribution from the rewards pool
     * @param recipient The address receiving the reward
     * @param amount The reward amount
     */
    function recordRewardDistribution(address recipient, uint256 amount) external;

    /**
     * @dev Transfer funds between internal treasury accounts
     * @param fromAccount Source account
     * @param toAccount Target account
     * @param amount Amount to transfer
     * @param movementType Description of the movement
     */
    function transferBetweenAccounts(
        TreasuryAccount fromAccount,
        TreasuryAccount toAccount,
        uint256 amount,
        string calldata movementType
    ) external;

    /**
     * @dev Record an external donation into a treasury account.
     *      Donations are an accounting component and must not be conflated with fees.
     * @param targetAccount The treasury account to credit
     * @param amount Amount of tokens donated
     */
    function recordDonation(TreasuryAccount targetAccount, uint256 amount) external;

    /**
     * @dev Record unexplained token deltas discovered during reconciliation.
     *      Unexplained deltas enter a governed recovery path and must not be
     *      silently absorbed into tracked custody.
     * @param delta The unexplained delta (may be negative via signed intent)
     * @param recoveryAccount The account to route the delta through
     * @param reason Human-readable reason for the recovery route
     */
    function recordUnexplainedDelta(
        int256 delta,
        TreasuryAccount recoveryAccount,
        string calldata reason
    ) external;

    // =========== VIEW FUNCTIONS ===========

    /**
     * @dev Get the balance of a specific treasury account
     */
    function getAccountBalance(TreasuryAccount account) external view returns (uint256);

    /**
     * @dev Get all account balances
     */
    function getAccountBalances() external view returns (uint256[6] memory);

    /**
     * @dev Calculate total assets across all accounts
     */
    function calculateTotalAssets() external view returns (uint256);

    /**
     * @dev Return the canonical conservation components used for reconciliation.
     */
    function getConservationComponents() external view returns (ConservationComponents memory);

    /**
     * @dev Return the total tracked custody (components sum).
     */
    function getTotalTrackedCustody() external view returns (uint256);

    /**
     * @dev Return the unexplained delta currently awaiting governed recovery.
     */
    function getUnexplainedDelta() external view returns (int256);

    // =========== EVENTS ===========

    event FundsTransferred(
        bytes32 indexed transactionId,
        TreasuryAccount fromAccount,
        TreasuryAccount toAccount,
        uint256 amount,
        address indexed operator,
        string movementType
    );

    event ExternalDeposit(
        bytes32 indexed transactionId,
        TreasuryAccount targetAccount,
        uint256 amount,
        address indexed depositor
    );

    event ExternalWithdrawal(
        bytes32 indexed transactionId,
        TreasuryAccount sourceAccount,
        uint256 amount,
        address indexed recipient,
        address indexed operator
    );

    event AccountSnapshotCreated(
        uint256 indexed snapshotIndex,
        uint256 timestamp,
        uint256 totalAssets,
        address indexed snapshotter
    );

    event DonationRecorded(
        bytes32 indexed transactionId,
        TreasuryAccount indexed targetAccount,
        uint256 amount,
        address indexed donor
    );

    event UnexplainedDeltaRecorded(
        bytes32 indexed transactionId,
        int256 delta,
        TreasuryAccount indexed recoveryAccount,
        string reason
    );

    event ConservationViolation(
        uint256 expectedTotal,
        uint256 actualTotal,
        int256 unexplainedDelta,
        bytes32 indexed reconciliationId
    );
}
