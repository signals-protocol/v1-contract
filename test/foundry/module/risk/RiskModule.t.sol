// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {RiskModule} from "../../../../contracts/modules/RiskModule.sol";

/// @title RiskModule Tests
/// @notice Foundry conversion of test/module/risk/riskModule.spec.ts
/// @dev Tests risk calculations (pure functions on RiskModule) and config validation (via SignalsCore)
contract RiskModuleTest is FullSystemDeployer {
    FullSystem sys;

    RiskModule riskModule;

    uint256 constant LAMBDA = 0.3e18; // 30% NAV loss floor
    uint256 constant K_DD = 1e18; // Drawdown sensitivity factor

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();
        riskModule = sys.riskModule;

        // Seed vault for risk config tests that require vault state
        sys.payment.mint(sys.owner, _usdc(100_000));
        vm.startPrank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        sys.core.seedVault(_usdc(10_000));
        sys.core.fundBackstop(_usdc(2000));
        sys.core.fundTreasury(_usdc(500));
        vm.stopPrank();
    }

    function _usdc(uint256 amount) internal pure returns (uint256) {
        return amount * 1e6;
    }

    function _wad(uint256 amount) internal pure returns (uint256) {
        return amount * 1e18;
    }

    // ============================================================
    // lnWadUp Safety: Conservative (PRBMath + 1 wei) ln calculation
    // ============================================================

    function test_lnWadUp_returnsLn2Plus1WeiForN2() public view {
        uint256 lnN = riskModule.lnWad(2);
        // PRBMath ln(2) ~ 0.693147... WAD, +1 wei for safety
        uint256 expectedLn2 = 693147180559945309;
        assertEq(lnN, expectedLn2 + 1);
    }

    function test_lnWadUp_returnsLn100Plus1WeiForN100() public view {
        uint256 lnN = riskModule.lnWad(100);
        // PRBMath ln(100*WAD) = 4605170185988091359, +1 wei for safety
        uint256 expectedLn100 = 4605170185988091359;
        assertEq(lnN, expectedLn100 + 1);
    }

    function test_lnWadUp_ln75LessThanLn100() public view {
        uint256 ln75 = riskModule.lnWad(75);
        uint256 ln100 = riskModule.lnWad(100);
        assertLt(ln75, ln100);
    }

    function test_lnWadUp_plus1WeiEnsuresConservativeAlphaBase() public view {
        uint256 Et = _wad(10_000);
        uint256 numBins = 75;

        uint256 alphaBase = riskModule.calculateAlphaBase(Et, numBins, LAMBDA);
        uint256 lnUsed = riskModule.lnWad(numBins);
        uint256 expectedAlphaBase = (LAMBDA * Et) / lnUsed;

        assertEq(alphaBase, expectedAlphaBase);

        // alphaBase is conservative due to +1 wei in denominator
        uint256 exactLn75 = 4.317488e18; // Approximate
        uint256 alphaBaseExact = (LAMBDA * Et) / exactLn75;
        assertLt(alphaBase, alphaBaseExact);
    }

    function test_lnWadUp_handlesLargeNumBinsSafely() public view {
        uint256 lnLarge = riskModule.lnWad(50000);
        assertGt(lnLarge, 0);
    }

    function test_lnWadUp_returnsZeroForN1() public view {
        uint256 ln1 = riskModule.lnWad(1);
        assertEq(ln1, 0);
    }

    function test_lnWadUp_returnsZeroForN0() public view {
        uint256 ln0 = riskModule.lnWad(0);
        assertEq(ln0, 0);
    }

    // ============================================================
    // Edge Cases: numBins boundary conditions
    // ============================================================

    function test_numBins_1RevertsWithInvalidNumBins() public {
        uint256 Et = _wad(10_000);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidNumBins.selector, 1));
        riskModule.calculateAlphaBase(Et, 1, LAMBDA);
    }

    function test_numBins_2ProvidesValidAlphaBase() public view {
        uint256 Et = _wad(10_000);
        uint256 alphaBase = riskModule.calculateAlphaBase(Et, 2, LAMBDA);

        // ln(2) ~ 0.693 WAD, alphaBase = 0.3 * 10000 / 0.693 ~ 4329
        assertGt(alphaBase, 0);
        assertLt(alphaBase, _wad(5000));
    }

    function test_numBins_256ProvidesValidAlphaBase() public view {
        uint256 Et = _wad(10_000);
        uint256 alphaBase = riskModule.calculateAlphaBase(Et, 256, LAMBDA);

        // ln(256) ~ 5.545 WAD, alphaBase ~ 541
        assertGt(alphaBase, _wad(400));
        assertLt(alphaBase, _wad(700));
    }

    function test_numBins_etZeroCausesAlphaBaseZero() public view {
        uint256 alphaBase = riskModule.calculateAlphaBase(0, 100, LAMBDA);
        assertEq(alphaBase, 0);
    }

    // ============================================================
    // DeltaEt (Tail Budget) Calculation
    // ============================================================

    function test_deltaEt_returnsZeroForUniformPrior() public view {
        uint256 deltaEt = riskModule.calculateDeltaEt(_wad(1000), 100, 0);
        assertEq(deltaEt, 0);
    }

    function test_deltaEt_returnsPositiveForConcentratedPrior() public view {
        uint256 deltaEt = riskModule.calculateDeltaEt(_wad(1000), 100, 0.5e18);
        assertGt(deltaEt, 0);
    }

    function test_deltaEt_scalesWithPriorConcentration() public view {
        uint256 deltaEt1 = riskModule.calculateDeltaEt(_wad(1000), 100, 0.1e18);
        uint256 deltaEt2 = riskModule.calculateDeltaEt(_wad(1000), 100, 0.5e18);

        // More concentrated prior -> higher tail risk -> higher deltaEt
        assertGt(deltaEt2, deltaEt1);
    }

    // ============================================================
    // Alpha Safety Bounds (alphaBase / alphaLimit)
    // ============================================================

    function test_alphaBase_calculatesCorrectly() public view {
        uint256 Et = _wad(10_000);

        uint256 alphaBase = riskModule.calculateAlphaBase(Et, 100, LAMBDA);

        // alphaBase = lambda * Et / ln(n) = 0.3 * 10000 / ln(100) ~ 651.5
        uint256 lnN = riskModule.lnWad(100);
        uint256 expectedAlphaBase = (LAMBDA * Et) / lnN;

        assertApproxEqAbs(alphaBase, expectedAlphaBase, WAD);
    }

    function test_alphaLimit_equalsAlphaBaseWhenDrawdownZero() public view {
        uint256 Et = _wad(10_000);

        uint256 alphaBase = riskModule.calculateAlphaBase(Et, 100, LAMBDA);
        uint256 alphaLimit = riskModule.calculateAlphaLimit(alphaBase, 0, K_DD);

        assertEq(alphaLimit, alphaBase);
    }

    function test_alphaLimit_decreasesWithPeakDrawdown() public view {
        uint256 Et = _wad(10_000);
        uint256 drawdown = 0.2e18; // 20% peak drawdown

        uint256 alphaBase = riskModule.calculateAlphaBase(Et, 100, LAMBDA);
        uint256 alphaLimit = riskModule.calculateAlphaLimit(alphaBase, drawdown, K_DD);

        // alphaLimit = alphaBase * (1 - k * DD) = alphaBase * 0.8
        uint256 expectedLimit = (alphaBase * (WAD - drawdown)) / WAD;
        assertEq(alphaLimit, expectedLimit);
    }

    function test_alphaLimit_zeroAt100PercentDrawdown() public view {
        uint256 Et = _wad(10_000);

        uint256 alphaBase = riskModule.calculateAlphaBase(Et, 100, LAMBDA);
        uint256 alphaLimit = riskModule.calculateAlphaLimit(alphaBase, WAD, K_DD);

        assertEq(alphaLimit, 0);
    }

    function test_alphaLimit_neverGoesNegative() public view {
        uint256 Et = _wad(10_000);
        uint256 drawdown = 1.5e18; // 150% (impossible but edge case)

        uint256 alphaBase = riskModule.calculateAlphaBase(Et, 100, LAMBDA);
        uint256 alphaLimit = riskModule.calculateAlphaLimit(alphaBase, drawdown, K_DD);

        assertEq(alphaLimit, 0); // max(0, negative) = 0
    }

    // ============================================================
    // Prior Admissibility
    // ============================================================

    function test_priorAdmissibility_acceptsWhenDeltaEtLeqBeff() public view {
        // Should not revert
        riskModule.checkPriorAdmissibility(_wad(100), _wad(200));
    }

    function test_priorAdmissibility_revertsWhenDeltaEtExceedsBeff() public {
        vm.expectRevert(abi.encodeWithSelector(SE.PriorNotAdmissible.selector, _wad(300), _wad(200)));
        riskModule.checkPriorAdmissibility(_wad(300), _wad(200));
    }

    // ============================================================
    // Alpha Enforcement Scenarios (Calculation)
    // ============================================================

    function test_alphaEnforcement_reducesLimitProportionallyToDrawdown() public view {
        uint256 alphaBase = _wad(1000);

        uint256 limit0 = riskModule.calculateAlphaLimit(alphaBase, 0, K_DD);
        uint256 limit10 = riskModule.calculateAlphaLimit(alphaBase, 0.1e18, K_DD);
        uint256 limit50 = riskModule.calculateAlphaLimit(alphaBase, 0.5e18, K_DD);

        assertEq(limit0, alphaBase);
        assertEq(limit10, (alphaBase * 9) / 10);
        assertEq(limit50, (alphaBase * 5) / 10);
    }

    function test_alphaEnforcement_limitIncreasesAsDrawdownRecovers() public view {
        uint256 alphaBase = _wad(1000);

        uint256 limitDrawdown = riskModule.calculateAlphaLimit(alphaBase, 0.5e18, K_DD);
        uint256 limitRecovered = riskModule.calculateAlphaLimit(alphaBase, 0.2e18, K_DD);

        assertGt(limitRecovered, limitDrawdown);
    }

    function test_alphaEnforcement_extremeDrawdownPreventsMarketCreation() public view {
        uint256 alphaBase = _wad(1000);

        uint256 alphaLimit = riskModule.calculateAlphaLimit(alphaBase, WAD, K_DD);

        assertEq(alphaLimit, 0);
        // Any alpha > 0 will exceed limit -> market creation should fail
    }

    // ============================================================
    // Config Validation: setRiskConfig
    // ============================================================

    function test_riskConfig_revertsWhenLambdaZero() public {
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidLambda.selector, 0));
        sys.core.setRiskConfig(0, K_DD, false);
    }

    function test_riskConfig_revertsWhenLambdaEqualsWad() public {
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidLambda.selector, WAD));
        sys.core.setRiskConfig(WAD, K_DD, false);
    }

    function test_riskConfig_revertsWhenLambdaGreaterThanWad() public {
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidLambda.selector, WAD + 1));
        sys.core.setRiskConfig(WAD + 1, K_DD, false);
    }

    function test_riskConfig_acceptsLambdaJustBelowWad() public {
        vm.prank(sys.owner);
        sys.core.setRiskConfig(WAD - 1, K_DD, false);
        // No revert = success
    }

    function test_riskConfig_acceptsLambdaOneWei() public {
        vm.prank(sys.owner);
        sys.core.setRiskConfig(1, K_DD, false);
        // No revert = success
    }

    function test_riskConfig_acceptsTypicalLambda() public {
        vm.prank(sys.owner);
        sys.core.setRiskConfig(0.3e18, K_DD, true);
        // No revert = success
    }

    // ============================================================
    // Config Validation: setFeeWaterfallConfig
    // ============================================================

    function test_feeWaterfallConfig_revertsWhenPhiSumGreaterThanWad() public {
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidFeeSplitSum.selector, 0.5e18, 0.3e18, 0.3e18));
        sys.core.setFeeWaterfallConfig(0, 0.5e18, 0.3e18, 0.3e18);
    }

    function test_feeWaterfallConfig_revertsWhenPhiSumLessThanWad() public {
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidFeeSplitSum.selector, 0.3e18, 0.3e18, 0.3e18));
        sys.core.setFeeWaterfallConfig(0, 0.3e18, 0.3e18, 0.3e18);
    }

    function test_feeWaterfallConfig_acceptsPhiSumEqualsWad() public {
        vm.prank(sys.owner);
        sys.core.setFeeWaterfallConfig(0, 0.8e18, 0.1e18, 0.1e18);
        // No revert = success
    }

    function test_feeWaterfallConfig_acceptsAllToLP() public {
        vm.prank(sys.owner);
        sys.core.setFeeWaterfallConfig(0, WAD, 0, 0);
        // No revert = success
    }
}
