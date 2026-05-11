// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/SignalsBaseTest.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {ISignalsCore} from "../../../../contracts/interfaces/ISignalsCore.sol";
import "../../../../contracts/testonly/TradeModuleHarness.sol";

/// @title TradeModule Validation Foundry Tests
/// @notice Converted from test/module/trade/validation.spec.ts (5 tests)
contract ValidationTest is SignalsBaseTest {
    TradeModuleHarness harness;

    address constant DUMMY_POLICY = address(1);

    function setUp() public override {
        super.setUp();
        harness = new TradeModuleHarness();
    }

    /// @dev Build a test market struct with configurable fields
    function _buildMarket(
        uint64,
        uint32 numBins,
        int256 tickSpacing,
        int256 maxTick,
        bool isSeeded,
        uint64 startTimestamp,
        uint64 endTimestamp
    ) internal pure returns (ISignalsCore.Market memory) {
        return ISignalsCore.Market({
            isSeeded: isSeeded,
            settled: false,
            snapshotChunksDone: false,
            failed: false,
            numBins: numBins,
            openPositionCount: 0,
            snapshotChunkCursor: 0,
            seedCursor: numBins,
            startTimestamp: startTimestamp,
            endTimestamp: endTimestamp,
            settlementTimestamp: uint64(uint256(endTimestamp) + 100),
            settlementFinalizedAt: 0,
            minTick: 0,
            maxTick: maxTick,
            tickSpacing: tickSpacing,
            settlementTick: 0,
            settlementValue: 0,
            liquidityParameter: WAD,
            feePolicy: DUMMY_POLICY,
            seedData: address(0),
            initialRootSum: uint256(numBins) * WAD,
            accumulatedFees: 0,
            minFactor: WAD,
            deltaEt: 0,
            feedId: bytes32("BTC"),
            feedDecimals: 8,
            tickScale: 1_000_000
        });
    }

    function _defaultMarket() internal view returns (ISignalsCore.Market memory) {
        uint64 now_ = uint64(block.timestamp);
        return _buildMarket(now_, 4, 1, 4, true, now_ - 10, now_ + 1_000);
    }

    // ============================================================
    // Test: reverts when market does not exist
    // ============================================================

    function test_revertsWhenMarketDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotFound.selector, 1));
        harness.exposedLoadAndValidateMarket(1);
    }

    // ============================================================
    // Test: reverts when market is not seeded
    // ============================================================

    function test_revertsWhenMarketIsNotSeeded() public {
        uint64 now_ = uint64(block.timestamp);
        harness.setMarket(1, _buildMarket(now_, 4, 1, 4, false, now_ - 10, now_ + 1_000));

        vm.expectRevert(SE.MarketNotSeeded.selector);
        harness.exposedLoadAndValidateMarket(1);
    }

    // ============================================================
    // Test: reverts when market has not started or already expired
    // ============================================================

    function test_revertsWhenMarketNotStartedOrExpired() public {
        uint64 now_ = uint64(block.timestamp);

        // Not started
        harness.setMarket(1, _buildMarket(now_, 4, 1, 4, true, now_ + 100, now_ + 1_000));
        vm.expectRevert(SE.MarketNotStarted.selector);
        harness.exposedLoadAndValidateMarket(1);

        // Expired
        harness.setMarket(2, _buildMarket(now_, 4, 1, 4, true, now_ - 1_000, now_ - 10));
        vm.expectRevert(SE.MarketExpired.selector);
        harness.exposedLoadAndValidateMarket(2);
    }

    // ============================================================
    // Test: reverts on invalid ticks (bounds, spacing, no point bet)
    // ============================================================

    function test_revertsOnInvalidTicks() public {
        harness.setMarket(1, _defaultMarket());

        // lowerTick = -1 → InvalidTick
        vm.expectRevert();
        harness.exposedValidateTickRange(-1, 1, 1);

        // upperTick = 5 with maxTick=4, numBins=4 → RangeBinsOutOfBounds
        vm.expectRevert();
        harness.exposedValidateTickRange(0, 5, 1);

        // lowerTick == upperTick → InvalidTickRange
        vm.expectRevert();
        harness.exposedValidateTickRange(0, 0, 1);

        // Misaligned tick spacing
        uint64 now_ = uint64(block.timestamp);
        harness.setMarket(2, _buildMarket(now_, 5, 2, 10, true, now_ - 10, now_ + 1_000));
        vm.expectRevert();
        harness.exposedValidateTickRange(1, 3, 2);
    }

    // ============================================================
    // Test: passes validation for aligned, in-range ticks
    // ============================================================

    function test_passesValidationForAlignedInRangeTicks() public {
        harness.setMarket(1, _defaultMarket());

        // These should not revert
        harness.exposedValidateTickRange(0, 2, 1);
        harness.exposedValidateTickRange(1, 3, 1);
    }
}
