// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./GovernanceHooks.sol";

/**
 * @title GovernanceOwnable
 * @notice Mixin that enables governance control over contract parameters
 * @dev Allows contracts to be controlled by DAO governance while maintaining
 *      emergency admin access for critical situations
 * 
 * Features:
 * - Parameter updates require governance proposal approval
 * - Emergency pause/unpause functions
 * - Upgrade authorization flow
 * - Role management integration
 */
abstract contract GovernanceOwnable is AccessControl, Pausable {
    // ============ Constants ============
    
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GOVERNANCE_ADMIN_ROLE = keccak256("GOVERNANCE_ADMIN_ROLE");
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");
    
    /// @notice Address of the governance controller
    address public governanceController;
    
    /// @notice Whether governance control is enabled
    bool public governanceEnabled = true;
    
    /// @notice Emergency admin (can pause during emergencies)
    address public emergencyAdmin;

    // ============ Events ============
    
    event GovernanceControllerUpdated(
        address indexed oldController,
        address indexed newController
    );
    
    event GovernanceEnabledUpdated(
        bool indexed enabled
    );
    
    event EmergencyAdminUpdated(
        address indexed oldAdmin,
        address indexed newAdmin
    );
    
    event ParameterUpdatedByGovernance(
        bytes32 indexed paramId,
        uint256 oldValue,
        uint256 newValue
    );
    
    event RoleRecovered(
        bytes32 indexed role,
        address indexed account,
        address indexed recoveryAdmin
    );
    
    event RoleRevokedByRecovery(
        bytes32 indexed role,
        address indexed account,
        address indexed recoveryAdmin
    );

    // ============ Errors ============
    
    error GovernanceDisabled();
    error ZeroAddress();
    error UnauthorizedGovernance();

    // ============ Modifiers ============
    
    modifier onlyGovernanceOrAdmin() {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender) && 
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender) &&
            msg.sender != emergencyAdmin) {
            revert UnauthorizedGovernance();
        }
        _;
    }
    
    modifier whenGovernanceEnabled() {
        if (!governanceEnabled) revert GovernanceDisabled();
        _;
    }

    // ============ Initialization ============
    
    /**
     * @notice Initialize governance ownership
     * @param _governanceController Address of governance controller
     * @param _admin Initial admin address
     * @param _emergencyAdmin Emergency admin address
     */
    function _initializeGovernance(
        address _governanceController,
        address _admin,
        address _emergencyAdmin
    ) internal {
        require(_admin != address(0), ZeroAddress());
        require(_emergencyAdmin != address(0), ZeroAddress());
        
        governanceController = _governanceController;
        emergencyAdmin = _emergencyAdmin;
        
        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ADMIN_ROLE, _admin);
        _grantRole(RECOVERY_ROLE, _admin);
        
        if (_governanceController != address(0)) {
            _grantRole(GOVERNANCE_ROLE, _governanceController);
        }
        
        _setRoleAdmin(GOVERNANCE_ROLE, GOVERNANCE_ADMIN_ROLE);
        _setRoleAdmin(RECOVERY_ROLE, GOVERNANCE_ADMIN_ROLE);
    }

    // ============ Governance Parameter Update Functions ============
    
    /**
     * @notice Request a parameter update through governance
     * @param paramType The parameter type to update
     * @param newValue The new value
     * @return proposalId The created proposal ID
     */
    function requestGovernanceParameterUpdate(
        GovernanceHooks.ParameterType paramType,
        uint256 newValue
    ) external onlyGovernanceOrAdmin returns (bytes32 proposalId) {
        if (governanceController == address(0)) revert ZeroAddress();
        
        // Delegate to governance controller
        proposalId = GovernanceHooks(governanceController).requestParameterUpdate(
            paramType,
            newValue
        );
    }

    /**
     * @notice Request address parameter update through governance
     * @param paramType The parameter type to update
     * @param newAddress The new address
     * @return proposalId The created proposal ID
     */
    function requestGovernanceAddressUpdate(
        GovernanceHooks.ParameterType paramType,
        address newAddress
    ) external onlyGovernanceOrAdmin returns (bytes32 proposalId) {
        if (governanceController == address(0)) revert ZeroAddress();
        if (newAddress == address(0)) revert ZeroAddress();
        
        proposalId = GovernanceHooks(governanceController).requestAddressParameterUpdate(
            paramType,
            newAddress
        );
    }

    // ============ Emergency Functions ============
    
    /**
     * @notice Emergency pause function (available to emergency admin even when governance disabled)
     */
    function emergencyPause() external {
        require(msg.sender == emergencyAdmin || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not authorized");
        _pause();
    }
    
    /**
     * @notice Emergency unpause function
     */
    function emergencyUnpause() external virtual {
        require(msg.sender == emergencyAdmin || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not authorized");
        _unpause();
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Update governance controller address
     * @param _newController New governance controller address
     */
    function setGovernanceController(address _newController) 
        external onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (_newController == address(0)) revert ZeroAddress();
        address oldController = governanceController;
        
        // Revoke old governance role
        if (oldController != address(0)) {
            _revokeRole(GOVERNANCE_ROLE, oldController);
        }
        
        governanceController = _newController;
        
        // Grant governance role to new controller
        _grantRole(GOVERNANCE_ROLE, _newController);
        
        emit GovernanceControllerUpdated(oldController, _newController);
    }
    
    /**
     * @notice Enable/disable governance control
     * @param _enabled Whether to enable governance
     */
    function setGovernanceEnabled(bool _enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        governanceEnabled = _enabled;
        emit GovernanceEnabledUpdated(_enabled);
    }
    
    /**
     * @notice Update emergency admin
     * @param _newEmergencyAdmin New emergency admin address
     */
    function setEmergencyAdmin(address _newEmergencyAdmin) 
        external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newEmergencyAdmin != address(0), ZeroAddress());
        
        address oldAdmin = emergencyAdmin;
        emergencyAdmin = _newEmergencyAdmin;
        
        emit EmergencyAdminUpdated(oldAdmin, _newEmergencyAdmin);
    }

    // ============ View Functions ============
    
    /**
     * @notice Check if address has governance rights
     * @param account Address to check
     * @return True if has governance rights
     */
    function hasGovernanceRights(address account) external view returns (bool) {
        return hasRole(GOVERNANCE_ROLE, account) || 
               hasRole(DEFAULT_ADMIN_ROLE, account) ||
               account == emergencyAdmin;
    }
    
    /**
     * @notice Get governance controller interface version
     * @return The version number ( 0 if no controller )
     */
    function getGovernanceVersion() external view returns (uint256) {
        return 1; // Placeholder for future governance version tracking
    }

    // ============ Role Recovery Functions ============
    
    /**
     * @notice Recover a role by granting it in an emergency
     * @param role The role to recover
     * @param account The address to grant the role to
     */
    function recoverRole(bytes32 role, address account) external {
        if (!hasRole(RECOVERY_ROLE, msg.sender)) {
            revert UnauthorizedGovernance();
        }
        require(account != address(0), ZeroAddress());
        _grantRole(role, account);
        emit RoleRecovered(role, account, msg.sender);
    }
    
    /**
     * @notice Revoke a role in an emergency (e.g., if compromised)
     * @param role The role to revoke
     * @param account The address to revoke the role from
     */
    function recoverRevokeRole(bytes32 role, address account) external {
        if (!hasRole(RECOVERY_ROLE, msg.sender)) {
            revert UnauthorizedGovernance();
        }
        require(account != address(0), ZeroAddress());
        _revokeRole(role, account);
        emit RoleRevokedByRecovery(role, account, msg.sender);
    }

    /**
     * @dev Storage gap to allow future upgrades without shifting variables.
     */
    // ============ Reserved Storage ============

    /// @dev Storage gap for future upgrades (reserved 50 slots)
    uint256[50] private __gap;
}
