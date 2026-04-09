// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignalsErrors as SE} from "contracts/errors/SignalsErrors.sol";
import {FixedPointMathHarness} from "contracts/testonly/FixedPointMathHarness.sol";

contract EchidnaFixedPointMath {
    uint256 private constant WAD = 1e18;
    uint256 private constant SCALE_DIFF = 1e12;
    uint256 private constant MAX_EXP_INPUT_WAD = 133_084258667509499440;
    uint256 private constant ROUNDTRIP_TOLERANCE = WAD / 100_000;

    FixedPointMathHarness private harness;

    uint256 private maxLnExpX;

    uint256 private storedMulX;
    uint256 private storedMulY;

    uint256 private storedDivX;
    uint256 private storedDivY;

    uint256 private storedExpLnX;
    uint256 private storedLnExpX;

    uint256 private storedExpMonoA;
    uint256 private storedExpMonoB;

    uint256 private storedLnMonoA;
    uint256 private storedLnMonoB;

    uint256 private storedLnWadUpA;
    uint256 private storedLnWadUpB;
    uint256 private storedLnWadUpSingleN;

    uint256 private storedConversionInput6;
    uint256 private storedConversionInputWad;

    bool private expRevertObserved;
    bytes4 private expRevertSelector;

    bool private lnRevertObserved;
    bytes4 private lnRevertSelector;

    bool private toWadRevertObserved;
    bytes4 private toWadRevertSelector;

    bool private divRevertObserved;
    bytes4 private divRevertSelector;

    constructor() {
        harness = new FixedPointMathHarness();
        maxLnExpX = harness.wExp(MAX_EXP_INPUT_WAD);

        storedMulX = WAD;
        storedMulY = WAD;
        storedDivX = WAD;
        storedDivY = WAD;
        storedExpLnX = WAD;
        storedLnExpX = WAD;
        storedExpMonoA = 0;
        storedExpMonoB = WAD;
        storedLnMonoA = WAD;
        storedLnMonoB = WAD;
        storedLnWadUpA = 2;
        storedLnWadUpB = 2;
        storedLnWadUpSingleN = 1;
        storedConversionInput6 = 1;
        storedConversionInputWad = WAD;

        expRevertObserved = true;
        expRevertSelector = SE.FP_Overflow.selector;
        lnRevertObserved = true;
        lnRevertSelector = SE.FP_InvalidInput.selector;
        toWadRevertObserved = true;
        toWadRevertSelector = SE.FP_Overflow.selector;
        divRevertObserved = true;
        divRevertSelector = SE.FP_DivisionByZero.selector;
    }

    function setMulInputs(uint256 rawX, uint256 rawY) external {
        storedMulX = _bound(rawX, 0, type(uint128).max);
        storedMulY = _bound(rawY, 0, type(uint128).max);
    }

    function setDivInputs(uint256 rawX, uint256 rawY) external {
        storedDivX = _bound(rawX, 0, type(uint256).max / WAD);
        storedDivY = _bound(rawY, 1, type(uint256).max);
    }

    function setExpLnInput(uint256 rawX) external {
        storedExpLnX = _bound(rawX, WAD, MAX_EXP_INPUT_WAD);
    }

    function setLnExpInput(uint256 rawX) external {
        storedLnExpX = _bound(rawX, WAD, maxLnExpX);
    }

    function setExpMonoPair(uint256 rawA, uint256 rawB) external {
        storedExpMonoA = _bound(rawA, 0, MAX_EXP_INPUT_WAD);
        storedExpMonoB = _bound(rawB, 0, MAX_EXP_INPUT_WAD);
        if (storedExpMonoA > storedExpMonoB) {
            (storedExpMonoA, storedExpMonoB) = (storedExpMonoB, storedExpMonoA);
        }
    }

    function setLnMonoPair(uint256 rawA, uint256 rawB) external {
        storedLnMonoA = _bound(rawA, WAD, type(uint256).max);
        storedLnMonoB = _bound(rawB, WAD, type(uint256).max);
        if (storedLnMonoA > storedLnMonoB) {
            (storedLnMonoA, storedLnMonoB) = (storedLnMonoB, storedLnMonoA);
        }
    }

    function setLnWadUpPair(uint256 rawA, uint256 rawB) external {
        uint256 maxInput = type(uint256).max / WAD;
        storedLnWadUpA = _bound(rawA, 2, maxInput);
        storedLnWadUpB = _bound(rawB, 2, maxInput);
        if (storedLnWadUpA > storedLnWadUpB) {
            (storedLnWadUpA, storedLnWadUpB) = (storedLnWadUpB, storedLnWadUpA);
        }
    }

    function setLnWadUpSingle(uint256 rawN) external {
        storedLnWadUpSingleN = _bound(rawN, 0, type(uint256).max / WAD);
    }

    function setConversionInput6(uint256 rawX6) external {
        storedConversionInput6 = _bound(rawX6, 0, type(uint256).max / SCALE_DIFF);
    }

    function setConversionInputWad(uint256 rawXWad) external {
        storedConversionInputWad = rawXWad;
    }

    function setExpRevertInput(uint256 rawX) external {
        uint256 x = _bound(rawX, MAX_EXP_INPUT_WAD + 1, type(uint256).max);
        try this.executeExp(x) returns (uint256) {
            expRevertObserved = false;
            expRevertSelector = bytes4(0);
        } catch (bytes memory err) {
            expRevertObserved = true;
            expRevertSelector = _selector(err);
        }
    }

    function setLnRevertInput(uint256 rawX) external {
        uint256 x = _bound(rawX, 0, WAD - 1);
        try this.executeLn(x) returns (uint256) {
            lnRevertObserved = false;
            lnRevertSelector = bytes4(0);
        } catch (bytes memory err) {
            lnRevertObserved = true;
            lnRevertSelector = _selector(err);
        }
    }

    function setToWadRevertInput(uint256 rawX) external {
        uint256 x = _bound(rawX, (type(uint256).max / SCALE_DIFF) + 1, type(uint256).max);
        try this.executeToWad(x) returns (uint256) {
            toWadRevertObserved = false;
            toWadRevertSelector = bytes4(0);
        } catch (bytes memory err) {
            toWadRevertObserved = true;
            toWadRevertSelector = _selector(err);
        }
    }

    function setDivRevertInput(uint256 rawX) external {
        try this.executeDivByZero(rawX) returns (uint256) {
            divRevertObserved = false;
            divRevertSelector = bytes4(0);
        } catch (bytes memory err) {
            divRevertObserved = true;
            divRevertSelector = _selector(err);
        }
    }

    function executeExp(uint256 x) external view returns (uint256) {
        return harness.wExp(x);
    }

    function executeLn(uint256 x) external view returns (uint256) {
        return harness.wLn(x);
    }

    function executeToWad(uint256 x) external view returns (uint256) {
        return harness.toWad(x);
    }

    function executeDivByZero(uint256 x) external view returns (uint256) {
        return harness.wDiv(x, 0);
    }

    function echidna_mul_rounding_order() external view returns (bool) {
        uint256 floorValue = harness.wMul(storedMulX, storedMulY);
        uint256 nearestValue = harness.wMulNearest(storedMulX, storedMulY);
        uint256 ceilValue = harness.wMulUp(storedMulX, storedMulY);
        return floorValue <= nearestValue && nearestValue <= ceilValue;
    }

    function echidna_mul_identity() external view returns (bool) {
        return harness.wMul(storedMulX, WAD) == storedMulX;
    }

    function echidna_div_rounding_order() external view returns (bool) {
        uint256 floorValue = harness.wDiv(storedDivX, storedDivY);
        uint256 nearestValue = harness.wDivNearest(storedDivX, storedDivY);
        uint256 ceilValue = harness.wDivUp(storedDivX, storedDivY);
        return floorValue <= nearestValue && nearestValue <= ceilValue;
    }

    function echidna_div_identity() external view returns (bool) {
        return harness.wDiv(storedDivX, WAD) == storedDivX;
    }

    function echidna_exp_ln_roundtrip() external view returns (bool) {
        uint256 roundtrip = harness.wLn(harness.wExp(storedExpLnX));
        return _relativeError(roundtrip, storedExpLnX) <= ROUNDTRIP_TOLERANCE;
    }

    function echidna_ln_exp_roundtrip() external view returns (bool) {
        uint256 roundtrip = harness.wExp(harness.wLn(storedLnExpX));
        return _relativeError(roundtrip, storedLnExpX) <= ROUNDTRIP_TOLERANCE;
    }

    function echidna_exp_monotonic() external view returns (bool) {
        return harness.wExp(storedExpMonoA) <= harness.wExp(storedExpMonoB);
    }

    function echidna_ln_monotonic() external view returns (bool) {
        return harness.wLn(storedLnMonoA) <= harness.wLn(storedLnMonoB);
    }

    function echidna_lnWadUp_monotonic() external view returns (bool) {
        return harness.lnWadUp(storedLnWadUpA) <= harness.lnWadUp(storedLnWadUpB);
    }

    function echidna_lnWadUp_boundary() external view returns (bool) {
        uint256 result = harness.lnWadUp(storedLnWadUpSingleN);
        if (storedLnWadUpSingleN <= 1) {
            return result == 0;
        }

        uint256 exact = harness.wLn(storedLnWadUpSingleN * WAD);
        return exact <= result && result <= exact + 1;
    }

    function echidna_toWad_fromWad_roundtrip() external view returns (bool) {
        return harness.fromWad(harness.toWad(storedConversionInput6)) == storedConversionInput6;
    }

    function echidna_fromWad_toWad_lossy() external view returns (bool) {
        uint256 roundtrip = harness.toWad(harness.fromWad(storedConversionInputWad));
        return roundtrip <= storedConversionInputWad && storedConversionInputWad - roundtrip <= SCALE_DIFF - 1;
    }

    function echidna_fromWad_roundUp_bounded() external view returns (bool) {
        uint256 floorValue = harness.fromWad(storedConversionInputWad);
        uint256 ceilValue = harness.fromWadRoundUp(storedConversionInputWad);
        return floorValue <= ceilValue && ceilValue <= floorValue + 1;
    }

    function echidna_fromWad_nearest_bounded() external view returns (bool) {
        uint256 floorValue = harness.fromWad(storedConversionInputWad);
        uint256 nearestValue = harness.fromWadNearest(storedConversionInputWad);
        return floorValue <= nearestValue && nearestValue <= floorValue + 1;
    }

    function echidna_fromWadNearestMin1_positive() external view returns (bool) {
        return storedConversionInputWad == 0 || harness.fromWadNearestMin1(storedConversionInputWad) >= 1;
    }

    function echidna_exp_reverts_above_max() external view returns (bool) {
        return expRevertObserved && expRevertSelector == SE.FP_Overflow.selector;
    }

    function echidna_ln_reverts_below_wad() external view returns (bool) {
        return lnRevertObserved && lnRevertSelector == SE.FP_InvalidInput.selector;
    }

    function echidna_toWad_reverts_on_overflow() external view returns (bool) {
        return toWadRevertObserved && toWadRevertSelector == SE.FP_Overflow.selector;
    }

    function echidna_div_reverts_on_zero() external view returns (bool) {
        return divRevertObserved && divRevertSelector == SE.FP_DivisionByZero.selector;
    }

    function _bound(uint256 x, uint256 min, uint256 max) private pure returns (uint256) {
        if (min == max) return min;
        if (min == 0 && max == type(uint256).max) return x;

        uint256 span = max - min;
        return min + (x % (span + 1));
    }

    function _selector(bytes memory err) private pure returns (bytes4 sel) {
        if (err.length < 4) {
            return bytes4(0);
        }

        assembly ("memory-safe") {
            sel := mload(add(err, 32))
        }
    }

    function _relativeError(uint256 actual, uint256 expected) private pure returns (uint256) {
        return Math.mulDiv(_absDiff(actual, expected), WAD, expected);
    }

    function _absDiff(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
