// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignalsErrors as SE} from "../errors/SignalsErrors.sol";

/// @title DecommissionModule
/// @notice One-shot vault module used to sweep the full Core payment-token balance during protocol shutdown.
contract DecommissionModule {
    using SafeERC20 for IERC20;

    IERC20 private immutable paymentToken;
    address private immutable self;

    event DecommissionSweep(address indexed to, uint256 amount);

    modifier onlyDelegated() {
        if (address(this) == self) revert SE.NotDelegated();
        _;
    }

    constructor(address paymentToken_) {
        if (paymentToken_ == address(0)) revert SE.ZeroAddress();
        paymentToken = IERC20(paymentToken_);
        self = address(this);
    }

    /// @notice Sweeps up to `maxBalance` of the Core payment token to `to`, capping at the signed amount.
    /// @dev Transfers `min(balanceOf(Core), maxBalance)`: a claim that lowers the balance still fully drains
    ///      Core, while any unsolicited excess (dust or an unreviewed deposit) beyond the signed cap is left
    ///      behind rather than reverting, so a dust transfer cannot grief the signed sweep.
    function withdrawTreasury(uint256 maxBalance, address to) external onlyDelegated {
        if (to == address(0)) revert SE.ZeroAddress();
        uint256 balance = paymentToken.balanceOf(address(this));
        uint256 amount = balance > maxBalance ? maxBalance : balance;
        paymentToken.safeTransfer(to, amount);
        emit DecommissionSweep(to, amount);
    }
}
