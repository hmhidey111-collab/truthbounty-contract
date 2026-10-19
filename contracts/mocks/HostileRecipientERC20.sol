// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title HostileRecipientERC20
 * @notice Reward test token whose outbound transfers can be programmed to fail for a
 *         specific recipient, either by reverting or by returning `false`.
 *
 * @dev Used by the SC-051 withdrawal-liveness suite to prove that a single hostile
 *      recipient cannot block other recipients, that a failed payout remains owed
 *      exactly once, and that retries are permission-safe.
 */
contract HostileRecipientERC20 is ERC20 {
    enum Fault {
        None,
        Revert,
        ReturnFalse
    }

    /// @notice Per-recipient outbound-transfer fault.
    mapping(address => Fault) public faultFor;

    constructor() ERC20("Hostile Recipient Token", "HRT") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    /// @notice Configure how outbound transfers to `recipient` behave.
    function setFault(address recipient, Fault fault) external {
        faultFor[recipient] = fault;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        Fault fault = faultFor[to];
        if (fault == Fault.Revert) {
            revert("HostileRecipientERC20: recipient rejected transfer");
        }
        if (fault == Fault.ReturnFalse) {
            return false;
        }
        return super.transfer(to, value);
    }
}
