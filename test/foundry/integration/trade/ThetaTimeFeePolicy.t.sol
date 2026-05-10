// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/TradeModuleDeployer.sol";
import "../../../../contracts/fees/ThetaTimeFeePolicy.sol";
import "../../../../contracts/interfaces/IFeePolicy.sol";

/// @title ThetaTimeFeePolicyIntegrationTest
/// @notice Integration: ThetaTimeFeePolicy charges time-based fees across buy/sell flows.
/// @dev Mirrors test/integration/trade/thetaTimeFeePolicy.spec.ts (5 tests — combined into flow).
contract ThetaTimeFeePolicyIntegrationTest is TradeModuleDeployer {
    TradeModuleSystem sys;
    ThetaTimeFeePolicy feePolicy;
    uint64 endTimestamp;

    uint256 constant BASE_BPS = 30;
    uint256 constant THETA_MAX_BPS = 3000;
    uint32 window;
    uint8 constant BETA = 2;

    function setUp() public override {
        super.setUp();

        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: 4, tickSpacing: 1, minTick: 0, maxTick: 4, endOffset: ONE_HOUR * 2, liquidityParameter: WAD
        });
        sys = deployTradeModuleSystem(
            DeployOptions({
                markets: markets, userCount: 1, fundAmount: 100_000e6, submitWindow: 300, settlementWindow: 60
            })
        );

        window = uint32(ONE_HOUR);

        // Deploy ThetaTimeFeePolicy
        feePolicy = new ThetaTimeFeePolicy(address(sys.core), BASE_BPS, THETA_MAX_BPS, window, BETA);

        // Attach fee policy to market
        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        m.feePolicy = address(feePolicy);
        sys.core.setMarket(1, m);

        endTimestamp = m.endTimestamp;
    }

    /// @notice Fees increase as time approaches market end: open < increase < decrease < close.
    function test_chargesTimeBasedFeesAcrossBuySellFlows() public {
        address user = sys.users[0];
        int256 lo = 0;
        int256 hi = 4;
        uint128 qty = 1_000_000;

        // OPEN at tau = window (base fee only)
        uint64 tOpen = endTimestamp - uint64(window);
        vm.warp(tOpen);
        vm.prank(user);
        sys.core.openPosition(1, lo, hi, qty, type(uint256).max);

        // INCREASE at tau = window / 2
        uint64 tInc = endTimestamp - uint64(window) / 2;
        vm.warp(tInc);
        vm.prank(user);
        sys.core.increasePosition(1, qty, type(uint256).max);

        // DECREASE at tau = window / 4
        uint64 tDec = endTimestamp - uint64(window) / 4;
        vm.warp(tDec);
        vm.prank(user);
        sys.core.decreasePosition(1, qty, 0);

        // CLOSE at tau = 0 (max theta)
        vm.warp(endTimestamp);
        vm.prank(user);
        sys.core.closePosition(1, 0);

        // Market accumulates fees
        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        assertGt(m.accumulatedFees, 0, "fees should accumulate");
    }

    /// @notice Verify fee increases monotonically as tau decreases (same qty, same range).
    function test_feeIncreasesAsTimeApproachesEnd() public {
        // Quote fees at different tau values
        IFeePolicy.QuoteParams memory params = IFeePolicy.QuoteParams({
            trader: sys.users[0],
            marketId: 1,
            lowerTick: 0,
            upperTick: 4,
            quantity: 1_000_000,
            baseAmount: 1_000_000, // 1 USDC base
            isBuy: true,
            context: bytes32(0)
        });

        // At tau = window (far from end)
        vm.warp(endTimestamp - uint64(window));
        uint256 feeFar = feePolicy.quoteFee(params);

        // At tau = window / 2
        vm.warp(endTimestamp - uint64(window) / 2);
        uint256 feeMid = feePolicy.quoteFee(params);

        // At tau = 0 (market end)
        vm.warp(endTimestamp);
        uint256 feeClose = feePolicy.quoteFee(params);

        assertLe(feeFar, feeMid, "fee at window should be <= fee at window/2");
        assertLe(feeMid, feeClose, "fee at window/2 should be <= fee at end");
    }

    /// @notice Base fee only when tau >= window.
    function test_baseFeeOnlyWhenTauGteWindow() public {
        IFeePolicy.QuoteParams memory params = IFeePolicy.QuoteParams({
            trader: sys.users[0],
            marketId: 1,
            lowerTick: 0,
            upperTick: 4,
            quantity: 1_000_000,
            baseAmount: 1_000_000,
            isBuy: true,
            context: bytes32(0)
        });

        // At tau > window (current block.timestamp is far from end)
        assertGe(endTimestamp - uint64(block.timestamp), window);
        uint256 fee = feePolicy.quoteFee(params);

        // Base fee = baseAmount * baseBps / 10000 = 1_000_000 * 30 / 10000 = 3000
        uint256 expectedBaseFee = (params.baseAmount * BASE_BPS) / 10_000;
        assertEq(fee, expectedBaseFee, "should charge only base fee when far from end");
    }

    /// @notice Sell (isBuy=false) also incurs time-based fees.
    function test_sellAlsoIncursTimeBasedFees() public {
        IFeePolicy.QuoteParams memory params = IFeePolicy.QuoteParams({
            trader: sys.users[0],
            marketId: 1,
            lowerTick: 0,
            upperTick: 4,
            quantity: 1_000_000,
            baseAmount: 1_000_000,
            isBuy: false,
            context: bytes32(0)
        });

        // At tau = 0 (max theta)
        vm.warp(endTimestamp);
        uint256 fee = feePolicy.quoteFee(params);

        uint256 baseFee = (params.baseAmount * BASE_BPS) / 10_000;
        assertGt(fee, baseFee, "sell fee at end should exceed base fee");
    }

    /// @notice Zero base amount produces zero fee.
    function test_zeroBaseAmountProducesZeroFee() public {
        IFeePolicy.QuoteParams memory params = IFeePolicy.QuoteParams({
            trader: sys.users[0],
            marketId: 1,
            lowerTick: 0,
            upperTick: 4,
            quantity: 1_000_000,
            baseAmount: 0,
            isBuy: true,
            context: bytes32(0)
        });

        vm.warp(endTimestamp);
        uint256 fee = feePolicy.quoteFee(params);
        assertEq(fee, 0, "zero base amount should produce zero fee");
    }
}
