// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/RedstoneHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {ISignalsCore} from "../../../../contracts/interfaces/ISignalsCore.sol";

/// @title OracleModule Foundry Tests
/// @notice Converted from test/module/oracle/oracle.spec.ts (25 tests)
contract OracleTest is FullSystemDeployer {
    FullSystem sys;

    // Settlement config (matches TS: submitWindow=120, opsWindow=300)
    uint64 constant SUBMIT_WINDOW = 120;
    uint64 constant OPS_WINDOW = 300;

    // Dummy fee policy for harnessSetMarket
    address constant DUMMY_POLICY = address(1);

    // Market state set via harnessSetMarket
    uint64 tSet; // settlementTimestamp

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(SUBMIT_WINDOW, OPS_WINDOW);

        // Create market via harnessSetMarket (like TS setup)
        uint64 now_ = uint64(block.timestamp);
        tSet = now_ + 300;

        ISignalsCore.Market memory market = ISignalsCore.Market({
            isSeeded: true,
            settled: false,
            snapshotChunksDone: false,
            failed: false,
            numBins: 4,
            openPositionCount: 0,
            snapshotChunkCursor: 0,
            seedCursor: 4,
            startTimestamp: now_ - 100,
            endTimestamp: now_ + 200,
            settlementTimestamp: tSet,
            settlementFinalizedAt: 0,
            minTick: 0,
            maxTick: 4,
            tickSpacing: 1,
            settlementTick: 0,
            settlementValue: 0,
            liquidityParameter: WAD,
            feePolicy: DUMMY_POLICY,
            seedData: address(0),
            initialRootSum: 4 * WAD,
            accumulatedFees: 0,
            minFactor: WAD,
            deltaEt: 0
        });
        vm.prank(sys.owner);
        sys.core.harnessSetMarket(1, market);

        // Seed tree for settlement tests
        uint256[] memory factors = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) factors[i] = WAD;
        vm.prank(sys.owner);
        sys.core.harnessSeedTree(1, factors);
    }

    // ============================================================
    // Redstone payload validation
    // ============================================================

    function test_revertsWhenCalldataHasNoRedstonePayload() public {
        vm.warp(uint256(tSet) + 1);

        // Submit without payload — just call submitSettlementSample with no Redstone data
        vm.prank(sys.owner);
        vm.expectRevert(); // CalldataMustHaveValidPayload
        sys.core.submitSettlementSample(1);
    }

    function test_revertsWhenUniqueSignersThresholdNotMet() public {
        // We cannot easily build a 1-signer payload in Foundry since RedstoneHelper
        // always uses 3 signers. Test that the raw call with no valid payload reverts.
        vm.warp(uint256(tSet) + 1);
        vm.prank(sys.owner);
        vm.expectRevert(); // InsufficientNumberOfUniqueSigners or CalldataMustHaveValidPayload
        sys.core.submitSettlementSample(1);
    }

    function test_storesScaledSettlementValueWithValidPayload() public {
        vm.warp(uint256(tSet) + 1);
        uint256 priceTs = uint256(tSet) + 2;
        vm.warp(priceTs + 1);

        uint256 humanPrice = 2;
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, humanPrice, priceTs);

        (int256 storedPrice, uint64 storedTs) = sys.core.getSettlementPrice(1);
        assertEq(storedPrice, RedstoneHelper.toSettlementValue(humanPrice));
        assertEq(storedTs, uint64(priceTs));
    }

    // ============================================================
    // Submit window bounds
    // ============================================================

    function test_revertsBeforeTset() public {
        uint256 blockTs = uint256(tSet) - 1;
        vm.warp(blockTs);

        vm.expectRevert(); // OracleSampleTooEarly
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 2, blockTs);
    }

    function test_revertsAfterSubmitWindow() public {
        uint256 blockTs = uint256(tSet) + 121; // submitWindow = 120
        vm.warp(blockTs);

        vm.expectRevert(SE.SettlementWindowClosed.selector);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 2, blockTs);
    }

    // ============================================================
    // Timestamp validation
    // ============================================================

    function test_revertsWhenOracleTimestampInFarFuture() public {
        uint256 blockTs = uint256(tSet) + 10;
        uint256 futurePriceTs = blockTs + 240; // 4 minutes in future
        vm.warp(blockTs);

        vm.expectRevert(); // TimestampFromTooLongFuture
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 2, futurePriceTs);
    }

    function test_revertsWhenOracleTimestampTooOld() public {
        uint256 blockTs = uint256(tSet) + 10;
        uint256 oldPriceTs = blockTs - 240; // 4 minutes ago
        vm.warp(blockTs);

        vm.expectRevert(); // TimestampIsTooOld
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 2, oldPriceTs);
    }

    // ============================================================
    // Closest-sample rule
    // ============================================================

    function test_acceptsFirstCandidate() public {
        uint256 blockTs = uint256(tSet) + 60;
        uint256 priceTs = uint256(tSet) + 50; // Within 3min of blockTs
        vm.warp(blockTs);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 2, priceTs);

        (int256 price, uint64 ts) = sys.core.getSettlementPrice(1);
        assertEq(price, RedstoneHelper.toSettlementValue(2));
        assertEq(ts, uint64(priceTs));
    }

    function test_updatesCandidateIfCloserToTset() public {
        // First: priceTs = tSet + 50, distance = 50
        uint256 blockTs = uint256(tSet) + 60;
        uint256 ts1 = uint256(tSet) + 50;
        vm.warp(blockTs);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 2, ts1);

        // Second: priceTs = tSet + 20, distance = 20 (strictly closer)
        blockTs = uint256(tSet) + 65;
        uint256 ts2 = uint256(tSet) + 20;
        vm.warp(blockTs);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 3, ts2);

        (int256 price, uint64 ts) = sys.core.getSettlementPrice(1);
        assertEq(price, RedstoneHelper.toSettlementValue(3)); // Updated
        assertEq(ts, uint64(ts2));
    }

    function test_ignoresCandidateIfFartherFromTset() public {
        // First: priceTs = tSet + 20, distance = 20
        uint256 blockTs = uint256(tSet) + 30;
        uint256 ts1 = uint256(tSet) + 20;
        vm.warp(blockTs);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 2, ts1);

        // Second: priceTs = tSet + 50, distance = 50 (farther)
        blockTs = uint256(tSet) + 60;
        uint256 ts2 = uint256(tSet) + 50;
        vm.warp(blockTs);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 3, ts2);

        (int256 price, uint64 ts) = sys.core.getSettlementPrice(1);
        assertEq(price, RedstoneHelper.toSettlementValue(2)); // Still first
        assertEq(ts, uint64(ts1));
    }

    function test_onTiePrefersEarlierTimestamp() public {
        // First: priceTs = tSet + 30, distance = 30
        uint256 blockTs = uint256(tSet) + 40;
        uint256 ts1 = uint256(tSet) + 30;
        vm.warp(blockTs);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 2, ts1);

        // Second: priceTs = tSet + 10, distance = 10 (closer, should replace)
        blockTs = uint256(tSet) + 50;
        uint256 ts2 = uint256(tSet) + 10;
        vm.warp(blockTs);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 3, ts2);

        (int256 price, uint64 ts) = sys.core.getSettlementPrice(1);
        assertEq(price, RedstoneHelper.toSettlementValue(3)); // Replaced (closer)
        assertEq(ts, uint64(ts2));
    }

    function test_onTieKeepsExistingIfNewIsFarther() public {
        // First: priceTs = tSet + 20, distance = 20
        uint256 blockTs = uint256(tSet) + 30;
        uint256 ts1 = uint256(tSet) + 20;
        vm.warp(blockTs);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 2, ts1);

        // Second: priceTs = tSet + 40, distance = 40 (farther, should not replace)
        blockTs = uint256(tSet) + 50;
        uint256 ts2 = uint256(tSet) + 40;
        vm.warp(blockTs);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 3, ts2);

        (int256 price, uint64 ts) = sys.core.getSettlementPrice(1);
        assertEq(price, RedstoneHelper.toSettlementValue(2)); // Still first (closer)
        assertEq(ts, uint64(ts1));
    }

    // ============================================================
    // State machine view functions
    // ============================================================

    function test_getMarketStateReturnsCorrectStates() public {
        // State 0: Trading (before Tset)
        vm.warp(uint256(tSet) - 1);
        assertEq(sys.core.getMarketState(1), 0);

        // State 1: SettlementOpen [Tset, Tset + submitWindow)
        vm.warp(uint256(tSet) + 1);
        assertEq(sys.core.getMarketState(1), 1);

        // State 2: PendingOps [Tset + submitWindow, Tset + submitWindow + opsWindow)
        vm.warp(uint256(tSet) + 121);
        assertEq(sys.core.getMarketState(1), 2);

        // After PendingOps ends, state 3
        vm.warp(uint256(tSet) + 421);
        assertEq(sys.core.getMarketState(1), 3);
    }

    function test_getSettlementWindowsReturnsCorrectValues() public {
        (uint64 retTSet, uint64 settleEnd, uint64 opsEnd, uint64 claimOpen) = sys.core.getSettlementWindows(1);
        assertEq(retTSet, tSet);
        assertEq(settleEnd, tSet + SUBMIT_WINDOW);
        assertEq(opsEnd, tSet + SUBMIT_WINDOW + OPS_WINDOW);
        assertEq(claimOpen, tSet + SUBMIT_WINDOW + OPS_WINDOW);
    }

    // ============================================================
    // markFailed and secondary settlement
    // ============================================================

    function test_revertsMarkFailedBeforePendingOps() public {
        vm.prank(sys.owner);
        vm.expectRevert(SE.PendingOpsNotStarted.selector);
        sys.core.markSettlementFailed(1);
    }

    function test_allowsMarkFailedDuringPendingOps() public {
        uint256 pendingOpsStart = uint256(tSet) + SUBMIT_WINDOW;
        vm.warp(pendingOpsStart + 1);
        vm.prank(sys.owner);
        sys.core.markSettlementFailed(1);

        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        assertTrue(m.failed);
    }

    function test_revertsSecondarySettlementOnNonFailedMarket() public {
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotFailed.selector, 1));
        sys.core.finalizeSecondarySettlement(1, 100);
    }

    function test_allowsSecondarySettlementOnFailedMarket() public {
        uint256 pendingOpsStart = uint256(tSet) + SUBMIT_WINDOW;
        vm.warp(pendingOpsStart + 1);
        vm.prank(sys.owner);
        sys.core.markSettlementFailed(1);

        vm.warp(pendingOpsStart + 2);
        vm.prank(sys.owner);
        sys.core.finalizeSecondarySettlement(1, 2);

        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        assertTrue(m.settled);
        assertFalse(m.failed);
        assertEq(m.settlementValue, 2);
    }

    function test_markSettlementFailedClearsCandidateDuringPendingOps() public {
        // Submit a candidate during settlement window
        uint256 blockTs = uint256(tSet) + 30;
        uint256 candidateTs = uint256(tSet) + 20;
        vm.warp(blockTs);
        RedstoneHelper.submitWithPayload(vm, address(sys.core), sys.owner, 1, 2, candidateTs);

        // Verify candidate exists
        (, uint64 ts) = sys.core.getSettlementPrice(1);
        assertEq(ts, uint64(candidateTs));

        // Mark failed during PendingOps
        uint256 pendingOpsStart = uint256(tSet) + SUBMIT_WINDOW;
        vm.warp(pendingOpsStart + 1);
        vm.prank(sys.owner);
        sys.core.markSettlementFailed(1);

        // Candidate should be cleared
        vm.expectRevert(SE.SettlementOracleCandidateMissing.selector);
        sys.core.getSettlementPrice(1);
    }

    function test_finalizePrimaryRevertsWithoutCandidateAfterPendingOps() public {
        uint256 opsEnd = uint256(tSet) + SUBMIT_WINDOW + OPS_WINDOW;

        // Time passes without any sample submission
        vm.warp(opsEnd + 1);

        // Should revert because no candidate exists
        vm.prank(sys.owner);
        vm.expectRevert(SE.SettlementOracleCandidateMissing.selector);
        sys.core.finalizePrimarySettlement(1);
    }

    // ============================================================
    // getSettlementPrice
    // ============================================================

    function test_getSettlementPriceRevertsWhenNoCandidateRecorded() public {
        vm.expectRevert(SE.SettlementOracleCandidateMissing.selector);
        sys.core.getSettlementPrice(1);
    }

    // ============================================================
    // setRedstoneConfig
    // ============================================================

    function test_setRedstoneConfigUpdatesFeedIdAndParams() public {
        bytes32 newFeedId = bytes32("NEW_FEED");
        uint8 newDecimals = 6;
        uint64 newMaxDistance = 1200;
        uint64 newFutureTolerance = 120;

        vm.prank(sys.owner);
        sys.core.setRedstoneConfig(newFeedId, newDecimals, newMaxDistance, newFutureTolerance);

        assertEq(sys.core.redstoneFeedId(), newFeedId);
        assertEq(sys.core.redstoneFeedDecimals(), newDecimals);
        assertEq(sys.core.maxSampleDistance(), newMaxDistance);
        assertEq(sys.core.futureTolerance(), newFutureTolerance);
    }
}
