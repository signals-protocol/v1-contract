// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import {ISignalsCore} from "../../../../contracts/interfaces/ISignalsCore.sol";

/// @title GetMarket unit tests
/// @notice Validates the custom getMarket() getter replacing the auto getter.
contract GetMarketTest is FullSystemDeployer {
    FullSystem sys;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();
    }

    function test_getMarket_returnsAllFields() public {
        uint64 now_ = uint64(block.timestamp);
        uint64 start = now_ - 100;
        uint64 end_ = now_ + 200;
        uint32 numBins = 4;

        vm.prank(sys.owner);
        uint256 marketId =
            sys.core.createMarketUniform(0, 4, 1, start, end_, end_, numBins, WAD, address(sys.feePolicy));

        ISignalsCore.Market memory m = sys.core.getMarket(marketId);

        assertEq(m.numBins, numBins, "numBins");
        assertEq(m.startTimestamp, start, "startTimestamp");
        assertEq(m.endTimestamp, end_, "endTimestamp");
        assertEq(m.settlementTimestamp, end_, "settlementTimestamp");
        assertEq(m.liquidityParameter, WAD, "liquidityParameter");
        assertEq(m.feePolicy, address(sys.feePolicy), "feePolicy");
        assertEq(m.minTick, 0, "minTick");
        assertEq(m.maxTick, 4, "maxTick");
        assertEq(m.tickSpacing, 1, "tickSpacing");
        assertFalse(m.settled, "settled");
        assertFalse(m.failed, "failed");
    }

    function test_getMarket_nonexistentReturnsEmpty() public view {
        ISignalsCore.Market memory m = sys.core.getMarket(999);

        assertFalse(m.isSeeded, "isSeeded should be false");
        assertFalse(m.settled, "settled should be false");
        assertEq(m.numBins, 0, "numBins should be 0");
        assertEq(m.startTimestamp, 0, "startTimestamp should be 0");
        assertEq(m.endTimestamp, 0, "endTimestamp should be 0");
        assertEq(m.liquidityParameter, 0, "liquidityParameter should be 0");
        assertEq(m.feePolicy, address(0), "feePolicy should be zero address");
    }

    function test_getMarket_matchesHarness() public {
        uint64 now_ = uint64(block.timestamp);

        vm.prank(sys.owner);
        uint256 marketId =
            sys.core.createMarketUniform(-2, 2, 1, now_ - 50, now_ + 300, now_ + 300, 4, WAD, address(sys.feePolicy));

        ISignalsCore.Market memory fromGetter = sys.core.getMarket(marketId);
        ISignalsCore.Market memory fromHarness = sys.core.harnessGetMarket(marketId);

        assertEq(fromGetter.numBins, fromHarness.numBins, "numBins mismatch");
        assertEq(fromGetter.startTimestamp, fromHarness.startTimestamp, "startTimestamp mismatch");
        assertEq(fromGetter.endTimestamp, fromHarness.endTimestamp, "endTimestamp mismatch");
        assertEq(fromGetter.liquidityParameter, fromHarness.liquidityParameter, "liquidityParameter mismatch");
        assertEq(fromGetter.minTick, fromHarness.minTick, "minTick mismatch");
        assertEq(fromGetter.maxTick, fromHarness.maxTick, "maxTick mismatch");
        assertEq(fromGetter.feePolicy, fromHarness.feePolicy, "feePolicy mismatch");
        assertEq(fromGetter.isSeeded, fromHarness.isSeeded, "isSeeded mismatch");
        assertEq(fromGetter.settled, fromHarness.settled, "settled mismatch");
    }
}
