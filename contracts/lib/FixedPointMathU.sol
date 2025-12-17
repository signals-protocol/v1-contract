// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Fixed-point math utilities (WAD = 1e18) with 512-bit safe arithmetic.
/// @dev Uses OpenZeppelin Math.mulDiv for overflow-safe multiplication/division.
///      This implementation mirrors v0's PRB-Math based approach for numerical stability.
library FixedPointMathU {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = 5e17;
    uint256 internal constant SCALE_DIFF = 1e12; // 6-dec → 18-dec
    uint256 internal constant HALF_SCALE = SCALE_DIFF / 2;

    error FP_DivisionByZero();
    error FP_InvalidInput();
    error FP_Overflow();

    // ============================================================
    // Decimal Conversion (6-dec ↔ 18-dec)
    // ============================================================

    /// @dev 6-decimal → 18-decimal (multiply by 1e12)
    /// @notice Safe: max 6-dec value * 1e12 fits in uint256
    function toWad(uint256 x) internal pure returns (uint256) {
        unchecked {
            return x * SCALE_DIFF;
        }
    }

    /// @dev 18-decimal → 6-decimal (truncates/floor)
    function fromWad(uint256 x) internal pure returns (uint256) {
        return x / SCALE_DIFF;
    }

    /// @dev 18-decimal → 6-decimal with round-up (ceil)
    /// @notice Prevents zero-cost attacks by ensuring non-zero WAD → non-zero 6-dec
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

    /// @dev fromWadNearest but returns at least 1 if x > 0
    function fromWadNearestMin1(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 res = fromWadNearest(x);
        return res == 0 ? 1 : res;
    }

    // ============================================================
    // WAD Multiplication (512-bit safe via mulDiv)
    // ============================================================

    /// @notice WAD multiply with floor (truncate)
    /// @dev result = floor(x * y / WAD)
    ///      Uses 512-bit intermediate to prevent overflow
    function wMul(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, y, WAD);
    }

    /// @notice WAD multiply with ceil (round up)
    /// @dev result = ceil(x * y / WAD)
    ///      Uses mulDiv + mulmod to check for remainder
    ///      Per whitepaper: ceil semantics required for Nfloor calculation
    function wMulUp(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 result = Math.mulDiv(x, y, WAD);
        // Check if there's a remainder (x*y % WAD != 0)
        if (mulmod(x, y, WAD) > 0) {
            unchecked {
                result += 1;
            }
        }
        return result;
    }

    /// @notice WAD multiply with round-to-nearest (ties up)
    /// @dev result = round(x * y / WAD)
    ///      Uses mulDiv + mulmod to check remainder against HALF_WAD
    function wMulNearest(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 result = Math.mulDiv(x, y, WAD);
        uint256 remainder = mulmod(x, y, WAD);
        if (remainder >= HALF_WAD) {
            unchecked {
                result += 1;
            }
        }
        return result;
    }

    // ============================================================
    // WAD Division (512-bit safe via mulDiv)
    // ============================================================

    /// @notice WAD divide with floor (truncate)
    /// @dev result = floor(x * WAD / y)
    ///      Uses 512-bit intermediate to prevent overflow
    function wDiv(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == 0) revert FP_DivisionByZero();
        return Math.mulDiv(x, WAD, y);
    }

    /// @notice WAD divide with ceil (round up)
    /// @dev result = ceil(x * WAD / y)
    ///      Uses mulDiv + mulmod to check for remainder
    function wDivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == 0) revert FP_DivisionByZero();
        uint256 result = Math.mulDiv(x, WAD, y);
        // Check if there's a remainder (x*WAD % y != 0)
        if (mulmod(x, WAD, y) > 0) {
            unchecked {
                result += 1;
            }
        }
        return result;
    }

    /// @notice WAD divide with round-to-nearest (ties up)
    /// @dev result = round(x * WAD / y)
    ///      Uses mulDiv + mulmod to check remainder against y/2
    function wDivNearest(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == 0) revert FP_DivisionByZero();
        uint256 result = Math.mulDiv(x, WAD, y);
        uint256 remainder = mulmod(x, WAD, y);
        // Round up if remainder >= y/2
        if (remainder >= (y >> 1) + (y & 1)) {
            // (y + 1) / 2 for correct rounding
            unchecked {
                result += 1;
            }
        }
        return result;
    }

    // ============================================================
    // Exponential & Logarithm (Taylor series)
    // ============================================================

    /// @notice Exponential using Taylor series approximation
    /// @dev exp(x) = 1 + x + x²/2! + x³/3! + ...
    ///      Safe: uses mulDiv for each term to prevent overflow
    function wExp(uint256 xWad) internal pure returns (uint256) {
        uint256 term = WAD;
        uint256 sum = WAD;
        for (uint256 i = 1; i < 20; i++) {
            // term_{n+1} = term_n * x / (n * WAD)
            // Split into two steps to avoid overflow in (WAD * i)
            // First: term * xWad / WAD (this is wMul)
            // Then: result / i
            term = Math.mulDiv(term, xWad, WAD);
            term = term / i;
            sum += term;
            if (term == 0) break;
        }
        return sum;
    }

    /// @notice Natural log using series approximation
    /// @dev ln(x) ~ 2 * atanh((x-1)/(x+1)) for x > 0
    ///      Uses safe wDiv and wMul throughout
    function wLn(uint256 xWad) internal pure returns (uint256) {
        if (xWad == 0) revert FP_InvalidInput();
        // ln(x) ~ 2 * atanh((x-1)/(x+1))
        uint256 num = xWad > WAD ? xWad - WAD : WAD - xWad;
        uint256 den = xWad + WAD;
        uint256 z = wDiv(num, den);
        uint256 zPow = z;
        uint256 res = 0;
        // 10 terms of series: sum(z^(2k+1) / (2k+1)) for k=0..9
        for (uint256 i = 1; i < 20; i += 2) {
            // term = zPow / i (i is integer, not WAD)
            uint256 term = zPow / i;
            res += term;
            zPow = wMul(zPow, wMul(z, z));
        }
        // Multiply by 2 (res is already in WAD)
        res = res * 2;
        if (xWad < WAD) {
            return WAD - res;
        }
        return res;
    }

    // ============================================================
    // Safe ln(n) Lookup Table for α Safety Bounds
    // ============================================================

    /// @notice Pre-computed ln values in WAD precision (rounded UP for safety)
    /// @dev ln(n) values computed with high precision, rounded up to ensure
    ///      α_base = λE/ln(n) is CONSERVATIVE (smaller α_base = safer)
    ///      Per whitepaper v2: α_base must never exceed the safety bound.
    uint256 internal constant LN_2 = 693147180559945310;
    uint256 internal constant LN_5 = 1609437912434100375;
    uint256 internal constant LN_10 = 2302585092994045685;
    uint256 internal constant LN_20 = 2995732273553991095;
    uint256 internal constant LN_50 = 3912023005428146060;
    uint256 internal constant LN_100 = 4605170185988091369;
    uint256 internal constant LN_200 = 5298317366548036678;
    uint256 internal constant LN_500 = 6214608098422191781;
    uint256 internal constant LN_1000 = 6907755278982137053;
    uint256 internal constant LN_2000 = 7600902459542082362;
    uint256 internal constant LN_5000 = 8517193191416237509;
    uint256 internal constant LN_10000 = 9210340371976182818;

    /// @notice Calculate ln(n) with safe (upward) rounding for α calculation
    /// @dev Returns ln(n) in WAD, rounded UP to ensure α_base is conservative
    /// @param n Number of bins (integer, not WAD)
    /// @return lnN ln(n) in WAD, rounded up for safety
    function lnWadUp(uint256 n) internal pure returns (uint256 lnN) {
        if (n <= 1) return 0;

        if (n == 2) return LN_2;
        if (n <= 5) return LN_5;
        if (n <= 10) return LN_10;
        if (n <= 20) return LN_20;
        if (n <= 50) return LN_50;
        if (n <= 100) return LN_100;
        if (n <= 200) return LN_200;
        if (n <= 500) return LN_500;
        if (n <= 1000) return LN_1000;
        if (n <= 2000) return LN_2000;
        if (n <= 5000) return LN_5000;
        if (n <= 10000) return LN_10000;

        // For n > 10000, use conservative upper bound
        // ln(n) < digits * ln(10) where digits = floor(log10(n)) + 1
        uint256 digits = 0;
        uint256 temp = n;
        while (temp >= 10) {
            temp /= 10;
            digits++;
        }
        // Upper bound: (digits + 1) * ln(10) (always over-estimates)
        return (digits + 1) * LN_10;
    }
}
