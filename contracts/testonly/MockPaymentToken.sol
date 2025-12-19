// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simple 6-decimal ERC20 for testing.
contract MockPaymentToken is ERC20 {
    constructor() ERC20("MockUSD", "mUSD") {
        _mint(msg.sender, 1_000_000_000 * 1e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
