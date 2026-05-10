// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/SeedHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title AlphaEnforcementTest
/// @notice Integration: alpha safety bound enforcement at market creation, trade freedom, drawdown impact.
/// @dev Mirrors test/integration/risk/alphaEnforcement.spec.ts (29 tests).
contract AlphaEnforcementTest is FullSystemDeployer {
    FullSystem sys;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();

        // Transfer tokens from test contract (deployer / minter) to owner
        sys.payment.transfer(sys.owner, 100_000e6);

        // Configure risk: lambda=0.3, kDrawdown=1, enforceAlpha=true
        vm.startPrank(sys.owner);
        sys.core.setRiskConfig(0.3e18, 1e18, true);
        sys.core.setFeeWaterfallConfig(0.2e18, 0.7e18, 0.2e18, 0.1e18);

        // Seed vault
        sys.payment.approve(address(sys.core), type(uint256).max);
        sys.core.seedVault(10_000e6);

        // Fund backstop
        sys.core.fundBackstop(2_000e6);

        // Fund trader
        sys.payment.transfer(sys.users[0], 10_000e6);
        vm.stopPrank();

        vm.prank(sys.users[0]);
        sys.payment.approve(address(sys.core), type(uint256).max);
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _ts() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _setBackstopNav(uint256 targetWad) internal {
        (uint256 current,) = sys.core.getCapitalStack();
        if (current < targetWad) {
            uint256 diff6 = (targetWad - current) / 1e12;
            if (diff6 > 0) {
                // Mint fresh tokens to owner to cover backstop funding
                sys.payment.mint(sys.owner, diff6);
                vm.startPrank(sys.owner);
                sys.payment.approve(address(sys.core), diff6);
                sys.core.fundBackstop(diff6);
                vm.stopPrank();
            }
        } else if (current > targetWad) {
            uint256 diff6 = (current - targetWad) / 1e12;
            if (diff6 > 0) {
                vm.prank(sys.owner);
                sys.core.withdrawBackstop(diff6);
            }
        }
    }

    function _concentratedFactors(uint256 numBins, uint256 hotWeight) internal pure returns (uint256[] memory) {
        uint256[] memory factors = new uint256[](numBins);
        for (uint256 i = 0; i < numBins; i++) {
            factors[i] = (i == 0) ? hotWeight : WAD;
        }
        return factors;
    }

    // ============================================================
    // Market Creation with alpha enforcement
    // ============================================================

    function test_allowsMarketCreation_whenAlphaLeAlphaLimit() public {
        // NAV=10000, lambda=0.3, numBins=100: alpha_base ~651.5, no drawdown -> alpha_limit ~651.5
        vm.prank(sys.owner);
        sys.core
            .createMarketUniform(
                0, 1000, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 100, 500e18, address(sys.feePolicy)
            );
    }

    function test_revertsMarketCreation_whenAlphaGtAlphaLimit() public {
        vm.prank(sys.owner);
        vm.expectPartialRevert(SE.AlphaExceedsLimit.selector);
        sys.core
            .createMarketUniform(
                0, 1000, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 100, 1000e18, address(sys.feePolicy)
            );
    }

    // ============================================================
    // Trading freedom within configured alpha
    // ============================================================

    function test_allowsOpenPositionFreely() public {
        vm.prank(sys.owner);
        sys.core
            .createMarketUniform(
                0, 1000, 10, _ts() + 10, _ts() + 3600, _ts() + 3660, 100, 500e18, address(sys.feePolicy)
            );
        vm.warp(block.timestamp + 15);

        vm.prank(sys.users[0]);
        sys.core.openPosition(1, 100, 200, 100, 1_000e6);
    }

    function test_allowsIncreasePositionFreely() public {
        vm.prank(sys.owner);
        sys.core
            .createMarketUniform(
                0, 1000, 10, _ts() + 10, _ts() + 3600, _ts() + 3660, 100, 500e18, address(sys.feePolicy)
            );
        vm.warp(block.timestamp + 15);

        vm.prank(sys.users[0]);
        sys.core.openPosition(1, 100, 200, 100, 1_000e6);

        vm.prank(sys.users[0]);
        sys.core.increasePosition(1, 50, 500e6);
    }

    function test_allowsClosePositionFreely() public {
        vm.prank(sys.owner);
        sys.core
            .createMarketUniform(
                0, 1000, 10, _ts() + 10, _ts() + 3600, _ts() + 3660, 100, 500e18, address(sys.feePolicy)
            );
        vm.warp(block.timestamp + 15);

        vm.prank(sys.users[0]);
        sys.core.openPosition(1, 100, 200, 100, 1_000e6);

        vm.prank(sys.users[0]);
        sys.core.closePosition(1, 0);
    }

    function test_allowsDecreasePositionFreely() public {
        vm.prank(sys.owner);
        sys.core
            .createMarketUniform(
                0, 1000, 10, _ts() + 10, _ts() + 3600, _ts() + 3660, 100, 500e18, address(sys.feePolicy)
            );
        vm.warp(block.timestamp + 15);

        vm.prank(sys.users[0]);
        sys.core.openPosition(1, 100, 200, 100, 1_000e6);

        vm.prank(sys.users[0]);
        sys.core.decreasePosition(1, 50, 0);
    }

    // ============================================================
    // Peak drawdown impact on alpha limit
    // ============================================================

    function test_reducesAlphaLimitProportionallyToPeakDrawdown() public {
        // Alpha=500 succeeds initially
        vm.prank(sys.owner);
        sys.core
            .createMarketUniform(
                0, 1000, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 100, 500e18, address(sys.feePolicy)
            );

        // Simulate 50% peak drawdown
        vm.prank(sys.owner);
        sys.core.harnessSetLpVault(5_000e18, 10_000e18, 0.5e18, 1e18, true);

        // Same alpha=500 should now fail
        vm.prank(sys.owner);
        vm.expectPartialRevert(SE.AlphaExceedsLimit.selector);
        sys.core
            .createMarketUniform(
                0, 1000, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 100, 500e18, address(sys.feePolicy)
            );
    }

    function test_allowsLowerAlphaWhenPeakDrawdownReducesLimit() public {
        // Simulate 50% peak drawdown with NAV=10000
        vm.prank(sys.owner);
        sys.core.harnessSetLpVault(10_000e18, 10_000e18, 0.5e18, 1e18, true);

        // alpha=300 should succeed (300 < 325.75)
        vm.prank(sys.owner);
        sys.core
            .createMarketUniform(
                0, 1000, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 100, 300e18, address(sys.feePolicy)
            );
    }

    function test_rejectsAllMarketCreationWhenPeakDrawdownReaches100Pct() public {
        // 100% drawdown: price=0, pricePeak=1
        vm.prank(sys.owner);
        sys.core.harnessSetLpVault(10_000e18, 10_000e18, 0, 1e18, true);

        // Even alpha=1 should fail
        vm.prank(sys.owner);
        vm.expectPartialRevert(SE.AlphaExceedsLimit.selector);
        sys.core
            .createMarketUniform(0, 1000, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 100, 1e18, address(sys.feePolicy));
    }

    // ============================================================
    // Alpha enforcement toggle
    // ============================================================

    function test_skipsAlphaCheckWhenEnforceAlphaFalse() public {
        vm.prank(sys.owner);
        sys.core.setRiskConfig(0.3e18, 1e18, false);

        vm.prank(sys.owner);
        sys.core
            .createMarketUniform(
                0, 1000, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 100, 10_000e18, address(sys.feePolicy)
            );
    }

    // ============================================================
    // Edge cases: risk parameter boundaries
    // ============================================================

    function test_revertsMarketCreationWithNumBins1() public {
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidNumBins.selector, uint256(1)));
        sys.core
            .createMarketUniform(0, 10, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 1, 100e18, address(sys.feePolicy));
    }

    function test_allowsMarketCreationWithNumBins2() public {
        vm.prank(sys.owner);
        sys.core
            .createMarketUniform(0, 20, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 2, 100e18, address(sys.feePolicy));
    }

    function test_rejectsSetRiskConfigWhenLambdaZero() public {
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidLambda.selector, uint256(0)));
        sys.core.setRiskConfig(0, 1e18, true);
    }

    function test_ignoresPeakDrawdownWhenKDrawdownZero() public {
        vm.prank(sys.owner);
        sys.core.setRiskConfig(0.3e18, 0, true);

        // Simulate 50% peak drawdown
        vm.prank(sys.owner);
        sys.core.harnessSetLpVault(10_000e18, 10_000e18, 0.5e18, 1e18, true);

        // k=0 means no drawdown penalty, alpha=500 should work
        vm.prank(sys.owner);
        sys.core
            .createMarketUniform(
                0, 1000, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 100, 500e18, address(sys.feePolicy)
            );
    }

    function test_rejectsBaseFactorsWithZeroElement() public {
        uint256[] memory factors = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            factors[i] = WAD;
        }
        factors[5] = 0;
        address seedData = address(SeedHelper.deploySeedData(factors));

        _setBackstopNav(1_000e18);

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidFactor.selector, uint256(0)));
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );
    }

    // ============================================================
    // Prior admissibility (deltaEt <= backstopNav)
    // ============================================================

    function test_allowsMarketWhenDeltaEtLeBackstopNav() public {
        // Concentrated prior: first bin 2x weight
        uint256[] memory factors = _concentratedFactors(10, 2 * WAD);
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(100e18);

        vm.prank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );
    }

    function test_revertsMarketWhenDeltaEtGtBackstopNav() public {
        // Concentrated prior: first bin 10x weight -> large deltaEt
        uint256[] memory factors = _concentratedFactors(10, 10 * WAD);
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(50e18);

        vm.prank(sys.owner);
        vm.expectPartialRevert(SE.PriorNotAdmissible.selector);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );
    }

    function test_boundaryDeltaEtExactlyEqualsBackstopNav() public {
        uint256[] memory factors = _concentratedFactors(10, 2 * WAD);
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(10e18);

        // deltaEt ~= 9.53 < 10
        vm.prank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );
    }

    function test_uniformPriorHasDeltaEtZero() public {
        uint256[] memory factors = uniformFactors(10);
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(0);

        // Uniform: deltaEt=0, always admissible
        vm.prank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );
    }

    // ============================================================
    // DeltaEt storage validation
    // ============================================================

    function test_storesDeltaEtGtZeroForConcentratedPrior() public {
        uint256[] memory factors = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            factors[i] = WAD;
        }
        factors[0] = 2 * WAD;
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(1_000e18);

        vm.prank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );

        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        assertGt(m.deltaEt, 0);
        assertGe(m.deltaEt, 9e18);
        assertLt(m.deltaEt, 15e18);
    }

    function test_storesDeltaEtZeroForUniformPrior() public {
        uint256[] memory factors = uniformFactors(10);
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(1_000e18);

        vm.prank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );

        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        assertEq(m.deltaEt, 0);
    }

    function test_deltaEtScalesProportionallyWithAlpha() public {
        uint256[] memory factors = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            factors[i] = WAD;
        }
        factors[0] = 2 * WAD;
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(10_000e18);

        // Market 1: alpha=100
        vm.prank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );

        // Market 2: alpha=200 (different batch)
        vm.prank(sys.owner);
        sys.core
            .createMarket(
                200,
                300,
                10,
                _ts() + 86400 + 60,
                _ts() + 86400 + 3600,
                _ts() + 86400 + 3660,
                10,
                200e18,
                address(sys.feePolicy),
                seedData
            );

        ISignalsCore.Market memory m1 = sys.core.harnessGetMarket(1);
        ISignalsCore.Market memory m2 = sys.core.harnessGetMarket(2);

        // Ratio should be ~200 (195-205)
        uint256 ratio = (m2.deltaEt * 100) / m1.deltaEt;
        assertGe(ratio, 195);
        assertLe(ratio, 205);
    }

    // ============================================================
    // DeltaEt calculation
    // ============================================================

    function test_uniformPriorAllFactorsWad_deltaEtZero() public {
        uint256[] memory factors = uniformFactors(10);
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(1_000e18);

        vm.prank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );

        assertEq(sys.core.harnessGetMarket(1).deltaEt, 0);
    }

    function test_skewedPrior_oneBin2x_deltaEtGtZero() public {
        uint256[] memory factors = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            factors[i] = WAD;
        }
        factors[0] = 2 * WAD;
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(1_000e18);

        vm.prank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );

        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        assertGt(m.deltaEt, 0);
        assertLt(m.deltaEt, 15e18);
    }

    function test_extremeSkew_oneBin10x_largerDeltaEt() public {
        uint256[] memory factors = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            factors[i] = WAD;
        }
        factors[0] = 10 * WAD;
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(10_000e18);

        vm.prank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );

        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        assertGt(m.deltaEt, 50e18);
        assertLt(m.deltaEt, 100e18);
    }

    function test_minFactorLtWad_increasesDeltaEt() public {
        uint256[] memory factors = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            factors[i] = WAD;
        }
        factors[5] = WAD / 2;
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(10_000e18);

        vm.prank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );

        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        assertGt(m.deltaEt, 50e18);
    }

    // ============================================================
    // Multiple markets per batch
    // ============================================================

    function test_allowsFirstMarketForBatch() public {
        uint256[] memory factors = uniformFactors(10);
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(1_000e18);

        vm.prank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, _ts() + 3660, 10, 100e18, address(sys.feePolicy), seedData
            );
    }

    function test_allowsSecondMarketForSameBatch() public {
        uint256[] memory factors = uniformFactors(10);
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(1_000e18);

        uint64 settlementTime = _ts() + 3660;

        vm.startPrank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, settlementTime, 10, 100e18, address(sys.feePolicy), seedData
            );
        sys.core
            .createMarket(
                200, 300, 10, _ts() + 100, _ts() + 3500, settlementTime, 10, 100e18, address(sys.feePolicy), seedData
            );
        vm.stopPrank();
    }

    function test_allowsMarketsInDifferentBatches() public {
        uint256[] memory factors = uniformFactors(10);
        address seedData = address(SeedHelper.deploySeedData(factors));
        _setBackstopNav(1_000e18);

        uint64 settlementTime1 = _ts() + 3660;
        uint64 settlementTime2 = settlementTime1 + 86400;

        vm.startPrank(sys.owner);
        sys.core
            .createMarket(
                0, 100, 10, _ts() + 60, _ts() + 3600, settlementTime1, 10, 100e18, address(sys.feePolicy), seedData
            );
        sys.core
            .createMarket(
                200,
                300,
                10,
                _ts() + 60 + 86400,
                _ts() + 3600 + 86400,
                settlementTime2,
                10,
                100e18,
                address(sys.feePolicy),
                seedData
            );
        vm.stopPrank();
    }
}
