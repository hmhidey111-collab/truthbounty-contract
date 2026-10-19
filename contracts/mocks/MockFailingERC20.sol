// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev Mock ERC20 token used to exercise settlement paths where an external
 * payout fails without reverting. The failure is controllable so that the
 * same token can be used to verify that a failed payout remains retryable
 * without repeating state effects.
 *
 * By default the token behaves like a well-behaved ERC20. Callers may
 * enable failure mode to simulate a transfer that returns false without
 * reverting, which is the exact failure mode settlement must tolerate.
 */
contract MockFailingERC20 is ERC20 {
    bool public transferFails;

    event TransferFailureModeSet(bool enabled);

    constructor() ERC20("Mock Failing ERC20", "MFE") {
        _mint(msg.sender, 1000000 * 10 ** decimals());
    }

    /**
     * @dev Enable or disable the non-reverting transfer failure mode.
     */
    function setTransferFails(bool enabled) external {
        transferFails = enabled;
        emit TransferFailureModeSet(enabled);
    }

    /**
     * @dev Returns false without moving balances when failure mode is enabled.
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (transferFails) {
            return false;
        }
        return super.transfer(to, amount);
    }

    /**
     * @dev Returns false without moving balances when failure mode is enabled.
     */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (transferFails) {
            return false;
        }
        return super.transferFrom(from, to, amount);
    }
}
