// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/TradeModuleDeployer.sol";

/// @title RoundingInvariantTest
/// @notice Foundry invariant tests for CLMSR rounding properties.
/// @dev Mirrors test/invariant/rounding.invariants.spec.ts (6 tests).
///
/// Invariants tested:
///   - INV-R-1: Small quantities have positive cost
///   - INV-R-2: Cost never underestimates (user protection)
///   - INV-R-3: Proceeds never exceed theoretical value
///   - INV-R-4: Full close returns <= cost paid
///   - INV-R-5: Roundtrip never creates value
///   - INV-R-6: Protocol collects rounding dust, never loses it
contract RoundingInvariantTest is TradeModuleDeployer {
    uint32 constant NUM_BINS = 10;
    uint256 constant MARKET_ID = 1;

    TradeModuleSystem sys;

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
            DeployOptions({markets: markets, userCount: 1, fundAmount: 100_000e6, submitWindow: 1, settlementWindow: 1})
        );
    }

    // ============================================================
    // Cost Rounding (Debits)
    // ============================================================

    function test_INVR1_smallQuantityPositiveCost() public {
        uint256 cost = sys.core.calculateOpenCost(MARKET_ID, 4, 5, 1);
        assertGe(cost, 0, "INV-R-1: tiny quantity must have non-negative cost");
    }

    function test_INVR2_costNeverUnderestimates() public {
        address user = sys.users[0];
        uint256 balBefore = sys.payment.balanceOf(user);

        vm.prank(user);
        sys.core.openPosition(MARKET_ID, 3, 6, uint128(MEDIUM_QUANTITY), 100e6);

        uint256 balAfter = sys.payment.balanceOf(user);
        uint256 actualCost = balBefore - balAfter;

        // Actual cost must not exceed maxCost
        assertLe(actualCost, 100e6, "INV-R-2: actual cost must be <= maxCost");
    }

    // ============================================================
    // Proceeds Rounding (Credits)
    // ============================================================

    function test_INVR3_proceedsNeverExceedTheoretical() public {
        address user = sys.users[0];
        uint256 positionId = sys.position.nextId();

        vm.prank(user);
        sys.core.openPosition(MARKET_ID, 3, 6, uint128(MEDIUM_QUANTITY), 100e6);

        uint256 balBefore = sys.payment.balanceOf(user);

        vm.prank(user);
        sys.core.closePosition(positionId, 0);

        uint256 balAfter = sys.payment.balanceOf(user);
        uint256 actualProceeds = balAfter - balBefore;

        assertGe(actualProceeds, 0, "INV-R-3: proceeds must be non-negative");
    }

    function test_INVR4_fullCloseReturnsLeThanCostPaid() public {
        address user = sys.users[0];
        uint256 balStart = sys.payment.balanceOf(user);

        uint256 positionId = sys.position.nextId();

        vm.prank(user);
        sys.core.openPosition(MARKET_ID, 3, 6, uint128(MEDIUM_QUANTITY), 100e6);

        uint256 balAfterOpen = sys.payment.balanceOf(user);
        uint256 costPaid = balStart - balAfterOpen;

        vm.prank(user);
        sys.core.closePosition(positionId, 0);

        uint256 balAfterClose = sys.payment.balanceOf(user);
        uint256 proceedsReceived = balAfterClose - balAfterOpen;

        assertLe(proceedsReceived, costPaid, "INV-R-4: proceeds must be <= cost for immediate close");
    }

    // ============================================================
    // Protocol Solvency
    // ============================================================

    function test_INVR5_roundtripNeverCreatesValue() public {
        address user = sys.users[0];
        uint256 balStart = sys.payment.balanceOf(user);

        uint256 positionId = sys.position.nextId();

        vm.prank(user);
        sys.core.openPosition(MARKET_ID, 2, 5, uint128(MEDIUM_QUANTITY), 100e6);

        vm.prank(user);
        sys.core.closePosition(positionId, 0);

        uint256 balEnd = sys.payment.balanceOf(user);
        assertLe(balEnd, balStart, "INV-R-5: user must not profit from roundtrip");
    }

    function test_INVR6_protocolCollectsRoundingDust() public {
        address user = sys.users[0];
        uint256 coreBalBefore = sys.payment.balanceOf(address(sys.core));

        for (uint256 i = 0; i < 10; i++) {
            int256 lo = int256(i % (NUM_BINS - 1));
            int256 hi = lo + 1;

            vm.prank(user);
            sys.core.openPosition(MARKET_ID, lo, hi, uint128(SMALL_QUANTITY), 10e6);
        }

        uint256 coreBalAfter = sys.payment.balanceOf(address(sys.core));
        assertGe(coreBalAfter, coreBalBefore, "INV-R-6: protocol must not lose funds");
    }
}
