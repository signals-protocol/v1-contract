// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/SignalsBaseTest.sol";
import "../../../../contracts/interfaces/ISignalsCore.sol";
import "../../../../contracts/testonly/OracleTickLibHarness.sol";

contract OracleTickLibTest is SignalsBaseTest {
    OracleTickLibHarness harness;

    function setUp() public override {
        super.setUp();
        harness = new OracleTickLibHarness();
    }

    function test_btcScaleMatchesLegacyConversion() public {
        _setMarket(0, 10, 1, 1_000_000);

        assertEq(harness.toSettlementTick(2_000_000), 2);
        assertEq(harness.toSettlementTick(-1_000_000), 0);
        assertEq(harness.toSettlementTick(99_000_000), 9);
    }

    function test_customTickScaleControlsConversionBeforeClampAndAlignment() public {
        _setMarket(0, 400, 100, 100);

        assertEq(harness.toSettlementTick(25_000), 200);
        assertEq(harness.toSettlementTick(40_000), 300);
        assertEq(harness.toSettlementTick(10_000), 100);
    }

    function test_zeroTickScaleCausesEvmPanic() public {
        // All production call sites guard tickScale before entering the lib:
        // submitSettlementSample, finalizePrimarySettlement, and finalizeSecondarySettlement.
        // A future unguarded caller would hit the EVM division-by-zero panic here.
        _setMarket(0, 10, 1, 0);

        vm.expectRevert();
        harness.toSettlementTick(2_000_000);
    }

    function testFuzz_btcScaleParityWithLegacyAlgorithm(int256 settlementValue) public {
        settlementValue = bound(settlementValue, -1_000_000_000_000, 1_000_000_000_000);
        _setMarket(-1000, 1000, 10, 1_000_000);

        int256 legacy = _legacyToSettlementTick(-1000, 1000, 10, settlementValue);
        assertEq(harness.toSettlementTick(settlementValue), legacy);
    }

    function _setMarket(int256 minTick, int256 maxTick, int256 tickSpacing, uint64 tickScale) internal {
        harness.setMarket(
            ISignalsCore.Market({
                isSeeded: true,
                settled: false,
                snapshotChunksDone: false,
                failed: false,
                numBins: uint32(uint256((maxTick - minTick) / tickSpacing)),
                openPositionCount: 0,
                snapshotChunkCursor: 0,
                seedCursor: 0,
                startTimestamp: 0,
                endTimestamp: 0,
                settlementTimestamp: 0,
                settlementFinalizedAt: 0,
                minTick: minTick,
                maxTick: maxTick,
                tickSpacing: tickSpacing,
                settlementTick: 0,
                settlementValue: 0,
                liquidityParameter: WAD,
                feePolicy: address(1),
                seedData: address(0),
                initialRootSum: WAD,
                accumulatedFees: 0,
                minFactor: WAD,
                deltaEt: 0,
                feedId: bytes32("BTC"),
                feedDecimals: 8,
                tickScale: tickScale
            })
        );
    }

    function _legacyToSettlementTick(int256 minTick, int256 maxTick, int256 tickSpacing, int256 settlementValue)
        internal
        pure
        returns (int256)
    {
        int256 tick = settlementValue / 1_000_000;
        int256 lastValidTick = maxTick - tickSpacing;
        if (tick < minTick) tick = minTick;
        if (tick > lastValidTick) tick = lastValidTick;
        int256 offset = tick - minTick;
        return minTick + (offset / tickSpacing) * tickSpacing;
    }
}
