// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./base/ForkBaseTest.sol";
import "../../../contracts/core/SignalsCore.sol";
import "../../../contracts/modules/TradeModule.sol";
import "../../../contracts/modules/MarketLifecycleModule.sol";
import "../../../contracts/modules/LPVaultModule.sol";
import "../../../contracts/modules/DecommissionModule.sol";
import "../../../contracts/interfaces/ISignalsPosition.sol";
import "../../../contracts/errors/SignalsErrors.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ModuleSwapSimulation
/// @notice Verifies module swap on live forked state doesn't break existing data.
contract ModuleSwapSimulationTest is ForkBaseTest {
    IERC20 internal ctUSD;

    struct PositionSnapshot {
        uint256 nextId;
        bool exists;
        uint256 positionId;
        address owner;
        ISignalsPosition.Position data;
    }

    function setUp() public override {
        super.setUp();
        ctUSD = IERC20(paymentToken);
    }

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
                post.liquidityParameter, pre[i].liquidityParameter, string.concat("market ", id, ": liqParam changed")
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

    function test_decommission_module_sweeps_full_core_balance_and_restores_vault() public {
        uint256 coreBalance = ctUSD.balanceOf(address(core));
        if (coreBalance == 0) return;

        DecommissionModule decommission = new DecommissionModule(paymentToken);
        bool hasMarket = core.nextMarketId() > 0;
        MarketSnapshot memory marketBefore;
        if (hasMarket) {
            marketBefore = _readMarket(1);
        }
        PositionSnapshot memory positionBefore = _readPositionSnapshot();
        address originalVault = core.vaultModule();
        uint256 safeBefore = ctUSD.balanceOf(ownerSafe);

        _swapSweepRestore(decommission);

        assertEq(ctUSD.balanceOf(address(core)), 0, "core balance not swept");
        assertEq(ctUSD.balanceOf(ownerSafe) - safeBefore, coreBalance, "safe did not receive full core balance");
        assertEq(core.vaultModule(), originalVault, "vault module not restored");
        if (hasMarket) {
            _assertMarketSnapshot(1, marketBefore);
        }
        _assertPositionSnapshot(positionBefore);
    }

    function test_decommission_module_direct_call_reverts() public {
        DecommissionModule decommission = new DecommissionModule(paymentToken);

        vm.expectRevert(SignalsErrors.NotDelegated.selector);
        decommission.withdrawTreasury(0, ownerSafe);
    }

    function test_decommission_sweep_succeeds_while_core_is_paused() public {
        uint256 coreBalance = ctUSD.balanceOf(address(core));
        if (coreBalance == 0) return;

        DecommissionModule decommission = new DecommissionModule(paymentToken);
        address originalVault = core.vaultModule();
        uint256 safeBefore = ctUSD.balanceOf(ownerSafe);

        if (!core.paused()) {
            vm.prank(ownerSafe);
            core.pause();
        }

        _swapSweepRestore(decommission);

        assertTrue(core.paused(), "core should still be paused");
        assertEq(ctUSD.balanceOf(address(core)), 0, "paused core balance not swept");
        assertEq(ctUSD.balanceOf(ownerSafe) - safeBefore, coreBalance, "safe did not receive paused sweep");
        assertEq(core.vaultModule(), originalVault, "vault module not restored after paused sweep");
    }

    function _swapSweepRestore(DecommissionModule decommission) internal {
        address trade = core.tradeModule();
        address lifecycle = core.lifecycleModule();
        address risk = core.riskModule();
        address originalVault = core.vaultModule();
        address oracle = core.oracleModule();

        vm.startPrank(ownerSafe);
        core.setModules(trade, lifecycle, risk, address(decommission), oracle);
        core.withdrawTreasury(1);
        core.setModules(trade, lifecycle, risk, originalVault, oracle);
        vm.stopPrank();
    }

    function _readPositionSnapshot() internal view returns (PositionSnapshot memory snap) {
        snap.nextId = position.nextId();
        uint256 upper = snap.nextId > 25 ? 25 : snap.nextId;
        for (uint256 id = 1; id < upper; id++) {
            if (!position.exists(id)) continue;
            snap.exists = true;
            snap.positionId = id;
            snap.owner = position.ownerOf(id);
            snap.data = position.getPosition(id);
            break;
        }
    }

    function _assertMarketSnapshot(uint256 marketId, MarketSnapshot memory expected) internal view {
        MarketSnapshot memory actual = _readMarket(marketId);
        assertEq(actual.isSeeded, expected.isSeeded, "market isSeeded changed");
        assertEq(actual.settled, expected.settled, "market settled changed");
        assertEq(actual.numBins, expected.numBins, "market numBins changed");
        assertEq(actual.startTs, expected.startTs, "market startTs changed");
        assertEq(actual.endTs, expected.endTs, "market endTs changed");
        assertEq(actual.liquidityParameter, expected.liquidityParameter, "market liquidityParameter changed");
        assertEq(actual.initialRootSum, expected.initialRootSum, "market initialRootSum changed");
    }

    function _assertPositionSnapshot(PositionSnapshot memory expected) internal view {
        assertEq(position.nextId(), expected.nextId, "position nextId changed");
        if (!expected.exists) return;

        assertTrue(position.exists(expected.positionId), "position disappeared");
        assertEq(position.ownerOf(expected.positionId), expected.owner, "position owner changed");

        ISignalsPosition.Position memory actual = position.getPosition(expected.positionId);
        assertEq(actual.marketId, expected.data.marketId, "position marketId changed");
        assertEq(actual.lowerTick, expected.data.lowerTick, "position lowerTick changed");
        assertEq(actual.upperTick, expected.data.upperTick, "position upperTick changed");
        assertEq(actual.quantity, expected.data.quantity, "position quantity changed");
        assertEq(actual.createdAt, expected.data.createdAt, "position createdAt changed");
    }
}
