// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/FeeWaterfallLibHarness.sol";
import {FeeWaterfallReference} from "../../../../contracts/testonly/FeeWaterfallReference.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title FeeWaterfallLibFuzzTest
/// @notice Foundry-native fuzz tests for FeeWaterfallLib invariants and reference parity.
/// @dev Complements the deterministic tests in FeeWaterfallLib.t.sol with random exploration.
contract FeeWaterfallLibFuzzTest is HarnessDeployer {
    FeeWaterfallLibHarness harness;

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

    function setUp() public override {
        super.setUp();
        harness = deployFeeWaterfallLibHarness();
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _calc(CalcInput memory c)
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
        return harness.calculate(
            c.Lt, c.Ftot, c.Nprev, c.Bprev, c.Tprev, c.deltaEt, c.pdd, c.rhoBS, c.phiLP, c.phiBS, c.phiTR
        );
    }

    function _wMulUp(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 product = a * b;
        if (product == 0) return 0;
        return (product - 1) / WAD + 1;
    }

    /// @dev Bound raw fuzz inputs to valid parameter ranges that won't trigger expected reverts.
    function _boundValidParams(
        uint256 rawNprev,
        uint256 rawBprev,
        uint256 rawTprev,
        uint256 rawFtot,
        uint256 rawDeltaEt,
        uint256 rawLt,
        bool ltNegative,
        uint256 rawPdd,
        uint256 rawRhoBS,
        uint256 rawPhiLP,
        uint256 rawPhiBS
    ) internal pure returns (CalcInput memory c) {
        c.Nprev = bound(rawNprev, 1e18, 1_000_000e18);
        c.Bprev = bound(rawBprev, 1e18, 500_000e18);
        c.Tprev = bound(rawTprev, 0, 100_000e18);
        c.Ftot = bound(rawFtot, 0, 100_000e18);
        c.deltaEt = bound(rawDeltaEt, 0, 100_000e18);

        // pdd in [-WAD, -0.01e18] (valid: strictly negative, >= -WAD)
        c.pdd = -int256(bound(rawPdd, 0.01e18, WAD));

        // rhoBS in [0, 0.5e18]
        c.rhoBS = bound(rawRhoBS, 0, 0.5e18);

        // Phi components: each >= 1%, sum == WAD
        c.phiLP = bound(rawPhiLP, 0.01e18, 0.98e18);
        c.phiBS = bound(rawPhiBS, 0.01e18, WAD - c.phiLP - 0.01e18);
        c.phiTR = WAD - c.phiLP - c.phiBS;

        // Lt: bound magnitude, then apply sign
        if (ltNegative) {
            // Negative Lt: bound to avoid catastrophic loss
            // |Lt| must be <= Nprev + Ftot to prevent CatastrophicLoss revert
            uint256 maxLoss = c.Nprev + c.Ftot;
            uint256 absLt = bound(rawLt, 0, maxLoss);
            c.Lt = -int256(absLt);
        } else {
            c.Lt = int256(bound(rawLt, 0, c.Nprev));
        }

        // Ensure grant constraints are satisfiable
        if (c.Lt < 0) {
            uint256 Lneg = uint256(-c.Lt);
            uint256 Floss_ = Lneg < c.Ftot ? Lneg : c.Ftot;
            uint256 Nraw_ = c.Nprev + Floss_ - Lneg;

            int256 wadPlusPdd = int256(WAD) + c.pdd;
            uint256 Nfloor_ = wadPlusPdd > 0 ? _wMulUp(c.Nprev, uint256(wadPlusPdd)) : 0;
            uint256 grantNeed_ = Nfloor_ > Nraw_ ? Nfloor_ - Nraw_ : 0;

            // Ensure deltaEt >= grantNeed
            if (grantNeed_ > c.deltaEt) {
                c.deltaEt = grantNeed_;
            }
            // Ensure Bprev >= grantNeed
            if (grantNeed_ > c.Bprev) {
                c.Bprev = grantNeed_;
            }
        }
    }

    // ============================================================
    // Positive fuzz tests
    // ============================================================

    /// @notice INV-FW1: Floss + Fpool == Ftot (fee conservation)
    function testFuzz_FW1_feeConservation(
        uint256 rawNprev,
        uint256 rawBprev,
        uint256 rawTprev,
        uint256 rawFtot,
        uint256 rawDeltaEt,
        uint256 rawLt,
        bool ltNeg,
        uint256 rawPdd,
        uint256 rawRhoBS,
        uint256 rawPhiLP,
        uint256 rawPhiBS
    ) public view {
        CalcInput memory c = _boundValidParams(
            rawNprev, rawBprev, rawTprev, rawFtot, rawDeltaEt, rawLt, ltNeg, rawPdd, rawRhoBS, rawPhiLP, rawPhiBS
        );
        (uint256 Floss, uint256 Fpool,,,,,,,,) = _calc(c);
        assertEq(Floss + Fpool, c.Ftot, "INV-FW1: Floss + Fpool != Ftot");
    }

    /// @notice INV-FW2: Loss compensation bound
    function testFuzz_FW2_lossCompBound(
        uint256 rawNprev,
        uint256 rawBprev,
        uint256 rawTprev,
        uint256 rawFtot,
        uint256 rawDeltaEt,
        uint256 rawLt,
        bool ltNeg,
        uint256 rawPdd,
        uint256 rawRhoBS,
        uint256 rawPhiLP,
        uint256 rawPhiBS
    ) public view {
        CalcInput memory c = _boundValidParams(
            rawNprev, rawBprev, rawTprev, rawFtot, rawDeltaEt, rawLt, ltNeg, rawPdd, rawRhoBS, rawPhiLP, rawPhiBS
        );
        (uint256 Floss,,,,,,,,,) = _calc(c);

        if (c.Lt >= 0) {
            assertEq(Floss, 0, "INV-FW2: Floss != 0 on profit");
        } else {
            uint256 absLt = uint256(-c.Lt);
            uint256 cap = absLt < c.Ftot ? absLt : c.Ftot;
            assertEq(Floss, cap, "INV-FW2: Floss != min(Ftot, |Lt|)");
        }
    }

    /// @notice INV-FW3: Grant bound (Gt <= deltaEt && Gt <= Bprev)
    function testFuzz_FW3_grantBound(
        uint256 rawNprev,
        uint256 rawBprev,
        uint256 rawTprev,
        uint256 rawFtot,
        uint256 rawDeltaEt,
        uint256 rawLt,
        bool ltNeg,
        uint256 rawPdd,
        uint256 rawRhoBS,
        uint256 rawPhiLP,
        uint256 rawPhiBS
    ) public view {
        CalcInput memory c = _boundValidParams(
            rawNprev, rawBprev, rawTprev, rawFtot, rawDeltaEt, rawLt, ltNeg, rawPdd, rawRhoBS, rawPhiLP, rawPhiBS
        );
        (,,, uint256 Gt,,,,,,) = _calc(c);
        assertLe(Gt, c.deltaEt, "INV-FW3: Gt > deltaEt");
        assertLe(Gt, c.Bprev, "INV-FW3: Gt > Bprev");
    }

    /// @notice INV-FW4: Grant calculation correctness
    function testFuzz_FW4_grantCalculation(
        uint256 rawNprev,
        uint256 rawBprev,
        uint256 rawTprev,
        uint256 rawFtot,
        uint256 rawDeltaEt,
        uint256 rawLt,
        bool ltNeg,
        uint256 rawPdd,
        uint256 rawRhoBS,
        uint256 rawPhiLP,
        uint256 rawPhiBS
    ) public view {
        CalcInput memory c = _boundValidParams(
            rawNprev, rawBprev, rawTprev, rawFtot, rawDeltaEt, rawLt, ltNeg, rawPdd, rawRhoBS, rawPhiLP, rawPhiBS
        );
        (,, uint256 Nraw, uint256 Gt,,,,,,) = _calc(c);

        // Recompute expected grant
        int256 wadPlusPdd = int256(WAD) + c.pdd;
        uint256 Nfloor = wadPlusPdd > 0 ? _wMulUp(c.Nprev, uint256(wadPlusPdd)) : 0;
        uint256 expectedGrant = Nfloor > Nraw ? Nfloor - Nraw : 0;

        assertEq(Gt, expectedGrant, "INV-FW4: Gt != max(0, Nfloor - Nraw)");
    }

    /// @notice INV-NAV1: Npre - Nprev == Lt + Ft + Gt
    function testFuzz_NAV1_navEquation(
        uint256 rawNprev,
        uint256 rawBprev,
        uint256 rawTprev,
        uint256 rawFtot,
        uint256 rawDeltaEt,
        uint256 rawLt,
        bool ltNeg,
        uint256 rawPdd,
        uint256 rawRhoBS,
        uint256 rawPhiLP,
        uint256 rawPhiBS
    ) public view {
        CalcInput memory c = _boundValidParams(
            rawNprev, rawBprev, rawTprev, rawFtot, rawDeltaEt, rawLt, ltNeg, rawPdd, rawRhoBS, rawPhiLP, rawPhiBS
        );
        (,,, uint256 Gt,,, uint256 Ft, uint256 Npre,,) = _calc(c);

        int256 navDelta = int256(Npre) - int256(c.Nprev);
        int256 expected = c.Lt + int256(Ft) + int256(Gt);
        assertEq(navDelta, expected, "INV-NAV1: NAV equation violated");
    }

    /// @notice INV-BS-POS: Backstop non-negative (trivially true for uint256, but verifies no revert)
    function testFuzz_backstopNonNegative(
        uint256 rawNprev,
        uint256 rawBprev,
        uint256 rawTprev,
        uint256 rawFtot,
        uint256 rawDeltaEt,
        uint256 rawLt,
        bool ltNeg,
        uint256 rawPdd,
        uint256 rawRhoBS,
        uint256 rawPhiLP,
        uint256 rawPhiBS
    ) public view {
        CalcInput memory c = _boundValidParams(
            rawNprev, rawBprev, rawTprev, rawFtot, rawDeltaEt, rawLt, ltNeg, rawPdd, rawRhoBS, rawPhiLP, rawPhiBS
        );
        (,,,,,,,, uint256 Bnext,) = _calc(c);
        assertGe(Bnext, 0, "INV-BS-POS: Bnext < 0");
    }

    /// @notice INV-TR: Treasury non-decreasing
    function testFuzz_treasuryNonDecreasing(
        uint256 rawNprev,
        uint256 rawBprev,
        uint256 rawTprev,
        uint256 rawFtot,
        uint256 rawDeltaEt,
        uint256 rawLt,
        bool ltNeg,
        uint256 rawPdd,
        uint256 rawRhoBS,
        uint256 rawPhiLP,
        uint256 rawPhiBS
    ) public view {
        CalcInput memory c = _boundValidParams(
            rawNprev, rawBprev, rawTprev, rawFtot, rawDeltaEt, rawLt, ltNeg, rawPdd, rawRhoBS, rawPhiLP, rawPhiBS
        );
        (,,,,,,,,, uint256 Tnext) = _calc(c);
        assertGe(Tnext, c.Tprev, "INV-TR: Tnext < Tprev");
    }

    /// @notice Cross-implementation parity: FeeWaterfallLib == FeeWaterfallReference
    function testFuzz_referenceParity(
        uint256 rawNprev,
        uint256 rawBprev,
        uint256 rawTprev,
        uint256 rawFtot,
        uint256 rawDeltaEt,
        uint256 rawLt,
        bool ltNeg,
        uint256 rawPdd,
        uint256 rawRhoBS,
        uint256 rawPhiLP,
        uint256 rawPhiBS
    ) public view {
        CalcInput memory c = _boundValidParams(
            rawNprev, rawBprev, rawTprev, rawFtot, rawDeltaEt, rawLt, ltNeg, rawPdd, rawRhoBS, rawPhiLP, rawPhiBS
        );

        (uint256 Floss, uint256 Fpool,, uint256 Gt,,, uint256 Ft, uint256 Npre, uint256 Bnext, uint256 Tnext) = _calc(c);

        FeeWaterfallReference.Params memory rp = FeeWaterfallReference.Params({
            Lt: c.Lt,
            Ftot: c.Ftot,
            Nprev: c.Nprev,
            Bprev: c.Bprev,
            Tprev: c.Tprev,
            deltaEt: c.deltaEt,
            pdd: c.pdd,
            rhoBS: c.rhoBS,
            phiLP: c.phiLP,
            phiBS: c.phiBS,
            phiTR: c.phiTR
        });
        FeeWaterfallReference.Result memory ref = FeeWaterfallReference.calculate(rp);

        assertEq(Floss, ref.Floss, "Parity: Floss mismatch");
        assertEq(Fpool, ref.Fpool, "Parity: Fpool mismatch");
        assertEq(Gt, ref.Gt, "Parity: Gt mismatch");
        assertEq(Ft, ref.Ft, "Parity: Ft mismatch");
        assertEq(Npre, ref.Npre, "Parity: Npre mismatch");
        assertEq(Bnext, ref.Bnext, "Parity: Bnext mismatch");
        assertEq(Tnext, ref.Tnext, "Parity: Tnext mismatch");
    }

    // ============================================================
    // Negative fuzz tests (revert verification)
    // ============================================================

    /// @notice InvalidDrawdownFloor for pdd >= 0
    function testFuzz_revert_invalidPddPositive(uint256 rawPdd) public {
        int256 pdd = int256(bound(rawPdd, 0, uint256(type(int256).max)));

        vm.expectRevert(abi.encodeWithSelector(SE.InvalidDrawdownFloor.selector, pdd));
        harness.calculate(0, 100e18, 1000e18, 200e18, 50e18, 100e18, pdd, 0.2e18, 0.7e18, 0.2e18, 0.1e18);
    }

    /// @notice InvalidDrawdownFloor for pdd < -WAD (strictly)
    function testFuzz_revert_invalidPddTooNegative(uint256 rawPdd) public {
        int256 pdd = -int256(bound(rawPdd, WAD + 1, 10 * WAD));

        vm.expectRevert(abi.encodeWithSelector(SE.InvalidDrawdownFloor.selector, pdd));
        harness.calculate(0, 100e18, 1000e18, 200e18, 50e18, 100e18, pdd, 0.2e18, 0.7e18, 0.2e18, 0.1e18);
    }

    /// @notice InvalidPhiSum when phiLP + phiBS + phiTR != WAD
    function testFuzz_revert_invalidPhiSum(uint256 rawPhiLP, uint256 rawPhiBS, uint256 rawPhiTR) public {
        uint256 phiLP = bound(rawPhiLP, 0.01e18, 0.98e18);
        uint256 phiBS = bound(rawPhiBS, 0.01e18, 0.98e18);
        uint256 phiTR = bound(rawPhiTR, 0.01e18, 0.98e18);

        uint256 phiSum = phiLP + phiBS + phiTR;
        vm.assume(phiSum != WAD);

        vm.expectRevert(abi.encodeWithSelector(SE.InvalidPhiSum.selector, phiSum));
        harness.calculate(0, 100e18, 1000e18, 200e18, 50e18, 100e18, -0.3e18, 0.2e18, phiLP, phiBS, phiTR);
    }

    /// @notice CatastrophicLoss when |Lt| > Nprev + Ftot
    function testFuzz_revert_catastrophicLoss(uint256 rawNprev, uint256 rawFtot, uint256 rawLt) public {
        uint256 Nprev = bound(rawNprev, 1e18, 1_000_000e18);
        uint256 Ftot = bound(rawFtot, 0, 100_000e18);

        // Ensure |Lt| > Nprev + Ftot (catastrophic)
        uint256 absLt = bound(rawLt, Nprev + Ftot + 1, Nprev + Ftot + 1_000_000e18);
        int256 Lt = -int256(absLt);

        // Floss = min(Ftot, absLt) = Ftot (since absLt > Nprev + Ftot > Ftot)
        uint256 navPlusFloss = Nprev + Ftot;

        vm.expectRevert(abi.encodeWithSelector(SE.CatastrophicLoss.selector, absLt, navPlusFloss));
        harness.calculate(Lt, Ftot, Nprev, 500_000e18, 50e18, 500_000e18, -0.3e18, 0.2e18, 0.7e18, 0.2e18, 0.1e18);
    }
}
