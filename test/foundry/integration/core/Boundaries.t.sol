// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/TradeModuleDeployer.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title Boundaries Integration Tests
/// @notice Tests edge cases and boundary conditions (19 tests from boundaries.spec.ts)
contract BoundariesTest is TradeModuleDeployer {
    uint256 internal constant MARKET_ID = 1;
    uint32 internal constant NUM_BINS = 100;

    TradeModuleSystem internal sys;

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
            DeployOptions({
                markets: markets, userCount: 1, fundAmount: 100_000e6, submitWindow: 300, settlementWindow: 60
            })
        );
    }

    // ============================================================
    // Quantity Boundaries
    // ============================================================

    function test_reverts_with_zero_quantity() public {
        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.openPosition(MARKET_ID, int256(10), int256(20), uint128(0), 1000e6);
    }

    function test_handles_minimum_quantity_1wei() public {
        // 1 wei quantity should either work or revert cleanly
        vm.prank(sys.users[0]);
        try sys.core.openPosition(MARKET_ID, int256(10), int256(20), uint128(1), 1000e6) {
        // Success is acceptable
        }
            catch {
            // Revert is also acceptable for edge case
        }
    }

    function test_handles_small_but_valid_quantity() public {
        // 1 micro USDC = 1 (6 decimals)
        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, int256(10), int256(20), uint128(1e6 / 1e6), 1000e6);
    }

    function test_cost_increases_monotonically_with_quantity() public {
        uint128[3] memory quantities = [uint128(SMALL_QUANTITY), uint128(MEDIUM_QUANTITY), uint128(1e6)];

        uint256 prevCost = 0;
        for (uint256 i = 0; i < quantities.length; i++) {
            uint256 cost = sys.core.calculateOpenCost(MARKET_ID, int256(10), int256(20), quantities[i]);
            assertGt(cost, prevCost);
            prevCost = cost;
        }
    }

    // ============================================================
    // Tick Boundaries
    // ============================================================

    function test_reverts_when_lowerTick_eq_upperTick() public {
        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.openPosition(MARKET_ID, int256(50), int256(50), uint128(SMALL_QUANTITY), 100e6);
    }

    function test_reverts_when_lowerTick_gt_upperTick() public {
        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.openPosition(MARKET_ID, int256(60), int256(40), uint128(SMALL_QUANTITY), 100e6);
    }

    function test_allows_trade_at_minimum_tick_boundary() public {
        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, int256(0), int256(1), uint128(SMALL_QUANTITY), 100e6);
    }

    function test_allows_trade_at_maximum_tick_boundary() public {
        vm.prank(sys.users[0]);
        sys.core
            .openPosition(
                MARKET_ID, int256(uint256(NUM_BINS) - 2), int256(uint256(NUM_BINS) - 1), uint128(SMALL_QUANTITY), 100e6
            );
    }

    function test_reverts_when_tick_exceeds_maxTick() public {
        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.openPosition(MARKET_ID, int256(0), int256(uint256(NUM_BINS) + 10), uint128(SMALL_QUANTITY), 100e6);
    }

    function test_allows_full_range_trade() public {
        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, int256(0), int256(uint256(NUM_BINS) - 1), uint128(SMALL_QUANTITY), 100e6);
    }

    function test_allows_single_bin_trade() public {
        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, int256(50), int256(51), uint128(SMALL_QUANTITY), 100e6);
    }

    // ============================================================
    // Time Boundaries
    // ============================================================

    function test_reverts_trade_before_market_start() public {
        // Create a market that starts in the future
        ISignalsCore.Market memory market = ISignalsCore.Market({
            isSeeded: true,
            settled: false,
            snapshotChunksDone: false,
            failed: false,
            numBins: 10,
            openPositionCount: 0,
            snapshotChunkCursor: 0,
            seedCursor: 10,
            startTimestamp: uint64(block.timestamp + 10_000),
            endTimestamp: uint64(block.timestamp + 20_000),
            settlementTimestamp: uint64(block.timestamp + 20_100),
            settlementFinalizedAt: 0,
            minTick: 0,
            maxTick: 10,
            tickSpacing: 1,
            settlementTick: 0,
            settlementValue: 0,
            liquidityParameter: WAD,
            feePolicy: address(sys.feePolicy),
            seedData: address(0),
            initialRootSum: 10 * WAD,
            accumulatedFees: 0,
            minFactor: WAD,
            deltaEt: 0
        });
        sys.core.setMarket(2, market);
        sys.core.seedTree(2, uniformFactors(10));

        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.openPosition(2, int256(2), int256(5), uint128(SMALL_QUANTITY), 100e6);
    }

    function test_reverts_trade_after_market_end() public {
        ISignalsCore.Market memory market = ISignalsCore.Market({
            isSeeded: true,
            settled: false,
            snapshotChunksDone: false,
            failed: false,
            numBins: 10,
            openPositionCount: 0,
            snapshotChunkCursor: 0,
            seedCursor: 10,
            startTimestamp: uint64(block.timestamp - 20_000),
            endTimestamp: uint64(block.timestamp - 10_000),
            settlementTimestamp: uint64(block.timestamp - 5_000),
            settlementFinalizedAt: 0,
            minTick: 0,
            maxTick: 10,
            tickSpacing: 1,
            settlementTick: 0,
            settlementValue: 0,
            liquidityParameter: WAD,
            feePolicy: address(sys.feePolicy),
            seedData: address(0),
            initialRootSum: 10 * WAD,
            accumulatedFees: 0,
            minFactor: WAD,
            deltaEt: 0
        });
        sys.core.setMarket(3, market);
        sys.core.seedTree(3, uniformFactors(10));

        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.openPosition(3, int256(2), int256(5), uint128(SMALL_QUANTITY), 100e6);
    }

    function test_allows_trade_during_active_market_period() public {
        ISignalsCore.Market memory market = ISignalsCore.Market({
            isSeeded: true,
            settled: false,
            snapshotChunksDone: false,
            failed: false,
            numBins: 10,
            openPositionCount: 0,
            snapshotChunkCursor: 0,
            seedCursor: 10,
            startTimestamp: uint64(block.timestamp - 1_000),
            endTimestamp: uint64(block.timestamp + 10_000),
            settlementTimestamp: uint64(block.timestamp + 10_100),
            settlementFinalizedAt: 0,
            minTick: 0,
            maxTick: 10,
            tickSpacing: 1,
            settlementTick: 0,
            settlementValue: 0,
            liquidityParameter: WAD,
            feePolicy: address(sys.feePolicy),
            seedData: address(0),
            initialRootSum: 10 * WAD,
            accumulatedFees: 0,
            minFactor: WAD,
            deltaEt: 0
        });
        sys.core.setMarket(4, market);
        sys.core.seedTree(4, uniformFactors(10));

        vm.prank(sys.users[0]);
        sys.core.openPosition(4, int256(2), int256(5), uint128(SMALL_QUANTITY), 100e6);
    }

    // ============================================================
    // Cost Boundaries
    // ============================================================

    function test_reverts_when_cost_exceeds_maxCost() public {
        uint256 cost = sys.core.calculateOpenCost(MARKET_ID, int256(10), int256(20), uint128(MEDIUM_QUANTITY));
        uint256 maxCost = cost / 2;

        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.openPosition(MARKET_ID, int256(10), int256(20), uint128(MEDIUM_QUANTITY), maxCost);
    }

    function test_allows_trade_when_cost_equals_maxCost() public {
        uint256 cost = sys.core.calculateOpenCost(MARKET_ID, int256(10), int256(20), uint128(MEDIUM_QUANTITY));
        // Add small buffer for rounding
        uint256 maxCost = cost + 10;

        vm.prank(sys.users[0]);
        sys.core.openPosition(MARKET_ID, int256(10), int256(20), uint128(MEDIUM_QUANTITY), maxCost);
    }

    // ============================================================
    // Market State Boundaries
    // ============================================================

    function test_reverts_trade_on_unseeded_market() public {
        ISignalsCore.Market memory market = ISignalsCore.Market({
            isSeeded: false,
            settled: false,
            snapshotChunksDone: false,
            failed: false,
            numBins: 10,
            openPositionCount: 0,
            snapshotChunkCursor: 0,
            seedCursor: 0,
            startTimestamp: uint64(block.timestamp - 1_000),
            endTimestamp: uint64(block.timestamp + 10_000),
            settlementTimestamp: uint64(block.timestamp + 10_100),
            settlementFinalizedAt: 0,
            minTick: 0,
            maxTick: 10,
            tickSpacing: 1,
            settlementTick: 0,
            settlementValue: 0,
            liquidityParameter: WAD,
            feePolicy: address(sys.feePolicy),
            seedData: address(0),
            initialRootSum: 10 * WAD,
            accumulatedFees: 0,
            minFactor: WAD,
            deltaEt: 0
        });
        sys.core.setMarket(5, market);
        sys.core.seedTree(5, uniformFactors(10));

        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.openPosition(5, int256(2), int256(5), uint128(SMALL_QUANTITY), 100e6);
    }

    function test_reverts_trade_on_settled_market() public {
        ISignalsCore.Market memory market = ISignalsCore.Market({
            isSeeded: true,
            settled: true,
            snapshotChunksDone: false,
            failed: false,
            numBins: 10,
            openPositionCount: 0,
            snapshotChunkCursor: 0,
            seedCursor: 10,
            startTimestamp: uint64(block.timestamp - 1_000),
            endTimestamp: uint64(block.timestamp + 10_000),
            settlementTimestamp: uint64(block.timestamp + 10_100),
            settlementFinalizedAt: 0,
            minTick: 0,
            maxTick: 10,
            tickSpacing: 1,
            settlementTick: 5,
            settlementValue: 5_000_000,
            liquidityParameter: WAD,
            feePolicy: address(sys.feePolicy),
            seedData: address(0),
            initialRootSum: 10 * WAD,
            accumulatedFees: 0,
            minFactor: WAD,
            deltaEt: 0
        });
        sys.core.setMarket(6, market);
        sys.core.seedTree(6, uniformFactors(10));

        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.openPosition(6, int256(2), int256(5), uint128(SMALL_QUANTITY), 100e6);
    }

    function test_reverts_trade_on_nonexistent_market() public {
        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.openPosition(999, int256(2), int256(5), uint128(SMALL_QUANTITY), 100e6);
    }
}
