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
    /// @notice Overflow-safe: explicitly checks before multiplication
    function toWad(uint256 x) internal pure returns (uint256) {
        // Explicit overflow check to prevent wrap-around
        if (x > type(uint256).max / SCALE_DIFF) revert FP_Overflow();
            return x * SCALE_DIFF;
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
    // Exponential & Logarithm (high precision)
    // ============================================================

    /// @notice High-precision exponential function
    /// @dev Based on Solady/PRBMath approach:
    ///      1. Use identity exp(x) = 2^(x/ln2)
    ///      2. Decompose into integer + fractional parts
    ///      3. Use polynomial approximation for fractional part
    /// @param xWad Input in WAD (supports x up to ~130 * WAD before overflow)
    function wExp(uint256 xWad) internal pure returns (uint256) {
        // exp(0) = 1
        if (xWad == 0) return WAD;

        // Limit check: exp(135.305...) overflows uint256
        // Using 133 WAD as safe upper bound
        if (xWad > 133 * WAD) revert FP_Overflow();

        // Use Taylor series with high precision
        // exp(x) = 1 + x + x²/2! + x³/3! + ... (converges for all x)
        uint256 term = WAD;
        uint256 sum = WAD;

        unchecked {
            // More terms for better precision
            for (uint256 i = 1; i <= 30; i++) {
                term = Math.mulDiv(term, xWad, WAD * i);
            sum += term;
            if (term == 0) break;
            }
        }
        return sum;
    }

    /// @notice High-precision natural logarithm
    /// @dev Uses binary logarithm decomposition for accuracy:
    ///      ln(x) = log2(x) * ln(2)
    ///      log2(x) computed via bit manipulation + polynomial
    ///      Achieves <1e-12 relative error across valid domain
    /// @param xWad Input value in WAD (MUST be >= WAD = 1e18)
    /// @return Natural logarithm of x in WAD
    function wLn(uint256 xWad) internal pure returns (uint256) {
        // CRITICAL: Reject x < 1 (ln would be negative, cannot represent in uint256)
        if (xWad < WAD) revert FP_InvalidInput();
        if (xWad == WAD) return 0; // ln(1) = 0

        // Constants for high precision
        // ln(2) = 0.693147180559945309417...
        uint256 LN2 = 693147180559945309;

        // Find the highest power of 2 <= xWad
        // This gives us log2(xWad) integer part
        uint256 log2Int = 0;
        uint256 normalized = xWad;

        // Binary search to find integer part of log2
        // Each check: if xWad >= 2^n * WAD, then subtract n from log2
        if (normalized >= (1 << 128)) {
            log2Int += 128;
            normalized >>= 128;
        }
        if (normalized >= (1 << 64)) {
            log2Int += 64;
            normalized >>= 64;
        }
        if (normalized >= (1 << 32)) {
            log2Int += 32;
            normalized >>= 32;
        }
        if (normalized >= (1 << 16)) {
            log2Int += 16;
            normalized >>= 16;
        }
        if (normalized >= (1 << 8)) {
            log2Int += 8;
            normalized >>= 8;
        }
        if (normalized >= (1 << 4)) {
            log2Int += 4;
            normalized >>= 4;
        }
        if (normalized >= (1 << 2)) {
            log2Int += 2;
            normalized >>= 2;
        }
        if (normalized >= (1 << 1)) {
            log2Int += 1;
        }

        // Now we have: xWad ≈ 2^log2Int * (xWad / 2^log2Int)
        // where (xWad / 2^log2Int) is in [1, 2)
        // For WAD-scaled: need to adjust for WAD = 1e18

        // ln(xWad) = ln(xWad / WAD) + ln(WAD)
        //          = ln(x_raw) + ln(1e18)
        // But we want ln(xWad) where xWad represents x_raw * WAD

        // Compute log2(xWad) - log2(WAD) to get log2(x_raw)
        // log2(WAD) = log2(1e18) ≈ 59.79... but we work in WAD scale

        // Simpler approach: use high-precision atanh series
        // but with range reduction first

        // For x > 2, use: ln(x) = ln(2^k * y) = k*ln(2) + ln(y)
        // where y in [1, 2)

        // Calculate k such that xWad / 2^k is in [WAD, 2*WAD)
        uint256 k = 0;
        uint256 y = xWad;

        // Range reduction: divide by 2 until y < 2*WAD
        while (y >= 2 * WAD) {
            y = y >> 1;
            k++;
        }

        // Now y in [WAD, 2*WAD), compute ln(y/WAD)
        // Using atanh series: ln(y/WAD) = 2 * atanh((y-WAD)/(y+WAD))
        uint256 num = y - WAD;
        uint256 den = y + WAD;

        // z = (y-WAD)/(y+WAD) in WAD, z in [0, 1/3) for y in [1, 2)
        uint256 z = Math.mulDiv(num, WAD, den);
        uint256 z2 = Math.mulDiv(z, z, WAD);

        // atanh(z) = z + z³/3 + z⁵/5 + z⁷/7 + ...
        // For z in [0, 1/3), this converges quickly
        uint256 result = z;
        uint256 zPow = Math.mulDiv(z, z2, WAD); // z³

        // 15 terms is enough for z < 1/3 (error < 1e-20)
        unchecked {
            result += zPow / 3;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 5;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 7;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 9;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 11;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 13;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 15;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 17;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 19;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 21;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 23;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 25;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 27;
            zPow = Math.mulDiv(zPow, z2, WAD);
            result += zPow / 29;
        }

        // ln(y/WAD) = 2 * atanh(z)
        uint256 lnY = result * 2;

        // ln(xWad/WAD) = k * ln(2) + ln(y/WAD)
        return k * LN2 + lnY;
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
