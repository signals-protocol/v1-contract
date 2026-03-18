// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/SeedHelper.sol";
import "../../base/VaultHelper.sol";
import "../../base/RedstoneHelper.sol";

/// @title Vault Lifecycle E2E Tests
/// @notice 1 test: seed → deposit → process batch → withdraw lifecycle
contract VaultLifecycleTest is FullSystemDeployer {
    FullSystem internal sys;
    address internal user;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(5, 5);
        user = sys.users[0];
    }

    /// @notice Helper to create a failed market in a specific batch and finalize secondary settlement
    function _createFailedMarketInBatch(uint64 batchId) internal returns (uint256 mktId) {
        uint64 bStart = batchStartTimestamp(batchId);
        uint64 bEnd = batchEndTimestamp(batchId);

        uint64 now_ = uint64(block.timestamp);
        uint64 settlementTs = bStart + 1000;
        if (settlementTs <= now_) {
            settlementTs = now_ + 60;
        }
        if (settlementTs >= bEnd) {
            settlementTs = bEnd - 1;
        }

        uint64 startTs = settlementTs - 300;
        uint64 endTs = settlementTs - 100;

        uint256[] memory factors = uniformFactors(10);
        SeedData seedData = SeedHelper.deploySeedData(factors);

        vm.prank(sys.owner);
        mktId = sys.core.createMarket(
            0,
            100,
            10,
            startTs,
            endTs,
            settlementTs,
            10,
            100e18,
            address(sys.feePolicy),
            address(seedData)
        );

        vm.prank(sys.owner);
        sys.core.seedNextChunks(mktId, 10);

        uint64 submitWindow = 5;
        uint64 opsStart = settlementTs + submitWindow + 1;
        vm.warp(opsStart);

        vm.prank(sys.owner);
        sys.core.markSettlementFailed(mktId);

        vm.prank(sys.owner);
        sys.core.finalizeSecondarySettlement(mktId, 100_000_000);
    }

    function test_seeds_deposits_processes_batch_and_withdraws() public {
        address coreAddress = address(sys.core);

        // Configure risk and fee waterfall
        vm.startPrank(sys.owner);
        sys.core.setRiskConfig(0.3e18, WAD, false);
        sys.core.setFeeWaterfallConfig(0, WAD, 0, 0);
        vm.stopPrank();

        // Seed vault
        uint256 seedAmount = 5_000_000;
        sys.payment.mint(sys.owner, seedAmount);
        vm.startPrank(sys.owner);
        sys.payment.approve(coreAddress, seedAmount);
        sys.core.seedVault(seedAmount);
        vm.stopPrank();

        // Fund user and deposit
        uint256 depositAmount = 2_000_000;
        sys.payment.mint(user, depositAmount);
        vm.startPrank(user);
        sys.payment.approve(coreAddress, depositAmount);
        uint64 depositRequestId = sys.core.requestDeposit(depositAmount);
        vm.stopPrank();

        // Process a batch with a failed market so we can claim
        uint64 currentBatch = sys.core.getCurrentBatchId();
        uint64 batchId = currentBatch + 1;
        _createFailedMarketInBatch(batchId);
        advancePastBatchEnd(batchId);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);

        vm.prank(user);
        sys.core.claimDeposit(depositRequestId);

        uint256 shares = sys.lpShare.balanceOf(user);
        assertGt(shares, 0);

        // Request withdrawal
        uint256 withdrawShares = shares / 2;
        vm.prank(user);
        sys.core.requestWithdraw(withdrawShares);

        // Process batches through withdrawal lag
        uint64 lag = sys.core.getWithdrawalLagBatches();
        uint64 currentBatchAfter = sys.core.getCurrentBatchId();
        uint64 eligibleBatchId = currentBatchAfter + lag + 1;
        for (uint64 batch = currentBatchAfter + 1; batch <= eligibleBatchId; batch++) {
            _createFailedMarketInBatch(batch);
            advancePastBatchEnd(batch);
            vm.prank(sys.owner);
            sys.core.processDailyBatch(batch);
        }

        uint256 balanceBefore = sys.payment.balanceOf(user);
        vm.prank(user);
        sys.core.claimWithdraw(0);
        uint256 balanceAfter = sys.payment.balanceOf(user);
        assertGt(balanceAfter, balanceBefore);
    }
}
