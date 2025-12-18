// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathU} from "../../lib/FixedPointMathU.sol";
import {CE} from "../../errors/CLMSRErrors.sol";

/// @notice CLMSR pure math helpers (safe exp).
library SignalsClmsrMath {
    using FixedPointMathU for uint256;

    function _safeExp(uint256 numeratorWad, uint256 alpha) internal pure returns (uint256) {
        if (alpha == 0) revert CE.MathMulOverflow();
        uint256 inputWad = numeratorWad.wDiv(alpha);
        if (inputWad > FixedPointMathU.MAX_EXP_INPUT_WAD) revert CE.MathMulOverflow();
        return inputWad.wExp();
    }
}
