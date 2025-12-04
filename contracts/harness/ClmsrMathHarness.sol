// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../lib/LazyMulSegmentTree.sol";
import "../core/lib/SignalsClmsrMath.sol";

/// @notice Harness for CLMSR math: initializes a tree from bins and exposes quote helpers.
/// @dev Uses the same LazyMulSegmentTree/SignalsClmsrMath stack that will back TradeModule,
///      but without touching SignalsCore storage.
contract ClmsrMathHarness {
    using LazyMulSegmentTree for LazyMulSegmentTree.Tree;

    LazyMulSegmentTree.Tree private tree;

    /// @notice Seed the tree with explicit bin factors.
    function seed(uint256[] memory factors) external {
        if (factors.length == 0) revert("EMPTY_FACTORS");
        // reset just in case the harness is re-used
        tree.size = 0;
        tree.root = 0;
        tree.nextIndex = 0;
        tree.cachedRootSum = 0;
        tree.init(uint32(factors.length));
        tree.seedWithFactors(factors);
    }

    function cachedRootSum() external view returns (uint256) {
        return tree.cachedRootSum;
    }

    function applyRangeFactor(uint32 loBin, uint32 hiBin, uint256 factor) external {
        tree.applyRangeFactor(loBin, hiBin, factor);
    }

    function rangeSum(uint32 loBin, uint32 hiBin) external view returns (uint256) {
        return tree.getRangeSum(loBin, hiBin);
    }

    function quoteBuy(
        uint256 alpha,
        uint32 loBin,
        uint32 hiBin,
        uint256 quantityWad
    ) external view returns (uint256 costWad) {
        costWad = SignalsClmsrMath.calculateTradeCost(tree, alpha, loBin, hiBin, quantityWad);
    }

    function quoteSell(
        uint256 alpha,
        uint32 loBin,
        uint32 hiBin,
        uint256 quantityWad
    ) external view returns (uint256 proceedsWad) {
        proceedsWad = SignalsClmsrMath.calculateSellProceeds(tree, alpha, loBin, hiBin, quantityWad);
    }

    function quantityFromCost(
        uint256 alpha,
        uint32 loBin,
        uint32 hiBin,
        uint256 costWad
    ) external view returns (uint256 quantityWad) {
        quantityWad = SignalsClmsrMath.calculateQuantityFromCost(tree, alpha, loBin, hiBin, costWad);
    }

    /// @notice Expose the core safe exponential helper for parity tests against v0.
    function exposedSafeExp(uint256 qWad, uint256 alphaWad) external pure returns (uint256) {
        return SignalsClmsrMath._safeExp(qWad, alphaWad);
    }
}
