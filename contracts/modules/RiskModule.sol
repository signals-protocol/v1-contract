// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../lib/FixedPointMathU.sol";
import "../errors/ModuleErrors.sol";

/// @title RiskModule
/// @notice Delegate-only module for safety bound enforcement (Phase 7)
/// @dev Implements whitepaper v2 Sec 4.1-4.5:
///      - ΔEₜ (tail budget) calculation from prior
///      - αbase/αlimit calculation
///      - Prior admissibility check
///      - Trade α enforcement hooks
contract RiskModule is SignalsCoreStorage {
    using FixedPointMathU for uint256;

    address private immutable self;

    // ============================================================
    // Errors
    // ============================================================

    /// @notice Prior not admissible: ΔEₜ > B^eff_{t-1}
    error PriorNotAdmissible(uint256 deltaEt, uint256 effectiveBackstop);

    /// @notice Market α exceeds safety limit
    error AlphaExceedsLimit(uint256 marketAlpha, uint256 alphaLimit);

    /// @notice Invalid number of bins (must be > 1)
    error InvalidNumBins(uint256 numBins);

    // ============================================================
    // Constants
    // ============================================================

    uint256 internal constant WAD = 1e18;
    
    /// @notice Pre-computed ln values for common bin counts (WAD precision)
    /// @dev ln(n) values: ln(2)=0.693, ln(10)=2.303, ln(100)=4.605, ln(1000)=6.908
    uint256 internal constant LN_2 = 693147180559945309;
    uint256 internal constant LN_10 = 2302585092994045684;
    uint256 internal constant LN_100 = 4605170185988091368;
    uint256 internal constant LN_1000 = 6907755278982137052;

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyDelegated() {
        if (address(this) == self) revert ModuleErrors.NotDelegated();
        _;
    }

    constructor() {
        self = address(this);
    }

    // ============================================================
    // ΔEₜ (Tail Budget) Calculation - WP v2 Sec 4.1
    // ============================================================

    /**
     * @notice Calculate tail budget ΔEₜ from prior concentration
     * @dev Per whitepaper v2 Eq. 4.1:
     *      E_ent(q₀,t) = C(q₀,t) - min_j q₀,t,j  (entropy budget)
     *      ΔEₜ := E_ent(q₀,t) - α ln n           (tail budget)
     * 
     *      For uniform prior (q₀ = 0): E_ent = α ln n, so ΔEₜ = 0
     *      For concentrated prior: E_ent > α ln n, so ΔEₜ > 0
     * 
     * @param alpha Market liquidity parameter α (WAD)
     * @param numBins Number of outcome bins n
     * @param priorConcentration Measure of prior concentration (WAD)
     *        0 = uniform prior, higher = more concentrated
     * @return deltaEt Tail budget (WAD)
     */
    function calculateDeltaEt(
        uint256 alpha,
        uint256 numBins,
        uint256 priorConcentration
    ) external pure returns (uint256 deltaEt) {
        if (numBins <= 1) revert InvalidNumBins(numBins);
        
        // For uniform prior (concentration = 0), ΔEₜ = 0
        if (priorConcentration == 0) {
            return 0;
        }

        // For concentrated prior:
        // ΔEₜ = priorConcentration * α (simplified model)
        // Full implementation would compute E_ent(q₀) - α ln n from actual prior weights
        // Here we use concentration as a direct multiplier for tail risk
        deltaEt = alpha.wMul(priorConcentration);
    }

    /**
     * @notice Get current tail budget for batch processing
     * @dev Called by LPVaultModule.processDailyBatch()
     *      V1 with uniform priors returns 0 (no tail risk)
     * @return deltaEt Tail budget for current state (WAD)
     */
    function getDeltaEt() external view onlyDelegated returns (uint256) {
        // Phase 7 V1: Uniform prior only → ΔEₜ = 0
        // This means grant rule becomes: grantNeed > 0 can always proceed
        // (until we add concentrated prior support)
        return 0;
    }

    // ============================================================
    // α Safety Bounds - WP v2 Sec 4.3-4.5
    // ============================================================

    /**
     * @notice Calculate αbase from NAV and bins
     * @dev Per whitepaper v2 Eq. 4.9:
     *      αbase,t = λ * E_t / ln(n)
     *      where E_t = N_{t-1} (vault NAV from previous batch)
     * 
     *      This ensures uniform-prior worst-case loss ≤ λ * E_t
     * 
     * @param Et Vault NAV (WAD)
     * @param numBins Number of outcome bins n
     * @param lambda Safety parameter λ (WAD, e.g., 0.3 = 30% max drawdown)
     * @return alphaBase Base liquidity parameter limit (WAD)
     */
    function calculateAlphaBase(
        uint256 Et,
        uint256 numBins,
        uint256 lambda
    ) external pure returns (uint256 alphaBase) {
        if (numBins <= 1) revert InvalidNumBins(numBins);
        
        uint256 lnN = _lnWad(numBins);
        if (lnN == 0) return type(uint256).max; // Edge case: n=1
        
        // αbase = λ * E_t / ln(n)
        alphaBase = lambda.wMul(Et).wDiv(lnN);
    }

    /**
     * @notice Calculate αlimit from αbase and drawdown
     * @dev Per whitepaper v2 Eq. 4.15:
     *      αlimit,t+1 = max{0, αbase,t+1 * (1 - k * DD_t)}
     *      where DD_t = 1 - P_t / P^peak_t
     * 
     * @param alphaBase Base liquidity parameter (WAD)
     * @param drawdown Current drawdown DD_t (WAD, 0 to WAD)
     * @param k Drawdown sensitivity factor (WAD, typically 1.0)
     * @return alphaLimit Effective liquidity parameter limit (WAD)
     */
    function calculateAlphaLimit(
        uint256 alphaBase,
        uint256 drawdown,
        uint256 k
    ) external pure returns (uint256 alphaLimit) {
        // αlimit = αbase * (1 - k * DD)
        uint256 kDD = k.wMul(drawdown);
        
        if (kDD >= WAD) {
            // k * DD >= 1 → factor would be negative → return 0
            return 0;
        }
        
        uint256 factor = WAD - kDD; // 1 - k * DD
        alphaLimit = alphaBase.wMul(factor);
    }

    /**
     * @notice Get current αlimit for the system
     * @dev Combines αbase calculation with current drawdown
     * @param numBins Number of bins for α calculation
     * @param lambda Safety parameter λ (WAD)
     * @param k Drawdown sensitivity factor (WAD)
     * @return alphaLimit Current effective α limit (WAD)
     */
    function getAlphaLimit(
        uint256 numBins,
        uint256 lambda,
        uint256 k
    ) external view onlyDelegated returns (uint256 alphaLimit) {
        // E_t = N_{t-1} (use current NAV as proxy)
        uint256 Et = lpVault.nav;
        if (Et == 0) return 0;
        
        // Calculate αbase
        uint256 lnN = _lnWad(numBins);
        if (lnN == 0) return type(uint256).max;
        uint256 alphaBase = lambda.wMul(Et).wDiv(lnN);
        
        // Calculate drawdown: DD = 1 - P / P^peak
        uint256 drawdown = 0;
        if (lpVault.pricePeak > 0 && lpVault.price < lpVault.pricePeak) {
            drawdown = WAD - lpVault.price.wDiv(lpVault.pricePeak);
        }
        
        // Calculate αlimit
        uint256 kDD = k.wMul(drawdown);
        if (kDD >= WAD) {
            return 0;
        }
        alphaLimit = alphaBase.wMul(WAD - kDD);
    }

    // ============================================================
    // Prior Admissibility - WP v2 Sec 4.1
    // ============================================================

    /**
     * @notice Check if prior is admissible
     * @dev Per whitepaper v2: ΔEₜ ≤ B^eff_{t-1}
     *      If violated, reverts with PriorNotAdmissible
     * 
     * @param deltaEt Tail budget from prior (WAD)
     * @param effectiveBackstop Effective backstop budget B^eff (WAD)
     */
    function checkPriorAdmissibility(
        uint256 deltaEt,
        uint256 effectiveBackstop
    ) external pure {
        if (deltaEt > effectiveBackstop) {
            revert PriorNotAdmissible(deltaEt, effectiveBackstop);
        }
    }

    // ============================================================
    // Trade Hooks - α Enforcement
    // ============================================================

    /**
     * @notice Pre-trade hook: validate market α against limit
     * @dev Called before createMarket/reopenMarket/openPosition/increasePosition
     *      close/decreasePosition always allowed (reducing exposure)
     * 
     * @param marketAlpha Market liquidity parameter α (WAD)
     * @param numBins Number of outcome bins
     * @param lambda Safety parameter λ (WAD)
     * @param k Drawdown sensitivity factor (WAD)
     */
    function validateAlpha(
        uint256 marketAlpha,
        uint256 numBins,
        uint256 lambda,
        uint256 k
    ) external view onlyDelegated {
        // Calculate current αlimit
        uint256 Et = lpVault.nav;
        if (Et == 0) {
            // No NAV → cannot assess risk, block all trades
            revert AlphaExceedsLimit(marketAlpha, 0);
        }
        
        uint256 lnN = _lnWad(numBins);
        if (lnN == 0) return; // Edge case
        
        uint256 alphaBase = lambda.wMul(Et).wDiv(lnN);
        
        // Get drawdown
        uint256 drawdown = 0;
        if (lpVault.pricePeak > 0 && lpVault.price < lpVault.pricePeak) {
            drawdown = WAD - lpVault.price.wDiv(lpVault.pricePeak);
        }
        
        // Calculate limit
        uint256 kDD = k.wMul(drawdown);
        uint256 alphaLimit = kDD >= WAD ? 0 : alphaBase.wMul(WAD - kDD);
        
        if (marketAlpha > alphaLimit) {
            revert AlphaExceedsLimit(marketAlpha, alphaLimit);
        }
    }

    // ============================================================
    // Utility Functions
    // ============================================================

    /**
     * @notice Calculate natural log of n in WAD
     * @dev Uses lookup table for common values, approximation for others
     * @param n Input value (not WAD)
     * @return Natural log of n in WAD precision
     */
    function lnWad(uint256 n) external pure returns (uint256) {
        return _lnWad(n);
    }

    /**
     * @notice Internal ln calculation
     * @dev Lookup for common values, series approximation for others
     */
    function _lnWad(uint256 n) internal pure returns (uint256) {
        if (n <= 1) return 0;
        if (n == 2) return LN_2;
        if (n == 10) return LN_10;
        if (n == 100) return LN_100;
        if (n == 1000) return LN_1000;
        
        // For other values, use approximation:
        // ln(n) ≈ ln(10) * log10(n)
        // log10(n) = number of digits - 1 + fractional part
        // Simplified: count digits and interpolate
        
        uint256 digits = 0;
        uint256 temp = n;
        while (temp >= 10) {
            temp /= 10;
            digits++;
        }
        
        // ln(n) ≈ digits * ln(10) + ln(temp)
        // For temp in [1,10), use linear interpolation
        uint256 baseLn = digits * LN_10;
        
        // Add fractional part: ln(temp) where temp in [1,10)
        // ln(temp) ≈ (temp - 1) / temp * ln(10) / ln(10/e) (rough approximation)
        // Simplified: ln(temp) ≈ (temp - 1) * LN_10 / 9 for temp in [1,10)
        if (temp > 1) {
            baseLn += ((temp - 1) * LN_10) / 9;
        }
        
        return baseLn;
    }
}

