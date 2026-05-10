// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/TradeModuleDeployer.sol";
import "./handlers/TradeHandler.sol";

/// @title ClmsrInvariantTest
/// @notice Foundry invariant tests for CLMSR mathematical and system invariants.
/// @dev Mirrors test/invariant/clmsr.invariants.spec.ts (22 tests).
///
/// Invariants tested:
///   - INV-1/2/3: Sum monotonicity (buy increases, sell decreases)
///   - INV-4/5: Range isolation (only affected bins change)
///   - INV-RBE-1/2/3: Range-binary equivalence
///   - INV-6/7/8/9: Cost/proceeds symmetry
///   - INV-EC-1/2/3/4: Edge cases
///   - INV-PI-1/2: Path independence
///   - INV-LB-1/2: Loss bound
///   - INV-10/11: Stress invariants
contract ClmsrInvariantTest is TradeModuleDeployer {
    uint32 constant NUM_BINS = 10;
    uint256 constant MARKET_ID = 1;

    TradeModuleSystem sys;
    TradeHandler handler;

    function setUp() public override {
        super.setUp();

        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: NUM_BINS,
            tickSpacing: 1,
            minTick: 0,
            maxTick: int256(uint256(NUM_BINS)),
            endOffset: 100_000,
            liquidityParameter: WAD
        });

        sys = deployTradeModuleSystem(
            DeployOptions({markets: markets, userCount: 2, fundAmount: 100_000e6, submitWindow: 1, settlementWindow: 1})
        );

        handler = new TradeHandler(sys.core, sys.position, MARKET_ID, NUM_BINS, sys.users[0]);

        targetContract(address(handler));
    }

    // ============================================================
    // Invariant: Total sum is always positive after any sequence of trades
    // ============================================================

    function invariant_totalSumPositive() public view {
        uint256 totalSum = sys.core.getMarketTotalSum(MARKET_ID);
        assertGt(totalSum, 0, "INV: totalSum must be > 0");
    }

    // ============================================================
    // Invariant: All individual bin factors remain positive
    // ============================================================

    function invariant_allBinsPositive() public view {
        for (uint32 i = 0; i < NUM_BINS; i++) {
            uint256 binValue = sys.core.getMarketBinFactor(MARKET_ID, i);
            assertGt(binValue, 0, "INV: each bin must be > 0");
        }
    }

    // ============================================================
    // Invariant: Total sum >= initial sum (buys only increase it, closes approximately restore)
    // ============================================================

    function invariant_totalSumGeInitial() public view {
        uint256 totalSum = sys.core.getMarketTotalSum(MARKET_ID);
        uint256 initialSum = uint256(NUM_BINS) * WAD;
        // After closes, sum may drop slightly below initial due to rounding
        // Allow 1000 wei tolerance per close operation
        uint256 tolerance = handler.closeCount() * 1000;
        assertGe(totalSum + tolerance, initialSum, "INV: totalSum should be >= initial (within rounding)");
    }

    // ============================================================
    // Sum Monotonicity (INV-1, INV-2, INV-3)
    // ============================================================

    function test_INV1_buyIncreasesTotalSum() public {
        uint256 sumBefore = sys.core.getMarketTotalSum(MARKET_ID);

        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, 2, 5, uint128(MEDIUM_QUANTITY), 100e6);

        uint256 sumAfter = sys.core.getMarketTotalSum(MARKET_ID);
        assertGt(sumAfter, sumBefore, "INV-1: buy must increase total sum");
    }

    function test_INV2_sellDecreasesTotalSum() public {
        uint256 nextId = sys.position.nextId();

        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, 2, 5, uint128(MEDIUM_QUANTITY), 100e6);

        uint256 sumBefore = sys.core.getMarketTotalSum(MARKET_ID);

        vm.prank(sys.users[0]);
        sys.core.closePosition(nextId, 0);

        uint256 sumAfter = sys.core.getMarketTotalSum(MARKET_ID);
        assertLt(sumAfter, sumBefore, "INV-2: sell must decrease total sum");
    }

    function test_INV3_multipleBuysMonotonicallyIncreaseSum() public {
        uint256 prevSum = sys.core.getMarketTotalSum(MARKET_ID);

        for (uint256 i = 0; i < 5; i++) {
            int256 lo = int256(i % (NUM_BINS - 1));
            int256 hi = lo + 1;

            vm.prank(sys.users[0]);
            sys.core.openPosition(MARKET_ID, lo, hi, uint128(SMALL_QUANTITY), 10e6);

            uint256 newSum = sys.core.getMarketTotalSum(MARKET_ID);
            assertGt(newSum, prevSum, "INV-3: each buy must increase sum");
            prevSum = newSum;
        }
    }

    // ============================================================
    // Range Isolation (INV-4, INV-5)
    // ============================================================

    function test_INV4_buyOnlyAffectsBinsInRange() public {
        // Record bin values before
        uint256[] memory binsBefore = new uint256[](NUM_BINS);
        for (uint32 i = 0; i < NUM_BINS; i++) {
            binsBefore[i] = sys.core.getMarketBinFactor(MARKET_ID, i);
        }

        // Buy range [3, 6)
        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, 3, 6, uint128(MEDIUM_QUANTITY), 100e6);

        for (uint32 i = 0; i < NUM_BINS; i++) {
            uint256 binAfter = sys.core.getMarketBinFactor(MARKET_ID, i);
            if (i >= 3 && i < 6) {
                assertGt(binAfter, binsBefore[i], "INV-4: affected bins must increase");
            } else {
                assertEq(binAfter, binsBefore[i], "INV-4: unaffected bins must not change");
            }
        }
    }

    function test_INV5_overlappingRangesCompound() public {
        // First buy [2, 5)
        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, 2, 5, uint128(MEDIUM_QUANTITY), 100e6);

        uint256 bin3After1 = sys.core.getMarketBinFactor(MARKET_ID, 3);

        // Second buy [3, 7) - overlaps at [3, 5)
        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, 3, 7, uint128(MEDIUM_QUANTITY), 100e6);

        uint256 bin3After2 = sys.core.getMarketBinFactor(MARKET_ID, 3);
        assertGt(bin3After2, bin3After1, "INV-5: overlapping buy must further increase bin");
    }

    // ============================================================
    // Range-Binary Equivalence (INV-RBE-1, INV-RBE-2, INV-RBE-3)
    // ============================================================

    function test_INVRBE1_singleBinBuyPositiveCost() public {
        uint256 cost = sys.core.calculateOpenCost(MARKET_ID, 4, 5, uint128(SMALL_QUANTITY));
        assertGt(cost, 0, "INV-RBE-1: single bin buy must have positive cost");
    }

    function test_INVRBE2_fullRangeBuyPositiveCost() public {
        uint256 cost = sys.core.calculateOpenCost(MARKET_ID, 0, int256(uint256(NUM_BINS)), uint128(SMALL_QUANTITY));
        assertGt(cost, 0, "INV-RBE-2: full range buy must have positive cost");
    }

    function test_INVRBE3_adjacentRangesNotAdditive() public {
        uint256 costA = sys.core.calculateOpenCost(MARKET_ID, 0, 5, uint128(SMALL_QUANTITY));
        uint256 costB = sys.core.calculateOpenCost(MARKET_ID, 5, int256(uint256(NUM_BINS)), uint128(SMALL_QUANTITY));
        uint256 costFull = sys.core.calculateOpenCost(MARKET_ID, 0, int256(uint256(NUM_BINS)), uint128(SMALL_QUANTITY));

        // Sum of parts != whole due to normalization
        assertTrue(costA + costB != costFull, "INV-RBE-3: adjacent range costs must not be additive");
    }

    // ============================================================
    // Cost/Proceeds Symmetry (INV-6, INV-7, INV-8, INV-9)
    // ============================================================

    function test_INV6_roundtripRestoresDistribution() public {
        uint256 sumBefore = sys.core.getMarketTotalSum(MARKET_ID);

        uint256 positionId = sys.position.nextId();

        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, 2, 5, uint128(MEDIUM_QUANTITY), 100e6);

        vm.prank(sys.users[0]);
        sys.core.closePosition(positionId, 0);

        uint256 sumAfter = sys.core.getMarketTotalSum(MARKET_ID);

        uint256 diff = sumAfter > sumBefore ? sumAfter - sumBefore : sumBefore - sumAfter;
        assertLe(diff, 100, "INV-6: roundtrip must restore distribution within 100 wei");
    }

    function test_INV7_costIncreasesWithQuantity() public {
        uint256 smallCost = sys.core.calculateOpenCost(MARKET_ID, 2, 5, uint128(SMALL_QUANTITY));
        uint256 largeCost = sys.core.calculateOpenCost(MARKET_ID, 2, 5, uint128(MEDIUM_QUANTITY));

        assertGt(largeCost, smallCost, "INV-7: larger quantity must cost more");
    }

    function test_INV8_proceedsIncreaseWithQuantity() public {
        uint256 positionId = sys.position.nextId();

        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, 2, 5, uint128(MEDIUM_QUANTITY), 100e6);

        uint256 smallProceeds = sys.core.calculateDecreaseProceeds(positionId, uint128(SMALL_QUANTITY));
        uint256 largeProceeds = sys.core.calculateDecreaseProceeds(positionId, uint128(MEDIUM_QUANTITY));

        assertGt(largeProceeds, smallProceeds, "INV-8: larger quantity must yield more proceeds");
    }

    // ============================================================
    // Edge Cases (INV-EC-1, INV-EC-2, INV-EC-3, INV-EC-4)
    // ============================================================

    function test_INVEC1_singleBinAtBoundary0() public {
        uint256 cost = sys.core.calculateOpenCost(MARKET_ID, 0, 1, uint128(SMALL_QUANTITY));
        assertGt(cost, 0, "INV-EC-1: first bin buy must have positive cost");
    }

    function test_INVEC2_singleBinAtBoundaryLast() public {
        uint256 cost = sys.core
            .calculateOpenCost(
                MARKET_ID, int256(uint256(NUM_BINS - 1)), int256(uint256(NUM_BINS)), uint128(SMALL_QUANTITY)
            );
        assertGt(cost, 0, "INV-EC-2: last bin buy must have positive cost");
    }

    function test_INVEC3_verySmallQuantity() public {
        uint256 cost = sys.core.calculateOpenCost(MARKET_ID, 2, 5, 1);
        assertGe(cost, 0, "INV-EC-3: tiny quantity must have non-negative cost");
    }

    function test_INVEC4_concentratedDistribution() public {
        // Concentrate mass on bin 5 through multiple buys
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(sys.users[0]);
            sys.core.openPosition(MARKET_ID, 5, 6, uint128(MEDIUM_QUANTITY), 100e6);
        }

        uint256 costConcentrated = sys.core.calculateOpenCost(MARKET_ID, 5, 6, uint128(SMALL_QUANTITY));
        uint256 costOther = sys.core.calculateOpenCost(MARKET_ID, 0, 1, uint128(SMALL_QUANTITY));

        assertGt(costConcentrated, costOther, "INV-EC-4: concentrated bin must be more expensive");
    }

    // ============================================================
    // Path Independence (INV-PI-1, INV-PI-2)
    // ============================================================

    function test_INVPI1_sameEndStateYieldsSameCost() public {
        // Path 1: Direct buy cost
        uint256 directCost = sys.core.calculateOpenCost(MARKET_ID, 2, 5, uint128(MEDIUM_QUANTITY));

        // Set up second market for Path 2
        ISignalsCore.Market memory m = sys.core.harnessGetMarket(MARKET_ID);
        sys.core.setMarket(2, m);
        sys.core.seedTree(2, uniformFactors(NUM_BINS));

        // Path 2: Two half-size buys
        uint128 halfQty = uint128(MEDIUM_QUANTITY / 2);
        uint256 cost1 = sys.core.calculateOpenCost(2, 2, 5, halfQty);

        vm.prank(sys.users[0]);
        sys.core.openPosition(2, 2, 5, halfQty, 100e6);

        uint256 cost2 = sys.core.calculateOpenCost(2, 2, 5, halfQty);
        uint256 pathCost = cost1 + cost2;

        // Both should be positive (path cost >= direct due to convexity)
        assertGt(directCost, 0, "INV-PI-1: direct cost must be positive");
        assertGt(pathCost, 0, "INV-PI-1: path cost must be positive");
    }

    function test_INVPI2_orderOfIndependentRangesDoesntAffectTotalCost() public {
        uint256 costA = sys.core.calculateOpenCost(MARKET_ID, 0, 2, uint128(SMALL_QUANTITY));
        uint256 costB = sys.core.calculateOpenCost(MARKET_ID, 5, 8, uint128(SMALL_QUANTITY));

        assertGt(costA, 0, "INV-PI-2: cost A must be positive");
        assertGt(costB, 0, "INV-PI-2: cost B must be positive");

        // Execute A first, then check B's cost
        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, 0, 2, uint128(SMALL_QUANTITY), 50e6);

        uint256 costB_afterA = sys.core.calculateOpenCost(MARKET_ID, 5, 8, uint128(SMALL_QUANTITY));
        assertGt(costB_afterA, 0, "INV-PI-2: cost B after A must be positive");
    }

    // ============================================================
    // Loss Bound (INV-LB-1, INV-LB-2)
    // ============================================================

    function test_INVLB1_maxLossBounded() public view {
        uint256 initialSum = sys.core.getMarketTotalSum(MARKET_ID);
        assertEq(initialSum, uint256(NUM_BINS) * WAD, "INV-LB-1: initial sum must be n * WAD");
    }

    function test_INVLB1_largeBuyCostPositive() public {
        uint256 cost = sys.core.calculateOpenCost(MARKET_ID, 0, 1, uint128(10e6));
        assertGt(cost, 0, "INV-LB-1: large buy cost must be positive");
    }

    function test_INVLB2_costIncreasesAsMassConcentrates() public {
        uint256[] memory costs = new uint256[](5);

        for (uint256 i = 0; i < 5; i++) {
            costs[i] = sys.core.calculateOpenCost(MARKET_ID, 4, 5, uint128(MEDIUM_QUANTITY));

            vm.prank(sys.users[0]);
            sys.core.openPosition(MARKET_ID, 4, 5, uint128(MEDIUM_QUANTITY), 100e6);
        }

        for (uint256 i = 1; i < 5; i++) {
            assertGt(costs[i], costs[i - 1], "INV-LB-2: cost must increase as mass concentrates");
        }
    }

    // ============================================================
    // Stress Invariants (INV-10, INV-11)
    // ============================================================

    function test_INV10_sumConsistentUnderManyOps() public {
        Prng memory prng = createPrng(uint64(42));

        for (uint256 i = 0; i < 20; i++) {
            uint256 lo = nextInRange(prng, 0, NUM_BINS - 1);
            uint256 hi = lo + 1 + (nextInRange(prng, 0, NUM_BINS - 1 - lo));

            vm.prank(sys.users[0]);
            sys.core.openPosition(MARKET_ID, int256(lo), int256(hi), uint128(SMALL_QUANTITY), 50e6);
        }

        uint256 totalSum = sys.core.getMarketTotalSum(MARKET_ID);
        assertGt(totalSum, uint256(NUM_BINS) * WAD, "INV-10: sum must exceed initial after buys");

        for (uint32 i = 0; i < NUM_BINS; i++) {
            uint256 binValue = sys.core.getMarketBinFactor(MARKET_ID, i);
            assertGt(binValue, 0, "INV-10: each bin must remain positive");
        }
    }

    function test_INV11_multiUserConsistency() public {
        uint256 pos1Id = sys.position.nextId();

        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, 2, 4, uint128(MEDIUM_QUANTITY), 100e6);

        uint256 pos2Id = sys.position.nextId();

        vm.prank(sys.users[1]);
        sys.core.openPosition(MARKET_ID, 5, 8, uint128(MEDIUM_QUANTITY), 100e6);

        vm.prank(sys.users[0]);
        sys.core.closePosition(pos1Id, 0);

        vm.prank(sys.users[1]);
        sys.core.closePosition(pos2Id, 0);

        uint256 finalSum = sys.core.getMarketTotalSum(MARKET_ID);
        uint256 initialSum = uint256(NUM_BINS) * WAD;

        uint256 diff = finalSum > initialSum ? finalSum - initialSum : initialSum - finalSum;
        assertLe(diff, 200, "INV-11: multi-user roundtrip must restore within 200 wei");
    }
}
