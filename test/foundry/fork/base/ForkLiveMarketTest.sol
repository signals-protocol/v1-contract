// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./ForkBaseTest.sol";
import "../../../../contracts/interfaces/ISignalsCore.sol";

/// @title ForkLiveMarketTest
/// @notice Shared helpers for advisory fork suites that depend on an ambient live market.
abstract contract ForkLiveMarketTest is ForkBaseTest {
    function _tryFindActiveMarket()
        internal
        view
        returns (bool found, uint256 marketId, ISignalsCore.Market memory market)
    {
        uint256 upper = core.nextMarketId() + 5;
        for (uint256 i = upper; i > 0; --i) {
            try core.getMarket(i) returns (ISignalsCore.Market memory candidate) {
                if (
                    candidate.isSeeded &&
                    !candidate.settled &&
                    block.timestamp >= candidate.startTimestamp &&
                    block.timestamp <= candidate.endTimestamp
                ) {
                    return (true, i, candidate);
                }
            } catch {
                continue;
            }
        }
    }
}
