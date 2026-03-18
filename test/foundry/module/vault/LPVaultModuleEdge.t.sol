// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/VaultHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {LPVaultModule} from "../../../../contracts/modules/LPVaultModule.sol";

/// @title LPVaultModule Edge Case Tests
/// @notice Foundry conversion of test/module/vault/lpVaultModule.spec.ts (edge cases)
/// @dev Covers: seed vault edge cases, share price tracking, fee waterfall integration,
///      multi-user batch scenarios, withdrawal lag edge cases, double-claim prevention
contract LPVaultModuleEdgeTest is FullSystemDeployer {
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

        // Mint tokens to users
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

    function _seedVault() internal {
        vm.prank(userA);
        sys.core.seedVault(_usdc(1000));
        currentBatchId = sys.core.getCurrentBatchId();
        firstBatchId = currentBatchId + 1;
    }

    function _recordPnlAndProcess(uint64 batchId, int256 lt, uint256 ftot, uint256 deltaEt) internal {
        vm.startPrank(sys.owner);
        sys.core.harnessRecordPnl(batchId, lt, ftot, deltaEt);
        vm.stopPrank();
        VaultHelper.processBatch(vm, address(sys.core), batchId);
    }

    function _processZeroPnl(uint64 batchId) internal {
        _recordPnlAndProcess(batchId, 0, 0, _wad(500));
    }

    // ============================================================
    // Seed Vault Edge Cases
    // ============================================================

    function test_seedVault_setsInitialNavAndShares() public {
        vm.prank(userA);
        sys.core.seedVault(_usdc(1000));

        assertEq(sys.core.getVaultNav(), _wad(1000));
        assertEq(sys.core.getVaultShares(), _wad(1000));
        assertEq(sys.core.getVaultPrice(), WAD); // Price = 1.0
    }

    function test_seedVault_revertsOnDoubleSeed() public {
        vm.prank(userA);
        sys.core.seedVault(_usdc(1000));

        vm.prank(userA);
        vm.expectRevert(SE.VaultAlreadySeeded.selector);
        sys.core.seedVault(_usdc(1000));
    }

    function test_seedVault_revertsOnZeroAmount() public {
        vm.prank(userA);
        vm.expectRevert(SE.ZeroAmount.selector);
        sys.core.seedVault(0);
    }

    // ============================================================
    // Share Price Tracking
    // ============================================================

    function test_sharePrice_startsAtOneWad() public {
        _seedVault();
        assertEq(sys.core.getVaultPrice(), WAD);
    }

    function test_sharePrice_increasesWithPositivePnl() public {
        _seedVault();

        // Record positive P&L
        _recordPnlAndProcess(firstBatchId, int256(_wad(100)), 0, _wad(500));

        // Price should be > 1.0
        assertGt(sys.core.getVaultPrice(), WAD);
    }

    function test_sharePrice_decreasesWithNegativePnl() public {
        _seedVault();

        // Record negative P&L
        _recordPnlAndProcess(firstBatchId, -int256(_wad(100)), 0, _wad(500));

        // Price should be < 1.0
        assertLt(sys.core.getVaultPrice(), WAD);
    }

    // ============================================================
    // Peak Drawdown Tracking
    // ============================================================

    function test_pricePeak_tracksHighWaterMark() public {
        _seedVault();

        // Positive P&L -> price > 1.0
        _recordPnlAndProcess(firstBatchId, int256(_wad(200)), 0, _wad(500));
        uint256 peakAfterGain = sys.core.getVaultPricePeak();

        // Negative P&L -> price drops
        _recordPnlAndProcess(firstBatchId + 1, -int256(_wad(100)), 0, _wad(500));

        // Peak should remain at previous high
        assertEq(sys.core.getVaultPricePeak(), peakAfterGain);
    }

    function test_pricePeak_updatesOnNewHigh() public {
        _seedVault();

        uint256 peakBefore = sys.core.getVaultPricePeak();

        // Large positive P&L
        _recordPnlAndProcess(firstBatchId, int256(_wad(500)), 0, _wad(500));

        assertGt(sys.core.getVaultPricePeak(), peakBefore);
    }

    // ============================================================
    // Multi-User Batch Scenarios
    // ============================================================

    function test_multiUser_depositsInSameBatch() public {
        _seedVault();

        // Three users deposit different amounts
        vm.prank(userA);
        sys.core.requestDeposit(_usdc(100));
        vm.prank(userB);
        sys.core.requestDeposit(_usdc(200));
        vm.prank(userC);
        sys.core.requestDeposit(_usdc(300));

        _processZeroPnl(firstBatchId);

        // All three should be claimable
        vm.prank(userA);
        uint256 sharesA = sys.core.claimDeposit(0);
        vm.prank(userB);
        uint256 sharesB = sys.core.claimDeposit(1);
        vm.prank(userC);
        uint256 sharesC = sys.core.claimDeposit(2);

        // Shares proportional to deposits (at price 1.0)
        assertGt(sharesA, 0);
        assertGt(sharesB, 0);
        assertGt(sharesC, 0);
        assertGt(sharesC, sharesB);
        assertGt(sharesB, sharesA);
    }

    function test_multiUser_depositAndWithdrawSameBatch() public {
        _seedVault();

        // Set D_lag = 0 for immediate withdrawal
        vm.prank(sys.owner);
        sys.core.setWithdrawalLagBatches(0);

        // userA deposits, userB withdraws (userA seeded so has shares)
        vm.prank(userB);
        sys.core.requestDeposit(_usdc(500));

        vm.prank(userA);
        sys.core.requestWithdraw(_wad(200));

        _processZeroPnl(firstBatchId);

        // Both should be claimable
        vm.prank(userB);
        uint256 shares = sys.core.claimDeposit(0);
        assertGt(shares, 0);

        // Process second batch for withdraw (D_lag = 0 but eligible batch is firstBatchId)
        vm.prank(userA);
        uint256 assets = sys.core.claimWithdraw(0);
        assertGt(assets, 0);
    }

    // ============================================================
    // Sequential Batches
    // ============================================================

    function test_sequentialBatches_depositsAcrossMultipleBatches() public {
        _seedVault();

        // Batch 1: userA deposits
        vm.prank(userA);
        sys.core.requestDeposit(_usdc(100));
        _processZeroPnl(firstBatchId);

        uint256 navAfterBatch1 = sys.core.getVaultNav();
        assertEq(navAfterBatch1, _wad(1100));

        // Batch 2: userB deposits
        vm.prank(userB);
        sys.core.requestDeposit(_usdc(200));
        _processZeroPnl(firstBatchId + 1);

        uint256 navAfterBatch2 = sys.core.getVaultNav();
        assertEq(navAfterBatch2, _wad(1300));
    }

    // ============================================================
    // Withdrawal Lag Edge Cases
    // ============================================================

    function test_dLag_zeroLagAllowsImmediateWithdrawal() public {
        _seedVault();

        vm.prank(sys.owner);
        sys.core.setWithdrawalLagBatches(0);

        vm.prank(userA);
        sys.core.requestWithdraw(_wad(100));

        _processZeroPnl(firstBatchId);

        // Should be claimable immediately
        vm.prank(userA);
        uint256 assets = sys.core.claimWithdraw(0);
        assertGt(assets, 0);
    }

    function test_dLag_changingLagDoesNotAffectExistingRequests() public {
        _seedVault();

        // D_lag = 1 (default)
        vm.prank(userA);
        sys.core.requestWithdraw(_wad(100));
        // Request is already recorded with eligibleBatchId = firstBatchId + 1

        // Change D_lag to 0 — should not affect existing request
        vm.prank(sys.owner);
        sys.core.setWithdrawalLagBatches(0);

        // Process first batch
        _processZeroPnl(firstBatchId);

        // Still need second batch because request was made with D_lag = 1
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(SE.BatchNotProcessed.selector, firstBatchId + 1));
        sys.core.claimWithdraw(0);

        // Process second batch
        _processZeroPnl(firstBatchId + 1);

        // NOW claimable
        vm.prank(userA);
        uint256 assets = sys.core.claimWithdraw(0);
        assertGt(assets, 0);
    }

    // ============================================================
    // Double Claim Prevention
    // ============================================================

    function test_doubleClaim_depositCannotBeClaimedTwice() public {
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

    function test_doubleClaim_withdrawCannotBeClaimedTwice() public {
        _seedVault();

        vm.prank(sys.owner);
        sys.core.setWithdrawalLagBatches(0);

        vm.prank(userA);
        sys.core.requestWithdraw(_wad(100));

        _processZeroPnl(firstBatchId);

        vm.prank(userA);
        sys.core.claimWithdraw(0);

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotPending.selector, uint64(0)));
        sys.core.claimWithdraw(0);
    }

    // ============================================================
    // Cancel After Process Failure
    // ============================================================

    function test_cancelAfterProcess_cannotCancelDepositAfterClaim() public {
        _seedVault();

        vm.prank(userB);
        sys.core.requestDeposit(_usdc(100));

        _processZeroPnl(firstBatchId);

        vm.prank(userB);
        sys.core.claimDeposit(0);

        // Cannot cancel a claimed deposit
        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotPending.selector, uint64(0)));
        sys.core.cancelDeposit(0);
    }

    // ============================================================
    // NAV Consistency
    // ============================================================

    function test_navConsistency_navNeverGoesNegative() public {
        _seedVault();

        vm.prank(sys.owner);
        sys.core.setWithdrawalLagBatches(0);

        // Withdraw most of the vault (but not all, due to MIN_DEAD_SHARES)
        vm.prank(userA);
        sys.core.requestWithdraw(_wad(900));

        _processZeroPnl(firstBatchId);

        // NAV should be > 0 (at least MIN_DEAD_SHARES worth)
        assertGt(sys.core.getVaultNav(), 0);
    }

    // ============================================================
    // Batch Ordering
    // ============================================================

    function test_batchOrdering_mustProcessSequentially() public {
        _seedVault();

        // Process batch 1
        _processZeroPnl(firstBatchId);

        // Try to skip batch 2 and process batch 3
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.BatchNotReady.selector, firstBatchId + 2));
        sys.core.processDailyBatch(firstBatchId + 2);
    }

    function test_batchOrdering_cannotReprocessSameBatch() public {
        _seedVault();

        _processZeroPnl(firstBatchId);

        // Cannot process same batch again
        vm.startPrank(sys.owner);
        sys.core.harnessRecordPnl(firstBatchId, 0, 0, _wad(500));
        vm.stopPrank();

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.BatchNotReady.selector, firstBatchId));
        sys.core.processDailyBatch(firstBatchId);
    }

    // ============================================================
    // Fee Waterfall Integration
    // ============================================================

    function test_feeWaterfall_feesAppliedDuringBatchProcessing() public {
        _seedVault();

        // Fund backstop and treasury for waterfall
        vm.startPrank(sys.owner);
        sys.payment.mint(sys.owner, _usdc(10_000));
        sys.payment.approve(address(sys.core), _usdc(10_000));
        sys.core.fundBackstop(_usdc(2000));
        sys.core.fundTreasury(_usdc(500));
        vm.stopPrank();

        // Record PnL with fees
        _recordPnlAndProcess(firstBatchId, int256(_wad(100)), _wad(50), _wad(500));

        // NAV should reflect PnL minus fees distributed to backstop/treasury
        uint256 nav = sys.core.getVaultNav();
        // NAV includes initial 1000 + Lt (100) + fee split to LP
        // Exact value depends on waterfall config, but should be > 1000
        assertGt(nav, _wad(1000));
    }
}
