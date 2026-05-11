// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/RedstoneHelper.sol";
import "../../base/SeedHelper.sol";
import "../../base/SettlementHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {ISignalsCore} from "../../../../contracts/interfaces/ISignalsCore.sol";

/// @title MarketLifecycleModule Foundry Tests
/// @notice Converted from test/module/lifecycle/market.spec.ts (38 tests)
contract MarketLifecycleTest is FullSystemDeployer {
    FullSystem sys;

    // Settlement config (matches TS: submitWindow=120, opsWindow=60)
    uint64 constant SUBMIT_WINDOW = 120;
    uint64 constant OPS_WINDOW = 60;

    // Redstone price config
    uint256 constant HUMAN_PRICE = 2;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(SUBMIT_WINDOW, OPS_WINDOW);
    }

    // ============================================================
    // Helper: create a default market (seeded, active)
    // ============================================================

    function _createDefaultMarket() internal returns (uint256 marketId, uint64 start, uint64 end_) {
        uint64 now_ = uint64(block.timestamp);
        start = now_ - 100;
        end_ = now_ + 200;
        vm.prank(sys.owner);
        marketId = sys.core
            .createMarketUniform(
                0, // minTick
                4, // maxTick
                1, // tickSpacing
                start,
                end_,
                end_, // settlementTimestamp = endTimestamp
                4, // numBins
                WAD, // liquidityParameter
                address(sys.feePolicy)
            );
    }

    /// @dev Build a cloned market struct with overrides
    function _cloneMarket(
        ISignalsCore.Market memory m,
        bool overrideSettled,
        bool settled,
        bool overrideFailed,
        bool failed,
        uint32 overrideOpenPosCount,
        uint32 overrideSnapshotCursor,
        bool overrideSnapshotDone,
        bool snapshotDone
    ) internal pure returns (ISignalsCore.Market memory) {
        if (overrideSettled) m.settled = settled;
        if (overrideFailed) m.failed = failed;
        if (overrideOpenPosCount > 0) m.openPositionCount = overrideOpenPosCount;
        if (overrideSnapshotCursor > 0) m.snapshotChunkCursor = overrideSnapshotCursor;
        if (overrideSnapshotDone) m.snapshotChunksDone = snapshotDone;
        return m;
    }

    // ============================================================
    // Test: creates market and seeds tree via chunks
    // ============================================================

    function test_createMarketAndSeedTreeViaChunks() public {
        uint64 now_ = uint64(block.timestamp);
        uint64 start = now_ + 10;
        uint64 end_ = start + 100;
        uint64 settlementTs = end_ + 50;

        uint256[] memory factors = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            factors[i] = WAD;
        }

        SeedData seedData = SeedHelper.deploySeedData(factors);

        vm.prank(sys.owner);
        uint256 marketId = sys.core
        .createMarket(0, 4, 1, start, end_, settlementTs, 4, WAD, address(sys.feePolicy), address(seedData));

        vm.prank(sys.owner);
        sys.core.seedNextChunks(marketId, 4);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertTrue(market.isSeeded);
        assertEq(market.numBins, 4);
        assertEq(market.liquidityParameter, WAD);
        assertEq(sys.core.harnessGetTreeSize(marketId), 4);
        assertEq(sys.core.harnessGetTreeSum(marketId), 4 * WAD);
    }

    function test_createMarketStoresOracleConfig() public {
        uint64 now_ = uint64(block.timestamp);
        SeedData seedData = _uniformSeedData(4);
        ISignalsCore.MarketOracleConfig memory oracleConfig =
            ISignalsCore.MarketOracleConfig({feedId: bytes32("ETH"), feedDecimals: 18, tickScale: 1_000_000_000_000});

        vm.prank(sys.owner);
        uint256 marketId = sys.core
            .createMarket(
                0,
                4,
                1,
                now_ + 10,
                now_ + 100,
                now_ + 150,
                4,
                WAD,
                address(sys.feePolicy),
                address(seedData),
                oracleConfig
            );

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertEq(market.feedId, oracleConfig.feedId);
        assertEq(market.feedDecimals, oracleConfig.feedDecimals);
        assertEq(market.tickScale, oracleConfig.tickScale);
    }

    function test_createMarketRejectsInvalidOracleConfig() public {
        uint64 now_ = uint64(block.timestamp);
        SeedData seedData = _uniformSeedData(4);

        _expectInvalidOracleConfig(
            now_, seedData, ISignalsCore.MarketOracleConfig({feedId: bytes32(0), feedDecimals: 8, tickScale: 1_000_000})
        );
        _expectInvalidOracleConfig(
            now_,
            seedData,
            ISignalsCore.MarketOracleConfig({feedId: bytes32("BTC"), feedDecimals: 0, tickScale: 1_000_000})
        );
        _expectInvalidOracleConfig(
            now_,
            seedData,
            ISignalsCore.MarketOracleConfig({feedId: bytes32("BTC"), feedDecimals: 19, tickScale: 1_000_000})
        );
        _expectInvalidOracleConfig(
            now_, seedData, ISignalsCore.MarketOracleConfig({feedId: bytes32("BTC"), feedDecimals: 8, tickScale: 0})
        );
    }

    function test_finalizeSecondarySettlementUsesMarketTickScale() public {
        uint64 now_ = uint64(block.timestamp);
        uint64 start = now_ + 10;
        uint64 settlementTs = now_ + 100;
        SeedData seedData = _uniformSeedData(4);

        vm.prank(sys.owner);
        uint256 marketId = sys.core
            .createMarket(
                0,
                400,
                100,
                start,
                settlementTs,
                settlementTs,
                4,
                WAD,
                address(sys.feePolicy),
                address(seedData),
                ISignalsCore.MarketOracleConfig({feedId: bytes32("BTC"), feedDecimals: 8, tickScale: 100})
            );
        vm.prank(sys.owner);
        sys.core.seedNextChunks(marketId, 4);

        vm.warp(uint256(settlementTs) + SUBMIT_WINDOW + 1);
        vm.startPrank(sys.owner);
        sys.core.markSettlementFailed(marketId);
        sys.core.finalizeSecondarySettlement(marketId, 25_000);
        vm.stopPrank();

        assertEq(sys.core.harnessGetMarket(marketId).settlementTick, 200);
    }

    function test_finalizeSecondarySettlementRevertsWhenOracleConfigMissing() public {
        (uint256 marketId,, uint64 settlementTs) = _createDefaultMarket();
        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        market.tickScale = 0;
        vm.prank(sys.owner);
        sys.core.harnessSetMarket(marketId, market);

        vm.warp(uint256(settlementTs) + SUBMIT_WINDOW + 1);
        vm.startPrank(sys.owner);
        sys.core.markSettlementFailed(marketId);
        vm.expectRevert(abi.encodeWithSelector(SE.OracleConfigMissing.selector, marketId));
        sys.core.finalizeSecondarySettlement(marketId, 1_000_000);
        vm.stopPrank();
    }

    // ============================================================
    // Test: reverts seeding for unknown market
    // ============================================================

    function test_revertsSeedingForUnknownMarket() public {
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotFound.selector, 999));
        sys.core.seedNextChunks(999, 1);
    }

    function _uniformSeedData(uint32 numBins) internal returns (SeedData seedData) {
        uint256[] memory factors = new uint256[](numBins);
        for (uint256 i = 0; i < numBins; i++) {
            factors[i] = WAD;
        }
        seedData = SeedHelper.deploySeedData(factors);
    }

    function _expectInvalidOracleConfig(
        uint64 now_,
        SeedData seedData,
        ISignalsCore.MarketOracleConfig memory oracleConfig
    ) internal {
        vm.prank(sys.owner);
        vm.expectRevert(SE.InvalidOracleConfig.selector);
        sys.core
            .createMarket(
                0,
                4,
                1,
                now_ + 10,
                now_ + 100,
                now_ + 150,
                4,
                WAD,
                address(sys.feePolicy),
                address(seedData),
                oracleConfig
            );
    }

    // ============================================================
    // Test: seeds in multiple chunks and completes only on final chunk
    // ============================================================

    function test_seedsInMultipleChunks() public {
        uint64 now_ = uint64(block.timestamp);
        uint64 start = now_ + 10;
        uint64 end_ = start + 100;
        uint64 settlementTs = end_ + 50;

        // Fund backstop for risk gate
        sys.payment.transfer(sys.owner, 1_000_000e6);
        vm.prank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(sys.owner);
        sys.core.fundBackstop(1_000_000e6);

        uint256[] memory factors = new uint256[](5);
        factors[0] = WAD;
        factors[1] = WAD * 2;
        factors[2] = WAD * 3;
        factors[3] = WAD * 4;
        factors[4] = WAD * 5;

        SeedData seedData = SeedHelper.deploySeedData(factors);

        vm.prank(sys.owner);
        uint256 marketId = sys.core
        .createMarket(0, 5, 1, start, end_, settlementTs, 5, WAD, address(sys.feePolicy), address(seedData));

        // Zero limit reverts
        vm.prank(sys.owner);
        vm.expectRevert(SE.ZeroLimit.selector);
        sys.core.seedNextChunks(marketId, 0);

        // Chunk 1: seed 2
        vm.prank(sys.owner);
        sys.core.seedNextChunks(marketId, 2);
        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertEq(market.seedCursor, 2);
        assertFalse(market.isSeeded);

        // Chunk 2: seed 2 more
        vm.prank(sys.owner);
        sys.core.seedNextChunks(marketId, 2);
        market = sys.core.harnessGetMarket(marketId);
        assertEq(market.seedCursor, 4);
        assertFalse(market.isSeeded);

        // Chunk 3: seed remaining (ask for 10, only 1 left)
        vm.prank(sys.owner);
        sys.core.seedNextChunks(marketId, 10);
        market = sys.core.harnessGetMarket(marketId);
        assertEq(market.seedCursor, 5);
        assertTrue(market.isSeeded);

        // Re-seed reverts
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.SeedAlreadyComplete.selector, marketId));
        sys.core.seedNextChunks(marketId, 1);
    }

    // ============================================================
    // Test: rejects invalid market parameters and time ranges
    // ============================================================

    function test_rejectsInvalidMarketParams_zeroBins() public {
        vm.prank(sys.owner);
        vm.expectRevert(); // InvalidMarketParameters
        sys.core.createMarketUniform(0, 0, 1, 0, 1, 1, 1, WAD, address(sys.feePolicy));
    }

    function test_rejectsInvalidMarketParams_zeroSpacing() public {
        vm.prank(sys.owner);
        vm.expectRevert(); // InvalidMarketParameters
        sys.core.createMarketUniform(0, 4, 0, 0, 1, 1, 1, WAD, address(sys.feePolicy));
    }

    function test_rejectsInvalidTimeRange_startAfterEnd() public {
        vm.prank(sys.owner);
        vm.expectRevert(); // InvalidTimeRange
        sys.core.createMarketUniform(0, 4, 1, 10, 5, 5, 4, WAD, address(sys.feePolicy));
    }

    function test_rejectsInvalidTimeRange_settlementBeforeEnd() public {
        vm.prank(sys.owner);
        vm.expectRevert(); // InvalidTimeRange
        sys.core.createMarketUniform(0, 4, 1, 0, 10, 5, 4, WAD, address(sys.feePolicy));
    }

    function test_rejectsZeroLiquidityParameter() public {
        vm.prank(sys.owner);
        vm.expectRevert(SE.InvalidLiquidityParameter.selector);
        sys.core.createMarketUniform(0, 4, 1, 0, 10, 10, 4, 0, address(sys.feePolicy));
    }

    // ============================================================
    // Test: reverts when fee policy is zero
    // ============================================================

    function test_revertsWhenFeePolicyIsZero() public {
        uint64 now_ = uint64(block.timestamp);
        vm.prank(sys.owner);
        vm.expectRevert(SE.ZeroAddress.selector);
        sys.core.createMarketUniform(0, 4, 1, now_ + 10, now_ + 100, now_ + 150, 4, WAD, address(0));
    }

    // ============================================================
    // Test: settles market when candidate exists and marks snapshot state
    // ============================================================

    function test_settlesMarketWithCandidate() public {
        (uint256 marketId,, uint64 end_) = _createDefaultMarket();
        uint64 tSet = end_; // settlementTimestamp = endTimestamp

        // Submit oracle candidate during settlement window
        uint256 candidateTs = uint256(tSet) + 10;
        vm.warp(candidateTs + 1);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, marketId, HUMAN_PRICE, candidateTs);

        // Set open positions to keep snapshotChunksDone false
        ISignalsCore.Market memory mkt = sys.core.harnessGetMarket(marketId);
        mkt.openPositionCount = 10;
        vm.prank(sys.owner);
        sys.core.harnessSetMarket(marketId, mkt);

        // Finalize after PendingOps ends
        uint256 opsEnd = uint256(tSet) + SUBMIT_WINDOW + OPS_WINDOW;
        vm.warp(opsEnd + 1);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(marketId);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertTrue(market.settled);
        assertEq(market.settlementValue, RedstoneHelper.toSettlementValue(HUMAN_PRICE));
        assertEq(market.snapshotChunkCursor, 0);
        assertFalse(market.snapshotChunksDone);

        // Candidate should be cleared after settlement
        vm.expectRevert(SE.SettlementOracleCandidateMissing.selector);
        sys.core.getSettlementPrice(marketId);
    }

    // ============================================================
    // Test: finalizePrimary enforces candidate and window checks
    // ============================================================

    function test_finalizePrimaryEnforcesCandidateAndWindowChecks() public {
        (uint256 marketId,, uint64 end_) = _createDefaultMarket();
        uint64 tSet = end_;
        uint256 opsEnd = uint256(tSet) + SUBMIT_WINDOW + OPS_WINDOW;

        // Test 1: Submit before Tset - should revert
        uint256 earlyBlockTs = uint256(tSet) - 1;
        vm.warp(earlyBlockTs);
        vm.expectRevert(); // OracleSampleTooEarly
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, marketId, HUMAN_PRICE, earlyBlockTs);

        // Test 2: Valid candidate within window
        uint256 goodTs = uint256(tSet) + 10;
        vm.warp(goodTs + 1);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, marketId, HUMAN_PRICE, goodTs);

        // Test 3: Finalize before opsStart - should revert with PendingOpsNotStarted
        vm.warp(goodTs + 10);
        vm.prank(sys.owner);
        vm.expectRevert(SE.PendingOpsNotStarted.selector);
        sys.core.finalizePrimarySettlement(marketId);

        // Test 4: Submit after window - should revert
        uint256 lateBlockTs = uint256(tSet) + 121;
        vm.warp(lateBlockTs);
        vm.expectRevert(SE.SettlementWindowClosed.selector);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, marketId, HUMAN_PRICE, lateBlockTs);

        // Test 5: Finalize after opsEnd - should succeed
        vm.warp(opsEnd + 2);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(marketId);
    }

    // ============================================================
    // Test: finalizePrimary allows during PendingOps window
    // ============================================================

    function test_finalizePrimaryAllowsDuringPendingOps() public {
        (uint256 marketId,, uint64 end_) = _createDefaultMarket();
        uint64 tSet = end_;

        uint256 candidateTs = uint256(tSet) + 10;
        vm.warp(candidateTs + 1);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, marketId, HUMAN_PRICE, candidateTs);

        uint256 opsStart = uint256(tSet) + SUBMIT_WINDOW;
        vm.warp(opsStart + 1);
        vm.prank(sys.owner);
        sys.core.finalizePrimarySettlement(marketId);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertTrue(market.settled);
    }

    // ============================================================
    // Test: marks settlement failed during PendingOps window when no candidate
    // ============================================================

    function test_marksSettlementFailedDuringPendingOps() public {
        (uint256 marketId,, uint64 end_) = _createDefaultMarket();
        uint64 tSet = end_;
        uint256 opsStart = uint256(tSet) + SUBMIT_WINDOW;

        // Move to PendingOps window (no candidate submitted)
        vm.warp(opsStart + 1);
        vm.prank(sys.owner);
        sys.core.markSettlementFailed(marketId);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertTrue(market.failed);
        assertFalse(market.settled);
    }

    // ============================================================
    // Test: rejects markSettlementFailed before PendingOps starts
    // ============================================================

    function test_rejectsMarkFailedBeforePendingOps() public {
        (uint256 marketId,, uint64 end_) = _createDefaultMarket();
        uint64 tSet = end_;

        vm.warp(uint256(tSet) + 10);
        vm.prank(sys.owner);
        vm.expectRevert(SE.PendingOpsNotStarted.selector);
        sys.core.markSettlementFailed(marketId);
    }

    // ============================================================
    // Test: rejects markSettlementFailed after PendingOps if candidate exists
    // ============================================================

    function test_rejectsMarkFailedIfCandidateExists() public {
        (uint256 marketId,, uint64 end_) = _createDefaultMarket();
        uint64 tSet = end_;
        uint256 opsEnd = uint256(tSet) + SUBMIT_WINDOW + OPS_WINDOW;

        // Submit candidate
        uint256 candidateTs = uint256(tSet) + 10;
        vm.warp(candidateTs + 1);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, marketId, HUMAN_PRICE, candidateTs);

        // After PendingOps with candidate - should revert
        vm.warp(opsEnd + 1);
        vm.prank(sys.owner);
        vm.expectRevert(SE.SettlementOracleCandidateMissing.selector);
        sys.core.markSettlementFailed(marketId);
    }

    // ============================================================
    // Test: finalizes secondary settlement for failed market
    // ============================================================

    function test_finalizesSecondarySettlementForFailedMarket() public {
        (uint256 marketId,, uint64 end_) = _createDefaultMarket();
        uint64 tSet = end_;
        uint256 opsStart = uint256(tSet) + SUBMIT_WINDOW;

        // Mark as failed first
        vm.warp(opsStart + 1);
        vm.prank(sys.owner);
        sys.core.markSettlementFailed(marketId);

        // Finalize secondary settlement with ops-provided value
        int256 settlementValue = 2_000_000; // 2.0 in 6 decimals
        vm.prank(sys.owner);
        sys.core.finalizeSecondarySettlement(marketId, settlementValue);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertTrue(market.settled);
        assertFalse(market.failed);
        assertEq(market.settlementValue, settlementValue);
    }

    // ============================================================
    // Test: rejects finalizeSecondarySettlement for non-failed market
    // ============================================================

    function test_rejectsSecondarySettlementForNonFailedMarket() public {
        (uint256 marketId,,) = _createDefaultMarket();

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotFailed.selector, marketId));
        sys.core.finalizeSecondarySettlement(marketId, 1_000_000);
    }

    // ============================================================
    // Test: rejects finalizeSecondarySettlement for already settled market
    // ============================================================

    function test_rejectsSecondarySettlementForAlreadySettledMarket() public {
        (uint256 marketId,, uint64 end_) = _createDefaultMarket();
        uint64 tSet = end_;
        uint256 opsStart = uint256(tSet) + SUBMIT_WINDOW;

        // Mark as failed
        vm.warp(opsStart + 1);
        vm.prank(sys.owner);
        sys.core.markSettlementFailed(marketId);

        // First secondary settlement
        vm.prank(sys.owner);
        sys.core.finalizeSecondarySettlement(marketId, 2_000_000);

        // Second attempt should fail
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketAlreadySettled.selector, marketId));
        sys.core.finalizeSecondarySettlement(marketId, 1_000_000);
    }

    // ============================================================
    // Test: updates market timing
    // ============================================================

    function test_updatesMarketTiming() public {
        (uint256 marketId,,) = _createDefaultMarket();

        // Invalid time range
        vm.prank(sys.owner);
        vm.expectRevert(); // InvalidTimeRange
        sys.core.updateMarketTiming(marketId, 10, 5, 5);

        uint64 now_ = uint64(block.timestamp);
        uint64 start = now_ + 5;
        uint64 end_ = start + 10;
        uint64 settlement = end_ + 5;

        vm.prank(sys.owner);
        sys.core.updateMarketTiming(marketId, start, end_, settlement);
        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertEq(market.startTimestamp, start);
        assertEq(market.endTimestamp, end_);
        assertEq(market.settlementTimestamp, settlement);
    }

    // ============================================================
    // Test: emits settlement chunk requests and marks completion
    // ============================================================

    function test_settlementChunkRequestsAndCompletion() public {
        (uint256 marketId,,) = _createDefaultMarket();

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        market.settled = true;
        market.openPositionCount = 1000;
        vm.prank(sys.owner);
        sys.core.harnessSetMarket(marketId, market);

        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 1);
        ISignalsCore.Market memory updated = sys.core.harnessGetMarket(marketId);
        assertEq(updated.snapshotChunkCursor, 1);
        assertFalse(updated.snapshotChunksDone);

        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);
        updated = sys.core.harnessGetMarket(marketId);
        assertEq(updated.snapshotChunkCursor, 2); // ceil(1000/512) = 2
        assertTrue(updated.snapshotChunksDone);

        // Already completed
        vm.prank(sys.owner);
        vm.expectRevert(SE.SnapshotAlreadyCompleted.selector);
        sys.core.requestSettlementChunks(marketId, 1);
    }

    // ============================================================
    // Test: rejects re-settlement and supports multi-chunk ordering
    // ============================================================

    function test_rejectsReSettlementAndMultiChunkOrdering() public {
        (uint256 marketId,,) = _createDefaultMarket();

        // Mark as settled with large openPositionCount = 1025 → ceil(1025/512) = 3 chunks
        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        market.settled = true;
        market.openPositionCount = 1025;
        market.snapshotChunkCursor = 0;
        market.snapshotChunksDone = false;
        vm.prank(sys.owner);
        sys.core.harnessSetMarket(marketId, market);

        // Re-settlement should revert
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketAlreadySettled.selector, marketId));
        sys.core.finalizePrimarySettlement(marketId);

        // Chunk 1: request 2
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 2);
        ISignalsCore.Market memory updated = sys.core.harnessGetMarket(marketId);
        assertEq(updated.snapshotChunkCursor, 2);
        assertFalse(updated.snapshotChunksDone);

        // Chunk 2: request 2 more (only 1 left → completes)
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 2);
        updated = sys.core.harnessGetMarket(marketId);
        assertEq(updated.snapshotChunkCursor, 3);
        assertTrue(updated.snapshotChunksDone);
    }

    // ============================================================
    // Test: handles zero open positions and chunk input validation
    // ============================================================

    function test_handlesZeroOpenPositionsAndChunkValidation() public {
        (uint256 marketId,,) = _createDefaultMarket();

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        market.settled = true;
        market.openPositionCount = 0;
        vm.prank(sys.owner);
        sys.core.harnessSetMarket(marketId, market);

        // Zero limit
        vm.prank(sys.owner);
        vm.expectRevert(SE.ZeroLimit.selector);
        sys.core.requestSettlementChunks(marketId, 0);

        // With 0 open positions, should complete immediately without emitting chunks
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);
        ISignalsCore.Market memory updated = sys.core.harnessGetMarket(marketId);
        assertTrue(updated.snapshotChunksDone);

        // Not settled should revert
        market.settled = false;
        vm.prank(sys.owner);
        sys.core.harnessSetMarket(marketId, market);
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotSettled.selector, marketId));
        sys.core.requestSettlementChunks(marketId, 1);
    }
}
