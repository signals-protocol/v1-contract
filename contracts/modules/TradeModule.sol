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
import "./trade/lib/LazyMulSegmentTree.sol";
import "../lib/FixedPointMathU.sol";
import "./trade/lib/ExposureDiffLib.sol";
import "./trade/lib/TickBinLib.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IOwnableLite {
    function owner() external view returns (address);
}

/// @notice Delegate-only trade module (skeleton)
contract TradeModule is SignalsCoreStorage {
    address private immutable self;
    
    uint256 internal constant WAD = 1e18;

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
        
        // Cache market params and compute bins ONCE
        uint256 alpha = market.liquidityParameter;
        uint32 numBins = market.numBins;
        address feePolicy = market.feePolicy != address(0) ? market.feePolicy : defaultFeePolicy;
        (uint32 loBin, uint32 hiBin) = TickBinLib.ticksToBinsPrim(
            market.minTick, market.maxTick, market.tickSpacing, numBins, lowerTick, upperTick
        );

        uint256 qtyWad = uint256(quantity).toWad();
        uint256 costWad = _calculateTradeCostBins(marketId, loBin, hiBin, qtyWad, alpha);
        uint256 cost6 = _roundDebit(costWad);

        uint256 fee6 = _quoteFeeWithPolicy(feePolicy, true, msg.sender, marketId, lowerTick, upperTick, quantity, cost6);
        if (fee6 > cost6) revert CE.FeeExceedsBase(fee6, cost6);
        uint256 totalCost = cost6 + fee6;
        if (totalCost > maxCost) revert CE.CostExceedsMaximum(totalCost, maxCost);

        _pullPayment(msg.sender, totalCost);

        _applyFactorBins(marketId, loBin, hiBin, qtyWad, alpha, true);
        market.accumulatedFees += fee6.toWad();
        _addExposureBins(marketId, loBin, hiBin, quantity, numBins);

        positionId = positionContract.mintPosition(msg.sender, marketId, lowerTick, upperTick, quantity);
        if (!market.settled) {
            market.openPositionCount += 1;
        }

        emit TradeFeeCharged(msg.sender, marketId, positionId, true, cost6, fee6, feePolicy);
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
        
        // Cache market params and compute bins ONCE
        uint256 alpha = market.liquidityParameter;
        uint32 numBins = market.numBins;
        address feePolicy = market.feePolicy != address(0) ? market.feePolicy : defaultFeePolicy;
        (uint32 loBin, uint32 hiBin) = TickBinLib.ticksToBinsPrim(
            market.minTick, market.maxTick, market.tickSpacing, numBins,
            position.lowerTick, position.upperTick
        );

        uint256 qtyWad = uint256(quantity).toWad();
        uint256 costWad = _calculateTradeCostBins(position.marketId, loBin, hiBin, qtyWad, alpha);
        uint256 cost6 = _roundDebit(costWad);

        uint256 fee6 = _quoteFeeWithPolicy(feePolicy, true, msg.sender, position.marketId, position.lowerTick, position.upperTick, quantity, cost6);
        if (fee6 > cost6) revert CE.FeeExceedsBase(fee6, cost6);
        uint256 totalCost = cost6 + fee6;
        if (totalCost > maxCost) revert CE.CostExceedsMaximum(totalCost, maxCost);

        _pullPayment(msg.sender, totalCost);

        _applyFactorBins(position.marketId, loBin, hiBin, qtyWad, alpha, true);
        market.accumulatedFees += fee6.toWad();
        _addExposureBins(position.marketId, loBin, hiBin, quantity, numBins);

        uint128 newQuantity = position.quantity + quantity;
        positionContract.updateQuantity(positionId, newQuantity);

        emit TradeFeeCharged(msg.sender, position.marketId, positionId, true, cost6, fee6, feePolicy);
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

    /**
     * @notice Claim payout for a winning position after market settlement
     * @dev Phase 6 (WP v1.0):
     *      - Claim is gated by time: settlementFinalizedAt + Δ_claim
     *      - Payout draws from escrow (reserved at settlement finalization)
     *      - NAV is unaffected because payout was already reserved in escrow at settlement
     *      - Batch processing status is IRRELEVANT to claim eligibility
     * @param positionId Position ID to claim payout for
     */
    function claimPayout(uint256 positionId) external onlyDelegated {
        ISignalsPosition.Position memory position = positionContract.getPosition(positionId);
        if (positionContract.ownerOf(positionId) != msg.sender) revert CE.UnauthorizedCaller(msg.sender);

        ISignalsCore.Market storage market = markets[position.marketId];
        if (!market.settled) revert CE.MarketNotSettled(position.marketId);

        // Phase 6: Time-based gating (WP v1.0 Oracle & Settlement State Machine)
        // Claim is allowed after settlementFinalizedAt + Δ_claim
        // Note: Batch processing status is NOT a gating condition
        uint64 claimOpen = market.settlementFinalizedAt + claimDelaySeconds;
        if (block.timestamp < claimOpen) revert CE.ClaimTooEarly(claimOpen, uint64(block.timestamp));

        uint256 payout = _calculateClaimAmount(position, market);

        // Phase 6: Draw from payout escrow (reserved at settlement finalization)
        // This ensures NAV is unaffected because:
        // 1. At settlement, Payout_t was calculated from exposure ledger
        // 2. Payout_t was reserved in escrow (deducted from core balance)
        // 3. L_t = ΔC_t - Payout_t was recorded (payout already reflected in P&L)
        // 4. Claim draws only from escrow, not affecting current NAV/price
        if (payout > 0) {
            uint256 remaining = _payoutReserveRemaining[position.marketId];
            if (payout > remaining) {
                payout = remaining; // Cap at remaining reserve (safety)
            }
            _payoutReserveRemaining[position.marketId] = remaining - payout;
            
            // Track total payout reserve for free balance calculation
            _totalPayoutReserve6 -= payout;
            
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

    /// @dev Converts ticks to inclusive bin range using shared library
    function _ticksToBins(
        ISignalsCore.Market memory market,
        int256 lowerTick,
        int256 upperTick
    ) internal pure returns (uint32 loBin, uint32 hiBin) {
        _validateTickRange(lowerTick, upperTick, market);
        return TickBinLib.ticksToBins(market, lowerTick, upperTick);
    }

    /// @dev Converts a single tick to bin index using shared library
    function _tickToBin(
        ISignalsCore.Market memory market,
        int256 tick
    ) internal pure returns (uint32 bin) {
        return TickBinLib.tickToBin(market, tick);
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

    /**
     * @notice Calculate trade cost using pre-computed bins (gas optimized)
     * @dev Avoids redundant Market memory copy and bins calculation
     */
    function _calculateTradeCostBins(
        uint256 marketId,
        uint32 loBin,
        uint32 hiBin,
        uint256 quantityWad,
        uint256 alpha
    ) internal view returns (uint256 costWad) {
        LazyMulSegmentTree.Tree storage tree = marketTrees[marketId];
        costWad = tree.calculateTradeCost(alpha, loBin, hiBin, quantityWad);
    }

    /**
     * @notice Calculate sell proceeds using pre-computed bins (gas optimized)
     * @dev Avoids redundant Market memory copy and bins calculation
     */
    function _calculateSellProceedsBins(
        uint256 marketId,
        uint32 loBin,
        uint32 hiBin,
        uint256 quantityWad,
        uint256 alpha
    ) internal view returns (uint256 proceedsWad) {
        LazyMulSegmentTree.Tree storage tree = marketTrees[marketId];
        proceedsWad = tree.calculateSellProceeds(alpha, loBin, hiBin, quantityWad);
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

        // Cache market params and compute bins ONCE
        uint256 alpha = market.liquidityParameter;
        uint32 numBins = market.numBins;
        address feePolicy = market.feePolicy != address(0) ? market.feePolicy : defaultFeePolicy;
        (uint32 loBin, uint32 hiBin) = TickBinLib.ticksToBinsPrim(
            market.minTick, market.maxTick, market.tickSpacing, numBins,
            position.lowerTick, position.upperTick
        );

        uint256 qtyWad = uint256(quantity).toWad();
        uint256 proceedsWad = _calculateSellProceedsBins(position.marketId, loBin, hiBin, qtyWad, alpha);
        baseProceeds = _roundCredit(proceedsWad);

        uint256 fee6 = _quoteFeeWithPolicy(
            feePolicy,
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

        _applyFactorBins(position.marketId, loBin, hiBin, qtyWad, alpha, false);
        market.accumulatedFees += fee6.toWad();
        _removeExposureBins(position.marketId, loBin, hiBin, quantity, numBins);

        _pushPayment(msg.sender, netProceeds);

        newQuantity = position.quantity - quantity;
        if (newQuantity == 0) {
            positionContract.burn(positionId);
            if (!market.settled && market.openPositionCount > 0) {
                market.openPositionCount -= 1;
            }
        } else {
            positionContract.updateQuantity(positionId, newQuantity);
        }

        emit TradeFeeCharged(msg.sender, position.marketId, positionId, false, baseProceeds, fee6, feePolicy);
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

    /**
     * @notice Quote fee using pre-resolved policy address (gas optimized)
     * @dev Avoids redundant Market memory copy for policy resolution
     */
    function _quoteFeeWithPolicy(
        address policyAddress,
        bool isBuy,
        address trader,
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity,
        uint256 baseAmount
    ) internal view returns (uint256 fee6) {
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
            factor = WAD.wDivUp(factor);
        }
        marketTrees[marketId].applyRangeFactor(loBin, hiBin, factor);
    }

    /**
     * @notice Apply factor to tree using pre-computed bins (gas optimized)
     * @dev Avoids redundant Market memory copy and bins calculation
     */
    function _applyFactorBins(
        uint256 marketId,
        uint32 loBin,
        uint32 hiBin,
        uint256 qtyWad,
        uint256 alpha,
        bool isBuy
    ) internal {
        uint256 factor = SignalsClmsrMath._safeExp(qtyWad, alpha);
        if (!isBuy) {
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

    // --- Exposure Ledger helpers (Diff-based) ---

    /**
     * @notice Update exposure ledger for position open/increase (Diff-based)
     * @dev Uses O(1) diff array update: exactly 2 storage writes
     *      WP v2 Sec 3.5: Q_{t,b} accumulates quantity for all positions covering bin b
     * @param marketId Market identifier
     * @param lowerTick Lower bound (inclusive)
     * @param upperTick Upper bound (exclusive)
     * @param quantity Position quantity (token units)
     */
    function _addExposure(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity
    ) internal {
        ISignalsCore.Market memory market = markets[marketId];
        (uint32 loBin, uint32 hiBin) = _ticksToBins(market, lowerTick, upperTick);
        
        // Use diff array for O(1) range update
        ExposureDiffLib.rangeAdd(
            _exposureFenwick[marketId],
            loBin,
            hiBin,
            int256(uint256(quantity)),
            market.numBins
        );
    }

    /**
     * @notice Update exposure ledger using pre-computed bins (gas optimized)
     * @dev Avoids redundant Market memory copy and bins calculation
     */
    function _addExposureBins(
        uint256 marketId,
        uint32 loBin,
        uint32 hiBin,
        uint128 quantity,
        uint32 numBins
    ) internal {
        ExposureDiffLib.rangeAdd(
            _exposureFenwick[marketId],
            loBin,
            hiBin,
            int256(uint256(quantity)),
            numBins
        );
    }

    /**
     * @notice Update exposure ledger for position decrease/close (Diff-based)
     * @dev Uses O(1) diff array update with negative delta
     *      WP v2 Sec 3.5: Decreasing/closing subtracts over the same range
     * @param marketId Market identifier
     * @param lowerTick Lower bound (inclusive)
     * @param upperTick Upper bound (exclusive)
     * @param quantity Position quantity (token units)
     */
    function _removeExposure(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity
    ) internal {
        ISignalsCore.Market memory market = markets[marketId];
        (uint32 loBin, uint32 hiBin) = _ticksToBins(market, lowerTick, upperTick);
        
        // Use diff array for O(1) range update (negative delta)
        ExposureDiffLib.rangeAdd(
            _exposureFenwick[marketId],
            loBin,
            hiBin,
            -int256(uint256(quantity)),
            market.numBins
        );
    }

    /**
     * @notice Remove exposure using pre-computed bins (gas optimized)
     * @dev Avoids redundant Market memory copy and bins calculation
     */
    function _removeExposureBins(
        uint256 marketId,
        uint32 loBin,
        uint32 hiBin,
        uint128 quantity,
        uint32 numBins
    ) internal {
        ExposureDiffLib.rangeAdd(
            _exposureFenwick[marketId],
            loBin,
            hiBin,
            -int256(uint256(quantity)),
            numBins
        );
    }

    /**
     * @notice Get payout exposure at a specific tick (Diff-based)
     * @dev Uses O(n) prefix sum - acceptable since only called once per market at settlement
     * @param marketId Market identifier
     * @param tick Settlement tick (must be aligned to tickSpacing)
     * @return exposure Total payout owed if settlement tick is `tick`
     */
    function _getExposureAtTick(
        uint256 marketId,
        int256 tick
    ) internal view returns (uint256 exposure) {
        ISignalsCore.Market memory market = markets[marketId];
        uint32 bin = _tickToBin(market, tick);
        
        // Use diff array prefix sum for point query
        return ExposureDiffLib.pointQuery(_exposureFenwick[marketId], bin);
    }
}
