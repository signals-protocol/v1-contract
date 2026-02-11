// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LazyMulTreeTarget.sol";

contract EchidnaLazyMulTree {
    uint256 internal constant DRIFT_TOLERANCE_WAD_WEI = 1e12;
    uint256 internal constant REL_DRIFT_DENOM = 1e12; // 1e-12 relative drift tolerance.

    LazyMulTreeTarget internal target;

    constructor() {
        target = new LazyMulTreeTarget(64);
    }

    function step(uint32 lo, uint32 hi, uint256 factor) external {
        target.applyBounded(lo, hi, factor);
    }

    function echidna_total_sum_non_zero() external view returns (bool) {
        return target.totalSum() > 0;
    }

    function echidna_total_vs_leaf_drift_bounded() external view returns (bool) {
        uint256 total = target.totalSum();
        uint256 maxAllowedDrift = DRIFT_TOLERANCE_WAD_WEI + (total / REL_DRIFT_DENOM);
        return target.driftTotalVsLeaf() <= maxAllowedDrift;
    }

    function echidna_total_vs_fullrange_drift_bounded() external view returns (bool) {
        uint256 total = target.totalSum();
        uint256 maxAllowedDrift = DRIFT_TOLERANCE_WAD_WEI + (total / REL_DRIFT_DENOM);
        return target.driftTotalVsFullRange() <= maxAllowedDrift;
    }
}
