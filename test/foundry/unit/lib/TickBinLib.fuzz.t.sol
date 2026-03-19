// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/TickBinLibHarness.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

contract TickBinLibFuzzTest is HarnessDeployer {
    TickBinLibHarness harness;

    function setUp() public override {
        super.setUp();
        harness = deployTickBinLibHarness();
    }

    // ============================================================
    // Helper
    // ============================================================

    /// @dev Build valid market config from fuzz inputs (numBins >= 2 for ticksToBins)
    function _makeMarketConfig(
        int128 _minTick,
        uint16 _rawSpacing,
        uint16 _rawNumBins
    ) private pure returns (int256 minTick, int256 maxTick, int256 tickSpacing, uint32 numBins) {
        minTick = int256(_minTick);
        tickSpacing = int256(uint256(bound(_rawSpacing, 1, 10_000)));
        numBins = uint32(bound(_rawNumBins, 2, 1000));
        maxTick = minTick + int256(uint256(numBins - 1)) * tickSpacing;
    }

    // ============================================================
    // tickToBin fuzz tests
    // ============================================================

    /// @notice Round-trip: bin → tick → bin recovers the original index
    function testFuzz_tickToBin_roundTrip(
        int128 _minTick,
        uint16 _rawSpacing,
        uint16 _rawNumBins,
        uint16 _rawBinIdx
    ) public view {
        int256 minTick = int256(_minTick);
        int256 tickSpacing = int256(uint256(bound(_rawSpacing, 1, 10_000)));
        uint32 numBins = uint32(bound(_rawNumBins, 1, 1000));
        uint32 binIdx = uint32(bound(_rawBinIdx, 0, numBins - 1));

        int256 tick = minTick + int256(uint256(binIdx)) * tickSpacing;

        assertEq(harness.tickToBin(minTick, tickSpacing, numBins, tick), binIdx);
    }

    /// @notice Output is always a valid bin index (< numBins)
    function testFuzz_tickToBin_outputAlwaysLtNumBins(
        int128 _minTick,
        uint16 _rawSpacing,
        uint16 _rawNumBins,
        uint16 _rawBinIdx
    ) public view {
        int256 minTick = int256(_minTick);
        int256 tickSpacing = int256(uint256(bound(_rawSpacing, 1, 10_000)));
        uint32 numBins = uint32(bound(_rawNumBins, 1, 1000));
        uint32 binIdx = uint32(bound(_rawBinIdx, 0, numBins - 1));

        int256 tick = minTick + int256(uint256(binIdx)) * tickSpacing;

        uint32 result = harness.tickToBin(minTick, tickSpacing, numBins, tick);
        assertLt(result, numBins);
    }

    /// @notice Unaligned ticks always revert
    function testFuzz_tickToBin_revertsOnMisalignment(
        int128 _minTick,
        uint16 _rawSpacing,
        uint16 _rawNumBins,
        uint16 _rawBinIdx,
        uint16 _rawMisalign
    ) public {
        int256 minTick = int256(_minTick);
        // tickSpacing >= 2 so misalignment can exist
        int256 tickSpacing = int256(uint256(bound(_rawSpacing, 2, 10_000)));
        uint32 numBins = uint32(bound(_rawNumBins, 1, 1000));
        uint32 binIdx = uint32(bound(_rawBinIdx, 0, numBins - 1));
        int256 misalignment = int256(uint256(bound(_rawMisalign, 1, uint256(int256(tickSpacing)) - 1)));

        int256 tick = minTick + int256(uint256(binIdx)) * tickSpacing + misalignment;

        vm.expectPartialRevert(SE.InvalidTickSpacing.selector);
        harness.tickToBin(minTick, tickSpacing, numBins, tick);
    }

    /// @notice Tick at bin == numBins is out of bounds and always reverts
    function testFuzz_tickToBin_revertsOnOutOfBounds(int128 _minTick, uint16 _rawSpacing, uint16 _rawNumBins) public {
        int256 minTick = int256(_minTick);
        int256 tickSpacing = int256(uint256(bound(_rawSpacing, 1, 10_000)));
        uint32 numBins = uint32(bound(_rawNumBins, 1, 1000));

        // tick at bin index == numBins (one past the last valid bin)
        int256 tick = minTick + int256(uint256(numBins)) * tickSpacing;

        vm.expectPartialRevert(SE.RangeBinsOutOfBounds.selector);
        harness.tickToBin(minTick, tickSpacing, numBins, tick);
    }

    // ============================================================
    // ticksToBins fuzz tests
    // ============================================================

    /// @notice Range conversion matches single-tick conversion at boundaries
    function testFuzz_ticksToBins_consistentWithTickToBin(
        int128 _minTick,
        uint16 _rawSpacing,
        uint16 _rawNumBins,
        uint16 _rawLoBin,
        uint16 _rawHiBin
    ) public view {
        (int256 minTick, int256 maxTick, int256 tickSpacing, uint32 numBins) = _makeMarketConfig(
            _minTick,
            _rawSpacing,
            _rawNumBins
        );

        uint32 loBinExpected = uint32(bound(_rawLoBin, 0, numBins - 2));
        uint32 hiBinExpected = uint32(bound(_rawHiBin, loBinExpected, numBins - 1));

        int256 lowerTick = minTick + int256(uint256(loBinExpected)) * tickSpacing;
        int256 upperTick = minTick + int256(uint256(hiBinExpected + 1)) * tickSpacing;

        (uint32 loBin, uint32 hiBin) = harness.ticksToBins(
            minTick,
            maxTick,
            tickSpacing,
            numBins,
            lowerTick,
            upperTick
        );

        assertEq(loBin, harness.tickToBin(minTick, tickSpacing, numBins, lowerTick));
        assertEq(hiBin, harness.tickToBin(minTick, tickSpacing, numBins, upperTick - tickSpacing));
    }

    /// @notice Number of bins * tickSpacing == tick range width
    function testFuzz_ticksToBins_binCountMatchesTickSpan(
        int128 _minTick,
        uint16 _rawSpacing,
        uint16 _rawNumBins,
        uint16 _rawLoBin,
        uint16 _rawHiBin
    ) public view {
        (int256 minTick, int256 maxTick, int256 tickSpacing, uint32 numBins) = _makeMarketConfig(
            _minTick,
            _rawSpacing,
            _rawNumBins
        );

        uint32 loBinExpected = uint32(bound(_rawLoBin, 0, numBins - 2));
        uint32 hiBinExpected = uint32(bound(_rawHiBin, loBinExpected, numBins - 1));

        int256 lowerTick = minTick + int256(uint256(loBinExpected)) * tickSpacing;
        int256 upperTick = minTick + int256(uint256(hiBinExpected + 1)) * tickSpacing;

        (uint32 loBin, uint32 hiBin) = harness.ticksToBins(
            minTick,
            maxTick,
            tickSpacing,
            numBins,
            lowerTick,
            upperTick
        );

        assertEq(uint256(hiBin - loBin + 1) * uint256(int256(tickSpacing)), uint256(upperTick - lowerTick));
    }

    /// @notice Full market range maps to [0, numBins-1]
    function testFuzz_ticksToBins_fullRangeGivesAllBins(
        int128 _minTick,
        uint16 _rawSpacing,
        uint16 _rawNumBins
    ) public view {
        (int256 minTick, int256 maxTick, int256 tickSpacing, uint32 numBins) = _makeMarketConfig(
            _minTick,
            _rawSpacing,
            _rawNumBins
        );

        int256 lowerTick = minTick;
        int256 upperTick = minTick + int256(uint256(numBins)) * tickSpacing;

        (uint32 loBin, uint32 hiBin) = harness.ticksToBins(
            minTick,
            maxTick,
            tickSpacing,
            numBins,
            lowerTick,
            upperTick
        );

        assertEq(loBin, 0);
        assertEq(hiBin, numBins - 1);
    }

    /// @notice One-tickSpacing range maps to a single bin
    function testFuzz_ticksToBins_singleBinRange(
        int128 _minTick,
        uint16 _rawSpacing,
        uint16 _rawNumBins,
        uint16 _rawBinIdx
    ) public view {
        (int256 minTick, int256 maxTick, int256 tickSpacing, uint32 numBins) = _makeMarketConfig(
            _minTick,
            _rawSpacing,
            _rawNumBins
        );

        uint32 binIdx = uint32(bound(_rawBinIdx, 0, numBins - 1));

        int256 lowerTick = minTick + int256(uint256(binIdx)) * tickSpacing;
        int256 upperTick = lowerTick + tickSpacing;

        (uint32 loBin, uint32 hiBin) = harness.ticksToBins(
            minTick,
            maxTick,
            tickSpacing,
            numBins,
            lowerTick,
            upperTick
        );

        assertEq(loBin, binIdx);
        assertEq(hiBin, binIdx);
    }

    /// @notice Output is always ordered: loBin <= hiBin
    function testFuzz_ticksToBins_loBinLeHiBin(
        int128 _minTick,
        uint16 _rawSpacing,
        uint16 _rawNumBins,
        uint16 _rawLoBin,
        uint16 _rawHiBin
    ) public view {
        (int256 minTick, int256 maxTick, int256 tickSpacing, uint32 numBins) = _makeMarketConfig(
            _minTick,
            _rawSpacing,
            _rawNumBins
        );

        uint32 loBinExpected = uint32(bound(_rawLoBin, 0, numBins - 2));
        uint32 hiBinExpected = uint32(bound(_rawHiBin, loBinExpected, numBins - 1));

        int256 lowerTick = minTick + int256(uint256(loBinExpected)) * tickSpacing;
        int256 upperTick = minTick + int256(uint256(hiBinExpected + 1)) * tickSpacing;

        (uint32 loBin, uint32 hiBin) = harness.ticksToBins(
            minTick,
            maxTick,
            tickSpacing,
            numBins,
            lowerTick,
            upperTick
        );

        assertLe(loBin, hiBin);
    }

    /// @notice Degenerate and inverted ranges always revert
    function testFuzz_ticksToBins_revertsWhenLowerGeUpper(
        int128 _minTick,
        uint16 _rawSpacing,
        uint16 _rawNumBins,
        uint16 _rawBinIdx,
        bool equalCase
    ) public {
        (int256 minTick, int256 maxTick, int256 tickSpacing, uint32 numBins) = _makeMarketConfig(
            _minTick,
            _rawSpacing,
            _rawNumBins
        );

        uint32 binIdx = uint32(bound(_rawBinIdx, 0, numBins - 1));
        int256 lowerTick = minTick + int256(uint256(binIdx)) * tickSpacing;

        int256 upperTick;
        if (equalCase) {
            // lowerTick == upperTick
            upperTick = lowerTick;
        } else {
            // lowerTick > upperTick (go one spacing below, but ensure it's still aligned)
            upperTick = lowerTick - tickSpacing;
            if (upperTick < minTick) {
                // Edge case: binIdx == 0, can't go below. Use equal case instead.
                upperTick = lowerTick;
            }
        }

        vm.expectPartialRevert(SE.InvalidTickRange.selector);
        harness.ticksToBins(minTick, maxTick, tickSpacing, numBins, lowerTick, upperTick);
    }
}
