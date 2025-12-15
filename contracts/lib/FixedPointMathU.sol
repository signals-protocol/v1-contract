// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Fixed-point math utilities (WAD = 1e18) ported from v0.
library FixedPointMathU {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SCALE_DIFF = 1e12; // 6-dec → 18-dec
    uint256 internal constant HALF_SCALE = SCALE_DIFF / 2;

    error FP_DivisionByZero();
    error FP_InvalidInput();

    /// @dev 6-decimal → 18-decimal (multiply by 1e12)
    function toWad(uint256 x) internal pure returns (uint256) {
        unchecked {
            return x * SCALE_DIFF;
        }
    }

    /// @dev 18-decimal → 6-decimal (truncates)
    function fromWad(uint256 x) internal pure returns (uint256) {
        return x / SCALE_DIFF;
    }

    /// @dev 18-decimal → 6-decimal with round-up (prevents zero-cost attacks)
    function fromWadRoundUp(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        return ((x - 1) / SCALE_DIFF) + 1;
    }

    /// @dev 18-decimal → 6-decimal nearest (ties up)
    function fromWadNearest(uint256 x) internal pure returns (uint256) {
        uint256 quotient = x / SCALE_DIFF;
        uint256 remainder = x % SCALE_DIFF;
        if (remainder >= HALF_SCALE) {
            unchecked {
                quotient += 1;
            }
        }
        return quotient;
    }

    function fromWadNearestMin1(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 res = fromWadNearest(x);
        return res == 0 ? 1 : res;
    }

    function wMul(uint256 x, uint256 y) internal pure returns (uint256) {
        unchecked {
            return (x * y) / WAD;
        }
    }

    /// @dev WAD multiply with round-up (ceil)
    /// @notice Used for conservative calculations where under-estimation is unsafe
    /// Per whitepaper: ceil semantics required for Nfloor calculation to ensure
    /// grantNeed is never under-estimated (drawdown floor is an invariant)
    function wMulUp(uint256 x, uint256 y) internal pure returns (uint256) {
        unchecked {
            uint256 product = x * y;
            // (product + WAD - 1) / WAD, but handle zero case
            return product == 0 ? 0 : (product - 1) / WAD + 1;
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
