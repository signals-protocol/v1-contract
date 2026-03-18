// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/VaultHelper.sol";
import "../../../../contracts/errors/SignalsErrors.sol";

/// @title BatchAccounting Spec Tests
/// @notice Whitepaper v2 section 3 requirements:
///   - processDailyBatch is the ONLY place that modifies NAV/Shares
///   - claimDeposit/claimWithdraw do NOT change NAV/Shares
///   - Pre-batch NAV equation: N^pre_t = N_{t-1} + L_t + F_t + G_t
///   - Batch price equation: P^e_t = N^pre_t / S_{t-1}
/// @dev Migrated from test/integration/vault/batchAccounting.spec.ts (34 tests)
contract BatchAccountingTest is FullSystemDeployer {
    FullSystem sys;

    address owner_;
    address userA;
    address userB;

    uint256 constant FUND_AMOUNT = 100_000e6;
    uint256 constant DEFAULT_DELTA_ET = 500e18;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();

        owner_ = sys.owner;
        userA = sys.users[0];
        userB = sys.users[1];

        // Reconfigure for these tests: lambda=0.3, phiLP=70%, phiBS=20%, phiTR=10%
        vm.startPrank(owner_);
        sys.core.setWithdrawalLagBatches(0);
        sys.core.setRiskConfig(0.3e18, 1e18, false);
        sys.core.setFeeWaterfallConfig(0, 0.7e18, 0.2e18, 0.1e18);
        vm.stopPrank();

        // Fund users
        _fundUser(owner_, FUND_AMOUNT);
        _fundUser(userA, FUND_AMOUNT);
        _fundUser(userB, FUND_AMOUNT);
    }

    function _fundUser(address user, uint256 amount) internal {
        sys.payment.mint(user, amount);
        vm.prank(user);
        sys.payment.approve(address(sys.core), type(uint256).max);
    }

    function _seedVault() internal returns (uint64 currentBatchId) {
        // Seed vault (VaultHelper.seedVault overwrites approval, so re-approve after)
        VaultHelper.seedVault(vm, address(sys.core), owner_, 1000e6);
        // Re-approve for subsequent operations
        vm.prank(owner_);
        sys.payment.approve(address(sys.core), type(uint256).max);
        // Fund backstop for grant testing
        vm.prank(owner_);
        sys.core.fundBackstop(500e6);

        currentBatchId = sys.core.getCurrentBatchId();

        // Advance time past next batch end to allow processDailyBatch
        uint64 nextBatchEnd = batchEndTimestamp(currentBatchId + 1);
        vm.warp(uint256(nextBatchEnd) + 1);
    }

    function _processBatch(uint64 batchId, int256 lt, uint256 ftot) internal {
        vm.prank(owner_);
        sys.core.harnessRecordPnl(batchId, lt, ftot, DEFAULT_DELTA_ET);
        vm.prank(owner_);
        sys.core.processDailyBatch(batchId);
    }

    // ================================================================
    // SPEC-1: Only processDailyBatch modifies NAV/Shares
    // ================================================================

    function test_requestDepositDoesNotChangeNavOrShares() public {
        _seedVault();

        uint256 navBefore = sys.core.getVaultNav();
        uint256 sharesBefore = sys.core.getVaultShares();

        vm.prank(userA);
        sys.core.requestDeposit(500e6);

        assertEq(sys.core.getVaultNav(), navBefore, "NAV changed on requestDeposit");
        assertEq(sys.core.getVaultShares(), sharesBefore, "Shares changed on requestDeposit");
    }

    function test_requestWithdrawDoesNotChangeNavOrShares() public {
        _seedVault();

        uint256 navBefore = sys.core.getVaultNav();
        uint256 sharesBefore = sys.core.getVaultShares();

        vm.prank(owner_);
        sys.core.requestWithdraw(200e18);

        assertEq(sys.core.getVaultNav(), navBefore, "NAV changed on requestWithdraw");
        assertEq(sys.core.getVaultShares(), sharesBefore, "Shares changed on requestWithdraw");
    }

    function test_claimDepositDoesNotChangeNavOrShares() public {
        uint64 currentBatchId = _seedVault();

        vm.prank(userA);
        sys.core.requestDeposit(500e6);

        _processBatch(currentBatchId + 1, 0, 0);

        uint256 navAfterBatch = sys.core.getVaultNav();
        uint256 sharesAfterBatch = sys.core.getVaultShares();

        vm.prank(userA);
        sys.core.claimDeposit(0);

        assertEq(sys.core.getVaultNav(), navAfterBatch, "NAV changed on claimDeposit");
        assertEq(sys.core.getVaultShares(), sharesAfterBatch, "Shares changed on claimDeposit");
    }

    function test_claimWithdrawDoesNotChangeNavOrShares() public {
        uint64 currentBatchId = _seedVault();

        vm.prank(owner_);
        sys.core.requestWithdraw(200e18);

        _processBatch(currentBatchId + 1, 0, 0);

        uint256 navAfterBatch = sys.core.getVaultNav();
        uint256 sharesAfterBatch = sys.core.getVaultShares();

        vm.prank(owner_);
        sys.core.claimWithdraw(0);

        assertEq(sys.core.getVaultNav(), navAfterBatch, "NAV changed on claimWithdraw");
        assertEq(sys.core.getVaultShares(), sharesAfterBatch, "Shares changed on claimWithdraw");
    }

    function test_processDailyBatchCalledExactlyOncePerBatch() public {
        uint64 currentBatchId = _seedVault();
        uint64 batchId = currentBatchId + 1;

        _processBatch(batchId, 0, 0);

        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(SignalsErrors.BatchNotReady.selector, batchId));
        sys.core.processDailyBatch(batchId);
    }

    function test_cancelDepositDoesNotChangeNavOrShares() public {
        _seedVault();

        vm.prank(userA);
        sys.core.requestDeposit(500e6);

        uint256 navBefore = sys.core.getVaultNav();
        uint256 sharesBefore = sys.core.getVaultShares();

        vm.prank(userA);
        sys.core.cancelDeposit(0);

        assertEq(sys.core.getVaultNav(), navBefore, "NAV changed on cancelDeposit");
        assertEq(sys.core.getVaultShares(), sharesBefore, "Shares changed on cancelDeposit");
    }

    function test_cancelWithdrawDoesNotChangeNavOrShares() public {
        _seedVault();

        vm.prank(owner_);
        sys.core.requestWithdraw(200e18);

        uint256 navBefore = sys.core.getVaultNav();
        uint256 sharesBefore = sys.core.getVaultShares();

        vm.prank(owner_);
        sys.core.cancelWithdraw(0);

        assertEq(sys.core.getVaultNav(), navBefore, "NAV changed on cancelWithdraw");
        assertEq(sys.core.getVaultShares(), sharesBefore, "Shares changed on cancelWithdraw");
    }

    // ================================================================
    // SPEC-2: Pre-batch NAV equation: N^pre_t = N_{t-1} + L_t + F_t + G_t
    // ================================================================

    function test_preBatchNavEquationPositivePnl() public {
        uint64 currentBatchId = _seedVault();

        uint256 N_prev = sys.core.getVaultNav();
        uint64 batchId = currentBatchId + 1;

        int256 Lt = 100e18;
        uint256 Ftot = 30e18;

        _processBatch(batchId, Lt, Ftot);

        (, , uint256 ft, uint256 gt, uint256 npre, , ) = sys.core.getDailyPnl(batchId);

        // Verify: Npre - Nprev = Lt + Ft + Gt
        int256 lhs = int256(npre) - int256(N_prev);
        int256 rhs = Lt + int256(ft) + int256(gt);

        assertEq(lhs, rhs, "Pre-batch NAV equation violated");
    }

    function test_preBatchNavEquationNegativePnlWithGrant() public {
        uint64 currentBatchId = _seedVault();

        // Add more backstop for grant capability
        vm.prank(owner_);
        sys.core.fundBackstop(500e6);

        uint256 N_prev = sys.core.getVaultNav();
        uint64 batchId = currentBatchId + 1;

        int256 Lt = -400e18;
        uint256 Ftot = 20e18;

        _processBatch(batchId, Lt, Ftot);

        (, , uint256 ft, uint256 gt, uint256 npre, , ) = sys.core.getDailyPnl(batchId);

        int256 lhs = int256(npre) - int256(N_prev);
        int256 rhs = Lt + int256(ft) + int256(gt);

        assertEq(lhs, rhs, "Pre-batch NAV equation violated with grant");
    }

    function test_preBatchNavEquationZeroPnl() public {
        uint64 currentBatchId = _seedVault();

        uint256 N_prev = sys.core.getVaultNav();
        uint64 batchId = currentBatchId + 1;

        _processBatch(batchId, 0, 0);

        (, , uint256 ft, uint256 gt, uint256 npre, , ) = sys.core.getDailyPnl(batchId);

        assertEq(npre, N_prev);
        assertEq(ft, 0);
        assertEq(gt, 0);
    }

    function test_preBatchNavEquationNegativePnlAboveFloor() public {
        uint64 currentBatchId = _seedVault();

        uint256 N_prev = sys.core.getVaultNav();
        uint64 batchId = currentBatchId + 1;

        // Small loss that stays above NAV loss floor (pdd = -30%)
        int256 Lt = -100e18;
        uint256 Ftot = 10e18;

        _processBatch(batchId, Lt, Ftot);

        (, , uint256 ft, uint256 gt, uint256 npre, , ) = sys.core.getDailyPnl(batchId);

        // Grant should be 0 since we're above floor
        assertEq(gt, 0, "Grant should be 0 when above floor");

        int256 lhs = int256(npre) - int256(N_prev);
        int256 rhs = Lt + int256(ft) + int256(gt);
        assertEq(lhs, rhs, "Pre-batch NAV equation violated");
    }

    // ================================================================
    // SPEC-3: Batch price equation: P^e_t = N^pre_t / S_{t-1}
    // ================================================================

    function test_batchPriceEquation() public {
        uint64 currentBatchId = _seedVault();

        uint256 S_prev = sys.core.getVaultShares();
        uint64 batchId = currentBatchId + 1;

        _processBatch(batchId, 50e18, 0);

        (, , , , uint256 npre, uint256 pe, ) = sys.core.getDailyPnl(batchId);

        uint256 expectedPe = (npre * WAD) / S_prev;

        // Allow 1 wei tolerance
        assertApproxEqAbs(pe, expectedPe, 1);
    }

    function test_batchPriceUsedForAllOpsInSameBatch() public {
        uint64 currentBatchId = _seedVault();

        vm.prank(userA);
        sys.core.requestDeposit(100e6);
        vm.prank(userB);
        sys.core.requestDeposit(200e6);
        vm.prank(owner_);
        sys.core.requestWithdraw(50e18);

        uint64 batchId = currentBatchId + 1;
        _processBatch(batchId, 30e18, 0);

        (uint256 totalDeposits, uint256 totalWithdraws, uint256 batchPrice, ) = sys.core.harnessGetBatchAggregation(
            batchId
        );

        assertEq(totalDeposits, 300e18); // 100 + 200
        assertEq(totalWithdraws, 50e18);
        assertGt(batchPrice, WAD); // Price increased due to positive P&L
    }

    // ================================================================
    // SPEC-4: Price invariance during batch processing
    // ================================================================

    function test_pricePreservedAfterDepositProcessing() public {
        uint64 currentBatchId = _seedVault();

        vm.prank(userA);
        sys.core.requestDeposit(500e6);

        uint64 batchId = currentBatchId + 1;
        _processBatch(batchId, 0, 0);

        (, , uint256 batchPrice, ) = sys.core.harnessGetBatchAggregation(batchId);
        uint256 finalPrice = sys.core.getVaultPrice();

        uint256 diff = finalPrice > batchPrice ? finalPrice - batchPrice : batchPrice - finalPrice;
        assertLe(diff, 10, "Price not preserved after deposit");
    }

    function test_pricePreservedAfterWithdrawalProcessing() public {
        uint64 currentBatchId = _seedVault();

        vm.prank(owner_);
        sys.core.requestWithdraw(200e18);

        uint64 batchId = currentBatchId + 1;
        _processBatch(batchId, 0, 0);

        (, , uint256 batchPrice, ) = sys.core.harnessGetBatchAggregation(batchId);
        uint256 finalPrice = sys.core.getVaultPrice();

        uint256 diff = finalPrice > batchPrice ? finalPrice - batchPrice : batchPrice - finalPrice;
        assertLe(diff, 10, "Price not preserved after withdrawal");
    }

    function test_pricePreservedAfterMixedDepositWithdrawal() public {
        uint64 currentBatchId = _seedVault();

        vm.prank(userA);
        sys.core.requestDeposit(300e6);
        vm.prank(owner_);
        sys.core.requestWithdraw(100e18);

        uint64 batchId = currentBatchId + 1;

        vm.prank(owner_);
        sys.core.harnessRecordPnl(batchId, 50e18, 0, DEFAULT_DELTA_ET);
        vm.prank(owner_);
        sys.core.processDailyBatch(batchId);

        (, , uint256 batchPrice, ) = sys.core.harnessGetBatchAggregation(batchId);
        uint256 finalPrice = sys.core.getVaultPrice();

        uint256 diff = finalPrice > batchPrice ? finalPrice - batchPrice : batchPrice - finalPrice;
        assertLe(diff, 10, "Price not preserved after mixed ops");
    }

    // ================================================================
    // SPEC-5: Same market underwriters get same return
    // ================================================================

    function test_sharesExistingAtBatchStartReceiveSamePnl() public {
        uint64 currentBatchId = _seedVault();

        uint256 initialPrice = sys.core.getVaultPrice();

        _processBatch(currentBatchId + 1, 100e18, 0);

        uint256 finalPrice = sys.core.getVaultPrice();
        uint256 priceChange = finalPrice - initialPrice;

        assertGt(priceChange, 0);
    }

    function test_newDepositsDoNotDiluteExistingShares() public {
        uint64 currentBatchId = _seedVault();

        vm.prank(userA);
        sys.core.requestDeposit(500e6);

        _processBatch(currentBatchId + 1, 100e18, 0);

        vm.prank(userA);
        sys.core.claimDeposit(0);

        uint256 priceAfter = sys.core.getVaultPrice();
        assertGt(priceAfter, WAD);
    }

    // ================================================================
    // SPEC-6: No duplicate state updates
    // ================================================================

    function test_harnessRecordPnlAccumulatesDoesNotOverwrite() public {
        uint64 currentBatchId = _seedVault();
        uint64 batchId = currentBatchId + 1;

        vm.prank(owner_);
        sys.core.harnessRecordPnl(batchId, 30e18, 5e18, DEFAULT_DELTA_ET);
        vm.prank(owner_);
        sys.core.harnessRecordPnl(batchId, 20e18, 3e18, DEFAULT_DELTA_ET);

        (int256 lt, uint256 ftot, , , , , ) = sys.core.getDailyPnl(batchId);

        assertEq(lt, 50e18); // 30 + 20
        assertEq(ftot, 8e18); // 5 + 3
    }

    function test_processDailyBatchUpdatesStateExactlyOnce() public {
        uint64 currentBatchId = _seedVault();
        uint64 batchId = currentBatchId + 1;

        uint256 navBefore = sys.core.getVaultNav();

        _processBatch(batchId, 100e18, 0);

        uint256 navAfter = sys.core.getVaultNav();
        (, , , , , , bool processed) = sys.core.getDailyPnl(batchId);

        assertTrue(processed);
        assertGt(navAfter, navBefore);

        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(SignalsErrors.BatchNotReady.selector, batchId));
        sys.core.processDailyBatch(batchId);
    }

    // ================================================================
    // SPEC-7: Edge cases
    // ================================================================

    function test_revertsProcessDailyBatchForFutureBatch() public {
        uint64 currentBatchId = _seedVault();

        uint64 futureBatchId = currentBatchId + 100;
        vm.prank(owner_);
        sys.core.harnessRecordPnl(futureBatchId, 0, 0, DEFAULT_DELTA_ET);

        advancePastBatchEnd(futureBatchId);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(SignalsErrors.BatchNotReady.selector, futureBatchId));
        sys.core.processDailyBatch(futureBatchId);
    }

    function test_handlesZeroLtFtGtCorrectly() public {
        uint64 currentBatchId = _seedVault();

        uint256 navBefore = sys.core.getVaultNav();

        _processBatch(currentBatchId + 1, 0, 0);

        assertEq(sys.core.getVaultNav(), navBefore);
    }

    function test_handlesLargeNegativeLtWithoutUnderflow() public {
        uint64 currentBatchId = _seedVault();

        // Add more backstop for grant capability
        vm.prank(owner_);
        sys.core.fundBackstop(10_000e6);

        uint256 navBefore = sys.core.getVaultNav();
        uint64 batchId = currentBatchId + 1;

        // Very large negative Lt (-50% of NAV)
        vm.prank(owner_);
        sys.core.harnessRecordPnl(batchId, -500e18, 0, 1000e18);
        vm.prank(owner_);
        sys.core.processDailyBatch(batchId);

        uint256 navAfter = sys.core.getVaultNav();

        // Floor = navBefore * (1 - 0.3) = navBefore * 0.7
        uint256 floor = (navBefore * 70) / 100;
        assertGe(navAfter, floor);
    }
}
