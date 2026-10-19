// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IUpgradeController
 * @notice Interface for the Protocol Upgrade Controller
 * @dev Governs the full upgrade lifecycle: propose → schedule → execute
 */
interface IUpgradeController {
    enum UpgradeType {
        STANDARD,
        EMERGENCY,
        ROLLBACK
    }

    enum UpgradeStatus {
        NONE,
        PROPOSED,
        SCHEDULED,
        EXECUTED,
        CANCELLED,
        ROLLED_BACK
    }

    struct UpgradeProposal {
        bytes32 proposalId;
        address targetContract;
        address currentImplementation;
        address newImplementation;
        string version;
        UpgradeType upgradeType;
        UpgradeStatus status;
        uint256 scheduledAt;
        uint256 executeAfter;
        uint256 executedAt;
        address proposer;
        bytes32 governanceProposalId;
        bytes32 upgradeHash;
    }

    event UpgradeProposed(
        bytes32 indexed proposalId,
        address indexed targetContract,
        address indexed newImplementation,
        string version,
        UpgradeType upgradeType
    );

    event UpgradeScheduled(
        bytes32 indexed proposalId,
        uint256 executeAfter
    );

    event UpgradeExecuted(
        bytes32 indexed proposalId,
        address indexed targetContract,
        address indexed newImplementation,
        string version
    );

    event UpgradeCancelled(bytes32 indexed proposalId);

    event UpgradeRolledBack(
        bytes32 indexed proposalId,
        address indexed targetContract,
        address indexed previousImplementation
    );

    event EmergencyDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event ExecutionWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event StandardDelayUpdated(uint256 oldDelay, uint256 newDelay);

    function proposeUpgrade(
        address targetContract,
        address newImplementation,
        string calldata version,
        UpgradeType upgradeType,
        bytes32 governanceProposalId
    ) external returns (bytes32 proposalId);

    function scheduleUpgrade(bytes32 proposalId) external;

    function executeUpgrade(bytes32 proposalId) external;

    function cancelUpgrade(bytes32 proposalId) external;

    function rollbackUpgrade(bytes32 proposalId) external;

    function setEmergencyDelay(uint256 newDelay) external;
    function setExecutionWindow(uint256 newWindow) external;
    function setStandardDelay(uint256 newDelay) external;

    function getProposal(bytes32 proposalId) external view returns (UpgradeProposal memory);
    function isUpgradeScheduled(bytes32 proposalId) external view returns (bool);
    function getUpgradeHistory(address targetContract) external view returns (bytes32[] memory);
    function getPendingUpgrades(address targetContract) external view returns (bytes32[] memory);
    function currentImplementation(address targetContract) external view returns (address);
}
