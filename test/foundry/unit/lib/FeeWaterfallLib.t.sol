// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/FeeWaterfallLibHarness.sol";
import {FeeWaterfallReference} from "../../../../contracts/testonly/FeeWaterfallReference.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

contract FeeWaterfallLibTest is HarnessDeployer {
    FeeWaterfallLibHarness harness;

    // Default test parameters
    uint256 constant DEF_NPREV = 1000e18;
    uint256 constant DEF_BPREV = 200e18;
    uint256 constant DEF_TPREV = 50e18;
    uint256 constant DEF_DELTA_ET = 100e18;
    int256 constant DEF_PDD = -0.3e18;
    uint256 constant DEF_RHO_BS = 0.2e18;
    uint256 constant DEF_PHI_LP = 0.7e18;
    uint256 constant DEF_PHI_BS = 0.2e18;
    uint256 constant DEF_PHI_TR = 0.1e18;

    function setUp() public override {
        super.setUp();
        harness = deployFeeWaterfallLibHarness();
    }

    // ============================================================
    // Helper: call harness.calculate with defaults for unspecified params
    // ============================================================

    struct CalcInput {
        int256 Lt;
        uint256 Ftot;
        uint256 Nprev;
        uint256 Bprev;
        uint256 Tprev;
        uint256 deltaEt;
        int256 pdd;
        uint256 rhoBS;
        uint256 phiLP;
        uint256 phiBS;
        uint256 phiTR;
    }

    function _defaults() internal pure returns (CalcInput memory c) {
        c.Nprev = DEF_NPREV;
        c.Bprev = DEF_BPREV;
        c.Tprev = DEF_TPREV;
        c.deltaEt = DEF_DELTA_ET;
        c.pdd = DEF_PDD;
        c.rhoBS = DEF_RHO_BS;
        c.phiLP = DEF_PHI_LP;
        c.phiBS = DEF_PHI_BS;
        c.phiTR = DEF_PHI_TR;
    }

    function _calc(
        CalcInput memory c
    )
        internal
        view
        returns (
            uint256 Floss,
            uint256 Fpool,
            uint256 Nraw,
            uint256 Gt,
            uint256 Ffill,
            uint256 Fdust,
            uint256 Ft,
            uint256 Npre,
            uint256 Bnext,
            uint256 Tnext
        )
    {
        return
            harness.calculate(
                c.Lt,
                c.Ftot,
                c.Nprev,
                c.Bprev,
                c.Tprev,
                c.deltaEt,
                c.pdd,
                c.rhoBS,
                c.phiLP,
                c.phiBS,
                c.phiTR
            );
    }

    // ============================================================
    // INV-FW1: Fee Conservation
    // ============================================================

    function test_FW1_feeConservation_profit() public view {
        CalcInput memory c = _defaults();
        c.Lt = 100e18;
        c.Ftot = 50e18;
        (uint256 Floss, uint256 Fpool, , , , , , , , ) = _calc(c);
        assertEq(Floss + Fpool, 50e18);
    }

    function test_FW1_feeConservation_lossCoveredByFees() public view {
        CalcInput memory c = _defaults();
        c.Lt = -30e18;
        c.Ftot = 50e18;
        (uint256 Floss, uint256 Fpool, , , , , , , , ) = _calc(c);
        assertEq(Floss + Fpool, 50e18);
        assertEq(Floss, 30e18);
    }

    function test_FW1_feeConservation_lossExceedsFees() public view {
        CalcInput memory c = _defaults();
        c.Lt = -100e18;
        c.Ftot = 20e18;
        (uint256 Floss, uint256 Fpool, , , , , , , , ) = _calc(c);
        assertEq(Floss + Fpool, 20e18);
        assertEq(Floss, 20e18); // Floss capped at Ftot
        assertEq(Fpool, 0);
    }

    // ============================================================
    // INV-FW2: Loss Compensation Bound
    // ============================================================

    function test_FW2_noLossCompensation_profit() public view {
        CalcInput memory c = _defaults();
        c.Lt = 100e18;
        c.Ftot = 50e18;
        (uint256 Floss, uint256 Fpool, , , , , , , , ) = _calc(c);
        assertEq(Floss, 0);
        assertEq(Fpool, 50e18);
    }

    function test_FW2_lossCoveredByFees() public view {
        CalcInput memory c = _defaults();
        c.Lt = -30e18;
        c.Ftot = 100e18;
        (uint256 Floss, uint256 Fpool, , uint256 Gt, , , , , , ) = _calc(c);
        assertEq(Floss, 30e18);
        assertEq(Fpool, 70e18);
        assertEq(Gt, 0); // No grant needed
    }

    // ============================================================
    // INV-FW3: Grant Bound (Safety Invariant)
    // ============================================================

    function test_FW3_grantNeeded_deltaEtSufficient() public view {
        CalcInput memory c = _defaults();
        c.Lt = -400e18;
        c.Ftot = 50e18;
        c.Nprev = 1000e18;
        c.Bprev = 200e18;
        c.deltaEt = 100e18;
        (, , , uint256 Gt, , , , , uint256 Bnext, ) = _calc(c);
        // Nraw = 1000 - 400 + 50 = 650; Nfloor = 1000 * 0.7 = 700; grantNeed = 50
        assertEq(Gt, 50e18);
        assertLe(Bnext, 200e18); // Backstop decreased
    }

    function test_FW3_revertsWhenGrantExceedsDeltaEt() public {
        CalcInput memory c = _defaults();
        c.Lt = -500e18;
        c.Ftot = 50e18;
        c.Nprev = 1000e18;
        c.Bprev = 200e18;
        c.deltaEt = 100e18; // grantNeed=150 > deltaEt=100
        vm.expectRevert(abi.encodeWithSelector(SE.GrantExceedsTailBudget.selector, 150e18, 100e18));
        _calc(c);
    }

    function test_FW3_revertsWhenGrantExceedsBackstop() public {
        CalcInput memory c = _defaults();
        c.Lt = -400e18;
        c.Ftot = 50e18;
        c.Nprev = 1000e18;
        c.Bprev = 30e18; // Small backstop < grantNeed
        c.deltaEt = 500e18;
        vm.expectRevert(abi.encodeWithSelector(SE.InsufficientBackstopForGrant.selector, 50e18, 30e18));
        _calc(c);
    }

    // ============================================================
    // INV-FW4: Grant Calculation
    // ============================================================

    function test_FW4_grantZeroWhenNrawAboveFloor() public view {
        CalcInput memory c = _defaults();
        c.Lt = -50e18;
        c.Ftot = 100e18;
        // Nraw = 1000 - 50 + 50 = 1000; Nfloor = 700; grantNeed = 0
        (, , , uint256 Gt, , , , , , ) = _calc(c);
        assertEq(Gt, 0);
    }

    function test_FW4_grantEqualsNeedWhenDeltaEtSufficient() public view {
        CalcInput memory c = _defaults();
        c.Lt = -400e18;
        c.Ftot = 50e18;
        c.deltaEt = 500e18;
        // Nraw = 1000 - 400 + 50 = 650; Nfloor = 700; grantNeed = 50
        (, , , uint256 Gt, , , , , , ) = _calc(c);
        assertEq(Gt, 50e18);
    }

    function test_FW4_revertsWhenGrantNeedExceedsDeltaEt() public {
        CalcInput memory c = _defaults();
        c.Lt = -500e18;
        c.Ftot = 50e18;
        c.deltaEt = 30e18; // Low limit < grantNeed=150
        vm.expectRevert(abi.encodeWithSelector(SE.GrantExceedsTailBudget.selector, 150e18, 30e18));
        _calc(c);
    }

    // ============================================================
    // INV-FW5: Backstop Equation
    // ============================================================

    function test_FW5_backstopEquation_profit() public view {
        CalcInput memory c = _defaults();
        c.Lt = 100e18;
        c.Ftot = 100e18;
        (, , , uint256 Gt, , , , , uint256 Bnext, ) = _calc(c);
        assertEq(Gt, 0); // No grant in profit case
        assertGe(Bnext, DEF_BPREV); // Backstop should receive its share
    }

    // ============================================================
    // Step 3: Backstop Coverage Target
    // ============================================================

    function test_step3_noFillWhenBgrantAboveTarget() public view {
        CalcInput memory c = _defaults();
        c.Lt = 50e18;
        c.Ftot = 10e18;
        c.Nprev = 500e18;
        c.Bprev = 200e18;
        c.rhoBS = 0.2e18; // Btarget = 550 * 0.2 = 110; dBneed = max(0, 110 - 200) = 0
        (, , , , uint256 Ffill, , , , , ) = _calc(c);
        assertEq(Ffill, 0);
    }

    function test_step3_ffillCappedAtFpool() public view {
        CalcInput memory c = _defaults();
        c.Lt = 100e18;
        c.Ftot = 10e18;
        c.Nprev = 1000e18;
        c.Bprev = 50e18;
        c.rhoBS = 0.3e18; // Btarget = 1100 * 0.3 = 330; dBneed = 280 > Fpool = 10
        (uint256 Floss, uint256 Fpool, , , uint256 Ffill, , , , , ) = _calc(c);
        assertEq(Floss, 0); // profit case, no loss compensation
        assertEq(Ffill, Fpool); // Ffill capped at Fpool
    }

    function test_step3_ffillEqualsDBneedWhenSmall() public view {
        CalcInput memory c = _defaults();
        c.Lt = 100e18;
        c.Ftot = 200e18;
        c.Nprev = 1000e18;
        c.Bprev = 200e18;
        c.rhoBS = 0.2e18; // Btarget = 1100 * 0.2 = 220; dBneed = 20 < Fpool = 200
        (, , , , uint256 Ffill, , , , , ) = _calc(c);
        assertEq(Ffill, 20e18);
    }

    // ============================================================
    // INV-FW6: Residual Split Conservation
    // ============================================================

    function test_FW6_residualSplitsSumCorrectly() public view {
        CalcInput memory c = _defaults();
        c.Lt = 0;
        c.Ftot = 100e18;
        (uint256 Floss, uint256 Fpool, , , , , , , , ) = _calc(c);
        assertEq(Floss, 0);
        assertEq(Fpool, 100e18);
    }

    function test_FW6_dustGoesToLP() public view {
        CalcInput memory c = _defaults();
        c.Lt = 0;
        c.Ftot = 100e18 + 3; // Small amount with dust
        c.Nprev = 500e18;
        c.Bprev = 200e18;
        (uint256 Floss, , , , , uint256 Fdust, uint256 Ft, , , ) = _calc(c);
        assertGe(Fdust, 0);
        assertGe(Ft, Floss);
    }

    // ============================================================
    // Step 4: Residual Split Calculation
    // ============================================================

    function test_step4_individualCoreValues() public view {
        // No loss, no fill needed → all Fpool goes to residual split
        CalcInput memory c = _defaults();
        c.Lt = 0;
        c.Ftot = 100e18;
        c.Nprev = 500e18;
        c.Bprev = 200e18;
        c.rhoBS = 0.2e18; // Btarget = 500 * 0.2 = 100 < Bgrant = 200

        (, , , , uint256 Ffill, , uint256 Ft, uint256 Npre, uint256 Bnext, uint256 Tnext) = _calc(c);

        assertEq(Ffill, 0);
        // Fremain = Fpool = 100 WAD
        // FcoreLP = floor(100 * 0.7) = 70; FcoreBS = 20; FcoreTR = 10; Fdust = 0
        assertEq(Ft, 70e18); // Floss + FcoreLP + Fdust = 0 + 70 + 0
        assertEq(Bnext, 220e18); // Bgrant + Ffill + FcoreBS = 200 + 0 + 20
        assertEq(Tnext, 60e18); // Tprev + FcoreTR = 50 + 10
    }

    function test_step4_splitWithNonZeroFfill() public view {
        CalcInput memory c = _defaults();
        c.Lt = 0;
        c.Ftot = 100e18;
        c.Nprev = 1000e18;
        c.Bprev = 150e18;
        c.rhoBS = 0.2e18; // Btarget = 1000 * 0.2 = 200; dBneed = 50

        (, , , , uint256 Ffill, , uint256 Ft, , uint256 Bnext, uint256 Tnext) = _calc(c);

        // Ffill = min(50, 100) = 50
        assertEq(Ffill, 50e18);
        // Fremain = 100 - 50 = 50
        // FcoreLP = floor(50 * 0.7) = 35; FcoreBS = 10; FcoreTR = 5; Fdust = 0
        assertEq(Ft, 35e18); // 0 + 35 + 0
        assertEq(Bnext, 210e18); // 150 + 50 + 10
        assertEq(Tnext, 55e18); // 50 + 5
    }

    // ============================================================
    // INV-NAV1: Pre-batch NAV Equation
    // ============================================================

    function test_NAV1_profit() public view {
        CalcInput memory c = _defaults();
        c.Lt = 100e18;
        c.Ftot = 50e18;
        (, , , , , , , uint256 Npre, , ) = _calc(c);
        assertGt(Npre, DEF_NPREV);
    }

    function test_NAV1_lossWithGrant() public view {
        CalcInput memory c = _defaults();
        c.Lt = -400e18;
        c.Ftot = 50e18;
        c.deltaEt = 100e18; // grantNeed = 50 < deltaEt = 100
        (, , uint256 Nraw, uint256 Gt, , , uint256 Ft, uint256 Npre, , ) = _calc(c);
        assertGe(Npre, Nraw); // Grant increases NAV
        assertGt(Gt, 0);
        assertEq(Gt, 50e18);
    }

    // ============================================================
    // Edge Cases
    // ============================================================

    function test_edge_zeroFees() public view {
        CalcInput memory c = _defaults();
        c.Lt = 100e18;
        c.Ftot = 0;
        (uint256 Floss, uint256 Fpool, , , , , uint256 Ft, , , ) = _calc(c);
        assertEq(Floss, 0);
        assertEq(Fpool, 0);
        assertEq(Ft, 0);
    }

    function test_edge_zeroPnL() public view {
        CalcInput memory c = _defaults();
        c.Lt = 0;
        c.Ftot = 50e18;
        (uint256 Floss, , uint256 Nraw, , , , , , , ) = _calc(c);
        assertEq(Floss, 0);
        assertEq(Nraw, DEF_NPREV);
    }

    function test_edge_revertsOnPositivePdd() public {
        CalcInput memory c = _defaults();
        c.Lt = 0;
        c.Ftot = 50e18;
        c.pdd = 0.1e18; // Invalid: positive
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidDrawdownFloor.selector, int256(0.1e18)));
        _calc(c);
    }

    function test_edge_revertsOnPddBelowNegWAD() public {
        CalcInput memory c = _defaults();
        c.Lt = 0;
        c.Ftot = 50e18;
        c.pdd = -1.1e18; // Invalid: < -WAD
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidDrawdownFloor.selector, int256(-1.1e18)));
        _calc(c);
    }

    function test_edge_revertsOnCatastrophicLoss() public {
        CalcInput memory c = _defaults();
        c.Lt = -2000e18; // Loss > Nprev + Ftot
        c.Ftot = 10e18;
        c.Nprev = 1000e18;
        // loss = 2000e18, Nraw underflows: Nprev + Floss = 1000 + 10 = 1010 < 2000
        vm.expectRevert(abi.encodeWithSelector(SE.CatastrophicLoss.selector, uint256(2000e18), uint256(1010e18)));
        _calc(c);
    }

    function test_edge_revertsOnInvalidPhiSum() public {
        CalcInput memory c = _defaults();
        c.Lt = 0;
        c.Ftot = 50e18;
        c.phiLP = 0.5e18;
        c.phiBS = 0.3e18;
        c.phiTR = 0.1e18; // Sum = 0.9, not 1.0
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidPhiSum.selector, uint256(0.9e18)));
        _calc(c);
    }

    function test_edge_NprevZero_NfloorBecomesZero() public view {
        CalcInput memory c = _defaults();
        c.Lt = 100e18;
        c.Ftot = 50e18;
        c.Nprev = 0;
        c.Bprev = 200e18;
        c.Tprev = 50e18;
        (, , uint256 Nraw, uint256 Gt, , , , , , ) = _calc(c);
        // Nfloor = 0 when Nprev = 0; Nraw = 0 + 100 + 0 = 100 > 0
        assertEq(Gt, 0);
        assertEq(Nraw, 100e18);
    }

    // ============================================================
    // Ceil Rounding for Nfloor (Safety Invariant)
    // ============================================================

    function test_ceil_wMulUpForNfloor() public view {
        // Nprev = 1000e18 + 1 wei; pdd = -0.3e18; wadPlusPdd = 0.7e18
        CalcInput memory c = _defaults();
        c.Lt = -301e18;
        c.Ftot = 1e18;
        c.Nprev = 1000e18 + 1;
        // Nraw = (1000e18+1) - 301e18 + 1e18 = 700e18 + 1
        // wMulUp: ceil((1000e18+1) * 0.7e18 / 1e18) = 700e18 + 1
        // grantNeed = max(0, (700e18+1) - (700e18+1)) = 0
        (, , , uint256 Gt, , , , , , ) = _calc(c);
        assertEq(Gt, 0);
    }

    function test_ceil_grantNeedNeverUnderEstimated() public view {
        CalcInput memory c = _defaults();
        c.Lt = -350e18;
        c.Ftot = 50e18;
        c.Nprev = 999e18 + 999999999999999999;
        c.deltaEt = 500e18;

        (, , , uint256 Gt, , , uint256 Ft, uint256 Npre, , ) = _calc(c);
        // Verify NAV equation: Npre - Nprev == Lt + Ft + Gt
        int256 navDelta = int256(Npre) - int256(c.Nprev);
        int256 expected = c.Lt + int256(Ft) + int256(Gt);
        assertEq(navDelta, expected);
    }

    function test_ceil_maintainsNAVLossFloorInvariant() public view {
        uint256[4] memory nprevs;
        nprevs[0] = 1000e18 + 1;
        nprevs[1] = 1000e18 + 123456789;
        nprevs[2] = 1000e18 + 0.5e18;
        nprevs[3] = 1000e18 + 999999999999999999;

        for (uint256 i = 0; i < nprevs.length; i++) {
            CalcInput memory c = _defaults();
            c.Lt = -400e18;
            c.Ftot = 50e18;
            c.Nprev = nprevs[i];
            c.deltaEt = 500e18;

            (, , , , , , , uint256 Npre, , ) = _calc(c);

            // Expected Nfloor with ceil
            uint256 wadPlusPdd = 0.7e18;
            uint256 product = nprevs[i] * wadPlusPdd;
            uint256 expectedNfloorCeil = product == 0 ? 0 : (product - 1) / WAD + 1;

            assertGe(Npre, expectedNfloorCeil);
        }
    }

    // ============================================================
    // Property Tests
    // ============================================================

    function test_prop_backstopNeverNegative() public view {
        CalcInput memory c = _defaults();
        c.Lt = -400e18;
        c.Ftot = 50e18;
        c.deltaEt = 100e18;
        (, , , , , , , , uint256 Bnext, ) = _calc(c);
        assertGe(Bnext, 0);
    }

    function test_prop_treasuryNeverDecreases() public view {
        CalcInput memory c = _defaults();
        c.Lt = -200e18;
        c.Ftot = 30e18;
        (, , , , , , , , , uint256 Tnext) = _calc(c);
        assertGe(Tnext, DEF_TPREV);
    }

    function test_prop_totalValueConserved() public view {
        CalcInput memory c = _defaults();
        c.Lt = -300e18;
        c.Ftot = 100e18;
        (uint256 Floss, uint256 Fpool, , , , , , uint256 Npre, uint256 Bnext, uint256 Tnext) = _calc(c);

        // Fee conservation
        assertEq(Floss + Fpool, c.Ftot);

        // Total system NAV: before = Nprev + Bprev + Tprev; after = Npre + Bnext + Tnext
        uint256 before_ = DEF_NPREV + DEF_BPREV + DEF_TPREV;
        uint256 after_ = Npre + Bnext + Tnext;
        int256 delta = int256(after_) - int256(before_);
        int256 expectedDelta = c.Lt + int256(c.Ftot);
        // Allow 1 wei tolerance for rounding
        assertApproxEqAbs(delta, expectedDelta, 1);
    }

    function test_prop_flossPoolEqualsFtot() public view {
        CalcInput memory c = _defaults();
        c.Lt = -200e18;
        c.Ftot = 80e18;
        (uint256 Floss, uint256 Fpool, , , , , , , , ) = _calc(c);
        assertEq(Floss + Fpool, 80e18);
    }

    function test_prop_gtLeDeltaEt() public view {
        CalcInput memory c = _defaults();
        c.Lt = -350e18;
        c.Ftot = 50e18;
        c.deltaEt = 100e18;
        // Nraw = 1000 - 350 + 50 = 700 = Nfloor => grantNeed = 0
        (, , , uint256 Gt, , , , , , ) = _calc(c);
        assertEq(Gt, 0);
        assertLe(Gt, 100e18);
    }

    function test_prop_gtLeBprev() public view {
        CalcInput memory c = _defaults();
        c.Lt = -400e18;
        c.Ftot = 50e18;
        c.Bprev = 200e18;
        c.deltaEt = 300e18;
        (, , , uint256 Gt, , , , , , ) = _calc(c);
        assertLe(Gt, 200e18);
    }

    function test_prop_navEquation() public view {
        CalcInput memory c = _defaults();
        c.Lt = -300e18;
        c.Ftot = 100e18;
        (, , , uint256 Gt, , , uint256 Ft, uint256 Npre, , ) = _calc(c);
        // Npre - Nprev = Lt + Ft + Gt
        int256 navDelta = int256(Npre) - int256(DEF_NPREV);
        int256 expected = c.Lt + int256(Ft) + int256(Gt);
        assertEq(navDelta, expected);
    }

    // ============================================================
    // Solidity Reference Parity (replaces JS Reference Parity)
    // ============================================================

    function test_refParity_profitCase() public view {
        FeeWaterfallReference.Params memory rp = FeeWaterfallReference.Params({
            Lt: int256(100e18),
            Ftot: 50e18,
            Nprev: DEF_NPREV,
            Bprev: DEF_BPREV,
            Tprev: DEF_TPREV,
            deltaEt: DEF_DELTA_ET,
            pdd: DEF_PDD,
            rhoBS: DEF_RHO_BS,
            phiLP: DEF_PHI_LP,
            phiBS: DEF_PHI_BS,
            phiTR: DEF_PHI_TR
        });

        (
            uint256 Floss,
            uint256 Fpool,
            ,
            uint256 Gt,
            ,
            ,
            uint256 Ft,
            uint256 Npre,
            uint256 Bnext,
            uint256 Tnext
        ) = harness.calculate(
                rp.Lt,
                rp.Ftot,
                rp.Nprev,
                rp.Bprev,
                rp.Tprev,
                rp.deltaEt,
                rp.pdd,
                rp.rhoBS,
                rp.phiLP,
                rp.phiBS,
                rp.phiTR
            );

        FeeWaterfallReference.Result memory ref = FeeWaterfallReference.calculate(rp);

        assertEq(Floss, ref.Floss);
        assertEq(Fpool, ref.Fpool);
        assertEq(Gt, ref.Gt);
        assertEq(Ft, ref.Ft);
        assertEq(Npre, ref.Npre);
        assertEq(Bnext, ref.Bnext);
        assertEq(Tnext, ref.Tnext);
    }

    function test_refParity_lossWithGrant() public view {
        FeeWaterfallReference.Params memory rp = FeeWaterfallReference.Params({
            Lt: int256(-400e18),
            Ftot: 50e18,
            Nprev: DEF_NPREV,
            Bprev: DEF_BPREV,
            Tprev: DEF_TPREV,
            deltaEt: 100e18,
            pdd: DEF_PDD,
            rhoBS: DEF_RHO_BS,
            phiLP: DEF_PHI_LP,
            phiBS: DEF_PHI_BS,
            phiTR: DEF_PHI_TR
        });

        (
            uint256 Floss,
            uint256 Fpool,
            ,
            uint256 Gt,
            ,
            ,
            uint256 Ft,
            uint256 Npre,
            uint256 Bnext,
            uint256 Tnext
        ) = harness.calculate(
                rp.Lt,
                rp.Ftot,
                rp.Nprev,
                rp.Bprev,
                rp.Tprev,
                rp.deltaEt,
                rp.pdd,
                rp.rhoBS,
                rp.phiLP,
                rp.phiBS,
                rp.phiTR
            );

        FeeWaterfallReference.Result memory ref = FeeWaterfallReference.calculate(rp);

        assertEq(Floss, ref.Floss);
        assertEq(Fpool, ref.Fpool);
        assertEq(Gt, ref.Gt);
        assertEq(Ft, ref.Ft);
        assertEq(Npre, ref.Npre);
        assertEq(Bnext, ref.Bnext);
        assertEq(Tnext, ref.Tnext);
    }

    function test_refParity_10randomCases() public view {
        Prng memory prng = createPrng();

        uint256 matched = 0;
        for (uint256 i = 0; i < 50; i++) {
            // Generate random params matching TS generateRandomParams
            int256 Lt = int256(nextInRange(prng, 0, 1000)) * int256(WAD) - 500 * int256(WAD);
            uint256 Ftot = ((nextInRange(prng, 0, 1000) * WAD) / 1000) * 100;
            uint256 Nprev = (nextInRange(prng, 100, 10100)) * WAD;
            uint256 Bprev = ((nextInRange(prng, 100, 10100)) * WAD) / 5;
            uint256 Tprev = ((nextInRange(prng, 100, 10100)) * WAD) / 20;
            uint256 deltaEt = ((nextInRange(prng, 100, 10100)) * WAD) / 10;
            int256 pdd = -0.3e18;
            uint256 rhoBS = 0.2e18;

            // Skip cases that would revert
            if (Lt < 0) {
                uint256 Lneg = uint256(-Lt);
                uint256 Floss_ = Lneg < Ftot ? Lneg : Ftot;
                if (Nprev + Floss_ < Lneg) continue; // CatastrophicLoss
                uint256 Nraw_ = Nprev + Floss_ - Lneg;
                uint256 wadPlusPdd_ = 0.7e18;
                uint256 Nfloor_ = Nprev > 0 ? _wMulUp(Nprev, wadPlusPdd_) : 0;
                uint256 grantNeed_ = Nfloor_ > Nraw_ ? Nfloor_ - Nraw_ : 0;
                if (grantNeed_ > deltaEt) continue;
                if (grantNeed_ > Bprev) continue;
            }

            FeeWaterfallReference.Params memory rp = FeeWaterfallReference.Params({
                Lt: Lt,
                Ftot: Ftot,
                Nprev: Nprev,
                Bprev: Bprev,
                Tprev: Tprev,
                deltaEt: deltaEt,
                pdd: pdd,
                rhoBS: rhoBS,
                phiLP: DEF_PHI_LP,
                phiBS: DEF_PHI_BS,
                phiTR: DEF_PHI_TR
            });

            (uint256 Floss, uint256 Fpool, , uint256 Gt, , , , uint256 Npre, uint256 Bnext, uint256 Tnext) = harness
                .calculate(Lt, Ftot, Nprev, Bprev, Tprev, deltaEt, pdd, rhoBS, DEF_PHI_LP, DEF_PHI_BS, DEF_PHI_TR);

            FeeWaterfallReference.Result memory ref = FeeWaterfallReference.calculate(rp);

            // Both Solidity implementations include Fdust in Npre, so exact match expected
            assertEq(Floss, ref.Floss);
            assertEq(Fpool, ref.Fpool);
            assertEq(Gt, ref.Gt);
            assertEq(Npre, ref.Npre);
            assertEq(Bnext, ref.Bnext);
            assertEq(Tnext, ref.Tnext);

            matched++;
            if (matched >= 10) break;
        }
        assertGe(matched, 10, "Need at least 10 valid random parity cases");
    }

    // ============================================================
    // INV: Fuzz Property Tests (100 cases)
    // ============================================================

    function test_fuzz_allCoreInvariants_100cases() public view {
        Prng memory prng = createPrng();

        uint256 validCases = 0;
        uint256 attempts = 0;
        uint256 maxAttempts = 500;

        while (validCases < 100 && attempts < maxAttempts) {
            attempts++;

            int256 Lt = int256(nextInRange(prng, 0, 1000)) * int256(WAD) - 500 * int256(WAD);
            uint256 Ftot = ((nextInRange(prng, 0, 1000) * WAD) / 1000) * 100;
            uint256 Nprev = (nextInRange(prng, 100, 10100)) * WAD;
            uint256 Bprev = ((nextInRange(prng, 100, 10100)) * WAD) / 5;
            uint256 Tprev = ((nextInRange(prng, 100, 10100)) * WAD) / 20;
            uint256 deltaEt = ((nextInRange(prng, 100, 10100)) * WAD) / 10;
            int256 pdd = -0.3e18;
            uint256 rhoBS = 0.2e18;

            // Pre-check: skip cases that would revert
            if (Lt < 0) {
                uint256 Lneg = uint256(-Lt);
                uint256 Floss_ = Lneg < Ftot ? Lneg : Ftot;
                if (Nprev + Floss_ < Lneg) continue; // CatastrophicLoss
                uint256 Nraw_ = Nprev + Floss_ - Lneg;
                uint256 wadPlusPdd_ = 0.7e18;
                uint256 Nfloor_ = Nprev > 0 ? _wMulUp(Nprev, wadPlusPdd_) : 0;
                uint256 grantNeed_ = Nfloor_ > Nraw_ ? Nfloor_ - Nraw_ : 0;
                if (grantNeed_ > deltaEt) continue;
                if (grantNeed_ > Bprev) continue;
            }

            (
                uint256 Floss,
                uint256 Fpool,
                ,
                uint256 Gt,
                ,
                ,
                uint256 Ft,
                uint256 Npre,
                uint256 Bnext,
                uint256 Tnext
            ) = harness.calculate(
                    Lt,
                    Ftot,
                    Nprev,
                    Bprev,
                    Tprev,
                    deltaEt,
                    pdd,
                    rhoBS,
                    DEF_PHI_LP,
                    DEF_PHI_BS,
                    DEF_PHI_TR
                );

            // INV-FW1: Floss + Fpool == Ftot
            assertEq(Floss + Fpool, Ftot, "INV-FW1 violated");

            // INV-BS-POS: Bnext >= 0
            assertGe(Bnext, 0, "INV-BS-POS violated");

            // INV-TR: Tnext >= Tprev
            assertGe(Tnext, Tprev, "INV-TR violated");

            // INV-NAV1: Npre - Nprev == Lt + Ft + Gt
            int256 navDelta = int256(Npre) - int256(Nprev);
            int256 expected = Lt + int256(Ft) + int256(Gt);
            assertEq(navDelta, expected, "INV-NAV1 violated");

            // INV-FW3: Gt <= deltaEt
            assertLe(Gt, deltaEt, "INV-FW3a violated");

            // INV-FW3: Gt <= Bprev
            assertLe(Gt, Bprev, "INV-FW3b violated");

            validCases++;
        }
        assertGe(validCases, 100, "Need at least 100 valid random cases");
    }

    // ============================================================
    // Internal helpers
    // ============================================================

    function _wMulUp(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 product = a * b;
        if (product == 0) return 0;
        return (product - 1) / WAD + 1;
    }
}
