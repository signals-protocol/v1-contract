// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/TradeModuleDeployer.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {ISignalsCore} from "../../../../contracts/interfaces/ISignalsCore.sol";

/// @title TradeModule Slippage Foundry Tests
/// @notice Converted from test/module/trade/slippage.spec.ts (5 tests)
contract SlippageTest is TradeModuleDeployer {
    TradeModuleSystem sys;

    function setUp() public override {
        super.setUp();
        sys = deployMinimalTradeSystem();
    }

    // ============================================================
    // Test: reverts open when cost exceeds maxCost near boundary
    // ============================================================

    function test_revertsOpenWhenCostExceedsMaxCost() public {
        address user = sys.users[0];

        // Calculate exact cost
        uint256 quote = sys.core.calculateOpenCost(1, 0, 4, 1_000);

        // maxCost = quote - 1 should revert
        vm.prank(user);
        vm.expectRevert(); // CostExceedsMaximum
        sys.core.openPosition(1, 0, 4, 1_000, quote - 1);

        // maxCost = quote + 1000 should succeed
        vm.prank(user);
        sys.core.openPosition(1, 0, 4, 1_000, quote + 1_000);
    }

    // ============================================================
    // Test: reverts decrease when proceeds fall below minProceeds
    // ============================================================

    function test_revertsDecreaseWhenProceedsBelowMinProceeds() public {
        address user = sys.users[0];

        vm.prank(user);
        sys.core.openPosition(1, 0, 4, 2_000, 10_000_000);

        uint256 quote = sys.core.calculateDecreaseProceeds(1, 1_000);

        // minProceeds = quote + 1 should revert
        vm.prank(user);
        vm.expectRevert(); // ProceedsBelowMinimum
        sys.core.decreasePosition(1, 1_000, quote + 1);

        // minProceeds = quote should succeed
        vm.prank(user);
        sys.core.decreasePosition(1, 1_000, quote);
    }

    // ============================================================
    // Test: reverts increase when cost exceeds maxCost
    // ============================================================

    function test_revertsIncreaseWhenCostExceedsMaxCost() public {
        address user = sys.users[0];

        vm.prank(user);
        sys.core.openPosition(1, 0, 4, 1_000, 10_000_000);

        // maxCost = 0 should revert
        vm.prank(user);
        vm.expectRevert(); // CostExceedsMaximum
        sys.core.increasePosition(1, 500, 0);

        // Large maxCost should succeed
        vm.prank(user);
        sys.core.increasePosition(1, 500, 10_000_000);
    }

    // ============================================================
    // Test: reverts close when proceeds fall below minProceeds
    // ============================================================

    function test_revertsCloseWhenProceedsBelowMinProceeds() public {
        address user = sys.users[0];

        vm.prank(user);
        sys.core.openPosition(1, 0, 4, 1_000, 10_000_000);

        // Impossibly high minProceeds should revert
        vm.prank(user);
        vm.expectRevert(); // ProceedsBelowMinimum
        sys.core.closePosition(1, type(uint256).max);

        // 0 minProceeds should succeed
        vm.prank(user);
        sys.core.closePosition(1, 0);
    }

    // ============================================================
    // Test: rejects trades on settled market
    // ============================================================

    function test_rejectsTradesOnSettledMarket() public {
        address user = sys.users[0];

        // Update market to settled state
        uint64 now_ = uint64(block.timestamp);
        ISignalsCore.Market memory settledMarket = ISignalsCore.Market({
            isSeeded: true,
            settled: true,
            snapshotChunksDone: false,
            failed: false,
            numBins: 4,
            openPositionCount: 0,
            snapshotChunkCursor: 0,
            seedCursor: 4,
            startTimestamp: now_ - 10,
            endTimestamp: now_ + 1_000,
            settlementTimestamp: now_ + 1_100,
            settlementFinalizedAt: 0,
            minTick: 0,
            maxTick: 4,
            tickSpacing: 1,
            settlementTick: 0,
            settlementValue: 0,
            liquidityParameter: WAD,
            feePolicy: address(sys.feePolicy),
            seedData: address(0),
            initialRootSum: 4 * WAD,
            accumulatedFees: 0,
            minFactor: WAD,
            deltaEt: 0
        });
        sys.core.setMarket(1, settledMarket);

        vm.prank(user);
        vm.expectRevert();
        sys.core.openPosition(1, 0, 4, 1_000, 1_000_000);
    }
}
