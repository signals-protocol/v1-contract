// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/TradeModuleDeployer.sol";

/// @title FuzzTest
/// @notice Integration fuzz: randomized multi-market flows with Foundry native fuzzer.
/// @dev Mirrors test/integration/trade/fuzz.spec.ts (2 tests).
contract FuzzTest is TradeModuleDeployer {
    // ============================================================
    // Fuzz: openPositionCount invariant across random ops
    // ============================================================

    function testFuzz_maintainsOpenPositionCountAcrossRandomOps(uint64 fuzzSeed) public {
        TradeModuleSystem memory sys = deployMultiMarketSystem();

        uint256 seed = uint256(fuzzSeed);
        uint256 nextId = 1;

        // Track positions: posId -> (ownerIdx, marketId, qty, alive)
        uint256 maxPositions = 50;
        uint256[] memory ownerIdx = new uint256[](maxPositions);
        uint256[] memory mktId = new uint256[](maxPositions);
        uint256[] memory qty = new uint256[](maxPositions);
        bool[] memory alive = new bool[](maxPositions);
        uint256 posCount = 0;

        uint256 ops = 30; // fewer for fuzz speed

        for (uint256 i = 0; i < ops; i++) {
            seed = (seed * 1664525 + 1013904223) % 0xffffffff;
            uint256 op = seed % 4;
            seed = (seed * 1664525 + 1013904223) % 0xffffffff;
            uint256 userIdx = seed % sys.users.length;
            seed = (seed * 1664525 + 1013904223) % 0xffffffff;
            uint256 marketId = (seed % 2) + 1;

            int256 lo;
            int256 hi;
            if (marketId == 1) {
                lo = 0;
                hi = 4;
            } else {
                seed = (seed * 1664525 + 1013904223) % 0xffffffff;
                lo = int256(seed % 3) - 2;
                hi = lo + 1;
            }

            if (op == 0 && posCount < maxPositions) {
                // open
                seed = (seed * 1664525 + 1013904223) % 0xffffffff;
                uint128 q = uint128(500 + (seed % 1_000));
                vm.prank(sys.users[userIdx]);
                sys.core.openPosition(marketId, lo, hi, q, 20_000_000);
                ownerIdx[posCount] = userIdx;
                mktId[posCount] = marketId;
                qty[posCount] = q;
                alive[posCount] = true;
                posCount++;
                nextId++;
            } else if (op == 1) {
                // decrease
                uint256 aliveId = _findAlive(alive, posCount, seed);
                if (aliveId == type(uint256).max) continue;
                uint256 decQty = qty[aliveId] / 2;
                if (decQty == 0) continue;
                vm.prank(sys.users[ownerIdx[aliveId]]);
                sys.core.decreasePosition(aliveId + 1, uint128(decQty), 0);
                qty[aliveId] -= decQty;
                if (qty[aliveId] == 0) alive[aliveId] = false;
            } else if (op == 2) {
                // close
                uint256 aliveId = _findAlive(alive, posCount, seed);
                if (aliveId == type(uint256).max) continue;
                vm.prank(sys.users[ownerIdx[aliveId]]);
                sys.core.closePosition(aliveId + 1, 0);
                alive[aliveId] = false;
                qty[aliveId] = 0;
            } else if (op == 3) {
                // increase
                uint256 aliveId = _findAlive(alive, posCount, seed);
                if (aliveId == type(uint256).max) continue;
                seed = (seed * 1664525 + 1013904223) % 0xffffffff;
                uint128 addQty = uint128(100 + (seed % 500));
                vm.prank(sys.users[ownerIdx[aliveId]]);
                sys.core.increasePosition(aliveId + 1, addQty, 20_000_000);
                qty[aliveId] += addQty;
            }
        }

        // Verify openPositionCount matches alive positions per market
        for (uint256 mid = 1; mid <= 2; mid++) {
            uint256 aliveCount = 0;
            for (uint256 j = 0; j < posCount; j++) {
                if (alive[j] && mktId[j] == mid) aliveCount++;
            }
            ISignalsCore.Market memory m = sys.core.harnessGetMarket(mid);
            assertEq(m.openPositionCount, aliveCount, "openPositionCount mismatch");
        }

        // Verify position existence
        for (uint256 j = 0; j < posCount; j++) {
            bool exists = sys.position.exists(j + 1);
            assertEq(exists, alive[j], "position existence mismatch");
        }
    }

    // ============================================================
    // Fuzz: position quantity after random increase/decrease
    // ============================================================

    function testFuzz_preservesPositionQuantity(uint64 fuzzSeed) public {
        TradeModuleSystem memory sys = deployMinimalTradeSystem();
        address user = sys.users[0];

        uint128 initialQty = 1000;
        vm.prank(user);
        sys.core.openPosition(1, 0, 4, initialQty, 20_000_000);
        uint256 positionId = 1;

        uint256 expectedQty = initialQty;
        uint256 seed = uint256(fuzzSeed);

        for (uint256 i = 0; i < 15; i++) {
            seed = (seed * 1664525 + 1013904223) % 0xffffffff;
            uint256 op = seed % 2;
            if (op == 0) {
                // increase
                seed = (seed * 1664525 + 1013904223) % 0xffffffff;
                uint128 addQty = uint128(100 + (seed % 300));
                vm.prank(user);
                sys.core.increasePosition(positionId, addQty, 20_000_000);
                expectedQty += addQty;
            } else {
                // decrease
                if (expectedQty > 100) {
                    seed = (seed * 1664525 + 1013904223) % 0xffffffff;
                    uint256 decQty = (seed % (expectedQty / 2)) + 1;
                    vm.prank(user);
                    sys.core.decreasePosition(positionId, uint128(decQty), 0);
                    expectedQty -= decQty;
                }
            }
        }

        ISignalsPosition.Position memory pos = sys.position.getPosition(positionId);
        assertEq(pos.quantity, expectedQty, "quantity mismatch after random inc/dec");
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _findAlive(bool[] memory aliveArr, uint256 count, uint256 seed) internal pure returns (uint256) {
        if (count == 0) return type(uint256).max;
        uint256 startIdx = seed % count;
        for (uint256 i = 0; i < count; i++) {
            uint256 idx = (startIdx + i) % count;
            if (aliveArr[idx]) return idx;
        }
        return type(uint256).max;
    }
}
