// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/TradeModuleDeployer.sol";
import "../../../../contracts/fees/ThetaTimeFeePolicy.sol";
import "../../../../contracts/interfaces/IFeePolicy.sol";
import "../../../../contracts/interfaces/ISignalsCore.sol";

contract ThetaTimeFeePolicyTest is TradeModuleDeployer {
    TradeModuleSystem sys;
    uint64 endTimestamp;

    uint256 constant BPS_DENOM = 10_000;

    function setUp() public override {
        super.setUp();
        sys = deployMinimalTradeSystem();

        // Get market endTimestamp via harness getter
        ISignalsCore.Market memory market = sys.core.harnessGetMarket(1);
        endTimestamp = market.endTimestamp;
    }

    // ============================================================
    // Fee calculations
    // ============================================================

    function test_baseFeeOnlyWhenTauGteWindow() public {
        uint256 baseBps = 30;
        uint256 thetaMaxBps = 3000;
        uint32 window = uint32(ONE_HOUR);
        uint8 beta = 2;
        uint256 baseAmount = 1_000_000;

        ThetaTimeFeePolicy fp = new ThetaTimeFeePolicy(address(sys.core), baseBps, thetaMaxBps, window, beta);

        // Tau is > window (we just deployed, far from endTimestamp)
        assertGe(endTimestamp - uint64(block.timestamp), window);

        uint256 fee = fp.quoteFee(
            IFeePolicy.QuoteParams({
                trader: address(0),
                marketId: 1,
                lowerTick: 0,
                upperTick: 4,
                quantity: 1_000_000,
                baseAmount: baseAmount,
                isBuy: true,
                context: bytes32(0)
            })
        );

        // Expected: base fee only = baseAmount * baseBps / BPS_DENOM
        uint256 expected = (baseAmount * baseBps) / BPS_DENOM;
        assertEq(fee, expected);
    }

    function test_rampsWithinWindow() public {
        uint256 baseBps = 30;
        uint256 thetaMaxBps = 3000;
        uint32 window = uint32(ONE_HOUR);
        uint8 beta = 2;
        uint256 baseAmount = 2_500_000;

        ThetaTimeFeePolicy fp = new ThetaTimeFeePolicy(address(sys.core), baseBps, thetaMaxBps, window, beta);

        // Warp to midpoint of window (tau = window/2)
        uint64 targetNow = endTimestamp - window / 2;
        vm.warp(targetNow);

        uint256 fee = fp.quoteFee(
            IFeePolicy.QuoteParams({
                trader: address(0),
                marketId: 1,
                lowerTick: 0,
                upperTick: 4,
                quantity: 1_000_000,
                baseAmount: baseAmount,
                isBuy: true,
                context: bytes32(0)
            })
        );

        // Compute expected theta fee
        uint256 tau = endTimestamp - targetNow;
        uint256 xWad = ((window - tau) * WAD) / window;
        uint256 xPow = _powWad(xWad, beta);
        uint256 thetaBps = (thetaMaxBps * xPow) / WAD;
        uint256 totalBps = baseBps + thetaBps;
        uint256 expected = (baseAmount * totalBps) / BPS_DENOM;

        assertEq(fee, expected);
    }

    function test_maxThetaAtTauZero() public {
        uint256 baseBps = 30;
        uint256 thetaMaxBps = 3000;
        uint32 window = uint32(ONE_HOUR);
        uint8 beta = 4;
        uint256 baseAmount = 5_000_000;

        ThetaTimeFeePolicy fp = new ThetaTimeFeePolicy(address(sys.core), baseBps, thetaMaxBps, window, beta);

        // Warp to exactly endTimestamp (tau = 0)
        vm.warp(endTimestamp);

        uint256 fee = fp.quoteFee(
            IFeePolicy.QuoteParams({
                trader: address(0),
                marketId: 1,
                lowerTick: 0,
                upperTick: 4,
                quantity: 1_000_000,
                baseAmount: baseAmount,
                isBuy: true,
                context: bytes32(0)
            })
        );

        // At tau=0: xWad = 1 WAD, xPow = 1 WAD, thetaBps = thetaMaxBps
        uint256 totalBps = baseBps + thetaMaxBps;
        uint256 expected = (baseAmount * totalBps) / BPS_DENOM;
        assertEq(fee, expected);
    }

    // ============================================================
    // Edge cases
    // ============================================================

    function test_zeroBaseAmount() public {
        ThetaTimeFeePolicy fp = new ThetaTimeFeePolicy(address(sys.core), 10, 100, uint32(ONE_HOUR), 1);

        uint256 fee = fp.quoteFee(
            IFeePolicy.QuoteParams({
                trader: address(0),
                marketId: 1,
                lowerTick: 0,
                upperTick: 4,
                quantity: 1_000_000,
                baseAmount: 0,
                isBuy: true,
                context: bytes32(0)
            })
        );

        assertEq(fee, 0);
    }

    function test_rejectsInvalidConstructorParams() public {
        // core=0
        vm.expectRevert("core=0");
        new ThetaTimeFeePolicy(address(0), 10, 100, uint32(ONE_HOUR), 1);

        // window=0
        vm.expectRevert("window=0");
        new ThetaTimeFeePolicy(address(sys.core), 10, 100, 0, 1);

        // beta<1
        vm.expectRevert("beta<1");
        new ThetaTimeFeePolicy(address(sys.core), 10, 100, uint32(ONE_HOUR), 0);

        // rate>100%
        vm.expectRevert("rate>100%");
        new ThetaTimeFeePolicy(address(sys.core), 9000, 2000, uint32(ONE_HOUR), 1);
    }

    function test_descriptorEncodesParams() public {
        ThetaTimeFeePolicy fp = new ThetaTimeFeePolicy(address(sys.core), 30, 3000, uint32(ONE_HOUR), 4);

        string memory raw = fp.descriptor();
        // Just verify it contains expected substrings
        assertTrue(bytes(raw).length > 0);
        // The descriptor is a JSON string — verify key fields exist
        assertTrue(_contains(raw, '"theta-time"'));
        assertTrue(_contains(raw, '"30"'));
        assertTrue(_contains(raw, '"3000"'));
        assertTrue(_contains(raw, '"4"'));
    }

    // ============================================================
    // Internal helpers
    // ============================================================

    function _powWad(uint256 xWad, uint256 exponent) private pure returns (uint256 result) {
        result = WAD;
        uint256 base = xWad;
        uint256 e = exponent;
        while (e > 0) {
            if (e & 1 == 1) {
                result = (result * base) / WAD;
            }
            e >>= 1;
            if (e > 0) {
                base = (base * base) / WAD;
            }
        }
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
