// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/ForkProtocolTest.sol";
import "../base/ForkRedstoneFFI.sol";
import "../../../../contracts/interfaces/ISignalsCore.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PrimarySettlementForkTest
/// @notice Advisory created-market smoke for the live Redstone primary-settlement path.
contract PrimarySettlementForkTest is ForkProtocolTest, ForkRedstoneFFI {
    IERC20 internal ctUSDToken;

    function setUp() public override(ForkBaseTest, ForkProtocolTest) {
        ForkProtocolTest.setUp();
        ctUSDToken = IERC20(paymentToken);
    }

    function test_primary_settlement_smoke_uses_live_redstone_payload() public {
        if (_isDevEnv()) return;

        uint64 targetBatch = _targetBatchAfter(uint64(block.timestamp + 120));
        uint256 marketId = _createUniformMarketForBatch(targetBatch);

        address trader = makeAddr("primarySettlementTrader");
        _fundAndApprove(trader, 100_000_000);

        uint128 quantity = 1_000_000;
        uint256 maxCost = core.calculateOpenCost(marketId, 0, 1, quantity) + 1_000_000;
        vm.prank(trader);
        core.openPosition(marketId, 0, 1, quantity, maxCost);

        uint64 settlementTimestamp = core.getMarket(marketId).settlementTimestamp;
        vm.warp(uint256(settlementTimestamp) + 1);

        bool submitted = _trySubmitPrimarySettlementSample(marketId);
        if (!submitted) return;

        vm.warp(uint256(settlementTimestamp) + core.settlementSubmitWindow() + 1);

        vm.prank(ownerSafe);
        core.finalizePrimarySettlement(marketId);

        vm.prank(ownerSafe);
        core.requestSettlementChunks(marketId, 4);

        ISignalsCore.Market memory market = core.getMarket(marketId);
        assertTrue(market.settled, "market not settled");
        assertFalse(market.failed, "market marked failed");
        assertGt(market.settlementFinalizedAt, 0, "primary finalize timestamp missing");
    }
}
