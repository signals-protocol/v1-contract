// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/RiskMathHarness.sol";
import {FixedPointMathU} from "../../../../contracts/lib/FixedPointMathU.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

contract RiskMathFuzzTest is HarnessDeployer {
    using FixedPointMathU for uint256;

    RiskMathHarness h;

    function setUp() public override {
        super.setUp();
        h = deployRiskMathHarness();
    }

    // ============================================================
    // calculateAlphaBase
    // ============================================================

    function testFuzz_alphaBase_positive(uint256 etSeed, uint256 nbSeed, uint256 lamSeed) public view {
        uint256 Et = bound(etSeed, WAD, 1e30);
        uint256 numBins = bound(nbSeed, 2, 200);
        uint256 lambda = bound(lamSeed, 0.01e18, WAD);
        uint256 alphaBase = h.calculateAlphaBase(Et, numBins, lambda);
        assertGt(alphaBase, 0);
    }

    function testFuzz_alphaBase_proportionalToEt(uint256 et1Seed, uint256 et2Seed, uint256 nbSeed, uint256 lamSeed)
        public
        view
    {
        uint256 numBins = bound(nbSeed, 2, 200);
        uint256 lambda = bound(lamSeed, 0.01e18, WAD);
        uint256 Et1 = bound(et1Seed, WAD, 1e27);
        // Ensure meaningful gap to avoid wMul rounding equality
        uint256 Et2 = bound(et2Seed, Et1 * 2, 1e30);
        uint256 ab1 = h.calculateAlphaBase(Et1, numBins, lambda);
        uint256 ab2 = h.calculateAlphaBase(Et2, numBins, lambda);
        assertGt(ab2, ab1);
    }

    function testFuzz_alphaBase_proportionalToLambda(uint256 etSeed, uint256 nbSeed, uint256 l1Seed, uint256 l2Seed)
        public
        view
    {
        uint256 Et = bound(etSeed, WAD, 1e30);
        uint256 numBins = bound(nbSeed, 2, 200);
        uint256 lambda1 = bound(l1Seed, 0.01e18, WAD / 4);
        // Ensure meaningful gap to avoid wMul rounding equality
        uint256 lambda2 = bound(l2Seed, lambda1 * 2, WAD);
        uint256 ab1 = h.calculateAlphaBase(Et, numBins, lambda1);
        uint256 ab2 = h.calculateAlphaBase(Et, numBins, lambda2);
        assertGt(ab2, ab1);
    }

    function testFuzz_alphaBase_inverseToNumBins(uint256 etSeed, uint256 n1Seed, uint256 n2Seed, uint256 lamSeed)
        public
        view
    {
        uint256 Et = bound(etSeed, WAD, 1e30);
        uint256 lambda = bound(lamSeed, 0.01e18, WAD);
        uint256 n1 = bound(n1Seed, 2, 100);
        uint256 n2 = bound(n2Seed, n1 + 1, 200);
        uint256 ab1 = h.calculateAlphaBase(Et, n1, lambda);
        uint256 ab2 = h.calculateAlphaBase(Et, n2, lambda);
        assertLt(ab2, ab1);
    }

    function testFuzz_alphaBase_revertsNumBinsLe1(uint256 etSeed, uint256 lamSeed) public {
        uint256 Et = bound(etSeed, WAD, 1e30);
        uint256 lambda = bound(lamSeed, 0.01e18, WAD);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidNumBins.selector, 0));
        h.calculateAlphaBase(Et, 0, lambda);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidNumBins.selector, 1));
        h.calculateAlphaBase(Et, 1, lambda);
    }

    // ============================================================
    // calculateAlphaLimit
    // ============================================================

    function testFuzz_alphaLimit_equalsBaseAtZeroDrawdown(uint256 abSeed, uint256 kSeed) public view {
        uint256 alphaBase = bound(abSeed, WAD, 1e24);
        uint256 k = bound(kSeed, 0.1e18, 5e18);
        uint256 alphaLimit = h.calculateAlphaLimit(alphaBase, 0, k);
        assertEq(alphaLimit, alphaBase);
    }

    function testFuzz_alphaLimit_zeroWhenKddGeWad(uint256 abSeed, uint256 kSeed, uint256 ddSeed) public view {
        uint256 alphaBase = bound(abSeed, WAD, 1e24);
        uint256 k = bound(kSeed, WAD, 5e18);
        // Ceiling division: minDD such that k * minDD / WAD >= WAD
        uint256 minDD = (WAD * WAD + k - 1) / k;
        if (minDD > WAD) minDD = WAD;
        uint256 drawdown = bound(ddSeed, minDD, WAD);
        uint256 alphaLimit = h.calculateAlphaLimit(alphaBase, drawdown, k);
        assertEq(alphaLimit, 0);
    }

    function testFuzz_alphaLimit_monotonicallyDecreasing(
        uint256 abSeed,
        uint256 kSeed,
        uint256 dd1Seed,
        uint256 dd2Seed
    ) public view {
        uint256 alphaBase = bound(abSeed, WAD, 1e24);
        uint256 k = bound(kSeed, 0.1e18, 5e18);
        uint256 dd1 = bound(dd1Seed, 0, WAD / 2);
        uint256 dd2 = bound(dd2Seed, dd1 + 1, WAD);
        uint256 al1 = h.calculateAlphaLimit(alphaBase, dd1, k);
        uint256 al2 = h.calculateAlphaLimit(alphaBase, dd2, k);
        assertLe(al2, al1);
    }

    function testFuzz_alphaLimit_leBase(uint256 abSeed, uint256 ddSeed, uint256 kSeed) public view {
        uint256 alphaBase = bound(abSeed, WAD, 1e24);
        uint256 drawdown = bound(ddSeed, 0, WAD);
        uint256 k = bound(kSeed, 0.1e18, 5e18);
        uint256 alphaLimit = h.calculateAlphaLimit(alphaBase, drawdown, k);
        assertLe(alphaLimit, alphaBase);
    }

    function testFuzz_alphaLimit_formula(uint256 abSeed, uint256 ddSeed, uint256 kSeed) public view {
        uint256 alphaBase = bound(abSeed, WAD, 1e24);
        uint256 drawdown = bound(ddSeed, 0, WAD);
        uint256 k = bound(kSeed, 0.1e18, 5e18);
        uint256 alphaLimit = h.calculateAlphaLimit(alphaBase, drawdown, k);
        // Manual calculation
        uint256 kDD = k.wMul(drawdown);
        uint256 expected;
        if (kDD >= WAD) {
            expected = 0;
        } else {
            expected = alphaBase.wMul(WAD - kDD);
        }
        assertApproxEqAbs(alphaLimit, expected, 1);
    }

    // ============================================================
    // calculateDrawdown
    // ============================================================

    function testFuzz_drawdown_zeroWhenPriceGePeak(uint256 priceSeed, uint256 peakSeed) public view {
        uint256 pricePeak = bound(peakSeed, 1, 1e30);
        uint256 price = bound(priceSeed, pricePeak, type(uint128).max);
        uint256 dd = h.calculateDrawdown(price, pricePeak);
        assertEq(dd, 0);
    }

    function testFuzz_drawdown_zeroWhenPeakZero(uint256 priceSeed) public view {
        uint256 price = bound(priceSeed, 0, 1e30);
        uint256 dd = h.calculateDrawdown(price, 0);
        assertEq(dd, 0);
    }

    function testFuzz_drawdown_positiveWhenBelow(uint256 peakSeed, uint256 priceSeed) public view {
        uint256 pricePeak = bound(peakSeed, 2, 1e30);
        // Ensure price is large enough that price.wDiv(pricePeak) > 0, so DD < WAD
        uint256 minPrice = pricePeak / WAD + 1;
        if (minPrice >= pricePeak) return; // skip degenerate cases
        uint256 price = bound(priceSeed, minPrice, pricePeak - 1);
        uint256 dd = h.calculateDrawdown(price, pricePeak);
        assertGt(dd, 0);
        assertLt(dd, WAD);
    }

    function testFuzz_drawdown_boundedByWad(uint256 priceSeed, uint256 peakSeed) public view {
        uint256 price = bound(priceSeed, 1, 1e30);
        uint256 pricePeak = bound(peakSeed, 1, 1e30);
        uint256 dd = h.calculateDrawdown(price, pricePeak);
        assertLe(dd, WAD);
    }

    function testFuzz_drawdown_formula(uint256 peakSeed, uint256 priceSeed) public view {
        uint256 pricePeak = bound(peakSeed, 2, 1e30);
        uint256 price = bound(priceSeed, 1, pricePeak - 1);
        uint256 dd = h.calculateDrawdown(price, pricePeak);
        uint256 expected = WAD - price.wDiv(pricePeak);
        assertEq(dd, expected);
    }

    // ============================================================
    // calculateDeltaEt
    // ============================================================

    function testFuzz_deltaEt_zeroForUniform(uint256 alphaSeed, uint256 nbSeed, uint256 mfSeed) public view {
        uint256 alpha = bound(alphaSeed, WAD, 100e18);
        uint32 numBins = uint32(bound(nbSeed, 2, 100));
        uint256 minFactor = bound(mfSeed, WAD, type(uint256).max / numBins);
        uint256 rootSum = uint256(numBins) * minFactor;
        uint256 deltaEt = h.calculateDeltaEt(alpha, numBins, rootSum, minFactor);
        assertEq(deltaEt, 0);
    }

    function testFuzz_deltaEt_positiveForConcentrated(
        uint256 alphaSeed,
        uint256 nbSeed,
        uint256 mfSeed,
        uint256 extraSeed
    ) public view {
        uint256 alpha = bound(alphaSeed, WAD, 100e18);
        uint32 numBins = uint32(bound(nbSeed, 2, 100));
        uint256 minFactor = bound(mfSeed, WAD, 1e24);
        uint256 uniformSum = uint256(numBins) * minFactor;
        uint256 extra = bound(extraSeed, 1e16, uniformSum);
        uint256 rootSum = uniformSum + extra;
        uint256 deltaEt = h.calculateDeltaEt(alpha, numBins, rootSum, minFactor);
        assertGt(deltaEt, 0);
    }

    function testFuzz_deltaEt_monotonic(
        uint256 alphaSeed,
        uint256 nbSeed,
        uint256 mfSeed,
        uint256 rs1Seed,
        uint256 rs2Seed
    ) public view {
        uint256 alpha = bound(alphaSeed, WAD, 100e18);
        uint32 numBins = uint32(bound(nbSeed, 2, 50));
        uint256 minFactor = bound(mfSeed, WAD, 1e22);
        uint256 uniformSum = uint256(numBins) * minFactor;
        uint256 rs1 = bound(rs1Seed, uniformSum + 1e16, uniformSum * 2);
        uint256 rs2 = bound(rs2Seed, rs1 + 1, uniformSum * 3);
        uint256 d1 = h.calculateDeltaEt(alpha, numBins, rs1, minFactor);
        uint256 d2 = h.calculateDeltaEt(alpha, numBins, rs2, minFactor);
        assertGe(d2, d1);
    }

    function testFuzz_deltaEt_scalingWithAlpha(
        uint256 a1Seed,
        uint256 a2Seed,
        uint256 nbSeed,
        uint256 mfSeed,
        uint256 rsSeed
    ) public view {
        uint32 numBins = uint32(bound(nbSeed, 2, 50));
        uint256 minFactor = bound(mfSeed, WAD, 1e22);
        uint256 uniformSum = uint256(numBins) * minFactor;
        uint256 rootSum = bound(rsSeed, uniformSum + 1e16, uniformSum * 2);
        uint256 alpha1 = bound(a1Seed, WAD, 25e18);
        // Ensure meaningful gap to avoid wMulUp rounding equality
        uint256 alpha2 = bound(a2Seed, alpha1 * 2, 100e18);
        uint256 d1 = h.calculateDeltaEt(alpha1, numBins, rootSum, minFactor);
        uint256 d2 = h.calculateDeltaEt(alpha2, numBins, rootSum, minFactor);
        assertGt(d2, d1);
    }

    // ============================================================
    // calculateDeltaEtFromFactors
    // ============================================================

    function testFuzz_deltaEtFromFactors_uniformZero(uint256 alphaSeed, uint256 fSeed) public view {
        uint256 alpha = bound(alphaSeed, WAD, 100e18);
        uint256 factorVal = bound(fSeed, WAD, 5e18);
        uint256[] memory factors = new uint256[](4);
        factors[0] = factorVal;
        factors[1] = factorVal;
        factors[2] = factorVal;
        factors[3] = factorVal;
        uint256 deltaEt = h.calculateDeltaEtFromFactors(alpha, 4, factors);
        assertEq(deltaEt, 0);
    }

    function testFuzz_deltaEtFromFactors_matchesDeltaEt(uint256 alphaSeed, uint256 seed) public view {
        uint256 alpha = bound(alphaSeed, WAD, 100e18);
        uint256[] memory factors = new uint256[](4);
        uint256 rootSum = 0;
        uint256 minFactor = type(uint256).max;
        for (uint256 i = 0; i < 4; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            factors[i] = bound(seed, 0.5e18, 5e18);
            rootSum += factors[i];
            if (factors[i] < minFactor) minFactor = factors[i];
        }
        uint256 fromFactors = h.calculateDeltaEtFromFactors(alpha, 4, factors);
        uint256 fromPrecomputed = h.calculateDeltaEt(alpha, 4, rootSum, minFactor);
        assertEq(fromFactors, fromPrecomputed);
    }

    function testFuzz_deltaEtFromFactors_zeroOnEdgeCases(uint256 alphaSeed) public view {
        uint256 alpha = bound(alphaSeed, WAD, 100e18);

        // Zero factor in array -> returns 0
        uint256[] memory zeroFactors = new uint256[](4);
        zeroFactors[0] = WAD;
        zeroFactors[1] = 0;
        zeroFactors[2] = WAD;
        zeroFactors[3] = WAD;
        assertEq(h.calculateDeltaEtFromFactors(alpha, 4, zeroFactors), 0);

        // numBins=0 -> returns 0
        uint256[] memory factors = new uint256[](4);
        factors[0] = WAD;
        factors[1] = WAD;
        factors[2] = WAD;
        factors[3] = WAD;
        assertEq(h.calculateDeltaEtFromFactors(alpha, 0, factors), 0);

        // Length mismatch -> returns 0
        assertEq(h.calculateDeltaEtFromFactors(alpha, 3, factors), 0);
    }

    // ============================================================
    // Enforcement functions
    // ============================================================

    function testFuzz_enforcePrior_noRevertWhenLe(uint256 dSeed, uint256 bSeed) public view {
        uint256 deltaEt = bound(dSeed, 0, 1e30);
        uint256 backstop = bound(bSeed, deltaEt, type(uint128).max);
        // Should not revert
        h.enforcePriorAdmissibility(deltaEt, backstop);
    }

    function testFuzz_enforcePrior_revertsWhenGt(uint256 dSeed, uint256 bSeed) public {
        uint256 backstop = bound(bSeed, 0, 1e30);
        uint256 deltaEt = bound(dSeed, backstop + 1, 1e30 + 1);
        vm.expectRevert(abi.encodeWithSelector(SE.PriorNotAdmissible.selector, deltaEt, backstop));
        h.enforcePriorAdmissibility(deltaEt, backstop);
    }

    function testFuzz_enforceAlpha_noRevertWhenLe(uint256 aSeed, uint256 lSeed) public view {
        uint256 alpha = bound(aSeed, 0, 1e30);
        uint256 limit = bound(lSeed, alpha, type(uint128).max);
        // Should not revert
        h.enforceAlphaLimit(alpha, limit);
    }

    function testFuzz_enforceAlpha_revertsWhenGt(uint256 aSeed, uint256 lSeed) public {
        uint256 limit = bound(lSeed, 0, 1e30);
        uint256 alpha = bound(aSeed, limit + 1, 1e30 + 1);
        vm.expectRevert(abi.encodeWithSelector(SE.AlphaExceedsLimit.selector, alpha, limit));
        h.enforceAlphaLimit(alpha, limit);
    }

    // ============================================================
    // lnWadUp + Pipeline
    // ============================================================

    function testFuzz_lnWadUp_monotonic(uint256 n1Seed, uint256 n2Seed) public view {
        uint256 n1 = bound(n1Seed, 2, 500);
        uint256 n2 = bound(n2Seed, n1 + 1, 1000);
        assertGt(h.lnWadUp(n2), h.lnWadUp(n1));
    }

    function testFuzz_lnWadUp_geActualLn(uint256 nSeed) public view {
        uint256 n = bound(nSeed, 2, 1000);
        uint256 lnUp = h.lnWadUp(n);
        // wLn(n * WAD) is the "actual" ln
        uint256 lnActual = (n * WAD).wLn();
        assertGe(lnUp, lnActual);
    }

    function testFuzz_pipeline_alphaLimitLeBase(
        uint256 etSeed,
        uint256 nbSeed,
        uint256 lamSeed,
        uint256 priceSeed,
        uint256 peakSeed,
        uint256 kSeed
    ) public view {
        uint256 Et = bound(etSeed, WAD, 1e30);
        uint256 numBins = bound(nbSeed, 2, 200);
        uint256 lambda = bound(lamSeed, 0.01e18, WAD);
        uint256 k = bound(kSeed, 0.1e18, 5e18);

        uint256 alphaBase = h.calculateAlphaBase(Et, numBins, lambda);

        uint256 pricePeak = bound(peakSeed, 1, 1e30);
        uint256 price = bound(priceSeed, 1, 1e30);
        uint256 drawdown = h.calculateDrawdown(price, pricePeak);

        uint256 alphaLimit = h.calculateAlphaLimit(alphaBase, drawdown, k);
        assertLe(alphaLimit, alphaBase);
    }
}
