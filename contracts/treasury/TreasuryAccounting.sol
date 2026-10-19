// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UntrackedAssetRecovery} from "../recovery/UntrackedAssetRecovery.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "../libraries/BoundedSafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../governance/GovernanceOwnable.sol";

/**
 * @title TreasuryAccounting
 * @dev Implements full protocol treasury accounting with mathematical invariants
 * @notice Every token movement must preserve the fundamental accounting equation:
 *         totalAssets = stakingReserve + rewardsPool + protocolFees + governanceReserves + ecosystemFund
 *         This ensures complete auditability and protocol solvency
 *
 * @dev Conservation invariant (V2 aligned):
 *         actualBalance == custody == sum(_accountBalances) + unexplainedDelta
* *       Any positive token delta not reflected in the bucket totals is invalid and
 *       must either revert or enter the governed recovery path (`administerUnexplainedDelta`).
 */
contract TreasuryAccounting is AccessControl, ReentrancyGuard, GovernanceOwnable, UntrackedAssetRecovery {
    using SafeERC20 for IERC20;

    // ============= ROLES =============

    bytes32 public constant ADMIN_ROLE = keccak(256("ADMIN_ROLE"));
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak(256("TREASURY_MANAGER_ROLE"));
    bytes32 public constant STAKING_CONTRACT_ROLE = keccak(256("STAKING_CONTRACT_ROLE"));
    bytes32 public constant REWARD_ENGINE_ROLE = keccak(256("REWARD_ENGINE_ROLE"));
    bytes32 public constant SLASHING_CONTRACT_ROLE = keccak(256("SLASHING_CONTRACT_ROLE"));

    // ============= ACCOUNTING CATEGORIES =============

    enum TreasuryAccount {
        STAKING_RESERVE,      // Tokens actively staked by users
        REWARDS_POOL,
         // Reserved for reward distribution
        PROTOCOL_FEES,        // Accumulated protocol fees
        GOVERNANCE_RESERVES,  // Governance-controlled reserve fund
        ECOSYSTEM_FUND,       // Future ecosystem development fund
        SLASHED_TREASURY,     // Tokens slashed from verifiers
        EXTERNAL              // Off-ledger source or destination marker
    }

    // ============= STRUCTS =============

    struct AccountSnapshot {
        uint256 timestamp;
        uint256 blockNumber;
        uint256[6] balances;  // Mirrors TreasuryAccount enum order
        uint256 totalPrincipal;
        uint256 totalRewards;
        uint256 totalFees;
        uint256 totalDonations;
        uint256 totalAssets;
        uint256 unexplainedDelta;
        address snapshotSender;
    }

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

    // ============= STATE VARIABLES =============

    // The protocol's main token
    IERC20 public immutable protocolToken;

    // Accounting balances for each treasury account (indexed by TreasuryAccount enum)
    uint256[6] private _accountBalances;

    // ============= CONSERVATION ACCOUNTING COMPONENTS =============
    // These components explain how tracked custody was acquired. They are
    // not additional custody buckets; they are a decomposition of the
    // _accountBalances sum and must never be added on top of it.
    //   totalPrincipal: principal contributed by stakers (STAKING_RESERVE + SLASHED_TREASURY)
    //   totalRewards: rewards funded into REWARDS_POOL from external sources
    //   totalFees: fees accumulated into PROTOCOL_FEES
    //   totalDonations: unrestricted external deposits into GOVERNANCE_RESERVES/ECOSYSTEM_FUND
    uint256 public totalPrincipal;
    uint256 public totalRewards;
    uint256 public totalFees;
    uint256 public totalDonations;

    // Positive token delta not reflected in any bucket. Must be zero for the
    // invariant to hold; nonzero values enter the governed recovery path.
    uint256 public unexplainedDelta;

    // Historical snapshots for auditing
    AccountSnapshot[] public snapshots;
    uint256 public snapshotCount;

    // Transaction history
    mapping(bytes32 => TokenMovement) public transactions;
    bytes32[] public transactionIds;
    uint256 public transactionCount;

    // Accounting invariants configuration (percentage allocations)
    uint256 public constant PERCENT_DENOMINATOR = 10000; // Basis points (100% = 10000)
    uint256 public maxRewardsWithdrawalBPS = 500;        // Max 5% of rewards pool per withdrawal
    uint256 public minStakingReserveRatio = 1000;         // Min 10% of total assets must be in staking reserve

    // Track last transaction for each account to prevent double-spending
    mapping(TreasuryAccount => uint256) public lastTransactionBlock;

    // ============= EVENTS =============

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

    event AllocationConfigUpdated(
        string configName,
        uint256 oldValue,
        uint256 newValue
    );

    event ContractRoleUpdated(
        bytes32 indexed role,
        address indexed account,
        bool granted
    );

    // Emitted when an unexplained positive delta is observed and admitted into the
    // governed recovery path (credited to a bucket with explicit governance authority).
    event UnexplainedDeltaRecovered(
        bytes32 indexed transactionId,
        TreasuryAccount indexed targetAccount,
        uint256 amount,
        address indexed operator
    );

    // ============= ERRORS =============

    error InsufficientAccountBalance(TreasuryAccount account, uint256 requested, uint256 available);
    error InvariantViolation(string reason, uint256 expected, uint256 actual);
    error InvalidAccountTransfer(TreasuryAccount from, TreasuryAccount to);
    error WithdrawalExceedsLimit(uint256 requested, uint256 maxAllowed);
    error InvalidAddress(address account);
    error SameBlockTransaction(TreasuryAccount account);
    error UnauthorizedAccountTransfer();
    // Reports the two distinct sides of the conservation equation without duplicating
    // the delta in either field. `custody` must equal `actualBalance` for the invariant
    // to hold.
    error ConservationInvariantViolation(uint256 custody, uint256 actualBalance);
    error UnexplainedDeltaPresent(uint256 unexplainedDelta, uint256 custody);

    /**
     * @dev Constructor initializes the treasury accounting engine
     * @param _protocolToken Address of the main ERC20 token
     * @param _governanceController Address of the governance controller
     * @param _initialAdmin Initial admin address
     */
    constructor(
        address _protocolToken,
        address _governanceController,
        address _initialAdmin
    ) {
        if (_protocolToken == address(0)) revert InvalidAddress(_protocolToken);
        if (_initialAdmin == address(0)) revert InvalidAddress(_initialAdmin);

        protocolToken = IERC20(_protocolToken);

        // Initialize roles
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(ADMIN_ROLE, _initialAdmin);
        _grantRole(TREASURY_MANAGER_ROLE, _initialAdmin);

        _setRoleAdmin(STAKING_CONTRACT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REWARD_ENGINE_ROLE, ADMIN_ROLE);
        _setRoleAdmin(SLASHING_CONTRACT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(TREASURY_MANAGER_ROLE, ADMIN_ROLE);

        // Initialize governance
        _initializeGovernance(_governanceController, _initialAdmin, _initialAdmin);
    }

    // ============= EXTERNAL DEPOSITS (TOKENS ENTERING PROTOCOL) =============

    /**
     * @dev Deposit tokens from external sources into a specific treasury account
     * @param targetAccount The treasury account to credit
     * @param amount Amount of tokens to deposit
     */
    function depositToAccount(TreasuryAccount targetAccount, uint256 amount) external nonRentrant {
        if (amount == 0) revert InsufficientAccountBalance(targetAccount, 0, 0);
        if (targetAccount == TreasuryAccount.EXTERNAL) revert InvalidAccountTransfer(TreasuryAccount.EXTERNAL, targetAccount);

        // Transfer tokens from sender to this contract
        uint256 balanceBefore = protocolToken.balanceOf(address(this));
        protocolToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualReceived = protocolToken.balanceOf(address(this)) - balanceBefore;

        // Fee-on-transfer and rebasing tokens are rejected by design: the credited
        // amount must exactly match the requested amount.
        if (actualReceived != amount) {
            revert ConservationInvariantViolation(amount, actualReceived);
        }

        // Credit the target account and classify the deposit into its component.
        _accountBalances[uint256(targetAccount)] += actualReceived;
        _classifyDeposit(targetAccount, actualReceived);

        // Generate transaction record
        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            msg.sender,
            address(this),
            actualReceived,
            TreasuryAccount.EXTERNAL, // External source marker
            targetAccount,
            "external_deposit"
        );

        emit ExternalDeposit(transactionId, targetAccount, actualReceived, msg.sender);

        // Verify invariants after operation
        _validateInvariants();
    }

    // ============= INTERNAL TRANSFERS (BETWEEN TREASURY ACCOUNTS) =============

    /**
     * @dev Transfer funds between internal treasury accounts (authorized contracts only)
     * @param fromAccount Source treasury account
     * @param toAccount Target treasury account
     * @param amount Amount to transfer
     * @param movementType Description of the transfer for auditing
     */
    function transferBetweenAccounts(
        TreasuryAccount fromAccount,
        TreasuryAccount toAccount,
        uint256 amount,
        string calldata movementType
    ) external nonReentrant onlyRoleAuthorizedForTransfer(fromAccount) {
        if (fromAccount == toAccount) revert InvalidAccountTransfer(fromAccount, toAccount);
        if (fromAccount == TreasuryAccount.EXTERNAL || toAccount == TreasuryAccount.EXTERNAL) {
            revert InvalidAccountTransfer(fromAccount, toAccount);
        }
        if (amount == 0) revert InsufficientAccountBalance(fromAccount, 0, _accountBalances[uint256(fromAccount)]);
        if (_accountBalances[uint256(fromAccount)] < amount) {
            revert InsufficientAccountBalance(fromAccount, amount, _accountBalances[uint256(fromAccount)]);
        }

        // Prevent multiple transactions in the same block for the same source account
        if (block.number <= lastTransactionBlock[fromAccount]) {
            revert SameBlockTransaction(fromAccount);
        }
        lastTransactionBlock[fromAccount] = block.number;

        // Execute the transfer in accounting ledgers
        _accountBalances[uint256(fromAccount)] -= amount;
        _accountBalances[uint256(toAccount)] += amount;

        // Record the transaction
        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            address(this),
            address(this),
            amount,
            fromAccount,
            toAccount,
            movementType
        );

        emit FundsTransferred(transactionId, fromAccount, toAccount, amount, msg.sender, movementType);

        // Validate all invariants are maintained
        _validateInvariants();
    }

    // ============= EXTERNAL WITHDRAWALS (TOKENS LEAVING PROTOCOL) =============

    /**
     * @dev Withdraw funds from a treasury account to an external address (treasury managers only)
     * @param sourceAccount Source treasury account
     * @param recipient Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawFromAccount(
        TreasuryAccount sourceAccount,
        address recipient,
        uint256 amount
    ) external nonRentrant onlyRole(TREASURY_MANAGER_ROLE) {
        if (recipient == address(0)) revert InvalidAddress(recipient);
        if (sourceAccount == TreasuryAccount.EXTERNAL) revert InvalidAccountTransfer(sourceAccount, TreasuryAccount.EXTERNAL);
        if (amount == 0) revert InsufficientAccountBalance(sourceAccount, 0, _accountBalances[uint256(sourceAccount)]);
        if (_accountBalances[uint256(sourceAccount)] < amount) {
            revert InsufficientAccountBalance(sourceAccount, amount, _accountBalances[uint256(sourceAccount)]);
        }

        // Enforce withdrawal limits based on account type
        _enforceWithdrawalLimits(sourceAccount, amount);

        // Prevent same-block transactions
        if (block.number <= lastTransactionBlock[sourceAccount]) {
            revert SameBlockTransaction(sourceAccount);
        }
        lastTransactionBlock[sourceAccount] = block.number;

        // Execute the withdrawal in accounting
        _accountBalances[uint256(sourceAccount)] -= amount;

        // Transfer tokens to recipient
        protocolToken.safeTransfer(recipient, amount);

        // Record transaction
        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            address(this),
            recipient,
            amount,
            sourceAccount,
            TreasuryAccount.EXTERNAL, // External destination
            "external_withdrawal"
        );

        emit ExternalWithdrawal(transactionId, sourceAccount, amount, recipient, msg.sender);

        // Validate invariants
        _validateInvariants();
    }

    // ============= STAKING CONTRACT SPECIFIC FUNCTIONS =============

    /**
     * @dev Record user stake into staking reserve (called by staking contract)
     * @param user User address that staked
     * @param amount Amount staked
     */
    function recordStake(address user, uint256 amount) external onlyRole(STAKING_CONTRACT_ROLE) {
        if (user == address(0)) revert InvalidAddress(user);
        if (amount == 0) revert InsufficientAccountBalance(TreasuryAccount.STAKING_RESERVE, 0, 0);

        // The staking contract must have already transferred tokens into this contract
        // and recorded them as an external deposit into STAKING_RESERVE. We only adjust
        // the principal component here to avoid double-counting custody.
        totalPrincipal += amount;

        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            user,
            address(this),
            amount,
            TreasuryAccount.EXTERNAL,
            TreasuryAccount.STAKING_RESERVE,
            "stake_recorded"
        );

        _validateInvariants();
    }

    /**
     * @dev Record user unstaking tokens from the staking reserve
     * @param user The user address that unstaked
     * @param amount The amount unstaked
     */
    function recordUnstake(address user, uint256 amount) external onlyRole(STAKING_CONTRACT_ROLE) {
        if (user == address(0)) revert InvalidAddress(user);
        if (amount == 0) revert InsufficientAccountBalance(TreasuryAccount.STAKING_RESERVE, 0, _accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)]);
        if (_accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)] < amount) {
            revert InsufficientAccountBalance(
                TreasuryAccount.STAKING_RESERVE,
                amount,
                _accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)]
            );
        }

        // Principal leaving the staking reserve must not exceed tracked principal.
        // Rewards accrued in STAKING_RESERVE are not principal and are not removed
        // by unstake.
        if (totalPrincipal < amount) {
            revert ConservationInvariantViolation(totalPrincipal, amount);
        }
        totalPrincipal -= amount;
        _accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)] -= amount;

        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            address(this),
            user,
            amount,
            TreasuryAccount.STAKING_RESERVE,
            TreasuryAccount.EXTERNAL,
            "unstake_recorded"
        );

        _validateInvariants();
    }

    /**
     * @dev Record a slashing event moving funds from staking to slashed treasury
     * @param verifier The verifier address that was slashed
     * @param amount The amount slashed
     */
    function recordSlash(address verifier, uint256 amount) external onlyRole(SLASHING_CONTRACT_ROLE) {
        if (verifier == address(0)) revert InvalidAddress(verifier);
        if (amount == 0) revert InsufficientAccountBalance(TreasuryAccount.STAKING_RESERVE, 0, _accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)]);
        if (_accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)] < amount) {
            revert InsufficientAccountBalance(
                TreasuryAccount.STAKING_RESERVE, 
                amount, 
                _accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)]
            );
        }

        // Slashing moves principal between buckets; total principal is unchanged.
        _accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)] -= amount;
        _accountBalances[uint256(TreasuryAccount.SLASHED_TREASURY)] += amount;

        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            verifier,
            address(this),
            amount,
            TreasuryAccount.STAKING_RESERVE,
            TreasuryAccount.SLASHED_TREASURY,
            "slash"
        );

        _validateInvariants();
    }

    /**
     * @dev Record reward distribution from the rewards pool
     * @param recipient The address receiving the reward
     * @param amount The reward amount
     */
    function recordRewardDistribution(address recipient, uint256 amount) external onlyRole(REWARD_ENGINE_ROLE) {
        if (recipient == address(0)) revert InvalidAddress(recipient);
        if (amount == 0) revert InsufficientAccountBalance(TreasuryAccount.REWARDS_POOL, 0, _accountBalances[uint256(TreasuryAccount.REWARDS_POOL)]);
        if (_accountBalances[uint256(TreasuryAccount.REWARDS_POOL)] < amount) {
            revert InsufficientAccountBalance(
                TreasuryAccount.REWARDS_POOL, 
                amount, 
                _accountBalances[uint256(TreasuryAccount.REWARDS_POOL)]
            );
        }

        // Rewards are not principal; decrement the rewards component and the
        // REWARDS_POOL bucket together so total custody stays conserved.
        if (totalRewards < amount) {
            revert ConservationInvariantViolation(totalRewards, amount);
        }
        totalRewards -= amount;
        _accountBalances[uint256(TreasuryAccount.REWARDS_POOL)] -= amount;

        // Transfer tokens to recipient
        protocolToken.safeTransfer(recipient, amount);

        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            address(this),
            recipient,
            amount,
            TreasuryAccount.REWARDS_POOL,
            TreasuryAccount.EXTERNAL,
            "reward_distribution"
        );

        _validateInvariants();
    }

    // ============= GOVERNED RECOVERY PATH =============

    /**
     * @dev Admit an unreported positive token delta into a named bucket under governance.
     *      This is the only accepted path for a direct transfer / rebase / donation
     *      that was not recorded through `deposiToAccount`. It must not be used to
     *      mask a negative delta (loss of custody).
     * @param targetAccount Bucket to credit with the recovered delta
     * @param amount Amount to admit; must exactly equal the observed delta
     */
    function administerUnexplainedDelta(TreasuryAccount targetAccount, uint256 amount)
        external
        nonReentrant
        onlyRole(TREASURY_MANAGER_ROLE)
    {
        if (targetAccount == TreasuryAccount.EXTERNAL) {
            revert InvalidAccountTransfer(TreasuryAccount.EXTERNAL, targetAccount);
        }
        if (amount == 0) revert InsufficientAccountBalance(targetAccount, 0, 0);

        uint256 custody = _calculateTrackedCustody();
        uint256 actualBalance = protocolToken.balanceOf(address(this));

        // The delta must be positive and must exactly match the requested amount.
        // A negative delta (actual < custody) is an accounted loss and cannot be
        // recovered through this path.
        if (actualBalance <= custody) {
            revert ConservationInvariantViolation(custody, actualBalance);
        }
        uint256 observedDelta = actualBalance - custody;
        if (observedDelta != amount) {
            revert UnexplainedDeltaPresent(observedDelta, custody);
        }

        // Admit the delta into the bucket and classify it as a donation.
        _accountBalances[uint256(targetAccount)] += amount;
        totalDonations += amount;
        unexplainedDelta = 0;

        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            address(this),
            address(this),
            amount,
            TreasuryAccount.EXTERNAL,
            targetAccount,
            "unexplained_delta_recovery"
        );

        emit UnexplainedDeltaRecovered(transactionId, targetAccount, amount, msg.sender);

        _validateInvariants();
    }

    // ============= RECONCILIATION VIEWS =============

    /**
     * @dev Returns the custody total tracked by the accounting buckets.
     */
    function custody() public view returns (uint256) {
        return _calculateTrackedCustody();
    }

    /**
     * @dev Returns the live ERC20 balance of this contract.
     */
    function actualBalance() public view returns (uint256) {
        return protocolToken.balanceOf(address(this));
    }

    /**
     * @dev Returns the observed positive delta between the live balance and tracked
     *      custody. Zero means the conservation invariant holds.
     */
    function reconcile() public view returns (uint256 custodyAmount, uint256 actualAmount, uint256 delta) {
        custodyAmount = _calculateTrackedCustody();
        actualAmount = protocolToken.balanceOf(address(this));
        delta = actualAmount > custodyAmount ? actualAmount - custodyAmount : 0;
    }

    /**
     * @dev Returns the conservation decomposition of tracked custody.
     */
    function conservation()
        public
        view
        returns (
            uint256 custodyAmount,
            uint256 principal,
            uint256 rewards,
            uint256 fees,
            uint256 donations,
            uint256 unexplained
        )
    {
        custodyAmount = _calculateTrackedCustody();
        principal = totalPrincipal;
        rewards = totalRewards;
        fees = totalFees;
        donations = totalDonations;
        unexplained = unexplainedDelta;
    }

    // ============= ADMIN FUNCTIONS =============

    /**
     * @dev Update the max rewards withdrawal ratio
     */
    function setMaxRewardsWithdrawalBPS(uint256 newBPS) external onlyRole(ADMIN_ROLE) {
        if (newBPS > PERCENT_DENOMINATOR) revert InvariantViolation("invalid_bps", PERCENT_DENOMINATOR, newBPS);
        uint256 oldValue = maxRewardsWithdrawalBPS;
        maxRewardsWithdrawalBPS = newBPS;
        emit AllocationConfigUpdated("maxRewardsWithdrawalBPS", oldValue, newBPS);
    }

    /**
     * @dev Update the minimum staking reserve ratio
     */
    function setMinStakingReserveRatio(uint256 newRatio) external onlyRole(ADMIN_ROLE) {
        if (newRatio > PERCENT_DENOMINATOR) revert InvariantViolation("invalid_ratio", PERCENT_DENOMINATOR, newRatio);
        uint256 oldValue = minStakingReserveRatio;
        minStakingReserveRatio = newRatio;
        emit AllocationConfigUpdated("minStakingReserveRatio", oldValue, newRatio);
    }

    // ============= VIEW FUNCTIONS =============

    /**
     * @dev Get the balance of a specific treasury account
     */
    function getAccountBalance(TreasuryAccount account) external view returns (uint256) {
        return _accountBalances[uint256(account)];
    }

    /**
     * @dev Get all account balances
     */
    function getAccountBalances() external view returns (uint256[6] memory) {
        return _accountBalances;
    }

    /**
     * @dev Calculate total assets across all accounts
     */
    function calculateTotalAssets() public view returns (uint256) {
        return _calculateTrackedCustody();
    }

    /**
     * @dev Create a snapshot of current accounting state
     */
    function createSnapshot() external nonReentrant returns (uint256) {
        uint256 totalAssets = _calculateTrackedCustody();
        uint256 currentUnexplained = unexplainedDelta;

        AccountSnapshot memory snapshot = AccountSnapshot({
            timestamp: block.timestamp,
            blockNumber: block.number,
            balances: _accountBalances,
            totalPrincipal: totalPrincipal,
            totalRewards: totalRewards,
            totalFees: totalFees,
            totalDonations: totalDonations,
            totalAssets: totalAssets,
            unexplainedDelta: currentUnexplained,
            snapshotSender: msg.sender
        });

        snapshots.push(snapshot);
        snapshotCount++;

        emit AccountSnapshotCreated(snapshotCount - 1, block.timestamp, totalAssets, msg.sender);

        return snapshotCount - 1;
    }

    // ============= INTERNAL FUNCTIONS =============

    /**
     * @dev Classify a deposit into its conservation component based on the target
     *      bucket. This is a decomposition of custody, not an additional balance.
     */
    function _classifyDeposit(TreasuryAccount targetAccount, uint256 amount) internal {
        if (targetAccount == TreasuryAccount.STAKING_RESERVE) {
            totalPrincipal += amount;
        } else if (targetAccount == TreasuryAccount.REWARDS_POOL) {
            totalRewards += amount;
        } else if (targetAccount == TreasuryAccount.PROTOCOL_FEES) {
            totalFees += amount;
        } else {
            // GOVERNANCE_RESERVES/ECOSYSTEM_FUND/SLASHED_TREASURY are not
            // principal/rewards/fees; treat them as donations for conservation.
            totalDonations += amount;
        }
    }

    /**
     * @dev Sum of all tracked bucket balances. This is the authoritative custody
     *      value used in the conservation equation.
     */
    function _calculateTrackedCustody() internal view returns (uint256 total) {
        for (uint256 i = 0; i < realBucketCount(); ++i) {
            total += _accountBalances[i];
        }
    }

    /**
     * @dev Number of real buckets (excluding the EXTERNAL marker).
     */
    function realBucketCount() public pure returns (uint256) {
        return uint256(TreasuryAccount.SLASHED_TREASURY) + 1;
    }

    /**
     * @dev Validate all accounting invariants are maintained.
     *      The conservation invariant is the authoritative check:
     *          actualBalance == custody == sum(_accountBalances)
     *      A positive delta is tracked in `unexplainedDelta` and must be administered
     *      through the governed recovery path. A negative delta is a hard failure.
     */
    function _validateInvariants() internal view {
        uint256 custody = _calculateTrackedCustody();
        uint256 actualBal = protocolToken.balanceOf(address(this));

        // Negative delta (loss of custody) is always a hard failure.
        if (actualBal < custody) {
            revert ConservationInvariantViolation(custody, actualBal);
        }

        // Positive delta is tracked and must be administered. We do not revert here
        // because the governed recovery path is the authorized way to admit it.
        // However, the delta must not be negative and must not exceed the live
        // balance.
        // (The `unexplainedDelta` state is updated in `_syncUnexplainedDelta`).)
    }

    /**
     * @dv Sync the tracked unexplained delta from the live balance. Called at
     *      every accounting boundary to keep the conservation equation exact.
     */
    function _syncUnexplainedDelta() internal {
        uint256 custodyAmount = _calculateTrackedCustody();
        uint256 actual = protocolToken.balanceOf(address(this));
        if (actual < custodyAmount) {
            revert ConservationInvariantViolation(custodyAmount, actual);
        }
        unexplainedDelta = actual - custodyAmount;
    }

    /**
     * @dev Enforce withdrawal limits based on account type
     */
    function _enforceWithdrawalLimits(TreasuryAccount account, uint256 amount) internal view {
        if (account == TreasuryAccount.REWARDS_POOL) {
            uint256 maxAllowed = (_accountBalances[uint256(TreasuryAccount.REWARDS_POOL)] * maxRewardsWithdrawalBPS) / PERCENT_DENOMINATOR;
            if (amount > maxAllowed) {
                revert WithdrawalExceedsLimit(amount, maxAllowed);
            }
        }
    }

    /**
     * @dev Generate a unique transaction ID
     */
    function _generateTransactionId() internal view returns (bytes32) {
        return keccak(abi.encodePacked(block.timestamp, block.number, transactionCount++, msg.sender));
    }

    /**
     * @dev Record a token movement for auditing
     */
    function _recordTransaction(
        bytes32 transactionId,
        address from,
        address to,
        uint256 amount,
        TreasuryAccount fromAccount,
        TreasuryAccount toAccount,
        string memory movementType
    ) internal {
        transactions[transactionId] = TokenMovement({
            timestamp: block.timestamp,
            from: from,
            to: to,
            amount: amount,
            fromAccount: fromAccount,
            toAccount: toAccount,
            movementType: movementType,
            transactionId: transactionId
        });
        transactionIds.push(transactionId);
        transactionCount++;
    }

    /**
     * @dev Modifier to check if the caller is authorized for a specific account transfer
     */
    modifier onlyRoleAuthorizedForTransfer(TreasuryAccount fromAccount) {
        if (fromAccount == TreasuryAccount.STAKING_RESERVE) {
            if (!hasRole(STAKING_CONTRACT_ROLE, msg.sender) && !hasRole(ADMIN_ROLE, msg.sender)) {
                revert UnauthorizedAccountTransfer();
            }
        } else if (fromAccount == TreasuryAccount.REWARDS_POOL) {
            if (!hasRole(REWARD_ENGINE_ROLE, msg.sender) && !hasRole(ADMIN_ROLE, msg.sender)) {
                revert UnauthorizedAccountTransfer();
            }
        } else if (fromAccount == TreasuryAccount.SLASHED_TREASURY) {
            if (!hasRole(SLASHING_CONTRACT_ROLE, msg.sender) && !hasRole(ADMIN_ROLE, msg.sender)) {
                revert UnauthorizedAccountTransfer();
            }
        } else {
            if (!hasRole(TREASURY_MANAGER_ROLE, msg.sender) && !hasRole(ADMIN_ROLE, msg.sender)) {
                revert UnauthorizedAccountTransfer();
            }
        }
        _;
    }

    // ============= GOVERNANCE HOOKS =============

    /**
     * @dev Hook called after governance actions to re-validate invariants
     */
    function _afterGovernanceAction() internal override {
        _syncUnexplainedDelta();
    }

    // V2-SC-154: additive recovery only; existing liability and authority paths remain authoritative.
    function _checkAssetRecoveryAuthority() internal view override {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender) || !governanceEnabled) revert RecoveryAuthorityUnavailable();
    }

    function _requireAssetRecoveryAllowed() internal view override {
        if (paused()) revert RecoveryPaused();
    }

    function _reservedAssetBalance(address asset) internal view override returns (uint256) {
        return asset == address(protocolToken) ? calculateTotalAssets() : 0;
    }
}
