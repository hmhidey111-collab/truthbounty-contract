// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockRewardToken is ERC20 {
    constructor() ERC20("Mock Reward Token", "MRT") {
        _mint(msg.sender, 1000000000 ether);
    }

    /// @dev Test-only helper so invariant/fuzz tests can inject arbitrary amounts.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
