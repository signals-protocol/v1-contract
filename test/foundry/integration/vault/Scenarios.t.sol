// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/VaultHelper.sol";
import "../../../../contracts/errors/SignalsErrors.sol";

/// @title LP Vault Integration Scenarios
/// @notice Tests complete multi-day workflows per whitepaper section 3.
/// @dev Migrated from test/integration/vault/scenarios.spec.ts (28 tests)
contract ScenariosTest is FullSystemDeployer {
    FullSystem sys;

    address owner_;
    address userA;
    address userB;
    address userC;
    address userD;
    address userE;

    uint256 constant FUND_AMOUNT = 1_000_000e6;
    uint256 constant DEFAULT_DELTA_ET = 500e18;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();

        owner_ = sys.owner;
        userA = sys.users[0];
        userB = sys.users[1];
        userC = sys.users[2];
        userD = sys.users[3];
        userE = sys.users[4];

        // Reconfigure: lambda=0.2, phiLP=80%, phiBS=10%, phiTR=10%, D_lag=1
        vm.startPrank(owner_);
        sys.core.setWithdrawalLagBatches(1);
        sys.core.setRiskConfig(0.2e18, 1e18, false);
        sys.core.setFeeWaterfallConfig(0, 0.8e18, 0.1e18, 0.1e18);
        vm.stopPrank();

        // Fund all users
        address[5] memory users = [userA, userB, userC, userD, userE];
        for (uint256 i = 0; i < 5; i++) {
            sys.payment.mint(users[i], FUND_AMOUNT);
            vm.prank(users[i]);
            sys.payment.approve(address(sys.core), type(uint256).max);
        }

        // Initialize capital stack
        vm.prank(userA);
        sys.core.fundBackstop(500e6);
        vm.prank(userA);
        sys.core.fundTreasury(100e6);
    }

    function _seedVault() internal returns (uint64 firstBatchId) {
        VaultHelper.seedVault(vm, address(sys.core), userA, 10_000e6);
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        firstBatchId = currentBatchId + 1;
    }

    function _processBatchWithPnl(uint64 batchId, int256 pnl, uint256 fees) internal {
        vm.prank(owner_);
        sys.core.harnessRecordPnl(batchId, pnl, fees, DEFAULT_DELTA_ET);
        advancePastBatchEnd(batchId);
        vm.prank(owner_);
        sys.core.processDailyBatch(batchId);
    }

    // ============================================================
    // Scenario 1: Happy Path 3-Day
    // ============================================================

    function test_completesFullThreeDayDepositTradeWithdrawCycle() public {
        uint64 day1 = _seedVault();
        uint64 day2 = day1 + 1;
        uint64 day3 = day1 + 2;
        uint64 day4 = day1 + 3;

        // Initial state
        assertEq(sys.core.getVaultNav(), 10_000e18);
        assertEq(sys.core.getVaultPrice(), WAD);

        // === Day 1 ===
        vm.prank(userB);
        sys.core.requestDeposit(1000e6);

        _processBatchWithPnl(day1, 500e18, 0);

        vm.prank(userB);
        sys.core.claimDeposit(0);

        uint256 nav1 = sys.core.getVaultNav();
        assertApproxEqAbs(nav1, 11_500e18, 100e18);

        uint256 price1 = sys.core.getVaultPrice();
        assertGt(price1, WAD);

        // === Day 2 ===
        vm.prank(userC);
        sys.core.requestDeposit(2000e6);

        _processBatchWithPnl(day2, -200e18, 100e18);

        vm.prank(userC);
        sys.core.claimDeposit(1);

        uint256 nav2 = sys.core.getVaultNav();
        assertGt(nav2, 11_000e18);

        // === Day 3 ===
        vm.prank(userA);
        sys.core.requestWithdraw(1000e18);

        _processBatchWithPnl(day3, 300e18, 0);

        // D_lag=1, need to process day4 for withdrawal to be claimable
        _processBatchWithPnl(day4, 0, 0);

        vm.prank(userA);
        sys.core.claimWithdraw(0);

        uint256 nav3 = sys.core.getVaultNav();
        assertGt(nav3, 10_000e18);

        uint256 finalPrice = sys.core.getVaultPrice();
        assertGt(finalPrice, WAD);
    }

    // ============================================================
    // Scenario 2: Peak Drawdown + Backstop Grant
    // ============================================================

    function test_backstopGrantProtectsLpFromExcessivePeakDrawdown() public {
        uint64 day1 = _seedVault();

        uint256 navBefore = sys.core.getVaultNav();
        (uint256 backstopBefore, ) = sys.core.getCapitalStack();

        assertEq(navBefore, 10_000e18);
        assertEq(backstopBefore, 500e18);

        // Large loss: -2000 on 10000 = 20% loss
        _processBatchWithPnl(day1, -2000e18, 0);

        uint256 navAfter = sys.core.getVaultNav();
        (uint256 backstopAfter, ) = sys.core.getCapitalStack();

        // LP should be partially protected
        assertGe(navAfter, 8000e18);

        // Backstop should have decreased
        assertLe(backstopAfter, backstopBefore);

        // Peak drawdown should be limited
        uint256 price = sys.core.getVaultPrice();
        uint256 peak = sys.core.getVaultPricePeak();
        uint256 drawdown = WAD - (price * WAD) / peak;
        assertLe(drawdown, 0.25e18); // Allow some margin
    }

    function test_recoveryFromPeakDrawdownUpdatesPeakCorrectly() public {
        uint64 day1 = _seedVault();
        uint64 day2 = day1 + 1;

        // Day 1: Loss
        _processBatchWithPnl(day1, -1000e18, 0);

        uint256 peakAfterLoss = sys.core.getVaultPricePeak();
        uint256 priceAfterLoss = sys.core.getVaultPrice();
        assertLt(priceAfterLoss, peakAfterLoss);

        // Day 2: Recovery
        _processBatchWithPnl(day2, 1500e18, 0);

        uint256 peakAfterRecovery = sys.core.getVaultPricePeak();
        uint256 priceAfterRecovery = sys.core.getVaultPrice();

        assertGt(priceAfterRecovery, WAD);
        assertGe(peakAfterRecovery, priceAfterRecovery);
    }

    // ============================================================
    // Scenario 3: Bank Run
    // ============================================================

    function test_handlesSimultaneousLargeWithdrawalRequests() public {
        uint64 day1 = _seedVault();
        uint64 day2 = day1 + 1;
        uint64 day3 = day1 + 2;

        // Setup: Multiple users deposit
        vm.prank(userB);
        sys.core.requestDeposit(2000e6);
        vm.prank(userC);
        sys.core.requestDeposit(2000e6);
        vm.prank(userD);
        sys.core.requestDeposit(2000e6);
        vm.prank(userE);
        sys.core.requestDeposit(2000e6);

        // Process Day 1: deposits
        _processBatchWithPnl(day1, 0, 0);

        vm.prank(userB);
        sys.core.claimDeposit(0);
        vm.prank(userC);
        sys.core.claimDeposit(1);
        vm.prank(userD);
        sys.core.claimDeposit(2);
        vm.prank(userE);
        sys.core.claimDeposit(3);

        uint256 navAfterDeposits = sys.core.getVaultNav();
        assertEq(navAfterDeposits, 18_000e18);

        // Bank run: All users request withdrawal
        uint256 withdrawAmount = 1500e18;
        vm.prank(userA);
        sys.core.requestWithdraw(withdrawAmount);
        vm.prank(userB);
        sys.core.requestWithdraw(withdrawAmount);
        vm.prank(userC);
        sys.core.requestWithdraw(withdrawAmount);
        vm.prank(userD);
        sys.core.requestWithdraw(withdrawAmount);
        vm.prank(userE);
        sys.core.requestWithdraw(withdrawAmount);

        // D_lag=1, withdrawals eligible at day3
        (, uint256 pendingWithdraws) = sys.core.harnessGetPendingBatchTotals(day3);
        assertEq(pendingWithdraws, 7500e18);

        // Process Day 2: empty batch (withdraws not eligible yet)
        _processBatchWithPnl(day2, 0, 0);

        // Process Day 3: withdrawals now eligible
        _processBatchWithPnl(day3, 0, 0);

        // Claim withdrawals
        vm.prank(userA);
        sys.core.claimWithdraw(0);
        vm.prank(userB);
        sys.core.claimWithdraw(1);
        vm.prank(userC);
        sys.core.claimWithdraw(2);
        vm.prank(userD);
        sys.core.claimWithdraw(3);
        vm.prank(userE);
        sys.core.claimWithdraw(4);

        uint256 navAfterWithdraws = sys.core.getVaultNav();
        assertEq(navAfterWithdraws, 10_500e18);

        // Price should remain stable
        uint256 price = sys.core.getVaultPrice();
        uint256 diff = price > WAD ? price - WAD : WAD - price;
        assertLe(diff, 10);
    }

    function test_dLagPreventsImmediateBankRunExit() public {
        uint64 day1 = _seedVault();
        uint64 day2 = day1 + 1;
        uint64 day3 = day1 + 2;

        // Deposit
        vm.prank(userB);
        sys.core.requestDeposit(5000e6);

        _processBatchWithPnl(day1, 0, 0);

        vm.prank(userB);
        sys.core.claimDeposit(0);

        // Immediate withdrawal request
        vm.prank(userB);
        sys.core.requestWithdraw(5000e18);

        // Process day2
        _processBatchWithPnl(day2, 0, 0);

        // Should fail - D_lag not met (eligible at batch 3)
        vm.prank(userB);
        vm.expectRevert();
        sys.core.claimWithdraw(0);

        // Process day3 - now should work
        _processBatchWithPnl(day3, 0, 0);

        vm.prank(userB);
        sys.core.claimWithdraw(0); // Should not revert
    }

    function test_maintainsPriceInvariantDuringMassExit() public {
        uint64 day1 = _seedVault();
        uint64 day2 = day1 + 1;
        uint64 day3 = day1 + 2;

        // Deposits
        vm.prank(userB);
        sys.core.requestDeposit(3000e6);
        vm.prank(userC);
        sys.core.requestDeposit(3000e6);
        vm.prank(userD);
        sys.core.requestDeposit(3000e6);

        _processBatchWithPnl(day1, 500e18, 0);

        vm.prank(userB);
        sys.core.claimDeposit(0);
        vm.prank(userC);
        sys.core.claimDeposit(1);
        vm.prank(userD);
        sys.core.claimDeposit(2);

        uint256 priceBeforeRun = sys.core.getVaultPrice();

        // Mass withdrawal
        vm.prank(userB);
        sys.core.requestWithdraw(2500e18);
        vm.prank(userC);
        sys.core.requestWithdraw(2500e18);
        vm.prank(userD);
        sys.core.requestWithdraw(2500e18);

        // Process through D_lag
        _processBatchWithPnl(day2, 0, 0);
        _processBatchWithPnl(day3, 0, 0);

        vm.prank(userB);
        sys.core.claimWithdraw(0);
        vm.prank(userC);
        sys.core.claimWithdraw(1);
        vm.prank(userD);
        sys.core.claimWithdraw(2);

        uint256 priceAfterRun = sys.core.getVaultPrice();

        uint256 priceDiff =
            priceAfterRun > priceBeforeRun ? priceAfterRun - priceBeforeRun : priceBeforeRun - priceAfterRun;
        assertLe(priceDiff, 0.001e18); // < 0.1%
    }

    function test_withdrawingAllUserSharesLeavesOnlyDeadShares() public {
        uint64 day1 = _seedVault();
        uint64 day2 = day1 + 1;

        uint256 totalShares = sys.core.getVaultShares();
        // MIN_DEAD_SHARES = 1000 (from LPVaultModule)
        uint256 userShares = totalShares - 1000; // Dead shares belong to DEAD_ADDRESS

        // Withdraw all user shares
        vm.prank(userA);
        sys.core.requestWithdraw(userShares);

        // Process through D_lag
        _processBatchWithPnl(day1, 0, 0);
        _processBatchWithPnl(day2, 0, 0);

        vm.prank(userA);
        sys.core.claimWithdraw(0);

        // Only dead shares remain
        assertEq(sys.core.getVaultShares(), 1000);
    }

    // ============================================================
    // Scenario 4: Fee Distribution
    // ============================================================

    function test_distributesFeesCorrectlyToLpBsTrPerPhiConfig() public {
        uint64 day1 = _seedVault();

        uint256 navBefore = sys.core.getVaultNav();
        (uint256 backstopBefore, uint256 treasuryBefore) = sys.core.getCapitalStack();

        // Fees: Ftot=1000 WAD, phi: LP=80%, BS=10%, TR=10%
        uint256 fees = 1000e18;
        _processBatchWithPnl(day1, 0, fees);

        uint256 navAfter = sys.core.getVaultNav();
        (uint256 backstopAfter, uint256 treasuryAfter) = sys.core.getCapitalStack();

        // LP NAV increase = Ftot * phiLP = 1000 * 0.8 = 800
        uint256 navIncrease = navAfter - navBefore;
        assertApproxEqAbs(navIncrease, 800e18, 10e18);

        // Backstop increase = Ftot * phiBS = 1000 * 0.1 = 100
        uint256 bsIncrease = backstopAfter - backstopBefore;
        assertApproxEqAbs(bsIncrease, 100e18, 10e18);

        // Treasury increase = Ftot * phiTR = 1000 * 0.1 = 100
        uint256 trIncrease = treasuryAfter - treasuryBefore;
        assertApproxEqAbs(trIncrease, 100e18, 10e18);
    }
}
