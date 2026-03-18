// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/VaultHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {LPVaultModule} from "../../../../contracts/modules/LPVaultModule.sol";

/// @title LPVaultModule Core Flow Tests
/// @notice Foundry conversion of test/module/vault/lpVaultModule.spec.ts (core flows)
/// @dev Uses FullSystemDeployer with SignalsCoreHarness for delegatecall vault operations
contract LPVaultModuleTest is FullSystemDeployer {
    FullSystem sys;

    address userA;
    address userB;
    address userC;

    uint64 currentBatchId;
    uint64 firstBatchId;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();

        userA = sys.users[0];
        userB = sys.users[1];
        userC = sys.users[2];

        // Mint tokens to users (6 decimals)
        sys.payment.mint(userA, _usdc(100_000));
        sys.payment.mint(userB, _usdc(100_000));
        sys.payment.mint(userC, _usdc(100_000));

        // Approve core for all users
        vm.prank(userA);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(userB);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(userC);
        sys.payment.approve(address(sys.core), type(uint256).max);
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _usdc(uint256 amount) internal pure returns (uint256) {
        return amount * 1e6;
    }

    function _wad(uint256 amount) internal pure returns (uint256) {
        return amount * 1e18;
    }

    /// @dev Seed vault with 1000 tokens from userA, set currentBatchId/firstBatchId
    function _seedVault() internal {
        vm.prank(userA);
        sys.core.seedVault(_usdc(1000));
        currentBatchId = sys.core.getCurrentBatchId();
        firstBatchId = currentBatchId + 1;
    }

    /// @dev Record PnL and process a batch through the harness
    function _recordPnlAndProcess(uint64 batchId, int256 lt, uint256 ftot, uint256 deltaEt) internal {
        vm.startPrank(sys.owner);
        sys.core.harnessRecordPnl(batchId, lt, ftot, deltaEt);
        vm.stopPrank();
        // VaultHelper handles warp + batch market state + processDailyBatch
        VaultHelper.processBatch(vm, address(sys.core), batchId);
    }

    /// @dev Record PnL and process with zero PnL
    function _processZeroPnl(uint64 batchId) internal {
        _recordPnlAndProcess(batchId, 0, 0, _wad(500));
    }

    // ============================================================
    // requestDeposit
    // ============================================================

    function test_requestDeposit_createsDepositRequestWithSequentialId() public {
        _seedVault();

        vm.prank(userB);
        uint64 reqId = sys.core.requestDeposit(_usdc(100));

        assertEq(reqId, 0, "First request should get ID 0");
    }

    function test_requestDeposit_incrementsRequestIdForEachNewRequest() public {
        _seedVault();

        vm.prank(userA);
        uint64 id0 = sys.core.requestDeposit(_usdc(50));

        vm.prank(userB);
        uint64 id1 = sys.core.requestDeposit(_usdc(50));

        vm.prank(userA);
        uint64 id2 = sys.core.requestDeposit(_usdc(50));

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_requestDeposit_transfersTokensToVault() public {
        _seedVault();

        uint256 balBefore = sys.payment.balanceOf(userB);

        vm.prank(userB);
        sys.core.requestDeposit(_usdc(100));

        uint256 balAfter = sys.payment.balanceOf(userB);
        assertEq(balBefore - balAfter, _usdc(100));
    }

    function test_requestDeposit_revertsOnZeroAmount() public {
        _seedVault();

        vm.prank(userB);
        vm.expectRevert(SE.ZeroAmount.selector);
        sys.core.requestDeposit(0);
    }

    function test_requestDeposit_revertsIfVaultNotSeeded() public {
        // Don't seed vault

        vm.prank(userB);
        vm.expectRevert(SE.VaultNotSeeded.selector);
        sys.core.requestDeposit(_usdc(100));
    }

    // ============================================================
    // requestWithdraw
    // ============================================================

    function test_requestWithdraw_createsWithdrawRequestWithSequentialId() public {
        _seedVault();

        vm.prank(userA);
        uint64 reqId = sys.core.requestWithdraw(_wad(100));

        assertEq(reqId, 0, "First withdraw request should get ID 0");
    }

    function test_requestWithdraw_revertsOnZeroShares() public {
        _seedVault();

        vm.prank(userA);
        vm.expectRevert(SE.ZeroAmount.selector);
        sys.core.requestWithdraw(0);
    }

    // ============================================================
    // cancelDeposit
    // ============================================================

    function test_cancelDeposit_cancelsAndRefundsTokens() public {
        _seedVault();

        vm.prank(userB);
        sys.core.requestDeposit(_usdc(200));

        uint256 balBefore = sys.payment.balanceOf(userB);

        vm.prank(userB);
        sys.core.cancelDeposit(0);

        uint256 balAfter = sys.payment.balanceOf(userB);
        assertEq(balAfter - balBefore, _usdc(200));
    }

    function test_cancelDeposit_revertsIfRequestNotFound() public {
        _seedVault();

        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotFound.selector, uint64(999)));
        sys.core.cancelDeposit(999);
    }

    function test_cancelDeposit_revertsIfNotOwner() public {
        _seedVault();

        vm.prank(userA);
        sys.core.requestDeposit(_usdc(100));

        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotOwned.selector, uint64(0), userA, userB));
        sys.core.cancelDeposit(0);
    }

    function test_cancelDeposit_revertsIfAlreadyClaimed() public {
        _seedVault();

        vm.prank(userB);
        sys.core.requestDeposit(_usdc(100));

        _processZeroPnl(firstBatchId);

        vm.prank(userB);
        sys.core.claimDeposit(0);

        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotPending.selector, uint64(0)));
        sys.core.cancelDeposit(0);
    }

    // ============================================================
    // cancelWithdraw
    // ============================================================

    function test_cancelWithdraw_cancelsPendingWithdraw() public {
        _seedVault();

        vm.prank(userA);
        sys.core.requestWithdraw(_wad(100));

        vm.prank(userA);
        sys.core.cancelWithdraw(0);
        // No revert = success
    }

    function test_cancelWithdraw_revertsIfRequestNotFound() public {
        _seedVault();

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotFound.selector, uint64(999)));
        sys.core.cancelWithdraw(999);
    }

    function test_cancelWithdraw_revertsIfNotOwner() public {
        _seedVault();

        vm.prank(userA);
        sys.core.requestWithdraw(_wad(100));

        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotOwned.selector, uint64(0), userA, userB));
        sys.core.cancelWithdraw(0);
    }

    // ============================================================
    // processDailyBatch
    // ============================================================

    function test_processDailyBatch_processesBatchWithDeposits() public {
        _seedVault();

        vm.prank(userA);
        sys.core.requestDeposit(_usdc(100));
        vm.prank(userB);
        sys.core.requestDeposit(_usdc(200));

        _processZeroPnl(firstBatchId);

        // NAV should have increased by total deposits (300)
        // Initial seed = 1000, deposits = 300, NAV = 1300
        assertEq(sys.core.getVaultNav(), _wad(1300));
    }

    function test_processDailyBatch_updatesNavAndSharesCorrectly() public {
        _seedVault();

        vm.prank(userB);
        sys.core.requestDeposit(_usdc(500));

        _processZeroPnl(firstBatchId);

        // N = 1000 + 500 = 1500, S = 1000 + 500/1.0 = 1500
        assertEq(sys.core.getVaultNav(), _wad(1500));
        assertEq(sys.core.getVaultShares(), _wad(1500));
    }

    function test_processDailyBatch_revertsIfBatchIdOutOfSequence() public {
        _seedVault();

        vm.prank(userB);
        sys.core.requestDeposit(_usdc(100));

        // Try to process far-future batch
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.BatchNotReady.selector, firstBatchId + 4));
        sys.core.processDailyBatch(firstBatchId + 4);
    }

    function test_processDailyBatch_handlesOnlyWithdrawals() public {
        _seedVault();

        // Set D_lag = 0 for immediate withdrawal
        vm.prank(sys.owner);
        sys.core.setWithdrawalLagBatches(0);

        vm.prank(userA);
        sys.core.requestWithdraw(_wad(200));

        _processZeroPnl(firstBatchId);

        // N = 1000 - 200 = 800, S = 1000 - 200 = 800
        assertEq(sys.core.getVaultNav(), _wad(800));
        assertEq(sys.core.getVaultShares(), _wad(800));
    }

    function test_processDailyBatch_handlesMixedDepositsAndWithdrawals() public {
        _seedVault();

        // Set D_lag = 0 for immediate withdrawal
        vm.prank(sys.owner);
        sys.core.setWithdrawalLagBatches(0);

        vm.prank(userA);
        sys.core.requestWithdraw(_wad(300));
        vm.prank(userB);
        sys.core.requestDeposit(_usdc(500));

        _processZeroPnl(firstBatchId);

        // Net: +500 - 300 = +200, N = 1000 + 200 = 1200
        assertEq(sys.core.getVaultNav(), _wad(1200));
    }

    // ============================================================
    // claimDeposit
    // ============================================================

    function test_claimDeposit_calculatesSharesUsingBatchPrice() public {
        _seedVault();

        vm.prank(userB);
        sys.core.requestDeposit(_usdc(100));

        // Record positive P&L: Lt = 100 WAD
        // N_pre = 1000 + 100 (P&L) = 1100, S = 1000
        // P_e = 1.1
        _recordPnlAndProcess(firstBatchId, int256(_wad(100)), 0, _wad(500));

        vm.prank(userB);
        uint256 shares = sys.core.claimDeposit(0);

        // shares = 100 / 1.1 = ~90.909...
        uint256 expectedShares = ((_wad(100) * WAD) / _wad(1100)) * 1000;
        // Use approximate comparison due to fee waterfall effects
        assertApproxEqAbs(shares, expectedShares, _wad(2));
    }

    function test_claimDeposit_revertsIfBatchNotProcessed() public {
        _seedVault();

        vm.prank(userB);
        sys.core.requestDeposit(_usdc(100));

        // Don't process the batch
        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(SE.BatchNotProcessed.selector, firstBatchId));
        sys.core.claimDeposit(0);
    }

    function test_claimDeposit_revertsIfAlreadyClaimed() public {
        _seedVault();

        vm.prank(userB);
        sys.core.requestDeposit(_usdc(100));

        _processZeroPnl(firstBatchId);

        vm.prank(userB);
        sys.core.claimDeposit(0);

        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotPending.selector, uint64(0)));
        sys.core.claimDeposit(0);
    }

    function test_claimDeposit_revertsIfNotOwner() public {
        _seedVault();

        vm.prank(userB);
        sys.core.requestDeposit(_usdc(100));

        _processZeroPnl(firstBatchId);

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotOwned.selector, uint64(0), userB, userA));
        sys.core.claimDeposit(0);
    }

    // ============================================================
    // claimWithdraw
    // ============================================================

    function test_claimWithdraw_calculatesPayoutUsingBatchPrice() public {
        _seedVault();

        // Set D_lag = 0
        vm.prank(sys.owner);
        sys.core.setWithdrawalLagBatches(0);

        vm.prank(userA);
        sys.core.requestWithdraw(_wad(100));

        // Process with positive P&L: Lt = 200 WAD
        // N_pre = 1000 + 200 = 1200, S = 1000, P_e = 1.2
        _recordPnlAndProcess(firstBatchId, int256(_wad(200)), 0, _wad(500));

        vm.prank(userA);
        uint256 assets = sys.core.claimWithdraw(0);

        // payout = 100 * 1.2 = 120
        // Use approximate comparison due to fee waterfall
        assertApproxEqAbs(assets, _wad(120), _wad(2));
    }

    function test_claimWithdraw_revertsIfBatchNotProcessed() public {
        _seedVault();

        // D_lag = 1, so request eligible at batch N + 2
        vm.prank(userA);
        sys.core.requestWithdraw(_wad(100));

        // Process first batch
        _processZeroPnl(firstBatchId);

        // Batch 2 not yet processed
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(SE.BatchNotProcessed.selector, firstBatchId + 1));
        sys.core.claimWithdraw(0);
    }

    function test_claimWithdraw_allowsAfterDLagBatchesProcessed() public {
        _seedVault();

        // D_lag = 1 (default), request eligible at batch (firstBatchId + 1)
        vm.prank(userA);
        sys.core.requestWithdraw(_wad(100));

        // Process first batch
        _processZeroPnl(firstBatchId);

        // Process second batch
        uint64 secondBatchId = firstBatchId + 1;
        _processZeroPnl(secondBatchId);

        // Now claim should work
        vm.prank(userA);
        uint256 assets = sys.core.claimWithdraw(0);
        assertGt(assets, 0);
    }

    // ============================================================
    // O(1) aggregation invariant
    // ============================================================

    function test_aggregation_preAggregatedTotalsMatchIndividualRequests() public {
        _seedVault();

        // Multiple deposits
        vm.prank(userA);
        sys.core.requestDeposit(_usdc(123));
        vm.prank(userB);
        sys.core.requestDeposit(_usdc(456));
        vm.prank(userC);
        sys.core.requestDeposit(_usdc(789));

        _processZeroPnl(firstBatchId);

        // NAV should reflect total deposits: 1000 + 123 + 456 + 789 = 2368
        assertEq(sys.core.getVaultNav(), _wad(2368));
    }

    function test_aggregation_cancelUpdatesPreAggregatedTotal() public {
        _seedVault();

        vm.prank(userA);
        sys.core.requestDeposit(_usdc(100));
        vm.prank(userB);
        sys.core.requestDeposit(_usdc(200));

        // userA cancels
        vm.prank(userA);
        sys.core.cancelDeposit(0);

        _processZeroPnl(firstBatchId);

        // Only userB's 200 should remain
        assertEq(sys.core.getVaultNav(), _wad(1200));
    }

    // ============================================================
    // Multi-batch D_lag scenario
    // ============================================================

    function test_dLag_enforcesDLagAcrossMultipleBatches() public {
        _seedVault();

        // Set D_lag = 2
        vm.prank(sys.owner);
        sys.core.setWithdrawalLagBatches(2);

        // userA requests withdraw (eligible at firstBatchId + 2)
        vm.prank(userA);
        sys.core.requestWithdraw(_wad(100));

        // userB deposits (eligible at firstBatchId)
        vm.prank(userB);
        sys.core.requestDeposit(_usdc(200));

        // Process first batch - deposit included
        _processZeroPnl(firstBatchId);

        // Deposit claimable
        vm.prank(userB);
        sys.core.claimDeposit(0);

        // Withdraw NOT claimable yet (batch firstBatchId + 2 not processed)
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(SE.BatchNotProcessed.selector, firstBatchId + 2));
        sys.core.claimWithdraw(0);

        // Process second batch
        _processZeroPnl(firstBatchId + 1);

        // Still not claimable
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(SE.BatchNotProcessed.selector, firstBatchId + 2));
        sys.core.claimWithdraw(0);

        // Process third batch
        _processZeroPnl(firstBatchId + 2);

        // NOW claimable
        vm.prank(userA);
        uint256 assets = sys.core.claimWithdraw(0);
        assertGt(assets, 0);
    }
}
