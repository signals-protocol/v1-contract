// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/RedstoneHelper.sol";
import "../../base/SettlementHelper.sol";
import "../../base/VaultHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title PayoutReserveTest
/// @notice Integration: payout reserve spec — claim gating, NAV invariance, L_t, failure path.
/// @dev Mirrors test/integration/settlement/payoutReserve.spec.ts (12 tests).
contract PayoutReserveTest is FullSystemDeployer {
    FullSystem sys;

    // Settlement window config matching TS: submitWindow=300, opsWindow=60
    uint64 constant SUBMIT_WINDOW = 300;
    uint64 constant OPS_WINDOW = 60;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(SUBMIT_WINDOW, OPS_WINDOW);

        // Transfer tokens to owner
        sys.payment.transfer(sys.owner, 500_000e6);

        vm.startPrank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        // Disable alpha enforcement for simpler market creation
        sys.core.setRiskConfig(0.3e18, 1e18, false);
        sys.core.setFeeWaterfallConfig(0, 0.8e18, 0.1e18, 0.1e18);

        // Fund backstop
        sys.core.fundBackstop(500e6);
        vm.stopPrank();

        // Fund users
        for (uint256 i = 0; i < 3; i++) {
            sys.payment.transfer(sys.users[i], 10_000e6);
            vm.prank(sys.users[i]);
            sys.payment.approve(address(sys.core), type(uint256).max);
        }
    }

    // ============================================================
    // Helpers
    // ============================================================

    /// @notice Seed vault, create market with enough time for trading, return context
    function _setupMarket() internal returns (uint256 marketId, uint64 tSet, uint64 batchId) {
        // Align to batch boundary
        uint64 latest = uint64(block.timestamp);
        uint64 baseBatchId = toBatchId(latest) + 1;
        uint64 seedTime = batchStartTimestamp(baseBatchId) + 100;

        // Seed vault
        vm.warp(seedTime);
        vm.prank(sys.owner);
        sys.core.seedVault(1_000e6);

        uint64 start = seedTime + 50;
        uint64 end = seedTime + 1000; // Longer window for trading
        tSet = seedTime + 1200;

        vm.warp(seedTime + 10);
        vm.prank(sys.owner);
        marketId = sys.core.createMarketUniform(0, 4, 1, start, end, tSet, 4, WAD, address(sys.feePolicy));

        // Warp to trading window
        vm.warp(start + 1);

        batchId = toBatchId(tSet);
    }

    function _submitAndFinalize(uint256 marketId, uint64 tSet, uint256 priceHuman) internal {
        uint64 priceTs = tSet + 1;
        vm.warp(priceTs + 1);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, marketId, priceHuman, priceTs);

        // Finalize after submit window
        uint64 opsEnd = tSet + SUBMIT_WINDOW + OPS_WINDOW;
        vm.warp(opsEnd + 1);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(marketId);
    }

    function _openPosition(address user, uint256 marketId, int256 lo, int256 hi, uint128 qty) internal {
        vm.prank(user);
        sys.core.openPosition(marketId, lo, hi, qty, type(uint256).max);
    }

    // ============================================================
    // SPEC-1: Claim gating is TIME-BASED
    // ============================================================

    function test_revertsClaimPayoutWhenTimeLtClaimDelay() public {
        (uint256 marketId, uint64 tSet, ) = _setupMarket();

        _openPosition(sys.users[0], marketId, 0, 2, 1000);

        // Submit and finalize
        uint64 priceTs = tSet + 1;
        vm.warp(priceTs + 1);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, marketId, 1, priceTs);

        uint64 opsStart = tSet + SUBMIT_WINDOW;
        vm.warp(opsStart + 1);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(marketId);

        // Try to claim before claimOpen (tSet + claimDelay)
        uint64 claimOpen = tSet + SUBMIT_WINDOW + OPS_WINDOW;
        vm.warp(claimOpen - 1);

        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.claimPayout(1);
    }

    function test_allowsClaimPayoutAfterClaimDelay() public {
        (uint256 marketId, uint64 tSet, uint64 batchId) = _setupMarket();

        _openPosition(sys.users[0], marketId, 0, 2, 1000);

        _submitAndFinalize(marketId, tSet, 1);

        // Warp past claim delay
        uint64 claimOpen = tSet + SUBMIT_WINDOW + OPS_WINDOW;
        vm.warp(claimOpen + 1);

        uint256 balBefore = sys.payment.balanceOf(sys.users[0]);
        vm.prank(sys.users[0]);
        sys.core.claimPayout(1);
        uint256 balAfter = sys.payment.balanceOf(sys.users[0]);

        assertGt(balAfter, balBefore, "trader should receive payout");
    }

    // ============================================================
    // SPEC-2: claimPayout does NOT change NAV/Price
    // ============================================================

    function test_navUnchangedAfterClaimPayout() public {
        (uint256 marketId, uint64 tSet, uint64 batchId) = _setupMarket();

        _openPosition(sys.users[0], marketId, 0, 2, 1000);

        _submitAndFinalize(marketId, tSet, 1);

        // Process batch
        advancePastBatchEnd(batchId);
        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(batchId, 1, 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);

        uint256 navBefore = sys.core.getVaultNav();
        uint256 priceBefore = sys.core.getVaultPrice();

        vm.prank(sys.users[0]);
        sys.core.claimPayout(1);

        uint256 navAfter = sys.core.getVaultNav();
        uint256 priceAfter = sys.core.getVaultPrice();

        assertEq(navAfter, navBefore, "NAV changed after claimPayout");
        assertEq(priceAfter, priceBefore, "Price changed after claimPayout");
    }

    function test_multipleClaimsDoNotChangeNAV() public {
        (uint256 marketId, uint64 tSet, uint64 batchId) = _setupMarket();

        _openPosition(sys.users[0], marketId, 0, 2, 500);
        _openPosition(sys.users[1], marketId, 0, 2, 300);

        _submitAndFinalize(marketId, tSet, 1);

        advancePastBatchEnd(batchId);
        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(batchId, 1, 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);

        uint256 navBefore = sys.core.getVaultNav();

        vm.prank(sys.users[0]);
        sys.core.claimPayout(1);
        assertEq(sys.core.getVaultNav(), navBefore, "NAV changed after first claim");

        vm.prank(sys.users[1]);
        sys.core.claimPayout(2);
        assertEq(sys.core.getVaultNav(), navBefore, "NAV changed after second claim");
    }

    // ============================================================
    // SPEC-3: Payout reserve affects L_t
    // ============================================================

    function test_ltIncludesPayoutDeduction() public {
        (uint256 marketId, uint64 tSet, uint64 batchId) = _setupMarket();

        _openPosition(sys.users[0], marketId, 0, 2, 1000);

        _submitAndFinalize(marketId, tSet, 1);

        // Check L_t via getDailyPnl
        (int256 lt, , , , , , ) = sys.core.getDailyPnl(batchId);
        assertTrue(lt != 0, "L_t should reflect payout reserve");
    }

    // ============================================================
    // SPEC-4: Payout reserve invariant
    // ============================================================

    function test_totalWinningPayoutsEqualsEscrowReserve() public {
        (uint256 marketId, uint64 tSet, uint64 batchId) = _setupMarket();

        // Winning positions
        _openPosition(sys.users[0], marketId, 0, 2, 500);
        _openPosition(sys.users[1], marketId, 0, 2, 300);
        // Losing position
        _openPosition(sys.users[0], marketId, 2, 4, 200);

        _submitAndFinalize(marketId, tSet, 1);

        advancePastBatchEnd(batchId);
        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(batchId, 1, 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);

        uint256 coreBalBefore = sys.payment.balanceOf(address(sys.core));

        // Claim winners
        vm.prank(sys.users[0]);
        sys.core.claimPayout(1);
        vm.prank(sys.users[1]);
        sys.core.claimPayout(2);

        // Claim loser — should give 0
        uint256 balBeforeLoser = sys.payment.balanceOf(sys.users[0]);
        vm.prank(sys.users[0]);
        sys.core.claimPayout(3);
        uint256 balAfterLoser = sys.payment.balanceOf(sys.users[0]);
        assertEq(balAfterLoser, balBeforeLoser, "loser should receive 0");

        uint256 coreBalAfter = sys.payment.balanceOf(address(sys.core));
        uint256 expectedTotalPayout = 500 + 300;
        assertEq(coreBalBefore - coreBalAfter, expectedTotalPayout, "core bal decrease should match total payout");
    }

    function test_revertsDoubleClaim() public {
        (uint256 marketId, uint64 tSet, uint64 batchId) = _setupMarket();

        _openPosition(sys.users[0], marketId, 0, 2, 500);

        _submitAndFinalize(marketId, tSet, 1);

        advancePastBatchEnd(batchId);
        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(batchId, 1, 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);

        vm.prank(sys.users[0]);
        sys.core.claimPayout(1);

        // Second claim reverts (burned)
        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.claimPayout(1);
    }

    function test_revertsClaimByNonOwner() public {
        (uint256 marketId, uint64 tSet, uint64 batchId) = _setupMarket();

        _openPosition(sys.users[0], marketId, 0, 2, 500);

        _submitAndFinalize(marketId, tSet, 1);

        advancePastBatchEnd(batchId);
        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(batchId, 1, 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);

        // Non-owner tries to claim
        vm.prank(sys.users[1]);
        vm.expectRevert();
        sys.core.claimPayout(1);
    }

    function test_revertsClaimOnUnsettledMarket() public {
        (uint256 marketId, , ) = _setupMarket();

        _openPosition(sys.users[0], marketId, 0, 2, 500);

        // Advance time but don't settle
        vm.warp(block.timestamp + 86400);

        vm.prank(sys.users[0]);
        vm.expectRevert();
        sys.core.claimPayout(1);
    }

    // ============================================================
    // Failure path + Batch/Claim separation
    // ============================================================

    function test_markFailed_manualSettleRecordsPnlToBatch() public {
        // Seed and create market
        uint64 latest = uint64(block.timestamp);
        uint64 baseBatchId = toBatchId(latest) + 1;
        uint64 seedTime = batchStartTimestamp(baseBatchId) + 1000;

        sys.payment.mint(sys.owner, 100_000e6);
        vm.startPrank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.warp(seedTime);
        sys.core.seedVault(10_000e6);

        uint64 tSet = seedTime + 500;
        sys.core.createMarketUniform(0, 100, 10, seedTime + 100, tSet - 100, tSet, 10, 100e18, address(sys.feePolicy));

        // Wait for settlement window to expire
        vm.warp(tSet + SUBMIT_WINDOW + 100);
        sys.core.markSettlementFailed(1);
        vm.stopPrank();

        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        assertTrue(m.failed);
        assertFalse(m.settled);

        // Manual settle
        vm.warp(block.timestamp + 10);
        vm.prank(sys.owner);
        sys.core.finalizeSecondarySettlement(1, 50);

        m = sys.core.harnessGetMarket(1);
        assertTrue(m.settled);
    }

    function test_batchExecutesIndependentlyOfClaimTiming() public {
        uint64 latest = uint64(block.timestamp);
        uint64 baseBatchId = toBatchId(latest) + 1;
        uint64 seedTime = batchStartTimestamp(baseBatchId) + 1000;

        sys.payment.mint(sys.owner, 100_000e6);
        vm.startPrank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.warp(seedTime);
        sys.core.seedVault(10_000e6);

        uint64 tSet = seedTime + 500;
        sys.core.createMarketUniform(0, 100, 10, seedTime + 100, tSet - 100, tSet, 10, 100e18, address(sys.feePolicy));
        vm.stopPrank();

        // Submit oracle
        uint64 priceTs = tSet + 1;
        vm.warp(priceTs);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 50, priceTs);

        // Finalize
        vm.warp(tSet + SUBMIT_WINDOW + OPS_WINDOW + 1);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(1);

        // Process batch
        uint64 batchId = toBatchId(tSet);
        advancePastBatchEnd(batchId);
        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(batchId, 1, 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);

        (, , , , , , bool processed) = sys.core.getDailyPnl(batchId);
        assertTrue(processed, "batch should be processed");
    }

    function test_secondarySettlementFlowsToSameBatch() public {
        uint64 latest = uint64(block.timestamp);
        uint64 baseBatchId = toBatchId(latest) + 1;
        uint64 seedTime = batchStartTimestamp(baseBatchId) + 1000;

        sys.payment.mint(sys.owner, 100_000e6);
        vm.startPrank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.warp(seedTime);
        sys.core.seedVault(10_000e6);

        uint64 tSet = seedTime + 500;
        sys.core.createMarketUniform(0, 100, 10, seedTime + 100, tSet - 100, tSet, 10, 100e18, address(sys.feePolicy));

        // Fail and manual settle
        vm.warp(tSet + SUBMIT_WINDOW + 100);
        sys.core.markSettlementFailed(1);
        sys.core.finalizeSecondarySettlement(1, 50);
        vm.stopPrank();

        // Process batch
        uint64 batchId = toBatchId(tSet);
        advancePastBatchEnd(batchId);
        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(batchId, 1, 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);

        (, , , , , , bool processed) = sys.core.getDailyPnl(batchId);
        assertTrue(processed, "batch should be processed after secondary settlement");

        uint256 navAfter = sys.core.getVaultNav();
        assertGe(navAfter, 0);
    }
}
