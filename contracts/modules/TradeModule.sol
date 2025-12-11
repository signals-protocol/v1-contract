// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../interfaces/ISignalsCore.sol";
import "../interfaces/IFeePolicy.sol";
import "../interfaces/ISignalsPosition.sol";
import "../errors/CLMSRErrors.sol";
import "../errors/ModuleErrors.sol";
import "../core/lib/SignalsDistributionMath.sol";
import "../core/lib/SignalsClmsrMath.sol";
import "../lib/LazyMulSegmentTree.sol";
import "../lib/FixedPointMathU.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IOwnableLite {
    function owner() external view returns (address);
}

/// @notice Delegate-only trade module (skeleton)
contract TradeModule is SignalsCoreStorage {
    address private immutable self;

    // Events mirrored from v0 for parity
    event PositionOpened(
        uint256 indexed positionId,
        address indexed trader,
        uint256 indexed marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity,
        uint256 cost
    );

    event PositionIncreased(
        uint256 indexed positionId,
        address indexed trader,
        uint128 deltaQuantity,
        uint128 newQuantity,
        uint256 cost
    );

    event PositionDecreased(
        uint256 indexed positionId,
        address indexed trader,
        uint128 deltaQuantity,
        uint128 newQuantity,
        uint256 proceeds
    );

    event PositionClosed(uint256 indexed positionId, address indexed trader, uint256 proceeds);
    event PositionClaimed(uint256 indexed positionId, address indexed trader, uint256 payout);
    event PositionSettled(uint256 indexed positionId, address indexed trader, uint256 payout, bool isWin);

    event TradeFeeCharged(
        address indexed trader,
        uint256 indexed marketId,
        uint256 indexed positionId,
        bool isBuy,
        uint256 baseAmount,
        uint256 feeAmount,
        address feePolicy
    );

    using SignalsDistributionMath for LazyMulSegmentTree.Tree;
    using SignalsClmsrMath for uint256;
    using LazyMulSegmentTree for LazyMulSegmentTree.Tree;
    using FixedPointMathU for uint256;
    using SafeERC20 for IERC20;

    modifier onlyDelegated() {
        if (address(this) == self) revert ModuleErrors.NotDelegated();
        _;
    }

    constructor() {
        self = address(this);
    }

    // --- External stubs ---
    function openPosition(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity,
        uint256 maxCost
    ) external onlyDelegated returns (uint256 positionId) {
        if (quantity == 0) revert CE.InvalidQuantity(quantity);
        ISignalsCore.Market storage market = _loadAndValidateMarket(marketId);
        _validateTickRange(lowerTick, upperTick, market);

        uint256 qtyWad = uint256(quantity).toWad();
        uint256 costWad = _calculateTradeCostInternal(marketId, lowerTick, upperTick, qtyWad);
        uint256 cost6 = _roundDebit(costWad);

        uint256 fee6 = _quoteFee(true, msg.sender, marketId, lowerTick, upperTick, quantity, cost6);
        if (fee6 > cost6) revert CE.FeeExceedsBase(fee6, cost6);
        uint256 totalCost = cost6 + fee6;
        if (totalCost > maxCost) revert CE.CostExceedsMaximum(totalCost, maxCost);

        _pullPayment(msg.sender, totalCost);
        if (fee6 > 0) _pushPayment(_resolveFeeRecipient(), fee6);

        _applyFactorChunked(marketId, lowerTick, upperTick, qtyWad, market.liquidityParameter, true);

        // Phase 6: Accumulate fees (P&L calculated from tree state at settlement)
        market.accumulatedFees += fee6;

        positionId = positionContract.mintPosition(msg.sender, marketId, lowerTick, upperTick, quantity);
        if (!market.settled) {
            market.openPositionCount += 1;
        }

        emit TradeFeeCharged(msg.sender, marketId, positionId, true, cost6, fee6, _resolveFeePolicy(market));
    }

    function increasePosition(
        uint256 positionId,
        uint128 quantity,
        uint256 maxCost
    ) external onlyDelegated {
        if (quantity == 0) revert CE.InvalidQuantity(quantity);
        ISignalsPosition.Position memory position = positionContract.getPosition(positionId);
        if (positionContract.ownerOf(positionId) != msg.sender) revert CE.UnauthorizedCaller(msg.sender);

        ISignalsCore.Market storage market = _loadAndValidateMarket(position.marketId);
        _validateTickRange(position.lowerTick, position.upperTick, market);

        uint256 qtyWad = uint256(quantity).toWad();
        uint256 costWad = _calculateTradeCostInternal(position.marketId, position.lowerTick, position.upperTick, qtyWad);
        uint256 cost6 = _roundDebit(costWad);

        uint256 fee6 = _quoteFee(true, msg.sender, position.marketId, position.lowerTick, position.upperTick, quantity, cost6);
        if (fee6 > cost6) revert CE.FeeExceedsBase(fee6, cost6);
        uint256 totalCost = cost6 + fee6;
        if (totalCost > maxCost) revert CE.CostExceedsMaximum(totalCost, maxCost);

        _pullPayment(msg.sender, totalCost);
        if (fee6 > 0) _pushPayment(_resolveFeeRecipient(), fee6);

        _applyFactorChunked(position.marketId, position.lowerTick, position.upperTick, qtyWad, market.liquidityParameter, true);

        // Phase 6: Accumulate fees (P&L calculated from tree state at settlement)
        market.accumulatedFees += fee6;

        uint128 newQuantity = position.quantity + quantity;
        positionContract.updateQuantity(positionId, newQuantity);

        emit TradeFeeCharged(msg.sender, position.marketId, positionId, true, cost6, fee6, _resolveFeePolicy(market));
    }

    function decreasePosition(
        uint256 positionId,
        uint128 quantity,
        uint256 minProceeds
    ) external onlyDelegated {
        ISignalsPosition.Position memory position = positionContract.getPosition(positionId);
        _decreasePositionInternal(position, positionId, quantity, minProceeds);
    }

    function closePosition(
        uint256 positionId,
        uint256 minProceeds
    ) external onlyDelegated {
        ISignalsPosition.Position memory position = positionContract.getPosition(positionId);
        (uint128 newQty, uint256 baseProceeds) = _decreasePositionInternal(
            position,
            positionId,
            position.quantity,
            minProceeds
        );
        if (newQty != 0) revert CE.CloseInconsistent(0, newQty);
        emit PositionClosed(positionId, msg.sender, baseProceeds);
    }

    function claimPayout(uint256 positionId) external onlyDelegated {
        ISignalsPosition.Position memory position = positionContract.getPosition(positionId);
        if (positionContract.ownerOf(positionId) != msg.sender) revert CE.UnauthorizedCaller(msg.sender);

        ISignalsCore.Market storage market = markets[position.marketId];
        if (!market.settled) revert CE.MarketNotSettled(position.marketId);

        uint64 claimOpen = (market.settlementTimestamp == 0 ? market.endTimestamp : market.settlementTimestamp) +
            settlementFinalizeDeadline;
        if (block.timestamp < claimOpen) revert CE.SettlementTooEarly(claimOpen, uint64(block.timestamp));

        uint256 payout = _calculateClaimAmount(position, market);

        if (payout > 0) {
            _pushPayment(msg.sender, payout);
        }

        positionContract.burn(positionId);

        if (!positionSettledEmitted[positionId]) {
            positionSettledEmitted[positionId] = true;
            emit PositionSettled(positionId, msg.sender, payout, payout > 0);
        }

        emit PositionClaimed(positionId, msg.sender, payout);
    }

    // --- View stubs ---

    function calculateOpenCost(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity
    ) external view returns (uint256 cost) {
        if (quantity == 0) revert CE.InvalidQuantity(quantity);
        ISignalsCore.Market storage market = _loadAndValidateMarket(marketId);
        _validateTickRange(lowerTick, upperTick, market);

        uint256 costWad = _calculateTradeCostInternal(
            marketId,
            lowerTick,
            upperTick,
            uint256(quantity).toWad()
        );
        return _roundDebit(costWad);
    }

    function calculateIncreaseCost(
        uint256 positionId,
        uint128 quantity
    ) external view returns (uint256 cost) {
        if (quantity == 0) revert CE.InvalidQuantity(quantity);
        ISignalsCore.Market storage market;
        {
            ISignalsPosition.Position memory position = positionContract.getPosition(positionId);
            market = _loadAndValidateMarket(position.marketId);
            _validateTickRange(position.lowerTick, position.upperTick, market);
            uint256 costWad = _calculateTradeCostInternal(
                position.marketId,
                position.lowerTick,
                position.upperTick,
                uint256(quantity).toWad()
            );
            return _roundDebit(costWad);
        }
    }

    function calculateDecreaseProceeds(
        uint256 positionId,
        uint128 quantity
    ) external view returns (uint256 proceeds) {
        if (quantity == 0) revert CE.InvalidQuantity(quantity);
        ISignalsPosition.Position memory position = positionContract.getPosition(positionId);
        ISignalsCore.Market storage market = _loadAndValidateMarket(position.marketId);
        _validateTickRange(position.lowerTick, position.upperTick, market);
        uint256 proceedsWad = _calculateSellProceeds(
            position.marketId,
            position.lowerTick,
            position.upperTick,
            uint256(quantity).toWad()
        );
        return _roundCredit(proceedsWad);
    }

    function calculateCloseProceeds(
        uint256 positionId
    ) external view returns (uint256 proceeds) {
        ISignalsPosition.Position memory position = positionContract.getPosition(positionId);
        ISignalsCore.Market storage market = _loadAndValidateMarket(position.marketId);
        _validateTickRange(position.lowerTick, position.upperTick, market);
        uint256 proceedsWad = _calculateSellProceeds(
            position.marketId,
            position.lowerTick,
            position.upperTick,
            uint256(position.quantity).toWad()
        );
        return _roundCredit(proceedsWad);
    }

    function calculatePositionValue(
        uint256 positionId
    ) external view returns (uint256 value) {
        ISignalsPosition.Position memory position = positionContract.getPosition(positionId);
        ISignalsCore.Market storage market = markets[position.marketId];
        _validateTickRange(position.lowerTick, position.upperTick, market);
        uint256 proceedsWad = _calculateSellProceeds(
            position.marketId,
            position.lowerTick,
            position.upperTick,
            uint256(position.quantity).toWad()
        );
        return _roundCredit(proceedsWad);
    }

    // --- Shared validation helpers ---

    function _marketExists(uint256 marketId) internal view returns (bool) {
        return markets[marketId].numBins > 0;
    }

    /// @dev Loads a market and enforces active/time checks shared across trade entrypoints.
    function _loadAndValidateMarket(uint256 marketId)
        internal
        view
        returns (ISignalsCore.Market storage market)
    {
        market = markets[marketId];
        if (!_marketExists(marketId)) revert CE.MarketNotFound(marketId);
        if (market.settled) revert CE.MarketAlreadySettled(marketId);
        if (!market.isActive) revert CE.MarketNotActive();
        if (block.timestamp < market.startTimestamp) revert CE.MarketNotStarted();
        if (block.timestamp > market.endTimestamp) revert CE.MarketExpired();
    }

    function _validateTick(int256 tick, ISignalsCore.Market memory market) internal pure {
        if (tick < market.minTick || tick > market.maxTick) {
            revert CE.InvalidTick(tick, market.minTick, market.maxTick);
        }
        if ((tick - market.minTick) % market.tickSpacing != 0) {
            revert CE.InvalidTickSpacing(tick, market.tickSpacing);
        }
    }

    /// @dev Validates tick ordering/spacing; “no point betting” enforced via strict inequality.
    function _validateTickRange(
        int256 lowerTick,
        int256 upperTick,
        ISignalsCore.Market memory market
    ) internal pure {
        _validateTick(lowerTick, market);
        _validateTick(upperTick, market);
        if (lowerTick >= upperTick) {
            revert CE.InvalidTickRange(lowerTick, upperTick);
        }
        if ((upperTick - lowerTick) % market.tickSpacing != 0) {
            revert CE.InvalidTickRange(lowerTick, upperTick);
        }
    }

    /// @dev Converts ticks to inclusive bin range; reverts if out of bounds.
    function _ticksToBins(
        ISignalsCore.Market memory market,
        int256 lowerTick,
        int256 upperTick
    ) internal pure returns (uint32 loBin, uint32 hiBin) {
        _validateTickRange(lowerTick, upperTick, market);
        loBin = uint32(uint256((lowerTick - market.minTick) / market.tickSpacing));
        hiBin = uint32(uint256((upperTick - market.minTick) / market.tickSpacing - 1));
        if (loBin >= market.numBins || hiBin >= market.numBins) {
            revert CE.RangeBinsOutOfBounds(loBin, hiBin, market.numBins);
        }
        if (loBin > hiBin) revert CE.InvalidRangeBins(loBin, hiBin);
    }

    /// @dev Thin wrapper to calculate buy cost using shared library.
    function _calculateTradeCostInternal(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint256 quantityWad
    ) internal view returns (uint256 costWad) {
        ISignalsCore.Market storage market = markets[marketId];
        LazyMulSegmentTree.Tree storage tree = marketTrees[marketId];
        (uint32 loBin, uint32 hiBin) = _ticksToBins(market, lowerTick, upperTick);
        costWad = tree.calculateTradeCost(market.liquidityParameter, loBin, hiBin, quantityWad);
    }

    /// @dev Thin wrapper to calculate sell proceeds using shared library.
    function _calculateSellProceeds(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint256 quantityWad
    ) internal view returns (uint256 proceedsWad) {
        ISignalsCore.Market storage market = markets[marketId];
        LazyMulSegmentTree.Tree storage tree = marketTrees[marketId];
        (uint32 loBin, uint32 hiBin) = _ticksToBins(market, lowerTick, upperTick);
        proceedsWad = tree.calculateSellProceeds(market.liquidityParameter, loBin, hiBin, quantityWad);
    }

    /// @dev Thin wrapper to back out quantity from cost using shared library.
    function _calculateQuantityFromCostInternal(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint256 costWad
    ) internal view returns (uint256 quantityWad) {
        ISignalsCore.Market storage market = markets[marketId];
        LazyMulSegmentTree.Tree storage tree = marketTrees[marketId];
        (uint32 loBin, uint32 hiBin) = _ticksToBins(market, lowerTick, upperTick);
        quantityWad = tree.calculateQuantityFromCost(market.liquidityParameter, loBin, hiBin, costWad);
    }

    function _decreasePositionInternal(
        ISignalsPosition.Position memory position,
        uint256 positionId,
        uint128 quantity,
        uint256 minProceeds
    ) internal returns (uint128 newQuantity, uint256 baseProceeds) {
        if (quantity == 0) revert CE.InvalidQuantity(quantity);
        if (positionContract.ownerOf(positionId) != msg.sender) revert CE.UnauthorizedCaller(msg.sender);

        ISignalsCore.Market storage market = _loadAndValidateMarket(position.marketId);
        _validateTickRange(position.lowerTick, position.upperTick, market);

        if (quantity > position.quantity) revert CE.InsufficientPositionQuantity(quantity, position.quantity);

        uint256 qtyWad = uint256(quantity).toWad();
        uint256 proceedsWad = _calculateSellProceeds(position.marketId, position.lowerTick, position.upperTick, qtyWad);
        baseProceeds = _roundCredit(proceedsWad);

        uint256 fee6 = _quoteFee(
            false,
            msg.sender,
            position.marketId,
            position.lowerTick,
            position.upperTick,
            quantity,
            baseProceeds
        );
        if (fee6 > baseProceeds) revert CE.FeeExceedsBase(fee6, baseProceeds);
        uint256 netProceeds = baseProceeds - fee6;
        if (netProceeds < minProceeds) revert CE.ProceedsBelowMinimum(netProceeds, minProceeds);

        _applyFactorChunked(position.marketId, position.lowerTick, position.upperTick, qtyWad, market.liquidityParameter, false);

        // Phase 6: Accumulate fees (P&L calculated from tree state at settlement)
        market.accumulatedFees += fee6;

        _pushPayment(msg.sender, netProceeds);
        if (fee6 > 0) _pushPayment(_resolveFeeRecipient(), fee6);

        newQuantity = position.quantity - quantity;
        if (newQuantity == 0) {
            positionContract.burn(positionId);
            if (!market.settled && market.openPositionCount > 0) {
                market.openPositionCount -= 1;
            }
        } else {
            positionContract.updateQuantity(positionId, newQuantity);
        }

        emit TradeFeeCharged(msg.sender, position.marketId, positionId, false, baseProceeds, fee6, _resolveFeePolicy(market));
    }

    // --- Fee/payment helpers ---

    function _roundDebit(uint256 wadAmount) internal pure returns (uint256) {
        return wadAmount.fromWadRoundUp();
    }

    function _roundCredit(uint256 wadAmount) internal pure returns (uint256) {
        return wadAmount.fromWad();
    }

    function _resolveFeeRecipient() internal view returns (address) {
        if (feeRecipient != address(0)) return feeRecipient;
        return IOwnableLite(address(this)).owner();
    }

    function _resolveFeePolicy(ISignalsCore.Market memory market) internal view returns (address) {
        return market.feePolicy != address(0) ? market.feePolicy : defaultFeePolicy;
    }

    function _quoteFee(
        bool isBuy,
        address trader,
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity,
        uint256 baseAmount
    ) internal view returns (uint256 fee6) {
        ISignalsCore.Market memory market = markets[marketId];
        address policyAddress = _resolveFeePolicy(market);
        if (policyAddress == address(0)) return 0;
        IFeePolicy.QuoteParams memory params = IFeePolicy.QuoteParams({
            trader: trader,
            marketId: marketId,
            lowerTick: lowerTick,
            upperTick: upperTick,
            quantity: quantity,
            baseAmount: baseAmount,
            isBuy: isBuy,
            context: bytes32(0)
        });
        fee6 = IFeePolicy(policyAddress).quoteFee(params);
        if (fee6 > baseAmount) revert CE.FeeExceedsBase(fee6, baseAmount);
    }

    function _pullPayment(address from, uint256 amount6) internal {
        if (amount6 == 0) return;
        uint256 balance = paymentToken.balanceOf(from);
        if (balance < amount6) revert CE.InsufficientBalance(from, amount6, balance);
        paymentToken.safeTransferFrom(from, address(this), amount6);
    }

    function _pushPayment(address to, uint256 amount6) internal {
        if (amount6 == 0) return;
        paymentToken.safeTransfer(to, amount6);
    }

    // --- Tree update helper ---

    function _applyFactorChunked(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint256 qtyWad,
        uint256 alpha,
        bool isBuy
    ) internal {
        ISignalsCore.Market memory market = markets[marketId];
        (uint32 loBin, uint32 hiBin) = _ticksToBins(market, lowerTick, upperTick);
        uint256 factor = SignalsClmsrMath._safeExp(qtyWad, alpha);
        if (!isBuy) {
            uint256 WAD = 1e18;
            factor = WAD.wDivUp(factor);
        }
        marketTrees[marketId].applyRangeFactor(loBin, hiBin, factor);
    }

    function _calculateClaimAmount(
        ISignalsPosition.Position memory position,
        ISignalsCore.Market memory market
    ) internal pure returns (uint256) {
        if (!market.settled) return 0;
        bool winning = position.lowerTick <= market.settlementTick && position.upperTick > market.settlementTick;
        if (!winning) return 0;
        // v0 semantics: payout is position quantity (6-dec) when in-range
        return uint256(position.quantity);
    }
}
