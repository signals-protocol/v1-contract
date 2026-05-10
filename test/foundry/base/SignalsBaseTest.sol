// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

/// @title SignalsBaseTest
/// @notice Base test contract with constants, time helpers, PRNG, and factor utils.
/// @dev All Foundry test contracts should inherit from this (directly or via a deployer).
abstract contract SignalsBaseTest is Test {
    // ============================================================
    // WAD (18 decimals) constants — from constants.ts:5-7
    // ============================================================
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = 0.5e18;
    uint256 internal constant TWO_WAD = 2e18;

    // ============================================================
    // USDC (6 decimals) constants — from constants.ts:10-11
    // ============================================================
    uint8 internal constant USDC_DECIMALS = 6;
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000_000e6;

    // ============================================================
    // Market constants — from constants.ts:14-16
    // ============================================================
    uint256 internal constant ALPHA = 1e18;
    uint32 internal constant TICK_COUNT = 100;
    uint256 internal constant MARKET_DURATION = 7 days;

    // ============================================================
    // Test quantities (6 decimals) — from constants.ts:19-21
    // ============================================================
    uint256 internal constant SMALL_QUANTITY = 1000; // 0.001e6
    uint256 internal constant MEDIUM_QUANTITY = 10_000; // 0.01e6
    uint256 internal constant LARGE_QUANTITY = 100_000; // 0.1e6

    // ============================================================
    // Cost limits (6 decimals) — from constants.ts:24-26
    // ============================================================
    uint256 internal constant SMALL_COST = 10_000; // 0.01e6
    uint256 internal constant MEDIUM_COST = 100_000; // 0.1e6
    uint256 internal constant LARGE_COST = 1_000_000; // 1e6

    // ============================================================
    // Factor limits (WAD) — from constants.ts:29-30
    // ============================================================
    uint256 internal constant MIN_FACTOR = 0.01e18;
    uint256 internal constant MAX_FACTOR = 100e18;

    // ============================================================
    // Tolerance — from constants.ts:33-34
    // ============================================================
    uint256 internal constant DEFAULT_TOLERANCE = 1e10;
    uint256 internal constant LOOSE_TOLERANCE = 1e14;

    // ============================================================
    // Time constants — from constants.ts:37-40
    // ============================================================
    uint256 internal constant ONE_DAY = 86_400;
    uint256 internal constant ONE_HOUR = 3600;
    uint64 internal constant BATCH_SECONDS = 86_400;
    uint64 internal constant PST_OFFSET_SECONDS = 28_800; // 8 * 3600

    // ============================================================
    // Setup — warp to realistic timestamp
    // ============================================================

    function setUp() public virtual {
        vm.warp(1_700_000_000);
    }

    // ============================================================
    // State snapshot helpers — for mid-test checkpoint/restore
    // ============================================================

    function snapshotHere() internal returns (uint256) {
        return vm.snapshotState();
    }

    function revertHere(uint256 snapshotId) internal {
        require(vm.revertToState(snapshotId), "revertHere: invalid snapshot");
    }

    // ============================================================
    // Batch helpers — from constants.ts:42-53
    // ============================================================

    function toBatchId(uint64 ts) internal pure returns (uint64) {
        if (ts < PST_OFFSET_SECONDS) return 0;
        return (ts - PST_OFFSET_SECONDS) / BATCH_SECONDS;
    }

    function batchStartTimestamp(uint64 id) internal pure returns (uint64) {
        return id * BATCH_SECONDS + PST_OFFSET_SECONDS;
    }

    function batchEndTimestamp(uint64 id) internal pure returns (uint64) {
        return batchStartTimestamp(id + 1);
    }

    // ============================================================
    // Time manipulation
    // ============================================================

    function advancePastBatchEnd(uint64 batchId) internal {
        vm.warp(batchEndTimestamp(batchId) + 1);
    }

    // ============================================================
    // Factor helpers
    // ============================================================

    function uniformFactors(uint32 n) internal pure returns (uint256[] memory factors) {
        factors = new uint256[](n);
        for (uint32 i = 0; i < n; i++) {
            factors[i] = WAD;
        }
    }

    // ============================================================
    // PRNG — matches utils.ts:50-80 exactly
    // LCG parameters:
    //   seed     = 0x6eed0e9dafbb99b5
    //   mult     = 6364136223846793005
    //   inc      = 1442695040888963407
    //   mod      = 2^64 (via uint64 truncation in unchecked block)
    // ============================================================

    struct Prng {
        uint64 state;
    }

    uint64 internal constant PRNG_DEFAULT_SEED = 0x6eed0e9dafbb99b5;
    uint64 internal constant PRNG_MULTIPLIER = 6_364_136_223_846_793_005;
    uint64 internal constant PRNG_INCREMENT = 1_442_695_040_888_963_407;

    function createPrng() internal pure returns (Prng memory) {
        return Prng({state: PRNG_DEFAULT_SEED});
    }

    function createPrng(uint64 seed) internal pure returns (Prng memory) {
        return Prng({state: seed});
    }

    function nextRand(Prng memory prng) internal pure returns (uint64 val) {
        unchecked {
            prng.state = prng.state * PRNG_MULTIPLIER + PRNG_INCREMENT;
        }
        return prng.state;
    }

    function nextInRange(Prng memory prng, uint256 min, uint256 max) internal pure returns (uint256) {
        require(min < max, "min must be less than max");
        uint64 raw = nextRand(prng);
        return min + (uint256(raw) % (max - min));
    }

    function randomFactors(Prng memory prng, uint32 count, uint256 min, uint256 max)
        internal
        pure
        returns (uint256[] memory factors)
    {
        factors = new uint256[](count);
        for (uint32 i = 0; i < count; i++) {
            factors[i] = nextInRange(prng, min, max);
        }
    }
}
