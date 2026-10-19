// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {V2SafeCast} from "../../v2/libraries/V2SafeCast.sol";

/**
 * @title TruthBountyGovernanceToken
 * @notice ERC20Votes token used for TruthBounty V2 on-chain governance.
 * @dev Delegation is required before voting power is active. Holders delegate to themselves or another address via {delegate}. Token transfers move voting units 1:1 with balances.
 */
contract TruthBountyGovernanceToken is ERC20, ERC20Permit, ERC20Votes {
    /// @notice Recipient address must not be zero.
    error ZeroRecipient();

    /// @param initialHolder Non-zero account receiving the initial supply.
    /// @param initialSupply Initial token amount in base units.
    constructor(address initialHolder, uint256 initialSupply)
        ERC20("TruthBounty Governance", "TB-GOV")
        ERC20Permit("TruthBounty Governance")
    {
        if (initialHolder == address(0)) revert ZeroRecipient();
        _mint(initialHolder, initialSupply);
    }

    /// @notice Returns the timestamp-based voting clock.
    /// @return timestamp Current Unix timestamp as uint48 seconds.
    /// @dev V2-SC-161: reverts `V2Errors.SafeCastOverflow("GovernanceToken.clock", now, type(uint48).max)`
    ///      instead of truncating once `block.timestamp` exceeds `type(uint48).max`, so checkpoints can
    ///      never be written at a wrapped (earlier) timepoint.
    function clock() public view override returns (uint48 timestamp) {
        return V2SafeCast.timestamp48(V2SafeCast.FIELD_GOVERNANCE_CLOCK);
    }

    /// @notice Describes the timestamp clock used by governance voting checkpoints.
    /// @return mode Clock mode string `mode=timestamp`.
    function CLOCK_MODE() public pure override returns (string memory mode) {
        return "mode=timestamp";
    }

    /// @notice Returns the current ERC-20 permit nonce for an owner.
    /// @param owner Permit owner.
    /// @return nonce Next permit nonce.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256 nonce) {
        return super.nonces(owner);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}
