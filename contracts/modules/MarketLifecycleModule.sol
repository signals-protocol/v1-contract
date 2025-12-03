// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../errors/ModuleErrors.sol";

/// @notice Delegate-only lifecycle module (skeleton)
contract MarketLifecycleModule is SignalsCoreStorage {
    address private immutable self;

    event SettlementChunkRequested(uint256 indexed marketId, uint32 indexed chunkIndex);

    modifier onlyDelegated() {
        if (address(this) == self) revert ModuleErrors.NotDelegated();
        _;
    }

    constructor() {
        self = address(this);
    }

    // --- External stubs ---

    function createMarket(/* params */) external onlyDelegated {
        // implementation to be ported in Phase 3-4
    }

    function settleMarket(uint256 /*marketId*/) external onlyDelegated {
        // implementation to be ported in Phase 3-4
    }

    function reopenMarket(uint256 /*marketId*/) external onlyDelegated {
        // implementation to be ported in Phase 3-4
    }

    function setMarketActive(uint256 /*marketId*/, bool /*isActive*/) external onlyDelegated {
        // implementation to be ported in Phase 3-4
    }

    function updateMarketTiming(
        uint256 /*marketId*/,
        uint64 /*startTimestamp*/,
        uint64 /*endTimestamp*/,
        uint64 /*settlementTimestamp*/
    ) external onlyDelegated {
        // implementation to be ported in Phase 3-4
    }

    function requestSettlementChunks(uint256 /*marketId*/, uint32 /*maxChunksPerTx*/) external onlyDelegated {
        // implementation to be ported in Phase 3-4
    }
}
