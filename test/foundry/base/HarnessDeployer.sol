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

/// @title HarnessDeployer
/// @notice Deploys individual library harness contracts for isolated unit testing.
/// @dev Foundry auto-deploys and links libraries (e.g. LazyMulSegmentTree) when using `new`.
abstract contract HarnessDeployer is SignalsBaseTest {
    // From deploy.ts — 3 existing harness deployers

    function deployFixedPointMathHarness() internal returns (FixedPointMathHarness) {
        return new FixedPointMathHarness();
    }

    function deployLazyMulSegmentTreeHarness() internal returns (LazyMulSegmentTreeHarness) {
        return new LazyMulSegmentTreeHarness();
    }

    function deployClmsrMathHarness() internal returns (ClmsrMathHarness) {
        return new ClmsrMathHarness();
    }

    // Consolidated from individual test files

    function deployFeeWaterfallLibHarness() internal returns (FeeWaterfallLibHarness) {
        return new FeeWaterfallLibHarness();
    }

    function deployExposureDiffLibHarness() internal returns (ExposureDiffLibHarness) {
        return new ExposureDiffLibHarness();
    }

    function deploySeedDataLibHarness() internal returns (SeedDataLibHarness) {
        return new SeedDataLibHarness();
    }

    function deployTickBinLibHarness() internal returns (TickBinLibHarness) {
        return new TickBinLibHarness();
    }

    function deployVaultAccountingLibHarness() internal returns (VaultAccountingLibHarness) {
        return new VaultAccountingLibHarness();
    }

    // Note: file is SignalsDistributionMathHarness.sol, contract name is ClmsrMathCostHarness
    function deployClmsrMathCostHarness() internal returns (ClmsrMathCostHarness) {
        return new ClmsrMathCostHarness();
    }
}
