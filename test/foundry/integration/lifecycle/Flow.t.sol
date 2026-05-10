// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/RedstoneHelper.sol";
import "../../base/SettlementHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {MarketLifecycleModule} from "../../../../contracts/modules/MarketLifecycleModule.sol";
import {VaultHelper} from "../../base/VaultHelper.sol";

/// @title Lifecycle Flow Integration Tests
/// @notice Full market lifecycle from creation to settlement (6 tests from flow.spec.ts)
contract FlowTest is FullSystemDeployer {
    FullSystem internal sys;
    address internal user;
    uint64 internal submitWindow;
    uint64 internal opsWindow;

    function setUp() public override {
        super.setUp();
        submitWindow = 300;
        opsWindow = 60;
        sys = deployFullSystem(submitWindow, opsWindow);
        user = sys.users[0];

        // Fund user
        sys.payment.mint(user, 10_000_000);
        vm.prank(user);
        sys.payment.approve(address(sys.core), type(uint256).max);
    }

    /// @notice Helper to create a 4-bin market starting in the past
    function _createMarket() internal returns (uint256 marketId) {
        uint64 start = uint64(block.timestamp - 50);
        uint64 end = uint64(block.timestamp + 200);
        uint64 settlementTs = end + 10;

        vm.prank(sys.owner);
        marketId = sys.core.createMarketUniform(0, 4, 1, start, end, settlementTs, 4, 1e18, address(sys.feePolicy));
    }

    function test_create_trade_settlement_snapshot_claim_flow() public {
        uint256 marketId = _createMarket();

        // Open position
        uint256 positionId = sys.position.nextId();
        vm.prank(user);
        sys.core.openPosition(marketId, int256(0), int256(4), uint128(1_000), 5_000_000);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertEq(market.openPositionCount, 1);

        // Get settlement windows
        (uint64 tSet, uint64 settleEnd,,) = sys.core.getSettlementWindows(marketId);

        // Submit oracle price after Tset
        uint256 priceTimestamp = tSet + 5;
        vm.warp(priceTimestamp + 1);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, marketId, 2, priceTimestamp);

        // Finalize after PendingOps starts
        vm.warp(settleEnd);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(marketId);

        market = sys.core.harnessGetMarket(marketId);
        assertTrue(market.settled);
        assertFalse(market.snapshotChunksDone);

        // Request settlement chunks
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);

        market = sys.core.harnessGetMarket(marketId);
        assertTrue(market.snapshotChunksDone);

        // Claim payout
        (,,, uint64 claimOpen) = sys.core.getSettlementWindows(marketId);
        vm.warp(claimOpen);

        uint256 balBefore = sys.payment.balanceOf(user);
        vm.prank(user);
        sys.core.claimPayout(positionId);
        uint256 balAfter = sys.payment.balanceOf(user);

        assertEq(balAfter - balBefore, 1_000);
        assertFalse(sys.position.exists(positionId));
    }

    function test_burns_loser_positions_and_prevents_double_claim() public {
        uint256 marketId = _createMarket();

        // Open two positions: one winner (full range), one loser (upper only)
        uint256 pos1 = sys.position.nextId();
        vm.prank(user);
        sys.core.openPosition(marketId, int256(0), int256(4), uint128(1_000), 5_000_000);

        uint256 pos2 = sys.position.nextId();
        vm.prank(user);
        sys.core.openPosition(marketId, int256(3), int256(4), uint128(1_000), 5_000_000);

        // Settle at tick 1
        (uint64 tSet, uint64 settleEnd,,) = sys.core.getSettlementWindows(marketId);
        uint256 priceTimestamp = tSet + 5;
        vm.warp(priceTimestamp + 1);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, marketId, 1, priceTimestamp);

        vm.warp(settleEnd);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(marketId);

        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);

        // Claim both
        (,,, uint64 claimOpen) = sys.core.getSettlementWindows(marketId);
        vm.warp(claimOpen);

        uint256 balBefore = sys.payment.balanceOf(user);
        vm.prank(user);
        sys.core.claimPayout(pos1);
        vm.prank(user);
        sys.core.claimPayout(pos2);
        uint256 balAfter = sys.payment.balanceOf(user);

        // Loser payout is zero, so total equals winner's payout
        assertEq(balAfter - balBefore, 1_000);
        assertFalse(sys.position.exists(pos1));
        assertFalse(sys.position.exists(pos2));

        // Double claim reverts
        vm.prank(user);
        vm.expectRevert();
        sys.core.claimPayout(pos1);
    }

    function test_enforces_time_gates() public {
        uint64 start = uint64(block.timestamp + 100);
        uint64 end = start + 100;
        uint64 settlementTs = end + 50;

        vm.prank(sys.owner);
        uint256 marketId =
            sys.core.createMarketUniform(0, 4, 1, start, end, settlementTs, 4, 1e18, address(sys.feePolicy));

        // Too early to trade
        vm.prank(user);
        vm.expectRevert();
        sys.core.openPosition(marketId, int256(0), int256(4), uint128(1_000), 5_000_000);

        // Advance to active period
        vm.warp(start + 1);
        uint256 positionId = sys.position.nextId();
        vm.prank(user);
        sys.core.openPosition(marketId, int256(0), int256(4), uint128(1_000), 5_000_000);

        // After endTimestamp, trading should revert
        vm.warp(end + 1);
        vm.prank(user);
        vm.expectRevert();
        sys.core.increasePosition(positionId, uint128(1_000), 5_000_000);

        // Settlement too early
        vm.prank(sys.owner);
        vm.expectRevert();
        sys.core.finalizePrimarySettlement(marketId);

        // Submit settlement after Tset
        uint256 priceTimestamp = settlementTs + 10;
        vm.warp(priceTimestamp + 1);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, marketId, 1, priceTimestamp);

        // Finalize during PendingOps
        vm.warp(settlementTs + submitWindow + 1);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(marketId);

        // Claim too early
        vm.prank(user);
        vm.expectRevert();
        sys.core.claimPayout(positionId);

        // Advance past claim delay
        vm.warp(settlementTs + submitWindow + opsWindow + 1);

        // Need to process settlement chunks first
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);

        vm.prank(user);
        sys.core.claimPayout(positionId);
    }
}
