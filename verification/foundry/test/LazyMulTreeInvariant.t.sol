// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LazyMulTreeTarget.sol";

contract LazyMulTreeInvariant {
    uint256 internal constant DRIFT_TOLERANCE_WAD_WEI = 1e12; // 1 micro-USDC in WAD-wei.
    uint256 internal constant REL_DRIFT_DENOM = 1e12; // Allow 1e-12 relative drift at large magnitudes.
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;

    function _next(uint256 s) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(s)));
    }

    function _runStateful(uint256 seed, uint256 steps) internal {
        LazyMulTreeTarget target = new LazyMulTreeTarget(64);

        uint256 s = seed;
        for (uint256 i = 0; i < steps; i++) {
            s = _next(s);
            uint32 lo = uint32(s);
            s = _next(s);
            uint32 hi = uint32(s);
            s = _next(s);
            uint256 factor = s;

            (bool ok, bytes4 selector) = target.tryApplyBounded(lo, hi, factor);
            if (!ok) {
                // Panic is never acceptable for valid-domain fuzzing.
                assert(selector != PANIC_SELECTOR);
            }
        }

        uint256 total = target.totalSum();
        uint256 driftLeaf = target.driftTotalVsLeaf();
        uint256 driftRange = target.driftTotalVsFullRange();
        uint256 maxAllowedDrift = DRIFT_TOLERANCE_WAD_WEI + (total / REL_DRIFT_DENOM);

        assert(total > 0);
        assert(driftLeaf <= maxAllowedDrift);
        assert(driftRange <= maxAllowedDrift);
    }

    function testFuzz_stateful_256_ops(uint256 seed) public {
        _runStateful(seed, 256);
    }

    function testFuzz_stateful_1024_ops(uint256 seed) public {
        _runStateful(seed, 1024);
    }
}
