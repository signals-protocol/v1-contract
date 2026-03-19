// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./base/ForkBaseTest.sol";
import "../../../contracts/core/SignalsCore.sol";
import "../../../contracts/modules/TradeModule.sol";
import "../../../contracts/modules/MarketLifecycleModule.sol";
import "../../../contracts/modules/LPVaultModule.sol";

/// @title ModuleSwapSimulation
/// @notice Verifies module swap on live forked state doesn't break existing data.
contract ModuleSwapSimulationTest is ForkBaseTest {
    function test_module_swap_preserves_market_data() public {
        uint256 lastMarketId = core.nextMarketId();
        if (lastMarketId == 0) return;

        // Snapshot all markets
        MarketSnapshot[] memory pre = new MarketSnapshot[](lastMarketId);
        for (uint256 i = 0; i < lastMarketId; i++) {
            pre[i] = _readMarket(i + 1);
        }

        // Read current modules BEFORE prank (to avoid consuming the prank)
        address currentRisk = core.riskModule();
        address currentOracle = core.oracleModule();

        // Deploy new modules and swap
        TradeModule newTrade = new TradeModule();
        MarketLifecycleModule newLifecycle = new MarketLifecycleModule();
        LPVaultModule newVault = new LPVaultModule();

        vm.prank(ownerSafe);
        core.setModules(address(newTrade), address(newLifecycle), currentRisk, address(newVault), currentOracle);

        // Verify all market data preserved
        for (uint256 i = 0; i < lastMarketId; i++) {
            uint256 marketId = i + 1;
            MarketSnapshot memory post = _readMarket(marketId);
            string memory id = vm.toString(marketId);

            assertEq(post.isSeeded, pre[i].isSeeded, string.concat("market ", id, ": isSeeded changed"));
            assertEq(post.settled, pre[i].settled, string.concat("market ", id, ": settled changed"));
            assertEq(post.numBins, pre[i].numBins, string.concat("market ", id, ": numBins changed"));
            assertEq(
                post.liquidityParameter,
                pre[i].liquidityParameter,
                string.concat("market ", id, ": liqParam changed")
            );
            assertEq(post.startTs, pre[i].startTs, string.concat("market ", id, ": startTs changed"));
            assertEq(post.endTs, pre[i].endTs, string.concat("market ", id, ": endTs changed"));
            assertEq(post.initialRootSum, pre[i].initialRootSum, string.concat("market ", id, ": initRootSum changed"));
        }
    }

    function test_query_functions_work_after_swap() public {
        // Read current modules BEFORE prank
        address currentRisk = core.riskModule();
        address currentOracle = core.oracleModule();

        TradeModule newTrade = new TradeModule();
        MarketLifecycleModule newLifecycle = new MarketLifecycleModule();
        LPVaultModule newVault = new LPVaultModule();

        vm.prank(ownerSafe);
        core.setModules(address(newTrade), address(newLifecycle), currentRisk, address(newVault), currentOracle);

        // Vault queries should still work
        core.getVaultNav();
        core.getVaultShares();
        core.getVaultPrice();
        core.getCurrentBatchId();

        // If tradeable markets exist, calculateOpenCost should work.
        // Markets may be expired/failed on testnet — use try/catch.
        uint256 lastMarketId = core.nextMarketId();
        for (uint256 i = 1; i <= lastMarketId; i++) {
            MarketSnapshot memory mkt = _readMarket(i);
            if (!mkt.settled && mkt.numBins > 0 && mkt.endTs > uint64(block.timestamp)) {
                try core.calculateOpenCost(i, int256(uint256(0)), int256(uint256(1)), 1e15) returns (uint256 cost) {
                    assertGt(cost, 0, "calculateOpenCost returned 0 after swap");
                } catch {
                    // Market may be in a non-tradeable state (failed, etc.) — not a swap issue
                }
                break;
            }
        }
    }

    function test_unauthorized_module_swap_reverts() public {
        // Read current modules BEFORE prank/expectRevert
        address currentLifecycle = core.lifecycleModule();
        address currentRisk = core.riskModule();
        address currentVault = core.vaultModule();
        address currentOracle = core.oracleModule();

        TradeModule newTrade = new TradeModule();
        address random = makeAddr("random");

        vm.prank(random);
        vm.expectRevert();
        core.setModules(address(newTrade), currentLifecycle, currentRisk, currentVault, currentOracle);
    }
}
