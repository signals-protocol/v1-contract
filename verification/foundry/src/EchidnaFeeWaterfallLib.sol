// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeWaterfallReference} from "contracts/testonly/FeeWaterfallReference.sol";
import {FeeWaterfallLibHarness} from "contracts/testonly/FeeWaterfallLibHarness.sol";

contract EchidnaFeeWaterfallLib {
    uint256 private constant WAD = 1e18;

    struct Input {
        int256 Lt;
        uint256 Ftot;
        uint256 Nprev;
        uint256 Bprev;
        uint256 Tprev;
        uint256 deltaEt;
        int256 pdd;
        uint256 rhoBS;
        uint256 phiLP;
        uint256 phiBS;
        uint256 phiTR;
    }

    struct Output {
        uint256 Floss;
        uint256 Fpool;
        uint256 Nraw;
        uint256 Gt;
        uint256 Ffill;
        uint256 Fdust;
        uint256 Ft;
        uint256 Npre;
        uint256 Bnext;
        uint256 Tnext;
    }

    FeeWaterfallLibHarness private harness;

    Input private lastInput;
    Output private lastResult;
    Output private lastReference;
    bool private unexpectedRevertOccurred;

    constructor() {
        harness = new FeeWaterfallLibHarness();

        Input memory defaults = Input({
            Lt: -int256(3e17),
            Ftot: 10e18,
            Nprev: 100e18,
            Bprev: 50e18,
            Tprev: 0,
            deltaEt: 20e18,
            pdd: -int256(3e17),
            rhoBS: 2e17,
            phiLP: 34e16,
            phiBS: 33e16,
            phiTR: 33e16
        });

        _storeInput(defaults);
        Output memory prod = _runHarness(defaults);
        Output memory refOut = _runReference(defaults);
        _storeOutput(prod, lastResult);
        _storeOutput(refOut, lastReference);
    }

    function doCalculate(
        uint256 rawNprev,
        uint256 rawBprev,
        uint256 rawTprev,
        uint256 rawFtot,
        uint256 rawDeltaEt,
        uint256 rawLt,
        bool ltNegative,
        uint256 rawPdd,
        uint256 rawRhoBS,
        uint256 rawPhiLP,
        uint256 rawPhiBS
    ) external {
        Input memory params = _boundValidParams(
            rawNprev,
            rawBprev,
            rawTprev,
            rawFtot,
            rawDeltaEt,
            rawLt,
            ltNegative,
            rawPdd,
            rawRhoBS,
            rawPhiLP,
            rawPhiBS
        );

        try this.executeCalculate(params) returns (Output memory prod, Output memory refOut) {
            _storeInput(params);
            _storeOutput(prod, lastResult);
            _storeOutput(refOut, lastReference);
        } catch {
            unexpectedRevertOccurred = true;
        }
    }

    function executeCalculate(Input memory params) external view returns (Output memory prod, Output memory refOut) {
        prod = _runHarness(params);
        refOut = _runReference(params);
    }

    function echidna_fee_split_conservation() external view returns (bool) {
        return lastResult.Floss + lastResult.Fpool == lastInput.Ftot;
    }

    function echidna_nav_equation() external view returns (bool) {
        int256 navDelta = int256(lastResult.Npre) - int256(lastInput.Nprev);
        int256 expected = lastInput.Lt + int256(lastResult.Ft) + int256(lastResult.Gt);
        return navDelta == expected;
    }

    function echidna_loss_comp_bound() external view returns (bool) {
        if (lastInput.Lt >= 0) {
            return lastResult.Floss == 0;
        }

        uint256 absLt = uint256(-lastInput.Lt);
        uint256 cap = absLt < lastInput.Ftot ? absLt : lastInput.Ftot;
        return lastResult.Floss == cap;
    }

    function echidna_grant_bound() external view returns (bool) {
        return lastResult.Gt <= lastInput.deltaEt && lastResult.Gt <= lastInput.Bprev;
    }

    function echidna_treasury_non_decreasing() external view returns (bool) {
        return lastResult.Tnext >= lastInput.Tprev;
    }

    function echidna_reference_parity() external view returns (bool) {
        return
            lastResult.Floss == lastReference.Floss &&
            lastResult.Fpool == lastReference.Fpool &&
            lastResult.Nraw == lastReference.Nraw &&
            lastResult.Gt == lastReference.Gt &&
            lastResult.Ffill == lastReference.Ffill &&
            lastResult.Fdust == lastReference.Fdust &&
            lastResult.Ft == lastReference.Ft &&
            lastResult.Npre == lastReference.Npre &&
            lastResult.Bnext == lastReference.Bnext &&
            lastResult.Tnext == lastReference.Tnext;
    }

    function echidna_no_revert() external view returns (bool) {
        return !unexpectedRevertOccurred;
    }

    function _runHarness(Input memory params) private view returns (Output memory out) {
        (out.Floss, out.Fpool, out.Nraw, out.Gt, out.Ffill, out.Fdust, out.Ft, out.Npre, out.Bnext, out.Tnext) = harness
            .calculate(
                params.Lt,
                params.Ftot,
                params.Nprev,
                params.Bprev,
                params.Tprev,
                params.deltaEt,
                params.pdd,
                params.rhoBS,
                params.phiLP,
                params.phiBS,
                params.phiTR
            );
    }

    function _runReference(Input memory params) private pure returns (Output memory out) {
        FeeWaterfallReference.Params memory refParams = FeeWaterfallReference.Params({
            Lt: params.Lt,
            Ftot: params.Ftot,
            Nprev: params.Nprev,
            Bprev: params.Bprev,
            Tprev: params.Tprev,
            deltaEt: params.deltaEt,
            pdd: params.pdd,
            rhoBS: params.rhoBS,
            phiLP: params.phiLP,
            phiBS: params.phiBS,
            phiTR: params.phiTR
        });

        FeeWaterfallReference.Result memory refResult = FeeWaterfallReference.calculate(refParams);
        out = Output({
            Floss: refResult.Floss,
            Fpool: refResult.Fpool,
            Nraw: refResult.Nraw,
            Gt: refResult.Gt,
            Ffill: refResult.Ffill,
            Fdust: refResult.Fdust,
            Ft: refResult.Ft,
            Npre: refResult.Npre,
            Bnext: refResult.Bnext,
            Tnext: refResult.Tnext
        });
    }

    function _storeInput(Input memory params) private {
        lastInput.Lt = params.Lt;
        lastInput.Ftot = params.Ftot;
        lastInput.Nprev = params.Nprev;
        lastInput.Bprev = params.Bprev;
        lastInput.Tprev = params.Tprev;
        lastInput.deltaEt = params.deltaEt;
        lastInput.pdd = params.pdd;
        lastInput.rhoBS = params.rhoBS;
        lastInput.phiLP = params.phiLP;
        lastInput.phiBS = params.phiBS;
        lastInput.phiTR = params.phiTR;
    }

    function _storeOutput(Output memory from, Output storage to) private {
        to.Floss = from.Floss;
        to.Fpool = from.Fpool;
        to.Nraw = from.Nraw;
        to.Gt = from.Gt;
        to.Ffill = from.Ffill;
        to.Fdust = from.Fdust;
        to.Ft = from.Ft;
        to.Npre = from.Npre;
        to.Bnext = from.Bnext;
        to.Tnext = from.Tnext;
    }

    function _boundValidParams(
        uint256 rawNprev,
        uint256 rawBprev,
        uint256 rawTprev,
        uint256 rawFtot,
        uint256 rawDeltaEt,
        uint256 rawLt,
        bool ltNegative,
        uint256 rawPdd,
        uint256 rawRhoBS,
        uint256 rawPhiLP,
        uint256 rawPhiBS
    ) private pure returns (Input memory params) {
        params.Nprev = _bound(rawNprev, 1e18, 1_000_000e18);
        params.Bprev = _bound(rawBprev, 1e18, 500_000e18);
        params.Tprev = _bound(rawTprev, 0, 100_000e18);
        params.Ftot = _bound(rawFtot, 0, 100_000e18);
        params.deltaEt = _bound(rawDeltaEt, 0, 100_000e18);
        params.pdd = -int256(_bound(rawPdd, 0.01e18, WAD));
        params.rhoBS = _bound(rawRhoBS, 0, 0.5e18);
        params.phiLP = _bound(rawPhiLP, 0.01e18, 0.98e18);
        params.phiBS = _bound(rawPhiBS, 0.01e18, WAD - params.phiLP - 0.01e18);
        params.phiTR = WAD - params.phiLP - params.phiBS;

        if (ltNegative) {
            uint256 maxLoss = params.Nprev + params.Ftot;
            uint256 absLt = _bound(rawLt, 0, maxLoss);
            params.Lt = -int256(absLt);
        } else {
            params.Lt = int256(_bound(rawLt, 0, params.Nprev));
        }

        if (params.Lt < 0) {
            uint256 loss = uint256(-params.Lt);
            uint256 floss = loss < params.Ftot ? loss : params.Ftot;
            uint256 nraw = params.Nprev + floss - loss;

            int256 wadPlusPdd = int256(WAD) + params.pdd;
            uint256 nfloor = wadPlusPdd > 0 ? _wMulUp(params.Nprev, uint256(wadPlusPdd)) : 0;
            uint256 grantNeed = nfloor > nraw ? nfloor - nraw : 0;

            if (grantNeed > params.deltaEt) {
                params.deltaEt = grantNeed;
            }
            if (grantNeed > params.Bprev) {
                params.Bprev = grantNeed;
            }
        }
    }

    function _bound(uint256 x, uint256 min, uint256 max) private pure returns (uint256) {
        if (min == max) return min;
        if (min == 0 && max == type(uint256).max) return x;

        uint256 span = max - min;
        return min + (x % (span + 1));
    }

    function _wMulUp(uint256 a, uint256 b) private pure returns (uint256) {
        uint256 product = a * b;
        if (product == 0) return 0;
        return ((product - 1) / WAD) + 1;
    }
}
