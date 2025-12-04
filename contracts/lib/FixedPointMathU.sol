// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Fixed-point math utilities (WAD = 1e18) ported from v0.
library FixedPointMathU {
    uint256 internal constant WAD = 1e18;

    error FP_DivisionByZero();
    error FP_InvalidInput();

    function toWad(uint256 x) internal pure returns (uint256) {
        unchecked {
            return x * WAD;
        }
    }

    function fromWad(uint256 x) internal pure returns (uint256) {
        return x / WAD;
    }

    function fromWadRoundUp(uint256 x) internal pure returns (uint256) {
        return (x + WAD - 1) / WAD;
    }

    function fromWadNearest(uint256 x) internal pure returns (uint256) {
        return (x + (WAD / 2)) / WAD;
    }

    function fromWadNearestMin1(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        return (x + (WAD / 2)) / WAD;
    }

    function wMul(uint256 x, uint256 y) internal pure returns (uint256) {
        unchecked {
            return (x * y) / WAD;
        }
    }

    function wMulNearest(uint256 x, uint256 y) internal pure returns (uint256) {
        unchecked {
            return (x * y + WAD / 2) / WAD;
        }
    }

    function wDiv(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == 0) revert FP_DivisionByZero();
        unchecked {
            return (x * WAD) / y;
        }
    }

    function wDivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == 0) revert FP_DivisionByZero();
        unchecked {
            return (x * WAD + y - 1) / y;
        }
    }

    function wDivNearest(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == 0) revert FP_DivisionByZero();
        unchecked {
            return (x * WAD + y / 2) / y;
        }
    }

    /// @notice Exponential using Taylor series approximation (same as v0 PRB-math style).
    function wExp(uint256 xWad) internal pure returns (uint256) {
        // Adapted from PRBMathUD60x18 exp implementation.
        uint256 x = xWad;
        uint256 term = WAD;
        uint256 sum = WAD;
        for (uint256 i = 1; i < 20; i++) {
            term = (term * x) / (WAD * i);
            sum += term;
            if (term == 0) break;
        }
        return sum;
    }

    /// @notice Natural log using series approximation around 1; input must be > 0.
    function wLn(uint256 xWad) internal pure returns (uint256) {
        if (xWad == 0) revert FP_InvalidInput();
        // Simple iterative approximation: ln(x) ~ 2 * atanh((x-1)/(x+1))
        uint256 num = xWad > WAD ? xWad - WAD : WAD - xWad;
        uint256 den = xWad + WAD;
        uint256 z = wDiv(num, den);
        uint256 zPow = z;
        uint256 res = 0;
        // 10 terms of series
        for (uint256 i = 1; i < 20; i += 2) {
            uint256 term = wDiv(zPow, i);
            res += term;
            zPow = wMul(zPow, wMul(z, z));
        }
        res = wMul(res, 2);
        if (xWad < WAD) {
            return WAD - res;
        }
        return res + 0;
    }
}
