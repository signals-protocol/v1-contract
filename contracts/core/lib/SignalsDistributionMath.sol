// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LazyMulSegmentTree} from "../../lib/LazyMulSegmentTree.sol";
import {FixedPointMathU} from "../../lib/FixedPointMathU.sol";
import {SignalsClmsrMath} from "./SignalsClmsrMath.sol";
import {CE} from "../../errors/CLMSRErrors.sol";

/// @notice CLMSR distribution math (buy/sell cost/proceeds, quantity from cost) over a segment tree.
library SignalsDistributionMath {
    using FixedPointMathU for uint256;
    using LazyMulSegmentTree for LazyMulSegmentTree.Tree;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_EXP_INPUT_WAD = 135305999368893231588; // matches v0
    uint256 internal constant MAX_CHUNKS_PER_TX = 100;
    uint256 internal constant OVERFLOW_GUARD_MULTIPLIER = 50e18; // 50 * WAD

    /// @notice Maximum safe quantity per chunk to keep exp input within bounds.
    function _maxSafeChunkQuantity(uint256 alpha) private pure returns (uint256) {
        uint256 raw = alpha.wMul(MAX_EXP_INPUT_WAD);
        if (raw == 0) return 0;
        return raw;
    }

    function calculateTradeCost(
        LazyMulSegmentTree.Tree storage tree,
        uint256 alpha,
        uint32 loBin,
        uint32 hiBin,
        uint256 quantityWad
    ) internal view returns (uint256 costWad) {
        uint256 totalQuantity = quantityWad;
        uint256 maxSafeQuantityPerChunk = _maxSafeChunkQuantity(alpha);

        if (totalQuantity == 0) return 0;
        if (totalQuantity <= maxSafeQuantityPerChunk) {
            return _calculateSingleTradeCost(tree, alpha, loBin, hiBin, totalQuantity);
        }

        uint256 sumBefore = tree.cachedRootSum;
        uint256 affectedSum = tree.getRangeSum(loBin, hiBin);
        if (sumBefore == 0) revert CE.TreeNotInitialized();

        uint256 requiredChunks = (totalQuantity + maxSafeQuantityPerChunk - 1) / maxSafeQuantityPerChunk;
        if (requiredChunks > MAX_CHUNKS_PER_TX) {
            revert CE.ChunkLimitExceeded(requiredChunks, MAX_CHUNKS_PER_TX);
        }

        uint256 cumulativeCostWad;
        uint256 remainingQuantity = totalQuantity;
        uint256 currentSumBefore = sumBefore;
        uint256 currentAffectedSum = affectedSum;
        uint256 chunkCount;

        while (remainingQuantity > 0 && chunkCount < MAX_CHUNKS_PER_TX) {
            uint256 chunkQuantity = remainingQuantity > maxSafeQuantityPerChunk
                ? maxSafeQuantityPerChunk
                : remainingQuantity;

            uint256 quantityScaled = chunkQuantity.wDiv(alpha);
            uint256 factor = quantityScaled.wExp();

            if (currentAffectedSum > type(uint256).max / factor) {
                chunkQuantity = _computeSafeChunk(
                    currentAffectedSum,
                    alpha,
                    remainingQuantity,
                    MAX_CHUNKS_PER_TX - chunkCount
                );
                if (chunkQuantity > remainingQuantity) {
                    chunkQuantity = remainingQuantity;
                }
                quantityScaled = chunkQuantity.wDiv(alpha);
                factor = quantityScaled.wExp();
            }

            if (currentAffectedSum != 0 && factor > type(uint256).max / currentAffectedSum) {
                revert CE.MathMulOverflow();
            }

            uint256 newAffectedSum = currentAffectedSum.wMulNearest(factor);
            uint256 sumAfter = currentSumBefore - currentAffectedSum + newAffectedSum;
            if (sumAfter <= currentSumBefore) revert CE.NonIncreasingSum(currentSumBefore, sumAfter);

            uint256 ratio = sumAfter.wDivUp(currentSumBefore);
            uint256 chunkCost = alpha.wMul(ratio.wLn());
            cumulativeCostWad += chunkCost;

            if (chunkQuantity == 0) revert CE.NoChunkProgress();

            currentSumBefore = sumAfter;
            currentAffectedSum = newAffectedSum;
            remainingQuantity -= chunkQuantity;
            chunkCount++;
        }

        if (remainingQuantity != 0) revert CE.ResidualQuantity(remainingQuantity);
        return cumulativeCostWad;
    }

    function _calculateSingleTradeCost(
        LazyMulSegmentTree.Tree storage tree,
        uint256 alpha,
        uint32 loBin,
        uint32 hiBin,
        uint256 quantityWad
    ) private view returns (uint256 cost) {
        uint256 sumBefore = tree.cachedRootSum;
        if (sumBefore == 0) revert CE.TreeNotInitialized();
        uint256 quantityScaled = quantityWad.wDiv(alpha);
        uint256 factor = quantityScaled.wExp();
        uint256 affectedSum = tree.getRangeSum(loBin, hiBin);
        if (affectedSum == 0) revert CE.AffectedSumZero();
        if (affectedSum > type(uint256).max / factor) {
            return calculateTradeCost(tree, alpha, loBin, hiBin, quantityWad);
        }
        uint256 sumAfter = sumBefore - affectedSum + affectedSum.wMulNearest(factor);
        if (sumAfter <= sumBefore) return 0;
        uint256 ratio = sumAfter.wDivUp(sumBefore);
        cost = alpha.wMul(ratio.wLn());
    }

    function calculateSellProceeds(
        LazyMulSegmentTree.Tree storage tree,
        uint256 alpha,
        uint32 loBin,
        uint32 hiBin,
        uint256 quantityWad
    ) internal view returns (uint256 proceedsWad) {
        uint256 totalQuantity = quantityWad;
        uint256 maxSafeQuantityPerChunk = _maxSafeChunkQuantity(alpha);
        if (totalQuantity == 0) return 0;
        if (totalQuantity <= maxSafeQuantityPerChunk) {
            return _calculateSingleSellProceeds(tree, alpha, loBin, hiBin, totalQuantity);
        }

        uint256 sumBefore = tree.cachedRootSum;
        uint256 affectedSum = tree.getRangeSum(loBin, hiBin);
        if (sumBefore == 0) revert CE.TreeNotInitialized();

        uint256 requiredChunks = (totalQuantity + maxSafeQuantityPerChunk - 1) / maxSafeQuantityPerChunk;
        if (requiredChunks > MAX_CHUNKS_PER_TX) revert CE.ChunkLimitExceeded(requiredChunks, MAX_CHUNKS_PER_TX);

        uint256 cumulativeProceeds;
        uint256 remainingQuantity = totalQuantity;
        uint256 currentSumBefore = sumBefore;
        uint256 currentAffectedSum = affectedSum;
        uint256 chunkCount;

        while (remainingQuantity > 0 && chunkCount < MAX_CHUNKS_PER_TX) {
            uint256 chunkQuantity = remainingQuantity > maxSafeQuantityPerChunk
                ? maxSafeQuantityPerChunk
                : remainingQuantity;

            uint256 quantityScaled = chunkQuantity.wDiv(alpha);
            uint256 factor = quantityScaled.wExp();
            uint256 inverseFactor = WAD.wDivUp(factor);

            if (currentAffectedSum > type(uint256).max / inverseFactor) {
                chunkQuantity = _computeSafeChunk(
                    currentAffectedSum,
                    alpha,
                    remainingQuantity,
                    MAX_CHUNKS_PER_TX - chunkCount
                );
                if (chunkQuantity > remainingQuantity) {
                    chunkQuantity = remainingQuantity;
                }
                quantityScaled = chunkQuantity.wDiv(alpha);
                factor = quantityScaled.wExp();
                inverseFactor = WAD.wDivUp(factor);
            }

            if (currentAffectedSum != 0 && inverseFactor > type(uint256).max / currentAffectedSum) {
                revert CE.MathMulOverflow();
            }

            uint256 newAffectedSum = currentAffectedSum.wMulNearest(inverseFactor);
            uint256 sumAfter = currentSumBefore - currentAffectedSum + newAffectedSum;
            if (sumAfter == 0) revert CE.SumAfterZero();
            if (sumBefore <= sumAfter) return 0;

            uint256 ratio = currentSumBefore.wDivUp(sumAfter);
            uint256 chunkProceeds = alpha.wMul(ratio.wLn());
            cumulativeProceeds += chunkProceeds;

            if (chunkQuantity == 0) revert CE.NoChunkProgress();

            currentSumBefore = sumAfter;
            currentAffectedSum = newAffectedSum;
            remainingQuantity -= chunkQuantity;
            chunkCount++;
        }

        if (remainingQuantity != 0) revert CE.ResidualQuantity(remainingQuantity);
        return cumulativeProceeds;
    }

    function _calculateSingleSellProceeds(
        LazyMulSegmentTree.Tree storage tree,
        uint256 alpha,
        uint32 loBin,
        uint32 hiBin,
        uint256 quantityWad
    ) private view returns (uint256 proceeds) {
        uint256 sumBefore = tree.cachedRootSum;
        if (sumBefore == 0) revert CE.TreeNotInitialized();

        uint256 quantityScaled = quantityWad.wDiv(alpha);
        uint256 factor = quantityScaled.wExp();
        uint256 inverseFactor = WAD.wDivUp(factor);

        uint256 affectedSum = tree.getRangeSum(loBin, hiBin);
        if (affectedSum == 0) revert CE.AffectedSumZero();
        if (affectedSum > type(uint256).max / inverseFactor) {
            return calculateSellProceeds(tree, alpha, loBin, hiBin, quantityWad);
        }

        uint256 sumAfter = sumBefore - affectedSum + affectedSum.wMulNearest(inverseFactor);
        if (sumAfter == 0) revert CE.SumAfterZero();
        if (sumBefore <= sumAfter) return 0;

        uint256 ratio = sumBefore.wDivUp(sumAfter);
        uint256 lnRatio = ratio.wLn();
        proceeds = alpha.wMul(lnRatio);
    }

    function calculateQuantityFromCost(
        LazyMulSegmentTree.Tree storage tree,
        uint256 alpha,
        uint32 loBin,
        uint32 hiBin,
        uint256 costWad
    ) internal view returns (uint256 quantityWad) {
        uint256 sumBefore = tree.cachedRootSum;
        uint256 affectedSum = tree.getRangeSum(loBin, hiBin);
        if (sumBefore == 0) revert CE.TreeNotInitialized();
        if (affectedSum == 0) revert CE.AffectedSumZero();

        uint256 expValue = SignalsClmsrMath._safeExp(costWad, alpha);
        uint256 targetSumAfter = sumBefore.wMul(expValue);
        uint256 requiredAffectedSum = targetSumAfter - (sumBefore - affectedSum);
        uint256 factor = requiredAffectedSum.wDiv(affectedSum);
        quantityWad = alpha.wMul(factor.wLn());
    }

    function _computeSafeChunk(
        uint256 currentSum,
        uint256 alpha,
        uint256 remainingQty,
        uint256 chunksLeft
    ) private pure returns (uint256 safeChunk) {
        if (chunksLeft == 0) return remainingQty;

        uint256 minProgress = (remainingQty + chunksLeft - 1) / chunksLeft;
        if (minProgress == 0) minProgress = 1;

        uint256 maxSafeQuantity = alpha.wMul(MAX_EXP_INPUT_WAD);
        if (currentSum > alpha.wMul(OVERFLOW_GUARD_MULTIPLIER)) {
            maxSafeQuantity = alpha / 10;
        }

        safeChunk = minProgress < maxSafeQuantity ? minProgress : maxSafeQuantity;
        if (safeChunk > remainingQty) {
            safeChunk = remainingQty;
        }
    }
}
