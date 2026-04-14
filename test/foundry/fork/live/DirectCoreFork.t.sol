// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/ForkLiveMarketTest.sol";
import "../../../../contracts/interfaces/ISignalsCore.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DirectCoreForkTest
/// @notice Advisory live-market coverage for direct SignalsCore trading without Router custody.
contract DirectCoreForkTest is ForkLiveMarketTest {
    IERC20 internal ctUSDToken;

    function setUp() public override {
        super.setUp();
        ctUSDToken = IERC20(paymentToken);
    }

    function test_direct_trade_lifecycle_on_active_market() public {
        (bool found, uint256 marketId, ISignalsCore.Market memory market) = _tryFindActiveMarket();
        if (!found) return;

        address trader = makeAddr("directCoreTrader");
        deal(paymentToken, trader, 100_000_000);

        vm.prank(trader);
        ctUSDToken.approve(address(core), type(uint256).max);

        int256 centerTick = ((market.minTick + market.maxTick) / 2 / market.tickSpacing) * market.tickSpacing;
        uint128 openQty = 5_000_000;
        uint256 positionId = position.nextId();
        uint256 openCost = core.calculateOpenCost(marketId, centerTick, centerTick + market.tickSpacing, openQty);

        vm.prank(trader);
        core.openPosition(marketId, centerTick, centerTick + market.tickSpacing, openQty, openCost + 1_000_000);

        uint128 increaseQty = 2_000_000;
        uint256 increaseCost = core.calculateIncreaseCost(positionId, increaseQty);

        vm.prank(trader);
        core.increasePosition(positionId, increaseQty, increaseCost + 1_000_000);
        assertEq(position.ownerOf(positionId), trader, "owner changed after increase");

        uint128 quantityAfterIncrease = position.getPosition(positionId).quantity;
        uint256 proceedsBeforeDecrease = ctUSDToken.balanceOf(trader);

        vm.prank(trader);
        core.decreasePosition(positionId, quantityAfterIncrease / 2, 0);

        assertGt(ctUSDToken.balanceOf(trader), proceedsBeforeDecrease, "decrease paid nothing");
        assertTrue(position.exists(positionId), "position burned on partial decrease");

        vm.prank(trader);
        core.closePosition(positionId, 0);

        assertFalse(position.exists(positionId), "position still exists after close");
    }
}
