// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/SignalsCore.sol";
import "../lib/LazyMulSegmentTree.sol";

/// @notice Harness extending SignalsCore with helpers to seed markets/trees for tests.
contract SignalsCoreHarness is SignalsCore {
    using LazyMulSegmentTree for LazyMulSegmentTree.Tree;

    function harnessSetMarket(uint256 marketId, ISignalsCore.Market calldata market) external onlyOwner {
        markets[marketId] = market;
    }

    function harnessSeedTree(uint256 marketId, uint256[] calldata factors) external onlyOwner {
        LazyMulSegmentTree.Tree storage tree = marketTrees[marketId];
        if (tree.size == 0) {
            tree.init(uint32(factors.length));
        }
        tree.seedWithFactors(factors);
    }

    function harnessSetPositionContract(address pos) external onlyOwner {
        positionContract = ISignalsPosition(pos);
    }

    function harnessSetPaymentToken(address token) external onlyOwner {
        paymentToken = IERC20(token);
    }

    function harnessGetTreeSize(uint256 marketId) external view returns (uint32) {
        return marketTrees[marketId].size;
    }

    function harnessGetTreeSum(uint256 marketId) external view returns (uint256) {
        LazyMulSegmentTree.Tree storage tree = marketTrees[marketId];
        if (tree.size == 0) return 0;
        return tree.getRangeSum(0, tree.size - 1);
    }

    function harnessGetMarket(uint256 marketId) external view returns (ISignalsCore.Market memory) {
        return markets[marketId];
    }

    // ============================================================
    // Phase 6: Exposure Ledger test helpers
    // ============================================================

    /**
     * @notice Set exposure at a specific tick for testing
     * @dev Used in spec tests to simulate position creation without full trade flow
     * @param marketId Market identifier
     * @param tick Settlement tick
     * @param exposure Total exposure at this tick (token units)
     */
    function harnessSetExposure(uint256 marketId, int256 tick, uint256 exposure) external onlyOwner {
        _exposureLedger[marketId][tick] = exposure;
    }

    /**
     * @notice Add exposure to a range of ticks (simulates openPosition)
     * @param marketId Market identifier
     * @param lowerTick Lower bound (inclusive)
     * @param upperTick Upper bound (exclusive)
     * @param quantity Position quantity (token units)
     */
    function harnessAddExposure(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint256 quantity
    ) external onlyOwner {
        for (int256 tick = lowerTick; tick < upperTick; tick++) {
            _exposureLedger[marketId][tick] += quantity;
        }
    }

    /// @notice Set exposure at a specific tick (Phase 6 testing)
    function harnessSetExposureAtTick(
        uint256 marketId,
        int256 tick,
        uint256 quantity
    ) external onlyOwner {
        _exposureLedger[marketId][tick] = quantity;
    }

    /// @notice Set payout reserve for a market (Phase 6 testing)
    function harnessSetPayoutReserve(
        uint256 marketId,
        uint256 amount
    ) external onlyOwner {
        _payoutReserve[marketId] = amount;
        _payoutReserveRemaining[marketId] = amount;
    }

    /**
     * @notice Get exposure at a specific tick
     * @param marketId Market identifier
     * @param tick Settlement tick
     * @return exposure Total exposure at this tick
     */
    function harnessGetExposure(uint256 marketId, int256 tick) external view returns (uint256 exposure) {
        return _exposureLedger[marketId][tick];
    }

    /**
     * @notice Get payout reserve for a market
     * @param marketId Market identifier
     * @return reserve Total payout reserve for the market
     */
    function harnessGetPayoutReserve(uint256 marketId) external view returns (uint256 reserve) {
        return _payoutReserve[marketId];
    }
}
