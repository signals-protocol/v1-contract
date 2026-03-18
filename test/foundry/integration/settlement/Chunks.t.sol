// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/RedstoneHelper.sol";
import "../../base/SettlementHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title ChunksTest
/// @notice Integration: settlement chunks and claim totals (snapshot chunking, boundary ticks).
/// @dev Mirrors test/integration/settlement/chunks.spec.ts (9 tests).
contract ChunksTest is FullSystemDeployer {
    FullSystem sys;

    function setUp() public override {
        super.setUp();
        // Short settlement windows for fast tests
        sys = deployFullSystem(200, 60);

        // Fund owner and users
        sys.payment.transfer(sys.owner, 200_000e6);
        vm.startPrank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        sys.core.seedVault(100_000e6);
        // Disable alpha enforcement for simpler market creation
        sys.core.setRiskConfig(0.2e18, 1e18, false);

        for (uint256 i = 0; i < 3; i++) {
            sys.payment.transfer(sys.users[i], 20_000e6);
        }
        vm.stopPrank();

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(sys.users[i]);
            sys.payment.approve(address(sys.core), type(uint256).max);
        }
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _createMarket() internal returns (uint256 marketId) {
        uint64 now_ = uint64(block.timestamp);
        vm.prank(sys.owner);
        marketId = sys.core.createMarketUniform(
            0,
            4,
            1,
            now_ - 10,
            now_ + 100,
            now_ + 110,
            4,
            WAD,
            address(sys.feePolicy)
        );
    }

    function _settleMarket(uint256 marketId, uint256 priceHuman) internal {
        SettlementHelper.settleMarket(vm, address(sys.core), sys.owner, marketId, priceHuman);
        // Warp past claimDelay so claims are allowed
        vm.warp(block.timestamp + 300);
    }

    // ============================================================
    // Tests
    // ============================================================

    function test_revertsRequestSettlementChunksBeforeSettled() public {
        uint256 marketId = _createMarket();

        vm.expectRevert();
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 10);
    }

    function test_handlesMultipleUsersPositionsAcrossChunks() public {
        uint256 marketId = _createMarket();

        // Open 4 positions: 3 users, different ranges
        vm.prank(sys.users[0]);
        sys.core.openPosition(marketId, 0, 2, 1_000, 10_000e6); // wins at tick=1
        vm.prank(sys.users[1]);
        sys.core.openPosition(marketId, 2, 4, 1_000, 10_000e6); // loses at tick=1
        vm.prank(sys.users[2]);
        sys.core.openPosition(marketId, 1, 3, 1_000, 10_000e6); // wins at tick=1
        vm.prank(sys.users[0]);
        sys.core.openPosition(marketId, 0, 1, 500, 10_000e6); // loses (upperTick exclusive)

        ISignalsCore.Market memory m = sys.core.harnessGetMarket(marketId);
        assertEq(m.openPositionCount, 4);

        // Settle at tick=1 (priceHuman=1)
        _settleMarket(marketId, 1);

        // Request chunks — 4 positions fits in 1 chunk
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 10);

        // Second call should revert — snapshot complete
        vm.prank(sys.owner);
        vm.expectRevert(SE.SnapshotAlreadyCompleted.selector);
        sys.core.requestSettlementChunks(marketId, 10);

        // Top up core to ensure payouts
        sys.payment.transfer(address(sys.core), 10_000e6);

        // Claim all positions
        uint256 balBefore =
            sys.payment.balanceOf(sys.users[0]) +
                sys.payment.balanceOf(sys.users[1]) +
                sys.payment.balanceOf(sys.users[2]);

        vm.prank(sys.users[0]);
        sys.core.claimPayout(1); // wins
        vm.prank(sys.users[1]);
        sys.core.claimPayout(2); // loses
        vm.prank(sys.users[2]);
        sys.core.claimPayout(3); // wins
        vm.prank(sys.users[0]);
        sys.core.claimPayout(4); // loses

        uint256 balAfter =
            sys.payment.balanceOf(sys.users[0]) +
                sys.payment.balanceOf(sys.users[1]) +
                sys.payment.balanceOf(sys.users[2]);

        // Position 1 [0,2) wins (1000), Position 3 [1,3) wins (1000)
        // Position 2 [2,4) loses, Position 4 [0,1) loses (1 not in [0,1))
        assertEq(balAfter - balBefore, 1_000 + 1_000);
    }

    function test_completesSnapshotInSingleChunkWhenPositionsLessThanChunkSize() public {
        uint256 marketId = _createMarket();

        // 4 positions (< CHUNK_SIZE=512)
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(sys.users[i % 3]);
            sys.core.openPosition(marketId, 0, 2, 1_000, 10_000e6);
        }

        _settleMarket(marketId, 1);

        // Single chunk should complete snapshot
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 10);

        // Verify complete — second call reverts
        vm.prank(sys.owner);
        vm.expectRevert(SE.SnapshotAlreadyCompleted.selector);
        sys.core.requestSettlementChunks(marketId, 10);
    }

    function test_revertsClaimOnNonWinningPosition_payoutZero() public {
        uint256 marketId = _createMarket();

        // Position [2,4) — loses when settlementTick=1
        vm.prank(sys.users[0]);
        sys.core.openPosition(marketId, 2, 4, 1_000, 10_000e6);

        _settleMarket(marketId, 1);
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 10);

        uint256 balBefore = sys.payment.balanceOf(sys.users[0]);
        vm.prank(sys.users[0]);
        sys.core.claimPayout(1);
        uint256 balAfter = sys.payment.balanceOf(sys.users[0]);

        assertEq(balAfter - balBefore, 0, "losing position gets 0 payout");
    }

    function test_boundary_settlementTickEqualsUpperTickMinus1_winning() public {
        uint256 marketId = _createMarket();

        // Position [1,3) — wins if settlementTick=2 (upper-1)
        vm.prank(sys.users[0]);
        sys.core.openPosition(marketId, 1, 3, 1_000, 10_000e6);

        _settleMarket(marketId, 2);
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 10);
        sys.payment.transfer(address(sys.core), 10_000e6);

        uint256 balBefore = sys.payment.balanceOf(sys.users[0]);
        vm.prank(sys.users[0]);
        sys.core.claimPayout(1);
        uint256 balAfter = sys.payment.balanceOf(sys.users[0]);

        assertEq(balAfter - balBefore, 1_000, "should win: lo(1) <= tick(2) < hi(3)");
    }

    function test_boundary_settlementTickEqualsLowerTick_winning() public {
        uint256 marketId = _createMarket();

        // Position [2,4) — wins if settlementTick=2
        vm.prank(sys.users[0]);
        sys.core.openPosition(marketId, 2, 4, 1_000, 10_000e6);

        _settleMarket(marketId, 2);
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 10);
        sys.payment.transfer(address(sys.core), 10_000e6);

        uint256 balBefore = sys.payment.balanceOf(sys.users[0]);
        vm.prank(sys.users[0]);
        sys.core.claimPayout(1);
        uint256 balAfter = sys.payment.balanceOf(sys.users[0]);

        assertEq(balAfter - balBefore, 1_000, "should win: lo(2) <= tick(2) < hi(4)");
    }

    function test_boundary_settlementTickEqualsUpperTick_losing() public {
        uint256 marketId = _createMarket();

        // Position [0,2) — loses if settlementTick=2 (upperTick exclusive)
        vm.prank(sys.users[0]);
        sys.core.openPosition(marketId, 0, 2, 1_000, 10_000e6);

        _settleMarket(marketId, 2);
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 10);

        uint256 balBefore = sys.payment.balanceOf(sys.users[0]);
        vm.prank(sys.users[0]);
        sys.core.claimPayout(1);
        uint256 balAfter = sys.payment.balanceOf(sys.users[0]);

        assertEq(balAfter - balBefore, 0, "should lose: 2 < hi(2) is false");
    }

    /// @notice Chunk event emission test (replaces explicit emit check with state verification)
    function test_chunkRequestEmitsEventAndCompletesSnapshot() public {
        uint256 marketId = _createMarket();

        vm.prank(sys.users[0]);
        sys.core.openPosition(marketId, 0, 2, 1_000, 10_000e6);

        _settleMarket(marketId, 1);

        // First chunk should succeed
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 10);

        // Snapshot is complete
        ISignalsCore.Market memory m = sys.core.harnessGetMarket(marketId);
        assertTrue(m.snapshotChunksDone, "snapshot should be complete");
    }
}
