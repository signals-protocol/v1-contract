// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice SMT-friendly core arithmetic model aligned with FixedPointMathU semantics.
/// @dev This contract intentionally avoids heavy transcendental imports (exp/ln)
///      so the model checker can finish in practical time.
contract FixedPointCoreSMT {
    uint256 private constant WAD = 1e18;
    uint256 private constant SCALE_DIFF = 1e12;

    function _toWad(uint256 x) private pure returns (uint256) {
        if (x > type(uint256).max / SCALE_DIFF) revert();
        return x * SCALE_DIFF;
    }

    function _fromWad(uint256 x) private pure returns (uint256) {
        return x / SCALE_DIFF;
    }

    function _fromWadRoundUp(uint256 x) private pure returns (uint256) {
        if (x == 0) return 0;
        return ((x - 1) / SCALE_DIFF) + 1;
    }

    function _wMul(uint256 x, uint256 y) private pure returns (uint256) {
        if (x != 0 && y > type(uint256).max / x) revert();
        return (x * y) / WAD;
    }

    function _wDiv(uint256 x, uint256 y) private pure returns (uint256) {
        if (y == 0) revert();
        if (x != 0 && WAD > type(uint256).max / x) revert();
        return (x * WAD) / y;
    }

    function prove_toWad_fromWad_roundtrip(uint128 x) external pure {
        uint256 y = _toWad(uint256(x));
        assert(_fromWad(y) == uint256(x));
    }

    function prove_wMul_identity(uint256 x) external pure {
        uint256 y = _wMul(x, WAD);
        assert(y == x);
    }

    function prove_wDiv_identity(uint256 x) external pure {
        uint256 y = _wDiv(x, WAD);
        assert(y == x);
    }

    function prove_round_up_minimum_for_non_zero(uint256 x) external pure {
        if (x == 0) return;
        assert(_fromWadRoundUp(x) >= 1);
    }

    function prove_floor_then_expand_no_increase(uint256 x) external pure {
        uint256 floor6 = _fromWad(x);
        uint256 expanded = floor6 * SCALE_DIFF;
        assert(expanded <= x);
    }
}
