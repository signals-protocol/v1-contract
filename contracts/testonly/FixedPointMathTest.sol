// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathU} from "../lib/FixedPointMathU.sol";

/// @notice Test harness for FixedPointMathU library functions.
contract FixedPointMathTest {
    uint256 public constant WAD = 1e18;

    // Core math wrappers
    function wExp(uint256 x) public pure returns (uint256) {
        return FixedPointMathU.wExp(x);
    }

    function wLn(uint256 x) public pure returns (uint256) {
        return FixedPointMathU.wLn(x);
    }

    function wMul(uint256 a, uint256 b) public pure returns (uint256) {
        return FixedPointMathU.wMul(a, b);
    }

    function wMulNearest(uint256 a, uint256 b) public pure returns (uint256) {
        return FixedPointMathU.wMulNearest(a, b);
    }

    function wDiv(uint256 a, uint256 b) public pure returns (uint256) {
        return FixedPointMathU.wDiv(a, b);
    }

    function wDivUp(uint256 a, uint256 b) public pure returns (uint256) {
        return FixedPointMathU.wDivUp(a, b);
    }

    function wDivNearest(uint256 a, uint256 b) public pure returns (uint256) {
        return FixedPointMathU.wDivNearest(a, b);
    }

    // Conversion helpers
    function toWad(uint256 amt6) external pure returns (uint256) {
        return FixedPointMathU.toWad(amt6);
    }

    function fromWad(uint256 amtWad) external pure returns (uint256) {
        return FixedPointMathU.fromWad(amtWad);
    }

    function fromWadRoundUp(uint256 amtWad) external pure returns (uint256) {
        return FixedPointMathU.fromWadRoundUp(amtWad);
    }

    function fromWadNearest(uint256 amtWad) external pure returns (uint256) {
        return FixedPointMathU.fromWadNearest(amtWad);
    }

    function fromWadNearestMin1(uint256 amtWad) external pure returns (uint256) {
        return FixedPointMathU.fromWadNearestMin1(amtWad);
    }

    // CLMSR cost helper: cost = alpha * ln(sumAfter / sumBefore)
    function clmsrCost(
        uint256 alpha,
        uint256 sumBefore,
        uint256 sumAfter
    ) public pure returns (uint256) {
        uint256 ratio = FixedPointMathU.wDiv(sumAfter, sumBefore);
        uint256 lnRatio = FixedPointMathU.wLn(ratio);
        return FixedPointMathU.wMul(alpha, lnRatio);
    }
}



