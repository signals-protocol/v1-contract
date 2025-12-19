// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../vault/lib/FeeWaterfallLib.sol";

/// @title FeeWaterfallLibHarness
/// @notice Test harness to expose FeeWaterfallLib internal functions
contract FeeWaterfallLibHarness {
    /// @notice Calculate Fee Waterfall
    function calculate(
        int256 Lt,
        uint256 Ftot,
        uint256 Nprev,
        uint256 Bprev,
        uint256 Tprev,
        uint256 deltaEt,
        int256 pdd,
        uint256 rhoBS,
        uint256 phiLP,
        uint256 phiBS,
        uint256 phiTR
    ) external pure returns (
        uint256 Floss,
        uint256 Fpool,
        uint256 Nraw,
        uint256 Gt,
        uint256 Ffill,
        uint256 Fdust,
        uint256 Ft,
        uint256 Npre,
        uint256 Bnext,
        uint256 Tnext
    ) {
        FeeWaterfallLib.Params memory params = FeeWaterfallLib.Params({
            Lt: Lt,
            Ftot: Ftot,
            Nprev: Nprev,
            Bprev: Bprev,
            Tprev: Tprev,
            deltaEt: deltaEt,
            pdd: pdd,
            rhoBS: rhoBS,
            phiLP: phiLP,
            phiBS: phiBS,
            phiTR: phiTR
        });

        FeeWaterfallLib.Result memory r = FeeWaterfallLib.calculate(params);

        return (
            r.Floss,
            r.Fpool,
            r.Nraw,
            r.Gt,
            r.Ffill,
            r.Fdust,
            r.Ft,
            r.Npre,
            r.Bnext,
            r.Tnext
        );
    }
}


