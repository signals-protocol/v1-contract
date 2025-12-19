// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathU} from "../../lib/FixedPointMathU.sol";
import {SignalsErrors as SE} from "../../errors/SignalsErrors.sol";

/// @notice CLMSR pure math helpers (safe exp).
library SignalsClmsrMath {
    using FixedPointMathU for uint256;

    function _safeExp(uint256 numeratorWad, uint256 alpha) internal pure returns (uint256) {
        if (alpha == 0) revert SE.InvalidLiquidityParameter();
        uint256 inputWad = numeratorWad.wDiv(alpha);
        if (inputWad > FixedPointMathU.MAX_EXP_INPUT_WAD) revert SE.FP_Overflow();
        return inputWad.wExp();
    }
}
