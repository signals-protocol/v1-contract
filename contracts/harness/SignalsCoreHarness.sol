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
}
