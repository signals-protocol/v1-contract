// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/RedstoneHelper.sol";
import "../../base/SettlementHelper.sol";
import "../../base/SeedHelper.sol";

/// @title VaultWithMarkets E2E Tests
/// @notice 4 tests: finalize PnL, ΔEₜ grant cap wiring (3 scenarios)
contract VaultWithMarketsTest is FullSystemDeployer {
    FullSystem internal sys;
    address internal seeder;

    function setUp() public override {
        super.setUp();
        // Deploy with wider submit/ops windows matching the TS test (300/60)
        sys = deployFullSystem(300, 60);
        seeder = sys.users[0];

        // Fund seeder generously
        sys.payment.mint(seeder, 100_000e18);
        vm.prank(seeder);
        sys.payment.approve(address(sys.core), type(uint256).max);
    }

    function test_finalizePrimary_records_daily_PnL_and_vault_consumes_it() public {
        // Fix timestamp for deterministic batchId
        uint64 latest = uint64(block.timestamp);
        uint64 seedTime = batchStartTimestamp(toBatchId(latest) + 1) + 1_000;
        uint64 dayKey = toBatchId(seedTime);

        // Seed vault
        uint256 seedAmount = 1000e18;
        vm.warp(seedTime);
        vm.prank(seeder);
        sys.core.seedVault(seedAmount);

        uint64 currentBatchId = sys.core.currentBatchId();
        assertEq(currentBatchId, dayKey - 1);

        // Create market settling on the same day-key as first vault batch
        uint64 tSet = seedTime + 10;
        uint64 start = tSet - 200;
        uint64 end = tSet - 20;

        vm.prank(sys.owner);
        uint256 mktId = sys.core.createMarketUniform(0, 4, 1, start, end, tSet, 4, WAD, address(sys.feePolicy));

        // Manipulate tree state to create non-zero P&L
        uint256[] memory factors = new uint256[](4);
        factors[0] = 2e18;
        factors[1] = 1e18;
        factors[2] = 1e18;
        factors[3] = 1e18;
        vm.prank(sys.owner);
        sys.core.harnessSeedTree(mktId, factors);

        uint64 batchId = toBatchId(tSet);
        assertEq(batchId, dayKey);

        // Submit oracle price
        uint256 priceTimestamp = uint256(tSet) + 1;
        vm.warp(priceTimestamp + 1);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, mktId, 1, priceTimestamp);

        // Finalize after PendingOps ends (submitWindow=300, opsWindow=60)
        uint256 opsEnd = uint256(tSet) + 300 + 60;
        vm.warp(opsEnd + 1);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(mktId);

        // Check daily PnL before batch processing
        (, , , , , , bool processedBefore) = sys.core.getDailyPnl(batchId);
        assertFalse(processedBefore);

        uint256 navBefore = sys.core.getVaultNav();
        advancePastBatchEnd(batchId);

        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(batchId, 1, 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);

        uint256 navAfter = sys.core.getVaultNav();
        assertTrue(navAfter != navBefore);

        (, , , , , , bool processedAfter) = sys.core.getDailyPnl(batchId);
        assertTrue(processedAfter);
        assertEq(sys.core.currentBatchId(), batchId);
    }

    function test_batch_succeeds_when_grantNeed_leq_deltaEt_uniform_prior() public {
        uint64 latest = uint64(block.timestamp);
        uint64 seedTime = batchStartTimestamp(toBatchId(latest) + 1) + 1_000;

        vm.warp(seedTime);
        vm.prank(seeder);
        sys.core.seedVault(1000e18);

        // Create market with uniform prior → ΔEₜ = 0
        uint64 tSet = seedTime + 500;
        vm.prank(sys.owner);
        uint256 mktId = sys.core.createMarketUniform(
            0,
            100,
            10,
            seedTime + 100,
            tSet - 100,
            tSet,
            10,
            WAD,
            address(sys.feePolicy)
        );

        // Submit oracle and settle
        uint256 priceTimestamp = uint256(tSet) + 1;
        vm.warp(priceTimestamp);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, mktId, 50, priceTimestamp);

        uint256 opsEnd = uint256(tSet) + 300 + 60;
        vm.warp(opsEnd + 1);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(mktId);

        // Process batch
        uint64 batchId = toBatchId(tSet);
        advancePastBatchEnd(batchId);

        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(batchId, 1, 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);

        (, , , , , , bool processed) = sys.core.getDailyPnl(batchId);
        assertTrue(processed);
    }

    function test_market_deltaEt_stored_and_propagated_to_batch() public {
        uint64 latest = uint64(block.timestamp);
        uint64 seedTime = batchStartTimestamp(toBatchId(latest) + 1) + 1_000;

        vm.warp(seedTime);
        vm.prank(seeder);
        sys.core.seedVault(1000e18);

        // Increase backstopNav for prior admissibility
        uint256 backstopAmount = 10_000e6;
        sys.payment.mint(seeder, backstopAmount);
        vm.prank(seeder);
        sys.core.fundBackstop(backstopAmount);

        // Create market with concentrated prior → ΔEₜ > 0
        uint64 tSet = seedTime + 500;
        uint256[] memory concentratedFactors = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            concentratedFactors[i] = WAD;
        }
        concentratedFactors[0] = 2 * WAD;
        SeedData seedData = SeedHelper.deploySeedData(concentratedFactors);

        vm.prank(sys.owner);
        uint256 mktId = sys.core.createMarket(
            0,
            100,
            10,
            seedTime + 100,
            tSet - 100,
            tSet,
            10,
            100e18,
            address(sys.feePolicy),
            address(seedData)
        );

        vm.prank(sys.owner);
        sys.core.seedNextChunks(mktId, 10);

        // Verify market has ΔEₜ
        ISignalsCore.Market memory market = sys.core.harnessGetMarket(mktId);
        assertGt(market.deltaEt, 0);
        assertLt(market.deltaEt, 15e18);

        // Settle
        uint256 priceTimestamp = uint256(tSet) + 1;
        vm.warp(priceTimestamp);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, mktId, 50, priceTimestamp);

        uint256 opsEnd = uint256(tSet) + 300 + 60;
        vm.warp(opsEnd + 1);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(mktId);

        // Process batch
        uint64 batchId = toBatchId(tSet);
        advancePastBatchEnd(batchId);

        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(batchId, 1, 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);

        (, , , , , , bool processed) = sys.core.getDailyPnl(batchId);
        assertTrue(processed);
    }

    function test_single_market_per_batch_deltaEt_used_in_grant_cap() public {
        uint64 latest = uint64(block.timestamp);
        uint64 seedTime = batchStartTimestamp(toBatchId(latest) + 1) + 1_000;

        vm.warp(seedTime);
        vm.prank(seeder);
        sys.core.seedVault(1000e18);

        // Backstop
        uint256 backstopAmount = 10_000e6;
        sys.payment.mint(seeder, backstopAmount);
        vm.prank(seeder);
        sys.core.fundBackstop(backstopAmount);

        // Concentrated prior
        uint64 tSet = seedTime + 500;
        uint256[] memory factors = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            factors[i] = WAD;
        }
        factors[0] = 2 * WAD;
        SeedData seedData = SeedHelper.deploySeedData(factors);

        vm.prank(sys.owner);
        uint256 mktId = sys.core.createMarket(
            0,
            100,
            10,
            seedTime + 100,
            tSet - 100,
            tSet,
            10,
            100e18,
            address(sys.feePolicy),
            address(seedData)
        );

        vm.prank(sys.owner);
        sys.core.seedNextChunks(mktId, 10);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(mktId);
        assertGt(market.deltaEt, 0);

        // Settle
        uint256 priceTimestamp = uint256(tSet) + 1;
        vm.warp(priceTimestamp);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, mktId, 50, priceTimestamp);

        uint256 opsEnd = uint256(tSet) + 300 + 60;
        vm.warp(opsEnd + 1);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(mktId);

        uint64 batchId = toBatchId(tSet);
        advancePastBatchEnd(batchId);

        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(batchId, 1, 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);

        (, , , , , , bool processed) = sys.core.getDailyPnl(batchId);
        assertTrue(processed);
    }
}
