// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/ClmsrMathHarness.sol";
import {FixedPointMathU} from "../../../../contracts/lib/FixedPointMathU.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

contract ClmsrMathFuzzTest is HarnessDeployer {
    ClmsrMathHarness h;

    uint256 constant MAX_EXP_INPUT = FixedPointMathU.MAX_EXP_INPUT_WAD;
    uint256 constant E_WAD = 2_718281828459045235;

    function setUp() public override {
        super.setUp();
        h = deployClmsrMathHarness();
    }

    // ============================================================
    // Pure function helpers
    // ============================================================

    function _boundAlpha(uint256 seed) private pure returns (uint256) {
        return bound(seed, 1e15, 1000e18);
    }

    function _factorsFromSeed(uint256 seed, uint32 bins) private pure returns (uint256[] memory f) {
        f = new uint256[](bins);
        for (uint32 i = 0; i < bins; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            f[i] = bound(seed, 0.5e18, 5e18);
        }
    }

    // ============================================================
    // safeExp fuzz tests
    // ============================================================

    function testFuzz_safeExp_identityAtZero(uint256 alphaSeed) public view {
        uint256 alpha = _boundAlpha(alphaSeed);
        uint256 result = h.exposedSafeExp(0, alpha);
        assertEq(result, WAD);
    }

    function testFuzz_safeExp_geWad(uint256 alphaSeed, uint256 numSeed) public view {
        uint256 alpha = _boundAlpha(alphaSeed);
        uint256 maxNumerator = (alpha * MAX_EXP_INPUT) / WAD;
        uint256 numerator = bound(numSeed, 0, maxNumerator);
        uint256 result = h.exposedSafeExp(numerator, alpha);
        assertGe(result, WAD);
    }

    function testFuzz_safeExp_monotonic(uint256 alphaSeed, uint256 aSeed, uint256 bSeed) public view {
        uint256 alpha = _boundAlpha(alphaSeed);
        uint256 maxNumerator = (alpha * MAX_EXP_INPUT) / WAD;
        uint256 a = bound(aSeed, 0, maxNumerator - 1);
        uint256 b = bound(bSeed, a + 1, maxNumerator);
        assertLe(h.exposedSafeExp(a, alpha), h.exposedSafeExp(b, alpha));
    }

    function testFuzz_safeExp_revertsOnZeroAlpha(uint256 numSeed) public {
        uint256 numerator = bound(numSeed, 1, 1e30);
        vm.expectRevert(SE.InvalidLiquidityParameter.selector);
        h.exposedSafeExp(numerator, 0);
    }

    function testFuzz_safeExp_revertsOnOverflow(uint256 alphaSeed) public {
        uint256 alpha = _boundAlpha(alphaSeed);
        uint256 overflowInput = (alpha * (MAX_EXP_INPUT + WAD)) / WAD;
        vm.expectRevert(SE.FP_Overflow.selector);
        h.exposedSafeExp(overflowInput, alpha);
    }

    // ============================================================
    // maxSafeChunkQuantity fuzz tests
    // ============================================================

    function testFuzz_maxSafeChunk_proportionalToAlpha(uint256 alphaSeed, uint256 kSeed) public view {
        uint256 alpha = bound(alphaSeed, 1e15, 100e18);
        uint256 k = bound(kSeed, 2, 10);
        uint256 maxSafe1 = h.maxSafeChunkQuantity(alpha);
        uint256 maxSafeK = h.maxSafeChunkQuantity(alpha * k);
        // k*maxSafe(alpha) approx maxSafe(k*alpha), within 0.1%
        assertApproxEqRel(maxSafeK, maxSafe1 * k, 0.001e18);
    }

    // ============================================================
    // computeBuyCostFromSumChange fuzz tests
    // ============================================================

    function testFuzz_buyCost_zeroWhenEqual(uint256 alphaSeed, uint256 sumSeed) public view {
        uint256 alpha = _boundAlpha(alphaSeed);
        uint256 s = bound(sumSeed, WAD, 1e30);
        assertEq(h.computeBuyCostFromSumChange(alpha, s, s), 0);
    }

    function testFuzz_buyCost_positive(uint256 alphaSeed, uint256 sumSeed, uint256 deltaSeed) public view {
        uint256 alpha = _boundAlpha(alphaSeed);
        uint256 sumBefore = bound(sumSeed, WAD, 1e30);
        uint256 delta = bound(deltaSeed, 1e16, sumBefore);
        uint256 cost = h.computeBuyCostFromSumChange(alpha, sumBefore, sumBefore + delta);
        assertGt(cost, 0);
    }

    function testFuzz_buyCost_monotonic(uint256 alphaSeed, uint256 sumSeed, uint256 d1Seed, uint256 d2Seed)
        public
        view
    {
        uint256 alpha = _boundAlpha(alphaSeed);
        uint256 sumBefore = bound(sumSeed, WAD, 1e28);
        uint256 d1 = bound(d1Seed, 1e16, sumBefore);
        uint256 d2 = bound(d2Seed, d1 + 1, sumBefore * 2);
        uint256 cost1 = h.computeBuyCostFromSumChange(alpha, sumBefore, sumBefore + d1);
        uint256 cost2 = h.computeBuyCostFromSumChange(alpha, sumBefore, sumBefore + d2);
        assertLe(cost1, cost2);
    }

    function testFuzz_buyCost_scalingWithAlpha(uint256 a1Seed, uint256 a2Seed, uint256 sumSeed, uint256 deltaSeed)
        public
        view
    {
        uint256 alpha1 = bound(a1Seed, 1e15, 500e18);
        uint256 alpha2 = bound(a2Seed, alpha1 + 1, 1000e18);
        uint256 sumBefore = bound(sumSeed, WAD, 1e28);
        uint256 delta = bound(deltaSeed, 1e16, sumBefore);
        uint256 cost1 = h.computeBuyCostFromSumChange(alpha1, sumBefore, sumBefore + delta);
        uint256 cost2 = h.computeBuyCostFromSumChange(alpha2, sumBefore, sumBefore + delta);
        assertLe(cost1, cost2);
    }

    // ============================================================
    // computeSellProceedsFromSumChange fuzz tests
    // ============================================================

    function testFuzz_sellProceeds_zeroWhenEqual(uint256 alphaSeed, uint256 sumSeed) public view {
        uint256 alpha = _boundAlpha(alphaSeed);
        uint256 s = bound(sumSeed, WAD, 1e30);
        assertEq(h.computeSellProceedsFromSumChange(alpha, s, s), 0);
        // Also zero when sumAfter > sumBefore
        assertEq(h.computeSellProceedsFromSumChange(alpha, s, s + 1), 0);
    }

    function testFuzz_sellProceeds_positive(uint256 alphaSeed, uint256 sumSeed, uint256 deltaSeed) public view {
        uint256 alpha = _boundAlpha(alphaSeed);
        uint256 sumBefore = bound(sumSeed, 2 * WAD, 1e30);
        uint256 delta = bound(deltaSeed, 1e16, sumBefore - WAD);
        uint256 proceeds = h.computeSellProceedsFromSumChange(alpha, sumBefore, sumBefore - delta);
        assertGt(proceeds, 0);
    }

    function testFuzz_sellProceeds_monotonic(uint256 alphaSeed, uint256 sumSeed, uint256 d1Seed, uint256 d2Seed)
        public
        view
    {
        uint256 alpha = _boundAlpha(alphaSeed);
        uint256 sumBefore = bound(sumSeed, 3 * WAD, 1e28);
        uint256 d1 = bound(d1Seed, 1e16, sumBefore / 2);
        uint256 d2 = bound(d2Seed, d1 + 1, sumBefore - WAD);
        uint256 p1 = h.computeSellProceedsFromSumChange(alpha, sumBefore, sumBefore - d1);
        uint256 p2 = h.computeSellProceedsFromSumChange(alpha, sumBefore, sumBefore - d2);
        assertLe(p1, p2);
    }

    // ============================================================
    // buyCost >= sellProceeds (protocol-favored rounding)
    // ============================================================

    function testFuzz_buySell_protocolFavored(uint256 alphaSeed, uint256 sumSeed, uint256 deltaSeed) public view {
        uint256 alpha = _boundAlpha(alphaSeed);
        uint256 sumBefore = bound(sumSeed, 2 * WAD, 1e28);
        uint256 delta = bound(deltaSeed, 1e16, sumBefore / 2);
        uint256 sumAfter = sumBefore + delta;
        uint256 buyCost = h.computeBuyCostFromSumChange(alpha, sumBefore, sumAfter);
        uint256 sellProceeds = h.computeSellProceedsFromSumChange(alpha, sumAfter, sumBefore);
        assertGe(buyCost, sellProceeds);
    }

    // ============================================================
    // buyCost ln identity: cost(alpha, S, e*S) ≈ alpha
    // ============================================================

    function testFuzz_buyCost_lnIdentity(uint256 alphaSeed, uint256 sumSeed) public view {
        uint256 alpha = _boundAlpha(alphaSeed);
        uint256 s = bound(sumSeed, WAD, 1e26);
        // e * S (using E_WAD)
        uint256 sumAfter = (s * E_WAD) / WAD;
        if (sumAfter <= s) return; // overflow guard
        uint256 cost = h.computeBuyCostFromSumChange(alpha, s, sumAfter);
        // cost ≈ alpha within 0.1%
        assertApproxEqRel(cost, alpha, 0.001e18);
    }

    // ============================================================
    // Tree-based fuzz tests
    // ============================================================

    function testFuzz_quoteBuy_positive(uint256 seed, uint256 alphaSeed, uint256 qSeed) public {
        uint256 alpha = bound(alphaSeed, 0.1e18, 50e18);
        uint256[] memory f = _factorsFromSeed(seed, 4);
        h.seed(f);
        uint256 maxSafe = h.maxSafeChunkQuantity(alpha);
        uint256 q = bound(qSeed, 1e15, maxSafe);
        uint256 cost = h.quoteBuy(alpha, 0, 1, q);
        assertGt(cost, 0);
    }

    function testFuzz_quoteBuy_monotonic(uint256 seed, uint256 alphaSeed, uint256 q1Seed, uint256 q2Seed) public {
        uint256 alpha = bound(alphaSeed, 0.1e18, 50e18);
        uint256[] memory f = _factorsFromSeed(seed, 4);
        h.seed(f);
        uint256 maxSafe = h.maxSafeChunkQuantity(alpha);
        uint256 q1 = bound(q1Seed, 1e15, maxSafe / 2);
        uint256 q2 = bound(q2Seed, q1 + 1, maxSafe);
        uint256 cost1 = h.quoteBuy(alpha, 0, 1, q1);
        uint256 cost2 = h.quoteBuy(alpha, 0, 1, q2);
        assertLe(cost1, cost2);
    }

    function testFuzz_quoteSell_positive(uint256 seed, uint256 alphaSeed, uint256 qSeed) public {
        uint256 alpha = bound(alphaSeed, 0.1e18, 50e18);
        // Concentrated tree: factors > WAD in bins 0-1
        uint256[] memory f = _factorsFromSeed(seed, 4);
        // Ensure bins 0-1 are large enough for meaningful sell
        f[0] = bound(f[0], 2e18, 5e18);
        f[1] = bound(f[1], 2e18, 5e18);
        h.seed(f);
        uint256 maxSafe = h.maxSafeChunkQuantity(alpha);
        uint256 q = bound(qSeed, 1e15, maxSafe / 2);
        uint256 proceeds = h.quoteSell(alpha, 0, 1, q);
        assertGt(proceeds, 0);
    }

    function testFuzz_quoteBuySell_noArbitrage(uint256 seed, uint256 alphaSeed, uint256 qSeed) public {
        uint256 alpha = bound(alphaSeed, 0.1e18, 50e18);
        uint256[] memory f = _factorsFromSeed(seed, 4);
        // Ensure enough concentration for sell
        f[0] = bound(f[0], 2e18, 5e18);
        f[1] = bound(f[1], 2e18, 5e18);
        h.seed(f);
        uint256 maxSafe = h.maxSafeChunkQuantity(alpha);
        uint256 q = bound(qSeed, 1e15, maxSafe / 4);
        uint256 buyCost = h.quoteBuy(alpha, 0, 1, q);
        uint256 sellProceeds = h.quoteSell(alpha, 0, 1, q);
        assertGe(buyCost, sellProceeds);
    }

    function testFuzz_quantityFromCost_roundtrip(uint256 seed, uint256 alphaSeed, uint256 costSeed) public {
        uint256 alpha = bound(alphaSeed, 0.5e18, 50e18);
        uint256[] memory f = _factorsFromSeed(seed, 4);
        h.seed(f);
        uint256 cost = bound(costSeed, 1e15, alpha / 2);
        uint256 q = h.quantityFromCost(alpha, 0, 1, cost);
        if (q == 0) return;
        uint256 reconstructedCost = h.quoteBuy(alpha, 0, 1, q);
        // 1% tolerance + 1 for cumulative exp/ln rounding
        assertApproxEqAbs(reconstructedCost, cost, cost / 100 + 1);
    }

    function testFuzz_quoteBuy_fullRange_approxQuantity(uint256 seed, uint256 alphaSeed, uint256 qSeed) public {
        uint256 alpha = bound(alphaSeed, 0.5e18, 50e18);
        uint256[] memory f = _factorsFromSeed(seed, 4);
        h.seed(f);
        uint256 maxSafe = h.maxSafeChunkQuantity(alpha);
        uint256 q = bound(qSeed, 1e15, maxSafe / 2);
        // Full range buy: bins 0-3
        uint256 cost = h.quoteBuy(alpha, 0, 3, q);
        // CLMSR identity: full-range cost ≈ quantity, within 1%
        assertApproxEqRel(cost, q, 0.01e18);
    }

    function testFuzz_quoteBuy_chunking(uint256 seed, uint256 alphaSeed) public {
        uint256 alpha = bound(alphaSeed, 0.5e18, 10e18);
        uint256[] memory f = _factorsFromSeed(seed, 4);
        h.seed(f);
        uint256 maxSafe = h.maxSafeChunkQuantity(alpha);
        // Quantity > maxSafe to trigger chunking (2-3 chunks)
        uint256 q = maxSafe + maxSafe / 2;
        // Should not revert
        uint256 cost = h.quoteBuy(alpha, 0, 1, q);
        assertGt(cost, 0);
    }
}
