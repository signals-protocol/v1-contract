// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./SignalsBaseTest.sol";

import "../../../contracts/testonly/FixedPointMathHarness.sol";
import "../../../contracts/testonly/LazyMulSegmentTreeHarness.sol";
import "../../../contracts/testonly/ClmsrMathHarness.sol";
import "../../../contracts/testonly/FeeWaterfallLibHarness.sol";
import "../../../contracts/testonly/ExposureDiffLibHarness.sol";
import "../../../contracts/testonly/SeedDataLibHarness.sol";
import "../../../contracts/testonly/TickBinLibHarness.sol";
import "../../../contracts/testonly/VaultAccountingLibHarness.sol";
import "../../../contracts/testonly/SignalsDistributionMathHarness.sol";
import "../../../contracts/testonly/RiskMathHarness.sol";

/// @title HarnessDeployer
/// @notice Deploys individual library harness contracts for isolated unit testing.
/// @dev Foundry auto-deploys and links libraries (e.g. LazyMulSegmentTree) when using `new`.
abstract contract HarnessDeployer is SignalsBaseTest {
    // From deploy.ts — 3 existing harness deployers

    function deployFixedPointMathHarness() internal returns (FixedPointMathHarness h) {
        h = new FixedPointMathHarness();
        vm.label(address(h), "FixedPointMathHarness");
    }

    function deployLazyMulSegmentTreeHarness() internal returns (LazyMulSegmentTreeHarness h) {
        h = new LazyMulSegmentTreeHarness();
        vm.label(address(h), "LazyMulSegmentTreeHarness");
    }

    function deployClmsrMathHarness() internal returns (ClmsrMathHarness h) {
        h = new ClmsrMathHarness();
        vm.label(address(h), "ClmsrMathHarness");
    }

    // Consolidated from individual test files

    function deployFeeWaterfallLibHarness() internal returns (FeeWaterfallLibHarness h) {
        h = new FeeWaterfallLibHarness();
        vm.label(address(h), "FeeWaterfallLibHarness");
    }

    function deployExposureDiffLibHarness() internal returns (ExposureDiffLibHarness h) {
        h = new ExposureDiffLibHarness();
        vm.label(address(h), "ExposureDiffLibHarness");
    }

    function deploySeedDataLibHarness() internal returns (SeedDataLibHarness h) {
        h = new SeedDataLibHarness();
        vm.label(address(h), "SeedDataLibHarness");
    }

    function deployTickBinLibHarness() internal returns (TickBinLibHarness h) {
        h = new TickBinLibHarness();
        vm.label(address(h), "TickBinLibHarness");
    }

    function deployVaultAccountingLibHarness() internal returns (VaultAccountingLibHarness h) {
        h = new VaultAccountingLibHarness();
        vm.label(address(h), "VaultAccountingLibHarness");
    }

    // Note: file is SignalsDistributionMathHarness.sol, contract name is ClmsrMathCostHarness
    function deployClmsrMathCostHarness() internal returns (ClmsrMathCostHarness h) {
        h = new ClmsrMathCostHarness();
        vm.label(address(h), "ClmsrMathCostHarness");
    }

    function deployRiskMathHarness() internal returns (RiskMathHarness h) {
        h = new RiskMathHarness();
        vm.label(address(h), "RiskMathHarness");
    }
}
