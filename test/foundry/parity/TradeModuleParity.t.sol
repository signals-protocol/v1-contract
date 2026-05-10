// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/TradeModuleDeployer.sol";
import {ISignalsPosition} from "../../../contracts/interfaces/ISignalsPosition.sol";
import {ISignalsCore} from "../../../contracts/interfaces/ISignalsCore.sol";
import {SignalsErrors as SE} from "../../../contracts/errors/SignalsErrors.sol";

/// @title TradeModuleParityTest
/// @notice Golden-value parity tests: view quotes match execution.
/// @dev Mirrors test/parity/tradeModule.spec.ts (3 tests).
///
/// Tests:
///   1. Open cost view matches actual payment deduction
///   2. Decrease proceeds view matches actual payment received
///   3. Multi-user slippage and partial close
contract TradeModuleParityTest is TradeModuleDeployer {
    TradeModuleSystem sys;

    function setUp() public override {
        super.setUp();

        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: 4, tickSpacing: 1, minTick: 0, maxTick: 4, endOffset: 1_000, liquidityParameter: WAD
        });

        sys = deployTradeModuleSystem(
            DeployOptions({
                markets: markets,
                userCount: 2,
                fundAmount: 10_000_000, // 10 USDC
                submitWindow: 300,
                settlementWindow: 60
            })
        );
    }

    // ============================================================
    // 1. Open cost view matches actual payment
    // ============================================================

    function test_matchesOpenCostWithViewQuote() public {
        address userA = sys.users[0];

        uint256 quote = sys.core.calculateOpenCost(1, 0, 4, 2_000);
        uint256 balBefore = sys.payment.balanceOf(userA);
        uint256 nextId = sys.position.nextId();

        vm.prank(userA);
        sys.core.openPosition(1, 0, 4, 2_000, quote + 100);

        uint256 balAfter = sys.payment.balanceOf(userA);

        // Actual cost must match quote exactly
        assertEq(balBefore - balAfter, quote, "open cost must match view quote");
        assertTrue(sys.position.exists(nextId), "position must exist after open");
    }

    // ============================================================
    // 2. Decrease proceeds view matches actual payment
    // ============================================================

    function test_matchesDecreaseProceedsWithViewQuote() public {
        address userA = sys.users[0];

        uint256 nextId = sys.position.nextId();
        uint256 positionId = nextId;

        vm.prank(userA);
        sys.core.openPosition(1, 0, 4, 2_000, 10_000_000);

        uint256 quote = sys.core.calculateDecreaseProceeds(positionId, 800);
        uint256 balBefore = sys.payment.balanceOf(userA);

        vm.prank(userA);
        sys.core.decreasePosition(positionId, 800, quote);

        uint256 balAfter = sys.payment.balanceOf(userA);
        assertEq(balAfter - balBefore, quote, "decrease proceeds must match view quote");

        // Check remaining quantity
        ISignalsPosition.Position memory pos = sys.position.getPosition(positionId);
        assertEq(pos.quantity, 1_200, "remaining quantity must be 1200");
    }

    // ============================================================
    // 3. Multi-user slippage and partial close
    // ============================================================

    function test_handlesMultiUserSlippageAndPartialClose() public {
        address userA = sys.users[0];
        address userB = sys.users[1];

        uint256 posAId = sys.position.nextId();

        vm.prank(userA);
        sys.core.openPosition(1, 0, 4, 1_500, 10_000_000);

        // B's quote should revert if maxCost is below actual
        uint256 quoteB = sys.core.calculateOpenCost(1, 0, 4, 1_000);

        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(SE.CostExceedsMaximum.selector, quoteB, quoteB - 1));
        sys.core.openPosition(1, 0, 4, 1_000, quoteB - 1);

        // B opens with sufficient maxCost
        uint256 posBId = sys.position.nextId();

        vm.prank(userB);
        sys.core.openPosition(1, 0, 4, 1_000, quoteB + 1_000);

        // Decrease B's position partially
        uint256 decQuote = sys.core.calculateDecreaseProceeds(posBId, 600);
        uint256 balBBefore = sys.payment.balanceOf(userB);

        vm.prank(userB);
        sys.core.decreasePosition(posBId, 600, decQuote);

        uint256 balBAfter = sys.payment.balanceOf(userB);
        assertEq(balBAfter - balBBefore, decQuote, "decrease proceeds must match for userB");

        // B closes remaining
        vm.prank(userB);
        sys.core.closePosition(posBId, 0);
        assertFalse(sys.position.exists(posBId), "position B must not exist after close");

        // A closes
        vm.prank(userA);
        sys.core.closePosition(posAId, 0);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(1);
        assertEq(market.openPositionCount, 0, "openPositionCount must be 0 after all close");
    }
}
