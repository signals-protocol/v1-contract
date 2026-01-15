// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";

import "../interfaces/IFeePolicy.sol";

/// @dev Minimal interface to read endTimestamp from core.markets(marketId)
interface ICoreMarkets {
    function markets(uint256 marketId)
        external
        view
        returns (
            bool isSeeded,
            bool settled,
            bool snapshotChunksDone,
            bool failed,
            uint32 numBins,
            uint32 openPositionCount,
            uint32 snapshotChunkCursor,
            uint32 seedCursor,
            uint64 startTimestamp,
            uint64 endTimestamp,
            uint64 settlementTimestamp,
            uint64 settlementFinalizedAt,
            int256 minTick,
            int256 maxTick,
            int256 tickSpacing,
            int256 settlementTick,
            int256 settlementValue,
            uint256 liquidityParameter,
            address feePolicy,
            address seedData,
            uint256 initialRootSum,
            uint256 accumulatedFees,
            uint256 minFactor,
            uint256 deltaEt
        );
}

/// @notice Base + Theta(time-to-end) fee policy (symmetric for buy/sell)
contract ThetaTimeFeePolicy is IFeePolicy {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;

    address public immutable core;
    uint256 public immutable baseBps;
    uint256 public immutable thetaMaxBps;
    uint32 public immutable thetaWindowSeconds;
    uint8 public immutable beta;

    uint256 public immutable baseRateWad;
    uint256 public immutable thetaMaxRateWad;

    constructor(
        address core_,
        uint256 baseBps_,
        uint256 thetaMaxBps_,
        uint32 thetaWindowSeconds_,
        uint8 beta_
    ) {
        require(core_ != address(0), "core=0");
        require(thetaWindowSeconds_ > 0, "window=0");
        require(beta_ >= 1, "beta<1");
        require(baseBps_ + thetaMaxBps_ <= BPS, "rate>100%");

        core = core_;
        baseBps = baseBps_;
        thetaMaxBps = thetaMaxBps_;
        thetaWindowSeconds = thetaWindowSeconds_;
        beta = beta_;

        baseRateWad = (baseBps_ * WAD) / BPS;
        thetaMaxRateWad = (thetaMaxBps_ * WAD) / BPS;
    }

    function name() external pure override returns (string memory) {
        return "ThetaTimeFeePolicy";
    }

    function descriptor() external view override returns (string memory) {
        return string(
            abi.encodePacked(
                '{"policy":"theta-time","params":{"baseBps":"',
                Strings.toString(baseBps),
                '","thetaMaxBps":"',
                Strings.toString(thetaMaxBps),
                '","windowSec":"',
                Strings.toString(thetaWindowSeconds),
                '","beta":"',
                Strings.toString(beta),
                '","name":"ThetaTimeFeePolicy"},"name":"ThetaTimeFeePolicy"}'
            )
        );
    }

    function quoteFee(QuoteParams calldata params)
        external
        view
        override
        returns (uint256 feeAmount)
    {
        uint256 baseAmount = params.baseAmount;
        if (baseAmount == 0) return 0;

        (, , , , , , , , , uint64 endTimestamp, , , , , , , , , , , , , , ) =
            ICoreMarkets(core).markets(params.marketId);

        uint256 tau = 0;
        if (endTimestamp > block.timestamp) {
            tau = uint256(endTimestamp) - block.timestamp;
        }

        uint256 thetaRateWad = 0;
        uint256 window = uint256(thetaWindowSeconds);
        if (tau < window) {
            uint256 xWad = ((window - tau) * WAD) / window;
            uint256 xPowWad = _powWad(xWad, beta);
            thetaRateWad = (thetaMaxRateWad * xPowWad) / WAD;
        }

        uint256 totalRateWad = baseRateWad + thetaRateWad;
        feeAmount = (baseAmount * totalRateWad) / WAD;
        if (feeAmount > baseAmount) {
            feeAmount = baseAmount;
        }
    }

    /// @dev Exponentiation by squaring for WAD fixed point.
    function _powWad(uint256 xWad, uint8 exp) internal pure returns (uint256) {
        uint256 result = WAD;
        uint256 base = xWad;
        uint8 e = exp;

        while (e > 0) {
            if (e & 1 == 1) {
                result = (result * base) / WAD;
            }
            e >>= 1;
            if (e > 0) {
                base = (base * base) / WAD;
            }
        }
        return result;
    }
}
