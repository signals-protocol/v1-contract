// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/SignalsBaseTest.sol";
import "../../../../contracts/modules/RiskModule.sol";

/// @notice Tests RiskMath through RiskModule public functions (library functions are internal)
contract RiskMathTest is SignalsBaseTest {
    RiskModule riskModule;

    function setUp() public override {
        super.setUp();
        riskModule = new RiskModule();
    }

    // ============================================================
    // calculateAlphaBase
    // ============================================================

    function test_calculateAlphaBase_correctFormula() public view {
        // E_t = 1000 WAD, λ = 0.3, n = 10
        // αbase = 0.3 * 1000 / ln(10) ≈ 130.28
        uint256 Et = 1000e18;
        uint256 lambda = 0.3e18;
        uint32 numBins = 10;

        uint256 alphaBase = riskModule.calculateAlphaBase(Et, numBins, lambda);

        assertGt(alphaBase, 130e18);
        assertLt(alphaBase, 131e18);
    }

    function test_calculateAlphaBase_revertsWithNumBinsLe1() public {
        vm.expectRevert();
        riskModule.calculateAlphaBase(1000e18, 1, 0.3e18);
    }

    // ============================================================
    // calculateAlphaLimit
    // ============================================================

    function test_calculateAlphaLimit_zeroDrawdown() public view {
        uint256 alphaBase = 100e18;
        uint256 alphaLimit = riskModule.calculateAlphaLimit(alphaBase, 0, WAD);
        assertEq(alphaLimit, alphaBase);
    }

    function test_calculateAlphaLimit_20pctDrawdown() public view {
        // αlimit = 100 * (1 - 1 * 0.2) = 80
        uint256 alphaLimit = riskModule.calculateAlphaLimit(100e18, 0.2e18, WAD);
        assertEq(alphaLimit, 80e18);
    }

    function test_calculateAlphaLimit_100pctDrawdown() public view {
        uint256 alphaLimit = riskModule.calculateAlphaLimit(100e18, WAD, WAD);
        assertEq(alphaLimit, 0);
    }

    function test_calculateAlphaLimit_kGt1() public view {
        // k = 2, DD = 0.5 → k * DD = 1 → αlimit = 0
        uint256 alphaLimit = riskModule.calculateAlphaLimit(100e18, 0.5e18, 2e18);
        assertEq(alphaLimit, 0);
    }

    // ============================================================
    // calculateDeltaEt
    // ============================================================

    function test_calculateDeltaEt_uniformPrior() public view {
        uint256 deltaEt = riskModule.calculateDeltaEt(100e18, 10, 0);
        assertEq(deltaEt, 0);
    }

    function test_calculateDeltaEt_concentratedPrior() public view {
        uint256 deltaEt = riskModule.calculateDeltaEt(100e18, 10, 0.5e18);
        assertGt(deltaEt, 0);
    }

    // ============================================================
    // lnWad
    // ============================================================

    function test_lnWad_ln2() public view {
        uint256 ln2 = riskModule.lnWad(2);
        assertGt(ln2, 0.693e18);
        assertLt(ln2, 0.694e18);
    }

    function test_lnWad_ln10() public view {
        uint256 ln10 = riskModule.lnWad(10);
        assertGt(ln10, 2.302e18);
        assertLt(ln10, 2.303e18);
    }

    function test_lnWad_ln100() public view {
        uint256 ln100 = riskModule.lnWad(100);
        assertGt(ln100, 4.605e18);
        assertLt(ln100, 4.606e18);
    }
}
