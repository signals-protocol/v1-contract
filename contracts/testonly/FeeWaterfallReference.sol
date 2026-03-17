// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title FeeWaterfallReference
/// @notice Pure Solidity reference implementation of the Fee Waterfall algorithm (whitepaper §4.3-4.6).
/// @dev Port of test/helpers/feeWaterfallReference.ts. Used to verify on-chain FeeWaterfallLib
///      matches expected behavior. NOT for production use — this is a test-only contract.
library FeeWaterfallReference {
    uint256 internal constant WAD = 1e18;

    struct Params {
        int256 Lt; // P&L (signed)
        uint256 Ftot; // Total gross fees
        uint256 Nprev; // Previous NAV
        uint256 Bprev; // Previous Backstop NAV
        uint256 Tprev; // Previous Treasury NAV
        uint256 deltaEt; // Available backstop support
        int256 pdd; // NAV loss floor (negative, WAD)
        uint256 rhoBS; // Backstop coverage ratio (WAD)
        uint256 phiLP; // LP fee share (WAD)
        uint256 phiBS; // Backstop fee share (WAD)
        uint256 phiTR; // Treasury fee share (WAD)
    }

    struct Result {
        // Intermediate values
        uint256 Floss;
        uint256 Fpool;
        uint256 Nraw;
        uint256 Gt;
        uint256 Ffill;
        uint256 Fdust;
        // Output values
        uint256 Ft;
        uint256 Npre;
        uint256 Bnext;
        uint256 Tnext;
    }

    // ============================================================
    // WAD math (matching TS: wMul, wMulUp)
    // ============================================================

    function _wMul(uint256 a, uint256 b) private pure returns (uint256) {
        return (a * b) / WAD;
    }

    /// @dev Ceil semantics for Nfloor calculation — ensures grantNeed is never under-estimated
    function _wMulUp(uint256 a, uint256 b) private pure returns (uint256) {
        uint256 product = a * b;
        if (product == 0) return 0;
        return (product - 1) / WAD + 1;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    // ============================================================
    // Main calculation
    // ============================================================

    /// @notice Calculate fee waterfall (reference implementation)
    /// @dev Mirrors calculateFeeWaterfall() in feeWaterfallReference.ts exactly
    function calculate(Params memory p) internal pure returns (Result memory r) {
        // Validate inputs
        require(p.pdd < 0 && p.pdd >= -int256(WAD), "InvalidDrawdownFloor");
        require(p.phiLP + p.phiBS + p.phiTR == WAD, "InvalidPhiSum");

        // Step 1: Loss Compensation
        uint256 Lneg = p.Lt < 0 ? uint256(-p.Lt) : 0;
        r.Floss = _min(p.Ftot, Lneg);
        r.Fpool = p.Ftot - r.Floss;

        // Nraw = Nprev + Lt + Floss
        if (p.Lt >= 0) {
            r.Nraw = p.Nprev + uint256(p.Lt) + r.Floss;
        } else {
            uint256 loss = uint256(-p.Lt);
            uint256 temp = p.Nprev + r.Floss;
            require(temp >= loss, "CatastrophicLoss");
            r.Nraw = temp - loss;
        }

        // Step 2: NAV Loss Floor & Grant
        uint256 Nfloor;
        if (p.Nprev > 0) {
            int256 wadPlusPdd = int256(WAD) + p.pdd;
            Nfloor = wadPlusPdd > 0 ? _wMulUp(p.Nprev, uint256(wadPlusPdd)) : 0;
        }

        uint256 grantNeed = Nfloor > r.Nraw ? Nfloor - r.Nraw : 0;
        require(grantNeed <= p.deltaEt, "GrantExceedsTailBudget");
        r.Gt = grantNeed;
        require(r.Gt <= p.Bprev, "InsufficientBackstopForGrant");

        uint256 Ngrant = r.Nraw + r.Gt;
        uint256 Bgrant = p.Bprev - r.Gt;

        // Step 3: Backstop Coverage Target
        uint256 Btarget = _wMul(p.rhoBS, Ngrant);
        uint256 dBneed = Btarget > Bgrant ? Btarget - Bgrant : 0;
        r.Ffill = _min(dBneed, r.Fpool);
        uint256 Fremain = r.Fpool - r.Ffill;

        // Step 4: Residual Split
        uint256 FcoreLP = _wMul(Fremain, p.phiLP);
        uint256 FcoreBS = _wMul(Fremain, p.phiBS);
        uint256 FcoreTR = _wMul(Fremain, p.phiTR);
        r.Fdust = Fremain - FcoreLP - FcoreBS - FcoreTR;

        // Step 5: Final Output Values
        r.Ft = r.Floss + FcoreLP + r.Fdust;
        r.Npre = Ngrant + FcoreLP + r.Fdust;
        r.Bnext = Bgrant + r.Ffill + FcoreBS;
        r.Tnext = p.Tprev + FcoreTR;
    }
}
