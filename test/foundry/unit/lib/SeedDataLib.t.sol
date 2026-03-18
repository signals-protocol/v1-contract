// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../base/SeedHelper.sol";
import "../../../../contracts/testonly/SeedDataLibHarness.sol";
import "../../../../contracts/utils/SeedData.sol";

contract SeedDataLibTest is HarnessDeployer {
    SeedDataLibHarness harness;

    function setUp() public override {
        super.setUp();
        harness = deploySeedDataLibHarness();
    }

    function test_readFactorsByRange() public {
        uint256[] memory factors = new uint256[](4);
        factors[0] = WAD;
        factors[1] = 2 * WAD;
        factors[2] = 3 * WAD;
        factors[3] = 4 * WAD;
        SeedData seedData = SeedHelper.deploySeedData(factors);

        uint256[] memory slice = harness.readFactors(address(seedData), 1, 2);
        assertEq(slice.length, 2);
        assertEq(slice[0], 2 * WAD);
        assertEq(slice[1], 3 * WAD);

        uint256[] memory empty = harness.readFactors(address(seedData), 0, 0);
        assertEq(empty.length, 0);
    }

    function test_validateSeedData_rejectsZeroAddress() public {
        vm.expectRevert();
        harness.validateSeedData(address(0), 4);
    }

    function test_validateSeedData_rejectsSizeMismatch() public {
        uint256[] memory factors = _uniformFactors(4);
        SeedData seedData = SeedHelper.deploySeedData(factors);

        vm.expectRevert();
        harness.validateSeedData(address(seedData), 5);
    }

    function test_computeSeedStats_uniformPrior() public {
        uint32 numBins = 4;
        uint256 alpha = 100e18;
        uint256[] memory factors = _uniformFactors(numBins);
        SeedData seedData = SeedHelper.deploySeedData(factors);

        (uint256 rootSum, uint256 minFactor, uint256 deltaEt) = harness.computeSeedStats(
            address(seedData),
            numBins,
            alpha
        );

        assertEq(rootSum, uint256(numBins) * WAD);
        assertEq(minFactor, WAD);
        assertEq(deltaEt, 0);
    }

    function test_computeSeedStats_skewedPrior() public {
        uint32 numBins = 4;
        uint256 alpha = 100e18;
        uint256[] memory factors = new uint256[](4);
        factors[0] = 2 * WAD;
        factors[1] = WAD;
        factors[2] = WAD;
        factors[3] = WAD;
        SeedData seedData = SeedHelper.deploySeedData(factors);

        (uint256 rootSum, uint256 minFactor, uint256 deltaEt) = harness.computeSeedStats(
            address(seedData),
            numBins,
            alpha
        );

        assertEq(rootSum, 5 * WAD);
        assertEq(minFactor, WAD);

        uint256 expectedDelta = harness.calculateDeltaEt(alpha, numBins, rootSum, minFactor);
        assertEq(deltaEt, expectedDelta);
        assertGt(deltaEt, 0);
    }

    function test_computeSeedStats_revertsOnZeroFactor() public {
        uint32 numBins = 4;
        uint256 alpha = 100e18;
        uint256[] memory factors = new uint256[](4);
        factors[0] = WAD;
        factors[1] = 0;
        factors[2] = WAD;
        factors[3] = WAD;
        SeedData seedData = SeedHelper.deploySeedData(factors);

        vm.expectRevert();
        harness.computeSeedStats(address(seedData), numBins, alpha);
    }

    function _uniformFactors(uint32 n) private pure returns (uint256[] memory factors) {
        factors = new uint256[](n);
        for (uint32 i = 0; i < n; i++) {
            factors[i] = 1e18;
        }
    }
}
