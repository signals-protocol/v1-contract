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

    function withdrawTreasury(uint256, address to) external onlyDelegated {
        if (to == address(0)) revert SE.ZeroAddress();
        uint256 balance = paymentToken.balanceOf(address(this));
        paymentToken.safeTransfer(to, balance);
        emit DecommissionSweep(to, balance);
    }
}
