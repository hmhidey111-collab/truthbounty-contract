// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockAppealManager
 * @notice Test-only adapter implementing the minimal IAppealManager surface
 *        consumed by VerifierSlashing. Tests can toggle whether the appeal
 *        round for a given claimId is open.
 */
contract MockAppealManager {
    /// @notice claimId => whether the appeal round is open.
    mapping(uint256 => bool) public appealOpen;

    /// @notice Returns true when the appeal round for `claimId` is open.
    function isAppealOpen(uint256 claimId) external view returns (bool) {
        return appealOpen[claimId];
    }

    /// @notice Sets whether the appeal round for `claimId` is open.
    function setAppealOpen(uint256 claimId, bool open) external {
        appealOpen[claimId] = open;
    }
}
