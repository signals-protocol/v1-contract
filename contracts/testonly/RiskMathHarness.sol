// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../lib/RiskMath.sol";

/// @notice Harness exposing all RiskMath internal functions as external for fuzz testing.
contract RiskMathHarness {
    function calculateDeltaEtFromFactors(uint256 alpha, uint32 numBins, uint256[] calldata baseFactors)
        external
        pure
        returns (uint256)
    {
        return RiskMath.calculateDeltaEtFromFactors(alpha, numBins, baseFactors);
    }

    function calculateDeltaEt(uint256 alpha, uint32 numBins, uint256 rootSum, uint256 minFactor)
        external
        pure
        returns (uint256)
    {
        return RiskMath.calculateDeltaEt(alpha, numBins, rootSum, minFactor);
    }

    function calculateAlphaBase(uint256 Et, uint256 numBins, uint256 lambda) external pure returns (uint256) {
        return RiskMath.calculateAlphaBase(Et, numBins, lambda);
    }

    function calculateAlphaLimit(uint256 alphaBase, uint256 drawdown, uint256 k) external pure returns (uint256) {
        return RiskMath.calculateAlphaLimit(alphaBase, drawdown, k);
    }

    function calculateDrawdown(uint256 price, uint256 pricePeak) external pure returns (uint256) {
        return RiskMath.calculateDrawdown(price, pricePeak);
    }

    function enforcePriorAdmissibility(uint256 deltaEt, uint256 effectiveBackstop) external pure {
        RiskMath.enforcePriorAdmissibility(deltaEt, effectiveBackstop);
    }

    function enforceAlphaLimit(uint256 alpha, uint256 alphaLimit) external pure {
        RiskMath.enforceAlphaLimit(alpha, alphaLimit);
    }

    function lnWadUp(uint256 n) external pure returns (uint256) {
        return RiskMath.lnWadUp(n);
    }
}
