// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../base/SeedHelper.sol";
import "../../../../contracts/testonly/SeedDataLibHarness.sol";
import "../../../../contracts/utils/SeedData.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

contract SeedDataLibFuzzTest is HarnessDeployer {
    SeedDataLibHarness harness;

    function setUp() public override {
        super.setUp();
        harness = deploySeedDataLibHarness();
    }

    // ============================================================
    // readFactors fuzz tests
    // ============================================================

    /// @notice Store-then-load fidelity: deployed factors read back identically
    function testFuzz_readFactors_roundTrip(uint64 seed, uint8 _rawNumBins) public {
        uint32 numBins = uint32(bound(_rawNumBins, 1, 32));
        Prng memory prng = createPrng(seed);

        uint256[] memory factors = randomFactors(prng, numBins, 1, 100e18);
        SeedData seedData = SeedHelper.deploySeedData(factors);

        uint256[] memory result = harness.readFactors(address(seedData), 0, numBins);

        assertEq(result.length, factors.length);
        for (uint32 i = 0; i < numBins; i++) {
            assertEq(result[i], factors[i]);
        }
    }

    /// @notice Arbitrary valid slices are consistent with full read
    function testFuzz_readFactors_sliceConsistency(uint64 seed, uint8 _rawNumBins, uint8 _rawStart, uint8 _rawCount)
        public
    {
        uint32 numBins = uint32(bound(_rawNumBins, 2, 32));
        Prng memory prng = createPrng(seed);

        uint256[] memory factors = randomFactors(prng, numBins, 1, 100e18);
        SeedData seedData = SeedHelper.deploySeedData(factors);

        uint32 start = uint32(bound(_rawStart, 0, numBins - 1));
        uint32 count = uint32(bound(_rawCount, 1, numBins - start));

        uint256[] memory fullRead = harness.readFactors(address(seedData), 0, numBins);
        uint256[] memory slice = harness.readFactors(address(seedData), start, count);

        assertEq(slice.length, count);
        for (uint32 i = 0; i < count; i++) {
            assertEq(slice[i], fullRead[start + i]);
        }
    }

    // ============================================================
    // validateSeedData fuzz tests
    // ============================================================

    /// @notice Matching size is always accepted
    function testFuzz_validateSeedData_acceptsCorrectSize(uint64 seed, uint8 _rawNumBins) public {
        uint32 numBins = uint32(bound(_rawNumBins, 1, 32));
        Prng memory prng = createPrng(seed);

        uint256[] memory factors = randomFactors(prng, numBins, 1, 100e18);
        SeedData seedData = SeedHelper.deploySeedData(factors);

        // Should not revert
        harness.validateSeedData(address(seedData), numBins);
    }

    /// @notice Mismatched bin count always reverts
    function testFuzz_validateSeedData_rejectsWrongSize(uint64 seed, uint8 _rawNumBins, uint8 _rawWrongBins) public {
        uint32 numBins = uint32(bound(_rawNumBins, 1, 32));
        Prng memory prng = createPrng(seed);

        uint256[] memory factors = randomFactors(prng, numBins, 1, 100e18);
        SeedData seedData = SeedHelper.deploySeedData(factors);

        uint32 wrongBins = uint32(bound(_rawWrongBins, 1, 32));
        if (wrongBins == numBins) {
            wrongBins = numBins == 32 ? 1 : numBins + 1;
        }

        vm.expectPartialRevert(SE.SeedDataLengthMismatch.selector);
        harness.validateSeedData(address(seedData), wrongBins);
    }

    // ============================================================
    // computeSeedStats fuzz tests
    // ============================================================

    /// @notice Uniform distribution produces zero deltaEt
    function testFuzz_computeSeedStats_uniformDeltaEtIsZero(uint8 _rawNumBins, uint128 _rawFactor, uint128 _rawAlpha)
        public
    {
        uint32 numBins = uint32(bound(_rawNumBins, 1, 32));
        uint256 factorValue = bound(_rawFactor, 1, 100e18);
        uint256 alpha = bound(_rawAlpha, 1e18, 10_000e18);

        uint256[] memory factors = new uint256[](numBins);
        for (uint32 i = 0; i < numBins; i++) {
            factors[i] = factorValue;
        }
        SeedData seedData = SeedHelper.deploySeedData(factors);

        (uint256 rootSum, uint256 minFactor, uint256 deltaEt) =
            harness.computeSeedStats(address(seedData), numBins, alpha);

        assertEq(deltaEt, 0, "uniform prior should have zero deltaEt");
        assertEq(rootSum, uint256(numBins) * factorValue, "rootSum should be numBins * factor");
        assertEq(minFactor, factorValue, "minFactor should equal the uniform factor value");
    }

    /// @notice rootSum is exact arithmetic sum of all factors
    function testFuzz_computeSeedStats_rootSumEqualsFactorSum(uint64 seed, uint8 _rawNumBins, uint128 _rawAlpha)
        public
    {
        uint32 numBins = uint32(bound(_rawNumBins, 1, 32));
        uint256 alpha = bound(_rawAlpha, 1e18, 10_000e18);
        Prng memory prng = createPrng(seed);

        uint256[] memory factors = randomFactors(prng, numBins, 1, 100e18);
        SeedData seedData = SeedHelper.deploySeedData(factors);

        uint256 expectedSum;
        for (uint32 i = 0; i < numBins; i++) {
            expectedSum += factors[i];
        }

        (uint256 rootSum,,) = harness.computeSeedStats(address(seedData), numBins, alpha);

        assertEq(rootSum, expectedSum);
    }

    /// @notice minFactor is truly the smallest factor
    function testFuzz_computeSeedStats_minFactorIsSmallest(uint64 seed, uint8 _rawNumBins, uint128 _rawAlpha) public {
        uint32 numBins = uint32(bound(_rawNumBins, 1, 32));
        uint256 alpha = bound(_rawAlpha, 1e18, 10_000e18);
        Prng memory prng = createPrng(seed);

        uint256[] memory factors = randomFactors(prng, numBins, 1, 100e18);
        SeedData seedData = SeedHelper.deploySeedData(factors);

        uint256 expectedMin = type(uint256).max;
        for (uint32 i = 0; i < numBins; i++) {
            if (factors[i] < expectedMin) expectedMin = factors[i];
        }

        (, uint256 minFactor,) = harness.computeSeedStats(address(seedData), numBins, alpha);

        assertEq(minFactor, expectedMin);
    }

    /// @notice Any zero factor triggers revert regardless of position
    function testFuzz_computeSeedStats_zeroFactorAlwaysReverts(
        uint64 seed,
        uint8 _rawNumBins,
        uint128 _rawAlpha,
        uint8 _rawZeroIdx
    ) public {
        uint32 numBins = uint32(bound(_rawNumBins, 1, 32));
        uint256 alpha = bound(_rawAlpha, 1e18, 10_000e18);
        Prng memory prng = createPrng(seed);

        uint256[] memory factors = randomFactors(prng, numBins, 1, 100e18);
        uint32 zeroIdx = uint32(bound(_rawZeroIdx, 0, numBins - 1));
        factors[zeroIdx] = 0;
        SeedData seedData = SeedHelper.deploySeedData(factors);

        vm.expectPartialRevert(SE.InvalidFactor.selector);
        harness.computeSeedStats(address(seedData), numBins, alpha);
    }

    /// @notice Non-uniform prior produces positive deltaEt
    function testFuzz_computeSeedStats_skewedHasPositiveDeltaEt(
        uint64,
        uint8 _rawNumBins,
        uint128 _rawAlpha,
        uint8 _rawBoostIdx,
        uint128 _rawBoostAmount
    ) public {
        uint32 numBins = uint32(bound(_rawNumBins, 2, 32));
        uint256 alpha = bound(_rawAlpha, 1e18, 10_000e18);
        uint256 boostAmount = bound(_rawBoostAmount, 1, 100e18);
        uint32 boostIdx = uint32(bound(_rawBoostIdx, 0, numBins - 1));

        // Start with uniform factors (WAD), then boost one
        uint256[] memory factors = new uint256[](numBins);
        for (uint32 i = 0; i < numBins; i++) {
            factors[i] = WAD;
        }
        factors[boostIdx] += boostAmount;
        SeedData seedData = SeedHelper.deploySeedData(factors);

        (,, uint256 deltaEt) = harness.computeSeedStats(address(seedData), numBins, alpha);

        assertGt(deltaEt, 0, "skewed prior should have positive deltaEt");
    }
}
