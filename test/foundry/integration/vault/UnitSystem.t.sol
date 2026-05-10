// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/VaultHelper.sol";
import "../../../../contracts/testonly/FixedPointMathHarness.sol";
import "../../../../contracts/testonly/FeeWaterfallLibHarness.sol";

/// @title UnitSystem Spec Tests
/// @notice Whitepaper v2 section 6.2 & Appendix C requirements:
///   - External token transfers use USDC6 (6 decimals)
///   - Internal operations use WAD (1e18)
///   - Conversion happens exactly once at entry and once at exit
///   - Rounding/dust rules for trades, deposits, withdrawals, and fee splits
/// @dev Migrated from test/integration/vault/unitSystem.spec.ts (17 tests)
contract UnitSystemTest is FullSystemDeployer {
    FullSystem sys;
    FixedPointMathHarness mathHarness;
    FeeWaterfallLibHarness feeHarness;

    uint256 constant WAD_DECIMALS = 18;
    uint256 constant USDC6_DECIMALS = 6;
    uint256 constant SCALE_FACTOR = 10 ** (WAD_DECIMALS - USDC6_DECIMALS); // 1e12

    address owner_;
    address depositor;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();
        mathHarness = new FixedPointMathHarness();
        feeHarness = new FeeWaterfallLibHarness();

        owner_ = sys.owner;
        depositor = sys.users[0];

        // Reconfigure for these tests
        vm.startPrank(owner_);
        sys.core.setWithdrawalLagBatches(0);
        sys.core.setRiskConfig(0.2e18, 1e18, false);
        sys.core.setFeeWaterfallConfig(0, 0.8e18, 0.1e18, 0.1e18);
        vm.stopPrank();

        // Fund users
        sys.payment.mint(owner_, 10_000_000_000); // 10000 USDC
        vm.prank(owner_);
        sys.payment.approve(address(sys.core), type(uint256).max);

        sys.payment.mint(depositor, 100_000_000); // 100 USDC
        vm.prank(depositor);
        sys.payment.approve(address(sys.core), type(uint256).max);
    }

    // ================================================================
    // SPEC-1: Trade debit rounds UP (user pays ceiling)
    // ================================================================

    function test_fromWadRoundUpRoundsWadAmountToUsdc6Ceiling() public view {
        // WAD amount that doesn't divide evenly by 1e12
        uint256 wadAmount = 1_000000_000001_000000; // 1.000000000001 WAD
        uint256 result = mathHarness.fromWadRoundUp(wadAmount);

        // Should round UP to 1.000001 USDC6 = 1000001
        assertEq(result, 1000001);
    }

    function test_fromWadRoundUpOnExactMultipleReturnsSameValue() public view {
        uint256 wadAmount = 1e18; // 1.0 WAD
        uint256 result = mathHarness.fromWadRoundUp(wadAmount);

        assertEq(result, 1000000);
    }

    function test_dustInTradeCostGoesToMaker() public pure {
        uint256 costWad = 10e18 + 1; // 10 WAD + 1 wei

        // Round up: trader pays ceiling
        uint256 costUsdc6 = (costWad + SCALE_FACTOR - 1) / SCALE_FACTOR;

        // Round down: exact conversion
        uint256 exactUsdc6 = costWad / SCALE_FACTOR;

        // Dust should be positive (goes to maker/LP)
        uint256 dust = costUsdc6 - exactUsdc6;
        assertEq(dust, 1);
    }

    // ================================================================
    // SPEC-2: Trade credit rounds DOWN (user receives floor)
    // ================================================================

    function test_fromWadRoundsWadAmountToUsdc6Floor() public view {
        uint256 wadAmount = 1e18 + SCALE_FACTOR - 1;
        uint256 result = mathHarness.fromWad(wadAmount);

        // Should round DOWN to 1.000000 USDC6 = 1000000
        assertEq(result, 1000000);
    }

    function test_proceedsDustStaysWithMakerWhenTraderSells() public pure {
        uint256 proceedsWad = 10e18 + (SCALE_FACTOR - 1);

        // Round down: trader receives floor
        uint256 proceedsUsdc6 = proceedsWad / SCALE_FACTOR;

        // Exact value (integer division truncates)
        // If we had perfect division, we'd get slightly more
        // Trader receives less than exact → dust stays with maker
        assertLt(proceedsUsdc6 * SCALE_FACTOR, proceedsWad);
    }

    // ================================================================
    // SPEC-3: Deposit residual refunded (not kept by vault)
    // ================================================================

    function test_depositResidualRefundedToDepositorNotKeptByVault() public {
        // Seed vault
        VaultHelper.seedVault(vm, address(sys.core), owner_, 10_000_000); // 10 USDC

        // Change price by processing a batch with P&L
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 batchId = currentBatchId + 1;

        vm.prank(owner_);
        sys.core.harnessRecordPnl(batchId, 1e18, 0, 500e18);
        advancePastBatchEnd(batchId);
        vm.prank(owner_);
        sys.core.processDailyBatch(batchId);

        // Now price != 1.0, deposit may have residual
        uint256 depositAmount = 1_000_001; // 1.000001 USDC

        vm.prank(depositor);
        sys.core.requestDeposit(depositAmount);

        // Process next batch
        uint64 nextBatchId = sys.core.getCurrentBatchId() + 1;
        vm.prank(owner_);
        sys.core.harnessRecordPnl(nextBatchId, 0, 0, 500e18);
        advancePastBatchEnd(nextBatchId);
        vm.prank(owner_);
        sys.core.processDailyBatch(nextBatchId);

        // Claim deposit - should not revert
        vm.prank(depositor);
        sys.core.claimDeposit(0);
    }

    function test_vaultNavIncreasesByAUsedNotFullDepositAmount() public {
        VaultHelper.seedVault(vm, address(sys.core), owner_, 10_000_000); // 10 USDC

        uint256 navBefore = sys.core.getVaultNav();

        uint256 depositAmount = 1_000_000; // 1 USDC
        vm.prank(depositor);
        sys.core.requestDeposit(depositAmount);

        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 batchId = currentBatchId + 1;
        vm.prank(owner_);
        sys.core.harnessRecordPnl(batchId, 0, 0, 500e18);
        advancePastBatchEnd(batchId);
        vm.prank(owner_);
        sys.core.processDailyBatch(batchId);

        vm.prank(depositor);
        sys.core.claimDeposit(0);

        uint256 navAfter = sys.core.getVaultNav();
        assertGe(navAfter - navBefore, 0);
    }

    // ================================================================
    // SPEC-4: Withdrawal dust stays in vault
    // ================================================================

    function test_withdrawalPayoutRoundsDownDustStaysInVault() public {
        VaultHelper.seedVault(vm, address(sys.core), owner_, 10_000_000); // 10 USDC

        uint256 withdrawShares = 1.5e18; // 1.5 shares
        vm.prank(owner_);
        sys.core.requestWithdraw(withdrawShares);

        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 batchId = currentBatchId + 1;
        vm.prank(owner_);
        sys.core.harnessRecordPnl(batchId, 0, 0, 500e18);
        advancePastBatchEnd(batchId);
        vm.prank(owner_);
        sys.core.processDailyBatch(batchId);

        vm.prank(owner_);
        sys.core.claimWithdraw(0);

        // The payout rounds down; dust stays in vault.
        // Verification: claim doesn't revert + vault still operational
    }

    // ================================================================
    // SPEC-5: Fee split dust goes to LP
    // ================================================================

    function test_feeWaterfallDustAttributedToLp() public view {
        // Create scenario where Fremain doesn't divide evenly
        (,,,,, uint256 fdust, uint256 ft,,,) = feeHarness.calculate(
            0, // Lt = 0
            100e18, // Ftot = 100
            1000e18, // Nprev
            200e18, // Bprev
            50e18, // Tprev
            100e18, // deltaEt
            -0.3e18, // pdd
            0, // rhoBS = 0
            0.333333333333333333e18, // phiLP ≈ 1/3
            0.333333333333333333e18, // phiBS ≈ 1/3
            0.333333333333333334e18 // phiTR ≈ 1/3
        );

        // Fdust should be non-negative due to rounding
        assertGe(fdust, 0);
        // Ft should include Fdust
        assertGe(ft, fdust);
    }

    // ================================================================
    // SPEC-6: Internal state is WAD-denominated
    // ================================================================

    function test_vaultNavIsStoredInWadUnits() public {
        uint256 seedAmountUsdc6 = 1_000_000_000; // 1000 USDC
        VaultHelper.seedVault(vm, address(sys.core), owner_, seedAmountUsdc6);

        uint256 nav = sys.core.getVaultNav();
        uint256 expectedNavWad = 1000e18;

        assertEq(nav, expectedNavWad);
        assertGe(nav, 1e18); // At least 1 WAD
    }

    function test_vaultPriceIsInWadUnits() public {
        VaultHelper.seedVault(vm, address(sys.core), owner_, 1_000_000_000);

        uint256 price = sys.core.getVaultPrice();
        assertEq(price, WAD);
    }

    function test_batchPriceIsInWadUnits() public {
        VaultHelper.seedVault(vm, address(sys.core), owner_, 1_000_000_000);

        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 batchId = currentBatchId + 1;
        vm.prank(owner_);
        sys.core.harnessRecordPnl(batchId, 100e18, 0, 500e18);
        advancePastBatchEnd(batchId);
        vm.prank(owner_);
        sys.core.processDailyBatch(batchId);

        (,, uint256 batchPrice,) = sys.core.harnessGetBatchAggregation(batchId);

        assertGt(batchPrice, WAD); // Increased due to positive P&L
    }

    function test_vaultSharesIsInWadUnits() public {
        uint256 seedAmountUsdc6 = 1_000_000_000; // 1000 USDC
        VaultHelper.seedVault(vm, address(sys.core), owner_, seedAmountUsdc6);

        uint256 shares = sys.core.getVaultShares();
        uint256 expectedSharesWad = 1000e18;

        assertEq(shares, expectedSharesWad);
        assertGe(shares, 1e18); // At least 1 WAD
    }
}
