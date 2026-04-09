// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignalsErrors as SE} from "contracts/errors/SignalsErrors.sol";
import {FixedPointMathU} from "contracts/lib/FixedPointMathU.sol";
import {ClmsrMathCostHarness} from "contracts/testonly/SignalsDistributionMathHarness.sol";
import {LazyMulSegmentTreeNoLink} from "./LazyMulSegmentTreeNoLink.sol";

contract EchidnaClmsrMath {
    using FixedPointMathU for uint256;
    using LazyMulSegmentTreeNoLink for LazyMulSegmentTreeNoLink.Tree;

    uint256 private constant WAD = 1e18;
    uint32 private constant TREE_SIZE = 10;
    uint256 private constant DRIFT_TOLERANCE_WAD_WEI = 1e12;
    uint256 private constant REL_DRIFT_DENOM = 1e12;

    enum Action {
        NONE,
        BUY,
        SELL,
        ROUNDTRIP
    }

    LazyMulSegmentTreeNoLink.Tree private tree;
    ClmsrMathCostHarness private costHarness;

    uint256 private alpha;
    Action private lastAction;
    bool private unexpectedRevertOccurred;

    uint256 private lastBuySumBefore;
    uint256 private lastBuySumAfter;
    uint256 private lastBuyCost;

    uint256 private lastSellSumBefore;
    uint256 private lastSellSumAfter;
    uint256 private lastSellProceeds;

    uint256 private lastRoundtripCost;
    uint256 private lastRoundtripProceeds;

    uint256 private pairBuyCost1;
    uint256 private pairBuyCost2;
    uint256 private pairSellProceeds1;
    uint256 private pairSellProceeds2;
    uint256 private pairRoundtripSellProceeds1;
    uint256 private pairRoundtripSellProceeds2;

    constructor() {
        costHarness = new ClmsrMathCostHarness();

        tree.init(TREE_SIZE);
        uint256[] memory factors = new uint256[](TREE_SIZE);
        for (uint256 i = 0; i < TREE_SIZE; i++) {
            factors[i] = WAD;
        }
        tree.seedWithFactors(factors);

        alpha = WAD;
        uint256 sumBefore = 3 * WAD;
        uint256 delta1 = 1e16;
        uint256 delta2 = 2e16;
        pairBuyCost1 = costHarness.computeBuyCostFromSumChange(alpha, sumBefore, sumBefore + delta1);
        pairBuyCost2 = costHarness.computeBuyCostFromSumChange(alpha, sumBefore, sumBefore + delta2);
        pairSellProceeds1 = costHarness.computeSellProceedsFromSumChange(alpha, sumBefore, sumBefore - delta1);
        pairSellProceeds2 = costHarness.computeSellProceedsFromSumChange(alpha, sumBefore, sumBefore - delta2);
        pairRoundtripSellProceeds1 = costHarness.computeSellProceedsFromSumChange(alpha, sumBefore + delta1, sumBefore);
        pairRoundtripSellProceeds2 = costHarness.computeSellProceedsFromSumChange(alpha, sumBefore + delta2, sumBefore);
    }

    function setAlpha(uint256 rawAlpha) external {
        alpha = _bound(rawAlpha, 1e15, 1000e18);
    }

    function doBuy(uint32 rawLo, uint32 rawHi, uint256 rawQuantity) external {
        (uint32 lo, uint32 hi) = _boundRange(rawLo, rawHi);
        uint256 quantity = _boundQuantity(rawQuantity);

        try this.executeBuy(lo, hi, quantity) returns (uint256 sumBefore, uint256 sumAfter, uint256 cost) {
            lastBuySumBefore = sumBefore;
            lastBuySumAfter = sumAfter;
            lastBuyCost = cost;
            lastAction = Action.BUY;
        } catch (bytes memory err) {
            _handleClmsrRevert(err);
        }
    }

    function doSell(uint32 rawLo, uint32 rawHi, uint256 rawQuantity) external {
        (uint32 lo, uint32 hi) = _boundRange(rawLo, rawHi);
        uint256 quantity = _boundQuantity(rawQuantity);

        try this.executeSell(lo, hi, quantity) returns (uint256 sumBefore, uint256 sumAfter, uint256 proceeds) {
            lastSellSumBefore = sumBefore;
            lastSellSumAfter = sumAfter;
            lastSellProceeds = proceeds;
            lastAction = Action.SELL;
        } catch (bytes memory err) {
            _handleClmsrRevert(err);
        }
    }

    function doRoundtrip(uint32 rawLo, uint32 rawHi, uint256 rawQuantity) external {
        (uint32 lo, uint32 hi) = _boundRange(rawLo, rawHi);
        uint256 quantity = _boundQuantity(rawQuantity);

        try this.executeRoundtrip(lo, hi, quantity) returns (uint256 cost, uint256 proceeds) {
            lastRoundtripCost = cost;
            lastRoundtripProceeds = proceeds;
            lastAction = Action.ROUNDTRIP;
        } catch (bytes memory err) {
            _handleClmsrRevert(err);
        }
    }

    function setPureCostPair(uint256 rawAlpha, uint256 rawSumBefore, uint256 rawDelta1, uint256 rawDelta2) external {
        uint256 pairAlpha = _bound(rawAlpha, 1e15, 1000e18);
        uint256 sumBefore = _bound(rawSumBefore, 3 * WAD, 1e30);
        uint256 delta1 = _bound(rawDelta1, 1e16, sumBefore - WAD);
        uint256 delta2 = _bound(rawDelta2, 1e16, sumBefore - WAD);

        if (delta1 > delta2) {
            (delta1, delta2) = (delta2, delta1);
        }

        pairBuyCost1 = costHarness.computeBuyCostFromSumChange(pairAlpha, sumBefore, sumBefore + delta1);
        pairBuyCost2 = costHarness.computeBuyCostFromSumChange(pairAlpha, sumBefore, sumBefore + delta2);
        pairSellProceeds1 = costHarness.computeSellProceedsFromSumChange(pairAlpha, sumBefore, sumBefore - delta1);
        pairSellProceeds2 = costHarness.computeSellProceedsFromSumChange(pairAlpha, sumBefore, sumBefore - delta2);
        pairRoundtripSellProceeds1 = costHarness.computeSellProceedsFromSumChange(
            pairAlpha,
            sumBefore + delta1,
            sumBefore
        );
        pairRoundtripSellProceeds2 = costHarness.computeSellProceedsFromSumChange(
            pairAlpha,
            sumBefore + delta2,
            sumBefore
        );
    }

    function executeBuy(
        uint32 lo,
        uint32 hi,
        uint256 quantity
    ) external returns (uint256 sumBefore, uint256 sumAfter, uint256 cost) {
        sumBefore = tree.totalSum();
        uint256 factor = costHarness.safeExp(quantity, alpha);
        tree.applyRangeFactor(lo, hi, factor);
        sumAfter = tree.totalSum();
        cost = costHarness.computeBuyCostFromSumChange(alpha, sumBefore, sumAfter);
    }

    function executeSell(
        uint32 lo,
        uint32 hi,
        uint256 quantity
    ) external returns (uint256 sumBefore, uint256 sumAfter, uint256 proceeds) {
        sumBefore = tree.totalSum();
        uint256 factor = costHarness.safeExp(quantity, alpha);
        uint256 inverseFactor = WAD.wDivUp(factor);
        tree.applyRangeFactor(lo, hi, inverseFactor);
        sumAfter = tree.totalSum();
        proceeds = costHarness.computeSellProceedsFromSumChange(alpha, sumBefore, sumAfter);
    }

    function executeRoundtrip(
        uint32 lo,
        uint32 hi,
        uint256 quantity
    ) external returns (uint256 cost, uint256 proceeds) {
        uint256 sumBefore = tree.totalSum();
        uint256 factor = costHarness.safeExp(quantity, alpha);

        tree.applyRangeFactor(lo, hi, factor);
        uint256 sumAfterBuy = tree.totalSum();
        cost = costHarness.computeBuyCostFromSumChange(alpha, sumBefore, sumAfterBuy);

        uint256 inverseFactor = WAD.wDivUp(factor);
        tree.applyRangeFactor(lo, hi, inverseFactor);
        uint256 sumAfterSell = tree.totalSum();
        proceeds = costHarness.computeSellProceedsFromSumChange(alpha, sumAfterBuy, sumAfterSell);
    }

    function echidna_buy_cost_positive() external view returns (bool) {
        if (lastAction != Action.BUY) {
            return true;
        }

        uint256 recomputed = costHarness.computeBuyCostFromSumChange(alpha, lastBuySumBefore, lastBuySumAfter);
        return (recomputed == 0 && lastBuyCost == 0) || (recomputed > 0 && lastBuyCost > 0);
    }

    function echidna_sell_proceeds_positive() external view returns (bool) {
        if (lastAction != Action.SELL) {
            return true;
        }

        uint256 recomputed = costHarness.computeSellProceedsFromSumChange(alpha, lastSellSumBefore, lastSellSumAfter);
        return (recomputed == 0 && lastSellProceeds == 0) || (recomputed > 0 && lastSellProceeds > 0);
    }

    function echidna_no_value_creation() external view returns (bool) {
        if (lastAction != Action.ROUNDTRIP) {
            return true;
        }

        return lastRoundtripProceeds <= lastRoundtripCost + _driftTolerance(lastRoundtripCost);
    }

    function echidna_sum_after_buy_nondecreasing() external view returns (bool) {
        if (lastAction != Action.BUY) {
            return true;
        }

        return lastBuySumAfter + _driftTolerance(lastBuySumBefore) >= lastBuySumBefore;
    }

    function echidna_sum_after_sell_nonincreasing() external view returns (bool) {
        if (lastAction != Action.SELL) {
            return true;
        }

        return lastSellSumAfter <= lastSellSumBefore + _driftTolerance(lastSellSumBefore);
    }

    function echidna_no_unexpected_revert() external view returns (bool) {
        return !unexpectedRevertOccurred;
    }

    function echidna_buy_cost_monotonic() external view returns (bool) {
        return pairBuyCost1 <= pairBuyCost2;
    }

    function echidna_sell_proceeds_monotonic() external view returns (bool) {
        return pairSellProceeds1 <= pairSellProceeds2;
    }

    function echidna_buy_cost_ge_sell_proceeds() external view returns (bool) {
        return pairBuyCost1 >= pairRoundtripSellProceeds1 && pairBuyCost2 >= pairRoundtripSellProceeds2;
    }

    function _driftTolerance(uint256 baseline) private pure returns (uint256) {
        return DRIFT_TOLERANCE_WAD_WEI + (baseline / REL_DRIFT_DENOM);
    }

    function _boundQuantity(uint256 rawQuantity) private view returns (uint256) {
        uint256 minQuantity = alpha / 1e6;
        if (minQuantity == 0) {
            minQuantity = 1;
        }

        return _bound(rawQuantity, minQuantity, costHarness.maxSafeChunkQuantity(alpha));
    }

    function _boundRange(uint32 rawLo, uint32 rawHi) private pure returns (uint32 lo, uint32 hi) {
        lo = uint32(uint256(rawLo) % TREE_SIZE);
        hi = uint32(uint256(rawHi) % TREE_SIZE);
        if (lo > hi) {
            (lo, hi) = (hi, lo);
        }
    }

    function _handleClmsrRevert(bytes memory err) private {
        bytes4 sel = _selector(err);
        if (sel == SE.FP_DivisionByZero.selector || sel == SE.MathMulOverflow.selector) {
            return;
        }

        unexpectedRevertOccurred = true;
    }

    function _bound(uint256 x, uint256 min, uint256 max) private pure returns (uint256) {
        if (min == max) return min;
        if (min == 0 && max == type(uint256).max) return x;

        uint256 span = max - min;
        return min + (x % (span + 1));
    }

    function _selector(bytes memory err) private pure returns (bytes4 sel) {
        if (err.length < 4) {
            return bytes4(0);
        }

        assembly ("memory-safe") {
            sel := mload(add(err, 32))
        }
    }
}
