// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/SeedHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title Seed Chunks Gating E2E Test
/// @notice 1 test: verifies trading is blocked until market is fully seeded via chunks
contract SeedChunksTest is FullSystemDeployer {
    FullSystem internal sys;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(5, 5);
    }

    function test_blocks_trading_until_market_is_fully_seeded() public {
        address trader = sys.users[0];
        address coreAddress = address(sys.core);

        // Seed vault
        uint256 seedAmount = 20_000_000;
        sys.payment.mint(sys.owner, seedAmount);
        vm.startPrank(sys.owner);
        sys.payment.approve(coreAddress, seedAmount);
        sys.core.seedVault(seedAmount);
        vm.stopPrank();

        // Fund trader
        sys.payment.mint(trader, 50_000_000);
        vm.prank(trader);
        sys.payment.approve(coreAddress, type(uint256).max);

        // Create market with 6 bins (DO NOT use createMarketUniform — it auto-seeds)
        uint32 numBins = 6;
        uint64 start = uint64(block.timestamp - 5);
        uint64 end = uint64(block.timestamp + 100);
        uint64 settlement = uint64(block.timestamp + 200);

        uint256[] memory factors = uniformFactors(numBins);
        SeedData seedData = SeedHelper.deploySeedData(factors);

        vm.prank(sys.owner);
        uint256 marketId = sys.core
            .createMarket(
                0,
                int256(uint256(numBins)),
                1,
                start,
                end,
                settlement,
                numBins,
                WAD,
                address(sys.feePolicy),
                address(seedData)
            );

        // Market starts unseeded
        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertFalse(market.isSeeded);
        assertEq(market.seedCursor, 0);

        // Seed 2 chunks
        vm.prank(sys.owner);
        sys.core.seedNextChunks(marketId, 2);
        market = sys.core.harnessGetMarket(marketId);
        assertEq(market.seedCursor, 2);
        assertFalse(market.isSeeded);

        // Trading should fail (not fully seeded)
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotSeeded.selector));
        sys.core.openPosition(marketId, 1, 3, 1_000, 0);

        // Seed 2 more
        vm.prank(sys.owner);
        sys.core.seedNextChunks(marketId, 2);
        market = sys.core.harnessGetMarket(marketId);
        assertEq(market.seedCursor, 4);
        assertFalse(market.isSeeded);

        // Seed remaining (request more than needed, should cap)
        vm.prank(sys.owner);
        sys.core.seedNextChunks(marketId, 10);
        market = sys.core.harnessGetMarket(marketId);
        assertEq(market.seedCursor, numBins);
        assertTrue(market.isSeeded);

        // Now trading should succeed
        uint256 openCost = sys.core.calculateOpenCost(marketId, 1, 3, 1_000);
        vm.prank(trader);
        sys.core.openPosition(marketId, 1, 3, 1_000, openCost + 1_000_000);
    }
}
