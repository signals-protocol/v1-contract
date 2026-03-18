// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../base/TradeModuleDeployer.sol";

/// @title TradeHandler
/// @notice Stateful handler for Foundry invariant testing of CLMSR trade operations.
/// @dev The fuzzer calls doTrade/doClose with random seeds; the test contract checks invariants.
contract TradeHandler is Test {
    TradeModuleProxy public core;
    SignalsPosition public position;
    uint256 public marketId;
    uint32 public numBins;
    address public user;

    // Ghost variables for invariant checking
    uint256 public tradeCount;
    uint256 public closeCount;
    uint256[] public openPositionIds;

    // Track sum direction for monotonicity checks
    uint256 public lastSumAfterTrade;

    constructor(TradeModuleProxy _core, SignalsPosition _position, uint256 _marketId, uint32 _numBins, address _user) {
        core = _core;
        position = _position;
        marketId = _marketId;
        numBins = _numBins;
        user = _user;
        lastSumAfterTrade = _core.getMarketTotalSum(_marketId);
    }

    /// @notice Execute a buy trade with fuzzed parameters
    function doTrade(uint256 seed) external {
        // Derive range from seed
        uint32 lo = uint32(seed % (numBins - 1));
        uint32 hi = lo + 1 + uint32((seed >> 8) % (numBins - lo - 1));
        if (hi > numBins) hi = numBins;
        if (hi <= lo) hi = lo + 1;

        // Use small quantity to avoid overflow
        uint128 quantity = uint128(100 + ((seed >> 16) % 9_900)); // 100..9999

        uint256 nextId = position.nextId();

        vm.prank(user);
        try
            core.openPosition(
                marketId,
                int256(uint256(lo)),
                int256(uint256(hi)),
                quantity,
                100_000e6 // large maxCost
            )
        {
            openPositionIds.push(nextId);
            tradeCount++;
            lastSumAfterTrade = core.getMarketTotalSum(marketId);
        } catch {
            // Revert is acceptable (e.g., cost too high)
        }
    }

    /// @notice Close a random open position
    function doClose(uint256 seed) external {
        if (openPositionIds.length == 0) return;

        uint256 idx = seed % openPositionIds.length;
        uint256 positionId = openPositionIds[idx];

        // Remove from array (swap and pop)
        openPositionIds[idx] = openPositionIds[openPositionIds.length - 1];
        openPositionIds.pop();

        vm.prank(user);
        try core.closePosition(positionId, 0) {
            closeCount++;
        } catch {
            // Position may have already been closed
        }
    }

    function getOpenPositionCount() external view returns (uint256) {
        return openPositionIds.length;
    }
}
