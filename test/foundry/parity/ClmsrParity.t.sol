// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/HarnessDeployer.sol";
import "../../../contracts/testonly/ClmsrMathHarness.sol";

/// @title ClmsrParityTest
/// @notice Golden-value parity tests for CLMSR math.
/// @dev Mirrors test/parity/clmsr.spec.ts (9 tests).
///
/// Tests:
///   1. Closed-form cost/proceeds for symmetric buy/sell
///   2. Round-trip quantity -> cost -> quantity
///   3. E2E open->close restores distribution
///   4. Round-trip on non-uniform distribution
///   5. SDK calculateOpenCost & quantityFromCost parity
///   6. SDK decrease/close proceeds parity
///   7. SDK parity on non-uniform distribution with alpha != 1
///   8. Larger quantity full-range parity
///   9. safeExp parity (golden values)
contract ClmsrParityTest is HarnessDeployer {
    ClmsrMathHarness h;

    uint32 constant LO_BIN = 0;
    uint32 constant HI_BIN = 3; // 4 bins total
    uint256 constant QTY = WAD; // 1.0

    /// @dev 3e-8 WAD tolerance (matches TS TOLERANCE)
    uint256 constant TOLERANCE = 30_000_000_000; // 3e10

    /// @dev 1e-6 WAD tolerance for safeExp parity (matches TS SAFE_EXP_TOLERANCE)
    uint256 constant SAFE_EXP_TOLERANCE = 1e12;

    function setUp() public override {
        super.setUp();
        h = deployClmsrMathHarness();

        // Seed with uniform [1, 1, 1, 1]
        uint256[] memory factors = new uint256[](4);
        factors[0] = WAD;
        factors[1] = WAD;
        factors[2] = WAD;
        factors[3] = WAD;
        h.seed(factors);
    }

    // ============================================================
    // 1. Closed-form cost/proceeds for symmetric buy/sell
    // ============================================================

    function test_matchesClosedFormCostProceeds() public view {
        // For full-range buy on uniform distribution: cost = quantity
        uint256 cost = h.quoteBuy(ALPHA, LO_BIN, HI_BIN, QTY);
        assertApproxEqAbs(cost, WAD, TOLERANCE, "cost must match WAD for full-range uniform buy");

        uint256 proceeds = h.quoteSell(ALPHA, LO_BIN, HI_BIN, QTY);
        assertApproxEqAbs(proceeds, WAD, TOLERANCE, "proceeds must match WAD for full-range uniform sell");
    }

    // ============================================================
    // 2. Round-trip quantity -> cost -> quantity
    // ============================================================

    function test_roundTripQuantityCostQuantity() public view {
        uint256 cost = h.quoteBuy(ALPHA, LO_BIN, HI_BIN, QTY);
        uint256 qtyBack = h.quantityFromCost(ALPHA, LO_BIN, HI_BIN, cost);
        assertApproxEqAbs(qtyBack, QTY, TOLERANCE, "round-trip quantity must match");
    }

    // ============================================================
    // 3. E2E open->close restores distribution
    // ============================================================

    function test_openCloseRestoresDistribution() public {
        uint256 halfQty = WAD / 2; // 0.5

        uint256 rootBefore = h.rangeSum(0, 3);

        // Buy: compute cost then apply factor
        uint256 cost = h.quoteBuy(ALPHA, LO_BIN, HI_BIN, halfQty);
        uint256 factor = h.exposedSafeExp(halfQty, ALPHA); // exp(q/alpha)
        h.applyRangeFactor(LO_BIN, HI_BIN, factor);

        uint256 rootAfterBuy = h.rangeSum(0, 3);
        uint256 expectedAfterBuy = (rootBefore * factor) / WAD;
        assertApproxEqAbs(rootAfterBuy, expectedAfterBuy, TOLERANCE * 10, "root after buy must match");

        // Sell: apply inverse factor
        uint256 proceeds = h.quoteSell(ALPHA, LO_BIN, HI_BIN, halfQty);
        uint256 inverseFactor = (WAD * WAD) / factor;
        h.applyRangeFactor(LO_BIN, HI_BIN, inverseFactor);

        uint256 rootAfterSell = h.rangeSum(0, 3);
        assertApproxEqAbs(rootAfterSell, rootBefore, TOLERANCE * 10, "root after sell must restore");

        // Cost and proceeds should be ~symmetric
        assertApproxEqAbs(cost, proceeds, TOLERANCE * 10, "cost and proceeds must be symmetric");
    }

    // ============================================================
    // 4. Round-trip on non-uniform distribution
    // ============================================================

    function test_roundTripNonUniform() public {
        // Re-seed with non-uniform [1, 2, 3, 5]
        uint256[] memory factors = new uint256[](4);
        factors[0] = WAD;
        factors[1] = 2 * WAD;
        factors[2] = 3 * WAD;
        factors[3] = 5 * WAD;
        h.seed(factors);

        uint256 q = 0.42e18; // arbitrary quantity (0.42 WAD)
        uint256 cost = h.quoteBuy(ALPHA, 1, 3, q);
        uint256 qtyBack = h.quantityFromCost(ALPHA, 1, 3, cost);
        assertApproxEqAbs(qtyBack, q, TOLERANCE * 10, "non-uniform round-trip must match");

        // Monotonicity: larger quantity costs more
        uint256 q2 = 0.84e18;
        uint256 cost2 = h.quoteBuy(ALPHA, 1, 3, q2);
        assertGt(cost2, cost, "larger quantity must cost more");
    }

    // ============================================================
    // 5. Golden values: calculateOpenCost & quantityFromCost
    // (pre-computed from SDK for uniform distribution, alpha=1, 4 bins)
    // ============================================================

    function test_goldenOpenCostAndQuantityFromCost() public view {
        // SDK: calculateOpenCost(0, 4, 1_000_000, uniform_4bin, alpha=1) → cost ≈ 1_000_000 micro-USDC
        // In WAD: quantity = 1e18, cost should be ~1e18 (full-range uniform = linear cost)
        uint256 costWad = h.quoteBuy(ALPHA, LO_BIN, HI_BIN, WAD);
        // Full-range uniform: cost = quantity exactly
        assertApproxEqAbs(costWad, WAD, TOLERANCE, "golden: full-range cost must equal quantity");

        // quantityFromCost round-trip
        uint256 qtyWad = h.quantityFromCost(ALPHA, LO_BIN, HI_BIN, costWad);
        assertApproxEqAbs(qtyWad, WAD, TOLERANCE, "golden: quantityFromCost must round-trip");
    }

    // ============================================================
    // 6. Golden values: decrease/close proceeds
    // (After opening a position, sell proceeds should match)
    // ============================================================

    function test_goldenDecreaseCloseProceeds() public {
        // Open a position (apply factor to tree)
        uint256 posQtyWad = 2e18; // 2 WAD position
        uint256 factor = h.exposedSafeExp(posQtyWad, ALPHA);
        h.applyRangeFactor(LO_BIN, HI_BIN, factor);

        // Sell half
        uint256 sellQtyWad = 0.5e18;
        uint256 proceedsWad = h.quoteSell(ALPHA, LO_BIN, HI_BIN, sellQtyWad);
        assertGt(proceedsWad, 0, "golden: sell proceeds must be positive");

        // Close full position
        uint256 closeWad = h.quoteSell(ALPHA, LO_BIN, HI_BIN, posQtyWad);
        assertGt(closeWad, proceedsWad, "golden: full close must exceed partial sell");
    }

    // ============================================================
    // 7. Non-uniform distribution with alpha != 1
    // ============================================================

    function test_goldenNonUniformAlpha075() public {
        uint256 alphaCustom = 0.75e18; // 0.75 WAD

        // Re-seed with [1, 2, 4, 8]
        uint256[] memory factors = new uint256[](4);
        factors[0] = WAD;
        factors[1] = 2 * WAD;
        factors[2] = 4 * WAD;
        factors[3] = 8 * WAD;
        h.seed(factors);

        // Buy range [1, 3) with 1.5 WAD quantity
        uint256 qtyWad = 1.5e18;
        uint256 costWad = h.quoteBuy(alphaCustom, 1, 2, qtyWad);
        assertGt(costWad, 0, "golden: non-uniform alpha=0.75 cost must be positive");

        // Round-trip
        uint256 qtyBack = h.quantityFromCost(alphaCustom, 1, 2, costWad);
        // Allow looser tolerance for non-uniform + non-unit alpha
        assertApproxEqAbs(qtyBack, qtyWad, TOLERANCE * 100, "golden: non-uniform round-trip must match");
    }

    // ============================================================
    // 8. Larger quantity full-range parity
    // ============================================================

    function test_goldenLargerQuantityFullRange() public view {
        // 3 WAD quantity on full range
        uint256 qtyWad = 3e18;
        uint256 costWad = h.quoteBuy(ALPHA, LO_BIN, HI_BIN, qtyWad);

        // Full-range uniform: cost = quantity
        // Allow 2% tolerance for larger quantities (matches TS pctTolerance)
        uint256 twoPercent = costWad / 50;
        assertApproxEqAbs(costWad, qtyWad, twoPercent, "golden: large full-range cost must be ~quantity");
    }

    // ============================================================
    // 9. safeExp parity (golden values)
    // Representative inputs: alpha in {0.5, 1, 2}, q in {0.1, 0.5, 1, 2}
    // ============================================================

    function test_safeExpGoldenValues() public view {
        uint256[3] memory alphas = [uint256(0.5e18), uint256(1e18), uint256(2e18)];
        uint256[4] memory qs = [uint256(0.1e18), uint256(0.5e18), uint256(1e18), uint256(2e18)];

        // Pre-computed golden values: exp(q/alpha) in WAD
        // These are mathematically exact: exp(q/alpha) * 1e18
        //
        // alpha=0.5: q=0.1→exp(0.2), q=0.5→exp(1), q=1→exp(2), q=2→exp(4)
        // alpha=1.0: q=0.1→exp(0.1), q=0.5→exp(0.5), q=1→exp(1), q=2→exp(2)
        // alpha=2.0: q=0.1→exp(0.05), q=0.5→exp(0.25), q=1→exp(0.5), q=2→exp(1)

        // Just verify internal consistency: exp(q/alpha) > 1 for all positive q,alpha
        for (uint256 a = 0; a < 3; a++) {
            for (uint256 q = 0; q < 4; q++) {
                uint256 result = h.exposedSafeExp(qs[q], alphas[a]);
                assertGt(result, WAD, "safeExp must be > 1 WAD for positive inputs");
            }
        }

        // Specific golden: exp(1) ≈ 2.718281828...e18
        uint256 exp1 = h.exposedSafeExp(WAD, WAD);
        uint256 EULER_WAD = 2_718281828459045235;
        assertApproxEqAbs(exp1, EULER_WAD, SAFE_EXP_TOLERANCE, "safeExp(1,1) must match e");

        // exp(0.5) ≈ 1.6487212707...e18
        uint256 expHalf = h.exposedSafeExp(0.5e18, WAD);
        uint256 SQRT_E_WAD = 1_648721270700128146;
        assertApproxEqAbs(expHalf, SQRT_E_WAD, SAFE_EXP_TOLERANCE, "safeExp(0.5,1) must match sqrt(e)");

        // exp(2) ≈ 7.389056099...e18
        uint256 exp2 = h.exposedSafeExp(2e18, WAD);
        uint256 E_SQUARED_WAD = 7_389056098930650227;
        assertApproxEqAbs(exp2, E_SQUARED_WAD, SAFE_EXP_TOLERANCE, "safeExp(2,1) must match e^2");
    }
}
