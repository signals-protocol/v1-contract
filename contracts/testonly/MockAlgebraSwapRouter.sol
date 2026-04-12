// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAlgebraSwapRouter} from "../interfaces/IAlgebraSwapRouter.sol";

contract MockAlgebraSwapRouter is IAlgebraSwapRouter {
    using SafeERC20 for IERC20;

    error RateNotSet(address tokenIn, address tokenOut);
    error OutputBelowMinimum(uint256 amountOut, uint256 minAmountOut);

    mapping(address => mapping(address => uint256)) public ratesWad;
    uint256 public swapCount;

    function setRate(address tokenIn, address tokenOut, uint256 rateWad) external {
        ratesWad[tokenIn][tokenOut] = rateWad;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        uint256 rateWad = ratesWad[params.tokenIn][params.tokenOut];
        if (rateWad == 0) revert RateNotSet(params.tokenIn, params.tokenOut);

        swapCount += 1;

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        amountOut = (params.amountIn * rateWad) / 1e18;
        if (amountOut < params.amountOutMinimum) {
            revert OutputBelowMinimum(amountOut, params.amountOutMinimum);
        }

        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);
    }

    function multicall(bytes[] calldata) external payable returns (bytes[] memory) {
        revert("unsupported");
    }
}
