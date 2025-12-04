// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Lazy segment tree for multiplicative updates and range sums (WAD values).
/// @dev This is a direct port of the v0 LazyMulSegmentTree with minimal surface needed for CLMSR math.
library SignalsLazyMulSegmentTree {
    struct Tree {
        uint256 size;
        mapping(uint256 => uint256) value;
        mapping(uint256 => uint256) lazy;
    }

    uint256 internal constant WAD = 1e18;

    function init(Tree storage t, uint256 nBins, uint256 initial) internal {
        t.size = _ceilPow2(nBins);
        uint256 rootIndex = 1;
        t.value[rootIndex] = initial * t.size;
        t.lazy[rootIndex] = WAD;
    }

    function _ceilPow2(uint256 x) private pure returns (uint256) {
        if (x <= 1) return 1;
        uint256 p = 1;
        while (p < x) p <<= 1;
        return p;
    }

    function _push(Tree storage t, uint256 idx, uint256 l, uint256 r) private {
        uint256 lazyVal = t.lazy[idx];
        if (lazyVal == WAD) return; // identity

        uint256 mid = (l + r) >> 1;
        uint256 left = idx << 1;
        uint256 right = left | 1;

        // propagate to children
        t.value[left] = (t.value[left] * lazyVal) / WAD;
        t.value[right] = (t.value[right] * lazyVal) / WAD;
        t.lazy[left] = (t.lazy[left] * lazyVal) / WAD;
        t.lazy[right] = (t.lazy[right] * lazyVal) / WAD;

        // reset current
        t.lazy[idx] = WAD;
    }

    function applyRangeFactor(
        Tree storage t,
        uint256 ql,
        uint256 qr,
        uint256 factor
    ) internal {
        _applyRangeFactor(t, 1, 0, t.size - 1, ql, qr, factor);
    }

    function _applyRangeFactor(
        Tree storage t,
        uint256 idx,
        uint256 l,
        uint256 r,
        uint256 ql,
        uint256 qr,
        uint256 factor
    ) private {
        if (ql > r || qr < l) return;
        if (ql <= l && r <= qr) {
            t.value[idx] = (t.value[idx] * factor) / WAD;
            t.lazy[idx] = (t.lazy[idx] * factor) / WAD;
            return;
        }
        _push(t, idx, l, r);
        uint256 mid = (l + r) >> 1;
        _applyRangeFactor(t, idx << 1, l, mid, ql, qr, factor);
        _applyRangeFactor(t, (idx << 1) | 1, mid + 1, r, ql, qr, factor);
        t.value[idx] = t.value[idx << 1] + t.value[(idx << 1) | 1];
    }

    function getRangeSum(
        Tree storage t,
        uint256 ql,
        uint256 qr
    ) internal view returns (uint256) {
        return _getRangeSum(t, 1, 0, t.size - 1, ql, qr);
    }

    function _getRangeSum(
        Tree storage t,
        uint256 idx,
        uint256 l,
        uint256 r,
        uint256 ql,
        uint256 qr
    ) private view returns (uint256) {
        if (ql > r || qr < l) return 0;
        if (ql <= l && r <= qr) return t.value[idx];
        uint256 mid = (l + r) >> 1;
        uint256 left = _getRangeSum(t, idx << 1, l, mid, ql, qr);
        uint256 right = _getRangeSum(t, (idx << 1) | 1, mid + 1, r, ql, qr);
        // lazy propagation is not applied in view; assume caller triggers on fresh state.
        return left + right;
    }
}
