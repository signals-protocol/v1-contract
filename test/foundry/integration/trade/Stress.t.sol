// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/TradeModuleDeployer.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title StressTest
/// @notice Integration: stress and boundary scenarios for TradeModule.
/// @dev Mirrors test/integration/trade/stress.spec.ts (3 tests).
contract StressTest is TradeModuleDeployer {
    // ============================================================
    // Many positions on large bin market
    // ============================================================

    function test_handlesManyPositionsOnLargeBinMarket() public {
        TradeModuleSystem memory sys = deployLargeBinSystem(128);

        // Open 50 positions with deterministic pseudo-random params, track owners
        uint256 ops = 50;
        uint256 seed = 424242;

        address[] memory posOwners = new address[](ops);

        for (uint256 i = 0; i < ops; i++) {
            seed = (seed * 1664525 + 1013904223) % 0xffffffff;
            uint256 userIdx = seed % sys.users.length;
            seed = (seed * 1664525 + 1013904223) % 0xffffffff;
            int256 lower = int256(seed % 127);
            seed = (seed * 1664525 + 1013904223) % 0xffffffff;
            int256 upper = lower + 1 + int256(seed % uint256(128 - uint256(lower) - 1));
            seed = (seed * 1664525 + 1013904223) % 0xffffffff;
            uint128 qty = uint128(500 + (seed % 1_000));

            vm.prank(sys.users[userIdx]);
            sys.core.openPosition(1, lower, upper, qty, 50_000_000);
            posOwners[i] = sys.users[userIdx];
        }

        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        assertEq(m.openPositionCount, ops);

        // Close all positions with correct owners
        for (uint256 i = 0; i < ops; i++) {
            vm.prank(posOwners[i]);
            sys.core.closePosition(i + 1, 0);
        }

        m = sys.core.harnessGetMarket(1);
        assertEq(m.openPositionCount, 0);
    }

    // ============================================================
    // Extreme quantity values
    // ============================================================

    function test_handlesExtremeQuantityValues() public {
        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: 4,
            tickSpacing: 1,
            minTick: 0,
            maxTick: 4,
            endOffset: 10_000,
            liquidityParameter: WAD
        });
        TradeModuleSystem memory sys = deployTradeModuleSystem(
            DeployOptions({
                markets: markets,
                userCount: 1,
                fundAmount: 10_000_000e6,
                submitWindow: 300,
                settlementWindow: 60
            })
        );

        address user = sys.users[0];
        uint128 largeQty = 1_000_000;
        uint256 quote = sys.core.calculateOpenCost(1, 0, 4, largeQty);
        vm.prank(user);
        sys.core.openPosition(1, 0, 4, largeQty, quote * 2);

        ISignalsPosition.Position memory pos = sys.position.getPosition(1);
        assertEq(pos.quantity, largeQty);
    }

    // ============================================================
    // Reverts after expiry
    // ============================================================

    function test_revertsTradesAfterMarketExpiry() public {
        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: 8,
            tickSpacing: 1,
            minTick: 0,
            maxTick: 8,
            endOffset: 50,
            liquidityParameter: WAD
        });
        TradeModuleSystem memory sys = deployTradeModuleSystem(
            DeployOptions({
                markets: markets,
                userCount: 1,
                fundAmount: 100_000e6,
                submitWindow: 300,
                settlementWindow: 60
            })
        );

        address user = sys.users[0];
        uint256 quote = sys.core.calculateOpenCost(1, 0, 4, 1_000);
        vm.prank(user);
        sys.core.openPosition(1, 0, 4, 1_000, quote + 1_000);

        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        vm.warp(uint256(m.endTimestamp) + 1);

        vm.prank(user);
        vm.expectRevert(SE.MarketExpired.selector);
        sys.core.openPosition(1, 0, 4, 1_000, quote + 1_000);
    }
}
