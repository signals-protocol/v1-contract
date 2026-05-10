// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/RedstoneHelper.sol";
import "../../base/SeedHelper.sol";

/// @title Failure Path E2E Test
/// @notice 1 test: marks failed → secondary settlement → claim payout
contract FailurePathTest is FullSystemDeployer {
    FullSystem internal sys;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(5, 5);
    }

    function test_marks_failed_settles_secondary_and_claims() public {
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

        // Create market
        uint64 start = uint64(block.timestamp - 5);
        uint64 end = uint64(block.timestamp + 50);
        uint64 settlement = uint64(block.timestamp + 60);

        vm.prank(sys.owner);
        uint256 marketId = sys.core.createMarketUniform(0, 4, 1, start, end, settlement, 4, WAD, address(sys.feePolicy));

        // Open position
        uint128 quantity = 1_000;
        uint256 openCost = sys.core.calculateOpenCost(marketId, 1, 3, quantity);
        uint256 positionId = sys.position.nextId();
        vm.prank(trader);
        sys.core.openPosition(marketId, 1, 3, quantity, openCost + 1_000_000);

        // Fast-forward past settlement + submit window
        vm.warp(settlement + 5 + 1);

        // Mark settlement failed
        vm.prank(sys.owner);
        sys.core.markSettlementFailed(marketId);

        // Finalize secondary settlement with value = tick 2
        int256 settlementValue = RedstoneHelper.toSettlementValue(2);
        vm.prank(sys.owner);
        sys.core.finalizeSecondarySettlement(marketId, settlementValue);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertFalse(market.failed);
        assertTrue(market.settled);

        // Process settlement chunks
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);

        // Claim payout
        (,,, uint64 claimOpen) = sys.core.getSettlementWindows(marketId);
        vm.warp(claimOpen);

        uint256 balanceBefore = sys.payment.balanceOf(trader);
        vm.prank(trader);
        sys.core.claimPayout(positionId);
        uint256 balanceAfter = sys.payment.balanceOf(trader);
        assertGt(balanceAfter, balanceBefore);
    }
}
