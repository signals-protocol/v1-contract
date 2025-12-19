// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../core/SignalsCore.sol";
import "../modules/trade/lib/LazyMulSegmentTree.sol";
import "../modules/trade/lib/ExposureDiffLib.sol";
import "../modules/trade/lib/TickBinLib.sol";
import "../interfaces/IRiskModule.sol";

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
    // Exposure Ledger test helpers (Fenwick-based)
    // ============================================================

    /**
     * @notice Set exposure at a specific tick for testing (Fenwick-based)
     * @dev Computes delta from current exposure and applies it via Fenwick rangeAdd
     * @param marketId Market identifier
     * @param tick Settlement tick (must be aligned to tickSpacing)
     * @param exposure Target exposure at this tick (token units)
     */
    function harnessSetExposure(uint256 marketId, int256 tick, uint256 exposure) external onlyOwner {
        ISignalsCore.Market storage market = markets[marketId];
        uint32 bin = TickBinLib.tickToBin(market.minTick, market.tickSpacing, market.numBins, tick);
        
        // Get current exposure via Fenwick point query
        int256 current = ExposureDiffLib.rawPrefixSum(_exposureFenwick[marketId], bin);
        int256 delta = int256(exposure) - current;
        
        // Apply delta to single bin [bin, bin]
        if (delta != 0) {
            ExposureDiffLib.rangeAdd(
                _exposureFenwick[marketId],
                bin,
                bin,
                delta,
                market.numBins
            );
        }
    }

    /**
     * @notice Add exposure to a range of ticks (Fenwick-based, simulates openPosition)
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
        ISignalsCore.Market storage market = markets[marketId];
        (uint32 loBin, uint32 hiBin) = TickBinLib.ticksToBins(
            market.minTick, market.maxTick, market.tickSpacing, market.numBins,
            lowerTick, upperTick
        );
        
        ExposureDiffLib.rangeAdd(
            _exposureFenwick[marketId],
            loBin,
            hiBin,
            int256(quantity),
            market.numBins
        );
    }

    /// @notice Set exposure at a specific tick (Diff-based)
    function harnessSetExposureAtTick(
        uint256 marketId,
        int256 tick,
        uint256 quantity
    ) external onlyOwner {
        ISignalsCore.Market storage market = markets[marketId];
        uint32 bin = TickBinLib.tickToBin(market.minTick, market.tickSpacing, market.numBins, tick);
        
        int256 current = ExposureDiffLib.rawPrefixSum(_exposureFenwick[marketId], bin);
        int256 delta = int256(quantity) - current;
        
        if (delta != 0) {
            ExposureDiffLib.rangeAdd(
                _exposureFenwick[marketId],
                bin,
                bin,
                delta,
                market.numBins
            );
        }
    }

    /// @notice Set payout reserve for a market (testing)
    function harnessSetPayoutReserve(
        uint256 marketId,
        uint256 amount
    ) external onlyOwner {
        _payoutReserve[marketId] = amount;
        _payoutReserveRemaining[marketId] = amount;
    }

    /**
     * @notice Get exposure at a specific tick (Fenwick-based)
     * @param marketId Market identifier
     * @param tick Settlement tick (must be aligned to tickSpacing)
     * @return exposure Total exposure at this tick
     */
    function harnessGetExposure(uint256 marketId, int256 tick) external view returns (uint256 exposure) {
        ISignalsCore.Market storage market = markets[marketId];
        uint32 bin = TickBinLib.tickToBin(market.minTick, market.tickSpacing, market.numBins, tick);
        return ExposureDiffLib.pointQuery(_exposureFenwick[marketId], bin);
    }

    /**
     * @notice Get payout reserve for a market
     * @param marketId Market identifier
     * @return reserve Total payout reserve for the market
     */
    function harnessGetPayoutReserve(uint256 marketId) external view returns (uint256 reserve) {
        return _payoutReserve[marketId];
    }

    // ============================================================
    // LP Vault state helpers for testing
    // ============================================================

    /// @notice Set LP vault state directly for testing α safety with drawdown
    function harnessSetLpVault(
        uint256 nav,
        uint256 shares,
        uint256 price,
        uint256 pricePeak,
        bool isSeeded
    ) external onlyOwner {
        lpVault.nav = nav;
        lpVault.shares = shares;
        lpVault.price = price;
        lpVault.pricePeak = pricePeak;
        lpVault.isSeeded = isSeeded;
    }

    /// @notice Get current LP vault state
    function harnessGetLpVault() external view returns (
        uint256 nav,
        uint256 shares,
        uint256 price,
        uint256 pricePeak,
        bool isSeeded
    ) {
        return (lpVault.nav, lpVault.shares, lpVault.price, lpVault.pricePeak, lpVault.isSeeded);
    }

    // ============================================================
    // Backward-compatible createMarket for tests
    // ============================================================

    /// @notice Create market with uniform prior (backward compatible for tests)
    /// @dev Generates uniform factors (all 1 WAD) internally
    function createMarketUniform(
        int256 minTick,
        int256 maxTick,
        int256 tickSpacing,
        uint64 startTimestamp,
        uint64 endTimestamp,
        uint64 settlementTimestamp,
        uint32 numBins,
        uint256 liquidityParameter,
        address feePolicy
    ) external onlyOwner whenNotPaused returns (uint256 marketId) {
        // Generate uniform factors for backward compatibility
        uint256[] memory factors = new uint256[](numBins);
        for (uint256 i = 0; i < numBins; i++) {
            factors[i] = 1e18;
        }
        
        // Risk gate first - RiskModule calculates deltaEt from factors
        _riskGate(abi.encodeCall(
            IRiskModule.gateCreateMarket,
            (liquidityParameter, numBins, factors)
        ));
        
        bytes memory ret = _delegate(lifecycleModule, abi.encodeWithSignature(
            "createMarket(int256,int256,int256,uint64,uint64,uint64,uint32,uint256,address,uint256[])",
            minTick,
            maxTick,
            tickSpacing,
            startTimestamp,
            endTimestamp,
            settlementTimestamp,
            numBins,
            liquidityParameter,
            feePolicy,
            factors
        ));
        if (ret.length > 0) marketId = abi.decode(ret, (uint256));
    }

    /// @dev Set market failed state for testing reopenMarket
    function harnessSetMarketFailed(uint256 marketId, bool failed) external onlyOwner {
        markets[marketId].failed = failed;
        if (failed) {
            markets[marketId].settled = false;
        }
    }

    /// @dev Set market settled state for testing
    function harnessSetMarketSettled(uint256 marketId, bool settled) external onlyOwner {
        markets[marketId].settled = settled;
    }
}
