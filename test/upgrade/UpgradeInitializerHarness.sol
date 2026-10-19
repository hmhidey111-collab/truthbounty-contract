// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../contracts/upgrade/ProtocolUpgradeable.sol";

/**
 * @title UpgradeInitializerHarness
 * @notice Test harness exposing the initialization surface of {ProtocolUpgradeable}.
 * @dev Shared by the V2-SC-122 initializer/reinitializer suites.
 *
 * `reinitializeAt` deliberately puts the version guard before the role guard, so a
 * call that cannot be reinitialized reverts with `InvalidInitialization()` even when
 * the caller also lacks the admin role — and an unauthorized caller that passes the
 * version guard does not consume the version, because the whole call reverts.
 */
contract UpgradeInitializerHarness is ProtocolUpgradeable {
    uint256 public value;

    function initializeHarness(
        address admin,
        address upgradeController,
        address governanceController,
        uint256 initialValue
    ) external initializer {
        _initializeProtocolUpgradeable(admin, upgradeController, governanceController);
        value = initialValue;
    }

    /// @dev Reaches the internal initializer without the `initializer` modifier, so
    ///      `onlyInitializing` is the only thing left between a caller and setup.
    function initializeUnguarded(address admin) external {
        _initializeProtocolUpgradeable(admin, address(0), address(0));
    }

    function reinitializeAt(uint64 version, uint256 newValue)
        external
        reinitializer(version)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        value = newValue;
    }

    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }
}

/// @dev Proxy whose implementation slot is set without running an initializer.
contract UninitializedUpgradeProxy is ERC1967Proxy {
    constructor(address implementation) ERC1967Proxy(implementation, bytes("")) {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}
