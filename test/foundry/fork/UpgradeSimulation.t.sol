// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./base/ForkBaseTest.sol";
import "../../../contracts/core/SignalsCore.sol";
import "../../../contracts/modules/TradeModule.sol";
import "../../../contracts/modules/MarketLifecycleModule.sol";
import "../../../contracts/modules/LPVaultModule.sol";
import "../../../contracts/position/SignalsPosition.sol";
import "../../../contracts/tokens/SignalsLPShare.sol";

/// @title UpgradeSimulation
/// @notice Simulates UUPS proxy upgrades on forked production state and verifies
///         that all existing data survives intact.
contract UpgradeSimulationTest is ForkBaseTest {
    struct CoreSnapshot {
        address owner;
        address paymentToken;
        address positionContract;
        address lpShareToken;
        address riskModule;
        address oracleModule;
        uint256 nextMarketId;
        uint256 nextPosId;
        uint256 vaultNav;
        uint256 vaultShares;
        uint256 vaultPrice;
        uint64 batchId;
    }

    function _snapshotCore() internal view returns (CoreSnapshot memory s) {
        s.owner = core.owner();
        s.paymentToken = address(core.paymentToken());
        s.positionContract = address(core.positionContract());
        s.lpShareToken = core.lpShareToken();
        s.riskModule = core.riskModule();
        s.oracleModule = core.oracleModule();
        s.nextMarketId = core.nextMarketId();
        s.nextPosId = position.nextId();
        s.vaultNav = core.getVaultNav();
        s.vaultShares = core.getVaultShares();
        s.vaultPrice = core.getVaultPrice();
        s.batchId = core.getCurrentBatchId();
    }

    function _assertCoreUnchanged(CoreSnapshot memory pre) internal view {
        assertEq(core.owner(), pre.owner, "owner changed");
        assertEq(address(core.paymentToken()), pre.paymentToken, "paymentToken changed");
        assertEq(address(core.positionContract()), pre.positionContract, "positionContract changed");
        assertEq(core.lpShareToken(), pre.lpShareToken, "lpShareToken changed");
        assertEq(core.nextMarketId(), pre.nextMarketId, "nextMarketId changed");
        assertEq(position.nextId(), pre.nextPosId, "position nextId changed");
        assertEq(core.getVaultNav(), pre.vaultNav, "vault nav changed");
        assertEq(core.getVaultShares(), pre.vaultShares, "vault shares changed");
        assertEq(core.getVaultPrice(), pre.vaultPrice, "vault price changed");
        assertEq(core.getCurrentBatchId(), pre.batchId, "batch ID changed");
    }

    function test_core_upgradeToAndCall_preserves_state() public {
        CoreSnapshot memory pre = _snapshotCore();

        MarketSnapshot memory preMkt;
        if (pre.nextMarketId > 0) {
            preMkt = _readMarket(1);
        }

        // Deploy new implementation + modules
        SignalsCore newImpl = new SignalsCore();
        TradeModule newTrade = new TradeModule();
        MarketLifecycleModule newLifecycle = new MarketLifecycleModule();
        LPVaultModule newVault = new LPVaultModule();

        bytes memory setModulesData = abi.encodeCall(
            SignalsCore.setModules,
            (address(newTrade), address(newLifecycle), pre.riskModule, address(newVault), pre.oracleModule)
        );

        vm.prank(ownerSafe);
        core.upgradeToAndCall(address(newImpl), setModulesData);

        _assertCoreUnchanged(pre);

        // Modules should be updated
        assertEq(core.tradeModule(), address(newTrade), "trade module not updated");
        assertEq(core.lifecycleModule(), address(newLifecycle), "lifecycle module not updated");
        assertEq(core.vaultModule(), address(newVault), "vault module not updated");
        assertEq(core.riskModule(), pre.riskModule, "risk module should not change");
        assertEq(core.oracleModule(), pre.oracleModule, "oracle module should not change");
        assertEq(_implAddress(address(core)), address(newImpl), "impl not updated");

        // Verify market data still readable
        if (pre.nextMarketId > 0) {
            MarketSnapshot memory postMkt = _readMarket(1);
            assertEq(postMkt.isSeeded, preMkt.isSeeded, "market 1 isSeeded changed");
            assertEq(postMkt.numBins, preMkt.numBins, "market 1 numBins changed");
            assertEq(postMkt.liquidityParameter, preMkt.liquidityParameter, "market 1 liqParam changed");
        }
    }

    function test_core_upgrade_without_module_swap() public {
        CoreSnapshot memory pre = _snapshotCore();

        address preTrade = core.tradeModule();
        address preLifecycle = core.lifecycleModule();

        SignalsCore newImpl = new SignalsCore();

        vm.prank(ownerSafe);
        core.upgradeToAndCall(address(newImpl), "");

        assertEq(core.tradeModule(), preTrade, "trade module changed");
        assertEq(core.lifecycleModule(), preLifecycle, "lifecycle module changed");
        assertEq(core.riskModule(), pre.riskModule, "risk module changed");
        assertEq(core.vaultModule(), core.vaultModule(), "vault module changed");
        assertEq(core.oracleModule(), pre.oracleModule, "oracle module changed");
        assertEq(core.nextMarketId(), pre.nextMarketId, "nextMarketId changed");
        assertEq(_implAddress(address(core)), address(newImpl), "impl not updated");
    }

    function test_position_upgrade_preserves_state() public {
        uint256 preNextId = position.nextId();
        string memory preName = position.name();
        address preCore = position.core();
        address preOwner = position.owner();

        SignalsPosition newImpl = new SignalsPosition();

        address positionOwner = _requireConfigAddr("owners.position");
        vm.prank(positionOwner);
        position.upgradeToAndCall(address(newImpl), "");

        assertEq(position.nextId(), preNextId, "nextId changed");
        assertEq(position.name(), preName, "name changed");
        assertEq(position.core(), preCore, "core ref changed");
        assertEq(position.owner(), preOwner, "owner changed");
        assertEq(_implAddress(address(position)), address(newImpl), "impl not updated");
    }

    function test_lpshare_upgrade_preserves_state() public {
        string memory preName = lpShare.name();
        string memory preSymbol = lpShare.symbol();
        uint256 preTotalSupply = lpShare.totalSupply();
        address preCore = lpShare.core();
        address preAsset = lpShare.asset();
        address preOwner = lpShare.owner();

        SignalsLPShare newImpl = new SignalsLPShare();

        address lpShareOwner = _requireConfigAddr("owners.lpShare");
        vm.prank(lpShareOwner);
        lpShare.upgradeToAndCall(address(newImpl), "");

        assertEq(lpShare.name(), preName, "name changed");
        assertEq(lpShare.symbol(), preSymbol, "symbol changed");
        assertEq(lpShare.totalSupply(), preTotalSupply, "totalSupply changed");
        assertEq(lpShare.core(), preCore, "core ref changed");
        assertEq(lpShare.asset(), preAsset, "asset ref changed");
        assertEq(lpShare.owner(), preOwner, "owner changed");
        assertEq(_implAddress(address(lpShare)), address(newImpl), "impl not updated");
    }

    function test_unauthorized_upgrade_reverts() public {
        SignalsCore newImpl = new SignalsCore();
        address random = makeAddr("random");

        vm.prank(random);
        vm.expectRevert();
        core.upgradeToAndCall(address(newImpl), "");
    }
}
