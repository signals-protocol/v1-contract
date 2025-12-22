// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../core/lib/SignalsDistributionMath.sol";

/// @title SignalsDistributionMathHarness
/// @notice Test harness to expose internal library functions
contract SignalsDistributionMathHarness {
    function maxSafeChunkQuantity(uint256 alpha) external pure returns (uint256) {
        return SignalsDistributionMath.maxSafeChunkQuantity(alpha);
    }

    function computeBuyCostFromSumChange(
        uint256 alpha,
        uint256 sumBefore,
        uint256 sumAfter
    ) external pure returns (uint256) {
        return SignalsDistributionMath.computeBuyCostFromSumChange(alpha, sumBefore, sumAfter);
    }

    function computeSellProceedsFromSumChange(
        uint256 alpha,
        uint256 sumBefore,
        uint256 sumAfter
    ) external pure returns (uint256) {
        return SignalsDistributionMath.computeSellProceedsFromSumChange(alpha, sumBefore, sumAfter);
    }
}

