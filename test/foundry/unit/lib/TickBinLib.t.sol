// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/TickBinLibHarness.sol";

contract TickBinLibTest is HarnessDeployer {
    TickBinLibHarness harness;

    // Market config: range [0, 100) with spacing 10 → 10 bins
    int256 constant MIN_TICK = 0;
    int256 constant MAX_TICK = 90;
    int256 constant TICK_SPACING = 10;
    uint32 constant NUM_BINS = 10;

    function setUp() public override {
        super.setUp();
        harness = deployTickBinLibHarness();
    }

    // ============================================================
    // tickToBin
    // ============================================================

    function test_tickToBin_minTickIsBin0() public view {
        assertEq(harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, MIN_TICK), 0);
    }

    function test_tickToBin_alignedTicks() public view {
        assertEq(harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, 0), 0);
        assertEq(harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, 10), 1);
        assertEq(harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, 50), 5);
        assertEq(harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, 90), 9);
    }

    function test_tickToBin_negativeMinTick() public view {
        int256 negMin = -50;
        assertEq(harness.tickToBin(negMin, 10, 10, -50), 0);
        assertEq(harness.tickToBin(negMin, 10, 10, -40), 1);
        assertEq(harness.tickToBin(negMin, 10, 10, 0), 5);
        assertEq(harness.tickToBin(negMin, 10, 10, 40), 9);
    }

    function test_tickToBin_revertsOnUnalignedTick() public {
        vm.expectRevert();
        harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, 15);
    }

    function test_tickToBin_revertsOnTickBelowMin() public {
        vm.expectRevert();
        harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, -10);
    }

    function test_tickToBin_revertsOnBinOutOfBounds() public {
        vm.expectRevert();
        harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, 100);
    }

    function test_tickToBin_revertsOnUint32Overflow() public {
        int256 hugeTick = int256(uint256(1 << 32)) + 1;
        vm.expectRevert();
        harness.tickToBin(0, 1, NUM_BINS, hugeTick);
    }

    // ============================================================
    // ticksToBins
    // ============================================================

    function test_ticksToBins_singleBinRange() public view {
        (uint32 lo, uint32 hi) = harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 0, 10);
        assertEq(lo, 0);
        assertEq(hi, 0);
    }

    function test_ticksToBins_multiBinRange() public view {
        (uint32 lo, uint32 hi) = harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 20, 60);
        assertEq(lo, 2);
        assertEq(hi, 5);
    }

    function test_ticksToBins_fullRange() public view {
        (uint32 lo, uint32 hi) = harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 0, 100);
        assertEq(lo, 0);
        assertEq(hi, 9);
    }

    function test_ticksToBins_negativeTickRange() public view {
        int256 negMin = -100;
        int256 negMax = 90;
        (uint32 lo, uint32 hi) = harness.ticksToBins(negMin, negMax, 10, 20, -50, 0);
        assertEq(lo, 5);
        assertEq(hi, 9);
    }

    function test_ticksToBins_revertsWhenLowerGteUpper() public {
        vm.expectRevert();
        harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 50, 50);

        vm.expectRevert();
        harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 60, 50);
    }

    function test_ticksToBins_revertsWhenLowerBelowMin() public {
        vm.expectRevert();
        harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, -10, 50);
    }

    function test_ticksToBins_revertsOnUnalignedLower() public {
        vm.expectRevert();
        harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 5, 50);
    }

    function test_ticksToBins_revertsOnUnalignedUpper() public {
        vm.expectRevert();
        harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 10, 55);
    }

    function test_ticksToBins_revertsWhenUpperExceedsMax() public {
        vm.expectRevert();
        harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 0, 110);
    }

    function test_ticksToBins_revertsWhenHiBinExceedsNumBins() public {
        vm.expectRevert();
        harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, 5, 0, 100);
    }

    function test_ticksToBins_revertsOnUint32Overflow() public {
        int256 hugeUpper = int256(uint256(1 << 32)) + 4;
        vm.expectRevert();
        harness.ticksToBins(0, hugeUpper - 1, 1, NUM_BINS, 0, hugeUpper);
    }

    // ============================================================
    // Edge cases
    // ============================================================

    function test_tickSpacing1() public view {
        (uint32 lo, uint32 hi) = harness.ticksToBins(0, 9, 1, 10, 0, 10);
        assertEq(lo, 0);
        assertEq(hi, 9);
    }

    function test_singleBinMarket() public view {
        assertEq(harness.tickToBin(0, 10, 1, 0), 0);
    }
}
